import CoreMedia
import Foundation

/// Independent track pulls over one captured representation. Neither pull stages
/// pictures for the other: a far-ahead video track cannot consume the storage or
/// progress needed to decode audio and produce its presentation mapping.
actor FFmpegPlaybackMediaAdapter: PlaybackVideoDecoding {
    enum Failure: Error { case noAudio, invalidFormat, concurrentRead, cancelled }
    nonisolated let metadata: FFmpegMediaMetadata
    private let audioReader: FFmpegMediaReader?
    private let videoReader: FFmpegMediaReader?
    private var owner: (any Actor)?
    private var audioReading = false, videoReading = false, cancelled = false
    private let start: CMTime

    static func open(input: any MediaByteLeaseSource, metadata: FFmpegMediaMetadata,
                     audioTrackID: Int32? = nil, start: CMTime, owner: (any Actor)? = nil) async throws -> FFmpegPlaybackMediaAdapter {
        let selectedAudio = audioTrackID ?? metadata.selectedAudioTrackID
        var audio: FFmpegMediaReader?, video: FFmpegMediaReader?
        do {
            if let selectedAudio {
                audio = try await FFmpegMediaReader.open(input: input.makeReadLease(),
                    selection: .init(audioTrackID: selectedAudio, includeAudio: true, includeVideo: false), start: start)
            }
            if let selectedVideo = metadata.selectedVideoTrackID {
                video = try await FFmpegMediaReader.open(input: input.makeReadLease(),
                    selection: .init(videoTrackID: selectedVideo, includeAudio: false, includeVideo: true), start: start)
            }
            try Task.checkCancellation()
            return FFmpegPlaybackMediaAdapter(audio: audio, video: video, metadata: metadata, start: start, owner: owner)
        } catch {
            audio?.stop(); video?.stop()
            await audio?.cancel(); await video?.cancel()
            throw error
        }
    }

    private init(audio: FFmpegMediaReader?, video: FFmpegMediaReader?, metadata: FFmpegMediaMetadata,
                 start: CMTime, owner: (any Actor)?) {
        audioReader = audio; videoReader = video; self.metadata = metadata; self.start = start; self.owner = owner
    }
    deinit { audioReader?.stop(); videoReader?.stop() }

    func makeAudioDecoder() async throws -> (any PCMDecoding)? {
        guard !cancelled else { throw Failure.cancelled }
        guard let audioReader else { return nil }
        let first = try await nextAudio()
        let track = audioReader.metadata.tracks.first { $0.id == audioReader.metadata.selectedAudioTrackID }
        let rate = first?.sampleRate ?? track?.sampleRate ?? 0
        // Decoded surround plays as stereo (`PCMStereoDownmix`).
        let channels = first?.channels ?? track.map { min(2, $0.channels) } ?? 0
        guard rate > 0, rate <= Int32.max, channels > 0 else { throw Failure.invalidFormat }
        return Audio(owner: self, reader: audioReader, first: first, rate: rate, channels: channels,
            start: max(.zero, first?.presentationTime ?? start))
    }

    private func nextAudio() async throws -> FFmpegAudioReader.Chunk? {
        guard !cancelled else { throw Failure.cancelled }
        guard !audioReading else { throw Failure.concurrentRead }
        guard let audioReader else { return nil }
        audioReading = true; defer { audioReading = false }
        while let event = try await audioReader.next() {
            guard !cancelled else { throw Failure.cancelled }
            if case .audio(let chunk) = event { return chunk }
        }
        return nil
    }
    func nextVideoFrame() async throws -> PlaybackVideoFrame? {
        guard !cancelled else { throw Failure.cancelled }
        guard !videoReading else { throw Failure.concurrentRead }
        guard let videoReader else { return nil }
        videoReading = true; defer { videoReading = false }
        while let event = try await videoReader.next() {
            guard !cancelled else { throw Failure.cancelled }
            if case .video(let frame) = event { return frame }
        }
        return nil
    }
    func videoPosterFrame() async -> PlaybackVideoFrame? {
        guard !cancelled else { return nil }
        let frame = await videoReader?.videoPosterFrame()
        return cancelled ? nil : frame
    }
    private func checkActive() throws { guard !cancelled else { throw Failure.cancelled } }
    func cancelVideo() async { await cancel() }
    func cancel() async {
        guard !cancelled else { return }
        cancelled = true
        audioReader?.stop(); videoReader?.stop()
        await audioReader?.cancel(); await videoReader?.cancel()
        owner = nil
    }

    private actor Audio: PCMDecoding {
        nonisolated let sampleRate: Int
        nonisolated let channels: Int
        nonisolated let startTime: CMTime
        nonisolated let startFrame: Int64
        nonisolated let bufferState: PCMBufferState?
        nonisolated let sourceFailure: PCMSourceFailure?
        private nonisolated let preparedDurationMilliseconds: Int64?
        nonisolated var sourceDurationMilliseconds: Int64? {
            bufferState?.snapshot.durationMicroseconds.map { $0 / 1000 } ?? preparedDurationMilliseconds
        }
        nonisolated let sourceSeekable: Bool?
        private var owner: FFmpegPlaybackMediaAdapter?
        private var first: FFmpegAudioReader.Chunk?
        private var reading = false
        init(owner: FFmpegPlaybackMediaAdapter, reader: FFmpegMediaReader, first: FFmpegAudioReader.Chunk?,
             rate: Int, channels: Int, start: CMTime) {
            self.owner = owner; self.first = first; sampleRate = rate; self.channels = channels; startTime = start
            startFrame = CMTimeConvertScale(start, timescale: Int32(rate), method: .roundTowardZero).value
            bufferState = reader.bufferState; sourceFailure = reader.sourceFailure
            preparedDurationMilliseconds = reader.metadata.duration.map { CMTimeConvertScale($0, timescale: 1000, method: .roundTowardZero).value }
            sourceSeekable = reader.metadata.sourceSeekable
        }
        func next() async throws -> NativePCMDecoder.Packet? {
            guard let owner else { throw Failure.cancelled }
            guard !reading else { throw Failure.concurrentRead }
            reading = true; defer { reading = false }
            try await owner.checkActive()
            let chunk: FFmpegAudioReader.Chunk?
            if let first { chunk = first; self.first = nil } else { chunk = try await owner.nextAudio() }
            guard self.owner != nil else { throw Failure.cancelled }
            guard let chunk else { return nil }
            guard chunk.sampleRate == sampleRate, chunk.channels == channels else { throw Failure.invalidFormat }
            return .init(samples: chunk.samples, sampleRate: sampleRate, channels: channels,
                presentationTime: chunk.presentationTime, startsDecodedBuffer: chunk.startsDecodedBuffer)
        }
        func cancel() async {
            let old = owner; owner = nil; first = nil
            await old?.cancel()
        }
    }
}
