import Foundation
import Testing
@testable import NotTennaPodCore

struct FeedInformationTests {
    @Test func matchesOriginalDescriptionAndFundingOutputIncludingUTF16Distinctions() throws {
        struct Description: Decodable { let input: String?, expected: String }
        struct Funding: Decodable { let entries: [FeedFunding], expected: String }
        struct Fixture: Decodable { let descriptions: [Description], funding: [Funding] }
        let url = try #require(Bundle.module.url(forResource: "feed-information-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.descriptions.count == 101 && fixture.funding.count == 118)
        for item in fixture.descriptions {
            let result = try FeedDescriptionText.format(item.input)
            #expect(result.utf16.elementsEqual(item.expected.utf16), "Description: \(item.input ?? "nil")")
        }
        for item in fixture.funding {
            let result = FeedInformation.fundingText(item.entries, supportLabel: "Support this podcast")
            #expect(result.utf16.elementsEqual(item.expected.utf16), "Funding: \(item.entries)")
        }
    }

    @Test func subscriptionLocalLinkAndFundingVisibilityUseOriginalConditions() throws {
        for subscription in FeedSubscriptionState.allCases {
            for local in [false, true] {
                for link in [nil, "", "https://example.test"] as [String?] {
                    for callable in [false, true] {
                        for funded in [false, true] {
                            var metadata = ParsedFeed(format: .rss, description: "<p>Description</p>", link: link)
                            if funded { metadata.funding = [FeedFunding(url: "https://example.test/support", content: "")] }
                            var feed = LibraryFeed(id: 1, source: local ? "antennapod_local:folder" : "https://example.test/feed",
                                metadata: metadata, episodes: [])
                            feed.subscriptionState = subscription
                            let original = feed
                            let info = try FeedInformation(feed: feed, websiteCallable: callable, supportLabel: "Support")
                            #expect(info.description == "Description")
                            #expect(info.showsStatistics == (subscription != .notSubscribed))
                            #expect(info.showsSubscribe == (subscription == .notSubscribed))
                            #expect(info.showsFunding == (funded && subscription != .notSubscribed))
                            #expect(info.showsReconnect == (subscription == .subscribed && local))
                            #expect(info.showsShare == (subscription == .subscribed && !local))
                            #expect(info.showsEditURL == info.showsShare)
                            #expect(info.showsWebsite == (subscription == .subscribed && link != nil && callable))
                            #expect(feed == original)
                        }
                    }
                }
            }
        }
    }
}
