import Foundation
import Testing
@testable import NotTennaPodCore

struct EpisodeMenuTests {
    private func feed(media: Bool = true, local: Bool = false) -> LibraryFeed {
        LibraryFeed(id: 1, source: local ? "antennapod_local:folder" : "https://example.test/feed",
            metadata: ParsedFeed(format: .rss, link: "https://example.test/podcast"),
            episodes: [LibraryEpisode(id: 1, details: ParsedEpisode(identifier: "one", title: "Episode",
                media: media ? ParsedMedia(url: "https://example.test/one.mp3", size: 0) : nil))])
    }

    @Test func originalCapturedUnplayedMenuKeepsCategoryOrder() {
        let feed = feed()
        // first-journey/09-episode-menu: actual Android text order, not XML order.
        let actions = EpisodeMenu.actions(episode: feed.episodes[0], feed: feed, queued: false, isSelectedMedia: false)
        #expect(actions == [.markPlayed, .addToQueue, .openPodcast, .addFavorite, .share])
        #expect(actions.map { $0.titleKey(hasMedia: true) } == ["mark_as_played_label", "add_to_queue_label", "open_podcast", "add_to_favorite_label", "share_label"])
    }

    @Test func activeQueuedFavoriteWithPositionAndOverflowWebsite() {
        var feed = feed()
        feed.episodes[0].userState.isFavorite = true
        feed.episodes[0].userState.positionMilliseconds = 20_000
        feed.episodes[0].userState.playState = .new
        #expect(EpisodeMenu.actions(episode: feed.episodes[0], feed: feed, queued: true, isSelectedMedia: true, websiteInToolbar: false)
            == [.skip, .removeFromInbox, .markPlayed, .removeFromQueue, .resetPosition, .website, .openPodcast, .removeFavorite, .share])
    }

    @Test func textLocalPreviewAndPlayedRulesPreserveAvailableActions() {
        var local = feed(media: false, local: true)
        #expect(EpisodeMenu.actions(episode: local.episodes[0], feed: local, queued: false, isSelectedMedia: true, websiteInToolbar: false)
            == [.openPodcast, .addFavorite])
        local.episodes[0].userState.playState = .played
        #expect(EpisodeMenu.actions(episode: local.episodes[0], feed: local, queued: true, isSelectedMedia: false)
            == [.markUnplayed, .removeFromQueue, .openPodcast, .addFavorite])
        #expect(EpisodeMenu.Action.markUnplayed.titleKey(hasMedia: false) == "mark_unread_label_no_media")
        var preview = feed()
        preview.subscriptionState = .notSubscribed
        #expect(EpisodeMenu.actions(episode: preview.episodes[0], feed: preview, queued: false, isSelectedMedia: false)
            == [.addToQueue, .openPodcast, .addFavorite, .share])
        preview.subscriptionState = .archived
        #expect(EpisodeMenu.actions(episode: preview.episodes[0], feed: preview, queued: false, isSelectedMedia: false).first == .markPlayed)
    }

    @Test func favoriteCommandsPreserveCurrentPlaybackQueueMetadataAndSurviveReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Favorite-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let original = feed()
        let parsed = ParsedFeed(format: .rss, title: "Feed", episodes: original.episodes.map(\.details))
        let saved = try await store.insert(FetchedFeed(feed: parsed, source: original.source,
            responseURL: URL(string: original.source)!, validator: nil, permanentRedirectURL: nil))
        let id = try #require(saved.episodes.first?.id)
        try await store.updateEpisode(id: id) {
            $0.userState.playState = .played
            $0.userState.autoDownloadEnabled = false
            $0.userState.localFileURL = "/test/one.mp3"
            $0.userState.isDownloaded = true
        }
        let session = try await store.beginPlayback(episodeID: id)
        _ = try await store.recordPlayback(sessionID: session.id, sample: PlaybackSample(positionMilliseconds: 12_345, durationMilliseconds: 100_000, status: .playing))
        let effects = try await store.pendingEffects()
        let selection = try await store.playbackSelectionEpisodeID()
        for favorite in [true, true, false, false, true] {
            let before = try #require(await store.episode(id: id))
            try await store.setFavorite(episodeID: id, favorite: favorite)
            var expected = before
            expected.userState.isFavorite = favorite
            #expect(try await store.episode(id: id) == expected)
            #expect(try await store.queue().map(\.id) == [id])
            #expect(try await store.pendingEffects() == effects)
            #expect(try await store.playbackSelectionEpisodeID() == selection)
            #expect(try await store.playbackSession()?.id == session.id)
            _ = try await store.recordPlayback(sessionID: session.id, sample: PlaybackSample(positionMilliseconds: 23_456, durationMilliseconds: 100_000, status: .paused))
            #expect(try await store.episode(id: id)?.userState.isFavorite == favorite)
        }
        let final = try await store.episode(id: id)
        await #expect(throws: FeedLibraryError.missingEpisode(999)) { try await store.setFavorite(episodeID: 999, favorite: true) }
        #expect(try await store.episode(id: id) == final)
        try await store.close()
        let reopened = try FeedLibraryStore(url: url)
        #expect(try await reopened.episode(id: id) == final)
        #expect(try await reopened.queue().map(\.id) == [id])
        try await reopened.close()
    }
}
