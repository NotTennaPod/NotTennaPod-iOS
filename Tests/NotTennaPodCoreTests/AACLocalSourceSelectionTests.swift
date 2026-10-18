import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized) struct AACLocalSourceSelectionTests {
    private func fixture(_ name: String, directory: String) throws -> URL {
#if SWIFT_PACKAGE
        return try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/" + directory))
#else
        return try #require(Bundle(for: AACLocalFixtures.self).url(forResource: name, withExtension: nil,
            subdirectory: directory == "LongNativeFormats" ? nil : directory))
#endif
    }
    private func drain(_ session: SampleBufferPlaybackSession, output: SampleBufferPCMOutputTests.Transport) async throws -> Data {
        try await session.prepare()
        if session.state != .ended { try session.play() }
        let deadline = ContinuousClock.now + .seconds(10)
        while session.state != .ended, session.failure == nil, ContinuousClock.now < deadline {
            if output.playing { output.currentTime = output.end; output.onTimeChanged?() }
            await Task.yield()
        }
        try #require(session.state == .ended && session.failure == nil)
        var data = Data()
        for buffer in output.buffers { data.append(try #require(buffer.content.withContiguousStorageIfAvailable { Data($0) })) }
        session.close()
        return data
    }

    @Test(arguments: ["download", "wrong.m4a", "opaque.media"])
    func selectedADTSKeepsOriginalLateSeekAndCapturedFile(filename: String) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("selected-adts-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: fixture("long.aac", directory: "LongNativeFormats"))
        let url = root.appendingPathComponent(filename), cache = root.appendingPathComponent("unused-cache")
        try original.write(to: url)
        var outputs: [SampleBufferPCMOutputTests.Transport] = []
        let owner = PCMPlaybackFactory(cacheDirectory: cache, makeTransport: {
            let output = SampleBufferPCMOutputTests.Transport(); outputs.append(output); return output
        })
        let factory = try await owner.make(.local(url))
        #expect(factory.providesSourceDuration && outputs.isEmpty)
        try FileManager.default.removeItem(at: url)
        try Data("Different file before the first decoder is created".utf8).write(to: url)
        let session = try await factory.make(positionMilliseconds: 360000, parameters: .init(speed: 1, skipSilence: false))
        defer { session.close() }
        try await session.prepare()
        #expect(try session.mediaMicroseconds == 360000000)
        #expect(session.sourceDurationMilliseconds == 369448 && session.sourceSeekable == true)
        let actual = try await drain(session, output: #require(outputs.last))
        // The late seek plays the remaining ~9.4 s of the episode: the same
        // amount of audio (within 50 ms) and loudness as the system decoder
        // reading the file from the seek position.
        let suffix = root.appendingPathComponent("suffix.aac")
        try Data(original.dropFirst(3003804)).write(to: suffix)
        let file = try AVAudioFile(forReading: suffix, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var expected = Data()
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: UInt32(min(4096, file.length - file.framePosition)))
            try #require(buffer.frameLength > 0)
            expected.append(Data(bytes: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * 2))
        }
        // Mono Int16: 2 bytes per frame; 2400 frames is 50 ms at 48 kHz.
        #expect(abs(actual.count - expected.count) <= 2400 * 2, "late seek bytes \(actual.count)/\(expected.count)")
        func rms(_ data: Data) -> Double {
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            guard !samples.isEmpty else { return 0 }
            return (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
        }
        let loudness = rms(actual), reference = rms(expected)
        #expect(reference > 100 && abs(loudness - reference) <= reference * 0.1, "rms \(loudness), system \(reference)")
        let start = try await factory.make(positionMilliseconds: 0, parameters: .init(speed: 1, skipSilence: false))
        defer { start.close() }
        try await start.prepare()
        #expect(try start.mediaMicroseconds == 0)
        #expect(start.writtenFrames > 0 && start.sourceDurationMilliseconds == 369448)
        start.close()
        let end = try await factory.make(positionMilliseconds: 370000, parameters: .init(speed: 1, skipSilence: false))
        defer { end.close() }
        try await end.prepare()
        #expect(end.state == .ended && end.writtenFrames == 0 && end.failure == nil)
        #expect(try end.mediaMicroseconds == 370000000)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    private struct Report: Decodable {
        let cases: [Case]
        struct Case: Decodable { let file: String, startMs: Int64, durationMs: Int64, admittedBytes: Int }
    }
    @Test(arguments: ["lc", "he", "hev2"], ["gapless", "clip-tag"])
    func selectedMP4KeepsStartupAndClipBehaviorAfterPathReplacement(profile: String, variant: String) async throws {
        let name = profile + "-" + variant + ".m4a"
        let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: fixture("android-report.json", directory: "MP4Gapless")))
        let root = URL.temporaryDirectory.appendingPathComponent("selected-mp4-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("misleading.mp3")
        try FileManager.default.copyItem(at: fixture(name, directory: "MP4Gapless"), to: url)
        var outputs: [SampleBufferPCMOutputTests.Transport] = []
        let owner = PCMPlaybackFactory(cacheDirectory: root.appendingPathComponent("cache"), makeTransport: {
            let output = SampleBufferPCMOutputTests.Transport(); outputs.append(output); return output
        })
        let factory = try await owner.make(.local(url))
        #expect(factory.providesSourceDuration && outputs.isEmpty)
        try FileManager.default.removeItem(at: url)
        for start: Int64 in [0, 1500, 0] {
            let expected = try #require(report.cases.first { $0.file == name && $0.startMs == start })
            let session = try await factory.make(positionMilliseconds: start, parameters: .init(speed: 1, skipSilence: false))
            defer { session.close() }
            #expect(session.sourceDurationMilliseconds == expected.durationMs && session.sourceSeekable == true)
            let output = try #require(outputs.last)
            let data = try await drain(session, output: output)
            // Playback from the start and after a seek yields the same amount
            // of audio as Android (within 50 ms: 2400 stereo Int16 frames).
            #expect(abs(data.count - expected.admittedBytes) <= 2400 * 4, "\(name) @\(start): bytes \(data.count)/\(expected.admittedBytes)")
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cache").path))
    }
}
private final class AACLocalFixtures: NSObject {}
