import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct NativePCMFileEndTests {
    private func fixture(_ name: String) throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: "mp3", subdirectory: "Fixtures"))
#else
        try #require(Bundle(for: PCMFileEndFixtures.self).url(forResource: name, withExtension: "mp3"))
#endif
    }
    @Test(arguments: ["playback-indexed-vbri-3", "playback-indexed-vbri-9"],
          // Whole file, 0.1 s before the end, the native estimated length, the real end and
          // beyond it. Single-sample neighbours of these points (1, 1_439_999, 1_440_576,
          // 1_441_151, 1_441_153) were removed: the check is audible
          // (50 ms), so they could not distinguish anything a listener hears.
          [Int64(0), 1_435_903, 1_440_000, 1_441_152, 2_000_000])
    func vbriFileSeeksNearEndPlayRemainingAudio(name: String, start: Int64) async throws {
        let url = try fixture(name)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var baseline: [Int16] = []
        // Full-capacity reads independently preserve all1251 inventoried MPEG
        // frames. The final read crosses the native estimated1440000-frame length.
        while file.framePosition < file.length {
            try file.read(into: buffer)
            baseline += Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * 2))
        }
        try #require(baseline.count == 1251 * 1152 * 2)
        let decoder = try NativePCMDecoder(url: url, start: CMTime(value: start, timescale: 48000))
        var actual: [Int16] = [], first: Int64?
        while let packet = try await decoder.next() {
            #expect(packet.sampleRate == 48000 && packet.channels == 2)
            let origin = first ?? CMTimeConvertScale(packet.presentationTime, timescale: 48000, method: .roundTowardZero).value
            first = origin
            #expect(packet.presentationTime == CMTime(value: origin + Int64(actual.count / 2), timescale: 48000))
            actual += packet.samples
        }
        let total = Int64(baseline.count / 2)
        if let first { #expect(abs(first - min(start, total)) <= 12000, "start \(first) for target \(start)") }
        // The whole remaining episode plays: nothing lost at the end (within 50 ms).
        let expected = Array(baseline.dropFirst(Int(min(first ?? start, total)) * 2))
        #expect(AudibleMatch.matches(actual, expected, channels: 2, sampleRate: 48000),
            "decoded \(actual.count / 2) frames; expected \(expected.count / 2) from frame \(start)")
        #expect(try await decoder.next() == nil)
        await decoder.cancel()
    }

    @Test(arguments: [0, 4096, 8192])
    func exactBufferBoundaryPCMEndsWithoutReplaying(start: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pcm-end-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("exact.wav")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true))
        let samples = (0..<8192).map { Int16(($0 % 1000) - 500) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192))
            buffer.frameLength = 8192
            for index in samples.indices { buffer.int16ChannelData![0][index] = samples[index] }
            try file.write(from: buffer)
        }
        let decoder = try NativePCMDecoder(url: url, start: CMTime(value: Int64(start), timescale: 48000))
        var actual: [Int16] = []
        while let packet = try await decoder.next() { actual += packet.samples; #expect(packet.frameCount <= 4096) }
        #expect(actual == Array(samples.dropFirst(start)))
        #expect(try await decoder.next() == nil)
        await decoder.cancel()
    }
}
private final class PCMFileEndFixtures: NSObject {}

// Complete local-format output and seek tails: lossless formats exact, lossy
// formats must sound the same (AudibleMatch); seeks land within 0.25 s.
@Suite(.serialized) struct NativePCMFormatContinuityTests {
    @Test(arguments: ["tone.wav", "tone.m4a", "tone-tail.m4a", "tone.aac", "tone.flac"], ["zero", "sample", "tail", "end", "beyond"])
    func localFormatsPlayCompleteAudioAndSeekTails(name: String, point: String) async throws {
#if SWIFT_PACKAGE
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
#else
        let url = try #require(Bundle(for: PCMFileEndFixtures.self).url(forResource: name, withExtension: nil))
#endif
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        let channels = Int(file.processingFormat.channelCount), rate = Int32(file.processingFormat.sampleRate)
        var baseline: [Int16] = []
        while file.framePosition < file.length {
            // Preserve the original explicit-read conversion. The overload
            // without frameCount rounds some AAC samples differently.
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, file.length - file.framePosition)))
            try #require(buffer.frameLength > 0)
            baseline += Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * channels))
        }
        let total = Int64(baseline.count / channels)
        try #require(total > 157)
        let start: Int64 = switch point { case "sample": 123; case "tail": total - 157; case "end": total; case "beyond": total + 20_000; default: 0 }
        let decoder = try NativePCMDecoder(url: url, start: CMTime(value: start, timescale: rate))
        var actual: [Int16] = [], first: Int64?
        while let packet = try await decoder.next() {
            #expect(packet.channels == channels && packet.sampleRate == Int(rate))
            let origin = first ?? CMTimeConvertScale(packet.presentationTime, timescale: rate, method: .roundTowardZero).value
            first = origin
            #expect(packet.presentationTime == CMTime(value: origin + Int64(actual.count / channels), timescale: rate))
            actual += packet.samples
        }
        if let first { #expect(abs(first - min(start, total)) <= Int64(rate / 4)) }
        let expected = Array(baseline.dropFirst(Int(min(first ?? start, total)) * channels))
        let lossless = name.hasSuffix("wav") || name.hasSuffix("flac")
        #expect(lossless ? actual == expected : AudibleMatch.matches(actual, expected, channels: channels, sampleRate: Int(rate)),
            "\(name) from \(start): output differs")
        #expect(try await decoder.next() == nil)
        await decoder.cancel()
    }

}
