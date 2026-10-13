import Foundation
import Testing
@testable import NotTennaPodCore

/// External entry host checks against the Android oracle (Fixtures/m34-entry-oracle.json).
struct ExternalEntryTests {
    private struct Oracle: Decodable {
        struct Case: Decodable {
            struct Android: Decodable { var url: String?; var noPodcast: Bool?; var androidCrash: String? }
            /// Android's outcome, and for shared text the iOS outcome (shared text opens its first link).
            var group: String; var input: String; var android: Android; var iosUserDecision: Android?
        }
        var cases: [Case]
    }

    private func oracle() throws -> Oracle {
        let file = try #require(Bundle.module.url(forResource: "m34-entry-oracle", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: file))
    }

    /// What the app does with an address (`LibraryViewController.loadFeedPage`): the prepared address,
    /// or the no-podcast error when preparation fails.
    private func appOutcome(_ input: String) -> String? { try? FeedAddress.prepare(input) }

    /// What the app does with shared text: the Share Extension's handoff link, its route, then the
    /// preparation of the routed address; nil is the no-podcast error.
    private func sharedOutcome(_ text: String) throws -> String? {
        switch ExternalEntry.route(for: try #require(ShareHandoff.url(text: text))) {
        case .feedPreview(let address): return appOutcome(address)
        case .noPodcast: return nil
        case let other: Issue.record("unexpected route \(String(describing: other))"); return nil
        }
    }

    @Test func everyOracleCaseMatchesAndroidOrShowsTheNoPodcastError() throws {
        let cases = try oracle().cases
        #expect(cases.count == 95)
        #expect(Set(cases.map(\.group)) == ["urlCheckerTest", "schemeLink", "sharedText"])
        for entry in cases {
            if let url = entry.android.url {
                #expect(appOutcome(entry.input) == url, "\(entry.group): \(entry.input.debugDescription)")
            } else {
                // No-podcast (Android's own dialog) and Android crashes (not copied).
                #expect(appOutcome(entry.input) == nil, "\(entry.group): \(entry.input.debugDescription)")
            }
        }
        // The Android crash cases are really in the fixture.
        #expect(cases.filter { $0.android.androidCrash != nil }.count >= 3)
    }

