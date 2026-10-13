import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(2))) struct NativeMP4InputTests {
    static let variants = ["fast", "tail", "large-mdat", "extended-free"]
    private func fixture(_ name: String) throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
#else
        try #require(Bundle(for: MP4ExtentFixtures.self).url(forResource: name, withExtension: nil))
#endif
    }
    private func bytes(_ variant: String) throws -> Data {
        let original = try Data(contentsOf: fixture(variant == "fast" ? "tone.m4a" : "tone-tail.m4a"))
        let padding = 2 << 20
        if variant == "large-mdat" {
            // Unreferenced mdat padding moves moov, never the indexed AAC bytes.
            let result = original.prefix(36) + big(UInt64(64471 + padding), 4) + Data("mdat".utf8)
                + original[44..<64507] + Data(repeating: 0, count: padding) + original.dropFirst(64507)
            try verifyDerivative(result, name: "tone-large-tail.m4a")
            return result
        }
        if variant == "extended-free" {
            let result = original.prefix(64507) + big(1, 4) + Data("free".utf8) + big(UInt64(padding + 16), 8)
                + Data(repeating: 0, count: padding) + original.dropFirst(64507)
            try verifyDerivative(result, name: "tone-extended-tail.m4a")
            return result
        }
        return original
    }
    private func verifyDerivative(_ bytes: Data, name: String) throws {
#if SWIFT_PACKAGE
        let url = try #require(Bundle.module.url(forResource: "mp4-extents", withExtension: "json", subdirectory: "Fixtures/NativeFormatReference"))
#else
        let url = try #require(Bundle(for: MP4ExtentFixtures.self).url(forResource: "mp4-extents", withExtension: "json", subdirectory: "NativeFormatReference"))
#endif
        let report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        try #require(report["complete"] as? Bool == true)
        let cases = try #require(report["cases"] as? [[String: Any]])
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let matching = cases.filter { $0["name"] as? String == name }
        try #require(matching.count == 2)
        for reference in matching {
            try #require(reference["sha256"] as? String == hash && reference["ended"] as? Bool == true)
            let map = try #require((reference["maps"] as? [[String: Any]])?.first)
            try #require(map["durationUs"] as? Int64 == 8_000_000 && map["seekable"] as? Bool == true)
        }
    }
    private func baseline(_ variant: String) throws -> [Int16] {
        let file = try AVAudioFile(forReading: fixture(variant == "fast" ? "tone.m4a" : "tone-tail.m4a"), commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var result: [Int16] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, file.length - file.framePosition)))
            try #require(buffer.frameLength > 0)
            result += Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * Int(file.processingFormat.channelCount)))
        }
        return result
    }
    /// Plays a prepared MP4 input the way NativeAudioPlaybackSource does for an unknown-length
    /// MP4 (indexed packet producer + buffered decoder) and checks it sounds like the file.
    private func expectPlaysCompletely(_ input: NativeMP4Input, timeline: NativeAudioSourceTimeline, variant: String) async throws {
        let producer = NativeAudioPacketProducer(input: input, timeline: timeline, format: .mp4, indexedStart: .zero)
        defer { producer.stop() }
        let decoder = try await NativeBufferedAudioDecoder.open(producer: producer, ownsProducer: false, start: .zero)
        var actual: [Int16] = []
        while let packet = try await decoder.next() {
            #expect(packet.presentationTime == CMTime(value: Int64(actual.count / decoder.channels), timescale: Int32(decoder.sampleRate)))
            actual += packet.samples
        }
        let expected = try baseline(variant)
        #expect(AudibleMatch.matches(actual, expected, channels: decoder.channels, sampleRate: decoder.sampleRate))
        await decoder.cancel()
        producer.stop(); await producer.waitForExit()
    }

    @Test(arguments: variants, [1, 4096])
    func unknownLengthM4AWithTrailingIndexPlaysCompleteAudio(variant: String, fragment: Int) async throws {
        let data = try bytes(variant)
        let source = Memory(data, fragment: fragment)
        let input = try await NativeMP4Input.open(input: source)
        #expect(input.length == Int64(data.count))
        let timeline = try await NativeAudioSourceTimeline.read(input: NativeMP4Input.open(input: Memory(data, fragment: fragment)), format: .mp4)
        try await expectPlaysCompletely(input, timeline: timeline, variant: variant)
    }

    @Test(arguments: variants, [false, true])
    func unknownLengthAuthenticatedHTTPM4APlaysCompleteAudio(variant: String, proxyEnabled: Bool) async throws {
        try await http(variant: variant, proxyEnabled: proxyEnabled, reportsTotal: true)
    }

    @Test(arguments: ["large-mdat", "extended-free"], [false, true])
    func unknownTotalRangeResponsesStillPlayCompleteAudio(variant: String, proxyEnabled: Bool) async throws {
        try await http(variant: variant, proxyEnabled: proxyEnabled, reportsTotal: false)
    }

    private func http(variant: String, proxyEnabled: Bool, reportsTotal: Bool) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("mp4-extents-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try bytes(variant), large = data.count > 1 << 20
        let credentials = FeedCredentials(username: "mp4", password: "captured")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            if let range = request.headers["range"], let offset = Int(range.dropFirst(6).dropLast()) {
                guard offset < data.count else { return .init(status: 416, headers: ["Content-Range": "bytes */\(data.count)"], body: Data()) }
                return .init(status: 206, headers: ["ETag": "\"mp4-stable\"", "Content-Range": "bytes \(offset)-\(data.count - 1)/\(reportsTotal ? String(data.count) : "*")"], body: Data(data.dropFirst(offset)))
            }
            // Large fixtures never finish the initial response. Preparation
            // must jump over the unused bytes to a real range response.
            return .init(headers: ["Content-Type": "text/html", "ETag": "\"mp4-stable\""],
                body: large ? Data(data.prefix(98304)) : data, keepConnectionOpen: large,
                includeAutomaticContentLength: false)
        }
        defer { server.stop() }
        let url = proxyEnabled ? URL(string: "http://mp4.invalid/wrong.mp3")! : server.url.appendingPathComponent("wrong.mp3")
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let cache = try SharedStreamingCache(directory: root)
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        defer { remote.input.cancel(); remote.relay.cancel() }
        let timeline = try await NativeAudioSourceTimeline.read(input: remote.makeReadLease(), format: .mp4)
        let input = try await NativeMP4Input.open(remote: remote)
        #expect(input.length == Int64(data.count))
        try await expectPlaysCompletely(input, timeline: timeline, variant: variant)
    }

    @Test func corruptHugeBoxFailsInsteadOfInventingLength() async throws {
        let data = big(1, 4) + Data("mdat".utf8) + big(1 << 40, 8) + Data(repeating: 0, count: 1024)
        let source = Memory(data)
        await #expect(throws: NativeMP4Input.Failure.incompleteBox) { try await NativeMP4Input.open(input: source) }
    }

    @Test func malformedHeadersAndUnknownSizeHaveExplicitErrors() async throws {
        let cases: [(Data, NativeMP4Input.Failure)] = [
            (Data(), .incompleteBox), (Data([0, 0, 0, 8]), .incompleteBox),
            (big(4, 4) + Data("mdat".utf8), .invalidBox),
            (big(1, 4) + Data("mdat".utf8) + big(UInt64.max, 8), .invalidBox),
            (big(1, 4) + Data("mdat".utf8) + big(8, 8), .invalidBox),
            (big(0, 4) + Data("mdat".utf8), .unknownSizedBox),
            (big(12, 4) + Data("free".utf8) + Data([0]), .incompleteBox)
        ]
        for (data, error) in cases {
            let source = Memory(data)
            await #expect(throws: error) { try await NativeMP4Input.open(input: source) }
        }
    }

    @Test func failureAndCancellationKeepOriginalInputOutcome() async throws {
        let failed = Memory(Data(), fails: true)
        await #expect(throws: URLError(.networkConnectionLost)) { try await NativeMP4Input.open(input: failed) }
        let source = Memory(Data(), blocks: true)
        let task = Task { try await NativeMP4Input.open(input: source) }
        await source.entered()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(source.state.withLock { $0.cancelled })
    }

    private func big(_ value: UInt64, _ count: Int) -> Data { Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    private final class Memory: MediaByteInput {
        struct State { var readBytes = 0; var maximumRead = 0; var cancelled = false; var indexed: [Int64] = []; var reading = false; var continuation: CheckedContinuation<Void, Never>? }
        let state = Mutex(State()), wake = DispatchSemaphore(value: 0)
        let bytes: Data, known: Bool, fragment: Int, blocks: Bool, fails: Bool
        init(_ bytes: Data, known: Bool = false, fragment: Int = 4096, blocks: Bool = false, fails: Bool = false) {
            self.bytes = bytes; self.known = known; self.fragment = fragment; self.blocks = blocks; self.fails = fails
        }
        var length: Int64? { known ? Int64(bytes.count) : nil }
        var supportsRandomAccess: Bool { true }
        func prepareForSeek() {}
        func prepareForIndexedSeek(to offset: Int64) { state.withLock { $0.indexed.append(offset) } }
        func checkFailure() throws { if state.withLock({ $0.cancelled }) { throw CancellationError() } }
        func cancel() { state.withLock { $0.cancelled = true }; wake.signal() }
        func entered() async {
            await withCheckedContinuation { continuation in
                state.withLock { value in if value.reading { continuation.resume() } else { value.continuation = continuation } }
            }
        }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            state.withLock { value in
                value.maximumRead = max(value.maximumRead, maximumCount); value.reading = true
                value.continuation?.resume(); value.continuation = nil
            }
            if blocks { wake.wait() }
            try checkFailure()
            if fails { throw URLError(.networkConnectionLost) }
            guard offset < bytes.count else { return Data() }
            let end = min(bytes.count, Int(offset) + min(fragment, maximumCount))
            state.withLock { $0.readBytes += end - Int(offset) }
            return bytes.subdata(in: Int(offset)..<end)
        }
    }
}
private final class MP4ExtentFixtures: NSObject {}
