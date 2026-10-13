import Foundation

/// The episode pager menu, in Android's category-sorted order.
public enum EpisodeMenu {
    public enum Action: String, Equatable, Sendable {
        case skip, removeFromInbox, markPlayed, markUnplayed, addToQueue, removeFromQueue
        case resetPosition, website, openPodcast, addFavorite, removeFavorite, share

        public func titleKey(hasMedia: Bool) -> String {
            switch self {
            case .skip: "skip_episode_label"
            case .removeFromInbox: "remove_inbox_label"
            case .markPlayed: "mark_as_played_label"
            case .markUnplayed: hasMedia ? "mark_as_unplayed_label" : "mark_unread_label_no_media"
            case .addToQueue: "add_to_queue_label"
            case .removeFromQueue: "remove_from_queue_label"
            case .resetPosition: "reset_playback_position_label"
            case .website: "visit_website_label"
            case .openPodcast: "open_podcast"
            case .addFavorite: "add_to_favorite_label"
            case .removeFavorite: "remove_from_favorite_label"
            case .share: "share_label"
            }
        }
    }

    // PlaybackStatus.isPlaying in the source compares selected media identity,
    // including paused media; it does not require a playing transport phase.
    public static func actions(episode: LibraryEpisode, feed: LibraryFeed, queued: Bool,
                               isSelectedMedia: Bool, websiteInToolbar: Bool = true) -> [Action] {
        let media = episode.details.media != nil
        var actions: [Action] = []
        if media && isSelectedMedia { actions.append(.skip) }
        if episode.userState.playState == .new { actions.append(.removeFromInbox) }
        if media && episode.userState.playState != .played && feed.subscriptionState != .notSubscribed {
            actions.append(.markPlayed)
        }
        if episode.userState.playState == .played { actions.append(.markUnplayed) }
        if queued { actions.append(.removeFromQueue) }
        else if media { actions.append(.addToQueue) }
        if media && episode.userState.positionMilliseconds != 0 { actions.append(.resetPosition) }
        if !websiteInToolbar && EpisodeWebsite.toolbarDestination(episode: episode, feed: feed) != nil {
            actions.append(.website)
        }
        actions.append(.openPodcast)
        // menuCategory="container" places these after the uncategorized items.
        actions.append(episode.userState.isFavorite ? .removeFavorite : .addFavorite)
        if !feed.source.isLocalFeedSource { actions.append(.share) }
        return actions
    }
}
