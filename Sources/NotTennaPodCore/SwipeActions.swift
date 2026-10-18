import Foundation

/// Every configurable list screen except Downloads (which keeps its own model), by source
/// `SwipeActions` tag. The name dates from when only the four Remove-from-inbox routes existed;
/// Queue and Playback history were added later. Directions are physical.
public enum SwipeScreen: String, Codable, CaseIterable, Sendable {
    case queue = "QueueFragment"
    case inbox = "NewEpisodesFragment"
    case episodes = "EpisodesFragment"
    case history = "PlaybackHistoryFragment"
    case favorites = "FavoritesFragment"
    case feed = "ItemlistFragment"

    /// The four original screens; they offer Remove from inbox.
    public static let inboxRoutes: [SwipeScreen] = [.inbox, .episodes, .favorites, .feed]

    public var titleKey: String {
        switch self {
        case .queue: "queue_label"
        case .inbox: "inbox_label"
        case .episodes: "episodes_label"
        case .history: "playback_history_label"
        case .favorites: "favorite_episodes_label"
        case .feed: "individual_subscription"
        }
    }
    /// `SwipeActionsDialog.setupSwipeDirectionView` picker order (row by row in a two-column grid).
    public var actions: [SwipeAction] {
        switch self {
        case .queue: [.removeQueue, .download, .delete, .favorite, .played]
        case .inbox: [.queue, .download, .removeInbox, .favorite]
        case .episodes, .feed: [.queue, .download, .removeInbox, .delete, .favorite, .played]
        case .history: [.queue, .download, .delete, .favorite, .removeHistory, .played]
        case .favorites: [.queue, .download, .removeInbox, .delete, .removeFavorite, .played]
        }
    }
    /// Proposed dialog values (`SwipeActions.getPrefsWithDefaults`), not an implicit saved configuration.
    public var defaultConfiguration: SwipeConfiguration {
        switch self {
        case .queue: .init(left: .removeQueue, right: .removeQueue)
        case .inbox: .init(left: .removeInbox, right: .queue)
        case .episodes, .feed: .init(left: .download, right: .favorite)
        case .history: .init(left: .removeHistory, right: .removeHistory)
        case .favorites: .init(left: .removeFavorite, right: .removeFavorite)
        }
    }
    /// The fixed `FeedItemFilter` a screen passes to its swipe actions: Queue `queued` (`QueueFragment`),
    /// Inbox `new`, History unfiltered (`PlaybackHistoryFragment`). Nil: the screen's own list filter
    /// (Episodes, Favorites, a podcast).
    public var fixedSwipeFilter: FeedEpisodeFilter? {
        switch self {
        case .queue: .init(values: ["queued"])
        case .inbox: .init(values: ["new"])
        case .history: .init()
        case .episodes, .favorites, .feed: nil
        }
    }
}

public enum SwipeAction: String, Codable, CaseIterable, Sendable {
    case queue = "ADD_TO_QUEUE"
    case download = "START_DOWNLOAD"
    case removeInbox = "REMOVE_FROM_INBOX"
    case delete = "DELETE"
    case favorite = "MARK_FAV"
    case removeFavorite = "REMOVE_FROM_FAVORITES"
    case played = "MARK_PLAYED"
    case removeQueue = "REMOVE_FROM_QUEUE"
    case removeHistory = "REMOVE_FROM_HISTORY"

    public var titleKey: String {
        switch self {
        case .queue: "add_to_queue_label"
        case .download: "download_label"
        case .removeInbox: "remove_inbox_label"
        case .delete: "delete_label"
        case .favorite: "add_to_favorite_label"
        case .removeFavorite: "remove_from_favorite_label"
        case .played: "toggle_played_label"
        case .removeQueue: "remove_from_queue_label"
        case .removeHistory: "remove_history_label"
        }
    }
    public var icon: String {
        switch self {
        case .queue: "ic_playlist_play"
        case .download: "ic_download"
        case .removeInbox: "ic_check"
        case .delete: "ic_delete"
        case .favorite: "ic_star"
        case .removeFavorite: "ic_star_border"
        case .played: "ic_mark_played"
        case .removeQueue: "ic_playlist_remove"
        case .removeHistory: "ic_history_remove"
        }
    }
    public var colorAttribute: String {
        switch self {
        case .queue, .removeQueue: "colorAccent"
        case .download: "icon_green"
        case .removeInbox, .removeHistory: "icon_purple"
        case .delete: "icon_red"
        case .favorite, .removeFavorite: "icon_yellow"
        case .played: "icon_gray"
        }
    }

