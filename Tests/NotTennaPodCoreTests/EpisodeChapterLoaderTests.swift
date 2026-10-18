import Foundation
import Testing
@testable import NotTennaPodCore

private actor ChapterTransport: FeedHTTPTransport {
    var requests: [URLRequest] = []
    private var responses: [Result<FeedHTTPResponse, URLError>]
    private let holdFirst: Bool
    private var held: CheckedContinuation<Void, Never>?
    private var started: [CheckedContinuation<Void, Never>] = []
    init(_ responses: [Result<FeedHTTPResponse, URLError>], holdFirst: Bool = false) {
        self.responses = responses; self.holdFirst = holdFirst
    }
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
        requests.append(request)
        let response = responses.isEmpty ? .failure(URLError(.notConnectedToInternet)) : responses.removeFirst()
        if holdFirst && requests.count == 1 {
            await withCheckedContinuation { continuation in
                held = continuation
                for waiter in started { waiter.resume() }; started = []
            }
        }
        return try response.get()
    }
    func awaitHeldRequest() async {
        if held == nil { await withCheckedContinuation { started.append($0) } }
    }
    func release() { held?.resume(); held = nil }
}

private actor ChapterMediaProbe {
    var calls = 0
    func read(_ chapters: [ParsedChapter]?) -> [ParsedChapter]? { calls += 1; return chapters }
}

@Suite struct EpisodeChapterLoaderTests {
    private let url = URL(string: "https://example.invalid/chapters.json")!
    private func cache() -> URLCache { URLCache(memoryCapacity: 1_000_000, diskCapacity: 0) }
    private func response(_ title: String, count: Int = 2, headers: [String: String] = [:]) -> FeedHTTPResponse {
        let chapters = (0..<count).map { ["startTime": $0 * 60, "title": "\(title)\($0)"] as [String: Any] }
        return .init(url: url, status: 200, headers: headers,
                     body: try! JSONSerialization.data(withJSONObject: ["chapters": chapters]))
    }
    private func loader(_ transport: ChapterTransport, _ cache: URLCache? = nil) -> EpisodeChapterLoader {
        EpisodeChapterLoader(transport: transport, cache: cache ?? self.cache(), userAgent: "AntennaPod/test")
    }

    @Test func cacheWorksOfflineAndForceRefreshReplacesIt() async throws {
        let transport = ChapterTransport([.success(response("First")), .success(response("Updated"))])
        let loader = loader(transport)
        let first = try await loader.load(stored: nil, externalURL: url.absoluteString) { nil }
        #expect(first.map(\.title) == ["First0", "First1"])
        #expect(try await loader.load(stored: nil, externalURL: url.absoluteString) { nil } == first)
        #expect(await transport.requests.count == 1)
        let updated = try await loader.load(stored: nil, loaded: first, externalURL: url.absoluteString, forceRefresh: true) { nil }
        #expect(updated.map(\.title) == ["Updated0", "Updated1"])
        #expect(try await loader.load(stored: nil, externalURL: url.absoluteString) { nil } == updated)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cache-Control") == "no-cache" && $0.value(forHTTPHeaderField: "User-Agent") == "AntennaPod/test" })
    }

    @Test func emptyAndDummyCachedListsRetryNetworkWithoutReturningStalePlaceholder() async throws {
        for count in [0, 1] {
            let transport = ChapterTransport([.success(response("Placeholder", count: count)), .success(response("Ready"))])
            let loader = loader(transport)
            #expect(try await loader.load(stored: nil, externalURL: url.absoluteString) { nil }.count == count)
            #expect(try await loader.load(stored: nil, externalURL: url.absoluteString) { nil }.map(\.title) == ["Ready0", "Ready1"])
            #expect(await transport.requests.count == 2)
        }
        let transport = ChapterTransport([.success(response("Placeholder", count: 1))])
        let loader = loader(transport)
        _ = try await loader.load(stored: nil, externalURL: url.absoluteString) { nil }
        #expect(try await loader.load(stored: nil, externalURL: url.absoluteString) { nil }.isEmpty)
        #expect(await transport.requests.count == 2)
    }

