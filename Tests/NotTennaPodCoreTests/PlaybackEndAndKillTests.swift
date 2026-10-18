import Foundation
import Testing
@testable import NotTennaPodCore

/// The playback-end and process-kill journeys on the real store and coordinator with a scripted engine and
/// clock, so the Android rules are checked exactly and quickly; `PlaybackEndJourneyTests` (UI) runs the same
/// journeys through the app with real audio. Android 3.12.1 sources:
/// - `Media3PlaybackService.setupPositionObserver`: a 1-second observer saves the position when
///   `POSITION_SAVE_INTERVAL_MS` (5000) has passed since the last save; nothing is saved when the process dies.
/// - `PlayableUtils.saveCurrentPosition` stamps the history date with every save, and saves happen only while
///   playing (`onPlaybackStateChanged` STATE_READY with play-when-ready, `onIsPlayingChanged`, the observer).
/// - `Media3PlaybackService.startNextInQueue`: the finished episode is completed in the database and the queue
///   item after it is loaded with `setPlayWhenReady(isFollowQueue())`; with none, no media remains selected.
@Suite @MainActor
struct PlaybackEndAndKillTests {
    private final class Clock {
        var milliseconds: Int64 = 1_700_000_000_000
        var date: Date { Date(timeIntervalSince1970: Double(milliseconds) / 1_000) }
    }

    /// Reports what a real engine reports: readiness, one position a second while playing, the natural end.
    private final class Engine: PlaybackEngine {
        var reading: PlaybackEngineReading?
        var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
        private(set) var loads: [(episode: Int64, position: Int64)] = []
        private var generation: UUID?, commandID: UUID?, start: Int64 = 0, playing = false
        let duration: Int32 = 20_000

        func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
            self.generation = generation; commandID = generation
            start = positionMilliseconds; reading = nil; playing = false
            loads.append((episode.id, positionMilliseconds))
        }
        func play(commandID: UUID) { command(commandID); playing = true; reading?.sample.status = .playing }
        func pause(commandID: UUID) { command(commandID); playing = false; reading?.sample.status = .paused }
        func seek(to positionMilliseconds: Int64, commandID: UUID) {
            command(commandID); reading?.sample.positionMilliseconds = Int32(positionMilliseconds)
        }
        func setSpeed(_ speed: Float, commandID: UUID) throws { command(commandID) }
        func unload() { reading = nil; generation = nil; commandID = nil; playing = false }
        private func command(_ id: UUID) { commandID = id; reading?.commandID = id }

