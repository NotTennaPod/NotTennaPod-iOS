import Foundation
import Testing
@testable import NotTennaPodCore

struct EpisodeWebsiteTests {
    private struct Oracle: Decodable {
        struct Case: Decodable { let episode, feed, expected: String? }
        let referenceCommit: String
        let blankUTF16Units: Set<UInt32>
        let cases: [Case]
    }

    @Test func fallbackMatchesUnchangedOriginalJavaAndDoesNotRewriteLinks() throws {
        let url = try #require(Bundle.module.url(forResource: "episode-website-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        #expect(oracle.referenceCommit == "f8c641887e4677237b01b6e942ff8fe20fc8beec")
        #expect(oracle.cases.count == 324)
        for item in oracle.cases {
            #expect(EpisodeWebsite.link(episode: item.episode, feed: item.feed) == item.expected)
        }
        // Java's char-based blank test has a finite BMP domain. Include the
        // supplementary scalar boundaries to verify surrogate pairs stay links.
        for value: UInt32 in Array(0...0xFFFF) + [0x10000, 0x1F600, 0x10FFFF] {
            guard let scalar = UnicodeScalar(value) else { continue }
            let text = String(scalar)
            let blank = oracle.blankUTF16Units.contains(value)
            #expect(EpisodeWebsite.link(episode: text, feed: "fallback") == (blank ? "fallback" : text))
        }
    }

    @Test func pagerHidesWebsiteForTextOnlyLocalAndMissingLinksAcrossPlaybackStates() {
        for hasMedia in [false, true] {
            for source in ["https://example.test/rss", "antennapod_local:folder", "ANTENNAPOD_LOCAL:folder"] {
                for link: String? in [nil, "", " \t", "https://example.test/item"] {
                    for feedLink: String? in [nil, "", "https://example.test/podcast"] {
                        for state in EpisodePlayState.allCases {
                            var episode = LibraryEpisode(id: 1, details: ParsedEpisode(link: link,
                                media: hasMedia ? ParsedMedia(size: 0) : nil))
                            episode.userState.playState = state
                            let feed = LibraryFeed(id: 1, source: source, metadata: ParsedFeed(format: .rss, link: feedLink), episodes: [episode])
                            let expected = hasMedia && source != "antennapod_local:folder"
                                ? (link == "https://example.test/item" ? link : (feedLink == "" ? nil : feedLink)) : nil
                            #expect(EpisodeWebsite.toolbarDestination(episode: episode, feed: feed) == expected)
                        }
                    }
                }
            }
        }
    }

    @Test func refreshedLinksChangeDestinationWithoutChangingListeningState() {
        var episode = LibraryEpisode(id: 1, details: ParsedEpisode(identifier: "episode", link: "https://example.test/old", media: ParsedMedia(size: 0)))
        episode.userState.positionMilliseconds = 12_345
        episode.userState.playState = .played
        let originalState = episode.userState
        episode.update(from: ParsedEpisode(link: "https://example.test/new"))
        let feed = LibraryFeed(id: 1, source: "https://example.test/rss", metadata: ParsedFeed(format: .rss, link: "https://example.test/podcast"), episodes: [episode])
        #expect(EpisodeWebsite.toolbarDestination(episode: episode, feed: feed) == "https://example.test/new")
        episode.update(from: ParsedEpisode(link: " "))
        #expect(EpisodeWebsite.toolbarDestination(episode: episode, feed: feed) == "https://example.test/podcast")
        #expect(episode.userState == originalState)
    }
}
