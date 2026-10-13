import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(1)))
struct FFmpegPlaybackMediaAdapterTests {
    private func fixture(_ name: String) throws -> URL {
        try FFmpegBufferedSeekReferenceTests.resource(name, directory: "PlaybackDecoder")
    }
    private func open(_ name: String, track: Int32? = nil, start: CMTime = .zero) async throws -> FFmpegPlaybackMediaAdapter {
        let file = try LocalAudioBytes(url: fixture(name))
        let probe = try await FFmpegMediaReader.open(input: file.lease())
        let metadata = probe.metadata
        await probe.cancel()
        return try await FFmpegPlaybackMediaAdapter.open(input: file.lease(), metadata: metadata, audioTrackID: track, start: start)
    }
    @Test func videoOnlyHasNoFabricatedPCMAndDrainsAllPictures() async throws {
        let media = try await open("video-only.mp4")
        #expect(try await media.makeAudioDecoder() == nil)
        var count = 0
        while let frame = try await media.nextVideoFrame() {
            #expect(frame.sourceRange.start == CMTime(value: Int64(count), timescale: 25))
            count += 1
        }
        #expect(count == 200)
        #expect(try await media.nextVideoFrame() == nil)
        await media.cancelVideo()
    }
    @Test(arguments: [Int32(1), Int32(2)])
    func selectedTrackSeeksToEpisodeTimeAndPreservesCompleteAudioAndVideo(track: Int32) async throws {
        let start = CMTime(value: 24_048, timescale: 48_000)
        let media = try await open("video-multitrack.mp4", track: track, start: start)
        let decoder = try #require(try await media.makeAudioDecoder())
        #expect(decoder.sampleRate == 48_000 && decoder.channels == 1 && abs(decoder.startTime.seconds - start.seconds) <= 0.25)
        var samples: [Int16] = []
        while let packet = try await decoder.next() { samples += packet.samples }
        #expect(abs(samples.count - (384_000 - 24_048)) <= 2400)
        let window = samples.prefix(48_000)
        let crossings = zip(window, window.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
        let expected = track == 1 ? 440 : 880
        #expect((expected - 2 ... expected + 2).contains(crossings))
        // Audio reaches EOF without consuming any future pictures. Its EOF is
        // not a common-owner cancellation and all remaining pictures survive.
        var pictures = 0
        while let frame = try await media.nextVideoFrame() {
            if pictures == 0 { #expect(frame.sourceRange.start <= start && CMTimeRangeGetEnd(frame.sourceRange) > start) }
            pictures += 1
        }
        #expect(pictures == 188)
        await decoder.cancel()
    }
    @Test func allVideoBeforeAudioStillAllowsAudioToFinishBeforeVideoPull() async throws {
        let file = try Data(contentsOf: fixture("skewed.avi"))
        let upstream = Sequential(file)
        let source = try PlaybackRetainedByteSource(input: upstream)
        defer { source.cancel() }
        let probe = try await FFmpegMediaReader.open(input: source.makeReadLease())
        let metadata = probe.metadata
        await probe.cancel()
        let media = try await FFmpegPlaybackMediaAdapter.open(input: source, metadata: metadata, start: .zero)
        let decoder = try #require(try await media.makeAudioDecoder())
        var audio = AudibleAudio()
        while let packet = try await decoder.next() { audio.add(packet) }
        // All three seconds of audio play without waiting for the video, then every picture follows.
        #expect(abs(audio.totalFrames - 144_000) <= 2400 && audio.peak > 1000)
        var frames = 0
        while try await media.nextVideoFrame() != nil { frames += 1 }
        #expect(frames == 75)
        await media.cancel()
    }
    @Test func audioTailExposesOneGenuinePosterWithoutExtendingVideoEOF() async throws {
        let media = try await open("audio-tail.mp4", start: CMTime(value: 7, timescale: 1))
        let audio = try #require(try await media.makeAudioDecoder())
        #expect(try await media.nextVideoFrame() == nil)
        let poster = try #require(await media.videoPosterFrame())
        #expect(poster.sourceRange.start == CMTime(value: 76, timescale: 25))
        #expect(poster.sourceRange.duration == CMTime(value: 1, timescale: 25))
        var frames = 0
        while let packet = try await audio.next() { frames += packet.frameCount }
        #expect(abs(frames - 48_000) <= 2400)
        #expect(try await media.nextVideoFrame() == nil)
        await media.cancel()
        #expect(await media.videoPosterFrame() == nil)
    }

    /// Stopping a video episode stops both its sound and its pictures, even while the
    /// player still holds the audio decoder.
    @Test func cancellingTheItemStopsAudioAndVideo() async throws {
        let media = try await open("video-multitrack.mp4")
        let decoder = try #require(try await media.makeAudioDecoder())
        #expect(try await decoder.next() != nil)
        await media.cancelVideo()
        await #expect(throws: (any Error).self) { _ = try await decoder.next() }
        await #expect(throws: (any Error).self) { _ = try await media.nextVideoFrame() }
        await decoder.cancel(); await media.cancelVideo()
    }

    private final class Sequential: MediaByteInput, @unchecked Sendable {
        let data: Data
        let length: Int64? = nil
        let supportsRandomAccess = false
        private let lock = NSLock()
        private var offset = 0, cancelled = false
        init(_ data: Data) { self.data = data }
        var bytesRead: Int { lock.withLock { offset } }
        func prepareForSeek() {}
        func cancel() { lock.withLock { cancelled = true } }
        func checkFailure() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
        func read(at position: Int64, maximumCount: Int) throws -> Data {
            try lock.withLock {
                if cancelled { throw CancellationError() }
                guard position == offset else { throw CocoaError(.fileReadCorruptFile) }
                let end = min(data.count, offset + maximumCount)
                defer { offset = end }
                return data.subdata(in: offset..<end)
            }
        }
    }
}
