import Foundation
import Testing
@testable import NotTennaPodCore

/// Uses the same resolver and live preference stores as AppDelegate, with a
/// controllable engine. Expectations are durable app outcomes, not flag values.
@Suite(.timeLimit(.minutes(1))) @MainActor
struct PlaybackApplicationPreferencesTests {
    @Test(arguments: [EnqueueLocation.front, .back, .afterCurrentlyPlaying])
    func selectedEpisodeUsesLivePlacementAndDoesNotMoveExistingItems(_ location: EnqueueLocation) async throws {
        try await PCPlaybackFixture.withFixture { f in
            _ = try await f.store.enqueue([1, 2, 3])
            try await f.player.select(episodeID: 2); f.engine.ready(); try await f.player.awaitPendingOperations()
            _ = try await f.store.removeFromQueue([4])
            var prefs = f.download.value; prefs.enqueueLocation = location; try f.download.update(prefs)
            try await f.player.select(episodeID: 4)
            let expected: [Int64] = location == .front ? [4, 1, 2, 3] : location == .back ? [1, 2, 3, 4] : [1, 2, 4, 3]
            #expect(try await f.store.queue().map(\.id) == expected)
            try await f.player.select(episodeID: 1)
            #expect(try await f.store.queue().map(\.id) == expected)
        }
    }

    @Test(arguments: ["pause", "external", "end", "switch"])
    func listeningQueuesExactDurableActionFromActualPreferenceComposition(_ ending: String) async throws {
        try await PCPlaybackFixture.withFixture { f in
            try await f.store.selectSynchronizationAccount(UUID())
            try await f.player.select(episodeID: 1); f.engine.ready(); try await f.player.awaitPendingOperations()
            f.engine.position(12_345); try await f.player.awaitPendingOperations()
            switch ending {
            case "pause": try await f.player.pause()
            case "external": f.engine.state(.paused); try await f.player.awaitPendingOperations()
            case "end": f.engine.end(); try await f.player.awaitPendingOperations()
            default: try await f.player.select(episodeID: 2)
            }
            let actions = try await f.actions()
            #expect(actions.count == 1)
            let action = try #require(actions.first)
            #expect(action.action == .play && action.started == 0 && action.total == 100)
            #expect(action.position == (ending == "end" ? 100 : 12))
            #expect(action.podcast == "https://example.test/feed" && action.episode == "https://example.test/1.mp3")
            #expect(try await f.store.episode(id: 1)?.userState.positionMilliseconds == (ending == "end" ? 0 : 12_345))
            let reopened = try FeedLibraryStore(url: f.file)
            #expect(try await reopened.synchronizationQueue() == f.store.synchronizationQueue())
            try await reopened.close()
        }
    }

    @Test(arguments: ["disconnected", "unsubscribed", "local", "no-progress"])
    func ineligibleListeningDoesNotEnterOutbox(_ kind: String) async throws {
        try await PCPlaybackFixture.withFixture(local: kind == "local") { f in
            if kind != "disconnected" { try await f.store.selectSynchronizationAccount(UUID()) }
            if kind == "unsubscribed" { try await f.store.updatePreferences(feedID: 1) { $0.subscriptionState = .notSubscribed } }
            try await f.player.select(episodeID: 1); f.engine.ready(); try await f.player.awaitPendingOperations()
            if kind != "no-progress" { f.engine.position(12_345); try await f.player.awaitPendingOperations() }
            try await f.player.pause()
            #expect(try await f.actions().isEmpty)
        }
    }
}

