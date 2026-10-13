import Foundation
import Testing
@testable import NotTennaPodCore

struct FeedParserTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let namespaces = """
    xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
    xmlns:content="http://purl.org/rss/1.0/modules/content/"
    xmlns:media="http://search.yahoo.com/mrss/"
    xmlns:podcast="https://podcastindex.org/namespace/1.0"
    xmlns:psc="http://podlove.org/simple-chapters"
    xmlns:atom="http://www.w3.org/2005/Atom"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    """

    private func parse(_ xml: String) throws -> ParsedFeed {
        try FeedParser().parse(Data(xml.utf8), now: now)
    }

    private func rss(_ channel: String) throws -> ParsedFeed {
        try parse("<rss version=\"2.0\" \(namespaces)><channel>\(channel)</channel></rss>")
    }

    private func fixture(_ name: String) throws -> ParsedFeed {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures/Feeds"))
        return try FeedParser().parse(Data(contentsOf: url), now: now)
    }

    @Test(arguments: ["feed-rss-testRss2Basic", "feed-atom-testAtomBasic"])
    func upstreamBasicFeedExpectations(name: String) throws {
        let feed = try fixture(name)
        #expect(feed.format == (name.contains("rss") ? .rss : .atom))
        #expect(feed.title == "title")
        #expect(feed.link == "http://example.com")
        #expect(feed.description == "This is the description")
        #expect(feed.funding.first?.url == "http://example.com/payment")
        #expect(feed.imageURL == "http://example.com/picture")
        #expect(feed.episodes.count == 10)
        if feed.format == .rss { #expect(feed.language == "en") }
        else { #expect(feed.identifier == "http://example.com/feed") }
        for (index, episode) in feed.episodes.enumerated() {
            #expect(episode.identifier == "http://example.com/item-\(index)")
            #expect(episode.title == "item-\(index)")
            #expect(episode.description == nil)
            #expect(episode.link == "http://example.com/items/\(index)")
            #expect(episode.publicationDate == Date(timeIntervalSince1970: Double(index * 60)))
            #expect(episode.paymentLink == nil)
            #expect(episode.imageURL(in: feed) == "http://example.com/picture")
            #expect(episode.media?.url == "http://example.com/media-\(index)")
            #expect(episode.media?.size == 1_048_576)
            #expect(episode.media?.mimeType == "audio/mp3")
            #expect(episode.chapters == nil)
        }
    }

    @Test(arguments: ["feed-rss-testImageWithWhitespace", "feed-atom-testLogoWithWhitespace"])
    func upstreamArtworkWhitespaceExpectations(name: String) throws {
        let feed = try fixture(name)
        #expect(feed.title == "title")
        #expect(feed.link == "http://example.com")
        #expect(feed.description == "This is the description")
        #expect(feed.funding.first?.url == "http://example.com/payment")
        #expect(feed.imageURL == "https://example.com/image.png")
        #expect(feed.episodes.isEmpty)
    }

    @Test func remainingUpstreamFixtures() throws {
        let missingRel = try fixture("feed-atom-testEmptyRelLinks")
        #expect(missingRel.identifier == "http://example.com/feed")
        #expect(missingRel.title == "title")
        #expect(missingRel.description == "This is the description")
        #expect(missingRel.link == "http://example.com")
        #expect(missingRel.funding.isEmpty)
        let episode = try #require(missingRel.episodes.first)
        #expect(missingRel.episodes.count == 1)
        #expect(episode.identifier == "http://example.com/item-0")
        #expect(episode.title == "item-0")
        #expect(episode.link == "http://example.com/items/0")
        #expect(episode.publicationDate == Date(timeIntervalSince1970: 0))
        #expect(episode.media == nil)
        #expect(episode.chapters == nil)
        #expect(episode.description == nil)
        #expect(episode.paymentLink == nil)
        #expect(episode.imageURL(in: missingRel) == "http://example.com/picture")
        let media = try fixture("feed-rss-testMediaContentMime")
        #expect(media.imageURL == nil)
        #expect(media.episodes.count == 1)
        #expect(media.episodes.first?.media?.url == "https://www.example.com/file.mp4")
        #expect(media.episodes.first?.media?.mimeType == "video/*")
        let funding = try fixture("feed-rss-testMultipleFundingTags")
        #expect(funding.funding.map(\.url) == (1...3).map { "https://example.com/funding\($0)" })
        #expect(funding.funding.map(\.content) == ["Text 1", "Text 2", ""])
        let transcript = try fixture("feed-rss-testPodcastIndexTranscript")
        #expect(transcript.episodes.first?.transcript?.format == .json)
        #expect(transcript.episodes.first?.transcript?.url == "https://podnews.net/audio/podnews231011.mp3.json")
        let unsupported = try fixture("feed-rss-testUnsupportedElements")
        #expect(unsupported.episodes.count == 1)
        #expect(unsupported.episodes.first?.title == "item-0")
    }

    @Test func descriptionSelectionUsesJavaUTF16LengthAndKeepsFirstTie() throws {
        let feed = try rss("""
        <item><description>aaa</description><content:encoded>😀😀</content:encoded>
        <itunes:summary>bbbb</itunes:summary></item>
        <item><description><![CDATA[<p>Raw shownotes</p>]]></description><itunes:summary>short</itunes:summary></item>
        <item><title/><description>fallback only for absent title</description></item>
        """)
        #expect(feed.episodes.map(\.description) == ["😀😀", "<p>Raw shownotes</p>", "fallback only for absent title"])
        #expect(feed.episodes.map(\.title) == ["😀😀", "<p>Raw shownotes</p>", ""])
    }

    @Test func htmlMetadataAndPlainShownotesRemainDifferent() throws {
        let feed = try rss("""
        <title><![CDATA[A &amp; B <b>bold</b>]]></title>
        <description><![CDATA[<p>First</p><p>Second<br>line</p>]]></description>
        <itunes:author><![CDATA[Author &copy;]]></itunes:author>
        <item><description><![CDATA[one
        two &amp; three]]></description></item>
        """)
        #expect(feed.title == "A & B bold")
        #expect(feed.description == "First\nSecond\nline\n")
        #expect(feed.author == "Author ©")
        #expect(feed.episodes.first?.description == "one\ntwo &amp; three")
        let atom = try parse("""
        <feed xmlns="http://www.w3.org/2005/Atom"><title type="html">&lt;p&gt;First&lt;/p&gt;&lt;p&gt;Second&lt;/p&gt;</title>
        <entry><summary type="text">&lt;b&gt;Literal&lt;/b&gt;</summary></entry></feed>
        """)
        #expect(atom.title == "First\n\nSecond\n\n")
        #expect(atom.episodes.first?.description == "<b>Literal</b>")
    }

    @Test func artworkPreferenceAndExplicitEpisodeArtwork() throws {
        for channel in [
            "<image><url>rss</url></image><media:thumbnail url=\"media\"/><itunes:image href=\" itunes \"/>",
            "<itunes:image href=\" itunes \"/><image><url>rss</url></image><media:thumbnail url=\"media\"/>"
        ] {
            let feed = try rss(channel + """
            <item><media:thumbnail url="episode"/><itunes:image href=""/></item>
            <item><media:thumbnail url="episode"/><itunes:image/></item>
            <item/>
            """)
            #expect(feed.imageURL == " itunes ")
            #expect(feed.episodes.map { $0.imageURL(in: feed) } == ["", " itunes ", " itunes "])
        }
    }

    @Test func enclosureChoiceAndSizeRules() throws {
        let feed = try rss("""
        <item><enclosure url="cover" type="image/png"/><enclosure url="first" type="audio/mpeg" length="16383"/>
        <enclosure url="second" type="audio/mpeg" length="40000"/></item>
        <item><enclosure url="file" type="unknown" length="16384"/></item>
        <item><enclosure url="" type="audio/mpeg"/></item>
        <item><enclosure url="file.mp3?auth=yes" length="-9"/></item>
        <item><enclosure url="file.mp3" type="image/jpeg"/></item>
        """)
        #expect(feed.episodes.map { $0.media?.url } == ["first", "file", nil, "file.mp3?auth=yes", "file.mp3"])
        #expect(feed.episodes.map { $0.media?.size } == [0, 16384, nil, 0, 0])
        #expect(feed.episodes.map { $0.media?.mimeType } == ["audio/mpeg", "audio/*", nil, "audio/*", "audio/mpeg"])
        let atom = try parse("""
        <feed xmlns="http://www.w3.org/2005/Atom"><entry><link rel="enclosure" length="12" type="audio/mpeg"/></entry></feed>
        """)
        #expect(atom.episodes.first?.media?.size == 12)
        #expect(atom.episodes.first?.media?.url == nil)
        #expect(atom.episodes.first?.media != nil)
    }

    @Test func mediaDefaultOverridesEnclosureAndItunesDurationAppliesAtEpisodeEnd() throws {
        let feed = try rss("""
        <item><itunes:duration>02:15:45</itunes:duration><enclosure url="original" type="audio/mpeg"/>
        <media:content url="other" type="audio/aac"/>
        <media:content url="chosen" type="audio/flac" isDefault="true" duration="99" fileSize="12"/>
        <itunes:duration>invalid</itunes:duration></item>
        <item><media:content url="next" medium="audio" duration="2"/></item>
        <item><itunes:duration>5</itunes:duration></item>
        <item><enclosure url="last" type="audio/mpeg"/></item>
        """)
        #expect(feed.episodes.map { $0.media?.url } == ["chosen", "next", nil, "last"])
        #expect(feed.episodes.map { $0.media?.durationMilliseconds } == [8_145_000, 2_000, nil, 0])
        #expect(feed.episodes.first?.media?.size == 12)
    }

    @Test func transcriptPriorityFirstTieAndMimeAliases() throws {
        let formats = ["application/x-subrip", "text/vtt", "application/json"]
        for permutation in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            let tags = permutation.map { "<podcast:transcript url=\"url\($0)\" type=\"\(formats[$0])\"/>" }.joined()
            let feed = try rss("<item>\(tags)<podcast:transcript url=\"later\" type=\"application/json\"/></item>")
            #expect(feed.episodes.first?.transcript == FeedTranscript(format: .json, url: "url2"))
        }
        let feed = try rss("""
        <item><podcast:transcript url="unsupported" type="text/plain"/>
        <podcast:transcript url="srt" type="application/srr"/>
        <podcast:transcript url="" type="application/json"/></item>
        """)
        #expect(feed.episodes.first?.transcript == FeedTranscript(format: .srt, url: "srt"))
    }

    @Test func identifiersLanguageAndNamespaceRegistration() throws {
        let feed = try rss("""
        <language> EN-US </language><item><guid>  identity  </guid></item><item><guid> </guid></item>
        <item><guid/></item><item xmlns:other="http://www.itunes.com/dtds/podcast-1.0.dtd"><other:image href="recognized-by-uri"/></item>
        """)
        #expect(feed.language == "en-us")
        #expect(feed.episodes.map(\.identifier) == ["  identity  ", " ", nil, nil])
        #expect(feed.episodes.last?.imageURL == "recognized-by-uri")
        let unregistered = try parse("""
        <rss xmlns:other="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><other:image href="ignored"/></channel></rss>
        """)
        #expect(unregistered.imageURL == nil)
        let atom = try parse("<feed xmlns=\"http://www.w3.org/2005/Atom\" xml:lang=\"EN-US\"><id> raw </id></feed>")
        #expect(atom.language == "EN-US")
        #expect(atom.identifier == " raw ")
    }

    @Test func chaptersFundingSocialPaginationAndRedirect() throws {
        let feed = try rss("""
        <podcast:funding url="donate">  support  </podcast:funding><itunes:new-feed-url> https://new.example </itunes:new-feed-url>
        <atom:link rel="next" href="next"/><atom:link rel="alternate" type="application/rss+xml" href="alternate" title="Old"/>
        <atom:link rel="archives" type="application/rss+xml" href="alternate" title="New"/>
        <item><podcast:chapters url="chapters.json"/><podcast:socialInteract uri="social"/>
        <psc:chapters><psc:chapter start="00:01:02.5" title="Start" href="link" image="image"/>
        <psc:chapter start="bad:time"/><psc:chapter start="12" title="Single value"/></psc:chapters></item>
        """)
        #expect(feed.funding == [FeedFunding(url: "donate", content: "  support  ")])
        #expect(feed.redirectURL == "https://new.example")
        #expect(feed.isPaged)
        #expect(feed.nextPageURL == "next")
        #expect(feed.alternateFeeds == [AlternateFeed(title: "New", url: "alternate")])
        #expect(feed.episodes.first?.chapterURL == "chapters.json")
        #expect(feed.episodes.first?.socialInteractionURL == "social")
        #expect(feed.episodes.first?.chapters == [
            ParsedChapter(startMilliseconds: 62500, title: "Start", link: "link", imageURL: "image"),
            ParsedChapter(startMilliseconds: 0, title: "Single value", link: nil, imageURL: nil)
        ])
    }

    @Test func atomDatesPreferPublishedAndRejectFuture() throws {
        let feed = try parse("""
        <feed xmlns="http://www.w3.org/2005/Atom">
        <entry><updated>2020-01-01</updated><published>2021-01-01</published><updated>2022-01-01</updated></entry>
        <entry><published>2099-01-01</published><updated>2020-01-01</updated></entry>
        <entry><updated>2020-01-01</updated><published>2099-01-01</published></entry>
        </feed>
        """)
        #expect(feed.episodes.map(\.publicationDate) == [
            Date(timeIntervalSince1970: 1_609_459_200), Date(timeIntervalSince1970: 1_577_836_800), nil
        ])
    }

    @Test func rejectsWrongRootsVersionsAndMalformedXML() throws {
        #expect(throws: FeedParsingError.unsupportedRoot("html")) { try parse("<html/>") }
        #expect(throws: FeedParsingError.unsupportedRSSVersion("3.0")) { try parse("<rss version=\"3.0\"/>") }
        for source in ["", "not xml", "<rss><channel><item></channel></rss>", "<rss><channel>&missing;</channel></rss>"] {
            #expect(throws: FeedParsingError.self) { try parse(source) }
        }
        for version in ["2.0", "0.91", "0.92"] {
            #expect(try parse("<rss version=\"\(version)\"><channel/></rss>").format == .rss)
        }
    }

    @Test func decodesDeclaredEncodingAndSplitCDATA() throws {
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><rss><channel><title>Café<![CDATA[ &amp; ]]>茶</title></channel></rss>"
        let data = try #require(xml.data(using: .utf16))
        #expect(try FeedParser().parse(data, now: now).title == "Café & 茶")
    }

    @Test func literalNestedMarkupFollowsTheReleaseSAXBufferRules() throws {
        let feed = try rss("""
        <item><description>before<unknown>inside</unknown>after</description></item>
        <item><description><![CDATA[before<unknown>inside</unknown>after]]></description></item>
        """)
        #expect(feed.episodes.first?.description == nil)
        #expect(feed.episodes.last?.description == "before<unknown>inside</unknown>after")
    }

    @Test func independentParsesDoNotShareFeedState() async throws {
        let parser = FeedParser()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    let xml = "<rss><channel><title>feed-\(index)</title><item><guid>item-\(index)</guid></item></channel></rss>"
                    let feed = try parser.parse(Data(xml.utf8))
                    #expect(feed.title == "feed-\(index)")
                    #expect(feed.episodes.map(\.identifier) == ["item-\(index)"])
                }
            }
            try await group.waitForAll()
        }
    }

    @Test func largeFeedKeepsSourceOrderAndDuplicateIdentifiers() throws {
        let items = (0..<1_000).map { "<item><guid>duplicate</guid><title>episode-\($0)</title></item>" }.joined()
        let feed = try rss(items)
        #expect(feed.episodes.count == 1_000)
        #expect(feed.episodes.map(\.title) == (0..<1_000).map { "episode-\($0)" })
        #expect(feed.episodes.allSatisfy { $0.identifier == "duplicate" })
    }

    @Test func externalEntitiesCannotReadLocalFiles() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("external-entity-sentinel".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let xml = """
        <!DOCTYPE rss [<!ENTITY external SYSTEM "\(file.absoluteString)">]>
        <rss><channel><title>&external;</title></channel></rss>
        """
        do {
            let feed = try parse(xml)
            #expect(feed.title?.contains("external-entity-sentinel") != true)
        } catch is FeedParsingError {
        }
    }
}
