import Foundation
import Testing
@testable import NotTennaPodCore

private actor ScriptedFeedTransport: FeedHTTPTransport {
    struct Reply: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body = Data("<rss><channel><title>Podcast</title><item><title>Episode</title></item></channel></rss>".utf8)
        var error: URLError.Code?
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else {
            Issue.record("Unexpected extra request")
            throw URLError(.unknown)
        }
        let reply = replies.removeFirst()
        if let error = reply.error { throw URLError(error) }
        return FeedHTTPResponse(url: request.url!, status: reply.status, headers: reply.headers, body: reply.body)
    }
}

struct FeedFetcherTests {
    private let source = "http://example.test/feed"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func requestHeadersAndValidationRules() async throws {
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let boundary = formatter.string(from: clock.addingTimeInterval(-3 * 86_400))
        let inside = formatter.string(from: clock.addingTimeInterval(-3 * 86_400 + 1))
        let future = formatter.string(from: clock.addingTimeInterval(1_000))
        for (validator, force, modified, etag) in [
            (nil, false, nil, nil), ("", false, nil, nil), ("\"etag\"", false, nil, "\"etag\""),
            ("W/\"etag\"", false, nil, "W/\"etag\""), (boundary, false, nil, nil),
            (inside, false, inside, nil), (future, false, future, nil), (inside, true, nil, nil),
            ("\"etag\"", true, nil, nil)
        ] as [(String?, Bool, String?, String?)] {
            let transport = ScriptedFeedTransport([.init(status: 304, body: Data())])
            let result = try await FeedFetcher(transport: transport, userAgent: "AntennaPod/test", clock: { clock })
                .fetch(FeedFetchRequest(source: source, validator: validator, force: force))
            #expect(result == .notModified)
            let request = try #require(await transport.requests.first)
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "AntennaPod/test")
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
            #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "gzip")
            #expect(request.value(forHTTPHeaderField: "Upgrade-Insecure-Requests") == "1")
            #expect(request.value(forHTTPHeaderField: "If-Modified-Since") == modified)
            #expect(request.value(forHTTPHeaderField: "If-None-Match") == etag)
            #expect(request.value(forHTTPHeaderField: "Range") == nil)
        }
    }

    @Test func responseValidatorsPreferLastModifiedEvenWhenEmpty() async throws {
        for headers in [["Last-Modified": "date", "ETag": "tag"], ["lAsT-mOdIfIeD": "", "ETag": "tag"], ["etag": "tag"], [:]] {
            let transport = ScriptedFeedTransport([.init(headers: headers)])
            let result = try await FeedFetcher(transport: transport).fetch(FeedFetchRequest(source: source))
            guard case .updated(let value) = result else { Issue.record("Missing updated feed"); continue }
            #expect(value.validator == (headers["Last-Modified"] ?? headers["lAsT-mOdIfIeD"] ?? headers["etag"]))
            #expect(value.feed.title == "Podcast")
            #expect(value.feed.episodes.first?.title == "Episode")
            #expect(value.feed.imageURL == "antennapod_generative_cover:" + source)
        }
    }

    @Test func initialPreviewPreservesMissingArtworkWhileRefreshGeneratesIt() async throws {
        for image in [nil, "https://example.test/art.png"] as [String?] {
            let imageXML = image.map { "<image><url>\($0)</url></image>" } ?? ""
            let xml = "<rss><channel><title>Podcast</title>\(imageXML)</channel></rss>"
            for generate in [false, true] {
                let transport = ScriptedFeedTransport([.init(body: Data(xml.utf8))])
                let result = try await FeedFetcher(transport: transport).fetch(
                    FeedFetchRequest(source: source, generateMissingArtwork: generate))
                guard case .updated(let fetched) = result else { Issue.record("Missing fetched preview"); continue }
                #expect(fetched.feed.imageURL == (image ?? (generate ? "antennapod_generative_cover:" + source : nil)))
            }
        }
    }

    @Test func allHTTPStatusCategories() async throws {
        for status in 200...599 {
            let transport = ScriptedFeedTransport(Array(repeating: .init(status: status), count: status == 408 ? 2 : 1))
            let fetcher = FeedFetcher(transport: transport)
            if (200..<300).contains(status) {
                guard case .updated = try await fetcher.fetch(FeedFetchRequest(source: source)) else {
                    Issue.record("Expected 2xx success for \(status)"); continue
                }
            } else if status == 304 {
                #expect(try await fetcher.fetch(FeedFetchRequest(source: source)) == .notModified)
            } else {
                let expected: FeedFetchError
                switch status {
                case 401: expected = .unauthorized
                case 403: expected = .forbidden
                case 404, 410: expected = .notFound(status: status)
                case 407: expected = .io(code: nil)
                default: expected = .httpStatus(status)
                }
                await #expect(throws: expected) { try await fetcher.fetch(FeedFetchRequest(source: source)) }
            }
        }
    }

    @Test func firstRedirectDeterminesPermanentUpdate() async throws {
        for first in [300, 301, 302, 303, 307, 308] {
            let transport = ScriptedFeedTransport([
                .init(status: first, headers: ["Location": "/first"]),
                .init(status: 301, headers: ["Location": "https://cdn.test/final"]), .init()
            ])
            let result = try await FeedFetcher(transport: transport).fetch(FeedFetchRequest(source: source))
            guard case .updated(let value) = result else { Issue.record("Expected feed"); continue }
            #expect(value.responseURL.absoluteString == "https://cdn.test/final")
            #expect(value.permanentRedirectURL == ([301, 308].contains(first) ? "http://example.test/first" : nil))
            #expect(await transport.requests.count == 3)
        }
        let upgrade = ScriptedFeedTransport([.init(status: 302, headers: ["Location": "https://example.test/feed"]), .init()])
        guard case .updated(let value) = try await FeedFetcher(transport: upgrade).fetch(FeedFetchRequest(source: source)) else {
            Issue.record("Expected upgraded feed"); return
        }
        #expect(value.permanentRedirectURL == "https://example.test/feed")
    }

    @Test func redirectsAreBoundedAndUnsupportedLocationsFail() async {
        let loop = ScriptedFeedTransport(Array(repeating: .init(status: 302, headers: ["Location": "/feed"]), count: 21))
        await #expect(throws: FeedFetchError.tooManyRedirects) {
            try await FeedFetcher(transport: loop).fetch(FeedFetchRequest(source: source))
        }
        #expect(await loop.requests.count == 21)
        let file = ScriptedFeedTransport([.init(status: 302, headers: ["Location": "file:///tmp/feed"])])
        await #expect(throws: FeedFetchError.httpStatus(302)) {
            try await FeedFetcher(transport: file).fetch(FeedFetchRequest(source: source))
        }
    }

    @Test func privateFeedRetriesLatin1ThenUTF8OnlyAfterUnauthorized() async throws {
        let transport = ScriptedFeedTransport([.init(status: 401), .init(status: 401), .init()])
        _ = try await FeedFetcher(transport: transport).fetch(FeedFetchRequest(
            source: source, credentials: FeedCredentials(username: "é", password: "£")
        ))
        let requests = await transport.requests
        #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [nil, "Basic 6Tqj", "Basic w6k6wqM="])
        let success = ScriptedFeedTransport([.init()])
        _ = try await FeedFetcher(transport: success).fetch(FeedFetchRequest(
            source: source, credentials: FeedCredentials(username: "user", password: "password")
        ))
        #expect(await success.requests.count == 1)
        #expect(await success.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func embeddedCredentialsTakePrecedenceAndLeaveTheWireURL() async throws {
        let transport = ScriptedFeedTransport([.init(status: 401), .init()])
        _ = try await FeedFetcher(transport: transport).fetch(FeedFetchRequest(
            source: "https://user:pass@example.test/feed#fragment", credentials: FeedCredentials(username: "ignored", password: "ignored")
        ))
        let requests = await transport.requests
        #expect(requests.map { $0.url?.absoluteString } == ["https://example.test/feed", "https://example.test/feed"])
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Basic dXNlcjpwYXNz")
        #expect(requests.first?.value(forHTTPHeaderField: "Upgrade-Insecure-Requests") == nil)
    }

    @Test(arguments: [false, true])
    func redirectChallengesOnlyReceiveCredentialsForTheirOriginalOrigin(embedded: Bool) async throws {
        // Independently specified origin boundaries; neither a redirect nor a
        // matching realm grants another origin access to saved credentials.
        let cases: [(String, String, Bool)] = [
            ("https://example.test/feed", "/private", true),
            ("https://EXAMPLE.test:443/feed", "https://example.TEST/private", true),
            ("http://example.test/feed", "http://EXAMPLE.test:80/private", true),
            ("https://example.test:8443/feed", "https://example.test:8443/private", true),
            ("https://example.test/feed", "https://other.test/feed", false),
            ("https://example.test/feed", "https://private.example.test/feed", false),
            ("https://example.test/feed", "https://example.test.evil.test/feed", false),
            ("https://example.test/feed", "https://example.test:8443/feed", false),
            ("https://example.test:8443/feed", "https://example.test/feed", false),
            ("https://example.test/feed", "http://example.test/feed", false),
            ("http://example.test/feed", "https://example.test/feed", false),
            ("http://example.test:8080/feed", "http://example.test:8081/feed", false)
        ]
        for (source, target, permitted) in cases {
            var address = try #require(URLComponents(string: source))
            if embedded { address.user = "user"; address.password = "pass" }
            let transport = ScriptedFeedTransport([
                .init(status: 301, headers: ["Location": target]), .init(status: 401),
                .init(status: permitted ? 200 : 401), .init(status: 401)
            ])
            let fetcher = FeedFetcher(transport: transport)
            let input = FeedFetchRequest(source: try #require(address.string),
                credentials: .init(username: embedded ? "ignored" : "user", password: embedded ? "ignored" : "pass"))
            if permitted {
                guard case .updated = try await fetcher.fetch(input) else {
                    Issue.record("Expected same-origin authentication: \(source) → \(target)"); continue
                }
            } else {
                await #expect(throws: FeedFetchError.unauthorized) { try await fetcher.fetch(input) }
            }
            let requests = await transport.requests
            #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") }
                == (permitted ? [nil, nil, "Basic dXNlcjpwYXNz"] : [nil, nil]), "\(source) → \(target)")
            #expect(requests.allSatisfy { $0.url?.user == nil && $0.url?.password == nil })
        }
    }

    @Test func authenticatedRedirectCannotTriggerAnEncodingRetryAtAnotherOrigin() async throws {
        let transport = ScriptedFeedTransport([
            .init(status: 401), .init(status: 302, headers: ["Location": "https://other.test/feed"]),
            .init(status: 401), .init(status: 302, headers: ["Location": "https://other.test/feed"]), .init(status: 401)
        ])
        await #expect(throws: FeedFetchError.unauthorized) {
            try await FeedFetcher(transport: transport).fetch(.init(source: source, credentials: .init(username: "é", password: "£")))
        }
        let requests = await transport.requests
        #expect(requests.map { $0.url?.host } == ["example.test", "example.test", "other.test"])
        #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [nil, "Basic 6Tqj", nil])
    }

    @Test func sameOriginEncodingRetryUsesTheLatestChallengedURL() async throws {
        let transport = ScriptedFeedTransport([
            .init(status: 401), .init(status: 302, headers: ["Location": "/private"]),
            .init(status: 401), .init()
        ])
        _ = try await FeedFetcher(transport: transport).fetch(.init(source: source, credentials: .init(username: "é", password: "£")))
        let requests = await transport.requests
        #expect(requests.map { $0.url?.path } == ["/feed", "/feed", "/private", "/private"])
        #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") }
            == [nil, "Basic 6Tqj", "Basic 6Tqj", "Basic w6k6wqM="])
    }

    /// Any root other than rss/feed is a website on Android: TypeGetter hands it to jsoup, whose document
    /// root is always <html> (Android oracle, Fixtures/HostileFeeds/expected/android.jsonl).
    @Test func validationPreventsPartialOrTitlelessFeedsFromBeingPublished() async {
        for (xml, expected) in [
            ("<rss><channel/></rss>", FeedFetchError.missingFeedTitle),
            ("<rss><channel><title>Feed</title><item/></channel></rss>", .missingEpisodeTitle(index: 0)),
            ("<html><title>Website</title></html>", .websiteInsteadOfFeed), ("<other/>", .websiteInsteadOfFeed),
            ("<rss version=\"1.0\"><channel><title>Feed</title></channel></rss>", .unsupportedFeed), ("", .unsupportedFeed)
        ] {
            let transport = ScriptedFeedTransport([.init(body: Data(xml.utf8))])
            await #expect(throws: expected) { try await FeedFetcher(transport: transport).fetch(FeedFetchRequest(source: source)) }
        }
    }

    @Test func sizeMismatchFailsButGzipDoesNotCompareCompressedLength() async throws {
        let wrong = ScriptedFeedTransport([.init(headers: ["Content-Length": "1000"], body: Data("abc".utf8))])
        await #expect(throws: FeedFetchError.wrongSize(expected: 1000, received: 3)) {
            try await FeedFetcher(transport: wrong).fetch(FeedFetchRequest(source: source))
        }
        let gzip = ScriptedFeedTransport([.init(headers: ["Content-Length": "10", "Content-Encoding": "GZIP"])])
        guard case .updated = try await FeedFetcher(transport: gzip).fetch(FeedFetchRequest(source: source)) else {
            Issue.record("Expected gzip response to parse"); return
        }
        for encoding in ["br", "deflate", " Br "] {
            let encoded = ScriptedFeedTransport([.init(headers: ["Content-Length": "10", "Content-Encoding": encoding])])
            guard case .updated = try await FeedFetcher(transport: encoded).fetch(FeedFetchRequest(source: source)) else {
                Issue.record("Expected \(encoding) response to parse"); return
            }
        }
        let identity = ScriptedFeedTransport([.init(headers: ["Content-Length": "1000", "Content-Encoding": "identity"],
                                                    body: Data("abc".utf8))])
        await #expect(throws: FeedFetchError.wrongSize(expected: 1000, received: 3)) {
            try await FeedFetcher(transport: identity).fetch(FeedFetchRequest(source: source))
        }
    }

    @Test func networkErrorsAndCancellationStayDistinct() async {
        for (code, expected) in [
            (URLError.timedOut, FeedFetchError.connection), (.cannotConnectToHost, .connection),
            (.cannotFindHost, .unknownHost), (.dnsLookupFailed, .unknownHost),
            (.serverCertificateUntrusted, .certificate), (.appTransportSecurityRequiresSecureConnection, .blocked),
            (.notConnectedToInternet, .io(code: URLError.notConnectedToInternet.rawValue))
        ] {
            let transport = ScriptedFeedTransport([.init(error: code)])
            await #expect(throws: expected) { try await FeedFetcher(transport: transport).fetch(FeedFetchRequest(source: source)) }
        }
        let cancelled = ScriptedFeedTransport([.init(error: .cancelled)])
        await #expect(throws: CancellationError.self) {
            try await FeedFetcher(transport: cancelled).fetch(FeedFetchRequest(source: source))
        }
    }

    @Test func retryAfterRulesMatchThePinnedOkHTTPClient() async throws {
        for status in [408, 503] {
            for retryAfter in [nil, "0", "00", "1", "-1", "garbage", "Wed, 01 Jan 2020 00:00:00 GMT"] as [String?] {
                let shouldRetry = retryAfter == "0" || retryAfter == "00" || (status == 408 && retryAfter == nil)
                let headers = retryAfter.map { ["Retry-After": $0] } ?? [:]
                let transport = ScriptedFeedTransport([.init(status: status, headers: headers), .init()])
                let fetcher = FeedFetcher(transport: transport)
                if shouldRetry {
                    guard case .updated = try await fetcher.fetch(FeedFetchRequest(source: source)) else {
                        Issue.record("Expected immediate retry"); continue
                    }
                    #expect(await transport.requests.count == 2)
                } else {
                    await #expect(throws: FeedFetchError.httpStatus(status)) {
                        try await fetcher.fetch(FeedFetchRequest(source: source))
                    }
                    #expect(await transport.requests.count == 1)
                }
            }
        }
        let repeated = ScriptedFeedTransport(Array(repeating: .init(status: 503, headers: ["Retry-After": "0"]), count: 2))
        await #expect(throws: FeedFetchError.httpStatus(503)) {
            try await FeedFetcher(transport: repeated).fetch(FeedFetchRequest(source: source))
        }
        #expect(await repeated.requests.count == 2)
    }

    @Test func emptyTitlesRemainValidAndHTTPRedirectWinsOverFeedRedirect() async throws {
        let xml = """
        <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title/>
        <itunes:new-feed-url>https://feed-directed.test/feed</itunes:new-feed-url><itunes:image href=""/>
        <item><title/></item></channel></rss>
        """
        let transport = ScriptedFeedTransport([
            .init(status: 301, headers: ["Location": "https://http-directed.test/feed"]), .init(body: Data(xml.utf8))
        ])
        guard case .updated(let value) = try await FeedFetcher(transport: transport).fetch(FeedFetchRequest(source: source)) else {
            Issue.record("Expected feed with empty titles"); return
        }
        #expect(value.feed.title == "")
        #expect(value.feed.episodes.first?.title == "")
        #expect(value.feed.imageURL == "antennapod_generative_cover:" + source)
        #expect(value.feed.redirectURL == "https://feed-directed.test/feed")
        #expect(value.proposedSourceUpdate == "https://http-directed.test/feed")
    }
}

