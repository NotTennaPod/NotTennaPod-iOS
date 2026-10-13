import Foundation
import Testing
@testable import NotTennaPodCore

@Suite struct FeedSkipDraftTests {
    @Test func editingFiltersInsertedCharactersAndPreservesSelectionCapacity() {
        #expect(FeedSkipDraft.edit("12", range: NSRange(location: 2, length: 0), replacement: "a34 56") == "12345")
        #expect(FeedSkipDraft.edit("12345", range: NSRange(location: 1, length: 3), replacement: "9876") == "19875")
        #expect(FeedSkipDraft.edit("12345", range: NSRange(location: 5, length: 0), replacement: "6") == "12345")
        #expect(FeedSkipDraft.edit("10", range: NSRange(location: 0, length: 2), replacement: "") == "")
        #expect(FeedSkipDraft.edit("0", range: NSRange(location: 3, length: 0), replacement: "1") == nil)
    }
    @Test func confirmationParsesIndependentlyAndOldHeadersDefaultToZero() throws {
        var draft = FeedSkipDraft(.init(introSeconds: 99999, endingSeconds: 12))
        #expect(draft.intro == "99999" && draft.ending == "12")
        draft.intro = ""; #expect(draft.confirmed == .init(introSeconds: 0, endingSeconds: 12))
        draft.intro = "1234567890123"; draft.ending = "abc"
        #expect(draft.confirmed == .init())
        let old = LibraryFeed(id: 1, source: "fixture", metadata: .init(format: .rss), episodes: [])
        var data = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        data.removeValue(forKey: "skipPreferencesValue")
        #expect(try JSONDecoder().decode(LibraryFeed.self, from: JSONSerialization.data(withJSONObject: data)).skipPreferences == .init())
    }
}
