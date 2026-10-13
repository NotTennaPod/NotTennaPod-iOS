import Foundation
import Testing
@testable import NotTennaPodCore

private final class PlaybackCoordinatorTestBundleMarker {}
@Suite(.timeLimit(.minutes(1))) @MainActor
struct PlaybackCoordinatorTests {
    private final class Clock {
        /// Wall time. Changing it is time passing, which monotonic time follows; `correctWallClock` is not.
        var milliseconds: Int64 = 1_700_000_000_000 { didSet { monotonic += milliseconds - oldValue } }
        private(set) var monotonic: Int64 = 0
        var date: Date { Date(timeIntervalSince1970: Double(milliseconds) / 1_000) }
        /// The system corrects its wall clock (network time, a manual change); no time passes.
        func correctWallClock(by delta: Int64) { let kept = monotonic; milliseconds += delta; monotonic = kept }
    }

    private final class Engine: PlaybackSilenceControlling, PlaybackVolumeControlling {
        enum Command: Equatable { case load(Int64, Int64), play, pause, seek(Int64), unload }
        var reading: PlaybackEngineReading?
        var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
        var commands: [Command] = []
        var generation: UUID?
        var commandID: UUID?
        var initialPosition: Int64 = 0
        var emitTransitions = false
        var speed: Float = 1
        var speedChanges: [Float] = []
        var skipSilence = false
        var wantsPlayback = false
        var volume: FeedVolumeAdaptation = .off
        var volumeChanges: [FeedVolumeAdaptation] = []
        var timerVolume: Float = 1
        /// Pauses and sleep-timer volumes in the order the engine received them.
        var outputLog: [String] = []
        func setSleepTimerVolume(_ volume: Float) { timerVolume = volume; outputLog.append("volume \(volume)") }
        func setVolumeAdaptation(_ setting: FeedVolumeAdaptation) { volume = setting; volumeChanges.append(setting) }

