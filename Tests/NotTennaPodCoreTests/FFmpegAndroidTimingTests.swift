import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

/// Expectations from actual pinned Media3 + Android API 36 decoder execution, compared by what a
/// listener notices: audio after a seek starts within 0.25 s of where Android starts and the amount
/// that plays is within 50 ms of Android's.
struct FFmpegAndroidTimingTests {
    private struct Expected: Decodable {
        let file: String
        let startMs: Int64
        let firstPTSUs: Int64?
        let frames: Int64
    }
    @Test(arguments: FFmpegAudioReaderTests.names, [Int64(0), 3883, 4000, 7990])
    func admittedTimelineAndFrameCountMatchAndroid(name: String, startMs: Int64) async throws {
        let evidence = try #require(Bundle.module.url(forResource: "android-codec-timing", withExtension: "json", subdirectory: "Fixtures"))
        let entries = try JSONDecoder().decode([Expected].self, from: Data(contentsOf: evidence))
        let expected = try #require(entries.first { $0.file == name && $0.startMs == startMs })
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
        // The app's own route for these containers (PCMPlaybackFactory → FFmpegPlaybackSource).
        let source = try FFmpegPlaybackSource(url: url, maximumFrames: 65_536)
        let decoder = try await source.makeDecoder(start: CMTime(value: startMs, timescale: 1000))
        var audio = AudibleAudio()
        while let packet = try await decoder.next() { audio.add(packet) }
        await decoder.cancel()
        FFmpegBufferedSeekReferenceTests.expectComplete(audio, expectedFrames: Int(expected.frames), sampleRate: 48_000,
            target: expected.firstPTSUs ?? startMs * 1000, referenceRMS: nil, "\(name) seek \(startMs) ms")
    }
}
