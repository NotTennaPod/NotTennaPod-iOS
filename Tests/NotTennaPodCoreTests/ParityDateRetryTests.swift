import Foundation
import Testing
@testable import NotTennaPodCore

/// DateUtils' weekday retry in linear time: the date is normalized once and each retry
/// is a suffix of it. Its answers are held to the server's and to the retry as Android runs it (each retry normalized
/// again), on dates made of chains of "word, " prefixes.
struct ParityDateRetryTests {
    /// The server's answers (Fixtures/ParityWeekdayDates.jsonl, internal/feed parseDate at c363811), directly and as
    /// Android retries.
    @Test func weekdayRetriesAnswerAsTheServer() throws {
        var failures: [String] = []
        let rows = try ParityParseRegressionTests.lines("ParityWeekdayDates.jsonl")
        for line in rows {
            let row = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [Any])
            let now = try #require((row[0] as? NSNumber)?.int64Value)
            let input = try #require(row[1] as? String)
            let server = try #require(row[2] as? String)
            let linear = ParityParseRegressionTests.optional(try ParityDates.parse(input, now: now))
            let renormalizing = ParityParseRegressionTests.optional(try ParityDates.dateUtilsParseRenormalizing(input, now: now))
            if linear != server || renormalizing != server {
                failures.append("\(String(reflecting: input)) at \(now): \(linear), renormalizing \(renormalizing), server \(server)")
            }
        }
        #expect(rows.count == 4000)
        #expect(failures.isEmpty, "\(failures.count) differ:\n\(failures.prefix(20).joined(separator: "\n"))")
    }

    /// Random chains of prefixes, separators and dates: the linear retry answers as the retry that normalizes again.
    @Test func linearRetryAnswersAsTheRenormalizingRetry() throws {
        let words = ["Sat", "Mon", "a", "Sept", "Sep", "1", "12", "2021", "x_y", "\u{E9}", "e\u{301}", "\u{200C}", "\u{2163}",
                     "\u{661}\u{662}", "SAT", "CET", "CEST", "GMT", "Z", "T", "Oct", "09", "_", "\u{301}", "\u{DF}", "\u{1D7CF}", "x.5"]
        let separators = [", ", ", ", ",", ",  ", ", \t", " ,", ",\u{3000}", ", \u{85}", ", \u{2028}", " ", ",, ", ";", ", \u{A0}",
                          ", \u{1}", ", \u{200B}", ", \u{301}", ",\n", ", /", ", ."]
        let tails = ["09 Oct 2021 10:00:00 +0000", "Sat, 09 Oct 2021 10:00:00 GMT", "2021-10-09T10:00:00.12345Z", "2021/10/09",
                     "09 Sept 2021 10:00 CEST", "Thu, 09 Sep 2021 10:00:00 +02:00", "Fri 08 Oct 2021", "1.5", "+12:34", "CET",
                     "09 Oct 21 10:00:00 -0800", "2021-10-09T10:00:00+0200", "2021-10-09", "2021-10-09T10:00:00.5",
                     "Sat, 09 Oct 2021 10:00:00 +0000\u{85}", "09 Oct 2021 10:00:00 CET", "Sat Oct 9 10:00:00 2021", "", "x",
                     "09 Oct 2021 10:00:00 +00:00\n", "2021-10-09T10:00:00.1234567+01:00", "09 Sept 21 10:00:00 Z", "10.10.2021",
                     "2021-10-09T10:00:00.5Z", "Sat, 09 Oct 2021 10:00:00 +0000 CEST", "1.5ab", "a.", "+\u{1D7CF}\u{1D7D0}:\u{1D7D1}\u{1D7D2}"]
        let pads = ["", "", " ", "\t", "\n", "\u{3000}", "  ", "\u{85}"]
        let nows: [Int64] = [1_791_227_192_000, 1_633_773_600_000, 0, -1, 4_102_444_800_000]
        var rng = SplitMix64(seed: 2026_10_10)
        func pick<T>(_ a: [T]) -> T { a[Int(rng.next() % UInt64(a.count))] }
        var failures: [String] = []
        for _ in 0..<3_000 {
            var s = pick(pads)
            for _ in 0..<Int(rng.next() % 7) {
                s += pick(words)
                if rng.next() % 3 == 0 { s += pick(words) }
                s += pick(separators)
            }
            var tail = pick(tails)
            if rng.next() % 4 == 0, !tail.isEmpty {
                var units = Array(tail.utf16)
                units.insert(contentsOf: Array(pick(["/", " ", ",", ".", ":", "Sept", "1", ", ", "\u{301}", "  "]).utf16),
                             at: Int(rng.next() % UInt64(units.count)))
                tail = String(decoding: units, as: UTF16.self)
            }
            s += tail + pick(pads)
            let now = pick(nows)
            let linear = try ParityDates.parse(s, now: now)
            let renormalizing = try ParityDates.dateUtilsParseRenormalizing(s, now: now)
            if linear != renormalizing { failures.append("\(String(reflecting: s)) at \(now): \(String(describing: linear)), \(String(describing: renormalizing))") }
        }
        #expect(failures.isEmpty, "\(failures.count) differ:\n\(failures.prefix(20).joined(separator: "\n"))")
    }

    /// A date of many "word, " prefixes took quadratic time (a 64 KB pubDate took 11.7 s, as on
    /// Android);
    /// it takes linear time now, with the same answer.
    @Test func manyPrefixesAreLinear() throws {
        let plain = "Sat, 09 Oct 2021 10:00:00 +0000"
        let short = String(repeating: "a, ", count: 2_000) + plain
        let long = String(repeating: "a, ", count: 8_000) + plain
        var answers: [Int64?] = []
        let shortTime = try ParityParseRegressionTests.seconds { answers.append(try ParityDates.parse(short, now: ParityFeedParserTests.now)) }
        let longTime = try ParityParseRegressionTests.seconds { answers.append(try ParityDates.parse(long, now: ParityFeedParserTests.now)) }
        #expect(answers == [1_633_773_600_000, 1_633_773_600_000])
        // 4 times the input: linear takes about 4 times as long, quadratic about 16 times.
        #expect(longTime < 8 * shortTime + 0.5, "\(shortTime) s, then \(longTime) s")
    }
}
