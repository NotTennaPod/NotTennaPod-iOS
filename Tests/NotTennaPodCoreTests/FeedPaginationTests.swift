import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.timeLimit(.minutes(1)))
struct FeedPaginationTests {
    private func withStore(_ body: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Pagination-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("library.sqlite"), store = try FeedLibraryStore(url: file)
        do { try await body(store, file); try await store.close() }
        catch { try? await store.close(); throw error }
    }
    private func seed(_ store: FeedLibraryStore) async throws -> LibraryFeed {
        var parsed = ParsedFeed(format: .rss, title: "Root title")
        parsed.isPaged = true; parsed.nextPageURL = "https://example.org/page1"
        parsed.episodes = [ParsedEpisode(identifier: "root", title: "Root episode")]
        return try await store.insert(.init(feed: parsed, source: "https://example.org/root",
            responseURL: URL(string: "https://example.org/root")!, validator: "validator", permanentRedirectURL: nil))
    }

    @Test func pagesMergeWithoutReplacingRootMetadataOrUserStateAndResetSurvivesReopen() async throws {
        try await withStore { store, file in
            let seed = try await seed(store), id = try #require(seed.episodes.first?.id)
            try await store.updateEpisode(id: id) { $0.userState.isFavorite = true; $0.userState.positionMilliseconds = 23_000 }
            let transport = PaginationTransport()
            let service = FeedRefreshService(store: store, fetcher: .init(transport: transport))
            _ = try await service.refresh(feedID: seed.id, nextPage: true)
            var feed = try #require(try await store.feed(id: seed.id))
            #expect(feed.title == "Root title" && feed.source == seed.source && feed.pageNumber == 0)
            #expect(feed.metadata.nextPageURL == "https://example.org/page2")
            #expect(Set(feed.episodes.compactMap(\.details.identifier)) == ["root", "older1"])
            _ = try await service.refresh(feedID: seed.id, nextPage: true)
            feed = try #require(try await store.feed(id: seed.id))
            #expect(feed.metadata.isPaged && feed.metadata.nextPageURL == nil)
            #expect(feed.episodes.count == 3)
            let owner = ManualFeedRefreshCoordinator(store: store, execute: { _ in })
            owner.suspend()
            let request = try await owner.runOnce(feedID: seed.id, resetPagination: true).value
            #expect(request.force && !request.nextPage)
            let reopened = try FeedLibraryStore(url: file)
            #expect(try await reopened.manualRefreshRequest() == request)
            #expect(try await reopened.feed(id: seed.id)?.metadata.nextPageURL == seed.source)
            try await reopened.close()
            _ = try await service.refresh(feedID: seed.id, force: request.force, manualRequestID: request.id)
            feed = try #require(try await store.feed(id: seed.id))
            // Source root refresh keeps the reset cursor; the next page action
            // reads that root as a page, advancing its cursor without duplicates.
            #expect(feed.metadata.nextPageURL == seed.source)
            _ = try await service.refresh(feedID: seed.id, nextPage: true, manualRequestID: request.id)
            feed = try #require(try await store.feed(id: seed.id))
            #expect(feed.metadata.nextPageURL == "https://example.org/page1")
            #expect(feed.episodes.count == 3)
            let retained = try #require(feed.episodes.first { $0.id == id })
            #expect(retained.userState.isFavorite && retained.userState.positionMilliseconds == 23_000)
            #expect(await transport.paths == ["/page1", "/page2", "/root", "/root"])
        }
    }

    @Test func invalidResetDoesNotReplaceExistingRequestOrMutateCursor() async throws {
        try await withStore { store, _ in
            let feed = try await seed(store)
            let current = FeedRefreshRequest(feedID: feed.id, enqueuedAt: Date())
            try await store.enqueueManualRefresh(current)
            let invalid = FeedRefreshRequest(feedID: feed.id, nextPage: true, enqueuedAt: Date())
            await #expect(throws: FeedLibraryError.self) { try await store.enqueueManualRefresh(invalid, resetPagination: true) }
            #expect(try await store.manualRefreshRequest() == current)
            #expect(try await store.feed(id: feed.id)?.metadata.nextPageURL == "https://example.org/page1")
            let missing = FeedRefreshRequest(feedID: feed.id + 100, enqueuedAt: Date())
            await #expect(throws: FeedLibraryError.self) { try await store.enqueueManualRefresh(missing, resetPagination: true) }
            #expect(try await store.manualRefreshRequest() == current)
        }
    }
}

private actor PaginationTransport: FeedHTTPTransport {
    var paths: [String] = []
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
        let url = try #require(request.url); paths.append(url.path)
        let guid = url.path == "/root" ? "root" : (url.path == "/page1" ? "older1" : "older2")
        let next = url.path == "/page2" ? "" : "<atom:link rel=\"next\" href=\"https://example.org/\(url.path == "/root" ? "page1" : "page2")\"/>"
        let xml = "<rss version=\"2.0\" xmlns:atom=\"http://www.w3.org/2005/Atom\"><channel><title>Response title</title>\(next)<item><guid>\(guid)</guid><title>\(guid)</title></item></channel></rss>"
        return FeedHTTPResponse(url: url, status: 200, headers: [:], body: Data(xml.utf8))
    }
}
