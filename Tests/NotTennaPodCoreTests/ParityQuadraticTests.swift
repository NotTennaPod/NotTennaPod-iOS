import Foundation
import Testing
@testable import NotTennaPodCore

/// Hostile inputs that took the server's parse quadratic time, some without stopping at its deadline (its
/// quadratic_test.go, after the date report from this port): the same paths are linear here, or stop at
/// cancellation, with the same output.
struct ParityQuadraticTests {
    typealias Parse = ParityFeedParserTests

    /// Fails when body takes longer than limit: far above the linear time in a debug build on a loaded machine, far
    /// below the quadratic time the same input took before.
    static func within(_ limit: Duration, _ what: String, _ body: () throws -> Void) rethrows {
        let start = ContinuousClock.now
        try body()
        let elapsed = start.duration(to: .now)
        #expect(elapsed <= limit, "\(what) took \(elapsed)")
    }

    /// How many times a parse of doc asks whether it is cancelled.
    static func checks(_ doc: String) -> Int {
        let counter = Parse.CancelAfter(Int.max)
        _ = try? Parse.parse(doc, isCancelled: counter.ask)
        return Int.max - counter.left
    }

    /// A date of many "word, " prefixes: every date field stops at the parse's cancellation at its first retry; the
    /// retry's result is unchanged.
    @Test func aDateStopsAtCancellationInEveryField() throws {
        let plain = "Sat, 09 Oct 2021 10:00:00 +0000"
        let want: Int64 = 1_633_773_600_000
        let date = String(repeating: "a, ", count: 1000) + plain
        #expect(try ParityDates.parse(date, now: Parse.now) == want)
        #expect(try ParityDates.parse(String(repeating: "Sat, ", count: 50) + "nothing", now: Parse.now) == nil)
        let rss = "<rss version=\"2.0\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><channel><title>T</title><item><title>I</title>"
        for (name, doc) in [
            ("pubDate", rss + "<pubDate>DATE</pubDate></item></channel></rss>"),
            ("dc:date", rss + "<dc:date>DATE</dc:date></item></channel></rss>"),
            ("published", "<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>T</title><entry><title>I</title><published>DATE</published></entry></feed>"),
            ("updated", "<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>T</title><entry><title>I</title><updated>DATE</updated></entry></feed>")
        ] {
            let hostile = doc.replacingOccurrences(of: "DATE", with: date)
            #expect(try Parse.parse(hostile).items.first?.pubDate == want, "\(name)")
            // Every check a parse of the plain date makes passes; the hostile date's first retry stops it.
            let cancel = Parse.CancelAfter(Self.checks(doc.replacingOccurrences(of: "DATE", with: plain)))
            #expect(throws: CancellationError.self, "\(name)") { try Parse.parse(hostile, isCancelled: cancel.ask) }
        }
    }

