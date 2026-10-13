import Foundation
import Testing
@testable import NotTennaPodCore

/// Changing playback speed must not change voice pitch (no "chipmunk" or slowed-down
/// voice), as with Android's Sonic processing. Exercises the app's own speed processor.
@Suite struct NativeTimePitchTests {
    @Test(arguments: [Float(0.5), 0.8, 1.25, 1.5, 2, 3, 4])
    func speedChangeKeepsTonePitchAndScalesDuration(speed: Float) throws {
        let rate = 48_000, frames = 192_000
        let input = (0..<frames).map { Int16(8192 * sin(2 * Double.pi * 440 * Double($0) / Double(rate))) }
        var processor = try PCMSpeedProcessor(sampleRate: rate, channels: 1, speed: speed)
        var output: [Int16] = []
        for start in stride(from: 0, to: frames, by: 4096) {
            output += try processor.process(Array(input[start..<min(frames, start + 4096)]))
        }
        output += processor.finish()
        let intended = Double(frames) / Double(speed)
        #expect(abs(Double(output.count) - intended) <= max(intended * 0.03, 960), "speed \(speed): \(output.count) frames")
        // Ignore the first/last 100 ms; count rising zero crossings of the 440 Hz tone.
        let start = 4800, end = output.count - 4800
        try #require(end > start + 9600)
        let crossings = ((start + 1)..<end).filter { output[$0 - 1] <= 0 && output[$0] > 0 }.count
        let measured = Double(crossings) * Double(rate) / Double(end - start)
        #expect(abs(measured - 440) <= 5, "speed \(speed): measured \(measured) Hz")
    }
}
