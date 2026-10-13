import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct PCMDeferredRetryTests {
    private func wait(_ condition: () async throws -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(12)
        repeat {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        } while ContinuousClock.now < end
        try #require(try await condition())
    }
    private func media() throws -> Data {
#if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: "playback-unknown-duration", withExtension: "mp3", subdirectory: "Fixtures")!
#else
        let url = Bundle(for: DeferredFixtures.self).url(forResource: "playback-unknown-duration", withExtension: "mp3")!
#endif
        return try Data(contentsOf: url)
    }
    struct Scenario: Sendable {
        let proxyEnabled: Bool
        let cancel: Bool
        let skipSilence: Bool
    }
    /// Each scenario waits for the real eight-second upstream idle failure, so every dimension
    /// is covered once instead of the full 2×2×2 grid: resume without
    /// and with skip-silence (proxy on the latter), and closing the episode instead of resuming.
    nonisolated static let scenarios = [
        Scenario(proxyEnabled: false, cancel: false, skipSilence: false),
        Scenario(proxyEnabled: true, cancel: false, skipSilence: true),
        Scenario(proxyEnabled: true, cancel: true, skipSilence: false),
    ]
    @Test(arguments: scenarios)
    func liveStreamDropWhilePausedPlaysBufferedAudioThenRestartsWithSameSettings(scenario: Scenario) async throws {
        let proxyEnabled = scenario.proxyEnabled, cancel = scenario.cancel, skipSilence = scenario.skipSilence
        let bytes = try media(), count = DeferredCounter(), disconnected = DeferredCounter()
        let credentials = FeedCredentials(username: "live", password: "captured")
        let proxyAuthorization = "Basic " + Data("proxy:saved".utf8).base64EncodedString()
        let server = try await LoopbackHTTPServer.start(onClientDisconnect: { _ = disconnected.next() }) { request in
            if proxyEnabled && request.headers["proxy-authorization"] != proxyAuthorization {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"live\""])
            }
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            let first = count.next() == 1
            let data = first ? Data(bytes.prefix(bytes.count / 2)) : bytes
            return .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked", "ETag": first ? "\"old-live\"" : "\"new-live\""],
                body: Data("\(String(data.count, radix: 16))\r\n".utf8) + data + Data("\r\n".utf8),
                keepConnectionOpen: true)
        }
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deferred-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory.appendingPathComponent("cache"))
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!, username: "proxy", password: "saved") : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://live.invalid/audio.mp3")! : server.url
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        _ = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Live", episodes: [
            .init(identifier: "live", title: "Live episode", media: .init(url: url.absoluteString, size: 0, durationMilliseconds: 0))]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        try await store.updatePreferences(feedID: 1) { $0.volumeAdaptation = .lightReduction }
        var outputs: [DeferredTransport] = []
        let engine = PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), makeFactory: {
            try PCMRecoveryFactory(mp3URL: $0, proxy: proxy, credentials: credentials, cache: cache, makeTransport: {
                let output = DeferredTransport(); outputs.append(output); return output
            })
        }, positionTicker: PCMPlaybackEngineTests.Ticker(), now: { 5000 })
        defer { engine.unload() }
        let player = PlaybackCoordinator(store: store, engine: engine, clock: { Date(timeIntervalSince1970: 5) })
        try await player.select(episodeID: 1, play: false)
        try await wait { player.phase == .paused || player.phase == .failed }
        try #require(player.phase == .paused && outputs.count == 1)
        #expect(engine.reading?.sample.durationMilliseconds == -1 && engine.reading?.sample.seekable == false)
        try await player.setSpeed(1.5)
        try await player.setSkipSilence(skipSilence)
        #expect(!outputs[0].playing)
        try await player.play()
        try await wait { outputs[0].playing }
        // Present part of the buffered period, then pause before exhaustion.
        try await wait {
            outputs[0].consumeAvailable()
            return (engine.reading?.sample.positionMilliseconds ?? 0) >= 5000
        }
        try await player.pause()
        let paused = try #require(engine.reading?.sample.positionMilliseconds)
        #expect(!outputs[0].playing)
        // The real eight-second upstream idle failure must arrive while paused.
        // Proxy authentication owns one earlier closed challenge connection.
        try await wait { disconnected.value >= (proxyEnabled ? 2 : 1) }
        // The dropped connection neither moves the paused position nor starts playback.
        #expect(engine.reading?.sample.positionMilliseconds == paused && !outputs[0].playing)
        if cancel {
            engine.unload()
            try await wait { outputs.allSatisfy(\.closed) }
        } else {
            try await player.play()
            var lastPosition: Int32 = paused
            try await wait {
                if outputs.count > 1 { return true }
                lastPosition = max(lastPosition, engine.reading?.sample.positionMilliseconds ?? 0)
                outputs[0].consumeAvailable()
                return false
            }
            try await wait { outputs[1].playing }
            // Everything already buffered (about 15 s of the 30 s episode) was played before
            // reconnecting: the first output presented all it was given, and the listened time
            // recorded at the restart covers it. With skip-silence on, this all-silent stream's
            // last stretch is skipped at its final output frame, the instant the stream restarts,
            // so the shown position is not sampled there (skipped silence counts when
            // heard; the earlier `lastPosition` check relied on Media3's count-when-processed).
            #expect(outputs[0].presentedAll)
            try await player.awaitPendingOperations()
            #expect(try await store.episode(id: 1)?.userState.playedDurationMilliseconds ?? 0 >= 14_000)
            if !skipSilence { #expect(lastPosition >= 14_000) }
            #expect(outputs[0].closed)
            // The live stream restarts at zero. With silence skipping,
            // the source-derived clock also includes silence already processed.
            if !skipSilence { #expect(engine.reading?.sample.positionMilliseconds == 0) }
            else { #expect((engine.reading?.sample.positionMilliseconds ?? -1) >= 0 && (engine.reading?.sample.positionMilliseconds ?? .max) < 3000) }
            #expect(engine.reading?.speed == 1.5 && engine.reading?.skipSilence == skipSilence)
            #expect(player.volumeAdaptation == .lightReduction && engine.reading?.sample.durationMilliseconds == -1)
            try await wait {
                outputs[1].consumeAvailable()
                return (engine.reading?.sample.positionMilliseconds ?? 0) >= 3000
            }
            try await player.pause()
            #expect(player.phase == .paused && !outputs[1].playing)
            let saved = try await store.episode(id: 1)
            #expect(saved?.userState.positionMilliseconds ?? 0 >= 3000)
            engine.unload()
        }
        try await store.close()
    }
}
@MainActor private final class DeferredTransport: PCMVolumePresentationTransport {
    var currentTime = CMTime.zero
    var onTimeChanged: (@MainActor () -> Void)?
    var onFailure: (@MainActor (any Error) -> Void)?
    var playing = false, closed = false
    private var endFrame: Int64 = 0
    private(set) var firstTimestamp: CMTime?
    var presentedAll: Bool { endFrame > 0 && currentTime == CMTime(value: endFrame, timescale: 44100) }
    func enqueue(_ buffer: CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>) async throws {
        if firstTimestamp == nil { firstTimestamp = buffer.presentationTimeStamp }
        let start = CMTimeConvertScale(buffer.presentationTimeStamp, timescale: 44100, method: .roundTowardZero).value
        endFrame = max(endFrame, start + Int64(buffer.sampleCount))
    }
    func setRendererVolume(_ volume: Float) {}
    func setPlaying(_ playing: Bool, at time: CMTime) { self.playing = playing; currentTime = time }
    func observeEnd(_ time: CMTime) {}
    func finishEnqueuing() {}
    func stopMonitoring() {}
    func close() { playing = false; closed = true }
    func consumeAvailable() {
        guard playing else { return }
        currentTime = CMTime(value: endFrame, timescale: 44100); onTimeChanged?()
    }
}
private final class DeferredCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func next() -> Int { lock.withLock { count += 1; return count } }
}
private final class DeferredFixtures: NSObject {}
