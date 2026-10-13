import Foundation
import SQLite3
import Testing
@testable import NotTennaPodCore

struct FeedEpisodeFilterTests {
    @Test func matchesUnchangedOriginalSQLAcrossEveryCapturedFilterAndEpisodeState() throws {
        struct Row: Decodable {
            let id: Int64, play: Int, media: Bool, position: Int32?, downloaded: Int64?, history: Int64?
            let favorite, queued: Bool
        }
        struct Case: Decodable { let values: [String], expected: Data }
        struct Fixture: Decodable { let rows: [Row], cases: [Case] }
        let url = try #require(Bundle.module.url(forResource: "feed-filter-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.cases.count == 753 && fixture.rows.count == 1008)
        let episodes = fixture.rows.map { row in
            var state = EpisodeUserState()
            state.playState = EpisodePlayState(rawValue: row.play)!
            state.positionMilliseconds = row.position ?? 0; state.isFavorite = row.favorite
            state.downloadDate = row.downloaded.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            state.lastPlayedHistoryMilliseconds = row.history
            return LibraryEpisode(id: row.id, details: ParsedEpisode(title: "Episode",
                media: row.media ? ParsedMedia(url: "fixture://media", size: 0) : nil), userState: state)
        }
        for item in fixture.cases {
            let filter = FeedEpisodeFilter(values: item.values)
            var result = [UInt8](repeating: 0, count: (episodes.count + 7) / 8)
            for index in episodes.indices where filter.includes(episodes[index], queued: fixture.rows[index].queued) {
                result[index / 8] |= 1 << (index % 8)
            }
            #expect(Data(result) == item.expected, "Original SQL query for \(item.values)")
        }
    }

    @Test func all729DialogStatesToggleExclusivelyResetAndKeepOtherGroups() {
        for mask in 0..<729 {
            var remaining = mask, values: [String] = []
            for group in FeedFilterGroup.allCases {
                let choice = remaining % 3; remaining /= 3
                if choice != 0 { values.append(group.values[choice - 1]) }
            }
            let original = FeedFilterSelection(FeedEpisodeFilter(values: values))
            #expect(original.filter.values == values)
            for group in FeedFilterGroup.allCases {
                for index in 0...1 {
                    var state = original; state.toggle(group: group, index: index)
                    let token = group.values[index]
                    #expect(state.contains(token) == !values.contains(token))
                    #expect(!state.contains(group.values[1 - index]))
                    #expect(state.filter.values.filter { !group.values.contains($0) } == values.filter { !group.values.contains($0) })
                    state.reset(); #expect(!state.filter.isActive)
                }
            }
        }
    }

    @Test func storedTokenParsingAndDialogRestorePreserveSourceDistinctions() {
        #expect(FeedEpisodeFilter(values: [",played,,"]).values == ["", "played"])
        #expect(FeedEpisodeFilter(values: [","]).values.isEmpty)
        #expect(FeedEpisodeFilter(values: ["unknown"]).isActive)
        for values in [["played", "unplayed"], ["unplayed", "played"]] {
            let selection = FeedFilterSelection(FeedEpisodeFilter(values: values))
            #expect(selection.filter.values == [values.last!])
        }
        let restored = FeedFilterSelection(FeedEpisodeFilter(values: ["unknown", "new", "is_in_history", "paused"]))
        #expect(restored.filter.values == ["paused"])
    }

    @Test func filteredDisplayRetainsSourceTitleOrderAndRespondsToCurrentQueueWithoutMutatingEpisodes() {
        let episodes = ["Zebra", "Apple", "Middle"].enumerated().map { index, title in
            LibraryEpisode(id: Int64(index + 1), details: ParsedEpisode(title: title))
        }
        var feed = LibraryFeed(id: 1, source: "fixture://feed", metadata: .init(format: .rss), episodes: episodes)
        feed.episodeSortOrderCode = 3; feed.episodeFilterValues = ["queued"]
        #expect(feed.filteredDisplayEpisodes(queuedIDs: [1, 2]).map(\.id) == [2, 1])
        #expect(feed.filteredDisplayEpisodes(queuedIDs: [3]).map(\.id) == [3])
        #expect(feed.filteredDisplayEpisodes(queuedIDs: []).isEmpty)
        feed.episodeFilterValues = nil
        #expect(feed.filteredDisplayEpisodes(queuedIDs: []).map(\.id) == [2, 3, 1])
        #expect(feed.episodes == episodes)
    }

    @Test func persistenceReopenRefreshLegacyDecodeAndRollbackKeepUnrelatedState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FeedFilter-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let fetched = FetchedFeed(feed: ParsedFeed(format: .rss, title: "Feed", episodes: [
            ParsedEpisode(identifier: "one", title: "One", publicationDate: .distantPast, media: ParsedMedia(url: "https://example.invalid/one.mp3", size: 0))]),
            source: "https://example.invalid/feed", responseURL: URL(string: "https://example.invalid/feed")!, validator: nil, permanentRedirectURL: nil)
        let inserted = try await store.insert(fetched)
        _ = try await store.enqueue(inserted.episodes.map(\.id))
        let feed = try #require(await store.feed(id: inserted.id))
        let effects = try await store.pendingEffects(), queue = try await store.queue()
        #expect(queue.count == 1)
        let filter = FeedEpisodeFilter(values: ["unplayed", "not_downloaded"])
        try await store.setEpisodeFilter(feedID: feed.id, filter: filter)
        #expect(try await store.feed(id: feed.id)?.episodes == feed.episodes)
        #expect(try await store.pendingEffects() == effects)
        #expect(try await store.queue() == queue)
        _ = try await store.applyRefresh(fetched, feedID: feed.id)
        #expect(try await store.feed(id: feed.id)?.episodeFilter == filter)
        try await store.close()
        let reopened = try FeedLibraryStore(url: url)
        #expect(try await reopened.feed(id: feed.id)?.episodeFilter == filter)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await reopened.setEpisodeFilter(feedID: feed.id, filter: .init())
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await reopened.feed(id: feed.id)?.episodeFilter == filter)
        let db = try LibrarySQLite(url: url)
        try db.execute("CREATE TRIGGER reject_filter BEFORE UPDATE ON feeds BEGIN SELECT RAISE(ABORT, 'fixture write denied'); END")
        await #expect(throws: FeedLibraryError.self) { try await reopened.setEpisodeFilter(feedID: feed.id, filter: .init()) }
        #expect(try await reopened.feed(id: feed.id)?.episodeFilter == filter)
        try db.execute("DROP TRIGGER reject_filter"); try db.close()
        try await reopened.setEpisodeFilter(feedID: feed.id, filter: .init())
        #expect(try await reopened.feed(id: feed.id)?.episodeFilter.isActive == false)
        try await reopened.close()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(feed)) as? [String: Any])
        json.removeValue(forKey: "episodeFilterValues")
        let legacy = try JSONDecoder().decode(LibraryFeed.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!legacy.episodeFilter.isActive && legacy.episodeFilterValues == nil)
    }
}
