import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite
struct FeedListActionTests {
    @Test func ordersMatchUnchangedAndroidQueriesExecutedInSQLite() throws {
        struct Item: Decodable { let id: Int64; let title, link: String?; let date: Double; let duration: Int32? }
        struct Case: Decodable { let code, globalCode: Int; let ids: [Int64] }
        struct Fixture: Decodable { let items: [Item]; let cases: [Case] }
        let url = try #require(Bundle.module.url(forResource: "feed-sort", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let episodes = fixture.items.map { value in
            LibraryEpisode(id: value.id, details: .init(title: value.title, link: value.link,
                publicationDate: Date(timeIntervalSince1970: value.date / 1000),
                media: value.duration.map { .init(url: "https://example.org/\(value.id)", size: 0, durationMilliseconds: $0) }))
        }
        #expect(fixture.cases.count == 60)
        for row in fixture.cases {
            var feed = LibraryFeed(id: 1, source: "https://example.org", metadata: .init(format: .rss), episodes: episodes.reversed())
            feed.episodeSortOrderCode = row.code == 0 ? nil : row.code
            #expect(feed.sortedEpisodes(global: try #require(.init(rawValue: row.globalCode))).map(\.id) == row.ids)
        }
    }
    private func withStore(_ body: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FeedListActions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        do { try await body(store, root); try await store.close() }
        catch { try? await store.close(); throw error }
    }
    private func insert(_ store: FeedLibraryStore, source: String = "https://example.org/feed") async throws -> LibraryFeed {
        try await store.insert(.init(feed: .init(format: .rss, episodes: ["Zulu", "Alpha", "Beta"].enumerated().map { index, title in
            .init(identifier: title, title: title, publicationDate: Date(timeIntervalSince1970: Double(index + 1)),
                  media: .init(url: "https://example.org/\(title).mp3", size: 100, durationMilliseconds: Int32(index * 1000)))
        }), source: source, responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil))
    }
    @Test func immediateRapidSortSelectionsPersistInOrderAndGlobalPreferenceSurvivesReload() async throws {
        try await withStore { store, root in
            let feed = try await insert(store)
            let editor = FeedSortEditor(feed: feed, store: store)
            #expect(editor.selection == .global)
            #expect(editor.fields == [.title, .duration, .date, .global])
            #expect(editor.select(.global) == nil)
            editor.select(.title); #expect(editor.selection == .titleAscending)
            editor.select(.title); #expect(editor.selection == .titleDescending)
            let saved = editor.select(.date); #expect(editor.selection == .dateNewest)
            await saved?.value
            #expect(try await store.feed(id: feed.id)?.episodeSortOrderCode == 2)
            await editor.select(.date)?.value
            #expect(try await store.feed(id: feed.id)?.displayEpisodes.map(\.details.title) == ["Zulu", "Alpha", "Beta"])
            await editor.select(.global)?.value
            let preferences = try NavigationPreferenceStore(file: root.appendingPathComponent("preferences.json"))
            var value = preferences.value; value.defaultFeedSortOrder = .titleDescending
            try preferences.update(value)
            let reopened = try NavigationPreferenceStore(file: root.appendingPathComponent("preferences.json"))
            let reloaded = try #require(try await store.feed(id: feed.id))
            #expect(reloaded.episodeSortOrderCode == 11)
            #expect(reloaded.sortedEpisodes(global: reopened.value.defaultFeedSortOrder).map(\.details.title) == ["Zulu", "Beta", "Alpha"])
        }
    }
    @Test func failedSortSaveRevertsOnlyLatestSelectionAndLaterWritesContinue() async {
        var writes: [FeedEpisodeSortOrder] = [], failures = 0
        let editor = FeedSortEditor(selection: .global, local: true, save: { value in
            writes.append(value)
            if value == .titleAscending || value == .dateNewest { throw CocoaError(.fileWriteUnknown) }
        })
        editor.onFailure = { _ in failures += 1 }
        editor.select(.title)
        await editor.select(.filename)?.value
        #expect(editor.selection == .filenameAscending)
        await editor.select(.date)?.value
        #expect(editor.selection == .filenameAscending)
        #expect(writes == [.titleAscending, .filenameAscending, .dateNewest])
        #expect(failures == 2)
    }
    @Test func removeInboxAffectsOnlyNewEpisodesAndPreservesOtherStateAndEffects() async throws {
        try await withStore { store, _ in
            let feed = try await insert(store), other = try await insert(store, source: "https://example.org/other")
            let ids = feed.episodes.map(\.id)
            for (index, id) in ids.enumerated() {
                try await store.updateEpisode(id: id) {
                    $0.userState.playState = index == 0 ? .new : (index == 1 ? .played : .unplayed)
                    $0.userState.isFavorite = true; $0.userState.positionMilliseconds = index == 0 ? 0 : 900
                    $0.userState.playedDurationMilliseconds = 700; $0.userState.localFileURL = "file:///retained.mp3"
                    $0.userState.isDownloaded = true; $0.userState.downloadDate = Date(timeIntervalSince1970: 100)
                }
            }
            _ = try await store.enqueue([ids[1]])
            let before = try #require(try await store.feed(id: feed.id)), otherBefore = try await store.feed(id: other.id)
            let effects = try await store.pendingEffects(), queue = try await store.queue()
            #expect(try await store.removeFeedFromInbox(feedID: feed.id) == [ids[0]])
            var expected = before
            expected.episodes[0].userState.playState = .unplayed
            #expect(try await store.feed(id: feed.id) == expected)
            #expect(try await store.feed(id: other.id) == otherBefore)
            #expect(try await store.queue() == queue)
            #expect(try await store.pendingEffects() == effects)
            #expect(try await store.removeFeedFromInbox(feedID: feed.id).isEmpty)
        }
    }
}
