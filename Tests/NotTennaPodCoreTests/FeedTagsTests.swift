import Foundation
import Testing
@testable import NotTennaPodCore

@Suite struct FeedTagsTests {
    @Test func reopenedOrderMatchesAndroidRuntimeCorpus() throws {
        struct Case: Decodable {
            let `case`: String
            let stored, displayed, edited, saved, reopened, coldReopened: [String]
        }
        let url = try #require(Bundle.module.url(forResource: "feed-tag-order", withExtension: "json", subdirectory: "Fixtures"))
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        #expect(cases.count == 260)
        for sample in cases {
            func units(_ tags: [String]) -> [[UInt16]] { tags.map { Array($0.utf16) } }
            var draft = FeedTags(tags: sample.stored)
            #expect(units(draft.displayed) == units(sample.displayed), Comment(rawValue: sample.case))
            while !draft.displayed.isEmpty { draft.remove(at: 0) }
            draft.includeRoot = false
            for name in sample.edited { _ = draft.add(name) }
            #expect(units(draft.saved) == units(sample.saved), Comment(rawValue: sample.case + " save"))
            #expect(units(draft.reopeningSaved().displayed) == units(sample.reopened), Comment(rawValue: sample.case + " warm reopen"))
            #expect(units(FeedTags(tags: draft.saved).displayed) == units(sample.coldReopened), Comment(rawValue: sample.case + " cold reopen"))
        }
    }
    @Test func draftUsesExactNamesSourceTrimAndReservedTagRules() {
        var draft = FeedTags(tags: ["#root", "News", "News", "é", "e\u{301}"])
        #expect(draft.displayed.count == 3); #expect(draft.includeRoot)
        let empty = draft.add("\u{0}\t \n"), reserved = draft.add(" #untagged ")
        #expect(!empty); #expect(!reserved)
        let duplicate = draft.add(" News "), differentCase = draft.add("news")
        #expect(!duplicate); #expect(differentCase)
        #expect({ draft.add("\u{a0} ") }()); #expect(draft.displayed.last == "\u{a0}")
        draft.remove(at: draft.displayed.firstIndex(of: "News")!); draft.includeRoot = false
        #expect(!draft.saved.contains("#root")); #expect(!draft.saved.contains("News"))
        // The original permits manually entering #root, independently of its checkbox.
        #expect({ draft.add("#root") }()); #expect(draft.saved.contains("#root"))
        #expect(draft.displayed.filter { Array($0.utf16) == Array("é".utf16) }.count == 1)
        #expect(draft.displayed.filter { Array($0.utf16) == Array("e\u{301}".utf16) }.count == 1)
    }
    @Test func additionsStayInDraftOrderUntilReopened() {
        var draft = FeedTags(tags: [])
        let science = draft.add("Science"), listening = draft.add("Listening")
        #expect(science && listening)
        #expect(draft.displayed == ["Science", "Listening"])
        #expect(draft.reopeningSaved().displayed == ["Listening", "Science"])
        #expect(FeedTags(tags: draft.saved).displayed == ["Listening", "Science"])
        #expect(draft.displayed == ["Science", "Listening"])
    }
    @Test func emptyStoredTagsRestoreRootOnlyOnFreshLoad() {
        var draft = FeedTags(tags: [])
        #expect(draft.displayed.isEmpty && draft.includeRoot)
        draft.includeRoot = false
        #expect(draft.saved.isEmpty)
        #expect(!draft.reopeningSaved().includeRoot)
        #expect(FeedTags(tags: draft.saved).includeRoot)
    }
    @Test func contextMenuOrderAndAvailabilityAcrossStatesAndLocalFeeds() {
        for state in FeedSubscriptionState.allCases {
            for local in [false, true] {
                var feed = LibraryFeed(id: 1, source: local ? "antennapod_local:fixture" : "https://example.org/feed", metadata: .init(format: .rss), episodes: [])
                feed.subscriptionState = state
                var expected: [SearchFeedMenu.Action] = state == .subscribed ? [.removeInbox, .editTags, .removeArchive] : [.editTags]
                if state == .archived { expected.append(.removeRestore) }
                if !local { expected.append(.share) }
                #expect(SearchFeedMenu.actions(for: feed) == expected)
            }
        }
    }
    @Test func persistedTagsSurviveReopenAndUnrelatedPreferenceChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TagStore-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Tagged", episodes: [.init(title: "Episode")]), source: "https://example.org/feed", responseURL: URL(string: "https://example.org/feed")!, validator: nil, permanentRedirectURL: nil))
        #expect(feed.tags.isEmpty)
        try await store.updatePreferences(feedID: feed.id) { $0.tags = ["#root", "News", "é", "e\u{301}", "News"] }
        try await store.updatePreferences(feedID: feed.id) { $0.customTitle = "Renamed"; $0.keepUpdated = false }
        try await store.close()
        let reopened = try FeedLibraryStore(url: url)
        let actual = try #require(try await reopened.feed(id: feed.id))
        #expect(actual.tags.count == 4); #expect(actual.title == "Renamed"); #expect(!actual.keepUpdated)
        #expect(actual.episodes == feed.episodes)
        #expect(FeedTags.suggestions(in: [actual]).count == 3)
        var archived = actual; archived.subscriptionState = .archived; archived.tags = ["Archived"]
        #expect(!FeedTags.suggestions(in: [actual, archived]).contains("Archived"))
        // The optional property keeps pre-tag Swift headers readable.
        let encoded = try JSONEncoder().encode(actual)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "tagValues")
        let legacy = try JSONDecoder().decode(LibraryFeed.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.tags.isEmpty)
        try await reopened.close()
    }
}
