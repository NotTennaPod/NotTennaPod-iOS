import Foundation
import Testing
@testable import NotTennaPodCore

/// The parity parse against the shared feed vectors (NotTennaPod-Server `contract/vectors/feeds`, `feed_values.json`
/// and `feed_date_symbols.json`): Android AntennaPod 3.12.1's own parser classes on the emulator, which the server's
/// parse passes too. Every applicable vector must pass. Strings in the vectors are exact UTF-16; as in the server's
/// tests, an unpaired surrogate reads as U+FFFD (Swift strings, like Go's, hold none), and the parse's own output
/// has U+FFFD there as well.
@Suite(.serialized) struct ParityFeedVectorTests {
    static let vectors = ContractVectorTests.directory
    /// The corpus generation time: every date in it is a day before it or after 2100.
    static let corpusNow: Int64 = 1_791_227_192_000
    static let corpusSource = "https://feeds.example.invalid/"

    /// A vector file's JSON with each unpaired surrogate escape read as U+FFFD, as Go's encoding/json reads it.
    static func decode(_ data: Data) throws -> ContractJSON {
        let bytes = Array(data)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        func unit(_ i: Int) -> UInt32? {
            guard i + 6 <= bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") else { return nil }
            return UInt32(String(decoding: bytes[(i + 2)..<(i + 6)], as: UTF8.self), radix: 16)
        }
        var i = 0
        var inString = false
        while i < bytes.count {
            let b = bytes[i]
            if !inString {
                if b == UInt8(ascii: "\"") { inString = true }
                out.append(b)
                i += 1
            } else if b == UInt8(ascii: "\"") {
                inString = false
                out.append(b)
                i += 1
            } else if b == UInt8(ascii: "\\"), let value = unit(i), (0xD800...0xDFFF).contains(value) {
                if value <= 0xDBFF, let low = unit(i + 6), (0xDC00...0xDFFF).contains(low) {
                    out.append(contentsOf: bytes[i..<(i + 12)])
                    i += 12
                } else {
                    out.append(contentsOf: Array("\\ufffd".utf8))
                    i += 6
                }
            } else if b == UInt8(ascii: "\\") {
                out.append(contentsOf: bytes[i..<min(bytes.count, i + 2)])
                i += 2
            } else {
                out.append(b)
                i += 1
            }
        }
        return try ContractJSON.decode(out)
    }

    /// The parse's outcome for one corpus file in the vectors' schema.
    static func corpusResult(file: String) throws -> ContractJSON {
        let data = try Data(contentsOf: vectors.appendingPathComponent("feeds/" + file))
        do {
            return try ParityFeedParser.parse(data, source: corpusSource + file, now: corpusNow).vectorObject
        } catch let error as ParityParseError {
            return ["error": .string(error.label), "detail": error.detail.map(ContractJSON.string) ?? .null]
        }
    }

    /// The paths where two results differ (array positions kept).
    static func differences(_ path: String, _ a: ContractJSON, _ b: ContractJSON, into output: inout [String]) {
        if case .object(let left) = a, case .object(let right) = b {
            for name in Set(left.names + right.names).sorted() {
                differences(path + "." + name, left[name] ?? .null, right[name] ?? .null, into: &output)
            }
            return
        }
        if case .array(let left) = a, case .array(let right) = b, left.count == right.count {
            for (index, pair) in zip(left, right).enumerated() { differences(path + "[\(index)]", pair.0, pair.1, into: &output) }
            return
        }
        if a != b { output.append(path) }
    }

    // MARK: Feed corpus

