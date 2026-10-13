import Darwin
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// The parity parse's cost beside the app's own parser: parse time and peak heap for
/// the largest corpus feed and for a 20,000-item feed, so a refresh's cost while audio plays can be judged. A
/// measurement, not a check; it runs when `NTP_PARITY_MEASURE` is set (best in a release build:
/// `swift test -c release -Xswiftc -enable-testing --filter ParityParseMeasurementTests`).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NTP_PARITY_MEASURE"] != nil))
struct ParityParseMeasurementTests {
    static let now: Int64 = 1_791_227_192_000

    /// A 20,000-item feed as large podcasts publish them: iTunes and Podcasting 2.0 tags, HTML show notes, dates.
    static func largeFeed(items: Int) -> Data {
        var s = """
            <?xml version="1.0" encoding="UTF-8"?>
            <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:podcast="https://podcastindex.org/namespace/1.0" xmlns:atom="http://www.w3.org/2005/Atom">
            <channel><title>A very long-running show</title><link>https://example.com/show</link>
            <atom:link rel="self" type="application/rss+xml" href="https://example.com/feed.xml"/>
            <description>Daily episodes &amp; more.</description><language>en-us</language>
            <itunes:image href="https://example.com/cover.jpg"/><itunes:author>The Hosts</itunes:author>

            """
        let weekdays = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        for i in 0..<items {
            let seconds = 1_000_000_000 + i * 86_400 / 2
            let date = Date(timeIntervalSince1970: Double(seconds))
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            let pubDate = String(format: "%@, %02d %@ %04d %02d:%02d:%02d +0000", weekdays[(seconds / 86_400) % 7], c.day!,
                                 months[c.month! - 1], c.year!, c.hour!, c.minute!, c.second!)
            s += """
                <item><title>Episode \(i): On &lt;things&gt; &amp; other things</title><link>https://example.com/episodes/\(i)</link>
                <guid isPermaLink="false">https://example.com/guid/\(i)</guid><pubDate>\(pubDate)</pubDate>
                <description><![CDATA[<p>In episode \(i) we talk about <b>things</b>, <a href="https://example.com/links/\(i)">links</a> and more.</p><ul><li>One</li><li>Two</li></ul>]]></description>
                <content:encoded><![CDATA[<p>Show notes for episode \(i): <i>everything</i> we mentioned, with <a href="https://example.com/n/\(i)">notes</a>.</p><p>Thanks for listening.</p>]]></content:encoded>
                <enclosure url="https://cdn.example.com/audio/episode-\(i).mp3" length="\(40_000_000 + i)" type="audio/mpeg"/>
                <itunes:duration>01:\(String(format: "%02d", i % 60)):17</itunes:duration><itunes:explicit>false</itunes:explicit>
                <podcast:transcript url="https://example.com/t/\(i).vtt" type="text/vtt"/></item>

                """
        }
        s += "</channel></rss>\n"
        return Data(s.utf8)
    }

    /// The heap in use, all zones.
    static func heapInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    /// The wall time of body and the most its heap grew above where it started, sampled every millisecond.
    static func measure(_ body: () throws -> Void) rethrows -> (seconds: Double, peakBytes: Int) {
        let baseline = heapInUse()
        let peak = Mutex(baseline)
        let running = Mutex(true)
        let sampler = Thread {
            while running.withLock({ $0 }) {
                let now = heapInUse()
                peak.withLock { $0 = max($0, now) }
                usleep(1_000)
            }
        }
        sampler.start()
        let clock = ContinuousClock()
        let start = clock.now
        try body()
        let elapsed = start.duration(to: clock.now)
        let end = heapInUse()
        running.withLock { $0 = false }
        let peakBytes = peak.withLock { max($0, end) } - baseline
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return (seconds, peakBytes)
    }

    static func report(_ label: String, bytes: Int, runs: [(seconds: Double, peakBytes: Int)]) -> String {
        let best = runs.map(\.seconds).min() ?? 0
        let median = runs.map(\.seconds).sorted()[runs.count / 2]
        let peak = runs.map(\.peakBytes).max() ?? 0
        return String(format: "MEASURE %@: %d bytes, best %.1f ms, median %.1f ms, peak heap %.1f MB (%.1fx the document), load %@",
                      label, bytes, best * 1000, median * 1000, Double(peak) / 1_048_576, Double(peak) / Double(bytes),
                      ProcessInfo.processInfo.loadAverageDescription)
    }

