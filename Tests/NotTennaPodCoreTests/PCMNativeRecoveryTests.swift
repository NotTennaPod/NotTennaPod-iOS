import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized) struct PCMNativeRecoveryTests {
    private final class Transport: PCMVolumePresentationTransport {
        var currentTime = CMTime.zero
        var onTimeChanged: (@MainActor () -> Void)?
        var onFailure: (@MainActor (any Error) -> Void)?
        var buffers: [CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>] = []
        var playing = false, closed = false, finished = false
        var end = CMTime.zero
        func enqueue(_ buffer: CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>) async throws { buffers.append(buffer) }
        private(set) var rendererVolume: Float = 1
        func setRendererVolume(_ volume: Float) { rendererVolume = volume }
        func setPlaying(_ playing: Bool, at time: CMTime) { self.playing = playing; currentTime = time }
        func observeEnd(_ time: CMTime) { end = time }
        func finishEnqueuing() { finished = true }
        func stopMonitoring() { finished = false }
        func close() { closed = true; playing = false }
        func payload() throws -> Data {
            try buffers.reduce(into: Data()) { $0.append(try #require($1.content.withContiguousStorageIfAvailable { Data($0) })) }
        }
    }
    private func wait(_ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while try !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try #require(try condition())
    }
    /// The PCM before the volume stage.
    private func input(_ url: URL, speed: Float, silence: Bool) async throws -> [Int16] {
        let stream = try LocalPCMPlaybackStream(url: url, skipSilence: silence, speed: speed, maximumOutputFrames: 65536)
        defer { Task { await stream.cancel() } }
        var result: [Int16] = []
        while let raw = try await stream.next() { result += raw }
        return result
    }
    /// Composed check: renderer volume × queued PCM against Android's split, with `processedWith`
    /// the setting the whole queued PCM was processed with.
    private func expectHeard(_ output: Transport, _ input: [Int16], processedWith: FeedVolumeAdaptation,
                             renderer: FeedVolumeAdaptation, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let payload = PCMTestFixture.samples(try output.payload())
        #expect(payload.count == input.count, sourceLocation: sourceLocation)
        #expect(output.rendererVolume == VolumeOracle.Command(v: renderer.factor).playerVolume, sourceLocation: sourceLocation)
        VolumeOracle.expectComposed(actualPCM: payload, actualRenderer: [(0, output.rendererVolume)],
            referencePCM: VolumeOracle.processedPCM(input, channels: 2, sampleRate: 48000, commands: [(0, .init(v: processedWith.factor))]),
            referenceRenderer: [(0, VolumeOracle.Command(v: renderer.factor).playerVolume)], channels: 2,
            frames: input.count / 2, label: "processed \(processedWith), renderer \(renderer)", sourceLocation: sourceLocation)
    }

    @Test(arguments: FeedVolumeAdaptation.allCases, [false, true])
    func savedVolumeAndLiveChangesSurviveOfflineRendererRecovery(volume: FeedVolumeAdaptation, proxyEnabled: Bool) async throws {
        let (file, _) = try PCMTestFixture.waveFixture()
        let root = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try Data(contentsOf: file)
        let credentials = FeedCredentials(username: "native", password: "volume")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            return .init(headers: ["ETag": "\"volume\""], body: bytes)
        }
        defer { server.stop() }
        let url = proxyEnabled ? URL(string: "http://native-volume.invalid/wrong.mp3")! : server.url
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let database = root.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: database)
        _ = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Native volume", episodes: [
            .init(identifier: "one", title: "Episode", media: .init(url: url.absoluteString, size: 0, durationMilliseconds: 600))]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        try await store.updatePreferences(feedID: 1) { $0.volumeAdaptation = volume }
        var outputs: [Transport] = []
        let factory = PCMPlaybackFactory(cacheDirectory: root.appendingPathComponent("cache"), maximumOutputFrames: 65536,
            makeTransport: { let output = Transport(); outputs.append(output); return output })
        let engine = PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), resolveFactory: { _, selected in
            try await factory.make(.remote(selected, proxy: proxy, credentials: credentials))
        }, positionTicker: PCMPlaybackEngineTests.Ticker(), now: { 5000 })
        let player = PlaybackCoordinator(store: store, engine: engine, preferences: { _ in
            var result = PlaybackPreferences(); result.end.smartMarkAsPlayedSeconds = 0; return result
        }, clock: { Date(timeIntervalSince1970: 5) })
        do {
            try await player.select(episodeID: 1, play: false)
            try await wait { player.phase == .paused && outputs.first?.finished == true }
            let first = try #require(outputs.first)
            #expect(player.volumeAdaptation == volume && !first.playing)
            let original = try await input(file, speed: 1, silence: false)
            try expectHeard(first, original, processedWith: volume, renderer: volume)
            server.stop()
            let changed: FeedVolumeAdaptation = volume == .heavyBoost ? .heavyReduction : .heavyBoost
            try await store.updatePreferences(feedID: 1) { $0.volumeAdaptation = changed }
            try await player.refreshVolumeAdaptation(feedID: 1)
            // Everything was already queued: the renderer takes the new attenuation at once, the queued
            // PCM keeps the boost it was processed with (nothing is flushed or re-processed).
            try expectHeard(first, original, processedWith: volume, renderer: changed)
            #expect(player.volumeAdaptation == changed && !first.playing)
            try await player.setSpeed(2); try await player.setSkipSilence(true)
            let stale = first.onFailure
            first.onFailure?(NativeSampleBufferTransport.Failure.reconfigurationRequired)
            try await wait { outputs.count == 2 && outputs[1].finished && engine.reading?.buffering == false }
            let replacement = outputs[1]
            #expect(first.closed && !replacement.playing && player.phase == .paused)
            #expect(engine.reading?.sample.positionMilliseconds == 0 && engine.reading?.speed == 2 && engine.reading?.skipSilence == true)
            try expectHeard(replacement, try await input(file, speed: 2, silence: true), processedWith: changed, renderer: changed)
            #expect(try await store.episode(id: 1)?.userState.playState != .played)
            stale?(NativeSampleBufferTransport.Failure.reconfigurationRequired)
            #expect(outputs.count == 2)
            try await player.play()
            try await wait { replacement.playing }
            replacement.currentTime = replacement.end; replacement.onTimeChanged?()
            try await wait { player.phase == .idle }
            #expect(try await store.episode(id: 1)?.userState.playState == .played)
            engine.unload(); try await store.close()
            let reopened = try FeedLibraryStore(url: database)
            #expect(try await reopened.volumeAdaptation(forEpisode: 1) == changed)
            #expect(try await reopened.episode(id: 1)?.userState.playState == .played)
            try await reopened.close()
        } catch { engine.unload(); try? await store.close(); throw error }
    }

    private func fixture(_ name: String) throws -> URL {
        let folder = name.hasPrefix("variable") ? "FLACVariants" : "StreamingFormats"
#if SWIFT_PACKAGE
        return try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/" + folder))
#else
        return try #require(Bundle(for: NativeRecoveryFixtures.self).url(forResource: name, withExtension: nil,
            subdirectory: folder == "FLACVariants" ? folder : nil))
