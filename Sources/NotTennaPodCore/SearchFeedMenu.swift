import Foundation

/// HorizontalFeedListAdapter → nav_feed_context → FeedMenuHandler.
public enum SearchFeedMenu {
    public enum Action: String, Equatable, Sendable {
        case removeInbox, editTags, removeArchive, removeRestore, share
        public var titleKey: String {
            switch self {
            case .removeInbox: "remove_all_inbox_label"
            case .editTags: "edit_tags"
            case .removeArchive: "remove_archive_feed_label"
            case .removeRestore: "remove_restore_feed_label"
            case .share: "share_label"
            }
        }
    }
    public static func actions(for feed: LibraryFeed) -> [Action] {
        var actions: [Action] = []
        if feed.subscriptionState == .subscribed { actions.append(.removeInbox) }
        actions.append(.editTags)
        if feed.subscriptionState == .subscribed { actions.append(.removeArchive) }
        if feed.subscriptionState == .archived { actions.append(.removeRestore) }
        if !feed.source.isLocalFeedSource { actions.append(.share) }
        return actions
    }
}
