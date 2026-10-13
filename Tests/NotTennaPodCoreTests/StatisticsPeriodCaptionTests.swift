import Foundation
import Testing
@testable import NotTennaPodCore

struct StatisticsPeriodCaptionTests {
    private func milliseconds(_ iso: String) -> Int64 { Int64(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 * 1000) }
    private func caption(now: String, from: String, to: String? = nil, oldest: String = "2025-07-01T07:00:00Z", zone: String = "America/Los_Angeles", locale: String = "en-US") -> StatisticsPeriodCaption {
        .init(preferences: .init(timeFrom: milliseconds(from), timeTo: to.map(milliseconds) ?? .max),
            oldestMilliseconds: milliseconds(oldest), formatter: .init(locale: Locale(identifier: locale), timeZone: TimeZone(identifier: zone)!, now: ISO8601DateFormatter().date(from: now)!))
    }
    @Test func todayOnFirstDayLabelsCurrentMonthWithoutChangingBounds() {
        let value = caption(now: "2026-09-01T19:00:00Z", from: "2026-09-01T07:00:00Z")
        #expect(value.from == "Sep 2026"); #expect(value.to == "Sep 2026"); #expect(value.interval == .nonempty)
    }
    @Test func exclusiveMonthBoundaryLabelsPrecedingMonthAcrossDSTAndYear() {
        let march = caption(now: "2026-04-02T19:00:00Z", from: "2026-03-01T08:00:00Z", to: "2026-04-01T07:00:00Z")
        #expect(march.from == "Mar 2026"); #expect(march.to == "Mar 2026")
        let year = caption(now: "2026-01-02T20:00:00Z", from: "2025-12-01T08:00:00Z", to: "2026-01-01T08:00:00Z")
        #expect(year.to == "Dec 2025")
    }
    @Test func finiteCurrentMonthEndCapsOnlyDisplayAndTodayDiffersAtExactMidnight() {
        let ongoing = caption(now: "2026-09-01T19:00:00Z", from: "2026-09-01T07:00:00Z", to: "2026-10-01T07:00:00Z")
        #expect(ongoing.to == "Sep 2026")
        let today = caption(now: "2026-09-01T07:00:00Z", from: "2026-09-01T07:00:00Z", oldest: "2026-09-01T07:00:00Z")
        #expect(today.interval == .empty); #expect(today.to == "Sep 2026")
        let exclusive = caption(now: "2026-09-01T07:00:00Z", from: "2026-08-01T07:00:00Z", to: "2026-09-01T07:00:00Z")
        #expect(exclusive.interval == .nonempty); #expect(exclusive.to == "Aug 2026")
    }
    @Test func userReversedRangeAndEqualBoundsAreNotNormalized() {
        let reversed = caption(now: "2026-09-23T19:00:00Z", from: "2026-09-01T07:00:00Z", to: "2026-08-01T07:00:00Z")
        #expect(reversed.interval == .reversed); #expect(reversed.from == "Sep 2026"); #expect(reversed.to == "Jul 2026")
        let equal = caption(now: "2026-09-23T19:00:00Z", from: "2026-09-01T07:00:00Z", to: "2026-09-01T07:00:00Z")
        #expect(equal.interval == .empty); #expect(equal.from == "Sep 2026"); #expect(equal.to == "Aug 2026")
    }
    @Test func demonstratedThaiPrimitiveUsesGregorianYearAndLocalMonth() {
        let value = caption(now: "2026-09-23T19:00:00Z", from: "2026-09-01T07:00:00Z", locale: "th-TH")
        #expect(value.from == "ก.ย. 2026"); #expect(value.to == "ก.ย. 2026")
    }
    @Test func midnightRecoveryKeepsRealMonthCaptionAndEmptyElapsedInterval() throws {
        let stamp = milliseconds("2026-09-01T07:00:00Z")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let options = try StatisticsPeriodOptions(oldestMilliseconds: stamp, nowMilliseconds: stamp, calendar: calendar, locale: Locale(identifier: "en-US"))
        let draft = StatisticsPeriodDraft(preferences: .init(), options: options)
        // The exact-midnight month recovery repairs selection, not elapsed listening time.
        #expect(options.from.map(\.timestamp) == [1_788_246_000_000])
        let saved = try #require(draft.confirmedPreferences())
        #expect(saved == .init(timeFrom: 1_788_246_000_000))
        let value = StatisticsPeriodCaption(preferences: saved, oldestMilliseconds: stamp,
            formatter: .init(locale: Locale(identifier: "en-US"), timeZone: calendar.timeZone,
                             now: Date(timeIntervalSince1970: Double(stamp) / 1000)))
        #expect(value.from == "Sep 2026" && value.to == "Sep 2026")
        #expect(value.interval == .empty)
    }
}
