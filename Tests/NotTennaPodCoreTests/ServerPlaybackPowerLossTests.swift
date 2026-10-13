import Foundation
import Testing
@testable import NotTennaPodCore

/// The save-loss bound of a power loss (PROTOCOL §8.2): the five-second saves commit without
/// waiting for the disk (`synchronous = NORMAL`), while the minute's checkpoint export, a pause and a play are durable
/// transactions, which sync the write-ahead log with everything before them. A power loss keeps exactly the log as it
/// was last synced. The library runs on a pass-through file system that observes every real sync of its log, so after
/// every save a power loss is simulated at the observed boundary: the library and its log cut at its length at the
/// latest sync (no checkpoint runs meanwhile) are opened as after a restart, and what survives is compared with what was
/// saved. Nothing here assumes which transactions are durable: if the minute's transaction stops syncing, the loss
/// grows to the whole session and the test fails. The bound while playing is about a minute of position and listening;
/// nothing is lost while paused.
@Suite(.serialized, .timeLimit(.minutes(10))) struct ServerPlaybackPowerLossTests {
    /// The library as a power loss would leave it now: the database file and its log up to `synced` bytes, opened.
    static func afterPowerLoss(_ fixture: ServerLibraryFixture, synced: Int) async throws -> (position: Int32, lastPlayed: Int64, journaled: Int64) {
        let folder = fixture.directory.appendingPathComponent("power-loss-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("library.sqlite")
        try FileManager.default.copyItem(at: fixture.url, to: copy)
        let log = try Data(contentsOf: URL(fileURLWithPath: fixture.url.path + "-wal"))
        try log.prefix(synced).write(to: URL(fileURLWithPath: copy.path + "-wal"))
        let store = try FeedLibraryStore(url: copy)
        defer { Task { try? await store.close() } }
        let episode = try #require(try await store.playbackSession()?.episodeID)
        let state = try #require(try await store.episode(id: episode)).userState
        let journaled = try await store.syncSessionsForTesting().compactMap { $0.last?.time }.max() ?? 0
        return (state.positionMilliseconds, state.lastPlayedTimeMilliseconds, journaled)
    }

    @Test func aPowerLossLosesAtMostAboutAMinuteWhilePlayingAndNothingWhilePaused() async throws {
        SyncObservingVFS.install()
        defer { SyncObservingVFS.restoreDefault() }
        let (fixture, ids, _, _) = try await ServerPlaybackRecorderTests.library()
        defer { Task { await fixture.close() } }
        let log = fixture.url.path + "-wal"
        // No checkpoint moves the log into the database during the measurement: the log alone is what a power loss cuts.
        try await fixture.store.setLogCheckpointingForTesting(enabled: false)
        let player = StorePlayer(fixture.store)
        try await player.load(ids[1])
        try await player.play()
        #expect(SyncObservingVFS.synced(log: log).observed, "the library's log runs on the observing file system")
        let syncsBefore = SyncObservingVFS.synced(log: log).syncs
        var worst: (seconds: Double, position: Int32) = (0, 0)
        var losses: [Double] = []
        let start = player.time
        for _ in 0..<(10 * 60 / 5) {
            try await player.listen(5)
            let survived = try await Self.afterPowerLoss(fixture, synced: SyncObservingVFS.synced(log: log).length)
            // The latest save that survived: the session journal's (the play's own start save included), committed with
            // the row's in each save's transaction.
            let lost = Double(Int64(player.time.timeIntervalSince1970 * 1_000) - survived.journaled) / 1_000
            losses.append(lost)
            if lost > worst.seconds { worst = (lost, player.position - survived.position) }
            #expect(survived.lastPlayed == 0 || survived.journaled == survived.lastPlayed, "the session journal survives with its save")
        }
        let syncsPlaying = SyncObservingVFS.synced(log: log).syncs - syncsBefore
        try await player.pause()
        let paused = try await Self.afterPowerLoss(fixture, synced: SyncObservingVFS.synced(log: log).length)
        let pausedLoss = player.position - paused.position
        let mean = losses.reduce(0, +) / Double(losses.count)
        print("POWER LOSS while playing \(Int(player.time.timeIntervalSince(start))) s, saves every 5 s: worst loss \(worst.seconds) s "
              + "(\(worst.position) ms of position), mean \(String(format: "%.1f", mean)) s over \(losses.count) simulated losses "
              + "at the observed log syncs (\(syncsPlaying) while playing); after a pause: \(pausedLoss) ms of position lost")
        #expect(worst.seconds <= 60, "at most the minute's export interval while playing")
        #expect(worst.seconds >= 55, "the five-second saves alone are not synced (the bound is real)")
        #expect(pausedLoss == 0 && paused.lastPlayed == Int64(player.time.timeIntervalSince1970 * 1_000), "nothing while paused")
    }
}

extension FeedLibraryStore {
    /// Turns SQLite's automatic log checkpoints off (or back on) on this connection, for the power-loss simulation.
    func setLogCheckpointingForTesting(enabled: Bool) throws {
        _ = try database.rows("PRAGMA wal_autocheckpoint = \(enabled ? 1_000 : 0)")
    }
}
