import Foundation
import Testing
@testable import NotTennaPodCore

struct EpisodeDuplicateMatcherTests {
    @Test func matchesUnmodifiedJavaMatcherAndPool() throws {
        struct Input: Decodable {
            struct Media: Decodable {
                var url: String?
                var duration: Int32
                var mime: String?
            }
            var identifier: String?
            var title: String?
            var date: Int64?
            var media: Media?

            var episode: ParsedEpisode {
                ParsedEpisode(identifier: identifier, title: title,
                              publicationDate: date.map { Date(timeIntervalSince1970: Double($0) / 1_000) },
                              media: media.map { ParsedMedia(url: $0.url, size: 0, mimeType: $0.mime,
                                                            durationMilliseconds: $0.duration) })
            }
        }
        struct Fixture: Decodable {
            var first: Input
            var second: Input
            var zone: String
            var expected: Bool
            var guess: Int64
            var find: Int64
        }
        let url = try #require(Bundle.module.url(forResource: "duplicates-java", withExtension: "json",
                                                subdirectory: "Fixtures"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        #expect(fixtures.count == 6_906)
        for (index, fixture) in fixtures.enumerated() {
            let zone = try #require(TimeZone(identifier: fixture.zone))
            let first = fixture.first.episode
            let second = fixture.second.episode
            #expect(EpisodeDuplicateMatcher.seemDuplicates(first, second, timeZone: zone) == fixture.expected,
                    "Java fixture \(index), zone \(fixture.zone)")
            let pool = EpisodeDuplicatePool([
                RefreshEpisode(LibraryEpisode(id: 0, details: first)),
                RefreshEpisode(LibraryEpisode(id: 1, details: second))
            ], timeZone: zone)
            #expect((pool.guess(second)?.value.id ?? -1) == fixture.guess, "Java pool guess fixture \(index)")
            #expect((pool.findByID(second)?.value.id ?? -1) == fixture.find, "Java pool ID fixture \(index)")
        }
    }

    @Test func identifyingValueUsesActualSourcePrecedenceIncludingEmptyMediaURL() {
        var episode = ParsedEpisode(identifier: "id", title: "title", link: "link",
                                    media: ParsedMedia(url: "media", size: 0, mimeType: nil))
        #expect(EpisodeDuplicateMatcher.identifyingValue(episode) == "id")
        episode.identifier = ""
        #expect(EpisodeDuplicateMatcher.identifyingValue(episode) == "title")
        episode.title = ""
        #expect(EpisodeDuplicateMatcher.identifyingValue(episode) == "media")
        episode.media?.url = ""
        #expect(EpisodeDuplicateMatcher.identifyingValue(episode) == "")
        episode.media?.url = nil
        #expect(EpisodeDuplicateMatcher.identifyingValue(episode) == "link")
        episode.link = nil
        #expect(EpisodeDuplicateMatcher.identifyingValue(episode) == nil)
    }

    @Test func matchingDoesNotApplySwiftCanonicalUnicodeEquality() {
        let first = ParsedEpisode(identifier: "é")
        let second = ParsedEpisode(identifier: "e\u{301}")
        #expect(!EpisodeDuplicateMatcher.seemDuplicates(first, second))
        let pool = EpisodeDuplicatePool([RefreshEpisode(LibraryEpisode(id: 7, details: first))], timeZone: .gmt)
        #expect(pool.findByID(second) == nil)
    }

    @Test func poolRetainsOriginalKeysButObservesUpdatedObjectValues() {
        let node = RefreshEpisode(LibraryEpisode(id: 1, details: ParsedEpisode(identifier: "old", title: "Title")))
        let pool = EpisodeDuplicatePool([node], timeZone: .gmt)
        node.value.details.identifier = "new"
        #expect(pool.findByID(ParsedEpisode(identifier: "old")) === node)
        #expect(pool.findByID(ParsedEpisode(identifier: "new")) == nil)
        #expect(pool.guess(ParsedEpisode(identifier: "new", title: "Title")) === node)
    }
}
