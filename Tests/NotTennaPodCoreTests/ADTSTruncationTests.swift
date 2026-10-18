import CoreMedia
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.serialized)
struct ADTSTruncationTests {
    private struct Report: Decodable {
        let complete: Bool
        let cases: [Scenario]
        struct Scenario: Decodable {
            let name: String, sha256: String
            let knownLength: Bool
            let requestedTimeUs: Int64, sourceTargetUs: Int64
            let seekPoint: Point
            let maps: [Map]
            let seek: Phase
        }
        struct Point: Decodable { let position: Int64 }
        struct Map: Decodable { let durationUs: Int64; let seekable: Bool }
        struct Phase: Decodable { let ended: Bool; let error: String?; let tracks: [Track] }
        struct Track: Decodable { let id: Int; let output: Output }
        struct Output: Decodable { let samples: Int; let bytes: Int; let payloadSHA256: String? }
    }
    private func resource(_ name: String, folder: String) throws -> Data {
#if SWIFT_PACKAGE
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/\(folder)"))
#else
        let url = try #require(Bundle(for: TruncatedADTSFixtures.self).url(forResource: name, withExtension: nil,
            subdirectory: folder == "StreamingFormats" ? nil : folder))
#endif
        return try Data(contentsOf: url)
    }
    private func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func variant(_ name: String) throws -> Data {
        let original = try resource("tone.aac", folder: "StreamingFormats")
        // Independently framed original fixture:376 frames; final frame begins
        // at66931 and declares164 bytes. Preserve all previous encoded packets.
        try #require(original.count == 67095)
        let kept = try #require(Int(name.split(separator: "-")[1].split(separator: ".")[0]))
        let prefix = name.hasPrefix("tagged") ? Data("ID3".utf8) + Data([4, 0, 0, 0, 0, 0, 64]) + Data(repeating: 0, count: 64) : Data()
        return prefix + original.prefix(66931 + kept)
    }

    @Test(arguments: 0..<64, [17, 4096])
    func completePacketsAndEOFMatchOriginalForPartialHeaderAndPayload(index: Int, fragment: Int) async throws {
        let report = try JSONDecoder().decode(Report.self, from: resource("android-report.json", folder: "ADTSTruncation"))
        try #require(report.complete && report.cases.count == 64)
        let reference = report.cases[index], bytes = try variant(reference.name)
        try #require(hash(bytes) == reference.sha256 && reference.seek.ended && reference.seek.error == nil)
        let expected = try #require(reference.seek.tracks.first { $0.id == 0 }?.output)
        let timeline = try await NativeAudioSourceTimeline.read(input: Input(bytes, known: reference.knownLength, fragment: fragment), format: .adts)
        let map = try #require(reference.maps.first)
        // The displayed duration and seekability match Android (within 50 ms).
        let androidDuration = map.durationUs == -9223372036854775807 ? nil : map.durationUs
        #expect((timeline.durationMicroseconds == nil) == (androidDuration == nil))
        if let duration = timeline.durationMicroseconds, let androidDuration { #expect(abs(duration - androidDuration) <= 50_000) }
        #expect(timeline.seekable == map.seekable)
        let start: NativeAudioPacketProducer.ADTSStart?
        if let index = timeline.adtsByteIndex {
            let point = index.points(at: reference.requestedTimeUs).first
            start = .init(bytePosition: point.bytePosition, time: CMTime(value: reference.sourceTargetUs, timescale: 1_000_000))
        } else { start = nil }
        let input = Input(bytes, known: reference.knownLength, fragment: fragment)
        let producer = NativeAudioPacketProducer(input: input, timeline: timeline, format: .adts, adtsStart: start)
        defer { producer.stop() }
        let lease = producer.makeReadLease(); defer { lease.cancel() }
        let config = try lease.configuration()
        #expect(config.basic.mSampleRate == 48000 && config.basic.mChannelsPerFrame == 1)
        // A download cut inside the last frame still plays every complete
        // frame after the seek and then ends without an error. Two 1024-frame
        // AAC packets (43 ms) of tolerance are imperceptible.
        var packets = 0
        while let batch = try lease.next() { packets += Int(batch.packetCount) }
        #expect(abs(packets - expected.samples) <= 2, "\(reference.name): packets \(packets)/\(expected.samples)")
        lease.cancel(); producer.stop(); await producer.waitForExit()
    }


    /// A transport failure reading the stream's start (for its format) or the
    /// seek point is thrown, never turned into a clean end. A seek learns the
    /// stream's first format from its start before it reads at the seek point,
    /// so when only the seek point fails, configuration() returns that format if
    /// the consumer asks before the failure and the first read throws. Both
    /// orders are checked: the failure recorded first, or held until the
    /// consumer has the format.
    @Test(arguments: [false, true], [false, true])
    func failedSeekOrFormatReadIsNotConvertedToSuccessfulEOF(prefixRead: Bool, consumerFirst: Bool) async throws {
        let bytes = try variant("plain-163.aac")
        let timeline = try await NativeAudioSourceTimeline.read(input: Input(bytes, known: true, fragment: 4096), format: .adts)
        let point = try #require(timeline.adtsByteIndex).points(at: 20_000_000).first
        // The format depends on the start's read, so only the seek point's failure can be held.
        let holdsFailure = consumerFirst && !prefixRead
        let input = Input(bytes, known: true, fragment: 4096,
            failingRange: prefixRead ? 0..<point.bytePosition : point.bytePosition..<Int64.max, holdsFailure: holdsFailure)
        let producer = NativeAudioPacketProducer(input: input, timeline: timeline, format: .adts,
            adtsStart: .init(bytePosition: point.bytePosition, time: CMTime(value: 20, timescale: 1)))
        defer { producer.stop() }
        let lease = producer.makeReadLease(); defer { lease.cancel() }
        if !consumerFirst { await producer.waitForExit() }
        var configured = false, packets = 0
        do {
            let config = try lease.configuration()
            configured = true
            #expect(config.basic.mSampleRate == 48000 && config.basic.mChannelsPerFrame == 1)
            input.releaseFailure()
            while let batch = try lease.next() { packets += Int(batch.packetCount) }
            Issue.record("the stream ended cleanly after \(packets) packets instead of throwing the transport failure")
        } catch Input.Failure.transport {
            // configuration() throws a recorded failure or one at the start; with the
            // seek point's failure held, the format comes from the start and the read throws.
            #expect(configured == holdsFailure)
            // Every read at and after the seek point failed: nothing was invented.
            #expect(packets == 0)
        }
        lease.cancel(); producer.stop(); await producer.waitForExit()
    }

    @Test(arguments: 0..<8)
    func capturedSourceEndsEmptyAtTruncatedTailAndReplaysOffline(configuration: Int) async throws {
        let proxyEnabled = configuration & 1 != 0, tagged = configuration & 2 != 0, kept = configuration & 4 != 0 ? 163 : 7
        let name = (tagged ? "tagged" : "plain") + "-\(kept).aac", bytes = try variant(name)
        let report = try JSONDecoder().decode(Report.self, from: resource("android-report.json", folder: "ADTSTruncation"))
        let reference = try #require(report.cases.first { $0.name == name && $0.knownLength && $0.requestedTimeUs == 20_000_000 })
        let duration = try #require(reference.maps.first?.durationUs)
        let target = CMTime(value: duration, timescale: 1_000_000)
        let credentials = FeedCredentials(username: "tail", password: "saved")
        let proxyAuthorization = "Basic " + Data("proxy:saved".utf8).base64EncodedString()
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            if proxyEnabled && request.headers["proxy-authorization"] != proxyAuthorization {
                return .init(status: 407, headers: ["Proxy-Authenticate": "Basic realm=\"tail\""])
            }
            return .init(headers: ["Content-Type": "audio/aac"], body: bytes)
        }
        defer { server.stop() }
        let root = URL.temporaryDirectory.appendingPathComponent("truncated-adts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try SharedStreamingCache(directory: root)
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!, username: "proxy", password: "saved") : PodcastProxy()
        let url = proxyEnabled ? URL(string: "http://tail.invalid/episode.mp3")! : server.url
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        defer { remote.input.cancel(); remote.relay.cancel() }
        let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache)
        let decoder = try await source.makeDecoder(start: target)
        #expect(decoder.startTime == target && decoder.sampleRate == 48000 && decoder.channels == 1)
        #expect(decoder.sourceDurationMilliseconds == duration / 1000 && decoder.sourceSeekable == true)
        #expect(try await decoder.next() == nil)
        await decoder.cancel()
        // Offline replay at the end with speed and skip-silence also ends.
        server.stop()
        let replay = try await source.makeDecoder(start: target)
        let stream = try LocalPCMPlaybackStream(decoder: replay, skipSilence: true, speed: 1.5)
        #expect(try await stream.nextPacket() == nil)
        let decoded = await stream.decodedFrames, delivered = await stream.deliveredFrames
        #expect(decoded == 0 && delivered == 0)
        #expect(await stream.segment.mediaStartTime == target)
        await stream.cancel()
    }

    private final class Input: MediaByteInput, Sendable {
        enum Failure: Error, Equatable { case transport }
        let bytes: Data, known: Bool, fragment: Int
        let failingRange: Range<Int64>?
        /// A failing read waits for releaseFailure() (or cancel()), at most ten
        /// seconds so a regression fails instead of hanging the producer.
        let holdsFailure: Bool
        private let release = DispatchSemaphore(value: 0)
        private let state = Mutex((cancelled: false, maximum: 0))
        init(_ bytes: Data, known: Bool, fragment: Int, failingRange: Range<Int64>? = nil, holdsFailure: Bool = false) {
            self.bytes = bytes; self.known = known; self.fragment = fragment; self.failingRange = failingRange
            self.holdsFailure = holdsFailure
        }
        func releaseFailure() { release.signal() }
        var length: Int64? { known ? Int64(bytes.count) : nil }
        var supportsRandomAccess: Bool { true }
        var maximumRead: Int { state.withLock { $0.maximum } }
        func prepareForSeek() {}
        func cancel() { state.withLock { $0.cancelled = true }; release.signal() }
        func checkFailure() throws { if state.withLock({ $0.cancelled }) { throw CancellationError() } }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            try checkFailure()
            if failingRange?.contains(offset) == true {
                if holdsFailure { _ = release.wait(timeout: .now() + 10) }
                throw Failure.transport
            }
            state.withLock { $0.maximum = max($0.maximum, maximumCount) }
            guard offset < bytes.count else { return Data() }
            return bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + min(fragment, maximumCount)))
        }
    }
}
private final class TruncatedADTSFixtures: NSObject {}
