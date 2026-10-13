import Foundation
import Testing
@testable import NotTennaPodCore

struct EpisodeStateActionTests {
    @Test func originalSyncAdmissionAndIntegerSecondPayloads() {
        for connected in [false, true] {
            for local in [false, true] {
                for subscription in FeedSubscriptionState.allCases {
                    for media in [false, true] {
                        for played in [false, true] {
                            for duration: Int32 in [-1, 0, 999, 1_000, 99_999, .max] {
                                let episode = LibraryEpisode(id: 1, details: ParsedEpisode(identifier: "guid", media: media
                                    ? ParsedMedia(url: "https://example.test/audio", size: 0, durationMilliseconds: duration) : nil))
                                var feed = LibraryFeed(id: 1, source: local ? "antennapod_local:folder" : "https://example.test/rss",
                                    metadata: ParsedFeed(format: .rss), episodes: [episode])
                                feed.subscriptionState = subscription
                                let action = EpisodeStateSyncAction(episode: episode, feed: feed, played: played, providerConnected: connected)
                                if !connected || local || !media || subscription == .notSubscribed {
                                    #expect(action == nil)
                                } else {
                                    #expect(action?.kind == (played ? .play : .new))
                                    #expect(action?.podcast == "https://example.test/rss")
                                    #expect(action?.episode == "https://example.test/audio" && action?.guid == "guid")
                                    // Original Java integer division truncates toward zero.
                                    let seconds: Int32 = switch duration {
                                    case -1, 0, 999: 0
                                    case 1_000: 1
                                    case 99_999: 99
                                    default: 2_147_483
                                    }
                                    #expect(action?.started == (played ? seconds : -1))
                                    #expect(action?.position == action?.started && action?.total == action?.started)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func manualStateChangesAndOutboxSurviveReopen(played: Bool, media: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ManualState-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let detail = ParsedEpisode(identifier: "guid", title: "Episode", media: media
            ? ParsedMedia(url: "https://example.test/audio", size: 100, durationMilliseconds: 99_999) : nil)
        let feed = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, episodes: [detail]),
            source: "https://example.test/rss", responseURL: URL(string: "https://example.test/rss")!, validator: nil, permanentRedirectURL: nil))
        let id = try #require(feed.episodes.first?.id)
        if media { _ = try await store.beginPlayback(episodeID: id) }
        // The manual action is delivered to a connected account's outbox (the effect is not kept).
        try await store.selectSynchronizationAccount(UUID())
        let selection = try await store.playbackSelectionEpisodeID()
        let session = try await store.playbackSession()
        let queue = try await store.queue().map(\.id)
        for initial in EpisodePlayState.allCases {
            try await store.updateEpisode(id: id) {
                $0.userState.playState = initial
                $0.userState.positionMilliseconds = 45_000
                $0.userState.isFavorite = true
                $0.userState.playedDurationMilliseconds = 50_000
                $0.userState.timeSpentMilliseconds = 60_000
                $0.userState.lastPlayedHistoryMilliseconds = 70_000
                $0.userState.playbackCompletionDate = now
                $0.userState.localFileURL = "/test/audio.mp3"
                $0.userState.isDownloaded = media
            }
            var expected = try #require(await store.episode(id: id))
            expected.userState.playState = played ? .played : .unplayed
            if played && media { expected.userState.positionMilliseconds = 0 }
            let count = try await store.synchronizationQueue().count, pending = try await store.pendingEffects()
            try await store.markEpisodePlayed(episodeID: id, played: played, syncProviderConnected: true, now: now)
            #expect(try await store.episode(id: id) == expected)
            #expect(try await store.queue().map(\.id) == queue)
            #expect(try await store.playbackSelectionEpisodeID() == selection)
            #expect(try await store.playbackSession()?.id == session?.id)
            #expect(try await store.pendingEffects() == pending)
            let outbox = try await store.synchronizationQueue()
            #expect(outbox.count == count + (media ? 1 : 0))
            if media {
                let last = try #require(outbox.last)
                guard case .episode(let action) = last.value else { Issue.record("Missing manual sync action"); return }
                #expect(action.timestamp == now && action.podcast == feed.source && action.episode == "https://example.test/audio")
                #expect(action.action == (played ? .play : .new))
                #expect(action.started == (played ? 99 : -1))
                // A retained statistics session must not put a stale New flag back.
                _ = try await store.recordPlayback(sessionID: try #require(session?.id),
                    sample: PlaybackSample(positionMilliseconds: 0, durationMilliseconds: 99_999, status: .playing))
                #expect(try await store.episode(id: id)?.userState.playState == expected.userState.playState)
            }
        }
        let final = try await store.episode(id: id)
        let effects = try await store.pendingEffects()
        await #expect(throws: FeedLibraryError.missingEpisode(999)) {
            try await store.markEpisodePlayed(episodeID: 999, played: true, syncProviderConnected: true)
        }
        #expect(try await store.pendingEffects() == effects)
        try await store.close()
        let reopened = try FeedLibraryStore(url: url)
        #expect(try await reopened.episode(id: id) == final)
        #expect(try await reopened.pendingEffects() == effects)
        #expect(try await reopened.synchronizationQueue().count == (media ? EpisodePlayState.allCases.count : 0))
        #expect(try await reopened.playbackSelectionEpisodeID() == selection)
        try await reopened.close()
    }
}
