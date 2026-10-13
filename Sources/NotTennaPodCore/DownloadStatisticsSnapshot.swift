import Foundation

/// Downloads tab data: `DBReader.getStatistics(false, 0, Long.MAX_VALUE)` (`DownloadStatisticsFragment:69–89`,
/// `PodDBAdapter.getFeedStatisticsCursor` 1239–1283), sorted by size (`DownloadStatisticsFragment:80–82`).
public struct DownloadStatisticsSnapshot: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let feedID: Int64
        public let title: String?
        public let imageURL: String?
        /// Sum of the stored sizes of downloaded episodes (`FeedMedia.downloaded > 0`).
        public let bytes: Int64
        public let downloadedEpisodes: Int64
    }
    /// Subscribed and archived feeds with at least one episode, even with nothing downloaded.
    /// Descending size; equal sizes keep ascending feed id (stable sort over the SQL group order).
    public let rows: [Row]
    public let totalBytes: Int64
    public let totalEpisodes: Int64

    public init(feeds: [LibraryFeed]) {
        var rows: [Row] = []
        for feed in feeds.sorted(by: { $0.id < $1.id }) where feed.subscriptionState != .notSubscribed && !feed.episodes.isEmpty {
            var bytes: Int64 = 0, count: Int64 = 0
            for episode in feed.episodes {
                guard let media = episode.details.media, let date = episode.userState.downloadDate,
                      date.timeIntervalSince1970 * 1000 >= 1 else { continue }
                count += 1
                bytes = YearsStatisticsSnapshot.saturatingAdd(bytes, media.size)
            }
            rows.append(.init(feedID: feed.id, title: feed.title, imageURL: feed.metadata.imageURL, bytes: bytes, downloadedEpisodes: count))
        }
        // Swift's sort is not stable; the id tiebreak reproduces Collections.sort over id order.
        self.rows = rows.sorted { $0.bytes == $1.bytes ? $0.feedID < $1.feedID : $0.bytes > $1.bytes }
        totalBytes = self.rows.reduce(0) { YearsStatisticsSnapshot.saturatingAdd($0, $1.bytes) }
        totalEpisodes = self.rows.reduce(0) { $0 + $1.downloadedEpisodes }
    }
}
