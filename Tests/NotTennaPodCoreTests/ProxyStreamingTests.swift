import AVFoundation
import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ProxyStreamingTests {
    private var bytes: Data {
        get throws {
#if SWIFT_PACKAGE
            let url = Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures")!
#else
            let url = Bundle(for: ProxyStreamingFixtures.self).url(forResource: "playback-30sec", withExtension: "mp3")!
#endif
            return try Data(contentsOf: url)
        }
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await predicate())
    }
    private func episode(_ url: URL) -> LibraryEpisode {
        .init(id: 1, details: .init(identifier: "proxy-stream", title: "Proxy stream", media: .init(url: url.absoluteString, size: 0)))
    }
    @Test func selectedEngineStreamsThroughAuthenticatedProxyAndKeepsPendingCommands() async throws {
        let data = try bytes
        let proxyLogin = "Basic " + Data("proxy-user:proxy-secret".utf8).base64EncodedString()
        let feedLogin = "Basic " + Data("listener:feed-secret".utf8).base64EncodedString()
        let proxy = try await LoopbackHTTPServer.start { request in
            guard request.headers["proxy-authorization"] == proxyLogin else { return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"proxy\""]) }
            guard request.headers["authorization"] == feedLogin else { return .init(status: 403) }
            return .init(headers: ["Content-Type": "audio/mpeg"], body: data)
        }
        defer { proxy.stop() }
        let client = ProxyNetworkEnvironment.Client(configuration: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!, username: "proxy-user", password: "proxy-secret"))
        let engine = AVPlayerPlaybackEngine(muted: true, credentials: { _ in .init(username: "listener", password: "feed-secret") }, proxyClient: { client }, userAgent: "AntennaPod/test")
        defer { engine.unload() }
        var failures: [String] = []
        engine.onEvent = { if case .failed(_, let message) = $0 { failures.append(message) } }
        engine.load(episode: episode(URL(string: "http://never-resolves.invalid/audio")!), generation: UUID(), positionMilliseconds: 0)
        engine.seek(to: 3883, commandID: UUID()); try engine.setSpeed(1.5, commandID: UUID())
        engine.play(commandID: UUID()); engine.pause(commandID: UUID())
        try await wait { engine.reading != nil || !failures.isEmpty }
        try #require(failures.isEmpty, "\(failures)")
        #expect(engine.reading?.sample.status == .paused && engine.reading?.speed == 1.5)
        #expect(abs((engine.reading?.sample.positionMilliseconds ?? 0) - 3883) <= 250)
        #expect(!proxy.requests.isEmpty)
        #expect(proxy.requests.allSatisfy { $0.method == "GET" && $0.path == "http://never-resolves.invalid/audio" && $0.headers["user-agent"] == "AntennaPod/test" })
        engine.play(commandID: UUID())
        try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) > 4400 || !failures.isEmpty }
        #expect(failures.isEmpty)
    }
    @Test func activeRedirectKeepsProxySnapshotAndNextLoadUsesReplacement() async throws {
        let data = try bytes
        let environment = ProxyNetworkEnvironment(configuration: .init())
        let second = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["proxy-authorization"] == nil)
            return .init(headers: ["Content-Type": "audio/mpeg"], body: data)
        }
        let next = PodcastProxy(kind: .http, host: "127.0.0.1", port: second.url.port!)
        let first = try await LoopbackHTTPServer.start { request in
            if request.path == "http://redirected.invalid/audio" {
                #expect(request.headers["authorization"] == nil)
                return .init(headers: ["Content-Type": "audio/mpeg"], body: data)
            }
            environment.update(next, reinitializeShared: true)
            return .init(status: 302, headers: ["Location": "http://redirected.invalid/audio"])
        }
        defer { first.stop(); second.stop() }
        environment.update(.init(kind: .http, host: "127.0.0.1", port: first.url.port!), reinitializeShared: true)
        let engine = AVPlayerPlaybackEngine(muted: true, credentials: { _ in .init(username: "private", password: "origin-only") }, proxyClient: { environment.sharedClient() })
        defer { engine.unload() }
        let original = episode(URL(string: "http://original.invalid/audio")!)
        engine.load(episode: original, generation: UUID(), positionMilliseconds: 0)
        try await wait { engine.reading != nil }
        #expect(first.requests.count == 2 && second.requests.isEmpty)
        #expect(first.requests.first?.headers["authorization"] != nil)
        engine.load(episode: original, generation: UUID(), positionMilliseconds: 0)
        try await wait { engine.reading != nil }
        #expect(first.requests.count == 2 && second.requests.count == 1)
    }
    @Test func rejectedProxyDoesNotBypassItOrRetainCache() async throws {
        let data = try bytes
        let origin = try await LoopbackHTTPServer.start { _ in .init(headers: ["Content-Type": "audio/mpeg"], body: data) }
        let proxy = try await LoopbackHTTPServer.start { _ in .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"reject\""]) }
        defer { origin.stop(); proxy.stop() }
        let source = try ProgressiveHTTPMediaSource(url: origin.url, proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!, username: "bad", password: "bad"))
        let item = AVPlayerItem(asset: source.asset), player = AVPlayer()
        player.isMuted = true; player.replaceCurrentItem(with: item)
        defer { player.replaceCurrentItem(with: nil); source.cancel() }
        try await wait { item.status == .failed }
        #expect(origin.requests.isEmpty && !proxy.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: source.cacheURL.path))
    }
    @Test func proxyRangeSeekPreservesValidatedBytesAndCancellationCleansPartialCache() async throws {
        let data = try bytes
        let proxy = try await LoopbackHTTPServer.start { request in
            if let range = request.headers["range"], let start = Int(range.dropFirst(6).dropLast()) {
                #expect(request.headers["if-range"] == "\"fixture\"")
                return .init(status: 206, headers: ["Content-Type": "audio/mpeg", "ETag": "\"fixture\"", "Content-Range": "bytes \(start)-\(data.count-1)/\(data.count)"], body: data.suffix(from: start))
            }
            return .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(data.count)", "ETag": "\"fixture\""], body: data.prefix(data.count/4), keepConnectionOpen: true)
        }
        defer { proxy.stop() }
        let source = try ProgressiveHTTPMediaSource(url: URL(string: "http://seek-origin.invalid/audio")!, proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!))
        let item = AVPlayerItem(asset: source.asset), player = AVPlayer()
        player.isMuted = true; player.replaceCurrentItem(with: item)
        defer { player.replaceCurrentItem(with: nil); source.cancel() }
        try await wait { item.status != .unknown }
        try #require(item.status == .readyToPlay)
        #expect(await player.seek(to: CMTime(value: 25000, timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero))
        #expect(abs(player.currentTime().seconds - 25) < 0.25)
        player.play()
        try await wait { proxy.requests.contains { $0.headers["range"] != nil } && player.currentTime().seconds >= 25.3 }
        player.pause()
        let snapshot = await source.snapshot()
        #expect(snapshot.failure == nil)
        player.replaceCurrentItem(with: nil); source.cancel()
        _ = await source.snapshot() // Let cancellation settle before checking the disk.
        // The partial download does not linger on disk.
        #expect(!FileManager.default.fileExists(atPath: source.cacheURL.path))
    }
}
#if !SWIFT_PACKAGE
private final class ProxyStreamingFixtures: NSObject {}
#endif