    /// The hostile inputs the server found quadratic (its 08f4e05): a 2 MiB run of stray '&' in a document that
    /// declares an entity, a title of 200,000 line breaks then 200,000 empty paragraphs, one tag of 200,000
    /// attributes, 20,000 short descriptions after a 1 MiB one, 200,000 Atom feed authors, and a date after 40,000
    /// "a, " prefixes (quadratic on Android too; it is only stoppable).
    @Test func hostileInputCost() throws {
        func time(_ label: String, _ body: () throws -> String) rethrows {
            let clock = ContinuousClock()
            let start = clock.now
            let outcome = try body()
            let elapsed = start.duration(to: clock.now)
            print(String(format: "MEASURE hostile %@: %.2f s (%@), load %@", label,
                         Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18, outcome,
                         ProcessInfo.processInfo.loadAverageDescription))
        }
        func parse(_ doc: String) -> String {
            do {
                let feed = try ParityFeedParser.parse(Data(doc.utf8), source: "https://example.com/feed.xml", now: Self.now)
                return "title \(feed.title?.utf16.count ?? -1) units, author \(feed.author?.utf8.count ?? -1) bytes, "
                    + "description \(feed.items.first?.description?.utf16.count ?? -1) units"
            } catch {
                return "\(error)"
            }
        }
        let cancellation = ParityCancellation { false }
        // NTP_PARITY_MEASURE=before skips the 2 MiB run, which takes the quadratic scan most of an hour.
        let sizes = ProcessInfo.processInfo.environment["NTP_PARITY_MEASURE"] == "before" ? [256 << 10] : [256 << 10, 2 << 20]
        for size in sizes {
            time("\(size >> 10) KiB of stray '&'") {
                parse("<?xml version=\"1.0\"?><!DOCTYPE rss [<!ENTITY e \"x\">]><rss version=\"2.0\"><channel><title>"
                    + String(repeating: "&", count: size) + "</title></channel></rss>")
            }
        }
        try time("200,000 <br> then 200,000 <p></p>") {
            let html = "x" + String(repeating: "<br>", count: 200_000) + String(repeating: "<p></p>", count: 200_000)
            return "\(try ParityHTMLText.text(html, compact: false, cancellation: cancellation).utf16.count) units"
        }
        try time("one tag of 200,000 attributes") {
            var html = "<font"
            for i in 0..<200_000 { html += " a\(i)=v" }
            html += ">x</font>"
            return "\(try ParityHTMLText.text(html, compact: true, cancellation: cancellation).utf16.count) units"
        }
        time("20,000 short descriptions after a 1 MiB one (non-ASCII)") {
            parse("<rss version=\"2.0\" xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"><channel><title>T</title><item><title>I</title><description>"
                + String(repeating: "\u{E9}", count: 1 << 19) + "</description>"
                + String(repeating: "<itunes:summary>short</itunes:summary>", count: 20_000) + "</item></channel></rss>")
        }
        time("200,000 Atom feed authors") {
            parse("<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>T</title>"
                + String(repeating: "<author><name>a</name></author>", count: 200_000) + "</feed>")
        }
        time("a date after 40,000 \"a, \" prefixes") {
            parse("<rss version=\"2.0\"><channel><title>T</title><item><title>I</title><pubDate>"
                + String(repeating: "a, ", count: 40_000) + "Sat, 09 Oct 2021 10:00:00 +0000</pubDate></item></channel></rss>")
        }
    }

