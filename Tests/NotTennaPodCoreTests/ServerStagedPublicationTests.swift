import Foundation
import Testing
@testable import NotTennaPodCore

/// A staged publication is a bounded atomic switch that keeps concurrent local operations (PROTOCOL §6.8):
/// local changes outside its scope do not concern it (the player's saves and minute exports on another podcast), local
/// changes inside it are re-projected at its switch (a favorite, a queue edit, a checkpoint on an episode of the podcast
/// being staged), and one that cannot publish now keeps its staged result for the next exchange or pause, built again
/// only when what it was built on moved. Against a server that sends one commit (`ServerBoundedCutoverTests.serve`).
@Suite(.serialized, .timeLimit(.minutes(20))) struct ServerStagedPublicationTests {
    typealias Cutover = ServerBoundedCutoverTests

    /// A player saving on its own task while an exchange runs: every save is a minute's checkpoint export (its simulated
    /// clock moves a minute a save), a durable write that records a session fact with its overlays.
    final class Saver: @unchecked Sendable {
        let player: StorePlayer
        private let stopped = PlayingFlag()
        private var task: Task<Int, any Error>?

        init(_ player: StorePlayer) { self.player = player }

        func start() {
            let player = player, stopped = stopped
            task = Task {
                var saves = 0
                while !stopped.value {
                    try await player.listen(60, every: 60)
                    saves += 1
                    await Task.yield()
                }
                return saves
            }
        }

        /// Stops and returns how many saves it made.
        func stop() async throws -> Int {
            stopped.value = true
            return try await task?.value ?? 0
        }
    }

    static func log(_ engine: ServerSyncEngine) async throws -> [String] { try await engine.logEntries().map(\.detail) }

    static func checkpoints(_ fixture: ServerLibraryFixture) throws -> Int {
        try fixture.outbox().filter { $0.type == "session.checkpoint" }.count
    }

    /// The owner listens all day: a 20,000-episode catalog arrives while audio plays and the player exports a checkpoint
    /// every minute (here every save, to cover the staging's every window). It is staged and published while playing;
    /// the exports, on another podcast, never make it stale.
    @Test func aTwentyThousandEpisodeCatalogAppliesWhilePlayingWithMinuteExports() async throws {
        let (fixture, small, engine) = try await Cutover.arrival(count: 20_000, playing: true)
        await engine.setBudgets(playingInterval: 0.001)
        let player = StorePlayer(fixture.store)
        try await player.load(small.episodes.map(\.id).sorted()[1])
        try await player.play()
        let saver = Saver(player)
        saver.start()
        let report = await engine.exchange()
        let saves = try await saver.stop()
        #expect(report.completed && report.appliedUnits == 1, "\(report)")
        let log = try await Self.log(engine)
        #expect(!log.contains { $0.contains("staged again") } && log.filter { $0.contains("staged in") }.count == 1, "\(log.prefix(8))")
        #expect(try await Cutover.arrived(fixture.store)?.episodes.count == 20_000)
        let checkpoints = try Self.checkpoints(fixture)
        #expect(saves >= 3 && checkpoints >= 3, "the exports ran meanwhile: \(saves) saves, \(checkpoints) checkpoints")
        #expect(try await fixture.store.episode(id: player.episodeID ?? 0)?.userState.positionMilliseconds == player.position, "and are kept")
        await engine.close()
        await fixture.close()
    }

    /// The player plays an episode of the podcast whose catalog is being staged, and its minute exports land between
    /// staging transactions: the staging goes on, and the switch re-projects that episode, so its position is this
    /// phone's and the commit's rename of it applies.
    @Test func aCheckpointOnAnEpisodeOfTheStagedPodcastIsKept() async throws {
        let fixture = try await ServerLibraryFixture()
        let podcast = try await Cutover.registeredElsewhere(fixture)
        let first = podcast.episodes[0].id
        let records = try Cutover.episodeRecords(2...301) + [Cutover.metadata(1, title: "Arriving 1, renamed")]
        let engine = try await Cutover.serve(fixture, records, playing: true)
        await engine.setBudgets(playingInterval: 0.001)
        let player = StorePlayer(fixture.store)
        try await player.load(first)
        try await player.play()
        let saver = Saver(player)
        saver.start()
        let report = await engine.exchange()
        let saves = try await saver.stop()
        #expect(report.completed, "\(report)")
        #expect(!(try await Self.log(engine)).contains { $0.contains("staged again") })
        let checkpoints = try Self.checkpoints(fixture)
        #expect(saves >= 3 && checkpoints >= 3, "\(saves) saves, \(checkpoints) checkpoints")
        let kept = try #require(try await fixture.store.episode(id: first))
        #expect(kept.userState.positionMilliseconds == player.position, "this phone's checkpoints are kept: \(kept.userState.positionMilliseconds)")
        #expect(kept.details.title == "Arriving 1, renamed", "beside the commit's own change")
        #expect(try await Cutover.arrived(fixture.store)?.episodes.count == 301)
        await engine.close()
        await fixture.close()
    }

    /// A favorite of an episode the commit changes, made between the staging and the switch, is kept, and the shadow
    /// is not built again.
    @Test func aLocalActionInsideTheStagedScopeIsKeptWithoutBuildingAgain() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let podcast = try await Cutover.registeredElsewhere(fixture)
        let first = podcast.episodes[0].id
        let records = try Cutover.episodeRecords(2...301) + [Cutover.metadata(1, title: "Arriving 1, renamed")]
        let engine = try await Cutover.serve(fixture, records)
        let once = PlayingFlag()
        await engine.setBeforePublish {
            guard !once.value else { return }
            once.value = true
            try await store.setFavorite(episodeID: first, favorite: true)
        }
        let report = await engine.exchange()
        #expect(report.completed, "\(report)")
        let log = try await Self.log(engine)
        #expect(!log.contains { $0.contains("staged again") } && log.filter { $0.contains("staged in") }.count == 1, "\(log)")
        let kept = try #require(try await store.episode(id: first))
        #expect(kept.userState.isFavorite && kept.details.title == "Arriving 1, renamed", "\(kept.userState)")
        #expect(try fixture.outbox().contains { $0.type == "favorite.set" }, "and recorded")
        await engine.close()
        await fixture.close()
    }

    /// A queue reorder made between the staging and the switch survives the publication, beside the arriving
    /// podcast's own queued episodes.
    @Test func aQueueReorderDuringStagingIsKept() async throws {
        let (fixture, small, engine) = try await Cutover.arrival()
        let store = fixture.store
        let ids = small.episodes.map(\.id).sorted()
        _ = try await store.enqueue([ids[1]])
        let once = PlayingFlag()
        await engine.setBeforePublish {
            guard !once.value else { return }
            once.value = true
            _ = try await store.performQueueMove(.item(ids[1], finalIndex: 0), expected: try await store.queue().map(QueueEpisodeIdentity.init))
        }
        let report = await engine.exchange()
        #expect(report.completed, "\(report)")
        #expect(!(try await Self.log(engine)).contains { $0.contains("staged again") })
        let queue = try await store.queue().map(\.id)
        #expect(queue.count == 5, "\(queue)")
        let second = try #require(queue.firstIndex(of: ids[1])), first = try #require(queue.firstIndex(of: ids[0]))
        #expect(second < first, "the reorder is kept: \(queue)")
        await engine.close()
        await fixture.close()
    }

    /// A crash between the staging and the switch while the player keeps exporting: the next exchange (a relaunch)
    /// takes the staging out, stages again once, and publishes while the exports go on.
    @Test func aCrashBetweenStagingAndPublicationRecoversWhileThePlayerExports() async throws {
        let (fixture, small, engine) = try await Cutover.arrival(playing: true)
        await engine.setBudgets(playingInterval: 0.001)
        let player = StorePlayer(fixture.store)
        try await player.load(small.episodes.map(\.id).sorted()[1])
        try await player.play()
        let saver = Saver(player)
        saver.start()
        await engine.setCrashPoint(ServerExchangePushPullTests.crashOnce(at: "staging.staged"))
        let crashed = await engine.exchange()
        #expect(crashed.error == "InjectedCrash()", "\(crashed)")
        #expect(try fixture.rows("SELECT count(*) FROM ntp_hidden_feeds WHERE state = 'staging'") == [["1"]], "staged, hidden")
        await engine.close()
        // Relaunched: a new engine knows nothing of the staging but what the library holds.
        let relaunched = try await Cutover.serve(fixture, try Cutover.arrivingRecords(count: 300), playing: true)
        await relaunched.setBudgets(playingInterval: 0.001)
        let report = await relaunched.exchange()
        let saves = try await saver.stop()
        #expect(report.completed, "\(report)")
        let log = try await Self.log(relaunched)
        #expect(log.contains { $0.contains("taken out") } && !log.contains { $0.contains("staging changed") || $0.contains("during staging") }, "\(log)")
        #expect(saves >= 3, "\(saves) saves")
        #expect(try await Cutover.arrived(fixture.store)?.episodes.count == 300)
        #expect(try fixture.rows("SELECT count(*) FROM feeds") == [["2"]], "nothing of the first staging is left")
        #expect(try fixture.rows("SELECT (SELECT count(*) FROM ntp_hidden_feeds) + (SELECT count(*) FROM ntp_hidden_episodes) + (SELECT count(*) FROM ntp_staging)") == [["0"]])
        await relaunched.close()
        await fixture.close()
    }

    /// A local change in the staged scope that meets a structural dependency (a download started on an episode the
    /// commit renames, beside 70 favorites) while audio plays: nothing is published, the staged result is kept, and at
    /// the pause it is published as a whole from the intact local rows, not built again, with every favorite and the
    /// download kept.
    @Test func aPublicationThatCannotSwitchNowIsKeptAndRetriedWithoutBuildingAgain() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        try await ServerProjectionUnitTests.Applier(fixture).apply(try Cutover.arrivingRecords(count: 100))
        var favorites: [Int64] = []
        for number in 1...70 { favorites.append(try #require(try await store.localEpisodeForTesting(wire: Cutover.wire(number)))) }
        let records = try Cutover.episodeRecords(101...400) + (1...70).map { Cutover.metadata($0, title: "Renamed \($0)") }
        let playing = PlayingFlag()
        playing.value = true
        let engine = try await Cutover.serve(fixture, records, playingFlag: playing)
        await engine.setBudgets(playingInterval: 0.001)
        let once = PlayingFlag(), marked = favorites, media = fixture.directory
        await engine.setBeforePublish {
            guard !once.value else { return }
            once.value = true
            try await store.setFavorite(episodeIDs: marked, favorite: true)
            _ = try await store.requestDownload(episodeID: marked[1], directory: media, enqueue: false)
        }
        let waiting = await engine.exchange()
        #expect(waiting.waitingForPause && waiting.appliedUnits == 0, "\(waiting)")
        #expect(try await Cutover.arrived(store)?.episodes.count == 100, "nothing of it is published while playing")
        #expect(try fixture.rows("SELECT count(*) FROM ntp_hidden_episodes") == [["300"]], "its staging is kept")
        playing.value = false
        let paused = await engine.exchange()
        #expect(paused.completed && paused.appliedUnits == 1, "\(paused)")
        #expect(waiting.shadowsBuilt + paused.shadowsBuilt == 1, "built once")
        let log = try await Self.log(engine)
        #expect(log.filter { $0.contains("staged in") }.count == 1 && log.contains { $0.contains("published as a whole") }, "\(log)")
        #expect(try await Cutover.arrived(store)?.episodes.count == 400)
        for (number, id) in zip(1...70, favorites) {
            let episode = try #require(try await store.episode(id: id))
            #expect(episode.userState.isFavorite && episode.details.title == "Renamed \(number)", "\(number)")
        }
        #expect(try await store.downloadJobs().contains { $0.episodeID == favorites[1] }, "the download goes on")
        await engine.close()
        await fixture.close()
    }
}
