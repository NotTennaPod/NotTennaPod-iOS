import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// A scripted server: each request is answered by `respond`, which sees the method, path and decoded body.
final class StubServerTransport: SynchronizationHTTPTransport, Sendable {
    struct Request: Sendable { let method: String; let path: String; let body: ContractJSON?; let authorization: String? }
    private let requests = Mutex<[Request]>([])
    private let respond: @Sendable (Request) throws -> (Int, String)
    init(_ respond: @escaping @Sendable (Request) throws -> (Int, String)) { self.respond = respond }
    var seen: [Request] { requests.withLock { $0 } }
    func send(_ request: URLRequest) async throws -> SynchronizationHTTPResponse {
        let recorded = Request(method: request.httpMethod ?? "GET", path: request.url?.path ?? "",
                               body: request.httpBody.flatMap { try? ContractJSON.decode($0) },
                               authorization: request.value(forHTTPHeaderField: "Authorization"))
        requests.withLock { $0.append(recorded) }
        let (status, body) = try respond(recorded)
        return .init(status: status, body: Data(body.utf8))
    }
}

struct ServerClientTests {
    private let address = ServerAddress(entered: "https://sync.example.test")!

    @Test func addressesNormalizeAndOnlyPlainHTTPOutsideTailscaleWarns() {
        #expect(ServerAddress(entered: " Sync.Example.Test/ ")?.string == "https://sync.example.test")
        #expect(ServerAddress(entered: "https://sync.example.test:443/base/")?.string == "https://sync.example.test/base")
        #expect(ServerAddress(entered: "192.168.1.5:80")?.string == "http://192.168.1.5")
        #expect(ServerAddress(entered: "HTTP://127.0.0.1:8080")?.string == "http://127.0.0.1:8080")
        for invalid in ["", "ftp://host", "https://user:pw@host", "https://host?x=1", "https://host#a", "https://host:99999"] {
            #expect(ServerAddress(entered: invalid) == nil, "\(invalid)")
        }
        #expect(ServerAddress(entered: "http://127.0.0.1:8080")!.showsEncryptionWarning)
        #expect(!ServerAddress(entered: "https://127.0.0.1:8080")!.showsEncryptionWarning)
        for tailscale in ["http://100.64.0.1", "http://100.127.255.254:8080", "http://mac.tail1234.ts.net",
                          "http://[fd7a:115c:a1e0::1]:8080"] {
            #expect(ServerAddress(entered: tailscale)?.isTailscale == true, "\(tailscale)")
            #expect(ServerAddress(entered: tailscale)?.showsEncryptionWarning == false, "\(tailscale)")
        }
        for other in ["http://100.128.0.1", "http://100.63.255.255", "http://ts.net.example.com", "http://[fd7a:115c:a1e1::1]"] {
            #expect(ServerAddress(entered: other)?.isTailscale == false, "\(other)")
        }
        #expect(ServerAddress(entered: "http://[fd7a:115c:a1e0::1]:8080")?.host == "fd7a:115c:a1e0::1")
    }

