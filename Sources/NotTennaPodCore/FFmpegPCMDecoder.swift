import CoreMedia
import Foundation

/// Adapts the local/progressive reader to the shared processing pipeline. Preparation retains just the
/// first admitted chunk so the sink starts at its actual PTS, including seeks past the target.
/// No filename routing or application engine selection is implied by this internal adapter.
actor FFmpegPCMDecoder: PCMDecoding {
    enum Failure: Error, Equatable { case invalidTimestamp, cancelled, concurrentRead }
    nonisolated let sampleRate: Int
    nonisolated let channels: Int
    nonisolated let startFrame: Int64
    nonisolated let startTime: CMTime
    nonisolated var sourceFailure: PCMSourceFailure? { reader.sourceFailure }
    nonisolated var bufferState: PCMBufferState? { reader.bufferState }
    private let reader: FFmpegAudioReader
    private var sourceOwner: FFmpegPlaybackSource?
    private var first: FFmpegAudioReader.Chunk?
    private var ended: Bool
    private var cancelled = false
    private var reading = false

    @concurrent static func openBuffered(url: URL, start: CMTime = .zero,
                                        maximumFrames: Int = 4096,
                                        prepareSourceTimeline: Bool = false,
                                        targetBytes: Int64 = PlaybackLoadControl.audioTargetBytes) async throws -> FFmpegPCMDecoder {
        let reader: FFmpegAudioReader
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            reader = try await FFmpegAudioReader.openBuffered(input: HTTPCodecByteInput(url: url),
                maximumFrames: maximumFrames, timing: .media3, targetBytes: targetBytes)
        } else {
            reader = try await FFmpegAudioReader.openBuffered(url: url, maximumFrames: maximumFrames, timing: .media3, targetBytes: targetBytes)
        }
        return try await prepare(reader: reader, start: start, sourceTimeline: prepareSourceTimeline)
    }

    @concurrent static func openBuffered(input: any MediaByteLeaseSource, start: CMTime = .zero,
                                        maximumFrames: Int = 4096, prepareSourceTimeline: Bool = false) async throws -> FFmpegPCMDecoder {
        let reader = try await FFmpegAudioReader.openBuffered(input: input, maximumFrames: maximumFrames, timing: .media3)
        return try await prepare(reader: reader, start: start, sourceTimeline: prepareSourceTimeline)
    }

    @concurrent static func open(url: URL, start: CMTime = .zero,
                                maximumFrames: Int = 4096) async throws -> FFmpegPCMDecoder {
        let reader: FFmpegAudioReader
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            let input = try HTTPCodecByteInput(url: url)
            reader = try await FFmpegAudioReader.open(input: input, maximumFrames: maximumFrames, timing: .media3)
        } else {
            reader = try FFmpegAudioReader(url: url, maximumFrames: maximumFrames, timing: .media3)
        }
        return try await prepare(reader: reader, start: start)
    }

    @concurrent static func open(input: any MediaByteInput, start: CMTime = .zero,
                                maximumFrames: Int = 4096) async throws -> FFmpegPCMDecoder {
        let reader = try await FFmpegAudioReader.open(input: input, maximumFrames: maximumFrames, timing: .media3)
        return try await prepare(reader: reader, start: start)
    }

    static func openPrepared(reader: FFmpegAudioReader, start: CMTime,
                             owner: FFmpegPlaybackSource) async throws -> FFmpegPCMDecoder {
        try await prepare(reader: reader, start: start, seek: false, owner: owner)
    }

    private static func prepare(reader: FFmpegAudioReader, start: CMTime, sourceTimeline: Bool = false,
                                seek: Bool = true, owner: FFmpegPlaybackSource? = nil) async throws -> FFmpegPCMDecoder {
        do {
            var target = start
            if sourceTimeline, try await reader.prepareSourceTimeline() == false,
               start.isNumeric, start.epoch == 0, start >= .zero {
                // ProgressiveMediaPeriod maps every valid unseekable target to zero.
                // Invalid times still reach the reader's normal validation.
                target = .zero
            }
            if seek { try await reader.seek(to: target) }
            let first = try await reader.next()
            try Task.checkCancellation()
            let anchor = max(.zero, first?.presentationTime ?? target)
            guard anchor.isNumeric, anchor.epoch == 0,
                  CMTimeConvertScale(anchor, timescale: 1_000_000, method: .roundTowardZero).isNumeric,
                  CMTimeConvertScale(anchor, timescale: Int32(reader.sampleRate), method: .roundTowardZero).isNumeric else {
                throw Failure.invalidTimestamp
            }
            return FFmpegPCMDecoder(reader: reader, first: first, startTime: anchor, owner: owner)
        } catch {
            await reader.cancel()
            throw error
        }
    }

    private init(reader: FFmpegAudioReader, first: FFmpegAudioReader.Chunk?, startTime: CMTime,
                 owner: FFmpegPlaybackSource? = nil) {
        self.reader = reader
        sourceOwner = owner
        self.first = first
        ended = first == nil
        self.startTime = startTime
        sampleRate = reader.sampleRate
        channels = reader.channels
        startFrame = CMTimeConvertScale(startTime, timescale: Int32(reader.sampleRate), method: .roundTowardZero).value
    }

    func next() async throws -> NativePCMDecoder.Packet? {
        guard !cancelled else { throw Failure.cancelled }
        guard !reading else { throw Failure.concurrentRead }
        reading = true
        defer { reading = false }
        do {
            try Task.checkCancellation()
            guard !ended else { return nil }
            let chunk: FFmpegAudioReader.Chunk?
            if let prepared = first {
                try await reader.checkFailure()
                first = nil
                chunk = prepared
            }
            else { chunk = try await reader.next() }
            try Task.checkCancellation()
            guard !cancelled else { throw Failure.cancelled }
            guard let chunk else { ended = true; return nil }
            guard chunk.presentationTime.isNumeric, chunk.presentationTime.epoch == 0 else { throw Failure.invalidTimestamp }
            return NativePCMDecoder.Packet(samples: chunk.samples, sampleRate: sampleRate, channels: channels,
                presentationTime: chunk.presentationTime, startsDecodedBuffer: chunk.startsDecodedBuffer)
        } catch {
            await cancel()
            throw error
        }
    }

    func cancel() async {
        cancelled = true
        first = nil
        await reader.cancel()
        sourceOwner = nil
    }

    func updatePlayback(_ state: PCMPlaybackLoadState) async throws {
        guard !cancelled else { throw Failure.cancelled }
        try Task.checkCancellation()
        try await reader.updatePlayback(positionMicroseconds: state.positionMicroseconds, speed: state.speed)
    }

    func producerSnapshot() async -> FFmpegPacketProducer.Snapshot? {
        if let sourceOwner { return await sourceOwner.producerSnapshot() }
        return await reader.producerSnapshot()
    }
}
