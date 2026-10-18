import Foundation
import Testing
@testable import NotTennaPodCore

/// `version_unsupported` (PROTOCOL §10, §6.4): for one change or for a whole request (426), pushing
/// pauses, pulls continue where the pause lets them, nothing is retried as a transient failure, Synchronize now tries
/// again, and the page names the side that needs updating: the server for a refused change or a server older than
/// this app, this app for a whole request refused by a server that speaks this app's protocol or a newer one.
@Suite(.serialized) struct ServerVersionPauseTests {
    typealias Transport = ServerSyncEngineUnitTests.Transport

    /// The server's answers, changed by each test as it goes: a refusal of whole requests on `refused` paths, the
    /// protocol versions `GET /v1/info` reports (nil: it cannot be read), refused changes, and an empty pull at the
    /// library's own head.
    final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var state = (refused: Set<String>(), info: ClosedRange<Int>?(1...1), refusesChanges: false, acceptsPushes: false,
                             head: "", commit: ContractJSON?.none)
        /// Paths refused as a whole request; one ending in "/" refuses every path it begins.
        var refused: Set<String> { get { lock.withLock { state.refused } } set { lock.withLock { state.refused = newValue } } }
        var info: ClosedRange<Int>? { get { lock.withLock { state.info } } set { lock.withLock { state.info = newValue } } }
        var refusesChanges: Bool { get { lock.withLock { state.refusesChanges } } set { lock.withLock { state.refusesChanges = newValue } } }
        /// Pushes are answered without results (nothing acknowledged, nothing refused).
        var acceptsPushes: Bool { get { lock.withLock { state.acceptsPushes } } set { lock.withLock { state.acceptsPushes = newValue } } }
        var head: String { get { lock.withLock { state.head } } set { lock.withLock { state.head = newValue } } }
        /// A commit every pull answers with (after `head`'s predecessor).
        var commit: ContractJSON? { get { lock.withLock { state.commit } } set { lock.withLock { state.commit = newValue } } }

        func answer(_ path: String, _ body: ContractJSON?) throws -> ContractJSON {
            if refused.contains(where: { path == $0 || ($0.hasSuffix("/") && path.hasPrefix($0)) }) {
                throw ServerExchangeError.server(status: 426, code: "version_unsupported", retryAfter: nil)
            }
            switch path {
            case "v1/info":
                guard let info else { throw ServerExchangeError.unreachable }
                return ["server_id": "s", "protocol": ["min": .integer(Int64(info.lowerBound)), "max": .integer(Int64(info.upperBound))]]
            case "v1/push":
                let seqs = body?["operations"]?.arrayValue?.compactMap { $0["install_seq"]?.integerValue } ?? []
                if acceptsPushes { return ["results": []] }
                guard refusesChanges else { throw ServerExchangeError.unreachable }
                return ["results": .array(seqs.map { ["install_seq": .integer($0), "status": "version_unsupported"] })]
            case "v1/pull":
                return ["head": .string(head), "has_more": false, "items": .array(commit.map { [["commit": $0]] } ?? []), "install_watermark": 0]
            default:
                throw ServerExchangeError.server(status: 500, code: "internal", retryAfter: nil)
            }
        }

        /// The next commit consumed this installation's slot 1 with another fact than the library holds there (a transport
        /// conflict, PROTOCOL §6.10).
        func serveConflictingSlot(installID: String, after cursor: SyncCursor) throws {
            let commit: ContractJSON = ["epoch": .integer(cursor.epoch), "seq": .integer(cursor.seq + 1), "accepted": [], "decisions": [],
                                        "slots": [["install_id": .string(installID), "install_seq": 1, "op_id": .string(ContractIdentity.randomUUID())]],
                                        "records": []]
            let digest = try ContractHash.nextDigest(previous: ContractHex.decode(cursor.digest) ?? [], commit)
            self.commit = commit
            head = try SyncCursor(logID: cursor.logID, epoch: cursor.epoch, seq: cursor.seq + 1, digest: ContractHex.encode(digest)).encoded
        }

