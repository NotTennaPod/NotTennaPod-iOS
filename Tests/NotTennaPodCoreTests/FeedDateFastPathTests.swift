import Foundation
import Testing
@testable import NotTennaPodCore

/// The date fast path must give exactly the formatter chain's dates for every form it answers, and must
/// answer the canonical forms (otherwise it saves nothing).
struct FeedDateFastPathTests {
    private let parser = FeedDateParser()

    private func check(_ input: String, handled: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        let fast = FeedDateFastPath.parse(input)
        let chain = parser.parseWithFormatters(input)
        #expect((fast != nil) == handled, "fast path \(handled ? "missed" : "answered") \(input)", sourceLocation: sourceLocation)
        if let fast { #expect(fast == chain, "\(input): \(fast) != \(String(describing: chain))", sourceLocation: sourceLocation) }
        #expect(parser.parse(input) == chain, "\(input)", sourceLocation: sourceLocation)
    }

    @Test func realWorldFormsMatchTheFormatterChain() {
        for input in [
            "Tue, 03 Jun 2025 10:00:00 +0000", "Tue, 03 Jun 2025 10:00:00 GMT", "Tue, 3 Jun 2025 10:00:00 GMT",
            "Tue, 03 Jun 2025 10:00:00 -0700", "Tue, 03 Jun 2025 23:59:59 +1400", "Tue, 03 Jun 2025 00:00:00 -1200",
            "Tue, 03 Jun 2025 10:00:00 +0530", "Tue, 03 Jun 2025 10:00:00 +0545", "Tue, 03 Jun 2025 10:00:00 -0330",
            "Tue, 03 Jun 2025 10:00:00 UTC", "Tue, 03 Jun 2025 10:00:00 UT",
            "Tue, 03 Jun 2025 10:00:00 EST", "Tue, 03 Jun 2025 10:00:00 EDT", "Mon, 06 Jan 2025 10:00:00 EST",
            "Mon, 06 Jan 2025 10:00:00 EDT", "Tue, 03 Jun 2025 10:00:00 PST", "Tue, 03 Jun 2025 10:00:00 PDT",
            "Tue, 03 Jun 2025 10:00:00 CST", "Tue, 03 Jun 2025 10:00:00 CDT", "Tue, 03 Jun 2025 10:00:00 MST",
            "Tue, 03 Jun 2025 10:00:00 MDT",
            "Tue, 03 Jun 2025 10:00 +0000", "Tue, 03 Jun 2025 10:00 GMT", "Sat, 28 Mar 2015 01:31 EST",
            "03 Jun 2025 10:00:00 +0000", "3 Jun 2025 10:00:00 GMT", "03 Jun 2025 10:00 -0500",
            "Wed, 03 Jun 2025 10:00:00 +0000", "Sun, 29 Feb 2024 12:00:00 GMT", "Thu, 01 Jan 1970 00:00:00 GMT",
            "Fri, 31 Dec 1999 23:59:59 +0100", "Sat, 01 Jan 2000 00:00:00 -0100", "Mon, 08 Sep 2014 00:00:00 GMT",
            "2025-06-03T10:00:00Z", "2025-06-03T10:00:00+02:00", "2025-06-03T10:00:00-07:00", "2025-06-03T10:00:00+0200",
            "2025-06-03T10:00:00", "2025-06-03T10:00:00.123Z", "2025-06-03T10:00:00.1Z", "2025-06-03T10:00:00.12+05:30",
            "2025-06-03T10:00:00.123456Z", "2015-03-28T13:31:04.963870", "2017-02-22T14:28:00.002-08:00",
            "2024-05-08T22:18:52.485Z", "2024-02-29T00:00:00Z", "1999-12-31T23:59:59.999-00:30",
        ] { check(input, handled: true) }
    }

    @Test func otherFormsAreLeftToTheChain() {
        for input in [
            "Tue, 03 Jun 25 10:00:00 +0000", "Tue, 03 June 2025 10:00:00 +0000", "Tuesday, 03 Jun 2025 10:00:00 +0000",
            "Tue, 03 jun 2025 10:00:00 +0000", "tue, 03 Jun 2025 10:00:00 +0000", "Tue,  03 Jun 2025 10:00:00 +0000",
            "Tue, 03 Jun 2025 10:00:00", "Tue, 03 Jun 2025 10:00:00 CEST", "Tue, 03 Jun 2025 10:00:00 CET",
            "Tue, 03 Jun 2025 10:00:00 BST", "Tue, 03 Jun 2025 10:00:00 Z", "Tue, 03 Jun 2025 10:00:00 +00:00",
            "Tue, 31 Jun 2025 10:00:00 +0000", "Tue, 03 Jun 2025 24:00:00 +0000", "Tue, 03 Jun 2025 10:60:00 +0000",
            "Tue, 03 Jun 2025 10:00:60 +0000", "Tue, 03 Jun 2025 1:00:00 +0000", "Tue, 03 Jun 2025 10:00:00 +0000 ",
            " Tue, 03 Jun 2025 10:00:00 +0000", "Mon, 8 Sept 2014 00:00:00 GMT", "Sun 01 Mar 2015 01:00:00 GMT-0400 (EDT)",
            "Tue, 03 Jun 1850 10:00:00 +0000", "2025-06-03", "2025-06-03T10:00Z", "2025-06-03 10:00:00",
            "2025-06-03T10:00:00 +0700", "2025-06-03T10:00:00.Z", "2025-02-30T10:00:00Z", "2025-13-01T10:00:00Z",
            "2015-03-28T13:31:04.963870 +0700", "2025/06/03T10:00:00Z", "", "tomorrow",
        ] { check(input, handled: false) }
    }

    /// Thousands of generated instants in every canonical form, with correct and wrong weekday names.
    @Test func generatedCorpusMatchesTheFormatterChain() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let zones = ["+0000", "-0000", "+0100", "-0400", "-0500", "+0530", "+0930", "-1000", "+1245", "+1400",
                     "GMT", "UTC", "UT", "EST", "EDT", "CST", "CDT", "MST", "MDT", "PST", "PDT"]
        let isoZones = ["", "Z", "+00:00", "-07:00", "+05:30", "+0200", "-0330", "+14:00"]
        let calendar: Calendar = { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }()
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        var handled = 0
        for _ in 0..<1_500 {
            let instant = Date(timeIntervalSince1970: Double(631_152_000 + next(1_577_836_800)))
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: instant)
            let (year, month, day) = (parts.year!, parts.month!, parts.day!)
            let (hour, minute, second) = (parts.hour!, parts.minute!, parts.second!)
            let weekday = next(4) == 0 ? days[next(7)] : days[(parts.weekday! + 5) % 7]
            let zone = zones[next(zones.count)]
            let dayText = next(2) == 0 ? two(day) : "\(day)"
            let date = "\(dayText) \(months[month - 1]) \(year)"
            let fraction = ["", ".\(next(10))", ".\(two(next(100)))", ".\(next(1000))", ".\(next(1_000_000))"][next(5)]
            for input in [
                "\(weekday), \(date) \(two(hour)):\(two(minute)):\(two(second)) \(zone)",
                "\(weekday), \(date) \(two(hour)):\(two(minute)) \(zone)",
                "\(date) \(two(hour)):\(two(minute)):\(two(second)) \(zone)",
                "\(year)-\(two(month))-\(two(day))T\(two(hour)):\(two(minute)):\(two(second))\(fraction)\(isoZones[next(isoZones.count)])",
            ] {
                let fast = FeedDateFastPath.parse(input)
                if fast != nil { handled += 1 }
                #expect(fast != nil, "fast path missed \(input)")
                #expect(fast == parser.parseWithFormatters(input), "\(input)")
            }
        }
        #expect(handled == 6_000)
    }
}
