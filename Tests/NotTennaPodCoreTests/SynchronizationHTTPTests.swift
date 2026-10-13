import Foundation
import Testing
import Synchronization
@testable import NotTennaPodCore

private actor SynchronizationScript: SynchronizationHTTPTransport {
    var replies: [SynchronizationHTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [SynchronizationHTTPResponse]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> SynchronizationHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { Issue.record("Unexpected provider request"); throw URLError(.badServerResponse) }
        return replies.removeFirst()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SynchronizationHTTPTests {
    private func reply(_ json: String = "", status: Int = 200) -> SynchronizationHTTPResponse {
        .init(status: status, body: Data(json.utf8))
    }
    private func action(_ index: Int = 0) -> SynchronizationEpisodeAction {
        .init(podcast: "https://podcast.test/feed", episode: "https://podcast.test/\(index).mp3", guid: "guid-\(index)",
            action: .play, timestamp: Date(timeIntervalSince1970: 1_700_000_000), started: 3, position: 70, total: 100)
    }
    private func object(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
    private func array(_ request: URLRequest) throws -> [[String: Any]] {
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
    }

    @Test func gpodderLoginPathsCursorsDeviceAndSubscriptionPayloads() async throws {
        let script = SynchronizationScript([reply(), reply(#"{"add":["https%3A//a","https%3a//b"],"remove":["http%3A//c"],"timestamp":42}"#),
            reply(#"{"timestamp":43,"update_urls":[["old","new"],["old","newer"]]}"#),
            reply(#"[{"id":"phone","caption":"Phone","type":"mobile","subscriptions":2}]"#), reply()])
        let client = try SynchronizationHTTPClient(backend: .gpodder, host: "http://example.test:8123/base///", username: "müller", password: "päss", device: "phone", transport: script)
        await #expect(throws: SynchronizationError.notLoggedIn) { try await client.subscriptionChanges(since: 0) }
        #expect(await script.requests.isEmpty)
        try await client.login()
        let changes = try await client.subscriptionChanges(since: 31)
        #expect(changes == .init(added: ["https://a", "https%3a//b"], removed: ["http://c"], timestamp: 42))
        #expect(try await client.uploadSubscriptions(added: ["https://a"], removed: ["https://b"]) == .init(timestamp: 43, updatedURLs: ["old": "newer"]))
        #expect(try await client.devices() == [.init(id: "phone", caption: "Phone", type: "mobile", subscriptions: 2)])
        try await client.configureDevice(id: "phone", caption: "My phone", type: "mobile")
        try await client.logout()
        let requests = await script.requests
        #expect(requests.count == 5)
        #expect(requests[0].url?.absoluteString == "http://example.test:8123/base/api/2/auth/m%C3%BCller/login.json")
        #expect(requests[0].httpMethod == "POST" && requests[0].httpBody == Data())
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Basic " + Data("müller:päss".utf8).base64EncodedString())
        #expect(requests[1].url?.path == "/base/api/2/subscriptions/müller/phone.json")
        #expect(requests[1].url?.query == "since=31")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(try object(requests[2])["add"] as? [String] == ["https://a"])
        #expect(try object(requests[2])["remove"] as? [String] == ["https://b"])
        #expect(try object(requests[4])["caption"] as? String == "My phone")
    }

    @Test func nextcloudUsesBasicEveryRequestAndCompletionTimeWithoutParsingUploadBodies() async throws {
        let script = SynchronizationScript([reply(#"{"add":[],"remove":[],"timestamp":7}"#), reply("accepted"),
            reply(#"{"actions":[],"timestamp":8}"#), reply("{}")])
        let client = try SynchronizationHTTPClient(backend: .nextcloud, host: "cloud.test:80/nextcloud/", username: "ä", password: "ü", transport: script,
            clock: { Date(timeIntervalSince1970: 500.9) })
        try await client.login()
        #expect(await script.requests.isEmpty)
        #expect(try await client.subscriptionChanges(since: 2).timestamp == 7)
        #expect(try await client.uploadSubscriptions(added: [], removed: ["https://old"]).timestamp == 500)
        #expect(try await client.episodeChanges(since: 3).timestamp == 8)
        #expect(try await client.uploadEpisodeActions([action()])?.timestamp == 500)
        try await client.logout()
        let requests = await script.requests
        #expect(requests.map { $0.url?.path } == ["/nextcloud/index.php/apps/gpoddersync/subscriptions", "/nextcloud/index.php/apps/gpoddersync/subscription_change/create", "/nextcloud/index.php/apps/gpoddersync/episode_action", "/nextcloud/index.php/apps/gpoddersync/episode_action/create"])
        #expect(requests.allSatisfy { $0.url?.scheme == "http" && $0.value(forHTTPHeaderField: "Accept") == "application/json" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Basic " + Data([0xe4, 0x3a, 0xfc]).base64EncodedString() })
        let payload = try array(#require(requests.last))
        #expect(payload[0]["device"] == nil)
        await #expect(throws: SynchronizationError.unsupportedOperation) { try await client.devices() }
    }

    @Test(arguments: [SynchronizationHTTPClient.Backend.gpodder, .nextcloud])
    func episodeBatchesKeepOrderWireFieldsAndReturnFinalCursor(backend: SynchronizationHTTPClient.Backend) async throws {
        let upload = #"{"timestamp":91,"update_urls":[]}"#
        let script = SynchronizationScript((backend == .gpodder ? [reply()] : []) + [reply(upload), reply(upload), reply(upload)])
        let client = try SynchronizationHTTPClient(backend: backend, host: "example.test", username: "user", password: "password", device: "phone", transport: script,
            clock: { Date(timeIntervalSince1970: 300) })
        try await client.login()
        let result = try await client.uploadEpisodeActions((0..<61).map(action))
        #expect(result?.timestamp == (backend == .gpodder ? 91 : 300))
        let requests = await script.requests.filter { $0.url?.path.contains("episode") == true }
        let batches = try requests.map(array)
        #expect(batches.map(\.count) == [30, 30, 1])
        #expect(batches.flatMap { $0 }.compactMap { $0["episode"] as? String } == (0..<61).map { "https://podcast.test/\($0).mp3" })
        let first = batches[0][0]
        #expect(first["timestamp"] as? String == "2023-11-14T22:13:20")
        #expect(first["started"] as? Int == 3 && first["position"] as? Int == 70 && first["total"] as? Int == 100)
        #expect(first["device"] as? String == (backend == .gpodder ? "phone" : nil))
    }

    @Test func malformedActionsAreSkippedAndOptionalPlayFieldsAreAdmittedTogether() async throws {
        let script = SynchronizationScript([reply(#"{"timestamp":99,"actions":[{"podcast":"p","episode":"e","action":"PLAY","timestamp":"2023-11-14T22:13:20Z","guid":"g","started":"0","position":1,"total":10},{"podcast":"p","episode":"zero","action":"play","started":0,"position":0,"total":10},{"podcast":"p","episode":"new","action":"new","timestamp":"bad","started":10,"position":20,"total":30},{"podcast":"","episode":"e","action":"play"},{"podcast":"p","episode":"e","action":"future"}]}"#)])
        let client = try SynchronizationHTTPClient(backend: .nextcloud, host: "example.test", username: "u", password: "p", transport: script)
        let changes = try await client.episodeChanges(since: 0)
        #expect(changes.timestamp == 99 && changes.actions.count == 3)
        #expect(changes.actions[0].timestamp == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(changes.actions[0].started == 0 && changes.actions[0].position == 1 && changes.actions[0].guid == "g")
        #expect(changes.actions[1].started == -1 && changes.actions[1].position == -1 && changes.actions[1].total == -1)
        #expect(changes.actions[2].timestamp == nil && changes.actions[2].position == -1)
        var value = action(); value.action = .new
        let wire = try value.wireObject(device: nil)
        #expect(wire["started"] == nil && wire["position"] == nil && wire["total"] == nil)
        #expect(try JSONDecoder().decode(SynchronizationEpisodeAction.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test func failingBatchStopsFurtherRequestsAndDoesNotReturnPartialSuccess() async throws {
        let script = SynchronizationScript([reply(), reply(#"{"timestamp":10,"update_urls":[]}"#), reply(status: 503)])
        let client = try SynchronizationHTTPClient(backend: .gpodder, host: "example.test", username: "u", password: "p", device: "d", transport: script)
        try await client.login()
        await #expect(throws: SynchronizationError.httpStatus(503)) { try await client.uploadEpisodeActions((0..<61).map(action)) }
        #expect(await script.requests.count == 3)
    }

    @Test func invalidOutgoingActionRejectsBeforeAnyPartialUpload() async throws {
        let script = SynchronizationScript([])
        let client = try SynchronizationHTTPClient(backend: .nextcloud, host: "example.test", username: "u", password: "p", transport: script)
        var invalid = action(); invalid.timestamp = nil
        await #expect(throws: SynchronizationError.invalidAction) { try await client.uploadEpisodeActions((0..<31).map(action) + [invalid]) }
        #expect(await script.requests.isEmpty)
    }

    @Test func authenticationStatusAndMalformedResponsesAreNotReportedAsSuccess() async throws {
        for status in [201, 204, 301, 400, 401, 403, 500] {
            let script = SynchronizationScript([reply(status: status)])
            let client = try SynchronizationHTTPClient(backend: .gpodder, host: "example.test", username: "u", password: "p", transport: script)
            await #expect(throws: status == 401 ? SynchronizationError.authentication : .httpStatus(status)) { try await client.login() }
            await #expect(throws: SynchronizationError.notLoggedIn) { try await client.subscriptionChanges(since: 0) }
        }
        for body in ["not json", "[]", #"{"add":[],"remove":[]}"#, #"{"timestamp":true,"add":[],"remove":[]}"#] {
            let script = SynchronizationScript([reply(body)])
            let client = try SynchronizationHTTPClient(backend: .nextcloud, host: "example.test", username: "u", password: "p", transport: script)
            await #expect(throws: SynchronizationError.invalidResponse) { try await client.subscriptionChanges(since: 0) }
        }
    }

    @Test func realSessionCarriesLoginCookieAndReadsPostedBodies() async throws {
        let server = try await LoopbackHTTPServer.start { request in
            if request.path.hasSuffix("/login.json") {
                return .init(headers: ["Set-Cookie": "sessionid=fixture; Path=/; HttpOnly"], body: Data())
            }
            guard request.headers["cookie"]?.contains("sessionid=fixture") == true else { return .init(status: 401) }
            return .init(body: Data(#"{"timestamp":12,"update_urls":[]}"#.utf8))
        }
        defer { server.stop() }
        let client = try SynchronizationHTTPClient(backend: .gpodder, host: server.url.deletingLastPathComponent().absoluteString, username: "u", password: "p", device: "phone")
        try await client.login()
        #expect(try await client.uploadEpisodeActions([action()])?.timestamp == 12)
        let requests = server.requests
        #expect(requests.count == 2 && requests[1].headers["authorization"] == nil)
        let uploaded = try #require(JSONSerialization.jsonObject(with: requests[1].body) as? [[String: Any]])
        #expect(uploaded[0]["device"] as? String == "phone")
    }

    @Test func realSessionCancellationStopsHeldResponse() async throws {
        let server = try await LoopbackHTTPServer.start { _ in nil }
        defer { server.stop() }
        let client = try SynchronizationHTTPClient(backend: .nextcloud, host: server.url.deletingLastPathComponent().absoluteString, username: "u", password: "p")
        let work = Task { try await client.episodeChanges(since: 0) }
        while server.requests.isEmpty { await Task.yield() }
        work.cancel()
        do { _ = try await work.value; Issue.record("Cancelled request succeeded") }
        catch is CancellationError { }
        catch let error as URLError { #expect(error.code == .cancelled) }
    }

    @Test func nativeCookieSessionsAreIsolatedBetweenAccounts() async throws {
        let server = try await LoopbackHTTPServer.start { request in
            if request.path.hasSuffix("/auth/first/login.json") {
                return .init(headers: ["Set-Cookie": "sessionid=first-account; Path=/; HttpOnly"], body: Data())
            }
            return .init(body: Data(#"{"add":[],"remove":[],"timestamp":1}"#.utf8))
        }
        defer { server.stop() }
        let host = server.url.deletingLastPathComponent().absoluteString
        let first = try SynchronizationHTTPClient(backend: .gpodder, host: host, username: "first", password: "fixture", device: "d")
        let second = try SynchronizationHTTPClient(backend: .gpodder, host: host, username: "second", password: "fixture", device: "d")
        try await first.login()
        _ = try await first.subscriptionChanges(since: 0)
        try await second.login()
        _ = try await second.subscriptionChanges(since: 0)
        let requests = server.requests
        #expect(requests.count == 4)
        #expect(requests[1].headers["cookie"]?.contains("first-account") == true)
        #expect(requests[2].headers["cookie"] == nil && requests[3].headers["cookie"] == nil)
    }

    @Test func nativeRedirectRetainsSameOriginCredentialsAndStripsCrossOriginAuthorization() async throws {
        let destination = try await LoopbackHTTPServer.start { _ in
            .init(body: Data(#"{"add":[],"remove":[],"timestamp":2}"#.utf8))
        }
        defer { destination.stop() }
        let origin = try await LoopbackHTTPServer.start { request in
            if request.path == "/same" {
                return .init(status: 302, headers: ["Location": destination.url.absoluteString], body: Data())
            }
            return .init(status: 302, headers: ["Location": "/same"], body: Data())
        }
        defer { origin.stop() }
        let client = try SynchronizationHTTPClient(backend: .nextcloud, host: origin.url.deletingLastPathComponent().absoluteString,
            username: "fixture", password: "fixture")
        #expect(try await client.subscriptionChanges(since: 0).timestamp == 2)
        #expect(origin.requests.count == 2 && destination.requests.count == 1)
        #expect(origin.requests.allSatisfy { $0.headers["authorization"] != nil })
        #expect(destination.requests[0].headers["authorization"] == nil)
    }

    @Test func emptyUploadsHaveSourceProviderSpecificCursorAndMakeNoRequest() async throws {
        let script = SynchronizationScript([reply()])
        let gpodder = try SynchronizationHTTPClient(backend: .gpodder, host: "example.test", username: "u", password: "p", transport: script)
        try await gpodder.login()
        #expect(try await gpodder.uploadEpisodeActions([]) == nil)
        #expect(await script.requests.count == 1)
        let empty = SynchronizationScript([])
        let cloud = try SynchronizationHTTPClient(backend: .nextcloud, host: "example.test", username: "u", password: "p", transport: empty,
            clock: { Date(timeIntervalSince1970: 17.1) })
        #expect(try await cloud.uploadEpisodeActions([])?.timestamp == 17)
        #expect(await empty.requests.isEmpty)
    }

    @Test func redirectedChallengeNeverReceivesAccountOrRedirectEmbeddedCredentials() async throws {
        let target = try await LoopbackHTTPServer.start { _ in
            .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"Shared name\""], body: Data())
        }
        defer { target.stop() }
        var address = try #require(URLComponents(url: target.url, resolvingAgainstBaseURL: false))
        address.user = "untrusted"; address.password = "redirect"
        let redirect = try #require(address.string)
        let origin = try await LoopbackHTTPServer.start { _ in
            .init(status: 302, headers: ["Location": redirect], body: Data())
        }
        defer { origin.stop() }
        let client = try SynchronizationHTTPClient(backend: .nextcloud, host: origin.url.deletingLastPathComponent().absoluteString,
            username: "fixture", password: "fixture")
        await #expect(throws: SynchronizationError.httpStatus(401)) { try await client.subscriptionChanges(since: 0) }
        #expect(origin.requests.count == 1 && target.requests.count == 1)
        #expect(origin.requests[0].headers["authorization"] != nil)
        #expect(target.requests[0].headers["authorization"] == nil)
    }

    @Test func crossOriginRedirectCannotRestoreCredentialsWhenReturningToOriginalServer() async throws {
        let returnURL = Mutex<URL?>(nil)
        let destination = try await LoopbackHTTPServer.start { _ in
            .init(status: 302, headers: ["Location": returnURL.withLock { $0!.absoluteString }], body: Data())
        }
        defer { destination.stop() }
        let origin = try await LoopbackHTTPServer.start { request in
            if request.path == "/return" {
                return .init(body: Data(#"{"add":[],"remove":[],"timestamp":3}"#.utf8))
            }
            return .init(status: 302, headers: ["Location": destination.url.absoluteString], body: Data())
        }
        defer { origin.stop() }
        returnURL.withLock { $0 = origin.url.deletingLastPathComponent().appendingPathComponent("return") }
        let client = try SynchronizationHTTPClient(backend: .nextcloud, host: origin.url.deletingLastPathComponent().absoluteString,
            username: "fixture", password: "fixture")
        #expect(try await client.subscriptionChanges(since: 0).timestamp == 3)
        #expect(origin.requests.count == 2 && destination.requests.count == 1)
        #expect(origin.requests[0].headers["authorization"] != nil)
        #expect(origin.requests[1].headers["authorization"] == nil && destination.requests[0].headers["authorization"] == nil)
    }

    @Test func invalidHostsAndEncodedPathComponentsCannotChangeEndpointStructure() async throws {
        for host in ["", "ftp://example.test", "https://u:p@example.test", "https://example.test?query", "https://example.test#fragment", "https://example.test:99999", "https://example.test:999999999999999999999999"] {
            #expect(throws: SynchronizationError.invalidHost) {
                try SynchronizationHTTPClient(backend: .gpodder, host: host, username: "u", password: "p")
            }
        }
        let script = SynchronizationScript([reply(), reply(#"{"add":[],"remove":[],"timestamp":1}"#)])
        let client = try SynchronizationHTTPClient(backend: .gpodder, host: "example.test/base", username: "user/name?query", password: "p", device: "device/#part", transport: script)
        try await client.login(); _ = try await client.subscriptionChanges(since: 0)
        let requests = await script.requests
        #expect(requests[0].url?.absoluteString == "https://example.test/base/api/2/auth/user%2Fname%3Fquery/login.json")
        #expect(requests[1].url?.absoluteString == "https://example.test/base/api/2/subscriptions/user%2Fname%3Fquery/device%2F%23part.json?since=0")
    }
}
