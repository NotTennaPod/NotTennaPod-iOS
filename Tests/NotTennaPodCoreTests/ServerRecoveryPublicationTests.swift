import Foundation
import Testing
@testable import NotTennaPodCore

/// A recovery's base switch (PROTOCOL §6.11) is a retained publication (PROTOCOL §6.8): built from the
/// local-change log's end, published only over exactly the cursor it was built on, the local changes since re-projected
/// or, structural or touching a recovery hold, deferring it; a switch that waits is kept and published as it was built
/// when it may run, never built again while that cursor is live, and dropped once it is not. Against the pinned server
/// restored with its own commands.
@Suite(.serialized, .timeLimit(.minutes(30))) struct ServerRecoveryPublicationTests {
    typealias Copies = ServerCopiesTests
    typealias Recovery = ServerRecoveryTests
    typealias Regression = ServerRecoveryRegressionTests
    typealias PushPull = ServerExchangePushPullTests

    /// A changes e0 after the backup and B never pulls it; B's own change after the backup was accepted and pulled, so
    /// the restored server's log is no prefix of B's. A recovers first, restoring its change; B has signed in again and
    /// its recovery has not run: its base switch makes e0 played.
    static func unpulled(_ world: ExchangeWorld) async throws -> (a: DevicePhone, b: DevicePhone, onB: [Int64], wires: [String]) {
        let (a, ids) = try await Copies.subscribed(world)
        let b = try await world.device("B")
        let onB = try await ids.asyncMap { try await Recovery.same($0, from: a, on: b) }
        let wires = try await onB.asyncMap { try #require(try await b.store.wireEpisodeForTesting($0)) }
        let backup = try await world.backUp()
        try await b.store.setFavorite(episodeID: onB[3], favorite: true)
        await b.exchange()
        try await a.store.markEpisodePlayed(episodeID: ids[0], played: true)
        await a.exchange()
        try await world.restore(backup)
        _ = try await Recovery.recover(a)
        #expect(await b.engine.exchange().pause == .signIn)
        try await b.signInAgain()
        #expect(try await b.view().episodes[wires[0]]?.playState != .played, "B never pulled A's change")
        return (a, b, onB, wires)
    }

    /// B's recovery with the app in use while audio plays: its switch is over the publication budget, so it waits
    /// for the background, kept; nothing switched.
    static func kept(_ b: DevicePhone) async throws -> ServerExchangeReport {
        b.playing.value = true
        b.foreground.value = true
        await b.engine.setBudgets(publish: 1)
        let waiting = await b.engine.exchange()
        #expect(waiting.error == nil && waiting.waitingForBackground && waiting.shadowsBuilt == 1, "\(waiting)")
        #expect(await b.engine.keptFull?.replacing != nil, "the switch is kept")
        #expect(try await Recovery.recovery(b)?.caughtUp == false)
        return waiting
    }

    final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: LibraryEpisode?
        var value: LibraryEpisode? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    static func stagedSnapshots(_ phone: DevicePhone) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: try #require(phone.location.staging).path).filter { $0.hasPrefix("full-") }
    }

    // MARK: - Waiting and publishing

    /// While audio plays and the app is in use the switch waits; once the app leaves the foreground (audio still playing)
    /// the kept switch is published whole within the background budget, as it was built: not built again, and the
    /// recovery's own pass over what waits (its holds unchanged) does not defer it.
    @Test func aRecoverySwitchWaitsInTheForegroundAndIsPublishedWholeInTheBackground() async throws {
        try await ExchangeWorld.run { world in
            let (_, b, _, wires) = try await Regression.heldChain(world, queue: false, recover: false)
            _ = try await Self.kept(b)
            let held = try b.rows("SELECT count(*) FROM ntp_recovery_holds")
            #expect(held != [["0"]], "what waits is held")
            b.foreground.value = false
            b.eligibility.changed()
            let report = await b.engine.exchange()
            #expect(report.error == nil && report.shadowsBuilt == 0, "published as it was built: \(report)")
            #expect(!report.waitingForPause && !report.waitingForBackground, "\(report)")
            #expect(try await b.log().contains { $0.detail.contains("published whole while audio plays in the background") })
            #expect(try await b.log().contains { $0.detail.contains("built at an earlier exchange") })
            #expect(await b.engine.keptFull == nil)
            #expect(try b.rows("SELECT count(*) FROM ntp_recovery_holds") == held, "the holds stay")
            let recovery = try #require(try await Recovery.recovery(b))
            #expect(recovery.caughtUp && recovery.waiting, "\(recovery)")
            let view = try await b.view()
            #expect(view.episodes[wires[0]]?.favorite == true && view.episodes[wires[1]]?.favorite == true, "the waiting changes stay shown: \(view)")
            #expect(try Self.stagedSnapshots(b).isEmpty)
        }
    }

    /// A Force full synchronization while a recovery's switch is kept publishes that switch (its cursor is live): the
    /// library takes the restored server's base without building or downloading another, and the recovery goes on.
    @Test func aForceFullSynchronizationPublishesAKeptRecoverySwitch() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, wires) = try await Regression.heldChain(world, queue: false, recover: false)
            _ = try await Self.kept(b)
            b.foreground.value = false
            b.playing.value = false
            b.eligibility.changed()
            let full = await b.engine.forceFullSynchronization()
            #expect(full.error == nil && full.reprojected && full.shadowsBuilt == 0, "\(full)")
            #expect(await b.engine.keptFull == nil)
            let report = await b.exchange()
            #expect(report.recovery == .waiting, "\(report)")
            #expect(try await Recovery.recovery(b)?.caughtUp == true)
            _ = try await Recovery.recover(a)
            _ = await b.engine.exchange()
            _ = await b.engine.exchange()
            let recovery = try #require(try await Recovery.recovery(b))
            #expect(recovery.finished && recovery.complete == true, "\(recovery)")
            try await world.converge([a, b], "force full")
            let view = try await b.view()
            #expect(view.episodes[wires[0]]?.favorite == true && view.episodes[wires[1]]?.favorite == true)
        }
    }

    /// The cursor the kept switch replaces moves (same position, another digest): the switch is not published over it
    /// but dropped, and the next one is built on the live cursor.
    @Test func aKeptRecoverySwitchIsDroppedWhenItsSourceCursorMoves() async throws {
        try await ExchangeWorld.run { world in
            let (_, b, _, wires) = try await Regression.heldChain(world, queue: false, recover: false)
            _ = try await Self.kept(b)
            let source = try #require(try await b.store.serverExchangeState().cursor)
            let moved = try SyncCursor(logID: source.logID, epoch: source.epoch, seq: source.seq,
                                       digest: String(repeating: source.digest.hasPrefix("f") ? "e" : "f", count: 64))
            try await b.store.setCursorForTesting(moved)
            b.foreground.value = false
            b.playing.value = false
            b.eligibility.changed()
            let report = await b.engine.exchange()
            #expect(report.error == nil && report.shadowsBuilt == 1, "built again on the live cursor: \(report)")
            #expect(await b.engine.keptFull == nil)
            #expect(try await Recovery.recovery(b)?.caughtUp == true)
            let view = try await b.view()
            #expect(view.episodes[wires[0]]?.favorite == true && view.episodes[wires[1]]?.favorite == true, "\(view)")
        }
    }

    /// The app stops while a switch is kept (the store reopened, the kept build gone). After the relaunch the switch
    /// is built again on the server's newer head, the earlier opening's staged snapshot is taken out, and the recovery
    /// finishes with nothing lost.
    @Test func aStoreReopensWithAKeptRecoverySwitch() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, wires) = try await Regression.heldChain(world, queue: false, recover: false)
            _ = try await Self.kept(b)
            #expect(try Self.stagedSnapshots(b).count == 1)
            // A recovers meanwhile: the server's head moves on, with what B waits for.
            _ = try await Recovery.recover(a)
            try await b.relaunch()
            b.foreground.value = false
            b.playing.value = false
            let report = await b.exchange()
            #expect(report.shadowsBuilt == 1, "\(report)")
            _ = await b.engine.exchange()
            _ = await b.engine.exchange()
            let recovery = try #require(try await Recovery.recovery(b))
            #expect(recovery.finished && recovery.complete == true, "\(recovery)")
            let left = try Self.stagedSnapshots(b)
            #expect(left.isEmpty, "nothing staged is left behind: \(left)")
            try await world.converge([a, b], "reopened")
            let view = try await b.view()
            #expect(view.episodes[wires[0]]?.favorite == true && view.episodes[wires[1]]?.favorite == true)
        }
    }

    /// A crash around the kept switch's publication (inside its transaction, or right after it): the library is never
    /// half switched; without a relaunch the kept switch is published at the next exchange as it was built, and the
    /// recovery finishes with every device the same.
    @Test(arguments: [("full.base", false), ("full.written", false), ("full.published", false), ("full.written", true)])
    func aCrashAroundTheKeptSwitchLeavesTheLibraryComplete(point: String, relaunch: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, wires) = try await Regression.heldChain(world, queue: false, recover: false)
            _ = try await Self.kept(b)
            let before = try await b.store.serverExchangeState().cursor
            b.foreground.value = false
            b.playing.value = false
            b.eligibility.changed()
            await b.engine.setCrashPoint(PushPull.crashOnce(at: point))
            let crashed = await b.engine.exchange()
            #expect(crashed.error == "InjectedCrash()", "\(point): \(crashed.error ?? "no crash")")
            let inside = point != "full.published"
            #expect(try await b.store.serverExchangeState().cursor == before || !inside, "rolled back whole")
            var view = try await b.view()
            #expect(view.episodes[wires[0]]?.favorite == true && view.episodes[wires[1]]?.favorite == true, "\(point): \(view)")
            if relaunch { try await b.relaunch() }
            let report = await b.exchange()
            if inside && !relaunch { #expect(report.shadowsBuilt == 0, "\(point): published as it was built: \(report)") }
            #expect(try await Recovery.recovery(b)?.caughtUp == true)
            _ = try await Recovery.recover(a)
            _ = await b.engine.exchange()
            _ = await b.engine.exchange()
            let recovery = try #require(try await Recovery.recovery(b))
            #expect(recovery.finished && recovery.complete == true, "\(point): \(recovery)")
            try await world.converge([a, b], point)
            view = try await b.view()
            #expect(view.episodes[wires[0]]?.favorite == true && view.episodes[wires[1]]?.favorite == true, "\(point): \(view)")
            #expect(try Self.stagedSnapshots(b).isEmpty)
        }
    }

    // MARK: - Local changes during the build

    /// The person favorites an episode the switch writes (A's played e0) while it is built: the switch re-projects it
    /// at its publication instead of writing its image, so the episode is played and favorited as soon as it is
    /// published (before the favorite reaches the server).
    @Test func aLocalChangeDuringTheRecoveryBuildIsRebased() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, onB, wires) = try await Self.unpulled(world)
            let once = PlayingFlag()
            let store = b.store
            await b.engine.setBeforePublish {
                guard !once.value else { return }
                once.value = true
                try await store.setFavorite(episodeID: onB[0], favorite: true)
            }
            // The row as the publication leaves it.
            let published = Captured()
            let database = b.location.database, row = onB[0]
            await b.engine.setCrashPoint { point in
                guard point == "full.published", let json = try ServerLibraryFixture.read(database, "SELECT CAST(record AS TEXT) FROM episodes WHERE id = \(row)").first?.first ?? nil else { return }
                published.value = try JSONDecoder().decode(LibraryEpisode.self, from: Data(json.utf8))
            }
            let report = await b.exchange()
            await b.engine.setCrashPoint(nil)
            let switched = try #require(published.value?.userState)
            #expect(switched.playState == .played && switched.isFavorite, "published played and favorited: \(switched)")
            #expect(once.value && report.rebasedEntities >= 1 && report.shadowsBuilt == 1, "\(report)")
            #expect(try await b.log().contains { $0.detail.contains("local changes since staging re-projected") })
            let shown = try #require(try await b.view().episodes[wires[0]])
            #expect(shown.playState == .played && shown.favorite, "played by the switch, favorited since: \(shown)")
            try await world.converge([a, b], "rebased")
            #expect(try await a.view().episodes[wires[0]]?.favorite == true)
        }
    }

    /// A local change the switch cannot re-project while audio plays: a download started on an episode it writes
    /// (structural), or a recovery hold written. The switch is deferred, kept (not published within the budgets), and
    /// published as a whole once playback pauses, with that change kept.
    @Test(arguments: ["download", "hold"])
    func aStructuralOrHoldChangeDuringTheRecoveryBuildDefersTheSwitch(change: String) async throws {
        try await ExchangeWorld.run { world in
            let (a, b, onB, wires) = try await Self.unpulled(world)
            let once = PlayingFlag()
            let store = b.store
            let directory = b.location.folder.appendingPathComponent("downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let base = try #require(try b.rows("SELECT entity, id, field_group FROM ntp_records WHERE entity = 'episode' AND id = '\(wires[2])' LIMIT 1").first)
            let key = ServerRecordKey(entity: try #require(base[0]), id: try #require(base[1]), fieldGroup: try #require(base[2]))
            await b.engine.setBeforePublish {
                guard !once.value else { return }
                once.value = true
                if change == "download" {
                    _ = try await store.requestDownload(episodeID: onB[0], directory: directory, enqueue: false)
                } else {
                    try await store.holdServerRecords([FeedLibraryStore.ServerHeldRecord(key: key, nodes: ["test-node"])])
                }
            }
            b.playing.value = true
            let waiting = await b.engine.exchange()
            #expect(once.value && waiting.error == nil && waiting.waitingForPause, "\(change): \(waiting)")
            #expect(await b.engine.keptFull != nil, "kept")
            #expect(try await b.view().episodes[wires[0]]?.playState != .played, "nothing switched")
            b.playing.value = false
            b.eligibility.changed()
            let report = await b.exchange()
            #expect(report.shadowsBuilt == 0, "\(change): \(report)")
            #expect(try await b.log().contains { $0.detail.contains("reprojected as a whole") }, "\(change)")
            #expect(try await b.view().episodes[wires[0]]?.playState == .played)
            if change == "download" {
                #expect(try await b.store.downloadJobs().contains { $0.episodeID == onB[0] }, "the download goes on")
            }
            try await world.converge([a, b], change)
        }
    }

    // MARK: - Recovery holds in the local-change log

    /// Recovery holds are covered by the local-change log: a hold written, gaining a node or released is a touch that
    /// defers a retained publication (it is published as a whole when nothing limits it); a hold written again unchanged
    /// is no touch; and with the table created after the log started, what came before is unknown (a new epoch) and its
    /// writes are logged from then on.
    @Test func recoveryHoldsAreTouchesOfTheLocalChangeLog() async throws {
        let (fixture, _, _, _) = try await ServerLocalPlaybackTests.library()
        let store = fixture.store
        let keys = try fixture.rows("SELECT entity, id, field_group FROM ntp_records WHERE entity = 'episode' ORDER BY id LIMIT 2").map {
            ServerRecordKey(entity: $0[0]!, id: $0[1]!, fieldGroup: $0[2]!)
        }
        #expect(keys.count == 2)
        // Created after the log started (an older library whose table appears with its first use).
        try await store.executeForTesting("DROP TABLE IF EXISTS ntp_recovery_holds")
        let before = try await store.serverTouchWatermark()
        try await store.holdServerRecords([.init(key: keys[0], nodes: ["n1"])])
        #expect(try await store.serverTouches(since: before, limit: 500).unknown, "what the table held before is unknown")
        // Covered from then on.
        var mark = try await store.serverTouchWatermark()
        try await store.holdServerRecords([.init(key: keys[1], nodes: ["n1"])])
        #expect(try await store.serverTouches(since: mark, limit: 500).holds, "a new hold")
        mark = try await store.serverTouchWatermark()
        try await store.holdServerRecords([.init(key: keys[1], nodes: ["n1"])])
        #expect(try await store.serverTouches(since: mark, limit: 500).isEmpty, "the same hold again writes nothing")
        try await store.holdServerRecords([.init(key: keys[1], nodes: ["n2"])])
        #expect(try await store.serverTouches(since: mark, limit: 500).holds, "a hold gaining a node")
        mark = try await store.serverTouchWatermark()
        while try await store.releaseServerHolds(stillWaiting: [], history: nil, now: 3_000_000) != nil {}
        #expect(try await store.serverTouches(since: mark, limit: 500).holds, "holds released")
        // A retained full publication built before a hold changes is deferred, and published as a whole without a limit.
        try await store.requestServerFullSynchronization()
        let (build, head) = try await ServerRetainedPublicationTests.fullBuild(fixture) { _ in false }
        try await store.holdServerRecords([.init(key: keys[0], nodes: ["n3"])])
        await #expect {
            _ = try await store.publishFullReprojection(build, head: head, now: 3_000_000, crash: nil, workLimit: 1_000)
        } throws: { error in
            if case ServerApplyError.deferred(let reason) = error { return reason.contains("recovery holds") }
            return false
        }
        #expect(try await store.serverFullSynchronizationRequested(), "nothing written while deferred")
        let whole = try await store.publishFullReprojection(build, head: head, now: 3_000_000, crash: nil)
        #expect(whole.wholeAtPause && whole.published)
        await fixture.close()
    }
}
