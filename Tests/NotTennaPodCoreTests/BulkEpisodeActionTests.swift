import Foundation
import Testing
@testable import NotTennaPodCore

/// Multi-select actions over a long feed run in one transaction, without re-reading the feed per episode,
/// and leave exactly the state the one-episode-at-a-time actions leave (episodes, queue, sync outbox,
/// statistics session).
@MainActor @Suite struct BulkEpisodeActionTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let count = 150

    private func fetched() -> FetchedFeed {
        let episodes = (0..<count).map { index in
            ParsedEpisode(identifier: "e\(index)", title: "Episode \(index)", description: String(repeating: "Show notes. ", count: 40),
                          publicationDate: now.addingTimeInterval(Double(index)),
                          media: index % 10 == 9 ? nil : ParsedMedia(url: "https://example.test/\(index).mp3", size: 1_000,
                                                                     durationMilliseconds: 600_000))
        }
        return FetchedFeed(feed: ParsedFeed(format: .rss, title: "Long", episodes: episodes), source: "https://example.test/feed",
                           responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil)
    }

    /// A library with mixed state: new, played and in-progress episodes, a queue, a playing session, a sync account.
    private func prepared(_ url: URL) async throws -> (FeedLibraryStore, LibraryFeed) {
        let store = try FeedLibraryStore(url: url)
        let feed = try await store.insert(fetched(), options: FeedRefreshOptions(now: now, timeZone: .gmt))
        for (index, episode) in feed.episodes.enumerated() where index % 3 != 0 {
            try await store.updateEpisode(id: episode.id) {
                $0.userState.playState = index % 3 == 1 ? .new : .played
                $0.userState.positionMilliseconds = Int32(index * 1_000)
                $0.userState.isFavorite = index % 4 == 0
            }
        }
        _ = try await store.enqueue(feed.episodes.prefix(20).filter { $0.details.media != nil }.map(\.id))
        _ = try await store.beginPlayback(episodeID: feed.episodes[1].id)
        try await store.selectSynchronizationAccount(UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!)
        return (store, try #require(try await store.feed(id: feed.id)))
    }

    private struct Outcome: Equatable {
        let feed: LibraryFeed?
        let queue: [Int64]
        let outbox: [SynchronizationQueuedChange.Value]
        let sessionState: EpisodePlayState?
        let effects: [FeedLibraryEffect]
    }

    private func outcome(_ store: FeedLibraryStore, _ feedID: Int64) async throws -> Outcome {
        Outcome(feed: try await store.feed(id: feedID), queue: try await store.queue().map(\.id),
                outbox: try await store.synchronizationQueue().map(\.value),
                sessionState: try await store.playbackSession()?.itemPlayState,
                effects: try await store.pendingEffects().map(\.effect))
    }

    private func compare(_ bulk: (FeedLibraryStore, [Int64]) async throws -> Void,
                         single: (FeedLibraryStore, Int64) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BulkActions-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (a, feedA) = try await prepared(directory.appendingPathComponent("a.sqlite"))
        let (b, feedB) = try await prepared(directory.appendingPathComponent("b.sqlite"))
        do {
            #expect(try await outcome(a, feedA.id) == outcome(b, feedB.id))
            let ids = feedA.displayEpisodes.map(\.id)
            _ = try await a.snapshot()
            let commits = await a.writeCommits, reloads = await a.feedEpisodeReads
            try await bulk(a, ids)
            #expect(await a.writeCommits - commits == 1)
            #expect(await a.feedEpisodeReads == reloads)
            for id in ids { try await single(b, id) }
            let result = try await outcome(a, feedA.id)
            #expect(result == (try await outcome(b, feedB.id)))
            #expect(result.feed != feedA)
            try await a.close(); try await b.close()
        } catch { try? await a.close(); try? await b.close(); throw error }
    }

    @Test func selectAllMarkPlayedIsOneTransactionWithTheSameResult() async throws {
        try await compare({ try await $0.markEpisodesPlayed(episodeIDs: $1, played: true, now: now) },
                          single: { try await $0.markEpisodePlayed(episodeID: $1, played: true, now: now) })
    }

    @Test func selectAllMarkUnplayedIsOneTransactionWithTheSameResult() async throws {
        try await compare({ try await $0.markEpisodesPlayed(episodeIDs: $1, played: false, resetPosition: false, now: now) },
                          single: { try await $0.markEpisodePlayed(episodeID: $1, played: false, resetPosition: false, now: now) })
    }

    @Test func selectAllRemoveFromInboxAndFavoriteAreOneTransactionWithTheSameResult() async throws {
        try await compare({ try await $0.removeEpisodesFromInbox(episodeIDs: $1) },
                          single: { try await $0.removeEpisodeFromInbox(episodeID: $1) })
        try await compare({ try await $0.setFavorite(episodeIDs: $1, favorite: true) },
                          single: { try await $0.setFavorite(episodeID: $1, favorite: true) })
    }

    /// The list executor (multi-select menu) commits the whole selection once and keeps its counts.
    @Test func executorSelectAllCommitsOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BulkExecutor-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, feed) = try await prepared(directory.appendingPathComponent("library.sqlite"))
        do {
            let executor = EpisodeListActionExecutor(store: store, download: { _ in }, delete: { _ in }, reset: { _ in })
            let items = feed.displayEpisodes.map { EpisodeListItem(episode: $0, local: false) }
            for (action, expected) in [(EpisodeListAction.markPlayed, count), (.markUnplayed, count),
                                       (.removeInbox, items.filter { $0.episode.userState.playState == .new }.count),
                                       (.addFavorite, items.filter { !$0.episode.userState.isFavorite }.count)] {
                let commits = await store.writeCommits
                #expect(try await executor.perform(action, items: items, selection: true) == expected)
                #expect(await store.writeCommits - commits == 1)
            }
            let saved = try #require(try await store.feed(id: feed.id))
            #expect(saved.episodes.allSatisfy { $0.userState.playState == .unplayed && $0.userState.isFavorite })
            try await store.close()
        } catch { try? await store.close(); throw error }
    }

    @Test func feedHeaderHasTheFeedsFieldsWithoutEpisodes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BulkHeader-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, feed) = try await prepared(directory.appendingPathComponent("library.sqlite"))
        do {
            var expected = feed; expected.episodes = []
            #expect(try await store.feedHeader(id: feed.id) == expected)
            #expect(try await store.feedHeader(id: 9_999) == nil)
            try await store.close()
        } catch { try? await store.close(); throw error }
    }

    /// A row that disappeared after the selection was made is skipped, as the source's batch UPDATE skips it.
    @Test func missingEpisodeInSelectionIsSkipped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BulkMissing-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, feed) = try await prepared(directory.appendingPathComponent("library.sqlite"))
        do {
            let ids = [feed.episodes[2].id, 9_999_999, feed.episodes[3].id]
            try await store.markEpisodesPlayed(episodeIDs: ids, played: true, now: now)
            #expect(try await store.episode(id: ids[0])?.userState.playState == .played)
            #expect(try await store.episode(id: ids[2])?.userState.playState == .played)
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
}