    /// Numeric character references in text and in an attribute, a processing instruction of many "version=",
    /// Atom alternate links, a website head of many links (peak heap), and how long after a deadline a parse
    /// returns for one large token, a long date, a long entity declaration and one large website tag.
    /// NTP_PARITY_MEASURE=before (for the code before the fixes) skips the 4.4 MB alternates and the inputs added
    /// with the fixes: one XML tag of many attributes, 60 MiB values and HTML, and many "<!ENTITY" without their
    /// whitespace.
    @Test func referenceAndTagInputCost() throws {
        let rss = "<rss version=\"2.0\"><channel><title>t</title>"
        let end = "</channel></rss>"
        func fill(_ unit: String, _ size: Int, _ pre: String, _ post: String) -> String {
            pre + String(repeating: unit, count: max(1, (size - pre.utf8.count - post.utf8.count) / unit.utf8.count)) + post
        }
        func outcome(_ body: () throws -> ParityFeed) -> String {
            do {
                let feed = try body()
                return "feed, \(feed.items.count) items"
            } catch {
                return "\(error)"
            }
        }
        func parse(_ doc: String, isCancelled: () -> Bool = { false }) -> String {
            outcome { try ParityFeedParser.parse(Data(doc.utf8), source: "https://example.com/feed.xml", now: Self.now, isCancelled: isCancelled) }
        }
        func time(_ label: String, bytes: Int, _ body: () -> String) {
            var result = ""
            let run = Self.measure { result = body() }
            print(String(format: "MEASURE %@ (%d bytes): %.2f s, peak heap %.1f MB, %@, load %@", label, bytes, run.seconds,
                         Double(run.peakBytes) / 1_048_576, result, ProcessInfo.processInfo.loadAverageDescription))
        }
        /// How long after a deadline `after` the start the parse returned, and what it returned.
        func deadline(_ label: String, _ doc: String, after: Duration) {
            let clock = ContinuousClock()
            let start = clock.now
            let result = parse(doc) { clock.now - start > after }
            let late = (clock.now - start) - after
            print(String(format: "MEASURE deadline %@ (%d bytes, deadline %@): returned %@ after the deadline, %@, load %@", label,
                         doc.utf8.count, "\(after)", "\(late)", result, ProcessInfo.processInfo.loadAverageDescription))
        }
        let before = ProcessInfo.processInfo.environment["NTP_PARITY_MEASURE"] == "before"
        for size in [1 << 20, 4 << 20] {
            let text = fill("&#8217;", size, rss + "<item><title>i</title><description>", "</description></item>" + end)
            time("numeric references in text, \(size >> 20) MiB", bytes: text.utf8.count) { parse(text) }
            let attribute = fill("&#38;", size, rss + "<item><title>i</title><enclosure url=\"", "\"/></item>" + end)
            time("numeric references in an attribute, \(size >> 20) MiB", bytes: attribute.utf8.count) { parse(attribute) }
            let pi = fill("version=x", size, rss + "<?xml ", "?>" + end)
            time("processing instruction of many version=, \(size >> 20) MiB", bytes: pi.utf8.count) { parse(pi) }
        }
        for size in before ? [1 << 20] : [1 << 20, 4_400_000] {
            var atom = "<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>t</title>"
            for i in 0..<(size / 92) {
                atom += "<link rel=\"alternate\" type=\"application/rss+xml\" href=\"https://example.com/feeds/" + String(format: "%08d", i) + ".xml\"/>"
            }
            atom += "</feed>"
            time("Atom alternate links, \(size) bytes", bytes: atom.utf8.count) { parse(atom) }
        }
        let website = fill("<link a>", 16 << 20, "<html><head><title>x</title>", "</head></html>")
        time("website head of many links, 16 MiB", bytes: website.utf8.count) { parse(website) }
        deadline("one 16 MiB description", rss + "<item><title>i</title><description>" + String(repeating: "x", count: 16 << 20)
                 + "</description></item>" + end, after: .milliseconds(20))
        deadline("4 MiB of numeric references", fill("&#8217;", 4 << 20, rss + "<item><title>i</title><description>",
                 "</description></item>" + end), after: .seconds(1))
        deadline("a 16 MiB numeric date", rss + "<item><title>i</title><pubDate>" + String(repeating: "1", count: 16 << 20)
                 + "</pubDate></item>" + end, after: .milliseconds(100))
        deadline("a 10 MiB entity declaration", "<!DOCTYPE rss [<!ENTITY e \"" + String(repeating: "&#65;", count: 2 << 20)
                 + "\">]><rss><channel><title>T</title></channel></rss>", after: .milliseconds(300))
        var tag = "<html><head><link rel=\"alternate\" type=\"application/rss+xml\" href=\"/f\""
        for i in 0..<1_000_000 { tag += " a\(i)=v" }
        tag += "></head></html>"
        deadline("one website tag of 1,000,000 attributes", tag, after: .milliseconds(100))
        guard !before else { return }
        var element = rss + "<x"
        for i in 0..<1_000_000 { element += " a\(i)=\"v\"" }
        element += "/>" + end
        deadline("one XML tag of 1,000,000 attributes", element, after: .milliseconds(100))
        deadline("a 60 MiB itunes:duration", "<rss version=\"2.0\" xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"><channel>"
                 + "<title>t</title><item><title>i</title><itunes:duration>" + String(repeating: "1", count: 60 << 20)
                 + "</itunes:duration></item>" + end, after: .milliseconds(100))
        deadline("a 60 MiB enclosure length", rss + "<item><title>i</title><enclosure url=\"https://example.com/a.mp3\" length=\""
                 + String(repeating: "1", count: 60 << 20) + "\"/></item>" + end, after: .milliseconds(100))
        deadline("a 60 MiB HTML title", "<rss version=\"2.0\"><channel><title>" + String(repeating: "&lt;b&gt;x", count: 6 << 20)
                 + "</title>" + end, after: .milliseconds(500))
        let declarations = "<!DOCTYPE rss [" + String(repeating: "<!ENTITY", count: 1 << 19) + String(repeating: ">", count: 1 << 19)
            + "]><rss version=\"2.0\"><channel><title>T</title></channel></rss>"
        time("4.5 MiB of \"<!ENTITY\" then '>'", bytes: declarations.utf8.count) { parse(declarations) }
    }

