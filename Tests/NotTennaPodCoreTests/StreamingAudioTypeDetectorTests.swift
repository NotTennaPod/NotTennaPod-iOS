import AudioToolbox
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import NotTennaPodCore

struct StreamingAudioTypeDetectorTests {
    @Test(arguments: [1, 7, 128, 4096, 65_536])
    func discoversMP3FromFragmentedBytesWithoutMetadata(chunkSize: Int) throws {
        let url = Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures")!
        let bytes = try Data(contentsOf: url)
        let detector = try StreamingAudioTypeDetector()
        for start in stride(from: 0, to: bytes.count / 4, by: chunkSize) {
            try detector.append(bytes[start..<min(start + chunkSize, bytes.count / 4)])
            if detector.typeIdentifier != nil { break }
        }
        #expect(try detector.finish() == UTType.mp3.identifier)
    }

    @Test func emptyOrClosedDetectionCannotInventAType() throws {
        let detector = try StreamingAudioTypeDetector()
        try detector.append(Data())
        #expect(throws: StreamingAudioTypeError.unrecognized) { try detector.finish() }
        detector.close(); detector.close()
        #expect(throws: StreamingAudioTypeError.closed) { try detector.append(Data([0])) }
        #expect(detector.typeIdentifier == nil && detector.bytesExamined == 0)
    }

    @Test func distinguishesWaveFromMP3WithoutAFileExtension() throws {
        let (url, _) = try PCMTestFixture.waveFixture(channels: 1)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let bytes = try Data(contentsOf: url)
        let detector = try StreamingAudioTypeDetector()
        try detector.append(bytes.prefix(4096))
        #expect(try detector.finish() == UTType.wav.identifier)
    }

    @Test func endOfInputFlushesShortPrefixAndCancellationDiscardsUnparsedBytes() throws {
        let url = Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures")!
        let prefix = try Data(contentsOf: url).prefix(1000)
        let detector = try StreamingAudioTypeDetector()
        try detector.append(prefix)
        #expect(try detector.finish() == UTType.mp3.identifier)
        let cancelled = try StreamingAudioTypeDetector()
        try cancelled.append(prefix)
        cancelled.close()
        #expect(throws: StreamingAudioTypeError.unrecognized) { try cancelled.finish() }
    }
}

extension StreamingAudioTypeDetectorTests {
    @Test(arguments: [1, 7, 4096], [false, true])
    func fragmentedPlaylistRequestsNativeRoutingBeforeAudioParsing(chunkSize: Int, bom: Bool) throws {
        let bytes = (bom ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data("#EXTM3U\n#EXT-X-VERSION:3\n".utf8)
        let detector = try StreamingAudioTypeDetector()
        defer { detector.close() }
        for start in stride(from: 0, to: bytes.count, by: chunkSize) {
            try detector.append(bytes[start..<min(start + chunkSize, bytes.count)])
        }
        #expect(throws: StreamingAudioTypeError.requiresNativePlaylist) { try detector.finish() }
    }
}
