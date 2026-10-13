import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) struct MP4GaplessMetadataTests {
    private struct Report: Decodable {
        let complete: Bool
        let cases: [Case]
        struct Case: Decodable {
            let file: String, startMs: Int64, ended: Bool, timedOut: Bool
            let formats: [Format]
            let admittedBytes: Int, trimmedBytes: Int
        }
        struct Format: Decodable { let rate: Int64, encoderDelay: Int64, encoderPadding: Int64 }
    }
    private struct Manifest: Decodable {
        let files: [File]
        struct File: Decodable { let name: String, sha256: String }
    }
    private func fixture(_ name: String) throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/MP4Gapless"))
#else
        try #require(Bundle(for: GaplessMetadataFixtures.self).url(forResource: name, withExtension: nil, subdirectory: "MP4Gapless"))
#endif
    }
    @Test(arguments: 0..<12, [1, 17, 4096])
    func originalPriorityWithExplicitMediaAndFrameUnits(index: Int, fragment: Int) async throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: fixture("manifest.json")))
        let entry = manifest.files[index], data = try Data(contentsOf: fixture(entry.name))
        try #require(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == entry.sha256)
        let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: fixture("android-report.json")))
        try #require(report.complete && report.cases.count == 24)
        let original = try #require(report.cases.first { $0.file == entry.name && $0.startMs == 0 })
        try #require(original.ended && !original.timedOut)
        let format = try #require(original.formats.first)
        let edit = entry.name.contains("-gapless"), lc = entry.name.hasPrefix("lc-")
        for known in [false, true] {
            let input = Bytes(data, known: known, fragment: fragment)
            let result = try await NativeAudioSourceTimeline.read(input: input, format: .mp4)
            let trim = try #require(result.mp4AudioTrim)
            if edit {
                // Media3 derives these HE values from its 24kHz core format,
                // then configures the 48kHz sink with those unscaled values.
                // Preserve the declared edit units, not that unit mismatch.
                let scale: Int64 = lc ? 1 : 2
                #expect(trim.unitsPerSecond == 48000)
                #expect(trim.delay == format.encoderDelay * scale && trim.delay == 512)
                #expect(trim.padding == format.encoderPadding * scale)
                #expect(trim.padding == (lc ? 2112 : 6144))
                #expect(result.mp4AudioEdit == nil && result.mp4AudioSequence == nil)
            } else {
                #expect(trim.unitsPerSecond == nil)
                #expect(trim.delay == format.encoderDelay && trim.delay == 100)
                #expect(trim.padding == format.encoderPadding && trim.padding == 200)
                #expect((result.mp4AudioEdit != nil) == entry.name.contains("-clip-tag"))
            }
            #expect(input.cancelled.withLock { $0 })
        }
    }

    @Test(arguments: [" 00000000 00000000 00000000", " 00000000 FFFFFFFF 000000C8", " 00000000 80000000 000000C8", " 00000000 00000064 z00000C8", "x00000000 00000064 000000C8"])
    func invalidAndEmptyTagsAreIgnored(value: String) async throws {
        var data = try Data(contentsOf: fixture("lc-tag-only.m4a"))
        let range = try #require(data.range(of: Data(" 00000000 00000064 000000C8".utf8)))
        try #require(value.utf8.count == range.count)
        data.replaceSubrange(range, with: Data(value.utf8))
        let result = try await NativeAudioSourceTimeline.read(input: Bytes(data), format: .mp4)
        #expect(result.mp4AudioTrim == nil)
        #expect(result.durationMicroseconds.map { abs($0 - 4_011_000) <= 50_000 } == true)
    }

    @Test(arguments: ["com.apple.iTunes", "iTunSMPB"])
    func unrelatedInternalMetadataCannotTrimAudio(field: String) async throws {
        var data = try Data(contentsOf: fixture("lc-tag-only.m4a"))
        let range = try #require(data.range(of: Data(field.utf8)))
        data[range.upperBound - 1] = 88
        let result = try await NativeAudioSourceTimeline.read(input: Bytes(data), format: .mp4)
        #expect(result.mp4AudioTrim == nil && result.durationMicroseconds.map { abs($0 - 4_011_000) <= 50_000 } == true)
    }

    @Test(arguments: [" 00000000 00000000 000000c8", " 00000000 7FFFFFFF 00000000"])
    func paddingOnlyAndLargeValidValuesRemainMetadata(value: String) async throws {
        var data = try Data(contentsOf: fixture("lc-tag-only.m4a"))
        let range = try #require(data.range(of: Data(" 00000000 00000064 000000C8".utf8)))
        data.replaceSubrange(range, with: Data(value.utf8))
        let result = try await NativeAudioSourceTimeline.read(input: Bytes(data, fragment: 1), format: .mp4)
        let trim = try #require(result.mp4AudioTrim)
        #expect(trim.unitsPerSecond == nil)
        #expect(trim.delay == (value.contains("7FFFFFFF") ? Int64(Int32.max) : 0))
        #expect(trim.padding == (value.contains("7FFFFFFF") ? 0 : 200))
    }

    private final class Bytes: MediaByteInput {
        let data: Data, known: Bool, fragment: Int
        let cancelled = Mutex(false)
        init(_ data: Data, known: Bool = true, fragment: Int = 4096) { self.data = data; self.known = known; self.fragment = fragment }
        var length: Int64? { known ? Int64(data.count) : nil }
        var supportsRandomAccess: Bool { true }
        func prepareForSeek() {}
        func cancel() { cancelled.withLock { $0 = true } }
        func checkFailure() throws { if cancelled.withLock({ $0 }) { throw CancellationError() } }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            try checkFailure()
            guard offset < data.count else { return Data() }
            return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + min(fragment, maximumCount)))
        }
    }
}
private final class GaplessMetadataFixtures: NSObject {}
