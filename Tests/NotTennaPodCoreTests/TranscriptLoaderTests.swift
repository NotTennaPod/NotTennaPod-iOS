import Foundation
import Testing
@testable import NotTennaPodCore

private actor TranscriptTransport: FeedHTTPTransport {
    var requests: [URLRequest] = []
    var responses: [FeedHTTPResponse]
    let stalls: Bool
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ responses: [FeedHTTPResponse], stalls: Bool = false) { self.responses = responses; self.stalls = stalls }
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
        requests.append(request); started = true
        for waiter in waiters { waiter.resume() }; waiters = []
        if stalls { try await Task.sleep(for: .seconds(60)) }
        guard !responses.isEmpty else { throw URLError(.notConnectedToInternet) }
        return responses.removeFirst()
    }
    func awaitStart() async { if !started { await withCheckedContinuation { waiters.append($0) } } }
}

@Suite struct TranscriptLoaderTests {
    private let url = URL(string: "https://example.invalid/transcript.json")!
    private var descriptor: FeedTranscript { .init(format: .json, url: url.absoluteString) }
    private func data(_ word: String) -> Data { Data("{\"segments\":[{\"startTime\":0,\"endTime\":5,\"body\":\"\(word)\"}]}".utf8) }
    private func cache() -> URLCache { URLCache(memoryCapacity: 1_000_000, diskCapacity: 0) }

    @Test func cachedContentOfflineAndForceRefreshReplaceResponse() async throws {
        let transport = TranscriptTransport([
            .init(url: url, status: 200, body: data("First")),
            .init(url: url, status: 200, body: data("Updated"))
        ])
        let loader = TranscriptLoader(transport: transport, cache: cache(), userAgent: "AntennaPod/test")
        #expect(try await loader.load(descriptor).segments[0].words == "First")
        #expect(try await loader.load(descriptor).segments[0].words == "First")
        #expect(await transport.requests.count == 1)
        #expect(try await loader.load(descriptor, forceRefresh: true).segments[0].words == "Updated")
        #expect(try await loader.load(descriptor).segments[0].words == "Updated")
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "AntennaPod/test" && $0.value(forHTTPHeaderField: "Cache-Control") == "no-cache" })
        await #expect(throws: URLError.self) { try await loader.load(descriptor, forceRefresh: true) }
        #expect(try await loader.load(descriptor).segments[0].words == "Updated")
    }

    @Test func sidecarPrecedesCacheAndForceRefreshBypassesWithoutRewritingIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Transcript-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = dir.appendingPathComponent("episode.mp3"), file = dir.appendingPathComponent("episode.mp3.transcript")
        try data("Local").write(to: file)
        let transport = TranscriptTransport([.init(url: url, status: 200, body: data("Network"))])
        let loader = TranscriptLoader(transport: transport, cache: cache(), userAgent: "test")
        #expect(try await loader.load(descriptor, localMediaPath: media.path).segments[0].words == "Local")
        #expect(await transport.requests.isEmpty)
        #expect(try await loader.load(descriptor, localMediaPath: media.absoluteString, forceRefresh: true).segments[0].words == "Network")
        #expect(try Data(contentsOf: file) == data("Local"))
        #expect(try await loader.load(descriptor, localMediaPath: media.path).segments[0].words == "Local")
        try Data("invalid".utf8).write(to: file)
        await #expect(throws: (any Error).self) { try await loader.load(descriptor, localMediaPath: media.path) }
        #expect(await transport.requests.count == 1) // Nonempty malformed sidecar is authoritative in the release.
    }

    @Test func dummyCacheRetriesNetworkNoStoreIsNotCachedAndRedirectsAreFollowed() async throws {
        let destination = URL(string: "https://cdn.invalid/new.json")!
        let cache = cache()
        var request = URLRequest(url: url); request.setValue("test", forHTTPHeaderField: "User-Agent")
        cache.storeCachedResponse(CachedURLResponse(response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data: Data(" ".utf8)), for: request)
        let transport = TranscriptTransport([
            .init(url: url, status: 302, headers: ["Location": destination.absoluteString]),
            .init(url: destination, status: 200, headers: ["Cache-Control":"no-store"], body: data("Redirected"))
        ])
        let loader = TranscriptLoader(transport: transport, cache: cache, userAgent: "test")
        #expect(try await loader.load(descriptor).segments[0].words == "Redirected")
        #expect(await transport.requests.map(\.url) == [url, destination])
        await #expect(throws: URLError.self) { try await loader.load(descriptor) }
    }

    @Test func failedStatusMalformedAndCancellationDoNotBecomeSuccessfulContent() async throws {
        for response in [FeedHTTPResponse(url: url, status: 404, body: data("Do not parse")), .init(url: url, status: 200, body: Data("invalid".utf8))] {
            let loader = TranscriptLoader(transport: TranscriptTransport([response]), cache: cache(), userAgent: "test")
            await #expect(throws: (any Error).self) { try await loader.load(descriptor) }
        }
        let transport = TranscriptTransport([.init(url: url, status: 200, body: data("Late"))], stalls: true)
        let loader = TranscriptLoader(transport: transport, cache: cache(), userAgent: "test")
        let descriptor = descriptor
        let task = Task { try await loader.load(descriptor) }
        await transport.awaitStart(); task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests.count == 1)
    }
}
