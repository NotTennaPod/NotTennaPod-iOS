import UIKit
import NotTennaPodCore

// Links, shared text, documents, Home Screen quick actions and App Intents.
extension LibraryViewController {
    /// Routes an opened URL; false when it is not an entry point.
    @discardableResult func openExternalURL(_ url: URL) -> Bool {
        guard let route = ExternalEntry.route(for: url) else { return false }
        openExternal(route)
        return true
    }

    /// Runs an entry route now, or when this screen first appears (a cold launch delivers it before
    /// the window shows the screen).
    func openExternal(_ route: ExternalEntry.Route) {
        guard !isPreview else { return }
        // The route decides what shows: a restored player does not expand after it.
        restoredPlayerExpansion = false
        guard isOnScreen else { pendingExternalRoute = route; return }
        pendingExternalRoute = nil
        switch route {
        case .feedPreview(let text): openExternalFeedPage(text)
        case .noPodcast: openExternalFeedPage(nil)
        case .document(let url): openExternalDocument(url)
        case .shortcut(let action): performQuickAction(action)
        case .openPage(let destination):
            closeScreensAboveMain()
            drawerAction(.destination(destination))
            openDefaultPageIfHidden()
        case .search(let query):
            closeScreensAboveMain()
            openSearchSubmitting(query)
        case .openPlayer: openPlayerFromWidget()
        case .playbackSpeed: openSpeedDialogFromWidget()
        }
    }

    /// Widget: `MainActivityStarter.withOpenPlayer()` on the `singleTask` main screen: Settings and presented
    /// screens close and the player expands; a video episode opens the video screen. The app may have been launched
    /// by the tap, so the saved episode is restored first.
    private func openPlayerFromWidget() {
        closeScreensAboveMain()
        guard let playback else { return }
        Task { [weak self] in
            try? await playback.restore()
            guard let self, let episode = playback.episode else { return }
            updatePlayer()
            if episode.details.media?.mimeType?.hasPrefix("video/") == true { requestVideo() }
            else { playerView?.setExpanded(true, animated: false) }
        }
    }

    /// Widget: Android shows only the speed dialog over the launcher; here the app opens with
    /// its speed dialog over the current screen.
    private func openSpeedDialogFromWidget() {
        guard let playback, let speedPreferences else { return }
        var host: UIViewController = self
        while let presented = host.presentedViewController, !presented.isBeingDismissed { host = presented }
        guard !(host is PlaybackSpeedController) else { return }
        Task { [weak self, weak host] in
            try? await playback.restore()
            guard self != nil, let host, host.presentedViewController == nil else { return }
            host.present(PlaybackSpeedController(playback: playback, preferences: speedPreferences), animated: true)
        }
    }

    /// This screen, or a screen presented over it, is in a window. A full-screen presentation (the
    /// OPML import) detaches the covered view, which is still an active recipient (as `OPMLImportFlow`).
    private var isOnScreen: Bool {
        var current: UIViewController? = self
        while let controller = current {
            if controller.viewIfLoaded?.window != nil { return true }
            current = controller.presentedViewController
        }
        return false
    }

    func consumePendingExternalRoute() {
        guard let route = pendingExternalRoute else { return }
        openExternal(route)
    }

    /// `OnlineFeedViewActivity` over the current screen. A preview already open is
    /// replaced; nil text is Android's `feedUrl == null`.
    private func openExternalFeedPage(_ text: String?) {
        let open = { [weak self] in
            guard let self else { return }
            if let text { openFeedPage(text, manual: false) }
            else {
                let preview = FeedPreviewController(content: FeedPreviewLoadingController())
                messages.present(preview)
                previewFailure(Appearance.text("null_value_podcast_error"), preview: preview)
            }
        }
        if let preview = presentedViewController as? FeedPreviewController {
            fetchTask?.cancel()
            preview.dismiss(animated: false, completion: open)
        } else { open() }
    }

    /// A feed document opens the preview of its own address; other XML stays with OPML import.
    private func openExternalDocument(_ url: URL) {
        Task { [weak self] in
            let kind = await Task.detached { ExternalDocument.classify(fileAt: url) }.value
            guard let self else { return }
            switch kind {
            case .feed(let address): openExternalFeedPage(address)
            case .opml, .other: openOPMLDocument(url)
            }
        }
    }

    /// A static launcher shortcut starts a fresh main screen (FLAG_ACTIVITY_CLEAR_TASK): presented
    /// screens and Settings close and the player collapses; then the page, or the startup page and a refresh.
    private func performQuickAction(_ action: ExternalEntry.QuickAction) {
        closeScreensAboveMain()
        if let destination = action.destination {
            drawerAction(.destination(destination))
        } else {
            switch navigationPreferences?.value.startupRoute ?? .destination(.home) {
            case .destination(let destination): drawerAction(.destination(destination))
            case .feed(let id): drawerAction(.feed(id))
            }
        }
        openDefaultPageIfHidden()
        if action == .refresh { requestFeedRefresh(nil) }
    }

    /// `MainActivity.onResume`: a hidden last page gives way to the default page.
    private func openDefaultPageIfHidden() {
        guard let preferences = navigationPreferences?.value,
              preferences.configuration.hiddenTags.contains(rootNavigationTag) else { return }
        selectTag(preferences.defaultPage)
    }

    private func closeScreensAboveMain() {
        if presentedViewController != nil {
            fetchTask?.cancel()
            dismiss(animated: false)
        }
        popup?.removeFromSuperview(); popup = nil
        closeSettings()
        playerView?.setExpanded(false, animated: false)
    }

    /// `SearchFragment.newInstance(query)`: the library search on top of the current page, submitted,
    /// without the keyboard (`searchView.setQuery(query, true)` clears the focus).
    private func openSearchSubmitting(_ query: String) {
        openSearch()
        guard case .search(let search) = path.last else { return }
        search.focusOnAttach = false
        search.field.text = query
        search.session.change(query)
        search.session.submit()
    }
}