#endif
    }

    // The fixture's top-level mdat contains all referenced AAC bytes. Unused
    // movie metadata need not enter the persistent sparse cache. This checks
    // required media coverage independently of the native decoder's reads.
    private func requiredMediaRange(_ bytes: Data, name: String) throws -> Range<Int64> {
        guard name.hasSuffix(".m4a") else { return 0..<Int64(bytes.count) }
        var offset = 0
        while offset + 8 <= bytes.count {
            let size = bytes[offset..<(offset + 4)].reduce(0) { $0 * 256 + Int($1) }
            try #require(size >= 8 && size <= bytes.count - offset)
            if bytes[(offset + 4)..<(offset + 8)] == Data("mdat".utf8) {
                return Int64(offset + 8)..<Int64(offset + size)
            }
            offset += size
        }
        throw NativePCMDecoder.Failure.invalidFormat
    }
    private func covers(_ range: Range<Int64>, spans: [Range<Int64>]) -> Bool {
        var next = range.lowerBound
        for span in spans {
            if span.lowerBound > next { break }
            next = max(next, span.upperBound)
            if next >= range.upperBound { return true }
        }
        return false
    }

    @Test(arguments: ["tone.wav", "tone.flac", "tone.aac", "tone.m4a", "tone-tail.m4a", "variable.flac"], [false, true])
    func loadedEpisodePlaysOfflineThroughVolumeSpeedChangesAndRecovery(name: String, proxyEnabled: Bool) async throws {
        let bytes = try Data(contentsOf: fixture(name))
        let root = URL.temporaryDirectory.appendingPathComponent("native-output-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = FeedCredentials(username: "native", password: "recovery")
        let proxyAuthorization = "Basic " + Data("proxy:saved".utf8).base64EncodedString()
        let server = try await LoopbackHTTPServer.start { request in
            if proxyEnabled && request.headers["proxy-authorization"] != proxyAuthorization {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"source\""])
            }
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            return .init(headers: ["ETag": "\"native-output\""], body: bytes)
        }
        defer { server.stop() }
        let url = proxyEnabled ? URL(string: "http://native-output.invalid/wrong.mp3")! : server.url
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!, username: "proxy", password: "saved") : PodcastProxy()
        let cache = try SharedStreamingCache(directory: root)
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        var outputs: [NativeSampleBufferTransport] = []
        let factory = try PCMRecoveryFactory(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache,
            maximumOutputFrames: 4096, maximumQueuedBuffers: 4, makeTransport: {
                let output = NativeSampleBufferTransport(muted: true); outputs.append(output); return output
            })
        let owner = PCMRecoverySession(parameters: .init(speed: 1.5, skipSilence: true, volume: .lightReduction),
            lastPlayedMilliseconds: { 0 }, synchronizeStatistics: {}, factory: factory.make)
        defer { owner.close() }
        try await owner.seekPaused(to: 0)
        let required = try requiredMediaRange(bytes, name: name)
        try await wait {
            let transfer = remote.input.snapshot()
            return transfer.activeTransfers == 0 && !transfer.pendingRetry && transfer.failure == nil
                && covers(required, spans: cache.snapshot(for: url).spans)
        }
        #expect(owner.outputState == .paused && owner.sourceSeekable == true)
        #expect(abs((owner.sourceDurationMilliseconds ?? 0) - 8000) <= 100)
        server.stop()
        try owner.play()
        try await wait { try owner.positionMilliseconds > 150 }
        try owner.pause()
        for setting in FeedVolumeAdaptation.displayOrder { try owner.setVolumeAdaptation(setting) }
        try await owner.setParameters(speed: 2, skipSilence: false)
        try await owner.recoverPaused(to: 2000)
        let recovered = try owner.positionMilliseconds
        // Recovery lands within 0.25 s of the requested position, still paused.
        #expect(abs(recovered - 2000) <= 250 && owner.outputState == .paused)
        #expect(owner.parameters == .init(speed: 2, skipSilence: false, volume: .heavyBoost))
        try owner.play()
        try await wait { try owner.positionMilliseconds > recovered + 150 }
        try owner.pause()
        #expect(owner.failure == nil && owner.outputState == .paused)
        withExtendedLifetime(outputs) {}
    }
}
private final class NativeRecoveryFixtures: NSObject {}
