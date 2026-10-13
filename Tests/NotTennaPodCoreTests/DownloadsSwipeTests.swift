import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor struct DownloadsSwipeTests {
    @Test func downloadedFilterActionsToggleWithoutCancellingActiveRemoteJobs() {
        var episode = LibraryEpisode(id: 1, details: .init(title: "Episode", media: .init(url: "https://example.test/media", size: 100)))
        let active = EpisodeListItem(episode: episode, local: false, downloading: true)
        #expect(DownloadsSwipeAction.allCases == [.queue, .delete, .favorite, .played])
        #expect(DownloadsSwipeAction.delete.action(for: active) == nil)
        #expect(!DownloadsSwipeAction.delete.removesFromDownloads(active))
        #expect(EpisodeListMenu.actions([active], selection: false).contains(.delete))
        for state in [EpisodePlayState.new, .unplayed, .played] {
            episode.userState.playState = state; episode.userState.positionMilliseconds = 19_000
            let item = EpisodeListItem(episode: episode, local: false)
            #expect(DownloadsSwipeAction.played.action(for: item) == (state == .unplayed ? .markPlayed : .markUnplayed))
            #expect(!DownloadsSwipeAction.played.removesFromDownloads(item))
        }
        episode.userState.isDownloaded = true; episode.userState.isFavorite = true
        let downloaded = EpisodeListItem(episode: episode, local: false, queued: true)
        #expect(DownloadsSwipeAction.queue.action(for: downloaded) == .removeQueue)
        #expect(DownloadsSwipeAction.favorite.action(for: downloaded) == .removeFavorite)
        #expect(DownloadsSwipeAction.delete.removesFromDownloads(downloaded))
        #expect(DownloadsSwipeAction.delete.action(for: downloaded) == .delete)
        episode.userState.isDownloaded = false
        #expect(DownloadsSwipeAction.delete.action(for: .init(episode: episode, local: true)) == .delete)
    }
    @Test func motionUsesSourceDistanceEaseDirectionVelocityAndCancellation() {
        for sign in [-1.0, 1.0] {
            let below = EpisodeSwipeMotion(translation: sign*135, width: 400, removes: false)
            let at = EpisodeSwipeMotion(translation: sign*136, width: 400, removes: false)
            let limit = EpisodeSwipeMotion(translation: sign*1000, width: 400, removes: false)
            #expect(!below.commits(velocityX: sign*1000, velocityY: 0, removes: false))
            #expect(at.commits(velocityX: 0, velocityY: 0, removes: false))
            #expect(abs(limit.displacement-sign*112) < 1)
            #expect(!at.commits(velocityX: 0, velocityY: 0, removes: false, cancelled: true))
            #expect(at.direction == (sign > 0 ? .right : .left))
            let short = EpisodeSwipeMotion(translation: sign*100, width: 400, removes: true)
            #expect(!short.commits(velocityX: sign*179, velocityY: 0, removes: true))
            #expect(short.commits(velocityX: sign*180, velocityY: 0, removes: true))
            #expect(!short.commits(velocityX: sign*1000, velocityY: 1000, removes: true))
            #expect(!short.commits(velocityX: -sign*300, velocityY: 0, removes: true))
            #expect(EpisodeSwipeMotion(translation: sign*200, width: 400, removes: true).commits(velocityX: 0, velocityY: 0, removes: true))
        }
        #expect(!EpisodeSwipeMotion(translation: 100, width: 0, removes: true).commits(velocityX: 1000, velocityY: 0, removes: true))
    }
    @Test func configurationIsPrivateUntilSavedAndSurvivesReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwipePrefs-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("downloads.json"), store = try DownloadPreferenceStore(file: root.appendingPathComponent("downloads.json"))
        #expect(store.value.swipe == nil)
        var draft = store.value.swipe ?? .init()
        #expect(draft.left == .delete && draft.right == .delete && draft.enabled)
        draft.left = .favorite; draft.right = .queue; draft.enabled = false
        #expect(try DownloadPreferenceStore(file: url).value.swipe == nil)
        var value = store.value; value.swipe = draft; try store.update(value)
        let reopened = try #require(DownloadPreferenceStore(file: url).value.swipe)
        #expect(reopened == draft)
        #expect(reopened.action(.left).rawValue == "MARK_FAV" && reopened.action(.right).rawValue == "ADD_TO_QUEUE")
    }
    @Test func swipePlayedTransitionPreservesPositionAndExistingContextActionStillResetsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwipePlayed-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        do {
            let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Feed", episodes: [.init(identifier: "episode", media: .init(url: "https://example.test/media", size: 100, durationMilliseconds: 30_000))]), source: "https://example.test/feed", responseURL: URL(string:"https://example.test/feed")!, validator:nil, permanentRedirectURL:nil))
            let id = try #require(feed.episodes.first?.id)
            try await store.updateEpisode(id: id) { $0.userState.positionMilliseconds = 19_000; $0.userState.playState = .unplayed }
            _ = try await store.enqueue([id])
            let executor = EpisodeListActionExecutor(store: store, download: { _ in Issue.record("unexpected download") }, delete: { _ in Issue.record("unexpected deletion") }, reset: { _ in Issue.record("unexpected reset") })
            let episode = try #require(try await store.episode(id: id))
            _ = try await executor.perform(.markPlayed, items: [.init(episode: episode, local: false)], resetPosition: false)
            let swiped = try #require(try await store.episode(id: id))
            #expect(swiped.userState.playState == .played && swiped.userState.positionMilliseconds == 19_000)
            #expect(try await store.queue().map(\.id) == [id])
            _ = try await executor.perform(.markPlayed, items: [.init(episode: swiped, local: false)])
            #expect(try await store.episode(id: id)?.userState.positionMilliseconds == 0)
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
}