    /// Every corpus file parses to Android's result; hostile files compare only the outcome, the feed type or the
    /// error label (Android has no budgets).
    @Test func feedCorpus() throws {
        let lines = try String(contentsOf: Self.vectors.appendingPathComponent("feeds/expected.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 2115)
        var failed: [String] = []
        for line in lines {
            let row = try Self.decode(Data(line.utf8))
            let file = try #require(row["file"]?.stringValue)
            var expected = try #require(row["result"])
            var actual = try Self.corpusResult(file: file)
            if file.hasPrefix("hostile-") {
                expected = ["error": expected["error"] ?? .null, "type": expected["type"] ?? .null]
                actual = ["error": actual["error"] ?? .null, "type": actual["type"] ?? .null]
            }
            var paths: [String] = []
            Self.differences("", actual, expected, into: &paths)
            if !paths.isEmpty {
                failed.append("\(file) differs at \(paths.prefix(5))\n  parity:  \(((try? actual.canonicalString()) ?? "").prefix(700))\n  android: \(((try? expected.canonicalString()) ?? "").prefix(700))")
            }
        }
        print("parity feed corpus: \(lines.count) files, \(failed.count) differ")
        #expect(failed.isEmpty, "\(failed.count) of \(lines.count) corpus files differ:\n\(failed.prefix(8).joined(separator: "\n"))")
    }

    // MARK: Values

    @Test func feedValues() throws {
        let file = try Self.decode(Data(contentsOf: Self.vectors.appendingPathComponent("feed_values.json")))
        let cases = try #require(file["cases"]?.arrayValue)
        #expect(cases.count == 42624)
        var counts: [String: Int] = [:]
        var failures: [String: [String]] = [:]
        for vector in cases {
            let kind = try #require(vector["kind"]?.stringValue)
            let input = try #require(vector["input"])
            let expected = try #require(vector["output"])
            let actual: ContractJSON
            switch kind {
            case "date_parse":
                actual = try ParityDates.parse(try #require(input.stringValue), now: Self.corpusNow).map(ContractJSON.integer) ?? .null
            case "date_parse_or_null_if_future":
                actual = try ParityDates.parseOrNullIfFuture(try #require(input.stringValue), now: Self.corpusNow)
                    .map(ContractJSON.integer) ?? .null
            case "duration_in_millis":
                actual = try ParityValues.durationMillis(try #require(input.stringValue), work: ParityCancellation { false }).map { .string(String($0)) } ?? "error"
            case "parse_time_string":
                actual = try ParityValues.parseTimeString(try #require(input.stringValue), work: ParityCancellation { false }).map { .string(String($0)) } ?? "error"
            case "html_compact", "html_legacy":
                let cancellation = ParityCancellation { false }
                actual = .string(try ParityHTMLText.text(try #require(input.stringValue), compact: kind == "html_compact",
                                                         cancellation: cancellation))
            case "mime_type":
                let pair = try #require(input.arrayValue)
                actual = try ParityValues.mimeType(pair[0].stringValue, pair[1].stringValue, work: ParityCancellation { false }).map(ContractJSON.string) ?? .null
            case "mime_type_from_extension":
                actual = ParityValues.mimeTypeFromExtension(Array(try #require(input.stringValue).utf8)).map(ContractJSON.string) ?? .null
            default:
                Issue.record("unknown kind \(kind)")
                continue
            }
            counts[kind, default: 0] += 1
            if actual != expected {
                failures[kind, default: []].append("\((try? input.canonicalString()) ?? "") → parity \((try? actual.canonicalString()) ?? ""), android \((try? expected.canonicalString()) ?? "")")
            }
        }
        for (kind, count) in counts.sorted(by: { $0.key < $1.key }) {
            print("parity feed values: kind=\(kind) cases=\(count) differ=\(failures[kind]?.count ?? 0)")
        }
        #expect(counts.count == 8)
        for (kind, list) in failures.sorted(by: { $0.key < $1.key }) {
            Issue.record("\(kind): \(list.count) of \(counts[kind] ?? 0) cases differ:\n\(list.prefix(10).joined(separator: "\n"))")
        }
    }

    // MARK: Date symbols

    /// The date parser's symbols, zone names and zone rules are Android 16's (feed_date_symbols.json): Locale.US
    /// names, every zone the names resolve to among the emulator's zone IDs with its raw offset, and every zone name
    /// the emulator lists (other than GMT offset fallbacks) known to the matcher.
    @Test func dateSymbols() throws {
        let symbols = try ContractJSON.decode(Data(contentsOf: Self.vectors.appendingPathComponent("feed_date_symbols.json")))
        func strings(_ name: String) throws -> [String] { try #require(symbols[name]?.arrayValue).map { try #require($0.stringValue) } }
        #expect(try strings("weekdays") == ParityDateTables.weekdays)
        #expect(try strings("short_weekdays") == ParityDateTables.shortWeekdays)
        #expect(try strings("months").prefix(12).elementsEqual(ParityDateTables.months))
        #expect(try strings("short_months").prefix(12).elementsEqual(ParityDateTables.shortMonths))
        var rawOffsets: [String: Int64] = [:]
        for entry in try #require(symbols["available_ids"]?.arrayValue) {
            let pair = try #require(entry.arrayValue)
            rawOffsets[try #require(pair[0].stringValue)] = try #require(pair[1].integerValue)
        }
        #expect(ParityDates.Zone.byID.count > 100)
        for (id, zone) in ParityDates.Zone.byID {
            #expect(rawOffsets[id] == Int64(zone.raw), "\(id): raw offset \(zone.raw), emulator \(rawOffsets[id] ?? -1)")
        }
        let known = Set(ParityDateTables.zoneNames.map(\.0))
        var checked = 0
        for row in try #require(symbols["zone_strings"]?.arrayValue) {
            for name in try #require(row.arrayValue).dropFirst().compactMap(\.stringValue)
            where !name.hasPrefix("GMT+") && !name.hasPrefix("GMT-") {
                #expect(known.contains(name), "zone name \(name)")
                checked += 1
            }
        }
        #expect(checked > 1000)
    }
}
