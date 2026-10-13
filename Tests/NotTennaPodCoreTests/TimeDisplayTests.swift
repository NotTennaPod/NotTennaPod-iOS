import Foundation
import Testing
@testable import NotTennaPodCore

struct TimeDisplayTests {
    private let locale = Locale(identifier: "en_US")

    @Test func playerUsesFullDurationByDefaultAndTogglesTheRightHandTime() throws {
        #expect(!TimeDisplayPreferences().showRemainingTime)
        let duration = try #require(PlayerTimePresentation(position: 3_883, duration: 30_040, showRemainingTime: false, locale: locale))
        let remaining = try #require(PlayerTimePresentation(position: 3_883, duration: 30_040, showRemainingTime: true, locale: locale))
        #expect(duration.position == "00:00:03" && duration.length == "00:00:30")
        #expect(remaining.position == duration.position && remaining.length == "-00:00:26")
        #expect(duration.lengthAccessibilityKey == "chapter_duration")
        #expect(remaining.lengthAccessibilityKey == "remaining_time")
        #expect(remaining.lengthMilliseconds == 26_157)
    }

    @Test func remainingTimeBoundariesKeepTheSourceSignAndClampRules() throws {
        let cases: [(Int32, Int32, String)] = [
            (0, 30_040, "-00:00:30"), (30_000, 30_040, "-00:00:00"),
            (30_040, 30_040, "00:00:00"), (40_000, 30_040, "00:00:00"),
            (0, 0, "00:00:00"), (10_000, 0, "00:00:00"),
            (0, .max, "-596:31:23"), (.max, .max, "00:00:00"),
            (.min, .max, "00:00:00") // Java int subtraction wraps before max(…, 0).
        ]
        for (position, duration, expected) in cases {
            let actual = try #require(PlayerTimePresentation(position: position, duration: duration, showRemainingTime: true, locale: locale))
            #expect(actual.length == expected)
        }
    }

    @Test func invalidEventsLeaveTheExistingPlayerDisplayUntouched() {
        for remaining in [false, true] {
            for value: Int32 in [-1, 0, 30_000, .max] {
                #expect(PlayerTimePresentation(position: -1, duration: value, showRemainingTime: remaining) == nil)
                #expect(PlayerTimePresentation(position: value, duration: -1, showRemainingTime: remaining) == nil)
            }
        }
    }

    @Test func rowBindingKeepsFullDurationUntilStartedRegardlessOfSavedChoice() {
        for remaining in [false, true] {
            for playing in [false, true] {
                for position: Int32 in [0, 3_883, 30_040, 40_000] {
                    var episode = LibraryEpisode(id: 1, details: ParsedEpisode(media: ParsedMedia(url: "https://example.test/a.mp3", size: 0, durationMilliseconds: 30_040)))
                    episode.userState.positionMilliseconds = position
                    for state in EpisodePlayState.allCases {
                        episode.userState.playState = state
                        let row = EpisodeRowPresentation(episode: episode, activelyPlaying: playing, showRemainingTime: remaining, locale: locale)
                        let expected: String
                        if !remaining || (!playing && position == 0) { expected = "00:00:30" }
                        else if position == 0 { expected = "-00:00:30" }
                        else if position == 3_883 { expected = "-00:00:26" }
                        else { expected = "00:00:00" }
                        #expect(row.duration == expected)
                    }
                }
            }
        }
    }

    @Test func spokenTimeMatchesAndroidHoursMinutesAndNonbreakingSpaces() {
        let cases: [(Int32, String)] = [
            (0, "0\u{00a0}minutes"), (59_999, "0\u{00a0}minutes"), (60_000, "1\u{00a0}minute"),
            (3_600_000, "1\u{00a0}hour 0\u{00a0}minutes"),
            (7_260_000, "2\u{00a0}hours 1\u{00a0}minute"),
            (.max, "596\u{00a0}hours 31\u{00a0}minutes")
        ]
        for (value, expected) in cases {
            let actual = PlayerTimePresentation.spokenDuration(value) { key, count in
                let unit = key == "time_hours_quantified" ? "hour" : "minute"
                return "\(count) \(unit)\(count == 1 ? "" : "s")"
            }
            #expect(actual == expected)
        }
    }
}

@MainActor
struct TimeDisplayPreferenceStoreTests {
    @Test func addingSpeedPreferencePreservesOlderFilesAndDurationToggleDoesNotResetIt() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"showRemainingTime":true}"#.utf8).write(to: file)
        let store = try TimeDisplayPreferenceStore(file: file)
        #expect(store.value.showRemainingTime && !store.value.timeRespectsSpeed)
        try store.update(TimeDisplayPreferences(showRemainingTime: true, timeRespectsSpeed: true))
        try store.toggleRemainingTime()
        let restored = try TimeDisplayPreferenceStore(file: file)
        #expect(!restored.value.showRemainingTime && restored.value.timeRespectsSpeed)
    }

    @Test func bothToggleDirectionsSurviveRelaunch() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var store = try TimeDisplayPreferenceStore(file: file)
        #expect(!store.value.showRemainingTime)
        for expected in [true, false, true, false] {
            try store.toggleRemainingTime()
            #expect(store.value.showRemainingTime == expected)
            store = try TimeDisplayPreferenceStore(file: file)
            #expect(store.value.showRemainingTime == expected)
        }
    }

    @Test func corruptAndUnwritablePreferencesReportErrorsWithoutLosingData() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: file)
        #expect(throws: (any Error).self) { try TimeDisplayPreferenceStore(file: file) }
        #expect(try Data(contentsOf: file) == corrupt)
        let store = try TimeDisplayPreferenceStore(file: file.appendingPathComponent("not-a-directory.json"))
        #expect(throws: (any Error).self) { try store.toggleRemainingTime() }
        #expect(!store.value.showRemainingTime)
        #expect(try Data(contentsOf: file) == corrupt)
    }
}
