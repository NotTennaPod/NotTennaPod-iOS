import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.timeLimit(.minutes(1)))
struct FeedNetworkTests {
    @Test func actualURLSessionFollowsRedirectAndRetainsFirstPermanentTarget() async throws {
        let server = try await LoopbackHTTPServer.start { request in
            switch request.path {
            case "/feed": .init(status: 301, headers: ["Location": "/permanent"], body: Data())
            case "/permanent": .init(status: 302, headers: ["Location": "/final"], body: Data())
            default: .init(headers: ["ETag": "\"version1\""])
            }
        }
        defer { server.stop() }
        let result = try await FeedFetcher().fetch(FeedFetchRequest(source: server.url.absoluteString))
        guard case .updated(let value) = result else { Issue.record("Expected downloaded feed"); return }
        #expect(value.feed.title == "Network podcast")
        #expect(value.responseURL.path == "/final")
        #expect(value.permanentRedirectURL == server.url.deletingLastPathComponent().appendingPathComponent("permanent").absoluteString)
        #expect(value.validator == "\"version1\"")
        #expect(server.requests.map(\.path) == ["/feed", "/permanent", "/final"])
        #expect(server.requests.allSatisfy { $0.headers["cache-control"] == "no-store" && $0.method == "GET" })
    }

    @Test func actualURLSessionSupportsPrivateFeedChallengeAndEncodingRetry() async throws {
        let server = try await LoopbackHTTPServer.start { request in
            if request.headers["authorization"] == "Basic w6k6wqM=" { return .init() }
            return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"Podcast\""], body: Data())
        }
        defer { server.stop() }
        let result = try await FeedFetcher().fetch(FeedFetchRequest(
            source: server.url.absoluteString, credentials: FeedCredentials(username: "é", password: "£")
        ))
        guard case .updated = result else { Issue.record("Expected authenticated feed"); return }
        #expect(server.requests.map { $0.headers["authorization"] } == [nil, "Basic 6Tqj", "Basic w6k6wqM="])
    }

    @Test func actualURLSessionDoesNotReuseCredentialsForLaterRequests() async throws {
        let server = try await LoopbackHTTPServer.start { request in
            if request.headers["authorization"] == "Basic dXNlcjpwYXNz" { return .init() }
            return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"Podcast\""], body: Data())
        }
        defer { server.stop() }
        let fetcher = FeedFetcher()
        _ = try await fetcher.fetch(FeedFetchRequest(source: server.url.absoluteString,
                                                   credentials: FeedCredentials(username: "user", password: "pass")))
        await #expect(throws: FeedFetchError.unauthorized) {
            try await fetcher.fetch(FeedFetchRequest(source: server.url.absoluteString))
        }
        #expect(server.requests.map { $0.headers["authorization"] } == [nil, "Basic dXNlcjpwYXNz", nil])
    }

    @Test func actualURLSessionDecompressesGzipBeforeParsing() async throws {
        let compressed = try #require(Data(base64Encoded: "H4sIAAAAAAAC/7MpKi62s0nOSMzLS82xsynJLMlJtXPOzy0oSi0uTk1RKMhPSU4sLrHRh8jY6MOV6oN0AgBNMuMMPwAAAA=="))
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Encoding": "gzip", "Content-Type": "application/rss+xml"], body: compressed)
        }
        defer { server.stop() }
        let result = try await FeedFetcher().fetch(FeedFetchRequest(source: server.url.absoluteString))
        guard case .updated(let value) = result else { Issue.record("Expected decompressed feed"); return }
        #expect(value.feed.title == "Compressed podcast")
        #expect(server.requests.first?.headers["accept-encoding"]?.contains("gzip") == true)
    }

    /// A server that prefers Brotli when the client offers it. Android's OkHttp
    /// asks only for gzip, so the feed must arrive gzip-compressed and load.
    @Test func feedRequestsAskOnlyForGzipLikeAndroid() async throws {
        let gzip = try #require(Data(base64Encoded: "H4sIAAAAAAAC/7MpKi62s0nOSMzLS82xsynJLMlJtXPOzy0oSi0uTk1RKMhPSU4sLrHRh8jY6MOV6oN0AgBNMuMMPwAAAA=="))
        let brotli = try #require(Data(base64Encoded: "HzoAQI3UYs2cDqQnS1UKnyA1o9hszMULKOPAfbVmdAF/gjyxwZEKq7bDbr5LdjKcPw4E8A=="))
        let server = try await LoopbackHTTPServer.start { request in
            if request.headers["accept-encoding"]?.contains("br") == true {
                return .init(headers: ["Content-Encoding": "br", "Content-Type": "application/rss+xml"], body: brotli)
            }
            return .init(headers: ["Content-Encoding": "gzip", "Content-Type": "application/rss+xml"], body: gzip)
        }
        defer { server.stop() }
        let result = try await FeedFetcher().fetch(FeedFetchRequest(source: server.url.absoluteString))
        guard case .updated(let value) = result else { Issue.record("Expected the gzip feed"); return }
        #expect(value.feed.title == "Compressed podcast")
        #expect(server.requests.first?.headers["accept-encoding"] == "gzip")
    }

    /// A server that sends Brotli regardless: Content-Length counts the compressed bytes, so it must not be
    /// compared with the decoded body.
    @Test func unrequestedBrotliFeedStillLoads() async throws {
        let brotli = try #require(Data(base64Encoded: "HzoAQI3UYs2cDqQnS1UKnyA1o9hszMULKOPAfbVmdAF/gjyxwZEKq7bDbr5LdjKcPw4E8A=="))
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Encoding": "br", "Content-Type": "application/rss+xml"], body: brotli)
        }
        defer { server.stop() }
        let result = try await FeedFetcher().fetch(FeedFetchRequest(source: server.url.absoluteString))
        guard case .updated(let value) = result else { Issue.record("Expected the Brotli feed"); return }
        #expect(value.feed.title == "Brotli podcast")
    }

    @Test func actualConditionalRefreshReturnsUnchangedWithoutParsingEmptyBody() async throws {
        let server = try await LoopbackHTTPServer.start { request in
            if request.headers["if-none-match"] == "\"version1\"" { return .init(status: 304, body: Data()) }
            return .init(headers: ["ETag": "\"version1\""])
        }
        defer { server.stop() }
        let fetcher = FeedFetcher()
        let first = try await fetcher.fetch(FeedFetchRequest(source: server.url.absoluteString))
        guard case .updated(let value) = first else { Issue.record("Expected first download"); return }
        #expect(try await fetcher.fetch(FeedFetchRequest(source: server.url.absoluteString, validator: value.validator)) == .notModified)
        #expect(server.requests.count == 2)
    }

    @Test func cancellingSwiftTaskCancelsAnInFlightNetworkRequest() async throws {
        let server = try await LoopbackHTTPServer.start { _ in nil }
        defer { server.stop() }
        let task = Task { try await FeedFetcher().fetch(FeedFetchRequest(source: server.url.absoluteString)) }
        defer { task.cancel() }
        for _ in 0..<100 where server.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(server.requests.count == 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func chunkedTransferFeedsParseWithoutAContentLength() async throws {
        let xml = "<rss><channel><title>Chunked podcast</title></channel></rss>"
        let chunked = "\(String(xml.utf8.count, radix: 16))\r\n\(xml)\r\n0\r\n\r\n"
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Transfer-Encoding": "chunked"], body: Data(chunked.utf8))
        }
        defer { server.stop() }
        let result = try await FeedFetcher().fetch(FeedFetchRequest(source: server.url.absoluteString))
        guard case .updated(let value) = result else { Issue.record("Expected chunked feed"); return }
        #expect(value.feed.title == "Chunked podcast")
    }

    @Test func actualTransientStatusRetriesAreBounded() async throws {
        for status in [408, 503] {
            let server = try await LoopbackHTTPServer.start { _ in
                .init(status: status, headers: ["Retry-After": "0"], body: Data())
            }
            defer { server.stop() }
            await #expect(throws: FeedFetchError.httpStatus(status)) {
                try await FeedFetcher().fetch(FeedFetchRequest(source: server.url.absoluteString))
            }
            #expect(server.requests.count == 2)
        }
    }

    @Test func cookiesSurviveWithinTransportButNotAcrossIndependentTransports() async throws {
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Set-Cookie": "feed-session=fixture; Path=/"])
        }
        defer { server.stop() }
        let fetcher = FeedFetcher()
        _ = try await fetcher.fetch(FeedFetchRequest(source: server.url.absoluteString))
        _ = try await fetcher.fetch(FeedFetchRequest(source: server.url.absoluteString))
        _ = try await FeedFetcher().fetch(FeedFetchRequest(source: server.url.absoluteString))
        #expect(server.requests.map { $0.headers["cookie"] } == [nil, "feed-session=fixture", nil])
    }

    @Test func concurrentPrivateFeedsKeepTheirCredentialsAndResultsSeparate() async throws {
        let server = try await LoopbackHTTPServer.start { request in
            let name = String(request.path.dropFirst())
            let expected = "Basic " + Data("\(name):password".utf8).base64EncodedString()
            guard request.headers["authorization"] == expected else {
                return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"Podcast\""], body: Data())
            }
            return .init(body: Data("<rss><channel><title>\(name)</title></channel></rss>".utf8))
        }
        defer { server.stop() }
        let fetcher = FeedFetcher()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<16 {
                group.addTask {
                    let name = "private-\(index)"
                    let source = server.url.deletingLastPathComponent().appendingPathComponent(name).absoluteString
                    let result = try await fetcher.fetch(FeedFetchRequest(
                        source: source, credentials: FeedCredentials(username: name, password: "password")
                    ))
                    guard case .updated(let value) = result else { Issue.record("Expected private feed"); return }
                    #expect(value.feed.title == name)
                }
            }
            try await group.waitForAll()
        }
        #expect(server.requests.count == 32)
        for index in 0..<16 {
            let requests = server.requests.filter { $0.path == "/private-\(index)" }
            #expect(requests.count == 2)
            #expect(requests.first?.headers["authorization"] == nil)
            #expect(requests.last?.headers["authorization"] != nil)
        }
    }
}
