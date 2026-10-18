import UIKit
import NotTennaPodCore

// Player, video presentation and playback dialogs.
extension LibraryViewController {
    /// Runs on every playback change, including each position tick: a tick updates only
    /// the player's own position and time; rows and the shell update when the episode or play/pause changes.
    /// Nothing is drawn while the app is in the background (screen locked); it catches up once on return.
    func updatePlayer() {
        guard UIApplication.shared.applicationState != .background else { backgroundUpdatePending = true; return }
        let episodeID = playback?.episode?.id
        let statusChanged = lastInformationEpisode != episodeID || lastInformationStatus != playback?.sample?.status
        let speedChanged = lastInformationSpeed != playback?.speed
        lastInformationEpisode = episodeID
        lastInformationStatus = playback?.sample?.status
        lastInformationSpeed = playback?.speed
        // With change sets the screen follows the library by itself; only a screen fed by snapshots reads it again.
        if statusChanged, screenUpdater == nil { reloadLibrary(preservingEpisodeDetails: true, keepsUnchangedScreen: true) }
        else if speedChanged { updateQueueInformation() }
        let visible = episodeID != nil
        playerView?.isHidden = !visible || settingsVisible
        if !visible { playerView?.setExpanded(false, animated: false) }
        // The playing episode and its podcast's header, keyed (never the podcast's episodes); a podcast no list shows is
        // read through the player's own visibility (`playerFeedHeader`).
        let value = episodeID.flatMap(libraryEpisode)
        let header = value.map { value -> LibraryFeed in var feed = value.feed; feed.episodes = []; return feed }
        playerView?.update(feed: header, stored: value?.episode, held: header == nil ? episodeID.flatMap(heldFeed) : nil)
        // Android's Home re-queries Get surprised and Continue on PlayerStatusEvent: the picks are checked against the clock.
        if statusChanged, screenUpdater != nil, homeModel != nil, case .destination(.home) = path.last { patchHome(LibraryMirrorDelta()) }
        if let id = episodeID,
           requestedVideoEpisodeID == id || (playback?.wantsPlayback == true && id != lastAutomaticVideoEpisodeID),
           playback?.videoPresentation?.videoDisplayLayer != nil {
            presentVideo(preferThisScene: false)
        }
        // Episode buttons show Pause only on the playing episode.
        let rowState = (episode: episodeID, playing: playback?.wantsPlayback == true)
        if rowState != playerRowState { playerRowState = rowState; updateDownloadRows() }
        // The shell makes room for the player when it appears, goes or changes episode.
        let shellState = (episode: episodeID, visible: visible)
        if shellState != playerShellState { playerShellState = shellState; view.setNeedsLayout() }
        if let preview = presentedViewController as? FeedPreviewController,
           let child = preview.contentController as? LibraryViewController {
            child.updatePlayer()
        }
    }

    /// The podcast of the player's episode when no list shows it (PROTOCOL §6.8): read once per episode through the
    /// player's own read; the player is updated when it arrives.
    private func heldFeed(_ episodeID: Int64) -> LibraryFeed? {
        if let held = heldPlayerFeed, held.episode == episodeID { return held.feed }
        guard heldPlayerFeedRequest != episodeID, let library else { return nil }
        heldPlayerFeedRequest = episodeID
        Task { [weak self] in
            let feed = try? await library.readers().quick.playerFeedHeader(id: library.feedID(forEpisode: episodeID))
            guard let self, heldPlayerFeedRequest == episodeID, let feed else { return }
            heldPlayerFeed = (episodeID, feed)
            updatePlayer()
        }
        return nil
    }

    func requestVideo() {
        guard let playback, let id = playback.episode?.id else { return }
        preferVideoInThisScene()
        requestedVideoEpisodeID = id
        if playback.videoPresentation?.videoDisplayLayer != nil { presentVideo(); return }
        presentVideo()
        // A restored paused item has no prepared decoder yet. Prepare through the
        // same coordinator without changing its retained Play/Pause intent.
        let play = playback.wantsPlayback
        Task { [weak self] in
            do { try await playback.select(episodeID: id, play: play); self?.updatePlayer() }
            catch is CancellationError { }
            catch { self?.requestedVideoEpisodeID = nil; self?.showError(error) }
        }
    }

    func preferVideoInThisScene() {
        if let previous = Self.videoScreenOwner, previous !== self { previous.videoController?.close() }
        Self.videoScreenOwner = self
        lastAutomaticVideoEpisodeID = nil
    }

