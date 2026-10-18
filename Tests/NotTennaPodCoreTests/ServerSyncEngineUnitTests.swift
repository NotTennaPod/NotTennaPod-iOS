import Foundation
import SQLite3
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

    // MARK: - The durability barrier (PROTOCOL §15.2)

    static func durability(_ fixture: ServerLibraryFixture) throws -> Int { try durability(at: fixture.url) }

    /// `durability_counter`, read on a connection of its own (also from a transport's answer).
    static func durability(at url: URL) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { throw FeedLibraryError.invalidLocation }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT durability_counter FROM ntp_library", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FeedLibraryError.invalidLocation
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw FeedLibraryError.invalidLocation }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Everything sent is acknowledged: the outbox has nothing after `acked`.
    static func acknowledgeAll(_ fixture: ServerLibraryFixture) async throws {
        try await fixture.store.executeForTesting(
            "UPDATE ntp_library SET acked_install_seq = (SELECT coalesce(max(install_seq), 0) FROM ntp_outbox)", [])
    }

    /// A push with nothing to send makes no durable barrier transaction and no request.
    @Test func anEmptyPushWritesNoBarrier() async throws {
        let fixture = try await ServerLibraryFixture()
        let transport = Transport { path, _ in path == "v1/push" ? ["results": []] : [:] }
        let engine = try await Self.engine(fixture, transport)
        try await Self.acknowledgeAll(fixture)
        let before = try Self.durability(fixture)
        let report = await engine.run([.push])
        #expect(report.error == nil, "\(report)")
        #expect(try Self.durability(fixture) == before, "no barrier (its durable transaction is exactly this increment)")
        #expect(!transport.requests.contains("v1/push"))
        await engine.close()
        await fixture.close()
    }

    /// A fact waiting to be sent: the barrier commits before the request carries it.
    @Test func aPushSendsOnlyAfterTheBarrier() async throws {
        let fixture = try await ServerLibraryFixture()
        let url = fixture.url, seen = TokenBox("")
        let transport = Transport { path, body in
            guard path == "v1/push" else { return [:] }
            seen.value = try Self.durability(at: url).description
            let seqs = body?["operations"]?.arrayValue?.compactMap { $0["install_seq"]?.integerValue } ?? []
            return ["results": .array(seqs.map { ["install_seq": .integer($0), "status": "dependency_missing",
                                                   "missing": [.string(ContractIdentity.randomUUID())]] })]
        }
        let engine = try await Self.engine(fixture, transport)
        try await Self.acknowledgeAll(fixture)
        let before = try Self.durability(fixture)
        try await fixture.store.appendFactForTesting(type: "favorite.set", targets: [], payload: [:])
        _ = await engine.run([.push])
        #expect(transport.requests.contains("v1/push"))
        #expect(Int(seen.value) == before + 1, "the barrier committed before the request: \(seen.value) after \(before)")
        await engine.close()
        await fixture.close()
    }

    /// An owed fact the push itself records first (a play load's queue add whose recording failed) is sent, after the
    /// barrier: the check for something to send comes after the owed replay.
    @Test func anOwedFactRecordedByThePushIsSentAfterTheBarrier() async throws {
        let fixture = try await ServerLibraryFixture()
        let ids = try await fixture.subscribeRegistered().feed.episodes.map(\.id).sorted()
        let url = fixture.url, seen = TokenBox("")
        let transport = Transport { path, body in
            guard path == "v1/push" else { return [:] }
            seen.value = try Self.durability(at: url).description
            let seqs = body?["operations"]?.arrayValue?.compactMap { $0["install_seq"]?.integerValue } ?? []
            return ["results": .array(seqs.map { ["install_seq": .integer($0), "status": "dependency_missing",
                                                   "missing": [.string(ContractIdentity.randomUUID())]] })]
        }
        let engine = try await Self.engine(fixture, transport)
        await fixture.store.injectRecorderFailure(after: 1)
        _ = try await fixture.store.beginPlayback(episodeID: ids[1])
        await fixture.store.injectRecorderFailure(after: nil)
        #expect(try fixture.rows("SELECT count(*) FROM ntp_owed") != [["0"]], "a queue add is owed")
        try await Self.acknowledgeAll(fixture)
        let before = try Self.durability(fixture)
        _ = await engine.run([.push])
        #expect(try fixture.rows("SELECT count(*) FROM ntp_owed") == [["0"]], "the push recorded it")
        #expect(transport.requests.contains("v1/push"), "and sent it")
        #expect(Int(seen.value) == before + 1, "after the barrier")
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

// MARK: - Changes the server never accepts (PROTOCOL §6.4 `invalid_part`, §6.13 `max_framed_fact_bytes`)

extension ServerSyncEngineUnitTests {
    /// The engine's clock, moved by the test (and by a transport's answer).
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_760_000_000)
        var now: Date { lock.withLock { date } }
        func advance(_ seconds: Double) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    }

    /// What a scripted server answers each part, and what it was sent.
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        private var answers: [(Int) -> ContractJSON] = []
        /// The answer to the next part request (`index` is the part's index), until the script runs out: `invalid_part`.
        func then(_ answer: @escaping (Int) -> ContractJSON) { lock.withLock { answers.append(answer) } }
        func next(_ index: Int) -> ContractJSON? { lock.withLock { answers.isEmpty ? nil : answers.removeFirst()(index) } }
        func note(_ path: String) { lock.withLock { log.append(path) } }
        var pushes: Int { lock.withLock { log.filter { $0 == "v1/push" }.count } }
        var pulls: Int { lock.withLock { log.filter { $0 == "v1/pull" }.count } }
    }

    /// A library at seq 0 whose engine runs on `clock`, with a transport whose pull answers `pull` and whose push answers
    /// each part from `script` (or `invalid_part`).
    static func engine(_ fixture: ServerLibraryFixture, clock: Clock, script: Script,
                       pull: @escaping @Sendable (String) -> ContractJSON) async throws -> ServerSyncEngine {
        let logID = ContractIdentity.randomUUID()
        try await fixture.store.setCursorForTesting(try SyncCursor(logID: logID, epoch: 1, seq: 0, digest: String(repeating: "0", count: 64)))
        let transport = Transport { path, body in
            script.note(path)
            switch path {
            case "v1/pull": return pull(logID)
            case "v1/push":
                let operation = body?["operations"]?.arrayValue?.first
                let seq = operation?["install_seq"]?.integerValue ?? 0
                let index = Int(operation?["part"]?["part_index"]?.integerValue ?? 0)
                return ["results": [script.next(index) ?? ["install_seq": .integer(seq), "status": "invalid_part"]]]
            default: return [:]
            }
        }
        return try ServerSyncEngine(store: fixture.store, database: fixture.url,
                                    syncDatabase: fixture.directory.appendingPathComponent("sync.sqlite"),
                                    staging: fixture.directory.appendingPathComponent("staging"), transport: transport, vault: fixture.vault,
                                    clock: { clock.now })
    }

    /// The same library's engine after a relaunch (its stored state, a new engine).
    static func reopened(_ fixture: ServerLibraryFixture, clock: Clock, script: Script,
                         pull: @escaping @Sendable (String) -> ContractJSON) throws -> ServerSyncEngine {
        let transport = Transport { path, body in
            script.note(path)
            switch path {
            case "v1/pull": return pull("")
            case "v1/push":
                let operation = body?["operations"]?.arrayValue?.first
                let seq = operation?["install_seq"]?.integerValue ?? 0
                let index = Int(operation?["part"]?["part_index"]?.integerValue ?? 0)
                return ["results": [script.next(index) ?? ["install_seq": .integer(seq), "status": "invalid_part"]]]
            default: return [:]
            }
        }
        return try ServerSyncEngine(store: fixture.store, database: fixture.url,
                                    syncDatabase: fixture.directory.appendingPathComponent("sync.sqlite"),
                                    staging: fixture.directory.appendingPathComponent("staging"), transport: transport, vault: fixture.vault,
                                    clock: { clock.now })
    }

    /// A fact of about `bytes` canonical bytes in the outbox.
    static func appendFact(_ store: FeedLibraryStore, bytes: Int) async throws -> Int64 {
        try await store.appendFactForTesting(type: "favorite.set", targets: [], payload: ["note": .string(String(repeating: "x", count: bytes))])
        return try await store.serverExchangeState().nextInstallSeq - 1
    }

    /// A change larger than the server accepts (its bound fell after it was numbered) is never sent: no request in three
    /// exchanges, pushing paused (`change_too_large`), pulls going on. An explicit retry tries once more, and it pauses again.
    @Test func aChangeOverTheFactBoundIsNeverSentWhilePullsGoOn() async throws {
        let fixture = try await ServerLibraryFixture()
        let clock = Clock(), script = Script()
        let head = TokenBox("")
        let engine = try await Self.engine(fixture, clock: clock, script: script) { _ in
            ["head": .string(head.value), "has_more": false, "items": [], "install_watermark": 0]
        }
        head.value = try #require(try await fixture.store.serverExchangeState().cursor?.encoded)
        _ = try await Self.appendFact(fixture.store, bytes: 100_000)
        try await fixture.store.setServerBounds(["max_framed_fact_bytes": 65_536])
        for _ in 0..<3 {
            let report = await engine.exchange()
            #expect(report.pause == .changeTooLarge && !report.completed, "\(report)")
        }
        #expect(script.pushes == 0, "never sent")
        #expect(script.pulls == 3, "pulls go on")
        #expect(try await fixture.store.serverExchangeState().pause == .changeTooLarge)
        #expect(try await engine.logEntries().contains { $0.kind == "too_large" })
        await engine.retryRefusedChanges()
        #expect(try await fixture.store.serverExchangeState().pause == nil, "an explicit retry clears it")
        #expect(await engine.exchange().pause == .changeTooLarge, "still too large: paused again")
        #expect(script.pushes == 0)
        await engine.close()
        await fixture.close()
    }

    /// The real retained-prefix multipart sequence: parts 0–31 stored, then `invalid_part`; nothing more in that exchange
    /// (its second push included). The next exchanges, a relaunch among them, send nothing before the retry time (3 s, then
    /// 6 s); a part stored never resets the count; the third refusal pauses pushing (`change_refused`) while pulls go on; an
    /// explicit retry tries exactly once.
    @Test func anInvalidPartStopsPushingUntilItsRetryTimeAndPausesAtTheThird() async throws {
        let fixture = try await ServerLibraryFixture()
        let clock = Clock(), script = Script()
        // A pull page at the cursor's own head: nothing new.
        let head = TokenBox("")
        let pull: @Sendable (String) -> ContractJSON = { _ in ["head": .string(head.value), "has_more": false, "items": [], "install_watermark": 0] }
        let engine = try await Self.engine(fixture, clock: clock, script: script, pull: pull)
        head.value = try #require(try await fixture.store.serverExchangeState().cursor?.encoded)
        try await fixture.store.setServerBounds(["max_unframed_fact_bytes": 1_024, "max_part_bytes": 1_024])
        let seq = try await Self.appendFact(fixture.store, bytes: 34_000)
        var present: [ContractJSON] = []
        for index in 0..<32 {
            present.append(.integer(Int64(index)))
            let stored = present
            script.then { _ in ["install_seq": .integer(seq), "status": "part_stored", "parts_present": .array(stored)] }
        }
        var report = await engine.exchange()
        #expect(script.pushes == 33, "32 parts stored, then the refused one; nothing after it: \(script.pushes)")
        #expect(report.retryAfter.map { abs($0 - 3) < 0.01 } == true, "\(String(describing: report.retryAfter))")
        #expect(report.pause == nil)
        // A relaunch before the retry time: nothing is sent, whatever starts the exchange; pulls go on.
        await engine.close()
        let restarted = try Self.reopened(fixture, clock: clock, script: script, pull: pull)
        clock.advance(2)
        let pulls = script.pulls
        report = await restarted.exchange()
        #expect(script.pushes == 33 && script.pulls > pulls, "\(report)")
        #expect(report.retryAfter.map { $0 > 0.9 && $0 <= 1.01 } == true, "the rest of the 3 s: \(String(describing: report.retryAfter))")
        // Past it: exactly one more try. Its first part is stored and the next refused: the count goes on (2), and the
        // wait doubles.
        clock.advance(1.5)
        script.then { _ in ["install_seq": .integer(seq), "status": "part_stored", "parts_present": [0]] }
        report = await restarted.exchange()
        #expect(script.pushes == 35, "\(script.pushes)")
        #expect(report.retryAfter.map { abs($0 - 6) < 0.01 } == true, "\(String(describing: report.retryAfter))")
        clock.advance(6.5)
        report = await restarted.exchange()
        #expect(script.pushes == 36)
        #expect(report.pause == .changeRefused, "the third refusal pauses pushing: \(report)")
        #expect(try await fixture.store.serverExchangeState().pause == .changeRefused)
        clock.advance(3_600)
        let before = script.pulls
        report = await restarted.exchange()
        #expect(script.pushes == 36 && script.pulls > before, "paused: pulls go on, nothing is pushed")
        // Synchronize now: one more try, and the next refusal pauses again at once.
        await restarted.retryRefusedChanges()
        report = await restarted.exchange()
        #expect(script.pushes == 37 && report.pause == .changeRefused, "\(report)")
        #expect(try await restarted.logEntries().contains { $0.kind == "paused" && $0.detail.hasPrefix("change_refused") })
        await restarted.close()
        await fixture.close()
    }

    /// The latch holds for the whole exchange: a push refused with `invalid_part`, then a pull that applies 3 commits and
    /// takes longer than the retry time; the exchange's second push sends nothing.
    @Test func anInvalidPartHoldsTheSecondPushAfterASlowPull() async throws {
        let fixture = try await ServerLibraryFixture()
        let clock = Clock(), script = Script()
        let state = TokenBox("")
        let engine = try await Self.engine(fixture, clock: clock, script: script) { logID in
            var previous = ContractHex.decode(String(repeating: "0", count: 64)) ?? []
            var items: [ContractJSON] = []
            let commits = state.value.isEmpty ? 3 : 0
            for seq in 1...3 {
                let commit: ContractJSON = ["epoch": 1, "seq": .integer(Int64(seq)), "accepted": [], "decisions": [], "slots": [], "records": []]
                previous = (try? ContractHash.nextDigest(previous: previous, commit)) ?? previous
                if seq <= commits { items.append(["commit": commit]) }
            }
            if commits > 0 { clock.advance(10) }
            state.value = "pulled"
            let head = (try? SyncCursor(logID: logID, epoch: 1, seq: 3, digest: ContractHex.encode(previous)).encoded) ?? ""
            return ["head": .string(head), "has_more": false, "items": .array(items), "install_watermark": 0]
        }
        try await fixture.store.setServerBounds(["max_unframed_fact_bytes": 1_024, "max_part_bytes": 1_024])
        _ = try await Self.appendFact(fixture.store, bytes: 3_000)
        let report = await engine.exchange()
        #expect(try await fixture.store.serverExchangeState().cursor?.seq == 3, "the pull applied its commits: \(report)")
        #expect(script.pushes == 1, "one request for the refusal, none after the slow pull: \(script.pushes)")
        await engine.close()
        await fixture.close()
    }
}
