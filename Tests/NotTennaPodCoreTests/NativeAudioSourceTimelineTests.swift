import AVFoundation
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(2))) struct NativeAudioSourceTimelineTests {
    private struct Report: Decodable {
        let complete: Bool
        let cases: [Case]
        struct Case: Decodable {
            let name: String
            let knownLength: Bool
            let truncated: Bool
            let sha256: String
            let maps: [Map]
        }
        struct Map: Decodable { let durationUs: Int64; let seekable: Bool }
    }
    private func fixture(_ name: String) throws -> Data {
#if SWIFT_PACKAGE
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
#else
        let url = try #require(Bundle(for: NativeTimelineFixtures.self).url(forResource: name, withExtension: nil))
#endif
        return try Data(contentsOf: url)
    }
    private func report() throws -> Report {
#if SWIFT_PACKAGE
        let url = try #require(Bundle.module.url(forResource: "android-report", withExtension: "json", subdirectory: "Fixtures/NativeFormatReference"))
#else
        let url = try #require(Bundle(for: NativeTimelineFixtures.self).url(forResource: "android-report", withExtension: "json", subdirectory: "NativeFormatReference"))
#endif
        let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: url))
        try #require(report.complete && report.cases.count == 20)
        return report
    }
    private func format(_ name: String) -> NativeAudioSourceTimeline.Format {
        name.hasSuffix("wav") ? .wav : name.hasSuffix("aac") ? .adts : .flac
    }
    /// Duration as shown to the user: within 0.1 s of Android's, or unknown on both.
    private func sameDuration(_ actual: Int64?, _ androidUs: Int64) -> Bool {
        let reference: Int64? = androidUs == -9223372036854775807 ? nil : androidUs
        guard let actual, let reference else { return actual == nil && reference == nil }
        return abs(actual - reference) <= 100_000
    }
    private func seekTable(_ original: Data, placeholder: Bool = false) -> Data {
        let point = Data(repeating: placeholder ? 255 : 0, count: 8) + Data(repeating: 0, count: 8) + Data([0x12, 0])
        return original.prefix(42) + Data([3, 0, 0, 18]) + point + original.dropFirst(42)
    }

    // Expectations are the actual configured Android extractor report, including
    // content hashes. They are not produced by the Swift metadata implementation.
    // Arbitrary network chunk sizes must not change the result.
    @Test(arguments: 0..<14, [1, 17, 4096])
    func durationAndSeekabilityMatchAndroid(index: Int, fragment: Int) async throws {
        let cases = try report().cases.filter { !$0.name.hasSuffix("m4a") }
        try #require(cases.count == 14)
        let reference = cases[index]
        var data = try fixture(reference.name == "tone-seektable.flac" ? "tone.flac" : reference.name)
        if reference.name == "tone-seektable.flac" { data = seekTable(data) }
        if reference.truncated { data = Data(data.prefix(data.count / 2)) }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try #require(hash == reference.sha256)
        let input = Bytes(data, known: reference.knownLength, fragment: fragment)
        let timeline = try await NativeAudioSourceTimeline.read(input: input, format: format(reference.name))
        let expected = try #require(reference.maps.first)
        #expect(sameDuration(timeline.durationMicroseconds, expected.durationUs))
        #expect(timeline.seekable == expected.seekable)
    }

    @Test(arguments: ["tone.wav", "tone.aac", "tone.flac"], [false, true])
    func authenticatedStreamReportsAndroidDurationAndStillPlaysFully(name: String, known: Bool) async throws {
        let bytes = try fixture(name)
        let root = URL.temporaryDirectory.appendingPathComponent("native-timeline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = FeedCredentials(username: "timeline", password: "fixture")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            return .init(headers: ["Content-Type": "text/html"], body: bytes, includeAutomaticContentLength: known)
        }
        defer { server.stop() }
        let url = URL(string: "http://timeline.invalid/wrong.mp3")!
        let proxy = PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!)
        let cache = try SharedStreamingCache(directory: root)
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        let policy = try await NativeAudioSourceTimeline.read(input: remote.makeReadLease(), format: format(name))
        let reference = try #require(report().cases.first { $0.name == name && $0.knownLength == known && !$0.truncated }?.maps.first)
        #expect(sameDuration(policy.durationMicroseconds, reference.durationUs))
        #expect(policy.seekable == reference.seekable)
        // Reading metadata must not break playback of the same stream.
        let decoder = try await NativeIncrementalPCMDecoder.open(input: remote.makeReadLease())
        var actual: [Int16] = []
        while let packet = try await decoder.next() { actual += packet.samples }
        await decoder.cancel()
        let fileURL = root.appendingPathComponent(name)
        try bytes.write(to: fileURL)
        let file = try AVAudioFile(forReading: fileURL, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var expected: [Int16] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, file.length - file.framePosition)))
            try #require(buffer.frameLength > 0)
            expected += Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * decoder.channels))
        }
        #expect(name == "tone.aac" ? AudibleMatch.matches(actual, expected, channels: decoder.channels, sampleRate: decoder.sampleRate) : actual == expected)
        remote.input.cancel(); remote.relay.cancel()
    }

    @Test(arguments: ["tone.aac", "tone.flac"])
    func learnedOrCachedExtentDoesNotReclassifyInitialUnknownSource(name: String) async throws {
        let data = try fixture(name)
        let input = Bytes(data, known: false, cachedLength: Int64(data.count))
        let result = try await NativeAudioSourceTimeline.read(input: input, format: format(name))
        #expect(result.durationMicroseconds == (name.hasSuffix("flac") ? 8_000_000 : nil))
        #expect(!result.seekable)
    }

    @Test(arguments: [false, true], [false, true])
    func flacPlaceholderAndAbsentTotalSamplesPreserveIndependentPolicy(known: Bool, noTotal: Bool) async throws {
        var data = try fixture("tone.flac")
        if noTotal {
            data[21] &= 0xf0
            data.replaceSubrange(22..<26, with: Data(repeating: 0, count: 4))
        }
        let empty = try await NativeAudioSourceTimeline.read(input: Bytes(seekTable(data, placeholder: true), known: known), format: .flac)
        #expect(empty.seekable == (known && !noTotal))
        #expect(empty.durationMicroseconds == (noTotal ? nil : 8_000_000))
        let indexed = try await NativeAudioSourceTimeline.read(input: Bytes(seekTable(data), known: known), format: .flac)
        #expect(indexed.seekable)
        #expect(indexed.durationMicroseconds == empty.durationMicroseconds)
    }

    @Test func wavWithLargeMetadataChunkHasCorrectDuration() async throws {
        let original = try fixture("tone.wav")
        let paddingCount = 4 << 20
        let data = original.prefix(12) + Data("JUNK".utf8) + little(UInt64(paddingCount), 4) + Data(repeating: 0, count: paddingCount) + original.dropFirst(12)
        let input = Bytes(data, known: false)
        let result = try await NativeAudioSourceTimeline.read(input: input, format: .wav)
        #expect(result == NativeAudioSourceTimeline(durationMicroseconds: 8_000_000, seekable: true))
    }

    @Test(arguments: [false, true])
    func rf64UsesDeclaredDataSizeAndClampsOnlyKnownExtent(known: Bool) async throws {
        let original = try fixture("tone.wav")
        let samples: UInt64 = 480_000
        let ds64 = little(1_000_000, 8) + little(samples * 2, 8) + little(samples, 8) + little(0, 4)
        var data = Data("RF64".utf8) + little(0xffff_ffff, 4) + Data("WAVEds64".utf8) + little(28, 4) + ds64 + original.dropFirst(12)
        data.replaceSubrange(76..<80, with: little(0xffff_ffff, 4))
        let timeline = try await NativeAudioSourceTimeline.read(input: Bytes(data, known: known), format: .wav)
        #expect(timeline.durationMicroseconds == (known ? 8_000_000 : 10_000_000))
        #expect(timeline.seekable)
    }

    @Test func adtsDurationEstimateMatchesAndroidAndSkipsID3() async throws {
        let original = try fixture("tone.aac")
        let firstSize = Int(original[3] & 3) << 11 | Int(original[4]) << 3 | Int(original[5] >> 5)
        let frame = Data(original.prefix(firstSize))
        let tag = Data("ID3".utf8) + Data([4, 0, 0, 0, 0, 0, 3, 7, 8, 9])
        var data = tag
        for _ in 0..<1002 { data += frame }
        let input = Bytes(data, known: true)
        let result = try await NativeAudioSourceTimeline.read(input: input, format: .adts)
        // Source algorithm: integer frame average and truncated frame duration,
        // not the exact number of decoded samples or the native file duration.
        let bitrate = Int64(firstSize) * 8_000_000 / 21_333
        let android = Int64(data.count - tag.count) * 8_000_000 / bitrate
        #expect(abs((result.durationMicroseconds ?? 0) - android) <= 100_000)
        #expect(result.seekable)
    }

    @Test func corruptADTSBetweenFramesDisablesCBRInsteadOfInventingDuration() async throws {
        let original = try fixture("tone.aac")
        let firstSize = Int(original[3] & 3) << 11 | Int(original[4]) << 3 | Int(original[5] >> 5)
        let bytes = Data(original.prefix(firstSize)) + Data(repeating: 0, count: 6)
        let result = try await NativeAudioSourceTimeline.read(input: Bytes(bytes, known: true), format: .adts)
        #expect(!result.seekable && result.durationMicroseconds == nil)
    }

    @Test func malformedMetadataFailsWithAnError() async throws {
        var wav = try fixture("tone.wav")
        wav.replaceSubrange(24..<28, with: Data(repeating: 0, count: 4))
        var flac = try fixture("tone.flac")
        flac.replaceSubrange(18..<21, with: Data(repeating: 0, count: 3))
        var adts = try fixture("tone.aac")
        adts[2] |= 0x3c
        for (bytes, format) in [(wav, NativeAudioSourceTimeline.Format.wav), (flac, .flac), (adts, .adts)] {
            let input = Bytes(bytes, known: true)
            await #expect(throws: NativeAudioSourceTimeline.Failure.invalidMetadata) {
                try await NativeAudioSourceTimeline.read(input: input, format: format)
            }
        }
        let short = Bytes(Data("RIFF".utf8), known: true)
        await #expect(throws: NativeAudioSourceTimeline.Failure.incompleteMetadata) {
            try await NativeAudioSourceTimeline.read(input: short, format: .wav)
        }
    }

    @Test func cancellationInterruptsBlockedMetadataRead() async throws {
        let input = Blocked()
        let task = Task { try await NativeAudioSourceTimeline.read(input: input, format: .flac) }
        await input.entered()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(input.state.withLock { $0.cancelled })
    }

    @Test func originalInputErrorIsNotReplacedWithMetadataEOF() async throws {
        let input = Failing()
        await #expect(throws: URLError(.networkConnectionLost)) {
            try await NativeAudioSourceTimeline.read(input: input, format: .wav)
        }
    }

    private func little(_ value: UInt64, _ size: Int) -> Data {
        Data((0..<size).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private final class Bytes: MediaByteInput {
        struct State { var position = 0; var maximumRead = 0; var cancelled = false }
        let state = Mutex(State())
        let bytes: Data, known: Bool, fragment: Int, cachedLength: Int64?
        init(_ bytes: Data, known: Bool, fragment: Int = 4096, cachedLength: Int64? = nil) {
            self.bytes = bytes; self.known = known; self.fragment = fragment; self.cachedLength = cachedLength
        }
        var length: Int64? { cachedLength ?? (known ? Int64(bytes.count) : nil) }
        var initialDeclaredLength: Int64? { known ? Int64(bytes.count) : nil }
        var supportsRandomAccess: Bool { false }
        func prepareForSeek() { Issue.record("Metadata must be read sequentially") }
        func checkFailure() throws { if state.withLock({ $0.cancelled }) { throw CancellationError() } }
        func cancel() { state.withLock { $0.cancelled = true } }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            try checkFailure()
            return try state.withLock { state in
                try #require(Int64(state.position) == offset)
                state.maximumRead = max(state.maximumRead, maximumCount)
                let end = min(bytes.count, state.position + min(fragment, maximumCount))
                let result = bytes.subdata(in: state.position..<end)
                state.position = end
                return result
            }
        }
    }
    private final class Blocked: MediaByteInput {
        struct State { var reading = false; var cancelled = false; var continuation: CheckedContinuation<Void, Never>? }
        let state = Mutex(State()), wake = DispatchSemaphore(value: 0)
        var length: Int64? { nil }
        var supportsRandomAccess: Bool { false }
        func prepareForSeek() {}
        func checkFailure() throws { if state.withLock({ $0.cancelled }) { throw CancellationError() } }
        func cancel() { state.withLock { $0.cancelled = true }; wake.signal() }
        func entered() async {
            await withCheckedContinuation { continuation in
                state.withLock { value in
                    if value.reading { continuation.resume() } else { value.continuation = continuation }
                }
            }
        }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            state.withLock { value in value.reading = true; value.continuation?.resume(); value.continuation = nil }
            wake.wait()
            try checkFailure()
            return Data()
        }
    }
    private final class Failing: MediaByteInput {
        var length: Int64? { nil }
        var supportsRandomAccess: Bool { false }
        func prepareForSeek() {}
        func checkFailure() throws {}
        func cancel() {}
        func read(at offset: Int64, maximumCount: Int) throws -> Data { throw URLError(.networkConnectionLost) }
    }
}
private final class NativeTimelineFixtures: NSObject {}
