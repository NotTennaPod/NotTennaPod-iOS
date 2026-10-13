import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

private struct RefreshTestTransport: FeedHTTPTransport {
    var reply: @Sendable (URLRequest) async throws -> FeedHTTPResponse
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse { try await reply(request) }
}

@Suite(.timeLimit(.minutes(1)))
struct FeedRefreshServiceTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let initialXML = Data("""
        <rss version="2.0"><channel><title>Podcast</title>
        <item><guid>a</guid><title>Episode A</title><pubDate>Mon, 01 Jan 2001 00:00:00 GMT</pubDate>
        <enclosure url="https://example.test/a.mp3" type="audio/mpeg" length="40000"/></item>
        </channel></rss>
        """.utf8)
    private let updatedXML = Data("""
        <rss version="2.0"><channel><title>Podcast updated</title>
        <item><guid>a</guid><title>Episode A updated</title><pubDate>Mon, 01 Jan 2001 00:00:00 GMT</pubDate>
        <enclosure url="https://example.test/a.mp3" type="audio/mpeg" length="40000"/></item>
        <item><guid>b</guid><title>Episode B</title><pubDate>Tue, 02 Jan 2001 00:00:00 GMT</pubDate>
        <enclosure url="https://example.test/b.mp3" type="audio/mpeg" length="50000"/></item>
        </channel></rss>
        """.utf8)

    private func withLibrary(_ operation: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AntennaPodRefresh-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        do {
            try await operation(store, url)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    private func seed(_ store: FeedLibraryStore, source: String = "https://example.test/feed",
                      metadata: ParsedFeed? = nil) async throws -> LibraryFeed {
        let parsed = try metadata ?? FeedParser().parse(initialXML, now: now)
        return try await store.insert(FetchedFeed(feed: parsed, source: source, responseURL: URL(string: source)!,
                                                  validator: "\"v1\"", permanentRedirectURL: nil),
                                      options: FeedRefreshOptions(now: now, timeZone: .gmt))
    }

    @Test func refreshMergesAgainstListeningAndPreferenceChangesMadeDuringNetworkRequest() async throws {
        try await withLibrary { store, _ in
            let feed = try await seed(store)
            let episodeID = feed.episodes[0].id
            let body = updatedXML
            let transport = RefreshTestTransport { request in
                #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
                try await store.updateEpisode(id: episodeID) {
                    $0.userState.positionMilliseconds = 25_000
                    $0.userState.isFavorite = true
                    $0.userState.playState = .played
                    $0.details.media?.durationMilliseconds = 100_000
                }
                try await store.updatePreferences(feedID: feed.id) {
                    $0.customTitle = "Changed while refreshing"
                    $0.newEpisodesAction = .nothing
                }
                return FeedHTTPResponse(url: request.url!, status: 200, headers: ["ETag": "\"v2\""], body: body)
            }
            let date = now.addingTimeInterval(100)
            let service = FeedRefreshService(store: store, fetcher: FeedFetcher(transport: transport), clock: { date })
            guard case .updated(let result) = try await service.refresh(feedID: feed.id) else {
                Issue.record("Expected updated feed"); return
            }
            let old = try #require(result.feed.episodes.first { $0.id == episodeID })
            #expect(old.userState.positionMilliseconds == 25_000 && old.userState.isFavorite && old.userState.playState == .played)
            #expect(old.details.media?.durationMilliseconds == 100_000)
            #expect(old.details.title == "Episode A updated")
            #expect(result.feed.title == "Changed while refreshing")
            #expect(result.feed.validator == "\"v2\"" && result.feed.lastRefreshAttempt == date)
            #expect(result.feed.episodes.first { $0.id != episodeID }?.userState.playState == .unplayed)
            #expect(try await store.logs(feedID: feed.id).isEmpty)
        }
    }

    @Test func notModifiedAndCancellationPreserveAllPersistedStateIncludingPreviousFailure() async throws {
        try await withLibrary { store, _ in
            let initial = try await seed(store)
            try await store.recordFailure(.connection, feedID: initial.id, date: now)
            let before = try await store.feed(id: initial.id)
            let logs = try await store.logs(feedID: initial.id)
            let effects = try await store.pendingEffects()
            for cancel in [false, true] {
                let transport = RefreshTestTransport { request in
                    #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
                    if cancel { throw CancellationError() }
                    return FeedHTTPResponse(url: request.url!, status: 304, headers: [:], body: Data())
                }
                let service = FeedRefreshService(store: store, fetcher: FeedFetcher(transport: transport))
                if cancel {
                    await #expect(throws: CancellationError.self) { try await service.refresh(feedID: initial.id) }
                } else { #expect(try await service.refresh(feedID: initial.id) == .unchanged) }
                #expect(try await store.feed(id: initial.id) == before)
                #expect(try await store.logs(feedID: initial.id) == logs)
                #expect(try await store.pendingEffects() == effects)
            }
        }
    }

    @Test func HTTPAndParsingFailuresPersistTheirCategoriesAndDoNotReplaceEpisodes() async throws {
        try await withLibrary { store, _ in
            let feed = try await seed(store)
            let cases: [(Int, Data, FeedFetchError)] = [
                (403, Data(), .forbidden), (404, Data(), .notFound(status: 404)), (410, Data(), .notFound(status: 410)),
                (401, Data(), .unauthorized), (500, Data(), .httpStatus(500)),
                (200, Data("<html></html>".utf8), .websiteInsteadOfFeed),
                (200, Data("<rss><channel/></rss>".utf8), .missingFeedTitle),
                (200, Data("<rss><channel><title>Title</title><item/></channel></rss>".utf8), .missingEpisodeTitle(index: 0))
            ]
            for (index, entry) in cases.enumerated() {
                let date = now.addingTimeInterval(Double(index + 1))
                let transport = RefreshTestTransport { request in
                    FeedHTTPResponse(url: request.url!, status: entry.0, headers: [:], body: entry.1)
                }
                let service = FeedRefreshService(store: store, fetcher: FeedFetcher(transport: transport), clock: { date })
                #expect(try await service.refresh(feedID: feed.id) == .failed(entry.2))
                let actual = try #require(try await store.feed(id: feed.id))
                #expect(actual.episodes == feed.episodes)
                #expect(actual.metadata == feed.metadata && actual.validator == feed.validator)
                #expect(actual.lastUpdateFailed && actual.lastRefreshAttempt == date)
                #expect(try await store.logs(feedID: feed.id).first?.kind == .failure(entry.2))
                if entry.0 != 200 {
                    #expect(try await store.logs(feedID: feed.id).first?.detail == String(entry.0))
                }
            }
            #expect(try await store.logs(feedID: feed.id).count == cases.count)
        }
    }

    @Test func failureForcesNextRequestAndSuccessfulRecoveryResumesConditionalRefresh() async throws {
        try await withLibrary { store, _ in
            let feed = try await seed(store)
            let count = Mutex(0)
            let body = updatedXML
            let transport = RefreshTestTransport { request in
                let attempt = count.withLock { $0 += 1; return $0 }
                let validator = request.value(forHTTPHeaderField: "If-None-Match")
                switch attempt {
                case 1:
                    #expect(validator == "\"v1\"")
                    throw URLError(.timedOut)
                case 2:
                    #expect(validator == nil)
                    return FeedHTTPResponse(url: request.url!, status: 200, headers: ["ETag": "\"v2\""], body: body)
                default:
                    #expect(validator == "\"v2\"")
                    return FeedHTTPResponse(url: request.url!, status: 304, headers: [:], body: Data())
                }
            }
            let date = now.addingTimeInterval(50)
            let tick = Mutex(0)
            let service = FeedRefreshService(store: store, fetcher: FeedFetcher(transport: transport), clock: {
                date.addingTimeInterval(Double(tick.withLock { $0 += 1; return $0 }))
            })
            #expect(try await service.refresh(feedID: feed.id) == .failed(.connection))
            guard case .updated = try await service.refresh(feedID: feed.id) else { Issue.record("Expected recovery"); return }
            #expect(try await service.refresh(feedID: feed.id) == .unchanged)
            #expect(try await store.logs(feedID: feed.id).map(\.kind) == [.success, .failure(.connection)])
            #expect(try await store.feed(id: feed.id)?.lastUpdateFailed == false)
        }
    }

    @Test func nextPageUsesPageURLAndRetainsFrontPageMetadataAndSource() async throws {
        try await withLibrary { store, _ in
            var parsed = try FeedParser().parse(initialXML, now: now)
            parsed.isPaged = true
            parsed.nextPageURL = "https://example.test/page2"
            let feed = try await seed(store, metadata: parsed)
            let body = Data("""
                <rss xmlns:atom="http://www.w3.org/2005/Atom"><channel><title>Archive title</title>
                <atom:link rel="next" href="https://example.test/page3"/>
                <item><guid>archive</guid><title>Archived episode</title><pubDate>Mon, 01 Jan 1990 00:00:00 GMT</pubDate></item>
                </channel></rss>
                """.utf8)
            let transport = RefreshTestTransport { request in
                #expect(request.url?.absoluteString == "https://example.test/page2")
                return FeedHTTPResponse(url: request.url!, status: 200, headers: ["ETag": "page2"], body: body)
            }
            let service = FeedRefreshService(store: store, fetcher: FeedFetcher(transport: transport))
            guard case .updated(let result) = try await service.refresh(feedID: feed.id, nextPage: true) else {
                Issue.record("Expected archive page"); return
            }
            #expect(result.feed.metadata.title == "Podcast" && result.feed.source == feed.source)
            #expect(result.feed.metadata.nextPageURL == "https://example.test/page3")
            #expect(result.feed.lastRefreshAttempt == feed.lastRefreshAttempt)
            #expect(result.feed.episodes.count == 2)
            #expect(result.feed.validator == "page2" && result.feed.pageNumber == 0)
            #expect(result.feed.episodes.first { $0.details.identifier == "archive" }?.userState.playState == .unplayed)
        }
    }

    @Test func stalePreviewPageRefreshSurvivesTheFollowingExpiryCleanup() async throws {
        try await withLibrary { store, file in
            let date = now, old = now.addingTimeInterval(-2 * 86_400)
            var parsed = try FeedParser().parse(initialXML, now: old)
            parsed.isPaged = true; parsed.nextPageURL = "https://example.test/page2"
            let feed = try await store.preparePreview(.init(feed: parsed, source: "https://example.test/feed",
                responseURL: URL(string: "https://example.test/feed")!, validator: "old", permanentRedirectURL: nil), now: old)
            #expect(NonSubscribedFeedCleanup.shouldDelete(feed, queuedIDs: [], now: date))
            let body = Data("""
                <rss xmlns:atom="http://www.w3.org/2005/Atom"><channel><title>Archive title</title>
                <atom:link rel="next" href="https://example.test/page3"/>
                <item><guid>older</guid><title>Older episode</title><pubDate>Mon, 01 Jan 1990 00:00:00 GMT</pubDate></item>
                </channel></rss>
                """.utf8)
            let transport = RefreshTestTransport { request in
                #expect(request.url?.absoluteString == "https://example.test/page2")
                #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
                return .init(url: request.url!, status: 200, headers: ["ETag": "next"], body: body)
            }
            let service = FeedRefreshService(store: store, fetcher: FeedFetcher(transport: transport), clock: { date })
            guard case .updated(let result) = try await service.refresh(feedID: feed.id, force: true, nextPage: true) else {
                Issue.record("Expected refreshed preview page"); return
            }
            #expect(result.feed.lastRefreshAttempt == date)
            #expect(!result.feed.needsPreviewRefresh(at: date))
            #expect(result.feed.source == feed.source && result.feed.title == feed.title)
            #expect(result.feed.metadata.nextPageURL == "https://example.test/page3" && result.feed.pageNumber == 0)
            #expect(result.feed.episodes.count == 2 && result.feed.episodes.contains(feed.episodes[0]))
            #expect(result.feed.subscriptionState == .notSubscribed && !result.feed.keepUpdated)
            #expect(try await !store.requestFeedDeletion(feedID: feed.id, expiredAt: date))
            let reopened = try FeedLibraryStore(url: file)
            // Persistence reads pubdate DESC/id; the merger inserts a newly
            // discovered older episode at its incoming index before storage.
            var expected = result.feed; expected.episodes = result.feed.displayEpisodes
            let persisted = try #require(try await reopened.feed(id: feed.id))
            #expect(persisted.episodes.map(\.details.identifier) == ["a", "older"])
            #expect(persisted == expected)
            try await reopened.close()
        }
    }

    @Test func realHTTPFeedRefreshAndReopenPreserveStateAndUseConditionalHeaders() async throws {
        let version = Mutex(1)
        let first = initialXML
        let second = updatedXML
        let server = try await LoopbackHTTPServer.start { request in
            let value = version.withLock { $0 }
            let tag = "\"v\(value)\""
            if request.headers["if-none-match"] == tag { return .init(status: 304, body: Data()) }
            return .init(headers: ["ETag": tag], body: value == 1 ? first : second)
        }
        defer { server.stop() }
        try await withLibrary { store, url in
            let fetcher = FeedFetcher()
            guard case .updated(let input) = try await fetcher.fetch(FeedFetchRequest(source: server.url.absoluteString)) else {
                Issue.record("Expected initial HTTP feed"); return
            }
            let initial = try await store.insert(input, options: FeedRefreshOptions(now: now, timeZone: .gmt))
            let id = initial.episodes[0].id
            try await store.updateEpisode(id: id) { $0.userState.positionMilliseconds = 42_000 }
            version.withLock { $0 = 2 }
            let service = FeedRefreshService(store: store, fetcher: fetcher)
            guard case .updated = try await service.refresh(feedID: initial.id) else { Issue.record("Expected refresh"); return }
            let updated = try #require(try await store.feed(id: initial.id))
            #expect(updated.episodes.count == 2 && updated.validator == "\"v2\"")
            #expect(updated.episodes.first { $0.id == id }?.userState.positionMilliseconds == 42_000)
            #expect(updated.episodes.first { $0.id != id }?.userState.playState == .new)
            try await store.close()
            let reopened = try FeedLibraryStore(url: url)
            let nextService = FeedRefreshService(store: reopened, fetcher: fetcher)
            #expect(try await nextService.refresh(feedID: initial.id) == .unchanged)
            #expect(try await reopened.feed(id: initial.id) == updated)
            #expect(try await reopened.logs(feedID: initial.id).isEmpty)
            try await reopened.close()
            #expect(server.requests.map { $0.headers["if-none-match"] } == [nil, "\"v1\"", "\"v2\""])
        }
    }

    @Test func cancellingRealInFlightRefreshDoesNotCreateFailureOrChangeSavedData() async throws {
        let server = try await LoopbackHTTPServer.start { _ in nil }
        defer { server.stop() }
        try await withLibrary { store, _ in
            let feed = try await seed(store, source: server.url.absoluteString)
            let effects = try await store.pendingEffects()
            let service = FeedRefreshService(store: store)
            let task = Task { try await service.refresh(feedID: feed.id) }
            for _ in 0..<100 {
                if !server.requests.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(server.requests.count == 1)
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.feed(id: feed.id) == feed)
            #expect(try await store.logs(feedID: feed.id).isEmpty)
            #expect(try await store.pendingEffects() == effects)
        }
    }

    @Test func missingFeedDoesNotMakeNetworkRequest() async throws {
        try await withLibrary { store, _ in
            let transport = RefreshTestTransport { _ in Issue.record("Unexpected request"); throw CancellationError() }
            let service = FeedRefreshService(store: store, fetcher: FeedFetcher(transport: transport))
            await #expect(throws: FeedLibraryError.missingFeed(999)) { try await service.refresh(feedID: 999) }
        }
    }
}
