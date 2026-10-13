import Foundation
import Testing
@testable import NotTennaPodCore

private final class SleepTimerTestBundleMarker {}
struct SleepTimerTests {
    private struct Oracle: Decodable {
        struct Event: Decodable {
            let kind: String
            let display: Int64?
            let milliseconds: Int64?
            var swift: SleepTimerEvent {
                switch kind {
                case "enabled": .enabled(.init(display: display!, milliseconds: milliseconds!))
                case "updated": .updated(.init(display: display!, milliseconds: milliseconds!))
                case "cancelled": .cancelled
                case "vibrate": .expiryVibration
                case "shakeOn": .shakeListening(true)
                case "shakeOff": .shakeListening(false)
                default: preconditionFailure("Unknown oracle event: \(kind)")
                }
            }
        }
        struct Step: Decodable {
            let scenario, mode: Int
            let action: String
            let amount, position, duration: Int64
            let vibrate, shake, active, listening: Bool
            let remaining, milliseconds: Int64
            let next: Bool?
            let events: [Event]
        }
        let referenceCommit: String
        let steps: [Step]
        let ranges: [[Int]]
    }
    private func oracle() throws -> Oracle {
#if SWIFT_PACKAGE
        let url = try #require(Bundle.module.url(forResource: "sleep-timer-oracle", withExtension: "json", subdirectory: "Fixtures"))
#else
        let url = try #require(Bundle(for: SleepTimerTestBundleMarker.self).url(forResource: "sleep-timer-oracle", withExtension: "json"))
#endif
        return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
    }

    @Test func unchangedAndroidTimerSequences() throws {
        let oracle = try oracle()
        #expect(oracle.referenceCommit == "f8c641887e4677237b01b6e942ff8fe20fc8beec")
        #expect(oracle.steps.count == 1_024)
        var timer = SleepTimer()
        var scenario = -1
        var now: Int64 = 100_000
        for row in oracle.steps {
            if row.scenario != scenario { timer = .init(); now = 100_000; scenario = row.scenario }
            var events: [SleepTimerEvent] = []
            var next: Bool?
            switch row.action {
            case "start": events = timer.start(mode: try #require(.init(rawValue: row.mode)), value: row.amount, nowMilliseconds: now)
            case "tick":
                now += row.amount
                events = timer.tick(nowMilliseconds: now, positionMilliseconds: row.position,
                    durationMilliseconds: row.duration, vibrate: row.vibrate, shakeToReset: row.shake)
            case "extend": timer.extend(by: row.amount)
            case "reset": events = timer.reset()
            case "finish": (next, events) = timer.episodeFinished()
            case "stop": events = timer.stop()
            default: Issue.record("Unknown oracle action: \(row.action)")
            }
            let context = Comment(rawValue: "scenario \(scenario), \(row.action), now \(now)")
            #expect(timer.isActive == row.active, context)
            #expect(timer.value.display == row.remaining, context)
            #expect(timer.value.milliseconds == row.milliseconds, context)
            #expect(timer.isListeningForShake == row.listening, context)
            #expect(events == row.events.map(\.swift), context)
            #expect(next == row.next, context)
        }
    }

    @Test func unchangedAndroidAutoEnableRanges() throws {
        let rows = try oracle().ranges
        #expect(rows.count == 576)
        for row in rows {
            var settings = SleepTimerPreferences()
            settings.autoFromHour = row[0]
            settings.autoToHour = row[1]
            #expect(settings.autoDurationHours == row[2])
            #expect(settings.isAutoEnabledMostOfDay == (row[2] > 12))
            for hour in 0..<24 { #expect(settings.includes(hour: hour) == (row[3] & (1 << hour) != 0)) }
        }
    }

    @Test func fadeUsesRawFinalEpisodeTimeAndRestoresOnZero() {
        for (milliseconds, volume): (Int64, Float) in [(10_001, 1), (10_000, 1), (9_999, 0.9999),
                (5_000, 0.5), (1_000, 0.1), (1, 0.1), (0, 1)] {
            #expect(SleepTimerValue(display: 1, milliseconds: milliseconds).volume == volume)
        }
        var timer = SleepTimer()
        _ = timer.start(mode: .episodes, value: 2, nowMilliseconds: 0)
        #expect(!timer.isEndingThisEpisode(remainingMilliseconds: 9_000))
        #expect(timer.episodeFinished().continuePlayback)
        #expect(timer.isEndingThisEpisode(remainingMilliseconds: 90_000))
        _ = timer.stop()
        _ = timer.start(mode: .minutes, value: 60_000, nowMilliseconds: 0)
        #expect(!timer.isEndingThisEpisode(remainingMilliseconds: 59_999))
        #expect(timer.isEndingThisEpisode(remainingMilliseconds: 60_000))
    }

    @Test func defaultsInputAndLargeValues() throws {
        let defaults = try JSONDecoder().decode(SleepTimerPreferences.self, from: Data("{}".utf8))
        #expect(defaults == SleepTimerPreferences())
        #expect(defaults.lastValue == "15" && defaults.timerValue == 900_000)
        #expect(!defaults.vibrate && defaults.shakeToReset && !defaults.autoEnable)
        #expect(defaults.autoFromHour == 22 && defaults.autoToHour == 6)
        var episodes = defaults
        episodes.mode = .episodes
        #expect(episodes.lastValue == "1" && episodes.timerValue == 1)
        for invalid in ["", "0", "00", "1.5", " 15", "9223372036854775808"] {
            #expect(SleepTimerPreferences.validInput(invalid) == nil)
        }
        #expect(SleepTimerPreferences.validInput("0015") == 15)
        #expect(SleepTimerPreferences.validInput("+15") == 15)
        #expect(SleepTimerMode.minutes.timerValue(.max) == .max)
        #expect(SleepTimerMode.minutes.timerValue(.min) == .min)
        var timer = SleepTimer()
        _ = timer.start(mode: .minutes, value: .max, nowMilliseconds: 0)
        timer.extend(by: 1_800_000)
        #expect(timer.remaining == .max) // Prevent wraparound from expiring an enormous timer.
        let unknown = try JSONDecoder().decode(SleepTimerPreferences.self, from: Data("{\"mode\":99}".utf8))
        #expect(unknown.mode == .episodes)
    }

    @MainActor @Test func preferencesPersistBothModesAndFailedWritesKeepMemory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sleep.json")
        let store = try SleepTimerPreferenceStore(file: file)
        var value = store.value
        value.lastValue = "30"
        value.mode = .episodes
        value.lastValue = "3"
        value.vibrate = true
        value.shakeToReset = false
        value.autoEnable = true
        value.autoFromHour = 5
        value.autoToHour = 18
        try store.update(value)
        let restored = try SleepTimerPreferenceStore(file: file)
        #expect(restored.value == value)
        #expect(restored.value.lastMinutes == "30" && restored.value.timerValue == 3)
        try FileManager.default.removeItem(at: directory)
        var changed = value
        changed.autoEnable = false
        #expect(throws: (any Error).self) { try store.update(changed) }
        #expect(store.value == value)
    }
}