/// A server library's fetches: what the subscribe flow accepts is what the parity parse
/// reads, and the server's fetch bounds hold (64 MiB, one 120 s deadline for the fetch and its parse). Standalone
/// fetching is unchanged.
@Suite(.timeLimit(.minutes(1))) struct ServerLibraryFetchTests {
    private let source = "http://example.test/feed"

    /// Valid RSS the app's parser reads but the server's (and the parity) parser refuses: a `psc:chapter` outside
    /// `psc:chapters` (`S/internal/feed/handlers.go`).
    static let refusedByParity = Data("""
        <?xml version="1.0"?><rss version="2.0" xmlns:psc="http://podlove.org/simple-chapters"><channel><title>Show</title>\
        <item><title>One</title><guid>g1</guid><psc:chapter start="00:00:01" title="Intro"/></item></channel></rss>
        """.utf8)

    private func fetch(_ body: Data, parity: Bool, classifies: Bool) async throws -> FeedFetchResult {
        try await FeedFetcher(transport: ScriptedFeedTransport([.init(body: body)])).fetch(
            FeedFetchRequest(source: source, force: true, generateMissingArtwork: false, classifiesDocuments: classifies, parity: parity))
    }

    @Test func aServerLibrarysSubscriptionNeverAcceptsAFeedItsRefreshRefuses() async throws {
        await #expect(throws: FeedFetchError.self) { _ = try await fetch(Self.refusedByParity, parity: true, classifies: false) }
        do {
            _ = try await fetch(Self.refusedByParity, parity: true, classifies: true)
            Issue.record("the subscribe flow accepted a feed the server library refuses")
        } catch FeedDocumentError.broken(let message) {
            #expect(!message.isEmpty, "a parser error, as the subscribe flow shows one")
        }
        guard case .updated(let standalone) = try await fetch(Self.refusedByParity, parity: false, classifies: true) else {
            Issue.record("standalone"); return
        }
        #expect(standalone.catalog == nil && standalone.feed.title == "Show", "a standalone library reads it as before")
        // A website still goes to feed discovery, and a feed both read carries the parity catalog.
        await #expect(throws: FeedDocumentError.self) {
            _ = try await fetch(Data("<html><head><title>Site</title></head><body/></html>".utf8), parity: true, classifies: true)
        }
        let good = Data("<rss version=\"2.0\"><channel><title>Show</title><item><title>One</title><guid>g1</guid></item></channel></rss>".utf8)
        guard case .updated(let fetched) = try await fetch(good, parity: true, classifies: true) else { Issue.record("not fetched"); return }
        #expect(fetched.catalog?.items.count == 1)
    }

    /// The server's body limit (`maxBody`, 64 MiB): a larger response fails as the server's fetch does, as declared
    /// and while streaming; a standalone fetch has no such limit, and a feed within it is read.
    @Test func aServerLibrarysFetchHasTheServersBodyLimit() async throws {
        let feed = Data("<rss version=\"2.0\"><channel><title>Show</title><item><title>One</title><guid>g1</guid></item></channel></rss>".utf8)
        let large = Data(count: FeedFetcher.serverBodyLimit + 1)
        let server = try await LoopbackHTTPServer.start { request in
            switch request.path {
            case "/large": .init(body: large)
            default: .init(body: feed)
            }
        }
        defer { server.stop() }
        let base = "http://127.0.0.1:\(server.url.port!)"
        let fetcher = FeedFetcher(transport: URLSessionFeedTransport())
        do {
            _ = try await fetcher.fetch(FeedFetchRequest(source: base + "/large", force: true, parity: true))
            Issue.record("a body over the server's limit was read")
        } catch FeedFetchError.parsing(.limitExceeded(let message)) {
            #expect(message.hasPrefix("size_limit"))
        }
        guard case .updated(let fetched) = try await fetcher.fetch(FeedFetchRequest(source: base + "/feed", force: true, parity: true)) else {
            Issue.record("not fetched"); return
        }
        #expect(fetched.catalog?.items.count == 1, "a feed within the limit is read through the limited path")
        // Without a declared length the read stops at the limit. A server of its own, so the rest of the body follows
        // its first part only once that has been sent (the count of sent responses is this request's alone).
        let streamServer = try await LoopbackHTTPServer.start { _ in
            .init(body: Data(repeating: 0x20, count: 600), keepConnectionOpen: true, includeAutomaticContentLength: false)
        }
        defer { streamServer.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(streamServer.url.port!)/stream")!)
        request.timeoutInterval = 30
        let transport = URLSessionFeedTransport()
        let streaming = Task { try await transport.send(request, bodyLimit: 1_000) }
        while streamServer.sentResponseCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try await streamServer.appendResponseBody(Data(repeating: 0x20, count: 600), toLatestRequestFor: "/stream", isFinal: false)
        await #expect(throws: FeedBodyLimitExceeded.self) { _ = try await streaming.value }
        // A standalone fetch asks for no limit.
        let recording = LimitRecordingTransport(body: feed)
        _ = try await FeedFetcher(transport: recording).fetch(FeedFetchRequest(source: source, force: true))
        _ = try await FeedFetcher(transport: recording).fetch(FeedFetchRequest(source: source, force: true, parity: true))
        #expect(await recording.limits == [nil, FeedFetcher.serverBodyLimit])
    }

    /// One deadline for a server library's fetch and parse (the server's `FetchLimit`): when it passes, the fetch is
    /// cancelled and fails as the server's does, however slow the feed.
    @Test func aServerLibrarysFetchHasTheServersDeadline() async throws {
        let fetcher = FeedFetcher(transport: SilentTransport(), parityDeadline: .milliseconds(200))
        do {
            _ = try await fetcher.fetch(FeedFetchRequest(source: source, force: true, parity: true))
            Issue.record("no deadline")
        } catch FeedFetchError.parsing(.limitExceeded(let message)) {
            #expect(message.hasPrefix("time_limit"))
        }
        #expect(FeedFetcher.serverFetchLimit == .seconds(120))
    }
}

/// Records whether each request was limited.
private actor LimitRecordingTransport: FeedHTTPTransport {
    let body: Data
    private(set) var limits: [Int?] = []
    init(body: Data) { self.body = body }
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
        limits.append(nil)
        return FeedHTTPResponse(url: request.url!, status: 200, body: body)
    }
    func send(_ request: URLRequest, bodyLimit: Int) async throws -> FeedHTTPResponse {
        limits.append(bodyLimit)
        return FeedHTTPResponse(url: request.url!, status: 200, body: body)
    }
}

/// A feed that never answers until its request is cancelled.
private struct SilentTransport: FeedHTTPTransport {
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
        try await Task.sleep(for: .seconds(3_600))
        throw URLError(.timedOut)
    }
}
