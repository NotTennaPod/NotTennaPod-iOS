import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite
struct PlaybackTimelineResetTests {
    private final class Engine: PlaybackEngine {
        var reading: PlaybackEngineReading?
        var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
        func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
            reading = .init(generation: generation, sample: .init(positionMilliseconds: Int32(positionMilliseconds),
                durationMilliseconds: -1, seekable: false, status: .paused))
        }
        func play(commandID: UUID) { reading?.commandID = commandID; reading?.sample.status = .playing }
        func pause(commandID: UUID) { reading?.commandID = commandID; reading?.sample.status = .paused }
        func seek(to positionMilliseconds: Int64, commandID: UUID) {
            reading?.commandID = commandID; reading?.sample.positionMilliseconds = Int32(positionMilliseconds)
        }
        func setSpeed(_ speed: Float, commandID: UUID) throws { reading?.speed = speed; reading?.commandID = commandID }
        func unload() { reading = nil }
        func ready() { if let reading { onEvent?(.ready(reading)) } }
        func reset(after position: Int32) throws {
            reading?.sample.positionMilliseconds = position
            let final = try #require(reading)
            reading?.sample.positionMilliseconds = 0
            onEvent?(.timelineReset(final))
        }
    }

    private func withPlayer(_ operation: (FeedLibraryStore, PlaybackCoordinator, Engine, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        _ = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Live", episodes: (1...2).map {
            .init(identifier: "\($0)", title: "Episode \($0)", media: .init(url: "https://example.test/\($0).mp3", size: 0))
        }), source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        try await store.updateEpisode(id: 1) { $0.userState.playedDurationMilliseconds = 10_000 }
        let engine = Engine()
        let player = PlaybackCoordinator(store: store, engine: engine)
        do {
            try await player.select(episodeID: 1)
            engine.ready(); try await player.awaitPendingOperations()
            try await operation(store, player, engine, url)
            try await player.stop(); try await store.close()
        } catch { try? await player.stop(); try? await store.close(); throw error }
    }

    @Test(arguments: [false, true])
    func sourceResetPreservesOldPeriodThenAccumulatesNewPosition(pauseImmediately: Bool) async throws {
        try await withPlayer { store, player, engine, url in
            let session = try #require(try await store.playbackSession())
            try engine.reset(after: 3799)
            if pauseImmediately { try await player.pause() }
            try await player.awaitPendingOperations()
            #expect(try await store.episode(id: 1)?.userState.playedDurationMilliseconds == 13_799)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 0)
            #expect(try await store.playbackSession()?.id == session.id)
            #expect(try await store.playbackSession()?.playedDurationWhenStarted == 13_799)
            if pauseImmediately { #expect(player.phase == .paused && !player.wantsPlayback) }
            else { #expect(player.wantsPlayback) }
            engine.reading?.sample.positionMilliseconds = 1538
            try await player.pause()
            let saved = try #require(try await store.episode(id: 1))
            #expect(saved.userState.playedDurationMilliseconds == 15_337)
            #expect(saved.userState.positionMilliseconds == 1538 && saved.userState.playState != .played)
            #expect(try await store.queue().map(\.id) == [1])
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.episode(id: 1) == saved)
            #expect(try await reopened.playbackSession()?.playedDurationWhenStarted == 13_799)
            try await reopened.close()
        }
    }

    @Test func repeatedResetsAndZeroLengthPeriodDoNotDoubleCount() async throws {
        try await withPlayer { store, player, engine, _ in
            for position: Int32 in [3799, 0, 1538] {
                try engine.reset(after: position)
                try await player.awaitPendingOperations()
            }
            engine.reading?.sample.positionMilliseconds = 2000
            try await player.pause()
            #expect(try await store.episode(id: 1)?.userState.playedDurationMilliseconds == 17_337)
            #expect(try await store.playbackSession()?.playedDurationWhenStarted == 15_337)
        }
    }

    @Test func previousEpisodeResetCannotChangeReplacementSession() async throws {
        try await withPlayer { store, player, engine, _ in
            var stale = try #require(engine.reading)
            stale.sample.positionMilliseconds = 3799
            try await player.select(episodeID: 2)
            engine.ready(); try await player.awaitPendingOperations()
            let before = try await store.episode(id: 2), session = try await store.playbackSession()
            engine.onEvent?(.timelineReset(stale))
            try await player.awaitPendingOperations()
            #expect(try await store.episode(id: 2) == before)
            #expect(try await store.playbackSession() == session)
        }
    }
    @Test func resetSurvivesNewerPauseCommandWithoutRestoringPlayingIntent() async throws {
        try await withPlayer { store, player, engine, _ in
            var final = try #require(engine.reading)
            final.sample.positionMilliseconds = 3799
            try await player.pause()
            #expect(engine.reading?.commandID != final.commandID)
            engine.onEvent?(.timelineReset(final))
            try await player.awaitPendingOperations()
            #expect(player.phase == .paused && !player.wantsPlayback)
            #expect(player.sample?.status == .paused)
            #expect(try await store.playbackSession()?.status == .paused)
            #expect(try await store.episode(id: 1)?.userState.playedDurationMilliseconds == 13_799)
        }
    }

    @Test func nonzeroBaselineAndOrdinaryRewindKeepTheirExistingAccountingRules() async throws {
        try await withPlayer { store, player, _, _ in
            try await player.stop()
            let session = try await store.beginPlayback(episodeID: 1, positionMilliseconds: 1000)
            let final = PlaybackSample(positionMilliseconds: 4799, durationMilliseconds: -1, seekable: false, status: .playing)
            let result = try #require(try await store.recordPlaybackTimelineReset(sessionID: session.id, finalSample: final))
            #expect(result.episode.userState.playedDurationMilliseconds == 13_799)
            #expect(result.session.id == session.id && result.session.startPositionMilliseconds == 0)
            for (position, total): (Int32, Int64) in [(2000, 15_799), (1000, 14_799), (0, 14_799)] {
                let sample = PlaybackSample(positionMilliseconds: position, durationMilliseconds: -1, seekable: false, status: .paused)
                #expect(try await store.recordPlayback(sessionID: session.id, sample: sample)?.userState.playedDurationMilliseconds == total)
            }
        }
    }

    @Test func failedBaselineWriteRollsBackEpisodeAndStopsEngine() async throws {
        try await withPlayer { store, player, engine, url in
            let before = try await store.episode(id: 1), session = try await store.playbackSession()
            let effects = try await store.pendingEffects(), queue = try await store.queue()
            let connection = try LibrarySQLite(url: url)
            try connection.execute("CREATE TRIGGER fail_reset BEFORE UPDATE ON playback_session BEGIN SELECT RAISE(ABORT, 'test reset failure'); END")
            try engine.reset(after: 3799)
            try await player.awaitPendingOperations()
            #expect(player.phase == .failed && !player.wantsPlayback && engine.reading == nil)
            #expect(try await store.episode(id: 1) == before)
            #expect(try await store.playbackSession() == session)
            #expect(try await store.pendingEffects() == effects)
            #expect(try await store.queue() == queue)
            try connection.execute("DROP TRIGGER fail_reset")
            try connection.close()
        }
    }

    @Test func overflowAndCancellationCannotPartiallySettleOrRebase() async throws {
        try await withPlayer { store, player, _, _ in
            try await player.stop()
            try await store.updateEpisode(id: 1) { $0.userState.playedDurationMilliseconds = Int64.max }
            let session = try await store.beginPlayback(episodeID: 1, positionMilliseconds: 0)
            let before = try await store.episode(id: 1)
            let sample = PlaybackSample(positionMilliseconds: 1, durationMilliseconds: -1, status: .playing)
            await #expect(throws: FeedLibraryError.invalidMutation) {
                try await store.recordPlaybackTimelineReset(sessionID: session.id, finalSample: sample)
            }
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await store.recordPlaybackTimelineReset(sessionID: session.id, finalSample: sample)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.episode(id: 1) == before)
            #expect(try await store.playbackSession() == session)
            #expect(try await store.recordPlaybackTimelineReset(sessionID: UUID(), finalSample: sample) == nil)
        }
    }

}
