import Foundation
import Testing
@testable import NotTennaPodCore

/// Go 1.27.1's strconv.ParseFloat as GoFloat ports it: the server reads a float32 and a
/// date number's float64 with it, so its answers are the parse's, bit for bit, also where Go's slow path for a literal
/// of more than 800 digits does not give the nearest value.
struct ParityGoFloatTests {
    typealias Regression = ParityParseRegressionTests

    /// Go's own answers for literals of every path (Fixtures/ParityGoFloatCases.jsonl): short and long significands,
    /// exact midpoints with trailing zeros, literals around 800 digits before the point, exponents past 10,000,
    /// subnormal, underflow and overflow edges, hexadecimal, specials, syntax errors and date-number literals.
    @Test func parseFloatAnswersAsGo() throws {
        var failures: [String] = []
        let rows = try Regression.lines("ParityGoFloatCases.jsonl")
        var widths: [Int: Int] = [:]
        for line in rows {
            let row = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [Any])
            let bitSize = try #require(row[0] as? Int)
            let literal = try #require(row[1] as? String)
                + String(repeating: try #require(row[2] as? String), count: try #require(row[3] as? Int)) + (try #require(row[4] as? String))
            let (value, error) = try GoFloat.parseFloat(Array(literal.utf8), bitSize: bitSize, work: ParityCancellation { false })
            let bits = bitSize == 32 ? String(format: "%08x", Float(value).bitPattern) : String(format: "%016llx", value.bitPattern)
            let actual = bits + "|" + (error.map { "\($0)" } ?? "")
            let expected = try #require(row[5] as? String)
            if actual != expected {
                failures.append("\(bitSize) \(String(reflecting: literal).prefix(160)) (\(literal.utf8.count) bytes): \(actual), Go \(expected)")
            }
            widths[bitSize, default: 0] += 1
        }
        #expect(rows.count >= 8_000 && widths[32, default: 0] > 2_500 && widths[64, default: 0] > 2_500)
        #expect(failures.isEmpty, "\(failures.count) differ:\n\(failures.prefix(20).joined(separator: "\n"))")
    }

    /// Conformance cases, with the server's answers, directly and in feeds.
    @Test func conformanceCases() throws {
        func zeros(_ n: Int) -> String { String(repeating: "0", count: n) }
        // An exact midpoint with 89 trailing zeros rounds to even, as with 88.
        for n in [88, 89] {
            #expect(try Regression.numberResult("float", "1.000000059604644775390625" + zeros(n), titled: false) == "3f800000", "\(n) zeros")
        }
        let midpoint = "16777217.0" + zeros(740)
        #expect(try Regression.numberResult("duration", midpoint, titled: false) == "16777216000")
        #expect(try Regression.numberResult("chapter", "0:" + midpoint, titled: true) == "16777216000")
        // 801 digits before the point: Go's decimal keeps 800 and places the point by them.
        let long = "1000000059604644775390625" + zeros(775) + "1.e-800"
        #expect(try Regression.numberResult("float", long, titled: false) == "3dccccce")
        #expect(try Regression.numberResult("duration", long, titled: false) == "100")
        #expect(try Regression.numberResult("itunes_duration", long, titled: true) == "100")
        #expect(try Regression.numberResult("chapter", "0:" + long, titled: true) == "100")
        // In a date's number (float64), and the date number's exponent read only to 10,000.
        let now: Int64 = 1_791_227_192_000
        for (date, direct, feed) in [
            ("Mon, 100000000000000011102230246251565404236316680908203125" + zeros(746) + "1E-800 Jan 2024 00:00:00 +0000",
             "1703980800000", "1703980800000"),
            ("Mon, 01 Jan 2024 00:" + String(repeating: "1", count: 100_001) + "E-100000:00 +0000", "130553086020000", "nil")
        ] {
            #expect(Regression.optional(try ParityDates.parse(date, now: now)) == direct)
            let doc = "<rss version=\"2.0\"><channel><title>review</title><item><title>x</title><pubDate>" + date
                + "</pubDate></item></channel></rss>"
            let parsed = try ParityFeedParser.parse(Data(doc.utf8), source: "https://example.org/feed", now: now, isCancelled: { false })
            #expect(Regression.optional(parsed.items.first?.pubDate) == feed)
        }
    }

    /// The literal's steps are counted: a long one stops at the parse's cancellation.
    @Test func longLiteralsStopAtCancellation() {
        let literal = Array(("1." + String(repeating: "0", count: 1 << 18) + "1e5").utf8)
        for bitSize in [32, 64] {
            #expect(throws: CancellationError.self) {
                _ = try GoFloat.parseFloat(literal, bitSize: bitSize, work: ParityCancellation { true })
            }
        }
    }
}
