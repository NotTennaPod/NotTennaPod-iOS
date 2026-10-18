import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized) struct ApplicationPlaybackSourceTests {
    private func fixture(_ path: String) throws -> URL {
        let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
#if SWIFT_PACKAGE
        let folder = parts.count == 2 ? "Fixtures/" + parts[0] : "Fixtures"
        return try #require(Bundle.module.url(forResource: parts.last!, withExtension: nil, subdirectory: folder))
#else
        return try #require(Bundle(for: AppSourceFixtures.self).url(forResource: parts.last!, withExtension: nil, subdirectory: parts.count == 2 && parts[0] != "StreamingFormats" ? parts[0] : nil))
#endif
    }
    private func wait(_ check: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !check(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(check())
    }

    @Test(arguments: [false, true], [false, true])
    func identifiedMP3KeepsOneAuthenticatedConnectionAndUserAgent(proxyEnabled: Bool, live: Bool) async throws {
        let media = try Data(contentsOf: fixture(live ? "playback-unknown-duration.mp3" : "playback-30sec.mp3"))
        let login = FeedCredentials(username: "app", password: "saved"), agent = "AntennaPod/3.12.1-test"
        let proxyAuth = "Basic " + Data("proxy:saved".utf8).base64EncodedString()
        let server = try await LoopbackHTTPServer.start { request in
            if proxyEnabled && request.headers["proxy-authorization"] != proxyAuth {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"app\""])
            }
            #expect(request.headers["authorization"] == login.authorization(utf8: false))
            #expect(request.headers["user-agent"] == agent)
            if live {
                return .init(headers: ["Content-Type": "application/octet-stream", "Transfer-Encoding": "chunked"],
                    body: Data("\(String(media.count, radix: 16))\r\n".utf8) + media + Data("\r\n".utf8), keepConnectionOpen: true)
            }
            return .init(headers: ["Content-Type": "video/mp4"], body: media)
        }
        defer { server.stop() }
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!, username: "proxy", password: "saved") : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://app-dispatch.invalid/opaque")! : server.url
        let root = URL.temporaryDirectory.appendingPathComponent("app-source-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let factories = PCMPlaybackFactory(cacheDirectory: root, makeTransport: { NativeSampleBufferTransport(muted: true) })
        let factory = try #require(try await factories.mp3IfSupported(url: url, proxy: proxy, credentials: login, userAgent: agent))
        let session = try await factory.make(positionMilliseconds: 0, parameters: .init(speed: 1.5, skipSilence: true, volume: .lightReduction))
        defer { session.close() }
        try await session.prepare(); try session.play()
        try await wait { session.presentedFrames > 0 && ((try? session.mediaMicroseconds) ?? 0) > 500000 || session.failure != nil }
        #expect(session.failure == nil && session.writtenFrames > 0 && session.presentedFrames > 0)
        #expect(session.sourceSeekable == !live)
        #expect(!live || session.sourceDurationMilliseconds == nil)
        if live {
            // A live stream cannot be re-requested without skipping audio.
            let accepted = server.requests.filter { !proxyEnabled || $0.headers["proxy-authorization"] == proxyAuth }
            #expect(accepted.count == 1)
        }
    }

