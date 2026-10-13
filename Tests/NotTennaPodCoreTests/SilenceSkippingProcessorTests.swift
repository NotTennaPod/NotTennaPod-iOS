import Foundation
import Testing
@testable import NotTennaPodCore

struct SilenceSkippingProcessorTests {
    private struct Case: Decodable {
        let sampleRate, channels, chunkFrames, quietMs, quietAmplitude: Int
        let firstNoise, lastNoise, rightChannelNoise: Bool
        let inputFrames, outputFrames: Int
        let skippedFrames: Int64
        let outputSHA256, pattern: String
    }
    private struct Fixture: Decodable {
        let referenceCommit, media3Version: String
        let cases: [Case]
    }

    /// Skipped and played time match the original APK within 10 ms and nothing is lost apart from
    /// the skipped silence. (Output bytes are not hashed: sample-exact identity with Media3 is not
    /// something a listener can notice.)
    @Test func skippedTimeMatchesOriginalAPKWithoutLosingAudio() throws {
        let url = try #require(Bundle.module.url(forResource: "silence-processor-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.referenceCommit == "f8c641887e4677237b01b6e942ff8fe20fc8beec")
        #expect(fixture.media3Version == "1.10.0")
        #expect(fixture.cases.count == 234)
        for sample in fixture.cases {
            var processor = try SilenceSkippingProcessor(sampleRate: sample.sampleRate, channels: sample.channels)
            let firstFrames = sample.firstNoise ? sample.sampleRate / 20 : 0
            let quietFrames = sample.sampleRate * sample.quietMs / 1000
            let totalFrames = firstFrames + quietFrames + (sample.lastNoise ? sample.sampleRate / 20 : 0)
            #expect(totalFrames == sample.inputFrames)
            var input: [Int16] = []
            input.reserveCapacity(totalFrames * sample.channels)
            for frame in 0..<totalFrames {
                let noisy = frame < firstFrames || frame >= firstFrames + quietFrames
                for channel in 0..<sample.channels {
                    var amplitude = noisy || (sample.rightChannelNoise && channel == 1) ? 8192 : sample.quietAmplitude
                    if !noisy && ["varying-quiet", "bursts"].contains(sample.pattern) {
                        amplitude = (frame * 73 + channel * 19) % 1025
                        if sample.pattern == "bursts" && frame % 997 < 13 { amplitude += 2048 }
                    }
                    input.append(Int16(frame.isMultiple(of: 2) ? amplitude : -amplitude))
                }
            }
            var output: [Int16] = []
            for start in stride(from: 0, to: input.count, by: sample.chunkFrames * sample.channels) {
                let end = min(input.count, start + sample.chunkFrames * sample.channels)
                output.append(contentsOf: try processor.process(Array(input[start..<end])))
            }
            output.append(contentsOf: processor.finish())
            let context = "\(sample.sampleRate) Hz / \(sample.channels) ch / chunk \(sample.chunkFrames) / \(sample.pattern)"
            let tolerance = sample.sampleRate / 100 // 10 ms
            #expect(abs(output.count / sample.channels - sample.outputFrames) <= tolerance, Comment(rawValue: context))
            #expect(abs(processor.skippedFrames - sample.skippedFrames) <= Int64(tolerance), Comment(rawValue: context))
            // Every frame is either played or deliberately skipped.
            #expect(Int64(totalFrames) == Int64(output.count / sample.channels) + processor.skippedFrames)
        }
    }

    @Test func resetDiscardsBufferedAudioAndEndIsDrainedOnce() throws {
        var processor = try SilenceSkippingProcessor(sampleRate: 48_000, channels: 2)
        #expect(try processor.process(Array(repeating: 100, count: 40)).isEmpty)
        processor.reset()
        let noise: [Int16] = [.min, .max, 1025, -1025]
        #expect(try processor.process(noise) == noise)
        #expect(processor.finish().isEmpty)
        #expect(processor.finish().isEmpty)
        #expect(throws: SilenceSkippingProcessor.Failure.alreadyFinished) { try processor.process(noise) }
        processor.reset()
        #expect(try processor.process(Array(repeating: 100, count: 40)).isEmpty)
        #expect(processor.finish() == Array(repeating: 100, count: 40))
        #expect(processor.skippedFrames == 0)
    }

    @Test func malformedFramesDoNotMutateBufferedState() throws {
        var processor = try SilenceSkippingProcessor(sampleRate: 44_100, channels: 2)
        #expect(try processor.process([1, -1]).isEmpty)
        #expect(throws: SilenceSkippingProcessor.Failure.incompleteFrame) { try processor.process([10]) }
        #expect(processor.finish() == [1, -1])
        #expect(throws: SilenceSkippingProcessor.Failure.invalidFormat) { try SilenceSkippingProcessor(sampleRate: 0, channels: 2) }
        #expect(throws: SilenceSkippingProcessor.Failure.invalidFormat) { try SilenceSkippingProcessor(sampleRate: .max, channels: .max) }
        #expect(throws: SilenceSkippingProcessor.Failure.invalidFormat) { try SilenceSkippingProcessor(sampleRate: 48_000, channels: 0) }
    }
}
