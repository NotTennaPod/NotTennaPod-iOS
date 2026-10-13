import AVFoundation
import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct NativeMP3PacketParserTests {
    private var fixture: URL {
        fixture(named: "playback-unknown-duration")
    }
    private func fixture(named name: String) -> URL {
#if SWIFT_PACKAGE
        Bundle.module.url(forResource: name, withExtension: "mp3", subdirectory: "Fixtures")!
#else
        Bundle(for: MP3ParserFixtures.self).url(forResource: name, withExtension: "mp3")!
#endif
    }

    @Test(arguments: [1, 4, 137, 4096])
    func infoHeaderGivesDurationAndEveryPacketSurvivesChunking(chunk: Int) throws {
        var data = try Data(contentsOf: fixture(named: "playback-30sec"))
        data.replaceSubrange(21..<25, with: Data("Info".utf8))
        let parser = try NativeMP3PacketParser(); defer { parser.close() }
        var batches: [NativeMP3PacketParser.Batch] = []
        for offset in stride(from: 0, to: data.count, by: chunk) {
            batches += try parser.append(data.subdata(in: offset..<min(offset + chunk, data.count)))
        }
        batches += try parser.finish()
        let timing = try #require(parser.timing)
        #expect(abs((timing.durationMilliseconds ?? 0) - 30_040) <= 100)
        #expect(batches.reduce(0) { $0 + $1.descriptions.count } == 1150)
        let packets = batches.flatMap { batch in batch.descriptions.map {
            batch.bytes.subdata(in: Int($0.mStartOffset)..<(Int($0.mStartOffset) + Int($0.mDataByteSize)))
        }}
        #expect(packets.reduce(into: Data()) { $0.append($1) } == Data(data.dropFirst(417)))
    }

    @Test(arguments: [false, true], [1, 4, 137, 4096])
    func headerDurationIsKnownEarlyAndNotInventedWithoutHeader(hasHeader: Bool, chunkSize: Int) throws {
        let data = try Data(contentsOf: fixture(named: hasHeader ? "playback-30sec" : "playback-unknown-duration"))
        let parser = try NativeMP3PacketParser()
        defer { parser.close() }
        var initial: [NativeMP3PacketParser.Batch] = []
        for offset in stride(from: 0, to: 4096, by: chunkSize) {
            initial += try parser.append(data.subdata(in: offset..<min(offset + chunkSize, 4096)))
        }
        try #require(!initial.isEmpty)
        let timing = try #require(parser.timing)
        // Within the first 4 KiB: the header's duration, or none at all.
        if hasHeader { #expect(abs((timing.durationMilliseconds ?? 0) - 30_040) <= 100) }
        else { #expect(timing.durationMilliseconds == nil) }
        var packets = initial.reduce(0) { $0 + $1.descriptions.count }
        for offset in stride(from: 4096, to: data.count, by: 4096) {
            let batches = try parser.append(data.subdata(in: offset..<min(offset + 4096, data.count)))
            packets += batches.reduce(0) { $0 + $1.descriptions.count }
        }
        packets += try parser.finish().reduce(0) { $0 + $1.descriptions.count }
        #expect(packets == 1150)
        // EOF and a complete observed file do not manufacture a declared timeline.
        #expect(parser.timing == timing)
    }

    @Test(arguments: [0, 2010, 16384], [1, 137])
    func id3TaggedLowRateFileKeepsAllAudioAndDuration(tagSize: Int, chunkSize: Int) throws {
        let audio = try Data(contentsOf: fixture(named: "playback-vbr-low-rate"))
        var input = Data()
        if tagSize > 0 {
            input = Data([0x49, 0x44, 0x33, 4, 0, 0,
                UInt8((tagSize >> 21) & 127), UInt8((tagSize >> 14) & 127),
                UInt8((tagSize >> 7) & 127), UInt8(tagSize & 127)])
            input.append(Data(repeating: 0, count: tagSize))
        }
        input.append(audio)
        let parser = try NativeMP3PacketParser()
        defer { parser.close() }
        var packets = 0
        for offset in stride(from: 0, to: input.count, by: chunkSize) {
            let batches = try parser.append(input.subdata(in: offset..<min(offset + chunkSize, input.count)))
            for batch in batches { packets += batch.descriptions.count }
        }
        for batch in try parser.finish() { packets += batch.descriptions.count }
        #expect(packets == 29)
        #expect(abs((parser.timing?.durationMilliseconds ?? 0) - 757) <= 100)
    }

    @Test(arguments: [1, 2, 3, 7, 137, 4096, 32_768])
    func fragmentationPreservesEveryPacketAndContinuousTimestamps(chunkSize: Int) throws {
        let input = try Data(contentsOf: fixture)
        let parser = try NativeMP3PacketParser()
        defer { parser.close() }
        var payload = Data(), frames: Int64 = 0, packets = 0
        var allBatches: [NativeMP3PacketParser.Batch] = []
        for offset in stride(from: 0, to: input.count, by: chunkSize) {
            allBatches += try parser.append(input.subdata(in: offset..<min(input.count, offset + chunkSize)))
        }
        #expect(try parser.append(Data()).isEmpty)
        allBatches += try parser.finish()
        for batch in allBatches {
            #expect(batch.firstFrame == frames)
            let format = try #require(batch.format.audioStreamBasicDescription)
            #expect(format.mSampleRate == 44100 && format.mChannelsPerFrame == 1)
            for packet in batch.descriptions {
                let start = Int(packet.mStartOffset)
                payload.append(batch.bytes.subdata(in: start..<(start + Int(packet.mDataByteSize))))
                packets += 1
            }
            frames += batch.frameCount
        }
        // Independently measured encoded fixture: 1150 MP3 frames, 1152 samples each.
        #expect(packets == 1150 && frames == 1_324_800)
        #expect(payload == input)
        #expect(parser.parsedFrames == frames)
        #expect(throws: NativeMP3PacketParser.Failure.closed) { try parser.append(Data()) }
    }

    @Test func shortStreamFlushesStartupLookaheadOnlyAtActualEOF() throws {
        let input = Data(try Data(contentsOf: fixture).prefix(520)) // Five complete MP3 packets.
        let parser = try NativeMP3PacketParser()
        defer { parser.close() }
        #expect(try parser.append(input).isEmpty)
        #expect(parser.timing == nil && parser.parsedFrames == 0)
        #expect(try parser.append(Data()).isEmpty)
        let final = try parser.finish()
        #expect(final.reduce(0) { $0 + $1.descriptions.count } == 5)
        #expect(parser.parsedFrames == 5760 && parser.timing?.durationMilliseconds == nil)
        let bytes = final.reduce(into: Data()) { result, batch in
            for packet in batch.descriptions {
                let start = Int(packet.mStartOffset)
                result.append(batch.bytes.subdata(in: start..<(start + Int(packet.mDataByteSize))))
            }
        }
        #expect(bytes == input)
    }

}

private final class MP3ParserFixtures: NSObject {}
