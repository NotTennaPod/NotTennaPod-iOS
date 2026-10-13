import Foundation
import Testing
@testable import NotTennaPodCore

@Suite struct PlayerOverflowTests {
    @Test func sourceVisibilityOrderingAndMetadataFallbacks() throws {
        let source = "https://example.invalid/feed"
        let feed = LibraryFeed(id: 1, source: source, metadata: .init(format: .rss, link: "https://example.invalid/podcast"), episodes: [])
        let episode = LibraryEpisode(id: 1, details: .init(identifier: "one", title: "Episode"), userState: .init())
        #expect(PlayerOverflowAction.available(episode: episode, feed: feed) == [.openPodcast, .visitWebsite])
        var rich = episode
        rich.details.transcript = .init(format: .json, url: "https://example.invalid/transcript")
        rich.details.socialInteractionURL = "https://example.invalid/comments"
        #expect(PlayerOverflowAction.available(episode: rich, feed: feed) == [.openPodcast, .visitWebsite, .transcript, .comments])
        var local = feed; local.source = "antennapod_local:folder"
        #expect(PlayerOverflowAction.available(episode: rich, feed: local) == [.openPodcast, .transcript, .comments])
        let noLink = LibraryFeed(id: 1, source: source, metadata: .init(format: .rss, link: " \t"), episodes: [])
        #expect(PlayerOverflowAction.available(episode: episode, feed: noLink) == [.openPodcast])
        rich.details.socialInteractionURL = ""
        #expect(PlayerOverflowAction.available(episode: rich, feed: noLink) == [.openPodcast, .transcript, .comments])
    }
}
