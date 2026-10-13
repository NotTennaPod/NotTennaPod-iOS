import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Malformed, truncated and hostile feed documents never crash or stall a
/// refresh, and the person sees the message Android 3.12.1 shows for the same document.
///
/// Expected results come from Android's own code, not from the Swift parser: an independent oracle
/// runs the unchanged TypeGetter (kxml2, jsoup, commons-io XmlStreamReader) and the SAX pass of FeedHandler over
/// every document and maps the outcome as FeedParserTask does. Its output is
/// `Fixtures/HostileFeeds/expected/android.jsonl` (named documents) and `.../mutations.jsonl` (the seeded
/// corpus below; set GAP_ROBUST_DUMP_CORPUS=<dir> to write the corpus for the oracle). Documents too large
/// to commit are generated here with expectations from the Android source, cited per test.
@Suite(.serialized) struct HostileFeedCorpusTests {
    struct Oracle: Decodable { let file: String; let sha256: String; let type: String?; let label: String; let title: String?; let items: Int; let detail: String? }
    static let failureLabels: Set = ["download_error_parser_exception", "download_error_unsupported_type", "download_error_unsupported_type_html"]

    static let directory = Bundle.module.url(forResource: "HostileFeeds", withExtension: nil, subdirectory: "Fixtures")!
    static func oracle(_ name: String) throws -> [String: Oracle] {
        let lines = try String(contentsOf: directory.appendingPathComponent("expected/\(name)"), encoding: .utf8)
            .split(separator: "\n")
        let decoded = try lines.map { try JSONDecoder().decode(Oracle.self, from: Data($0.utf8)) }
        return Dictionary(uniqueKeysWithValues: decoded.map { ($0.file, $0) })
    }

