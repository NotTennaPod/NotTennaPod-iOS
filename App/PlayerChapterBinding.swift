import UIKit
import NotTennaPodCore

/// Each surface keeps its own status subscription and transient chapter list.
@MainActor final class PlayerChapterBinding {
    let presentation: EpisodeChapterPresentation
    private let playback: PlaybackCoordinator
    private var events: Task<Void, Never>?
    private var episodeID: Int64?
    private var phase: PlaybackCoordinator.Phase?
    private var wantsPlayback: Bool?
    private var position: Int32?
    private var observers: [NSObjectProtocol] = []

    init(surface: EpisodeChapterPresentation.Surface, playback: PlaybackCoordinator,
         library: FeedLibraryStore, access: EpisodeChapterAccess,
         timePreferences: TimeDisplayPreferenceStore? = nil) {
        self.playback = playback
        presentation = .init(surface: surface, store: library, access: access, displayPosition: { [weak playback] value in
            Int64(PlaybackSpeed.displayTime(Int32(truncatingIfNeeded: value), speed: playback?.speed ?? 1,
                respectsSpeed: timePreferences?.value.timeRespectsSpeed ?? false))
        })
    }
    isolated deinit {
        events?.cancel(); presentation.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
    func attach(to scene: UIScene?) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers = []
        guard let scene else { stop(); return }
        observers = [
            NotificationCenter.default.addObserver(forName: UIScene.didEnterBackgroundNotification, object: scene, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            },
            NotificationCenter.default.addObserver(forName: UIScene.willEnterForegroundNotification, object: scene, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.start() }
            }
        ]
        if scene.activationState != .background { start() }
    }
    func start() {
        guard events == nil else { return }
        episodeID = playback.episode?.id; phase = playback.phase; wantsPlayback = playback.wantsPlayback
        position = playback.sample?.positionMilliseconds
        presentation.reload(episodeID: episodeID)
        let stream = playback.events()
        events = Task { [weak self] in
            for await _ in stream {
                guard let self, !Task.isCancelled else { return }
                let changed = episodeID != playback.episode?.id || phase != playback.phase || wantsPlayback != playback.wantsPlayback
                let nextPosition = playback.sample?.positionMilliseconds
                episodeID = playback.episode?.id; phase = playback.phase; wantsPlayback = playback.wantsPlayback
                if changed { presentation.reload(episodeID: episodeID) }
                if nextPosition != position, let nextPosition { presentation.updatePosition(Int64(nextPosition)) }
                position = nextPosition
            }
        }
    }
    func refresh() { presentation.reload(episodeID: playback.episode?.id, forceRefresh: true) }
    func stop() { events?.cancel(); events = nil; presentation.stop() }
}
