import Foundation
import Testing
@testable import NotTennaPodCore

struct FeedInformationLinksTests {
    @Test func matchesActualAndroidFundingWebSpansAndDestinations() throws {
        struct Link: Decodable { let start, length: Int; let url: String }
        struct Case: Decodable { let text: String; let links: [Link] }
        struct Fixture: Decodable { let pattern: String; let flags: Int; let cases: [Case] }
        #if SWIFT_PACKAGE
        let url = try #require(Bundle.module.url(forResource: "feed-information-links", withExtension: "json", subdirectory: "Fixtures"))
        #else
        let url = try #require(Bundle(for: FeedInformationLinksFixtureBundle.self).url(forResource: "feed-information-links", withExtension: "json"))
        #endif
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.cases.count == 6826 && fixture.flags == 0)
        #expect(FeedInformationLinkPattern.value.utf16.elementsEqual(fixture.pattern.utf16))
        for row in fixture.cases {
            let expected = row.links.map { FeedInformationLinks.Link(range: NSRange(location: $0.start, length: $0.length), url: $0.url) }
            let actual = FeedInformationLinks.matches(in: row.text)
            #expect(actual == expected, "Input: \(row.text)")
            for (a, e) in zip(actual, expected) { #expect(a.url.utf16.elementsEqual(e.url.utf16)) }
        }
    }
}

#if !SWIFT_PACKAGE
private final class FeedInformationLinksFixtureBundle: NSObject {}
#endif
