import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

struct PlaybackSourceIdentificationTests {
    @MainActor
    @Test(arguments: ["mpeg-ts.ts", "video.flv", "video.avi", "fragmented.mp4",
        "hevc.mp4", "hevc.mkv", "av1.mp4", "av1.mkv", "video-vp8-opus.webm", "video-vp9-vorbis.webm"])
    func actualContainerAndProfileSelectsCommonMediaWithoutDroppingTracks(name: String) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("typed-selection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let factory = PCMPlaybackFactory(cacheDirectory: directory, makeTransport: {
            throw PlaybackTrackSelectionError.unsupported // No renderer is needed for source selection.
        })
        let url = try FFmpegBufferedSeekReferenceTests.resource(name, directory: "PlaybackDecoder")
        let selected = try #require(try await factory.processedIfSupported(url: url, proxy: PodcastProxy(),
            credentials: nil, userAgent: "Selection fixture"))
        let source = try #require(selected.mediaSource)
        let metadata = try await source.prepareMediaMetadata()
        #expect(metadata.selectedVideoTrackID != nil && metadata.selectedAudioTrackID != nil)
        let media = try await source.makeMedia(start: .zero)
        let audio = try #require(try await media.makeAudioDecoder())
        #expect(try await audio.next() != nil)
        #expect(try await media.nextVideoFrame() != nil)
        await media.cancel()
    }

    @Test(arguments: ["video-only.mp4", "video-multitrack.mp4", "skewed.avi"])
    func realMediaIdentifiesFromCapturedBytesWithoutFilenameHints(name: String) async throws {
        let url = try FFmpegBufferedSeekReferenceTests.resource(name, directory: "PlaybackDecoder")
        let file = try LocalAudioBytes(url: url)
        let format = try await file.identify()
        if name.hasSuffix(".avi") { #expect(format == .buffered) }
        else { #expect((try? NativeAudioSourceTimeline.Format(format)) == .mp4) }
    }

    @Test(arguments: [1, 7, 4096])
    func recognizesDemuxCandidatesBeforeNativeAudioRejection(fragmentSize: Int) throws {
        // These are only signature controls, not valid media or codec acceptance.
        // Actual demux/decode fixtures are verified by the expanded codec suite.
        let headers: [Data] = [Data("#!AMR\n".utf8), Data("#!AMR-WB\n".utf8),
            Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x41, 0x56, 0x49, 0x20]),
            Data([0x46, 0x4C, 0x56, 1, 5, 0, 0, 0, 9]), Data([0, 0, 1, 0xBA])]
        for header in headers {
            let detector = try StreamingAudioTypeDetector()
            defer { detector.close() }
            for offset in stride(from: 0, to: header.count, by: fragmentSize) {
                try detector.append(header[offset..<min(header.count, offset + fragmentSize)])
            }
            #expect(try detector.finish() == StreamingAudioTypeDetector.bufferedMediaIdentifier)
            #expect(detector.maximumBufferedBytes <= 4096)
        }
    }

    @Test(arguments: [188, 192, 204])
    func transportStreamRequiresRepeatedSyncBoundaries(packetSize: Int) throws {
        var data = Data(repeating: 0, count: packetSize * 3)
        let offset = packetSize == 192 ? 4 : 0
        for index in 0..<3 { data[offset + index * packetSize] = 0x47 }
        let detector = try StreamingAudioTypeDetector()
        try detector.append(data)
        #expect(try detector.finish() == StreamingAudioTypeDetector.bufferedMediaIdentifier)
        data[offset + packetSize] = 0
        let malformed = try StreamingAudioTypeDetector()
        try malformed.append(data)
        _ = try? malformed.finish()
        #expect(malformed.typeIdentifier != StreamingAudioTypeDetector.bufferedMediaIdentifier)
    }
}
