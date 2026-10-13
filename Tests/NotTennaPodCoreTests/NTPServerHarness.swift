import Foundation
import Darwin
@testable import NotTennaPodCore

/// The smallest server harness for host agreement tests: the NotTennaPod server pinned
/// in `TestSupport/Server/server-version.txt`, built by `Tools/ntp-server.sh` from an archived copy of the sibling
/// checkout, started with a fresh data directory on a free loopback port. A missing checkout or toolchain fails
/// the test loudly; nothing is skipped.
final class NTPServerProcess: @unchecked Sendable {
    let base: URL
    let dataDirectory: URL
    let setupCode: String
    private let process: Process

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Builds the pinned server once (the script caches it in `.work/ntp-server/<commit>/`). `NTP_SERVER_BINARY` names a
    /// prebuilt one instead: PROTOCOL §16 release candidate (`Tools/acceptance.sh`), as the web's suites take it.
    static func binary() throws -> URL {
        if let candidate = ProcessInfo.processInfo.environment["NTP_SERVER_BINARY"], !candidate.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: candidate) else {
                throw HarnessError.server("NTP_SERVER_BINARY=\(candidate) is not an executable server binary")
            }
            return URL(fileURLWithPath: candidate)
        }
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/zsh")
        script.arguments = [repositoryRoot.appendingPathComponent("Tools/ntp-server.sh").path]
        let output = Pipe(), errors = Pipe()
        script.standardOutput = output; script.standardError = errors
        try script.run()
        let path = output.fileHandleForReading.readDataToEndOfFile()
        let failure = errors.fileHandleForReading.readDataToEndOfFile()
        script.waitUntilExit()
        guard script.terminationStatus == 0 else {
            throw HarnessError.server("Tools/ntp-server.sh failed: " + String(decoding: failure, as: UTF8.self))
        }
        return URL(fileURLWithPath: String(decoding: path, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func freePort() throws -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw HarnessError.server("no socket") }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, length) } }
        guard bound == 0 else { throw HarnessError.server("bind failed") }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) } }
        return UInt16(bigEndian: address.sin_port)
    }

    private init(base: URL, dataDirectory: URL, setupCode: String, process: Process) {
        self.base = base; self.dataDirectory = dataDirectory; self.setupCode = setupCode; self.process = process
    }

    static func start() async throws -> NTPServerProcess {
        let binary = try binary()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ntp-agreement-\(UUID())")
        let data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let port = try freePort()
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--listen", "127.0.0.1:\(port)", "--data-dir", data.path, "--dev-allow-loopback-feeds", "--refresh-interval", "24h"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let base = URL(string: "http://127.0.0.1:\(port)")!
        // Wait for the condition: the health check answers and the setup code is written.
        let deadline = Date().addingTimeInterval(30)
        while true {
            if let (_, response) = try? await URLSession.shared.data(from: base.appendingPathComponent("healthz")),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let code = try? String(contentsOf: data.appendingPathComponent("setup-code"), encoding: .utf8) {
                return NTPServerProcess(base: base, dataDirectory: root, setupCode: code.trimmingCharacters(in: .whitespacesAndNewlines), process: process)
            }
            guard process.isRunning, Date() < deadline else {
                process.terminate()
                throw HarnessError.server("the server did not start")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            // Waits for the exit itself: `waitUntilExit` on the main actor missed an exit in a full host run and
            // waited forever for a server that was already gone.
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning, Date() < deadline { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: dataDirectory)
    }
}

enum HarnessError: Error, CustomStringConvertible {
    case server(String)
    case http(Int, String)
    var description: String {
        switch self {
        case .server(let message): message
        case .http(let status, let body): "HTTP \(status): \(body)"
        }
    }
}

/// JSON requests to the server with protocol JSON bodies (canonical, so facts keep their exact bytes).
struct NTPClient: Sendable {
    let base: URL
    var token: String?

    func send(_ method: String, _ path: String, _ body: ContractJSON? = nil, origin: Bool = false) async throws -> ContractJSON {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("1", forHTTPHeaderField: "NotTennaPod-Protocol")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try body.canonicalData()
        }
        if origin { request.setValue(base.absoluteString, forHTTPHeaderField: "Origin") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HarnessError.http(status, String(decoding: data, as: UTF8.self)) }
        return try ContractJSON.decode(data)
    }
}

