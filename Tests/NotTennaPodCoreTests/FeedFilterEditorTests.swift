import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor
struct FeedFilterEditorTests {
    private func fixture() async throws -> (URL, FeedLibraryStore, LibraryFeed) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FilterEditor-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let feed = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Feed"),
            source: "https://example.invalid/feed", responseURL: URL(string: "https://example.invalid/feed")!,
            validator: nil, permanentRedirectURL: nil))
        return (directory, store, feed)
    }

    @Test func rapidSelectionsAndResetPersistInTapOrderWithoutConfirm() async throws {
        let (directory, store, feed) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = FeedFilterEditor(feed: feed, store: store)
        var saved: [[String]] = [], errors = 0
        editor.onEvent = { event in
            if case .saved(let feed) = event { saved.append(feed.episodeFilter.values) }
            if case .failed = event { errors += 1 }
        }
        editor.toggle(group: .played, index: 0)
        editor.toggle(group: .played, index: 1)
        editor.toggle(group: .queued, index: 0)
        editor.reset()
        editor.toggle(group: .downloaded, index: 1)
        #expect(editor.selection.filter.values == ["not_downloaded"])
        await editor.waitForPendingChanges()
        #expect(saved == [["played"], ["unplayed"], ["unplayed", "queued"], [], ["not_downloaded"]])
        #expect(errors == 0)
        #expect(try await store.feed(id: feed.id)?.episodeFilter.values == ["not_downloaded"])
        try await store.close()
    }

    @Test func rejectedWriteRestoresLastPersistedSelectionAndReportsFailure() async throws {
        let (directory, store, feed) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.setEpisodeFilter(feedID: feed.id, filter: .init(values: ["played"]))
        let editor = FeedFilterEditor(feed: try #require(await store.feed(id: feed.id)), store: store)
        let db = try LibrarySQLite(url: directory.appendingPathComponent("library.sqlite"))
        try db.execute("CREATE TRIGGER reject_filter BEFORE UPDATE ON feeds BEGIN SELECT RAISE(ABORT, 'fixture write denied'); END")
        var failures = 0, saved = 0
        editor.onEvent = {
            if case .failed = $0 { failures += 1 }
            if case .saved = $0 { saved += 1 }
        }
        editor.toggle(group: .played, index: 1)
        #expect(editor.selection.filter.values == ["unplayed"])
        await editor.waitForPendingChanges()
        #expect(editor.selection.filter.values == ["played"])
        #expect(failures == 1 && saved == 0)
        try db.execute("DROP TRIGGER reject_filter"); try db.close()
        editor.toggle(group: .played, index: 1); await editor.waitForPendingChanges()
        #expect(saved == 1 && editor.selection.filter.values == ["unplayed"])
        try await store.close()
    }

    /// Closing the dialog straight after a tap does not lose that tap's saved filter.
    @Test func tapImmediatelyBeforeClosingTheDialogIsStillSaved() async throws {
        let (directory, store, feed) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var editor: FeedFilterEditor? = FeedFilterEditor(feed: feed, store: store)
        editor?.toggle(group: .favorite, index: 0)
        editor = nil // The dialog closes; nothing else holds the editor.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while try await store.feed(id: feed.id)?.episodeFilter.values != ["is_favorite"], ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await store.feed(id: feed.id)?.episodeFilter.values == ["is_favorite"])
        try await store.close()
    }

    @Test func openingNormalizesCheckedLegacyOptionsButPreservesUnknownOnlyFilters() async throws {
        let (directory, store, feed) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (values, expected) in [(["played","unplayed"], ["unplayed"]),
                                   (["unplayed","played"], ["played"]),
                                   (["new","is_in_history","queued"], ["queued"]),
                                   (["unknown","new"], ["unknown","new"])] {
            try await store.setEpisodeFilter(feedID: feed.id, filter: .init(values: values))
            let editor = FeedFilterEditor(feed: try #require(await store.feed(id: feed.id)), store: store)
            var writes = 0
            editor.onEvent = { if case .saved = $0 { writes += 1 } }
            editor.restoreVisibleOptions(); editor.restoreVisibleOptions()
            await editor.waitForPendingChanges()
            #expect(try await store.feed(id: feed.id)?.episodeFilter.values == expected)
            #expect(writes == (values == expected ? 0 : 1))
        }
        try await store.close()
    }
}
