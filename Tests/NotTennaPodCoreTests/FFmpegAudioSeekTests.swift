import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.timeLimit(.minutes(2)))
struct FFmpegAudioSeekTests {
    private struct NativeFrames: Decodable {
        struct Frame: Decodable { let pts: Int64; let samples: Int }
        let name: String
        let rate: Int
        let timeBaseNumerator: Int64
        let timeBaseDenominator: Int32
        let frames: [Frame]
        func time(_ frame: Frame) -> CMTime {
            CMTime(value: frame.pts * timeBaseNumerator, timescale: timeBaseDenominator)
        }
    }
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
    }
    private func baseline(_ name: String) throws -> NativeFrames {
        let url = try #require(Bundle.module.url(forResource: "codec-seek-native-frames", withExtension: "json", subdirectory: "Fixtures"))
        return try #require(JSONDecoder().decode([NativeFrames].self, from: Data(contentsOf: url)).first { $0.name == name })
    }

    @Test(arguments: FFmpegAudioReaderTests.names)
    func seeksLandNearTargetPlayTheRestAndClearOldOutput(name: String) async throws {
        let native = try baseline(name)
        let reader = try FFmpegAudioReader(url: fixture(name), maximumFrames: 127)
        _ = try await reader.next() // Leave an old partially delivered frame staged.
        // Forward, backward, beginning, sub-frame and end-of-media requests.
        for targetUs: Int64 in [4_000_000, 3_883_000, 0, 1, 7_990_000, 0] {
            let target = CMTime(value: targetUs, timescale: 1_000_000)
            let expected = native.frames.filter { native.time($0) >= target }
            try await reader.seek(to: target)
            var audio = AudibleAudio()
            while let chunk = try await reader.next() { audio.add(chunk) }
            // Starts within 0.25 s of the request (so no stale pre-seek audio) and the rest plays.
            FFmpegBufferedSeekReferenceTests.expectComplete(audio, expectedFrames: expected.reduce(0) { $0 + $1.samples },
                sampleRate: native.rate, target: targetUs, referenceRMS: nil, "\(name), target \(targetUs)")
            #expect(await reader.status == .ended)
        }
    }

    @Test func invalidSeekDoesNotDiscardPendingAudio() async throws {
        let url = try fixture("tone-opus.ogg")
        let reader = try FFmpegAudioReader(url: url, maximumFrames: 1)
        let control = try FFmpegAudioReader(url: url, maximumFrames: 1)
        _ = try await reader.next()
        _ = try await control.next()
        for target in [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity,
                       CMTime(value: -1, timescale: 1000), CMTime(value: Int64.max, timescale: 1)] {
            await #expect(throws: FFmpegAudioReader.Failure.invalidSeek) { try await reader.seek(to: target) }
        }
        let actual = try #require(try await reader.next())
        let expected = try #require(try await control.next())
        #expect(actual.presentationTime == expected.presentationTime)
        #expect(actual.samples == expected.samples)
        await reader.cancel()
        await control.cancel()
    }

    @Test func cancellationPreventsSeekResurrection() async throws {
        let reader = try FFmpegAudioReader(url: fixture("tone-opus.webm"))
        await reader.cancel()
        await #expect(throws: FFmpegAudioReader.Failure.cancelled) { try await reader.seek(to: .zero) }
        #expect(await reader.status == .cancelled)
    }
}
