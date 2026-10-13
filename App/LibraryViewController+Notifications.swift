import UIKit
import NotTennaPodCore

// Settings → Notifications, the download-failure message and opening the Download log from a
// notification or the message's Details action.
extension LibraryViewController {
    func renderNotificationSettings() {
        let screen = NotificationSettingsView(preferences: notificationPreferences,
            synchronizationAccount: synchronizationSettings?.saved.accountID, width: content.bounds.width)
        screen.onFailure = { [weak self] in self?.showError($0) }
        content.addSubview(screen)
        screen.frame.origin = .zero
        content.contentSize = screen.bounds.size
    }

    /// The in-app message of `EpisodeDownloadWorker` (Snackbar, LENGTH_LONG, with "Details"). A new message
    /// replaces the current one. Returns false when this screen is not visible.
    func showDownloadError(_ message: String) -> Bool {
        let details = Snackbar.Action(title: Appearance.text("download_error_details"), identifier: "downloadErrorDetails") { [weak self] in
            self?.detailsHost.openDownloadLogFromNotification()
        }
        guard showSnackbar(message, action: details) else { return false }
        visibleSnackbar?.accessibilityIdentifier = "downloadErrorSnackbar"
        return true
    }

    /// Details from a podcast preview opens the log on the main screen that presented it.
    private var detailsHost: LibraryViewController {
        guard isPreview else { return self }
        var owner = presentingViewController
        while let current = owner, !(current is LibraryViewController) { owner = current.presentingViewController }
        return owner as? LibraryViewController ?? self
    }

    /// The screen that shows a download message: a podcast preview on top has its own message
    /// (`OnlineFeedViewActivity`), otherwise this main screen.
    var downloadMessageHost: LibraryViewController {
        if let preview = presentedViewController as? FeedPreviewController,
           let content = preview.contentController as? LibraryViewController { return content }
        return self
    }

    /// `open_download_logs=true` (`MainActivity.handleNavIntent`): the current page, its back stack and the
    /// player stay; Settings and screens presented over the main screen close; the Download log opens over
    /// them, once. A log already open stays the only one (Android would stack a second sheet).
    func openDownloadLogFromNotification() {
        loadViewIfNeeded()
        if let sheet = downloadLogSheet, sheet.presentingViewController != nil || !sheet.isViewLoaded { return }
        if presentedViewController != nil { dismiss(animated: false) }
        popup?.removeFromSuperview(); popup = nil
        closeSettings()
        showDownloadLog()
    }
}
