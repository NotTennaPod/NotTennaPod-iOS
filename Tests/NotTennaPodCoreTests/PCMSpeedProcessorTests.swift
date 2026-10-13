import Foundation
import Testing
@testable import NotTennaPodCore

struct PCMSpeedProcessorTests {
    private struct Case: Decodable {
        let sampleRate, channels, step, chunkFrames, inputFrames, pattern: Int
    }
    private struct Oracle: Decodable { let cases: [Case] }

    private func sample(frame: Int, channel: Int, pattern: Int) -> Int16 {
        if pattern == 1 { return 0 }
        if pattern == 2 { return (frame + channel).isMultiple(of: 2) ? .min : .max }
        if pattern == 3 { return Int16((frame * 73 + channel * 19) % 65536 - 32768) }
        if (2500..<3300).contains(frame % 4000) { return 0 }
        let period = channel == 0 ? 109 : 173
        let phase = frame % period
        return Int16((phase < period / 2 ? phase : period - phase) * 48000 / period - 12000)
    }

    /// Every slider speed (0.5x...4x) across rates, channel counts, chunk sizes and signal
    /// shapes: the processed audio lasts input duration / speed (media time vs wall time),
    /// is not silenced, and nothing is held back after the stream ends. The inputs come from
    /// the recorded Media3 case list; its sample hashes are deliberately not compared.
    @Test func everySpeedPlaysForInputDurationDividedBySpeed() throws {
        let url = try #require(Bundle.module.url(forResource: "speed-processor-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
        #expect(!oracle.cases.isEmpty)
        for entry in oracle.cases {
            let speed = Float(entry.step + 10) / 20
            var processor = try PCMSpeedProcessor(sampleRate: entry.sampleRate, channels: entry.channels, speed: speed)
            var samples: [Int16] = []
            for start in stride(from: 0, to: entry.inputFrames, by: entry.chunkFrames) {
                var input: [Int16] = []
                for frame in start..<min(entry.inputFrames, start + entry.chunkFrames) {
                    for channel in 0..<entry.channels {
                        input.append(sample(frame: frame, channel: channel, pattern: entry.pattern))
                    }
                }
                samples += try processor.process(input)
            }
            samples += processor.finish()
            let context = Comment(rawValue: "\(entry.sampleRate)Hz / \(entry.channels)ch / \(speed)x / \(entry.inputFrames)frames / chunk\(entry.chunkFrames) / pattern\(entry.pattern)")
            let outputMilliseconds = Double(samples.count / entry.channels) * 1000 / Double(entry.sampleRate)
            let expectedMilliseconds = Double(entry.inputFrames) / Double(speed) * 1000 / Double(entry.sampleRate)
            #expect(abs(outputMilliseconds - expectedMilliseconds) <= 20, context)
            if entry.pattern != 1 && entry.inputFrames >= entry.sampleRate / 10 {
                #expect(samples.contains { $0 != 0 }, context)
            }
            #expect(processor.pendingInputFrames == 0 && processor.finish().isEmpty, context)
        }
    }
}
