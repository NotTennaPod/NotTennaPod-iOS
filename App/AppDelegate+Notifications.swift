import UIKit
import NotTennaPodCore
import UserNotifications

// Download-failure delivery, the "Synchronization failed" switch for backup failures, and the
// route a tapped "Episode download failed" notification takes.
extension AppDelegate {
    /// One application-wide owner, so a failure is shown once even with several scenes.
    func startDownloadErrorDelivery(_ downloads: DownloadCoordinator, directory: URL) {
        var center: any SynchronizationNotificationCenter = UNUserNotificationCenter.current()
#if DEBUG
        let recorder = NotificationRecorder.make(directory: directory)
        if let recorder { center = recorder }
#endif
        let preferences = notificationPreferences
        let delivery = DownloadErrorDelivery(center: center, text: .init(
                retrying: Appearance.text("download_error_retrying"), notRetrying: Appearance.text("download_error_not_retrying"),
                notificationTitle: Appearance.text("episode_download_failed"),
                notificationBody: Appearance.text("download_error_tap_for_details")),
            enabled: { [weak preferences] in preferences?.value.downloadFailed ?? true },
            foreground: { message in Self.showDownloadError(message) })
        downloadErrors = delivery
        let events = downloads.events()
        downloadErrorEvents?.cancel()
        downloadErrorEvents = Task { @MainActor in
            for await event in events {
                guard !Task.isCancelled else { return }
                guard case .attemptFailed(let report) = event else { continue }
                let outcome = await delivery.deliver(report)
#if DEBUG
                recorder?.record(outcome, report: report)
#else
                _ = outcome
#endif
            }
        }
    }

    /// The same predicate as synchronization errors: a foreground-active scene's key window shows it.
    private static func showDownloadError(_ message: String) -> Bool {
        for scene in UIApplication.shared.connectedScenes where scene.activationState == .foregroundActive {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.isKeyWindow {
                if let controller = window.rootViewController as? LibraryViewController,
                   controller.downloadMessageHost.showDownloadError(message) { return true }
            }
        }
        return false
    }

    /// A background backup failure, with "Synchronization failed" as it applies now (On without an account).
    func backupFailureDelivery(authorized: Bool) async -> NotificationPreferences.BackupFailureDelivery {
        let account = (try? await library?.synchronizationState())?.accountID
        return (notificationPreferences?.value ?? .init()).backupFailureDelivery(authorized: authorized, account: account)
    }

    /// A tapped "Episode download failed" notification: the Download log opens on the visible main screen,
    /// or on the next one to become active (cold launch).
    func routeDownloadLog(in preferredController: LibraryViewController? = nil) {
        pendingDownloadLog = true
        // Only a started library's screen takes it; until then it waits.
        guard libraryStartup.isStarted else { return }
        if let preferredController { consumeNotification(in: preferredController); return }
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
           let controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController as? LibraryViewController {
            consumeNotification(in: controller)
        }
    }
}
