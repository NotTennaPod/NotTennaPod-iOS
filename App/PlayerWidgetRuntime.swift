import UIKit
import WidgetKit
import NotTennaPodCore

/// Keeps the widget's App Group snapshot in step with the player and reloads the widget and the Control Center
/// control when what they show changes. Android redraws on play/pause and every second while playing; here the
/// widget's timeline advances the position by itself, so the app writes on visible changes (episode, play state,
/// speed, a seek, the time settings, the cover) and, while playing, renews the snapshot's lease about once a
/// minute on its playback events, or a live stream's position ticks (`PlayerWidgetLease`).
@MainActor final class PlayerWidgetRuntime {
    private let playback: PlaybackCoordinator
    private let library: FeedLibraryStore
    private let timeDisplay: @MainActor () -> TimeDisplayPreferences
    private let store: PlayerWidgetStore
    private let reload: @MainActor (_ widget: Bool, _ control: Bool) -> Void
    private let now: @MainActor () -> Date
    /// Monotonic, for the renewal cadence: a wall-clock change cannot hold a renewal back.
    private let clock: @MainActor () -> ContinuousClock.Instant
    private var events: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var coverTask: Task<Void, Never>?
    private var artwork: EpisodeArtworkView?
    private var coverEpisode: Int64?
    private var coverName: String?
    private var restored = false
    /// Widget button commands running now (`runWidgetCommand`); the system reloads the widget after each.
    private var widgetCommands = 0
    /// The last written snapshot; `.some(nil)` once "No media playing" was written.
    private(set) var written: PlayerWidgetSnapshot??
    /// When `written` was written, by `clock`; nil renews a playing snapshot at the next refresh.
    private var writtenAt: ContinuousClock.Instant?

    init(playback: PlaybackCoordinator, library: FeedLibraryStore, store: PlayerWidgetStore,
         timeDisplay: @escaping @MainActor () -> TimeDisplayPreferences,
         reload: @escaping @MainActor (_ widget: Bool, _ control: Bool) -> Void = PlayerWidgetRuntime.reloadSystem,
         now: @escaping @MainActor () -> Date = { Date() },
         clock: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        self.playback = playback; self.library = library; self.store = store; self.timeDisplay = timeDisplay
        self.reload = reload; self.now = now; self.clock = clock
    }

    static func reloadSystem(widget: Bool, control: Bool) {
        if widget { WidgetCenter.shared.reloadTimelines(ofKind: PlayerWidget.kind) }
        if control { ControlCenter.shared.reloadControls(ofKind: PlayerWidget.controlKind) }
    }

    /// Runs the command of a widget button (Play/Pause, Rewind, Fast-forward, Skip episode). The system reloads
    /// the widget once the command returns, so the result is written first, after a start or a seek still under
    /// way has settled (at most `settleLimit`), and the app does not reload the widget itself meanwhile. Its own
    /// reloads would replace the widget again a second or two later (each reload builds the whole timeline), and
    /// a tap on the widget at that moment is lost: Pause pressed shortly after Rewind did nothing.
    func runWidgetCommand(settleLimit: Duration = .seconds(2), _ command: @MainActor () async throws -> Void) async throws {
        let settle = try await applyWidgetCommand(settleLimit: settleLimit, command)
        await settle()
    }

    /// `runWidgetCommand` in two steps: the command now, and the returned step (the settle wait, then the write)
    /// to run after it, outside any queue of commands, so a later command never waits behind a settle wait. The
    /// app's own reloads stay suppressed from the command until that step ends.
    func applyWidgetCommand(settleLimit: Duration = .seconds(2),
                            _ command: @MainActor () async throws -> Void) async throws -> @MainActor () async -> Void {
        widgetCommands += 1
        do { try await command() } catch { widgetCommands -= 1; throw error }
        return { [weak self] in
            guard let self else { return }
            defer { widgetCommands -= 1 }
            await settled(limit: settleLimit)
            refresh()
        }
    }

    /// Asks for the widget to be drawn again from the current snapshot.
    func reloadWidget() { reload(true, false) }

    /// Whether the player wants to play but its position does not advance yet: starting, seeking or buffering.
    private static func isBetweenStates(_ playback: PlaybackCoordinator) -> Bool {
        playback.systemSnapshot.map { $0.wantsPlayback && $0.rate == 0 } ?? false
    }

    /// Returns once the player is not between states, or after `limit`; a later change reloads the widget as usual.
    private func settled(limit: Duration) async {
        let playback = playback
        guard Self.isBetweenStates(playback) else { return }
        let waiting = Task { @MainActor in
            // The stream starts with the current state, so a change before this point is not missed.
            for await _ in playback.events() where !Self.isBetweenStates(playback) { return }
        }
        let limiting = Task { try? await Task.sleep(for: limit); waiting.cancel() }
        await waiting.value
        limiting.cancel()
    }

