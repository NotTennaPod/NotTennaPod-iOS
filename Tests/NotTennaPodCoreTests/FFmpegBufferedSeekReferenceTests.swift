import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

/// What a listener hears from one decode: where playback starts, how much audio plays, whether
/// consecutive buffers are contiguous, and how loud it is. Used instead of sample-exact hashes.
struct AudibleAudio {
    private(set) var starts: [Int64] = [] // Chunk start times in microseconds.
    private(set) var frames: [Int] = []
    private(set) var sampleRate = 0
    private var sumOfSquares = 0.0, sampleCount = 0
    private(set) var peak = 0
    var totalFrames: Int { frames.reduce(0, +) }
    var rms: Double { sampleCount == 0 ? 0 : (sumOfSquares / Double(sampleCount)).squareRoot() }
    /// Largest discontinuity between one chunk's end and the next chunk's start, in microseconds.
    var largestGap: Int64 {
        guard sampleRate > 0 else { return 0 }
        return zip(zip(starts, frames), starts.dropFirst()).map { current, next in
            abs(next - (current.0 + Int64(current.1) * 1_000_000 / Int64(sampleRate)))
        }.max() ?? 0
    }
    mutating func add(time: CMTime, samples: [Int16], sampleRate: Int, channels: Int) {
        self.sampleRate = sampleRate
        starts.append(CMTimeConvertScale(time, timescale: 1_000_000, method: .roundTowardZero).value)
        frames.append(samples.count / max(channels, 1))
        for sample in samples {
            let value = Int(sample)
            sumOfSquares += Double(value * value); peak = max(peak, abs(value))
        }
        sampleCount += samples.count
    }
    mutating func add(_ chunk: FFmpegAudioReader.Chunk) {
        add(time: chunk.presentationTime, samples: chunk.samples, sampleRate: chunk.sampleRate, channels: chunk.channels)
    }
    mutating func add(_ packet: NativePCMDecoder.Packet) {
        add(time: packet.presentationTime, samples: packet.samples, sampleRate: packet.sampleRate, channels: packet.channels)
    }
}

@Suite(.serialized, .timeLimit(.minutes(2))) struct FFmpegBufferedSeekReferenceTests {
    private static let names = ["tone-vorbis.ogg", "tone-opus.ogg", "tone-opus.webm", "late-first-cue.webm"]
    struct Reference: Decodable {
        struct Buffer: Decodable { let timeMicroseconds: Int64; let frames, byteOffset, byteCount: Int }
        let file: String
        let sampleRate, channels: Int
        let sha256: String
        let buffers: [Buffer]
    }
    static func reference(_ name: String) throws -> Reference {
        let url = try resource("reference.json", directory: "BufferedCodecReference")
        return try #require(JSONDecoder().decode([Reference].self, from: Data(contentsOf: url)).first { $0.file == name })
    }
    static func resource(_ name: String, directory: String) throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/" + directory))
#else
        try #require(Bundle(for: BufferedSeekFixtures.self).url(forResource: name, withExtension: nil,
            subdirectory: directory == "StreamingFormats" ? nil : directory))
#endif
    }

    /// Checks what a listener would notice after decoding from `target` (microseconds), against the
    /// uninterrupted Android reference: playback starts within 0.25 s of the request, the remaining
    /// audio is complete to within 50 ms, chunks are contiguous (no gap over 10 ms) and the tone
    /// keeps the reference level (RMS within 10 %).
    static func expectAudible(_ audio: AudibleAudio, target: Int64, reference name: String, _ label: String) throws {
        let android = try Self.reference(name)
        let pcm = try Data(contentsOf: resource(name + ".s16", directory: "BufferedCodecReference"))
        let referenceRMS = pcm.withUnsafeBytes { raw -> Double in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            return (samples.reduce(0.0) { $0 + Double(Int($1) * Int($1)) } / Double(samples.count)).squareRoot()
        }
        let expectedFrames = android.buffers.filter { $0.timeMicroseconds >= target }.reduce(0) { $0 + $1.frames }
        expectComplete(audio, expectedFrames: expectedFrames, sampleRate: android.sampleRate, target: target,
                       referenceRMS: referenceRMS, label)
    }

    /// Compares two decodes of the same media (for example streamed against local) by what is audible.
    static func expectSameAudible(_ actual: AudibleAudio, _ expected: AudibleAudio, _ label: String) {
        expectComplete(actual, expectedFrames: expected.totalFrames, sampleRate: expected.sampleRate,
                       target: expected.starts.first, referenceRMS: expected.rms, label)
    }

    static func expectComplete(_ audio: AudibleAudio, expectedFrames: Int, sampleRate: Int, target: Int64?,
                               referenceRMS: Double?, _ label: String) {
        #expect(audio.sampleRate == 0 || audio.sampleRate == sampleRate, "\(label): sample rate \(audio.sampleRate)")
        #expect(abs(audio.totalFrames - expectedFrames) <= sampleRate / 20,
                "\(label): \(audio.totalFrames) frames played, expected about \(expectedFrames)")
        if let target, let first = audio.starts.first {
            #expect(abs(first - target) <= 250_000, "\(label): playback starts at \(first) µs, requested \(target) µs")
        }
        #expect(audio.largestGap <= 10_000, "\(label): \(audio.largestGap) µs gap between buffers")
        if let referenceRMS, referenceRMS > 0, audio.totalFrames >= sampleRate / 4 {
            #expect(abs(audio.rms - referenceRMS) <= referenceRMS * 0.1,
                    "\(label): level \(audio.rms), reference \(referenceRMS)")
        }
    }

    @Test(arguments: names)
    func bufferedSeekPreservesIntendedAudioAgainstUninterruptedAndroidReference(name: String) async throws {
        try await verifySequence(name: name, targets: [0, 1, 20, 79, 80, 499, 500, 501, 3883, 4000, 7990, 0])
    }

    @Test(arguments: ["tone-vorbis.ogg", "tone-opus.ogg", "tone-opus.webm"], [Int64(1), 80, 501, 3883, 4000, 7990])
    func initialNonzeroTargetAlsoDecodesBeforeAdmittingAudio(name: String, target: Int64) async throws {
        try await verifySequence(name: name, targets: [target])
    }

    private func verifySequence(name: String, targets: [Int64]) async throws {
        let fixtureURL = try Self.resource(name == "late-first-cue.webm" ? "tone-opus.webm" : name, directory: "StreamingFormats")
        var url = fixtureURL
        if name == "late-first-cue.webm" {
            var data = try Data(contentsOf: fixtureURL)
            try #require(data[86255] == 0xBB); data[86255] = 0xEC
            url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".webm")
            try data.write(to: url)
        }
        defer { if url != fixtureURL { try? FileManager.default.removeItem(at: url) } }
        let owner = try await FFmpegAudioReader.openBuffered(url: url, maximumFrames: 65_536, timing: .media3)
        do {
            #expect(try await owner.prepareSourceTimeline() == true)
            for target in targets {
                let reader = try await owner.makePlaybackReader(to: CMTime(value: target, timescale: 1000))
                var audio = AudibleAudio()
                while let chunk = try await reader.next() { audio.add(chunk) }
                await reader.cancel()
                try Self.expectAudible(audio, target: target * 1000, reference: name, "\(name) seek \(target) ms")
            }
        } catch { await owner.cancel(); throw error }
        await owner.cancel()
    }
}

private final class BufferedSeekFixtures: NSObject {}
