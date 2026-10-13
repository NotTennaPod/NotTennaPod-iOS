import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(2))) struct NativeMP3LongSourceTests {
    private func fixture() throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: "half-hour.mp3", withExtension: nil, subdirectory: "Fixtures/LongMP3"))
#else
        try #require(Bundle(for: LongMP3Fixtures.self).url(forResource: "half-hour.mp3", withExtension: nil, subdirectory: "LongMP3"))
#endif
    }
    private func media(xing: Bool) throws -> Data {
        var data = try Data(contentsOf: fixture())
        if xing { data.replaceSubrange(21..<25, with: Data("Xing".utf8)) }
        return data
    }
    private func referenceTail() throws -> [Int16] {
        let file = try AVAudioFile(forReading: fixture(), commonFormat: .pcmFormatInt16, interleaved: true)
        // This file reader exposes all encoded frames. Independently parsed
        // encoder fields declare576 leading/1440 trailing frames, yielding the
        // generated1800s. Compare the complete valid suffix, not encoder padding.
        #expect(file.length == 79382016)
        file.framePosition = 1790 * 44100
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var result = [Int16]()
        while file.framePosition < file.length {
            try file.read(into: buffer)
            try #require(buffer.frameLength > 0)
            result += UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength))
        }
        return Array(result.dropLast(1440))
    }
    /// What a listener gets after a seek: the shown position is within 0.25 s of the
    /// target, the audio is the episode's uninterrupted tail through its end, and it
    /// starts where Android starts it. The file reader's frames still include the 576
    /// leading encoder-delay frames, so the tail is aligned from the end of the valid
    /// 1800 s, and the heard start is the heard length back from there.
    /// A seek inside the audio loaded by an earlier seek (`loadedBy`) keeps that seek's
    /// timestamps on Android too (ProgressiveMediaPeriod.seekInsideBufferUs, then
    /// SampleQueue.seekTo), so it lands that far after the earlier landing.
    private func expectHeardTail(_ actual: [Int16], _ decoder: NativeMP3SourceDecoder, target: Int64, xing: Bool,
                                 _ tail: [Int16], loadedBy earlier: Int64? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(abs(CMTimeGetSeconds(decoder.startTime) - Double(target)) <= 0.25, sourceLocation: sourceLocation)
        #expect(!actual.isEmpty && AudibleMatch.matches(actual, Array(tail.suffix(actual.count)), channels: 1, sampleRate: 44100),
                "target \(target): heard audio is not the episode's tail", sourceLocation: sourceLocation)
        let heardStart = 1800 - Double(actual.count) / 44100
        let landed = earlier ?? target
        let expectedStart = try xing ? androidXingLanding(media(xing: true), target: Double(landed)) + Double(target - landed) : Double(target)
        #expect(abs(heardStart - expectedStart) <= 0.25,
                "target \(target): audio heard from \(heardStart) s, expected \(expectedStart) s", sourceLocation: sourceLocation)
    }
    /// Android 3.12.1 (Media3 1.10 XingSeeker.getSeekPoints, then Mp3Extractor's frame
    /// sync) seeks a Xing file by its coarse 1%-step table of contents. Near the end of
    /// this half-hour file that lands about 0.35 s before the target, while the shown
    /// position comes from the same table and reads as the target. Match Android.
    private func androidXingLanding(_ media: Data, target: Double) throws -> Double {
        let index = try PCIndexedMP3TailOracle(media)
        try #require(index.marker == "Xing" && index.table.count == 100 && index.duration > 0)
        let percent = target * 100_000_000 / Double(index.duration)
        let slot = min(99, Int(percent))
        let lower = Double(index.table[slot]), upper = slot == 99 ? 256 : Double(index.table[slot + 1])
        let scaled = lower + (percent - Double(slot)) * (upper - lower)
        let offset = index.headerOffset + Int((scaled / 256 * Double(index.declaredSize)).rounded())
        let packet = try #require(index.packets.firstIndex { $0.offset >= offset })
        return Double(Int64(packet) * index.framesPerPacket - index.leading) / Double(index.rate)
    }
    private func drain(_ decoder: NativeMP3SourceDecoder) async throws -> [Int16] {
        var samples = [Int16]()
        while let packet = try await decoder.next() {
            #expect(packet.presentationTime == decoder.startTime + CMTime(value: Int64(samples.count), timescale: 44100))
            samples += packet.samples
        }
        return samples
    }

    @Test(arguments: [false, true], [false, true])
    func resumingLatePositionInLongStreamDoesNotDownloadWholeEpisode(proxyEnabled: Bool, xing: Bool) async throws {
        let media = try media(xing: xing)
        let credentials = FeedCredentials(username: "long-mp3", password: "saved")
        let auth = "Basic " + Data("proxy:saved".utf8).base64EncodedString()
        let server = try await LoopbackHTTPServer.start { request in
            if proxyEnabled && request.headers["proxy-authorization"] != auth {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"long-mp3\""])
            }
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            if let start = request.headers["range"].flatMap({ Int($0.dropFirst(6).dropLast()) }) {
                return .init(status: 206, headers: ["Content-Type": "audio/mpeg", "ETag": "\"long-mp3\"",
                    "Content-Range": "bytes \(start)-\(media.count - 1)/\(media.count)"], body: Data(media.dropFirst(start)))
            }
            // A saved late position must not need the intervening 30-minute body.
            return .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(media.count)", "ETag": "\"long-mp3\""],
                body: Data(media.prefix(8192)), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!, username: "proxy", password: "saved") : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://long-mp3.invalid/episode.mp3")! : server.url
        let source = NativeMP3PlaybackSource(url: url, proxy: proxy, credentials: credentials)
        let opening = Task { try await source.makeDecoder(start: CMTime(value: 1798, timescale: 1), prepareSourceTimeline: true) }
        defer { opening.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !server.requests.contains(where: { $0.headers["range"] != nil }), ContinuousClock.now < deadline { await Task.yield() }
        if !server.requests.contains(where: { $0.headers["range"] != nil }) {
            opening.cancel(); _ = await opening.result
            Issue.record("Cold late seek waited for unavailable earlier audio instead of requesting the declared index position")
            return
        }
        let decoder = try await opening.value
        let actual = try await drain(decoder)
        try expectHeardTail(actual, decoder, target: 1798, xing: xing, try referenceTail())
        // Only a small part of the half-hour file was downloaded.
        let snapshot = try #require(await source.networkSnapshot)
        #expect(snapshot.received < Int64(media.count / 10))
        await decoder.cancel()
    }

    @Test(arguments: [false, true])
    func secondSeekWhileFirstIsStillLoadingPlaysSecondTarget(proxyEnabled: Bool) async throws {
        let data = try media(xing: false), ranges = Mutex(0)
        let server = try await LoopbackHTTPServer.start { request in
            if let start = request.headers["range"].flatMap({ Int($0.dropFirst(6).dropLast()) }) {
                let first = ranges.withLock { $0 += 1; return $0 == 1 }
                return .init(status: 206, headers: ["Content-Type": "audio/mpeg", "ETag": "\"replacement\"",
                    "Content-Length": "\(data.count - start)", "Content-Range": "bytes \(start)-\(data.count - 1)/\(data.count)"],
                    body: first ? Data() : Data(data.dropFirst(start)), keepConnectionOpen: first)
            }
            return .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": "\(data.count)", "ETag": "\"replacement\""],
                body: Data(data.prefix(8192)), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://replacement.invalid/episode.mp3")! : server.url
        let source = NativeMP3PlaybackSource(url: url, proxy: proxy)
        let old = Task { try await source.makeDecoder(start: CMTime(value: 1798, timescale: 1), prepareSourceTimeline: true) }
        defer { old.cancel() }
        try await wait { ranges.withLock { $0 } == 1 }
        let latest = Task { try await source.makeDecoder(start: CMTime(value: 1797, timescale: 1), prepareSourceTimeline: true) }
        defer { latest.cancel() }
        let decoder = try await latest.value
        let actual = try await drain(decoder)
        try expectHeardTail(actual, decoder, target: 1797, xing: false, try referenceTail())
        await decoder.cancel()
    }

    @Test(arguments: [false, true])
    func downloadedLongEpisodeSeeksNearEndPlayCorrectAudio(xing: Bool) async throws {
        let url = URL.temporaryDirectory.appendingPathComponent("long-mp3-\(UUID()).media")
        try media(xing: xing).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try #require(try await LocalAudioBytes.openIdentified(url: url))
        let source = NativeMP3PlaybackSource(localURL: url, file: file.file)
        try FileManager.default.removeItem(at: url)
        let expected = try referenceTail()
        // 1799 is inside the audio the 1798 seek loaded; 1797 is before it.
        for (target, loadedBy) in [(1798, nil), (1799, 1798), (1797, nil)] as [(Int64, Int64?)] {
            let decoder = try await source.makeDecoder(start: CMTime(value: target, timescale: 1), prepareSourceTimeline: true)
            let actual = try await drain(decoder)
            try expectHeardTail(actual, decoder, target: target, xing: xing, expected, loadedBy: loadedBy)
            await decoder.cancel()
        }
        #expect(await source.networkSnapshot == nil)
    }

    @Test(arguments: [false, true])
    func longEpisodeLoadingStaysWithinMemoryBudget(cold: Bool) async throws {
        let input = Bytes(try media(xing: false), chunk: 4096)
        let producer = NativeMP3PacketProducer(input: input, prepareSourceTimeline: true,
            initialSeekMicroseconds: cold ? 180000000 : 0)
        defer { producer.stop() }
        try await wait { producer.snapshot().waitingForBudget || producer.snapshot().exited }
        try producer.sourceFailure.check()
        let before = producer.snapshot(), budget = PlaybackLoadControl.audioTargetBytes
        try #require(before.waitingForBudget && !before.ended)
        #expect(before.allocatedBytes >= budget && before.allocatedBytes <= budget + 1048576 + 65536)
        let lease = producer.makeReadLease()
        // All queued packets are available; these synchronous pulls cannot wait.
        while producer.snapshot().unreadPackets > 0 { _ = try #require(try lease.next()) }
        lease.cancel()
        try producer.updatePlayback(.init(positionMicroseconds: 1200000000, speed: 1.5))
        try await wait { producer.snapshot().parsedFrames > before.parsedFrames && (producer.snapshot().exited || producer.snapshot().waitingForBudget) }
        try producer.sourceFailure.check()
        let after = producer.snapshot()
        #expect(after.parsedFrames > before.parsedFrames)
        #expect(after.allocatedBytes <= budget + 1048576 + 65536)
        // Loaded through the end; a seek near the end can use loaded audio.
        #expect(after.ended && producer.seek(to: 1798000000))
        producer.stop(); await producer.waitForExit()
    }

    private func wait(_ predicate: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(predicate())
    }
    private final class Bytes: MediaByteInput {
        struct State { var stopped = false; var bytes: Int64 = 0; var maximum = 0; var ranges: [Int64] = [] }
        let data: Data, chunk: Int
        private let state = Mutex(State())
        init(_ data: Data, chunk: Int) { self.data = data; self.chunk = chunk }
        var snapshot: State { state.withLock { $0 } }
        var length: Int64? { Int64(data.count) }
        var supportsRandomAccess: Bool { true }
        func cancel() { state.withLock { $0.stopped = true } }
        func checkFailure() throws { if state.withLock({ $0.stopped }) { throw CancellationError() } }
        func prepareForSeek() {}
        func prepareForIndexedSeek(to offset: Int64) { state.withLock { $0.ranges.append(offset) } }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            try checkFailure()
            let count = max(0, min(chunk, maximumCount, data.count - Int(offset)))
            state.withLock { $0.bytes += Int64(count); $0.maximum = max($0.maximum, maximumCount) }
            return data.subdata(in: Int(offset)..<(Int(offset) + count))
        }
    }

}
private final class LongMP3Fixtures: NSObject {}
