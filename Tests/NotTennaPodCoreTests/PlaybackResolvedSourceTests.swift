import AVFoundation
import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct PlaybackResolvedSourceTests {
    private var bytes: Data {
        get throws {
#if SWIFT_PACKAGE
            let url = Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures")!
#else
            let url = Bundle(for: PlaybackResolvedFixtures.self).url(forResource: "playback-30sec", withExtension: "mp3")!
#endif
            return try Data(contentsOf: url)
        }
    }
    private func episode(_ url: URL, id: Int64 = 1) -> LibraryEpisode {
        .init(id: id, details: .init(identifier: "\(id)", title: "Resolved audio", media: .init(url: url.absoluteString, size: 0)))
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await predicate())
    }

    @Test func resolvedMediaPlaysWithPendingSeekAndSpeedWithoutLeakingOriginalLogin() async throws {
        let body = try bytes
        let destination = try await LoopbackHTTPServer.start { _ in .init(headers: ["Content-Type": "audio/mpeg"], body: body) }
        defer { destination.stop() }
        let destinationURL = destination.url.absoluteString
        let origin = try await LoopbackHTTPServer.start { _ in .init(status: 302, headers: ["Location": destinationURL]) }
        defer { origin.stop() }
        let resolver = PlaybackURLResolver(transport: URLSessionFeedTransport())
        let engine = AVPlayerPlaybackEngine(muted: true, credentials: { _ in .init(username: "original-listener", password: "fixture") }, urlResolver: resolver)
        var failures: [String] = []
        engine.onEvent = { if case .failed(_, let message) = $0 { failures.append(message) } }
        defer { engine.unload() }
        engine.load(episode: episode(origin.url), generation: UUID(), positionMilliseconds: 0)
        try engine.setSpeed(1.5, commandID: UUID())
        engine.seek(to: 3883, commandID: UUID())
        engine.play(commandID: UUID()); engine.pause(commandID: UUID())
        try await wait { engine.reading != nil || !failures.isEmpty }
        try #require(failures.isEmpty, "\(failures)")
        #expect(engine.reading?.sample.status == .paused && engine.reading?.speed == 1.5)
        #expect(abs((engine.reading?.sample.positionMilliseconds ?? 0) - 3883) <= 250)
        #expect(origin.requests.count == 1 && origin.requests.first?.method == "HEAD")
        #expect(destination.requests.contains { $0.method == "GET" })
        #expect(destination.requests.allSatisfy { $0.headers["authorization"] == nil })
        engine.play(commandID: UUID())
        try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) > 4400 || !failures.isEmpty }
        #expect(failures.isEmpty)
        engine.unload()
        engine.load(episode: episode(origin.url), generation: UUID(), positionMilliseconds: 0)
        try await wait { engine.reading != nil || !failures.isEmpty }
        #expect(failures.isEmpty && origin.requests.count == 1) // Same factory's address cache survives unload.
    }

    @Test func cancelledResolutionCannotInstallOrCacheTheRetiredEpisode() async throws {
        let body = try bytes
        let destination = try await LoopbackHTTPServer.start { _ in .init(headers: ["Content-Type": "audio/mpeg"], body: body) }
        defer { destination.stop() }
        let transport = HeldPlaybackResolution(destination: destination.url)
        let resolver = PlaybackURLResolver(transport: transport)
        let engine = AVPlayerPlaybackEngine(muted: true, urlResolver: resolver)
        var ready: [UUID] = []
        engine.onEvent = { if case .ready(let reading) = $0 { ready.append(reading.generation) } }
        defer { engine.unload() }
        let old = URL(string: "http://old.invalid/media")!, next = URL(string: "http://next.invalid/media")!
        engine.load(episode: episode(old), generation: UUID(), positionMilliseconds: 0)
        try await wait { await transport.pending }
        #expect(engine.nativePlayer == nil && destination.requests.isEmpty)
        let generation = UUID()
        engine.load(episode: episode(next, id: 2), generation: generation, positionMilliseconds: 0)
        await transport.release()
        try await wait { engine.reading != nil }
        #expect(ready == [generation] && engine.reading?.generation == generation)
        #expect(destination.requests.count == 1)
        // A cancelled result never enters the resolver's address cache.
        _ = try await resolver.resolve(old)
        #expect(await transport.oldRequests == 2)
    }
}

private actor HeldPlaybackResolution: FeedHTTPTransport {
    let destination: URL
    var oldRequests = 0
    private var continuation: CheckedContinuation<FeedHTTPResponse, Never>?
    var pending: Bool { continuation != nil }
    init(destination: URL) { self.destination = destination }
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
        if request.url?.host == "old.invalid" {
            oldRequests += 1
            if oldRequests == 1 { return await withCheckedContinuation { continuation = $0 } }
        }
        return .init(url: destination, status: 200)
    }
    func release() { continuation?.resume(returning: .init(url: destination, status: 200)); continuation = nil }
}
#if !SWIFT_PACKAGE
private final class PlaybackResolvedFixtures: NSObject {}
#endif
