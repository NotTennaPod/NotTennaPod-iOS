import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct NativeFLACLoadingTests {
    private func fixture() throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: "half-hour.flac", withExtension: nil, subdirectory: "Fixtures/NativeBuffering"))
#else
        try #require(Bundle(for: FLACLoadingFixtures.self).url(forResource: "half-hour.flac", withExtension: nil, subdirectory: "NativeBuffering"))
#endif
    }
    private func wait(_ predicate: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if predicate() { return }
            await Task.yield()
        }
        try #require(predicate())
    }
    private func expected(at frame: Int64, count: Int = 4096) throws -> [Int16] {
        let file = try AVAudioFile(forReading: fixture(), commonFormat: .pcmFormatInt16, interleaved: true)
        file.framePosition = frame
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(count)))
        try file.read(into: buffer, frameCount: UInt32(count))
        try #require(buffer.frameLength == count)
        return Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: count))
    }
    private func window(_ decoder: any PCMDecoding, at frame: Int64) async throws -> [Int16] {
        var actual = [Int16]()
        while actual.count < 4096 {
            let value = try await decoder.next(), packet = try #require(value)
            #expect(packet.presentationTime == CMTime(value: frame + Int64(actual.count), timescale: 48000))
            actual += packet.samples
        }
        return Array(actual.prefix(4096))
    }

    @Test(arguments: [false, true])
    func longEpisodeLoadingStaysWithinMemoryBudgetAndSeeksPlayCorrectly(coldSeek: Bool) async throws {
        let data = try Data(contentsOf: fixture(), options: .mappedIfSafe)
        let timeline = try await NativeAudioSourceTimeline.read(input: Bytes(data), format: .flac)
        #expect(timeline.durationMicroseconds == 1800000000)
        let input = Bytes(data), start = CMTime(value: coldSeek ? 180 : 0, timescale: 1)
        let producer = NativeAudioPacketProducer(input: input, timeline: timeline, format: .flac, flacStart: coldSeek ? start : nil)
        defer { producer.stop() }
        // No decoder or playback progress exists while the default budget fills.
        try await wait { producer.snapshot().waitingForBudget || producer.snapshot().exited }
        try producer.sourceFailure.check()
        let before = producer.snapshot(), budget = PlaybackLoadControl.audioTargetBytes
        try #require(before.waitingForBudget && !before.ended)
        #expect(before.allocatedBytes >= budget && before.allocatedBytes <= budget + 1048576 + 65536)
        #expect(before.unreadPackets == before.retainedPackets && before.unreadPackets > 1000)
        // Consume what was loaded (playback), then advance the playback position:
        // loading continues for the new position without exceeding the budget.
        let lease = producer.makeReadLease()
        _ = try lease.configuration()
        while producer.snapshot().unreadPackets > 0 { _ = try #require(try lease.next()) }
        lease.cancel()
        try producer.updatePlayback(.init(positionMicroseconds: 900000000, speed: 1.5))
        try await wait { producer.snapshot().parsedFrames > before.parsedFrames && (producer.snapshot().waitingForBudget || producer.snapshot().exited) }
        try producer.sourceFailure.check()
        let after = producer.snapshot()
        #expect(!after.ended && after.waitingForBudget)
        #expect(after.allocatedBytes <= budget + 1048576 + 65536)
        let targetFrame: Int64 = 38400017, target = CMTime(value: targetFrame, timescale: 48000)
        try #require(producer.seek(to: 800000354))
        let decoder = try await NativeBufferedAudioDecoder.open(producer: producer, ownsProducer: false, start: target)
        #expect(try await window(decoder, at: targetFrame) == expected(at: targetFrame))
        await decoder.cancel()
        try #require(producer.seek(to: 1500000000))
        let later = try await NativeBufferedAudioDecoder.open(producer: producer, ownsProducer: false,
            start: CMTime(value: 1500, timescale: 1))
        try await later.updatePlayback(.init(positionMicroseconds: 1500000000, speed: 2))
        try await wait { producer.snapshot().exited }
        try producer.sourceFailure.check()
        #expect(producer.snapshot().ended && producer.bufferState.snapshot.isFinalBuffered)
        #expect(producer.bufferState.snapshot.durationMicroseconds == 1800000000)
        await later.cancel()
        try #require(producer.seek(to: 1798000354))
        let finalFrame: Int64 = 86304017
        let tail = try await NativeBufferedAudioDecoder.open(producer: producer, ownsProducer: false,
            start: CMTime(value: finalFrame, timescale: 48000))
        var tailAudio = [Int16]()
        while let packet = try await tail.next() {
            #expect(packet.presentationTime == CMTime(value: finalFrame + Int64(tailAudio.count), timescale: 48000))
            tailAudio += packet.samples
        }
        // The last two seconds of the episode play completely and correctly.
        let tailExpected = try expected(at: finalFrame, count: 95983)
        #expect(tailAudio.count == 95983 && tailAudio == tailExpected)
        await tail.cancel()
        producer.stop(); await producer.waitForExit()
    }

    @Test(arguments: [false, true])
    func longStreamedEpisodeRecoversFromDroppedConnectionAndSeeksCorrectly(proxyEnabled: Bool) async throws {
        let data = try Data(contentsOf: fixture(), options: .mappedIfSafe), cutoff = 15000000
        let credentials = FeedCredentials(username: "long-flac", password: "saved")
        let proxyAuthorization = "Basic " + Data("proxy:saved".utf8).base64EncodedString()
        let admitted = Mutex(0)
        let server = try await LoopbackHTTPServer.start { request in
            if proxyEnabled && request.headers["proxy-authorization"] != proxyAuthorization {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"long-flac\""])
            }
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            let attempt = admitted.withLock { $0 += 1; return $0 }
            if attempt == 1 {
                #expect(request.headers["range"] == nil)
                return .init(headers: ["Content-Type": "audio/flac", "Content-Length": String(data.count), "ETag": "\"long-flac\""],
                    body: Data(data.prefix(cutoff)), keepConnectionOpen: true)
            }
            let offset = Int(request.headers["range"]?.dropFirst(6).dropLast() ?? "") ?? -1
            guard offset >= 0 && offset < data.count else { return .init(status: 416) }
            return .init(status: 206, headers: ["Content-Type": "audio/flac", "ETag": "\"long-flac\"",
                "Content-Range": "bytes \(offset)-\(data.count - 1)/\(data.count)"], body: Data(data.dropFirst(offset)))
        }
        defer { server.stop() }
        let directory = URL.temporaryDirectory.appendingPathComponent("long-flac-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!, username: "proxy", password: "saved") : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://long-flac.invalid/audio")! : server.url
        let retry = PCMSourceRetry(sleep: { _ in await Task.yield() })
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache, retry: retry)
        defer { remote.input.cancel(); remote.relay.cancel() }
        var source: NativeAudioPlaybackSource? = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache)
        let initialValue = try await source?.makeDecoder(), initial = try #require(initialValue)
        let state = try #require(initial.bufferState), budget = PlaybackLoadControl.audioTargetBytes
        try await wait { !state.snapshot.isLoading && state.snapshot.allocatedBytes >= budget }
        let before = state.snapshot
        #expect(!before.isFinalBuffered && before.isUsable)
        #expect(before.allocatedBytes <= budget + 1048576 + 65536)
        let connection = try #require(server.requests.lastIndex { !proxyEnabled || $0.headers["proxy-authorization"] == proxyAuthorization })
        try await server.appendResponseBody(Data(), toConnectionAt: connection, isFinal: true)
        let targetFrame: Int64 = 43200017
        let nextValue = try await source?.makeDecoder(start: CMTime(value: targetFrame, timescale: 48000), admission: .exactFrame)
        let next = try #require(nextValue)
        try await next.updatePlayback(.init(positionMicroseconds: 900000354, speed: 1.5))
        #expect(try await window(next, at: targetFrame) == expected(at: targetFrame))
        try await wait {
            let value = state.snapshot
            return !value.isLoading && (value.bufferedThroughMicroseconds ?? 0) > (before.bufferedThroughMicroseconds ?? 0) && admitted.withLock { $0 } >= 2
        }
        let after = state.snapshot
        #expect(after.isUsable && !after.isFinalBuffered)
        #expect(after.allocatedBytes <= budget + 1048576 + 65536)
        await next.cancel()
        server.stop()
        // Seeking back into loaded audio plays offline.
        let replayValue = try await source?.makeDecoder(start: CMTime(value: 38400017, timescale: 48000), admission: .exactFrame)
        let replay = try #require(replayValue)
        #expect(try await window(replay, at: 38400017) == expected(at: 38400017))
        await replay.cancel(); source = nil
        _ = initial
    }

    private final class Bytes: MediaByteInput, @unchecked Sendable {
        struct State { var stopped = false, bytes: Int64 = 0, maximum = 0 }
        private let state = Mutex(State())
        let data: Data
        init(_ data: Data) { self.data = data }
        var length: Int64? { Int64(data.count) }
        var supportsRandomAccess: Bool { true }
        var cancelled: Bool { state.withLock { $0.stopped } }
        var snapshot: State { state.withLock { $0 } }
        func prepareForSeek() {}
        func cancel() { state.withLock { $0.stopped = true } }
        func checkFailure() throws { if cancelled { throw CancellationError() } }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            try checkFailure()
            guard offset < data.count else { return Data() }
            let end = min(data.count, Int(offset) + maximumCount)
            state.withLock { $0.bytes += Int64(end) - offset; $0.maximum = max($0.maximum, maximumCount) }
            return data.subdata(in: Int(offset)..<end)
        }
    }
}
private final class FLACLoadingFixtures: NSObject {}
