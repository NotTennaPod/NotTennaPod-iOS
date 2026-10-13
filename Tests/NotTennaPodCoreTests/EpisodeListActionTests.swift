import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct EpisodeListActionTests {
    private func item(_ id: Int64, media: Bool = true, local: Bool = false, played: EpisodePlayState = .new,
                      favorite: Bool = false, queued: Bool = false, downloading: Bool = false,
                      downloaded: Bool = false, position: Int32 = 0) -> EpisodeListItem {
        var state = EpisodeUserState(); state.playState = played; state.isFavorite = favorite
        state.isDownloaded = downloaded; state.positionMilliseconds = position
        return .init(episode: .init(id: id, details: .init(title: "Episode", media: media ? .init(url: "https://example.org/\(id)", size: 1) : nil), userState: state), local: local, queued: queued, downloading: downloading)
    }
    @Test func sourceContextAndSelectionOrderAndMixedAvailability() {
        let remote = item(1, position: 900)
        #expect(EpisodeListMenu.actions([remote], selection: false) == [.removeInbox, .markPlayed, .addQueue, .addFavorite, .resetPosition, .share, .multiSelect])
        #expect(EpisodeListMenu.actions([remote], selection: true) == [.download, .markPlayed, .addQueue, .share, .addFavorite, .resetPosition])
        let mixed = [remote, item(2, local: true, played: .played, favorite: true, queued: true, downloaded: true)]
        #expect(EpisodeListMenu.actions(mixed, selection: true) == [.delete, .download, .markUnplayed, .markPlayed, .removeQueue, .addQueue, .addFavorite, .resetPosition])
        #expect(EpisodeListMenu.actions([item(3, downloading: true)], selection: true) == [.delete, .markPlayed, .addQueue, .share, .addFavorite])
        #expect(EpisodeListMenu.actions([item(4, media: false, played: .played)], selection: false) == [.markUnplayed, .addFavorite, .share, .multiSelect])
        let preview = EpisodeListItem(episode: remote.episode, local: false, subscription: .notSubscribed)
        #expect(!EpisodeListMenu.actions([preview], selection: true).contains(.markPlayed))
        #expect(EpisodeListAction.markPlayed.titleKey(hasMedia: false) == "mark_read_no_media_label")
    }
    @Test func selectionKeepsIDsAcrossReplacementAndUsesDisplayedOrder() {
        var selection = EpisodeListSelection(); selection.start(3); selection.toggle(1)
        #expect(selection.selected(displayed: [1, 2, 3]) == [1, 3])
        #expect(selection.selected(displayed: [9]) == [])
        #expect(selection.active && selection.ids == [1, 3])
        selection.above(displayed: [9, 1, 2, 3]); selection.below(displayed: [9, 1, 2, 3, 4])
        #expect(selection.selected(displayed: [9, 1, 2, 3, 4]) == [9, 1, 3, 4])
        selection.toggleAll(displayed: [9, 1, 2, 3, 4])
        #expect(selection.ids.count == 5)
        selection.toggleAll(displayed: [9, 1, 2, 3, 4])
        #expect(selection.active && selection.ids.isEmpty) // overflow deselect differs from last-row toggle
        selection.toggle(2); selection.toggle(2)
        #expect(!selection.active)
    }
    @Test func bulkInboxIsExplicitlyScopedAndKeepsSourceXMLOrder() {
        let items = [item(1, position: 900)]
        #expect(EpisodeListMenu.actions(items, selection: true, bulkInbox: .allowed)
            == [.download, .markPlayed, .addQueue, .share, .removeInbox, .addFavorite, .resetPosition])
        #expect(!EpisodeListMenu.actions(items, selection: true, bulkInbox: .excluded).contains(.removeInbox))
        #expect(!EpisodeListMenu.actions([item(1, played: .unplayed), item(2, played: .played)],
            selection: true, bulkInbox: .allowed).contains(.removeInbox))
        #expect(EpisodeListMenu.actions(items, selection: false, bulkInbox: .excluded).first == .removeInbox)
        #expect(EpisodeListAction.removeInbox.messageKey == "removed_from_inbox_batch_label")
    }
    @Test func bulkInboxTouchesOnlyNewRowsCountsChangesAndPersistsWithoutSyncOrReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BulkInbox-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite"), store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        do {
            let feed = try await store.insert(.init(feed: .init(format: .rss, episodes: (1...4).map {
                .init(identifier: String($0), title: "Episode \($0)", media: .init(url: "https://example.org/\($0)", size: 10, durationMilliseconds: 120_000))
            }), source: "https://example.org/feed", responseURL: URL(string: "https://example.org/feed")!, validator: nil, permanentRedirectURL: nil))
            let ids = feed.episodes.map(\.id)
            _ = try await store.enqueue(ids)
            for (index, id) in ids.enumerated() {
                try await store.updateEpisode(id: id) {
                    $0.userState.playState = index < 2 ? .new : (index == 2 ? .played : .unplayed)
                    $0.userState.positionMilliseconds = 90_000; $0.userState.isFavorite = true
                }
            }
            try await store.selectSynchronizationAccount(UUID())
            let before = try #require(try await store.feed(id: feed.id)), effects = try await store.pendingEffects()
            let executor = EpisodeListActionExecutor(store: store, download: { _ in Issue.record("unexpected download") },
                delete: { _ in Issue.record("bulk inbox must not delete") }, reset: { _ in Issue.record("unexpected reset") })
            let count = try await executor.perform(.removeInbox, items: before.episodes.map { .init(episode: $0, local: false) }, selection: true)
            #expect(count == 2)
            var expected = before
            for index in expected.episodes.indices where expected.episodes[index].userState.playState == .new {
                expected.episodes[index].userState.playState = .unplayed
            }
            #expect(try await store.feed(id: feed.id) == expected)
            #expect(try await store.queue().map(\.id) == ids)
            #expect(try await store.pendingEffects() == effects)
            #expect(try await store.synchronizationQueue().isEmpty)
            #expect(try await executor.perform(.removeInbox, items: expected.episodes.map { .init(episode: $0, local: false) }, selection: true) == 0)
            try await store.close()
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.feed(id: feed.id) == expected)
            #expect(try await reopened.synchronizationQueue().isEmpty)
            try await reopened.close()
        } catch { try? await store.close(); throw error }
    }
    @Test func batchFiltersSideEffectsButKeepsSourceCountsAndDisplayOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        var downloads: [Int64] = [], deleted: [Int64] = [], reset: [Int64] = []
        let executor = EpisodeListActionExecutor(store: store, download: { downloads.append($0) }, delete: { deleted.append($0) }, reset: { reset.append($0) })
        let items = [item(4, position: 30), item(2, local: true, downloaded: true), item(9, downloading: true), item(7, media: false)]
        #expect(try await executor.perform(.download, items: items) == 2)
        #expect(downloads == [4, 9]) // downloading service deduplicates; handler counts it
        #expect(try await executor.perform(.delete, items: items) == 2)
        #expect(deleted == [2, 9])
        #expect(try await executor.perform(.resetPosition, items: items) == 1)
        #expect(reset == [4])
        try await store.close()
    }
    @Test func actionsPersistQueueFavoritesPlayStateAndInboxDoesNotSyncOrReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let feed = try await store.insert(.init(feed: .init(format: .rss, episodes: [1, 2].map { .init(identifier: String($0), title: "Episode \($0)", media: .init(url: "https://example.org/\($0)", size: 10)) }), source: "https://example.org/feed", responseURL: URL(string: "https://example.org/feed")!, validator: nil, permanentRedirectURL: nil))
        let ids = feed.episodes.map(\.id)
        let executor = EpisodeListActionExecutor(store: store, download: { _ in }, delete: { _ in }, reset: { try await store.resetPlaybackPosition(episodeID: $0) })
        let items = feed.episodes.reversed().map { EpisodeListItem(episode: $0, local: false) }
        #expect(try await executor.perform(.addQueue, items: items) == 2)
        #expect(try await store.queue().map(\.id) == ids.reversed())
        #expect(try await executor.perform(.addFavorite, items: items) == 2)
        #expect(try await store.feed(id: feed.id)?.episodes.allSatisfy(\.userState.isFavorite) == true)
        try await store.updateEpisode(id: ids[0]) { $0.userState.positionMilliseconds = 123; $0.userState.playState = .new }
        let before = try await store.pendingEffects()
        try await store.removeEpisodeFromInbox(episodeID: ids[0])
        #expect(try await store.episode(id: ids[0])?.userState.positionMilliseconds == 123)
        #expect(try await store.episode(id: ids[0])?.userState.playState == .unplayed)
        #expect(try await store.pendingEffects() == before)
        #expect(try await executor.perform(.markPlayed, items: items) == 2)
        #expect(try await store.episode(id: ids[0])?.userState.positionMilliseconds == 0)
        #expect(try await store.feed(id: feed.id)?.episodes.allSatisfy { $0.userState.playState == .played } == true)
        #expect(try await executor.perform(.removeQueue, items: items) == 2)
        #expect(try await store.queue().isEmpty)
        try await store.close()
    }
}
