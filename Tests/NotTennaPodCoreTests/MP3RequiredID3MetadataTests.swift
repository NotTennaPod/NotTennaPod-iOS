import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct MP3RequiredID3MetadataTests {
    final class Input: MediaByteInput {
        let data: Data
        let reads = Mutex<[Int]>([])
        let cancelled = Mutex(false)
        let failureOffset: Int64?
        enum Failure: Error { case source }
        init(_ data: Data, failureOffset: Int64? = nil) { self.data = data; self.failureOffset = failureOffset }
        var length: Int64? { Int64(data.count) }
        var supportsRandomAccess: Bool { false }
        func prepareForSeek() { Issue.record("Required metadata must not enable network range seeking") }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            try checkFailure()
            if offset == failureOffset { throw Failure.source }
            reads.withLock { $0.append(maximumCount) }
            guard offset >= 0, maximumCount > 0 else { throw Failure.source }
            guard offset < data.count else { return Data() }
            return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + maximumCount))
        }
        func checkFailure() throws { if cancelled.withLock({ $0 }) { throw CancellationError() } }
        func cancel() { cancelled.withLock { $0 = true } }
    }

    static func integer(_ value: Int, count: Int) -> Data {
        Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    static func synchSafe(_ value: Int) -> Data {
        Data((0..<4).reversed().map { UInt8((value >> ($0 * 7)) & 127) })
    }
    static func unsynchronize(_ bytes: Data) -> Data {
        var result = Data()
        for byte in bytes { result.append(byte); if byte == 255 { result.append(0) } }
        return result
    }
    static func mllt(milliseconds: Int = 5000, deviations: [UInt8] = [0, 1, 0, 2]) -> Data {
        integer(575, count: 2) + integer(59800, count: 3) + integer(milliseconds, count: 3)
            + Data([8, 8]) + Data(deviations)
    }
    static func frame(_ id: String, body: Data, version: Int = 3, flags: Int = 0, rawSize: Bool = false) -> Data {
        let size = version == 4 && !rawSize ? synchSafe(body.count) : integer(body.count, count: version == 2 ? 3 : 4)
        return Data(id.utf8) + size + (version == 2 ? Data() : integer(flags, count: 2)) + body
    }
    static func tag(_ body: Data, version: Int = 3, flags: UInt8 = 0) -> Data {
        Data([0x49, 0x44, 0x33, UInt8(version), 0, flags]) + synchSafe(body.count) + body
    }
    static func playbackTag(version: Int = 3) -> Data {
        tag(frame("MLLT", body: mllt(milliseconds: 15000, deviations: [0, 0, 0, 0]), version: version), version: version)
    }
    private func result(_ data: Data) throws -> Int64? {
        try MP3RequiredID3Metadata.read(from: Input(data))?.durationMicroseconds
    }

    // Original MlltSeeker method output.
    private static let seekOracle: [[Int64]] = [
        [0, 0, 0, 4096, -342000],
        [1, 44, 0, 4096, -338000],
        [100000, 45, 100000, 5291, -338000],
        [104482, 149, 104000, 5339, -330000],
        [208964, 416, 208000, 6583, -307000],
        [299999, 417, 299000, 7671, -307000],
        [300000, 418, 300000, 7683, -307000],
        [313446, 617, 313000, 7838, -290000],
        [500000, 1017, 500000, 10074, -257000],
        [1000000, 90056, 1000000, 16053, 7189000],
        [10000000, 90065, 10000000, 123660, 7189000],
        [22500000, 119599, 10003000, 123696, 9660000],
        [29900000, 119645, 10003000, 123696, 9664000],
        [30040793, 120016, 10003000, 123696, 9695000],
        [60000000, 125000, 10003000, 123696, 10003000],
    ]
    @Test(arguments: 0..<15, [3, 4])
    func mlltLookupMatchesOriginalInterpolation(caseIndex: Int, version: Int) throws {
        let row = Self.seekOracle[caseIndex]
        let data = Self.tag(Self.frame("MLLT", body: Self.mllt(), version: version), version: version)
        let input = Input(data)
        let forward = try #require(MP3RequiredID3Metadata.read(from: input,
            seeking: .timeMicroseconds(row[0]), firstFramePosition: 4096)?.seekPoint)
        #expect(forward.timeMicroseconds == row[2] && forward.bytePosition == row[3])
        let reverse = try #require(MP3RequiredID3Metadata.read(from: input,
            seeking: .bytePosition(row[1]), firstFramePosition: 4096)?.seekPoint)
        #expect(reverse.timeMicroseconds == row[4])
        #expect(input.reads.withLock { $0.max() ?? 0 } <= 4096)
        let table = try #require(MP3RequiredID3Metadata.read(from: input, retainSeekTable: true)?.seekTable)
        #expect(try table.point(for: .timeMicroseconds(row[0]), firstFramePosition: 4096) == forward)
        #expect(try table.point(for: .bytePosition(row[1]), firstFramePosition: 4096) == reverse)
    }

    @Test func retainedTableHasBoundedWritesAndReleasesItsTemporaryFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mllt-table-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var builder: MP3MLLTSeekTable.Builder? = try .init(directory: directory)
        for index in 1...100_000 { try builder?.append(milliseconds: Int128(index * 10), position: Int128(index * 100)) }
        var table = try #require(builder).finish()
        builder = nil
        let url = try #require(table?.url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try table?.point(for: .timeMicroseconds(555_555_555), firstFramePosition: 1234) == .init(timeMicroseconds: 555_555_000, bytePosition: 5_556_784))
        #expect(try table?.point(for: .bytePosition(5_556_784), firstFramePosition: 1234) == .init(timeMicroseconds: 555_555_000, bytePosition: 5_556_784))
        table = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
        var rejected: MP3MLLTSeekTable.Builder? = try .init(directory: directory)
        try rejected?.append(milliseconds: 10, position: 100)
        try rejected?.append(milliseconds: 9, position: 200)
        #expect(try rejected?.finish() == nil)
        rejected = nil
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test(arguments: [3, 4])
    func firstDecodedTagAndFirstUsableMLLTWin(version: Int) throws {
        let first = Self.tag(Self.frame("MLLT", body: Self.mllt(), version: version)
            + Self.frame("MLLT", body: Self.mllt(milliseconds: 9000), version: version), version: version)
        let later = Self.playbackTag(version: version)
        #expect(try result(first + later) == 10_003_000)
        let empty = Self.tag(Self.frame("TXXX", body: Data([0, 0]), version: version), version: version)
        #expect(try result(empty + later) == nil)
        // A malformed frame makes the complete tag invalid; a later valid tag is eligible.
        let invalid = Self.tag(Data("FAIL".utf8) + Self.integer(500, count: 4) + Data([0, 0]), version: version)
        #expect(try result(invalid + later) == 30_000_000)
    }

    @Test(arguments: [3, 4])
    func extendedHeadersUnsynchronizationGroupingAndLengthFields(version: Int) throws {
        let payload = Self.mllt(deviations: [0, 0, 255, 255])
        let body: Data, flags: UInt8
        if version == 3 {
            let frames = Self.frame("MLLT", body: Data([1]) + payload, flags: 0x20)
            body = Self.integer(6, count: 4) + Data(repeating: 0, count: 6) + Self.unsynchronize(frames)
            flags = 0xc0
        } else {
            let frames = Self.frame("MLLT", body: Data([1]) + Self.synchSafe(payload.count) + Self.unsynchronize(payload),
                version: 4, flags: 0x43)
            let contents = Self.synchSafe(6) + Data([1, 0]) + frames
            let footer = Data([0x33, 0x44, 0x49, 4, 0, 0x50]) + Self.synchSafe(contents.count + 10)
            body = contents + footer
            flags = 0x50
        }
        #expect(try result(Self.tag(body, version: version, flags: flags)) == 10_255_000)
    }

    @Test func rawV4FrameSizeFallbackValidatesWholeTagBeforeSelectingMetadata() throws {
        let first = Self.frame("MLLT", body: Self.mllt(), version: 4)
        let raw = Self.frame("APIC", body: Data(repeating: 0, count: 128), version: 4, rawSize: true)
        #expect(try result(Self.tag(first + raw, version: 4)) == 10_003_000)
        let invalid = Data("FAIL".utf8) + Self.integer(0x1fff_ffff, count: 4) + Data([0, 0])
        #expect(try result(Self.tag(first + invalid, version: 4) + Self.playbackTag()) == 30_000_000)
    }

    @Test(arguments: [3, 4])
    func unsupportedAndMalformedFramesCannotHideLaterValidMLLT(version: Int) throws {
        let flags = version == 3 ? [0x80, 0x40] : [8, 4]
        var body = Data()
        for flag in flags { body += Self.frame("MLLT", body: Self.mllt(milliseconds: 9000), version: version, flags: flag) }
        body += Self.frame("MLLT", body: Self.mllt().prefix(9), version: version)
        var invalidBits = Self.mllt(); invalidBits[8] = 0; invalidBits[9] = 0
        body += Self.frame("MLLT", body: invalidBits, version: version)
        body += Self.frame("MLLT", body: Self.mllt(), version: version)
        #expect(try result(Self.tag(body, version: version)) == 10_003_000)
        // The active dependency decodes v2.2 MLL as BinaryFrame, not MlltFrame.
        #expect(try result(Self.tag(Self.frame("MLL", body: Self.mllt(), version: 2), version: 2)
            + Self.playbackTag()) == nil)
    }

    @Test func bitWidthsAndPartialReferenceTailPreserveSourceDuration() throws {
        // Four references of byte-deviation3 bits + time-deviation5 bits.
        let payload = Self.integer(1, count: 2) + Self.integer(100, count: 3)
            + Self.integer(10, count: 3) + Data([3, 5, 0b00100010, 0b01000011, 0b01100100, 0b10000101])
        #expect(try result(Self.tag(Self.frame("MLLT", body: payload))) == 54_000)
        // Three12-bit references and four leftover bits; the tail is not a reference.
        let trailing = Self.integer(1, count: 2) + Self.integer(100, count: 3)
            + Self.integer(10, count: 3) + Data([4, 8, 0x10, 0x22, 0x03, 0x30, 0x4f])
        #expect(try result(Self.tag(Self.frame("MLLT", body: trailing))) == 39_000)
        for (byteWidth, timeWidth, tail, expected) in [
            (0, 8, Data([1, 2, 3]), Int64(36_000)),
            (8, 0, Data([1, 2, 3]), Int64(30_000)),
            (32, 32, Data([0, 0, 0, 1, 0, 0, 0, 2]), Int64(12_000))
        ] {
            let fields = Self.integer(1, count: 2) + Self.integer(100, count: 3)
                + Self.integer(10, count: 3) + Data([UInt8(byteWidth), UInt8(timeWidth)]) + tail
            #expect(try result(Self.tag(Self.frame("MLLT", body: fields))) == expected)
        }
    }

    @Test func largeIgnoredArtworkAndHeaderSearchUseBoundedCacheWindows() throws {
        let art = Self.frame("APIC", body: Data(repeating: 0, count: 1_048_576))
        let input = Input(Self.tag(art + Self.frame("MLLT", body: Self.mllt())))
        #expect(try MP3RequiredID3Metadata.read(from: input)?.durationMicroseconds == 10_003_000)
        #expect(input.reads.withLock { $0.max() ?? 0 } <= 4096)
        #expect(input.reads.withLock { $0.reduce(0, +) } < 20_000)
        let junk = Input(Data(repeating: 0, count: 131_073) + Self.playbackTag())
        #expect(try MP3RequiredID3Metadata.read(from: junk) == nil)
        #expect(junk.reads.withLock { $0.reduce(0, +) } < 140_000)
    }

    @Test func originalReadErrorsAndCancellationAreNotMalformedMetadata() throws {
        let bytes = Self.playbackTag()
        let failed = Input(bytes, failureOffset: Int64(bytes.count - 1))
        #expect(throws: Input.Failure.source) { try MP3RequiredID3Metadata.read(from: failed) }
        let cancelled = Input(bytes); cancelled.cancel()
        #expect(throws: CancellationError.self) { try MP3RequiredID3Metadata.read(from: cancelled) }
    }

    @Test(arguments: [3, 4], [false, true])
    func requiredMetadataOverridesXingWithoutChangingCompleteStereoAudio(version: Int, unsynchronized: Bool) async throws {
#if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: "playback-vbr-stereo", withExtension: "mp3", subdirectory: "Fixtures")!
#else
        let url = Bundle(for: RequiredID3Fixtures.self).url(forResource: "playback-vbr-stereo", withExtension: "mp3")!
#endif
        // One31-packet reference spans6240 encoded audio bytes and744ms. The
        // 255-byte deviation deliberately exercises FF/00 unsynchronization.
        let payload = Self.integer(31, count: 2) + Self.integer(5985, count: 3)
            + Self.integer(744, count: 3) + Data([8, 8, 255, 0])
        let tag: Data
        if unsynchronized && version == 3 {
            tag = Self.tag(Self.unsynchronize(Self.frame("MLLT", body: payload)), flags: 0x80)
        } else if unsynchronized {
            tag = Self.tag(Self.frame("MLLT", body: Data([1]) + Self.synchSafe(payload.count)
                + Self.unsynchronize(payload), version: 4, flags: 0x43), version: 4)
        } else { tag = Self.tag(Self.frame("MLLT", body: payload, version: version), version: version) }
        let body = tag + (try Data(contentsOf: url))
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"],
                body: Data("\(String(body.count, radix: 16))\r\n".utf8) + body + Data("\r\n0\r\n\r\n".utf8))
        }
        defer { server.stop() }
        let source = NativeMP3PlaybackSource(url: server.url, proxy: PodcastProxy())
        let decoder = try await source.makeDecoder(prepareSourceTimeline: true)
        #expect(decoder.sourceSeekable == true && decoder.sourceDurationMilliseconds == 744)
        var count = 0, peak = 0
        while let packet = try await decoder.next() {
            // Contiguous timestamps: no gaps or overlaps in the played audio.
            #expect(packet.presentationTime == CMTime(value: Int64(count), timescale: 48000))
            #expect(packet.channels == 2)
            count += packet.frameCount
            peak = max(peak, packet.samples.lazy.map { abs(Int($0)) }.max() ?? 0)
        }
        // The prepended tag changes neither the length nor the audibility of the episode
        // (0.7 s at 48 kHz; within 50 ms of the file's own length).
        let file = try AVAudioFile(forReading: url)
        #expect(abs(count - Int(file.length)) <= 2400)
        #expect(peak > 64, "decoded audio is silent")
        await decoder.cancel()
    }

    @Test func cancelledPartialTagPreparationRetainsRequestForReplacement() async throws {
        let tag = Self.tag(Self.frame("APIC", body: Data(repeating: 0, count: 16_384))
            + Self.frame("MLLT", body: Self.mllt(milliseconds: 15000, deviations: [0, 0, 0, 0])))
#if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures")!
#else
        let url = Bundle(for: RequiredID3Fixtures.self).url(forResource: "playback-30sec", withExtension: "mp3")!
#endif
        let body = tag + (try Data(contentsOf: url))
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "Content-Length": String(body.count)],
                body: Data(body.prefix(4096)), keepConnectionOpen: true)
        }
        defer { server.stop() }
        let source = NativeMP3PlaybackSource(url: server.url, proxy: PodcastProxy())
        let old = Task { try await source.makeDecoder(prepareSourceTimeline: true) }
        defer { old.cancel() }
        try await wait {
            let snapshot = await source.networkSnapshot
            return snapshot?.waitingReaders == 1 && snapshot?.received == 4096
        }
        old.cancel()
        await #expect(throws: CancellationError.self) { try await old.value }
        let replacement = Task { try await source.makeDecoder(prepareSourceTimeline: true) }
        defer { replacement.cancel() }
        try await wait { (await source.networkSnapshot)?.waitingReaders == 1 }
        try await server.appendResponseBody(Data(body.dropFirst(4096)), isFinal: true)
        let decoder = try await replacement.value
        #expect(decoder.sourceSeekable == true && decoder.sourceDurationMilliseconds == 30000)
        #expect(try await decoder.next()?.presentationTime == .zero)
        await decoder.cancel()
        #expect(server.requests.count == 1 && server.requests.allSatisfy { $0.headers["range"] == nil })
    }

    private func wait(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try await !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(try await condition())
    }
}
private final class RequiredID3Fixtures: NSObject {}
