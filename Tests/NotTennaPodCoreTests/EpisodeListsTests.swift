import Foundation
import Testing
@testable import NotTennaPodCore

/// Episode list order and database effects against the independent oracle
/// (written from the pinned source without reading this code).
/// The fixture library comes from an Android-schema database through the database import.
@Suite(.serialized) struct EpisodeListsTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized
    static let fixtures = root.appendingPathComponent("TestSupport/Data/episode-list-menus")
    nonisolated(unsafe) static let expected: [String: Any] = {
        let data = try! Data(contentsOf: fixtures.appendingPathComponent("expected/lists.json"))
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    private func withLibrary(_ body: (FeedLibraryStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M22-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let restored = try AndroidDatabaseRestore.read(Self.fixtures.appendingPathComponent("lists.db"), staging: directory.appendingPathComponent("s"))
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        do {
            try await store.installRestoredLibrary(restored, carrying: try await store.restoreCarryOver())
            try await body(store)
        } catch { try? await store.close(); throw error }
        try await store.close()
    }
    private func screen(_ name: String) -> [String: Any] { (Self.expected["screens"] as! [String: Any])[name] as! [String: Any] }
    /// Full expected order: first page plus the following page (iOS shows the whole list).
    private func order(_ screen: [String: Any], code: Int) -> [Int64] {
        let sort = (screen["by_sort"] as! [String: Any])[String(code)] as! [String: Any]
        return ((sort["first_page"] as? [Any] ?? []) + (sort["second_page"] as? [Any] ?? [])).compactMap { ($0 as? NSNumber)?.int64Value }
    }
    private func ids(_ rows: [EpisodeListQueries.Row]) -> [Int64] { rows.map(\.episode.id) }

    @Test func everyScreenAndSortMatchesTheSourceOrderIncludingTies() async throws {
        try await withLibrary { store in
            let snapshot = try await store.snapshot()
            let feeds = snapshot.feeds, queued = Set(snapshot.queue.map(\.id))
            for code in [1, 2, 5, 6] {
                let sort = try #require(EpisodeListSort(rawValue: code))
                #expect(ids(EpisodeListQueries.inbox(feeds, sort: sort)) == order(screen("inbox"), code: code), "inbox \(code)")
                #expect(ids(EpisodeListQueries.favorites(feeds, sort: sort)) == order(screen("favorites"), code: code), "favorites \(code)")
                let filter = FeedEpisodeFilter()
                let all = feeds.filter { $0.subscriptionState == .subscribed }.flatMap { feed in
                    feed.episodes.filter { filter.includes($0, queued: queued.contains($0.id)) }.map { (feed, $0) }
                }
                #expect(ids(EpisodeListQueries.episodes(all, filter: filter, sort: sort)) == order(screen("all_episodes"), code: code), "episodes \(code)")
            }
            // History breaks equal completion times by FeedMedia id. The import keeps episode ids but not media
            // ids, and Android creates an item and its media together, so their orders agree in real data; the
            // fixture swaps them on purpose. Within the oracle's tie groups any order is accepted here.
            let history = ids(EpisodeListQueries.history(feeds)), expectedHistory = order(screen("history"), code: 106)
            let ties = ((screen("history")["by_sort"] as! [String: Any])["106"] as! [String: Any])["ties"] as? [[String: Any]] ?? []
            let groups = ties.map { Set(($0["ids"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.int64Value }) }
            #expect(history.count == expectedHistory.count)
            for (a, e) in zip(history, expectedHistory) where a != e {
                #expect(groups.contains { $0.contains(a) && $0.contains(e) }, "history \(history) vs \(expectedHistory)")
            }
        }
    }

    @Test func sortDialogRowsFollowTheSourceTaps() {
        // Default Date ▼: Duration selects shortest first, Date flips to oldest first.
        #expect(EpisodeListSort.stored(nil) == .dateNewest && EpisodeListSort.stored(99) == .dateNewest)
        #expect(EpisodeListSort.dateNewest.selecting(.duration) == .durationShortest)
        #expect(EpisodeListSort.dateNewest.selecting(.date) == .dateOldest)
        #expect(EpisodeListSort.durationShortest.selecting(.duration) == .durationLongest)
        #expect(EpisodeListSort.durationLongest.selecting(.date) == .dateNewest)
        let dialog = screen("inbox")["sort_dialog"] as! [[String: Any]]
        #expect(dialog.compactMap { $0["tap_selects"] as? Int } == [EpisodeListSort.dateNewest.selecting(.duration).rawValue,
                                                                     EpisodeListSort.dateNewest.selecting(.date).rawValue])
    }

    @Test func removeAllFromInboxChangesOnlyNewToUnplayedEverywhere() async throws {
        try await withLibrary { store in
            let before = try await store.snapshot()
            let changed = try await store.removeAllFromInbox()
            let effect = (Self.expected["effects"] as! [String: Any])["remove_all_from_inbox"] as! [String: Any]
            let expectedIDs = (effect["changed_item_ids"] as! [Any]).compactMap { ($0 as? NSNumber)?.int64Value }
            #expect(Set(changed) == Set(expectedIDs))
            let after = try await store.snapshot()
            #expect(after.queue.map(\.id) == before.queue.map(\.id))
            let old = Dictionary(uniqueKeysWithValues: before.feeds.flatMap(\.episodes).map { ($0.id, $0) })
            for episode in after.feeds.flatMap(\.episodes) {
                let previous = try #require(old[episode.id])
                var expectedState = previous.userState
                if expectedState.playState == .new { expectedState.playState = .unplayed }
                #expect(episode.userState == expectedState, "episode \(episode.id)")
            }
            #expect(EpisodeListQueries.inbox(after.feeds, sort: .standard).isEmpty)
        }
    }

    @Test func clearHistoryResetsOnlyCompletionDates() async throws {
        try await withLibrary { store in
            let before = try await store.snapshot()
            let changed = try await store.clearPlaybackHistory()
            let effect = (Self.expected["effects"] as! [String: Any])["clear_history"] as! [String: Any]
            let expectedIDs = (effect["changed_item_ids"] as! [Any]).compactMap { ($0 as? NSNumber)?.int64Value }
            #expect(Set(changed) == Set(expectedIDs))
            let after = try await store.snapshot()
            let old = Dictionary(uniqueKeysWithValues: before.feeds.flatMap(\.episodes).map { ($0.id, $0) })
            for episode in after.feeds.flatMap(\.episodes) {
                var expectedState = try #require(old[episode.id]).userState
                expectedState.lastPlayedHistoryMilliseconds = nil
                #expect(episode.userState == expectedState, "episode \(episode.id)")
            }
            #expect(EpisodeListQueries.history(after.feeds).isEmpty)
            #expect(after.queue.map(\.id) == before.queue.map(\.id))
        }
    }
}
