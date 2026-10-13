import Foundation

/// CompletedDownloadsFragment: active URLs precede the independently sorted
/// downloaded set, including archived and unsubscribed stored feeds.
public enum DownloadsList {
    public static let sortFields: [FeedEpisodeSortOrder.Field] = [.title, .duration, .date, .size]
    public static func order(_ preference: FeedEpisodeSortOrder?) -> FeedEpisodeSortOrder {
        guard let preference, sortFields.contains(preference.field) else { return .dateNewest }
        return preference
    }
    public static func episodes(_ episodes: [LibraryEpisode], jobs: [LibraryDownloadJob],
                                order preference: FeedEpisodeSortOrder? = nil) -> [LibraryEpisode] {
        let completed = episodes.filter { $0.userState.isDownloaded }
        func equal(_ a: String?, _ b: String) -> Bool { a?.utf16.elementsEqual(b.utf16) == true }
        let activeURLs = jobs.filter { $0.state.isActive }.map(\.source).filter { url in
            !completed.contains { equal($0.details.media?.url, url) }
        }
        let active = episodes.filter { episode in activeURLs.contains { equal(episode.details.media?.url, $0) } }.sorted { a, b in
            let left = a.userState.lastPlayedHistoryMilliseconds ?? a.userState.lastPlayedTimeMilliseconds
            let right = b.userState.lastPlayedHistoryMilliseconds ?? b.userState.lastPlayedTimeMilliseconds
            return left == right ? a.id < b.id : left > right
        }
        return active + order(preference).sorted(completed)
    }
    public static func playedDownloadIDs(_ episodes: [LibraryEpisode]) -> [Int64] {
        FeedEpisodeSortOrder.dateOldest.sorted(episodes.filter { $0.userState.isDownloaded && $0.userState.playState == .played }).map(\.id)
    }
}
