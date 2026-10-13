import Foundation
import Testing
@testable import NotTennaPodCore

private actor DirectoryRequests {
    var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
}
@Suite struct PodcastSearchTests {
    @Test func providerRequestsDecodeEncodeAndAuthenticate() async throws {
        let tape = DirectoryRequests()
        let client = PodcastSearchClient(indexKey: "test-key", indexSecret: "test-secret", now: { Date(timeIntervalSince1970: 1_700_000_000) }) { request in
            await tape.record(request)
            let json: String
            switch request.url!.host! {
            case "itunes.apple.com": json = #"{"results":[{"collectionName":"Apple title","feedUrl":"https://a/feed","artistName":"Author","artworkUrl100":"https://a/image"},{"collectionName":"no feed"},{"feedUrl":"https://unknown/feed"}]}"#
            case "api.podcastindex.org": json = #"{"feeds":[{"title":"Index title","url":"https://b/feed","author":"  ","image":"https://b/image"},{"title":"no feed"}]}"#
            default: json = #"{"data":[{"title":"Fyyd title","xmlURL":"https://c/feed","thumbImageURL":"https://c/image","author":"Fyyd author"}]}"#
            }
            return (Data(json.utf8), 200)
        }
        let query = "C++ & café/?"
        let apple = try await client.search(query, provider: .apple)
        let index = try await client.search(query, provider: .podcastIndex)
        let fyyd = try await client.search(query, provider: .fyyd)
        #expect(apple.count == 2); #expect(apple[0].title == "Apple title"); #expect(apple[1].title == "Unknown")
        #expect(apple[0].imageURL == "https://a/image"); #expect(index[0].subtitle == "https://b/feed")
        #expect(fyyd[0].author == "Fyyd author"); #expect(fyyd[0].feedURL == "https://c/feed")
        let requests = await tape.requests
        #expect(requests.count == 3)
        for request in requests {
            let values = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.compactMap(\.value)
            #expect(values.contains(query)); #expect(request.url!.absoluteString.contains("%2B%2B"))
            #expect(request.timeoutInterval == 30)
        }
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "X-Auth-Key") == "test-key")
        #expect(requests[1].value(forHTTPHeaderField: "X-Auth-Date") == "1700000000")
        // Independently computed SHA1(test-key + test-secret + 1700000000).
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "2782ad65bd878a76107dd3f1cdbfabe647607c5d")
    }
    @Test func combinedRankingDeduplicatesAndKeepsLaterMetadata() throws {
        func item(_ url: String, _ title: String = "title") -> PodcastSearchResult { .init(title: title, feedURL: url) }
        let results = PodcastSearchClient.combine([[item("a"), item("shared", "Apple"), item("c")], [item("shared", "Index"), item("b"), item("a", "new a")]])
        #expect(results.map(\.feedURL) == ["shared", "a", "b", "c"])
        #expect(results[0].title == "Index"); #expect(results[1].title == "new a")
        #expect(PodcastSearchClient.combine([[item("a")], [item("b")]]).map(\.feedURL) == ["a", "b"])
    }
    @Test func combinedToleratesFailureButIndividualProviderReportsIt() async throws {
        let client = PodcastSearchClient(send: { request in
            if request.url!.host == "itunes.apple.com" { return (Data(#"{"results":[{"feedUrl":"https://a/feed"}]}"#.utf8), 200) }
            return (Data(), 503)
        })
        #expect(try await client.search("test").map(\.feedURL) == ["https://a/feed"])
        await #expect(throws: PodcastSearchError.http(503)) { try await client.search("test", provider: .podcastIndex) }
        let failed = PodcastSearchClient(send: { _ in (Data(), 503) })
        #expect(try await failed.search("test").isEmpty)
        let malformed = PodcastSearchClient(send: { _ in (Data(#"{"wrong":[]}"#.utf8), 200) })
        await #expect(throws: PodcastSearchError.invalidResponse) { try await malformed.search("test", provider: .apple) }
    }
    @Test func combinedStartsProvidersTogetherAndPropagatesCancellation() async throws {
        let gate = DirectoryResponseGate()
        let client = PodcastSearchClient(send: { request in await gate.send(request) })
        let operation = Task { try await client.search("cancel") }
        let deadline = ContinuousClock.now + .seconds(3)
        while await gate.count < 2, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await gate.count == 2)
        operation.cancel()
        await gate.finish()
        await #expect(throws: CancellationError.self) { try await operation.value }
    }
    @Test func recoveryRequiresBothNamesAndPreservesSourceCaseRules() async throws {
        struct Pair: Decodable { let left: String; let right: String; let equal: Bool }
        let fixture = try #require(Bundle.module.url(forResource: "directory-case", withExtension: "json", subdirectory: "Fixtures"))
        for pair in try JSONDecoder().decode([Pair].self, from: Data(contentsOf: fixture)) {
            #expect(PodcastSearchClient.sameDirectoryName(pair.left, pair.right) == pair.equal)
        }
        let tape = DirectoryRequests()
        let client = PodcastSearchClient(send: { request in
            await tape.record(request)
            if request.url!.path == "/lookup" {
                return (Data(#"{"results":[{"artistName":"Artist","trackName":"Track"}]}"#.utf8), 200)
            }
            if request.url!.host == "itunes.apple.com" {
                return (Data(#"{"results":[{"collectionName":"Track","artistName":"wrong","feedUrl":"https://wrong/artist"},{"collectionName":"wrong","artistName":"Artist","feedUrl":"https://wrong/title"},{"collectionName":"TRACK","artistName":"aRTIST","feedUrl":"https://correct/feed"}]}"#.utf8), 200)
            }
            return (Data(), 503)
        })
        let result = try await client.resolveFeed("https://podcasts.apple.com/us/podcast/title/id123")
        #expect(result.url == "https://correct/feed"); #expect(result.recoveredBySearch)
        let requests = await tape.requests
        #expect(requests.count == 3)
        for request in requests where request.url!.path != "/lookup" {
            #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.contains { $0.value == "Track Artist" })
        }
        let direct = try await client.resolveFeed("https://example.org/feed")
        #expect(!direct.recoveredBySearch); #expect(await tape.requests.count == 3)
    }
    @Test func recoveryFailureDoesNotAcceptNearMatchesOrMalformedMetadata() async throws {
        let client = PodcastSearchClient(send: { request in
            if request.url!.path == "/lookup" { return (Data(#"{"results":[{"artistName":"Artist","trackName":"Track"}]}"#.utf8), 200) }
            return (Data(#"{"results":[{"collectionName":"Track extra","artistName":"Artist","feedUrl":"https://wrong/feed"}],"feeds":[]}"#.utf8), 200)
        })
        await #expect(throws: PodcastSearchError.feedURLNotFound(artist: "Artist", track: "Track")) {
            try await client.resolveFeed("https://itunes.apple.com/lookup?id=123")
        }
        let invalid = PodcastSearchClient(send: { _ in (Data(#"{"results":[{"trackName":"Track"}]}"#.utf8), 200) })
        await #expect(throws: PodcastSearchError.invalidResponse) { try await invalid.resolveFeed("https://itunes.apple.com/lookup?id=123") }
    }
    @Test func appleLookupAndDirectFeedBypass() async throws {
        let tape = DirectoryRequests()
        let client = PodcastSearchClient(send: { request in
            await tape.record(request)
            return (Data(#"{"results":[{"feedUrl":"https://a/rss"}]}"#.utf8), 200)
        })
        #expect(try await client.resolveFeedURL("https://podcasts.apple.com/us/podcast/example/id123?i=42") == "https://a/rss")
        #expect(try await client.resolveFeedURL("https://itunes.apple.com/lookup?id=456") == "https://a/rss")
        #expect(try await client.resolveFeedURL("https://a/feed?ref=itunes.apple.com") == "https://a/feed?ref=itunes.apple.com")
        let requests = await tape.requests
        #expect(requests.map { $0.url!.absoluteString } == ["https://itunes.apple.com/lookup?id=123", "https://itunes.apple.com/lookup?id=456"])
        let missing = PodcastSearchClient(send: { _ in (Data(#"{"results":[{"artistName":"Artist","trackName":"Track"}]}"#.utf8), 200) })
        await #expect(throws: PodcastSearchError.feedURLNotFound(artist: "Artist", track: "Track")) {
            try await missing.resolveFeedURL("https://podcasts.apple.com/us/podcast/name/id123")
        }
    }
}

private actor OnlineSearchGate {
    var started: [String] = []
    var continuations: [String: CheckedContinuation<[PodcastSearchResult], any Error>] = [:]
    func read(_ query: String) async throws -> [PodcastSearchResult] {
        started.append(query)
        return try await withCheckedThrowingContinuation { continuations[query] = $0 }
    }
    func finish(_ query: String, fail: Bool = false) {
        let continuation = continuations.removeValue(forKey: query)
        if fail { continuation?.resume(throwing: PodcastSearchError.http(503)) }
        else { continuation?.resume(returning: [.init(title: query, feedURL: "https://\(query)/feed")]) }
    }
}
@MainActor @Suite struct OnlineSearchSessionTests {
    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await predicate()), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await predicate())
    }
    @Test func replacementCancellationAndRetryOwnTheirResults() async throws {
        let gate = OnlineSearchGate()
        let session = OnlineSearchSession(provider: .apple) { query, _ in try await gate.read(query) }
        session.submit("old"); try await wait { await gate.started.contains("old") }
        session.submit("new"); try await wait { await gate.started.contains("new") }
        await gate.finish("new"); try await wait { if case .results = session.state { true } else { false } }
        await gate.finish("old"); await Task.yield()
        #expect(session.state == .results([.init(title: "new", feedURL: "https://new/feed")]))
        session.submit("retry"); try await wait { await gate.started.contains("retry") }
        await gate.finish("retry", fail: true); try await wait { session.state == .failure("HTTP 503") }
        session.retry(); try await wait { await gate.started.filter { $0 == "retry" }.count == 2 }
        await gate.finish("retry"); try await wait { if case .results = session.state { true } else { false } }
        #expect(session.submittedQuery == "retry")
        session.submit("cancelled"); try await wait { await gate.started.contains("cancelled") }
        var updates = 0; session.onChange = { updates += 1 }
        session.cancel(); await gate.finish("cancelled"); await Task.yield()
        #expect(updates == 0)
    }
}

private actor DirectoryResponseGate {
    private var pending: [(String, CheckedContinuation<(Data, Int), Never>)] = []
    var count: Int { pending.count }
    func send(_ request: URLRequest) async -> (Data, Int) {
        await withCheckedContinuation { pending.append((request.url!.host!, $0)) }
    }
    func finish() {
        for (host, continuation) in pending {
            let json = host == "itunes.apple.com" ? #"{"results":[]}"# : #"{"feeds":[]}"#
            continuation.resume(returning: (Data(json.utf8), 200))
        }
        pending.removeAll()
    }
}
