import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Parser parity with the shared feed vectors (NotTennaPod-Server `contract/vectors/feeds`, `feed_values.json`
/// and `feed_date_symbols.json`): Android AntennaPod 3.12.1's own parser classes run on the emulator. The app's
/// feed pipeline (`FeedFetcher` with `FeedParser`, the title checks and generative cover) is mapped onto the
/// vectors' fields and compared. Differences are not fixed here: parser changes alter what people see, so
/// each known difference is listed in `TestSupport/Contract/feed-parity-differences.json` with both outputs'
/// values at its concrete path (array positions kept), and the tests fail when anything there changes: a new
/// difference, one that went away, or a different value on either side.
@Suite(.serialized) struct FeedParserParityTests {
    static let vectors = ContractVectorTests.directory
    static let differencesFile = ContractVectorTests.root.appendingPathComponent("TestSupport/Contract/feed-parity-differences.json")
    /// The corpus generation time: every date in it is a day before it or after 2100.
    static let corpusNow: Int64 = 1_791_227_192_000
    static let corpusSource = "https://feeds.example.invalid/"

    // MARK: Feed corpus

    private struct CorpusTransport: FeedHTTPTransport {
        let body: Data
        func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
            FeedHTTPResponse(url: request.url ?? URL(fileURLWithPath: "/"), status: 200, body: body)
        }
    }

    /// The app's outcome for one corpus file in the vectors' schema (the server's `GoldenFeedExportTest` rows).
    static func corpusResult(file: String, data: Data) async throws -> ContractJSON {
        let diagnostic = Mutex<String?>(nil)
        let fetcher = FeedFetcher(transport: CorpusTransport(body: data),
                                  clock: { Date(timeIntervalSince1970: Double(corpusNow) / 1000) })
        do {
            let result = try await fetcher.fetch(FeedFetchRequest(source: corpusSource + file)) { message in
                diagnostic.withLock { $0 = message }
            }
            guard case .updated(let fetched) = result else { return ["error": "not_modified", "detail": .null] }
            return feedObject(fetched.feed, document: data)
        } catch let error as FeedFetchError {
            let detail = diagnostic.withLock { $0 }
            switch error {
            case .parsing: return ["error": "parser_exception", "detail": .null]
            case .missingFeedTitle: return ["error": "parser_exception", "detail": "Feed has no title"]
            case .missingEpisodeTitle: return ["error": "parser_exception", "detail": "Item has no title"]
            case .websiteInsteadOfFeed: return ["error": "unsupported_type_html", "detail": detail.map(ContractJSON.string) ?? .null]
            case .unsupportedFeed: return ["error": "unsupported_type", "detail": detail.map(ContractJSON.string) ?? .null]
            default: return ["error": .string("fetch_error \(error)"), "detail": .null]
            }
        }
    }

    private static func text(_ value: String?) -> ContractJSON { value.map(ContractJSON.string) ?? .null }

    private static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    static func feedObject(_ feed: ParsedFeed, document: Data) -> ContractJSON {
        var alternates = ContractObject()
        var alternateWithoutURL: ContractJSON?
        for alternate in feed.alternateFeeds {
            if let url = alternate.url { alternates[url] = text(alternate.title) } else { alternateWithoutURL = text(alternate.title) }
        }
        // Android's feed type comes from its TypeGetter: RSS 0.91 and 0.92 have no type name in the export.
        var type: ContractJSON = feed.format == .atom ? "atom" : "rss"
        if feed.format == .rss, let text = try? AndroidXMLStreamDecoding.decode(document),
           let version = FeedDocumentClassifier.firstStartTag(text)?.version, version == "0.91" || version == "0.92" {
            type = .null
        }
        var object: ContractObject = [
            "type": type, "identifier": text(feed.identifier), "title": text(feed.title),
            "description": text(feed.description), "author": text(feed.author), "language": text(feed.language),
            "link": text(feed.link), "image_url": text(feed.imageURL),
            "funding": .array(feed.funding.map { ["url": text($0.url), "content": .string($0.content)] }),
            "paged": .bool(feed.isPaged), "next_page_url": text(feed.nextPageURL), "redirect_url": text(feed.redirectURL),
            "alternate_feed_urls": .object(alternates), "items": .array(feed.episodes.map(itemObject))
        ]
        if let alternateWithoutURL { object["alternate_feed_url_null"] = alternateWithoutURL }
        return .object(object)
    }

    static func itemObject(_ item: ParsedEpisode) -> ContractJSON {
        let media: ContractJSON = item.media.map { media in
            ["url": text(media.url), "size": .string(String(media.size)), "mime_type": text(media.mimeType),
             "duration": .integer(Int64(media.durationMilliseconds))]
        } ?? .null
        let chapters: ContractJSON = item.chapters.map { chapters in
            .array(chapters.map { ["start": .string(String($0.startMilliseconds)), "title": text($0.title),
                                   "link": text($0.link), "image_url": text($0.imageURL)] })
        } ?? .null
        return [
            "guid": text(item.identifier), "title": text(item.title), "description": text(item.description),
            "link": text(item.link), "pub_date": item.publicationDate.map { .integer(milliseconds($0)) } ?? .null,
            "image_url": text(item.imageURL), "payment_link": text(item.paymentLink), "media": media, "chapters": chapters,
            "chapter_url": text(item.chapterURL), "transcript_url": text(item.transcript?.url),
            "transcript_type": text(item.transcript?.format.rawValue), "social_interact_url": text(item.socialInteractionURL)
        ]
    }

    /// One difference: its concrete path (array positions kept) and both outputs there.
    struct Difference {
        let path: String
        let app: ContractJSON
        let android: ContractJSON

        /// `{"android": …, "app": …}`, as the recorded baseline holds it.
        var values: ContractJSON { ["android": android, "app": app] }
    }

    /// Where two results differ, with both values: objects by member, arrays by position when their lengths match,
    /// otherwise the whole array.
    static func differences(_ path: String, _ a: ContractJSON, _ b: ContractJSON, into output: inout [Difference]) {
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
        if a != b { output.append(Difference(path: path, app: a, android: b)) }
    }

    struct CorpusDifference {
        let file: String
        let differences: [Difference]
        let app: ContractJSON
        let android: ContractJSON
        var paths: [String] { differences.map(\.path) }
    }

    /// A path with its array positions removed, for the printed summary.
    static func pattern(_ path: String) -> String {
        path.replacingOccurrences(of: #"\[[0-9]+\]"#, with: "[]", options: .regularExpression)
    }

    static func corpusDifferences() async throws -> (rows: Int, differences: [CorpusDifference]) {
        let lines = try String(contentsOf: vectors.appendingPathComponent("feeds/expected.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        var found: [CorpusDifference] = []
        for line in lines {
            let row = try ContractJSON.decode(String(line))
            let file = try #require(row["file"]?.stringValue)
            var android = try #require(row["result"])
            var app = try await corpusResult(file: file, data: Data(contentsOf: vectors.appendingPathComponent("feeds/" + file)))
            if file.hasPrefix("hostile-") {
                // Android has no parse budgets: hostile files compare only the outcome.
                android = ["error": android["error"] ?? .null, "type": android["type"] ?? .null]
                app = ["error": app["error"] ?? .null, "type": app["type"] ?? .null]
            }
            var differing: [Difference] = []
            differences("", app, android, into: &differing)
            if !differing.isEmpty { found.append(CorpusDifference(file: file, differences: differing, app: app, android: android)) }
        }
        return (lines.count, found)
    }

    @Test func feedCorpus() async throws {
        let (rows, found) = try await Self.corpusDifferences()
        var byPath: [String: [String]] = [:]
        for difference in found {
            for path in Set(difference.paths.map(Self.pattern)) { byPath[path, default: []].append(difference.file) }
        }
        print("feed corpus: \(rows) files, \(found.count) differ")
        for (path, files) in byPath.sorted(by: { ($0.value.count, $1.key) > ($1.value.count, $0.key) }) {
            print("  \(path) \(files.count) e.g. \(files.prefix(3).joined(separator: ", "))")
        }
        if let dump = ProcessInfo.processInfo.environment["NTP_FEED_PARITY_DUMP"] {
            var out = ""
            for difference in found {
                out += "== \(difference.file) \(difference.paths)\n  app:     \((try? difference.app.canonicalString()) ?? "")\n  android: \((try? difference.android.canonicalString()) ?? "")\n"
            }
            try out.write(toFile: dump, atomically: true, encoding: .utf8)
        }
        var current = ContractObject()
        for difference in found {
            var paths = ContractObject()
            for entry in difference.differences { paths[entry.path] = entry.values }
            current[difference.file] = .object(paths)
        }
        try Self.compare(section: "corpus", current)
    }

    /// A known difference whose app value changes to another wrong value is noticed (gen-0000.xml,
    /// whose title already differs from Android's).
    @Test func aKnownDifferenceWithAnotherWrongValueIsNoticed() async throws {
        let file = "gen-0000.xml"
        let recorded = try #require(try ContractJSON.decode(Data(contentsOf: Self.differencesFile))["corpus"]?[file])
        let row = try #require(try String(contentsOf: Self.vectors.appendingPathComponent("feeds/expected.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try ContractJSON.decode(String($0)) }.first { $0["file"]?.stringValue == file })
        let android = try #require(row["result"])
        func baseline(_ app: ContractJSON) -> ContractJSON {
            var found: [Difference] = []
            Self.differences("", app, android, into: &found)
            var paths = ContractObject()
            for entry in found { paths[entry.path] = entry.values }
            return .object(paths)
        }
        var app = try #require(try await Self.corpusResult(file: file, data: Data(contentsOf: Self.vectors.appendingPathComponent("feeds/" + file))).objectValue)
        #expect(baseline(.object(app)) == recorded)
        #expect(app["title"] != android["title"])
        app["title"] = "A completely different title"
        let changed = baseline(.object(app))
        #expect(changed.objectValue?.names == recorded.objectValue?.names, "the same path differs")
        #expect(changed != recorded, "with another value")
        #expect(Self.entries(["corpus": ["gen-0000.xml": changed]]) != Self.entries(["corpus": ["gen-0000.xml": recorded]]))
    }

    // MARK: Values

    @Test func feedValues() throws {
        let file = try ContractJSON.decode(Self.replacingLoneSurrogates(Data(contentsOf: Self.vectors.appendingPathComponent("feed_values.json"))))
        let cases = try #require(file["cases"]?.arrayValue)
        let now = Date(timeIntervalSince1970: Double(Self.corpusNow) / 1000)
        let dates = FeedDateParser()
        var counts: [String: (cases: Int, failures: [String], skipped: Int)] = [:]
        var differing: [String: ContractObject] = [:]
        for (index, vector) in cases.enumerated() {
            let kind = try #require(vector["kind"]?.stringValue)
            let input = try #require(vector["input"])
            let expected = try #require(vector["output"])
            // A Swift string cannot hold a lone surrogate, so neither can the app's parser.
            if Self.containsSentinel(input) || Self.containsSentinel(expected) {
                counts[kind, default: (0, [], 0)].skipped += 1
                continue
            }
            let actual: ContractJSON
            switch kind {
            case "date_parse":
                actual = dates.parse(try #require(input.stringValue)).map { .integer(Self.milliseconds($0)) } ?? .null
            case "date_parse_or_null_if_future":
                actual = dates.parse(try #require(input.stringValue), now: now).map { .integer(Self.milliseconds($0)) } ?? .null
            case "duration_in_millis":
                actual = FeedValueParsing.duration(try #require(input.stringValue)).map { .string(String($0)) } ?? "error"
            case "parse_time_string":
                actual = FeedValueParsing.chapterTime(try #require(input.stringValue)).map { .string(String($0)) } ?? "error"
            case "html_compact", "html_legacy":
                actual = (try? FeedValueParsing.htmlText(try #require(input.stringValue), compact: kind == "html_compact"))
                    .map(ContractJSON.string) ?? "error"
            case "mime_type":
                let pair = try #require(input.arrayValue)
                actual = Self.text(FeedMIME.resolve(pair[0].stringValue, url: pair[1].stringValue))
            case "mime_type_from_extension":
                // As `FeedMIME.resolve` looks extensions up.
                actual = Self.text(AndroidMIMEMap.extensions[try #require(input.stringValue).lowercased()])
            default:
                Issue.record("unknown kind \(kind)")
                continue
            }
            counts[kind, default: (0, [], 0)].cases += 1
            if actual != expected {
                differing[kind, default: ContractObject()][String(index)] = ["android": expected, "app": actual]
                counts[kind]!.failures.append("\((try? input.canonicalString()) ?? "") → app \((try? actual.canonicalString()) ?? ""), android \((try? expected.canonicalString()) ?? "")")
            }
        }
        for (kind, count) in counts.sorted(by: { $0.key < $1.key }) {
            print("feed values: kind=\(kind) cases=\(count.cases) differ=\(count.failures.count) skipped=\(count.skipped)")
            for failure in count.failures.prefix(3) { print("    \(failure)") }
        }
        if let dump = ProcessInfo.processInfo.environment["NTP_FEED_PARITY_DUMP"] {
            let lines = counts.sorted(by: { $0.key < $1.key }).flatMap { kind, count in count.failures.map { "\(kind)\t\($0)" } }
            try lines.joined(separator: "\n").write(toFile: dump + ".values", atomically: true, encoding: .utf8)
        }
        var current = ContractObject()
        for (kind, cases) in differing { current[kind] = .object(cases) }
        try Self.compare(section: "values", current)
    }

    // MARK: Date symbols

    /// The date parser's names come from the en_US_POSIX formatter; Android's from Locale.US. Zone IDs Android
    /// knows and Foundation does not are listed as differences.
    @Test func dateSymbols() throws {
        let symbols = try ContractJSON.decode(Data(contentsOf: Self.vectors.appendingPathComponent("feed_date_symbols.json")))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        func strings(_ name: String) throws -> [String] {
            try #require(symbols[name]?.arrayValue).map { try #require($0.stringValue) }
        }
        var current = ContractObject()
        let pairs: [(String, [String], [String])] = [
            ("weekdays", Array(try strings("weekdays").dropFirst()), formatter.weekdaySymbols),
            ("short_weekdays", Array(try strings("short_weekdays").dropFirst()), formatter.shortWeekdaySymbols),
            ("months", try strings("months"), formatter.monthSymbols),
            ("short_months", try strings("short_months"), formatter.shortMonthSymbols),
            ("am_pm", try strings("am_pm"), [formatter.amSymbol, formatter.pmSymbol]),
            ("eras", try strings("eras"), formatter.eraSymbols)
        ]
        for (name, android, app) in pairs where android != app {
            current[name] = ["android": .array(android.map(ContractJSON.string)), "app": .array(app.map(ContractJSON.string))]
        }
        let zones = try #require(symbols["available_ids"]?.arrayValue).compactMap { $0.arrayValue?.first?.stringValue }
        let unknown = zones.filter { TimeZone(identifier: $0) == nil }
        if !unknown.isEmpty { current["unknown_time_zones"] = .array(unknown.map(ContractJSON.string)) }
        print("date symbols: \(pairs.count) symbol lists, \(zones.count) zone IDs, \(unknown.count) unknown to Foundation")
        try Self.compare(section: "date_symbols", current)
    }

    // MARK: Recorded differences

    /// Compares a section with the recorded differences; `NTP_FEED_PARITY_RECORD=1` records it instead.
    static func compare(section: String, _ current: ContractObject) throws {
        let file = differencesFile
        let existing = FileManager.default.fileExists(atPath: file.path) ? try ContractJSON.decode(Data(contentsOf: file)).objectValue ?? ContractObject() : ContractObject()
        if ProcessInfo.processInfo.environment["NTP_FEED_PARITY_RECORD"] == "1" {
            var updated = existing
            updated[section] = .object(current)
            try Data((try pretty(.object(updated)) + "\n").utf8).write(to: file)
            return
        }
        let recorded = existing[section]?.objectValue ?? ContractObject()
        guard recorded != current else { return }
        let now = entries(current), before = entries(recorded)
        let added = now.subtracting(before).sorted(), removed = before.subtracting(now).sorted()
        func shown(_ list: [String]) -> String { list.prefix(20).map { $0.count > 400 ? $0.prefix(400) + "…" : Substring($0) }.joined(separator: "; ") }
        Issue.record("""
            \(section): the parser's differences from Android changed (\(added.count) new or changed, \(removed.count) gone \
            or changed). Report them; after a decision, record them with NTP_FEED_PARITY_RECORD=1.
            now: \(shown(added))
            recorded: \(shown(removed))
            """)
    }

    /// Indented JSON whose every string and number is written canonically, so values read back exactly as recorded
    /// (Foundation's JSON writer loses a lone U+FEFF).
    static func pretty(_ value: ContractJSON, indent: String = "") throws -> String {
        let inner = indent + "  "
        switch value {
        case .object(let object) where !object.members.isEmpty:
            let members = object.members.sorted { $0.name.utf16.lexicographicallyPrecedes($1.name.utf16) }
            return "{\n" + (try members.map { inner + (try ContractJSON.string($0.name).canonicalString()) + ": " + (try pretty($0.value, indent: inner)) }
                .joined(separator: ",\n")) + "\n" + indent + "}"
        case .array(let elements) where !elements.isEmpty:
            return "[\n" + (try elements.map { inner + (try pretty($0, indent: inner)) }.joined(separator: ",\n")) + "\n" + indent + "]"
        default:
            return try value.canonicalString()
        }
    }

    /// Every recorded difference as one line, `name … path = {"android": …, "app": …}`: a value on either side that
    /// changes makes a different line.
    static func entries(_ object: ContractObject, prefix: String = "") -> Set<String> {
        var result = Set<String>()
        for member in object.members {
            let name = prefix.isEmpty ? member.name : prefix + " " + member.name
            if let nested = member.value.objectValue, nested["app"] == nil {
                result.formUnion(entries(nested, prefix: name))
            } else if let list = member.value.arrayValue, prefix.isEmpty {
                for element in list { result.insert(name + " " + ((try? element.canonicalString()) ?? "")) }
            } else {
                result.insert(name + " = " + ((try? member.value.canonicalString()) ?? ""))
            }
        }
        return result
    }

    /// Lone surrogate escapes (exact Java strings) become U+10FFFF, which Swift strings can hold.
    static func replacingLoneSurrogates(_ data: Data) -> Data {
        let bytes = Array(data)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        var inString = false
        func unit(at position: Int) -> UInt32? {
            guard position + 6 <= bytes.count, bytes[position] == UInt8(ascii: "\\"), bytes[position + 1] == UInt8(ascii: "u") else { return nil }
            var value: UInt32 = 0
            for offset in 2..<6 {
                guard let digit = ContractHex.digit(bytes[position + offset], uppercase: true) else { return nil }
                value = value << 4 | UInt32(digit)
            }
            return value
        }
        while index < bytes.count {
            let byte = bytes[index]
            if !inString {
                if byte == UInt8(ascii: "\"") { inString = true }
                output.append(byte)
                index += 1
                continue
            }
            if byte == UInt8(ascii: "\"") {
                inString = false
                output.append(byte)
                index += 1
            } else if byte == UInt8(ascii: "\\"), let value = unit(at: index), (0xD800...0xDFFF).contains(value) {
                if value <= 0xDBFF, let low = unit(at: index + 6), (0xDC00...0xDFFF).contains(low) {
                    output.append(contentsOf: bytes[index..<(index + 12)])
                    index += 12
                } else {
                    output.append(contentsOf: Array("\\udbff\\udfff".utf8))
                    index += 6
                }
            } else if byte == UInt8(ascii: "\\") {
                output.append(contentsOf: bytes[index..<min(bytes.count, index + 2)])
                index += 2
            } else {
                output.append(byte)
                index += 1
            }
        }
        return Data(output)
    }

    static func containsSentinel(_ value: ContractJSON) -> Bool {
        switch value {
        case .string(let text): text.unicodeScalars.contains { $0.value == 0x10FFFF }
        case .array(let elements): elements.contains(where: containsSentinel)
        case .object(let object): object.members.contains { containsSentinel($0.value) }
        default: false
        }
    }
}
