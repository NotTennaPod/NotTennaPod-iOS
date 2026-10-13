import Foundation
import Testing
@testable import NotTennaPodCore

struct AutomaticDownloadFilterDraftTests {
    @Test func editsArePrivateAndConfirmSerializesOnlyAddedTerms() {
        let original = AutomaticDownloadFilter(include: "\"Two words\" One", minimumDurationSeconds: 125)
        var draft = AutomaticDownloadFilterDraft(original)
        #expect(!draft.exclude && draft.terms == ["Two words", "One"])
        #expect(draft.durationEnabled && draft.minutes == "2")
        let additions = [draft.add("  \"\" \t"), draft.add("\"One\""), draft.add("  \"Third\" term  ")]
        #expect(additions == [false, false, true])
        draft.remove(at: 1); draft.exclude = true
        #expect(draft.confirmed == .init(exclude: "\"Two words\" \"Third term\" ", minimumDurationSeconds: 120))
        #expect(original.include == "\"Two words\" One" && original.minimumDurationSeconds == 125)
    }
    @Test func excludeOnlyRestoresItsListAndMixedLegacyValuesPreferInclude() {
        #expect(AutomaticDownloadFilterDraft(.init(exclude: "exclude")).exclude)
        let mixed = AutomaticDownloadFilterDraft(.init(include: "include", exclude: "exclude"))
        #expect(!mixed.exclude && mixed.terms == ["include"])
        #expect(mixed.confirmed == .init(include: "\"include\" "))
    }
    @Test func durationToggleAndInvalidNumberUseSourceConfirmationRules() {
        var draft = AutomaticDownloadFilterDraft(.init())
        #expect(!draft.durationEnabled && draft.minutes.isEmpty)
        draft.minutes = "15"
        #expect(draft.confirmed.minimumDurationSeconds == -1)
        draft.durationEnabled = true
        #expect(draft.confirmed.minimumDurationSeconds == 900)
        draft.minutes = ""
        #expect(draft.confirmed.minimumDurationSeconds == -1)
        draft.minutes = "invalid"
        #expect(draft.confirmed.minimumDurationSeconds == -1)
        draft.minutes = "-1"
        #expect(draft.confirmed.minimumDurationSeconds == -60)
        draft.minutes = "0"
        #expect(draft.confirmed.minimumDurationSeconds == 0)
    }
    @Test func duplicateComparisonIsCaseSensitiveAndUsesExactStoredText() {
        var draft = AutomaticDownloadFilterDraft(.init())
        let additions = [draft.add("News"), draft.add("news"), draft.add("é"), draft.add("e\u{301}"), draft.add("News")]
        #expect(additions == [true, true, true, true, false])
        #expect(draft.terms.count == 4)
    }
    @Test func durationFieldAcceptsSignedNumbersAndFiltersOtherCharacters() {
        #expect(AutomaticDownloadFilterDraft.editMinutes("", range: NSRange(location: 0, length: 0), replacement: "-1a2.3") == "-123")
        #expect(AutomaticDownloadFilterDraft.editMinutes("12", range: NSRange(location: 2, length: 0), replacement: "-4") == "124")
        #expect(AutomaticDownloadFilterDraft.editMinutes("-12", range: NSRange(location: 0, length: 0), replacement: "3") == "-12")
        #expect(AutomaticDownloadFilterDraft.editMinutes("-12", range: NSRange(location: 0, length: 1), replacement: "+") == "+12")
    }
    @Test func positiveDurationMustNotWrapNegativeAndDisableTheFilter() {
        var draft = AutomaticDownloadFilterDraft(.init())
        draft.durationEnabled = true; draft.minutes = "35791395"
        #expect(draft.confirmed.minimumDurationSeconds == 2_147_483_700)
        let episode = LibraryEpisode(id: 1, details: .init(title: "Short episode", media: .init(url: "https://example.org/audio.mp3", size: 1, durationMilliseconds: 30_000)))
        #expect(!draft.confirmed.includes(episode))
        #expect(AutomaticDownloadFilterDraft(draft.confirmed).minutes == "35791395")
    }
}