    @Test func infoChoosesTheProtocolOrSaysWhoNeedsUpdating() async throws {
        func info(_ body: String, status: Int = 200) async -> Result<ServerInfo, ServerClientError> {
            let client = ServerClient(address: address, transport: StubServerTransport { _ in (status, body) })
            do { return .success(try await client.info()) } catch { return .failure(error as! ServerClientError) }
        }
        let ok = try await info(#"{"server_id":"s1","protocol":{"min":1,"max":3},"bounds":{"max_operations":500}}"#).get()
        #expect(ok.serverID == "s1" && ok.protocolVersion == 1 && ok.bounds?["max_operations"]?.integerValue == 500)
        #expect(await info(#"{"server_id":"s1","protocol":{"min":2,"max":3}}"#) == .failure(.appNeedsUpdate))
        #expect(await info(#"{"server_id":"s1","protocol":{"min":0,"max":0}}"#) == .failure(.serverNeedsUpdate))
        #expect(await info("<html>It works!</html>") == .failure(.notAServer))
        #expect(await info(#"{"status":"ok"}"#) == .failure(.notAServer))
        #expect(await info(#"{"price": 1.5}"#) == .failure(.notAServer))
        #expect(await info("Not found", status: 404) == .failure(.notAServer))
        let offline = ServerClient(address: address, transport: StubServerTransport { _ in throw URLError(.cannotConnectToHost) })
        await #expect(throws: ServerClientError.unreachable) { _ = try await offline.info() }
    }

    @Test func signInErrorsAreNamedAndTheRequestCarriesTheInstallation() async throws {
        let transport = StubServerTransport { request in
            switch request.body?["password"]?.stringValue {
            case "wrong": (401, #"{"error":"unauthorized","message":"The username or password is incorrect."}"#)
            case "busy": (503, #"{"error":"server_busy","message":"Busy","retry_after":2}"#)
            case "many": (429, #"{"error":"rate_limited","message":"Too many","retry_after":61}"#)
            case "copy": (409, #"{"error":"installation_conflict","message":"…"}"#)
            case "disabled": (403, #"{"error":"forbidden","message":"…"}"#)
            default: (200, #"{"token":"ntp1_x","install_id":"\#(request.body!["install_id"]!.stringValue!)","account":{"account_id":"9d0f8c5e-56f4-4b9e-8a39-34a95c0f2a2b","namespace":"4f13d776-a268-4469-91ec-b63f9e88cdde","username":"Alice"}}"#)
            }
        }
        let client = ServerClient(address: address, transport: transport)
        let device = ServerDevice(name: "NotTennaPod on iPhone", appVersion: "1.0 (1)")
        let install = ContractIdentity.randomUUID(), nonce = ContractIdentity.randomUUID()
        let answer = try await client.signIn(username: "alice", password: "secret-1", installID: install, transportNonce: nonce, device: device)
        #expect(answer.token == "ntp1_x" && answer.installID == install && answer.username == "Alice")
        let body = try #require(transport.seen.last?.body)
        #expect(body["instance_nonce"]?.stringValue == nonce && body["device"]?["platform"]?.stringValue == "ios")
        #expect(body["device"]?["capabilities"] == ["favorites", "history", "inbox", "queue", "statistics"])
        #expect(transport.seen.last?.path == "/v1/auth/device")
        for (password, expected) in [("wrong", ServerClientError.wrongCredentials), ("busy", .busy(retryAfter: 2)),
                                     ("many", .rateLimited(retryAfter: 61)), ("copy", .installationConflict), ("disabled", .forbidden)] {
            await #expect(throws: expected) {
                _ = try await client.signIn(username: "alice", password: password, installID: install, transportNonce: nonce, device: device)
            }
        }
        // On an authenticated request a 401 means the token is gone, not a wrong password.
        let revoked = ServerClient(address: address, transport: StubServerTransport { _ in (401, #"{"error":"unauthorized","message":"Sign in again."}"#) })
        await #expect(throws: ServerClientError.unauthorized) { _ = try await revoked.installations(token: "t") }
        #expect(ServerClientError.unauthorized.rejectsCredentials && ServerClientError.forbidden.rejectsCredentials)
    }

    // MARK: - Attach snapshots

    private func snapshotItems(podcasts: Int) -> [ContractJSON] {
        (0..<podcasts).map { index in
            ["record": ["entity": "podcast", "id": .string("p1:\(index)"), "field_group": "subscription",
                        "value": ["state": "subscribed", "generation_id": "g1:x"], "provenance": []]]
        } + [["record": ["entity": "account", "id": "a", "field_group": "discovery_policy", "value": ["new_episodes_action": "inbox"], "provenance": []]]]
    }

    private func cursor() throws -> String {
        try SyncCursor(logID: ContractIdentity.randomUUID(), epoch: 1, seq: 0, digest: String(repeating: "0", count: 64)).encoded
    }

    /// Pages of `items`, the last framed into parts of `partBytes` when given; `digest` overrides the manifest's.
    private func pages(_ items: [ContractJSON], perPage: Int, frameLast partBytes: Int? = nil, digest: String? = nil) throws -> [String] {
        var wire: [ContractJSON] = items
        if let partBytes, let last = items.last {
            let bytes = try last.canonicalBytes()
            let chunks = stride(from: 0, to: bytes.count, by: partBytes).map { Array(bytes[$0..<min($0 + partBytes, bytes.count)]) }
            wire = Array(items.dropLast()) + chunks.enumerated().map { index, chunk in
                ["item_part": ["index": .integer(Int64(items.count)), "part_index": .integer(Int64(index)),
                               "part_count": .integer(Int64(chunks.count)), "data": .string(ContractBase64URL.encode(chunk))]]
            }
        }
        let expected = try digest ?? ServerAttachSnapshotDownload.hex(ContractHash.chainDigest(items))
        let head = try cursor()
        let groups = stride(from: 0, to: max(wire.count, 1), by: perPage).map { Array(wire[$0..<min($0 + perPage, wire.count)]) }
        return try groups.enumerated().map { index, group in
            var page: ContractObject = ["head": .string(head), "install_watermark": 0, "items": .array(group)]
            if index < groups.count - 1 { page["has_more"] = true; page["next"] = .string("page-\(index + 1)") }
            else {
                page["has_more"] = false
                page["manifest"] = ["item_count": .integer(Int64(items.count)), "snapshot_digest": .string(expected)]
            }
            return try ContractJSON.object(page).canonicalString()
        }
    }

    private func download(_ pages: [String], expireFirst: Bool = false) async throws -> (ServerAttachSnapshot, StubServerTransport) {
        let expired = Mutex(expireFirst)
        let transport = StubServerTransport { request in
            let page = request.body?["page"]?.stringValue
            if page != nil, expired.withLock({ let value = $0; $0 = false; return value }) {
                return (410, #"{"error":"view_expired","message":"…"}"#)
            }
            let index = page.map { Int($0.dropFirst(5))! } ?? 0
            return (200, pages[index])
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attach-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let snapshot = try await ServerAttachSnapshotDownload(client: ServerClient(address: address, transport: transport),
                                                              token: "t", installID: "i", folder: folder).run()
        var reread: [ContractJSON] = []
        try snapshot.forEachItem { reread.append($0) }
        #expect(reread.count == snapshot.itemCount)
        return (snapshot, transport)
    }

    @Test func snapshotsArePagedReassembledVerifiedAndRestartedWhenTheViewExpires() async throws {
        let empty = try await download(pages([], perPage: 10)).0
        #expect(empty.isEmptyAccount && empty.itemCount == 0)
        let accountOnly = try await download(pages(snapshotItems(podcasts: 0), perPage: 10)).0
        #expect(accountOnly.isEmptyAccount && accountOnly.itemCount == 1)
        var big = snapshotItems(podcasts: 3)
        big.append(["record": ["entity": "podcast", "id": "p1:big", "field_group": "subscription",
                               "value": ["state": "removed", "generation_id": .string(String(repeating: "g", count: 3_000))], "provenance": []]])
        let (framed, transport) = try await download(pages(big, perPage: 2, frameLast: 700))
        #expect(framed.itemCount == 5 && framed.podcastCount == 3 && !framed.isEmptyAccount)
        #expect(transport.seen.allSatisfy { $0.authorization == "Bearer t" && $0.body?["mode"]?.stringValue == "attach" })
        let (restarted, again) = try await download(pages(big, perPage: 2), expireFirst: true)
        #expect(restarted.itemCount == 5)
        #expect(again.seen.filter { $0.body?["page"] == nil }.count == 2, "view_expired restarts from the first page")
        await #expect(throws: ServerSnapshotError.verificationFailed) {
            _ = try await download(pages(big, perPage: 2, digest: String(repeating: "1", count: 64)))
        }
    }
}