    private struct Body: FeedHTTPTransport {
        let body: Data
        func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
            FeedHTTPResponse(url: request.url!, status: 200, body: body)
        }
    }

    struct Outcome {
        var label: String
        var feed: ParsedFeed?
        var seconds: Double
    }

    /// The refresh path a person's library uses: the real fetcher, parser and validation.
    static func refresh(_ body: Data) async -> Outcome {
        let start = ContinuousClock.now
        let label: String
        var feed: ParsedFeed?
        do {
            let result = try await FeedFetcher(transport: Body(body: body))
                .fetch(FeedFetchRequest(source: "https://hostile.test/feed.xml", generateMissingArtwork: false))
            guard case .updated(let fetched) = result else { return Outcome(label: "not modified", seconds: 0) }
            feed = fetched.feed; label = "success"
        } catch let error as FeedFetchError {
            label = FeedLogDetails.statusKey(for: .failure(error))
        } catch {
            label = "unexpected \(error)"
        }
        let elapsed = ContinuousClock.now - start
        return Outcome(label: label, feed: feed, seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    // MARK: - Named documents against the Android oracle

    /// Where the JDK stand-in differs from Android, or where copying Android would be a defect:
    /// - external-entity / external-dtd: the JDK resolves external entities (it read /etc/hosts into the title
    ///   and tried to fetch the DTD); Android's ExpatParser does not open an entity its resolver leaves
    ///   unresolved, so the feed reads without them. Never reading local files is also the safe outcome.
    static let androidOverrides: [String: String] = ["external-entity.xml": "success", "external-dtd.xml": "success"]

    @Test func namedHostileDocumentsShowAndroidsMessageQuickly() async throws {
        let oracle = try Self.oracle("android.jsonl")
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.directory.path).filter { $0.hasSuffix(".xml") }.sorted()
        #expect(files.count == oracle.count, "every document has an Android verdict")
        for file in files {
            let data = try Data(contentsOf: Self.directory.appendingPathComponent(file))
            let expected = try #require(oracle[file], "no oracle row for \(file)")
            #expect(expected.sha256 == Self.sha256(data), "\(file) changed since the oracle ran")
            let outcome = await Self.refresh(data)
            #expect(outcome.label == (Self.androidOverrides[file] ?? expected.label), "\(file)")
            #expect(outcome.seconds < 1, "\(file) took \(outcome.seconds) s")
            if outcome.label == "success", expected.items >= 0 {
                #expect(outcome.feed?.episodes.count == expected.items, "\(file): episode count")
            }
        }
    }

    /// The characters Android reads are the characters shown: declared and guessed encodings, byte-order marks
    /// and a stray invalid byte (which Android's reader replaces instead of rejecting the feed).
    @Test func encodingsGiveAndroidsTitles() async throws {
        let oracle = try Self.oracle("android.jsonl")
        for file in ["utf8-invalid-bytes.xml", "latin1-declared.xml", "windows1252-declared.xml", "utf16le-bom.xml",
                     "utf16be-no-bom.xml", "utf8-bom.xml", "xml-predefined-entities.xml"] {
            let outcome = await Self.refresh(try Data(contentsOf: Self.directory.appendingPathComponent(file)))
            #expect(outcome.feed?.title == oracle[file]?.title, "\(file)")
        }
    }

    /// The download log's technical reason for documents that are not feeds, and for a feed without a title,
    /// is the text FeedParserTask records (UnsupportedFeedtypeException / InvalidFeedException message).
    @Test func technicalReasonsMatchAndroid() async throws {
        let oracle = try Self.oracle("android.jsonl")
        let unsupported = oracle.values.filter { $0.label.hasPrefix("download_error_unsupported_type") }
        #expect(unsupported.count >= 10)
        for row in unsupported + [oracle["missing-channel-title.xml"]!] {
            let data = try Data(contentsOf: Self.directory.appendingPathComponent(row.file))
            let reason = Mutex<String?>(nil)
            _ = try? await FeedFetcher(transport: Body(body: data)).fetch(FeedFetchRequest(source: "https://hostile.test/feed.xml"),
                                                                          failureDiagnostic: { message in reason.withLock { $0 = message } })
            #expect(reason.withLock { $0 } == row.detail, "\(row.file)")
        }
    }

    @Test func externalEntitiesNeverReadLocalFiles() async throws {
        let outcome = await Self.refresh(try Data(contentsOf: Self.directory.appendingPathComponent("external-entity.xml")))
        let title = try #require(outcome.feed?.title)
        // Apple's parser also drops the text after the unresolved reference (Android keeps "Lab"); recorded
        // as a limit, as external entities do not occur in real feeds.
        #expect(title.hasPrefix("Hostile"), "\(title)")
        #expect(!title.contains("localhost") && !title.contains("#"), "no file content: \(title)")
    }

    // MARK: - Seeded mutation corpus

    static let richSeed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:psc="http://podlove.org/simple-chapters" xmlns:podcast="https://podcastindex.org/namespace/1.0" xmlns:media="http://search.yahoo.com/mrss/" xmlns:atom="http://www.w3.org/2005/Atom">
        <channel><title>Rich &amp; Hostile</title><link>https://hostile.test/</link><description><![CDATA[<p>About <b>this</b> show</p>]]></description>
        <language>en-US</language><itunes:author>Hostile Lab</itunes:author><itunes:image href="https://hostile.test/art.png"/>
        <atom:link rel="next" href="https://hostile.test/feed.xml?page=2"/><podcast:funding url="https://hostile.test/fund">Support</podcast:funding>
        <item><title>First &lt;episode&gt;</title><guid isPermaLink="false">r1</guid><pubDate>Mon, 14 Sep 2026 15:04:22 +0200</pubDate>
        <itunes:duration>01:02:03</itunes:duration><content:encoded><![CDATA[<p>Notes with <a href="https://hostile.test">a link</a></p>]]></content:encoded>
        <psc:chapters version="1.2"><psc:chapter start="00:00:00.000" title="Intro"/><psc:chapter start="00:10:00" title="Middle" href="https://hostile.test/c"/></psc:chapters>
        <podcast:transcript url="https://hostile.test/t.vtt" type="text/vtt"/><podcast:chapters url="https://hostile.test/c.json" type="application/json+chapters"/>
        <enclosure url="https://hostile.test/r1.mp3" length="12345678" type="audio/mpeg"/></item>
        <item><title>Second</title><guid>r2</guid><pubDate>2026-09-13T10:00:00Z</pubDate><media:content url="https://hostile.test/r2.mp4" medium="video" fileSize="999" duration="60"/>
        <description>Plain description</description></item>
        <item><description>Untitled item uses its description</description><guid>r3</guid><enclosure url="https://hostile.test/r3.m4a" type="audio/x-m4a"/></item>
        </channel></rss>
        """

    struct Seed { let name: String; let data: Data }
    static func seeds() throws -> [Seed] {
        func fixture(_ path: String) throws -> Data {
            try Data(contentsOf: Bundle.module.url(forResource: path, withExtension: nil, subdirectory: "Fixtures")!)
        }
        return [Seed(name: "rich", data: Data(richSeed.utf8)),
                Seed(name: "rss2", data: try fixture("Feeds/feed-rss-testRss2Basic.xml")),
                Seed(name: "atom", data: try fixture("Feeds/feed-atom-testAtomBasic.xml")),
                Seed(name: "latin1", data: try fixture("HostileFeeds/latin1-declared.xml")),
                Seed(name: "utf16", data: try fixture("HostileFeeds/utf16le-bom.xml"))]
    }

    static let tokens = ["<", "&", "&amp", "]]>", "<![CDATA[", "<!--", "<?xml version=\"1.0\"?>", "<item>", "</item>",
                         "<!DOCTYPE x [<!ENTITY a \"aaaaaaaaaa\">]>", "&a;", "\u{FEFF}", "\0", "<title>", "</channel>",
                         "xmlns:itunes=\"x\"", "encoding=\"UTF-16\"", "<rss version=\"2.0\">", "\u{1}", "&#0;", "&#xD800;"]
    static let hostileBytes: [UInt8] = [0x00, 0x3C, 0x3E, 0x26, 0x22, 0x27, 0xFF, 0xC3, 0x80, 0x0A, 0x3B, 0x5D, 0xFE, 0xEF]

    /// 150 deterministic mutations per seed: bit flips, hostile bytes, deletions, duplications, truncations
    /// and inserted markup fragments.
    static func mutations() throws -> [(name: String, data: Data)] {
        var random = LargeAndroidLibrary.Random(state: 0x6A9_2026_0008)
        var result: [(String, Data)] = []
        for seed in try seeds() {
            for number in 0..<150 {
                var bytes = [UInt8](seed.data)
                let kind = number % 6
                func position() -> Int { random.int(0...max(0, bytes.count - 1)) }
                switch kind {
                case 0: for _ in 0..<random.int(1...4) { bytes[position()] ^= UInt8(1 << random.int(0...7)) }
                case 1: for _ in 0..<random.int(1...4) { bytes[position()] = hostileBytes[random.int(0...(hostileBytes.count - 1))] }
                case 2:
                    let start = position(); bytes.removeSubrange(start..<min(bytes.count, start + random.int(1...64)))
                case 3:
                    let start = position(), slice = Array(bytes[start..<min(bytes.count, start + random.int(1...256))])
                    bytes.insert(contentsOf: slice, at: position())
                case 4: bytes = Array(bytes.prefix(position()))
                default: bytes.insert(contentsOf: Array(tokens[random.int(0...(tokens.count - 1))].utf8), at: position())
                }
                result.append((String(format: "mut-%@-%03d.xml", seed.name, number), Data(bytes)))
            }
        }
        return result
    }

    @Test func seededMutationsMatchAndroidAndNeverStall() async throws {
        let corpus = try Self.mutations()
        if let dump = ProcessInfo.processInfo.environment["GAP_ROBUST_DUMP_CORPUS"] {
            try FileManager.default.createDirectory(atPath: dump, withIntermediateDirectories: true)
            for (name, data) in corpus { try data.write(to: URL(fileURLWithPath: dump).appendingPathComponent(name)) }
        }
        let oracle = try Self.oracle("mutations.jsonl")
        #expect(oracle.count == corpus.count)
        var mismatches: [String] = [], exact = 0
        for (name, data) in corpus {
            let expected = try #require(oracle[name], "no oracle row for \(name)")
            #expect(expected.sha256 == Self.sha256(data), "\(name): the generator changed; rerun the oracle")
            let outcome = await Self.refresh(data)
            #expect(outcome.seconds < 1, "\(name) took \(outcome.seconds) s")
            guard expected.type != nil else {
                // TypeGetter rejected the prolog or the first start tag. Which of its three messages Android's
                // libcore KXmlParser then picks is not reproduced by the kxml2 stand-in; it is never success.
                if !Self.failureLabels.contains(outcome.label) { mismatches.append("\(name): Android fails, here \(outcome.label)") }
                continue
            }
            exact += 1
            let label = Self.mutationOverrides[name] ?? expected.label
            let itemsDiffer = Self.mutationOverrides[name] == nil && label == "success" && outcome.feed?.episodes.count != expected.items
            if outcome.label != label || itemsDiffer {
                mismatches.append("\(name): Android \(label) (\(expected.items) items), here \(outcome.label) (\(outcome.feed?.episodes.count ?? -1))")
            }
        }
        #expect(exact > 600, "most documents get Android's exact message")
        #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
    }

    /// Where Apple's parser reads a damaged document Android's parser refuses: a corrupted byte inside an
    /// element name decodes to U+FFFD, a name character in XML 1.0 (5th edition, libxml2) but not in the
    /// rules Expat and the JDK apply. The podcast stays readable here instead of showing a broken feed.
    static let mutationOverrides: [String: String] = ["mut-atom-072.xml": "success", "mut-rich-144.xml": "success"]

    // MARK: - Generated hostile and huge documents

    static func rss(title: String = "Hostile Lab", items: String = "", prolog: String = "<?xml version=\"1.0\"?>",
                    rootExtra: String = "") -> Data {
        Data((prolog + "<rss version=\"2.0\"\(rootExtra)><channel><title>\(title)</title>\(items)</channel></rss>").utf8)
    }
    static let item = "<item><title>Episode</title><guid>g</guid><enclosure url=\"https://hostile.test/e.mp3\" length=\"99999\" type=\"audio/mpeg\"/></item>"

    /// Entity expansion attacks: Android's Expat refuses both (amplification limit), a broken feed; Apple's
    /// parser spent over ten seconds on the quadratic one before the app guarded against it.
    @Test func entityExpansionAttacksAreBrokenFeedsWithinASecond() async {
        var laughs = "<?xml version=\"1.0\"?><!DOCTYPE rss [<!ENTITY a0 \"lollollollollol\">"
        for level in 1...10 { laughs += "<!ENTITY a\(level) \"" + String(repeating: "&a\(level - 1);", count: 10) + "\">" }
        laughs += "]>"
        let billion = await Self.refresh(Self.rss(title: "&a10;", prolog: laughs))
        let quadratic = await Self.refresh(Self.rss(title: String(repeating: "&a;", count: 50_000),
            prolog: "<?xml version=\"1.0\"?><!DOCTYPE rss [<!ENTITY a \"" + String(repeating: "x", count: 100_000) + "\">]>"))
        for (name, outcome) in [("billion laughs", billion), ("quadratic blow-up", quadratic)] {
            #expect(outcome.label == "download_error_parser_exception", "\(name)")
            #expect(outcome.seconds < 1, "\(name) took \(outcome.seconds) s")
        }
        // An ordinary use of declared entities stays well below the limit.
        let modest = await Self.refresh(Self.rss(title: String(repeating: "&a;", count: 20) + " Lab", items: Self.item,
            prolog: "<?xml version=\"1.0\"?><!DOCTYPE rss [<!ENTITY a \"" + String(repeating: "x", count: 1_000) + "\">]>"))
        #expect(modest.label == "success")
    }

    /// 200,000 attributes on one element: Apple's parser needs minutes for this (quadratic duplicate check),
    /// so it is a broken feed here. Android's parser would read it; no real feed comes near 10,000.
    @Test func thousandsOfAttributesDoNotStallTheParser() async {
        let attributes = (0..<200_000).map { "a\($0)=\"1\"" }.joined(separator: " ")
        let outcome = await Self.refresh(Self.rss(items: "<item \(attributes)><title>Episode</title></item>"))
        #expect(outcome.label == "download_error_parser_exception")
        #expect(outcome.seconds < 1, "took \(outcome.seconds) s")
        let ordinary = (0..<500).map { "a\($0)=\"1\"" }.joined(separator: " ")
        #expect(await Self.refresh(Self.rss(items: "<item \(ordinary)><title>Episode</title></item>")).label == "success")
    }

    /// Deep nesting: well-formed unknown elements are ignored (Expat has no depth limit); an unclosed
    /// pyramid is a broken feed. Neither may exhaust the stack.
    @Test func deepNestingNeitherCrashesNorStalls() async {
        let depth = 200_000
        let nested = await Self.refresh(Self.rss(items: String(repeating: "<x>", count: depth) + String(repeating: "</x>", count: depth) + Self.item))
        #expect(nested.label == "success" && nested.feed?.episodes.count == 1)
        #expect(nested.seconds < 3, "took \(nested.seconds) s")
        let unclosed = await Self.refresh(Self.rss(items: String(repeating: "<x>", count: depth)))
        #expect(unclosed.label == "download_error_parser_exception")
        #expect(unclosed.seconds < 3, "took \(unclosed.seconds) s")
        // Markup nested deep inside a title is converted to text without recursion.
        let title = "<![CDATA[" + String(repeating: "<b>", count: depth) + "Deep" + "]]>"
        let deepTitle = await Self.refresh(Self.rss(title: title, items: Self.item))
        #expect(deepTitle.label == "success" && deepTitle.feed?.title == "Deep")
        #expect(deepTitle.seconds < 5, "took \(deepTitle.seconds) s")
    }

    /// Large real-world shapes: a 50 MB description and 100,000 episodes open in seconds.
    @Test func hugeFeedsParseInSeconds() async {
        let huge = await Self.refresh(Self.rss(items: "<item><title>Long</title><description>" + String(repeating: "word ", count: 10_000_000) + "</description></item>"))
        #expect(huge.label == "success" && (huge.feed?.episodes.first?.description?.utf8.count ?? 0) > 49_000_000)
        #expect(huge.seconds < 10, "took \(huge.seconds) s")
        let many = await Self.refresh(Self.rss(items: (0..<100_000).map {
            "<item><title>Episode \($0)</title><guid>g\($0)</guid><pubDate>Mon, 14 Sep 2026 15:04:22 GMT</pubDate><enclosure url=\"https://hostile.test/\($0).mp3\" length=\"99999\" type=\"audio/mpeg\"/></item>"
        }.joined()))
        #expect(many.label == "success" && many.feed?.episodes.count == 100_000)
        #expect(many.seconds < 30, "took \(many.seconds) s")
    }

    /// DateUtils retries a date without its leading "word, " by recursion; thousands of such words recursed
    /// until the stack overflowed (Android included). The episode is kept without a date.
    @Test func hostileDatesNeitherCrashNorStall() async {
        let date = String(repeating: "Mon, ", count: 200_000) + "14 Sep 2026 15:04:22 GMT"
        let outcome = await Self.refresh(Self.rss(items: "<item><title>Episode</title><pubDate>\(date)</pubDate></item>"))
        #expect(outcome.label == "success" && outcome.feed?.episodes.count == 1)
        #expect(outcome.seconds < 1, "took \(outcome.seconds) s")
        // A real date behind a few weekday words is still read, as DateUtils does.
        let real = await Self.refresh(Self.rss(items: "<item><title>Episode</title><pubDate>Monday, Mon, 14 Sep 2026 15:04:22 GMT</pubDate></item>"))
        #expect(real.feed?.episodes.first?.publicationDate == Date(timeIntervalSince1970: 1_789_398_262))
    }

    /// Every parse has a time limit; past it the feed is reported as broken instead of holding the refresh.
    @Test func parseStopsAtItsTimeLimit() throws {
        let data = Self.rss(items: String(repeating: Self.item, count: 20_000))
        #expect(throws: FeedParsingError.limitExceeded("The feed took too long to read")) {
            try FeedParser(timeLimit: .milliseconds(1)).parse(data)
        }
        #expect(try FeedParser().parse(data).episodes.count == 20_000)
    }

    /// Runs `body` on a thread with the 512 KB stack iOS gives secondary threads, where the recursive HTML
    /// parser overflowed at about a thousand nesting levels.
    static func onSmallStack<T: Sendable>(_ body: @escaping @Sendable () throws -> T) throws -> T {
        let box = Mutex<Result<T, any Error>?>(nil), done = DispatchSemaphore(value: 0)
        let thread = Thread { box.withLock { $0 = Result { try body() } }; done.signal() }
        thread.stackSize = 512 * 1024
        thread.start(); done.wait()
        return try box.withLock { $0! }.get()
    }

    /// A feed's text nested 5,000 levels deep (title, show notes, podcast description, transcript cue)
    /// shows as its text instead of ending the app.
    @Test func deeplyNestedMarkupInFeedTextNeverCrashes() throws {
        let deep = String(repeating: "<div><b>", count: 2_500) + "Deep notes &amp; more"
        let style = ShownotesFormatter.Style(foreground: "#000", accent: "#00f", padding: 8)
        let notes = try Self.onSmallStack { try ShownotesFormatter.format(deep, durationMilliseconds: 0, noShownotesLabel: "", style: style) }
        #expect(notes.contains("Deep notes &amp; more"))
        #expect(try Self.onSmallStack { try FeedDescriptionText.format(deep) } == "Deep notes & more")
        #expect(try Self.onSmallStack { try FeedValueParsing.htmlText(deep, compact: true) } == "Deep notes & more")
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n" + deep + "\n"
        let transcript = try Self.onSmallStack { try TranscriptParser.parse(vtt, format: .vtt) }
        #expect(transcript.segments.first?.words == "Deep notes & more")
        // Ordinary markup still goes through the HTML parser (links survive in show notes).
        let shallow = try ShownotesFormatter.format("<p>See <a href=\"https://hostile.test\">this</a></p>", durationMilliseconds: 0,
                                                    noShownotesLabel: "", style: style)
        #expect(shallow.contains("<a href=\"https://hostile.test\">this</a>"))
    }
}
