import Foundation
import Testing
@testable import NotTennaPodCore

/// Parity parse regressions: each case fails without its fix. Expected values are the pinned
/// server's answers, never derived from this port's constants.
struct ParityParseRegressionTests {
    static let fixtures = ContractVectorTests.root.appendingPathComponent("Tests/NotTennaPodCoreTests/Fixtures")

    /// The fixture's lines, without its comments.
    static func lines(_ name: String) throws -> [String] {
        try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8).split(separator: "\n")
            .filter { !$0.hasPrefix("#") }.map(String.init)
    }

    static func optional(_ value: Int64?) -> String { value.map(String.init) ?? "nil" }

    /// Text in XML character data, as the Go wrappers escape it.
    static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The seconds body takes.
    static func seconds(_ body: () throws -> Void) rethrows -> Double {
        let clock = ContinuousClock()
        let start = clock.now
        try body()
        let elapsed = start.duration(to: clock.now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    // MARK: A — dates at the edges of the calendar and the clock

    /// Date rows: DateUtils.parse, and the pub_date of a titled item with that pubDate, at each
    /// row's now. Years past Java's long (292278994-08-17T07:12:55.808 and later on that day) and now near
    /// Long.MIN_VALUE stopped the process on arithmetic overflow; Go wraps there and answers.
    @Test func datesAnswerAsTheServerAtTheirEdges() throws {
        var failures: [String] = []
        var count = 0
        for line in try Self.lines("ParityDateCases.jsonl") {
            let row = try JSONDecoder().decode([String].self, from: Data(line.utf8))
            let now = try #require(Int64(row[0]))
            let date = Self.optional(try ParityDates.parse(row[3], now: now))
            let doc = "<rss version=\"2.0\"><channel><title>review</title><item><title>x</title><pubDate>" + Self.escaped(row[3])
                + "</pubDate></item></channel></rss>"
            let feed: String
            do {
                let parsed = try ParityFeedParser.parse(Data(doc.utf8), source: "https://example.org/feed", now: now, isCancelled: { false })
                feed = parsed.items.first.map { Self.optional($0.pubDate) } ?? "no item"
            } catch let error as ParityParseError {
                feed = "error:" + error.label
            }
            if date != row[1] || feed != row[2] {
                failures.append("\(String(reflecting: row[3])) now \(now): \(date) / \(feed), server \(row[1]) / \(row[2])")
            }
            count += 1
        }
        #expect(count == 10_367)
        #expect(failures.isEmpty, "\(failures.count) differ:\n\(failures.prefix(20).joined(separator: "\n"))")
    }

    // MARK: Linear tokens

    /// The decoder's time for one document.
    static func tokenize(_ doc: String) -> (seconds: Double, tokens: Int, failure: GoXMLDecoder.Failure?) {
        var decoder = GoXMLDecoder(Array(doc.utf8))
        var tokens = 0
        let time = seconds { while decoder.rawToken() != nil { tokens += 1 } }
        return (time, tokens, decoder.failure)
    }

    /// Numeric character references copied the whole text read so far, each (quadratic: 4 MiB took 20 s); now they
    /// cost about what named references do, in text and in attribute values, and decode the same.
    @Test func numericReferencesAreLinear() throws {
        let count = 800_000  // a debug build hides the copying below a few MiB
        for (name, wrap) in [("text", { (refs: String) in "<r>" + refs + "</r>" }),
                             ("attribute", { (refs: String) in "<r a=\"" + refs + "\"/>" })] {
            let numeric = Self.tokenize(wrap(String(repeating: "&#38;", count: count)))
            let named = Self.tokenize(wrap(String(repeating: "&amp;", count: count)))
            #expect(numeric.failure == .eof && named.failure == .eof)
            #expect(numeric.seconds < 2.5 * named.seconds, "\(name): numeric \(numeric.seconds) s, named \(named.seconds) s")
        }
        var decoder = GoXMLDecoder(Array("<r a=\"&#65;&#x42;&#128512;\">&#67;&#xD800;&#x110000;x</r>".utf8))
        guard case .start(_, let attrs) = decoder.rawToken() else { Issue.record("no start"); return }
        #expect(attrs.count == 1 && Array(attrs.value(0)) == Array("AB\u{1F600}".utf8))
        #expect(decoder.rawToken() == nil && decoder.failure == .syntax)  // &#x110000; is no character
        var plain = GoXMLDecoder(Array("<r>&#67;&#xD800;x</r>".utf8))
        _ = plain.rawToken()
        guard case .charData(let text) = plain.rawToken() else { Issue.record("no text"); return }
        #expect(text == Array("C\u{FFFD}x".utf8))  // a surrogate is U+FFFD, as Go writes it
    }

    /// procInst copied the rest of the instruction for every "version=" (4 MiB took 48 s); it searches in place.
    @Test func processingInstructionsAreLinear() {
        let size = 1 << 20
        let many = Self.tokenize("<r><?xml " + String(repeating: "version=x", count: size / 9) + "?></r>")
        let none = Self.tokenize("<r><?xml " + String(repeating: "aersion=x", count: size / 9) + "?></r>")
        #expect(many.failure == .eof && none.failure == .eof)
        #expect(many.seconds < 4 * none.seconds + 1, "many \(many.seconds) s, none \(none.seconds) s")
        #expect(GoXMLDecoder.procInst(Array("version".utf8), Array("version=x version='1.0' x".utf8)[...]) == Array("1.0".utf8))
        #expect(GoXMLDecoder.procInst(Array("version".utf8), Array("version=\"2\"".utf8)[...]) == Array("2".utf8))
        #expect(GoXMLDecoder.procInst(Array("version".utf8), Array("version=x version=".utf8)[...]).isEmpty)
        // A version other than 1.0 in an xml declaration is an error, wherever it is.
        var bad = GoXMLDecoder(Array("<r><?xml version='1.1'?></r>".utf8))
        while bad.rawToken() != nil {}
        #expect(bad.failure == .syntax)
    }

    // MARK: Alternates and website links

    /// Atom's alternate links were found by a scan of those before (1 MiB took 10 s); they are indexed, in their
    /// order, a repeated URL keeping its place and taking the later title.
    @Test func alternateLinksAreIndexed() throws {
        func feed(_ rel: String) -> String {
            var s = "<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>t</title>"
            for i in 0..<10_000 {
                s += "<link rel=\"\(rel)\" type=\"application/rss+xml\" href=\"https://example.com/feeds/\(i).xml\"/>"
            }
            return s + "<link rel=\"alternate\" type=\"application/rss+xml\" href=\"https://example.com/feeds/3.xml\" title=\"again\"/></feed>"
        }
        var alternates: ParityFeed?
        let indexed = try Self.seconds { alternates = try ParityFeedParserTests.parse(feed("alternate")) }
        let unindexed = try Self.seconds { _ = try ParityFeedParserTests.parse(feed("self")) }
        #expect(indexed < 4 * unindexed + 1, "alternates \(indexed) s, self links \(unindexed) s")
        let list = try #require(alternates).alternateURLs
        #expect(list.count == 10_000)
        #expect(list[3].url == "https://example.com/feeds/3.xml" && list[3].title == "again")
        #expect(list[4].title == "https://example.com/feeds/4.xml")
    }

    /// Website detection kept every link tag's attributes, which nothing reads (a page of links peaked at 23 times
    /// its size); it keeps only the title.
    @Test func websiteHeadsKeepNoLinks() throws {
        let page = "<html><head><title>x</title>" + String(repeating: "<link a>", count: (4 << 20) / 8) + "</head></html>"
        var result: Result<ParityFeed, any Error>?
        let run = ParityParseMeasurementTests.measure {
            result = Result { try ParityFeedParserTests.parse(page) }
        }
        #expect(throws: ParityParseError(label: "unsupported_type_html", detail: "Website title: \"x\"")) { try result?.get() }
        #expect(run.peakBytes < 8 * page.utf8.count, "peak heap \(run.peakBytes) bytes for a \(page.utf8.count)-byte page")
    }

    // MARK: Floats as Go reads them

    /// Number rows: floats, durations, chapter times and the handlers that read them, as Go's
    /// ParseFloat reads them: its exponent capped where it accumulates 10,000 or more, and literals of any length
    /// (Swift's Float(String) refuses 16 KiB and more, and read huge exponents differently).
    @Test func numbersAnswerAsTheServer() throws {
        var failures: [String] = []
        var count = 0
        for line in try Self.lines("ParityNumberCases.jsonl") {
            let row = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [Any])
            let kind = try #require(row[0] as? String)
            let titled = (row[1] as? Int) == 1
            var input = ""
            for run in try #require(row[2] as? [[Any]]) {
                input += String(repeating: try #require(run[1] as? String), count: try #require(run[0] as? Int))
            }
            let expected = try #require(row[3] as? String)
            let actual = try Self.numberResult(kind, input, titled: titled)
            if actual != expected {
                failures.append("\(kind) \(String(reflecting: input).prefix(120)) (\(input.utf8.count) bytes): \(actual), server \(expected)")
            }
            count += 1
        }
        #expect(count == 1_496)
        #expect(failures.isEmpty, "\(failures.count) differ:\n\(failures.prefix(20).joined(separator: "\n"))")
    }

    /// A date's numbers can be thousands of digits long; Swift's Double(String) fails past about 16,000 of them
    /// where Go's ParseFloat reads any length, so a year, day or minute of such a number (with an exponent that brings
    /// it back into range) was 0 here. The server's answers (Fixtures/ParityLongDateNumbers.jsonl).
    @Test func longDateNumbersAnswerAsTheServer() throws {
        var failures: [String] = []
        let rows = try Self.lines("ParityLongDateNumbers.jsonl")
        for line in rows {
            let row = try #require(try ContractJSON.decode(line.utf8).arrayValue)
            let now = try #require(row[0].integerValue)
            let unit = try #require(row[2].stringValue)
            let count = try #require(row[3].integerValue)
            let input = try #require(row[1].stringValue) + String(repeating: unit, count: Int(count)) + (try #require(row[4].stringValue))
            let actual = Self.optional(try ParityDates.parse(input, now: now))
            let server = try #require(row[5].stringValue)
            if actual != server {
                failures.append("\(row[1].stringValue ?? "") \(unit)×\(count) \(row[4].stringValue ?? ""): \(actual), server \(server)")
            }
        }
        #expect(rows.count == 14)
        #expect(failures.isEmpty, "\(failures.count) differ:\n\(failures.joined(separator: "\n"))")
    }

    /// The number harness's reading of a row (its Go wrapper).
    static func numberResult(_ kind: String, _ s: String, titled: Bool) throws -> String {
        switch kind {
        case "long": return optional(try ParityValues.javaParseLong(s))
        case "int": return optional(try ParityValues.javaParseInt(s))
        case "float":
            guard let f = try ParityValues.javaParseFloat(s) else { return "nil" }
            return f.isNaN ? "nan" : String(format: "%08x", f.bitPattern)
        case "duration": return optional(try ParityValues.durationMillis(s))
        case "time": return optional(try ParityValues.parseTimeString(s))
        default: break
        }
        let value = s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        var wrapper = "<rss version=\"2.0\" xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\" xmlns:media=\"http://search.yahoo.com/mrss/\" xmlns:psc=\"http://podlove.org/simple-chapters\"><channel><item><title>x</title>"
        var tail = "</item></channel></rss>"
        let inner: String
        switch kind {
        case "rss_size": inner = "<enclosure url=\"https://example.org/a.mp3\" type=\"audio/mpeg\" length=\"" + value + "\"/>"
        case "atom_size":
            wrapper = "<feed xmlns=\"http://www.w3.org/2005/Atom\"><entry><title>x</title>"
            tail = "</entry></feed>"
            inner = "<link rel=\"enclosure\" href=\"https://example.org/a.mp3\" type=\"audio/mpeg\" length=\"" + value + "\"/>"
        case "media_size": inner = "<media:content url=\"https://example.org/a.mp3\" type=\"audio/mpeg\" fileSize=\"" + value + "\"/>"
        case "media_duration": inner = "<media:content url=\"https://example.org/a.mp3\" type=\"audio/mpeg\" duration=\"" + value + "\"/>"
        case "itunes_duration": inner = "<enclosure url=\"https://example.org/a.mp3\" type=\"audio/mpeg\"/><itunes:duration>" + value + "</itunes:duration>"
        case "chapter": inner = "<psc:chapters><psc:chapter start=\"" + value + "\" title=\"x\"/></psc:chapters>"
        default: throw CocoaError(.coderInvalidValue)
        }
        if titled {
            wrapper = wrapper.replacingOccurrences(of: "<channel>", with: "<channel><title>feed</title>")
                .replacingOccurrences(of: "<entry>", with: "<title>feed</title><entry>")
        }
        do {
            let feed = try ParityFeedParser.parse(Data((wrapper + inner + tail).utf8), source: "https://example.org/feed",
                                                  now: 1_791_227_192_000, isCancelled: { false })
            guard let item = feed.items.first else { return "no item" }
            if kind == "chapter" { return optional(item.chapters?.first?.start) }
            guard let media = item.media else { return "nil" }
            return kind.contains("duration") ? String(media.duration) : String(media.size)
        } catch let error as ParityParseError {
            return "error:" + error.label
        }
    }

    // MARK: Namespaces, entity names and attributes

    /// The time a parse of doc takes, and its title.
    static func timedTitle(_ doc: String) throws -> (seconds: Double, title: String?) {
        var title: String?
        let time = try seconds { title = try ParityFeedParserTests.parse(doc).title }
        return (time, title)
    }

    /// A namespace URI as long as the document was hashed again for every element in its namespace and every
    /// attribute with its prefix, uncounted (306 KB took 19.5 s). A URI longer than every handler's is not looked up,
    /// and attributes compare numbers given to URIs where they are declared. The same document with a short URI and
    /// the same size of text is the yardstick.
    @Test func longNamespaceURIsAreHashedOnce() throws {
        let itunes = " xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\""
        func elements(_ uri: String, _ pad: Int) -> String {
            "<rss version=\"2.0\"" + itunes + " xmlns:p=\"" + uri + "\"><channel><title>t</title><x>" + String(repeating: "u", count: pad)
                + "</x>" + String(repeating: "<p:a/>", count: 20_000) + "</channel></rss>"
        }
        func attributes(_ uri: String, _ pad: Int) -> String {
            "<rss version=\"2.0\"" + itunes + " xmlns:p=\"" + uri + "\"><channel><title>t</title><x>" + String(repeating: "u", count: pad)
                + "</x><x" + (0..<10_000).map { " p:a\($0)=\"\"" }.joined() + "/></channel></rss>"
        }
        let n = 64 << 10
        for (name, doc) in [("elements", elements), ("attributes", attributes)] {
            let plain = try Self.timedTitle(doc("u", n - 1))
            let hostile = try Self.timedTitle(doc(String(repeating: "u", count: n), 0))
            print("parity long namespace URI \(name): \(hostile.seconds) s, a short URI \(plain.seconds) s")
            #expect(plain.title == "t" && hostile.title == "t", "\(name)")
            #expect(hostile.seconds < 4 * plain.seconds + 0.5, "\(name): \(hostile.seconds) s, a short URI \(plain.seconds) s")
        }
        // An expanded name is the namespace's value with the local name, whatever the prefix.
        let head = "<rss version=\"2.0\" xmlns:a=\"urn:x\" xmlns:b=\"urn:y\"><channel><title>t</title>"
        for (tag, outcome) in [("<x a:k=\"1\" b:k=\"2\"/>", "t"), ("<x k=\"1\" a:k=\"2\"/>", "t"),
                               ("<x xmlns:c=\"urn:x\" a:k=\"1\" c:k=\"2\"/>", "parser_exception"),
                               ("<x xmlns:b=\"urn:x\" a:k=\"1\" b:k=\"2\"/>", "parser_exception"),
                               ("<x xmlns:a=\"urn:z\" a:k=\"1\" b:k=\"2\"><y a:k=\"1\" b:k=\"2\"/></x><z a:k=\"1\"/>", "t"),
                               ("<x c:k=\"1\"/>", "parser_exception"), ("<x a:k=\"1\" a:k=\"2\"/>", "parser_exception"),
                               ("<x xmlns:xml=\"http://www.w3.org/XML/1998/namespace\" xml:k=\"1\" k=\"2\"/>", "t")] {
            let doc = head + tag + "</channel></rss>"
            let result: String
            do {
                result = try ParityFeedParserTests.parse(doc).title ?? "no title"
            } catch let error as ParityParseError {
                result = error.label
            }
            #expect(result == outcome, "\(tag)")
        }
    }

    /// In a document that declares an entity, each '&' of a run before one ';' copied and hashed a name as long
    /// as the rest of the run, uncounted (131 KB took 7.8 s). Only a name as long as a declared one is copied and
    /// looked up, and its bytes are counted.
    @Test func ampersandRunsCopyOnlyDeclaredLengths() throws {
        func doc(_ name: Int, _ pad: Int) -> String {
            "<!DOCTYPE rss [<!ENTITY " + String(repeating: "e", count: name) + " \"v\">]><rss version=\"2.0\"><channel><title>t</title>"
                + "<description>" + String(repeating: "u", count: pad) + String(repeating: "&", count: 65_536) + ";</description></channel></rss>"
        }
        var plain = 0.0
        var hostile = 0.0
        plain = Self.seconds { #expect(ParityFeedParserTests.isParserException { _ = try ParityFeedParserTests.parse(doc(1, 65_535)) }) }
        hostile = Self.seconds { #expect(ParityFeedParserTests.isParserException { _ = try ParityFeedParserTests.parse(doc(65_536, 0)) }) }
        print("parity hostile input (long entity names): \(hostile) s, a short name \(plain) s")
        #expect(hostile < 4 * plain + 0.5, "\(hostile) s, a short name \(plain) s")
        // Uses of names of several lengths still expand among other references.
        let feed = try ParityFeedParserTests.parse("<!DOCTYPE rss [<!ENTITY a \"x\"><!ENTITY abc \"y\">]><rss version=\"2.0\"><channel>"
            + "<title>&abc;&a;&amp;&abc;&#65;&a;</title></channel></rss>")
        #expect(feed.title == "yx&yAx")
        // A run of '&' before one use: the last is the use.
        #expect(ParityFeedParserTests.isParserException {
            _ = try ParityFeedParserTests.parse("<!DOCTYPE rss [<!ENTITY a \"x\">]><rss version=\"2.0\"><channel><title>&&a;</title></channel></rss>")
        })
    }

    /// The XML decoder handed its working buffer out as attribute names and values, so every attribute kept a
    /// buffer as large as the largest token before it (254 KB peaked at 645 MB, 1.24 MB at 984 MB). Each token's bytes
    /// are copied now.
    @Test func attributesKeepNoDecoderBuffer() throws {
        func attributes(_ count: Int) -> String { (0..<count).map { " a\($0)=\"\"" }.joined() }
        for (name, doc) in [
            ("after a long value", "<rss version=\"2.0\"><channel><title>t</title><x z=\"" + String(repeating: "u", count: 64 << 10) + "\""
                + attributes(20_000) + "/></channel></rss>"),
            ("after a long text", "<rss version=\"2.0\"><channel><title>t</title><description>" + String(repeating: "u", count: 64 << 10)
                + "</description><x" + attributes(5_000) + "/></channel></rss>")
        ] {
            var title: String?
            let run = try ParityParseMeasurementTests.measure { title = try ParityFeedParserTests.parse(doc).title }
            print("parity attribute buffer \(name): peak heap \(run.peakBytes) bytes for a \(doc.utf8.count)-byte feed")
            #expect(title == "t", "\(name)")
            #expect(run.peakBytes < 32 * doc.utf8.count, "\(name): peak heap \(run.peakBytes) bytes for a \(doc.utf8.count)-byte feed")
        }
    }
}
