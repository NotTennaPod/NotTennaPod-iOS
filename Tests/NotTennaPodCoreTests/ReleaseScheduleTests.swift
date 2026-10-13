import Foundation
import Testing
@testable import NotTennaPodCore

struct ReleaseScheduleTests {
    @Test func matchesUnchangedJavaAcrossOriginalHistoriesAndFiveTimeZones() throws {
        struct Expected: Decodable { let schedule: ReleaseScheduleGuess.Schedule, days: [Int]?, next: Int64?, multiple: Bool }
        struct Case: Decodable { let label: String, zone: String, dates: [Int64], expected: Expected }
        struct Fixture: Decodable { let cases: [Case] }
        let url = try #require(Bundle.module.url(forResource: "release-schedule-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.cases.count == 2100)
        for item in fixture.cases {
            let input = item.dates.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            let result = try ReleaseSchedule.guess(input, timeZone: #require(TimeZone(identifier: item.zone)))
            let next = result.nextExpectedDate.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
            #expect(result.schedule == item.expected.schedule && result.days == item.expected.days
                    && next == item.expected.next && result.multipleReleasesPerDay == item.expected.multiple,
                    "\(item.label) in \(item.zone): got \(result), expected \(item.expected)")
        }
    }

    @Test func emptySingleAndInvalidDatesHaveExplicitResults() throws {
        let empty = try ReleaseSchedule.guess([], timeZone: .gmt)
        #expect(empty.schedule == .unknown && empty.days == nil && empty.nextExpectedDate == nil && !empty.multipleReleasesPerDay)
        let dates = [Date(timeIntervalSince1970: 1_700_000_000)]
        #expect(try ReleaseSchedule.guess(dates, timeZone: .gmt) == empty)
        #expect(throws: ReleaseSchedule.PredictionError.invalidDate) {
            try ReleaseSchedule.guess([Date(timeIntervalSince1970: .nan)], timeZone: .gmt)
        }
    }

    @Test func displayUsesLocalAndDisabledOverridesAndExactSevenDayBoundary() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let unknown = "statistics_expected_next_episode_unknown"
        for local in [false, true] {
            for enabled in [false, true] {
                for multiple in [false, true] {
                    for delta in [-604800.001, -604800, -604799.999, -0.001, 0, 0.001] {
                        let expected = now.addingTimeInterval(delta)
                        let guess = ReleaseScheduleGuess(schedule: .daily, days: [2,3,4,5,6,7,1],
                            nextExpectedDate: expected, multipleReleasesPerDay: multiple)
                        let display = ReleaseScheduleDisplay(guess: guess, local: local, keepUpdated: enabled, now: now)
                        if local {
                            #expect(display.next == .textKey("local_folder") && display.scheduleKeys == ["local_folder"])
                        } else if !enabled {
                            #expect(display.next == .textKey("updates_disabled_label") && display.scheduleKeys == ["updates_disabled_label"])
                        } else if delta <= -604800 {
                            #expect(display.next == .textKey(unknown) && display.scheduleKeys == [unknown])
                        } else {
                            #expect(display.next == (delta > 0 ? .date(expected) : .textKey(multiple
                                ? "statistics_expected_next_episode_any_time" : "statistics_expected_next_episode_any_day")))
                            #expect(display.scheduleKeys == (multiple ? ["release_schedule_multiple_per_day", "release_schedule_daily"] : ["release_schedule_daily"]))
                        }
                    }
                }
            }
        }
        #expect(ReleaseScheduleDisplay(guess: nil, local: false, keepUpdated: true, now: now).next == .textKey(unknown))
    }

    @Test func displayRetainsWeekdayOrderMonthlyNamingAndUnknownDateDistinction() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let variants: [(ReleaseScheduleGuess.Schedule, [Int]?, [String])] = [
            (.daily, nil, ["daily"]), (.weekdays, nil, ["weekdays"]),
            (.weekly, [1], ["weekly", "sunday"]), (.biweekly, [2], ["biweekly", "monday"]),
            (.fourweekly, [7], ["monthly", "saturday"]), (.monthly, nil, ["monthly"]),
            (.specificDays, [6,3,5,4], ["friday", "tuesday", "thursday", "wednesday"])]
        for (schedule, days, keys) in variants {
            let guess = ReleaseScheduleGuess(schedule: schedule, days: days, nextExpectedDate: now, multipleReleasesPerDay: true)
            let display = ReleaseScheduleDisplay(guess: guess, local: false, keepUpdated: true, now: now)
            #expect(display.scheduleText(text: { $0 }) == (["release_schedule_multiple_per_day"] + keys.map { "release_schedule_" + $0 }).joined(separator: ", "))
        }
        let future = now.addingTimeInterval(3600)
        let guess = ReleaseScheduleGuess(schedule: .unknown, days: nil, nextExpectedDate: future, multipleReleasesPerDay: true)
        let display = ReleaseScheduleDisplay(guess: guess, local: false, keepUpdated: true, now: now)
        #expect(display.next == .date(future))
        #expect(display.scheduleKeys == ["statistics_expected_next_episode_unknown"])
    }
}
