import Foundation
import Testing
@testable import NotTennaPodCore

struct FeedValueParsingTests {
    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int,
                     milliseconds: Int = 0) -> Date {
        let components = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(secondsFromGMT: 0),
                                        year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        return components.date!.addingTimeInterval(Double(milliseconds) / 1_000)
    }

    @Test func allUpstreamDateRegressionExpectations() throws {
        let parser = FeedDateParser()
        let cases: [(String, Date)] = [
            ("2015-03-28T13:31:04.963870", utc(2015, 3, 28, 13, 31, 4, milliseconds: 963)),
            ("2015-03-28T13:31:04.96", utc(2015, 3, 28, 13, 31, 4, milliseconds: 960)),
            ("2024-05-08T22:18:52.485Z", utc(2024, 5, 8, 22, 18, 52, milliseconds: 485)),
            ("2015-03-28T13:31:04.9", utc(2015, 3, 28, 13, 31, 4, milliseconds: 900)),
            ("2015-03-28T13:31:04.963870 +0700", utc(2015, 3, 28, 6, 31, 4, milliseconds: 963)),
            ("2015-03-28T13:31:04.96 +0700", utc(2015, 3, 28, 6, 31, 4, milliseconds: 960)),
            ("2015-03-28T13:31:04.9 +0700", utc(2015, 3, 28, 6, 31, 4, milliseconds: 900)),
            ("Sat, 28 Mar 2015 01:31:04 EST", utc(2015, 3, 28, 6, 31, 4)),
            ("Sat, 28 Mar 2015 01:31 EST", utc(2015, 3, 28, 6, 31, 0)),
            ("Sat, 28 March 2015 08:16:12 -0400", utc(2015, 3, 28, 12, 16, 12)),
            ("Wed, 25 May 2011 12:33:00", utc(2011, 5, 25, 12, 33, 0)),
            ("Tue,  23 Mar   2010 01:06:26 -0500", utc(2010, 3, 23, 6, 6, 26)),
            ("2017-02-22T14:28:00.002-08:00", utc(2017, 2, 22, 22, 28, 0, milliseconds: 2)),
            ("Sun, 29 Jan 2017 00:00:00 CEST", utc(2017, 1, 28, 22, 0, 0)),
            ("Sun, 29 Jan 2017 00:00:00 CET", utc(2017, 1, 28, 23, 0, 0)),
            ("Thu, 8 Oct 2014 09:00:00 GMT", utc(2014, 10, 8, 9, 0, 0)),
            ("Mon, 8 Sept 2014 00:00:00 GMT", utc(2014, 9, 8, 0, 0, 0)),
            ("Sun 01 Mar 2015 01:00:00 GMT-0400 (EDT)", utc(2015, 3, 1, 5, 0, 0))
        ]
        for (input, expected) in cases {
            let parsed = parser.parse(input)
            #expect(parsed != nil, "\(input)")
            guard let actual = parsed else { continue }
            #expect(abs(actual.timeIntervalSince(expected)) < 0.000_001, "\(input): \(actual) != \(expected)")
        }
    }

    @Test func datesRejectGarbageAndFutureButIncludeNow() {
        let parser = FeedDateParser()
        for input in ["", "tomorrow", "2025-02-30", "2020-01-01junk"] {
            #expect(parser.parse(input) == nil, "\(input)")
        }
        let now = utc(2020, 1, 1, 0, 0, 0)
        #expect(parser.parse("2020-01-01T00:00:00Z", now: now) == now)
        #expect(parser.parse("2020-01-01T00:00:00.001Z", now: now) == nil)
    }

    @Test func allUpstreamDurationRegressionExpectations() {
        for (input, expected) in [("00:45", 45_000), ("7200", 7_200_000), ("05:10", 310_000),
                                  ("02:15:45", 8_145_000), ("00:00:00.123", 123)] {
            #expect(FeedValueParsing.duration(input) == Int64(expected))
        }
    }

    @Test func durationMatchesUnmodifiedJavaImplementation() throws {
        struct Case: Decodable {
            var input: String
            var milliseconds: Int64?
        }
        let url = try #require(Bundle.module.url(forResource: "duration-java", withExtension: "json", subdirectory: "Fixtures"))
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        #expect(cases.count >= 1_000)
        for fixture in cases {
            #expect(FeedValueParsing.duration(fixture.input) == fixture.milliseconds, "\(fixture.input)")
        }
    }

    @Test func chapterTimeKeepsItsDistinctSingleValueAndFloatRules() {
        for (input, expected) in [("12", Int64(0)), ("bad", 0), ("00:01.123", 1123),
                                  ("01:02:03", 3_723_000), ("1:2:3:4", 62_000)] {
            #expect(FeedValueParsing.chapterTime(input) == expected)
        }
        #expect(FeedValueParsing.chapterTime("bad:time") == nil)
    }

    @Test func upstreamAtomHTMLEntityRegressions() throws {
        for (input, expected) in [("&gt;", ">"), (">", ">"), ("&lt;Fran&ccedil;ais&gt;", "<Français>"),
                                  ("ßÄÖÜ", "ßÄÖÜ"), ("&quot;", "\""), ("&szlig;", "ß"),
                                  ("&#8217;", "’"), ("&#x2030;", "‰"), ("&euro;", "€")] {
            #expect(try FeedValueParsing.htmlText(input, compact: false) == expected)
        }
    }
}