    /// Hostile inputs of a second kind: a long namespace URI for many elements or prefixed attributes, a run of
    /// '&' with a long declared entity name and runs with names of many lengths, many attributes after a long
    /// value or text (peak heap), and how late a parse returns after a 200 ms deadline.
    @Test func secondKindInputCost() throws {
        let itunes = " xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\""
        func attributes(_ prefix: String, _ count: Int) -> String { (0..<count).map { " \(prefix)a\($0)=\"\"" }.joined() }
        func u(_ n: Int) -> String { String(repeating: "u", count: n) }
        let shapes: [String: (Int, Int) -> String] = [
            "ns-uri-elements": { n, m in "<rss version=\"2.0\"" + itunes + " xmlns:p=\"" + u(n) + "\"><channel><title>t</title>"
                + String(repeating: "<p:a/>", count: m) + "</channel></rss>" },
            "ns-uri-default": { n, m in "<rss version=\"2.0\"" + itunes + "><channel><title>t</title><x xmlns=\"" + u(n) + "\">"
                + String(repeating: "<a/>", count: m) + "</x></channel></rss>" },
            "ns-uri-attributes": { n, m in "<rss version=\"2.0\"" + itunes + " xmlns:p=\"" + u(n) + "\"><channel><title>t</title><x"
                + attributes("p:", m) + "/></channel></rss>" },
            "amp-run": { n, m in "<!DOCTYPE rss [<!ENTITY " + String(repeating: "e", count: n) + " \"v\">]><rss version=\"2.0\"><channel>"
                + "<title>t</title><description>" + String(repeating: "&", count: m) + ";</description></channel></rss>" },
            "attrs-after-value": { n, m in "<rss version=\"2.0\"><channel><title>t</title><x z=\"" + u(n) + "\"" + attributes("", m)
                + "/></channel></rss>" },
            "attrs-after-text": { n, m in "<rss version=\"2.0\"><channel><title>t</title><description>" + u(n) + "</description><x"
                + attributes("", m) + "/></channel></rss>" },
            // Names of every length in [w/2, w) and runs of w '&' repeated to n bytes (the server's 6ec5517).
            "many-lengths": { n, _ in
                var w = 2
                while 3 * w * w / 8 < n / 2 { w += 1 }
                var doc = "<!DOCTYPE rss ["
                for length in (w / 2)..<w { doc += "<!ENTITY " + String(repeating: "n", count: length) + " \"v\">" }
                doc += "]><rss version=\"2.0\"><channel><title>t</title><description>"
                let runs = max(0, (n - w - doc.utf8.count) / (w + 1))
                return doc + String(repeating: String(repeating: "&", count: w) + ";", count: runs) + "</description></channel></rss>"
            }
        ]
        func parse(_ doc: String, isCancelled: () -> Bool = { false }) -> String {
            do {
                return "feed \(try ParityFeedParser.parse(Data(doc.utf8), source: "https://example.com/feed.xml", now: Self.now, isCancelled: isCancelled).title ?? "")"
            } catch {
                return "\(error)"
            }
        }
        for (shape, n, m) in [("ns-uri-elements", 64 << 10, 20_000), ("ns-uri-elements", 64 << 10, 40_000),
                              ("ns-uri-default", 64 << 10, 20_000), ("ns-uri-attributes", 64 << 10, 10_000),
                              ("amp-run", 64 << 10, 64 << 10), ("attrs-after-value", 64 << 10, 20_000),
                              ("attrs-after-value", 1 << 20, 20_000), ("attrs-after-text", 1 << 20, 20_000),
                              ("attrs-after-text", 4 << 20, 20_000), ("many-lengths", 8 << 20, 0), ("many-lengths", 32 << 20, 0)] {
            let doc = shapes[shape]!(n, m)
            var result = ""
            let run = Self.measure { result = parse(doc) }
            print(String(format: "MEASURE second kind %@ N=%d M=%d (%d bytes): %.3f s, peak heap %.1f MB, %@, load %@", shape, n, m,
                         doc.utf8.count, run.seconds, Double(run.peakBytes) / 1_048_576, result,
                         ProcessInfo.processInfo.loadAverageDescription))
        }
        for (shape, n, m) in [("ns-uri-elements", 1 << 20, 4_000), ("ns-uri-attributes", 1 << 20, 12_000), ("amp-run", 4 << 20, 4 << 20)] {
            let doc = shapes[shape]!(n, m)
            let clock = ContinuousClock()
            let start = clock.now
            let after = Duration.milliseconds(200)
            let result = parse(doc) { clock.now - start > after }
            print(String(format: "MEASURE second kind deadline %@ N=%d M=%d (%d bytes, deadline 0.2 s): returned %@ after the deadline, %@, load %@",
                         shape, n, m, doc.utf8.count, "\((clock.now - start) - after)", result, ProcessInfo.processInfo.loadAverageDescription))
        }
    }

