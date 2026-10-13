import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(2)))
struct FFmpegMediaReaderTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try FFmpegBufferedSeekReferenceTests.resource(name, directory: "PlaybackDecoder")
        return try Data(contentsOf: url)
    }
    private func open(_ name: String, selection: FFmpegMediaSelection = .automatic, start: Double = 0,
                      retry: PCMSourceRetry = PCMSourceRetry()) async throws -> FFmpegMediaReader {
        try await FFmpegMediaReader.open(input: MemoryInput(try fixture(name), retry: retry), selection: selection,
            start: CMTime(seconds: start, preferredTimescale: 48_000))
    }
    private func pixel(_ frame: PlaybackVideoFrame) -> (width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) {
        frame.pixelBuffer.withUnsafeBuffer { buffer in
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            return (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), bytes[2], bytes[1], bytes[0])
        }
    }
    @Test(arguments: ["video-multitrack.mp4", "video-only.mp4", "video-vp8-opus.webm", "video-vp9-vorbis.webm", "mpeg-ts.ts", "video.flv", "video.avi", "hevc.mp4", "hevc.mkv", "av1.mp4", "av1.mkv", "fragmented.mp4"])
    func actualVideoPixelsTimestampsAndDrain(name: String) async throws {
        let reader = try await open(name)
        #expect(reader.metadata.selectedVideoTrackID != nil)
        #expect(reader.metadata.sourceSeekable)
        var count = 0, audio = 0
        var previous = CMTime.negativeInfinity
        var retained: PlaybackVideoFrame?
        while let event = try await reader.next() {
            switch event {
            case .audio(let chunk): audio += chunk.frameCount
            case .video(let frame):
                let value = pixel(frame)
                #expect(value.width == 320 && value.height == 180)
                #expect(frame.sourceRange.start >= previous && frame.sourceRange.duration > .zero)
                if count == 0 { retained = frame; #expect(value.red > 200 && value.blue < 20 && value.green < 20) }
                // Color periods are defined in the independent raw RGB generator.
                if count == 60 { #expect(value.blue > 200 && value.red < 20 && value.green < 20) }
                previous = frame.sourceRange.start; count += 1
            }
        }
        #expect(count == (["video-multitrack.mp4", "video-only.mp4", "fragmented.mp4"].contains(name) ? 200 : 75))
        #expect(name == "video-only.mp4" ? audio == 0 : audio > 140_000)
        #expect(reader.bufferState.snapshot.isFinalBuffered)
        await reader.cancel()
        // Output survives native frame reuse and complete decoder destruction.
        #expect(pixel(try #require(retained)).red > 200)
    }
    @Test func actualTrackSelectionAndTrimmedSeek() async throws {
        let reader = try await open("video-multitrack.mp4", selection: .init(audioTrackID: 2, includeVideo: false), start: 0.501)
        #expect(reader.metadata.containerName.contains("mp4"))
        #expect(reader.metadata.tracks.filter { $0.kind == .audio }.map(\.language) == ["eng", "deu"])
        #expect(reader.metadata.selectedAudioTrackID == 2 && reader.metadata.selectedVideoTrackID == nil)
        var samples: [Int16] = [], first: CMTime?
        while let event = try await reader.next() {
            guard case .audio(let chunk) = event else { Issue.record("Unselected video decoded"); continue }
            if first == nil { first = chunk.presentationTime }
            samples += chunk.samples
        }
        // Playback starts where requested and the rest of the selected track plays.
        #expect(abs((first?.seconds ?? -1) - 0.501) <= 0.25)
        #expect(abs(samples.count - (384_000 - 24_048)) <= 2400)
        let second = samples.prefix(48_000)
        let crossings = zip(second, second.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
        #expect((878...882).contains(crossings)) // Independently generated German track is 880Hz.
        await reader.cancel()
    }
    @Test(arguments: [Int32(0), Int32(1)])
    func audioOnlyMultitrackPreservesTitlesIDsAndIndependentSamples(trackID: Int32) async throws {
        let reader = try await open("audio-multitrack.m4a", selection: .init(audioTrackID: trackID))
        #expect(reader.metadata.tracks.map(\.id) == [0, 1])
        #expect(reader.metadata.tracks.map(\.kind) == [.audio, .audio])
        #expect(reader.metadata.tracks.map(\.title) == ["English 440 Hz", "Deutsch 880 Hz"])
        #expect(reader.metadata.tracks.map(\.language) == ["eng", "deu"])
        #expect(reader.metadata.selectedAudioTrackID == trackID && reader.metadata.selectedVideoTrackID == nil)
        var samples: [Int16] = []
        while let event = try await reader.next() {
            guard case .audio(let chunk) = event else { Issue.record("Unexpected video"); continue }
            #expect(chunk.sampleRate == 48_000 && chunk.channels == 1)
            samples += chunk.samples
        }
        #expect(abs(samples.count - 384_000) <= 2400)
        let second = samples.prefix(48_000)
        let crossings = zip(second, second.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
        let frequency = trackID == 0 ? 440 : 880
        #expect((frequency - 2...frequency + 2).contains(crossings))
        await reader.cancel()
    }
    @Test func independentScopesDoNotStallOnAllVideoBeforeAudio() async throws {
        let data = try fixture("skewed.avi"), retry = PCMSourceRetry()
        let audio = try await FFmpegMediaReader.open(input: MemoryInput(data, retry: retry), selection: .init(includeVideo: false))
        let video = try await FFmpegMediaReader.open(input: MemoryInput(data, retry: retry), selection: .init(includeAudio: false))
        var audioFrames = 0
        while let event = try await audio.next() { if case .audio(let chunk) = event { audioFrames += chunk.frameCount } }
        #expect(abs(audioFrames - 144_000) <= 2400) // No video consumer was needed to unblock audio.
        await audio.cancel()
        var videoFrames = 0
        while let event = try await video.next() { if case .video = event { videoFrames += 1 } }
        #expect(videoFrames == 75) // Canceling the audio lease did not retire the video lease.
        await video.cancel()
    }
    @Test func inputAudioFormatTransitionKeepsOutputGeometryAndDrains() async throws {
        let reader = try await open("changing.aac", selection: .init(includeVideo: false))
        var samples = 0, previous = CMTime.negativeInfinity, rates = Set<Int>(), channels = Set<Int>()
        while let event = try await reader.next() {
            guard case .audio(let chunk) = event else { continue }
            rates.insert(chunk.sampleRate); channels.insert(chunk.channels)
            #expect(chunk.presentationTime >= previous)
            previous = chunk.presentationTime; samples += chunk.frameCount
        }
        #expect(rates == [48_000] && channels == [1])
        // ADTS consists of 48 AAC frames at48k +25 at24k; resampling preserves both complete packet periods.
        #expect(abs(samples - (48 * 1024 + 25 * 2048)) <= 2400)
        await reader.cancel()
    }
    @Test func videoFormatTransitionPreservesOwnedGeometry() async throws {
        let reader = try await open("changing-video.ts", selection: .init(includeAudio: false))
        var widths: [Int] = []
        while let event = try await reader.next() { if case .video(let frame) = event { widths.append(pixel(frame).width) } }
        #expect(widths == [Int](repeating: 320, count: 25) + [Int](repeating: 160, count: 25))
        await reader.cancel()
    }
    @Test func cancelOpeningWakesBlockedInputAndPreservesRetryIdentity() async throws {
        let input = MemoryInput(try fixture("video-multitrack.mp4")); input.block()
        let task = Task { try await FFmpegMediaReader.open(input: input) }
        try await wait { input.isWaitingForData }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(input.cancelled)
    }
    @Test func cancelNextWakesExecutorAndWaitingIsNotFinalEOF() async throws {
        let input = MemoryInput(try fixture("wav-float.wav"))
        let reader = try await FFmpegMediaReader.open(input: input)
        #expect(reader.bufferState.sourceRetry === input.sourceRetry)
        input.block()
        let task = Task { while try await reader.next() != nil {} }
        try await wait { input.isWaitingForData }
        try await wait { reader.bufferState.snapshot.isWaitingForSource }
        #expect(reader.bufferState.snapshot.isWaitingForSamples)
        #expect(!reader.bufferState.snapshot.isFinalBuffered)
        await reader.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(!reader.bufferState.snapshot.isFinalBuffered)
    }
    @Test(arguments: ["amr-nb.amr", "amr-wb.amr", "wav-float.wav", "ogg-flac.ogg"])
    func demandPullIdleAllowsReadyBoundedPCMToStart(name: String) async throws {
        let reader = try await open(name, selection: .init(includeVideo: false))
        #expect(!reader.bufferState.snapshot.isLoading)
        #expect(try !reader.bufferState.snapshot.shouldStartPlayback(rendererReadyOrEnded: false,
            positionMicroseconds: 0, speed: 1, rebuffering: false))
        // The renderer holds only four decoded buffers. No background producer can
        // extend the encoded horizon while the caller stops pulling at that bound.
        var queuedDuration = CMTime.zero
        for _ in 0..<4 {
            guard case .audio(let chunk) = try await reader.next() else {
                Issue.record("Expected an actual PCM chunk before EOF"); await reader.cancel(); return
            }
            queuedDuration = CMTimeAdd(queuedDuration,
                CMTime(value: Int64(chunk.frameCount), timescale: Int32(chunk.sampleRate)))
            let state = reader.bufferState.snapshot
            #expect(!state.isLoading && !state.isWaitingForSamples && !state.isWaitingForSource)
            #expect(!state.isFinalBuffered && state.isUsable)
        }
        let state = reader.bufferState.snapshot
        #expect(queuedDuration > .zero && queuedDuration < CMTime(seconds: 1, preferredTimescale: 1))
        // Independent existing load policy still rejects this short horizon when
        // loading really is ongoing; the fix must not change that policy.
        #expect(try !PlaybackLoadControl().shouldStartPlayback(
            bufferedMicroseconds: max(0, state.bufferedThroughMicroseconds ?? 0), speed: 1,
            rebuffering: false, allocatedBytes: state.allocatedBytes, targetBytes: state.targetBytes))
        for rebuffering in [false, true] {
            #expect(try state.shouldStartPlayback(rendererReadyOrEnded: true,
                positionMicroseconds: 0, speed: 1, rebuffering: rebuffering))
        }
        await reader.cancel()
        #expect(!reader.bufferState.snapshot.isUsable)
    }

    @Test func activeInputWaitRemainsLoadingUntilAcquisitionCompletes() async throws {
        let input = MemoryInput(try fixture("wav-float.wav"))
        let reader = try await FFmpegMediaReader.open(input: input)
        input.block()
        let task = Task { while try await reader.next() != nil {} }
        try await wait { reader.bufferState.snapshot.isWaitingForSource }
        let waiting = reader.bufferState.snapshot
        #expect(waiting.isLoading && waiting.isWaitingForSamples && !waiting.isFinalBuffered)
        #expect(reader.bufferState.sourceRetry === input.sourceRetry)
        #expect(try !waiting.shouldStartPlayback(rendererReadyOrEnded: false,
            positionMicroseconds: 0, speed: 1, rebuffering: true))
        input.unblock()
        try await task.value
        let final = reader.bufferState.snapshot
        #expect(final.isFinalBuffered && !final.isLoading && !final.isWaitingForSamples && !final.isWaitingForSource)
        await reader.cancel()
    }

    @Test func cachedPacketReplayDoesNotResetRetryProgress() async throws {
        let retry = PCMSourceRetry()
        let first = try await open("video-multitrack.mp4", selection: .init(includeVideo: false), retry: retry)
        for _ in 0..<20 { _ = try await first.next() }
        let before = retry.snapshot.extractedSamples
        await first.cancel()
        for _ in 0..<4 { _ = try retry.plan(for: URLError(.timedOut), lengthKnown: true) }
        #expect(retry.currentError != nil)
        let second = try await open("video-multitrack.mp4", selection: .init(includeVideo: false), retry: retry)
        for _ in 0..<10 { _ = try await second.next() }
        #expect(retry.snapshot.extractedSamples == before)
        #expect(retry.currentError != nil)
        while try await second.next() != nil {}
        #expect(retry.snapshot.extractedSamples > before)
        #expect(retry.currentError == nil)
        await second.cancel()
    }
    @Test(arguments: ["amr-nb.amr", "amr-wb.amr", "ogg-flac.ogg", "wav-u8.wav", "wav-s24.wav", "wav-float.wav", "wav-ima.wav", "wav-alaw.wav", "wav-mulaw.wav"])
    func admittedAudioDecodesActualToneAndSeeks(name: String) async throws {
        let reader = try await open(name, selection: .init(includeVideo: false))
        var samples: [Int16] = [], rate = 0
        while let event = try await reader.next() {
            guard case .audio(let chunk) = event else { Issue.record("Unexpected video"); continue }
            #expect(chunk.channels == 1)
            rate = chunk.sampleRate; samples += chunk.samples
        }
        let expectedRate = name == "amr-nb.amr" ? 8000 : name == "amr-wb.amr" ? 16000 : 48000
        #expect(rate == expectedRate)
        // Three seconds of a loud 440 Hz tone, complete to within 50 ms.
        #expect(abs(samples.count - expectedRate * 3) <= expectedRate / 20)
        #expect(samples.map { abs(Int($0)) }.max() ?? 0 > 8000)
        if !name.hasPrefix("amr") { // Speech codecs are too lossy for a zero-crossing pitch count.
            let second = samples.prefix(expectedRate)
            let crossings = zip(second, second.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
            #expect((430...450).contains(crossings), "\(name): \(crossings) Hz")
        }
        await reader.cancel()
        let seek = try await open(name, selection: .init(includeVideo: false), start: 1)
        var seekSamples: [Int16] = [], first: CMTime?
        while let event = try await seek.next() {
            if case .audio(let chunk) = event { first = first ?? chunk.presentationTime; seekSamples += chunk.samples }
        }
        // Seeking to 1 s starts within 0.25 s of it and plays the remaining two seconds.
        #expect(abs((first?.seconds ?? -1) - 1) <= 0.25)
        #expect(abs(seekSamples.count - (samples.count - rate)) <= rate / 20)
        await seek.cancel()
    }
    @Test(arguments: ["video-multitrack.mp4", "video-vp8-opus.webm", "video-vp9-vorbis.webm", "mpeg-ts.ts", "video.flv", "video.avi", "hevc.mp4", "av1.mp4"])
    func selectedVideoSeekKeepsCrossingFrame(name: String) async throws {
        let reader = try await open(name, selection: .init(includeAudio: false), start: 1.501)
        var first: PlaybackVideoFrame?, count = 0
        while let event = try await reader.next() {
            if case .video(let frame) = event { first = first ?? frame; count += 1 }
        }
        let range = try #require(first).sourceRange
        #expect(CMTimeRangeGetEnd(range).seconds > 1.501 && range.start.seconds < 1.541)
        #expect(count > 30)
        await reader.cancel()
    }
    @Test func transportStreamUsesOneExactSharedEpisodeOrigin() async throws {
        let audio = try await open("mpeg-ts.ts", selection: .init(includeVideo: false))
        let video = try await open("mpeg-ts.ts", selection: .init(includeAudio: false))
        #expect(audio.metadata.timelineOrigin == video.metadata.timelineOrigin)
        #expect(audio.metadata.timelineOrigin > .zero)
        guard case .audio(let chunk) = try await audio.next(), case .video(let frame) = try await video.next() else {
            Issue.record("Missing first output"); await audio.cancel(); await video.cancel(); return
        }
        // Audio and video share one timeline, so they stay in sync (within 40 ms, one video frame).
        #expect(abs(chunk.presentationTime.seconds) <= 0.04)
        #expect(abs(frame.sourceRange.start.seconds - 1024.0 / 48_000) <= 0.04)
        await audio.cancel(); await video.cancel()
    }
    @Test func malformedAndInvalidTrackSelectionThrowInsteadOfEOF() async throws {
        await #expect(throws: (any Error).self) {
            try await FFmpegMediaReader.open(input: MemoryInput(Data(repeating: 0x55, count: 4096)))
        }
        await #expect(throws: (any Error).self) {
            try await open("video-multitrack.mp4", selection: .init(audioTrackID: 91))
        }
    }
    @Test func sourceDisplayRotationAndDimensionsAreExplicitMetadata() async throws {
        let reader = try await open("rotated.mp4")
        let track = try #require(reader.metadata.tracks.first { $0.kind == .video })
        #expect(track.width == 320 && track.height == 180 && track.pixelAspectRatio == 1)
        #expect(track.rotationDegrees == 90)
        await reader.cancel()
    }
    @Test(arguments: ["video-only.mp4", "video-multitrack.mp4"])
    func exactEndSeekDrainsWithoutInventingOutput(name: String) async throws {
        let reader = try await open(name, start: 8)
        #expect(try await reader.next() == nil)
        #expect(reader.bufferState.snapshot.isFinalBuffered)
        await reader.cancel()
    }
    @Test func embeddedArtworkRemainsAudioMediaWithoutAnImageDecoder() async throws {
        let reader = try await open("artwork.m4a")
        #expect(reader.metadata.selectedAudioTrackID != nil && reader.metadata.selectedVideoTrackID == nil)
        #expect(reader.metadata.tracks.filter { $0.kind == .video }.isEmpty)
        #expect(reader.metadata.tracks.contains { $0.kind == .other && $0.codec == "mjpeg" })
        var frames = 0
        while let event = try await reader.next() {
            if case .audio(let chunk) = event { frames += chunk.frameCount } else { Issue.record("Artwork decoded as video") }
        }
        #expect(abs(frames - 384_000) <= 2400)
        await reader.cancel()
    }
    @Test func audioTailSeekRetainsOneRealPosterWithoutInventingVideoDuration() async throws {
        let reader = try await open("audio-tail.mp4", selection: .init(includeAudio: false), start: 7)
        #expect(try await reader.next() == nil)
        let poster = try #require(await reader.videoPosterFrame())
        #expect(poster.sourceRange.start == CMTime(value: 76, timescale: 25))
        #expect(CMTimeRangeGetEnd(poster.sourceRange) == CMTime(value: 77, timescale: 25))
        #expect(pixel(poster).blue > 200 && pixel(poster).red < 20)
        #expect(reader.metadata.duration == CMTime(seconds: 8, preferredTimescale: 1))
        await reader.cancel()
        #expect(await reader.videoPosterFrame() == nil)
        #expect(pixel(poster).blue > 200) // Released codec never mutates the transferred picture.
    }
    @Test func existingPacketProducerRetainsRetryIdentityAndRejectsCachedProgress() async throws {
        let data = try fixture("ogg-flac.ogg"), retry = PCMSourceRetry()
        let producer = try await FFmpegPacketProducer.open(input: MemoryInput(data, retry: retry))
        #expect(producer.bufferState.sourceRetry === retry)
        var packets = 0
        while try await producer.next() != nil { packets += 1 }
        #expect(packets > 0 && producer.bufferState.snapshot.isFinalBuffered)
        #expect(!producer.bufferState.snapshot.isWaitingForSamples)
        let progress = retry.snapshot.extractedSamples
        #expect(progress > 0)
        await producer.cancel()
        for _ in 0..<4 { _ = try retry.plan(for: URLError(.timedOut), lengthKnown: true) }
        let replay = try await FFmpegPacketProducer.open(input: MemoryInput(data, retry: retry))
        while try await replay.next() != nil {}
        #expect(retry.snapshot.extractedSamples == progress && retry.currentError != nil)
        await replay.cancel()
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(4))
        while !predicate() && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(2)) }
        try #require(predicate())
    }
    private final class MemoryInput: MediaByteInput, @unchecked Sendable {
        let data: Data
        let sourceRetry: PCMSourceRetry?
        let condition = NSCondition()
        private var blocked = false, waiting = false, stopped = false
        init(_ data: Data, retry: PCMSourceRetry = PCMSourceRetry()) { self.data = data; sourceRetry = retry }
        var length: Int64? { Int64(data.count) }
        var supportsRandomAccess: Bool { true }
        var isWaitingForData: Bool { condition.withLock { waiting } }
        var cancelled: Bool { condition.withLock { stopped } }
        func prepareForSeek() {}
        func checkFailure() throws { if cancelled { throw CancellationError() } }
        func block() { condition.withLock { blocked = true } }
        func unblock() { condition.withLock { blocked = false; condition.broadcast() } }
        func cancel() { condition.withLock { stopped = true; condition.broadcast() } }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            condition.lock(); defer { waiting = false; condition.unlock() }
            while blocked && !stopped { waiting = true; sourceRetry?.notifyReadWaitChanged(); condition.wait() }
            if stopped { throw CancellationError() }
            guard offset >= 0, maximumCount > 0 else { throw FFmpegAudioReader.Failure.invalidSeek }
            guard offset < data.count else { return Data() }
            return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + maximumCount))
        }
    }
}
