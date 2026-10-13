import Foundation
import Testing
@testable import NotTennaPodCore

/// The exchange engine against transports of the test's own (PROTOCOL §6.4): what a report says
/// after cancellation, backoff and failures, without a server.
@Suite struct ServerSyncEngineUnitTests {
    /// A transport whose every request is answered by `answer` (a thrown error, or a JSON object).
    final class Transport: ServerExchangeTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        let answer: @Sendable (String, ContractJSON?) async throws -> ContractJSON
        init(_ answer: @escaping @Sendable (String, ContractJSON?) async throws -> ContractJSON) { self.answer = answer }
        var requests: [String] { lock.withLock { paths } }
        func send(_ method: String, _ path: String, body: ContractJSON?) async throws -> ContractJSON {
            lock.withLock { paths.append(path) }
            return try await answer(path, body)
        }
    }

    /// A server library at seq 0 of a lineage, and its engine on `transport`.
    static func engine(_ fixture: ServerLibraryFixture, _ transport: Transport) async throws -> ServerSyncEngine {
        try await fixture.store.setCursorForTesting(try SyncCursor(logID: ContractIdentity.randomUUID(), epoch: 1, seq: 0,
                                                                   digest: String(repeating: "0", count: 64)))
        return try ServerSyncEngine(store: fixture.store, database: fixture.url,
                                    syncDatabase: fixture.directory.appendingPathComponent("sync.sqlite"),
                                    staging: fixture.directory.appendingPathComponent("staging"), transport: transport, vault: fixture.vault)
    }

    // MARK: - Cancellation

    @Test func aCancelledRequestIsNeverASuccessfulSynchronization() async throws {
        let fixture = try await ServerLibraryFixture()
        let engine = try await Self.engine(fixture, Transport { _, _ in throw CancellationError() })
        let report = await engine.exchange()
        #expect(report.cancelled && !report.completed, "\(report)")
        #expect(try await engine.logEntries().contains { $0.kind == "cancelled" })
        await engine.close()
        await fixture.close()
    }

    /// Background time runs out in the middle of a request: the exchange stops and says it did not finish.
    @Test func anExchangeStoppedMidRequestDidNotFinish() async throws {
        let fixture = try await ServerLibraryFixture()
        let started = PlayingFlag()
        let engine = try await Self.engine(fixture, Transport { _, _ in
            started.value = true
            try await Task.sleep(for: .seconds(120))
            return [:]
        })
        let exchange = Task { await engine.exchange() }
        let deadline = ContinuousClock.now + .seconds(20)
        while !started.value, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        await engine.cancelExchange()
        let report = await exchange.value
        #expect(report.cancelled && !report.completed, "\(report)")
        await engine.close()
        await fixture.close()
    }

    // MARK: - Backoff

    /// A fact waiting for a dependency the server does not have backs off further at every exchange; only an
    /// exchange that needed no retry starts the backoff again.
    @Test func dependencyWaitsBackOffProgressively() async throws {
        let fixture = try await ServerLibraryFixture()
        let cursorBox = TokenBox("")
        let transport = Transport { path, body in
            switch path {
            case "v1/push":
                let seqs = body?["operations"]?.arrayValue?.compactMap { $0["install_seq"]?.integerValue } ?? []
                return ["results": .array(seqs.map { ["install_seq": .integer($0), "status": "dependency_missing",
                                                       "missing": [.string(ContractIdentity.randomUUID())]] })]
            case "v1/pull":
                return ["head": .string(cursorBox.value), "has_more": false, "items": [], "install_watermark": 0]
            default:
                return [:]
            }
        }
        let engine = try await Self.engine(fixture, transport)
        cursorBox.value = try #require(try await fixture.store.serverExchangeState().cursor?.encoded)
        try await fixture.store.appendFactForTesting(type: "favorite.set", targets: [], payload: [:])
        var delays: [Double] = []
        for _ in 0..<3 {
            let report = await engine.exchange()
            #expect(report.waitingForDependencies && !report.completed)
            delays.append(report.retryAfter ?? 0)
        }
        #expect(delays[1] > delays[0] * 1.5 && delays[2] > delays[1] * 1.5, "progressive: \(delays)")
        await engine.close()
        await fixture.close()
    }

    // MARK: - Receipt members and decisions not known yet (PROTOCOL §7.6)

    /// A receipt member and a decision kind this phone does not know yet (PROTOCOL §8.1 `sort_values` and
    /// `queue.layout`) neither fail the exchange nor stop the cursor: the commit is verified, archived and applied.
    @Test func unknownReceiptMembersAndDecisionKindsAreTolerated() async throws {
        let fixture = try await ServerLibraryFixture()
        let headBox = TokenBox("")
        let logID = ContractIdentity.randomUUID(), op = ContractIdentity.randomUUID()
        let fact: ContractJSON = ["op_id": .string(op), "type": "queue.add", "payload": ["members": []], "dependencies": []]
        let commit: ContractJSON = [
            "epoch": 1, "seq": 1,
            "accepted": [["fact": fact,
                          "receipt": ["op_id": .string(op), "content_hash": .string(try ContractHash.contentHash(fact)), "outcome": "applied",
                                      "normalized_time": 1_000, "epoch": 1, "seq": 1, "index": 0,
                                      "sort_values": [["episode_id": "x", "value": "y"]]]]],
            "decisions": [["decision_id": .string(ContractIdentity.randomUUID()), "decision_type": "queue.layout", "subject": .string(op),
                           "epoch": 1, "seq": 1, "index": 1, "normalized_time": 1_000, "dependencies": [.string(op)],
                           "result": ["keys": [["episode_id": "x", "key": "a0"]]]]],
            "slots": [], "records": []]
        let digest = try ContractHash.nextDigest(previous: ContractHex.decode(String(repeating: "0", count: 64)) ?? [], commit)
        headBox.value = try SyncCursor(logID: logID, epoch: 1, seq: 1, digest: ContractHex.encode(digest)).encoded
        let engine = try ServerSyncEngine(store: fixture.store, database: fixture.url,
                                          syncDatabase: fixture.directory.appendingPathComponent("sync.sqlite"),
                                          staging: fixture.directory.appendingPathComponent("staging"), transport: Transport { path, _ in
            switch path {
            case "v1/pull": return ["head": .string(headBox.value), "has_more": false, "items": [["commit": commit]], "install_watermark": 0]
            case "v1/push": return ["results": []]
            default: return [:]
            }
        }, vault: fixture.vault)
        try await fixture.store.setCursorForTesting(try SyncCursor(logID: logID, epoch: 1, seq: 0, digest: String(repeating: "0", count: 64)))
        let report = await engine.exchange()
        #expect(report.completed, "\(report)")
        #expect(try await fixture.store.serverExchangeState().cursor?.seq == 1, "the cursor moved past the commit")
        await engine.close()
        await fixture.close()
    }

    // MARK: - Mobile data

    struct Gate: ServerSyncNetworkGate {
        let allowed: Bool
        func permitted() async -> Bool { allowed }
        func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
        func allowsMobile() async -> Bool { allowed }
    }

    final class HTTP: SynchronizationHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { sent } }
        func send(_ request: URLRequest) async throws -> SynchronizationHTTPResponse {
            lock.withLock { sent.append(request) }
            return .init(status: 200, body: Data("{}".utf8))
        }
    }

    /// Every request asks the gate: on a prohibited network nothing is sent, the report says why, and no backoff
    /// starts; on a permitted one the request also tells the system whether an expensive network may be used.
    @Test func everyRequestIsGatedByTheMobileDataRule() async throws {
        let http = HTTP()
        let denied = HTTPServerExchangeTransport(base: URL(string: "http://127.0.0.1:1")!, transport: http, network: Gate(allowed: false), token: { "t" })
        await #expect(throws: ServerExchangeError.networkNotPermitted) { _ = try await denied.send("POST", "v1/push", body: [:]) }
        #expect(http.requests.isEmpty)
        let fixture = try await ServerLibraryFixture()
        let engine = try ServerSyncEngine(store: fixture.store, database: fixture.url,
                                          syncDatabase: fixture.directory.appendingPathComponent("sync.sqlite"),
                                          staging: fixture.directory.appendingPathComponent("staging"), transport: denied, vault: fixture.vault)
        try await fixture.store.setCursorForTesting(try SyncCursor(logID: ContractIdentity.randomUUID(), epoch: 1, seq: 0,
                                                                   digest: String(repeating: "0", count: 64)))
        let report = await engine.exchange()
        #expect(report.networkNotPermitted && !report.completed && report.retryAfter == nil, "\(report)")
        #expect(http.requests.isEmpty, "nothing was sent")
        let wifiOnly = HTTPServerExchangeTransport(base: URL(string: "http://127.0.0.1:1")!, transport: http, network: MobileOff(), token: { "t" })
        _ = try await wifiOnly.send("GET", "v1/secrets/x", body: nil)
        #expect(http.requests.first?.allowsExpensiveNetworkAccess == false)
        await engine.close()
        await fixture.close()
    }

    /// On Wi-Fi with the mobile-data preference off: requests go, but never over an expensive network.
    struct MobileOff: ServerSyncNetworkGate {
        func permitted() async -> Bool { true }
        func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
        func allowsMobile() async -> Bool { false }
    }
}