    /// Stray '&'s in a document that declares an entity each looked for the next ';' to the end of the document
    /// (2 MB took the server 53 s) and never asked for cancellation: the scan is linear and stoppable; the result is
    /// the same parser exception, and uses among them still expand.
    @Test func strayAmpersandsAreLinear() throws {
        let prolog = "<?xml version=\"1.0\"?><!DOCTYPE rss [<!ENTITY e \"x\">]><rss version=\"2.0\"><channel><title>"
        for (name, title) in [("no semicolon", String(repeating: "&", count: 2 << 20)),
                              ("one semicolon at end", String(repeating: "&", count: 2 << 20) + ";")] {
            let doc = prolog + title + "</title></channel></rss>"
            Self.within(.seconds(30), name) {
                #expect(Parse.isParserException { _ = try Parse.parse(doc) }, "\(name)")
            }
            #expect(throws: CancellationError.self, "\(name)") {
                try ParitySAX.expandDocument(Array(doc.utf8), cancellation: ParityCancellation { true })
            }
        }
        #expect(try Parse.parse(prolog + "&e;&#65;&e;&amp;&e;</title></channel></rss>").title == "xAx&x")
    }

    /// TagSoup walks the whole stack for an end tag it cannot find and for each block start under many restartable
    /// elements: quadratic time, on Android too. Its stack steps are counted and checked, not only its characters.
    @Test func tagSoupStackWalksStopAtCancellation() throws {
        let rss = "<rss version=\"2.0\"><channel><title><![CDATA[TITLE]]></title></channel></rss>"
        for (name, html) in [
            // Both under 4,096 characters: the scanner checks only at its start.
            ("end tags not open", String(repeating: "<div>", count: 600) + String(repeating: "</span>", count: 150)),
            ("blocks in formatting", String(repeating: "<b>", count: 300) + String(repeating: "<p>", count: 300))
        ] {
            let doc = rss.replacingOccurrences(of: "TITLE", with: html)
            #expect(throws: Never.self, "\(name)") { try Parse.parse(doc) }
            // Every check a parse of a one-letter title makes passes; the stack steps' first check stops it.
            let cancel = Parse.CancelAfter(Self.checks(rss.replacingOccurrences(of: "TITLE", with: "x")))
            #expect(throws: CancellationError.self, "\(name)") { try Parse.parse(doc, isCancelled: cancel.ask) }
        }
    }

    /// Html's appendNewlines counted every newline at the end for each block: it counts up to the margin, which
    /// decides the same.
    @Test func blocksAfterLineBreaksAreLinear() throws {
        let n = 200_000
        let converter = HTMLConverter(margin: 2)
        converter.text = [UInt16(ascii: "x")] + [UInt16](repeating: 0x0A, count: n)
        Self.within(.seconds(10), "200,000 blocks after 200,000 line breaks") {
            for _ in 0..<n { converter.appendNewlines(converter.margin) }
        }
        #expect(converter.text.count == n + 1)
        let cancellation = ParityCancellation { false }
        for (input, compact, legacy) in [("x<br><p>y</p>", "x\ny\n", "x\n\ny\n\n"),
                                         ("x<br><br><br><p>y</p><p>z</p>", "x\n\n\ny\nz\n", "x\n\n\ny\n\nz\n\n")] {
            #expect(try ParityHTMLText.text(input, compact: true, cancellation: cancellation) == compact)
            #expect(try ParityHTMLText.text(input, compact: false, cancellation: cancellation) == legacy)
        }
    }

    /// TagSoup looked every attribute up among the tag's earlier ones; then indexed them. Of an element's attributes
    /// Html's converter reads only the color, and only whether it is "-": that is all an element keeps now. A repeated
    /// name still replaces the value, names are lower-cased and values' references expanded.
    @Test func manyAttributesAreLinear() throws {
        var html = "<font"
        for i in 0..<200_000 { html += " a\(i)=v" }
        html += ">x</font>"
        let never = ParityCancellation { false }
        var text = ""
        try Self.within(.seconds(20), "200,000 attributes") {
            text = try ParityHTMLText.text(html, compact: true, cancellation: never)
        }
        #expect(text == "x")
        // Through Html: <font color="-"> throws, the color found after 20,000 other attributes.
        var many = "<font"
        for i in 0..<20_000 { many += " a\(i)=v" }
        many += " color=\"-\">x</font>"
        #expect(throws: ParityParseError.parserException) { try ParityHTMLText.text(many, compact: true, cancellation: never) }
        for (tag, throwsError) in [("<font color=\"-\" color=\"red\">", false), ("<font color=\"red\" COLOR=\"&#45;\">", true),
                                   ("<font xmlns:color=\"-\">", false), ("<font color>", false), ("<FONT Color=-->", false),
                                   ("<font color=->", true), ("<b color=\"-\">", false)] {
            let thrown = (try? ParityHTMLText.text(tag + "x</font>", compact: true, cancellation: never)) == nil
            #expect(thrown == throwsError, "\(tag)")
        }
    }

    /// Each competing description measured the current one's UTF-16 length again (Java keeps a string's length):
    /// the length is kept now; the comparison is the same.
    @Test func descriptionCandidatesAreLinear() throws {
        let state = ParityHandlerState(kind: .rss20, now: Parse.now, cancellation: ParityCancellation { false })
        try state.addItem()
        let long = String(repeating: "\u{E9}", count: 1 << 19)
        state.setDescriptionIfLonger(0, long)
        Self.within(.seconds(10), "20,000 descriptions after 1 MiB") {
            for _ in 0..<20_000 { state.setDescriptionIfLonger(0, "short") }
        }
        #expect(state.items[0].description.map { GoStrings.same($0, long) } == true)
        // UTF-16 lengths decide: "😀" is two units, as long as "ab".
        try state.addItem()
        for s in ["\u{1F600}", "ab", "abc", "ab\u{1F600}", "abcd"] { state.setDescriptionIfLonger(1, s) }
        #expect(state.items[1].description == "ab\u{1F600}")
    }

    /// Atom's feed author is every author name joined by ", ", which Java concatenated anew for each name: the names
    /// are appended in place, and another handler's author is still extended.
    @Test func feedAuthorsAreLinear() throws {
        let state = ParityHandlerState(kind: .atom, now: 0, cancellation: ParityCancellation { false })
        Self.within(.seconds(10), "200,000 authors") {
            for _ in 0..<200_000 { state.addFeedAuthor("a") }
        }
        let joined = try #require(state.feedAuthor)
        #expect(joined.utf8.count == 3 * 200_000 - 2 && joined.hasPrefix("a, a, ") && !joined.hasSuffix(", "))
        let feed = try Parse.parse("<feed xmlns=\"http://www.w3.org/2005/Atom\" xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\">"
            + "<title>T</title><author><name>A</name></author><author><name>B</name></author><itunes:author>I</itunes:author>"
            + "<author><name>C</name></author><author><name> D </name></author></feed>")
        #expect(feed.author == "I, C, D")
    }

    // MARK: The server's entity-candidate and namespaced-attribute follow-ups (07f1be3, 526f06c, 6ec5517)

    /// A run of '&' before one ';' gives each '&' a candidate entity name as long as the rest of the run; every
    /// candidate up to the longest declared name was copied and hashed (found by fuzzing the phone's parity parse). The server's
    /// TestQuadraticEntityCandidates: 11 entities and a 1 MiB run, and uses at every declared length.
    @Test func entityCandidatesAreLinear() throws {
        let n = 1 << 20
        var declarations = "<!ENTITY " + String(repeating: "e", count: n) + " \"v\">"
        for i in 0..<10 { declarations += "<!ENTITY a\(i) \"w\">" }
        let doc = "<!DOCTYPE rss [" + declarations + "]><rss version=\"2.0\"><channel><title>t</title><description>"
            + String(repeating: "&", count: n) + ";</description></channel></rss>"
        Self.within(.seconds(20), "a 1 MiB run of '&' with 11 entities") {
            #expect(Parse.isParserException { _ = try Parse.parse(doc) })
        }
        // Uses still expand, at every declared length.
        let ok = "<!DOCTYPE rss [" + declarations + "]><rss version=\"2.0\"><channel><title>&a3;&&a7;</title></channel></rss>"
        #expect(Parse.isParserException { _ = try Parse.parse(ok) }, "a stray '&' among uses")
        let uses = ok.replacingOccurrences(of: "&&a7;", with: "&a7;&" + String(repeating: "e", count: n) + ";")
        #expect(try Parse.parse(uses).title == "wwv")
    }

    /// How many times expandDocument asks whether it is cancelled on doc.
    static func expandDocumentChecks(_ doc: [UInt8]) -> Int {
        let counter = Parse.CancelAfter(Int.max)
        _ = try? ParitySAX.expandDocument(doc, cancellation: ParityCancellation(isCancelled: counter.ask))
        return Int.max - counter.left
    }

    /// The candidates of a run of '&' are filtered in one pass back from its ';', as far as the longest declared
    /// name, and that pass and hashing the declared names are counted (the server's TestEntityCandidateFilterIsCounted:
    /// a name of 600,000 bytes and a '&' as far from its ';').
    @Test func entityCandidateFilterIsCounted() throws {
        let k = 600_000
        let name = [UInt8](repeating: UInt8(ascii: "n"), count: k)
        #expect(throws: CancellationError.self) { _ = try ParitySAX.EntityFilter(declared: [name], work: ParityCancellation { true }) }
        var filter = try ParitySAX.EntityFilter(declared: [name], work: ParityCancellation { false })
        let hostile = Array(("&" + String(repeating: "y", count: k) + ";").utf8)
        let baseline = Array((String(repeating: "y", count: k) + "&;").utf8)
        try filter.window(baseline, k, k + 1, ParityCancellation { true })  // nothing to read: no question
        #expect(throws: CancellationError.self) { try filter.window(hostile, 0, k + 1, ParityCancellation { true }) }
        // The declared candidate passes; others of its length do not.
        let use = Array(("&" + String(repeating: "n", count: k) + ";").utf8)
        try filter.window(use, 0, k + 1, ParityCancellation { false })
        #expect(filter.passed(k))
        try filter.window(hostile, 0, k + 1, ParityCancellation { false })
        #expect(!filter.passed(k) && !filter.passed(k - 1))
    }

    /// The length guard alone leaves one family super-linear: names of every length in [w/2, w), and runs of w '&'
    /// repeated, look up as many bytes per run as the declarations hold, (n/2)^1.5 for a document of n. With the
    /// one-pass filter the work counted grows with the document: the checks stay within twice one per 1,024 bytes
    /// (the server's TestEntityCandidateWorkIsLinear).
    @Test func entityCandidateWorkIsLinear() throws {
        let n = 4 << 20
        var w = 2
        while 3 * w * w / 8 < n / 2 { w += 1 }
        var doc = "<!DOCTYPE rss ["
        for length in (w / 2)..<w { doc += "<!ENTITY " + String(repeating: "n", count: length) + " \"v\">" }
        doc += "]><rss version=\"2.0\"><channel><title>t</title><description>"
        let run = String(repeating: "&", count: w) + ";"
        var runs = 0
        while doc.utf8.count + runs * (w + 1) < n - w { runs += 1 }
        let full = doc + String(repeating: run, count: runs) + "</description></channel></rss>"
        let checks = Self.expandDocumentChecks(Array(full.utf8))
        let limit = 2 * full.utf8.count / 1024
        #expect(checks <= limit, "\(checks) checks for \(full.utf8.count) bytes, more than \(limit)")
        // A declared name among the runs is still found, and expands.
        let use = doc + "&&" + String(repeating: "n", count: w / 2) + ";" + String(repeating: run, count: runs - 1)
            + "</description></channel></rss>"
        let out = try ParitySAX.expandDocument(Array(use.utf8), cancellation: ParityCancellation { false })
        #expect(String(decoding: out, as: UTF8.self).contains("<description>&v"))
    }

    /// Attributes' expanded names (namespace, local) must be unique; the namespace was the URI itself, hashed for every
    /// attribute (found by fuzzing the phone's parity parse). Each URI is numbered once, when declared (the server's
    /// TestQuadraticNamespacedAttributes).
    @Test func namespacedAttributesAreLinear() throws {
        let doc = "<rss version=\"2.0\" xmlns:p=\"" + String(repeating: "u", count: 2 << 20) + "\"><channel><title>t</title><x"
            + (0..<40_000).map { " p:a\($0)=\"\"" }.joined() + "/></channel></rss>"
        Self.within(.seconds(20), "40,000 attributes in a namespace of 2 MiB") {
            #expect(throws: Never.self) { try Parse.parse(doc) }
        }
        // The same URI under two prefixes is one namespace; other URIs, no namespace and the default namespace are
        // others.
        for (tag, duplicate) in [
            ("<x xmlns:p=\"u\" xmlns:q=\"u\" p:a=\"1\" q:a=\"2\"/>", true),
            ("<x xmlns:p=\"u\" p:a=\"1\"><y xmlns:q=\"u\" p:a=\"1\" q:a=\"2\"/></x>", true),
            ("<x xmlns:p=\"u\" xmlns:q=\"v\" p:a=\"1\" q:a=\"2\"/>", false),
            ("<x xmlns:p=\"u\" a=\"1\" p:a=\"2\"/>", false),
            ("<x xmlns=\"u\" xmlns:p=\"u\" a=\"1\" p:a=\"2\"/>", false),
            ("<x xmlns:p=\"u\" p:a=\"1\"><y xmlns:p=\"v\" p:a=\"1\" xmlns:q=\"u\" q:a=\"2\"/></x>", false),
            ("<x xmlns:p=\"u\"><y xmlns:p=\"v\" xmlns:q=\"v\" p:a=\"1\" q:a=\"2\"/></x>", true),
            ("<x xml:lang=\"en\" lang=\"en\"/>", false)
        ] {
            let feed = "<rss version=\"2.0\"><channel><title>t</title>" + tag + "</channel></rss>"
            #expect(Parse.isParserException { _ = try Parse.parse(feed) } == duplicate, "\(tag)")
        }
    }
}
