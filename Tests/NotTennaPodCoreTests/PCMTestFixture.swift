import Foundation
import Testing

enum PCMTestFixture {
    static func waveFixture(channels: Int = 2, frames: Int = 28_800) throws -> (URL, [Int16]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("quiet.wav")
        let samples = (0..<frames).flatMap { frame -> [Int16] in
            let amplitude = frame < 2400 || frame >= frames - 2400 ? 8192 : 256
            return Array(repeating: Int16(frame.isMultiple(of: 2) ? amplitude : -amplitude), count: channels)
        }
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: Int) { data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8)) }
        func u32(_ value: Int) { u16(value); u16(value >> 16) }
        text("RIFF"); u32(36 + samples.count * 2); text("WAVEfmt "); u32(16)
        u16(1); u16(channels); u32(48_000); u32(48_000 * channels * 2); u16(channels * 2); u16(16)
        text("data"); u32(samples.count * 2)
        for sample in samples { u16(Int(UInt16(bitPattern: sample))) }
        try data.write(to: url)
        return (url, samples)
    }

    /// Interleaved native-endian Int16 PCM contained in `data`.
    static func samples(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { raw in
            (0..<(raw.count / 2)).map { raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self) }
        }
    }

    /// Listener-level equivalence of two interleaved Int16 renderings: the same duration
    /// (within `durationToleranceMilliseconds`), the same overall loudness, and the same
    /// loudness envelope in 50 ms windows (so dropped, duplicated or silent stretches and
    /// wrong gain are caught). Sample-exact identity is deliberately not required.
    static func expectAudiblyEquivalent(_ actual: Data, _ expected: Data, channels: Int = 2, sampleRate: Int = 48_000,
                                        durationToleranceMilliseconds: Double = 50, levelToleranceDecibels: Double = 1,
                                        sourceLocation: SourceLocation = #_sourceLocation) {
        expectAudiblyEquivalent(samples(actual), samples(expected), channels: channels, sampleRate: sampleRate,
            durationToleranceMilliseconds: durationToleranceMilliseconds, levelToleranceDecibels: levelToleranceDecibels,
            sourceLocation: sourceLocation)
    }

    static func expectAudiblyEquivalent(_ actual: [Int16], _ expected: [Int16], channels: Int = 2, sampleRate: Int = 48_000,
                                        durationToleranceMilliseconds: Double = 50, levelToleranceDecibels: Double = 1,
                                        sourceLocation: SourceLocation = #_sourceLocation) {
        expectAudibleDuration(actual, expectedFrames: expected.count / channels, channels: channels, sampleRate: sampleRate,
            toleranceMilliseconds: durationToleranceMilliseconds, requireSound: level(expected[...]) > silenceFloor,
            sourceLocation: sourceLocation)
        let actualLevel = level(actual[...]), expectedLevel = level(expected[...])
        #expect(abs(actualLevel - expectedLevel) <= levelToleranceDecibels,
                "overall level \(actualLevel) dBFS vs \(expectedLevel) dBFS", sourceLocation: sourceLocation)
        let window = max(1, sampleRate / 20) * channels
        func envelope(_ values: [Int16]) -> [Double] {
            stride(from: 0, to: values.count - window + 1, by: window).map { level(values[$0..<($0 + window)]) }
        }
        let a = envelope(actual), e = envelope(expected)
        for index in 0..<min(a.count, e.count) {
            // A window may straddle a loud/quiet boundary that moved by a few milliseconds.
            let neighbours = e[max(0, index - 1)...min(e.count - 1, index + 1)]
            let lower = neighbours.min()! - 2 * levelToleranceDecibels
            let upper = neighbours.max()! + 2 * levelToleranceDecibels
            if !(lower...upper).contains(a[index]) {
                Issue.record("50 ms window \(index) is \(a[index]) dBFS; expected \(lower)...\(upper) dBFS",
                             sourceLocation: sourceLocation)
                return
            }
        }
    }

    /// Duration within tolerance of `expectedFrames` and, when `requireSound`, not silent.
    static func expectAudibleDuration(_ actual: [Int16], expectedFrames: Int, channels: Int, sampleRate: Int,
                                      toleranceMilliseconds: Double = 50, requireSound: Bool = true,
                                      sourceLocation: SourceLocation = #_sourceLocation) {
        let actualMilliseconds = Double(actual.count / channels) * 1000 / Double(sampleRate)
        let expectedMilliseconds = Double(expectedFrames) * 1000 / Double(sampleRate)
        #expect(abs(actualMilliseconds - expectedMilliseconds) <= toleranceMilliseconds,
                "duration \(actualMilliseconds) ms vs \(expectedMilliseconds) ms", sourceLocation: sourceLocation)
        if requireSound { #expect(level(actual[...]) > silenceFloor, "output is silent", sourceLocation: sourceLocation) }
    }

    /// Overall RMS level in dBFS (floored at -80 dBFS for silence).
    static func levelDecibels(_ values: [Int16]) -> Double { level(values[...]) }

    private static let silenceFloor = -80.0
    private static func level(_ values: ArraySlice<Int16>) -> Double {
        guard !values.isEmpty else { return silenceFloor }
        var sum = 0.0
        for value in values { let x = Double(value) / 32768; sum += x * x }
        return max(silenceFloor, 10 * log10(sum / Double(values.count) + 1e-12))
    }
}
