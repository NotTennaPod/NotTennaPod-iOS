import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized) struct RoutedPlaybackEngineTests {
    final class Engine: PlaybackSilenceControlling, PlaybackVolumeControlling, PlaybackStatisticsConsumer {
        var reading: PlaybackEngineReading?
        var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
        var loaded: [(LibraryEpisode, UUID, Int64)] = []
        var unloadCount = 0, commandCount = 0
        var generation: UUID?, commandID: UUID?
        var position: Int32 = 0, speed: Float = 1
        var wantsPlayback = false, silence = false
        var supportsSkipSilence = true
        var volume: FeedVolumeAdaptation = .off
        var timerVolume: Float = 1
        var automaticReady = false
        var lastPlayed: (@MainActor (UUID) -> Int64)?
        var synchronize: (@MainActor (UUID) async throws -> Void)?
        func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
            self.generation = generation; commandID = generation; position = Int32(clamping: positionMilliseconds)
            loaded.append((episode, generation, positionMilliseconds))
            if automaticReady { ready() }
        }
        func play(commandID: UUID) { wantsPlayback = true; update(commandID) }
        func pause(commandID: UUID) { wantsPlayback = false; update(commandID) }
        func seek(to value: Int64, commandID: UUID) { position = Int32(clamping: value); update(commandID) }
        func setSpeed(_ value: Float, commandID: UUID) { speed = value; update(commandID) }
        func setSkipSilence(_ value: Bool, commandID: UUID) { silence = value; update(commandID) }
        func setVolumeAdaptation(_ value: FeedVolumeAdaptation) { volume = value }
        func setSleepTimerVolume(_ value: Float) { timerVolume = value }
        func update(_ id: UUID) {
            commandCount += 1; commandID = id
            guard var value = reading else { return }
            value.commandID = id; value.sample.positionMilliseconds = position
            value.sample.status = wantsPlayback ? .playing : .paused
            value.speed = speed; value.skipSilence = silence
            reading = value; onEvent?(.stateChanged(value))
        }
        func ready() {
            guard let generation, let commandID else { return }
            let value = PlaybackEngineReading(generation: generation, commandID: commandID,
                sample: .init(positionMilliseconds: position, durationMilliseconds: 100_000,
                              status: wantsPlayback ? .playing : .paused), speed: speed, skipSilence: silence)
            reading = value; onEvent?(.ready(value))
        }
        func advance(to position: Int32) {
            self.position = position; reading?.sample.positionMilliseconds = position
            if let reading { onEvent?(.position(reading)) }
        }
        func end() {
            position = 100_000; reading?.sample.positionMilliseconds = position
            if let reading { onEvent?(.ended(reading)) }
        }
        func unload() {
            unloadCount += 1
            // An engine can synchronously notify during stop. A handoff must
            // already have detached the outgoing callback.
            if let reading { onEvent?(.ended(reading)) }
            reading = nil; generation = nil; commandID = nil
            wantsPlayback = false; silence = false; speed = 1
        }
        func bindStatistics(lastPlayed: @escaping @MainActor (UUID) -> Int64,
                            synchronize: @escaping @MainActor (UUID) async throws -> Void) {
            self.lastPlayed = lastPlayed; self.synchronize = synchronize
        }
    }
    func episode(_ id: Int64 = 1) -> LibraryEpisode {
        var user = EpisodeUserState(); user.isDownloaded = true; user.localFileURL = "file:///media/\(id).mp3"
        return .init(id: id, details: ParsedEpisode(identifier: String(id), title: "Episode \(id)",
            media: ParsedMedia(url: "https://example.test/\(id).mp3", size: 1, durationMilliseconds: 100_000)), userState: user)
    }
    func withLibrary(_ body: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("cast-route-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Routes", episodes: [episode().details, episode(2).details]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        do { try await body(store, root) }
        catch { try? await store.close(); throw error }
        try await store.close()
    }

    @Test func roundTripTransfersPositionIntentSpeedAndEpisodeIdentity() throws {
        let local = Engine(), remote = Engine(), route = RoutedPlaybackEngine(local: local)
        defer { route.unload() }
        let generation = UUID(), command = UUID(), item = episode()
        var ready = 0, ended = 0
        route.onEvent = { if case .ready = $0 { ready += 1 }; if case .ended = $0 { ended += 1 } }
        route.load(episode: item, generation: generation, positionMilliseconds: 1200)
        route.play(commandID: command); try route.setSpeed(1.5, commandID: command); local.ready()
        local.advance(to: 4500)
        route.setRemote(remote)
        #expect(local.reading == nil && remote.loaded.last?.2 == 4500)
        #expect(remote.loaded.last?.0 == item && remote.wantsPlayback && remote.speed == 1.5)
        #expect(route.reading?.buffering == true && route.reading?.generation == generation)
        remote.ready(); remote.advance(to: 9400)
        let paused = UUID(); route.pause(commandID: paused)
        route.setRemote(nil); local.ready()
        #expect(local.loaded.last?.2 == 9400 && !local.wantsPlayback && local.speed == 1.5)
        #expect(route.reading?.commandID == paused && route.reading?.sample.positionMilliseconds == 9400)
        #expect(ready == 1 && ended == 0)
    }

    @Test func commandsDuringPreparationSurviveRepeatedHandoffs() throws {
        let local = Engine(), remote = Engine(), route = RoutedPlaybackEngine(local: local)
        defer { route.unload() }
        let generation = UUID(), latest = UUID()
        route.load(episode: episode(), generation: generation, positionMilliseconds: 0)
        route.play(commandID: UUID()); route.seek(to: 27_000, commandID: UUID())
        route.setRemote(remote)
        #expect(remote.loaded.last?.2 == 27_000 && remote.wantsPlayback)
        route.pause(commandID: latest); route.seek(to: 31_000, commandID: latest)
        try route.setSpeed(1.75, commandID: latest)
        route.setRemote(nil); local.ready()
        #expect(local.loaded.last?.2 == 31_000 && !local.wantsPlayback && local.speed == 1.75)
        #expect(route.reading?.generation == generation && route.reading?.commandID == latest)
    }

    @Test func retiredCallbacksCannotFinishOrFailTheReusedLocalEngine() throws {
        let local = Engine(), remote = Engine(), route = RoutedPlaybackEngine(local: local)
        defer { route.unload() }
        route.load(episode: episode(), generation: UUID(), positionMilliseconds: 1000); local.ready()
        let callback = local.onEvent, retired = try #require(local.reading)
        route.setRemote(remote); remote.ready(); route.setRemote(nil); local.ready()
        var forwarded = 0; route.onEvent = { _ in forwarded += 1 }
        callback?(.ready(retired)); callback?(.position(retired)); callback?(.ended(retired))
        callback?(.failed(generation: retired.generation, message: "retired"))
        // Even a misbehaving backend invoking its new callback with an old load
        // identity must not deliver the previous episode's event.
        local.onEvent?(.ended(retired))
        #expect(forwarded == 0 && route.reading?.sample.positionMilliseconds == 1000)
    }

    /// A remote route's refusal to relay reaches the coordinator for the episode generation, keeping the position it was
    /// loading; a retired backend load's refusal does not.
    @Test func streamingRefusalIsForwardedForTheCurrentBackendLoadOnly() {
        let local = Engine(), remote = Engine(), route = RoutedPlaybackEngine(local: local)
        defer { route.unload() }
        let generation = UUID()
        var refused: [UUID] = []
        route.onEvent = { if case .streamingConfirmationRequired(let id) = $0 { refused.append(id) } }
        route.load(episode: episode(), generation: generation, positionMilliseconds: 0)
        route.play(commandID: UUID()); local.ready(); local.advance(to: 7_000)
        route.setRemote(remote)
        let first = remote.generation!
        route.setRemote(nil); route.setRemote(remote)
        remote.onEvent?(.streamingConfirmationRequired(generation: first))
        #expect(refused.isEmpty, "a retired load's refusal is dropped")
        remote.onEvent?(.streamingConfirmationRequired(generation: remote.generation!))
        #expect(refused == [generation])
        #expect(route.reading?.generation == generation && route.reading?.sample.positionMilliseconds == 7_000)
    }

    @Test func routeConnectionSurvivesEpisodeUnloadAndSameSessionIsIdempotent() {
        let local = Engine(), remote = Engine(), route = RoutedPlaybackEngine(local: local)
        defer { route.unload() }
        route.setRemote(remote)
        route.load(episode: episode(), generation: UUID(), positionMilliseconds: 700); remote.ready()
        route.setRemote(remote)
        #expect(remote.loaded.count == 1 && local.loaded.isEmpty)
        route.unload()
        #expect(route.isRemote && route.reading == nil)
        route.load(episode: episode(2), generation: UUID(), positionMilliseconds: 0)
        #expect(remote.loaded.count == 2 && remote.loaded.last?.0.id == 2 && local.loaded.isEmpty)
    }

    @Test func localProcessingPreferencesAndTimerVolumeSurviveRemotePlayback() throws {
        let local = Engine(), remote = Engine(), route = RoutedPlaybackEngine(local: local)
        remote.supportsSkipSilence = false
        defer { route.unload() }
        let command = UUID()
        route.load(episode: episode(), generation: UUID(), positionMilliseconds: 0); local.ready()
        route.setSkipSilence(true, commandID: command)
        try route.setVolumeAdaptation(.heavyReduction); try route.setSleepTimerVolume(0.4)
        route.setRemote(remote); remote.ready()
        #expect(!route.supportsSkipSilence && route.retainsSkipSilencePreference && !remote.silence)
        #expect(remote.volume == .heavyReduction && remote.timerVolume == 0.4)
        let count = remote.commandCount, preferenceCommand = UUID()
        route.setSkipSilence(false, commandID: preferenceCommand)
        #expect(remote.commandCount == count && route.reading?.commandID == preferenceCommand)
        route.setSkipSilence(true, commandID: preferenceCommand)
        remote.advance(to: 6000)
        #expect(route.reading?.skipSilence == true && route.reading?.sample.positionMilliseconds == 6000)
        route.setRemote(nil); local.ready()
        #expect(local.silence && local.volume == .heavyReduction && local.timerVolume == 0.4)
    }

    @Test func synchronousReadinessPublishesTheTransferredIntentOnly() throws {
        let local = Engine(), remote = Engine(), route = RoutedPlaybackEngine(local: local)
        local.automaticReady = true; remote.automaticReady = true
        defer { route.unload() }
        route.load(episode: episode(), generation: UUID(), positionMilliseconds: 12_000)
        route.play(commandID: UUID())
        var states: [LibraryPlaybackSession.Status] = []
        route.onEvent = { if case .stateChanged(let r) = $0 { states.append(r.sample.status) } }
        route.setRemote(remote)
        #expect(states == [.playing] && remote.wantsPlayback)
    }

    @Test func coordinatorKeepsStatisticsSessionAndQueueUntilActualRemoteCompletion() async throws {
        try await withLibrary { store, _ in
            let local = Engine(), remote = Engine(), route = RoutedPlaybackEngine(local: local)
            let player = PlaybackCoordinator(store: store, engine: route)
            defer { route.unload() }
            try await player.select(episodeID: 1); local.ready(); try await player.awaitPendingOperations()
            let initial = try #require(try await store.playbackSession())
            let initialQueue = try await store.queue().map(\.id)
            #expect(initialQueue == [1])
            local.advance(to: 10_000); route.setRemote(remote); remote.ready()
            try await player.awaitPendingOperations()
            remote.advance(to: 25_000); try await player.pause()
            route.setRemote(nil); local.ready(); try await player.awaitPendingOperations()
            #expect(player.phase == .paused && player.episode?.id == 1)
            let retained = try #require(try await store.playbackSession())
            let item = try #require(try await store.episode(id: 1))
            #expect(retained.id == initial.id && item.userState.positionMilliseconds == 25_000)
            #expect(item.userState.playedDurationMilliseconds == 25_000 && item.userState.playState != .played)
            #expect(try await store.queue().map(\.id) == initialQueue)
            route.setRemote(remote); remote.ready(); try await player.awaitPendingOperations()
            remote.end(); try await player.awaitPendingOperations()
            #expect(try await store.episode(id: 1)?.userState.playState == .played)
            #expect(try await store.episode(id: 1)?.userState.playedDurationMilliseconds == 100_000)
            #expect(try await store.playbackSession() == nil)
            #expect(try await store.queue().isEmpty)
        }
    }

    /// A refusal the coordinator has queued but not yet handled belongs to the route that raised it: when that route is
    /// handed back before the queue drains, the local replacement keeps playing and nothing asks. The current route's
    /// refusal still asks.
    @Test func queuedRefusalOfARetiredRouteLeavesTheReplacementPlaying() async throws {
        try await withLibrary { store, _ in
            let local = Engine(), remote = Engine(), route = RoutedPlaybackEngine(local: local)
            local.automaticReady = true
            let player = PlaybackCoordinator(store: store, engine: route)
            defer { route.unload() }
            try await player.select(episodeID: 1); try await player.awaitPendingOperations()
            #expect(player.phase == .playing)
            route.setRemote(remote)
            remote.onEvent?(.streamingConfirmationRequired(generation: try #require(remote.generation)))
            route.setRemote(nil) // Handed back before the coordinator handled the refusal.
            try await player.awaitPendingOperations()
            #expect(!route.isRemote && local.loaded.count == 2 && local.generation != nil && local.wantsPlayback)
            #expect(player.pendingStreamingEpisodeID == nil && player.phase != .awaitingStreamingConfirmation)
            route.setRemote(remote)
            remote.onEvent?(.streamingConfirmationRequired(generation: try #require(remote.generation)))
            try await player.awaitPendingOperations()
            #expect(player.pendingStreamingEpisodeID == 1 && player.phase == .awaitingStreamingConfirmation)
        }
    }

    @Test func remoteSilencePreferencePersistsThroughCoordinatorWithoutReceiverProcessing() async throws {
        try await withLibrary { store, root in
            let settings = try PlaybackSpeedPreferenceStore(file: root.appendingPathComponent("speeds.json"))
            let local = Engine(), remote = Engine(), route = RoutedPlaybackEngine(local: local)
            remote.supportsSkipSilence = false
            let player = PlaybackCoordinator(store: store, engine: route, speedPreferences: settings)
            defer { route.unload() }
            route.setRemote(remote)
            try await player.select(episodeID: 1, play: false); remote.ready(); try await player.awaitPendingOperations()
            try await player.setSkipSilence(true, alsoGlobal: true); try await player.awaitPendingOperations()
            #expect(player.skipSilence && !remote.silence)
            let reopened = try PlaybackSpeedPreferenceStore(file: root.appendingPathComponent("speeds.json"))
            #expect(reopened.value.silence.global)
            route.setRemote(nil); local.ready(); try await player.awaitPendingOperations()
            #expect(local.silence && player.skipSilence && player.phase == .paused)
        }
    }
}
