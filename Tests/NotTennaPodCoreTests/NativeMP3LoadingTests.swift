import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct NativeMP3LoadingTests {
    private final class Transport: PCMPresentationTransport {
        var currentTime = CMTime.zero
        var onTimeChanged: (@MainActor () -> Void)?
        var onFailure: (@MainActor (any Error) -> Void)?
        var playing = false, closed = false
        var buffers: [CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>] = []
        func enqueue(_ buffer: CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>) async throws { buffers.append(buffer) }
        func setPlaying(_ value: Bool, at time: CMTime) { playing = value; currentTime = time }
        func observeEnd(_ time: CMTime) {}
        func finishEnqueuing() {}
        func stopMonitoring() {}
        func close() { closed = true; playing = false }
        func advance(to frames: Int64) { currentTime = CMTime(value: frames, timescale: 44100); onTimeChanged?() }
    }
    private final class Input: MediaByteInput {
        let bytes: Data
        let stopped = Mutex(false)
        let sourceFailure: PCMSourceFailure? = PCMSourceFailure()
        init(_ bytes: Data) { self.bytes = bytes }
        var length: Int64? { Int64(bytes.count) }
        var supportsRandomAccess: Bool { true }
        func prepareForSeek() { Issue.record("MP3 sequential loading must not request a range seek") }
        func checkFailure() throws { if stopped.withLock({ $0 }) { throw CancellationError() } }
        func cancel() { stopped.withLock { $0 = true } }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            try checkFailure()
            return bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + maximumCount))
        }
    }
    private func media() throws -> Data {
#if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: "playback-unknown-duration", withExtension: "mp3", subdirectory: "Fixtures")!
#else
        let url = Bundle(for: MP3LoadingFixtures.self).url(forResource: "playback-unknown-duration", withExtension: "mp3")!
#endif
        let data = try Data(contentsOf: url)
        // Independently inspected no-Xing fixture: 1150 CBR MPEG1 frames,
        // each104 bytes and1152 samples at44100Hz, no ID3/tag bytes.
        #expect(data.count == 1150 * 104)
        return data
    }
    nonisolated private func chunk(_ data: Data) -> Data { Data("\(String(data.count, radix: 16))\r\n".utf8) + data + Data("\r\n".utf8) }
    private func wait(_ condition: () async throws -> Bool) async throws {
        let limit = ContinuousClock.now + .seconds(5)
        while try !(await condition()), ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(2)) }
        try #require(try await condition())
    }
    private func read(_ producer: NativeMP3PacketProducer) async throws -> NativeMP3PacketParser.Batch? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(with: Result { try producer.next() }) }
        }
    }

    @Test(arguments: [false, true])
    func unknownDurationAppearsAtEndWhilePausedAndStaysUnseekable(proxyEnabled: Bool) async throws {
        let bytes = try media(), prefix = 104 * 100
        let auth = "Basic " + Data("saved:proxy".utf8).base64EncodedString()
        let server = try await LoopbackHTTPServer.start { request in
            if proxyEnabled, request.headers["proxy-authorization"] != auth {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"loading\""])
            }
            return .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"],
                body: chunk(Data(bytes.prefix(prefix))), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!,
            username: "saved", password: "proxy") : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://mp3-loading.invalid/audio.mp3")! : server.url
        let source = NativeMP3PlaybackSource(url: url, proxy: proxy)
        let decoder = try await source.makeDecoder(prepareSourceTimeline: true)
        let transport = Transport()
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: false, speed: 1, maximumOutputFrames: 127)
        let session = try SampleBufferPlaybackSession(stream: stream, transport: transport, maximumQueuedBuffers: 2)
        defer { session.close() }
        try await session.prepare()
        try await wait { (await source.networkSnapshot)?.waitingReaders == 1 }
        #expect(session.state == .paused && !transport.playing)
        #expect(session.sourceDurationMilliseconds == nil && session.sourceSeekable == false)
        let mediaConnection = try #require(server.requests.lastIndex { !proxyEnabled || $0.headers["proxy-authorization"] == auth })
        try await server.appendResponseBody(chunk(Data(bytes.dropFirst(prefix))), toConnectionAt: mediaConnection)
        try await wait { let network = await source.networkSnapshot; return decoder.producerSnapshot.parsedFrames >= 1140 * 1152 && network?.waitingReaders == 1 }
        // All bytes arrived but the stream has not ended: duration still unknown.
        #expect(session.sourceDurationMilliseconds == nil)
        try await server.appendResponseBody(Data("0\r\n\r\n".utf8), toConnectionAt: mediaConnection, isFinal: true)
        try await wait { session.sourceDurationMilliseconds != nil }
        #expect(abs((session.sourceDurationMilliseconds ?? 0) - 30024) <= 100)
        // Learning the duration neither starts playback nor makes the stream seekable.
        #expect(session.sourceSeekable == false && session.state == .paused && !transport.playing)
    }

    @Test(arguments: [Float(1), Float(2)])
    func playbackWaitsForEnoughBufferedAudioThenStartsAtBeginning(speed: Float) async throws {
        let bytes = try media(), initial = 30 * 104
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"],
                body: chunk(Data(bytes.prefix(initial))), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let source = NativeMP3PlaybackSource(url: server.url, proxy: PodcastProxy())
        let decoder = try await source.makeDecoder(prepareSourceTimeline: true)
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: false, speed: speed, maximumOutputFrames: 127)
        let transport = Transport()
        let session = try SampleBufferPlaybackSession(stream: stream, transport: transport, maximumQueuedBuffers: 2)
        defer { session.close() }
        try await session.prepare()
        try session.play()
        // Under a second of audio: shows buffering instead of stuttering.
        #expect(session.state == .buffering && !transport.playing)
        let enough = 155 * 104 // about 4 s of audio
        try await server.appendResponseBody(chunk(bytes.subdata(in: initial..<enough)))
        try await wait { session.state == .playing }
        #expect(transport.playing)
        #expect(try session.mediaMicroseconds == 0)
        _ = decoder
    }

    @Test(arguments: [Float(1), Float(2)])
    func runningOutOfDataBuffersAndResumesAtSamePosition(speed: Float) async throws {
        let bytes = try media(), initialBytes = 8192
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"],
                body: chunk(Data(bytes.prefix(initialBytes))), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let source = NativeMP3PlaybackSource(url: server.url, proxy: PodcastProxy())
        let decoder = try await source.makeDecoder(prepareSourceTimeline: true)
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: false, speed: speed, maximumOutputFrames: 1024)
        let transport = Transport()
        let session = try SampleBufferPlaybackSession(stream: stream, transport: transport, maximumQueuedBuffers: 2)
        defer { session.close() }
        try await session.prepare(); try session.play()
        try await wait { session.state == .playing }
        // Consume one output slot at a time and wait for its replacement.
        // Jumping past both queued slots would invent a renderer scheduling
        // starvation before the independently loaded encoded queue is exhausted.
        while !decoder.producerSnapshot.waitingConsumer {
            let written = session.writtenFrames
            transport.advance(to: min(session.presentedFrames + 1024, written))
            try await wait { session.writtenFrames > written || decoder.producerSnapshot.waitingConsumer }
        }
        transport.advance(to: session.writtenFrames)
        #expect(session.state == .buffering && session.output.isRebuffering && !transport.playing)
        let frozen = try #require(try session.mediaMicroseconds)
        let enoughBytes = initialBytes + (speed == 1 ? 12288 : 20480)
        try await server.appendResponseBody(chunk(bytes.subdata(in: initialBytes..<enoughBytes)))
        try await wait { session.state == .playing }
        #expect(transport.playing && session.wantsPlayback)
        // Nothing was skipped while buffering.
        #expect(try session.mediaMicroseconds == frozen)
    }

    @Test func loadingPausesAtMemoryBudgetAndResumesAsPlaybackProgresses() async throws {
        let original = try media()
        var bytes = Data()
        for _ in 0..<30 { bytes.append(original) }
        let input = Input(bytes)
        let producer = NativeMP3PacketProducer(input: input, prepareSourceTimeline: true, targetBytes: 2 * 65_536)
        defer { producer.stop() }
        try await wait { producer.snapshot().waitingForBudget }
        let first = producer.snapshot()
        // Loading stops well before the whole (long) file is held in memory.
        #expect(!first.ended && first.parsedFrames < Int64(30 * 1150 * 1152))
        #expect(first.allocatedBytes <= 32 * 65_536)
        var frames: Int64 = 0
        while producer.snapshot().unreadPackets > 0 {
            let batch = try #require(try await read(producer))
            #expect(batch.firstFrame == frames)
            frames += batch.frameCount
        }
        let position = (frames - 1152) * 1_000_000 / 44100
        try producer.updatePlayback(PCMPlaybackLoadState(positionMicroseconds: position, speed: 2))
        try await wait { producer.snapshot().parsedFrames > frames }
        #expect(producer.snapshot().retainedPackets < first.retainedPackets * 2)
        producer.stop(); await producer.waitForExit()
    }

    @Test func seekingBeyondEncodedBudgetCanDrainPrefixWithoutAPlaybackClock() async throws {
        var bytes = Data()
        let original = try media()
        for _ in 0..<30 { bytes.append(original) }
        let producer = NativeMP3PacketProducer(input: Input(bytes), prepareSourceTimeline: true, targetBytes: 2 * 65_536)
        defer { producer.stop() }
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            Issue.record("Encoded seek prefix stayed blocked after consumption freed retained allocations")
            producer.stop()
        }
        defer { watchdog.cancel() }
        try await wait { producer.snapshot().waitingForBudget }
        try producer.updatePlayback(PCMPlaybackLoadState(positionMicroseconds: 800_000_000, speed: 1))
        var frames: Int64 = 0
        while frames < 800 * 44100 {
            let batch = try #require(try await read(producer))
            #expect(batch.firstFrame == frames)
            frames += batch.frameCount
        }
        #expect(frames >= 800 * 44100 && producer.sourceFailure.error == nil)
        producer.stop(); await producer.waitForExit()
    }

    @Test func shortCompleteEpisodeStartsPlayingDespiteSmallBuffer() async throws {
        let bytes = Data(try media().prefix(30 * 104))
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"],
                body: chunk(bytes) + Data("0\r\n\r\n".utf8))
        }
        defer { server.stop() }
        let output = Transport()
        let factory = try PCMRecoveryFactory(mp3URL: server.url, proxy: PodcastProxy(), maximumOutputFrames: 127,
            maximumQueuedBuffers: 2, makeTransport: { output })
        let session = try await factory.make(positionMilliseconds: 0, parameters: .init(speed: 2, skipSilence: false))
        defer { session.close() }
        try await session.prepare()
        try await wait { session.sourceDurationMilliseconds != nil }
        #expect(abs((session.sourceDurationMilliseconds ?? 0) - 767) <= 100 && session.sourceSeekable == false)
        try session.play()
        #expect(session.state == .playing && output.playing)
    }
}
private final class MP3LoadingFixtures: NSObject {}