/// An account on the server and an installation signed in to it.
struct NTPInstallation: Sendable {
    let client: NTPClient
    let installID: String
    let accountID: String
    let namespace: String

    static func setUp(_ server: NTPServerProcess, username: String = "alice", password: String = "alice-password-1") async throws {
        _ = try await NTPClient(base: server.base).send("POST", "v1/setup",
            ["username": .string(username), "password": .string(password), "setup_code": .string(server.setupCode)], origin: true)
    }

    static func signIn(_ server: NTPServerProcess, username: String = "alice", password: String = "alice-password-1",
                       installID: String = ContractIdentity.randomUUID()) async throws -> NTPInstallation {
        let answer = try await NTPClient(base: server.base).send("POST", "v1/auth/device", [
            "username": .string(username), "password": .string(password), "install_id": .string(installID),
            "instance_nonce": .string(ContractIdentity.randomUUID()),
            "device": ["name": "NotTennaPod on iPhone", "platform": "ios", "app_version": "test",
                       "capabilities": ["favorites", "history", "inbox", "queue", "statistics"]]])
        guard let token = answer["token"]?.stringValue, let account = answer["account"]?["account_id"]?.stringValue,
              let namespace = answer["account"]?["namespace"]?.stringValue else { throw HarnessError.server("sign-in answer \(answer)") }
        return NTPInstallation(client: NTPClient(base: server.base, token: token), installID: installID, accountID: account, namespace: namespace)
    }

    /// An attach snapshot: its head cursor and every record, keyed by `entity/id/field_group`.
    func attachSnapshot() async throws -> (head: String, records: [String: ContractJSON]) {
        var records: [String: ContractJSON] = [:]
        var page: String?
        var head = ""
        repeat {
            var body: ContractObject = ["mode": "attach", "install_id": .string(installID), "acked_install_seq": 0]
            if let page { body["page"] = .string(page) }
            let answer = try await client.send("POST", "v1/snapshot", .object(body))
            head = answer["head"]?.stringValue ?? head
            for item in answer["items"]?.arrayValue ?? [] {
                guard item["item_part"] == nil else { throw HarnessError.server("a framed snapshot item") }
                if let record = item["record"], record["tombstone"] == nil,
                   let entity = record["entity"]?.stringValue, let id = record["id"]?.stringValue, let group = record["field_group"]?.stringValue {
                    records["\(entity)/\(id)/\(group)"] = record["value"]
                }
            }
            page = answer["has_more"]?.boolValue == true ? answer["next"]?.stringValue : nil
        } while page != nil
        return (head, records)
    }
}

/// The phone's side of an exchange for agreement tests: a test stand-in for the pusher and for the
/// one piece of its applier recording needs (registration resolutions, which materialize drafts).
/// Receipts stay in memory.
@MainActor final class AgreementPhone {
    let fixture: ServerLibraryFixture
    let installation: NTPInstallation
    let vault: MemoryCredentialVault
    var cursor: String
    var acked: Int64 = 0
    /// Every receipt outcome by op ID (`applied`, `superseded`, `not_applied` or `rejected`, with its reason).
    var outcomes: [String: String] = [:]

    init(fixture: ServerLibraryFixture, installation: NTPInstallation, cursor: String, vault: MemoryCredentialVault) {
        self.fixture = fixture; self.installation = installation; self.cursor = cursor; self.vault = vault
    }

