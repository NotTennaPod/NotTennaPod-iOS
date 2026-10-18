import Foundation
import Testing
@testable import NotTennaPodCore

/// The acceptance hub (`TestSupport/Servers/serve-ntp-server-fixture.py`) from the phone's side: the app's own
/// server client, over its synchronization transport, meets faults set at the hub's proxy in front of the release
/// candidate, and the hub's event log records what the client met. The hub runs on free ports with its own run folder
/// under `.work/hub-host-tests/`, so it never meets the UI journeys' hub.
@Suite(.serialized) struct HubProxySmokeTests {
    /// The hub as a child process, and its control API.
    final class Hub: @unchecked Sendable {
        let process = Process()
        let control: URL
        let server: URL
        let run: URL

        init() async throws {
            let root = NTPServerProcess.repositoryRoot
            run = root.appendingPathComponent(".work/hub-host-tests/\(UUID().uuidString)")
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-u", root.appendingPathComponent("TestSupport/Servers/serve-ntp-server-fixture.py").path,
                                 "--port", "0", "--server-port", "0", "--publisher-port", "0", "--run-dir", run.path]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            // The first line names the control API's address.
            var line = Data()
            while !line.contains(UInt8(ascii: "\n")) {
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else { throw HarnessError.server("the hub exited before announcing its address") }
                line.append(chunk)
            }
            let text = String(decoding: line, as: UTF8.self)
            guard let range = text.range(of: #"http://127\.0\.0\.1:\d+"#, options: .regularExpression) else {
                throw HarnessError.server("no control address in \(text)")
            }
            control = URL(string: String(text[range]))!
            let ready = try await Self.call(control, "GET", "ready", timeout: 900)
            server = URL(string: try #require(ready["server"] as? String))!
        }

        func stop() {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: run)
        }

        @discardableResult
        func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
            try await Self.call(control, method, path, body: body)
        }

        static func call(_ base: URL, _ method: String, _ path: String, body: [String: Any]? = nil,
                         timeout: TimeInterval = 120) async throws -> [String: Any] {
            var request = URLRequest(url: URL(string: base.absoluteString + "/" + path)!, timeoutInterval: timeout)
            request.httpMethod = method
            if let body {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            guard (200..<300).contains(status) else { throw HarnessError.http(status, String(decoding: data, as: UTF8.self)) }
            return object
        }
    }

    @Test func aBusyAnswerAndARefusalAtTheProxyReachTheClientAndTheEventLog() async throws {
        let hub = try await Hub()
        defer { hub.stop() }
        let client = ServerClient(address: try #require(ServerAddress(entered: hub.server.absoluteString)))
        let before = try await client.info()

        // One busy answer for the next GET /v1/info, as the server answers while it imports.
        let rule = try await hub.call("POST", "proxy/rules", ["mode": "busy", "method": "GET", "path": "/v1/info", "retry_after": 7])
        let ruleID = try #require(rule["rule"] as? Int)
        await #expect(throws: ServerClientError.busy(retryAfter: 7)) { _ = try await client.info() }
        #expect(try await client.info().serverID == before.serverID, "the rule fired once")
        let faults = try await hub.call("GET", "events?source=proxy&kind=fault&rule=\(ruleID)")["events"] as? [[String: Any]]
        #expect(faults?.count == 1)
        let answered = try await hub.call("GET", "events?source=proxy&kind=request&outcome=answered&status=503")["events"] as? [[String: Any]]
        #expect(answered?.first?["path"] as? String == "/v1/info")

        // The server stopped: connections are refused, and the client says the server cannot be reached.
        try await hub.call("POST", "server/stop")
        await #expect(throws: ServerClientError.unreachable) { _ = try await client.info() }
        try await hub.call("POST", "server/start")
        #expect(try await client.info().serverID == before.serverID)
        let lifecycle = try await hub.call("GET", "events?source=server")["events"] as? [[String: Any]] ?? []
        #expect(lifecycle.compactMap { $0["kind"] as? String }.suffix(2) == ["stopped", "started"])
    }
}
