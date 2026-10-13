import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// The parity parse beyond the shared vectors: ports of the server's unit tests for hostile input, budgets,
/// cancellation, dates and HTML to text (`internal/feed/*_test.go`), the catalog record values and occurrence a
/// phone observes (PROTOCOL §9.4), and the first-item rule for repeated items (PROTOCOL §9).
struct ParityFeedParserTests {
    static let now: Int64 = 1_791_227_192_000

    static func parse(_ doc: String, isCancelled: () -> Bool = { false }) throws -> ParityFeed {
        try ParityFeedParser.parse(Data(doc.utf8), source: "https://feeds.example.invalid/hostile.xml", now: now,
                                   isCancelled: isCancelled)
    }

    static func isParserException(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            return false
        } catch let error as ParityParseError {
            return error.label == "parser_exception"
        } catch {
            return false
        }
    }

    /// A cancellation answer that turns true after `checks` questions, and counts them.
    final class CancelAfter: Sendable {
        let remaining: Mutex<Int>
        init(_ checks: Int) { remaining = Mutex(checks) }
        func ask() -> Bool { remaining.withLock { $0 -= 1; return $0 < 0 } }
        var left: Int { remaining.withLock { $0 } }
    }

    // MARK: hostile_test.go

    /// An unused entity is never expanded, however large it would be (Expat expands only at use); used, it is over
    /// the budget before any text is built.
    @Test func anUnusedEntityIsNotExpanded() throws {
        let doc = "<!DOCTYPE rss [<!ENTITY a \"" + String(repeating: "x", count: 64 << 10) + "\"><!ENTITY b \""
            + String(repeating: "&a;", count: 1024) + "\"><!ENTITY u \"&undefined;\">]><rss><channel><title>ok</title></channel></rss>"
        #expect(try Self.parse(doc).title == "ok")
        let used = doc.replacingOccurrences(of: "<title>ok</title>", with: "<title>&b;</title>")
        #expect(Self.isParserException { _ = try Self.parse(used) })
    }

    /// An entity's replacement text is content: its markup makes elements, as in Expat; markup in an attribute value
    /// is malformed.
    @Test func entityMarkupIsContent() throws {
        let feed = try Self.parse("<!DOCTYPE rss [<!ENTITY e \"<item><title>Episode</title></item>\">]><rss><channel><title>Feed</title>&e;</channel></rss>")
        #expect(feed.items.map(\.title) == ["Episode"])
        #expect(throws: ParityParseError.self) {
            try Self.parse("<!DOCTYPE rss [<!ENTITY e \"<b>\">]><rss x=\"&e;\"><channel><title>Feed</title></channel></rss>")
        }
    }

    /// A non-ASCII letter whose lower case is longer does not move offsets in the website scan.
    @Test func websiteWithUnicodeCase() {
        let doc = "<html><head><script data-x=\"" + String(repeating: "\u{212A}", count: 100) + "\"></script><title>T</title></head></html>"
        #expect(throws: ParityParseError(label: "unsupported_type_html", detail: "Website title: \"T\"")) { try Self.parse(doc) }
    }

    /// Thousands of raw-text elements are scanned in linear time, and a cancelled parse stops the scan.
    @Test func websiteScanIsLinearAndCancellable() throws {
        let doc = "<html><head>" + String(repeating: "<SCRIPT></SCRIPT>", count: 12_000) + "</head></html>"
        let start = ContinuousClock.now
        #expect(throws: ParityParseError.self) { try Self.parse(doc) }
        #expect(start.duration(to: .now) < .seconds(10))
        #expect(throws: CancellationError.self) { try Self.parse(doc, isCancelled: { true }) }
    }

    /// Expat's namespace constraints.
    @Test func namespaceConstraints() {
        for doc in [
            "<rss xmlns:a=\"urn:x\" xmlns:b=\"urn:x\" a:x=\"1\" b:x=\"2\"><channel><title>Feed</title></channel></rss>",
            "<rss xmlns:xml=\"urn:wrong\"><channel><title>Feed</title></channel></rss>",
            "<rss xmlns:p=\"http://www.w3.org/XML/1998/namespace\"><channel><title>Feed</title></channel></rss>",
            "<rss xmlns:p=\"\"><channel><title>Feed</title></channel></rss>"
        ] {
            #expect(Self.isParserException { _ = try Self.parse(doc) }, "\(doc)")
        }
    }

    // MARK: budget_test.go

    static func entities(size: Int, uses: Int, pad: Int) -> String {
        "<?xml version=\"1.0\"?><!DOCTYPE rss [<!ENTITY big \"" + String(repeating: "x", count: size) + "\">]>"
            + "<!--" + String(repeating: "p", count: pad) + "--><rss version=\"2.0\"><channel><title>"
            + String(repeating: "&big;", count: uses) + "</title></channel></rss>"
    }

    @Test func entityBudgets() throws {
        // Nested entities expand as Expat does.
        let nested = try Self.parse("<?xml version=\"1.0\"?><!DOCTYPE rss [<!ENTITY b \"x&#65;\"><!ENTITY a \"&b;&b;&amp;\">]>"
            + "<rss version=\"2.0\"><channel><title>&a;</title></channel></rss>")
        #expect(nested.title == "xAxA&")
        for doc in [
            "<!DOCTYPE rss [<!ENTITY a \"&b;\"><!ENTITY b \"&a;\">]><rss version=\"2.0\"><channel><title>&a;</title></channel></rss>",
            "<!DOCTYPE rss [<!ENTITY a \"&nope;\">]><rss version=\"2.0\"><channel><title>&a;</title></channel></rss>"
        ] {
            #expect(Self.isParserException { _ = try Self.parse(doc) }, "a recursive or undefined entity")
        }
        // 1 MiB of expansions from a small document: within both limits.
        #expect(try Self.parse(Self.entities(size: 1024, uses: 1024, pad: 0)).title?.utf8.count == 1 << 20)
        // Over Expat's amplification limit (Android refuses it too): 9 MiB from 9 KiB.
        #expect(Self.isParserException { _ = try Self.parse(Self.entities(size: 9 * 1024, uses: 1024, pad: 0)) })
        // Below Expat's limit (amplification under 100 thanks to 200 KiB of input) but over the 16 MiB budget.
        #expect(Self.isParserException { _ = try Self.parse(Self.entities(size: 64 * 1024, uses: 260, pad: 200 * 1024)) })
    }

    @Test func structureBudgets() throws {
        func nested(_ depth: Int) -> String {
            "<rss version=\"2.0\"><channel><title>t</title>" + String(repeating: "<x>", count: depth - 2)
                + String(repeating: "</x>", count: depth - 2) + "</channel></rss>"
        }
        // The server's budgets: 256 levels and 100,000 items.
        #expect(throws: Never.self) { try Self.parse(nested(256)) }
        #expect(Self.isParserException { _ = try Self.parse(nested(257)) })
        func items(_ n: Int) -> String {
            "<rss version=\"2.0\"><channel><title>t</title>" + String(repeating: "<item><title>i</title></item>", count: n)
                + "</channel></rss>"
        }
        #expect(try Self.parse(items(100_000)).items.count == 100_000)
        #expect(Self.isParserException { _ = try Self.parse(items(100_001)) })
    }

    /// Cancellation stops a parse midway (the fetch deadline covers parsing).
    @Test func cancellationStopsAParse() {
        let doc = "<rss version=\"2.0\"><channel><title>t</title>" + String(repeating: "<item><title>i</title></item>", count: 10_000)
            + "</channel></rss>"
        let cancel = CancelAfter(3)
        #expect(throws: CancellationError.self) { try Self.parse(doc, isCancelled: cancel.ask) }
        #expect(cancel.left < 0, "the parse never asked")
    }

    /// The HTML conversion of a title stops at cancellation too: TagSoup needs quadratic time for some inputs.
    @Test func cancellationStopsTheHTMLConversion() {
        let title = String(repeating: "</b>", count: 50_000)
        let cancel = CancelAfter(1)  // the conversion's first check passes
        #expect(throws: CancellationError.self) {
            try ParityHTMLText.text(title, compact: true, cancellation: ParityCancellation(isCancelled: cancel.ask))
        }
        // And within a parse: every check a parse of a one-letter title makes passes.
        let doc = "<rss version=\"2.0\"><channel><title>TITLE</title></channel></rss>"
        let hostile = doc.replacingOccurrences(of: "TITLE", with: String(repeating: "&lt;/b&gt;", count: 50_000))
        let checks = CancelAfter(Int.max)
        _ = try? Self.parse(doc.replacingOccurrences(of: "TITLE", with: "x"), isCancelled: checks.ask)
        let afterPlain = CancelAfter(Int.max - checks.left)
        #expect(throws: CancellationError.self) { try Self.parse(hostile, isCancelled: afterPlain.ask) }
    }

    // MARK: security_audit_test.go

    /// A namespace declared in a child can make its parent handled at only one of its ends: a parse error, never a
    /// crash. An element handled at both ends by different handlers keeps Android's result.
    @Test func anUnpairedEndTagIsAParseError() throws {
        for doc in [
            "<feed><x:outer xmlns:x=\"http://www.w3.org/2005/Atom\"><atom:inner xmlns:atom=\"http://www.w3.org/2005/Atom\"/></x:outer></feed>",
            "<rss version=\"2.0\"><channel><title>T</title><i:x xmlns:i=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"><itunes:y xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"/></i:x></channel></rss>"
        ] {
            #expect(Self.isParserException { _ = try Self.parse(doc) }, "\(doc)")
        }
        let feed = try Self.parse("<rss version=\"2.0\"><channel><title>T</title><item><title>I</title>"
            + "<content xmlns=\"http://www.w3.org/2005/Atom\" type=\"xhtml\"><div xmlns=\"http://www.w3.org/1999/xhtml\">x</div></content>"
            + "</item></channel></rss>")
        #expect(feed.items.map(\.title) == ["I"])
    }

    /// Entity expansions built along the way are charged to the 16 MiB budget too.
    @Test func nestedEntityExpansionsAreCharged() throws {
        var doc = "<!DOCTYPE rss [<!ENTITY e0 \"" + String(repeating: "x", count: 512 << 10) + "\">"
        for i in 1...63 { doc += "<!ENTITY e\(i) \"x&e\(i - 1);\">" }
        doc += "]><rss version=\"2.0\"><channel><title>Feed</title><description>&e63;</description></channel></rss>"
        #expect(Self.isParserException { _ = try Self.parse(doc) })
        let short = try Self.parse("<!DOCTYPE rss [<!ENTITY a \"x\"><!ENTITY b \"&a;&a;\"><!ENTITY c \"&b;&b;\">]>"
            + "<rss version=\"2.0\"><channel><title>&c;</title></channel></rss>")
        #expect(short.title == "xxxx")
    }

    // MARK: values_test.go and htmltext_test.go

    /// DateUtils.parseOrNullIfFuture drops a date after now, with now injected.
    @Test func futureDateBoundary() throws {
        let s = "Thu, 01 Jan 2026 00:00:00 +0000"
        let at: Int64 = 1_767_225_600_000
        #expect(try ParityDates.parse(s, now: at) == at)
        #expect(try ParityDates.parseOrNullIfFuture(s, now: at - 1) == nil)
        #expect(try ParityDates.parseOrNullIfFuture(s, now: at) == at)
        #expect(try ParityDates.parseOrNullIfFuture(s, now: at + 1) == at)
    }

    /// What the vectors leave out, with the server's answers: a two-digit year equal to the century window's start
    /// year (now minus 80 years) falls in the next century when the date lies before the window; "yyyy" takes two
    /// digits as they are; a leading weekday is dropped again and again.
    @Test func twoDigitYearsAndRepeatedWeekdays() throws {
        let cases: [(Int64, String, Int64)] = [
            (1_791_227_192_000, "01 Jan 46 00:00:00 +0000", 2_398_377_600_000),
            (1_791_227_192_000, "09 Oct 46 12:00:00 +0000", -733_060_800_000),
            (1_791_227_192_000, "09 Oct 46 12:00:00 GMT", -733_060_800_000),
            (1_791_227_192_000, "Sat, 09 Oct 99 10:00:00 EST", -59_018_835_838_000),
            (1_791_227_192_000, "Thu, 01 Jan 70 00:00:00 +0000", -59_958_316_800_000),
            (1_791_227_192_000, "01 Jan 26 00:00:00 +0000", 1_767_225_600_000),
            (946_684_800_000, "01 Jan 46 00:00:00 +0000", -757_382_400_000),
            (946_684_800_000, "01 Jan 26 00:00:00 +0000", -1_388_534_400_000),
            (1_791_227_192_000, "a, a, a, Sat, 09 Oct 2021 10:00:00 +0000", 1_633_773_600_000),
            (1_791_227_192_000, "Mon, Tue, 09 Oct 2021 10:00:00 +0000", 1_633_773_600_000)
        ]
        for (now, input, output) in cases {
            #expect(try ParityDates.parse(input, now: now) == output, "\(input) at \(now)")
        }
    }

    /// Many leading "word, " prefixes take the date parse quadratic time, on the server too (a 120 KB date takes it
    /// about 30 s); the parity parse can be cancelled in it.
    @Test func aHostileDateCanBeCancelled() {
        let date = String(repeating: "a, ", count: 20_000) + "Sat, 09 Oct 2021 10:00:00 +0000"
        let doc = "<rss version=\"2.0\"><channel><title>t</title><item><title>i</title><pubDate>" + date + "</pubDate></item></channel></rss>"
        let cancel = CancelAfter(10)
        let start = ContinuousClock.now
        #expect(throws: CancellationError.self) { try Self.parse(doc, isCancelled: cancel.ask) }
        #expect(start.duration(to: .now) < .seconds(10))
    }

    /// Windows-1252 reaches text through TagSoup's map of U+0080–U+009F, not the decoder: in an ISO-8859-1 feed a
    /// title shows "€" where a GUID keeps U+0080 (the server's answers).
    @Test func windows1252ThroughTagSoup() throws {
        let cancellation = ParityCancellation { false }
        #expect(try ParityHTMLText.text("\u{80}\u{81}\u{99} &#128; &#x9f;", compact: true, cancellation: cancellation) == "\u{20AC}\u{FFFD}\u{2122} \u{20AC} \u{178}")
        #expect(try ParityHTMLText.text("a\u{85}b", compact: true, cancellation: cancellation) == "a\u{2026}b")
        #expect(try ParityHTMLText.text("<b>x</b>\u{80}", compact: true, cancellation: cancellation) == "x\u{20AC}")
        let doc = Array("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><rss version=\"2.0\"><channel><title>A".utf8) + [0x80, 0x99]
            + Array("</title><item><title>B</title><guid>g".utf8) + [0x80] + Array("</guid></item></channel></rss>".utf8)
        let feed = try ParityFeedParser.parse(Data(doc), source: "https://x.invalid/f", now: Self.now)
        #expect(feed.title == "A\u{20AC}\u{2122}")
        #expect(feed.items.first?.guid?.unicodeScalars.map(\.value) == [0x67, 0x80])
    }

    /// A title nested hundreds of thousands of elements deep that then throws (a font with color "-") fails the parse
    /// cleanly, its whole element chain released.
    @Test func aDeeplyNestedTitleThatThrowsFailsCleanly() {
        let title = String(repeating: "&lt;b&gt;", count: 200_000) + "&lt;font color=\"-\"&gt;x"
        let doc = "<rss version=\"2.0\"><channel><title>" + title + "</title></channel></rss>"
        #expect(Self.isParserException { _ = try Self.parse(doc) })
    }

    /// The inputs on which Html.fromHtml throws, and near misses that do not.
    @Test func htmlThrows() throws {
        let cancellation = ParityCancellation { false }
        for input in ["<font color=\"-\">x</font>", "<font color=&#45;>x", "<!DOCTYPE html\u{3000}>", "<!x \u{2028}>",
                      "<!DOCTYPE html SYSTEM '>", "<!doctype html PUBLIC \"a\" \">", "<!DOCTYPE html PUBLIC '>"] {
            #expect(throws: ParityParseError.parserException, "\(input)") {
                try ParityHTMLText.text(input, compact: true, cancellation: cancellation)
            }
        }
        let fine = ["<font color=\"-1\">x</font>": "x", "<font color=\"\">x</font>": "x", "<!DOCTYPE html>x": "x",
                    "<!x '\u{2028}'>x": "x", "<!DOCTYPE html SYSTEM ''>x": "x", "<!DOCTYPE html system '>x": "x",
                    "<!DOCTYPE html><!DOCTYPE html SYSTEM '>x": "x", "<!DOCTYPE html PUBLIC \"a\" \"b\" '>x": "x"]
        for (input, output) in fine {
            #expect(try ParityHTMLText.text(input, compact: false, cancellation: cancellation) == output, "\(input)")
        }
        // A title that throws fails the feed's parse, as Android's does.
        #expect(Self.isParserException {
            _ = try Self.parse("<rss version=\"2.0\"><channel><title>&lt;font color=\"-\"&gt;x</title></channel></rss>")
        })
        // Script and style are CDATA: an end tag for another element inside is text.
        #expect(try ParityHTMLText.text("<script>a</b>c</script>d", compact: true, cancellation: cancellation) == "a</b>cd")
    }

    // MARK: Records (PROTOCOL §9.4)

    static let recordFeed = """
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:podcast="https://podcastindex.org/namespace/1.0" xmlns:psc="http://podlove.org/simple-chapters">
        <channel><title>Show &amp; Tell</title><link>https://user:pw@example.com/show</link><description>About https://u:p@example.com/x</description>
        <language>EN-us</language><itunes:image href="https://img:secret@example.com/cover.jpg"/><podcast:funding url="https://a:b@example.com/pay">Support</podcast:funding>
        <item><title>One</title><guid> https://g:h@example.com/e/1 </guid><pubDate>Mon, 02 Mar 2026 10:00:00 +0000</pubDate>
        <enclosure url="https://user:secret@cdn.example.com/one.mp3?x=1" type="audio/mpeg" length="20000"/><itunes:duration>1:02:03</itunes:duration>
        <psc:chapters><psc:chapter start="00:00:01.5" title="Intro" href="https://c:d@example.com/c"/></psc:chapters>
        <podcast:transcript url="https://t:u@example.com/t.vtt" type="text/vtt"/></item>
        <item><title>Two</title><enclosure url="HTTPS://CDN.example.com:443/two.mp3#t=1" type="audio/mpeg"/></item>
        <item><description>Three</description></item>
        </channel></rss>
        """

    @Test func recordFieldsAndOccurrence() throws {
        let feed = try ParityFeedParser.parse(Data(Self.recordFeed.utf8), source: "https://feeds.example.com/show.xml", now: Self.now)
        let podcast = feed.podcastFields
        #expect(podcast.names.sorted() == ["author", "description", "funding", "image_url", "language", "link", "next_page_url",
                                           "paged", "title", "type"])
        #expect(podcast["title"] == "Show & Tell")
        #expect(podcast["link"] == "https://example.com/show")
        #expect(podcast["description"] == "About https://example.com/x")
        #expect(podcast["language"] == "en-us")
        #expect(podcast["image_url"] == "https://example.com/cover.jpg")
        #expect(podcast["funding"] == [["url": "https://example.com/pay", "content": "Support"]])
        #expect(podcast["type"] == "rss" && podcast["paged"] == false && podcast["next_page_url"] == .null && podcast["author"] == .null)

        let one = feed.items[0].episodeFields
        #expect(one.names.sorted() == ["chapter_url", "chapters", "description", "image_url", "link", "media", "payment_link",
                                       "pub_date", "social_interact_url", "title", "transcript_type", "transcript_url"])
        #expect(one["media"] == ["url": "https://cdn.example.com/one.mp3?x=1", "size": "20000", "mime_type": "audio/mpeg",
                                 "duration": 3_723_000])
        #expect(one["pub_date"] == .integer(1_772_445_600_000))
        #expect(one["chapters"] == [["start": "1500", "title": "Intro", "link": "https://example.com/c", "image_url": .null]])
        #expect(one["transcript_url"] == "https://example.com/t.vtt" && one["transcript_type"] == "text/vtt")
        #expect(feed.items[1].episodeFields["media"]?["size"] == "0")  // under 16 KiB is suspicious

        #expect(feed.items[0].occurrence(feedType: feed.type) == [
            "guid": "https://example.com/e/1", "enclosure_url": "https://cdn.example.com/one.mp3?x=1",
            "publication_time": .integer(1_772_445_600_000), "title": "One", "k": "rss-guid", "v": "https://example.com/e/1"
        ])
        #expect(feed.items[1].occurrence(feedType: feed.type) == [
            "enclosure_url": "HTTPS://CDN.example.com:443/two.mp3#t=1", "title": "Two", "k": "enclosure",
            "v": "https://cdn.example.com/two.mp3"
        ])
        // The description stands in for a missing title; without GUID and enclosure there is no derivation.
        #expect(feed.items[2].occurrence(feedType: feed.type) == ["title": "Three"])
        #expect(feed.items[0].occurrence(feedType: "atom")["k"] == "atom-id")
    }

    /// The server's rule for repeated items in one fetch, on the shared fixture's case
    /// (rules_releases.json, repeated items in one fetch, the first kept): the first item per
    /// derived episode ID is kept, and its record and occurrence are the first item's.
    @Test func repeatedItemsKeepTheFirst() throws {
        let namespace = "b0000000-0000-4000-8000-000000000002"
        let podcast = "p1:6e6fbb14979439af2a2896345edceae2f6d6292e569a52d3c3f2559991873451"
        let feed = try ParityFeedParser.parse(Data("""
            <rss version="2.0"><channel><title>Show</title>
            <item><title>First</title><guid>dup</guid><pubDate>Thu, 09 Oct 2025 08:53:20 +0000</pubDate><enclosure url="https://cdn.example.com/dup.mp3?ad=1" type="audio/mpeg" length="1000"/></item>
            <item><title>Second</title><guid>dup</guid><pubDate>Fri, 10 Oct 2025 08:53:20 +0000</pubDate><enclosure url="https://cdn.example.com/dup.mp3?ad=2" type="audio/mpeg" length="1000"/></item>
            <item><title>Third</title></item>
            <item><title>Fourth</title></item>
            </channel></rss>
            """.utf8), source: "https://feeds.example.com/one.xml", now: Self.now)
        let kept = try FetchEpisodeIdentity.firstPerEpisode(feed, namespace: namespace, podcastID: podcast)
        #expect(kept.map(\.title) == ["First", "Third", "Fourth"])
        let id = try FetchEpisodeIdentity.plainEpisodeID(namespace: namespace, podcastID: podcast, item: kept[0], feedType: feed.type)
        #expect(id == "e1:8a12c96b4b29a145707f036eb17040fae3f6aecc312d0bbaabb6e36c3a51b6f7")
        #expect(kept[0].occurrence(feedType: feed.type) == [
            "enclosure_url": "https://cdn.example.com/dup.mp3?ad=1", "guid": "dup", "k": "rss-guid",
            "publication_time": 1_760_000_000_000, "title": "First", "v": "dup"
        ])
        #expect(kept[0].episodeFields["media"]?["url"] == "https://cdn.example.com/dup.mp3?ad=1")
    }

    /// The parse in the vectors' schema keeps alternate feed URLs exactly (no Unicode canonical equivalence) and the
    /// null key.
    @Test func alternateFeedsAreKeptByExactURL() throws {
        let feed = try Self.parse("""
            <feed xmlns="http://www.w3.org/2005/Atom"><title>F</title>
            <link rel="alternate" type="application/rss+xml" href="https://example.com/\u{E9}" title="composed"/>
            <link rel="alternate" type="application/rss+xml" href="https://example.com/e\u{301}" title="decomposed"/>
            <link rel="alternate" type="application/rss+xml" href="https://example.com/\u{E9}" title="again"/>
            <link rel="archives" type="application/atom+xml" title="no href"/>
            </feed>
            """)
        #expect(feed.alternateURLs.map(\.title) == ["again", "decomposed"])
        #expect(feed.hasAlternateNull && feed.alternateNull == "no href")
        #expect(feed.vectorObject["alternate_feed_urls"]?.objectValue?.count == 2)
        #expect(feed.imageURL == "antennapod_generative_cover:https://feeds.example.invalid/hostile.xml")
    }
}
