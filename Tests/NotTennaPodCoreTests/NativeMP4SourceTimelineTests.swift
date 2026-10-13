import AVFoundation
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(2))) struct NativeMP4SourceTimelineTests {
    private struct Report: Decodable {
        let complete: Bool
        let cases: [Case]
        struct Case: Decodable {
            let name: String; let knownLength: Bool; let sha256: String; let ended: Bool; let maps: [Map]
        }
        struct Map: Decodable { let durationUs: Int64; let seekable: Bool }
    }
    private func fixture(_ name: String) throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/NativeMP4Timeline"))
#else
        try #require(Bundle(for: MP4TimelineFixtures.self).url(forResource: name, withExtension: nil, subdirectory: "NativeMP4Timeline"))
#endif
    }
    private func report() throws -> Report {
        let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: fixture("android-report.json")))
        try #require(report.complete && report.cases.count == 22)
        return report
    }
    @Test func movieExtendsDeclinesNativePacketTimelineEvenWithExistingSampleTables() async throws {
        var data = try Data(contentsOf: fixture("timeline-original.m4a"))
        let type = try #require(data.range(of: Data("moov".utf8)))
        let start = type.lowerBound - 4
        let oldSize = data[start..<type.lowerBound].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let newSize = oldSize + 8
        data.replaceSubrange(start..<type.lowerBound, with: (0..<4).reversed().map { UInt8(truncatingIfNeeded: newSize >> ($0 * 8)) })
        data.insert(contentsOf: [0, 0, 0, 8] + Array("mvex".utf8), at: start + Int(oldSize))
        // Existing indexed samples remain intact. The fragment declaration is
        // sufficient to forbid treating only that initial table as the episode.
        let timeline = try await NativeAudioSourceTimeline.read(input: Bytes(data, known: true), format: .mp4)
        #expect(!timeline.supportsNativePacketTimeline && timeline.durationMicroseconds == nil)
        let original = try await NativeAudioSourceTimeline.read(input: Bytes(Data(contentsOf: fixture("timeline-original.m4a")), known: true), format: .mp4)
        #expect(original.supportsNativePacketTimeline && original.durationMicroseconds == 8_000_000)
    }
    @Test(arguments: 0..<22, [1, 17, 4096])
    func durationAndSeekabilityMatchAndroidAcrossChunkSizes(index: Int, fragment: Int) async throws {
        let reference = try report().cases[index], data = try Data(contentsOf: fixture(reference.name))
        try #require(reference.ended && SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == reference.sha256)
        let input = Bytes(data, known: reference.knownLength, fragment: fragment)
        let result = try await NativeAudioSourceTimeline.read(input: input, format: .mp4)
        let expected = try #require(reference.maps.first)
        if expected.durationUs == -9223372036854775807 {
            #expect(result.durationMicroseconds == nil)
        } else {
            #expect(abs((result.durationMicroseconds ?? .min / 2) - expected.durationUs) <= 100_000)
        }
        #expect(result.seekable == expected.seekable)
    }

    @Test(arguments: [false, true], [false, true])
    func authenticatedM4AStreamReportsDurationAndPlaysCompleteAudio(known: Bool, proxyEnabled: Bool) async throws {
        try await handoff(known: known, proxyEnabled: proxyEnabled, large: false)
    }
    @Test(arguments: [false, true])
    func largeUnknownLengthM4AWithTrailingIndexPlaysCompleteAudio(proxyEnabled: Bool) async throws {
        try await handoff(known: false, proxyEnabled: proxyEnabled, large: true)
    }
    private func handoff(known: Bool, proxyEnabled: Bool, large: Bool) async throws {
        let original = try Data(contentsOf: fixture("timeline-original.m4a"))
        let padding = 2 << 20, size = UInt32(64471 + padding)
        let header = Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) }) + Data("mdat".utf8)
        let bytes = large ? original.prefix(36) + header + original[44..<64507] + Data(repeating: 0, count: padding) + original.dropFirst(64507) : original
        let credentials = FeedCredentials(username: "timing", password: "fixture")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                guard offset < bytes.count else { return .init(status: 416, headers: ["Content-Range": "bytes */\(bytes.count)"], body: Data()) }
                return .init(status: 206, headers: ["ETag": "\"timing\"", "Content-Range": "bytes \(offset)-\(bytes.count - 1)/*"], body: Data(bytes.dropFirst(offset)))
            }
            return .init(headers: ["Content-Type": "audio/mp4", "ETag": "\"timing\""], body: large ? Data(bytes.prefix(98304)) : bytes,
                keepConnectionOpen: large, includeAutomaticContentLength: known)
        }
        defer { server.stop() }
        let root = URL.temporaryDirectory.appendingPathComponent("mp4-timeline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = proxyEnabled ? URL(string: "http://timing.invalid/media")! : server.url
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: SharedStreamingCache(directory: root))
        defer { remote.input.cancel(); remote.relay.cancel() }
        let timeline = try await NativeAudioSourceTimeline.read(input: remote.makeReadLease(), format: .mp4)
        #expect(timeline.durationMicroseconds == 8_000_000 && timeline.seekable)
        let prepared = try await NativeMP4Input.open(remote: remote)
        // Played as NativeAudioPlaybackSource plays a prepared MP4 input.
        let producer = NativeAudioPacketProducer(input: prepared, timeline: timeline, format: .mp4, indexedStart: .zero)
        defer { producer.stop() }
        let decoder = try await NativeBufferedAudioDecoder.open(producer: producer, ownsProducer: false, start: .zero)
        var actual: [Int16] = []
        while let packet = try await decoder.next() { actual += packet.samples }
        await decoder.cancel()
        producer.stop(); await producer.waitForExit()
        let file = try AVAudioFile(forReading: fixture("timeline-original.m4a"), commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var expected: [Int16] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, file.length - file.framePosition)))
            try #require(buffer.frameLength > 0)
            expected += Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * decoder.channels))
        }
        #expect(AudibleMatch.matches(actual, expected, channels: decoder.channels, sampleRate: decoder.sampleRate))
    }

    @Test func unrecognizedSampleEntryDoesNotContributeTrackDuration() async throws {
        var bytes = try Data(contentsOf: fixture("timeline-original.m4a"))
        let entry = try #require(bytes.range(of: Data("mp4a".utf8)))
        bytes.replaceSubrange(entry, with: Data("zzzz".utf8))
        let result = try await NativeAudioSourceTimeline.read(input: Bytes(bytes, known: false), format: .mp4)
        #expect(result.durationMicroseconds == nil && result.seekable)
    }

    @Test func malformedBoxesAndTablesFailWithoutInventedTimeline() async throws {
        let original = try Data(contentsOf: fixture("timeline-no-edits.m4a"))
        var zeroScale = original, hugeTable = original
        let mvhd = try #require(original.range(of: Data("mvhd".utf8)))
        zeroScale.replaceSubrange((mvhd.lowerBound + 16)..<(mvhd.lowerBound + 20), with: Data(repeating: 0, count: 4))
        let stts = try #require(original.range(of: Data("stts".utf8)))
        hugeTable.replaceSubrange((stts.lowerBound + 8)..<(stts.lowerBound + 12), with: Data(repeating: 255, count: 4))
        for bytes in [zeroScale, hugeTable, Data(original.dropLast()), Data([0,0,0,4])+Data("moov".utf8)] {
            let input = Bytes(bytes, known: true)
            await #expect(throws: NativeMP4SourceTimeline.Failure.self) { try await NativeAudioSourceTimeline.read(input: input, format: .mp4) }
        }
    }

    @Test func blockedReadCancellationAndOriginalErrorRemainObservable() async throws {
        let input = Blocked()
        let task = Task { try await NativeAudioSourceTimeline.read(input: input, format: .mp4) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !input.state.withLock({ $0.entered }), ContinuousClock.now < deadline { await Task.yield() }
        #expect(input.state.withLock { $0.entered })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let failure = Bytes(Data(), known: false, error: URLError(.networkConnectionLost))
        await #expect(throws: URLError(.networkConnectionLost)) { try await NativeAudioSourceTimeline.read(input: failure, format: .mp4) }
    }

    private final class Bytes: MediaByteInput {
        struct State { var cancelled = false; var maximumRead = 0 }
        let state = Mutex(State()), bytes: Data, known: Bool, fragment: Int, error: (any Error)?
        init(_ bytes: Data, known: Bool, fragment: Int = 4096, error: (any Error)? = nil) {
            self.bytes = bytes; self.known = known; self.fragment = fragment; self.error = error
        }
        var length: Int64? { known ? Int64(bytes.count) : nil }
        var supportsRandomAccess: Bool { true }
        func prepareForSeek() {}
        func checkFailure() throws { if let error { throw error } }
        func cancel() { state.withLock { $0.cancelled = true } }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            if let error { throw error }
            return try state.withLock {
                if $0.cancelled { throw CancellationError() }
                $0.maximumRead = max($0.maximumRead, maximumCount)
                guard offset < bytes.count else { return Data() }
                return bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + min(fragment, maximumCount)))
            }
        }
    }
    private final class Blocked: MediaByteInput {
        struct State { var entered = false }
        let state = Mutex(State()), condition = NSCondition()
        nonisolated(unsafe) var cancelled = false
        var length: Int64? { nil }
        var supportsRandomAccess: Bool { false }
        func prepareForSeek() {}
        func checkFailure() throws {}
        func cancel() { condition.lock(); cancelled = true; condition.broadcast(); condition.unlock() }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            condition.lock(); defer { condition.unlock() }
            state.withLock { $0.entered = true }
            while !cancelled { condition.wait() }
            throw CancellationError()
        }
    }
}
private final class MP4TimelineFixtures: NSObject {}
