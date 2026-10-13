import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ApplicationPlaybackEngineTests {
    @MainActor final class Gate {
        var waiting = false
        private var continuation: CheckedContinuation<Void, Never>?
        func hold() async { await withCheckedContinuation { waiting = true; continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
    class Native: PlaybackVolumeControlling {
        var reading: PlaybackEngineReading?
        var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
        var loaded = 0, unloaded = 0, positions: [Int64] = [], speeds: [Float] = []
        var commands: [UUID] = [], playing = false
        var volume: FeedVolumeAdaptation = .off
        var sleepVolume: Float = 1
        func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
            loaded += 1; positions.append(positionMilliseconds)
            reading = .init(generation: generation, sample: .init(positionMilliseconds: Int32(positionMilliseconds), durationMilliseconds: 30000, status: .paused))
            onEvent?(.ready(reading!))
        }
        func play(commandID: UUID) { commands.append(commandID); playing = true }
        func pause(commandID: UUID) { commands.append(commandID); playing = false }
        func seek(to positionMilliseconds: Int64, commandID: UUID) { positions.append(positionMilliseconds); commands.append(commandID) }
        func setSpeed(_ speed: Float, commandID: UUID) throws { speeds.append(speed); commands.append(commandID) }
        func setVolumeAdaptation(_ setting: FeedVolumeAdaptation) throws { volume = setting }
        func setSleepTimerVolume(_ volume: Float) throws { sleepVolume = volume }
        func unload() { unloaded += 1; playing = false; reading = nil }
    }
    final class Processed: Native, PlaybackSilenceControlling, PlaybackStatisticsConsumer {
        var silence = false, boundAtLoad = false
        var statistics: (@MainActor (UUID) -> Int64)?
        func bindStatistics(lastPlayed: @escaping @MainActor (UUID) -> Int64, synchronize: @escaping @MainActor (UUID) async throws -> Void) { statistics = lastPlayed }
        func setSkipSilence(_ enabled: Bool, commandID: UUID) { silence = enabled; commands.append(commandID) }
        override func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
            boundAtLoad = statistics != nil
            super.load(episode: episode, generation: generation, positionMilliseconds: positionMilliseconds)
        }
    }
    private func withEpisode(_ body: (FeedLibraryStore, LibraryEpisode, URL) async throws -> Void) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("app-routing-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Routing", episodes: [
            ParsedEpisode(identifier: "1", title: "Episode", media: ParsedMedia(url: "https://example.test/media", size: 0, durationMilliseconds: 30000))]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        let episode = try #require(try await store.episode(id: 1))
        do { try await body(store, episode, root) }
        catch { try? await store.close(); throw error }
        try await store.close()
    }
    private func wait(_ check: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !check(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(check())
    }

    @Test func delayedSelectionRetainsLatestCommandsAndBindsStatisticsBeforeLoad() async throws {
        try await withEpisode { _, episode, _ in
            let gate = Gate(), backend = Processed()
            var captured = 0
            let engine = ApplicationPlaybackEngine { _ in captured += 1; return { await gate.hold(); return backend } }
            defer { engine.unload(); gate.release() }
            engine.bindStatistics(lastPlayed: { _ in 9123 }, synchronize: { _ in })
            let generation = UUID(), first = UUID(), latest = UUID()
            engine.load(episode: episode, generation: generation, positionMilliseconds: 123)
            #expect(captured == 1 && backend.loaded == 0)
            engine.play(commandID: first); engine.seek(to: 7500, commandID: first)
            try engine.setSpeed(1.5, commandID: first); engine.setSkipSilence(true, commandID: first)
            try engine.setVolumeAdaptation(.heavyBoost); engine.pause(commandID: latest)
            try engine.setSleepTimerVolume(0.3)
            try await wait { gate.waiting }; gate.release()
            try await wait { backend.loaded == 1 }
            // Controls used while the episode was still loading all take
            // effect once it is ready: latest seek, speed, skip-silence,
            // volume boost, sleep-timer fade and the final pause.
            #expect(backend.positions == [7500] && backend.speeds == [1.5] && !backend.playing)
            #expect(backend.volume == .heavyBoost && backend.silence)
            #expect(backend.sleepVolume == 0.3)
            try engine.setSleepTimerVolume(1)
            #expect(backend.sleepVolume == 1 && backend.volume == .heavyBoost)
            #expect(backend.statistics?(UUID()) == 9123)
            engine.play(commandID: first); #expect(backend.playing)
            engine.seek(to: 8000, commandID: latest); #expect(backend.positions == [7500, 8000])
            #expect(throws: PlaybackSpeedError.invalidSpeed) { try engine.setSpeed(.nan, commandID: latest) }
            #expect(backend.speeds == [1.5])
        }
    }

    @Test func replacementRetiresLateResolutionAndIgnoresOldEvents() async throws {
        try await withEpisode { _, episode, _ in
            let oldGate = Gate(), old = Processed(), current = Processed()
            var count = 0, ready: [UUID] = []
            let engine = ApplicationPlaybackEngine { _ in
                count += 1
                if count == 1 { return { await oldGate.hold(); return old } }
                return { current }
            }
            defer { engine.unload(); oldGate.release() }
            engine.onEvent = { if case let .ready(reading) = $0 { ready.append(reading.generation) } }
            engine.load(episode: episode, generation: UUID(), positionMilliseconds: 100)
            try await wait { oldGate.waiting }
            let generation = UUID()
            engine.load(episode: episode, generation: generation, positionMilliseconds: 900)
            engine.play(commandID: generation)
            try await wait { current.loaded == 1 }
            oldGate.release(); try await wait { old.unloaded == 1 }
            #expect(old.loaded == 0 && ready == [generation] && current.playing)
            let late = current.onEvent, reading = try #require(current.reading)
            engine.unload(); late?(.ready(reading))
            #expect(current.unloaded == 1 && !current.playing && ready == [generation] && engine.reading == nil)
        }
    }

    /// An item only AVPlayer can play does not skip silence, but neither
    /// a saved setting nor turning it on stops that item; the setting is kept for the next item.
    @Test(arguments: [false, true])
    func nativeFallbackPlaysWithoutSkippingAndKeepsSilencePreference(savedBeforeLoad: Bool) async throws {
        try await withEpisode { store, _, root in
            let native = Native(), settings = try PlaybackSpeedPreferenceStore(file: root.appendingPathComponent("speed.json"))
            if savedBeforeLoad { try settings.setGlobalSkipSilence(true) }
            let engine = ApplicationPlaybackEngine { _ in { native } }
            let player = PlaybackCoordinator(store: store, engine: RoutedPlaybackEngine(local: engine), speedPreferences: settings)
            defer { engine.unload() }
            try await player.select(episodeID: 1, play: true)
            try await wait { native.loaded == 1 && native.playing }
            #expect(!engine.supportsSkipSilence && engine.retainsSkipSilencePreference)
            #expect(player.skipSilence == savedBeforeLoad && player.phase != .failed)
            try await player.setSkipSilence(true, alsoGlobal: true)
            #expect(settings.value.silence.global && player.skipSilence && engine.reading?.skipSilence == true)
            #expect(native.playing && native.unloaded == 0 && player.phase != .failed)
            // The item never received the silence command; its later readings still reach the player.
            let reading = try #require(native.reading)
            native.reading?.sample.positionMilliseconds = 4_321
            native.reading?.commandID = try #require(native.commands.last)
            native.onEvent?(.position(try #require(native.reading)))
            try await wait { player.sample?.positionMilliseconds == 4_321 }
            #expect(reading.skipSilence == false && player.skipSilence)
        }
    }
}