    /// Pushes every unacknowledged outbox entry in slot order, with the secrets they name. Owed facts are recorded
    /// first, as the exchange's pusher does.
    func push() async throws {
        try await fixture.store.replayOwedFacts()
        while true {
            let entries = try fixture.rows("SELECT install_seq, CAST(fact AS TEXT), secret_ids FROM ntp_outbox WHERE install_seq > \(acked) ORDER BY install_seq LIMIT 400")
            guard !entries.isEmpty else { return }
            var operations: [ContractJSON] = []
            var secrets: [ContractJSON] = []
            for entry in entries {
                operations.append(["install_seq": .integer(Int64(entry[0]!)!), "fact": try ContractJSON.decode(entry[1]!)])
                for secret in (try? JSONDecoder().decode([String].self, from: Data((entry[2] ?? "[]").utf8))) ?? [] {
                    secrets.append(try self.secret(secret))
                }
            }
            var body: ContractObject = ["cursor": .string(cursor), "install_id": .string(installation.installID),
                                        "acked_install_seq": .integer(acked), "operations": .array(operations)]
            if !secrets.isEmpty { body["secrets"] = .array(secrets) }
            let answer = try await installation.client.send("POST", "v1/push", .object(body))
            for result in answer["results"]?.arrayValue ?? [] {
                guard let status = result["status"]?.stringValue, status == "accepted" || status == "duplicate",
                      let receipt = result["receipt"], let op = receipt["op_id"]?.stringValue, let outcome = receipt["outcome"]?.stringValue else {
                    throw HarnessError.server("push result \(result)")
                }
                outcomes[op] = outcome + (receipt["reason"]?.stringValue.map { "/" + $0 } ?? "")
                if let seq = result["install_seq"]?.integerValue { acked = max(acked, seq) }
            }
        }
    }

    private func secret(_ id: String) throws -> ContractJSON {
        guard let row = try fixture.rows("SELECT credential_id, approved_origins FROM ntp_secrets WHERE secret_id = '\(id)'").first,
              let credential = row[0].flatMap(UUID.init(uuidString:)) else { throw HarnessError.server("no secret \(id)") }
        let value = try JSONDecoder().decode(FeedCredentials.self, from: Data(try vault.password(id: credential).utf8))
        let origins = (try? JSONDecoder().decode([String].self, from: Data((row[1] ?? "[]").utf8))) ?? []
        return ["secret_id": .string(id), "username": .string(value.username ?? ""), "password": .string(value.password ?? ""),
                "approved_origins": .array(origins.map(ContractJSON.string))]
    }

    /// Pulls every commit since the cursor and applies the resolutions of this library's pending registrations.
    func pull() async throws {
        var page: String?
        var head = cursor
        repeat {
            var body: ContractObject = ["cursor": .string(cursor), "install_id": .string(installation.installID), "acked_install_seq": .integer(acked)]
            if let page { body["page"] = .string(page) }
            let answer = try await installation.client.send("POST", "v1/pull", .object(body))
            head = answer["head"]?.stringValue ?? head
            for item in answer["items"]?.arrayValue ?? [] {
                guard let commit = item["commit"] else { throw HarnessError.server("a framed commit") }
                for decision in commit["decisions"]?.arrayValue ?? [] where decision["decision_type"]?.stringValue == "podcast.resolution" {
                    guard let op = decision["subject"]?.stringValue, let result = decision["result"],
                          let podcast = result["podcast_id"]?.stringValue, let mode = result["mode"]?.stringValue else { continue }
                    let pending = try fixture.rows("SELECT count(*) FROM ntp_registrations WHERE op_id = '\(op)' AND state = 'pending'")
                    guard pending == [["1"]] else { continue }
                    try await fixture.store.resolveRegistration(opID: op, .init(podcastID: podcast, generationID: result["generation_id"]?.stringValue,
                                                                                mode: mode, decisionID: decision["decision_id"]?.stringValue))
                }
            }
            page = answer["has_more"]?.boolValue == true ? answer["next"]?.stringValue : nil
        } while page != nil
        cursor = head
    }

    /// Push, pull (resolving registrations), and push what materialized.
    func exchange() async throws {
        try await push()
        try await pull()
        try await push()
    }
}
