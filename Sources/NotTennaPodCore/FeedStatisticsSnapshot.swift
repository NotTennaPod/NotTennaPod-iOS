import Foundation

/// FeedStatisticsFragment's all-time totals and release cards for one stored feed.
/// A missing statistics row (empty or unsubscribed feed) produces no snapshot.
public struct FeedStatisticsSnapshot: Equatable, Sendable {
    public let feedID: Int64
    public let title: String?
    public let statistics: FeedStatistics
    public let prediction: ReleaseScheduleGuess?
    public let release: ReleaseScheduleDisplay

    /// `units`: the feed's statistics units by episode ID (schema 20); they count in the totals, never in the release
    /// prediction, which reads episodes only.
    public init?(feed: LibraryFeed, units: [Int64: [LibraryStatisticsUnit]] = [:], now: Date, timeZone: TimeZone = .current) throws {
        guard let statistics = try LibraryStatistics(feeds: [feed], units: units, includeMarkedAsPlayed: true,
                                                     now: now).feeds.first else { return nil }
        // The original explicitly requests unfiltered DATE_OLD_NEW items, including
        // archived feeds and episodes without media. The guesser sorts its own copy.
        // Cursor.getLong maps a legacy SQL NULL publication date to epoch zero.
        let dates = feed.episodes.map { $0.details.publicationDate ?? Date(timeIntervalSince1970: 0) }
        let prediction = dates.count > 1 ? try ReleaseSchedule.guess(dates, timeZone: timeZone) : nil
        self.feedID = feed.id
        self.title = feed.title
        self.statistics = statistics
        self.prediction = prediction
        self.release = ReleaseScheduleDisplay(guess: prediction,
            local: feed.source.isLocalFeedSource, keepUpdated: feed.keepUpdated, now: now)
    }
}
