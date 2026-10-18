import UIKit
import AVKit
import NotTennaPodCore

/// A screen over the application's existing playback session; never constructs a player.
@MainActor final class PlaybackVideoViewController: UIViewController, @MainActor AVPictureInPictureControllerDelegate {
    let playback: PlaybackCoordinator
    let videoView = PlaybackVideoView()
    var onClose: (() -> Void)?, onFavoriteChanged: (() async -> Void)?
    var openPodcast: ((LibraryFeed) -> Void)?, openLink: ((String) -> Void)?
    var openPlaybackSettings: (() -> Void)?
    var restoreInterface: ((PlaybackVideoViewController, @escaping (Bool) -> Void) -> Void)?
    private let library: FeedLibraryStore?
    private let timePreferences: TimeDisplayPreferenceStore
    private let intervals: PlaybackIntervalPreferenceStore?
    private let speeds: PlaybackSpeedPreferenceStore?
    private let timerPreferences: SleepTimerPreferenceStore?
    private let queuePreferences: PlaybackQueuePreferenceStore?
    private let chapters: EpisodeChapterAccess?
    private let transcripts: TranscriptLoader?
    private var events: Task<Void, Never>?, libraryTask: Task<Void, Never>?
    private var feed: LibraryFeed?
    private var displayedEpisode: LibraryEpisode?
    private var currentID: Int64?
    private var pip: AVPictureInPictureController?
    private var requestedInitialLandscape = false
    /// Why the scene declined the initial landscape request (resizable iPad windows do); nil when honoured or pending.
    private(set) var landscapeRefusal: String?
    private weak var landscapeScene: UIWindowScene?
    private var observingDeviceOrientation = false
    /// Scenes that were upright before a video asked for landscape. Shared by every video screen: one reopened
    /// while the previous screen's return to portrait is still in flight must not take landscape as the user's choice.
    private static var uprightBeforeVideo = Set<ObjectIdentifier>()
    private var closed = false
    private let idleTimerOwner = UUID()
    private var favoriteSaving = false
    private var lastFailure: String?
    private lazy var messages = ModalMessagePresenter(owner: self)

