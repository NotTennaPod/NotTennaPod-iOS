import Foundation
import Testing
@testable import NotTennaPodCore

/// A realistically large library (500 podcasts, 50,000 episodes) restored from
/// an Android 3.12.1 backup through the real restore stays correct and usable: the lists a person opens,
/// search, a refresh merge and the OPML, HTML and database exports.
///
/// The library is generated deterministically in Android's own schema (`LargeAndroidLibrary`); expected
/// orders and counts come from the generated rows. Budgets are human-scale for this debug host build;
/// the mounted lists' budgets on the Simulator are in `LargeLibraryViewTests`.
@Suite(.serialized) struct LargeLibraryScaleTests {
    private func temp() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GapRobustScale-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func timed<T>(_ body: () async throws -> T) async rethrows -> (T, Duration) {
        let start = ContinuousClock.now
        let value = try await body()
        return (value, ContinuousClock.now - start)
    }
    /// Generates and restores the library as the Database import does (validated private copy, then one install).
    private func restored(in directory: URL) async throws -> (LargeAndroidLibrary.Summary, FeedLibraryStore, Duration) {
        let backup = directory.appendingPathComponent("Antennapod.db")
        let summary = try LargeAndroidLibrary.write(to: backup)
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let (_, elapsed) = try await timed {
            let library = try AndroidDatabaseRestore.read(backup, staging: directory.appendingPathComponent("staging"))
            try await store.installRestoredLibrary(library, carrying: try await store.restoreCarryOver())
        }
        return (summary, store, elapsed)
    }

    @Test func restoredLargeLibraryListsAndSearchAreCompleteAndQuick() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let (summary, store, restore) = try await restored(in: directory)
        #expect(restore < .seconds(20), "restore took \(restore)")
        let (snapshot, load) = try await timed { try await store.snapshot() }
        #expect(load < .seconds(3), "library load took \(load)")
        #expect(snapshot.feeds.count == 500 && snapshot.feeds.reduce(0) { $0 + $1.episodes.count } == 50_000)
        #expect(snapshot.queue.map(\.id) == summary.queue, "queue order kept")

        // Each list's complete content in Android's order, each well under a second of work.
        let (inbox, inboxTime) = await timed { EpisodeListQueries.inbox(snapshot.feeds, sort: .dateNewest) }
        #expect(inbox.map(\.episode.id) == summary.inboxOrder && inbox.count > 900)
        let (history, historyTime) = await timed { EpisodeListQueries.history(snapshot.feeds) }
        #expect(history.map(\.episode.id) == summary.historyOrder && history.count > 4_000)
        let (favorites, favoritesTime) = await timed { EpisodeListQueries.favorites(snapshot.feeds, sort: .dateNewest) }
        #expect(Set(favorites.map(\.episode.id)) == summary.favorites)
        let (all, allTime) = await timed {
            EpisodeListQueries.episodes(snapshot.feeds.flatMap { feed in feed.episodes.map { (feed: feed, episode: $0) } },
                                        filter: .init(), sort: .dateNewest)
        }
        #expect(all.count == 50_000 && all.first?.episode.id == summary.episodes.max { ($0.pubDate, -$0.id) < ($1.pubDate, -$1.id) }?.id)
        let (subscriptions, subscriptionsTime) = await timed {
            SubscriptionListQueries.load(snapshot.feeds, preferences: .init(), state: .subscribed, globalAutoDownload: false)
        }
        #expect(Set(subscriptions.feeds.map(\.id)) == summary.subscribedFeedIDs)
        for (name, time) in [("Inbox", inboxTime), ("History", historyTime), ("Favorites", favoritesTime),
                             ("Episodes", allTime), ("Subscriptions", subscriptionsTime)] {
            #expect(time < .seconds(1), "\(name) took \(time)")
        }
        print("GAP-ROBUST timing: restore \(restore), load \(load), inbox \(inboxTime), history \(historyTime), favorites \(favoritesTime), episodes \(allTime), subscriptions \(subscriptionsTime)")

