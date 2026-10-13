import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(1))) struct MP4StartupSourceTests {
    static let names = ["lc", "he", "hev2"].flatMap { profile in
        ["gapless", "gapless-tag", "tag-only"].map { profile + "-" + $0 + ".m4a" }
    }
    private struct Report: Decodable {
        let cases: [Case]
        struct Case: Decodable {
            let file: String, startMs: Int64, durationMs: Int64
            let admittedBytes: Int, buffers: [Buffer]
        }
        struct Buffer: Decodable { let mediaPtsUs: Int64, bytes: Int, decodeOnly: Bool }
    }
    private func fixture(_ name: String, directory: String = "MP4Gapless") throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/" + directory))
#else
        try #require(Bundle(for: MP4StartupFixtures.self).url(forResource: name, withExtension: nil, subdirectory: directory))
#endif
    }
    private func original(_ name: String, start: Int64) throws -> Report.Case {
        let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: fixture("android-report.json")))
        return try #require(report.cases.first { $0.file == name && $0.startMs == start })
    }
    /// User-visible outcome: duration shown within 50 ms of Android's, playback starts within
    /// 0.25 s of where Android's does, the whole remaining episode is decoded (within 50 ms) and
    /// reaches the output without gaps. Packet-level identity with Media3 is not required.
    private func verify(_ decoder: NativeAudioSourceDecoder, name: String, start: Int64) async throws {
        let expected = try original(name, start: start)
        #expect(decoder.sampleRate == 48000 && decoder.channels == 2)
        #expect(decoder.sourceDurationMilliseconds.map { abs($0 - expected.durationMs) <= 50 } == true)
        let observer = Observed(decoder)
        let stream = try LocalPCMPlaybackStream(decoder: observer, skipSilence: false, maximumOutputFrames: 127)
        var rendered = [Int16]()
        while let packet = try await stream.nextPacket() {
            #expect(packet.outputStartFrame == rendered.count / 2) // contiguous output: no gaps
            rendered += packet.samples
        }
        let packets = await observer.packets
        let buffers = expected.buffers.filter { !$0.decodeOnly }
        if let first = packets.first?.presentationTime, let android = buffers.first {
            #expect(abs(first.seconds - Double(android.mediaPtsUs) / 1_000_000) <= 0.25, "\(name) start\(start): starts at \(first.seconds) s")
        } else {
            #expect(packets.isEmpty == buffers.isEmpty)
        }
        let androidFrames = expected.admittedBytes / 4
        let decodedFrames = packets.reduce(0) { $0 + $1.samples.count } / 2
        #expect(abs(decodedFrames - androidFrames) <= 2400, "\(name) start\(start): decoded \(decodedFrames), Android \(androidFrames)")
        #expect(abs(rendered.count / 2 - decodedFrames) <= 2400, "\(name) start\(start): rendered \(rendered.count / 2) of \(decodedFrames)")
        await stream.cancel()
        #expect(await observer.cancelled)
    }

    @Test(arguments: names, ["episode.m4a", "opaque.media", "misleading.mp3"])
    func localSourceRetainsOpenedMediaAcrossSeeksAndPathReplacement(name: String, filename: String) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("startup-local-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: fixture(name), to: url)
        let source = try NativeLocalAudioSource(url: url)
        try await verify(source.makeDecoder(processStartupTrim: true), name: name, start: 0)
        try FileManager.default.removeItem(at: url)
        try Data("A different file now occupies this path.".utf8).write(to: url)
        // Force a producer replacement, so replay cannot pass just because the
        // short fixture's encoded packets already fit in the retained queue.
        let unprocessed = try await source.makeDecoder(processStartupTrim: false)
        #expect(unprocessed.sourceStartupTrim == nil)
        #expect(try await unprocessed.next() != nil)
        await unprocessed.cancel()
        for start: Int64 in [1500, 0] {
            try await verify(source.makeDecoder(start: CMTime(value: start, timescale: 1000), processStartupTrim: true), name: name, start: start)
        }
        let fresh = try NativeLocalAudioSource(url: url)
        await #expect(throws: (any Error).self) { try await fresh.makeDecoder(processStartupTrim: true) }
    }

    /// A first (cold) seek in a downloaded file plays like Android even after the
    /// player has dropped its source and holds only the decoder.
    @Test(arguments: names)
    func coldLocalSeekPreservesStartupInterval(name: String) async throws {
        var source: NativeLocalAudioSource? = try NativeLocalAudioSource(url: fixture(name))
        let decoder = try await #require(source).makeDecoder(start: CMTime(value: 1500, timescale: 1000), processStartupTrim: true)
        source = nil
        try await verify(decoder, name: name, start: 1500)
        await #expect(throws: CancellationError.self) { try await decoder.next() }
    }

    @MainActor @Test(arguments: names, [false, true])
    func localFactoryCompletesAndPersistsPlayedState(name: String, automatic: Bool) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("startup-local-player-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("download.media")
        try FileManager.default.copyItem(at: fixture(name), to: url)
        let database = root.appendingPathComponent("library.sqlite"), store = try FeedLibraryStore(url: database)
        _ = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Local startup feed", episodes: [
            .init(identifier: "one", title: "Downloaded episode", media: .init(url: "https://example.test/episode", size: 0, durationMilliseconds: 4000))]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        var outputs: [SampleBufferPCMOutputTests.Transport] = []
        let factory = PCMPlaybackFactory(cacheDirectory: root.appendingPathComponent("unused-cache"), makeTransport: {
            let output = SampleBufferPCMOutputTests.Transport(); outputs.append(output); return output
        })
        let engine = PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), resolveFactory: { _, _ in
            try await factory.make(automatic ? .local(url) : .nativeLocal(url))
        }, positionTicker: PCMPlaybackEngineTests.Ticker(), now: { 5000 })
        let player = PlaybackCoordinator(store: store, engine: engine, preferences: { _ in
            var result = PlaybackPreferences(); result.end.smartMarkAsPlayedSeconds = 0; return result
        }, clock: { Date(timeIntervalSince1970: 5) })
        do {
            try await player.select(episodeID: 1, play: true)
            let deadline = ContinuousClock.now + .seconds(10)
            while player.phase != .idle, player.phase != .failed, ContinuousClock.now < deadline {
                if let output = outputs.last, output.playing { output.currentTime = output.end; output.onTimeChanged?() }
                await Task.yield()
            }
            try #require(player.phase == .idle, "Local completion: \(player.phase)")
            let output = try #require(outputs.last)
            var count = 0
            for buffer in output.buffers { count += try #require(buffer.content.withContiguousStorageIfAvailable { $0.count }) }
            let expected = try original(name, start: 0)
            // The whole episode reached the output (within 50 ms at 48 kHz stereo 16-bit).
            #expect(abs(count - expected.admittedBytes) <= 2400 * 4)
            #expect(output.closed)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("unused-cache").path))
            engine.unload(); try await store.close()
            let reopened = try FeedLibraryStore(url: database)
            #expect(try await reopened.episode(id: 1)?.userState.playState == .played)
            #expect(try await reopened.playbackSession() == nil)
            try await reopened.close()
        } catch { engine.unload(); try? await store.close(); throw error }
    }

    @MainActor @Test(arguments: ["lc-gapless.m4a", "he-gapless.m4a", "hev2-gapless.m4a"], [false, true])
    func localNativeTransportCompletesProcessedSeekAndRestart(name: String, automatic: Bool) async throws {
        let cache = URL.temporaryDirectory.appendingPathComponent("startup-native-unused-\(UUID())")
        defer { try? FileManager.default.removeItem(at: cache) }
        let owner = PCMPlaybackFactory(cacheDirectory: cache, makeTransport: { NativeSampleBufferTransport(muted: true) })
        let factory = try await owner.make(automatic ? .local(fixture(name)) : .nativeLocal(fixture(name)))
        #expect(factory.providesSourceDuration)
        for start: Int64 in [1500, 0] {
            let session = try await factory.make(positionMilliseconds: start,
                parameters: .init(speed: 1.5, skipSilence: true, volume: .heavyBoost))
            defer { session.close() }
            #expect(session.state == .idle && session.writtenFrames == 0)
            try await session.prepare(); try session.play()
            let deadline = ContinuousClock.now + .seconds(10)
            while session.state != .ended, session.failure == nil, ContinuousClock.now < deadline { await Task.yield() }
            #expect(session.state == .ended && session.failure == nil)
            #expect(session.sourceDurationMilliseconds == 4000 && session.sourceSeekable == true)
            #expect(session.writtenFrames > 0 && session.presentedFrames == session.writtenFrames)
            session.close()
        }
    }

    @MainActor @Test func invalidOrCancelledLocalSourceCannotCreateOutput() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("startup-invalid-local-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("invalid.media")
        try Data("This is not MP4 audio.".utf8).write(to: url)
        var outputs = 0
        let factory = try PCMRecoveryFactory(nativeSourceURL: url, makeTransport: { outputs += 1; return SampleBufferPCMOutputTests.Transport() })
        await #expect(throws: (any Error).self) {
            try await factory.make(positionMilliseconds: 0, parameters: .init(speed: 1, skipSilence: false))
        }
        let valid = try PCMRecoveryFactory(nativeSourceURL: fixture("lc-gapless.m4a"), makeTransport: { outputs += 1; return SampleBufferPCMOutputTests.Transport() })
        let task = Task { try await valid.make(positionMilliseconds: 0, parameters: .init(speed: 1, skipSilence: false)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(outputs == 0)
    }

    @MainActor @Test(arguments: ["lc", "he", "hev2"], ["single", "sequence", "window"])
    func emptyLocalSourceEndsWithoutAudioAtEveryRequestedStart(profile: String, variant: String) async throws {
        var outputs: [SampleBufferPCMOutputTests.Transport] = []
        let factory = try PCMRecoveryFactory(nativeSourceURL: fixture(profile + "-empty-" + variant + ".m4a", directory: "AACEmptyEdits"), makeTransport: {
            let output = SampleBufferPCMOutputTests.Transport(); outputs.append(output); return output
        })
        for start: Int64 in [0, 1500] {
            let session = try await factory.make(positionMilliseconds: start, parameters: .init(speed: 1.5, skipSilence: true))
            defer { session.close() }
            try await session.prepare()
            #expect(session.state == .ended && session.failure == nil)
            #expect(session.sourceDurationMilliseconds == 0 && session.sourceSeekable == true)
            #expect(session.writtenFrames == 0 && session.presentedFrames == 0)
            #expect(try session.mediaMicroseconds == 0)
            session.close()
        }
        #expect(outputs.count == 2 && outputs.allSatisfy { $0.buffers.isEmpty && $0.closed })
    }

    @Test(arguments: names, 0..<8)
    func realDirectProxyAndUnknownSourceUsesOriginalUnitsAndStartup(name: String, configuration: Int) async throws {
        let known = configuration & 1 == 0, proxyEnabled = configuration & 2 != 0
        let start: Int64 = configuration & 4 == 0 ? 0 : 1500
        let bytes = try Data(contentsOf: fixture(name))
        let credentials = FeedCredentials(username: "startup", password: "saved")
        let proxyAuthorization = "Basic " + Data("proxy:saved".utf8).base64EncodedString()
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            if proxyEnabled && request.headers["proxy-authorization"] != proxyAuthorization {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"startup\""])
            }
            return .init(headers: ["Content-Type": "audio/mp4"], body: bytes, includeAutomaticContentLength: known)
        }
        defer { server.stop() }
        let directory = URL.temporaryDirectory.appendingPathComponent("startup-source-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!, username: "proxy", password: "saved") : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://startup.invalid/episode.media")! : server.url
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache)
        defer { remote.input.cancel(); remote.relay.cancel() }
        let decoder = try await source.makeDecoder(start: CMTime(value: start, timescale: 1000), processStartupTrim: true)
        try await verify(decoder, name: name, start: start)
    }

    @Test(arguments: names)
    func exactModeAndRetainedOfflineSeeksDoNotShareTrimmedCoordinates(name: String) async throws {
        let bytes = try Data(contentsOf: fixture(name))
        let server = try await LoopbackHTTPServer.start { _ in .init(headers: ["Content-Type": "audio/mp4"], body: bytes) }
        defer { server.stop() }
        let directory = URL.temporaryDirectory.appendingPathComponent("startup-retained-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory), url = server.url
        let remote = try await PCMRemoteInput.open(url: url, proxy: PodcastProxy(), credentials: nil, cache: cache)
        let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: PodcastProxy(), credentials: nil, cache: cache)
        defer { remote.input.cancel(); remote.relay.cancel() }
        let before = try await source.makeDecoder(admission: .exactFrame)
        var baselineFrames: Int64 = 0
        while let packet = try await before.next() { baselineFrames += Int64(packet.frameCount) }
        await before.cancel()
        try await verify(source.makeDecoder(processStartupTrim: true), name: name, start: 0)
        #expect(cache.snapshot(for: url).committedBytes == bytes.count)
        let requests = server.requests.count
        server.stop()
        for start: Int64 in [1500, 0] {
            try await verify(source.makeDecoder(start: CMTime(value: start, timescale: 1000), processStartupTrim: true), name: name, start: start)
        }
        let exact = try await source.makeDecoder(admission: .exactFrame)
        #expect(exact.sourceStartupTrim == nil)
        var frames: Int64 = 0
        while let packet = try await exact.next() {
            #expect(packet.presentationTime == CMTime(value: frames, timescale: 48000))
            frames += Int64(packet.frameCount)
        }
        let native = try AVAudioFile(forReading: fixture(name))
        #expect(abs(frames - baselineFrames) <= 2400)
        #expect(abs(frames - native.length) <= 2400)
        await exact.cancel()
        try await verify(source.makeDecoder(processStartupTrim: true), name: name, start: 0)
        let reopened = try await PCMRemoteInput.open(url: url, proxy: PodcastProxy(), credentials: nil, cache: cache)
        let fresh = try NativeAudioPlaybackSource(remote: reopened, url: url, proxy: PodcastProxy(), credentials: nil, cache: cache)
        defer { reopened.input.cancel(); reopened.relay.cancel() }
        try await verify(fresh.makeDecoder(start: CMTime(value: 1500, timescale: 1000), processStartupTrim: true), name: name, start: 1500)
        #expect(server.requests.count == requests)
    }

    @Test func trimUnitConversionRejectsInvalidAndOverflowingValues() throws {
        for rate in [24000, 44100, 48000, 96000] {
            #expect(try PCMStartupTrim.mp4(.init(delay: 512, padding: 2112, unitsPerSecond: 48000), sampleRate: rate).frameCount == Int64(512 * rate / 48000))
            #expect(try PCMStartupTrim.mp4(.init(delay: 100, padding: 200, unitsPerSecond: nil), sampleRate: rate).frameCount == 100)
        }
        for (delay, scale, rate): (Int64, Int64?, Int) in [(-1, nil, 48000), (1, 0, 48000), (1, -1, 48000), (Int64.max, 1, 48000), (1, nil, 0)] {
            #expect(throws: LocalPCMPlaybackStream.Failure.invalidInput) {
                try PCMStartupTrim.mp4(.init(delay: delay, padding: 0, unitsPerSecond: scale), sampleRate: rate)
            }
        }
    }

    @Test(arguments: ["lc", "he", "hev2"])
    func truncatedPhysicalTailCannotCompleteNormally(profile: String) async throws {
        let bytes = try Data(contentsOf: fixture(profile + "-gapless.m4a"))
        var timeline = try await NativeAudioSourceTimeline.read(input: Bytes(bytes), format: .mp4)
        timeline.mp4AudioEdit = try #require(timeline.mp4UntrimmedAudio)
        let input = Bytes(Data(bytes.dropLast(100)))
        let producer = NativeAudioPacketProducer(input: input, timeline: timeline, format: .mp4,
            indexedStart: .zero, applyMP4Edits: true)
        defer { producer.stop() }
        var frames = 0, failure: (any Error)?
        do {
            let decoder = try await NativeBufferedAudioDecoder.open(producer: producer, admission: .wholeBuffer)
            defer { Task { await decoder.cancel() } }
            while let packet = try await decoder.next() { frames += packet.frameCount }
            await decoder.cancel()
        } catch { failure = error }
        #expect(failure != nil)
        // A short input can fail before its first native packet batch is
        // published. Both early rejection and an incomplete drain are valid;
        // declaring all physical source frames complete is not.
        #expect(frames < (try original(profile + "-gapless.m4a", start: 0)).admittedBytes / 4)
        producer.stop()
        await producer.waitForExit()
    }

    @Test(arguments: ["lc", "he", "hev2"])
    func clipTrimUsesOriginalMediaAndDefaultRouteRemainsAvailable(profile: String) async throws {
        let name = profile + "-clip-tag.m4a", bytes = try Data(contentsOf: fixture(name))
        let server = try await LoopbackHTTPServer.start { _ in .init(headers: ["Content-Type": "audio/mp4"], body: bytes) }
        defer { server.stop() }
        let directory = URL.temporaryDirectory.appendingPathComponent("startup-clip-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let remote = try await PCMRemoteInput.open(url: server.url, proxy: PodcastProxy(), credentials: nil, cache: cache)
        defer { remote.input.cancel(); remote.relay.cancel() }
        let source = try NativeAudioPlaybackSource(remote: remote, url: server.url, proxy: PodcastProxy(), credentials: nil, cache: cache)
        try await verify(source.makeDecoder(processStartupTrim: true), name: name, start: 0)
        let decoder = try await source.makeDecoder()
        #expect(decoder.sourceStartupTrim == nil)
        let expected = try original(name, start: 0).buffers.filter { !$0.decodeOnly }
        var packets = [NativePCMDecoder.Packet]()
        while let packet = try await decoder.next() { packets.append(packet) }
        // The default route plays the same clipped span as Android: same start (±0.25 s) and length (±50 ms).
        let first = try #require(packets.first?.presentationTime), androidFirst = try #require(expected.first)
        #expect(abs(first.seconds - Double(androidFirst.mediaPtsUs) / 1_000_000) <= 0.25)
        let frames = packets.reduce(0) { $0 + $1.samples.count } / 2
        #expect(abs(frames - expected.reduce(0) { $0 + $1.bytes } / 4) <= 2400)
        await decoder.cancel()
    }

    private final class Bytes: MediaByteInput {
        let data: Data
        private let cancelled = Mutex(false)
        init(_ data: Data) { self.data = data }
        var length: Int64? { Int64(data.count) }
        var supportsRandomAccess: Bool { true }
        func prepareForSeek() {}
        func cancel() { cancelled.withLock { $0 = true } }
        func checkFailure() throws { if cancelled.withLock({ $0 }) { throw CancellationError() } }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            try checkFailure()
            guard offset < data.count else { return Data() }
            return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + maximumCount))
        }
    }

    private actor Observed: PCMDecoding {
        nonisolated let sampleRate: Int, channels: Int, startFrame: Int64, startTime: CMTime
        nonisolated let sourceStartupTrim: PCMStartupTrim?
        private let decoder: NativeAudioSourceDecoder
        private(set) var packets = [NativePCMDecoder.Packet](), cancelled = false
        init(_ decoder: NativeAudioSourceDecoder) {
            self.decoder = decoder; sampleRate = decoder.sampleRate; channels = decoder.channels
            startFrame = decoder.startFrame; startTime = decoder.startTime; sourceStartupTrim = decoder.sourceStartupTrim
        }
        func next() async throws -> NativePCMDecoder.Packet? {
            let packet = try await decoder.next()
            if let packet { packets.append(packet) }
            return packet
        }
        func cancel() async { cancelled = true; await decoder.cancel() }
    }
}
private final class MP4StartupFixtures: NSObject {}
