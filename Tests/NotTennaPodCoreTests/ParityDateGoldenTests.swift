import Foundation
import Testing
@testable import NotTennaPodCore

/// The date parser against its golden corpus (Fixtures/ParityDatesGolden.json, 43,705 cases): for each date and clock,
/// the instant the server's feed date parser answers, or null for no date. Every case must pass, through `parse` with
/// and without a cancellation, `parseOrNullIfFuture` and the literal retry; the cases whose input holds an unpaired
/// surrogate (no Swift string can) go through the UTF-16 entry point.
@Suite(.serialized) struct ParityDateGoldenTests {
    struct Corpus: Decodable {
        struct Header: Decodable {
            let count: Int
            let nows: [Int64]
        }

        struct Case: Decodable {
            let category: String
            let input: String?
            let units: [UInt16]?
            let now: Int64
            let expected: Int64?
        }

        let header: Header
        let cases: [Case]
    }

    /// The corpus. JSONDecoder reads now and expected as 64-bit integers, digit for digit (the contract decoder stops
    /// at ±(2^53−1), and these reach ±(2^63−1)).
    static func corpus() throws -> Corpus {
        let data = try Data(contentsOf: ParityParseRegressionTests.fixtures.appendingPathComponent("ParityDatesGolden.json"))
        return try JSONDecoder().decode(Corpus.self, from: data)
    }

    static func describe(_ c: Corpus.Case) -> String {
        let input = c.input.map { String(reflecting: $0) } ?? "units \(c.units ?? [])"
        return "[\(c.category)] \(input.prefix(200)) at \(c.now)"
    }

    @Test func goldenCorpus() throws {
        let corpus = try Self.corpus()
        #expect(corpus.cases.count == 43_705 && corpus.header.count == 43_705)
        // The clocks at the 64-bit limits came through exactly.
        #expect(corpus.header.nows.contains(.max) && corpus.header.nows.contains(.min))
        #expect(corpus.cases.contains { $0.now == .max } && corpus.cases.contains { $0.now == .min })
        #expect(corpus.cases.contains { $0.now == 9_223_372_036_854_774_807 && $0.expected == 1_719_759_600_000 })
        let never = ParityCancellation { false }
        var failures: [String] = []
        var strings = 0
        var units = 0
        for c in corpus.cases {
            let want = ParityParseRegressionTests.optional(c.expected)
            if let input = c.input {
                strings += 1
                let direct = ParityParseRegressionTests.optional(try ParityDates.parse(input, now: c.now))
                let cancellable = ParityParseRegressionTests.optional(try ParityDates.parse(input, now: c.now, cancellation: never))
                let future = try ParityDates.parseOrNullIfFuture(input, now: c.now, cancellation: never)
                let wantFuture = c.expected.flatMap { $0 <= c.now ? $0 : nil }
                if direct != want || cancellable != want || future != wantFuture {
                    failures.append("\(Self.describe(c)): \(direct), with cancellation \(cancellable), "
                                    + "or null if future \(ParityParseRegressionTests.optional(future)); expected \(want)")
                }
            } else {
                let input = try #require(c.units, "\(c.category) case without input or units")
                units += 1
                let got = ParityParseRegressionTests.optional(try ParityDates.parse(units: input, now: c.now, cancellation: never))
                if got != want { failures.append("\(Self.describe(c)): \(got); expected \(want)") }
            }
        }
        #expect(strings + units == 43_705 && units == 334)
        #expect(failures.isEmpty, "\(failures.count) of 43,705 differ:\n\(failures.prefix(30).joined(separator: "\n"))")
    }

    /// DateUtils' retry taken literally (each retry cleaned up again) gives the same answers.
    @Test func renormalizingRetryAnswersTheCorpus() throws {
        var failures: [String] = []
        for c in try Self.corpus().cases {
            guard let input = c.input else { continue }
            let got = ParityParseRegressionTests.optional(try ParityDates.dateUtilsParseRenormalizing(input, now: c.now))
            let want = ParityParseRegressionTests.optional(c.expected)
            if got != want { failures.append("\(Self.describe(c)): \(got); expected \(want)") }
        }
        #expect(failures.isEmpty, "\(failures.count) differ:\n\(failures.prefix(30).joined(separator: "\n"))")
    }
}
