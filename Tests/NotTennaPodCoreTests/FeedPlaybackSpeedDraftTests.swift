import Foundation
import Testing
@testable import NotTennaPodCore

@Suite struct FeedPlaybackSpeedDraftTests {
    @Test(arguments: [PlaybackSpeed.useGlobal, 0.49, 1, 1.234, 1.25, 4, 8], PlaybackSilencePreference.allCases)
    func initializationMatchesSourceSliderAndDisabledState(speed: Float, silence: PlaybackSilencePreference) {
        let draft = FeedPlaybackSpeedDraft(speed: speed, skipSilence: silence)
        let expected: [Float: Int] = [-1: 10, 0.49: 0, 1: 10, 1.234: 15, 1.25: 15, 4: 70, 8: 70]
        #expect(draft.progress == expected[speed])
        #expect(draft.usesGlobal == (speed == -1))
        #expect(draft.skipsSilence == (speed != -1 && silence == .aggressive))
        #expect(draft.label() == nil)
    }
    @Test func togglingGlobalRetainsDraftAndDisabledControlsDoNotChangeIt() {
        var draft = FeedPlaybackSpeedDraft(speed: -1, skipSilence: .aggressive)
        draft.step(1)
        #expect(draft.progress == 10 && !draft.hasChangedSpeed)
        draft.usesGlobal = false; draft.step(1); draft.skipsSilence = true
        #expect(draft.sliderSpeed == 1.05 && draft.label(locale: Locale(identifier: "en_US")) == "1.05x")
        draft.usesGlobal = true; draft.move(to: 70)
        #expect(draft.savedSpeed == -1 && draft.savedSilence == .global)
        draft.usesGlobal = false
        #expect(draft.savedSpeed == 1.05 && draft.savedSilence == .aggressive)
        draft.move(to: 0); draft.step(-1); #expect(draft.savedSpeed == 0.5)
        draft.move(to: 70); draft.step(1); #expect(draft.savedSpeed == 4)
    }
    @MainActor @Test func confirmedPairPersistsWithoutChangingCurrentGlobalOrOtherFeeds() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("FeedSpeed-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = try PlaybackSpeedPreferenceStore(file: file)
        try store.setGlobal(1.5); try store.setFeed(20, speed: 2, skipSilence: .off)
        try store.activate(episodeID: 7, resolvedSpeed: 0.75, resolvedSkipSilence: false)
        let before = store.value
        var draft = FeedPlaybackSpeedDraft(speed: -1, skipSilence: .global)
        draft.usesGlobal = false; draft.move(to: 25); draft.skipsSilence = true
        #expect(store.value == before) // The open draft and Cancel have no writes.
        try store.setFeed(10, speed: draft.savedSpeed, skipSilence: draft.savedSilence)
        let reopened = try PlaybackSpeedPreferenceStore(file: file)
        #expect(reopened.value.feeds[10] == 1.75 && reopened.value.silence.feeds[10] == .aggressive)
        #expect(reopened.value.global == before.global && reopened.value.presets == before.presets)
        #expect(reopened.value.currentEpisodeID == 7 && reopened.value.temporary == 0.75)
        #expect(reopened.value.feeds[20] == 2 && reopened.value.silence.temporary == .off)
        #expect(reopened.value.resolved(episodeID: 7, feedID: 10) == 0.75)
        #expect(reopened.value.resolved(episodeID: 8, feedID: 10) == 1.75)
        #expect(reopened.value.resolvedSkipSilence(episodeID: 8, feedID: 10))
        draft.usesGlobal = true
        try reopened.setFeed(10, speed: draft.savedSpeed, skipSilence: draft.savedSilence)
        #expect(reopened.value.feeds[10] == nil && reopened.value.silence.feeds[10] == nil)
        #expect(reopened.value.resolved(episodeID: 8, feedID: 10) == 1.5)
        #expect(!reopened.value.resolvedSkipSilence(episodeID: 8, feedID: 10))
    }
}
