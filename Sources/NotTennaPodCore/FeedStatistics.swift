import Foundation

public struct FeedStatistics: Equatable, Sendable {
    public let feedID: Int64
    public let totalSeconds, playedSeconds: Int64
    public let episodes, episodesStarted, downloadedEpisodes, downloadedBytes: Int64
    public let hasRecentUnplayed: Bool
    public let oldestPlaybackMilliseconds: Int64?
}

public struct LibraryStatistics: Equatable, Sendable {
    public let feeds: [FeedStatistics]
    public let oldestPlaybackMilliseconds: Int64

    public enum CalculationError: Error, Equatable { case invalidDate, integerOverflow }

    /// DBReader.getStatistics/PodDBAdapter.getFeedStatisticsCursor. The time interval restricts played duration
    /// only; other columns remain all-time. `units` are the library's statistics units by episode ID (schema 20):
    /// each counts as the Android row it was, in its episode's feed, in every column, the episode count included
    /// (PROTOCOL §15.2).
    public init(feeds: [LibraryFeed], units: [Int64: [LibraryStatisticsUnit]] = [:], includeMarkedAsPlayed: Bool,
                timeFrom: Int64 = 0, timeTo: Int64 = .max, now: Date) throws {
        let nowMilliseconds = try Self.milliseconds(now)
        let (recentSince, overflow) = nowMilliseconds.subtractingReportingOverflow(15_780_096_000)
        guard !overflow else { throw CalculationError.integerOverflow }
        var results: [FeedStatistics] = [], oldest = nowMilliseconds
        for feed in feeds.sorted(by: { $0.id < $1.id }) where feed.subscriptionState != .notSubscribed && !feed.episodes.isEmpty {
            var total: Int64 = 0, played: Int64 = 0, started: Int64 = 0
            var downloaded: Int64 = 0, bytes: Int64 = 0, recent = false
            var feedOldest: Int64?
            let rows = Self.rows(of: feed, units: units)
            for episode in rows {
                let state = episode.userState
                if state.playState != .played, let date = episode.details.publicationDate,
                   try Self.milliseconds(date) >= recentSince { recent = true }
                if includeMarkedAsPlayed && state.playState == .played { started += 1 }
                guard let media = episode.details.media else { continue }
                if !(includeMarkedAsPlayed && state.playState == .played),
                   ((state.lastPlayedHistoryMilliseconds ?? 0) > 0 && state.playedDurationMilliseconds > 0)
                    || (includeMarkedAsPlayed && state.positionMilliseconds > 0) { started += 1 }
                total = try Self.add(total, Int64(media.durationMilliseconds))
                let last = state.lastPlayedTimeMilliseconds
                // Long.MAX_VALUE is also the source query's no-date sentinel.
                if last > 0 && last < .max { feedOldest = min(feedOldest ?? .max, last) }
                if last >= timeFrom && last < timeTo {
                    let duration = includeMarkedAsPlayed && state.playedDurationMilliseconds == 0
                        ? (state.playState == .played ? Int64(media.durationMilliseconds) : 0)
                        : state.playedDurationMilliseconds
                    played = try Self.add(played, duration)
                }
                if let date = state.downloadDate, try Self.milliseconds(date) > 0 {
                    downloaded += 1
                    bytes = try Self.add(bytes, media.size)
                }
            }
            if let feedOldest { oldest = min(oldest, feedOldest) }
            results.append(FeedStatistics(feedID: feed.id, totalSeconds: total / 1000, playedSeconds: played / 1000,
                episodes: Int64(rows.count), episodesStarted: started, downloadedEpisodes: downloaded,
                downloadedBytes: bytes, hasRecentUnplayed: recent, oldestPlaybackMilliseconds: feedOldest))
        }
        self.feeds = results
        oldestPlaybackMilliseconds = oldest
    }

    /// A feed's statistics rows: its episodes, then each episode's statistics units as the rows they were.
    static func rows(of feed: LibraryFeed, units: [Int64: [LibraryStatisticsUnit]]) -> [LibraryEpisode] {
        guard !units.isEmpty else { return feed.episodes }
        return feed.episodes + feed.episodes.flatMap { episode in (units[episode.id] ?? []).map { $0.statisticsRow(of: episode) } }
    }

    private static func milliseconds(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970 * 1000
        guard value.isFinite, value >= Double(Int64.min), value < Double(Int64.max) else { throw CalculationError.invalidDate }
        return Int64(value)
    }
    private static func add(_ left: Int64, _ right: Int64) throws -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        guard !overflow else { throw CalculationError.integerOverflow }
        return value
    }
}
