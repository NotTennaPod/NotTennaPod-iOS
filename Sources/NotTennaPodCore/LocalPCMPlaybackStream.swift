import CoreMedia
import Foundation

/// Pull-driven decoder/processor chain. Construct on the engine's worker task, then pull only
/// when the output queue has capacity. Producer counters are not a playback-position clock.
public actor LocalPCMPlaybackStream {
    public struct Parameters: Equatable, Sendable {
        public let speed: Float
        public let skipSilence: Bool
    }
    public struct Segment: Equatable, Sendable {
        public let id: UUID
        public let parameters: Parameters
        public let mediaStartTime: CMTime
        /// Sample-grid diagnostic only. Clocks must use mediaStartMicroseconds.
        public let mediaStartFrame: Int64
        public let outputStartFrame: Int64

        public var mediaStartMicroseconds: Int64 {
            CMTimeConvertScale(mediaStartTime, timescale: 1_000_000, method: .roundTowardZero).value
        }

        init(id: UUID, parameters: Parameters, mediaStartTime: CMTime, sampleRate: Int, outputStartFrame: Int64) {
            self.id = id
            self.parameters = parameters
            self.mediaStartTime = max(.zero, mediaStartTime)
            mediaStartFrame = CMTimeConvertScale(self.mediaStartTime, timescale: Int32(sampleRate), method: .roundTowardZero).value
            self.outputStartFrame = outputStartFrame
        }
    }
    public struct Packet: Sendable {
        public let samples: [Int16]
        public let progress: PCMProcessingProgress
        public let segment: Segment
        public let outputStartFrame: Int64
        public let videoTimelineSpans: [PlaybackVideoTimeline.Span]
        /// Skip-silence removals heard within this packet's output, in output order.
        public let heardSkips: [PCMHeardSkip]
    }
    public enum Failure: Error, Equatable { case invalidCapacity, invalidInput, cancelled, concurrentRead }
    public nonisolated let sampleRate: Int
    public nonisolated let channels: Int
    public nonisolated let maximumOutputFrames: Int
    public var speed: Float { segment.parameters.speed }
    public var requestedParameters: Parameters { pendingChange?.parameters ?? segment.parameters }
    public private(set) var segment: Segment
    public private(set) var decodedFrames: Int64 = 0
    public private(set) var deliveredFrames: Int64 = 0
    /// Current segment count: resets on processing changes, as in the original sink.
    public var skippedFrames: Int64 { processor?.skippedFrames ?? 0 }
    /// Lifetime diagnostic; do not substitute this for the current segment count in the clock.
    public var totalSkippedFrames: Int64 { completedSkippedFrames + skippedFrames }
    private let decoder: any PCMDecoding
    private let startupTrim: PCMStartupTrim?
    nonisolated let sourceFailure: PCMSourceFailure?
    nonisolated let bufferState: PCMBufferState?
    nonisolated var sourceDurationMilliseconds: Int64? { decoder.sourceDurationMilliseconds }
    nonisolated var sourceSeekable: Bool? { decoder.sourceSeekable }
    private var inputTimeline: PCMInputTimeline
    private var processor: SilenceSkippingProcessor?
    private var speedProcessor: PCMSpeedProcessor?
    private var speedInputFrames: Int64 = 0
    private var completedSkippedFrames: Int64 = 0
    private var pendingChange: PreparedParameters?
    private var drainedForChange = false
    private var heldInput: NativePCMDecoder.Packet?
    private var pending: [Int16] = []
    private var offset = 0
    private var ended = false
    private var cancelled = false
    private var reading = false
    private var videoMappingEnabled = false
    private var videoComposer: PCMVideoSpanComposer?
    private var pendingVideoSpans: [PlaybackVideoTimeline.Span] = []
    private var skipMapper: PCMHeardSkipMapper?
    private var pendingHeardSkips: [PCMHeardSkip] = []

    /// Must be enabled before the first pull. Audio-only clients keep their existing
    /// allocation/mapping behavior; video consumes the same processors' observations.
    func enableVideoTimeline() throws {
        guard deliveredFrames == 0, decodedFrames == 0, !reading else { throw Failure.invalidInput }
        videoMappingEnabled = true
        videoComposer = PCMVideoSpanComposer(sourceAnchor: segment.mediaStartTime,
            outputAnchor: segment.outputStartFrame, sampleRate: Int32(sampleRate))
    }

    func takeFinalVideoTimelineSpans() -> [PlaybackVideoTimeline.Span] {
        takeVideoSpans(through: deliveredFrames)
    }

    /// At EOF, after the last packet: removals of a skipped-only tail that emitted no packet.
    func takeFinalHeardSkips() -> [PCMHeardSkip] {
        defer { pendingHeardSkips.removeAll() }
        return pendingHeardSkips
    }

    public init(url: URL, start: CMTime = .zero, skipSilence: Bool, speed: Float = 1,
                maximumOutputFrames: Int = 4096) throws {
        guard (1...65_536).contains(maximumOutputFrames) else { throw Failure.invalidCapacity }
        try self.init(decoder: NativePCMDecoder(url: url, start: start), skipSilence: skipSilence,
                      speed: speed, maximumOutputFrames: maximumOutputFrames)
    }

    init(decoder: any PCMDecoding, skipSilence: Bool, speed: Float = 1,
         maximumOutputFrames: Int = 4096) throws {
        guard (1...65_536).contains(maximumOutputFrames) else { throw Failure.invalidCapacity }
        self.decoder = decoder
        startupTrim = decoder.sourceStartupTrim
        sourceFailure = decoder.sourceFailure
        bufferState = decoder.bufferState
        sampleRate = decoder.sampleRate
        channels = decoder.channels
        try startupTrim?.validate(sampleRate: sampleRate)
        guard decoder.startTime.isNumeric, decoder.startTime.epoch == 0,
              CMTimeConvertScale(decoder.startTime, timescale: 1_000_000, method: .roundTowardZero).isNumeric else {
            throw Failure.invalidInput
        }
        inputTimeline = try PCMInputTimeline(sampleRate: sampleRate)
        self.maximumOutputFrames = maximumOutputFrames
        let prepared = try PreparedParameters(sampleRate: sampleRate, channels: channels,
                                               speed: speed, skipSilence: skipSilence)
        processor = prepared.silence
        speedProcessor = prepared.speed
        segment = Segment(id: UUID(), parameters: prepared.parameters,
                          mediaStartTime: decoder.startTime, sampleRate: sampleRate, outputStartFrame: 0)
        skipMapper = prepared.silence == nil ? nil : PCMHeardSkipMapper(segmentOutputStart: 0)
    }

    /// The latest requested values win before the next input boundary. Duplicate requests are
    /// ignored, following ExoPlayerImpl; A→B→A still drains, as its messages reached the sink.
    /// Validation is atomic. A request after source EOF affects no already-produced audio.
    public func setParameters(speed: Float, skipSilence: Bool) throws {
        guard !cancelled else { throw Failure.cancelled }
        let prepared = try PreparedParameters(sampleRate: sampleRate, channels: channels,
                                               speed: speed, skipSilence: skipSilence)
        guard prepared.parameters != requestedParameters else { return }
        pendingChange = prepared
    }

    public func next() async throws -> [Int16]? {
        try await nextPacket()?.samples
    }

    /// May run while a pull awaits more encoded data. Loading must be able to resume
    /// from presentation progress even when the consumer is waiting on that loader.
    func updatePlayback(_ state: PCMPlaybackLoadState) async throws {
        guard !cancelled else { throw Failure.cancelled }
        try Task.checkCancellation()
        try await decoder.updatePlayback(state)
    }

    /// Samples and producer statistics are captured together, before another pull can advance
    /// the processors. Packets never cross segments. Their output frame offsets describe the
    /// ordered producer stream; output must accept every packet in order or reset the timeline.
    /// At EOF use `progress` to include any final skipped-only input.
    public func nextPacket() async throws -> Packet? {
        guard !cancelled else { throw Failure.cancelled }
        guard !reading else { throw Failure.concurrentRead }
        reading = true
        defer { reading = false }
        do {
            var result: [Int16] = []
            let capacity = maximumOutputFrames * channels
            result.reserveCapacity(capacity)
            while result.count < capacity {
                try Task.checkCancellation()
                guard !cancelled else { throw Failure.cancelled }
                try sourceFailure?.check()
                if offset < pending.count {
                    let end = min(pending.count, offset + capacity - result.count)
                    result.append(contentsOf: pending[offset..<end])
                    offset = end
                    if offset == pending.count { pending.removeAll(keepingCapacity: true); offset = 0 }
                    continue
                }
                guard !ended else { break }
                if pendingChange != nil {
                    if !drainedForChange {
                        pending = try drain()
                        drainedForChange = true
                        continue
                    }
                    // Finish the old packet before changing its processing statistics or ID.
                    if !result.isEmpty { break }
                    if heldInput == nil { heldInput = try await readInput() }
                    guard let packet = heldInput else { ended = true; break }
                    guard let change = pendingChange else { throw Failure.cancelled }
                    completedSkippedFrames += skippedFrames
                    processor = change.silence
                    speedProcessor = change.speed
                    speedInputFrames = 0
                    segment = Segment(id: UUID(), parameters: change.parameters,
                                      mediaStartTime: packet.presentationTime, sampleRate: sampleRate,
                                      outputStartFrame: deliveredFrames)
                    skipMapper = change.silence == nil ? nil : PCMHeardSkipMapper(segmentOutputStart: deliveredFrames)
                    if videoMappingEnabled {
                        videoComposer = PCMVideoSpanComposer(sourceAnchor: segment.mediaStartTime,
                            outputAnchor: deliveredFrames, sampleRate: Int32(sampleRate))
                    }
                    pendingChange = nil
                    drainedForChange = false
                    heldInput = nil
                    try process(packet)
                    continue
                }
                if heldInput == nil { heldInput = try await readInput() }
                guard let packet = heldInput else {
                    ended = true
                    pending = try drain()
                    continue
                }
                // A control request can arrive while the actor awaits decoding. Keep that
                // single decoded packet unprocessed until the old chain has drained.
                if pendingChange != nil { continue }
                if try inputTimeline.boundary(presentationMicroseconds: microseconds(packet),
                    startsDecodedBuffer: packet.startsDecodedBuffer, discontinuity: packet.discontinuity).requiresDrain {
                    // Preserve the held input while emitting the old processors' complete tail.
                    // Parameter requests arriving during this drain still replace these values.
                    pendingChange = try PreparedParameters(sampleRate: sampleRate, channels: channels,
                        speed: speed, skipSilence: segment.parameters.skipSilence)
                    continue
                }
                heldInput = nil
                try process(packet)
            }
            try sourceFailure?.check()
            guard !result.isEmpty else { return nil }
            let end = deliveredFrames + Int64(result.count / channels)
            let heard = pendingHeardSkips.prefix { $0.outputFrame <= end }
            pendingHeardSkips.removeFirst(heard.count)
            let packet = Packet(samples: result, progress: try progress, segment: segment,
                                outputStartFrame: deliveredFrames,
                                videoTimelineSpans: takeVideoSpans(through: end), heardSkips: Array(heard))
            deliveredFrames += Int64(result.count / channels)
            return packet
        } catch {
            // A failed/cancelled pull may already have consumed codec input. Make the stream
            // terminal so resuming cannot silently omit partially assembled output.
            cancelled = true
            pending.removeAll()
            heldInput = nil
            await decoder.cancel()
            throw error
        }
    }

    public var progress: PCMProcessingProgress {
        get throws {
            try PCMProcessingProgress(speed: speed, channels: channels,
                                      inputFrames: speedProcessor?.inputFrames ?? speedInputFrames,
                                      pendingInputFrames: Int64(speedProcessor?.pendingInputFrames ?? 0),
                                      outputFrames: speedProcessor?.outputFrames ?? speedInputFrames,
                                      skippedFrames: skippedFrames,
                                      speedProcessingActive: speedProcessor != nil)
        }
    }

    public func cancel() async {
        cancelled = true
        pending.removeAll()
        pendingHeardSkips.removeAll()
        heldInput = nil
        pendingChange = nil
        await decoder.cancel()
    }

    private func readInput() async throws -> NativePCMDecoder.Packet? {
        let packet = try await decoder.next()
        try Task.checkCancellation()
        guard !cancelled else { throw Failure.cancelled }
        if let packet {
            guard packet.sampleRate == sampleRate, packet.channels == channels,
                  !packet.samples.isEmpty, packet.samples.count % channels == 0,
                  packet.presentationTime.isNumeric, packet.presentationTime.epoch == 0,
                  CMTimeConvertScale(packet.presentationTime, timescale: 1_000_000, method: .roundTowardZero).isNumeric else {
                throw Failure.invalidInput
            }
            decodedFrames += Int64(packet.frameCount)
        }
        return packet
    }

    private func process(_ packet: NativePCMDecoder.Packet) throws {
        let trimmed = try startupTrim?.framesToRemove(at: packet.uneditedTime ?? packet.presentationTime,
            frames: packet.frameCount, sampleRate: sampleRate) ?? 0
        try inputTimeline.submit(presentationMicroseconds: microseconds(packet), frames: packet.frameCount,
                                 startsDecodedBuffer: packet.startsDecodedBuffer, discontinuity: packet.discontinuity,
                                 trimmedFrames: trimmed)
        guard trimmed < packet.frameCount else { return }
        let retained = trimmed == 0 ? packet.samples : Array(packet.samples.dropFirst(trimmed * channels))
        let samples = try processor?.process(retained) ?? retained
        if videoMappingEnabled {
            let count = Int64(retained.count / channels)
            videoComposer?.appendSilence(processor?.timelineSpans ?? [PCMProcessingSpan(
                input: speedInputFrames..<(speedInputFrames + count), output: speedInputFrames..<(speedInputFrames + count))])
        }
        skipMapper?.appendSilence(processor?.timelineSpans ?? [])
        let before = speedInputFrames
        speedInputFrames += Int64(samples.count / channels)
        pending = try speedProcessor?.process(samples) ?? samples
        consumeSpeedSpans(after: before)
    }

    /// Place this call's speed consumption on the output for video and for heard skips.
    private func consumeSpeedSpans(after before: Int64) {
        guard videoMappingEnabled || skipMapper != nil else { return }
        let spans = speedProcessor?.timelineSpans ?? (speedInputFrames > before
            ? [PCMProcessingSpan(input: before..<speedInputFrames, output: before..<speedInputFrames)] : [])
        if videoMappingEnabled { pendingVideoSpans += videoComposer?.consumeSpeed(spans) ?? [] }
        pendingHeardSkips += skipMapper?.consumeSpeed(spans) ?? []
    }

    private func microseconds(_ packet: NativePCMDecoder.Packet) -> Int64 {
        CMTimeConvertScale(packet.presentationTime, timescale: 1_000_000, method: .roundTowardZero).value
    }

    private func drain() throws -> [Int16] {
        let tail = processor?.finish() ?? []
        if videoMappingEnabled { videoComposer?.appendSilence(processor?.timelineSpans ?? []) }
        skipMapper?.appendSilence(processor?.timelineSpans ?? [])
        let before = speedInputFrames
        speedInputFrames += Int64(tail.count / channels)
        let first = try speedProcessor?.process(tail) ?? tail
        consumeSpeedSpans(after: before)
        let second = speedProcessor?.finish() ?? []
        let end = segment.outputStartFrame + (speedProcessor?.outputFrames ?? speedInputFrames)
        if videoMappingEnabled {
            pendingVideoSpans += videoComposer?.consumeSpeed(speedProcessor?.timelineSpans ?? []) ?? []
            pendingVideoSpans += videoComposer?.finish(at: end) ?? []
        }
        pendingHeardSkips += skipMapper?.consumeSpeed(speedProcessor?.timelineSpans ?? []) ?? []
        pendingHeardSkips += skipMapper?.finish(atOutputFrame: end) ?? []
        return first + second
    }

    private func takeVideoSpans(through frame: Int64) -> [PlaybackVideoTimeline.Span] {
        let end = CMTime(value: frame, timescale: Int32(sampleRate))
        var result: [PlaybackVideoTimeline.Span] = []
        while let span = pendingVideoSpans.first, span.presentation.start <= end {
            if span.presentation.end <= end { result.append(pendingVideoSpans.removeFirst()); continue }
            guard span.presentation.start < end else { break }
            let sourceEnd = PlaybackTimeMapping.map(end, fromRange: span.presentation, toRange: span.source)
            result.append(.init(source: CMTimeRange(start: span.source.start, end: sourceEnd),
                                presentation: CMTimeRange(start: span.presentation.start, end: end)))
            pendingVideoSpans[0] = .init(source: CMTimeRange(start: sourceEnd, end: span.source.end),
                                       presentation: CMTimeRange(start: end, end: span.presentation.end))
            break
        }
        return result
    }

    private struct PreparedParameters {
        let parameters: Parameters
        let silence: SilenceSkippingProcessor?
        let speed: PCMSpeedProcessor?

        init(sampleRate: Int, channels: Int, speed: Float, skipSilence: Bool) throws {
            guard speed.isFinite, (0.5...4).contains(speed) else { throw PCMSpeedProcessor.Failure.invalidSpeed }
            parameters = Parameters(speed: speed, skipSilence: skipSilence)
            silence = skipSilence ? try SilenceSkippingProcessor(sampleRate: sampleRate, channels: channels) : nil
            // Default SonicAudioProcessor wrapper's bypass differs from Sonic's own threshold.
            self.speed = abs(speed - 1) < Float(0.0001) ? nil
                : try PCMSpeedProcessor(sampleRate: sampleRate, channels: channels, speed: speed)
        }
    }
}
