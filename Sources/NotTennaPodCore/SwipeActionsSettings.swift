import Foundation

/// Settings → User interface → Swipe actions (`preferences_swipe.xml`): seven title-only rows in source
/// order. Each opens the `SwipeActionsDialog` of its screen tag (`SwipePreferencesFragment`), the same
/// dialog the list's first swipe opens. The row keys are not stored.
public enum SwipeActionsSettingsRow: String, CaseIterable, Sendable {
    case queue = "prefSwipeQueue"
    case inbox = "prefSwipeInbox"
    case episodes = "prefSwipeEpisodes"
    case downloads = "prefSwipeDownloads"
    case history = "prefSwipeHistory"
    case favorites = "prefSwipeFavorites"
    case feed = "prefSwipeFeed"

    public var key: String { rawValue }
    public var titleKey: String {
        switch self {
        case .queue: "queue_label"
        case .inbox: "inbox_label"
        case .episodes: "episodes_label"
        case .downloads: "downloads_label"
        case .history: "playback_history_label"
        case .favorites: "favorite_episodes_label"
        case .feed: "individual_subscription"
        }
    }
    /// The `SwipeActions` tag whose configuration the row edits.
    public var tag: String { screen?.rawValue ?? "DownloadsFragment" }
    /// Nil for Downloads, which keeps its own configuration model.
    public var screen: SwipeScreen? {
        switch self {
        case .queue: .queue
        case .inbox: .inbox
        case .episodes: .episodes
        case .downloads: nil
        case .history: .history
        case .favorites: .favorites
        case .feed: .feed
        }
    }
}