    @Test func completedEmptyOrNonemptyListsSkipBothSourcesUntilForced() async throws {
        let transport = ChapterTransport([.success(response("Remote"))]), media = ChapterMediaProbe()
        let loader = loader(transport)
        for list in [[], [ParsedChapter(startMilliseconds: 100, title: "Loaded")]] {
            #expect(try await loader.load(stored: nil, loaded: list, externalURL: url.absoluteString) { await media.read(nil) } == list)
        }
        #expect(await transport.requests.isEmpty); #expect(await media.calls == 0)
        #expect(try await loader.load(stored: nil, loaded: [], externalURL: url.absoluteString, forceRefresh: true) { await media.read(nil) }.count == 2)
        #expect(await transport.requests.count == 1); #expect(await media.calls == 1)
    }

    @Test func mergesStoredThenMediaThenExternalAndKeepsOtherSourcesOnFailure() async throws {
        let stored = [ParsedChapter(startMilliseconds: 0, title: "XML", link: "https://xml.invalid"),
                      ParsedChapter(startMilliseconds: 60_000, title: "XML second")]
        let media = [ParsedChapter(startMilliseconds: 0, title: "Media", imageURL: "https://media.invalid/cover"),
                     ParsedChapter(startMilliseconds: 60_000, title: "Media second")]
        let transport = ChapterTransport([.success(response("External")), .failure(URLError(.notConnectedToInternet))])
        let loader = loader(transport)
        let result = try await loader.load(stored: stored, externalURL: url.absoluteString) { media }
        #expect(result[0] == .init(startMilliseconds: 0, title: "External0", link: "https://xml.invalid", imageURL: "https://media.invalid/cover"))
        #expect(try await loader.load(stored: stored, loaded: result, externalURL: url.absoluteString, forceRefresh: true) { media } == ChapterMerger.merge(stored, media))
        #expect(try await loader.load(stored: stored, externalURL: nil) { throw URLError(.cannotDecodeContentData) } == stored)
    }

    @Test func malformedFailedStatusAndInvalidURLDoNotDiscardStoredChapters() async throws {
        let stored = [ParsedChapter(startMilliseconds: 5000, title: "Stored")]
        for response in [FeedHTTPResponse(url: url, status: 404, body: response("Invalid").body),
                         .init(url: url, status: 200, body: Data("invalid".utf8))] {
            let transport = ChapterTransport([.success(response)]), loader = loader(ChapterTransport([]))
            #expect(try await self.loader(transport).load(stored: stored, externalURL: url.absoluteString) { nil } == stored)
            #expect(try await loader.load(stored: stored, externalURL: "file:///chapters.json") { nil } == stored)
        }
    }

    @Test func noStoreAndRedirectsRetainSharedTransportOwnership() async throws {
        let destination = URL(string: "https://cdn.invalid/new.json")!
        let content = response("Redirected", headers: ["Cache-Control": "no-store"])
        let transport = ChapterTransport([
            .success(.init(url: url, status: 302, headers: ["Location": destination.absoluteString])),
            .success(.init(url: destination, status: 200, headers: content.headers, body: content.body))
        ])
        let loader = loader(transport)
        #expect(try await loader.load(stored: nil, externalURL: url.absoluteString) { nil }.count == 2)
        #expect(await transport.requests.map(\.url) == [url, destination])
        #expect(try await loader.load(stored: nil, externalURL: url.absoluteString) { nil }.isEmpty)
        #expect(await transport.requests.count == 3)
    }

    @Test func cancellationRejectsLateResponseAndAllowsFreshRetry() async throws {
        let transport = ChapterTransport([.success(response("Late")), .success(response("Fresh"))], holdFirst: true)
        let loader = loader(transport), media = ChapterMediaProbe(), address = url.absoluteString
        let task = Task { try await loader.load(stored: nil, externalURL: address) { await media.read(nil) } }
        await transport.awaitHeldRequest(); task.cancel(); await transport.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await media.calls == 0)
        #expect(try await loader.load(stored: nil, externalURL: address) { nil }.map(\.title) == ["Fresh0", "Fresh1"])
        #expect(await transport.requests.count == 2)
    }

    @Test func interruptedNetworkAndMediaPreserveRetryableFailure() async throws {
        for code in [URLError.Code.cancelled, .timedOut] {
            let loader = loader(ChapterTransport([.failure(URLError(code))]))
            await #expect(throws: URLError.self) {
                try await loader.load(stored: [], externalURL: url.absoluteString) { nil }
            }
            await #expect(throws: URLError.self) {
                try await loader.load(stored: [], externalURL: nil) { throw URLError(code) }
            }
        }
    }
}
