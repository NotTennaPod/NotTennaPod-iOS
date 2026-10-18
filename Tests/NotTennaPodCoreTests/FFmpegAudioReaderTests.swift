import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite
struct FFmpegAudioReaderTests {
    static let names = ["tone-vorbis.ogg", "tone-opus.ogg", "tone-opus.webm"]
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/StreamingFormats"))
    }

    @Test(arguments: names, [127, 4096, 65_536])
    func completeDecodeIsAudibleCompleteAndContiguous(name: String, capacity: Int) async throws {
        let reader = try FFmpegAudioReader(url: fixture(name), maximumFrames: capacity)
        #expect(reader.sampleRate == 48_000)
        #expect(reader.channels == (name == "tone-vorbis.ogg" ? 2 : 1))
        var audio = AudibleAudio()
        while let chunk = try await reader.next() {
            #expect(chunk.frameCount > 0 && chunk.frameCount <= capacity)
            #expect(chunk.sampleRate == reader.sampleRate && chunk.channels == reader.channels)
            #expect(chunk.presentationTime.isNumeric)
            audio.add(chunk)
        }
        // Eight seconds of tone: complete to within 50 ms, no gaps, not silent.
        FFmpegBufferedSeekReferenceTests.expectComplete(audio, expectedFrames: 384_000, sampleRate: 48_000,
            target: 0, referenceRMS: nil, "\(name), capacity \(capacity)")
        #expect(audio.peak > 1000, "\(name): decoded audio is silent")
        #expect(await reader.status == .ended)
        #expect(try await reader.next() == nil)
    }

    @Test func cancellationDiscardsAnUndeliveredFrameTail() async throws {
        let reader = try FFmpegAudioReader(url: fixture("tone-vorbis.ogg"), maximumFrames: 1)
        #expect(try await reader.next()?.frameCount == 1)
        await reader.cancel()
        await reader.cancel()
        #expect(await reader.status == .cancelled)
        await #expect(throws: FFmpegAudioReader.Failure.cancelled) { try await reader.next() }
    }

    @Test func taskCancellationClosesReaderInsteadOfAllowingResume() async throws {
        let reader = try FFmpegAudioReader(url: fixture("tone-opus.ogg"))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.next()
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await reader.status == .cancelled)
        await #expect(throws: FFmpegAudioReader.Failure.cancelled) { try await reader.next() }
    }

    @Test func malformedAndMissingInputsDoNotPreventSubsequentOpening() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("bad.ogg")
        for data in [Data(), Data("<html>not audio</html>".utf8), Data("OggS".utf8)] {
            try data.write(to: file)
            #expect(throws: (any Error).self) { try FFmpegAudioReader(url: file) }
        }
        try FileManager.default.removeItem(at: file)
        #expect(throws: (any Error).self) { try FFmpegAudioReader(url: file) }
        let valid = try FFmpegAudioReader(url: fixture("tone-vorbis.ogg"))
        #expect((try await valid.next()?.frameCount ?? 0) > 0)
        await valid.cancel()
    }

    @Test func cancellingOneReaderDoesNotAffectAnother() async throws {
        let url = try fixture("tone-opus.webm")
        let first = try FFmpegAudioReader(url: url)
        let second = try FFmpegAudioReader(url: url)
        let expected = try #require(try await first.next())
        await first.cancel()
        let actual = try #require(try await second.next())
        #expect(actual.samples == expected.samples)
        #expect(actual.presentationTime == expected.presentationTime)
        #expect(await second.status == .ready)
        await second.cancel()
    }

    @Test func concurrentPullsSerializeWithoutDuplicatingOrDroppingSamples() async throws {
        let url = try fixture("tone-vorbis.ogg")
        let serial = try FFmpegAudioReader(url: url, maximumFrames: 127)
        var expected: [Int16] = []
        for _ in 0..<24 { expected += try #require(try await serial.next()).samples }
        await serial.cancel()
        let concurrent = try FFmpegAudioReader(url: url, maximumFrames: 127)
        let chunks = try await withThrowingTaskGroup(of: FFmpegAudioReader.Chunk?.self) { group in
            for _ in 0..<24 { group.addTask { try await concurrent.next() } }
            var results: [FFmpegAudioReader.Chunk] = []
            for try await chunk in group { results.append(try #require(chunk)) }
            return results
        }
        let ordered = chunks.sorted { CMTimeCompare($0.presentationTime, $1.presentationTime) < 0 }
        #expect(ordered.count == 24)
        #expect(ordered.flatMap(\.samples) == expected)
        await concurrent.cancel()
    }
}
