import Foundation

/// Subscriptions multi-select floating actions (`nav_feed_action_speeddial.xml`,
/// `FeedMenuHandler.onPrepareMenu`, `SubscriptionFragment`).
public enum FeedBulkAction: String, CaseIterable, Sendable {
    case editTags, share, removeInbox, removeArchive, removeRestore, keepUpdated, notifications, autoDownload, autoDelete, playbackSpeed

    public var titleKey: String {
        switch self {
        case .editTags: "edit_tags"
        case .share: "share_label"
        case .removeInbox: "remove_all_inbox_label"
        case .removeArchive: "remove_archive_feed_label"
        case .removeRestore: "remove_restore_feed_label"
        case .keepUpdated: "keep_updated"
        case .notifications: "episode_notification"
        case .autoDownload: "auto_download_label"
        case .autoDelete: "pref_auto_delete_playback_title"
        case .playbackSpeed: "playback_speed"
        }
    }
    public var icon: String {
        switch self {
        case .editTags: "ic_tag"
        case .share: "ic_share"
        case .removeInbox: "ic_check"
        case .removeArchive, .removeRestore: "ic_delete"
        case .keepUpdated: "ic_refresh"
        case .notifications: "ic_notifications"
        case .autoDownload: "ic_download"
        case .autoDelete: "ic_delete_auto"
        case .playbackSpeed: "ic_playback_speed"
        }
    }
    /// Visible items for a non-empty selection, in XML order. The Archive screen removes the five
    /// preference actions. An empty selection keeps the previous items (the source returns early).
    public static func visible(_ selection: [LibraryFeed], archiveScreen: Bool) -> [Self] {
        let allSubscribed = selection.allSatisfy { $0.subscriptionState == .subscribed }
        let allArchived = selection.allSatisfy { $0.subscriptionState == .archived }
        let singleRemote = selection.count == 1 && !selection[0].source.isLocalFeedSource
        return allCases.filter { action in
            switch action {
            case .editTags: true
            case .share: singleRemote
            case .removeInbox: allSubscribed
            case .removeArchive: !allArchived && allSubscribed
            case .removeRestore: allArchived
            case .keepUpdated, .notifications, .autoDownload, .autoDelete, .playbackSpeed: !archiveScreen
            }
        }
    }
}

/// The bulk switch/list/speed dialogs set values; they never show the feeds' current values.
public enum FeedBulkPreference: Equatable, Sendable {
    case keepUpdated(Bool)
    case notifications(Bool)
    case autoDownload(FeedAutoDownload)
    case autoDelete(FeedAutoDelete)

    /// `spnEnableAutoDownloadItems` rows → `AutoDownloadSetting` (Global default, Enabled, Disabled).
    public static let autoDownloadChoices: [FeedAutoDownload] = [.global, .enabled, .disabled]
    /// `spnAutoDeleteItems` rows → `AutoDeleteAction.fromCode` (Global default, Always, Never).
    public static let autoDeleteChoices: [FeedAutoDelete] = [.global, .always, .never]

    /// Only the chosen column changes (Android rewrites every column from a snapshot).
    public func apply(to preferences: inout FeedLibraryPreferences) {
        switch self {
        case .keepUpdated(let value): preferences.keepUpdated = value
        case .notifications(let value): preferences.showEpisodeNotification = value
        case .autoDownload(let value): preferences.autoDownload = value
        case .autoDelete(let value): preferences.autoDelete = value
        }
    }
}
