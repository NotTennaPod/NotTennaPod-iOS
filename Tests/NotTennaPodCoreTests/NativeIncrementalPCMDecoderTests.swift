import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(2))) struct NativeIncrementalPCMDecoderTests {
    static let names = ["tone.wav", "tone.aac", "tone.m4a", "tone.flac"]
    private func fixture(_ name: String) throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
#else
        try #require(Bundle(for: IncrementalPCMFixtures.self).url(forResource: name, withExtension: nil))
#endif
    }
    private func baseline(_ name: String) throws -> [Int16] {
        let file = try AVAudioFile(forReading: fixture(name), commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var result: [Int16] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, file.length - file.framePosition)))
            try #require(buffer.frameLength > 0)
            result += Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0],
                count: Int(buffer.frameLength) * Int(file.processingFormat.channelCount)))
        }
        return result
    }
    private func collect(_ decoder: NativeIncrementalPCMDecoder, startFrame: Int64 = 0) async throws -> [Int16] {
        var result: [Int16] = []
        while let packet = try await decoder.next() {
            #expect(packet.presentationTime == CMTime(value: startFrame + Int64(result.count / decoder.channels), timescale: Int32(decoder.sampleRate)))
            result += packet.samples
        }
        #expect(try await decoder.next() == nil)
        return result
    }
    /// Lossless formats decode exactly; lossy ones must sound the same.
    private func compare(_ actual: [Int16], _ expected: [Int16], name: String, _ decoder: NativeIncrementalPCMDecoder) {
        let lossless = name.hasSuffix("wav") || name.hasSuffix("flac")
        #expect(lossless ? actual == expected
            : AudibleMatch.matches(actual, expected, channels: decoder.channels, sampleRate: decoder.sampleRate),
            "\(name): complete audio differs")
    }

    @Test(arguments: names, [1, 17, 4096, 32768])
    func unknownLengthArbitrarilyChunkedStreamPlaysCompleteAudio(name: String, chunk: Int) async throws {
        let input = Bytes(try Data(contentsOf: fixture(name)), chunk: chunk)
        let expected = try baseline(name)
        let decoder = try await NativeIncrementalPCMDecoder.open(input: input)
        compare(try await collect(decoder), expected, name: name, decoder)
        await decoder.cancel()
    }

    @Test(arguments: names, [false, true])
    func mislabelledUnknownLengthHTTPStreamPlaysCompleteAudio(name: String, proxyEnabled: Bool) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("incremental-http-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try Data(contentsOf: fixture(name)), expected = try baseline(name)
        let credentials = FeedCredentials(username: "native", password: "stream")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            return .init(headers: ["Content-Type": "text/html"], body: bytes, includeAutomaticContentLength: false)
        }
        defer { server.stop() }
        let url = proxyEnabled ? URL(string: "http://native-stream.invalid/wrong.mp3")! : server.url.appendingPathComponent("wrong.mp3")
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let cache = try SharedStreamingCache(directory: root)
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        let decoder = try await NativeIncrementalPCMDecoder.open(input: remote.makeReadLease())
        compare(try await collect(decoder), expected, name: name, decoder)
        await decoder.cancel()
    }

    @Test(arguments: names)
    func audioStartsBeforeDownloadEndsAndStopDoesNotHang(name: String) async throws {
        let bytes = try Data(contentsOf: fixture(name)), expected = try baseline(name)
        let input = Bytes(bytes, chunk: 4096, blockAfter: min(bytes.count - 1, 32768))
        let decoder = try await NativeIncrementalPCMDecoder.open(input: input)
        let first = try #require(try await decoder.next())
        #expect(!first.samples.isEmpty)
        compare(first.samples, Array(expected.prefix(first.samples.count)), name: name, decoder)
        let task = Task { try await collect(decoder, startFrame: Int64(first.frameCount)) }
        defer { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !input.state.withLock({ $0.waiting }), ContinuousClock.now < deadline { await Task.yield() }
        try #require(input.state.withLock { $0.waiting })
        await decoder.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(arguments: ["tone.wav", "tone.m4a", "tone.flac"])
    func truncatedFileReportsErrorInsteadOfEndingNormally(name: String) async throws {
        let bytes = try Data(contentsOf: fixture(name))
        let input = Bytes(Data(bytes.prefix(bytes.count / 2)), chunk: 4096)
        let decoder = try await NativeIncrementalPCMDecoder.open(input: input)
        let first = try #require(try await decoder.next())
        #expect(!first.samples.isEmpty)
        await #expect(throws: (any Error).self) {
            try await collect(decoder, startFrame: Int64(first.frameCount))
        }
    }

    @Test func unplayableOrMalformedDataReportsError() async throws {
        let tail = Bytes(try Data(contentsOf: fixture("tone-tail.m4a")), chunk: 4096)
        await #expect(throws: NativeAudioStreamParser.Failure.requiresRandomAccess) {
            try await NativeIncrementalPCMDecoder.open(input: tail)
        }
        for bytes in [Data(), Data("<html>broken</html>".utf8), Data([0x52, 0x49, 0x46, 0x46])] {
            let input = Bytes(bytes, chunk: 1)
            await #expect(throws: (any Error).self) { try await NativeIncrementalPCMDecoder.open(input: input) }
        }
    }

    private final class Bytes: MediaByteInput {
        struct State { var position = 0; var cancelled = false; var waiting = false }
        let state = Mutex(State())
        let bytes: Data, chunk: Int, blockAfter: Int?
        let wake = DispatchSemaphore(value: 0)
        init(_ bytes: Data, chunk: Int, blockAfter: Int? = nil) { self.bytes = bytes; self.chunk = chunk; self.blockAfter = blockAfter }
        var length: Int64? { nil }
        var supportsRandomAccess: Bool { false }
        func prepareForSeek() { Issue.record("Incremental input must not seek") }
        func cancel() { state.withLock { $0.cancelled = true }; wake.signal() }
        func checkFailure() throws { if state.withLock({ $0.cancelled }) { throw CancellationError() } }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            try checkFailure()
            #expect(offset == state.withLock { Int64($0.position) })
            if let blockAfter, offset >= blockAfter {
                state.withLock { $0.waiting = true }; wake.wait(); try checkFailure()
            }
            guard offset < bytes.count else { return Data() }
            let end = min(bytes.count, Int(offset) + min(chunk, maximumCount), blockAfter ?? bytes.count)
            state.withLock { $0.position = end }
            return bytes.subdata(in: Int(offset)..<end)
        }
    }
}
private final class IncrementalPCMFixtures: NSObject {}
