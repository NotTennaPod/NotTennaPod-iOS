import Foundation

/// Settings → Notifications (Android `preferences_notifications.xml`).
///
/// Each switch acts like the matching Android 8+ notification channel: Off stops that kind of system
/// notification; in-app messages are never affected. The keys keep Android's names for traceability;
/// Android keeps them in SharedPreferences, which no backup format carries.
public struct NotificationPreferences: Codable, Equatable, Sendable {
    /// "Download failed" (`prefShowDownloadReport`, default On).
    public var downloadFailed = true
    /// "Synchronization failed" (`pref_gpodnet_notifications`, default On) as last set by the person.
    public var synchronizationFailed = true
    /// The synchronization account the "Synchronization failed" choice was made for. Android sets the
    /// switch back to On at every login and logout (`SynchronizationCredentials.clear()`); a choice
    /// therefore lasts only while the same account stays selected.
    public var synchronizationAccount: UUID?

    public init() {}

    /// The "Synchronization failed" switch as the screen shows it and delivery applies it: On without an
    /// account (the row is then disabled) and for any account other than the one it was turned off for.
    public func synchronizationFailedEnabled(account: UUID?) -> Bool {
        guard let account, synchronizationAccount == account else { return true }
        return synchronizationFailed
    }

    public enum BackupFailureDelivery: Equatable, Sendable {
        /// Post the system notification.
        case notification
        /// Keep the text for the next activation (Android's Toast without permission).
        case pendingMessage
        /// Nothing: the notification is switched off.
        case nothing
    }
    /// An automatic backup failure while the app is in the background (`AutomaticDatabaseExportWorker.
    /// showErrorNotification`). Android 8+ posts it on the "Synchronization failed" channel, so that switch
    /// also silences it; without permission Android shows a Toast whatever the channel.
    public func backupFailureDelivery(authorized: Bool, account: UUID?) -> BackupFailureDelivery {
        guard authorized else { return .pendingMessage }
        return synchronizationFailedEnabled(account: account) ? .notification : .nothing
    }

    private enum CodingKeys: String, CodingKey {
        case downloadFailed = "prefShowDownloadReport"
        case synchronizationFailed = "pref_gpodnet_notifications"
        case synchronizationAccount
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        downloadFailed = try values.decodeIfPresent(Bool.self, forKey: .downloadFailed) ?? true
        synchronizationFailed = try values.decodeIfPresent(Bool.self, forKey: .synchronizationFailed) ?? true
        synchronizationAccount = try values.decodeIfPresent(UUID.self, forKey: .synchronizationAccount)
    }
}

@MainActor public final class NotificationPreferenceStore: JSONPreferenceStore<NotificationPreferences> {
    public init(file: URL) throws { try super.init(file: file, defaultValue: .init()) }

    /// Tapping "Download failed" saves at once; there is no dialog or permission request (`NPF` has no listeners).
    public func setDownloadFailed(_ enabled: Bool) throws {
        var value = value; value.downloadFailed = enabled
        try update(value)
    }

    /// Tapping "Synchronization failed" (enabled only with an account) saves the choice for that account.
    public func setSynchronizationFailed(_ enabled: Bool, account: UUID) throws {
        var value = value; value.synchronizationFailed = enabled; value.synchronizationAccount = account
        try update(value)
    }
}

/// The Notifications screen (Android `preferences_notifications.xml:5–18`, `NotificationPreferencesFragment`):
/// toolbar "Notifications", one category "Errors", two switch rows in this order.
public enum NotificationSettingsComposition {
    public struct Row: Equatable, Sendable {
        /// Android preference key, also the row's accessibility identifier.
        public let key: String
        /// Localizable string keys (Android `strings.xml` names).
        public let titleKey: String
        public let summaryKey: String
    }
    public static let downloadKey = "prefShowDownloadReport"
    public static let synchronizationKey = "pref_gpodnet_notifications"
    public static let titleKey = "notification_pref_fragment"
    public static let categoryKey = "notification_group_errors"
    public static let rows: [Row] = [
        Row(key: downloadKey, titleKey: "notification_channel_download_error",
            summaryKey: "notification_channel_download_error_description"),
        Row(key: synchronizationKey, titleKey: "notification_channel_sync_error",
            summaryKey: "notification_channel_sync_error_description"),
    ]

    /// `setEnabled(SynchronizationSettings.isProviderConnected())` (`NPF:25`): only the sync row depends on an account.
    public static func isEnabled(_ key: String, synchronizationAccount: UUID?) -> Bool {
        key != synchronizationKey || synchronizationAccount != nil
    }

    public static func isOn(_ key: String, _ preferences: NotificationPreferences, synchronizationAccount: UUID?) -> Bool {
        key == synchronizationKey ? preferences.synchronizationFailedEnabled(account: synchronizationAccount) : preferences.downloadFailed
    }
}
