import Foundation
import UserNotifications

/// One failed attempt of an episode download (Android `EpisodeDownloadWorker`).
public struct DownloadFailureReport: Equatable, Sendable {
    public let jobID: Int64
    public let episodeID: Int64
    /// The download request title: the episode title, or the download URL when the episode has none
    /// (`FeedMedia.getHumanReadableIdentifier`).
    public let title: String
    public let failure: MediaDownloadFailure
    /// Another attempt follows. False for the last attempt and for failures that end the download at once.
    public let retrying: Bool

    public init(jobID: Int64, episodeID: Int64, title: String, failure: MediaDownloadFailure, retrying: Bool) {
        self.jobID = jobID; self.episodeID = episodeID; self.title = title; self.failure = failure; self.retrying = retrying
    }
}

/// Chooses between the in-app message and the "Episode download failed" notification.
///
/// - While an AntennaPod scene is in the foreground: the message "Download of "…" failed." (with
///   "Will be retried later." only when a retry follows), once per attempt, with a Details action.
/// - Otherwise, only when no retry follows: the notification, if "Download failed" is On and the system
///   allows notifications. It never asks for permission (Android never does for this).
@MainActor public final class DownloadErrorDelivery {
    public struct Text: Sendable {
        /// `download_error_retrying` / `download_error_not_retrying`, with one `%@` for the short title.
        public let retrying: String
        public let notRetrying: String
        /// `episode_download_failed` / `download_error_tap_for_details`.
        public let notificationTitle: String
        public let notificationBody: String
        public init(retrying: String, notRetrying: String, notificationTitle: String, notificationBody: String) {
            self.retrying = retrying; self.notRetrying = notRetrying
            self.notificationTitle = notificationTitle; self.notificationBody = notificationBody
        }
    }
    public enum Outcome: Equatable, Sendable {
        case message(String), notification, nothing
    }

    /// One fixed identity (`R.id.notification_download_report`): a later failure replaces the earlier
    /// notification; failures never stack.
    public nonisolated static let identifier = "download-error"
    public nonisolated static let category = "download-error"
    /// `EDW:235–237`: titles longer than 20 UTF-16 units are cut to 19 units plus "…".
    public nonisolated static let titleLimit = 20

    private let center: any SynchronizationNotificationCenter
    private let text: Text
    private let enabled: @MainActor () -> Bool
    private let foreground: @MainActor (String) -> Bool

    /// `foreground` shows the message in a visible AntennaPod scene and returns whether it did;
    /// `enabled` reads the "Download failed" switch.
    public init(center: any SynchronizationNotificationCenter = UNUserNotificationCenter.current(), text: Text,
                enabled: @escaping @MainActor () -> Bool, foreground: @escaping @MainActor (String) -> Bool) {
        self.center = center; self.text = text; self.enabled = enabled; self.foreground = foreground
    }

    @discardableResult
    public func deliver(_ report: DownloadFailureReport) async -> Outcome {
        let message = message(for: report)
        if foreground(message) { return .message(message) }
        // Retried attempts are silent outside the app until the last one (`sendMessage` has no subscriber).
        guard !report.retrying, enabled() else { return .nothing }
        guard NativeNotificationAuthorization.permitsNotifications(await center.authorizationStatus()) else { return .nothing }
        do { try await center.post(Self.request(text: text)); return .notification }
        catch { return .nothing }
    }

    /// The message text. Android says "Will be retried later." also for failures that end the download at
    /// once (401/403/404/410, blocked); here only when a retry actually follows.
    public func message(for report: DownloadFailureReport) -> String {
        String(format: report.retrying ? text.retrying : text.notRetrying, Self.shortTitle(report.title))
    }

    /// Android's limits (more than 20 UTF-16 units → the first 19 plus "…"), but cut only between whole
    /// characters: Android can split an emoji or strip a combining accent.
    public nonisolated static func shortTitle(_ title: String) -> String {
        guard title.utf16.count > titleLimit else { return title }
        var kept = "", units = 0
        for character in title {
            let length = character.utf16.count
            guard units + length <= titleLimit - 1 else { break }
            kept.append(character); units += length
        }
        return kept + "…"
    }

    public nonisolated static func request(text: Text) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = text.notificationTitle; content.body = text.notificationBody
        content.categoryIdentifier = category
        // Android's channel is HIGH importance with full lock-screen content: alert with the default sound.
        content.interruptionLevel = .active; content.sound = .default
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }

    /// A tap opens the Download log (`open_download_logs=true`).
    public nonisolated static func opensDownloadLog(identifier: String, category: String) -> Bool {
        identifier == Self.identifier && category == Self.category
    }
}