#if os(iOS)
    @Test(arguments: ["mp3", "live", "wav", "hls"], [false, true])
    func publicAppEnginePlaysContentAndPreservesCapturedProxy(kind: String, proxyEnabled: Bool) async throws {
        let mp3 = try Data(contentsOf: fixture(kind == "live" ? "playback-unknown-duration.mp3" : "playback-30sec.mp3"))
        let wav = try Data(contentsOf: fixture("StreamingFormats/tone.wav"))
        let manifest = try Data(contentsOf: fixture("StreamingHLS/index.m3u8"))
        let parts = try (0..<5).map { try Data(contentsOf: fixture(String(format: "StreamingHLS/part%02d.ts", $0))) }
        let login = FeedCredentials(username: "app", password: "saved"), agent = "AntennaPod/3.12.1-app-test"
        let server = try await LoopbackHTTPServer.start { request in
            // The retained direct native HLS path responds to Basic challenges.
            // Never serve protected content merely because a probe had credentials.
            guard request.headers["authorization"] == login.authorization(utf8: false) else {
                return .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"app\""])
            }
            // Native direct HLS owns its User-Agent; preserving the fallback does
            // not establish the still-open app User-Agent parity for that path.
            if kind != "hls" || proxyEnabled { #expect(request.headers["user-agent"] == agent) }
            if request.path.contains("part"), let index = (0..<5).first(where: { request.path.contains(String(format: "part%02d.ts", $0)) }) {
                return .init(headers: ["Content-Type": "video/mp2t"], body: parts[index])
            }
            if kind == "hls" { return .init(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: manifest) }
            if kind == "wav" { return .init(headers: ["Content-Type": "audio/wav"], body: wav) }
            if kind == "live" {
                return .init(headers: ["Content-Type": "application/octet-stream", "Transfer-Encoding": "chunked"],
                    body: Data("\(String(mp3.count, radix: 16))\r\n".utf8) + mp3 + Data("\r\n".utf8), keepConnectionOpen: true)
            }
            return .init(headers: ["Content-Type": "video/mp4"], body: mp3)
        }
        defer { server.stop() }
        let root = URL.temporaryDirectory.appendingPathComponent("app-engine-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let url = proxyEnabled ? URL(string: "http://app-route.invalid/episode")! : server.url
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "App player", episodes: [
            ParsedEpisode(identifier: "1", title: "Episode", media: ParsedMedia(url: url.absoluteString, size: 0, durationMilliseconds: 30000))]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        let episode = try #require(try await store.episode(id: 1))
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let client = Mutex(ProxyNetworkEnvironment.Client(configuration: proxy))
        let engine = ApplicationPlaybackEngine(muted: true, credentials: { _ in login }, proxyClient: { client.withLock { $0 } },
            userAgent: agent, cacheDirectory: root.appendingPathComponent("cache"))
        defer { engine.unload() }
        engine.bindStatistics(lastPlayed: { _ in 0 }, synchronize: { _ in })
        var failures: [String] = []
        engine.onEvent = { if case let .failed(_, message) = $0 { failures.append(message) } }
        let generation = UUID(), processed = kind != "hls"
        engine.load(episode: episode, generation: generation, positionMilliseconds: kind == "mp3" ? 20000 : 0)
        client.withLock { $0 = .init(configuration: .init(kind: .http, host: "127.0.0.1", port: 1)) }
        try engine.setSpeed(1.5, commandID: generation)
        engine.setSkipSilence(processed, commandID: generation)
        engine.play(commandID: generation)
        try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) > (kind == "mp3" ? 20500 : 500) || !failures.isEmpty }
        #expect(failures.isEmpty)
        #expect(engine.reading?.isPrepared == true && engine.reading?.speed == 1.5)
        #expect(engine.supportsSkipSilence == processed && engine.reading?.skipSilence == processed)
        engine.pause(commandID: generation)
        if processed {
            let target: Int64 = kind == "mp3" ? 5000 : kind == "wav" ? 1000 : 2000
            engine.seek(to: target, commandID: generation)
            // The seek lands within 0.25 s of the requested position. A live stream has no
            // seekable range: as in Android (ExoPlayer seeks an unseekable progressive source
            // to 0 and reloads it), the stream restarts from its current start.
            let landing: Int64 = kind == "live" ? 0 : target
            try await wait { let position = Int64(engine.reading?.sample.positionMilliseconds ?? -1); return engine.reading?.isPrepared == true && abs(position - landing) <= 250 || !failures.isEmpty }
            #expect(failures.isEmpty)
            engine.play(commandID: generation)
            try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) > landing + 500 || !failures.isEmpty }
            #expect(failures.isEmpty)
        }
        engine.unload(); try await store.close()
    }
#endif
}
private final class AppSourceFixtures: NSObject {}
