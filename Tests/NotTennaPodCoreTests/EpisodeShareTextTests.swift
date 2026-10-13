import Testing
@testable import NotTennaPodCore

struct EpisodeShareTextTests {
    @Test func sourceSocialTextUsesFullLinksPositionAndFallbackWebsite() {
        var episode = LibraryEpisode(id: 1, details: .init(title: "Episode", link: "  ", media: .init(url: "https://example.org/audio", size: 1)))
        episode.userState.positionMilliseconds = 3_661_999
        let feed = LibraryFeed(id: 1, source: "feed", metadata: .init(format: .rss, title: "Podcast", link: "https://example.org"), episodes: [episode])
        #expect(EpisodeShareText.social(feed: feed, episode: episode, withPosition: true, abbreviated: false) == "Podcast: Episode\nStarting position: 01:01:01\n\nEpisode website: https://example.org\n\nMedia file: https://example.org/audio#t=3661")
        #expect(EpisodeShareText.social(feed: feed, episode: episode, withPosition: false, abbreviated: true) == "Podcast: Episode\nEpisode website: https://example.org\nMedia file: https://example.org/audio")
        episode.details.media?.url = nil
        #expect(!EpisodeShareText.social(feed: feed, episode: episode, withPosition: true, abbreviated: false).contains("Media file"))
        episode.details.media = nil
        #expect(!EpisodeShareText.social(feed: feed, episode: episode, withPosition: true, abbreviated: false).contains("Starting position"))
    }
    @Test func previewAbbreviatesAtJavaUTF16LimitWithoutShorteningSharedText() {
        let title = String(repeating: "é", count: 49) + "終" + "tail"
        let episode = LibraryEpisode(id: 1, details: .init(title: title))
        let feed = LibraryFeed(id: 1, source: "feed", metadata: .init(format: .rss, title: "Podcast"), episodes: [episode])
        #expect(EpisodeShareText.social(feed: feed, episode: episode, withPosition: true, abbreviated: true) == "Podcast: " + String(repeating: "é", count: 49) + "終…")
        #expect(EpisodeShareText.social(feed: feed, episode: episode, withPosition: true, abbreviated: false) == "Podcast: " + title)
    }
}