    func start() {
        guard events == nil else { return }
        let playback = playback
        events = Task { [weak self] in
            // Write nothing before the saved episode is back, so the widget never flashes "No media playing".
            try? await playback.restore()
            let stream = playback.events()
            self?.restored = true
            for await _ in stream {
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
        // A live stream (unknown duration) has no position events; its ticks still renew the playing lease.
        playback.onUnknownDurationTick = { [weak self] in self?.refresh() }
        // "Show remaining time" changes in the player; leaving the app is when the widget is seen again.
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        // The app is quit while it plays (force-quit from the app switcher): playback ends with the process, so the
        // widget must not keep showing Pause and a running time (Android updates the widget in onDestroy). iOS does
        // not always send this (memory, a crash); the playing lease covers those (`PlayerWidgetLease`).
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.processEnds() }
        })
        // The clock was set: a playing snapshot's dates no longer fit it, so renew it now.
        observers.append(NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.writtenAt = nil
                self?.refresh()
            }
        })
    }

    /// Writes the current episode as paused at its current position; a best effort, as iOS may end the app without it.
    func processEnds() {
        guard restored, var last = PlayerWidgetPlayback.snapshot(playback: playback, timeDisplay: timeDisplay(),
                                                                 cover: coverName, now: now()) else { return }
        guard last.isPlaying || last.positionRate > 0 else { return }
        last.isPlaying = false; last.positionRate = 0
        do { try store.write(last) } catch { return }
        written = .some(last); writtenAt = clock()
        reload(true, true)
    }

    func stop() {
        events?.cancel(); events = nil
        playback.onUnknownDurationTick = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        coverTask?.cancel(); coverTask = nil; artwork?.cancelLoading(); artwork = nil
    }

    func refresh() {
        guard restored else { return }
        let episode = playback.episode
        if episode?.id != coverEpisode { loadCover(episode) }
        let next = PlayerWidgetPlayback.snapshot(playback: playback, timeDisplay: timeDisplay(),
                                                 cover: coverName, now: now())
        let instant = clock()
        guard PlayerWidgetLease.needsWrite(next, after: written, elapsed: writtenAt.map { instant - $0 }) else { return }
        let playStateChanged = written.map { $0?.isPlaying != next?.isPlaying } ?? true
        do { try store.write(next) } catch { return }
        written = .some(next); writtenAt = instant
        // While a widget button's command runs, the system reloads the widget when it returns. A renewal reloads
        // the widget only: the control reads the lease whenever the system asks for its value.
        let widget = widgetCommands == 0
        if widget || playStateChanged { reload(widget, playStateChanged) }
    }

    /// The episode's cover as the Now Playing artwork loads it (episode image, then the podcast's).
    private func loadCover(_ episode: LibraryEpisode?) {
        coverTask?.cancel(); artwork?.cancelLoading(); artwork = nil
        coverEpisode = episode?.id; coverName = nil
        guard let episode else { return }
        let library = library, store = store
        coverTask = Task { [weak self] in
            guard let feedID = try? await library.feedID(forEpisode: episode.id),
                  let feed = try? await library.playbackFeedHeader(id: feedID), !Task.isCancelled,
                  let self, coverEpisode == episode.id else { return }
            let cover = EpisodeArtworkView(feed: feed, episode: episode, library: library)
            artwork = cover
            cover.onArtworkChange = { [weak self, weak cover] in
                guard let self, coverEpisode == episode.id,
                      let image = cover?.artwork(size: .init(width: 300, height: 300), scale: 1),
                      let data = Self.thumbnail(image).pngData(),
                      let name = try? store.writeCover(data, episodeID: episode.id) else { return }
                coverName = name
                refresh()
            }
        }
    }

    /// At most 300 × 300 pixels, centre-cropped to a square (the widget shows 48 points, or a blurred background).
    static func thumbnail(_ image: UIImage, side: CGFloat = 300) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let target = min(side, max(size.width * image.scale, size.height * image.scale))
        let scale = target / min(size.width, size.height)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: target, height: target), format: format).image { _ in
            image.draw(in: CGRect(x: (target - size.width * scale) / 2, y: (target - size.height * scale) / 2,
                                  width: size.width * scale, height: size.height * scale))
        }
    }

    isolated deinit { stop() }
}

extension PlayerWidgetIntentRouter {
    /// The app's binding: the widget's and the control's commands act on the live player with the live
    /// "Rewind skip time" / "Fast-forward skip time". The widget's buttons run through `widget`
    /// (`PlayerWidgetRuntime.runWidgetCommand`); the control's toggle is reloaded by the system as a control, so the
    /// app still reloads the widget for it.
    static func bind(playback: @escaping @MainActor () -> PlaybackCoordinator?,
                     intervals: @escaping @MainActor () -> PlaybackIntervalPreferences,
                     widget: @escaping @MainActor () -> PlayerWidgetRuntime? = { nil }) {
        let commands = bound(playback: playback, intervals: intervals, widget: widget)
        perform = { command, source in
            let after = try await commands(command, source)
            await after?()
        }
    }

    /// A command applied to the live player, returning what follows it for the widget: the settle wait and write,
    /// then the redraw of a refused legacy button. The app applies commands through its ordered dispatcher
    /// (`LibraryStartup.runCommand`) and runs what follows outside it.
    typealias Commands = @MainActor (PlayerWidgetCommand, Source) async throws -> (@MainActor () async -> Void)?

    /// The commands acting on the live player, as `bind` installs them.
    static func bound(playback: @escaping @MainActor () -> PlaybackCoordinator?,
                      intervals: @escaping @MainActor () -> PlaybackIntervalPreferences,
                      widget: @escaping @MainActor () -> PlayerWidgetRuntime? = { nil }) -> Commands {
        { command, source in
            guard let playback = playback() else { return nil }
            var accepted = true
            let run: @MainActor () async throws -> Void = {
                accepted = try await PlayerWidgetPlayback.perform(command, playback: playback, intervals: intervals())
            }
            switch source {
            case .widget:
                let runtime = widget()
                let settle: (@MainActor () async -> Void)?
                if let runtime { settle = try await runtime.applyWidgetCommand(run) } else { try await run(); settle = nil }
                // A button drawn before buttons said Play or Pause, refused (nothing to pause): have the widget
                // drawn again, with today's buttons.
                let refused = command == .playPause && !accepted
                return {
                    await settle?()
                    if refused { widget()?.reloadWidget() }
                }
            case .control:
                try await run()
                return nil
            }
        }
    }
}
