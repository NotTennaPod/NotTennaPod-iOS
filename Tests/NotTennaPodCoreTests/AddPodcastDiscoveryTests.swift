import Foundation
import Testing
@testable import NotTennaPodCore

/// Discovery against the Android oracle: inputs `TestSupport/Data/add-podcast-discovery/discovery-inputs.json`,
/// expectations `…/expected/discovery.json` (generated from the source rules and cross-checked by running the
/// unchanged Java classes, 73/73). Nothing here is derived from the Swift implementation.
@Suite struct AddPodcastDiscoveryTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized
    static let fixtures = root.appendingPathComponent("TestSupport/Data/add-podcast-discovery")
    static func json(_ name: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent(name))) as? [String: Any])
    }
    static var inputs: [String: Any] { get throws { try json("discovery-inputs.json") } }
    static var expected: [String: Any] { get throws { try json("expected/discovery.json") } }
    static func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

    // MARK: Top list and subscribed exclusion

    private func subscriptions() throws -> [DiscoverySubscription] {
        let rows = try #require(try Self.inputs["subscriptions"] as? [[String: Any]])
        return rows.map { row in
            let custom = row["custom_title"] as? String
            return DiscoverySubscription(title: custom.flatMap { $0.isEmpty ? nil : $0 } ?? row["title"] as? String,
                                         author: row["author"] as? String,
                                         state: FeedSubscriptionState(rawValue: row["state"] as! Int)!)
        }
    }

    @Test func topListParsesInFeedOrderAndExcludesSubscribedTitlesUpToEachScreensLimit() throws {
        let toplist = try Self.data(try #require(try Self.inputs["toplist"]))
        let parsed = try ItunesTopList.parse(toplist)
        let expected = try #require(try Self.expected["toplist"] as? [String: Any])
        let expectedParsed = try #require(expected["parsed"] as? [[String: Any]])
        #expect(parsed.map(\.title) == expectedParsed.map { $0["title"] as! String })
        #expect(parsed.map(\.feedURL) == expectedParsed.map { $0["feedUrl"] as! String })
        #expect(parsed.map(\.imageURL) == expectedParsed.map { $0["imageUrl"] as? String })
        #expect(parsed.map(\.author) == expectedParsed.map { $0["author"] as? String })
        let subscribed = try subscriptions()
        #expect(ItunesTopList.removeSubscribed(parsed, subscriptions: subscribed, limit: ItunesTopList.addScreenLimit).map(\.title)
                == expected["add_screen_12"] as! [String])
        #expect(ItunesTopList.removeSubscribed(parsed, subscriptions: subscribed, limit: ItunesTopList.discoverLimit).map(\.title)
                == expected["discover_25"] as! [String])
        // Every suggestion subscribed: the empty state.
        let all = parsed.map { DiscoverySubscription(title: $0.title, author: "A", state: .subscribed) }
        #expect(ItunesTopList.removeSubscribed(parsed, subscriptions: all, limit: 12).isEmpty)
    }

    @Test func storedFeedsUseTheirDisplayTitleAuthorAndState() throws {
        func feed(_ title: String, custom: String? = nil, author: String? = "A", state: FeedSubscriptionState) -> LibraryFeed {
            var feed = LibraryFeed(id: 1, source: "https://example.org/\(title)", metadata: ParsedFeed(format: .rss, title: title, author: author), episodes: [])
            feed.customTitle = custom; feed.subscriptionState = state
            return feed
        }
        let suggestions = ["Custom", "Original", "Archived", "Preview", "No author"].map {
            PodcastSearchResult(title: $0, feedURL: "https://itunes.apple.com/lookup?id=\($0)")
        }
        let kept = ItunesTopList.removeSubscribed(suggestions, feeds: [
            feed("Original", custom: "Custom", state: .subscribed), feed("Archived", state: .archived),
            feed("Preview", state: .notSubscribed), feed("No author", author: nil, state: .subscribed)
        ], limit: 12)
        #expect(kept.map(\.title) == ["Original", "Preview", "No author"])
    }

    @Test func malformedTopListShapesAreEmpty() throws {
        let variants = try #require(try Self.inputs["toplist_variants"] as? [String: Any])
        #expect(try ItunesTopList.parse(try Self.data(variants["entry_object"]!)).isEmpty)
        #expect(try ItunesTopList.parse(try Self.data(variants["no_feed"]!)).isEmpty)
    }

    @Test func topListRequestsTheCountryAndMapsHTTPFailures() async throws {
        let body = try Self.data(try #require(try Self.inputs["toplist"]))
        let requests = Locked<[URL]>([])
        func client(status: Int) -> PodcastSearchClient {
            PodcastSearchClient(send: { request in requests.value.append(request.url!); return (body, status) })
        }
        let shown = try await client(status: 200).topList(country: "US", limit: 12, feeds: [])
        #expect(shown.count == 12)
        let urls = try #require(try Self.expected["toplist"] as? [String: Any])["urls"] as! [String: [String]]
        #expect(requests.value.map(\.absoluteString) == urls["stored_US"])
        await #expect(throws: TopListError.noDataForCountry) { try await client(status: 400).topList(country: "DE", limit: 25, feeds: []) }
        await #expect(throws: TopListError.http(503)) { try await client(status: 503).topList(country: "US", limit: 25, feeds: []) }
        #expect(requests.value.last?.absoluteString == "https://itunes.apple.com/US/rss/toppodcasts/limit=25/explicit=true/json")
        let messages = try #require(try Self.expected["toplist"] as? [String: Any])["http_errors"] as! [String: String]
        #expect(ItunesTopList.noDataMessage == messages["400"])
    }

    // MARK: Provider search and combined order

    @Test(arguments: ["small_both", "small_apple_failed", "small_both_failed", "big_both"])
    func combinedSearchShowsAndroidOrderIncludingTies(_ name: String) async throws {
        let cases = try #require(try Self.inputs["search"] as? [String: Any])["combined"] as! [[String: Any]]
        let input = try #require(cases.first { $0["name"] as? String == name })
        let apple = input["Apple"] is NSNull ? nil : try Self.data(input["Apple"]!)
        let index = input["Podcast Index"] is NSNull ? nil : try Self.data(input["Podcast Index"]!)
        let client = PodcastSearchClient(indexKey: "test-key", indexSecret: "test-secret", send: { request in
            let body = request.url?.host == "itunes.apple.com" ? apple : index
            guard let body else { throw URLError(.cannotConnectToHost) }
            return (body, 200)
        })
        let results = try await client.search(input["query"] as! String, provider: .combined)
        let expected = try #require(try Self.expected["search"] as? [String: Any])["combined"] as! [String: [String: Any]]
        let oracle = try #require(expected[name])
        #expect(results.map(\.feedURL) == oracle["result_feed_urls"] as! [String])
        #expect(results.map(\.title) == oracle["result_titles"] as! [String])
    }

    @Test func combinedTieOrderIsTheHashMapOrderNotFirstEncounter() throws {
        let expected = try #require(try Self.expected["search"] as? [String: Any])["combined"] as! [String: [String: Any]]
        let cases = try #require(try Self.inputs["search"] as? [String: Any])["combined"] as! [[String: Any]]
        for name in ["small_both", "big_both"] {
            let input = try #require(cases.first { $0["name"] as? String == name })
            // Apple URLs first, then Podcast Index URLs: the insertion order of the source.
            let apple = ((input["Apple"] as! [String: Any])["results"] as! [[String: Any]]).compactMap { $0["feedUrl"] as? String }
            let index = ((input["Podcast Index"] as! [String: Any])["feeds"] as! [[String: Any]]).compactMap { $0["url"] as? String }
            var map = JavaHashMapOrder()
            (apple + index).forEach { map.put($0) }
            let oracle = try #require(expected[name])
            #expect(map.keys == oracle["hashmap_iteration"] as! [String], "\(name)")
            #expect(oracle["first_encounter_order_differs"] as? Bool == true)
        }
        #expect(PodcastSearchProvider.combined.name == (try Self.expected["search"] as? [String: Any])?["combined_name"] as? String)
    }

    @Test(arguments: ["apple_only", "pi_only", "fyyd_only"])
    func providerScreensKeepApiOrderAndDefaults(_ name: String) async throws {
        let cases = try #require(try Self.inputs["search"] as? [String: Any])["per_provider"] as! [[String: Any]]
        let input = try #require(cases.first { $0["name"] as? String == name })
        let provider: PodcastSearchProvider = switch input["provider"] as! String {
        case "Apple": .apple
        case "Podcast Index": .podcastIndex
        default: .fyyd
        }
        let body = try Self.data(input["response"]!)
        let seen = Locked<[URLRequest]>([])
        let client = PodcastSearchClient(indexKey: "test-key", indexSecret: "test-secret", send: { request in
            seen.value.append(request); return (body, 200)
        })
        let results = try await client.search(input["query"] as! String, provider: provider)
        let oracle = try #require((try Self.expected["search"] as? [String: Any])?["per_provider"] as? [String: [String: Any]])[name]!
        let rows = oracle["results"] as! [[String: Any]]
        #expect(results.map(\.title) == rows.map { $0["title"] as! String })
        #expect(results.map(\.feedURL) == rows.map { $0["feedUrl"] as! String })
        #expect(results.map(\.author) == rows.map { $0["author"] as? String })
        #expect(String(format: "Results by %@", provider.name) == oracle["powered_by"] as! String)
        // Same endpoint and the same decoded query (the byte encoding of spaces is not visible).
        let sentURL = try #require(seen.value.first?.url)
        let sent = try #require(URLComponents(url: sentURL, resolvingAgainstBaseURL: false))
        let wanted = try #require(URLComponents(string: oracle["request_url"] as! String))
        #expect(sent.host == wanted.host && sent.path == wanted.path)
        func decoded(_ components: URLComponents) -> [String: String] {
            Dictionary(uniqueKeysWithValues: (components.percentEncodedQuery ?? "").split(separator: "&").map {
                let pair = $0.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" }
                return (pair[0], pair.count > 1 ? pair[1] : "")
            })
        }
        #expect(decoded(sent) == decoded(wanted))
    }

    @Test func fyydWithoutDataIsTheNullResponseError() async throws {
        let client = PodcastSearchClient(send: { _ in (Data("{\"status\":0}".utf8), 200) })
        await #expect(throws: PodcastSearchError.nullResponse) { try await client.search("x", provider: .fyyd) }
        #expect(PodcastSearchError.nullResponse.localizedDescription == "Null response")
    }

    // MARK: Add podcast inputs

    @Test func addressValidationAndSearchBoxRouteMatchAndroid() throws {
        let rows = try #require(try Self.expected["url_inputs"] as? [[String: Any]])
        #expect(rows.count == 28)
        for row in rows {
            let input = row["input"] as! String
            #expect(AddPodcastInput.isValidAddress(input) == row["add_by_url_dialog_valid"] as! Bool, "\(input)")
            let box = row["search_box"] as! [String: Any]
            switch AddPodcastInput.route(input) {
            case .feedPage(let url): #expect(box["route"] as? String == "feed_preview" && box["url"] as? String == url, "\(input)")
            case .combinedSearch(let query):
                #expect(box["route"] as? String == "combined_search", "\(input)")
                #expect((query != nil) == (box["submits"] as? Bool ?? false), "\(input)")
            }
            if let prepared = row["prepared"] as? String, let ours = try? FeedAddress.prepare(input) {
                #expect(ours == prepared, "\(input)")
            }
        }
    }

    // MARK: Online feed page documents

    private func page(_ name: String, base: String) throws -> Data {
        let text = try String(contentsOf: Self.fixtures.appendingPathComponent("pages/" + name), encoding: .utf8)
        return Data(text.replacingOccurrences(of: "{BASE}", with: base).utf8)
    }

    @Test func documentsClassifyAndWebsitesOfferTheirFeedLinksInAndroidOrder() throws {
        let expected = try Self.expected
        let base = try #require(expected["base"] as? String)
        let pages = try #require(expected["pages"] as? [[String: Any]])
        #expect(pages.count == 15)
        for scenario in pages {
            let name = scenario["page"] as! String, requested = scenario["requested_url"] as! String
            let body = try page(name, base: base)
            let classification = scenario["classification"] as! [String: Any]
            let kind = FeedDocumentClassifier.classify(body)
            if classification["kind"] as? String == "feed" {
                #expect(kind == .feed, "\(name)")
                continue
            }
            let root = classification["root"] as? String
            #expect(kind == .unsupported(root: root, message: classification["message"] as! String), "\(name)")
            // Relative links follow RFC 3986; every other page follows the Android outcome.
            let outcome = (scenario["recommended_rfc3986"] ?? scenario["android"]) as! [String: Any]
            let links = root == "html" ? FeedDiscoverer.findLinks(in: String(decoding: body, as: UTF8.self), base: requested) : []
            switch outcome["outcome"] as! String {
            case "open_single": #expect(links.map(\.url) == [outcome["url"] as! String], "\(name)")
            case "chooser":
                let items = outcome["items"] as! [[String: String]]
                #expect(links.map(\.url) == items.map { $0["url"]! }, "\(name)")
                #expect(links.map(\.label) == items.map { $0["label"]! }, "\(name)")
                #expect(outcome["title"] as? String == "Subscriptions")
            default:
                #expect(links.isEmpty, "\(name)")
                let dialog = outcome["dialog"] as! [String: Any]
                let failure = OnlineFeedFailure(document: root, message: classification["message"] as! String,
                                                manual: scenario["manual"] as! Bool)
                let composed = OnlineFeedFailure.message(label: Self.strings[failure.labelKey]!, details: failure.details,
                                                         url: requested, template: Self.template)
                #expect(composed.text == dialog["message"] as! String, "\(name)")
                #expect(composed.labelLength == dialog["secondary_text_from"] as! Int, "\(name)")
            }
        }
    }

    @Test func manyLinksPageOrderDiffersFromDocumentOrderAndFollowsTheServedBase() throws {
        // The fixture server used by the app tests serves the same pages on 127.0.0.1:18820.
        let links = FeedDiscoverer.findLinks(in: String(decoding: try page("website-many-links.html", base: "http://127.0.0.1:18820"), as: UTF8.self),
                                             base: "http://127.0.0.1:18820/pages/website-many-links.html")
        #expect(links.map(\.label) == ["MP3 Feed (renamed)", "Comments", "AAC Feed", "http://127.0.0.1:18820/feeds/atom.xml"])
    }

    @Test func feedFetcherHandsTheOnlineFeedPageTheWebsiteBody() async throws {
        let body = try page("website-many-links.html", base: "http://127.0.0.1:18820")
        let fetcher = FeedFetcher(transport: StaticTransport(body: body))
        do {
            _ = try await fetcher.fetch(FeedFetchRequest(source: "http://127.0.0.1:18820/pages/website-many-links.html", force: true, classifiesDocuments: true))
            Issue.record("A website is not a feed")
        } catch let FeedDocumentError.unsupported(root, message, received) {
            #expect(root == "html" && message == "Website title: \"Many Feeds\"" && received == body)
        }
        // Refresh keeps its established classification.
        await #expect(throws: FeedFetchError.websiteInsteadOfFeed) {
            _ = try await fetcher.fetch(FeedFetchRequest(source: "http://127.0.0.1:18820/pages/website-many-links.html", force: true))
        }
        let broken = FeedFetcher(transport: StaticTransport(body: try page("feed-broken.xml", base: "")))
        await #expect(throws: FeedDocumentError.self) {
            _ = try await broken.fetch(FeedFetchRequest(source: "http://127.0.0.1:18820/pages/feed-broken.xml", force: true, classifiesDocuments: true))
        }
    }

    // MARK: Error dialogs

    static let template = "%1$@ \n\nTechnical reason: \n%2$@ \n\nFile URL:\n%3$@"
    static let strings = [
        "download_error_unsupported_type_html": "The podcast host's server sent a website, not a podcast.",
        "download_error_unsupported_type_html_manual": "The address you entered is a website address, not a podcast RSS address.",
        "download_error_parser_exception": "The podcast host's server sent a broken podcast feed. We recommend checking with a podcast validator such as castfeedvalidator.com and contacting the podcast creator to let them know.",
        "download_error_not_found": "The podcast host's server does not know where to find the file. It may have been deleted.",
        "download_error_http_data_error": "HTTP data error",
        "download_error_forbidden": "The podcast host's server refuses to respond.",
    ]

    @Test func downloadFailuresUseTheSourceLabelsAndTechnicalReasons() throws {
        let dialogs = try #require(try Self.expected["error_dialogs"] as? [String: Any])
        let notFound = OnlineFeedFailure(.notFound(status: 404), diagnostic: nil)
        let composed = OnlineFeedFailure.message(label: Self.strings[notFound.labelKey]!, details: notFound.details,
                                                 url: "http://127.0.0.1:18820/missing.xml", template: Self.template)
        let manual = dialogs["http_404_manual"] as! [String: Any]
        #expect(composed.text == manual["message"] as! String && composed.labelLength == manual["secondary_text_from"] as! Int)
        let server = OnlineFeedFailure(.httpStatus(500), diagnostic: nil)
        let search = dialogs["http_500_search_result"] as! [String: Any]
        #expect(OnlineFeedFailure.message(label: Self.strings[server.labelKey]!, details: server.details,
                                          url: "http://127.0.0.1:18820/error.xml", template: Self.template).text == search["message"] as! String)
        #expect(OnlineFeedFailure(.forbidden, diagnostic: nil) == .init(labelKey: "download_error_forbidden", details: "403"))
        #expect(OnlineFeedFailure(.notFound(status: 410), diagnostic: nil) == .init(labelKey: "download_error_not_found", details: "410"))
    }

    // MARK: Select country

    @Test func countryListUsesCodeUnitOrderAndOkSelectsOnlyAnExactName() throws {
        let names = try #require(try Self.inputs["countries"] as? [String: String])
        let countries = DiscoveryCountries(names.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
        let expected = try #require(try Self.expected["countries"] as? [String: Any])
        #expect(countries.names == expected["sorted_utf16"] as! [String])
        let hidden = DiscoveryPreferences(countryCode: nil, hidden: true)
        let valid = expected["ok_valid"] as! [String: Any], invalid = expected["ok_invalid_text"] as! [String: Any]
        #expect(countries.confirm("Germany", current: hidden, device: "US") == .init(countryCode: valid["country"] as? String, hidden: valid["hidden"] as! Bool))
        #expect(countries.confirm("germany", current: hidden, device: "US") == .init(countryCode: invalid["country"] as? String, hidden: invalid["hidden"] as! Bool))
        #expect(countries.confirm("", current: hidden, device: "US") == .init(countryCode: "US", hidden: true))
        // The dropdown filter: start of the name or of one of its words, ignoring case.
        #expect(countries.matches("un") == ["United Arab Emirates", "United Kingdom", "United States"])
        #expect(countries.matches("islands") == ["Turks & Caicos Islands", "U.S. Outlying Islands", "Åland Islands"])
        #expect(countries.matches("") == countries.names)
    }

    @Test @MainActor func discoveryPreferencesPersist() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("discovery-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = try DiscoveryPreferenceStore(file: file)
        #expect(store.value == .init())
        try store.update(.init(countryCode: "DE", hidden: true))
        #expect(try DiscoveryPreferenceStore(file: file).value == .init(countryCode: "DE", hidden: true))
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private struct StaticTransport: FeedHTTPTransport {
    let body: Data
    func requestScope() throws -> any FeedHTTPTransport { self }
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
        FeedHTTPResponse(url: request.url!, status: 200, body: body)
    }
}