    @Test func parseCost() throws {
        func corpus(_ file: String) throws -> Data {
            try Data(contentsOf: ParityFeedVectorTests.vectors.appendingPathComponent("feeds/" + file))
        }
        // The largest corpus file is a feed without a title, which Android refuses only after parsing all of it.
        let inputs: [(String, Data)] = [("largest corpus file (ios-large-feed.xml)", try corpus("ios-large-feed.xml")),
                                        ("largest corpus feed that parses (gen-1635.xml)", try corpus("gen-1635.xml")),
                                        ("20,000-item feed", Self.largeFeed(items: 20_000))]
        for (name, data) in inputs {
            var parity: [(seconds: Double, peakBytes: Int)] = []
            var app: [(seconds: Double, peakBytes: Int)] = []
            var outcome = ("", "")
            for _ in 0..<5 {
                parity.append(Self.measure {
                    do {
                        outcome.0 = "\(try ParityFeedParser.parse(data, source: "https://example.com/feed.xml", now: Self.now).items.count) items"
                    } catch {
                        outcome.0 = "\(error)"
                    }
                })
                app.append(Self.measure {
                    do {
                        outcome.1 = "\(try FeedParser().parse(data, now: Date(timeIntervalSince1970: Double(Self.now) / 1000)).episodes.count) items"
                    } catch {
                        outcome.1 = "\(error)"
                    }
                })
            }
            print(Self.report("parity parse, \(name), \(outcome.0)", bytes: data.count, runs: parity))
            print(Self.report("app parser, \(name), \(outcome.1)", bytes: data.count, runs: app))
        }
    }
}
