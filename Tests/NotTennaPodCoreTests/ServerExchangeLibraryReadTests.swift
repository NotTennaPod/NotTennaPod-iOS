import Foundation
import Testing
@testable import NotTennaPodCore

/// The library-wide reads the exchange touches (PROTOCOL §6.8): `feeds()`, `snapshot()` and `statistics()` give
/// exactly today's results in a standalone library, and in a server library without a pinned removal; only a pinned
/// removal is left out.
@Suite struct ServerExchangeLibraryReadTests {
    static let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func populate(_ store: FeedLibraryStore) async throws {
        let one = try await store.insert(ServerLibraryFixture.fetched("https://example.test/one.xml", title: "One", count: 6))
        let two = try await store.insert(ServerLibraryFixture.fetched("https://example.test/two.xml", title: "Two", count: 3))
        _ = try await store.preparePreview(ServerLibraryFixture.fetched("https://example.test/three.xml", title: "Three", count: 2))
        let ids = one.episodes.map(\.id).sorted()
        try await store.markEpisodePlayed(episodeID: ids[0], played: true)
        try await store.setFavorite(episodeID: ids[1], favorite: true)
        _ = try await store.enqueue([ids[2], two.episodes[0].id])
        try await store.projectForTesting(ids[3]) {
            $0.userState.playedDurationMilliseconds = 120_000; $0.userState.lastPlayedTimeMilliseconds = 1_760_000_000_000
            $0.userState.lastPlayedHistoryMilliseconds = 1_760_000_000_000
        }
    }

    private func expectTodaysReads(_ store: FeedLibraryStore, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let all = try await store.allFeedsForTesting()
        #expect(!all.isEmpty, sourceLocation: sourceLocation)
        #expect(try await store.feeds() == all, sourceLocation: sourceLocation)
        let snapshot = try await store.snapshot()
        #expect(snapshot.feeds == all, sourceLocation: sourceLocation)
        #expect(snapshot.queue.map(\.id) == (try await store.queue().map(\.id)), sourceLocation: sourceLocation)
        for marked in [true, false] {
            let statistics = try await store.statistics(includeMarkedAsPlayed: marked, now: Self.now)
            let today = try LibraryStatistics(feeds: all, includeMarkedAsPlayed: marked, timeFrom: 0, timeTo: .max, now: Self.now)
            #expect(statistics == today, sourceLocation: sourceLocation)
        }
    }

    @Test func standaloneReadsAreTodays() async throws {
        let fixture = try await ServerLibraryFixture(server: false)
        try await populate(fixture.store)
        try await expectTodaysReads(fixture.store)
        await fixture.close()
    }

    @Test func serverLibraryReadsWithoutAPinnedRemovalAreTodays() async throws {
        let fixture = try await ServerLibraryFixture()
        try await populate(fixture.store)
        try await expectTodaysReads(fixture.store)
        await fixture.close()
    }

    @Test func aPinnedRemovalLeavesEveryLibraryWideRead() async throws {
        let fixture = try await ServerLibraryFixture()
        let (feed, podcast, _) = try await fixture.subscribeRegistered()
        try await populate(fixture.store)
        try await fixture.store.markPinnedRemovalForTesting(podcast: podcast, feedID: feed.id)
        #expect(try await !fixture.store.feeds().contains { $0.id == feed.id })
        #expect(try await !fixture.store.snapshot().feeds.contains { $0.id == feed.id })
        let rest = try await fixture.store.allFeedsForTesting().filter { $0.id != feed.id }
        let expected = try LibraryStatistics(feeds: rest, includeMarkedAsPlayed: true, timeFrom: 0, timeTo: .max, now: Self.now)
        #expect(try await fixture.store.statistics(now: Self.now) == expected)
        // The player reads its episode's podcast; the screens do not see it.
        #expect(try await fixture.store.playbackFeed(id: feed.id) != nil, "the player still reads its feed")
        #expect(try await fixture.store.feed(id: feed.id) == nil, "the screens do not")
        await fixture.close()
    }
}

extension FeedLibraryStore {
    /// Every feed, pinned removals included (today's `loadFeeds`).
    func allFeedsForTesting() throws -> [LibraryFeed] {
        try database.transaction(write: false) { try loadFeeds() }
    }

    func markPinnedRemovalForTesting(podcast: String, feedID: Int64) throws {
        try database.transaction {
            try database.execute("UPDATE ntp_podcasts SET pinned_removal = 1, live_generation = NULL WHERE podcast_id = ? AND feed_id = ?",
                                 [.text(podcast), .integer(feedID)])
        }
    }
}
