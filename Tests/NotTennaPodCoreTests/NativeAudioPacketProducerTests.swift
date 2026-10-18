import AVFoundation
import CryptoKit
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct NativeAudioPacketProducerTests {
    static let names = ["tone.wav", "tone.aac", "tone.m4a", "tone.flac"]
    private func fixture(_ name: String) throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
#else
        try #require(Bundle(for: NativePacketFixtures.self).url(forResource: name, withExtension: nil))
#endif
    }
    private func format(_ name: String) -> NativeAudioSourceTimeline.Format {
        name.hasSuffix("wav") ? .wav : name.hasSuffix("aac") ? .adts : name.hasSuffix("m4a") ? .mp4 : .flac
    }
    private func timeline(_ bytes: Data, name: String) async throws -> NativeAudioSourceTimeline {
        try await NativeAudioSourceTimeline.read(input: Bytes(bytes), format: format(name))
    }
    private func baseline(_ name: String) throws -> [Int16] {
        let file = try AVAudioFile(forReading: fixture(name), commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var result: [Int16] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, file.length - file.framePosition)))
            try #require(buffer.frameLength > 0)
            result += Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * Int(file.processingFormat.channelCount)))
        }
        return result
    }
    private func collect(_ decoder: NativeBufferedAudioDecoder) async throws -> [Int16] {
        var result: [Int16] = []
        while let packet = try await decoder.next() {
            #expect(packet.presentationTime == CMTime(value: Int64(result.count / decoder.channels), timescale: Int32(decoder.sampleRate)))
            result += packet.samples
        }
        return result
    }
    /// User-visible audio outcome: length within 50 ms of the reference (or, for a partial
    /// stream, no longer than it) and audible. Sample identity is not required.
    private func expectAudio(_ actual: [Int16], like expected: [Int16], channels: Int, partial: Bool = false,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        let frames = actual.count / channels, expectedFrames = expected.count / channels
        if partial { #expect(frames > 0 && frames <= expectedFrames + 2400, sourceLocation: sourceLocation) }
        else { #expect(abs(frames - expectedFrames) <= 2400, "\(frames) frames, expected \(expectedFrames)", sourceLocation: sourceLocation) }
        #expect(actual.contains { abs(Int($0)) > 64 }, "decoded audio is silent", sourceLocation: sourceLocation)
    }
    private func wait(_ predicate: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if predicate() { return }
            await Task.yield()
        }
        try #require(predicate())
    }
    private func original(_ name: String) throws -> (samples: Int, bytes: Int64, last: Int64) {
#if SWIFT_PACKAGE
        let url = try #require(Bundle.module.url(forResource: "android-report", withExtension: "json", subdirectory: "Fixtures/NativeFormatReference"))
#else
        let url = try #require(Bundle(for: NativePacketFixtures.self).url(forResource: "android-report", withExtension: "json", subdirectory: "NativeFormatReference"))
#endif
        let report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try #require(report["cases"] as? [[String: Any]])
        let reference = try #require(cases.first { $0["name"] as? String == name && $0["knownLength"] as? Bool == false && $0["truncated"] as? Bool == false })
        let data = try Data(contentsOf: fixture(name))
        #expect(reference["sha256"] as? String == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        let track = try #require((reference["tracks"] as? [[String: Any]])?.first?["output"] as? [String: Any])
        return (try #require(track["samples"] as? Int), try #require(track["bytes"] as? Int64), try #require(track["lastTimeUs"] as? Int64))
    }

    @Test(arguments: names, [17, 4096])
    func independentExtractionMatchesOriginalQueuesAndCompletePCM(name: String, fragment: Int) async throws {
        let data = try Data(contentsOf: fixture(name)), input = Bytes(data, fragment: fragment)
        let policy = try await timeline(data, name: name), expected = try baseline(name), reference = try original(name)
        let producer = NativeAudioPacketProducer(input: input, timeline: policy, format: format(name))
        defer { producer.stop() }
        // No decoder exists: extraction must complete even while presentation is paused.
        try await wait { producer.snapshot().exited }
        try producer.sourceFailure.check()
        let snapshot = producer.snapshot()
        #expect(snapshot.ended && snapshot.unreadPackets > 0)
        // Buffered position and duration agree with Android's within 50 ms.
        #expect(producer.bufferState.snapshot.bufferedThroughMicroseconds.map { abs($0 - reference.last) <= 50_000 } == true)
        #expect(producer.bufferState.snapshot.durationMicroseconds.map { abs($0 - (policy.durationMicroseconds ?? reference.last + 10000)) <= 50_000 } == true)
        let decoder = try await NativeBufferedAudioDecoder.open(producer: producer)
        expectAudio(try await collect(decoder), like: expected, channels: decoder.channels)
        await decoder.cancel()
        #expect(producer.snapshot().cancelled && producer.snapshot().exited)
    }

    @Test func allocationGateRefillsFromPresentedPositionAndNeverFromDecodedProgress() async throws {
        let original = try Data(contentsOf: fixture("tone.wav"))
        var data = Data(original.prefix(44))
        for _ in 0..<8 { data.append(original.dropFirst(44)) }
        func little(_ n: Int) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }) }
        data.replaceSubrange(4..<8, with: little(data.count - 8)); data.replaceSubrange(40..<44, with: little(data.count - 44))
        let input = Bytes(data), policy = try await timeline(data, name: "tone.wav")
        let producer = NativeAudioPacketProducer(input: input, timeline: policy, format: .wav, targetBytes: 2 * 65536)
        defer { producer.stop() }
        try await wait { producer.snapshot().waitingForBudget }
        let before = producer.snapshot()
        #expect(!before.ended && before.unreadPackets > 0 && before.allocatedBytes >= 2 * 65536)
        #expect(before.allocatedBytes <= 2 * 65536 + 1048576 + 65536)
        let decoder = try await NativeBufferedAudioDecoder.open(producer: producer)
        var lastEnd: Int64 = 0
        while producer.snapshot().unreadPackets > 0 {
            let packet = try #require(try await decoder.next())
            lastEnd = packet.presentationTime.value + Int64(packet.frameCount)
        }
        #expect(producer.snapshot().parsedFrames == before.parsedFrames)
        try await decoder.updatePlayback(PCMPlaybackLoadState(positionMicroseconds: lastEnd * 1000000 / Int64(decoder.sampleRate), speed: 1.5))
        try await wait { producer.snapshot().parsedFrames > before.parsedFrames && producer.snapshot().waitingForBudget }
        #expect(producer.snapshot().allocatedBytes <= 2 * 65536 + 1048576 + 65536)
        await decoder.cancel()
        #expect(input.cancelled && producer.snapshot().exited)
    }

    @Test(arguments: names)
    func cancellingDecoderLeaseLeavesHeldSourceAlive(name: String) async throws {
        let data = try Data(contentsOf: fixture(name)), policy = try await timeline(data, name: name)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "application/octet-stream"], body: Data(data.prefix(32768)), keepConnectionOpen: true, includeAutomaticContentLength: false)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        let producer = NativeAudioPacketProducer(input: input, timeline: policy, format: format(name))
        defer { producer.stop() }
        let decoder = try await NativeBufferedAudioDecoder.open(producer: producer, ownsProducer: false)
        let task = Task { try await collect(decoder) }
        defer { task.cancel() }
        try await wait { producer.snapshot().waitingConsumer && input.snapshot().waitingReaders > 0 }
        await decoder.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!producer.snapshot().cancelled && !input.snapshot().cancelled)
        producer.stop(); await producer.waitForExit()
        #expect(input.snapshot().cancelled && input.snapshot().waitingReaders == 0 && producer.snapshot().exited)
    }

    @Test func actualUnknownChunkedFailureDrainsBeforeDeferredRestart() async throws {
        let data = try Data(contentsOf: fixture("tone.aac")), expected = try baseline("tone.aac")
        let prefix = Data(data.prefix(32768))
        let server = try await LoopbackHTTPServer.start { _ in
            // Hold the unknown-length body until the real upstream idle timeout.
            // Foundation can accept a closed unterminated chunked body as EOF.
            .init(headers: ["Content-Type": "audio/aac", "Transfer-Encoding": "chunked"],
                body: Data("\(String(prefix.count, radix: 16))\r\n".utf8) + prefix + Data("\r\n".utf8), keepConnectionOpen: true, includeAutomaticContentLength: false)
        }
        defer { server.stop() }
        let retry = PCMSourceRetry(sleep: { _ in await Task.yield() })
        let relay = try await NativeStreamingRelay.start(url: server.url, playlist: false, proxy: PodcastProxy(),
            onFailure: { retry.recordRelayFailure($0) })
        defer { relay.cancel() }
        let input = try HTTPCodecByteInput(url: relay.url, retry: retry)
        let producer = NativeAudioPacketProducer(input: input, timeline: .init(durationMicroseconds: nil, seekable: false), format: .adts)
        defer { producer.stop() }
        let decoder = try await NativeBufferedAudioDecoder.open(producer: producer)
        // The audio received before the failure is played out, then a restart is deferred.
        let actual = try await collect(decoder)
        expectAudio(actual, like: expected, channels: decoder.channels, partial: true)
        #expect(retry.requiresDeferredRestart && !producer.snapshot().ended)
        #expect(producer.bufferState.snapshot.durationMicroseconds == nil)
        await decoder.cancel()
        #expect(producer.snapshot().exited)
    }

    @Test func committedFiniteFailureDrainsPCMWithoutMaskingOrdinaryTruncation() async throws {
        let data = try Data(contentsOf: fixture("tone.wav")), expected = try baseline("tone.wav")
        let requests = Mutex(0)
        let retry = PCMSourceRetry(sleep: { _ in await Task.yield() }), claim = retry.claimPresentation()
        let server = try await LoopbackHTTPServer.start { _ in
            let first = requests.withLock { $0 += 1; return $0 == 1 }
            if !first { #expect(retry.snapshot.prepared) }
            return first ? .init(headers: ["Content-Type": "audio/wav", "Content-Length": String(data.count)],
                body: Data(data.prefix(32768)), keepConnectionOpen: true)
                : .init(status: 503, body: Data())
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url, retry: retry)
        let producer = NativeAudioPacketProducer(input: input, timeline: .init(durationMicroseconds: 8000000, seekable: true), format: .wav)
        defer { producer.stop() }
        let decoder = try await NativeBufferedAudioDecoder.open(producer: producer)
        // This scenario is a failure after preparation, not a race between
        // first extraction and exhausting immediate503 startup retries.
        try await wait { retry.snapshot.prepared }
        try await server.appendResponseBody(Data(), isFinal: true)
        let task = Task { try await collect(decoder) }
        defer { task.cancel() }
        try await wait { producer.snapshot().waitingConsumer && retry.currentError != nil && input.isWaitingForData }
        #expect(retry.commitErrorForDrain())
        let actual = try await task.value
        expectAudio(actual, like: expected, channels: decoder.channels, partial: true)
        #expect(retry.committedError != nil && !producer.snapshot().ended)
        await decoder.cancel()
        withExtendedLifetime(claim) {}
    }

    @MainActor @Test(arguments: [false, true])
    func pausedPresentationObservesEncodedEOFWithoutPullingMorePCM(proxyEnabled: Bool) async throws {
        let data = try Data(contentsOf: fixture("tone.aac")), prefix = 32768
        let authorization = "Basic " + Data("proxy:saved".utf8).base64EncodedString()
        let server = try await LoopbackHTTPServer.start { request in
            if proxyEnabled && request.headers["proxy-authorization"] != authorization {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"native-loading\""])
            }
            return .init(headers: ["Content-Type": "audio/aac", "Transfer-Encoding": "chunked"],
                body: Self.chunk(Data(data.prefix(prefix))), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!, username: "proxy", password: "saved") : PodcastProxy()
        let relay = try await NativeStreamingRelay.start(url: proxyEnabled ? URL(string: "http://native-loading.invalid/audio.aac")! : server.url,
            playlist: false, proxy: proxy)
        defer { relay.cancel() }
        let input = try HTTPCodecByteInput(url: relay.url)
        let producer = NativeAudioPacketProducer(input: input, timeline: .init(durationMicroseconds: nil, seekable: false), format: .adts)
        defer { producer.stop() }
        let decoder = try await NativeBufferedAudioDecoder.open(producer: producer)
        let transport = Transport()
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: false, speed: 1, maximumOutputFrames: 127)
        let session = try SampleBufferPlaybackSession(stream: stream, transport: transport, maximumQueuedBuffers: 2)
        defer { session.close() }
        try await session.prepare()
        try await wait { producer.snapshot().parsedFrames > 0 && input.isWaitingForData }
        let preroll = session.writtenFrames
        #expect(session.state == .paused && preroll > 0 && !transport.playing)
        #expect(session.sourceDurationMilliseconds == nil && session.sourceSeekable == false)
        let connection = try #require(server.requests.lastIndex { !proxyEnabled || $0.headers["proxy-authorization"] == authorization })
        try await server.appendResponseBody(Self.chunk(Data(data.dropFirst(prefix))) + Data("0\r\n\r\n".utf8), toConnectionAt: connection, isFinal: true)
        try await wait { producer.snapshot().exited }
        // Observable session metadata follows source EOF while its PCM queue stays paused.
        try await waitMain { session.sourceDurationMilliseconds.map { abs($0 - 8009) <= 50 } == true }
        // While paused, no more audio is pushed to the output.
        #expect(session.sourceSeekable == false && session.state == .paused && session.writtenFrames == preroll && !transport.playing)
        #expect(producer.bufferState.snapshot.isFinalBuffered && !producer.bufferState.snapshot.isLoading)
        #expect(server.requests.filter { !proxyEnabled || $0.headers["proxy-authorization"] == authorization }.count == 1)
    }

    @MainActor @Test(arguments: [Float(1), Float(2)])
    func presentationStartupUsesEncodedPlayoutAndFinalShortInput(speed: Float) async throws {
        var data = Data(try Data(contentsOf: fixture("tone.wav")).prefix(44 + 3 * 96000))
        func little(_ n: Int) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }) }
        data.replaceSubrange(4..<8, with: little(data.count - 8)); data.replaceSubrange(40..<44, with: little(data.count - 44))
        let media = data, prefix = 44 + 32768
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/wav", "Transfer-Encoding": "chunked"],
                body: Self.chunk(Data(media.prefix(prefix))), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let input = try HTTPCodecByteInput(url: server.url)
        let producer = NativeAudioPacketProducer(input: input, timeline: .init(durationMicroseconds: 3000000, seekable: true), format: .wav)
        defer { producer.stop() }
        let decoder = try await NativeBufferedAudioDecoder.open(producer: producer)
        let transport = Transport()
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: false, speed: speed, maximumOutputFrames: 127)
        let session = try SampleBufferPlaybackSession(stream: stream, transport: transport, maximumQueuedBuffers: 2)
        defer { session.close() }
        try await session.prepare(); try session.play()
        let preroll = session.writtenFrames
        #expect(session.state == .buffering && !transport.playing && preroll > 0)
        // Two seconds of source time is required at 2x; measure admitted sample
        // timestamps rather than counting requested/decoded PCM frames.
        let next = 44 + Int(speed * 1.3 * 96000)
        try await server.appendResponseBody(Self.chunk(data.subdata(in: prefix..<next)))
        try await waitMain { session.state == .playing }
        #expect(transport.playing)
        try session.pause()
        try await session.setParameters(speed: 4, skipSilence: false)
        try session.play()
        #expect(session.state == .buffering && !transport.playing)
        try await server.appendResponseBody(Self.chunk(Data(data.dropFirst(next))) + Data("0\r\n\r\n".utf8), isFinal: true)
        try await waitMain { session.state == .playing }
        #expect(producer.bufferState.snapshot.isFinalBuffered && transport.playing)
        #expect(session.sourceDurationMilliseconds == 3000 && session.sourceSeekable == true)
    }

    private static func chunk(_ data: Data) -> Data { Data("\(String(data.count, radix: 16))\r\n".utf8) + data + Data("\r\n".utf8) }
    @MainActor private func waitMain(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(predicate())
    }
    @MainActor private final class Transport: PCMPresentationTransport {
        var currentTime = CMTime.zero
        var onTimeChanged: (@MainActor () -> Void)?
        var onFailure: (@MainActor (any Error) -> Void)?
        var playing = false
        func enqueue(_ buffer: CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>) async throws {}
        func setPlaying(_ value: Bool, at time: CMTime) { playing = value; currentTime = time }
        func observeEnd(_ time: CMTime) {}
        func finishEnqueuing() {}
        func stopMonitoring() {}
        func close() { playing = false }
    }

    private final class Bytes: MediaByteInput {
        let bytes: Data, fragment: Int
        private let retired = Mutex(false)
        init(_ bytes: Data, fragment: Int = 4096) { self.bytes = bytes; self.fragment = fragment }
        var length: Int64? { nil }
        var supportsRandomAccess: Bool { true }
        var cancelled: Bool { retired.withLock { $0 } }
        func prepareForSeek() {}
        func checkFailure() throws { if cancelled { throw CancellationError() } }
        func cancel() { retired.withLock { $0 = true } }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            try checkFailure()
            guard offset < bytes.count else { return Data() }
            return bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + min(fragment, maximumCount)))
        }
    }
}
private final class NativePacketFixtures: NSObject {}
