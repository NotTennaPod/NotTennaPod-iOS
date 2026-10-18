import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// An MP3 whose ID3v2 tag (large cover or chapter art) is longer than the 1 MiB type probe takes the
/// processed MP3 route like any other MP3, as Media3's sniffers skip ID3 tags of any size.
@MainActor @Suite(.serialized) struct LargeID3TagRoutingTests {
    nonisolated static let mebibyte = 1 << 20
    nonisolated static let sizes = [mebibyte / 2, 3 * mebibyte / 2, 3 * mebibyte]

    nonisolated static func fixture(_ name: String) throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: "mp3", subdirectory: "Fixtures"))
#else
        try #require(Bundle(for: LargeID3TagFixtures.self).url(forResource: name, withExtension: "mp3"))
#endif
    }
    /// Frame or tag size bytes: syncsafe (v2.4 frames, every tag header) or plain (v2.3 frames).
    nonisolated static func size(_ value: Int, syncsafe: Bool) -> [UInt8] {
        syncsafe ? [21, 14, 7, 0].map { UInt8((value >> $0) & 0x7f) } : [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
    }
    /// A deterministic cover-art frame: JPEG-like bytes full of 0xFF, so anything scanning the tag
    /// for MPEG sync words finds false frames.
    nonisolated static func artwork(payload: Int, version: UInt8) -> Data {
        var bytes = Data([0]) + Data("image/jpeg".utf8) + Data([0, 3, 0, 0xff, 0xd8, 0xff, 0xe0])
        var state: UInt64 = 0x9e37_79b9_7f4a_7c15
        bytes.reserveCapacity(payload)
        while bytes.count < payload {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            bytes.append(UInt8(truncatingIfNeeded: state >> 24))
        }
        return Data("APIC".utf8) + Data(size(payload, syncsafe: version == 4) + [0, 0]) + bytes.prefix(payload)
    }
    /// A tag of exactly `length` bytes, header and optional v2.4 footer included, holding `frames`
    /// and cover art (after them, or before with `artFirst`).
    nonisolated static func tag(length: Int, version: UInt8 = 4, footer: Bool = false, frames: Data = Data(),
                                artFirst: Bool = false) -> Data {
        let body = length - 10 - (footer ? 10 : 0)
        let flags: UInt8 = footer ? 0x10 : 0
        let fields = [version, 0, flags] + size(body, syncsafe: true)
        let art = artwork(payload: body - frames.count - 10, version: version)
        return Data("ID3".utf8) + Data(fields) + (artFirst ? art + frames : frames + art)
            + (footer ? Data("3DI".utf8) + Data(fields) : Data())
    }
    /// The fixture's own MLLT tag, enlarged by cover art placed before its frames, so the required
    /// timing metadata lies beyond the 1 MiB probe prefix for a large tag.
    nonisolated static func enlargedMLLT(by extra: Int) throws -> Data {
        let media = try Data(contentsOf: fixture("playback-indexed-mllt-stereo-v4"))
        let header = Array(media.prefix(10))
        let body = header[6...9].reduce(0) { ($0 << 7) | Int($1) }
        let frames = media.subdata(in: 10..<(10 + body))
        return tag(length: 10 + body + extra, frames: frames, artFirst: true) + media.dropFirst(10 + body)
    }

    /// Positional reads with an optional cap per read; records every read.
    final class Recording: MediaByteInput {
        let media: Data
        let randomAccess: Bool
        let largestAt: @Sendable (Int64) -> Int
        private let log = Mutex<[(offset: Int64, requested: Int, returned: Int)]>([])
        var reads: [(offset: Int64, requested: Int, returned: Int)] { log.withLock { $0 } }
        init(_ media: Data, randomAccess: Bool, largestAt: @escaping @Sendable (Int64) -> Int = { _ in .max }) {
            self.media = media; self.randomAccess = randomAccess; self.largestAt = largestAt
        }
        var length: Int64? { Int64(media.count) }
        var supportsRandomAccess: Bool { randomAccess }
        func prepareForSeek() {}
        func checkFailure() throws {}
        func cancel() {}
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            guard offset >= 0, (1...65_536).contains(maximumCount) else { throw URLError(.badURL) }
            let start = Int(min(offset, Int64(media.count)))
            let count = min(maximumCount, largestAt(offset), media.count - start)
            log.withLock { $0.append((offset, maximumCount, count)) }
            return media.subdata(in: start..<(start + count))
        }
        /// Every read starts where the previous one ended: no rewind, no gap.
        var isSequential: Bool {
            zip(reads, reads.dropFirst()).allSatisfy { $1.offset == $0.offset + Int64($0.returned) } && reads.first?.offset == 0
        }
        var firstDiscontinuity: String {
            zip(reads, reads.dropFirst()).first { $1.offset != $0.offset + Int64($0.returned) }.map { "\($0) then \($1)" } ?? "none"
        }
        var bytesRead: Int { reads.reduce(0) { $0 + $1.returned } }
    }
    nonisolated static func probe(_ input: Recording) async throws -> PCMRemoteInput.Probe.Result {
        try await PCMRemoteInput.Probe(input: input).identify()
    }

    @Test(arguments: sizes, [false, true])
    func probeSkipsLargeTagWithBoundedReadsAndOriginalOffsets(tagLength: Int, randomAccess: Bool) async throws {
        let media = Self.tag(length: tagLength) + (try Data(contentsOf: Self.fixture("playback-30sec")))
        let input = Recording(media, randomAccess: randomAccess)
        let result = try await Self.probe(input)
        #expect(result.format == .mp3)
        // The replayed prefix still means "from byte 0" and stays within the probe bound.
        #expect(result.bytes.count <= Self.mebibyte && result.bytes == media.prefix(result.bytes.count))
        #expect(input.reads.allSatisfy { $0.requested <= 65_536 })
        if randomAccess {
            // A file jumps to the tag end instead of reading the art.
            #expect(input.bytesRead < 64 * 1024)
        } else {
            // A stream is read through once, in order: a non-range source needs no second request.
            #expect(input.isSequential, "\(input.firstDiscontinuity)")
            #expect(input.bytesRead >= tagLength && input.bytesRead < tagLength + 64 * 1024)
        }
    }

    @Test(arguments: [false, true])
    func probeHandlesSplitFooterAndRepeatedTags(randomAccess: Bool) async throws {
        let audio = try Data(contentsOf: Self.fixture("playback-30sec"))
        let empty = Data("ID3".utf8) + Data([3, 0, 0, 0, 0, 0, 0])
        let cases: [(String, Data)] = [
            ("footer", Self.tag(length: 3 * Self.mebibyte / 2, footer: true) + audio),
            ("repeated", Self.tag(length: 3 * Self.mebibyte / 4) + Self.tag(length: 3 * Self.mebibyte / 4, version: 3) + audio),
            ("empty then large", empty + Self.tag(length: 3 * Self.mebibyte / 2) + audio),
            ("v2.2", Self.tag(length: 3 * Self.mebibyte / 2, version: 2) + audio)]
        for (name, media) in cases {
            // Every tag header arrives one or two bytes at a time.
            var headers: [Int64] = [0], position: Int64 = 0
            while let length = PCMRemoteInput.Probe.id3v2TagLength(media.subdata(in: Int(position)..<Int(position + 10))) {
                position += length; headers.append(position)
            }
            #expect(headers.count == (name == "repeated" || name == "empty then large" ? 3 : 2), "\(name)")
            let starts = headers
            let input = Recording(media, randomAccess: randomAccess) { offset in
                starts.contains { offset >= $0 && offset < $0 + 12 } ? 1 + Int(offset % 2) : .max
            }
            let result = try await Self.probe(input)
            #expect(result.format == .mp3, "\(name)")
            #expect(result.bytes == media.prefix(result.bytes.count), "\(name)")
            if !randomAccess { #expect(input.isSequential, "\(name): \(input.firstDiscontinuity)") }
        }
    }

    @Test(arguments: [false, true])
    func malformedTagsAreNotSkippedAndNeverReadUnbounded(randomAccess: Bool) async throws {
        let audio = try Data(contentsOf: Self.fixture("playback-30sec"))
        // Declared 3 MiB, but the file ends after 1.2 MiB: not media (Media3's sniffers reject it too).
        let beyond = Self.tag(length: 3 * Self.mebibyte).prefix(Self.mebibyte + Self.mebibyte / 5)
        let input = Recording(Data(beyond), randomAccess: randomAccess)
        await #expect(throws: StreamingAudioTypeError.unrecognized) { try await Self.probe(input) }
        #expect(input.bytesRead <= beyond.count)
        if !randomAccess { #expect(input.isSequential) }
        // A truncated header is not a tag.
        for truncated in [Data("ID3".utf8), Data("ID3".utf8) + Data([4, 0, 0, 0, 0])] {
            await #expect(throws: (any Error).self) { try await Self.probe(Recording(truncated, randomAccess: randomAccess)) }
        }
        // Invalid syncsafe size bytes, an unknown version or a 0xFF revision: not a tag, so the
        // native detector sees the original bytes exactly as without the skip, never a jump.
        for fields in [[4, 0, 0, 0x7f, 0xff, 0x7f, 0x7f], [5, 0, 0, 0x7f, 0x7f, 0x7f, 0x7f], [4, 0xff, 0, 0x7f, 0x7f, 0x7f, 0x7f]] as [[UInt8]] {
            let media = Data("ID3".utf8) + Data(fields) + audio
            #expect(PCMRemoteInput.Probe.id3v2TagLength(media.prefix(10)) == nil)
            let input = Recording(media, randomAccess: randomAccess)
            let actual: PCMRemoteInput.Format?
            do { actual = try await Self.probe(input).format } catch { actual = nil }
            let detector = try StreamingAudioTypeDetector()
            try? detector.append(media)
            let expected: PCMRemoteInput.Format? = (try? detector.finish()).map { $0 == "public.mp3" ? .mp3 : .native($0) }
            detector.close()
            #expect(actual == expected)
            #expect(input.isSequential && input.bytesRead <= media.count)
        }
    }

    /// Decoded audio of the untagged fixture, the reference for every tagged copy.
    private func reference(_ name: String) throws -> (samples: [Int16], channels: Int, rate: Int) {
        let file = try AVAudioFile(forReading: Self.fixture(name), commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var result = [Int16]()
        while file.framePosition < file.length {
            try file.read(into: buffer)
            try #require(buffer.frameLength > 0)
            result += UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength * file.processingFormat.channelCount))
        }
        return (result, Int(file.processingFormat.channelCount), Int(file.processingFormat.sampleRate))
    }
    /// Plays a session to its end and returns everything it presented.
    private func play(_ factory: PCMRecoveryFactory, from position: Int64, outputs: () -> SampleBufferPCMOutputTests.Transport?) async throws -> (samples: [Int16], session: SampleBufferPlaybackSession) {
        let session = try await factory.make(positionMilliseconds: position, parameters: .init(speed: 1, skipSilence: false))
        defer { session.close() }
        try await session.prepare(); try session.play()
        let output = try #require(outputs())
        let deadline = ContinuousClock.now + .seconds(20)
        while session.state != .ended, session.failure == nil, ContinuousClock.now < deadline {
            if output.playing { output.currentTime = output.end; output.onTimeChanged?() }
            await Task.yield()
        }
        try #require(session.state == .ended && session.failure == nil)
        var actual = Data()
        for buffer in output.buffers { actual.append(try #require(buffer.content.withContiguousStorageIfAvailable { Data($0) })) }
        return (PCMTestFixture.samples(actual), session)
    }

    @Test(arguments: sizes)
    func localLargeTagDecodesCompletelyAndSeeksThroughTheMP3Route(tagLength: Int) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("large-id3-local-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["playback-30sec", "playback-indexed-mllt-stereo-v4"] {
            let url = root.appendingPathComponent("\(name).media")
            let media = name.contains("mllt") ? try Self.enlargedMLLT(by: tagLength)
                : Self.tag(length: tagLength) + (try Data(contentsOf: Self.fixture(name)))
            try media.write(to: url)
            #expect(try await LocalAudioBytes.openIdentified(url: url)?.format == .mp3)
            let expected = try reference(name)
            var outputs: [SampleBufferPCMOutputTests.Transport] = []
            let owner = PCMPlaybackFactory(cacheDirectory: root.appendingPathComponent("cache"), makeTransport: {
                let output = SampleBufferPCMOutputTests.Transport(); outputs.append(output); return output
            })
            let factory = try #require(try await owner.processedIfSupported(url: url, proxy: PodcastProxy(), credentials: nil, userAgent: "test"))
            for start: Int64 in [0, 20_000] {
                let (actual, session) = try await play(factory, from: start, outputs: { outputs.last })
                // Required timing metadata still comes from the tag: the MLLT duration, or the Xing one.
                #expect(abs((session.sourceDurationMilliseconds ?? 0) - (name.contains("mllt") ? 30_024 : 30_040)) <= 50)
                #expect(session.sourceSeekable == true)
                let skipped = Int(Double(start) / 1000 * Double(expected.rate)) * expected.channels
                PCMTestFixture.expectAudiblyEquivalent(actual, Array(expected.samples.dropFirst(skipped)),
                    channels: expected.channels, sampleRate: expected.rate, durationToleranceMilliseconds: 250)
            }
        }
    }

    @Test(arguments: sizes, [0, 1, 2])
    func remoteLargeTagPlaysCompletelyRangedAndUnranged(tagLength: Int, configuration: Int) async throws {
        // 0: ranges and a length; 1: no ranges, with a length; 2: no ranges, no length (chunked/live-style).
        let ranged = configuration == 0, unknownLength = configuration == 2
        let root = URL.temporaryDirectory.appendingPathComponent("large-id3-remote-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let media = Self.tag(length: tagLength) + (try Data(contentsOf: Self.fixture("playback-30sec")))
        let expected = try reference("playback-30sec")
        let credentials = FeedCredentials(username: "art", password: "large")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            let start = ranged ? request.headers["range"].flatMap { Int($0.dropFirst(6).dropLast()) } ?? 0 : 0
            if start > 0 {
                return .init(status: 206, headers: ["Content-Type": "audio/mpeg", "ETag": "\"art\"",
                    "Content-Range": "bytes \(start)-\(media.count - 1)/\(media.count)"], body: Data(media.dropFirst(start)))
            }
            return .init(headers: ["Content-Type": "audio/mpeg", "ETag": "\"art\""].merging(ranged ? ["Accept-Ranges": "bytes"] : [:]) { $1 },
                body: media, includeAutomaticContentLength: !unknownLength)
        }
        defer { server.stop() }
        let probed = try await PCMRemoteInput.open(url: server.url, proxy: PodcastProxy(), credentials: credentials,
            cache: SharedStreamingCache(directory: root.appendingPathComponent("probe")))
        #expect(probed.format == .mp3)
        var outputs: [SampleBufferPCMOutputTests.Transport] = []
        let owner = PCMPlaybackFactory(cacheDirectory: root.appendingPathComponent("cache"), makeTransport: {
            let output = SampleBufferPCMOutputTests.Transport(); outputs.append(output); return output
        })
        let before = server.requests.count
        let factory = try #require(try await owner.processedIfSupported(url: server.url, proxy: PodcastProxy(),
            credentials: credentials, userAgent: "test"))
        let (actual, session) = try await play(factory, from: 0, outputs: { outputs.last })
        PCMTestFixture.expectAudiblyEquivalent(actual, expected.samples, channels: expected.channels, sampleRate: expected.rate)
        if !unknownLength { #expect(abs((session.sourceDurationMilliseconds ?? 0) - 30_040) <= 50) }
        // Identification and the whole episode come from one response: nothing probed is fetched again.
        #expect(server.requests.count - before == 1, "\(server.requests.map { $0.headers["range"] ?? "initial" })")
        if ranged {
            let (sought, _) = try await play(factory, from: 20_000, outputs: { outputs.last })
            let skipped = 20 * expected.rate * expected.channels
            PCMTestFixture.expectAudiblyEquivalent(sought, Array(expected.samples.dropFirst(skipped)),
                channels: expected.channels, sampleRate: expected.rate, durationToleranceMilliseconds: 250)
        }
    }

    /// A response that cannot be repeated (no length, no ranges, gone afterwards) carries identification,
    /// the tag's required timing metadata beyond the probe prefix (MLLT after the art) and all the audio.
    @Test(arguments: sizes)
    func oneUnrepeatableUnknownLengthResponsePlaysTheWholeEpisode(tagLength: Int) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("large-id3-once-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let media = try Self.enlargedMLLT(by: tagLength)
        let expected = try reference("playback-indexed-mllt-stereo-v4")
        let credentials = FeedCredentials(username: "once", password: "only")
        let answered = Mutex(false)
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            let first = answered.withLock { done in defer { done = true }; return !done }
            guard first else { return .init(status: 410, body: Data()) }
            return .init(headers: ["Content-Type": "audio/mpeg"], body: media, includeAutomaticContentLength: false)
        }
        defer { server.stop() }
        var outputs: [SampleBufferPCMOutputTests.Transport] = []
        let owner = PCMPlaybackFactory(cacheDirectory: root, makeTransport: {
            let output = SampleBufferPCMOutputTests.Transport(); outputs.append(output); return output
        })
        let factory = try #require(try await owner.processedIfSupported(url: server.url, proxy: PodcastProxy(),
            credentials: credentials, userAgent: "test"))
        let (actual, session) = try await play(factory, from: 0, outputs: { outputs.last })
        PCMTestFixture.expectAudiblyEquivalent(actual, expected.samples, channels: expected.channels, sampleRate: expected.rate)
        #expect(abs((session.sourceDurationMilliseconds ?? 0) - 30_024) <= 50)
        #expect(server.requests.count == 1, "\(server.requests.map { $0.headers["range"] ?? "initial" })")
    }

    /// A one-shot server for `media`: no length, no ranges, HTTP 410 after the first answer.
    private func once(_ media: Data, length: Bool = false) async throws -> LoopbackHTTPServer {
        let answered = Mutex(false)
        return try await LoopbackHTTPServer.start { _ in
            let first = answered.withLock { done in defer { done = true }; return !done }
            guard first else { return .init(status: 410, body: Data()) }
            return .init(headers: ["Content-Type": "audio/mpeg"], body: media, includeAutomaticContentLength: length)
        }
    }
    /// Plays a prepared remote input through the processed MP3 route.
    private func play(_ input: PCMRemoteInput, url: URL, cache: SharedStreamingCache) async throws -> [Int16] {
        var outputs: [SampleBufferPCMOutputTests.Transport] = []
        let factory = try PCMRecoveryFactory(remote: input, url: url, proxy: PodcastProxy(), credentials: nil, cache: cache,
            maximumOutputFrames: 4096, maximumQueuedBuffers: 4,
            makeTransport: { let output = SampleBufferPCMOutputTests.Transport(); outputs.append(output); return output })
        return try await play(factory, from: 0, outputs: { outputs.last }).samples
    }

    /// Identification keeps at most its prefix plus `limit` bytes. A stream that cannot be read again
    /// and whose tag needs more fails then, with that cause, on its one request (never a later 410);
    /// one just within plays from that request.
    @Test(arguments: [(Int64(1) << 20, false), (Int64(1) << 20, true), (PCMRemoteInput.ProbedBytes.maximumCount, false)])
    func streamThatCannotBeReadAgainFailsWhenItsTagExceedsTheBuffer(limit: Int64, within: Bool) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("large-id3-limit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try Data(contentsOf: Self.fixture("playback-30sec"))
        let budget = Int(limit) + Self.mebibyte
        // Padding is valid tag content; the art generator would be slow at 65 MiB.
        let length = within ? budget - 128 * 1024 : budget + 64 * 1024
        let tag = Data("ID3".utf8) + Data([4, 0, 0] + Self.size(length - 10, syncsafe: true)) + Data(count: length - 10)
        let server = try await once(tag + audio)
        defer { server.stop() }
        let cache = try SharedStreamingCache(directory: root)
        let retention = PCMRemoteInput.Retention(limit: limit)
        if within {
            let input = try await PCMRemoteInput.open(url: server.url, proxy: PodcastProxy(), credentials: nil, cache: cache, retention: retention)
            #expect(input.format == .mp3)
            let expected = try reference("playback-30sec")
            PCMTestFixture.expectAudiblyEquivalent(try await play(input, url: server.url, cache: cache), expected.samples,
                channels: expected.channels, sampleRate: expected.rate)
        } else {
            await #expect(throws: PCMRemoteInput.Failure.metadataTooLargeToBuffer) {
                _ = try await PCMRemoteInput.open(url: server.url, proxy: PodcastProxy(), credentials: nil, cache: cache, retention: retention)
            }
        }
        #expect(server.requests.count == 1)
    }

    /// When the bytes cannot be kept (here: no such directory), a stream that cannot be read again fails
    /// with that storage error; one with a length still plays, reading them again from the shared cache.
    @Test(arguments: [false, true])
    func storageFailureFailsOnlyAStreamThatCannotBeReadAgain(known: Bool) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("large-id3-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let media = Self.tag(length: 3 * Self.mebibyte / 2) + (try Data(contentsOf: Self.fixture("playback-30sec")))
        let server = try await once(media, length: known)
        defer { server.stop() }
        let cache = try SharedStreamingCache(directory: root.appendingPathComponent("cache"))
        let retention = PCMRemoteInput.Retention(directory: root.appendingPathComponent("missing", isDirectory: true))
        if known {
            let input = try await PCMRemoteInput.open(url: server.url, proxy: PodcastProxy(), credentials: nil, cache: cache, retention: retention)
            let expected = try reference("playback-30sec")
            PCMTestFixture.expectAudiblyEquivalent(try await play(input, url: server.url, cache: cache), expected.samples,
                channels: expected.channels, sampleRate: expected.rate)
        } else {
            await #expect(throws: POSIXError(.ENOENT)) {
                _ = try await PCMRemoteInput.open(url: server.url, proxy: PodcastProxy(), credentials: nil, cache: cache, retention: retention)
            }
        }
        #expect(server.requests.count == 1)
    }
}
#if !SWIFT_PACKAGE
private final class LargeID3TagFixtures: NSObject {}
#endif