        func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
            self.generation = generation
            commandID = generation
            initialPosition = positionMilliseconds
            reading = nil
            wantsPlayback = false
            commands.append(.load(episode.id, positionMilliseconds))
        }
        func play(commandID: UUID) {
            wantsPlayback = true
            self.commandID = commandID
            reading?.commandID = commandID
            reading?.sample.status = .playing
            commands.append(.play)
            if emitTransitions, let reading { onEvent?(.stateChanged(reading)) }
        }
        func pause(commandID: UUID) {
            wantsPlayback = false
            outputLog.append("pause")
            self.commandID = commandID
            reading?.commandID = commandID
            reading?.sample.status = .paused
            commands.append(.pause)
            if emitTransitions, let reading { onEvent?(.stateChanged(reading)) }
        }
        func seek(to positionMilliseconds: Int64, commandID: UUID) {
            self.commandID = commandID
            reading?.commandID = commandID
            reading?.sample.positionMilliseconds = Int32(truncatingIfNeeded: positionMilliseconds)
            commands.append(.seek(positionMilliseconds))
        }
        func unload() {
            commands.append(.unload)
            reading = nil
            generation = nil
            commandID = nil
            speed = 1
            volume = .off
            timerVolume = 1
            skipSilence = false
            wantsPlayback = false
        }
        func setSpeed(_ speed: Float, commandID: UUID) throws {
            self.commandID = commandID
            self.speed = speed
            speedChanges.append(speed)
            reading?.speed = speed
            reading?.commandID = commandID
            if emitTransitions, let reading { onEvent?(.stateChanged(reading)) }
        }
        func ready() {
            guard let generation, let commandID else { return }
            let value = PlaybackEngineReading(generation: generation, commandID: commandID,
                sample: .init(positionMilliseconds: Int32(truncatingIfNeeded: initialPosition),
                              durationMilliseconds: 100_000, status: wantsPlayback ? .playing : .paused), speed: speed, skipSilence: skipSilence)
            reading = value
            onEvent?(.ready(value))
        }
        func setSkipSilence(_ enabled: Bool, commandID: UUID) {
            self.commandID = commandID
            skipSilence = enabled
            reading?.skipSilence = enabled
            reading?.commandID = commandID
            if emitTransitions, let reading { onEvent?(.stateChanged(reading)) }
        }
        func position(_ position: Int32, duration: Int32 = 100_000) {
            guard var value = reading else { return }
            value.sample.positionMilliseconds = position
            value.sample.durationMilliseconds = duration
            reading = value
            onEvent?(.position(value))
        }
        func state(_ status: LibraryPlaybackSession.Status, buffering: Bool = false) {
            guard var value = reading else { return }
            value.sample.status = status
            value.buffering = buffering
            reading = value
            onEvent?(.stateChanged(value))
        }
        func end(_ position: Int32 = 100_000) {
            guard var value = reading else { return }
            value.sample.positionMilliseconds = position
            value.sample.status = .other
            reading = value
            onEvent?(.ended(value))
        }
    }

    @Test func deletedFeedRetiresPlaybackAndRejectsLateEngineEvents() async throws {
        try await withPlayer { store, player, engine, _, _ in
            try await player.select(episodeID: 1)
            engine.ready(); try await player.awaitPendingOperations()
            let oldReading = try #require(engine.reading)
            let feed = try #require(try await store.feeds().first)
            _ = try await store.requestFeedDeletion(feedID: feed.id)
            try await player.retireDeletedEpisodes(Set(feed.episodes.map(\.id)))
            #expect(player.episode == nil && player.phase == .idle && !player.wantsPlayback)
            #expect(engine.commands.last == .unload)
            engine.onEvent?(.stateChanged(oldReading))
            try await player.awaitPendingOperations()
            #expect(try await store.playbackSession() == nil)
            #expect(try await store.episode(id: 1) == nil)
        }
    }

    @Test func positionWritesDoNotMasqueradeAsQueueItemChanges() async throws {
        try await withPlayer { store, player, engine, clock, _ in
            try await start(player, engine)
            var events = player.events().makeAsyncIterator()
            clock.milliseconds += 5_000
            engine.position(12_000); try await player.awaitPendingOperations()
            // A periodic position save must not be published as a library (queue/list) change;
            // the relative order of the other notifications is not asserted.
            var sawSave = false, sawLibrary = false
            collect: while let event = await events.next() {
                switch event {
                case .libraryChanged: sawLibrary = true
                case .positionSaved: sawSave = true
                case .stateChanged where sawSave: break collect
                default: break
                }
            }
            #expect(sawSave && !sawLibrary)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 12_000)
        }
    }

    @Test func positionEventsValidateGenerationCommandsAndPausedSeekWithoutPublishingRepaints() async throws {
        try await withPlayer { _, player, engine, _, _ in
            var events = player.events().makeAsyncIterator()
            // Stop at each known state barrier; unexpected position events remain
            // observable rather than being discarded by a filtering collector.
            func drainToState(count: Int = 1) async -> [PlaybackPositionUpdate] {
                var updates: [PlaybackPositionUpdate] = []
                var remaining = count
                while let event = await events.next() {
                    switch event {
                    case .positionChanged(let update): updates.append(update)
                    case .stateChanged:
                        remaining -= 1
                        if remaining == 0 { return updates }
                    default: break
                    }
                }
                return updates
            }
            #expect(await drainToState().isEmpty)
            try await player.select(episodeID: 1)
            #expect(await drainToState().isEmpty)
            engine.ready(); try await player.awaitPendingOperations()
            #expect(await drainToState().isEmpty) // readiness/save is not a position transition
            engine.position(12_345, duration: 120_000); try await player.awaitPendingOperations()
            // The event is still buffered in this real AsyncStream. A data rebind
            // now captures the baseline without changing playback/command identity.
            let bindingRevision = player.positionRevision
            let first = try #require(await drainToState().first)
            #expect(first.episodeID == 1 && first.positionMilliseconds == 12_345 && first.durationMilliseconds == 120_000)
            #expect(player.isCurrent(first))
            #expect(first.revision == bindingRevision)
            #expect(!player.isCurrent(first, after: bindingRevision))
            engine.position(15_000, duration: 120_000); try await player.awaitPendingOperations()
            let subsequent = try #require(await drainToState().first)
            #expect(subsequent.generation == first.generation && subsequent.commandID == first.commandID)
            #expect(subsequent.revision > bindingRevision && player.isCurrent(subsequent, after: bindingRevision))
            let oldReading = try #require(engine.reading)
            try await player.setSpeed(1.5)
            #expect(await drainToState().isEmpty)
            #expect(!player.isCurrent(first))
            engine.onEvent?(.position(oldReading)); try await player.awaitPendingOperations()
            // Rejected input emits nothing. A deliberate state command is a fence.
            try await player.setSpeed(1.25)
            #expect(await drainToState().isEmpty)
            try await player.pause()
            #expect(await drainToState().isEmpty)
            try await player.seek(to: 90_000)
            let seek = try #require(await drainToState().first)
            #expect(seek.positionMilliseconds == 90_000 && seek.episodeID == 1 && player.isCurrent(seek))
            #expect(!player.wantsPlayback)
            let retired = try #require(engine.reading)
            try await player.select(episodeID: 2, play: false)
            #expect(await drainToState(count: 2).isEmpty)
            engine.ready(); try await player.awaitPendingOperations()
            #expect(await drainToState().isEmpty)
            try await player.select(episodeID: 1)
            #expect(await drainToState(count: 2).isEmpty)
            engine.ready(); try await player.awaitPendingOperations()
            #expect(await drainToState().isEmpty)
            #expect(!player.isCurrent(seek))
            engine.onEvent?(.position(retired)); try await player.awaitPendingOperations()
            engine.position(42_000); try await player.awaitPendingOperations()
            let current = await drainToState()
            #expect(current.count == 1)
            let update = try #require(current.first)
            #expect(update.episodeID == 1 && update.positionMilliseconds == 42_000)
            #expect(update.generation != seek.generation && player.isCurrent(update))
            engine.onEvent?(.timelineReset(try #require(engine.reading)))
            try await player.awaitPendingOperations()
            let reset = try #require(await drainToState().first)
            #expect(reset.positionMilliseconds == 0 && reset.generation == update.generation)
        }
    }

    @Test func resolvedSpeedLoadsBeforeReadyAndChangesWhilePausedWithoutStarting() async throws {
        try await withPlayer(preferences: { episode in
            var prefs = PlaybackPreferences()
            prefs.speed = episode.id == 1 ? 1.5 : 0.75
            return prefs
        }) { _, player, engine, _, _ in
            try await player.select(episodeID: 1, play: false)
            #expect(player.speed == 1.5 && engine.speedChanges == [1.5])
            try await player.setSpeed(2)
            #expect(player.phase == .preparing && !player.wantsPlayback)
            engine.ready()
            try await player.awaitPendingOperations()
            #expect(player.phase == .paused && player.speed == 2)
            let position = player.sample?.positionMilliseconds
            engine.emitTransitions = true
            try await player.setSpeed(0.5)
            try await player.awaitPendingOperations()
            #expect(player.speed == 0.5 && player.phase == .paused && !player.wantsPlayback)
            #expect(player.sample?.positionMilliseconds == position)
            #expect(!engine.commands.contains(.play))
            try await player.select(episodeID: 2, play: false)
            #expect(player.speed == 0.75 && engine.speedChanges.last == 0.75)
        }
    }

    @Test func speedChangePreservesPlayingIntentAndRejectsOldCommandReadings() async throws {
        try await withPlayer { _, player, engine, _, _ in
            try await player.select(episodeID: 1)
            engine.ready()
            try await player.awaitPendingOperations()
            engine.emitTransitions = true
            let stale = try #require(engine.reading)
            try await player.setSpeed(1.5)
            try await player.awaitPendingOperations()
            #expect(player.wantsPlayback && player.phase == .playing && player.speed == 1.5)
            engine.onEvent?(.stateChanged(stale))
            try await player.awaitPendingOperations()
            #expect(player.speed == 1.5)
            try await player.pause()
            try await player.play()
            #expect(player.speed == 1.5 && player.wantsPlayback)
        }
    }

    @Test func invalidRateDoesNotInterruptCurrentMediaOrChangeItsCommandIdentity() async throws {
        try await withPlayer(preferences: { episode in
            var prefs = PlaybackPreferences(); prefs.speed = episode.id == 2 ? 0 : 1; return prefs
        }) { _, player, engine, _, _ in
            try await player.select(episodeID: 1)
            engine.ready()
            try await player.awaitPendingOperations()
            let commandID = engine.commandID
            let commands = engine.commands
            for rate: Float in [0, -1, .infinity, -.infinity, .nan] {
                await #expect(throws: PlaybackSpeedError.invalidSpeed) { try await player.setSpeed(rate) }
            }
            await #expect(throws: PlaybackSpeedError.invalidSpeed) { try await player.select(episodeID: 2) }
            #expect(engine.commands == commands && engine.commandID == commandID)
            #expect(player.episode?.id == 1 && player.wantsPlayback && player.speed == 1)
        }
    }

    @Test func persistentSpeedSelectionResolvesNewEpisodeBeforeReplacingCurrentIdentity() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Speeds-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let settings = try PlaybackSpeedPreferenceStore(file: file)
        try settings.setGlobal(1.25)
        try await withPlayer(speedPreferences: settings) { store, player, engine, _, _ in
            let feedID = try await store.feedID(forEpisode: 1)
            try settings.setFeed(feedID, speed: 0.75)
            try await player.select(episodeID: 1, play: false)
            engine.ready(); try await player.awaitPendingOperations()
            #expect(player.speed == 0.75 && settings.value.currentEpisodeID == 1)
            try await player.setSpeed(1.5, alsoGlobal: true)
            #expect(settings.value.global == 1.5 && settings.value.feeds[feedID] == 0.75)
            try settings.setFeed(feedID, speed: 2)
            #expect(player.speed == 1.5) // A feed default does not replace the current temporary value.
            try await player.select(episodeID: 2, play: false)
            #expect(player.speed == 2 && settings.value.temporary == 2 && settings.value.currentEpisodeID == 2)
            engine.ready(); try await player.awaitPendingOperations()
            try await player.setSpeed(3)
            #expect(settings.value.global == 1.5 && settings.value.temporary == 3)
            let otherFeed = try await store.insert(FetchedFeed(
                feed: ParsedFeed(format: .rss, title: "Other feed", episodes: [ParsedEpisode(identifier: "other",
                    media: ParsedMedia(url: "https://example.test/other.mp3", size: 0, durationMilliseconds: 100_000))]),
                source: "https://example.test/other-feed", responseURL: URL(string: "https://example.test/other-feed")!,
                validator: nil, permanentRedirectURL: nil))
            let otherEpisode = try #require(otherFeed.episodes.first)
            #expect(try await store.feedID(forEpisode: otherEpisode.id) == otherFeed.id)
            try await player.select(episodeID: otherEpisode.id, play: false)
            #expect(player.speed == 1.5 && settings.value.currentEpisodeID == otherEpisode.id)
            try await player.select(episodeID: 1, play: false)
            #expect(player.speed == 2) // The old episode-specific value is not a permanent per-episode setting.
            await #expect(throws: FeedLibraryError.missingEpisode(-1)) { try await store.feedID(forEpisode: -1) }
        }
    }

    @Test func currentSpeedSurvivesRelaunchWithoutAutoplayAndTemporarySpeedDoesNotChangeGlobal() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Speeds-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let settings = try PlaybackSpeedPreferenceStore(file: file)
        try await withPlayer(speedPreferences: settings) { _, player, engine, _, databaseURL in
            try await player.select(episodeID: 1, play: false)
            engine.ready(); try await player.awaitPendingOperations()
            try await player.setSpeed(1.25, alsoGlobal: false)
            #expect(player.speed == 1.25 && settings.value.global == 1)
            try await player.setSpeed(1.5, alsoGlobal: false)
            #expect(player.speed == 1.5 && !player.wantsPlayback)
            try await player.stop()
            let restoredSettings = try PlaybackSpeedPreferenceStore(file: file)
            let restoredStore = try FeedLibraryStore(url: databaseURL)
            let restoredEngine = Engine()
            let restored = PlaybackCoordinator(store: restoredStore, engine: restoredEngine, speedPreferences: restoredSettings)
            try await restored.restore()
            #expect(restored.speed == 1.5 && restored.phase == .stopped && !restored.wantsPlayback)
            #expect(restoredEngine.commands.isEmpty)
            try await restored.play()
            restoredEngine.ready(); try await restored.awaitPendingOperations()
            #expect(restoredEngine.speed == 1.5 && restored.wantsPlayback)
            try await restored.setSpeed(1, alsoGlobal: false)
            #expect(restored.speed == 1 && restoredEngine.speed == 1 && restoredSettings.value.global == 1)
            try await restored.stop()
            try await restoredStore.close()
        }
    }

    @Test func endingWithoutSuccessorClearsSpeedIdentityButNormalStopRetainsIt() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Speeds-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let settings = try PlaybackSpeedPreferenceStore(file: file)
        try await withPlayer(speedPreferences: settings) { _, player, engine, _, _ in
            try await start(player, engine)
            try await player.setSpeed(2)
            try await player.stop()
            #expect(settings.value.currentEpisodeID == 1 && settings.value.temporary == 2)
            try await player.play()
            engine.ready(); try await player.awaitPendingOperations()
            engine.end(); try await player.awaitPendingOperations()
            #expect(player.episode == nil && settings.value.currentEpisodeID == nil)
            #expect(settings.value.temporary == 2 && settings.value.global == 1)
            #expect(settings.value.resolved(episodeID: 1, feedID: 1) == 1)
        }
    }

    @Test func speedPersistenceFailureDoesNotChangeTheEngineOrPublishedSpeed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Speeds-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("preferences.json")
        let settings = try PlaybackSpeedPreferenceStore(file: file)
        try await withPlayer(speedPreferences: settings) { _, player, engine, _, _ in
            try await start(player, engine)
            let saved = try Data(contentsOf: file)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            let command = engine.commandID
            await #expect(throws: (any Error).self) { try await player.setSpeed(2, alsoGlobal: true) }
            #expect(player.speed == 1 && engine.speed == 1 && engine.commandID == command)
            #expect(settings.value.global == 1 && settings.value.temporary == 1)
            #expect(player.wantsPlayback)
            try FileManager.default.removeItem(at: file)
            try saved.write(to: file)
        }
    }

    @Test func silenceResolvesBeforeIdentityChangesAndSurvivesStopAndRelaunch() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Silence-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let settings = try PlaybackSpeedPreferenceStore(file: file)
        try await withPlayer(speedPreferences: settings) { store, player, engine, _, databaseURL in
            let feed = try await store.feedID(forEpisode: 1)
            try settings.setFeed(feed, speed: 1.5, skipSilence: .aggressive)
            try await player.select(episodeID: 1, play: false)
            #expect(player.skipSilence && engine.skipSilence && settings.value.silence.temporary == .aggressive)
            try await player.setSkipSilence(false)
            engine.ready(); try await player.awaitPendingOperations()
            #expect(!player.skipSilence && !player.wantsPlayback && player.phase == .paused)
            try await player.select(episodeID: 2, play: false)
            engine.ready(); try await player.awaitPendingOperations()
            #expect(player.skipSilence && settings.value.currentEpisodeID == 2)
            try await player.setSkipSilence(false, alsoGlobal: true)
            try settings.setGlobalSkipSilence(true)
            try await player.stop()
            #expect(settings.value.currentEpisodeID == 2 && settings.value.silence.temporary == .off)
            let restoredSettings = try PlaybackSpeedPreferenceStore(file: file)
            let restoredStore = try FeedLibraryStore(url: databaseURL)
            let restoredEngine = Engine()
            let restored = PlaybackCoordinator(store: restoredStore, engine: restoredEngine, speedPreferences: restoredSettings)
            try await restored.restore()
            #expect(!restored.skipSilence && restored.phase == .stopped && restoredEngine.commands.isEmpty)
            try await restored.play()
            restoredEngine.ready(); try await restored.awaitPendingOperations()
            #expect(!restored.skipSilence && !restoredEngine.skipSilence && restored.wantsPlayback)
            try await restored.stop(); try await restoredStore.close()
        }
    }

    @Test func silenceChangesPreserveIntentPositionAndSpeedAndFenceOldEvents() async throws {
        try await withPlayer { _, player, engine, _, _ in
            try await start(player, engine)
            engine.emitTransitions = true
            engine.position(20000); try await player.awaitPendingOperations()
            try await player.setSpeed(2)
            let old = try #require(engine.reading)
            try await player.setSkipSilence(true)
            try await player.awaitPendingOperations()
            #expect(player.skipSilence && player.speed == 2 && player.wantsPlayback)
            #expect(player.sample?.positionMilliseconds == 20000)
            engine.onEvent?(.stateChanged(old)); try await player.awaitPendingOperations()
            #expect(player.skipSilence && player.speed == 2)
            try await player.pause()
            try await player.setSkipSilence(false)
            try await player.awaitPendingOperations()
            #expect(!player.skipSilence && player.phase == .paused && !player.wantsPlayback && player.speed == 2)
            #expect(player.sample?.positionMilliseconds == 20000)
        }
    }

    @Test func queueSuccessorResolvesSilenceAndFinalCompletionClearsOnlyIdentity() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Silence-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let settings = try PlaybackSpeedPreferenceStore(file: file)
        try await withPlayer(speedPreferences: settings) { store, player, engine, _, _ in
            _ = try await store.enqueue([1, 2])
            try await start(player, engine)
            try await player.setSkipSilence(true)
            engine.end(); try await player.awaitPendingOperations()
            #expect(player.episode?.id == 2 && !player.skipSilence && !engine.skipSilence)
            engine.ready(); try await player.awaitPendingOperations()
            try await player.setSkipSilence(true)
            engine.end(); try await player.awaitPendingOperations()
            #expect(player.episode == nil && settings.value.currentEpisodeID == nil)
            #expect(settings.value.silence.temporary == .aggressive && !settings.value.silence.global)
            #expect(!settings.value.resolvedSkipSilence(episodeID: 2, feedID: 1))
        }
    }

    @Test func silenceWriteFailureDoesNotReachEngineOrChangeCurrentCommand() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Silence-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let settings = try PlaybackSpeedPreferenceStore(file: file)
        try await withPlayer(speedPreferences: settings) { _, player, engine, _, _ in
            try await start(player, engine)
            let original = settings.value
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            let command = engine.commandID
            await #expect(throws: (any Error).self) { try await player.setSkipSilence(true, alsoGlobal: true) }
            #expect(!player.skipSilence && !engine.skipSilence && player.wantsPlayback)
            #expect(engine.commandID == command && settings.value == original)
        }
    }

    @Test func unsupportedEngineRejectsEnabledSilenceBeforeChangingPlaybackOrPreferences() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Silence-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let settings = try PlaybackSpeedPreferenceStore(file: file)
        try await withPlayer { store, _, _, _, _ in
            let engine = AVPlayerPlaybackEngine()
            let player = PlaybackCoordinator(store: store, engine: engine, speedPreferences: settings)
            await #expect(throws: PlaybackSilenceError.unsupportedEngine) {
                try await player.setSkipSilence(true, alsoGlobal: true)
            }
            #expect(settings.value == PlaybackSpeedPreferences() && player.phase == .idle)
            try settings.setGlobalSkipSilence(true)
            await #expect(throws: PlaybackSilenceError.unsupportedEngine) { try await player.select(episodeID: 1) }
            #expect(player.episode == nil && engine.reading == nil && settings.value.currentEpisodeID == nil)
            #expect(try await store.playbackSession() == nil)
        }
    }

    @MainActor private final class StreamingNetwork {
        var allowed = false
        var local: Set<Int64> = []
        var casting = false
        var failObservation = false
        func access(_ episode: LibraryEpisode) -> PlaybackStreamingAccess {
            .init(needsStreaming: !local.contains(episode.id), streamingAllowed: allowed, isCasting: casting)
        }
    }

    @Test func failedAccessObservationLeavesResumeIntactAndRetiredSwitchRecoverable() async throws {
        let network = StreamingNetwork()
        network.allowed = true
        try await withPlayer(streamingAccess: { item in
            if network.failObservation { throw CancellationError() }
            return network.access(item)
        }) { store, player, engine, _, _ in
            try await player.select(episodeID: 1)
            #expect(player.phase == .preparing)
            let previousCommands = engine.commands
            let previousGeneration = engine.generation
            network.failObservation = true
            // Selecting the current live episode routes to resume: failed
            // observation happens before any engine/state mutation on that path.
            await #expect(throws: CancellationError.self) { try await player.select(episodeID: 1) }
            #expect(player.phase == .preparing && player.wantsPlayback)
            #expect(engine.commands == previousCommands && engine.generation == previousGeneration)
            #expect(try await store.playbackSelectionEpisodeID() == 1)
            #expect(player.pendingStreamingEpisodeID == nil)
            await #expect(throws: CancellationError.self) { try await player.select(episodeID: 2) }
            #expect(try await store.queue().map(\.id) == [1])
            #expect(try await store.playbackSelectionEpisodeID() == 1)
            #expect(player.phase == .stopped && engine.generation == nil)
            network.failObservation = false
            try await player.select(episodeID: 2)
            engine.ready(); try await player.awaitPendingOperations()
            #expect(player.phase == .playing && player.episode?.id == 2)
            #expect(try await store.playbackSelectionEpisodeID() == 2)
        }
    }

    @Test func cancelledInitialAccessCannotCreatePendingConfirmationOrPlaybackState() async throws {
        try await withPlayer(streamingAccess: { _ in throw CancellationError() }) { store, player, engine, _, _ in
            await #expect(throws: CancellationError.self) { try await player.select(episodeID: 1) }
            #expect(player.phase == .idle && !player.wantsPlayback)
            #expect(player.pendingStreamingEpisodeID == nil && player.episode == nil && engine.generation == nil)
            let queue = try await store.queue()
            let selection = try await store.playbackSelectionEpisodeID()
            let session = try await store.playbackSession()
            #expect(queue.isEmpty && selection == nil && session == nil)
        }
    }

    @Test func blockedInitialStreamingDoesNotSelectEnqueueOrStartEngineUntilDirectPlay() async throws {
        let network = StreamingNetwork()
        try await withPlayer(streamingAccess: { network.access($0) }) { store, player, engine, _, _ in
            var events = player.events().makeAsyncIterator()
            _ = await events.next()
            try await player.select(episodeID: 1)
            guard case .streamingConfirmationRequired(let id)? = await events.next() else {
                Issue.record("Missing confirmation event"); return
            }
            #expect(id == 1)
            #expect(player.pendingStreamingEpisodeID == 1 && player.phase == .awaitingStreamingConfirmation)
            #expect(player.episode == nil && player.sample == nil && !player.wantsPlayback)
            #expect(try await store.queue().isEmpty)
            #expect(try await store.playbackSession() == nil)
            #expect(try await store.playbackSelectionEpisodeID() == nil)
            #expect(!engine.commands.contains(.load(1, 0)) && !engine.commands.contains(.play))
            // Cancel has no command. Mini/row selection reopens confirmation; direct service Play accepts.
            try await player.pause()
            try await player.skip()
            try await player.toggle(episodeID: 1)
            #expect(player.pendingStreamingEpisodeID == 1 && player.episode == nil)
            try await player.play()
            engine.ready()
            try await player.awaitPendingOperations()
            #expect(player.pendingStreamingEpisodeID == nil && player.episode?.id == 1 && player.wantsPlayback)
            #expect(try await store.queue().map(\.id) == [1])
            #expect(try await store.playbackSelectionEpisodeID() == 1)
            #expect(!network.allowed)
        }
    }

    @Test func delayedNativeAccessThenOnceAndAlwaysPreserveOriginalSelectionAndPermissionRules() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Mobile-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let preferences = try MobileNetworkPreferenceStore(file: file)
        let network = DownloadNetworkMonitor(startMonitoring: false)
        let provider = StreamingAccessProvider(preferences: preferences, network: network)
        try await withPlayer(streamingAccess: { try await provider.access(for: $0) }) { store, player, engine, _, _ in
            let selection = Task { try await player.select(episodeID: 1) }
            // Always release the first observation even if an assertion throws, so
            // the coordinator's queued cleanup can run.
            defer { network.update(.init(connected: false, metered: true, cellular: true)) }
            let deadline = ContinuousClock.now + .seconds(5)
            while network.pendingObservationCount == 0 && ContinuousClock.now < deadline { await Task.yield() }
            try #require(network.pendingObservationCount == 1)
            #expect(try await store.queue().isEmpty)
            #expect(try await store.playbackSelectionEpisodeID() == nil)
            #expect(try await store.playbackSession() == nil)
            #expect(player.episode == nil && player.pendingStreamingEpisodeID == nil)
            #expect(engine.generation == nil && !engine.commands.contains(.play))
            network.update(.init(connected: true, metered: true, cellular: true))
            try await selection.value
            #expect(player.pendingStreamingEpisodeID == 1)
            #expect(try await store.queue().isEmpty)

            try await player.play() // Once: no persistent preference mutation.
            engine.ready(); try await player.awaitPendingOperations()
            #expect(player.phase == .playing && player.episode?.id == 1)
            #expect(try await store.queue().map(\.id) == [1])
            #expect(try MobileNetworkPreferenceStore(file: file).allowed == ["images"])
            try await player.pause()
            try await player.toggle() // Starter/reselect warns again.
            #expect(player.phase == .awaitingStreamingConfirmation)
            #expect(try await store.playbackSelectionEpisodeID() == 1)

            try preferences.setAllowed(.streaming, true) // Always saves before Play.
            try await player.play()
            engine.ready(); try await player.awaitPendingOperations()
            #expect(player.phase == .playing && player.pendingStreamingEpisodeID == nil)
            #expect(try MobileNetworkPreferenceStore(file: file).allowed == ["images", "streaming"])
            try await player.pause()
            try await player.toggle()
            #expect(player.pendingStreamingEpisodeID == nil && player.wantsPlayback)

            // A later settings change must be read at the next explicit Play.
            try preferences.setAllowed(.streaming, false)
            try await player.play()
            #expect(player.phase == .awaitingStreamingConfirmation)
            #expect(try await store.queue().map(\.id) == [1])
        }
    }

    @Test func restrictedResumeKeepsSavedMiniPlayerAndRejectsRetiredEngineCallbacks() async throws {
        let network = StreamingNetwork()
        network.allowed = true
        try await withPlayer(streamingAccess: { network.access($0) }) { store, player, engine, _, _ in
            try await start(player, engine)
            engine.position(3130)
            try await player.pause()
            let oldReading = try #require(engine.reading)
            let stored = try await store.episode(id: 1)
            let session = try await store.playbackSession()
            network.allowed = false
            try await player.toggle()
            #expect(player.phase == .awaitingStreamingConfirmation && player.episode == stored)
            #expect(player.sample?.positionMilliseconds == 3130 && !player.wantsPlayback)
            #expect(try await store.playbackSession() == session)
            #expect(try await store.playbackSelectionEpisodeID() == 1)
            #expect(engine.reading == nil)
            engine.onEvent?(.ended(oldReading))
            engine.onEvent?(.failed(generation: oldReading.generation, message: "retired"))
            try await player.awaitPendingOperations()
            #expect(player.phase == .awaitingStreamingConfirmation && player.pendingStreamingEpisodeID == 1)
            #expect(try await store.episode(id: 1) == stored)
            // Mini Play reselects and warns again, while the visible saved episode stays intact.
            try await player.toggle()
            #expect(player.pendingStreamingEpisodeID == 1 && !player.wantsPlayback)
            try await player.play()
            engine.ready()
            try await player.awaitPendingOperations()
            #expect(player.phase == .playing && player.sample?.positionMilliseconds == 3130)
            #expect(try await store.queue().map(\.id) == [1])
        }
    }

    @Test func blockedReplacementRetainsSelectionAcrossRelaunchWithoutKeepingOldStatisticsOwner() async throws {
        let network = StreamingNetwork()
        network.local = [1]
        try await withPlayer(streamingAccess: { network.access($0) }) { store, player, engine, _, url in
            try await start(player, engine)
            engine.position(10_000)
            try await player.pause()
            try await player.select(episodeID: 2)
            #expect(player.pendingStreamingEpisodeID == 2 && player.episode?.id == 1)
            #expect(try await store.playbackSelectionEpisodeID() == 1)
            #expect(try await store.playbackSession() == nil)
            #expect(try await store.queue().map(\.id) == [1])
            let reopened = try FeedLibraryStore(url: url)
            let replacementEngine = Engine()
            let restored = PlaybackCoordinator(store: reopened, engine: replacementEngine, streamingAccess: { network.access($0) })
            try await restored.restore()
            #expect(restored.episode?.id == 1 && restored.sample?.positionMilliseconds == 10_000)
            #expect(restored.phase == .stopped && restored.pendingStreamingEpisodeID == nil)
            #expect(replacementEngine.commands.isEmpty)
            try await reopened.close()
            try await player.play()
            engine.ready()
            try await player.awaitPendingOperations()
            #expect(player.episode?.id == 2 && player.wantsPlayback)
            #expect(try await store.playbackSelectionEpisodeID() == 2)
            #expect(try await store.queue().map(\.id) == [1, 2])
        }
    }

    @Test(arguments: [false, true])
    func blockedQueueNextRetainsPreviousSelectionUntilConsentRegardlessOfFollowQueue(_ follow: Bool) async throws {
        let network = StreamingNetwork()
        network.local = [1]
        try await withPlayer(preferences: { _ in var p = PlaybackPreferences(); p.followQueue = follow; return p },
                             streamingAccess: { network.access($0) }) { store, player, engine, _, _ in
            _ = try await store.enqueue([1, 2])
            try await start(player, engine)
            engine.end()
            try await player.awaitPendingOperations()
            #expect(player.pendingStreamingEpisodeID == 2 && player.phase == .awaitingStreamingConfirmation)
            #expect(player.episode?.id == 1 && player.episode?.userState.playState == .played)
            #expect(try await store.playbackSelectionEpisodeID() == 1)
            #expect(try await store.playbackSession() == nil)
            #expect(try await store.queue().map(\.id) == [2])
            try await player.skip() // No current live episode while showing the confirmation item.
            #expect(try await store.queue().map(\.id) == [2])
            try await player.play()
            engine.ready()
            try await player.awaitPendingOperations()
            #expect(player.episode?.id == 2 && player.wantsPlayback)
        }
    }

    @Test func newSelectionReplacesPendingRequestAndPersistentPermissionAllowsFurtherLoads() async throws {
        let network = StreamingNetwork()
        network.local = [3]
        try await withPlayer(streamingAccess: { network.access($0) }) { store, player, engine, _, _ in
            try await player.select(episodeID: 1)
            try await player.select(episodeID: 2)
            #expect(player.pendingStreamingEpisodeID == 2 && player.episode == nil)
            try await player.select(episodeID: 3)
            engine.ready()
            try await player.awaitPendingOperations()
            #expect(player.pendingStreamingEpisodeID == nil && player.episode?.id == 3)
            network.allowed = true // The settings owner persists Always before calling service Play.
            try await player.select(episodeID: 2)
            engine.ready()
            try await player.awaitPendingOperations()
            try await player.pause()
            try await player.toggle()
            #expect(player.pendingStreamingEpisodeID == nil && player.episode?.id == 2 && player.wantsPlayback)
            #expect(try await store.queue().map(\.id) == [3, 2])
        }
    }

    @Test func restrictionDuringPreparationRetiresPendingReadinessWithoutHistory() async throws {
        let network = StreamingNetwork()
        network.allowed = true
        try await withPlayer(streamingAccess: { network.access($0) }) { store, player, engine, _, _ in
            try await player.select(episodeID: 1)
            let token = try #require(engine.generation)
            let command = try #require(engine.commandID)
            try await player.pause()
            network.allowed = false
            try await player.play()
            #expect(player.pendingStreamingEpisodeID == 1 && player.phase == .awaitingStreamingConfirmation)
            engine.onEvent?(.ready(.init(generation: token, commandID: command,
                sample: .init(positionMilliseconds: 0, durationMilliseconds: 100_000, status: .playing))))
            try await player.awaitPendingOperations()
            #expect(!player.wantsPlayback && player.phase == .awaitingStreamingConfirmation)
            #expect(try await store.episode(id: 1)?.userState.lastPlayedHistoryMilliseconds == nil)
            #expect(try await store.playbackSelectionEpisodeID() == 1)
        }
    }

    @Test func castingBypassesAdmissionUntilReturningToRestrictedLocalPlayback() async throws {
        let network = StreamingNetwork()
        network.casting = true
        try await withPlayer(streamingAccess: { network.access($0) }) { _, player, engine, _, _ in
            try await start(player, engine)
            #expect(player.pendingStreamingEpisodeID == nil && player.wantsPlayback)
            try await player.pause()
            network.casting = false
            try await player.play()
            #expect(player.pendingStreamingEpisodeID == 1 && !player.wantsPlayback)
        }
    }

    private func withPlayer(preferences: @escaping @MainActor (LibraryEpisode) -> PlaybackPreferences = { _ in .init() },
                            speedPreferences: PlaybackSpeedPreferenceStore? = nil,
                            sleepTimerPreferences: SleepTimerPreferenceStore? = nil,
                            storedSkip: Bool = false,
                            drainFiles: Bool = false,
                            fileEffectsOverride: (@MainActor () async throws -> Void)? = nil,
                            streamingAccess: (@MainActor (LibraryEpisode) async throws -> PlaybackStreamingAccess)? = nil,
                            _ operation: (FeedLibraryStore, PlaybackCoordinator, Engine, Clock, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Coordinator-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let episodes = (1...3).map {
            ParsedEpisode(identifier: "\($0)", title: "Episode \($0)",
                          media: ParsedMedia(url: "https://example.test/\($0).mp3", size: 0, durationMilliseconds: 100_000))
        }
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Playback", episodes: episodes),
                                              source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
                                              validator: nil, permanentRedirectURL: nil))
        let engine = Engine()
        let clock = Clock()
        let skip: (@MainActor (LibraryEpisode) async throws -> FeedSkipPreferences)?
        if storedSkip { skip = { episode in try await store.skipPreferences(forEpisode: episode.id) } }
        else { skip = nil }
        let completionEffects: (@MainActor () async throws -> Void)?
        if let fileEffectsOverride { completionEffects = fileEffectsOverride }
        else if drainFiles { completionEffects = { try await MediaDownloadWorker(store: store).cleanCancelledFiles() } }
        else { completionEffects = nil }
        let player = PlaybackCoordinator(store: store, engine: engine, preferences: preferences,
                                         speedPreferences: speedPreferences, sleepTimerPreferences: sleepTimerPreferences, skipPreferences: skip,
                                         streamingAccess: streamingAccess, completionEffects: completionEffects,
                                         clock: { clock.date }, monotonicClock: { clock.monotonic })
        do {
            try await operation(store, player, engine, clock, url)
            await player.awaitPendingCompletionEffects()
            try await player.stop()
            try await store.close()
        } catch {
            await player.awaitPendingCompletionEffects()
            try? await player.stop()
            try? await store.close()
            throw error
        }
    }

    private func start(_ player: PlaybackCoordinator, _ engine: Engine, id: Int64 = 1) async throws {
        try await player.select(episodeID: id)
        engine.ready()
        try await player.awaitPendingOperations()
    }

    @Test func sleepClockExpiryPausesAndSavesWithoutCompletingOrAdvancingQueue() async throws {
        try await withPlayer { store, player, engine, clock, _ in
            _ = try await store.enqueue([1, 2])
            try await start(player, engine)
            try await player.startSleepTimer(mode: .minutes, value: 15_000)
            #expect(player.sleepTimerValue?.display == 15_000)
            clock.milliseconds += 10_000; engine.position(10_000)
            try await player.awaitPendingOperations()
            #expect(engine.timerVolume == 0.5 && player.sleepTimerValue?.display == 5_000)
            engine.outputLog = []
            clock.milliseconds += 5_000; engine.position(15_000)
            try await player.awaitPendingOperations()
            #expect(engine.timerVolume == 1 && player.sleepTimer == nil && player.sleepTimerValue == nil)
            // The faded audio stops before the volume is restored, so nothing is heard at full level.
            #expect(engine.outputLog == ["pause", "volume 1.0"])
            #expect(player.phase == .paused && !player.wantsPlayback && player.episode?.id == 1)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 15_000)
            #expect(try await store.episode(id: 1)?.userState.playState != .played)
            #expect(try await store.queue().map(\.id) == [1, 2])
            await #expect(throws: PlaybackCoordinator.SleepTimerError.noMediaPlaying) {
                try await player.startSleepTimer(mode: .minutes, value: 60_000)
            }
        }
    }

    @Test func sleepTimerCountsUnknownDurationButIgnoresPausedAndLongGapsThenResumes() async throws {
        try await withPlayer { _, player, engine, clock, _ in
            try await start(player, engine)
            try await player.startSleepTimer(mode: .minutes, value: 60_000)
            clock.milliseconds += 1_000; engine.position(1000, duration: -1)
            try await player.awaitPendingOperations()
            #expect(player.sleepTimerValue?.display == 59_000)
            try await player.pause()
            clock.milliseconds += 30_000; engine.position(1000)
            try await player.awaitPendingOperations()
            #expect(player.sleepTimerValue?.display == 59_000)
            try await player.play()
            clock.milliseconds += 1_000; engine.position(2000)
            try await player.awaitPendingOperations()
            #expect(player.sleepTimerValue?.display == 59_000)
            clock.milliseconds += 1_000; engine.position(3000)
            try await player.awaitPendingOperations()
            #expect(player.sleepTimerValue?.display == 58_000)
            try await player.stop()
            #expect(player.sleepTimer == nil && engine.timerVolume == 1)
        }
    }

    @Test func sleepEpisodeCountSkipsManualNextAndStopsAtCompletedEpisode() async throws {
        try await withPlayer { store, player, engine, _, url in
            _ = try await store.enqueue([1, 2, 3])
            try await start(player, engine)
            try await player.startSleepTimer(mode: .episodes, value: 1)
            try await player.skip()
            #expect(player.episode?.id == 2 && player.sleepTimer?.remaining == 1)
            engine.ready(); try await player.awaitPendingOperations()
            engine.position(95_000); try await player.awaitPendingOperations()
            #expect(engine.timerVolume == 0.5)
            engine.end(); try await player.awaitPendingOperations()
            #expect(player.episode == nil && player.phase == .idle && !player.wantsPlayback)
            #expect(player.sleepTimer == nil && engine.timerVolume == 1)
            #expect(try await store.queue().map(\.id) == [1, 3])
            #expect(try await store.episode(id: 2)?.userState.playState == .played)
            #expect(try await store.playbackSelectionEpisodeID() == nil)
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.playbackSelectionEpisodeID() == nil)
            #expect(try await reopened.queue().map(\.id) == [1, 3])
            try await reopened.close()
        }
    }

    /// An interval skip past the end completes the timer's last episode while its audio still plays:
    /// it stops before the volume is restored, and the final position and queue are saved as before.
    @Test func sleepEpisodeCompletionWithAudioStillPlayingPausesBeforeRestoring() async throws {
        try await withPlayer { store, player, engine, _, _ in
            _ = try await store.enqueue([1, 2])
            try await start(player, engine)
            try await player.startSleepTimer(mode: .episodes, value: 1)
            engine.position(95_000); try await player.awaitPendingOperations()
            #expect(player.wantsPlayback && engine.timerVolume == 0.5)
            engine.outputLog = []
            try await player.skipInterval(seconds: 30)
            #expect(engine.outputLog == ["pause", "volume 1.0"])
            #expect(player.episode == nil && player.sleepTimer == nil && !player.wantsPlayback)
            #expect(try await store.episode(id: 1)?.userState.playState == .played)
            #expect(try await store.queue().map(\.id) == [2])
        }
    }

    /// The same order when the engine reports the end of the timer's last episode.
    @Test func sleepEpisodeCompletionAtTheEndPausesBeforeRestoring() async throws {
        try await withPlayer { _, player, engine, _, _ in
            try await start(player, engine)
            try await player.startSleepTimer(mode: .episodes, value: 1)
            engine.position(95_000); try await player.awaitPendingOperations()
            engine.outputLog = []
            engine.end(); try await player.awaitPendingOperations()
            #expect(engine.outputLog == ["pause", "volume 1.0"] && player.sleepTimer == nil)
        }
    }

    @Test func sleepEpisodeCountFollowsQueueUntilFinalEpisodeAndSeekCompletionCounts() async throws {
        try await withPlayer { store, player, engine, _, _ in
            _ = try await store.enqueue([1, 2, 3])
            try await start(player, engine)
            try await player.startSleepTimer(mode: .episodes, value: 2)
            engine.end(); try await player.awaitPendingOperations()
            #expect(player.episode?.id == 2 && player.sleepTimer?.remaining == 1)
            engine.ready(); try await player.awaitPendingOperations()
            engine.position(90_000); try await player.awaitPendingOperations()
            try await player.skipInterval(seconds: 30)
            #expect(player.episode == nil && player.sleepTimer == nil)
            #expect(try await store.queue().map(\.id) == [3])
            #expect(try await store.episode(id: 2)?.userState.playState == .played)
        }
    }

    @Test func sleepResetRestoresInitialValueAfterExtensionAndCancellationRestoresGain() async throws {
        try await withPlayer { _, player, engine, clock, _ in
            try await start(player, engine)
            var effects: [SleepTimerEvent] = []
            player.onSleepTimerFeedback = { effects.append($0) }
            try await player.startSleepTimer(mode: .minutes, value: 15_000)
            clock.milliseconds += 7_000; engine.position(7000)
            try await player.awaitPendingOperations()
            #expect(engine.timerVolume == 0.8 && effects == [.shakeListening(true)])
            try await player.extendSleepTimer(by: 300_000)
            #expect(player.sleepTimerValue?.display == 8_000) // Display updates on next source tick.
            try await player.resetSleepTimerAfterShake()
            #expect(player.sleepTimer?.remaining == 15_000 && player.sleepTimerValue?.display == 15_000)
            #expect(engine.timerVolume == 1 && effects.last == .resetVibration)
            try await player.disableSleepTimer()
            #expect(player.wantsPlayback && player.sleepTimer == nil && player.sleepTimerValue == nil)
            #expect(effects.last == .shakeListening(false))
        }
    }

    @Test func sleepZeroPositionExpiryReleasesShakeListenerAndPreservesSelection() async throws {
        try await withPlayer { _, player, engine, _, _ in
            try await start(player, engine)
            var effects: [SleepTimerEvent] = []
            player.onSleepTimerFeedback = { effects.append($0) }
            try await player.startSleepTimer(mode: .episodes, value: 1)
            engine.position(100_000); try await player.awaitPendingOperations()
            #expect(player.sleepTimer == nil && player.phase == .paused && player.episode?.id == 1)
            #expect(effects == [.shakeListening(true), .shakeListening(false)])
        }
    }

    @Test func sleepAutoEnableUsesPersistedRangeAndDoesNotReenableUntilPlaybackRestarts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try SleepTimerPreferenceStore(file: directory.appendingPathComponent("sleep.json"))
        var value = settings.value
        value.autoEnable = true; value.autoFromHour = 0; value.autoToHour = 0
        value.lastMinutes = "2"
        try settings.update(value)
        try await withPlayer(sleepTimerPreferences: settings) { _, player, engine, _, _ in
            try await start(player, engine)
            #expect(player.sleepTimerValue?.display == 120_000)
            try await player.disableSleepTimer()
            engine.position(1000); try await player.awaitPendingOperations()
            #expect(player.sleepTimer == nil)
            try await player.pause(); try await player.play()
            #expect(player.sleepTimerValue?.display == 120_000)
            try await player.disableSleepTimer(); try await player.pause()
            let hour = Calendar.current.component(.hour, from: Clock().date)
            value.autoFromHour = (hour + 1) % 24; value.autoToHour = (hour + 2) % 24
            try settings.update(value)
            try await player.play()
            #expect(player.sleepTimer == nil)
        }
    }

    @Test(arguments: ["preparing", "playing", "paused", "stopped"])
    func resetSelectedEpisodeRetiresPlaybackWithoutCompletionEffects(state: String) async throws {
        try await withPlayer { store, player, engine, _, url in
            _ = try await store.enqueue([1, 2, 3])
            try await player.select(episodeID: 1)
            if state != "preparing" { engine.ready(); try await player.awaitPendingOperations() }
            if state == "paused" { try await player.pause() }
            if state == "stopped" { try await player.stop() }
            try await store.updateEpisode(id: 1) {
                $0.userState.positionMilliseconds = 45_000
                $0.userState.playState = .played
                $0.userState.isFavorite = true
                $0.userState.isDownloaded = true
                $0.userState.localFileURL = "/test/reset.mp3"
                $0.userState.playbackCompletionDate = Date(timeIntervalSince1970: 123)
                $0.userState.playedDurationMilliseconds = 12_345
                $0.userState.timeSpentMilliseconds = 54_321
                $0.userState.lastPlayedHistoryMilliseconds = 100
            }
            var expected = try #require(await store.episode(id: 1))
            expected.userState.positionMilliseconds = 0
            expected.userState.playState = .unplayed
            let effects = try await store.pendingEffects()
            let oldSession = try #require(await store.playbackSession())
            let stale = PlaybackEngineReading(generation: engine.generation ?? UUID(), commandID: engine.commandID ?? UUID(),
                sample: PlaybackSample(positionMilliseconds: 80_000, durationMilliseconds: 100_000, status: .playing))
            try await player.resetPlaybackPosition(episodeID: 1)
            #expect(player.phase == .idle && !player.wantsPlayback && player.episode == nil && player.sample == nil)
            #expect(engine.commands.last == .unload && !engine.wantsPlayback)
            engine.onEvent?(.ready(stale)); engine.onEvent?(.position(stale)); engine.onEvent?(.ended(stale))
            try await player.awaitPendingOperations()
            #expect(try await store.recordPlayback(sessionID: oldSession.id, sample: stale.sample) == nil)
            #expect(try await store.episode(id: 1) == expected)
            #expect(try await store.queue().map(\.id) == [1, 2, 3])
            #expect(try await store.pendingEffects() == effects)
            #expect(try await store.playbackSession() == nil)
            #expect(try await store.playbackSelectionEpisodeID() == nil)
            try await player.restore()
            #expect(player.episode == nil)
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.episode(id: 1) == expected)
            #expect(try await reopened.playbackSelectionEpisodeID() == nil)
            try await reopened.close()
        }
    }

    @Test func resettingAnotherEpisodeDoesNotInterruptCurrentPlayback() async throws {
        try await withPlayer { store, player, engine, _, _ in
            try await start(player, engine)
            try await store.updateEpisode(id: 2) { $0.userState.positionMilliseconds = 98_000; $0.userState.playState = .played }
            let session = try await store.playbackSession()
            let commands = engine.commands
            try await player.resetPlaybackPosition(episodeID: 2)
            #expect(player.phase == .playing && player.wantsPlayback && player.episode?.id == 1)
            #expect(engine.commands == commands)
            #expect(try await store.playbackSession() == session)
            #expect(try await store.playbackSelectionEpisodeID() == 1)
            #expect(try await store.episode(id: 2)?.userState.positionMilliseconds == 0)
            #expect(try await store.episode(id: 2)?.userState.playState == .unplayed)
            engine.position(12_345); try await player.awaitPendingOperations()
            #expect(player.sample?.positionMilliseconds == 12_345)
        }
    }

    @Test func failedResetPreservesSelectionAndEngine() async throws {
        try await withPlayer { store, player, engine, _, _ in
            try await start(player, engine)
            let before = try await store.episode(id: 1)
            let commands = engine.commands
            await #expect(throws: FeedLibraryError.missingEpisode(999)) {
                try await player.resetPlaybackPosition(episodeID: 999)
            }
            #expect(try await store.episode(id: 1) == before)
            #expect(player.phase == .playing && player.episode?.id == 1 && player.wantsPlayback)
            #expect(engine.commands == commands)
            #expect(try await store.playbackSelectionEpisodeID() == 1)
        }
    }

    @Test(arguments: ["preparing", "playing", "paused", "stopped"], [false, true])
    func deletingSelectedDownloadPreservesEpisodeHistoryAndRetiresStalePlayback(state: String, removeFromQueue: Bool) async throws {
        try await withPlayer { store, player, engine, clock, url in
            let file = url.deletingLastPathComponent().appendingPathComponent("download.media")
            try Data("downloaded fixture".utf8).write(to: file)
            let downloadDate = clock.date
            try await store.updateEpisode(id: 1) {
                $0.userState.localFileURL = file.path; $0.userState.isDownloaded = true
                $0.userState.downloadDate = downloadDate; $0.userState.isFavorite = true
                $0.userState.positionMilliseconds = 3000
            }
            _ = try await store.enqueue([1, 2, 3])
            try await store.selectSynchronizationAccount(UUID())
            try await player.select(episodeID: 1)
            if state != "preparing" { engine.ready(); try await player.awaitPendingOperations() }
            if state == "paused" { try await player.pause() }
            if state == "stopped" { try await player.stop() }
            var expected = try #require(await store.episode(id: 1))
            let original = expected
            expected.userState.localFileURL = nil; expected.userState.isDownloaded = false; expected.userState.downloadDate = nil
            expected.details.media?.hasEmbeddedPicture = false
            let session = try #require(await store.playbackSession())
            let stale = PlaybackEngineReading(generation: engine.generation ?? UUID(), commandID: engine.commandID ?? UUID(),
                sample: PlaybackSample(positionMilliseconds: 90000, durationMilliseconds: 100000, status: .playing))
            try await player.deleteDownloadedMedia(episodeID: 1, deleteRemovesFromQueue: removeFromQueue)
            #expect(player.episode == nil && player.phase == .idle && !player.wantsPlayback)
            #expect(engine.commands.last == .unload)
            engine.onEvent?(.ready(stale)); engine.onEvent?(.position(stale)); engine.onEvent?(.ended(stale))
            try await player.awaitPendingOperations()
            #expect(try await store.recordPlayback(sessionID: session.id, sample: stale.sample) == nil)
            #expect(try await store.episode(id: 1) == expected)
            #expect(try await store.queue().map(\.id) == (removeFromQueue ? [2, 3] : [1, 2, 3]))
            #expect(try await store.playbackSelectionEpisodeID() == nil)
            #expect(FileManager.default.fileExists(atPath: file.path)) // Durable intent precedes the worker.
            let worker = MediaDownloadWorker(store: store)
            try await worker.cleanCancelledFiles()
            #expect(!FileManager.default.fileExists(atPath: file.path))
            try await worker.cleanCancelledFiles() // Completed intent is not replayed.
            // Exactly one DELETE action for the original download reaches the account's outbox.
            let deleted = try await store.synchronizationQueue().filter {
                if case .episode(let action) = $0.value { action.action == .delete && action.episode == original.details.media?.url } else { false }
            }
            #expect(deleted.count == 1)
            #expect(!(try await store.pendingEffects()).contains { if case .deleteDownloadFile = $0.effect.kind { true } else { false } })
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.episode(id: 1) == expected)
            #expect(try await reopened.playbackSession() == nil)
            try await reopened.close()
        }
    }

    @Test func deletingAnotherDownloadOrRejectingInvalidDeletionDoesNotInterruptCurrentPlayer() async throws {
        try await withPlayer { store, player, engine, _, url in
            try await start(player, engine)
            let file = url.deletingLastPathComponent().appendingPathComponent("second.media")
            try Data("second".utf8).write(to: file)
            try await store.updateEpisode(id: 2) { $0.userState.localFileURL = file.path; $0.userState.isDownloaded = true }
            let commands = engine.commands, session = try await store.playbackSession()
            try await player.deleteDownloadedMedia(episodeID: 2)
            #expect(engine.commands == commands && player.episode?.id == 1 && player.wantsPlayback)
            #expect(try await store.playbackSession() == session)
            let worker = MediaDownloadWorker(store: store)
            try await worker.cleanCancelledFiles()
            #expect(!FileManager.default.fileExists(atPath: file.path))
            await #expect(throws: FeedLibraryError.missingEpisode(999)) { try await player.deleteDownloadedMedia(episodeID: 999) }
            try await store.updateEpisode(id: 3) { $0.details.media = nil }
            await #expect(throws: FeedLibraryError.invalidMutation) { try await player.deleteDownloadedMedia(episodeID: 3) }
            #expect(engine.commands == commands && player.wantsPlayback)
            #expect(try await store.playbackSession() == session)
        }
    }

    @Test func rowAndMiniPlayerTogglesShareSelectionAndPauseIntent() async throws {
        try await withPlayer { store, player, engine, _, _ in
            try await player.toggle()
            #expect(engine.commands.isEmpty)
            try await player.toggle(episodeID: 1)
            #expect(player.phase == .preparing && player.wantsPlayback)
            try await player.toggle()
            #expect(!player.wantsPlayback)
            engine.ready()
            try await player.awaitPendingOperations()
            #expect(player.phase == .paused)
            #expect(engine.commands.filter { $0 == .play }.count == 1 && engine.commands.last == .pause)
            try await player.toggle(episodeID: 1)
            #expect(player.wantsPlayback)
            engine.position(25_000)
            try await player.awaitPendingOperations()
            try await player.toggle()
            #expect(player.phase == .paused && !player.wantsPlayback)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 25_000)
            try await player.toggle(episodeID: 2)
            #expect(player.episode?.id == 2 && player.wantsPlayback)
            #expect(Array(engine.commands.suffix(2)) == [.load(2, 0), .play] && engine.reading == nil)
        }
    }

    @Test func intervalControlsUseLatestEnginePositionAndRewindStopsAtZero() async throws {
        try await withPlayer { _, player, engine, _, _ in
            try await player.skipInterval(seconds: 30)
            #expect(engine.commands.isEmpty)
            try await start(player, engine)
            engine.reading?.sample.positionMilliseconds = 32_500
            try await player.skipInterval(seconds: -10)
            #expect(engine.commands.last == .seek(22_500))
            try await player.skipInterval(seconds: 30)
            #expect(engine.commands.last == .seek(52_500))
            try await player.skipInterval(seconds: .min)
            #expect(engine.commands.last == .seek(0))
            #expect(player.wantsPlayback)
            try await player.pause()
            try await player.skipInterval(seconds: 30)
            #expect(engine.commands.last == .seek(30_000))
            #expect(player.phase == .paused && !player.wantsPlayback)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func forwardIntervalAtKnownEndCompletesAndHonorsFollowQueue(paused: Bool, follow: Bool) async throws {
        for position: Int32 in [69_999, 70_000, 70_001] {
            try await withPlayer(preferences: { _ in
                var preferences = PlaybackPreferences()
                preferences.followQueue = follow
                preferences.end.smartMarkAsPlayedSeconds = 0
                return preferences
            }) { store, player, engine, clock, url in
                _ = try await store.enqueue([1, 2])
                try await start(player, engine)
                if paused { try await player.pause() }
                engine.reading?.sample.positionMilliseconds = position
                let stale = try #require(engine.reading)
                let before = engine.commands.count
                try await player.skipInterval(seconds: 30)
                if position < 70_000 {
                    #expect(engine.commands.last == .seek(99_999))
                    #expect(player.episode?.id == 1 && player.wantsPlayback == !paused)
                    #expect(try await store.queue().map(\.id) == [1, 2])
                    return
                }
                // Media3PlaybackService.seekForward calls handlePlaybackEnded;
                // it does not seek and wait for playback to reach EOS.
                #expect(!engine.commands.dropFirst(before).contains { if case .seek = $0 { true } else { false } })
                #expect(player.episode?.id == 2 && player.phase == .preparing && player.wantsPlayback == follow)
                #expect(engine.commands.last == (follow ? .play : .load(2, 0)))
                let completed = try #require(try await store.episode(id: 1))
                #expect(completed.userState.playState == .played && completed.userState.positionMilliseconds == 0)
                #expect(completed.userState.lastPlayedHistoryMilliseconds == clock.milliseconds)
                #expect(try await store.queue().map(\.id) == [2])
                let reopened = try FeedLibraryStore(url: url)
                #expect(try await reopened.episode(id: 1)?.userState.playState == .played)
                #expect(try await reopened.queue().map(\.id) == [2])
                try await reopened.close()
                engine.onEvent?(.ended(stale))
                try await player.awaitPendingOperations()
                #expect(player.episode?.id == 2 && engine.commands.filter { $0 == .load(2, 0) }.count == 1)
                engine.ready(); try await player.awaitPendingOperations()
                #expect(player.phase == (follow ? .playing : .paused))
            }
        }
    }

    @Test(arguments: [Int32(-1), 0], [false, true])
    func intervalWithUnknownDurationPreservesTargetAndPauseIntent(duration: Int32, paused: Bool) async throws {
        try await withPlayer { store, player, engine, _, _ in
            try await start(player, engine)
            if paused { try await player.pause() }
            engine.reading?.sample.positionMilliseconds = 32_500
            engine.reading?.sample.durationMilliseconds = duration
            try await player.skipInterval(seconds: 30)
            #expect(engine.commands.last == .seek(62_500))
            #expect(player.sample?.positionMilliseconds == 62_500)
            try await player.skipInterval(seconds: -10)
            #expect(engine.commands.last == .seek(52_500))
            #expect(player.episode?.id == 1 && player.wantsPlayback == !paused)
            #expect(try await store.queue().map(\.id) == [1])
            // Original service uses long arithmetic and casts the position event
            // back to int. An unknown duration must not introduce a Swift trap.
            let hugeTarget = Int64(52_500) + Int64(Int32.max) * 1_000
            try await player.skipInterval(seconds: .max)
            #expect(engine.commands.last == .seek(hugeTarget))
            #expect(player.sample?.positionMilliseconds == Int32(truncatingIfNeeded: hugeTarget))
        }
    }

    @Test(arguments: [false, true])
    func forwardIntervalAtLastEpisodeClearsSelectionWithoutExplicitSkipMessage(paused: Bool) async throws {
        try await withPlayer(preferences: { _ in
            var preferences = PlaybackPreferences(); preferences.end.smartMarkAsPlayedSeconds = 0; return preferences
        }) { store, player, engine, _, _ in
            try await start(player, engine)
            if paused { try await player.pause() }
            engine.reading?.sample.positionMilliseconds = 70_000
            var events = player.events().makeAsyncIterator()
            _ = await events.next() // Initial state.
            try await player.skipInterval(seconds: 30)
            #expect(player.phase == .idle && player.episode == nil && !player.wantsPlayback)
            #expect(try await store.queue().isEmpty == true)
            #expect(try await store.playbackSession() == nil)
            #expect(try await store.episode(id: 1)?.userState.playState == .played)
            // The next selection's library event is a sentinel after every
            // completion event, including any erroneous trailing Skip warning.
            try await player.select(episodeID: 2, play: false)
            var libraryChanges = 0
            while let event = await events.next() {
                if case .noFollowingEpisode = event { Issue.record("Forward completion used the explicit Skip warning") }
                if case .libraryChanged = event { libraryChanges += 1 }
                if libraryChanges == 2 { break }
            }
        }
    }

    @Test func pausedSeekForceStopRestoresLastPauseAsRecordedOnAndroid() async throws {
        try await withPlayer { store, player, engine, clock, url in
            try await start(player, engine)
            engine.position(1_846, duration: 30_040)
            try await player.pause()
            try await player.seek(to: 15_020)
            #expect(player.sample?.positionMilliseconds == 15_020)
            #expect(player.phase == .paused && !player.wantsPlayback)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 1_846)
            let reopened = try FeedLibraryStore(url: url)
            let nextEngine = Engine()
            let restored = PlaybackCoordinator(store: reopened, engine: nextEngine, clock: { clock.date })
            try await restored.restore()
            #expect(restored.sample?.positionMilliseconds == 1_846)
            #expect(nextEngine.commands.isEmpty)
            try await reopened.close()
        }
    }

    @Test func restorationDoesNotLoadOrAutoplayEvenWhenStoredStatusIsPlaying() async throws {
        try await withPlayer { store, player, engine, clock, _ in
            let session = try await store.beginPlayback(episodeID: 1)
            _ = try await store.recordPlayback(sessionID: session.id,
                sample: .init(positionMilliseconds: 40_000, durationMilliseconds: 100_000, status: .playing), now: clock.date)
            try await player.restore()
            try await player.restore()
            #expect(player.episode?.id == 1 && player.phase == .stopped)
            #expect(player.sample?.positionMilliseconds == 40_000)
            #expect(!player.wantsPlayback && engine.commands.isEmpty)
            clock.milliseconds += 61_000
            try await player.play()
            #expect(Array(engine.commands.suffix(2)) == [.load(1, 37_000), .play])
            #expect(engine.reading == nil && engine.wantsPlayback)
            engine.ready()
            try await player.awaitPendingOperations()
            #expect(player.phase == .playing)
        }
    }

    @Test func initialSelectionAppliesIntroBeforeRewindAndWaitsForReadiness() async throws {
        try await withPlayer(preferences: { _ in var p = PlaybackPreferences(); p.skip.introSeconds = 10; return p }) {
            store, player, engine, clock, _ in
            let lastPlayed = clock.milliseconds - 61_000
            try await store.updateEpisode(id: 1) {
                $0.userState.positionMilliseconds = 5_000
                $0.userState.lastPlayedTimeMilliseconds = lastPlayed
            }
            try await player.select(episodeID: 1)
            #expect(Array(engine.commands.suffix(2)) == [.load(1, 7_000), .play] && engine.reading == nil)
            #expect(player.phase == .preparing && player.wantsPlayback)
            #expect(try await store.playbackSession()?.startPositionMilliseconds == 7_000)
            #expect(try await store.episode(id: 1)?.userState.lastPlayedHistoryMilliseconds == nil)
            engine.ready()
            try await player.awaitPendingOperations()
            #expect(engine.commands.last == .play && player.phase == .playing)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 7_000)
        }
    }

    @Test func pauseDuringPreparationPreventsLateReadyFromStartingAudio() async throws {
        try await withPlayer { store, player, engine, _, _ in
            try await player.select(episodeID: 1)
            try await player.pause()
            #expect(player.phase == .preparing && !player.wantsPlayback)
            engine.ready()
            try await player.awaitPendingOperations()
            #expect(player.phase == .paused && engine.commands.last == .pause)
            #expect(engine.commands.filter { $0 == .play }.count == 1)
            #expect(try await store.episode(id: 1)?.userState.lastPlayedHistoryMilliseconds == nil)
            try await player.play()
            #expect(engine.commands.last == .play)
        }
    }

    @Test func positionSavesAtFiveSecondsAndPauseSavesImmediately() async throws {
        try await withPlayer { store, player, engine, clock, _ in
            try await start(player, engine)
            let startTime = clock.milliseconds
            clock.milliseconds += 4_999
            engine.position(4_999)
            try await player.awaitPendingOperations()
            #expect(player.sample?.positionMilliseconds == 4_999)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 0)
            clock.milliseconds += 1
            engine.position(5_000)
            try await player.awaitPendingOperations()
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 5_000)
            clock.milliseconds += 123
            engine.position(5_123)
            try await player.pause()
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 5_123)
            #expect(try await store.episode(id: 1)?.userState.lastPlayedTimeMilliseconds == startTime + 5_123)
            #expect(try await store.playbackSession()?.status == .paused)
        }
    }

    @Test func pausedTicksAndUnknownDurationDoNotSave() async throws {
        try await withPlayer { store, player, engine, clock, _ in
            try await start(player, engine)
            clock.milliseconds += 5_000
            engine.position(5_000, duration: -1)
            try await player.awaitPendingOperations()
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 0)
            clock.milliseconds += 3_000
            engine.position(8_000)
            try await player.awaitPendingOperations()
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 8_000)
            clock.milliseconds += 1_000
            engine.position(9_000)
            try await player.pause()
            clock.milliseconds += 20_000
            engine.position(20_000)
            try await player.awaitPendingOperations()
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 9_000)
        }
    }

    /// A wall-clock correction (network time, a manual change) neither holds up nor hurries the checkpoints: they
    /// continue every five seconds of playback, stamped with the corrected wall time, and after the app is killed
    /// without a pause a relaunch resumes from the latest one. (Android 3.12.1 skips saves after a rollback.)
    @Test(arguments: [-3_600_000, 3_600_000] as [Int64])
    func checkpointsContinueEveryFiveSecondsAcrossWallClockCorrections(correction: Int64) async throws {
        try await withPlayer { store, player, engine, clock, url in
            try await start(player, engine)
            clock.milliseconds += 5_000
            engine.position(5_000)
            try await player.awaitPendingOperations()
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 5_000)
            clock.correctWallClock(by: correction)
            var checkpoint: Int32 = 5_000
            for second in 6...30 {
                if second == 18 { clock.correctWallClock(by: correction) }
                clock.milliseconds += 1_000
                engine.position(Int32(second) * 1_000)
                try await player.awaitPendingOperations()
                let saved = try #require(try await store.episode(id: 1)?.userState)
                if second % 5 == 0 {
                    checkpoint = Int32(second) * 1_000
                    #expect(saved.lastPlayedTimeMilliseconds == clock.milliseconds, "second \(second)")
                }
                #expect(saved.positionMilliseconds == checkpoint, "second \(second)")
            }
            let reopened = try FeedLibraryStore(url: url)
            let relaunched = PlaybackCoordinator(store: reopened, engine: Engine(), clock: { clock.date })
            try await relaunched.restore()
            #expect(relaunched.episode?.id == 1 && relaunched.sample?.positionMilliseconds == 30_000)
            try await reopened.close()
        }
    }

    /// A clock sleep timer counts listening time: a wall-clock correction neither extends nor shortens it, and the
    /// fade starts at the same remaining time. (Android 3.12.1's timer follows the wall clock.)
    @Test(arguments: [0, -3_600_000, 3_600_000] as [Int64])
    func sleepClockTimerCountsListeningTimeAcrossWallClockCorrections(correction: Int64) async throws {
        try await withPlayer { _, player, engine, clock, _ in
            try await start(player, engine)
            try await player.startSleepTimer(mode: .minutes, value: 60_000)
            var volumes: [Float] = []
            for second in 1...60 {
                if second == 30 || second == 55 { clock.correctWallClock(by: correction) }
                #expect(player.sleepTimer != nil && player.wantsPlayback, "second \(second)")
                clock.milliseconds += 1_000
                engine.position(Int32(second) * 1_000)
                try await player.awaitPendingOperations()
                volumes.append(engine.timerVolume)
                if second < 60 { #expect(player.sleepTimerValue?.display == 60_000 - Int64(second) * 1_000, "second \(second)") }
            }
            let fade = (1...9).reversed().map { Float($0 * 1_000) / 10_000 }
            #expect(volumes == Array(repeating: Float(1), count: 50) + fade + [1])
            #expect(player.sleepTimer == nil && player.sleepTimerValue == nil)
            #expect(player.phase == .paused && !player.wantsPlayback)
        }
    }

    /// The production monotonic clock counts milliseconds of the continuous clock.
    @Test func continuousMonotonicClockCountsMilliseconds() async {
        let origin = ContinuousClock.now
        while ContinuousClock.now - origin < .milliseconds(30) { await Task.yield() }
        let counted = PlaybackCoordinator.continuousMilliseconds(since: origin)
        let measured = ContinuousClock.now - origin
        #expect(counted >= 30 && Duration.milliseconds(counted) <= measured)
    }

    @Test func resumeRewindsWithoutReplacingStatisticsSession() async throws {
        try await withPlayer { store, player, engine, clock, _ in
            try await store.updateEpisode(id: 1) { $0.userState.positionMilliseconds = 10_000 }
            try await start(player, engine)
            let sessionID = try await store.playbackSession()?.id
            engine.position(20_000)
            try await player.pause()
            clock.milliseconds += 61_000
            try await player.play()
            #expect(Array(engine.commands.suffix(2)) == [.seek(17_000), .play])
            #expect(player.sample?.positionMilliseconds == 17_000 && player.sample?.status == .playing)
            #expect(try await store.playbackSession()?.id == sessionID)
            clock.milliseconds += 5_000
            engine.position(18_000)
            try await player.awaitPendingOperations()
            #expect(try await store.episode(id: 1)?.userState.playedDurationMilliseconds == 8_000)
            let count = engine.commands.count
            try await player.select(episodeID: 1)
            #expect(engine.commands.count == count)
        }
    }

    @Test func oldMediaReadyPositionEndAndFailureCannotAffectReplacement() async throws {
        try await withPlayer { store, player, engine, _, _ in
            try await start(player, engine)
            let old = try #require(engine.reading)
            try await player.select(episodeID: 2)
            for event in [PlaybackEngineEvent.ready(old), .position(old), .ended(old), .stateChanged(old),
                          .failed(generation: old.generation, message: "old failure")] { engine.onEvent?(event) }
            try await player.awaitPendingOperations()
            #expect(player.episode?.id == 2 && player.phase == .preparing)
            #expect(try await store.playbackSession()?.episodeID == 2)
            engine.ready()
            try await player.awaitPendingOperations()
            #expect(player.phase == .playing)
        }
    }

    @Test func delayedPauseAndEndFromOldCommandCannotOverrideNewPlay() async throws {
        try await withPlayer { store, player, engine, clock, _ in
            try await start(player, engine)
            engine.position(20_000)
            try await player.pause()
            let old = try #require(engine.reading)
            clock.milliseconds += 1_000
            try await player.play()
            engine.onEvent?(.stateChanged(old))
            engine.onEvent?(.ended(old))
            try await player.awaitPendingOperations()
            #expect(player.wantsPlayback && player.phase == .playing)
            #expect(try await store.playbackSession()?.episodeID == 1)
            #expect(try await store.episode(id: 1)?.userState.playState != .played)
        }
    }

    @Test func synchronousCallbacksAreSerializedWithoutDeadlockOrDuplicateCompletion() async throws {
        try await withPlayer { store, player, engine, _, _ in
            engine.emitTransitions = true
            _ = try await store.enqueue([1, 2])
            try await start(player, engine)
            try await player.awaitPendingOperations()
            #expect(player.phase == .playing)
            engine.end()
            try await player.awaitPendingOperations()
            #expect(player.episode?.id == 2 && player.phase == .preparing)
            #expect(try await store.queue().map(\.id) == [2])
        }
    }

    @Test(arguments: [true, false])
    func completionPreparesNextWithIntroButNoResumeRewind(follow: Bool) async throws {
        try await withPlayer(preferences: { _ in
            var p = PlaybackPreferences(); p.followQueue = follow; p.skip.introSeconds = 10; return p
        }) { store, player, engine, clock, _ in
            _ = try await store.enqueue([1, 2, 3])
            let lastPlayed = clock.milliseconds - 61_000
            try await store.updateEpisode(id: 2) {
                $0.userState.positionMilliseconds = 5_000
                $0.userState.lastPlayedTimeMilliseconds = lastPlayed
            }
            try await start(player, engine)
            engine.end(99_986)
            try await player.awaitPendingOperations()
            #expect(engine.commands.contains(.load(2, 10_000)))
            #expect(engine.commands.last == (follow ? .play : .load(2, 10_000)))
            #expect(engine.reading == nil && engine.wantsPlayback == follow)
            #expect(try await store.playbackSession()?.startPositionMilliseconds == 5_000)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 0)
            #expect(try await store.episode(id: 1)?.userState.playState == .played)
            #expect(try await store.queue().map(\.id) == [2, 3])
            engine.ready()
            try await player.awaitPendingOperations()
            #expect(player.phase == (follow ? .playing : .paused))
            #expect(player.wantsPlayback == follow)
        }
    }

    @Test func explicitSkipKeepsUnfinishedEpisodeAndStopsAtQueueEnd() async throws {
        try await withPlayer { store, player, engine, _, _ in
            _ = try await store.enqueue([1, 2])
            try await start(player, engine)
            engine.position(20_000)
            try await player.skip()
            #expect(try await store.queue().map(\.id) == [1, 2])
            #expect(try await store.episode(id: 1)?.userState.playState != .played)
            #expect(player.episode?.id == 2)
            engine.ready()
            try await player.awaitPendingOperations()
            try await player.skip()
            #expect(player.episode == nil && player.phase == .idle)
            #expect(try await store.playbackSession() == nil)
        }
    }

    @Test func stopSavesPositionAndRejectsLateCallbacksWithoutCompletingEpisode() async throws {
        try await withPlayer { store, player, engine, _, _ in
            try await start(player, engine)
            engine.position(80_000)
            let old = try #require(engine.reading)
            try await player.stop()
            engine.onEvent?(.ended(old))
            try await player.awaitPendingOperations()
            #expect(player.phase == .stopped && !player.wantsPlayback)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 80_000)
            #expect(try await store.episode(id: 1)?.userState.playState != .played)
            #expect(try await store.queue().map(\.id) == [1])
        }
    }

    @Test func endingSkipSeeksToDurationOnlyWithinStrictWindow() async throws {
        try await withPlayer(preferences: { _ in var p = PlaybackPreferences(); p.skip.endingSeconds = 10; return p }) {
            _, player, engine, _, _ in
            try await start(player, engine)
            engine.position(89_000)
            try await player.awaitPendingOperations()
            #expect(!engine.commands.contains(.seek(100_000)))
            engine.position(89_001)
            try await player.awaitPendingOperations()
            #expect(engine.commands.last == .seek(100_000))
        }
    }

    @Test func autoDeleteUsesLoadedChoiceAndDeletesRetiredEpisodeWhileFollowingQueue() async throws {
        try await withPlayer(drainFiles: true) { store, player, engine, _, url in
            let file = url.deletingLastPathComponent().appendingPathComponent("episode.mp3")
            try Data([1, 2, 3]).write(to: file)
            try await store.updateEpisode(id: 1) {
                $0.userState.localFileURL = file.path; $0.userState.isDownloaded = true
                $0.details.media?.hasEmbeddedPicture = true
            }
            try await store.updatePreferences(feedID: 1) { $0.autoDelete = .always }
            _ = try await store.enqueue([1, 2])
            try await start(player, engine)
            try await store.updatePreferences(feedID: 1) { $0.autoDelete = .never }
            engine.end(); try await player.awaitPendingOperations()
            await player.awaitPendingCompletionEffects()
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(try await store.episode(id: 1)?.userState.isDownloaded == false)
            #expect(try await store.episode(id: 1)?.details.media?.hasEmbeddedPicture == false)
            #expect(player.episode?.id == 2 && player.wantsPlayback)
            #expect(try await store.queue().map(\.id) == [2])
            let second = url.deletingLastPathComponent().appendingPathComponent("second.mp3")
            try Data([4]).write(to: second)
            try await store.updateEpisode(id: 2) { $0.userState.localFileURL = second.path; $0.userState.isDownloaded = true }
            engine.ready(); try await player.awaitPendingOperations()
            engine.end(); try await player.awaitPendingOperations()
            await player.awaitPendingCompletionEffects()
            #expect(FileManager.default.fileExists(atPath: second.path))
            #expect(try await store.episode(id: 2)?.userState.isDownloaded == true)
        }
    }

    @Test(arguments: [FeedAutoDelete.global, .always, .never], [false, true])
    func autoDeleteReadsGlobalPreferenceAtCompletion(choice: FeedAutoDelete, enabled: Bool) async throws {
        var global = false
        try await withPlayer(preferences: { _ in var p = PlaybackPreferences(); p.end.autoDelete = global; return p },
                             drainFiles: true) { store, player, engine, _, url in
            let file = url.deletingLastPathComponent().appendingPathComponent("episode.mp3")
            try Data([1]).write(to: file)
            try await store.updateEpisode(id: 1) { $0.userState.localFileURL = file.path; $0.userState.isDownloaded = true }
            try await store.updatePreferences(feedID: 1) { $0.autoDelete = choice }
            try await start(player, engine)
            global = enabled
            engine.end(); try await player.awaitPendingOperations()
            await player.awaitPendingCompletionEffects()
            let deleted = choice == .always || (choice == .global && enabled)
            #expect(FileManager.default.fileExists(atPath: file.path) == !deleted)
        }
    }

    @Test func failedCompletionDeletionRetainsRetryAndDoesNotBlockQueue() async throws {
        try await withPlayer(drainFiles: true) { store, player, engine, _, url in
            let file = url.deletingLastPathComponent().appendingPathComponent("episode.mp3")
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            let child = file.appendingPathComponent("keep")
            try Data([1]).write(to: child)
            try await store.updateEpisode(id: 1) { $0.userState.localFileURL = file.path; $0.userState.isDownloaded = true }
            try await store.updatePreferences(feedID: 1) { $0.autoDelete = .always }
            _ = try await store.enqueue([1, 2])
            try await start(player, engine); engine.end(); try await player.awaitPendingOperations()
            await player.awaitPendingCompletionEffects()
            #expect(player.episode?.id == 2 && player.phase == .preparing)
            #expect(try Data(contentsOf: child) == Data([1]))
            #expect(try await store.pendingEffects().contains { if case .deleteDownloadFile = $0.effect.kind { true } else { false } })
            try FileManager.default.removeItem(at: child); try FileManager.default.removeItem(at: file)
            try Data([2]).write(to: file)
            let reopened = try FeedLibraryStore(url: url)
            try await MediaDownloadWorker(store: reopened).cleanCancelledFiles()
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(!(try await reopened.pendingEffects()).contains { if case .deleteDownloadFile = $0.effect.kind { true } else { false } })
            try await reopened.close()
        }
    }

    @Test(arguments: ["switched", "skipped", "ended"])
    func directSwitchRereadsDeletionChoiceButQueueEndAndSkipRetainLoadedChoice(reason: String) async throws {
        try await withPlayer(drainFiles: true) { store, player, engine, _, url in
            let file = url.deletingLastPathComponent().appendingPathComponent("episode.mp3")
            try Data([1]).write(to: file)
            try await store.updateEpisode(id: 1) { $0.userState.localFileURL = file.path; $0.userState.isDownloaded = true }
            try await store.updatePreferences(feedID: 1) { $0.autoDelete = .never }
            _ = try await store.enqueue([1, 2])
            try await start(player, engine)
            try await store.updatePreferences(feedID: 1) { $0.autoDelete = .always }
            engine.position(70_000); try await player.awaitPendingOperations()
            if reason == "switched" { try await player.select(episodeID: 2) }
            else if reason == "skipped" { try await player.skip() }
            else { engine.end(); try await player.awaitPendingOperations() }
            await player.awaitPendingCompletionEffects()
            #expect(FileManager.default.fileExists(atPath: file.path) == (reason != "switched"))
            #expect(player.episode?.id == 2)
        }
    }

    @Test func slowFileProviderDoesNotBlockNextPlaybackOrPause() async throws {
        var started = false
        var resume: CheckedContinuation<Void, Never>?
        try await withPlayer(fileEffectsOverride: {
            started = true
            await withCheckedContinuation { resume = $0 }
        }) { store, player, engine, _, _ in
            defer { resume?.resume(); resume = nil }
            _ = try await store.enqueue([1, 2])
            try await start(player, engine)
            let retiredGeneration = engine.generation
            engine.end(); try await player.awaitPendingOperations()
            while !started { await Task.yield() }
            #expect(resume != nil && player.episode?.id == 2 && player.wantsPlayback)
            #expect(engine.generation != retiredGeneration)
            engine.ready(); try await player.awaitPendingOperations()
            try await player.pause()
            #expect(player.phase == .paused && !player.wantsPlayback)
        }
    }

    @Test func feedVolumeAppliesDuringPreparationAndLiveOnlyToMatchingSelection() async throws {
        try await withPlayer { store, player, engine, _, url in
            try await store.updatePreferences(feedID: 1) { $0.volumeAdaptation = .heavyReduction }
            try await player.select(episodeID: 1)
            #expect(engine.volume == .heavyReduction && player.volumeAdaptation == .heavyReduction)
            try await store.updatePreferences(feedID: 1) { $0.volumeAdaptation = .lightBoost }
            try await player.refreshVolumeAdaptation(feedID: 1)
            #expect(engine.volume == .lightBoost && player.phase == .preparing)
            engine.ready(); try await player.awaitPendingOperations()
            try await player.seek(to: 25_000); try await player.pause()
            let commands = engine.commands, queue = try await store.queue()
            try await store.updatePreferences(feedID: 1) { $0.volumeAdaptation = .heavyBoost }
            try await player.refreshVolumeAdaptation(feedID: 999)
            #expect(engine.volume == .lightBoost)
            try await player.refreshVolumeAdaptation(feedID: 1)
            #expect(engine.volume == .heavyBoost && player.volumeAdaptation == .heavyBoost)
            #expect(player.phase == .paused && !player.wantsPlayback && player.sample?.positionMilliseconds == 25_000)
            #expect(engine.commands == commands)
            #expect(try await store.queue() == queue)
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.volumeAdaptation(forEpisode: 2) == .heavyBoost)
            try await reopened.close()
            try await start(player, engine, id: 2)
            #expect(engine.volume == .heavyBoost)
            try await store.updatePreferences(feedID: 1) { $0.volumeAdaptation = .off }
            try await player.refreshVolumeAdaptation(feedID: 1)
            #expect(engine.volume == .off && player.wantsPlayback)
        }
    }

    @Test func pausedSeekIntoEndingWindowKeepsEpisodeAndQueueUntilPlaybackResumes() async throws {
        try await withPlayer(storedSkip: true) { store, player, engine, _, _ in
            try await store.updatePreferences(feedID: 1) { $0.skip.endingSeconds = 10 }
            _ = try await store.enqueue([1, 2])
            try await start(player, engine)
            try await player.pause()
            try await player.seek(to: 89_500)
            let queue = try await store.queue()
            let saved = try #require(try await store.episode(id: 1))
            let commands = engine.commands
            for _ in 0..<3 {
                engine.position(89_500)
                try await player.awaitPendingOperations()
            }
            #expect(engine.commands == commands)
            #expect(player.phase == .paused && !player.wantsPlayback && player.episode?.id == 1)
            #expect(player.sample?.positionMilliseconds == 89_500)
            #expect(try await store.queue() == queue)
            #expect(try await store.episode(id: 1) == saved)
            try await player.play()
            engine.position(89_500)
            try await player.awaitPendingOperations()
            #expect(player.wantsPlayback && engine.commands.last == .seek(100_000))
        }
    }

    @Test func storedFeedSkipPairPersistsAndOnlyAffectsSubsequentLoads() async throws {
        try await withPlayer(storedSkip: true) { store, player, engine, _, url in
            let before = try #require(await store.feed(id: 1))
            #expect(before.skipPreferences == .init())
            try await store.updatePreferences(feedID: 1) { $0.skip = .init(introSeconds: 10, endingSeconds: 10) }
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.skipPreferences(forEpisode: 1) == .init(introSeconds: 10, endingSeconds: 10))
            try await reopened.close()
            let saved = try #require(await store.feed(id: 1))
            #expect(saved.episodes == before.episodes && saved.tags == before.tags && saved.keepUpdated == before.keepUpdated)
            var messages: [Int32] = []
            let events = player.events()
            let task = Task { for await event in events {
                switch event { case .introSkipped(let seconds), .endingSkipped(let seconds): messages.append(seconds)
                default: break }
            } }
            defer { task.cancel() }
            try await start(player, engine)
            #expect(engine.commands.contains(.load(1, 10_000)))
            try await store.updatePreferences(feedID: 1) { $0.skip = .init(introSeconds: 20, endingSeconds: 20) }
            engine.position(79_500); try await player.awaitPendingOperations()
            #expect(!engine.commands.contains(.seek(100_000)))
            engine.position(89_500); try await player.awaitPendingOperations()
            #expect(engine.commands.last == .seek(100_000))
            try await start(player, engine, id: 2)
            #expect(engine.commands.contains(.load(2, 20_000)))
            let previousSeeks = engine.commands.filter { $0 == .seek(100_000) }.count
            engine.position(79_500); try await player.awaitPendingOperations()
            #expect(engine.commands.filter { $0 == .seek(100_000) }.count == previousSeeks + 1)
            for _ in 0..<100 where messages.count < 4 { await Task.yield() }
            #expect(messages == [10, 10, 20, 20])
            try await store.updatePreferences(feedID: 1) { $0.skip = .init() }
            try await start(player, engine, id: 3)
            #expect(engine.commands.contains(.load(3, 0)))
        }
    }

    @Test func bufferingRetainsPlayIntentWhileExternalPauseSaves() async throws {
        try await withPlayer { store, player, engine, _, _ in
            try await start(player, engine)
            engine.position(12_000)
            engine.state(.playing, buffering: true)
            try await player.awaitPendingOperations()
            #expect(player.phase == .buffering && player.wantsPlayback)
            engine.state(.playing)
            try await player.awaitPendingOperations()
            #expect(player.phase == .playing)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 12_000)
            engine.position(12_123)
            engine.state(.paused)
            try await player.awaitPendingOperations()
            #expect(player.phase == .paused && !player.wantsPlayback)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 12_123)
        }
    }

    @Test func preparationFailureDoesNotInventHistoryAndCanBeRetried() async throws {
        try await withPlayer { store, player, engine, _, _ in
            try await player.select(episodeID: 1)
            let token = try #require(engine.generation)
            engine.onEvent?(.failed(generation: token, message: "unreadable media"))
            try await player.awaitPendingOperations()
            #expect(player.phase == .failed && !player.wantsPlayback)
            #expect(try await store.episode(id: 1)?.userState.lastPlayedHistoryMilliseconds == nil)
            try await player.play()
            #expect(engine.generation != token && player.phase == .preparing)
            engine.ready()
            try await player.awaitPendingOperations()
            #expect(player.phase == .playing)
        }
    }

    @Test func invalidSelectionDoesNotInterruptCurrentEpisodeOrPoisonLaterCommands() async throws {
        try await withPlayer { _, player, engine, _, _ in
            try await start(player, engine)
            let commands = engine.commands
            await #expect(throws: FeedLibraryError.self) { try await player.select(episodeID: 999) }
            #expect(engine.commands == commands && player.episode?.id == 1)
            try await player.pause()
            #expect(player.phase == .paused)
        }
    }

    @Test func preparationUsesActualPositionAsBaselineAndDuplicateReadyIsIgnored() async throws {
        try await withPlayer { store, player, engine, _, _ in
            try await store.updateEpisode(id: 1) { $0.userState.positionMilliseconds = 10_000 }
            try await player.select(episodeID: 1)
            engine.initialPosition = 10_023
            engine.ready()
            let ready = try #require(engine.reading)
            try await player.awaitPendingOperations()
            #expect(try await store.playbackSession()?.startPositionMilliseconds == 10_023)
            let id = try await store.playbackSession()?.id
            engine.onEvent?(.ready(ready))
            try await player.awaitPendingOperations()
            #expect(try await store.playbackSession()?.id == id)
            #expect(engine.commands.filter { $0 == .play }.count == 1)
        }
    }

    @Test func storageFailureOnPauseStopsAudioAndPreservesLastDurableSample() async throws {
        try await withPlayer { store, player, engine, _, url in
            try await start(player, engine)
            let connection = try LibrarySQLite(url: url)
            try connection.execute("CREATE TRIGGER fail_sample BEFORE UPDATE ON episodes BEGIN SELECT RAISE(ABORT, 'test sample failure'); END")
            engine.position(12_000)
            let old = try #require(engine.reading)
            await #expect(throws: FeedLibraryError.self) { try await player.pause() }
            #expect(player.phase == .failed && !player.wantsPlayback)
            #expect(engine.commands.last == .unload)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 0)
            engine.onEvent?(.stateChanged(old))
            try await player.awaitPendingOperations()
            #expect(player.phase == .failed)
            try connection.execute("DROP TRIGGER fail_sample")
            try connection.close()
            try await player.play()
            engine.ready()
            try await player.awaitPendingOperations()
            #expect(player.phase == .playing)
        }
    }

    @Test func failedCompletionKeepsQueueAndSessionForRetry() async throws {
        try await withPlayer { store, player, engine, _, url in
            _ = try await store.enqueue([1, 2])
            try await start(player, engine)
            let connection = try LibrarySQLite(url: url)
            try connection.execute("CREATE TRIGGER fail_end BEFORE DELETE ON playback_session BEGIN SELECT RAISE(ABORT, 'test end failure'); END")
            engine.end()
            try await player.awaitPendingOperations()
            #expect(player.phase == .failed && !player.wantsPlayback)
            #expect(try await store.queue().map(\.id) == [1, 2])
            #expect(try await store.playbackSession()?.episodeID == 1)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 100_000)
            #expect(try await store.episode(id: 1)?.userState.playState != .played)
            try connection.execute("DROP TRIGGER fail_end")
            try connection.close()
            try await player.skip()
            #expect(player.episode?.id == 2)
            #expect(try await store.queue().map(\.id) == [2])
        }
    }

    @Test func anotherStoreOwnerInvalidatesThisEngineInsteadOfOverwritingItsPosition() async throws {
        try await withPlayer { store, player, engine, clock, _ in
            try await start(player, engine)
            let replacement = try await store.beginPlayback(episodeID: 2)
            clock.milliseconds += 5_000
            engine.position(5_000)
            try await player.awaitPendingOperations()
            #expect(player.phase == .failed && !player.wantsPlayback)
            #expect(try await store.playbackSession()?.id == replacement.id)
            #expect(try await store.episode(id: 2)?.userState.positionMilliseconds == 0)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func chapterSeekPreservesIntentUnlessRowRequestsPlay(wasPlaying: Bool, startPlayback: Bool) async throws {
        try await withPlayer { store, player, engine, _, _ in
            try await player.select(episodeID: 1, play: wasPlaying)
            engine.ready(); try await player.awaitPendingOperations()
            let old = try #require(engine.reading)
            let before = engine.commands.count
            try await player.seekChapter(episodeID: 1, to: 38_883, startPlayback: startPlayback)
            #expect(player.wantsPlayback == (wasPlaying || startPlayback))
            #expect(player.sample?.positionMilliseconds == 38_883)
            let commands = Array(engine.commands.dropFirst(before))
            #expect(commands == (!wasPlaying && startPlayback ? [.play, .seek(38_883)] : [.seek(38_883)]))
            engine.onEvent?(.position(old)); try await player.awaitPendingOperations()
            #expect(player.sample?.positionMilliseconds == 38_883)
            try await player.pause()
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 38_883)
            #expect(player.episode?.id == 1)
        }
    }

    @Test(arguments: [false, true])
    func chapterRowCanPrepareRestoredSelectionButCoverDoesNotStartIt(startPlayback: Bool) async throws {
        try await withPlayer { _, player, engine, _, _ in
            try await start(player, engine)
            try await player.stop()
            let before = engine.commands.count
            try await player.seekChapter(episodeID: 1, to: 42_000, startPlayback: startPlayback)
            if startPlayback {
                #expect(player.wantsPlayback && player.phase == .preparing)
                #expect(Array(engine.commands.suffix(2)) == [.play, .seek(42_000)])
                #expect(player.sample?.positionMilliseconds == 42_000)
            } else {
                #expect(!player.wantsPlayback && player.phase == .stopped)
                #expect(engine.commands.count == before)
            }
        }
    }

    @Test(arguments: [false, true])
    func chapterActionRejectsAnEpisodeRetiredByQueuedSelection(startPlayback: Bool) async throws {
        let entered = AsyncStream<Void>.makeStream(), release = AsyncStream<Void>.makeStream()
        try await withPlayer(streamingAccess: { episode in
            if episode.id == 2 {
                entered.continuation.yield(())
                for await _ in release.stream { break }
            }
            return .init(needsStreaming: false, streamingAllowed: true)
        }) { _, player, engine, _, _ in
            try await start(player, engine)
            let switchEpisode = Task { try await player.select(episodeID: 2, play: false) }
            for await _ in entered.stream { break }
            let releaseSwitch = Task { release.continuation.yield(()) }
            try await player.seekChapter(episodeID: 1, to: 42_000, startPlayback: startPlayback)
            _ = await releaseSwitch.value
            try await switchEpisode.value
            #expect(player.episode?.id == 2 && !player.wantsPlayback)
            #expect(!engine.commands.contains(.seek(42_000)))
            #expect(player.sample?.positionMilliseconds == 0)
        }
    }

    @Test func chapterRowUsesDirectPlayAdmissionAndCoverDoesNotAcceptConfirmation() async throws {
        let network = StreamingNetwork(); network.allowed = true
        try await withPlayer(streamingAccess: { network.access($0) }) { _, player, engine, _, _ in
            try await start(player, engine)
            try await player.pause()
            network.allowed = false
            try await player.seekChapter(episodeID: 1, to: 42_000, startPlayback: true)
            #expect(player.pendingStreamingEpisodeID == 1 && !player.wantsPlayback)
            #expect(!engine.commands.contains(.seek(42_000)))
            let before = engine.commands.count
            try await player.seekChapter(episodeID: 1, to: 42_000, startPlayback: false)
            #expect(engine.commands.count == before)
            // A new explicit row Play has the same Once behavior as direct Play.
            try await player.seekChapter(episodeID: 1, to: 52_000, startPlayback: true)
            #expect(player.wantsPlayback && player.pendingStreamingEpisodeID == nil)
            #expect(Array(engine.commands.suffix(2)) == [.play, .seek(52_000)])
            #expect(!engine.commands.contains(.seek(42_000)))
        }
    }

    @Test func chapterActionCannotAcceptConfirmationForAnotherEpisode() async throws {
        let network = StreamingNetwork(); network.allowed = true
        try await withPlayer(streamingAccess: { network.access($0) }) { _, player, engine, _, _ in
            try await start(player, engine)
            network.allowed = false
            try await player.select(episodeID: 2)
            #expect(player.episode?.id == 1 && player.pendingStreamingEpisodeID == 2)
            let before = engine.commands.count
            for play in [false, true] {
                try await player.seekChapter(episodeID: 1, to: 42_000, startPlayback: play)
            }
            #expect(player.pendingStreamingEpisodeID == 2 && !player.wantsPlayback)
            #expect(engine.commands.count == before)
        }
    }

    @Test func chapterPlayAndSeekRemainTogetherAcrossSuspendedResume() async throws {
        let entered = AsyncStream<Void>.makeStream(), release = AsyncStream<Void>.makeStream()
        var suspendResume = false
        try await withPlayer(streamingAccess: { _ in
            if suspendResume {
                suspendResume = false
                entered.continuation.yield(())
                for await _ in release.stream { break }
            }
            return .init(needsStreaming: false, streamingAllowed: true)
        }) { _, player, engine, _, _ in
            try await start(player, engine); try await player.pause()
            suspendResume = true
            let row = Task { try await player.seekChapter(episodeID: 1, to: 42_000, startPlayback: true) }
            for await _ in entered.stream { break }
            let releaseResume = Task { release.continuation.yield(()) }
            try await player.select(episodeID: 2, play: false)
            _ = await releaseResume.value
            try await row.value
            let seek = try #require(engine.commands.firstIndex(of: .seek(42_000)))
            let load = try #require(engine.commands.firstIndex(of: .load(2, 0)))
            #expect(engine.commands[seek - 1] == .play && seek < load)
            #expect(player.episode?.id == 2 && !player.wantsPlayback)
            #expect(player.sample?.positionMilliseconds == 0)
        }
    }

    @Test func seeksPublishImmediatelyAndCannotBeUndoneByEarlierTick() async throws {
        try await withPlayer { store, player, engine, _, _ in
            try await start(player, engine)
            let old = try #require(engine.reading)
            try await player.seek(to: 38_883)
            #expect(player.sample?.positionMilliseconds == 38_883)
            engine.onEvent?(.position(old))
            try await player.awaitPendingOperations()
            #expect(player.sample?.positionMilliseconds == 38_883)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 0)
            try await player.pause()
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 38_883)
        }
    }

    @Test func readyCapturedBeforePauseStillCompletesPreparationUsingCurrentIntent() async throws {
        try await withPlayer { store, player, engine, _, _ in
            try await player.select(episodeID: 1)
            let callback = engine.onEvent
            engine.onEvent = nil
            engine.ready()
            let captured = try #require(engine.reading)
            try await player.pause()
            engine.onEvent = callback
            engine.onEvent?(.ready(captured))
            try await player.awaitPendingOperations()
            #expect(player.phase == .paused && !player.wantsPlayback)
            #expect(engine.commands.filter { $0 == .play }.count == 1 && engine.commands.last == .pause)
            #expect(try await store.episode(id: 1)?.userState.lastPlayedHistoryMilliseconds == nil)
        }
    }

    @Test func recoveryReadsSharedSavedStatisticsAcrossTicksBufferingPauseAndSeek() async throws {
        try await withPlayer { store, player, engine, clock, databaseURL in
            try await start(player, engine)
#if SWIFT_PACKAGE
            let mediaURL = try #require(Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures"))
#else
            let mediaURL = try #require(Bundle(for: PlaybackCoordinatorTestBundleMarker.self).url(forResource: "playback-30sec", withExtension: "mp3"))
#endif
            let generation = try #require(engine.generation)
            let factory = try PCMRecoveryFactory(url: mediaURL, makeTransport: { SampleBufferPCMOutputTests.Transport() })
            let parameters = PCMRecoverySession.Parameters(speed: 1, skipSilence: false)
            let initial = try await factory.make(positionMilliseconds: 25000, parameters: parameters)
            try await initial.prepare()
            var targets: [Int64] = []
            let port = PCMRecoverySession(initial: initial, parameters: parameters,
                lastPlayedMilliseconds: { [weak player] in
                    guard player?.episode?.id == 1 else { return 0 }
                    return player?.episode?.userState.lastPlayedTimeMilliseconds ?? 0
                }, synchronizeStatistics: { try await player.synchronizePlaybackStatistics(generation: generation) }, factory: { position, parameters in
                    targets.append(position)
                    return try await factory.make(positionMilliseconds: position, parameters: parameters)
                })
            defer { port.close() }
            let readyTime = clock.milliseconds
            #expect(port.lastPlayedMilliseconds == readyTime)
            clock.milliseconds += 4999
            engine.position(25000); try await player.awaitPendingOperations()
            #expect(port.lastPlayedMilliseconds == readyTime)
            clock.milliseconds += 1
            engine.position(25000); try await player.awaitPendingOperations()
            #expect(port.lastPlayedMilliseconds == clock.milliseconds)
            let tickTime = clock.milliseconds
            clock.milliseconds += 1000
            engine.state(.playing, buffering: true); try await player.awaitPendingOperations()
            #expect(port.lastPlayedMilliseconds == tickTime)
            clock.milliseconds += 1000
            engine.state(.playing, buffering: false); try await player.awaitPendingOperations()
            #expect(port.lastPlayedMilliseconds == clock.milliseconds)

            let driver = AudioSessionActivationControllerTests.Driver()
            let activation = AudioSessionActivationController(driver: driver)
            let recovery = PlaybackRecoveryController(session: port, activation: activation,
                now: { clock.milliseconds })
            defer { recovery.close(); driver.complete() }
            try recovery.play()
            try await waitForRecovery { driver.pending != nil }; driver.complete()
            try await waitForRecovery { recovery.state == .playing }
            let beforeInterruptionSave = port.lastPlayedMilliseconds
            clock.milliseconds += 1000
            recovery.receive(.interrupted(reason: 0))
            #expect(port.lastPlayedMilliseconds == beforeInterruptionSave)
            // The engine's state callback is processed by the shared persistent coordinator.
            engine.state(.paused)
            let pausedTime = clock.milliseconds
            clock.milliseconds += 60001
            // Deliberately deliver gain before the queued database save has been processed.
            recovery.receive(.resumptionRecommended(false))
            try await waitForRecovery { targets == [22000] && recovery.state == .paused }
            #expect(try await store.episode(id: 1)?.userState.lastPlayedTimeMilliseconds == pausedTime)
            #expect(try port.positionMilliseconds == 22000)
            #expect(port.lastPlayedMilliseconds == pausedTime)
            try await player.seek(to: 15000)
            #expect(port.lastPlayedMilliseconds == pausedTime)
            let reopened = try FeedLibraryStore(url: databaseURL)
            #expect(try await reopened.episode(id: 1)?.userState.lastPlayedTimeMilliseconds == pausedTime)
            #expect(try await reopened.episode(id: 1)?.userState.positionMilliseconds == 25000)
            try await reopened.close()
            recovery.close()
            try await player.select(episodeID: 2, play: false)
            await #expect(throws: FeedLibraryError.invalidMutation) {
                try await player.synchronizePlaybackStatistics(generation: generation)
            }
        }
    }

    @Test func recoveryStatisticsBarrierRejectsFailedSave() async throws {
        try await withPlayer { _, player, engine, clock, databaseURL in
            try await start(player, engine)
            let generation = try #require(engine.generation)
            let db = try LibrarySQLite(url: databaseURL)
            defer { try? db.close() }
            try db.execute("CREATE TRIGGER fail_recovery_save BEFORE UPDATE ON episodes BEGIN SELECT RAISE(ABORT, 'test recovery failure'); END")
            clock.milliseconds += 1000
            engine.state(.paused)
            await #expect(throws: FeedLibraryError.invalidMutation) {
                try await player.synchronizePlaybackStatistics(generation: generation)
            }
            #expect(player.phase == .failed && !player.wantsPlayback)
            try db.execute("DROP TRIGGER fail_recovery_save")
        }
    }

    @Test func queuedReadyPositionAndEndKeepEventTimesInsteadOfQueueDrainTime() async throws {
        try await withPlayer { store, player, engine, clock, _ in
            try await player.select(episodeID: 1)
            let readyTime = clock.milliseconds
            engine.ready()
            clock.milliseconds += 6000
            try await player.awaitPendingOperations()
            #expect(try await store.episode(id: 1)?.userState.lastPlayedTimeMilliseconds == readyTime)
            let positionTime = clock.milliseconds
            engine.position(12000)
            clock.milliseconds += 4000
            try await player.awaitPendingOperations()
            #expect(try await store.episode(id: 1)?.userState.lastPlayedTimeMilliseconds == positionTime)
            let endedTime = clock.milliseconds
            engine.end()
            clock.milliseconds += 9000
            try await player.awaitPendingOperations()
            let saved = try #require(try await store.episode(id: 1))
            #expect(saved.userState.lastPlayedTimeMilliseconds == endedTime)
            #expect(saved.userState.lastPlayedHistoryMilliseconds == endedTime)
            // Completion marks played and resets position, as in the active service's
            // markItemsPlayed(PLAYED, true, ...) path; timestamps survive that reset.
            #expect(saved.userState.positionMilliseconds == 0 && saved.userState.playState == .played)
            #expect(saved.details.media?.durationMilliseconds == 100000 && player.episode == nil)
        }
    }

    private func waitForRecovery(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }
}
