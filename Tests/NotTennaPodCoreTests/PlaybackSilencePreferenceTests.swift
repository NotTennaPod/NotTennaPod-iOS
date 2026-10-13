import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor struct PlaybackSilencePreferenceTests {
    @Test func allInheritanceCombinationsMatchReleaseRules() {
        var checked = 0
        for global in [false, true] {
            for customSpeed in [false, true] {
                for current in [false, true] {
                    for feed in PlaybackSilencePreference.allCases {
                        for temporary in PlaybackSilencePreference.allCases {
                            var value = PlaybackSpeedPreferences()
                            value.silence.global = global
                            value.feeds[10] = customSpeed ? 1.5 : nil
                            value.silence.feeds[10] = feed
                            value.currentEpisodeID = current ? 1 : 2
                            value.silence.temporary = temporary
                            // Independent decision table: explicit current, custom-feed explicit, global.
                            let expected: Bool
                            switch (current, temporary, customSpeed, feed) {
                            case (true, .off, _, _): expected = false
                            case (true, .aggressive, _, _): expected = true
                            case (_, _, true, .off): expected = false
                            case (_, _, true, .aggressive): expected = true
                            default: expected = global
                            }
                            #expect(value.resolvedSkipSilence(episodeID: 1, feedID: 10) == expected)
                            checked += 1
                        }
                    }
                }
            }
        }
        #expect(checked == 72)
    }

    @Test func sharedIdentityPreferencesAndDormantFeedChoiceSurviveReopen() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Silence-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = try PlaybackSpeedPreferenceStore(file: file)
        #expect(store.value.silence == PlaybackSilencePreferences())
        try store.setGlobalSkipSilence(true)
        try store.setFeed(10, speed: 1.5, skipSilence: .off)
        #expect(!store.value.resolvedSkipSilence(episodeID: 1, feedID: 10))
        try store.activate(episodeID: 1, resolvedSpeed: 1.5, resolvedSkipSilence: false)
        try store.setCurrentSkipSilence(true, alsoGlobal: false)
        try store.setGlobalSkipSilence(false)
        #expect(store.value.resolvedSkipSilence(episodeID: 1, feedID: 10))
        #expect(!store.value.resolvedSkipSilence(episodeID: 2, feedID: 10))
        try store.setFeed(10, speed: PlaybackSpeed.useGlobal, skipSilence: .aggressive)
        #expect(!store.value.resolvedSkipSilence(episodeID: 2, feedID: 10))
        try store.setFeed(10, speed: 2)
        #expect(store.value.resolvedSkipSilence(episodeID: 2, feedID: 10))
        try store.setCurrentSkipSilence(false, alsoGlobal: true)
        #expect(!store.value.silence.global && store.value.silence.temporary == .off)
        #expect(store.value.global == 1 && store.value.temporary == 1.5)
        try store.clearCurrent()
        #expect(store.value.currentEpisodeID == nil && store.value.silence.temporary == .off)
        #expect(store.value.resolvedSkipSilence(episodeID: 1, feedID: 10))
        #expect(try PlaybackSpeedPreferenceStore(file: file).value == store.value)
    }

    @Test func earlierSpeedFileLoadsWithoutLosingAnySavedChoices() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Silence-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        // JSONEncoder stores an Int64-keyed dictionary as alternating keys and values.
        let original = Data(#"{"global":1.25,"presets":[1,2],"feeds":[10,1.5],"currentEpisodeID":7,"temporary":2}"#.utf8)
        try original.write(to: file)
        let store = try PlaybackSpeedPreferenceStore(file: file)
        #expect(store.value.silence == PlaybackSilencePreferences())
        #expect(store.value.global == 1.25 && store.value.feeds[10] == 1.5 && store.value.presets == [1, 2])
        #expect(store.value.currentEpisodeID == 7 && store.value.temporary == 2)
        #expect(try Data(contentsOf: file) == original)
        try store.setCurrentSkipSilence(true, alsoGlobal: true)
        let reopened = try PlaybackSpeedPreferenceStore(file: file)
        #expect(reopened.value == store.value && reopened.value.silence.global)
    }

    @Test func failedWriteDoesNotPublishAnySilenceOrSpeedChange() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Silence-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("obstruction".utf8).write(to: file)
        let store = try PlaybackSpeedPreferenceStore(file: file.appendingPathComponent("child.json"))
        #expect(throws: (any Error).self) { try store.setCurrentSkipSilence(true, alsoGlobal: true) }
        #expect(throws: (any Error).self) { try store.setGlobalSkipSilence(true) }
        #expect(throws: (any Error).self) { try store.setFeed(10, speed: 1.5, skipSilence: .aggressive) }
        #expect(store.value == PlaybackSpeedPreferences())
        #expect(try Data(contentsOf: file) == Data("obstruction".utf8))
    }
}