        var isPlaying: Bool { playing && reading != nil }
        func ready() {
            guard let generation, let commandID else { return }
            let value = PlaybackEngineReading(generation: generation, commandID: commandID, sample: .init(
                positionMilliseconds: Int32(start), durationMilliseconds: duration, status: playing ? .playing : .paused))
            reading = value
            onEvent?(.ready(value))
        }
        func tick(_ clock: Clock) {
            guard playing, var value = reading else { return }
            clock.milliseconds += 1_000
            value.sample.positionMilliseconds = min(duration, value.sample.positionMilliseconds + 1_000)
            reading = value
            onEvent?(.position(value))
        }
        func end() {
            guard var value = reading else { return }
            value.sample.positionMilliseconds = duration; value.sample.status = .other
            reading = value
            onEvent?(.ended(value))
        }
    }

    private struct Library {
        let directory: URL
        var url: URL { directory.appendingPathComponent("library.sqlite") }
    }

    private func withLibrary(_ operation: (Library, FeedLibraryStore) async throws -> Void) async throws {
        let library = Library(directory: FileManager.default.temporaryDirectory.appendingPathComponent("EndAndKill-\(UUID())"))
        try FileManager.default.createDirectory(at: library.directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: library.directory) }
        let store = try FeedLibraryStore(url: library.url)
        let episodes = ["A", "B", "C"].map { (letter: String) in
            ParsedEpisode(identifier: letter, title: "Episode " + letter,
                          media: ParsedMedia(url: "https://example.test/\(letter).mp3", size: 0, durationMilliseconds: 20_000))
        }
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "End lab", episodes: episodes),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
            validator: nil, permanentRedirectURL: nil))
        do { try await operation(library, store); try await store.close() }
        catch { try? await store.close(); throw error }
    }

    private func id(_ store: FeedLibraryStore, _ title: String) async throws -> Int64 {
        let episodes = try await store.snapshot().feeds.flatMap(\.episodes)
        return try #require(episodes.first { $0.details.title == title }?.id)
    }

    private func history(_ store: FeedLibraryStore) async throws -> [String] {
        EpisodeListQueries.history(try await store.snapshot().feeds).compactMap(\.episode.details.title)
    }

    private func settle(_ player: PlaybackCoordinator) async throws {
        try await player.awaitPendingOperations()
        await player.awaitPendingCompletionEffects()
    }

    /// Gap 2: Episode A ends with Continuous playback on → B plays and, playing, is listed above A; B ends with it
    /// off → C is loaded paused and stays out of the history; C ends → nothing remains selected. A reopened
    /// library shows the same state.
    @Test func naturalEndsFollowTheQueueRecordHistoryAndSurviveReopening() async throws {
        try await withLibrary { library, store in
            let (a, b, c) = (try await id(store, "Episode A"), try await id(store, "Episode B"), try await id(store, "Episode C"))
            _ = try await store.enqueue([a, b, c])
            var follow = true
            let clock = Clock(), engine = Engine()
            let player = PlaybackCoordinator(store: store, engine: engine, preferences: { _ in
                var preferences = PlaybackPreferences(); preferences.followQueue = follow; return preferences
            }, clock: { clock.date })

            try await player.select(episodeID: a); engine.ready(); try await settle(player)
            for _ in 0..<5 { engine.tick(clock) }
            clock.milliseconds += 500; engine.end(); try await settle(player)
            #expect(player.episode?.id == b && player.wantsPlayback, "Continuous playback starts B")
            #expect(try await store.episode(id: a)?.userState.playState == .played)
            #expect(try await store.episode(id: a)?.userState.positionMilliseconds == 0)
            #expect(try await store.queue().map(\.id) == [b, c])
            #expect(try await history(store) == ["Episode A"], "B is not listed before it plays")
            clock.milliseconds += 300; engine.ready(); try await settle(player)
            #expect(try await history(store) == ["Episode B", "Episode A"], "playing B saves, which stamps its history date")

            follow = false
            for _ in 0..<3 { engine.tick(clock) }
            clock.milliseconds += 500; engine.end(); try await settle(player)
            #expect(player.episode?.id == c && !player.wantsPlayback, "C is loaded but not started")
            #expect(engine.loads.last?.episode == c && engine.loads.last?.position == 0)
            engine.ready(); try await settle(player)
            #expect(player.phase == .paused && !engine.isPlaying)
            #expect(try await store.queue().map(\.id) == [c])
            #expect(try await history(store) == ["Episode B", "Episode A"], "a paused follower is not in the history")

            // Reopened (relaunch): C is still selected and paused at its start.
            let reopened = try FeedLibraryStore(url: library.url)
            let restored = PlaybackCoordinator(store: reopened, engine: Engine(), clock: { clock.date })
            try await restored.restore()
            #expect(restored.episode?.id == c && restored.phase == .stopped && restored.sample?.positionMilliseconds == 0)
            try await reopened.close()

            try await player.play(); try await settle(player)
            for _ in 0..<2 { engine.tick(clock) }
            clock.milliseconds += 500; engine.end(); try await settle(player)
            #expect(player.episode == nil && player.phase == .idle, "nothing follows the last queue episode")
            #expect(try await store.queue().isEmpty)
            #expect(try await history(store) == ["Episode C", "Episode B", "Episode A"])
            for episode in [a, b, c] { #expect(try await store.episode(id: episode)?.userState.playState == .played) }

            let final = try FeedLibraryStore(url: library.url)
            let relaunched = PlaybackCoordinator(store: final, engine: Engine(), clock: { clock.date })
            try await relaunched.restore()
            #expect(relaunched.episode == nil)
            #expect(try await history(final) == ["Episode C", "Episode B", "Episode A"])
            #expect(try await final.queue().isEmpty)
            try await final.close()
            try await player.stop()
        }
    }

    /// Gap 7: whenever the process dies while playing, the reopened library restores the last 5-second save:
    /// never ahead of what was heard and less than 6 s behind it, paused, and Play continues from there.
    @Test(arguments: 10...15)
    func terminationWhilePlayingRestoresWithinFiveSecondsAndResumesThere(heardSeconds: Int) async throws {
        try await withLibrary { library, store in
            let a = try await id(store, "Episode A")
            let clock = Clock(), engine = Engine()
            let player = PlaybackCoordinator(store: store, engine: engine, clock: { clock.date })
            try await player.select(episodeID: a); engine.ready(); try await settle(player)
            for _ in 0..<heardSeconds { engine.tick(clock) }
            try await settle(player)
            let heard = Int64(heardSeconds) * 1_000
            #expect(player.sample.map { Int64($0.positionMilliseconds) } == heard)
            // Killed: no pause, stop or completion runs. A second owner opens the same database.
            let reopened = try FeedLibraryStore(url: library.url)
            let nextEngine = Engine()
            let restored = PlaybackCoordinator(store: reopened, engine: nextEngine, clock: { clock.date })
            clock.milliseconds += 2_000
            try await restored.restore()
            let saved = Int64(try #require(restored.sample?.positionMilliseconds))
            #expect(saved <= heard && heard - saved < 6_000, "heard \(heard) ms, restored \(saved) ms")
            #expect(saved >= 5_000, "at least one periodic save happened")
            #expect(restored.episode?.id == a && restored.phase == .stopped && !restored.wantsPlayback,
                    "restored paused, not playing")
            #expect(nextEngine.loads.isEmpty)
            try await restored.play(); try await settle(restored)
            // Within a minute of the last save Android rewinds only MINIMUM_REWIND, 800 ms (RewindAfterPauseUtils).
            #expect(nextEngine.loads.first?.position == saved - 800)
            try await restored.stop()
            try await reopened.close()
        }
    }
}
