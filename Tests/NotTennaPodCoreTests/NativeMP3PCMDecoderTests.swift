import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(1))) struct NativeMP3PCMDecoderTests {
    enum Fixture: String, CaseIterable {
        case unknown = "playback-unknown-duration", finite = "playback-30sec", stereo = "playback-vbr-stereo", lowRate = "playback-vbr-low-rate"
        var rate: Int32 { self == .lowRate ? 22050 : self == .stereo ? 48000 : 44100 }
        var channels: Int { self == .stereo ? 2 : 1 }
        var audioFrames: Int64 { self == .lowRate ? 15435 : self == .stereo ? 33600 : self == .finite ? 1_323_000 : 1_324_800 }
        var duration: Int64? { self == .lowRate ? 757 : self == .stereo ? 743 : self == .finite ? 30040 : nil }
    }
    private func fixture(_ kind: Fixture) -> URL {
        let name = kind.rawValue
#if SWIFT_PACKAGE
        return Bundle.module.url(forResource: name, withExtension: "mp3", subdirectory: "Fixtures")!
#else
        return Bundle(for: MP3DecoderFixtures.self).url(forResource: name, withExtension: "mp3")!
#endif
    }

    @Test(arguments: Fixture.allCases, [257, 4096])
    func chunkedStreamDecodesCompleteAudioAndSurvivesSlowNetwork(kind: Fixture, capacity: Int) throws {
        let url = fixture(kind)
        let input = try Data(contentsOf: url)
        let parser = try NativeMP3PacketParser()
        defer { parser.close() }
        var decoder: NativeMP3PCMDecoder?
        defer { decoder?.close() }
        var samples: [Int16] = []
        var seenDry = 0, seenPackets = 0
        func drain() throws -> Bool {
            let decoder = try #require(decoder)
            for _ in 0..<10000 {
                switch try decoder.next() {
                case let .audio(packet):
                    #expect(packet.presentationTime == CMTime(value: Int64(samples.count / kind.channels), timescale: kind.rate))
                    #expect(packet.sampleRate == kind.rate && packet.channels == kind.channels)
                    #expect(packet.frameCount > 0 && packet.frameCount <= capacity)
                    samples += packet.samples
                    seenPackets += 1
                case .needsInput:
                    let count = decoder.decodedFrames
                    // Repeated polls cannot flush decoder state or manufacture EOF.
                    for _ in 0..<3 {
                        if case .needsInput = try decoder.next() {} else { Issue.record("Dry input changed state") }
                    }
                    #expect(decoder.decodedFrames == count && !decoder.isEnded)
                    seenDry += 1
                    return false
                case .ended: return true
                }
            }
            Issue.record("Decoder failed to reach a bounded drain state")
            return false
        }
        func consume(_ batch: NativeMP3PacketParser.Batch) throws {
            if decoder == nil {
                decoder = try NativeMP3PCMDecoder(format: batch.format, timing: batch.timing, maximumOutputFrames: capacity)
            }
            try decoder!.accept(batch)
            #expect(try !drain())
        }
        // Uneven network fragments exercise partial packets and temporary dry input.
        for offset in stride(from: 0, to: input.count, by: 137) {
            for batch in try parser.append(input.subdata(in: offset..<min(offset + 137, input.count))) {
                try consume(batch)
            }
        }
        #expect(!samples.isEmpty && !decoder!.isEnded)
        for batch in try parser.finish() { try consume(batch) }
        try decoder!.finish()
        #expect(try drain())
        #expect(seenDry > 1 && seenPackets > 1)
        if let duration = kind.duration {
            #expect(abs((decoder!.timing.durationMilliseconds ?? 0) - duration) <= 100)
        } else { #expect(decoder!.timing.durationMilliseconds == nil) }
        if case .ended = try decoder!.next() {} else { Issue.record("EOF was not retained") }

        // Independent native file reader owns its own demuxing and gapless handling.
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var expected: [Int16] = []
        // This native file reader omits MPEG2 padding. Use independently source-
        // verified fixture fields, not the production decoder's metadata, for its
        // comparison window. The source is exactly0.7s at22050Hz.
        if kind == .lowRate { file.framePosition = 576 }
        let endFrame = kind == .lowRate ? Int64(576 + 15435) : file.length
        while file.framePosition < endFrame {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, endFrame - file.framePosition)))
            try #require(buffer.frameLength > 0)
            expected += UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * kind.channels)
        }
        #expect(AudibleMatch.matches(samples, expected, channels: kind.channels, sampleRate: Int(kind.rate)))
    }

    @Test(arguments: Fixture.allCases, [257, 4096])
    func midFileStartKeepsCorrectTimeAndAudio(kind: Fixture, capacity: Int) throws {
        try checkPositionedPackets(kind: kind, capacity: capacity, approximate: false)
    }

    @Test(arguments: Fixture.allCases, [257, 4096])
    func approximateMidFileStartKeepsCorrectAudio(kind: Fixture, capacity: Int) throws {
        try checkPositionedPackets(kind: kind, capacity: capacity, approximate: true)
    }

    @Test(arguments: Fixture.allCases, [257, 4096])
    func interruptedDownloadStillPlaysAllReceivedAudio(kind: Fixture, capacity: Int) throws {
        try checkPositionedPackets(kind: kind, capacity: capacity, approximate: true, interrupted: true)
    }

    private func checkPositionedPackets(kind: Fixture, capacity: Int, approximate: Bool, interrupted: Bool = false) throws {
        let url = fixture(kind), data = try Data(contentsOf: url)
        let parser = try NativeMP3PacketParser()
        defer { parser.close() }
        var batches: [NativeMP3PacketParser.Batch] = []
        for offset in stride(from: 0, to: data.count, by: 4096) {
            batches += try parser.append(data.subdata(in: offset..<min(offset + 4096, data.count)))
        }
        batches += try parser.finish()
        // Reconstruct individual packets from the independent native parser.
        // Start within the file, retaining enough preceding audio for reservoir
        // and synthesis history before comparing the entire remaining waveform.
        var packets: [NativeMP3PacketParser.Batch] = []
        for batch in batches {
            let basic = try #require(batch.format.audioStreamBasicDescription)
            var frame = batch.firstFrame
            for (index, description) in batch.descriptions.enumerated() {
                let count = Int64(description.mVariableFramesInPacket == 0 ? basic.mFramesPerPacket : description.mVariableFramesInPacket)
                let start = Int(description.mStartOffset), end = start + Int(description.mDataByteSize)
                var description = description; description.mStartOffset = 0
                packets.append(.init(bytes: batch.bytes.subdata(in: start..<end), descriptions: [description],
                    format: batch.format, firstFrame: frame, frameCount: count, timing: batch.timing,
                    rollDistances: batch.rollDistances.map { [$0[index]] }))
                frame += count
            }
        }
        let selected = Array(packets.dropFirst(4).dropLast(interrupted ? 2 : 0)), first = try #require(selected.first)
        let selectedEnd = try #require(selected.last).firstFrame + (try #require(selected.last).frameCount)
        let expectedAudioEnd = interrupted ? selectedEnd - (first.timing.primingFrameCount ?? 0) : kind.audioFrames
        let shift = approximate ? (capacity == 257 ? first.frameCount : -first.frameCount) : 0
        let origin = first.firstFrame - (first.timing.primingFrameCount ?? 0)
        let decoder = try NativeMP3PCMDecoder(format: first.format, timing: first.timing,
            maximumOutputFrames: capacity, firstFrame: first.firstFrame + shift,
            rangeOrigin: approximate ? CMTime(value: origin, timescale: kind.rate) : nil)
        defer { decoder.close() }
        var audio: [NativePCMDecoder.Packet] = []
        func consume() throws {
            while true {
                switch try decoder.next() {
                case .audio(let packet): audio.append(packet)
                case .needsInput, .ended: return
                }
            }
        }
        for packet in selected {
            let input = NativeMP3PacketParser.Batch(bytes: packet.bytes, descriptions: packet.descriptions,
                format: packet.format, firstFrame: packet.firstFrame + shift, frameCount: packet.frameCount,
                timing: packet.timing, rollDistances: packet.rollDistances)
            try decoder.accept(input); try consume()
        }
        try decoder.finish(afterSourceFailure: interrupted); try consume()
        #expect(decoder.isEnded)
        let target = try #require(packets.enumerated().first { index, packet in
            index > 4 && packet.rollDistances?.first.map { Int64(index) - $0 >= 4 } == true
        }?.element)
        let audibleFrame = target.firstFrame - (target.timing.primingFrameCount ?? 0)
        let audible = audio.filter { $0.presentationTime >= CMTime(value: audibleFrame, timescale: kind.rate) }
        let initial = try #require(audible.first)
        let start = CMTimeConvertScale(initial.presentationTime, timescale: kind.rate, method: .roundTowardZero).value
        let samples = audible.flatMap(\.samples)
        for pair in zip(audible, audible.dropFirst()) {
            #expect(pair.1.presentationTime == pair.0.presentationTime + CMTime(value: Int64(pair.0.frameCount), timescale: kind.rate))
        }
        let referenceURL: URL
        if interrupted {
            let metadataBytes = data.count - packets.reduce(0) { $0 + $1.bytes.count }
            let through = packets.count - 2
            let bytes = metadataBytes + packets.prefix(through).reduce(0) { $0 + $1.bytes.count }
            referenceURL = FileManager.default.temporaryDirectory.appendingPathComponent("mp3-interruption-\(UUID()).mp3")
            try Data(data.prefix(bytes)).write(to: referenceURL)
        } else { referenceURL = url }
        defer { if interrupted { try? FileManager.default.removeItem(at: referenceURL) } }
        let file = try AVAudioFile(forReading: referenceURL, commonFormat: .pcmFormatInt16, interleaved: true)
        // Decode the reference sequentially before slicing. AVAudioFile's own
        // compressed random seek is not an independent full-history oracle.
        let end = kind == .lowRate ? 576 + expectedAudioEnd : expectedAudioEnd
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var expected: [Int16] = []
        while file.framePosition < end {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, end - file.framePosition)))
            try #require(buffer.frameLength > 0)
            expected += Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * kind.channels))
        }
        expected = Array(expected.dropFirst(Int(start + (kind == .lowRate ? 576 : 0)) * kind.channels))
        // Same length (nothing lost at the end) and same sound as the file from that time.
        #expect(AudibleMatch.matches(samples, expected, channels: kind.channels, sampleRate: Int(kind.rate)),
            "\(kind) capacity=\(capacity): actual=\(samples.count) expected=\(expected.count)")
    }

    @Test func truncatedDeclaredStreamDoesNotReportSuccessfulEOF() throws {
        let parser = try NativeMP3PacketParser()
        defer { parser.close() }
        let batches = try parser.append(Data(contentsOf: fixture(.finite)).prefix(4096))
        let first = try #require(batches.first)
        let decoder = try NativeMP3PCMDecoder(format: first.format, timing: first.timing)
        defer { decoder.close() }
        for batch in batches {
            try decoder.accept(batch)
            while !decoder.needsInput { _ = try decoder.next() }
        }
        try decoder.finish()
        #expect(throws: NativeMP3PCMDecoder.Failure.incompleteStream) {
            while !decoder.isEnded { _ = try decoder.next() }
        }
        #expect(!decoder.isEnded)
        #expect(throws: NativeMP3PCMDecoder.Failure.incompleteStream) { try decoder.next() }
    }
}
private final class MP3DecoderFixtures: NSObject {}
