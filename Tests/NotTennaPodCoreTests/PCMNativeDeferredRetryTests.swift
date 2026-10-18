import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized) struct PCMNativeDeferredRetryTests {
    private func wait(_ condition: () async throws -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(12)
        repeat {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        } while ContinuousClock.now < end
        try #require(try await condition())
    }
    private func media(_ name: String) throws -> Data {
#if SWIFT_PACKAGE
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
#else
        let url = try #require(Bundle(for: NativeDeferredFixtures.self).url(forResource: name, withExtension: nil))
#endif
        return try Data(contentsOf: url)
    }
    enum Outcome: Sendable { case cancel, live, recorded }
    struct Scenario: Sendable {
        let proxyEnabled: Bool
        let outcome: Outcome
        let skipSilence: Bool
    }
    /// Each scenario waits for the real eight-second upstream idle failure, so every outcome and
    /// setting is covered once instead of the full 2×3×2 grid.
    nonisolated static let scenarios = [
        Scenario(proxyEnabled: false, outcome: .live, skipSilence: false),
        Scenario(proxyEnabled: true, outcome: .live, skipSilence: true),
        Scenario(proxyEnabled: false, outcome: .recorded, skipSilence: true),
        Scenario(proxyEnabled: true, outcome: .recorded, skipSilence: false),
        Scenario(proxyEnabled: true, outcome: .cancel, skipSilence: false),
    ]
    @Test(arguments: scenarios)
    func liveAACDropWhilePausedPlaysBufferedAudioThenRestartsKeepingSettingsAndStatistics(scenario: Scenario) async throws {
        let proxyEnabled = scenario.proxyEnabled, cancel = scenario.outcome == .cancel, skipSilence = scenario.skipSilence
        let bytes = try media("tone.aac"), recorded = try media("tone.wav"), count = NativeDeferredCounter()
        let credentials = FeedCredentials(username: "live", password: "captured")
        let proxyAuthorization = "Basic " + Data("proxy:saved".utf8).base64EncodedString()
        let server = try await LoopbackHTTPServer.start { request in
            if proxyEnabled && request.headers["proxy-authorization"] != proxyAuthorization {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"live\""])
            }
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            let first = count.next() == 1
            if !first && scenario.outcome == .recorded {
                return .init(headers: ["Content-Type": "audio/wav"], body: recorded)
            }
            let data = first ? Data(bytes.prefix(bytes.count / 2)) : bytes
            return .init(headers: ["Content-Type": "audio/aac", "Transfer-Encoding": "chunked", "ETag": first ? "\"old-live\"" : "\"new-live\""],
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
        try await store.updateEpisode(id: 1) { $0.userState.playedDurationMilliseconds = 10_000 }
        var outputs: [NativeDeferredTransport] = []
        var captured: PCMRemoteInput?
        let engine = PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), resolveFactory: { _, selected in
            let remote = try await PCMRemoteInput.open(url: selected, proxy: proxy, credentials: credentials, cache: cache)
            captured = remote
            return try PCMRecoveryFactory(remote: remote, url: selected, proxy: proxy, credentials: credentials, cache: cache,
                maximumOutputFrames: 4096, maximumQueuedBuffers: 4, makeTransport: {
                    let output = NativeDeferredTransport(); outputs.append(output); return output
                })
        }, positionTicker: PCMPlaybackEngineTests.Ticker(), now: { 5000 })
        defer { engine.unload() }
        let player = PlaybackCoordinator(store: store, engine: engine, clock: { Date(timeIntervalSince1970: 5) })
        var resets: [PlaybackEngineReading] = []
        let consume = engine.onEvent
        engine.onEvent = { event in
            if case .timelineReset(let reading) = event { resets.append(reading) }
            consume?(event)
        }
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
            return (engine.reading?.sample.positionMilliseconds ?? 0) >= 1000
        }
        try await player.pause()
        let paused = try #require(engine.reading?.sample.positionMilliseconds)
        #expect(!outputs[0].playing)
        // Keep the incomplete chunked body open until the actual eight-second
        // upstream idle failure. Closing it can be interpreted as normal EOF;
        // the original fixture distinguishes that from interruption.
        try await wait { captured?.retry.requiresDeferredRestart == true }
        // The dropped connection neither moves the paused position nor starts playback.
        #expect(engine.reading?.sample.positionMilliseconds == paused && !outputs[0].playing)
        if cancel {
            engine.unload()
            try await wait { outputs.allSatisfy(\.closed) }
            #expect(resets.isEmpty)
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
            // Everything already buffered was played before reconnecting.
            #expect(lastPosition >= 3000)
            #expect(outputs[0].closed)
            // The stream restarts at zero. With silence skipping,
            // the source-derived clock also includes silence already processed.
            if !skipSilence { #expect(engine.reading?.sample.positionMilliseconds == 0) }
            else { #expect((engine.reading?.sample.positionMilliseconds ?? -1) >= 0 && (engine.reading?.sample.positionMilliseconds ?? .max) < 3000) }
            #expect(engine.reading?.speed == 1.5 && engine.reading?.skipSilence == skipSilence)
            #expect(player.volumeAdaptation == .lightReduction)
            #expect(engine.reading?.sample.durationMilliseconds == (scenario.outcome == .recorded ? 8000 : -1))
            #expect(engine.reading?.sample.seekable == (scenario.outcome == .recorded))
            try await wait {
                outputs[1].consumeAvailable()
                return (engine.reading?.sample.positionMilliseconds ?? 0) >= 1500
            }
            try await player.pause()
            #expect(player.phase == .paused && !outputs[1].playing)
            let saved = try await store.episode(id: 1)
            #expect(saved?.userState.positionMilliseconds ?? 0 >= 1500)
            #expect(saved?.details.media?.durationMilliseconds == (scenario.outcome == .recorded ? 8000 : 0))
            #expect(saved?.userState.playState != .played)
            try #require(resets.count == 1)
            let finalPosition = resets[0].sample.positionMilliseconds
            #expect(finalPosition >= lastPosition)
            #expect(saved?.userState.playedDurationMilliseconds == 10_000 + Int64(finalPosition) + Int64(saved?.userState.positionMilliseconds ?? -1))
            #expect(try await store.playbackSession()?.playedDurationWhenStarted == 10_000 + Int64(finalPosition))
            engine.unload()
        }
        try await store.close()
    }
}
@MainActor private final class NativeDeferredTransport: PCMVolumePresentationTransport {
    var currentTime = CMTime.zero
    var onTimeChanged: (@MainActor () -> Void)?
    var onFailure: (@MainActor (any Error) -> Void)?
    var playing = false, closed = false
    private var endFrame: Int64 = 0
    private(set) var firstTimestamp: CMTime?
    func enqueue(_ buffer: CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>) async throws {
        if firstTimestamp == nil { firstTimestamp = buffer.presentationTimeStamp }
        let start = CMTimeConvertScale(buffer.presentationTimeStamp, timescale: 48000, method: .roundTowardZero).value
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
        currentTime = CMTime(value: endFrame, timescale: 48000); onTimeChanged?()
    }
}
private final class NativeDeferredCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func next() -> Int { lock.withLock { count += 1; return count } }
}
private final class NativeDeferredFixtures: NSObject {}