    init(playback: PlaybackCoordinator, library: FeedLibraryStore?, timePreferences: TimeDisplayPreferenceStore,
         intervals: PlaybackIntervalPreferenceStore?, speeds: PlaybackSpeedPreferenceStore?,
         timerPreferences: SleepTimerPreferenceStore?, queuePreferences: PlaybackQueuePreferenceStore?,
         chapters: EpisodeChapterAccess?, transcripts: TranscriptLoader?) {
        self.playback = playback; self.library = library; self.timePreferences = timePreferences
        self.intervals = intervals; self.speeds = speeds; self.timerPreferences = timerPreferences
        self.queuePreferences = queuePreferences; self.chapters = chapters; self.transcripts = transcripts
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        overrideUserInterfaceStyle = .dark
    }
    required init?(coder: NSCoder) { fatalError() }
    isolated deinit {
        if observingDeviceOrientation { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
        PlaybackVideoIdleTimer.release(idleTimerOwner); events?.cancel(); libraryTask?.cancel(); if pip?.delegate === self { pip?.delegate = nil } }
    override func loadView() { view = videoView }
    override var prefersStatusBarHidden: Bool { !videoView.controlsVisible }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
    override var prefersHomeIndicatorAutoHidden: Bool { !videoView.controlsVisible }
    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(sceneActivated(_:)), name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneDeactivated(_:)), name: UIScene.willDeactivateNotification, object: nil)
        videoView.controlsChanged = { [weak self] in self?.setNeedsStatusBarAppearanceUpdate(); self?.setNeedsUpdateOfHomeIndicatorAutoHidden() }
        videoView.back = { [weak self] in self?.close() }
        videoView.playPause = { [weak self] in self?.perform { owner in
            if owner.playback.wantsPlayback { try await owner.playback.pause() } else { try await owner.playback.play() }
        } }
        videoView.rewind = { [weak self] in self?.skip(.rewind) }
        videoView.forward = { [weak self] in self?.skip(.forward) }
        videoView.seekTo = { [weak self] value in self?.perform { try await $0.playback.seek(to: value) } }
        videoView.toggleRemaining = { [weak self] in
            guard let self else { return }; do { try timePreferences.toggleRemainingTime(); update() } catch { showFailure(error.localizedDescription) }
        }
        videoView.editInterval = { [weak self] direction in
            guard let self, let intervals, presentedViewController == nil else { return }
            present(PlaybackIntervalController(direction: direction, preferences: intervals), animated: true)
        }
        videoView.favorite = { [weak self] in self?.toggleFavorite() }
        videoView.timer = { [weak self] in self?.showTimer() }
        videoView.share = { [weak self] in self?.showShare(anchor: $0) }
        videoView.overflow = { [weak self] in self?.showMenu(anchor: $0) }
        let stream = playback.events()
        events = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .libraryChanged: reloadContext()
                case .engineFailed(let message): showFailure(message)
                default: break
                }
                update()
            }
        }
        update()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); closed = false; update(); videoView.resetAutoHide(); messages.resume()
        if UIAccessibility.isVoiceOverRunning { videoView.setControlsVisible(true) }
        if !requestedInitialLandscape, let scene = view.window?.windowScene {
            requestedInitialLandscape = true
            landscapeScene = scene
            if scene.effectiveGeometry.interfaceOrientation.isPortrait { Self.uprightBeforeVideo.insert(ObjectIdentifier(scene)) }
            UIDevice.current.beginGeneratingDeviceOrientationNotifications(); observingDeviceOrientation = true
            // Match the source video activity's initial landscape preference.
            // Resizable scenes may decline it; layout always uses actual bounds.
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { [weak self] error in
                self?.landscapeRefusal = error.localizedDescription
                NSLog("Video landscape preference was not applied: %@", error.localizedDescription)
            }
        }
        if view.window?.windowScene?.activationState == .foregroundActive { PlaybackVideoIdleTimer.acquire(idleTimerOwner) }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        PlaybackVideoIdleTimer.release(idleTimerOwner)
        videoView.cancelAutoHide()
        if closed && pip?.isPictureInPictureActive != true { videoView.attach(nil) }
        if closed || isBeingDismissed { restoreOrientationAfterLandscape() }
    }
    /// The source's landscape preference belongs to the video activity alone: when it finishes, the
    /// screen underneath follows the device again. A scene geometry request outlives this controller,
    /// so closing it would otherwise leave the whole app sideways on an upright phone.
    private func restoreOrientationAfterLandscape() {
        guard observingDeviceOrientation else { return }
        observingDeviceOrientation = false
        let device = UIDevice.current.orientation
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        guard let scene = landscapeScene else { return }
        // Held sideways: stay, as Android's sensor orientation would. Upright, flat or unknown: the orientation
        // before the video. The landscape request may still be in flight, so the current geometry does not decide.
        if device.isLandscape { Self.uprightBeforeVideo.remove(ObjectIdentifier(scene)); return }
        guard device.isPortrait || Self.uprightBeforeVideo.contains(ObjectIdentifier(scene)) else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: [.portrait, .portraitUpsideDown])) { error in
            NSLog("Orientation after video was not restored: %@", error.localizedDescription)
        }
    }
    @objc private func sceneActivated(_ notification: Notification) {
        guard !closed, let scene = notification.object as? UIWindowScene, scene === viewIfLoaded?.window?.windowScene else { return }
        PlaybackVideoIdleTimer.acquire(idleTimerOwner)
    }
    @objc private func sceneDeactivated(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, scene === viewIfLoaded?.window?.windowScene else { return }
        PlaybackVideoIdleTimer.release(idleTimerOwner)
    }
    override func viewSafeAreaInsetsDidChange() { super.viewSafeAreaInsetsDidChange(); videoView.setNeedsLayout() }
    override func accessibilityPerformEscape() -> Bool { close(); return true }
    override var keyCommands: [UIKeyCommand]? {
        [.init(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape)),
         .init(input: " ", modifierFlags: [], action: #selector(space))]
    }
    @objc private func escape() { close() }
    @objc private func space() { videoView.playPause?() }

    func update() {
        guard isViewLoaded, !closed else { return }
        if currentID != playback.episode?.id { currentID = playback.episode?.id; reloadContext(); videoView.showError(nil) }
        let source = playback.videoPresentation
        let track = source?.mediaTracks.first { $0.id == source?.selectedVideoTrackID && $0.kind == .video }
        let geometry = track?.videoGeometry
        let aspect = geometry.map { Double($0.width) * $0.pixelAspectRatio / Double(max(1, $0.height)) }
        videoView.attach(source?.videoDisplayLayer, aspect: aspect, rotationDegrees: geometry?.rotationDegrees ?? 0)
        let nextPiP = source?.videoPictureInPicture?.controller
        if pip !== nextPiP {
            if pip?.delegate === self { pip?.delegate = nil; pip?.canStartPictureInPictureAutomaticallyFromInline = false }
            pip = nextPiP; pip?.delegate = self; pip?.canStartPictureInPictureAutomaticallyFromInline = true
        }
        if playback.phase != .failed { videoView.showError(nil); lastFailure = nil }
        let sample = playback.sample
        videoView.update(position: Int64(sample?.positionMilliseconds ?? playback.episode?.userState.positionMilliseconds ?? 0),
            duration: Int64(sample?.durationMilliseconds ?? playback.episode?.details.media?.durationMilliseconds ?? 0),
            playing: playback.wantsPlayback, buffering: playback.isBuffering || playback.phase == .preparing, seekable: sample?.seekable == true,
            speed: playback.speed, remaining: timePreferences.value.showRemainingTime, respectsSpeed: timePreferences.value.timeRespectsSpeed)
        videoView.updateActions(favorite: displayedEpisode?.userState.isFavorite == true,
            timer: playback.sleepTimerValue != nil, canShare: feed.map { !$0.source.isLocalFeedSource } == true)
        if playback.episode == nil || (source?.mediaTracks.isEmpty == false && track == nil && playback.phase != .preparing) { close() }
    }
    private func reloadContext() {
        libraryTask?.cancel()
        guard let library, let id = playback.episode?.id else { feed = nil; displayedEpisode = nil; return }
        libraryTask = Task { [weak self] in
            do {
                let feedID = try await library.feedID(forEpisode: id)
                let feed = try await library.playbackFeedHeader(id: feedID)
                let episode = feed == nil ? nil : try await library.episode(id: id)
                guard let self, !Task.isCancelled, playback.episode?.id == id else { return }
                self.feed = feed; displayedEpisode = episode; update()
            } catch is CancellationError { } catch { self?.showFailure(error.localizedDescription) }
        }
    }
    private func perform(_ action: @escaping @MainActor (PlaybackVideoViewController) async throws -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do { try await action(self) } catch is CancellationError { } catch { showFailure(error.localizedDescription) }
        }
    }
    private func skip(_ direction: PlaybackIntervalDirection) {
        let value = direction == .rewind ? intervals?.value.rewindSeconds ?? 10 : intervals?.value.forwardSeconds ?? 30
        perform { try await $0.playback.skipInterval(seconds: value, direction: direction) }
    }
    func close() {
        guard !closed else { return }; closed = true
        PlaybackVideoIdleTimer.release(idleTimerOwner)
        pip?.canStartPictureInPictureAutomaticallyFromInline = false
        if pip?.isPictureInPictureActive == true { pip?.stopPictureInPicture() }
        videoView.attach(nil); videoView.cancelAutoHide()
        dismiss(animated: true) { [weak self] in self?.onClose?() }
    }
    func showFailure(_ detail: String) {
        guard !closed, isViewLoaded else { return }
        let explanation = Appearance.text(PlaybackFailureExplanation(details: detail).key)
        videoView.showError(explanation)
        guard lastFailure != detail else { return }
        lastFailure = detail
        messages.present(SourceMessageController(title: Appearance.text("error_label"), message: explanation, details: detail))
    }
    private func toggleFavorite() {
        guard let library, let episode = displayedEpisode, !favoriteSaving else { return }
        favoriteSaving = true; videoView.favoriteButton.isEnabled = false
        perform { owner in
            defer { owner.favoriteSaving = false; owner.videoView.favoriteButton.isEnabled = true }
            try await library.setFavorite(episodeID: episode.id, favorite: !episode.userState.isFavorite)
            await owner.onFavoriteChanged?(); owner.reloadContext()
        }
    }
    private func showTimer() {
        guard let timerPreferences, let queuePreferences, presentedViewController == nil else { return }
        present(SleepTimerController(playback: playback, preferences: timerPreferences, queuePreferences: queuePreferences,
            library: library, openPlaybackSettings: { [weak self] in self?.closeThen { self?.openPlaybackSettings?() } }), animated: true)
    }
    private func showShare(anchor: UIView) {
        guard let feed, let displayedEpisode, !feed.source.isLocalFeedSource, presentedViewController == nil else { return }
        present(EpisodeShareController(feed: feed, episode: displayedEpisode) { [weak self, weak anchor] value in
            guard let self else { return }
            let activity = UIActivityViewController(activityItems: [value], applicationActivities: nil)
            let view = anchor?.window == nil ? videoView.shareButton : anchor!
            activity.popoverPresentationController?.sourceView = view; activity.popoverPresentationController?.sourceRect = view.bounds
            present(activity, animated: true)
        }, animated: true)
    }
    private func showMenu(anchor: UIView) {
        guard presentedViewController == nil else { return }
        var actions: [(id: String, title: String)] = [("audio", Appearance.text("audio_controls")), ("speed", Appearance.text("playback_speed"))]
        let remaining = feed.flatMap { feed in displayedEpisode.map { PlayerOverflowAction.available(episode: $0, feed: feed) } } ?? []
        for action in remaining where action == .openPodcast || action == .visitWebsite { actions.append((action.rawValue, Appearance.text(action.titleKey))) }
        actions.append(("audioOnly", Appearance.text("player_switch_to_audio_only")))
        actions.append(("chapters", Appearance.text("chapters_label")))
        for action in remaining where action == .transcript || action == .comments { actions.append((action.rawValue, Appearance.text(action.titleKey))) }
        videoView.cancelAutoHide()
        present(PopupMenuController(title: "", identifier: "videoOverflow", anchor: anchor, anchorFraction: .zero,
            actions: actions.map { ("videoMenu-" + $0.id, $0.title) }, toolbarTrailing: true) { [weak self] id in
                self?.menuAction(String(id.dropFirst("videoMenu-".count)))
            }, animated: true)
    }
    private func menuAction(_ id: String) {
        switch id {
        case "audio":
            let body = PlaybackVideoAudioTracksView(playback: playback) { [weak self] error in self?.showFailure(error.localizedDescription) }
            present(SourceMessageController(title: Appearance.text("audio_controls"), message: "",
                positive: .init(title: Appearance.text("close_label"), identifier: "videoAudioClose"), customBody: body), animated: true)
        case "speed": if let speeds { present(PlaybackSpeedController(playback: playback, preferences: speeds), animated: true) }
        case "audioOnly": close()
        case "chapters":
            if let library, let chapters { present(ChaptersController(playback: playback, library: library, access: chapters,
                notice: { [weak self] in self?.showNotice($0) }, failure: { [weak self] in self?.showFailure($0.localizedDescription) },
                openLink: { [weak self] in self?.openLink?($0) }), animated: true) }
        case PlayerOverflowAction.openPodcast.rawValue: if let feed { closeThen { self.openPodcast?(feed) } }
        case PlayerOverflowAction.visitWebsite.rawValue:
            if let feed, let episode = displayedEpisode, let url = EpisodeWebsite.link(episode: episode.details.link, feed: feed.metadata.link) { openLink?(url) }
        case PlayerOverflowAction.transcript.rawValue:
            if let library, let transcripts { present(TranscriptController(playback: playback, library: library, loader: transcripts,
                notice: { [weak self] in self?.showNotice($0) }, failure: { [weak self] in self?.showFailure($0.localizedDescription) }), animated: true) }
        case PlayerOverflowAction.comments.rawValue:
            guard let url = displayedEpisode?.details.socialInteractionURL else { return }
            present(SourceMessageController(title: Appearance.text("visit_social_interact_confirm_dialog_title"),
                message: String(format: Appearance.text("visit_social_interact_confirm_dialog_message"), url),
                positive: .init(title: Appearance.text("confirm_label"), identifier: "videoCommentsConfirm", perform: { [weak self] in self?.openLink?(url) }, performAfterDismiss: true),
                negative: .init(title: Appearance.text("cancel_label"), identifier: "videoCommentsCancel")), animated: true)
        default: break
        }
    }
    private func closeThen(_ action: @escaping () -> Void) {
        closed = true; PlaybackVideoIdleTimer.release(idleTimerOwner)
        videoView.attach(nil); videoView.cancelAutoHide()
        pip?.canStartPictureInPictureAutomaticallyFromInline = false
        if pip?.isPictureInPictureActive == true { pip?.stopPictureInPicture() }
        dismiss(animated: true) { [weak self] in self?.onClose?(); action() }
    }
    private func showNotice(_ message: String) {
        messages.present(SourceMessageController(message: message))
    }
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { videoView.setControlsVisible(false) }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) { showFailure(error.localizedDescription) }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        if let restoreInterface { restoreInterface(self, completionHandler) }
        else { completionHandler(viewIfLoaded?.window != nil) }
    }
}
