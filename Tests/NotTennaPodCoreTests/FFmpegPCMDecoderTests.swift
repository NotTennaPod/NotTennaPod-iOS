import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite
struct FFmpegPCMDecoderTests {
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
    }

    @Test(arguments: FFmpegAudioReaderTests.names, [127, 4096])
    func wholePipelinePlaysCompleteContiguousAudio(name: String, capacity: Int) async throws {
        let decoder = try await FFmpegPCMDecoder.open(url: fixture(name), maximumFrames: capacity)
        let stream = try LocalPCMPlaybackStream(decoder: decoder, skipSilence: false, maximumOutputFrames: capacity)
        let segment = await stream.segment
        var frames: Int64 = 0, peak = 0
        while let packet = try await stream.nextPacket() {
            #expect(packet.segment.id == segment.id)
            #expect(packet.outputStartFrame == frames) // Contiguous output: nothing skipped or repeated.
            #expect(packet.samples.count <= capacity * decoder.channels)
            peak = max(peak, packet.samples.map { abs(Int($0)) }.max() ?? 0)
            frames += Int64(packet.samples.count / decoder.channels)
        }
        // About eight seconds of audible tone (Opus keeps its real tail samples), within 50 ms.
        let expected: Int64 = name == "tone-vorbis.ogg" ? 384_000 : 384_648
        #expect(abs(frames - expected) <= 2400 && peak > 1000)
        #expect(segment.mediaStartMicroseconds == 0)
    }

    @Test(arguments: FFmpegAudioReaderTests.names)
    func seekedDecoderStartsNearTargetAndPlaysContiguously(name: String) async throws {
        let url = try fixture(name)
        let target = CMTime(value: 4, timescale: 1)
        let decoder = try await FFmpegPCMDecoder.open(url: url, start: target, maximumFrames: 127)
        #expect(abs(decoder.startTime.seconds - 4) <= 0.25)
        var audio = AudibleAudio()
        for _ in 0..<64 { audio.add(try #require(await decoder.next())) }
        #expect(abs(Double(audio.starts.first ?? 0) / 1_000_000 - decoder.startTime.seconds) <= 0.01)
        #expect(audio.largestGap <= 10_000 && audio.peak > 1000)
        await decoder.cancel()
        await #expect(throws: FFmpegPCMDecoder.Failure.cancelled) { try await decoder.next() }
    }

    @Test func cancelRetiresPreparedFirstChunkAndCancellationDoesNotResurrectEOF() async throws {
        let url = try fixture("tone-opus.webm")
        let decoder = try await FFmpegPCMDecoder.open(url: url)
        await decoder.cancel()
        await #expect(throws: FFmpegPCMDecoder.Failure.cancelled) { try await decoder.next() }
        let ended = try await FFmpegPCMDecoder.open(url: fixture("tone-vorbis.ogg"), start: CMTime(value: 799, timescale: 100))
        #expect(try await ended.next() == nil)
        #expect(ended.startTime == CMTime(value: 799, timescale: 100))
        await ended.cancel()
        await #expect(throws: FFmpegPCMDecoder.Failure.cancelled) { try await ended.next() }
    }

    @Test func taskCancellationBeforePreparationAndAfterPreparationIsTerminal() async throws {
        let url = try fixture("tone-opus.ogg")
        let opening = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FFmpegPCMDecoder.open(url: url)
        }
        await #expect(throws: CancellationError.self) { try await opening.value }
        let decoder = try await FFmpegPCMDecoder.open(url: url)
        let pulling = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await decoder.next()
        }
        await #expect(throws: CancellationError.self) { try await pulling.value }
        await #expect(throws: FFmpegPCMDecoder.Failure.cancelled) { try await decoder.next() }
    }
}
