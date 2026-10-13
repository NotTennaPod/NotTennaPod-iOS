import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct NativePCMDecoderTests {
    private func fixture(_ name: String, fileExtension suffix: String) throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: suffix, subdirectory: "Fixtures"))
#else
        try #require(Bundle(for: NativeDecoderFixtures.self).url(forResource: name, withExtension: suffix))
#endif
    }

    @Test(arguments: [1, 2]) func decodedWaveIsExactAndSkipSilenceSkipsLikeAndroid(channels: Int) async throws {
        let (url, input) = try PCMTestFixture.waveFixture(channels: channels)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let decoder = try NativePCMDecoder(url: url)
        var decoded: [Int16] = []
        var processed: [Int16] = []
        var processor = try SilenceSkippingProcessor(sampleRate: 48_000, channels: channels)
        var packetCount = 0
        while let packet = try await decoder.next() {
            #expect(packet.sampleRate == 48_000 && packet.channels == channels)
            #expect(packet.presentationTime == CMTime(value: Int64(decoded.count / channels), timescale: 48_000))
            decoded.append(contentsOf: packet.samples)
            processed.append(contentsOf: try processor.process(packet.samples))
            packetCount += 1
        }
        processed.append(contentsOf: processor.finish())
        #expect(decoded == input)
        #expect(packetCount > 1)
        #expect(try await decoder.next() == nil)
        struct Case: Decodable { let sampleRate, channels, outputFrames: Int; let pattern, outputSHA256: String; let skippedFrames: Int64 }
        struct Fixture: Decodable { let cases: [Case] }
        let fixtureURL = try self.fixture("silence-processor-oracle", fileExtension: "json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        let reference = try #require(fixture.cases.first { $0.sampleRate == 48_000 && $0.channels == channels && $0.pattern == "retained" })
        // Same amount of silence removed as Android's processor, within 50 ms.
        #expect(abs(processed.count / channels - reference.outputFrames) <= 2400)
        #expect(abs(processor.skippedFrames - reference.skippedFrames) <= 2400)
    }

    @Test func startPositionPlaysFromThereAndCancellationStopsReading() async throws {
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let decoder = try NativePCMDecoder(url: url, start: CMTime(value: 123, timescale: 1000))
        let first = try #require(try await decoder.next())
        #expect(abs(first.presentationTime.seconds - 0.123) <= 0.25)
        let frame = Int(CMTimeConvertScale(first.presentationTime, timescale: 48_000, method: .roundTowardZero).value)
        #expect(first.samples == Array(input[(frame * 2)..<(frame * 2 + first.samples.count)]))
        await decoder.cancel()
        await #expect(throws: NativePCMDecoder.Failure.cancelled) { try await decoder.next() }
    }

    @Test(arguments: [1, 123, 999, 1000, 1001, 3883, 15001, 29950])
    func downloadedMediaExtensionDecodesAndSeeksNearTarget(milliseconds: Int64) async throws {
        let source = try fixture("playback-30sec", fileExtension: "mp3")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("download.media")
        try FileManager.default.copyItem(at: source, to: url)
        let decoder = try NativePCMDecoder(url: url, start: CMTime(value: milliseconds, timescale: 1000))
        let packet = try #require(try await decoder.next())
        #expect(packet.frameCount > 0)
        let target = CMTime(value: milliseconds, timescale: 1000)
        #expect(abs(packet.presentationTime.seconds - target.seconds) <= 0.25)
        // Compare the remaining audio with an unseeked decode from the actual start.
        let selected = CMTimeConvertScale(packet.presentationTime, timescale: Int32(packet.sampleRate), method: .roundTowardZero)
        let complete = try NativePCMDecoder(url: url)
        var prefix: [Int16] = []
        let startSample = Int(selected.value) * packet.channels
        while let part = try await complete.next() {
            prefix.append(contentsOf: part.samples)
        }
        await complete.cancel()
        var tail = packet.samples
        while let part = try await decoder.next() { tail.append(contentsOf: part.samples) }
        #expect(AudibleMatch.matches(tail, Array(prefix.dropFirst(startSample)), channels: packet.channels, sampleRate: packet.sampleRate))
        await decoder.cancel()
    }

    @Test func remoteSourceIsExplicitlyUnimplementedAndMissingFilesThrow() async throws {
        #expect(throws: NativePCMDecoder.Failure.notLocal) {
            try NativePCMDecoder(url: URL(string: "https://example.invalid/episode.mp3")!)
        }
        for time in [CMTime.invalid, .indefinite, .positiveInfinity, CMTime(value: -1, timescale: 1)] {
            #expect(throws: NativePCMDecoder.Failure.invalidStart) {
                try NativePCMDecoder(url: URL(fileURLWithPath: "/unused.wav"), start: time)
            }
        }
        #expect(throws: (any Error).self) {
            try NativePCMDecoder(url: URL(fileURLWithPath: "/nonexistent-\(UUID()).wav"))
        }
    }

    @Test(arguments: [600, 601, 60_000])
    func endAndBeyondReturnNoAudio(milliseconds: Int64) async throws {
        let (url, _) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let decoder = try NativePCMDecoder(url: url, start: CMTime(value: milliseconds, timescale: 1000))
        #expect(try await decoder.next() == nil)
        #expect(try await decoder.next() == nil)
    }

    @Test func cancelledReadDoesNotLoseAudio() async throws {
        let (url, _) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let decoder = try NativePCMDecoder(url: url)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await decoder.next()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let first = try #require(try await decoder.next())
        #expect(first.presentationTime == .zero)
    }
}
private final class NativeDecoderFixtures: NSObject {}
