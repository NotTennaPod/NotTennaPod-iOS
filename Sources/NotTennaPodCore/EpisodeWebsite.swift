import Foundation

/// FeedItem.getLinkWithFallback and the episode pager's Visit website visibility.
public enum EpisodeWebsite {
    public static func link(episode: String?, feed: String?) -> String? {
        if let episode, !isBlank(episode) { return episode }
        if let feed, !isBlank(feed) { return feed }
        return nil
    }

    public static func toolbarDestination(episode: LibraryEpisode, feed: LibraryFeed) -> String? {
        // Text-only episodes expose this through their content action instead.
        guard episode.details.media != nil, !feed.source.isLocalFeedSource else { return nil }
        return link(episode: episode.details.link, feed: feed.metadata.link)
    }

    private static func isBlank(_ value: String) -> Bool {
        // Apache StringUtils uses Java Character.isWhitespace, which excludes
        // non-breaking spaces and differs from Foundation's trimming sets.
        value.unicodeScalars.allSatisfy {
            switch $0.value {
            case 0x0009...0x000D, 0x001C...0x0020, 0x1680,
                 0x2000...0x2006, 0x2008...0x200A, 0x2028, 0x2029, 0x205F, 0x3000: true
            default: false
            }
        }
    }
}