@MainActor final class PCPlaybackEngine: PlaybackVolumeControlling {
    var reading: PlaybackEngineReading?
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    var generation = UUID(), commandID = UUID()
    var position: Int32 = 0, duration: Int32 = 100_000
    var playing = false
    var rate: Float = 1, maximumRate: Float = 4
    var volume: Float = 1
    var seeks: [Int64] = []
    var unloads = 0
    func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
        self.generation = generation; commandID = generation; position = Int32(positionMilliseconds); reading = nil; playing = false
    }
    func play(commandID: UUID) { self.commandID = commandID; playing = true; reading?.commandID = commandID; reading?.sample.status = .playing }
    func pause(commandID: UUID) { self.commandID = commandID; playing = false; reading?.commandID = commandID; reading?.sample.status = .paused }
    func seek(to milliseconds: Int64, commandID: UUID) {
        self.commandID = commandID; position = Int32(clamping: milliseconds); seeks.append(milliseconds)
        reading?.commandID = commandID; reading?.sample.positionMilliseconds = position
    }
    func setSpeed(_ value: Float, commandID: UUID) { self.commandID = commandID; rate = min(value, maximumRate); reading?.commandID = commandID; reading?.speed = rate }
    func setVolumeAdaptation(_ value: FeedVolumeAdaptation) {}
    func setSleepTimerVolume(_ value: Float) { volume = value }
    func unload() { reading = nil; playing = false; unloads += 1 }
    func ready() {
        reading = .init(generation: generation, commandID: commandID, sample: .init(positionMilliseconds: position,
            durationMilliseconds: duration, status: playing ? .playing : .paused), speed: rate)
        onEvent?(.ready(reading!))
    }
    func position(_ value: Int32, duration: Int32? = nil) {
        position = value; if let duration { self.duration = duration }
        reading?.sample.positionMilliseconds = value; reading?.sample.durationMilliseconds = self.duration
        if let reading { onEvent?(.position(reading)) }
    }
    func state(_ status: LibraryPlaybackSession.Status, buffering: Bool = false) {
        reading?.sample.status = status; reading?.buffering = buffering
        playing = status == .playing
        if let reading { onEvent?(.stateChanged(reading)) }
    }
    func end() { position(duration); if let reading { onEvent?(.ended(reading)) } }
}

@MainActor final class PCPlaybackFixture {
    let store: FeedLibraryStore, file: URL
    let download: DownloadPreferenceStore, queue: PlaybackQueuePreferenceStore
    let engine = PCPlaybackEngine()
    let routes: RoutedPlaybackEngine
    let player: PlaybackCoordinator
    final class Clock { var milliseconds: Int64 = 1_700_000_000_000 }
    let clock = Clock()
    init(root: URL) throws {
        file = root.appendingPathComponent("library.sqlite"); store = try FeedLibraryStore(url: file)
        download = try DownloadPreferenceStore(file: root.appendingPathComponent("downloads.json"))
        queue = try PlaybackQueuePreferenceStore(file: root.appendingPathComponent("queue.json"))
        routes = RoutedPlaybackEngine(local: engine)
        let download = download, queue = queue, clock = clock
        player = PlaybackCoordinator(store: store, engine: routes, preferences: { _ in
            PlaybackApplicationPreferences.resolve(download: download.value, queue: queue.value)
        }, clock: { Date(timeIntervalSince1970: Double(clock.milliseconds) / 1_000) })
    }
    func actions() async throws -> [SynchronizationEpisodeAction] {
        try await store.synchronizationQueue().compactMap { if case .episode(let action) = $0.value { action } else { nil } }
    }
    static func withFixture(local: Bool = false, _ body: (PCPlaybackFixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PC-I1-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try PCPlaybackFixture(root: root)
        let source = local ? "antennapod_local:fixture" : "https://example.test/feed"
        _ = try await f.store.insert(.init(feed: .init(format: .rss, title: "System podcast", episodes: (1...4).map {
            .init(identifier: "\($0)", title: "Episode \($0)", media: .init(url: "https://example.test/\($0).mp3", size: 0, durationMilliseconds: 100_000))
        }), source: source, responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        do { try await body(f); try await f.player.stop(); try await f.store.close() }
        catch { try? await f.player.stop(); try? await f.store.close(); throw error }
    }
}
