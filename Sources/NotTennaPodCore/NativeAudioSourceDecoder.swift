import CoreMedia
import Foundation

/// A live decoder retains its item owner; cancelling it retires only its own
/// read scope. Metadata is the source timeline, independent of decoded length.
actor NativeAudioSourceDecoder: PCMDecoding {
    nonisolated let sampleRate: Int
    nonisolated let channels: Int
    nonisolated let startFrame: Int64
    nonisolated let startTime: CMTime
    nonisolated let sourceStartupTrim: PCMStartupTrim?
    nonisolated let bufferState: PCMBufferState?
    private nonisolated let initialDurationMilliseconds: Int64?
    nonisolated var sourceDurationMilliseconds: Int64? {
        bufferState?.snapshot.durationMicroseconds.map { $0 / 1000 } ?? initialDurationMilliseconds
    }
    nonisolated let sourceSeekable: Bool?
    nonisolated let sourceFailure: PCMSourceFailure?
    private let decoder: any PCMDecoding
    // Both remote and local actors own a stable encoded source across seeks.
    // Retention is the only relationship needed by the disposable decoder.
    private var owner: (any Actor)?
    private var first: NativePCMDecoder.Packet?
    private var ended = false, cancelled = false, reading = false

    static func open(decoder: any PCMDecoding, timeline: NativeAudioSourceTimeline,
                                 start: CMTime, admission: NativeAudioSeekAdmission,
                                 startupTrim: NativeMP4SourceTimeline.AudioTrim?,
                                 owner: any Actor) async throws -> NativeAudioSourceDecoder {
        let trim = try startupTrim.map { try PCMStartupTrim.mp4($0, sampleRate: decoder.sampleRate) }
        let frame = CMTimeConvertScale(start, timescale: Int32(decoder.sampleRate), method: .roundTowardZero)
        guard frame.isNumeric, frame.value >= 0 else { throw NativePCMDecoder.Failure.invalidStart }
        var first: NativePCMDecoder.Packet?
        while let packet = try await decoder.next() {
            try Task.checkCancellation()
            if let admitted = admission.admit(packet, at: start) {
                first = admitted
                break
            }
        }
        try Task.checkCancellation()
        let actualStart = admission == .wholeBuffer ? (first?.presentationTime ?? start)
            : CMTime(value: frame.value, timescale: Int32(decoder.sampleRate))
        return NativeAudioSourceDecoder(decoder: decoder, timeline: timeline, start: actualStart, first: first, trim: trim, owner: owner)
    }
    private init(decoder: any PCMDecoding, timeline: NativeAudioSourceTimeline, start: CMTime,
                 first: NativePCMDecoder.Packet?, trim: PCMStartupTrim?, owner: any Actor) {
        self.decoder = decoder; self.owner = owner; self.first = first; ended = first == nil
        sampleRate = decoder.sampleRate; channels = decoder.channels; startTime = start
        sourceStartupTrim = trim
        startFrame = CMTimeConvertScale(start, timescale: Int32(sampleRate), method: .roundTowardZero).value
        bufferState = decoder.bufferState
        initialDurationMilliseconds = timeline.durationMicroseconds.map { $0 / 1000 }
        sourceSeekable = timeline.seekable; sourceFailure = decoder.sourceFailure
    }
    func updatePlayback(_ state: PCMPlaybackLoadState) async throws {
        guard !cancelled else { throw CancellationError() }
        try await decoder.updatePlayback(state)
    }
    func next() async throws -> NativePCMDecoder.Packet? {
        guard !cancelled else { throw CancellationError() }
        guard !reading else { throw FFmpegPCMDecoder.Failure.concurrentRead }
        reading = true; defer { reading = false }
        do {
            try Task.checkCancellation(); try sourceFailure?.check()
            guard !ended else { return nil }
            if let first { self.first = nil; return first }
            let packet = try await decoder.next()
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            if packet == nil { ended = true }
            return packet
        } catch { await cancel(); throw error }
    }
    func cancel() async {
        cancelled = true; first = nil; owner = nil
        await decoder.cancel()
    }
    deinit {
        let decoder = decoder
        Task { await decoder.cancel() }
    }
}

/// The prepared source's explicit no-load end state. It owns no encoded queue,
/// converter or network work; this is source policy, not inferred PCM progress.
actor NativeAudioCompletedDecoder: PCMDecoding {
    nonisolated let sampleRate: Int, channels: Int
    nonisolated let startFrame: Int64
    nonisolated let bufferState: PCMBufferState?
    private var cancelled = false

    init(sampleRate: Int, channels: Int, start: CMTime, duration: Int64, retry: PCMSourceRetry? = nil) throws {
        let frame = CMTimeConvertScale(start, timescale: Int32(sampleRate), method: .roundTowardZero)
        guard frame.isNumeric, frame.value >= 0 else { throw NativePCMDecoder.Failure.invalidStart }
        self.sampleRate = sampleRate; self.channels = channels; startFrame = frame.value
        bufferState = PCMBufferState(.init(bufferedThroughMicroseconds: nil, allocatedBytes: 0,
            targetBytes: PlaybackLoadControl.audioTargetBytes, isLoading: false, isFinalBuffered: true,
            durationMicroseconds: duration, sourceSeekable: true), sourceRetry: retry)
    }
    func next() throws -> NativePCMDecoder.Packet? {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        return nil
    }
    func updatePlayback(_ state: PCMPlaybackLoadState) throws {
        guard !cancelled else { throw CancellationError() }
    }
    func cancel() { cancelled = true; bufferState?.finish() }
    deinit { bufferState?.finish() }
}