        /// The next commit names a podcast's credentials secret the library does not hold: applying it fetches it.
        func serveSecretCommit(after cursor: SyncCursor) throws {
            let commit: ContractJSON = ["epoch": .integer(cursor.epoch), "seq": .integer(cursor.seq + 1), "accepted": [], "decisions": [],
                                        "slots": [], "records": [["entity": "podcast", "id": .string(ContractIdentity.randomUUID()),
                                                                  "field_group": "credentials",
                                                                  "value": ["secret_id": .string(ContractIdentity.randomUUID())], "provenance": []]]]
            let digest = try ContractHash.nextDigest(previous: ContractHex.decode(cursor.digest) ?? [], commit)
            self.commit = commit
            head = try SyncCursor(logID: cursor.logID, epoch: cursor.epoch, seq: cursor.seq + 1, digest: ContractHex.encode(digest)).encoded
        }
    }

    /// A server library at its server's head, with one change to push unless `change` is false.
    private func world(change: Bool = true, _ body: (ServerLibraryFixture, Server, Transport, ServerSyncEngine) async throws -> Void) async throws {
        let fixture = try await ServerLibraryFixture()
        let server = Server()
        let transport = Transport { path, body in try server.answer(path, body) }
        let engine = try await ServerSyncEngineUnitTests.engine(fixture, transport)
        server.head = try #require(try await fixture.store.serverExchangeState().cursor?.encoded)
        if change { try await fixture.store.appendFactForTesting(type: "favorite.set", targets: [], payload: [:]) }
        do { try await body(fixture, server, transport, engine) } catch { await engine.close(); await fixture.close(); throw error }
        await engine.close()
        await fixture.close()
    }

    private func count(_ transport: Transport, _ path: String) -> Int { transport.requests.filter { $0 == path }.count }

    /// A server older than this app refuses a push: pushing pauses (never retried with backoff), the next exchange
    /// pulls but sends nothing, the server is named, and that stays so across a launch (the stored state).
    @Test func aWholePushRefusedByAnOlderServerNamesTheServerAndPullsContinue() async throws {
        try await world { fixture, server, transport, engine in
            server.refused = ["v1/push"]
            server.info = 0...0
            let report = await engine.exchange()
            #expect(report.pause == .versionUnsupported && report.retryAfter == nil && !report.appNeedsUpdate, "\(report)")
            let pushes = count(transport, "v1/push"), pulls = count(transport, "v1/pull")
            let next = await engine.exchange()
            #expect(next.pause == .versionUnsupported && next.retryAfter == nil && !next.appNeedsUpdate)
            #expect(count(transport, "v1/push") == pushes, "nothing is pushed while paused")
            #expect(count(transport, "v1/pull") > pulls, "pulls continue")
            #expect(count(transport, "v1/info") == 1, "the side is asked once")
            let stored = await engine.storedState()
            #expect(stored.pause == .versionUnsupported && !stored.appNeedsUpdate)
            #expect(try await fixture.store.serverUnsentChanges() == 1, "the change is kept")
            let paused = try await engine.logEntries().filter { $0.kind == "paused" }.map(\.detail)
            #expect(paused == ["version_unsupported HTTP 426 refused the push: the server needs updating"], "logged once: \(paused)")
        }
    }

    /// A server newer than this app, one that speaks this app's version and still refuses it, and one that cannot say
    /// which versions it speaks: this app needs updating.
    @Test(arguments: [ClosedRange<Int>?(2...3), 1...2, nil])
    func aWholeRequestRefusedOtherwiseNamesThisApp(info: ClosedRange<Int>?) async throws {
        try await world { _, server, _, engine in
            server.refused = ["v1/push"]
            server.info = info
            let report = await engine.exchange()
            #expect(report.pause == .versionUnsupported && report.appNeedsUpdate && report.retryAfter == nil, "\(String(describing: info)): \(report)")
            #expect(await engine.storedState().appNeedsUpdate)
        }
    }

    /// A refused pull (PROTOCOL §10: "pause the affected direction") is not sent again by later exchanges, while pushes go on;
    /// a refused snapshot (Force full synchronization) is not sent again either, while pulls go on. Neither is retried
    /// as a transient failure, and the side is asked once.
    @Test func aRefusedPullOrSnapshotIsNotSentAgainWhileTheRestGoesOn() async throws {
        try await world { fixture, server, transport, engine in
            server.acceptsPushes = true
            server.refused = ["v1/pull"]
            server.info = 2...2
            let pulled = await engine.exchange()
            #expect(pulled.pause == .versionUnsupported && pulled.appNeedsUpdate && pulled.retryAfter == nil, "\(pulled)")
            #expect(pulled.refusedRequests == [.pull])
            let pulls = count(transport, "v1/pull"), pushes = count(transport, "v1/push")
            for _ in 0..<3 { _ = await engine.exchange() }
            #expect(count(transport, "v1/pull") == pulls, "the refused pull is not sent again")
            #expect(count(transport, "v1/push") > pushes, "pushing goes on")
            #expect(count(transport, "v1/info") == 1)
            try await engine.resume()
            server.refused = ["v1/snapshot"]
            server.info = 0...0
            await engine.requestFullSynchronization()
            let full = await engine.forceFullSynchronization()
            #expect(full.pause == .versionUnsupported && !full.appNeedsUpdate && full.retryAfter == nil && full.refusedRequests == [.snapshot], "\(full)")
            #expect(await engine.fullSynchronizationRequested(), "the repair stays owed")
            let snapshots = count(transport, "v1/snapshot"), pullsBefore = count(transport, "v1/pull")
            _ = await engine.forceFullSynchronization()
            #expect(count(transport, "v1/snapshot") == snapshots, "the refused snapshot is not sent again")
            #expect(count(transport, "v1/pull") > pullsBefore, "pulls go on")
        }
    }

    /// A refused secret (the commit that needs it waits) is not asked again, while pushes go on.
    @Test func aRefusedSecretIsNotAskedAgainWhilePushesGoOn() async throws {
        try await world { fixture, server, transport, engine in
            server.acceptsPushes = true
            server.refused = ["v1/secrets/"]
            server.info = 0...0
            try server.serveSecretCommit(after: try #require(try await fixture.store.serverExchangeState().cursor))
            let first = await engine.exchange()
            #expect(first.pause == .versionUnsupported && first.refusedRequests == [.secret] && first.retryAfter == nil, "\(first)")
            func secrets() -> Int { transport.requests.filter { $0.hasPrefix("v1/secrets/") }.count }
            let asked = secrets(), pushes = count(transport, "v1/push")
            #expect(asked == 1)
            for _ in 0..<2 { _ = await engine.exchange() }
            #expect(secrets() == asked, "the refused secret is not asked again")
            #expect(count(transport, "v1/push") > pushes, "pushing goes on")
            #expect(try await fixture.store.serverExchangeState().cursor?.seq == 0, "the commit that needs it waits")
        }
    }

    /// A transport conflict found while applying a commit replaces a version pause in the same transaction, and with it
    /// what that pause refused and the server's protocol version.
    @Test func aConflictWhileApplyingClearsTheVersionPause() async throws {
        try await world { fixture, server, _, engine in
            server.acceptsPushes = true
            try await fixture.store.refuseServerRequest(.snapshot, refusedProtocol: 2)
            try server.serveConflictingSlot(installID: fixture.identity.installID, after: try #require(try await fixture.store.serverExchangeState().cursor))
            let report = await engine.exchange()
            #expect(report.pause == .transportConflict, "\(report)")
            #expect(try fixture.rows("SELECT pause_reason, protocol_version, version_refusals FROM ntp_library") == [["transport_conflict", nil, nil]])
            let state = try await fixture.store.serverExchangeState()
            #expect(state.refusedRequests.isEmpty && state.refusingProtocol == nil && !state.appNeedsUpdate)
        }
    }

    /// A refused change names the server even after a whole request named this app; resuming clears the side.
    /// A transition planned while a version pause stood (a recovery or a new installation clears the pause it stood
    /// for) clears what that pause refused and the server's version with it.
    @Test func aPlannedTransitionClearsWhatAVersionPauseRefused() async throws {
        let fixture = try await ServerLibraryFixture()
        try await fixture.store.refuseServerRequest(.pull, refusedProtocol: 2)
        #expect(try fixture.rows("SELECT pause_reason, protocol_version, version_refusals FROM ntp_library") == [["version_unsupported", "2", "pull"]])
        try await fixture.store.planServerTransition(.conflict, nonce: ContractIdentity.randomUUID())
        #expect(try fixture.rows("SELECT pause_reason, protocol_version, version_refusals FROM ntp_library") == [[nil, nil, nil]])
        await fixture.close()
    }

    @Test func aRefusedChangeNamesTheServer() async throws {
        try await world { _, server, _, engine in
            server.refused = ["v1/push"]
            server.info = 2...2
            #expect(await engine.exchange().appNeedsUpdate)
            try await engine.resume()
            let resumed = await engine.storedState()
            #expect(resumed.pause == nil && !resumed.appNeedsUpdate)
            server.refused = []
            server.refusesChanges = true
            let report = await engine.exchange()
            #expect(report.pause == .versionUnsupported && !report.appNeedsUpdate && report.retryAfter == nil, "\(report)")
            #expect(try await engine.logEntries().contains { $0.kind == "paused" && $0.detail == "version_unsupported favorite.set" })
        }
    }

    /// Synchronize now tries again after a whole request was refused, as after a refused change: once the server or
    /// the app is updated, the change goes.
    @Test @MainActor func synchronizeNowTriesAgain() async throws {
        let fixture = try await ServerLibraryFixture()
        let server = Server()
        let transport = Transport { path, body in try server.answer(path, body) }
        let engine = try await ServerSyncEngineUnitTests.engine(fixture, transport)
        server.head = try #require(try await fixture.store.serverExchangeState().cursor?.encoded)
        try await fixture.store.appendFactForTesting(type: "favorite.set", targets: [], payload: [:])
        server.refused = ["v1/push"]
        server.info = 0...0
        let scheduler = ServerSyncScheduler(engine: engine, hints: nil, outbox: nil, network: ServerSyncSurfacesTests.Permitted())
        scheduler.start()
        let first = try #require(await scheduler.synchronizeNow())
        #expect(first.pause == .versionUnsupported && scheduler.pause == nil, "pulls continue: the scheduler keeps running")
        let pushes = count(transport, "v1/push")
        server.refused = []
        server.refusesChanges = true
        _ = await scheduler.synchronizeNow()
        #expect(count(transport, "v1/push") == pushes + 1, "resumed and pushed again")
        await scheduler.close()
        await fixture.close()
    }

    /// Automatic work (background tasks) after a refused Force full synchronization: the snapshot is not sent again and
    /// incremental pulls go on; the repair stays owed and no processing time is asked for it; Synchronize now (an
    /// explicit retry) tries the snapshot again.
    @Test @MainActor func automaticWorkLeavesARefusedSnapshotAndKeepsPulling() async throws {
        let fixture = try await ServerLibraryFixture()
        let server = Server()
        let transport = Transport { path, body in try server.answer(path, body) }
        let engine = try await ServerSyncEngineUnitTests.engine(fixture, transport)
        server.head = try #require(try await fixture.store.serverExchangeState().cursor?.encoded)
        server.refused = ["v1/snapshot"]
        server.info = 1...2
        let scheduler = ServerSyncScheduler(engine: engine, hints: nil, outbox: nil, network: ServerSyncSurfacesTests.Permitted())
        scheduler.start()
        let full = try #require(await scheduler.forceFullSynchronization())
        #expect(full.pause == .versionUnsupported && full.retryAfter == nil && full.refusedRequests == [.snapshot], "\(full)")
        let snapshots = count(transport, "v1/snapshot"), pulls = count(transport, "v1/pull")
        #expect(snapshots >= 1)
        _ = await scheduler.runInBackground(.processing)
        _ = await scheduler.runInBackground(.refresh)
        #expect(count(transport, "v1/snapshot") == snapshots, "automatic work does not send the refused snapshot")
        #expect(count(transport, "v1/pull") >= pulls + 2, "incremental pulls go on")
        #expect(await engine.fullSynchronizationRequested() && !scheduler.needsProcessingTime, "owed, without asking for processing time")
        _ = await scheduler.synchronizeNow()
        #expect(count(transport, "v1/snapshot") == snapshots + 1, "an explicit retry sends it again")
        await scheduler.close()
        await fixture.close()
    }

    /// Automatic work after a refused pull: no pull is sent again, while pushes go on.
    @Test @MainActor func automaticWorkLeavesARefusedPullAndKeepsPushing() async throws {
        let fixture = try await ServerLibraryFixture()
        let server = Server()
        let transport = Transport { path, body in try server.answer(path, body) }
        let engine = try await ServerSyncEngineUnitTests.engine(fixture, transport)
        server.head = try #require(try await fixture.store.serverExchangeState().cursor?.encoded)
        server.acceptsPushes = true
        server.refused = ["v1/pull"]
        server.info = 0...0
        try await fixture.store.appendFactForTesting(type: "favorite.set", targets: [], payload: [:])
        let scheduler = ServerSyncScheduler(engine: engine, hints: nil, outbox: nil, network: ServerSyncSurfacesTests.Permitted())
        scheduler.start()
        let first = try #require(await scheduler.synchronizeNow())
        #expect(first.refusedRequests == [.pull] && first.retryAfter == nil, "\(first)")
        let pulls = count(transport, "v1/pull"), pushes = count(transport, "v1/push")
        for _ in 0..<3 { _ = await scheduler.runInBackground(.refresh) }
        #expect(count(transport, "v1/pull") == pulls, "automatic work does not send the refused pull")
        #expect(count(transport, "v1/push") >= pushes + 3, "pushes go on")
        await scheduler.close()
        await fixture.close()
    }

    /// The page names the side the report names: "This server needs updating" or "This app needs updating" (PROTOCOL §15.5).
    @Test @MainActor func thePageNamesTheSideThatNeedsUpdating() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ServerVersionPause-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = try await Self.accounts(root: root)
        for (appNeedsUpdate, condition) in [(false, ServerSynchronizationPage.Condition.serverNeedsUpdate), (true, .appNeedsUpdate)] {
            var report = ServerExchangeReport()
            report.pause = .versionUnsupported
            report.appNeedsUpdate = appNeedsUpdate
            accounts.exchangeReported(report)
            let page = accounts.page(otherProvider: false)
            #expect(page.condition == condition && page.subtitle == .paused, "\(appNeedsUpdate): \(String(describing: page.condition))")
        }
    }

    /// Server accounts with one active server library open and a usable token (no server needed).
    @MainActor static func accounts(root: URL) async throws -> ServerAccounts {
        let id = ContractIdentity.randomUUID()
        var registry = LibraryRegistry()
        registry.libraries = [.init(id: id, serverURL: "https://sync.example.test", serverID: "s", accountID: ContractIdentity.randomUUID(),
                                    username: "alice", state: .active, createdAt: 0)]
        registry.active = .server(id)
        try LibraryRegistryFile(root: root).write(registry)
        let secrets = MemoryServerSecrets()
        try secrets.saveInstallation(.init(transportNonce: ContractIdentity.randomUUID(), token: "ntp1_token"), library: id,
                                     install: ContractIdentity.randomUUID())
        let accounts = ServerAccounts(.init(root: root, openLibrary: { .server(id) }, requestSwitch: { _, _, _ in }, secrets: secrets,
            makeClient: { ServerClient(address: $0) }, device: ServerDevice(name: "NotTennaPod on iPhone", appVersion: "test")))
        await accounts.refresh()
        return accounts
    }
}
