import Foundation
import Testing
@testable import NotTennaPodCore

/// The parse's cancellation within one token and at its ends (the server's deadline_test.go
/// and entitydecl_test.go): a long date, text, declaration, tag or name stops at the parse's cancellation, and a
/// parse whose cancellation came is neither a feed nor a parse error. Outputs are unchanged.
struct ParityDeadlineTests {
    typealias Parse = ParityFeedParserTests
    typealias Quadratic = ParityQuadraticTests

    /// A cancellation that answers true from the start.
    static var cancelled: ParityCancellation { ParityCancellation { true } }

    /// Whether body throws CancellationError.
    static func isCancellation(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            return false
        } catch is CancellationError {
            return true
        } catch {
            return false
        }
    }

    /// A date as long as a feed's text that takes no weekday retry ran through every pass and format unchecked (a
    /// numeric pubDate of 16 MiB parsed 2 s past the server's deadline, and its feed was a success). Every pass
    /// counts its steps now; the date is still null, and the feed is kept.
    @Test func aLongDateStopsAtCancellation() throws {
        let date = String(repeating: "1", count: 1 << 18)
        #expect(try ParityDates.parse(date, now: Parse.now) == nil)
        // The passes' answers are the same: "Sept" is still Sep, before and after a weekday.
        #expect(try ParityDates.parse("09 Sept 2021 10:00:00 +0000", now: Parse.now) == 1_631_181_600_000)
        #expect(try ParityDates.parse("Thu, 09 Sept 2021 10:00:00 +0000", now: Parse.now) == 1_631_181_600_000)
        #expect(Self.isCancellation { _ = try ParityDates.parse(date, now: Parse.now, cancellation: Self.cancelled) })
        // After the UTF-16 conversion (its one check passes), the first pass's own steps.
        for long in [String(repeating: " ", count: 100_000) + "1", "1" + String(repeating: " ", count: 100_000) + "x",
                     String(repeating: "Sept ", count: 20_000), "2021-10-09T10:00:00." + String(repeating: "9", count: 100_000)] {
            let cancel = Parse.CancelAfter(1)
            #expect(Self.isCancellation {
                _ = try ParityDates.parse(long, now: Parse.now, cancellation: ParityCancellation(isCancelled: cancel.ask))
            }, "\(long.prefix(24))")
        }
        let rss = "<rss version=\"2.0\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><channel><title>T</title><item><title>I</title>"
        for (name, doc) in [
            ("pubDate", rss + "<pubDate>DATE</pubDate></item></channel></rss>"),
            ("dc:date", rss + "<dc:date>DATE</dc:date></item></channel></rss>"),
            ("published", "<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>T</title><entry><title>I</title><published>DATE</published></entry></feed>")
        ] {
            let long = doc.replacingOccurrences(of: "DATE", with: date)
            let feed = try Parse.parse(long)
            #expect(feed.items.count == 1 && feed.items[0].pubDate == nil, "\(name)")
            // Every check a parse of a short date makes passes; the long date's steps stop it.
            let cancel = Parse.CancelAfter(Quadratic.checks(doc.replacingOccurrences(of: "DATE", with: "1")))
            #expect(throws: CancellationError.self, "\(name)") { try Parse.parse(long, isCancelled: cancel.ask) }
        }
    }

    /// A parse whose cancellation came after its last check is no success: the parse asks once more before it
    /// returns. This document's parse asks after the type detection, at the reader's first token, at the title's
    /// conversion and at its end.
    @Test func anExpiredParseIsNoSuccess() throws {
        let doc = "<rss version=\"2.0\"><channel><title>T</title></channel></rss>"
        #expect(try Parse.parse(doc).title == "T")
        #expect(Quadratic.checks(doc) == 4, "the parse's checks changed: update this test")
        let cancel = Parse.CancelAfter(3)
        #expect(throws: CancellationError.self) { try Parse.parse(doc, isCancelled: cancel.ask) }
    }

    /// Nor is it a parse error: this document's parse asks after the type detection and at the reader's first token,
    /// then at its end, before the missing title is reported.
    @Test func anExpiredParseIsNoParseError() throws {
        let doc = "<rss version=\"2.0\"><channel></channel></rss>"
        #expect(Parse.isParserException { _ = try Parse.parse(doc) })
        #expect(Quadratic.checks(doc) == 3, "the parse's checks changed: update this test")
        let cancel = Parse.CancelAfter(2)
        #expect(throws: CancellationError.self) { try Parse.parse(doc, isCancelled: cancel.ask) }
    }

    /// Cancellation that comes after the titles are read stops the rest of the parse (it did before this round too).
    @Test func aDeadlineAfterTheTitlesStopsTheParse() throws {
        let doc = "<rss version=\"2.0\"><channel><title>t</title>"
            + String(repeating: "<item><title>i</title><description>d</description></item>", count: 5_000) + "</channel></rss>"
        // After the type detection, the reader's first token and the channel title's conversion.
        let cancel = Parse.CancelAfter(3)
        #expect(throws: CancellationError.self) { try Parse.parse(doc, isCancelled: cancel.ask) }
        #expect(cancel.left < 0)
    }

    /// The decoder reads a token in one call, so a text of many megabytes was read unchecked between the parse's
    /// checks: the decoder asks every 64 KiB it reads, in text, in a description and in an attribute value.
    @Test func aLongTokenStopsAtCancellation() throws {
        let rss = "<rss version=\"2.0\"><channel><title>T</title>"
        for (name, doc, size) in [
            ("text", rss + "<x>TEXT</x></channel></rss>", 4 << 20),
            ("description", rss + "<item><title>I</title><description>TEXT</description></item></channel></rss>", 16 << 20),
            ("attribute", rss + "<item><title>I</title><enclosure url=\"TEXT\" type=\"audio/mpeg\"/></item></channel></rss>", 4 << 20),
            ("CDATA", rss + "<x><![CDATA[TEXT]]></x></channel></rss>", 4 << 20)
        ] {
            let long = doc.replacingOccurrences(of: "TEXT", with: String(repeating: "a", count: size))
            if size <= 4 << 20 { #expect(throws: Never.self, "\(name)") { try Parse.parse(long) } }
            let cancel = Parse.CancelAfter(Quadratic.checks(doc.replacingOccurrences(of: "TEXT", with: "a")))
            #expect(throws: CancellationError.self, "\(name)") { try Parse.parse(long, isCancelled: cancel.ask) }
        }
        // Many numeric references in one text: the decoding stops too.
        var decoder = GoXMLDecoder(Array(("<r>" + String(repeating: "&#65;", count: 800_000) + "</r>").utf8),
                                   cancellation: Self.cancelled)
        _ = decoder.rawToken()
        #expect(decoder.rawToken() == nil && decoder.failure == .cancelled)
        // A name as long as the document.
        var named = GoXMLDecoder(Array(("<" + String(repeating: "n", count: 1 << 20) + "/>").utf8), cancellation: Self.cancelled)
        #expect(named.rawToken() == nil && named.failure == .cancelled)
    }

    /// Entity declarations were read and their character references replaced without a check, and an expired parse
    /// with a malformed declaration reported parser_exception. Reading the prolog, scanning the declarations and
    /// replacing their references ask now.
    @Test func aLongEntityDeclarationStopsAtCancellation() throws {
        let value = String(repeating: "&#65;", count: 1 << 20)
        for (name, tail) in [("valid", ""), ("invalid tail", "&#invalid;")] {
            let doc = "<!DOCTYPE rss [<!ENTITY e \"" + value + tail + "\">]><rss><channel><title>T</title></channel></rss>"
            if tail.isEmpty {
                #expect(try Parse.parse(doc).title == "T")
            } else {
                #expect(Parse.isParserException { _ = try Parse.parse(doc) }, "\(name)")
            }
            #expect(throws: CancellationError.self, "\(name)") {
                try ParitySAX.expandDocument(Array(doc.utf8), cancellation: Self.cancelled)
            }
            // The parse's first check, reading the prolog for the type, passes.
            let cancel = Parse.CancelAfter(1)
            #expect(throws: CancellationError.self, "\(name)") { try Parse.parse(doc, isCancelled: cancel.ask) }
        }
        // One declaration's own work.
        #expect(throws: CancellationError.self) {
            try ParitySAX.entityDeclarations(Array(("DOCTYPE rss [<!ENTITY e \"" + String(repeating: "x", count: 1 << 20) + "\">]").utf8),
                                             work: Self.cancelled) { _, _ in }
        }
        #expect(throws: CancellationError.self) {
            try ParitySAX.replaceCharacterReferences(Array(value.utf8), work: Self.cancelled)
        }
    }

    /// An already-cancelled parse of a document whose entity declaration is malformed reported parser_exception
    /// without asking: it is cancelled.
    @Test func anAlreadyCancelledParseWithABadDeclarationIsCancelled() {
        let doc = "<!DOCTYPE rss [<!ENTITY e \"&oops\">]><rss><channel><title>T</title></channel></rss>"
        #expect(Parse.isParserException { _ = try Parse.parse(doc) })
        #expect(throws: CancellationError.self) { try Parse.parse(doc, isCancelled: { true }) }
    }

    /// One large tag (a link of 200,000 attributes, a value or a title of 400,000 references) was read whole, its
    /// name, value and decoding scans unchecked: the head scan counts its work within a tag, a value or a title.
    @Test func oneLargeWebsiteTagStopsAtCancellation() throws {
        let link = "<link rel=\"alternate\" type=\"application/rss+xml\" href="
        var attributes = ""
        for i in 0..<200_000 { attributes += " a\(i)=v" }
        let references = String(repeating: "&amp;", count: 400_000)
        for (name, page) in [
            ("attributes", "<html><head>" + link + "\"/feed\"" + attributes + "></head></html>"),
            ("value", "<html><head>" + link + "\"/feed?" + references + "\"></head></html>"),
            ("title", "<html><head><title>" + references + "</title>" + link + "\"/feed\"></head></html>")
        ] {
            let head = try ParityWebsite.parseHead(Array(page.utf8)[...], cancellation: ParityCancellation { false })
            #expect((head.title != nil) == (name == "title"), "\(name)")
            // The scan's first check passes; the large token's own work stops it.
            let cancel = Parse.CancelAfter(1)
            #expect(throws: CancellationError.self, "\(name)") {
                _ = try ParityWebsite.parseHead(Array(page.utf8)[...], cancellation: ParityCancellation(isCancelled: cancel.ask))
            }
        }
    }

    /// No name longer than every entity's is one, with or without its semicolon, and such a name is not looked up:
    /// the guarded lookup answers as the table does.
    @Test func longEntityNamesAreNoEntities() {
        #expect(ParityWebsite.longestEntity == 32)
        #expect(ParityWebsite.entity(Array("CounterClockwiseContourIntegral".utf8), semicolon: true) == Array("\u{2233}".utf8))
        let prefixes = ["", "CounterClockwiseContourIntegral", "ClockwiseContourIntegral", "amp", "AMP", "copy", "not", "notin",
                        "nbsp", "AElig", "acE", "NotNestedGreaterGreater", "DoubleLongLeftRightArrow"]
        let tails = ["", "x", "1", "\u{E9}", "a1", "\u{E4}"]
        var rng = SplitMix64(seed: 20_261_009)
        for _ in 0..<50_000 {
            var name = prefixes[Int(rng.next() % UInt64(prefixes.count))]
            let length = 24 + Int(rng.next() % 16)
            while name.utf8.count < length { name += tails[Int(rng.next() % UInt64(tails.count))] }
            for semicolon in [false, true] {
                let bytes = Array(name.utf8)
                let guarded = ParityWebsite.entity(bytes, semicolon: semicolon)
                let table = ParityWebsite.entity(bytes, semicolon: semicolon, guarded: false)
                if guarded != table {
                    Issue.record("\(name) (semicolon \(semicolon)): \(String(describing: guarded)), the table says \(String(describing: table))")
                    return
                }
            }
        }
    }

    /// The declarations are read as the regular expression the server read them with before its scanner (in ICU,
    /// with Go's \s and ASCII \b spelled out), on the bytes as Latin-1 so that every byte is one character.
    static func expressionDeclarations(_ dir: [UInt8]) -> [[UInt8]] {
        let pattern = #"<!ENTITY[\t\n\f\r ]+([^\t\n\f\r %]+)[\t\n\f\r ]+(?:"([^"]*)"|'([^']*)'|(SYSTEM|PUBLIC)(?![0-9A-Za-z_])[^>]*)[\t\n\f\r ]*>"#
        let expression = try! NSRegularExpression(pattern: pattern)
        let text = String(decoding: dir.map { UInt16($0) }, as: UTF16.self)
        var out: [[UInt8]] = []
        for m in expression.matches(in: text, range: NSRange(location: 0, length: dir.count)) {
            func group(_ i: Int) -> [UInt8] {
                let r = m.range(at: i)
                return r.location == NSNotFound ? [] : Array(dir[r.location..<(r.location + r.length)])
            }
            out.append(group(1))
            out.append(group(2) + group(3))
        }
        return out
    }

    static func scannedDeclarations(_ dir: [UInt8]) throws -> [[UInt8]] {
        var out: [[UInt8]] = []
        try ParitySAX.entityDeclarations(dir, work: ParityCancellation { false }) { name, value in
            out.append(name)
            out.append(value)
        }
        return out
    }

    /// The declarations' scanner finds exactly the expression's matches, and in linear time where every attempt
    /// fails late: no '>' after many SYSTEM declarations, no closing quote after many opening ones, and many
    /// "<!ENTITY" without their whitespace before many '>'.
    @Test func entityDeclarationsMatchTheExpression() throws {
        func check(_ dir: [UInt8]) throws -> Bool {
            let got = try Self.scannedDeclarations(dir)
            let want = Self.expressionDeclarations(dir)
            if got != want {
                Issue.record("\(String(decoding: dir, as: UTF8.self)):\n got \(got.map { String(decoding: $0, as: UTF8.self) })\nwant \(want.map { String(decoding: $0, as: UTF8.self) })")
                return false
            }
            return true
        }
        for dir in [
            "", "DOCTYPE rss", "DOCTYPE rss [<!ENTITY a \"x\">]", "DOCTYPE rss [<!ENTITY a 'x'><!ENTITY b \"y\" >]",
            "DOCTYPE rss [<!ENTITY % pe \"x\"><!ENTITY a SYSTEM \"u\"><!ENTITY b PUBLIC \"p\" \"u\">]",
            "DOCTYPE rss [<!ENTITY a \"x <!ENTITY b \"y\">]", "<!ENTITY a SYSTEMx>", "<!ENTITY a SYSTEM_>", "<!ENTITY a SYSTEM>",
            "<!ENTITY a \"x\"y>", "<!ENTITY a%b \"x\">", "<!ENTITY\ta\u{0C}\"x\"\r\n>", "<!ENTITY a\u{0B}\"x\">", "<!ENTITY a \"x",
            "<!ENTITY a \"x\" <!ENTITY b 'y'>", "<!ENTITY a \"x\"" + String(repeating: " ", count: 100) + ">", "<!ENTITY a \"\"><!ENTITY a \"\">",
            "\"<!ENTITY a SYSTEM <!ENTITY b SYSTEM <!ENTITY c SYSTEM", "<!ENTITY a \"x' <!ENTITY b 'y\" >'>",
            "<!ENTITY<!ENTITY a \"x\">", "<!ENTITY<!ENTITY>>"
        ] {
            #expect(try check(Array(dir.utf8)))
        }
        #expect(try check(Array("<!ENTITY \u{E9} \"".utf8) + [0xFF] + Array("\">".utf8)))
        let words: [String] = ["<!ENTITY", "<!ENTITY", "<!ENTITY ", " ", " ", "\t", "\n", "\u{0C}", "\r", "\u{0B}", "%", "a", "b",
                               "\u{E9}", "x1", "\"", "\"", "'", "'", ">", ">", "<", "!", "SYSTEM", "PUBLIC", "SYSTEMx", "PUBLIC_",
                               "S", "P", "&#65;", "]", "[", "--"]
        let pieces: [[UInt8]] = words.map { Array($0.utf8) } + [[0xFF]]
        var rng = SplitMix64(seed: 20_261_009_7)
        for _ in 0..<20_000 {
            var dir: [UInt8] = []
            for _ in 0..<Int(rng.next() % 16) { dir += pieces[Int(rng.next() % UInt64(pieces.count))] }
            if !(try check(dir)) { return }
        }
        // Mostly well-formed declarations, mutated.
        let parts: [[String]] = [["<!ENTITY"], [" ", "\t", "", "  "], ["a", "b", "%", "\u{E9}", "a%"], [" ", "", "\n"],
                                 ["\"v\"", "'v'", "\"v", "'v\"", "SYSTEM 'u'", "PUBLIC \"p\" \"u\"", "SYSTEMx", "\"a>b\""],
                                 ["", " ", "\r"], [">", "", "x>", " >"]]
        for _ in 0..<10_000 {
            var dir: [UInt8] = []
            for _ in 0..<(1 + Int(rng.next() % 4)) {
                for p in parts { dir += Array(p[Int(rng.next() % UInt64(p.count))].utf8) }
                if rng.next() % 4 == 0 { dir += pieces[Int(rng.next() % UInt64(pieces.count))] }
            }
            if !(try check(dir)) { return }
        }
        // Linear where every attempt fails late.
        for (name, unit, tail) in [("SYSTEM without '>'", "<!ENTITY a SYSTEM ", ""), ("quoted without '>'", "<!ENTITY a \"x\" ", ""),
                                   ("no whitespace", "<!ENTITY", ">")] {
            func dir(_ n: Int) -> [UInt8] {
                Array((String(repeating: unit, count: n) + String(repeating: tail, count: n)).utf8)
            }
            #expect(try check(dir(200)), "\(name)")
            let small = dir(10_000)
            let large = dir(40_000)
            let smallTime = try ParityParseRegressionTests.seconds { _ = try Self.scannedDeclarations(small) }
            let largeTime = try ParityParseRegressionTests.seconds { _ = try Self.scannedDeclarations(large) }
            // 4 times the input: linear takes about 4 times as long, quadratic about 16 times.
            #expect(largeTime < 10 * smallTime + 0.5, "\(name): \(smallTime) s, then \(largeTime) s")
        }
    }

    /// TagSoup's passes over one token (a tag name made, lower-cased and looked up; a declaration split; a
    /// reference's digits read) are as long as the token: they count their steps, with the same results.
    @Test func tagSoupTokenPassesStopAtCancellation() throws {
        let name = Array(String(repeating: "Ab-", count: 1 << 16).utf16)
        #expect(Self.isCancellation { _ = try TagSoupParser.makeName(name, Self.cancelled) })
        #expect(Self.isCancellation { _ = try TagSoupJava.lowerRoot(name, Self.cancelled) })
        #expect(Self.isCancellation { _ = try TagSoupJava.lowerRoot(name + [0x130], Self.cancelled) })
        #expect(Self.isCancellation { _ = try TagSoupParser.split(name[...], Self.cancelled) })
        #expect(Self.isCancellation { _ = try TagSoupJava.parseInt([UInt16](repeating: 0x30, count: 1 << 18)[...], 10, Self.cancelled) })
        let never = ParityCancellation { false }
        // Code points as Swift's own UTF-16 decoding finds them: a lone surrogate is U+FFFD.
        for units: [UInt16] in [Array("Ab\u{130}x\u{3A3}".utf16), [0xD800, 0x41], [0xDC00, 0xD800], [0xD83D, 0xDE00, 0xDE00],
                                [0x78, 0xD83D], Array("x\u{1F600}Y".utf16)] {
            #expect(try TagSoupJava.codePoints(units, never) == String(decoding: units, as: UTF16.self).unicodeScalars.map(\.value))
        }
        #expect(try TagSoupJava.lowerRoot(Array("A\u{3A3}".utf16)) == Array("a\u{3C2}".utf16))
        #expect(try TagSoupJava.lowerRoot([0xD800, 0x41]) == [0xFFFD, 0x61])
        #expect(try TagSoupParser.makeName(Array("1a:2b:c".utf16)) == Array("_1a:_2bc".utf16))
        // A long text, name and reference convert as before.
        for (html, text) in [(String(repeating: "x", count: 1 << 18), String(repeating: "x", count: 1 << 18)),
                             ("<" + String(repeating: "a", count: 1 << 18) + ">y", "y"), ("&#" + String(repeating: "0", count: 1 << 18) + "65;", "A"),
                             ("<a b=\"&" + String(repeating: "c", count: 1 << 18) + ";\">z</a>", "z")] {
            #expect(try ParityHTMLText.text(html, compact: true, cancellation: never) == text)
        }
    }

    /// The value functions a handler applies to a text or an attribute (trimming, lower-casing, numbers, durations,
    /// times and MIME types) pass over values as long as the feed's text: they count their steps, with the same
    /// answers.
    @Test func valuesStopAtCancellation() throws {
        let zeros = String(repeating: "0", count: 1 << 18)
        let spaces = String(repeating: " ", count: 1 << 18)
        for (name, body) in [
            ("parseLong", { _ = try ParityValues.javaParseLong(zeros, work: Self.cancelled) }),
            ("parseFloat", { _ = try ParityValues.javaParseFloat(zeros + ".5", work: Self.cancelled) }),
            ("duration", { _ = try ParityValues.durationMillis(zeros + ":" + zeros, work: Self.cancelled) }),
            ("time", { _ = try ParityValues.parseTimeString("1:" + zeros + ".5", work: Self.cancelled) }),
            ("MIME type", { _ = try ParityValues.mimeType(nil, "https://example.com/" + zeros + ".mp3", work: Self.cancelled) }),
            ("trim", { _ = try JavaStrings.trim(spaces + "x" + spaces, work: Self.cancelled) }),
            ("trimAllWhitespace", { _ = try JavaStrings.trimAllWhitespace(spaces + "x", work: Self.cancelled) }),
            ("lowerUS", { _ = try JavaStrings.lowerUS(zeros, work: Self.cancelled) })
        ] as [(String, () throws -> Void)] {
            #expect(Self.isCancellation(body), "\(name)")
        }
        let never = ParityCancellation { false }
        #expect(try ParityValues.javaParseLong(zeros + "12", work: never) == 12)
        #expect(try ParityValues.javaParseLong("-", work: never) == nil && ParityValues.javaParseLong("+7") == 7)
        #expect(try ParityValues.javaParseFloat(" 0x1.8p1f ", work: never) == 3)
        #expect(try ParityValues.durationMillis(zeros + "1:02:03.5", work: never) == 3_723_500)
        #expect(try ParityValues.parseTimeString("01:02:03.250", work: never) == 3_723_250)
        #expect(try ParityValues.javaSplit("a::b::", UInt8(ascii: ":"), work: never) == ["a", "", "b"])
        #expect(try ParityValues.javaSplit("::", UInt8(ascii: ":")) == [] && ParityValues.javaSplit("ab", UInt8(ascii: ":")) == ["ab"])
        #expect(try ParityValues.mimeType(nil, "https://example.com/x/" + zeros + ".MP3", work: never) == "audio/mpeg")
        #expect(try ParityValues.mimeType(nil, "https://example.com/a.b/c", work: never) == nil)
        #expect(try ParityValues.mimeType("audio/x", "https://example.com/a.txt", work: never) == "audio/x")
        #expect(try ParityValues.fileExtension(Array("a.b\\c".utf8)) == [] && ParityValues.fileExtension(Array("a/b.c".utf8)) == Array("c".utf8))
        // Lower-casing can shrink an extension: KELVIN SIGN (three bytes) is "k".
        #expect(ParityValues.mimeTypeFromExtension(Array("M\u{212A}V".utf8)) == ParityValues.mimeTypeFromExtension(Array("mkv".utf8)))
        #expect(ParityValues.mimeTypeFromExtension(Array("\u{212A}".utf8)) == ParityValues.mimeTypeFromExtension(Array("k".utf8)))
        #expect(try JavaStrings.trimAllWhitespace("\u{3000} x\u{A0}\n", work: never) == "x")
        #expect(try JavaStrings.trim("\u{3000} x \u{1}", work: never) == "\u{3000} x")
        #expect(try JavaStrings.lowerUS("\u{130}A", work: never) == "i\u{307}a")
    }

    /// Decoding a document counts its steps in every charset, with the same output.
    @Test func decodingStopsAtCancellation() throws {
        let never = ParityCancellation { false }
        var text: [UInt8] = []
        for i in 0..<(1 << 16) { text += Array((i % 3 == 0 ? "\u{E9}" : i % 3 == 1 ? "\u{1F600}" : "a").utf8) }
        let invalid = text + [0xE2, 0x82] + text
        for (name, bytes) in [("UTF-8", text), ("UTF-8", invalid), ("UTF-8", [0x80] + text), ("UTF-16BE", text),
                              ("UTF-32LE", text), ("windows-1252", text), ("Shift_JIS", text), ("GB18030", text), ("Big5", text)] {
            #expect(try ParityDecode.decodeCharset(bytes[...], name: name, work: never)
                    == ParityDecode.decodeCharset(bytes[...], name: name), "\(name)")
            #expect(Self.isCancellation { _ = try ParityDecode.decodeCharset(bytes[...], name: name, work: Self.cancelled) }, "\(name)")
        }
    }
}

/// A seeded generator for reproducible random cases.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