    /// SwipeAction.willRemove controls travel, independently of whether its action can mutate the item.
    public func removesRow(item: EpisodeListItem, filter: FeedEpisodeFilter) -> Bool {
        let values = Set(filter.values)
        switch self {
        case .queue:
            return item.episode.details.media != nil && (values.contains("not_queued") || values.contains("new"))
        case .download: return false
        case .removeInbox: return values.contains("new")
        case .delete: return values.contains("downloaded") && (item.local || item.episode.userState.isDownloaded)
        case .favorite: return values.contains("is_favorite") || values.contains("not_favorite")
        case .removeFavorite: return values.contains("is_favorite")
        case .played:
            return values.contains("played") || values.contains("new")
                || (item.episode.userState.playState != .new && values.contains("unplayed"))
        case .removeQueue: return values.contains("queued") || values.contains("not_queued")
        case .removeHistory: return true
        }
    }

    /// Pure recipient selection. Mark recipients require the shared no-sync, position-preserving
    /// mark/Undo owner; they must not be dispatched as ordinary context Mark as played/unplayed.
    public func decision(item: EpisodeListItem, filter: FeedEpisodeFilter) -> SwipeDecision {
        let removes = removesRow(item: item, filter: filter)
        let hasMedia = item.episode.details.media != nil
        let state = item.episode.userState
        switch self {
        case .queue:
            if item.queued {
                let feedback = filter.values.contains("queued") || filter.values.contains("not_queued")
                return .init(recipient: .list(.removeQueue), removesRow: removes,
                             undo: feedback ? .queuePosition : nil)
            }
            return .init(recipient: hasMedia ? .list(.addQueue) : .notice("no_media_label"), removesRow: removes)
        case .download:
            let recipient: SwipeDecision.Recipient
            if !hasMedia { recipient = .notice("no_media_label") }
            else if item.local || state.isDownloaded { recipient = .notice("already_downloaded") }
            else if item.downloading { recipient = .none }
            else { recipient = .download }
            return .init(recipient: recipient, removesRow: removes)
        case .removeInbox:
            guard state.playState == .new else { return .init(recipient: .none, removesRow: removes) }
            // Uses the accepted prior NEW state for this wording and later Undo.
            return .init(recipient: .markWithUndo(.removeInbox), removesRow: removes,
                         undo: removes ? .playState(messageKey: "removed_from_inbox_message") : nil)
        case .delete:
            return .init(recipient: item.local || state.isDownloaded ? .list(.delete) : .none, removesRow: removes)
        case .favorite, .removeFavorite:
            return .init(recipient: .list(state.isFavorite ? .removeFavorite : .addFavorite), removesRow: removes)
        case .played:
            let played = state.playState == .unplayed
            return .init(recipient: .markWithUndo(played ? .markPlayed : .markUnplayed), removesRow: removes,
                         undo: removes ? .playState(messageKey: played ? "marked_as_played_message" : "marked_as_unplayed_message") : nil)
        case .removeQueue:
            // RemoveFromQueueSwipeAction: removal always; "1 episode removed from queue." + Undo only when willRemove.
            return .init(recipient: .list(.removeQueue), removesRow: removes, undo: removes ? .queuePosition : nil)
        case .removeHistory:
            // RemoveFromHistorySwipeAction: always slides out and always offers "Removed from history" + Undo.
            // History rows always have media; a media-less row has no history date to remove.
            return .init(recipient: hasMedia ? .removeHistory : .none, removesRow: removes, undo: hasMedia ? .historyDate : nil)
        }
    }
}

public struct SwipeDecision: Equatable, Sendable {
    public enum Recipient: Equatable, Sendable {
        case none
        case notice(String)
        case list(EpisodeListAction)
        /// Uses the ordinary single-item download admission/confirmation owner, not batch download.
        case download
        /// Uses markReadWithUndo semantics, including its delayed cleanup even without visible Undo.
        case markWithUndo(EpisodeListAction)
        /// Clears only the history date, keeping the original for Undo (`DBWriter.deleteFromPlaybackHistory`).
        case removeHistory

        public var action: EpisodeListAction? {
            switch self {
            case .none, .notice, .removeHistory: nil
            case .list(let action), .markWithUndo(let action): action
            case .download: .download
            }
        }
    }
    public enum Undo: Equatable, Sendable {
        case queuePosition
        case playState(messageKey: String)
        /// "Removed from history" + Undo restores the original history date.
        case historyDate
    }
    public let recipient: Recipient
    public let removesRow: Bool
    public let undo: Undo?
    public init(recipient: Recipient, removesRow: Bool, undo: Undo? = nil) {
        self.recipient = recipient; self.removesRow = removesRow; self.undo = undo
    }
}

public struct SwipeConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var left: SwipeAction
    public var right: SwipeAction
    public init(enabled: Bool = true, left: SwipeAction, right: SwipeAction) {
        self.enabled = enabled; self.left = left; self.right = right
    }
    public func action(_ direction: EpisodeSwipeDirection) -> SwipeAction {
        direction == .left ? left : right
    }
}

/// Editing or discarding a draft has no persistence side effects. Confirm commits only this screen.
public struct SwipeDraft: Equatable, Sendable {
    public let screen: SwipeScreen
    public var configuration: SwipeConfiguration
    public init(screen: SwipeScreen, configuration: SwipeConfiguration) {
        self.screen = screen; self.configuration = configuration
    }
}