    private func presentVideo(preferThisScene: Bool = true) {
        guard viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive else { return }
        if preferThisScene { preferVideoInThisScene() }
        guard Self.videoScreenOwner == nil || Self.videoScreenOwner === self else { return }
        guard let playback, let timeDisplayPreferences, let episodeID = playback.episode?.id,
              playback.videoPresentation?.videoDisplayLayer != nil || requestedVideoEpisodeID == episodeID,
              presentedViewController == nil, viewIfLoaded?.window != nil else { return }
        let controller = PlaybackVideoViewController(playback: playback, library: library,
            timePreferences: timeDisplayPreferences, intervals: intervalPreferences, speeds: speedPreferences,
            timerPreferences: sleepTimerPreferences, queuePreferences: playbackQueuePreferences,
            chapters: chapterAccess, transcripts: transcriptLoader)
        Self.videoScreenOwner = self
        requestedVideoEpisodeID = nil
        lastAutomaticVideoEpisodeID = playback.episode?.id
        controller.onClose = { [weak self, weak controller] in
            guard let self, videoController === controller else { return }
            lastAutomaticVideoEpisodeID = self.playback?.episode?.id
            videoController = nil
        }
        controller.onFavoriteChanged = { [weak self] in await self?.reloadLibrary(preservingEpisodeDetails: true)?.value }
        controller.openPodcast = { [weak self] feed in
            if feed.subscriptionState == .notSubscribed { self?.fetch(feed.source) }
            else { self?.drawerAction(.feed(feed.id)) }
        }
        controller.openLink = { [weak self] in self?.openWebsite($0) }
        controller.openPlaybackSettings = { [weak self] in self?.push(.settings(.playback)) }
        controller.restoreInterface = { [weak self] controller, completion in
            guard let self, viewIfLoaded?.window != nil else { completion(false); return }
            if presentedViewController === controller { completion(true) }
            else if presentedViewController == nil { present(controller, animated: true) { completion(true) } }
            else { completion(false) }
        }
        playerView?.setExpanded(false, animated: false)
        videoController = controller
        present(controller, animated: true)
    }

    func presentPlayerOverflow(feed: LibraryFeed, episode: LibraryEpisode, anchor: UIView) {
        guard presentedViewController == nil else { return }
        let actions = PlayerOverflowAction.available(episode: episode, feed: feed)
        present(PopupMenuController(title: "", identifier: "playerOverflowMenu", anchor: anchor,
            anchorFraction: .zero, actions: actions.map { ("playerOverflow-" + $0.rawValue, Appearance.text($0.titleKey)) },
            toolbarTrailing: true) { [weak self] id in
                guard let self, let action = actions.first(where: { "playerOverflow-" + $0.rawValue == id }) else { return }
                switch action {
                case .openPodcast:
                    if feed.subscriptionState == .notSubscribed { fetch(feed.source) }
                    else { drawerAction(.feed(feed.id)) }
                case .visitWebsite:
                    if let link = EpisodeWebsite.link(episode: episode.details.link, feed: feed.metadata.link) { openWebsite(link) }
                case .transcript:
                    guard let playback, let library else { return }
                    present(TranscriptController(playback: playback, library: library, loader: transcriptLoader,
                        notice: { [weak self] in self?.showNotice($0) }, failure: { [weak self] in self?.showError($0) }), animated: true)
                case .comments:
                    guard let url = episode.details.socialInteractionURL else { return }
                    present(SourceMessageController(title: Appearance.text("visit_social_interact_confirm_dialog_title"),
                        message: String(format: Appearance.text("visit_social_interact_confirm_dialog_message"), url),
                        positive: .init(title: Appearance.text("confirm_label"), identifier: "playerCommentsConfirm",
                            perform: { [weak self] in self?.openWebsite(url) }, performAfterDismiss: true),
                        negative: .init(title: Appearance.text("cancel_label"), identifier: "playerCommentsCancel")), animated: true)
                }
            }, animated: true)
    }

    func showPlaybackError(_ message: String) {
        requestedVideoEpisodeID = nil
        if let videoController, videoController.presentingViewController != nil {
            videoController.showFailure(message); return
        }
        let dialog = SourceMessageController(title: Appearance.text("error_label"),
            message: Appearance.text(PlaybackFailureExplanation(details: message).key), details: message) { [weak self] in
                self?.playerView?.setExpanded(false)
            }
        messages.present(dialog)
    }

    func showStreamingConfirmation() {
        guard let playback, let mobileNetworkPreferences else { return }
        func accept(always: Bool) {
            Task { [weak self] in
                do {
                    if always { try mobileNetworkPreferences.setAllowed(.streaming, true) }
                    // The affirmative actions call service Play. Mini-player and
                    // row actions reselect instead, so cancellation can warn again.
                    try await playback.play()
                } catch is CancellationError { }
                catch { self?.showError(error) }
            }
        }
        let dialog = SourceMessageController(title: Appearance.text("stream_label"),
            message: Appearance.text("confirm_mobile_streaming_notification_message"),
            positive: .init(title: Appearance.text("confirm_mobile_streaming_button_once"), identifier: "streamingOnce",
                            perform: { accept(always: false) }, performAfterDismiss: true),
            negative: .init(title: Appearance.text("confirm_mobile_streaming_button_always"), identifier: "streamingAlways",
                            perform: { accept(always: true) }, performAfterDismiss: true),
            neutral: .init(title: Appearance.text("cancel_label"), identifier: "streamingCancel"))
        messages.present(dialog)
    }
}