    /// Deliberate iOS deviation: shared text opens its first link. Every
    /// shared-text oracle case carries the iOS expectation next to Android's result.
    @Test func everySharedTextOracleCaseFollowsTheUserDecision() throws {
        let shared = try oracle().cases.filter { $0.group == "sharedText" }
        #expect(shared.count == 21)
        for entry in shared {
            let expected = try #require(entry.iosUserDecision, "\(entry.input.debugDescription)")
            #expect(try sharedOutcome(entry.input) == expected.url, "\(entry.input.debugDescription)")
        }
        // The deviation changes Android's outcome only where Android fetched the words or crashed.
        #expect(shared.filter { $0.android.url != nil && $0.android.url != $0.iosUserDecision?.url }
            .allSatisfy { $0.input.contains(" ") || $0.input.isEmpty })
    }

    @Test func sharedTextOpensItsFirstLink() throws {
        // A plain link, and a link with words before and after it.
        #expect(try sharedOutcome("https://example.com/feed.xml") == "https://example.com/feed.xml")
        #expect(try sharedOutcome("Listen to this: https://example.com/feed.xml") == "https://example.com/feed.xml")
        #expect(try sharedOutcome("https://example.com/feed.xml is my favourite show") == "https://example.com/feed.xml")
        #expect(try sharedOutcome("Hear this\nhttps://example.com/feed.xml\n\nSent from my phone") == "https://example.com/feed.xml")
        // Sentence punctuation, quotes and brackets around the link are not part of it; a bracket the
        // link itself opens stays.
        #expect(try sharedOutcome("Try https://example.com/feed.xml, it's great!") == "https://example.com/feed.xml")
        #expect(try sharedOutcome("Is it “https://example.com/feed.xml”?") == "https://example.com/feed.xml")
        #expect(try sharedOutcome("(see https://example.com/feed.xml)") == "https://example.com/feed.xml")
        #expect(try sharedOutcome("<https://example.com/feed.xml>") == "https://example.com/feed.xml")
        #expect(try sharedOutcome("New: https://example.com/show_(2024).xml.") == "https://example.com/show_(2024).xml")
        #expect(try sharedOutcome("See https://example.com/rss?id=5&x=y.") == "https://example.com/rss?id=5&x=y")
        // Several links: the first one.
        #expect(try sharedOutcome("Two: https://example.com/first.xml and http://example.com/second.xml") == "https://example.com/first.xml")
        #expect(try sharedOutcome("pcast://example.com/a then https://example.com/b") == "http://example.com/a")
        // Podcast-protocol links in text count as links and are prepared like a tapped link.
        #expect(try sharedOutcome("Subscribe: itpc://example.com/rss today") == "http://example.com/rss")
        #expect(try sharedOutcome("Subscribe: ITPC://https://example.com/rss") == "https://example.com/rss")
        #expect(try sharedOutcome("New show (feed://example.com/feed.xml)") == "http://example.com/feed.xml")
        #expect(try sharedOutcome("New show pcast:example.com/feed") == "http://example.com/feed")
        #expect(try sharedOutcome("Open antennapod-subscribe://https://example.com/feed now") == "https://example.com/feed")
        #expect(try sharedOutcome("Go to www.example.com/feed.xml") == "http://www.example.com/feed.xml")
        // Links inside the text get the same preparation as a bare link (UrlChecker.prepareUrl port).
        #expect(try sharedOutcome("Look https://www.subscribeonandroid.com/example.com/feed.xml") == "https://example.com/feed.xml")
        #expect(try sharedOutcome("Look https://antennapod.org/deeplink/subscribe?url=https%3A%2F%2Fexample.com%2Ffeed&title=x")
                == "https://example.com/feed")
        // A link must start a word: "Podcast:" and "xhttps://" are not links.
        #expect(try sharedOutcome("Podcast: The Show xhttps://example.com") == nil)
        // No link: the no-podcast error, as before; a single word is still the address itself (Android).
        #expect(try sharedOutcome("Listen to this podcast") == nil)
        #expect(try sharedOutcome("Podcast: a show") == nil)
        #expect(try sharedOutcome("   \n") == nil)
        #expect(try sharedOutcome("") == nil)
        #expect(try sharedOutcome("https:// nothing") == nil)
        #expect(try sharedOutcome("example.com/feed.xml") == "http://example.com/feed.xml")
        #expect(ExternalEntry.route(for: try #require(ShareHandoff.url(text: "Listen to this podcast"))) == .noPodcast)
    }

    @Test func antennaPodShareTextFindsTheFeedEvenWithPunctuationInTheTitle() throws {
        // ShareUtils.shareFeedLink text, with '?', '#' and '&' in the title before the link.
        let text = "Why? Show #1 & more\n\nhttps://antennapod.org/deeplink/subscribe/?url=%68%74%74ps%3A%2F%2Fexample.com%2Frss%3Fid%3D5&title=Why%3F"
        #expect(try FeedAddress.prepare(text) == "https://example.com/rss?id=5")
        // A ':' in the title makes the text opaque: Android crashes; here it is the no-podcast error.
        #expect(throws: FeedAddressError.missingDeeplinkURL) {
            try FeedAddress.prepare("Planet Money: The Indicator\n\nhttps://antennapod.org/deeplink/subscribe/?url=x")
        }
        // A key without '=' is the empty value, as Uri.getQueryParameter returns "".
        #expect(try FeedAddress.prepare("https://antennapod.org/deeplink/subscribe?url&title=a") == "http://")
    }

    /// The app's own "Share" text for a podcast, shared back into the app, finds that podcast again — as
    /// on Android — and also when the title has a ':' (Android crashes; not copied).
    /// A podcast shared from the app (title, blank line, plain feed address) opens that feed when shared back in.
    @Test func sharedPodcastTextRoundTrips() throws {
        for (title, source) in [("Example Show", "https://example.com/feed.xml"), ("Why? #1 & 2", "http://example.com/rss?id=5&x=y"),
                                ("Émission", "https://example.fr/a%20b"), ("", "https://example.com/"),
                                ("Planet Money: The Indicator", "https://example.com/feed"),
                                ("Part 2: Q&A (live).", "https://example.com/feed.xml?a=b")] {
            #expect(try sharedOutcome(FeedShareText.make(title: title, source: source)) == source, "\(title)")
        }
        // A stored address with an international host and a space is shared whole: the space percent-encoded (its
        // meaning in a URL), so the shared link names the entire address instead of stopping at the space.
        #expect(try sharedOutcome(FeedShareText.make(title: "Émission", source: "https://exämple.fr/a b")) == "https://exämple.fr/a%20b")
        #expect(try sharedOutcome(FeedShareText.make(title: "Tab", source: "https://example.com/a\tb")) == "https://example.com/a%09b")
        // Whitespace around a stored address (OPML imports keep it) is left out, so the address still opens; an
        // address already percent-encoded is shared unchanged.
        for source in ["  https://example.com/feed.xml", "https://example.com/feed.xml  ", "  https://example.com/feed.xml  ", "\thttps://example.com/feed.xml\n"] {
            #expect(try sharedOutcome(FeedShareText.make(title: "Padded", source: source)) == "https://example.com/feed.xml", "\(source.debugDescription)")
        }
        #expect(try sharedOutcome(FeedShareText.make(title: "Encoded", source: "https://example.com/a%20")) == "https://example.com/a%20")
        // A link in the title comes first, so it is the one opened.
        #expect(try sharedOutcome(FeedShareText.make(title: "Hi https://other.example/x.xml", source: "https://example.com/feed"))
                == "https://other.example/x.xml")
    }

    @Test func protocolLinksAndShareHandoffsRouteToThePreview() throws {
        for scheme in ["itpc", "pcast", "feed", "antennapod-subscribe", "ITPC"] {
            let url = try #require(URL(string: "\(scheme)://example.com/feed.xml"))
            #expect(ExternalEntry.route(for: url) == .feedPreview("\(scheme)://example.com/feed.xml"))
        }
        #expect(ExternalEntry.route(for: try #require(URL(string: "https://antennapod.org/deeplink/subscribe?url=x"))) == nil)
        #expect(ExternalEntry.route(for: URL(fileURLWithPath: "/tmp/list.opml")) == .document(URL(fileURLWithPath: "/tmp/list.opml")))
        // The Share Extension's text survives the handoff unchanged, including newlines and '&'.
        let text = "Example Show\n\nhttps://antennapod.org/deeplink/subscribe/?url=%68%74%74ps%3A%2F%2Fexample.com&title=A+B"
        let handoff = try #require(ShareHandoff.url(text: text))
        #expect(handoff.scheme == ShareHandoff.scheme)
        #expect(ShareHandoff.text(from: handoff) == text)
        // The route carries the text's first link.
        let link = "https://antennapod.org/deeplink/subscribe/?url=%68%74%74ps%3A%2F%2Fexample.com&title=A+B"
        #expect(ExternalEntry.route(for: handoff) == .feedPreview(link))
        #expect(try FeedAddress.prepare(link) == "https://example.com")
        #expect(ExternalEntry.route(for: try #require(ShareHandoff.url(text: nil))) == .noPodcast)
        // A web URL item (Safari) wins over the page title text; a file is not a shared link.
        let page = try #require(URL(string: "https://example.com/feed.xml"))
        #expect(ShareHandoff.sharedText(url: page, text: "Example page") == "https://example.com/feed.xml")
        #expect(ShareHandoff.sharedText(url: nil, text: "example.com/rss") == "example.com/rss")
        #expect(ShareHandoff.sharedText(url: URL(fileURLWithPath: "/tmp/a.xml"), text: nil) == nil)
    }

    @Test func quickActionsFollowTheLauncherShortcuts() {
        // shortcuts.xml order, labels, glyphs and targets.
        #expect(ExternalEntry.QuickAction.allCases.map(\.rawValue) == ["queue", "episodes", "subscriptions", "refresh"])
        #expect(ExternalEntry.QuickAction.allCases.map(\.titleKey) == ["queue_label", "episodes_label", "subscriptions_label", "refresh_label"])
        #expect(ExternalEntry.QuickAction.allCases.map(\.iconName) == ["ic_playlist_play", "ic_feed", "ic_subscriptions", "ic_refresh"])
        #expect(ExternalEntry.QuickAction.allCases.map(\.destination) == [.queue, .episodes, .subscriptions, nil])
        #expect(ExternalEntry.QuickAction.allCases.map(\.destination?.rawValue) == ["QueueFragment", "EpisodesFragment", "SubscriptionFragment", nil])
        for action in ExternalEntry.QuickAction.allCases { #expect(ExternalEntry.QuickAction(type: action.type) == action) }
        #expect(ExternalEntry.QuickAction(type: "queue") == nil)
    }

    @Test func appActionPagesFollowTheEntitySetAndDeeplinkTable() {
        #expect(ExternalEntry.AppActionPage.allCases.map(\.rawValue) == ["QUEUE", "EPISODES", "DOWNLOADS", "SUBSCRIPTIONS", "HISTORY"])
        #expect(ExternalEntry.AppActionPage.allCases.map(\.destination) == [.queue, .episodes, .downloads, .subscriptions, .history])
        #expect(ExternalEntry.AppActionPage.allCases.map(\.titleKey)
                == ["queue_label", "episodes_label", "downloads_label", "subscriptions_label", "playback_history_label"])
        #expect(ExternalEntry.deeplinkPage("STATISTICS") == .statistics)
        #expect(ExternalEntry.deeplinkPage("queue") == nil) // case-sensitive switch; "not found" message
    }

    @Test func feedDocumentsCarryTheirOwnAddress() {
        let rss = """
        <?xml version="1.0"?><rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
        <channel><title>T</title><link>https://example.com/</link>
        <atom:link href="https://example.com/feed.xml" rel="self" type="application/rss+xml"/>
        <itunes:new-feed-url>https://example.com/new.xml</itunes:new-feed-url>
        <item><atom:link rel="self" href="https://example.com/episode"/></item></channel></rss>
        """
        #expect(ExternalDocument.classify(Data(rss.utf8)) == .feed(address: "https://example.com/feed.xml"))
        let moved = "<rss xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"><channel><itunes:new-feed-url> http://example.com/moved.xml </itunes:new-feed-url></channel></rss>"
        #expect(ExternalDocument.classify(Data(moved.utf8)) == .feed(address: "http://example.com/moved.xml"))
        let atom = "<feed xmlns=\"http://www.w3.org/2005/Atom\"><link rel=\"alternate\" href=\"https://example.com/\"/><link rel=\"self\" href=\"https://example.com/atom\"/><entry/></feed>"
        #expect(ExternalDocument.classify(Data(atom.utf8)) == .feed(address: "https://example.com/atom"))
        // Only the channel's links count, and only web addresses.
        let itemOnly = "<rss><channel><item><atom:link xmlns:atom=\"http://www.w3.org/2005/Atom\" rel=\"self\" href=\"https://example.com/e\"/></item></channel></rss>"
        #expect(ExternalDocument.classify(Data(itemOnly.utf8)) == .feed(address: nil))
        let relative = "<feed xmlns=\"http://www.w3.org/2005/Atom\"><link rel=\"self\" href=\"/atom\"/></feed>"
        #expect(ExternalDocument.classify(Data(relative.utf8)) == .feed(address: nil))
        let rdf = "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\" xmlns=\"http://purl.org/rss/1.0/\"><channel/></rdf:RDF>"
        #expect(ExternalDocument.classify(Data(rdf.utf8)) == .feed(address: nil))
        #expect(ExternalDocument.classify(Data("<opml version=\"2.0\"><body/></opml>".utf8)) == .opml)
        #expect(ExternalDocument.classify(Data("<html><body/></html>".utf8)) == .other)
        #expect(ExternalDocument.classify(Data("not xml".utf8)) == .other)
    }
}
