import Foundation
import Testing
@testable import NotTennaPodCore

struct FeedStatisticsTests {
    @Test func matchesOriginalSQLForPlaybackFiltersMediaAndSubscriptionStates() throws {
        struct Episode: Decodable {
            let id: Int64, play: Int, publication: Int64, media: Bool
            let duration, played, last, history, position, download, size: Int64?
        }
        struct Feed: Decodable { let id: Int64, state: Int, episodes: [Episode] }
        struct Expected: Decodable {
            let id, oldest_date, num_episodes, episodes_started, played_time, total_time: Int64
            let num_downloaded, download_size, num_recent_unplayed: Int64
        }
        struct Query: Decodable { let marked: Bool, start: Int64, end: Int64, expected: [Expected] }
        struct Fixture: Decodable { let now: Int64, feeds: [Feed], cases: [Query] }
        let url = try #require(Bundle.module.url(forResource: "feed-statistics-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let feeds = fixture.feeds.map { source in
            let episodes = source.episodes.map { row in
                var state = EpisodeUserState()
                state.playState = EpisodePlayState(rawValue: row.play)!
                state.positionMilliseconds = Int32(row.position ?? 0)
                state.playedDurationMilliseconds = Int64(row.played ?? 0)
                state.lastPlayedTimeMilliseconds = row.last ?? 0
                state.lastPlayedHistoryMilliseconds = row.history
                state.downloadDate = row.download.map { Date(timeIntervalSince1970: Double($0) / 1000) }
                // Deliberately opposite flags: the statistics query uses date, not downloaded boolean.
                state.isDownloaded = row.download == 0
                state.timeSpentMilliseconds = 123_456_789
                return LibraryEpisode(id: row.id, details: ParsedEpisode(publicationDate: Date(timeIntervalSince1970: Double(row.publication) / 1000),
                    media: row.media ? ParsedMedia(url: "fixture://media", size: row.size!, durationMilliseconds: Int32(row.duration!)) : nil), userState: state)
            }
            var feed = LibraryFeed(id: source.id, source: "fixture://\(source.id)", metadata: ParsedFeed(format: .rss), episodes: episodes)
            feed.subscriptionState = FeedSubscriptionState(rawValue: source.state)!
            return feed
        }
        #expect(fixture.cases.count == 8 && fixture.feeds.count == 1317)
        for query in fixture.cases {
            let result = try LibraryStatistics(feeds: feeds.reversed(), includeMarkedAsPlayed: query.marked,
                timeFrom: query.start, timeTo: query.end, now: Date(timeIntervalSince1970: Double(fixture.now) / 1000))
            #expect(result.feeds.count == query.expected.count)
            for (actual, expected) in zip(result.feeds, query.expected) {
                #expect(actual.feedID == expected.id)
                #expect(actual.episodes == expected.num_episodes && actual.episodesStarted == expected.episodes_started)
                #expect(actual.playedSeconds == expected.played_time / 1000 && actual.totalSeconds == expected.total_time / 1000)
                #expect(actual.downloadedBytes == expected.download_size && actual.downloadedEpisodes == expected.num_downloaded)
                #expect(actual.hasRecentUnplayed == (expected.num_recent_unplayed > 0))
                #expect(actual.oldestPlaybackMilliseconds == (expected.oldest_date == .max ? nil : expected.oldest_date))
            }
            #expect(result.oldestPlaybackMilliseconds == min(fixture.now, query.expected.map(\.oldest_date).min() ?? .max))
        }
    }

    @Test func overflowAndInvalidClockFailWithoutWrappingAndEmptyLibraryUsesNow() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let empty = try LibraryStatistics(feeds: [], includeMarkedAsPlayed: true, now: now)
        #expect(empty.feeds.isEmpty && empty.oldestPlaybackMilliseconds == 1_700_000_000_000)
        #expect(throws: LibraryStatistics.CalculationError.invalidDate) {
            try LibraryStatistics(feeds: [], includeMarkedAsPlayed: true, now: Date(timeIntervalSince1970: .infinity))
        }
        var state = EpisodeUserState(); state.downloadDate = now
        let episode = LibraryEpisode(id: 1, details: ParsedEpisode(media: ParsedMedia(url: "fixture://media", size: .max)), userState: state)
        let feed = LibraryFeed(id: 1, source: "fixture://feed", metadata: ParsedFeed(format: .rss), episodes: [episode, episode])
        #expect(throws: LibraryStatistics.CalculationError.integerOverflow) {
            try LibraryStatistics(feeds: [feed], includeMarkedAsPlayed: true, now: now)
        }
    }

    @Test func persistedFeedStatisticsIgnoreDisplayFilterAndSurviveReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FeedStatistics-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("library.sqlite"), now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try FeedLibraryStore(url: file)
        let parsed = ParsedFeed(format: .rss, title: "Statistics", episodes: [
            ParsedEpisode(identifier: "a", title: "A", publicationDate: now,
                media: ParsedMedia(url: "fixture://a", size: 1500, durationMilliseconds: 900)),
            ParsedEpisode(identifier: "b", title: "B", publicationDate: now,
                media: ParsedMedia(url: "fixture://b", size: 2500, durationMilliseconds: 900))])
        let feed = try await store.insert(FetchedFeed(feed: parsed, source: "https://example.test/feed",
            responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        for episode in feed.episodes {
            try await store.updateEpisode(id: episode.id) {
                $0.userState.playState = .played; $0.userState.downloadDate = now
            }
        }
        try await store.setEpisodeFilter(feedID: feed.id, filter: FeedEpisodeFilter(values: ["unplayed"]))
        let result = try await store.statistics(now: now), entry = try #require(result.feeds.first)
        #expect(entry.totalSeconds == 1 && entry.playedSeconds == 1)
        #expect(entry.episodes == 2 && entry.episodesStarted == 2 && entry.downloadedBytes == 4000)
        #expect(entry.downloadedEpisodes == 2 && !entry.hasRecentUnplayed)
        #expect(try await store.statistics(includeMarkedAsPlayed: false, now: now).feeds.first?.playedSeconds == 0)
        try await store.close()
        let reopened = try FeedLibraryStore(url: file)
        #expect(try await reopened.statistics(now: now) == result)
        try await reopened.close()
    }
}