        // Search: a rare word finds exactly its episodes, newest first; a common word stays capped and quick.
        let (rare, rareTime) = try await timed { try await store.search(query: summary.searchWord) }
        let expected = summary.episodes.filter { summary.searchHits.contains($0.id) }
            .sorted { $0.pubDate == $1.pubDate ? $0.id < $1.id : $0.pubDate > $1.pubDate }.map(\.id)
        #expect(rare.episodes.map(\.episode.id) == expected && !expected.isEmpty)
        let (common, commonTime) = try await timed { try await store.search(query: "history music") }
        #expect(common.episodes.count == 300, "source cap")
        #expect(rareTime < .seconds(1) && commonTime < .seconds(2), "search took \(rareTime), \(commonTime)")
        print("GAP-ROBUST timing: search rare \(rareTime), common \(commonTime)")
        try await store.close()
    }

    @Test func largeLibraryExportsAndRefreshMergeCompleteInSeconds() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let (summary, store, _) = try await restored(in: directory)

        let (opml, opmlTime) = try await timed { try OPMLExportWriter.data(for: try await store.feeds(), createdAt: Date(), timeZone: .current) }
        #expect(String(decoding: opml, as: UTF8.self).components(separatedBy: "<outline ").count - 1 == summary.subscribedFeedIDs.count)
        let (html, htmlTime) = try await timed { HTMLExportWriter.subscriptions(try await store.feeds()) }
        #expect(String(decoding: html, as: UTF8.self).components(separatedBy: "<li>").count - 1 == summary.subscribedFeedIDs.count)
        let (backup, backupTime) = try await timed { try await AndroidDatabaseBackup.data(library: store, speeds: .init(), credentials: { _ in nil }) }
        for (name, time) in [("OPML", opmlTime), ("HTML", htmlTime), ("database", backupTime)] {
            #expect(time < .seconds(10), "\(name) export took \(time)")
        }
        // The exported database is a complete Android backup: it restores to the same library.
        let exported = directory.appendingPathComponent("exported.db")
        try backup.write(to: exported)
        let again = try AndroidDatabaseRestore.read(exported, staging: directory.appendingPathComponent("again"))
        #expect(again.feeds.count == 500 && again.feeds.reduce(0) { $0 + $1.episodes.count } == 50_000 && again.queue == summary.queue)

        // Refresh merge: the longest-running show gains ten episodes; then every podcast is merged once,
        // the store work of a full refresh.
        let largest = try #require(try await store.feed(id: summary.largestFeedID))
        func fetched(_ feed: LibraryFeed, adding: Int) -> FetchedFeed {
            var parsed = ParsedFeed(format: .rss, title: feed.metadata.title)
            parsed.episodes = feed.episodes.map(\.details) + (0..<adding).map {
                ParsedEpisode(identifier: "new-\(feed.id)-\($0)", title: "New \($0)", publicationDate: Date(timeIntervalSince1970: 1_790_100_000 + Double($0)))
            }
            return FetchedFeed(feed: parsed, source: feed.source, responseURL: URL(string: feed.source)!, validator: nil, permanentRedirectURL: nil)
        }
        let (merged, mergeTime) = try await timed { try await store.applyRefresh(fetched(largest, adding: 10), feedID: largest.id) }
        #expect(merged.feed.episodes.count == largest.episodes.count + 10)
        #expect(mergeTime < .seconds(2), "merge took \(mergeTime)")
        let feeds = try await store.feeds()
        let (_, fullTime) = try await timed {
            for feed in feeds { _ = try await store.applyRefresh(fetched(feed, adding: 0), feedID: feed.id) }
        }
        #expect(fullTime < .seconds(60), "merging all 500 podcasts took \(fullTime)")
        print("GAP-ROBUST timing: OPML \(opmlTime), HTML \(htmlTime), database \(backupTime), merge largest \(mergeTime), merge all \(fullTime)")
        #expect(try await store.snapshot().feeds.reduce(0) { $0 + $1.episodes.count } == 50_010)
        try await store.close()
    }
}
