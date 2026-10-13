import CFFmpegCodec
import CoreMedia
import CoreVideo
import Foundation

/// One serialized demux/decode owner. Events retain their storage and source time;
/// the playback adapter fans them out into bounded audio/video queues. No renderer,
/// network retry policy or processed-presentation clock lives in this layer.
actor FFmpegMediaReader {
    enum Event: Sendable {
        case audio(FFmpegAudioReader.Chunk)
        case video(PlaybackVideoFrame)
    }
    enum Failure: Error { case invalidSelection, invalidTimestamp, formatChanged, capacity, decoding(Int32), cancelled }
    nonisolated let metadata: FFmpegMediaMetadata
    nonisolated let bufferState: PCMBufferState
    nonisolated var sourceFailure: PCMSourceFailure? { input.sourceFailure }
    nonisolated private let input: any MediaByteInput
    nonisolated private let executor: BlockingReadExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let status: InputStatus
    private var demux: FFmpegDemuxContext?
    private var decoders: [Int32: Decoder] = [:]
    private var pendingStream: Int32?
    private var initialPacket: FFmpegEncodedPacket?
    private var flushIndices: [Int32] = []
    private var ended = false, cancelled = false
    private var seekTarget: CMTime
    private var decodedEnd = CMTime.zero
    private var lastVideoFrame: PlaybackVideoFrame?

    static func open(input: any MediaByteInput, selection: FFmpegMediaSelection = .automatic,
                     start: CMTime = .zero) async throws -> FFmpegMediaReader {
        guard start.isNumeric, start.epoch == 0, start >= .zero else { throw FFmpegAudioReader.Failure.invalidSeek }
        let executor = BlockingReadExecutor()
        return try await withTaskCancellationHandler {
            let reader = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FFmpegMediaReader, any Error>) in
                executor.queue.async {
                    do { continuation.resume(returning: try FFmpegMediaReader(input: input, selection: selection, start: start, executor: executor)) }
                    catch { input.cancel(); continuation.resume(throwing: error) }
                }
            }
            do { try Task.checkCancellation(); return reader }
            catch { await reader.cancel(); throw error }
        } onCancel: { input.cancel() }
    }

    private init(input: any MediaByteInput, selection: FFmpegMediaSelection, start: CMTime,
                 executor: BlockingReadExecutor) throws {
        self.input = input; self.executor = executor
        if start > .zero { input.prepareForSeek() }
        let demux = try FFmpegDemuxContext(url: nil, byteInput: input, mediaSelection: selection)
        guard let metadata = demux.mediaMetadata else { throw Failure.invalidSelection }
        self.metadata = metadata; self.demux = demux
        seekTarget = metadata.sourceSeekable ? start : .zero
        status = InputStatus(input: input, metadata: metadata)
        bufferState = status.bufferState
        // WAV IMA packet offsets describe exact block positions; generic PCM seek
        // timestamps instead use a rounded average byte rate. Capture the original
        // data-block origin once, without reading or staging the rest of the file.
        if demux.configurations.values.contains(where: \.usesIMAByteClock) { initialPacket = try demux.next() }
        for (index, config) in demux.configurations {
            guard let track = metadata.tracks.first(where: { $0.id == index }) else { throw Failure.invalidSelection }
            decoders[index] = try Decoder(configuration: config, track: track, audioByteOrigin: config.usesIMAByteClock ? initialPacket?.bytePosition : nil)
        }
        if seekTarget > .zero {
            // Decode from before the requested audio packet: decoder priming and
            // overlap consume complete frames after a fresh context starts. The
            // caller's requested cut remains seekTarget and is trimmed precisely.
            var anchor = seekTarget
            if let config = demux.configurations[demux.streamIndex], config.sampleRate > 0 {
                let preroll = max(config.seekPreroll, max(config.initialPadding, config.frameSize))
                anchor = max(.zero, CMTimeSubtract(anchor, CMTime(value: Int64(preroll), timescale: config.sampleRate)))
            }
            if metadata.containerName == "mpegts", let video = metadata.selectedVideoTrackID,
               let configuration = demux.configurations[video] {
                anchor = try Self.refineTransportStreamSeek(demux: demux, input: input,
                    video: video, configuration: configuration, target: seekTarget, anchor: anchor,
                    origin: metadata.timelineOrigin)
            }
            anchor = CMTimeAdd(anchor, metadata.timelineOrigin)
            let timestamp = CMTimeConvertScale(anchor, timescale: demux.timeBase.den, method: .roundTowardNegativeInfinity)
            guard timestamp.isNumeric else { throw FFmpegAudioReader.Failure.invalidSeek }
            try demux.seekBackward(to: timestamp.value / Int64(demux.timeBase.num))
            initialPacket = nil
        }
        status.start()
    }

    /// FFmpeg's MPEG-TS timestamp index explicitly marks DTS entries as keyframes
    /// without inspecting their keyframe flag (mpegts_get_dts). Verify the first
    /// decoded picture and back up only when that seek skipped the requested GOP.
    /// Backoff derives from the observed gap/frame duration, retains no frames and
    /// terminates at source start. Container indexes for other formats stay native.
    private static func refineTransportStreamSeek(demux: FFmpegDemuxContext, input: any MediaByteInput,
        video: Int32, configuration: FFmpegStreamConfiguration, target: CMTime,
        anchor initialAnchor: CMTime, origin: CMTime) throws -> CMTime {
        var anchor = initialAnchor, distance = CMTime.zero
        while anchor > .zero {
            try input.checkFailure()
            let absolute = CMTimeConvertScale(CMTimeAdd(anchor, origin), timescale: demux.timeBase.den, method: .roundTowardNegativeInfinity)
            try demux.seekBackward(to: absolute.value / Int64(demux.timeBase.num))
            var context: UnsafeMutablePointer<AVCodecContext>? = try configuration.makeCodecContext(manualSkip: false)
            var frame = av_frame_alloc()
            defer { av_frame_free(&frame); avcodec_free_context(&context) }
            guard let context, let frame else { throw FFmpegAudioReader.Failure.allocation }
            var first: CMTime?, frameDuration = CMTime(value: 1, timescale: configuration.timeBase.den)
            var eof = false
            while first == nil {
                try input.checkFailure()
                let received = avcodec_receive_frame(context, frame)
                if received >= 0 {
                    let raw = frame.pointee
                    if raw.best_effort_timestamp != Int64.min {
                        first = CMTimeSubtract(CMTimeMultiplyByRatio(CMTime(value: raw.best_effort_timestamp,
                            timescale: configuration.timeBase.den), multiplier: configuration.timeBase.num, divisor: 1), origin)
                    }
                    if raw.duration > 0 {
                        frameDuration = CMTimeMultiplyByRatio(CMTime(value: raw.duration, timescale: configuration.timeBase.den),
                            multiplier: configuration.timeBase.num, divisor: 1)
                    }
                    av_frame_unref(frame)
                    if first != nil { break }
                } else if received == apCodecEOF() { break }
                else if received != apCodecAgain() { throw Failure.decoding(received) }
                if eof { break }
                var packet: FFmpegEncodedPacket?
                repeat { packet = try demux.next() } while packet != nil && packet?.streamIndex != video
                let sent = packet?.send(to: context) ?? avcodec_send_packet(context, nil)
                guard sent >= 0 else { throw Failure.decoding(sent) }
                eof = packet == nil
            }
            if let first, first <= target { return anchor }
            let gap = first.map { max(frameDuration, CMTimeSubtract($0, target)) } ?? frameDuration
            distance = max(gap, CMTimeMultiplyByFloat64(distance, multiplier: 2))
            let next = CMTimeSubtract(target, distance)
            guard next.isNumeric, next < anchor else { return .zero }
            anchor = max(.zero, next)
        }
        return .zero
    }

    deinit { input.cancel(); status.finish() }

    func next() async throws -> Event? {
        try await withTaskCancellationHandler { try nextSynchronously() } onCancel: { input.cancel() }
    }

    private func nextSynchronously() throws -> Event? {
        guard !cancelled else { throw Failure.cancelled }
        do {
            try Task.checkCancellation(); try input.checkFailure()
            while true {
                try Task.checkCancellation()
                if let index = pendingStream, let decoder = decoders[index] {
                    switch try decoder.receive() {
                    case .event(let event):
                        // Retain the first frame crossing a seek target; trimming audio
                        // here prevents a whole-buffer discard from losing wanted samples.
                        if let admitted = admit(event) {
                            switch admitted {
                            case .audio(let chunk): decodedEnd = max(decodedEnd, CMTimeAdd(chunk.presentationTime,
                                CMTime(value: Int64(chunk.frameCount), timescale: Int32(chunk.sampleRate))))
                            case .video(let frame): decodedEnd = max(decodedEnd, CMTimeRangeGetEnd(frame.sourceRange))
                            }
                            return admitted
                        }
                        continue
                    case .noOutput: continue
                    case .needsPacket, .ended: pendingStream = nil
                    }
                }
                if ended {
                    guard !flushIndices.isEmpty else { status.drained(at: decodedEnd); return nil }
                    let index = flushIndices.removeFirst()
                    try decoders[index]?.send(nil)
                    pendingStream = index
                    continue
                }
                status.waiting(true)
                let packet: FFmpegEncodedPacket?
                do {
                    if let initial = initialPacket { packet = initial; initialPacket = nil }
                    else { packet = try demux?.next() }
                }
                catch { status.waiting(false); throw error }
                status.waiting(false)
                try Task.checkCancellation(); try input.checkFailure()
                guard let packet else {
                    ended = true; flushIndices = decoders.keys.sorted(); status.completed()
                    continue
                }
                status.packet(packet, timeBase: demux?.configurations[packet.streamIndex]?.timeBase,
                    fallbackBytePosition: demux?.inputPosition)
                guard let decoder = decoders[packet.streamIndex] else { continue }
                try decoder.send(packet)
                pendingStream = packet.streamIndex
            }
        } catch {
            cancelSynchronously()
            throw error
        }
    }

    private func admit(_ rawEvent: Event) -> Event? {
        let event: Event
        switch rawEvent {
        case .audio(let chunk):
            event = .audio(.init(samples: chunk.samples, presentationTime: CMTimeSubtract(chunk.presentationTime, metadata.timelineOrigin),
                sampleRate: chunk.sampleRate, channels: chunk.channels, startsDecodedBuffer: chunk.startsDecodedBuffer))
        case .video(let frame):
            event = .video(.init(pixelBuffer: frame.pixelBuffer, sourceRange: .init(
                start: CMTimeSubtract(frame.sourceRange.start, metadata.timelineOrigin), duration: frame.sourceRange.duration)))
        }
        switch event {
        case .video(let frame):
            lastVideoFrame = frame
            return CMTimeRangeGetEnd(frame.sourceRange) > seekTarget ? event : nil
        case .audio(let chunk):
            let end = CMTimeAdd(chunk.presentationTime, CMTime(value: Int64(chunk.frameCount), timescale: Int32(chunk.sampleRate)))
            guard end > seekTarget else { return nil }
            guard chunk.presentationTime < seekTarget else { return event }
            let trimTime = CMTimeConvertScale(CMTimeSubtract(seekTarget, chunk.presentationTime), timescale: Int32(chunk.sampleRate), method: .roundAwayFromZero)
            let trim = min(chunk.frameCount, max(0, Int(trimTime.value)))
            guard trim < chunk.frameCount else { return nil }
            return .audio(.init(samples: Array(chunk.samples.dropFirst(trim * chunk.channels)),
                presentationTime: CMTimeAdd(chunk.presentationTime, CMTime(value: Int64(trim), timescale: Int32(chunk.sampleRate))),
                sampleRate: chunk.sampleRate, channels: chunk.channels, startsDecodedBuffer: true))
        }
    }

    /// A genuine final picture for an audio tail, retaining its original source
    /// range. It does not represent additional video duration or queued playback.
    func videoPosterFrame() -> PlaybackVideoFrame? { lastVideoFrame }

    /// Wakes synchronous input immediately; cleanup itself remains on the codec executor.
    nonisolated func stop() { input.cancel() }
    nonisolated func cancel() async {
        input.cancel()
        await cancelSynchronously()
    }
    private func cancelSynchronously() {
        cancelled = true; lastVideoFrame = nil; input.cancel(); status.finish()
        decoders.removeAll(); demux = nil; pendingStream = nil; initialPacket = nil; flushIndices.removeAll()
    }

    private final class InputStatus: @unchecked Sendable {
        let bufferState: PCMBufferState
        private let input: any MediaByteInput
        private let lock = NSLock()
        private var value: PCMBufferState.Snapshot
        private var observer: Task<Void, Never>?
        private var finished = false
        private let originMicroseconds: Int64
        init(input: any MediaByteInput, metadata: FFmpegMediaMetadata) {
            self.input = input
            originMicroseconds = CMTimeConvertScale(metadata.timelineOrigin, timescale: 1_000_000, method: .roundTowardZero).value
            value = .init(bufferedThroughMicroseconds: nil, allocatedBytes: 0,
                targetBytes: PlaybackLoadControl.audioTargetBytes, isLoading: false, isFinalBuffered: false,
                durationMicroseconds: metadata.duration.map { CMTimeConvertScale($0, timescale: 1_000_000, method: .roundTowardZero).value },
                sourceSeekable: metadata.sourceSeekable)
            bufferState = PCMBufferState(value, sourceRetry: input.sourceRetry)
        }
        func start() {
            guard let retry = input.sourceRetry else { return }
            let events = retry.events()
            observer = Task { [weak self] in
                for await _ in events {
                    guard !Task.isCancelled else { return }
                    self?.refresh()
                }
            }
        }
        private func refresh() {
            lock.withLock {
                guard !finished else { return }
                value.isWaitingForSource = value.isWaitingForSamples && input.isWaitingForData
                bufferState.update(value); bufferState.notifySourceRetryChange()
            }
        }
        func waiting(_ waiting: Bool) {
            lock.withLock {
                guard !finished else { return }
                // This reader acquires packets only during a demand pull. Once
                // acquisition returns there is no producer that can grow the
                // encoded horizon while bounded PCM output pauses further pulls.
                value = .init(bufferedThroughMicroseconds: value.bufferedThroughMicroseconds,
                    allocatedBytes: value.allocatedBytes, targetBytes: value.targetBytes,
                    isLoading: waiting, isFinalBuffered: value.isFinalBuffered,
                    isWaitingForSamples: waiting, isWaitingForSource: waiting && input.isWaitingForData,
                    durationMicroseconds: value.durationMicroseconds, sourceSeekable: value.sourceSeekable)
                bufferState.update(value)
            }
        }
        func packet(_ packet: FFmpegEncodedPacket, timeBase: AVRational?, fallbackBytePosition: Int64?) {
            lock.withLock {
                guard !finished else { return }
                if let timeBase, packet.presentationTimestamp != Int64.min {
                    let end = Int64(clamping: Int128(packet.presentationTimestamp) + Int128(max(0, packet.duration)))
                    let through = Int64(clamping: Int128(av_rescale_q(end, timeBase, AVRational(num: 1, den: 1_000_000))) - Int128(originMicroseconds))
                    value = .init(bufferedThroughMicroseconds: max(value.bufferedThroughMicroseconds ?? through, through),
                        allocatedBytes: 0, targetBytes: value.targetBytes,
                        isLoading: false, isFinalBuffered: false, durationMicroseconds: value.durationMicroseconds, sourceSeekable: value.sourceSeekable)
                }
                let identity = packet.bytePosition >= 0 ? packet.bytePosition : fallbackBytePosition
                if let identity, identity >= 0 {
                    input.sourceRetry?.recordSamples(1, durationKnown: value.durationMicroseconds != nil,
                        extractedThrough: identity == .max ? identity : identity + 1)
                }
                bufferState.update(value)
            }
        }
        func completed() {
            lock.withLock {
                guard !finished else { return }
                value = .init(bufferedThroughMicroseconds: value.bufferedThroughMicroseconds, allocatedBytes: 0,
                    targetBytes: value.targetBytes, isLoading: false, isFinalBuffered: true,
                    durationMicroseconds: value.durationMicroseconds, sourceSeekable: value.sourceSeekable)
                bufferState.update(value)
            }
        }
        func drained(at end: CMTime) {
            lock.withLock {
                guard !finished, value.durationMicroseconds == nil, end > .zero else { return }
                value.durationMicroseconds = CMTimeConvertScale(end, timescale: 1_000_000, method: .roundTowardZero).value
                bufferState.update(value)
            }
        }
        func finish() {
            lock.withLock { finished = true; bufferState.finish() }
            observer?.cancel()
        }
        deinit { observer?.cancel() }
    }

    private final class Decoder {
        enum Output { case event(Event), noOutput, needsPacket, ended }
        private let configuration: FFmpegStreamConfiguration
        private let track: FFmpegMediaMetadata.Track
        private var context: UnsafeMutablePointer<AVCodecContext>?
        private var frame: UnsafeMutablePointer<AVFrame>?
        private var converter: OpaquePointer?
        private var scaler: UnsafeMutablePointer<SwsContext>?
        private var audioFormat: (rate: Int32, channels: Int32, sampleFormat: Int32)?
        private var inputLayout = AVChannelLayout()
        private var outputLayout = AVChannelLayout()
        /// More than two channels are resampled in their own layout and played
        /// as stereo (`PCMStereoDownmix`).
        private var converterLayout = AVChannelLayout()
        private var downmix: PCMStereoDownmix?
        private var outputRate: Int32 = 0
        private var pendingAudio: [FFmpegAudioReader.Chunk] = []
        private var nextAudioTime: CMTime?
        private var converterDrained = false
        private let audioByteOrigin: Int64?
        private var nextInputTime: CMTime?
        init(configuration: FFmpegStreamConfiguration, track: FFmpegMediaMetadata.Track, audioByteOrigin: Int64?) throws {
            self.audioByteOrigin = audioByteOrigin
            self.configuration = configuration; self.track = track
            context = try configuration.makeCodecContext(manualSkip: false)
            frame = av_frame_alloc()
            guard frame != nil else { avcodec_free_context(&context); throw FFmpegAudioReader.Failure.allocation }
        }
        deinit {
            swr_free(&converter); av_channel_layout_uninit(&inputLayout); av_channel_layout_uninit(&outputLayout)
            av_channel_layout_uninit(&converterLayout); sws_freeContext(scaler); av_frame_free(&frame); avcodec_free_context(&context)
        }
        func send(_ packet: FFmpegEncodedPacket?) throws {
            guard let context else { throw Failure.invalidSelection }
            if let packet, let origin = audioByteOrigin {
                let offset = packet.bytePosition - origin, alignment = Int64(configuration.blockAlign)
                guard alignment > 0, offset >= 0, offset % alignment == 0, configuration.samplesPerBlock > 0 else { throw Failure.invalidTimestamp }
                let samples = (offset / alignment).multipliedReportingOverflow(by: Int64(configuration.samplesPerBlock))
                guard !samples.overflow else { throw Failure.invalidTimestamp }
                nextInputTime = CMTime(value: samples.partialValue, timescale: configuration.sampleRate)
            }
            let result = packet?.send(to: context) ?? avcodec_send_packet(context, nil)
            if result < 0 { throw Failure.decoding(result) }
        }
        func receive() throws -> Output {
            if !pendingAudio.isEmpty { return .event(.audio(pendingAudio.removeFirst())) }
            guard let context, let frame else { throw Failure.invalidSelection }
            let result = avcodec_receive_frame(context, frame)
            if result == apCodecEOF() {
                if !converterDrained {
                    converterDrained = true
                    try drainConverter()
                    if !pendingAudio.isEmpty { return .event(.audio(pendingAudio.removeFirst())) }
                }
                return .ended
            }
            if result == apCodecAgain() { return .needsPacket }
            guard result >= 0 else { throw Failure.decoding(result) }
            defer { av_frame_unref(frame) }
            let raw = frame.pointee
            let pts: CMTime
            if let known = nextInputTime, audioByteOrigin != nil || raw.best_effort_timestamp == Int64.min {
                pts = known
            } else {
                guard raw.best_effort_timestamp != Int64.min else { throw Failure.invalidTimestamp }
                let scaled = raw.best_effort_timestamp.multipliedReportingOverflow(by: Int64(configuration.timeBase.num))
                guard !scaled.overflow else { throw Failure.invalidTimestamp }
                pts = CMTime(value: scaled.partialValue, timescale: configuration.timeBase.den)
            }
            if track.kind == .audio {
                let channels = raw.ch_layout.nb_channels, rate = raw.sample_rate, count = raw.nb_samples
                guard rate > 0, rate <= 768_000, channels > 0, channels <= 32, count > 0, count <= 65_536 else { throw Failure.capacity }
                nextInputTime = CMTimeAdd(pts, CMTime(value: Int64(count), timescale: rate))
                var layout = raw.ch_layout
                let changed = audioFormat.map { $0.rate != rate || $0.channels != channels || $0.sampleFormat != raw.format } ?? true
                if changed || av_channel_layout_compare(&inputLayout, &layout) != 0 {
                    try drainConverter()
                    swr_free(&converter); av_channel_layout_uninit(&inputLayout)
                    guard av_channel_layout_copy(&inputLayout, &layout) >= 0 else { throw FFmpegAudioReader.Failure.allocation }
                    if outputRate == 0 {
                        outputRate = rate
                        if channels > 2 { av_channel_layout_default(&outputLayout, 2) }
                        else { guard av_channel_layout_copy(&outputLayout, &layout) >= 0 else { throw FFmpegAudioReader.Failure.allocation } }
                    }
                    av_channel_layout_uninit(&converterLayout)
                    downmix = nil
                    if channels > 2 {
                        guard let downmix = PCMStereoDownmix(ffmpeg: layout) else { throw FFmpegAudioReader.Failure.invalidFormat }
                        self.downmix = downmix
                    }
                    let copied = channels > 2 ? av_channel_layout_copy(&converterLayout, &layout)
                        : av_channel_layout_copy(&converterLayout, &outputLayout)
                    guard copied >= 0 else { throw FFmpegAudioReader.Failure.allocation }
                    var result = swr_alloc_set_opts2(&converter, &converterLayout, AV_SAMPLE_FMT_S16, outputRate,
                        &layout, AVSampleFormat(rawValue: raw.format), rate, 0, nil)
                    if result >= 0 { result = swr_init(converter) }
                    guard result >= 0 else { throw Failure.decoding(result) }
                    audioFormat = (rate, channels, raw.format)
                    converterDrained = false
                }
                let delayed = swr_get_delay(converter, Int64(rate))
                let capacity = av_rescale_rnd(delayed + Int64(count), Int64(outputRate), Int64(rate), AV_ROUND_UP)
                let presentation = CMTimeSubtract(pts, CMTime(value: delayed, timescale: rate))
                let input = UnsafeRawPointer(raw.extended_data).assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
                if let chunk = try convert(input: input, count: count, capacity: capacity, presentation: presentation) {
                    pendingAudio.append(chunk)
                }
                if !pendingAudio.isEmpty { return .event(.audio(pendingAudio.removeFirst())) }
                // A resampler may buffer a short input. Receive another decoded frame
                // before requesting a packet; all native frame data was copied above.
                return .noOutput
            }
            guard raw.width > 0, raw.width <= 8192, raw.height > 0, raw.height <= 8192,
                  Int64(raw.width) * Int64(raw.height) * 4 <= 128 * 1024 * 1024 else { throw Failure.capacity }
            var pixel: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            guard CVPixelBufferCreate(kCFAllocatorDefault, Int(raw.width), Int(raw.height), kCVPixelFormatType_32BGRA, attributes, &pixel) == kCVReturnSuccess,
                  let pixel else { throw FFmpegAudioReader.Failure.allocation }
            scaler = sws_getCachedContext(scaler, raw.width, raw.height, AVPixelFormat(rawValue: raw.format),
                raw.width, raw.height, AV_PIX_FMT_BGRA, Int32(SWS_BILINEAR.rawValue), nil, nil, nil)
            guard scaler != nil else { throw FFmpegAudioReader.Failure.allocation }
            let coefficients = sws_getCoefficients(raw.colorspace == AVCOL_SPC_BT709 ? SWS_CS_ITU709
                : raw.colorspace == AVCOL_SPC_BT2020_NCL || raw.colorspace == AVCOL_SPC_BT2020_CL ? SWS_CS_BT2020 : SWS_CS_ITU601)
            let colorResult = sws_setColorspaceDetails(scaler, coefficients, raw.color_range == AVCOL_RANGE_JPEG ? 1 : 0,
                coefficients, 1, 0, 1 << 16, 1 << 16)
            guard colorResult >= 0 else { throw Failure.decoding(colorResult) }
            guard CVPixelBufferLockBaseAddress(pixel, []) == kCVReturnSuccess else { throw FFmpegAudioReader.Failure.allocation }
            let outputResult: Int32 = withUnsafePointer(to: raw.data) { data in
                withUnsafePointer(to: raw.linesize) { lines in
                    var output: [UnsafeMutablePointer<UInt8>?] = [CVPixelBufferGetBaseAddress(pixel)?.assumingMemoryBound(to: UInt8.self), nil, nil, nil]
                    let strides: [Int32] = [Int32(CVPixelBufferGetBytesPerRow(pixel)), 0, 0, 0]
                    return data.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { input in
                        lines.withMemoryRebound(to: Int32.self, capacity: 8) { inputLines in
                            sws_scale(scaler, input, inputLines, 0, raw.height, &output, strides)
                        }
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard outputResult == raw.height else { throw Failure.decoding(outputResult) }
            let duration: CMTime
            if raw.duration > 0 {
                let scaled = raw.duration.multipliedReportingOverflow(by: Int64(configuration.timeBase.num))
                guard !scaled.overflow else { throw Failure.invalidTimestamp }
                duration = CMTime(value: scaled.partialValue, timescale: configuration.timeBase.den)
            } else {
                let rate = configuration.nominalFrameRate
                guard rate.num > 0, rate.den > 0 else { throw Failure.invalidTimestamp }
                duration = CMTime(value: Int64(rate.den), timescale: rate.num)
            }
            // swscale only borrows the locked destination and retains no output
            // pointer. Mutation is complete and the fresh pixel is never reused.
            // The C callback borrow cannot express this transfer to Swift's checker.
            nonisolated(unsafe) let completedPixel = pixel
            return .event(.video(PlaybackVideoFrame(pixelBuffer: CVReadOnlyPixelBuffer(unsafeBuffer: completedPixel),
                sourceRange: CMTimeRange(start: pts, duration: duration))))
        }
        private func convert(input: UnsafePointer<UnsafePointer<UInt8>?>?, count: Int32,
                             capacity: Int64, presentation: CMTime) throws -> FFmpegAudioReader.Chunk? {
            let converting = Int(converterLayout.nb_channels), channels = Int(outputLayout.nb_channels)
            guard capacity >= 0, capacity <= 1_048_576, converting > 0, converting <= 32,
                  capacity * Int64(converting) <= 8_388_608 else { throw Failure.capacity }
            guard capacity > 0 else { return nil }
            var samples = [Int16](repeating: 0, count: Int(capacity) * converting)
            let converted = samples.withUnsafeMutableBytes { bytes in
                var output = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self) as UnsafeMutablePointer<UInt8>?
                return swr_convert(converter, &output, Int32(capacity), input, count)
            }
            guard converted >= 0 else { throw Failure.decoding(converted) }
            guard converted > 0 else { return nil }
            samples.removeLast(samples.count - Int(converted) * converting)
            if let downmix {
                samples = samples.withUnsafeBufferPointer { downmix.apply($0) }
                // A later surround segment of a mono stream keeps its first format.
                if channels == 1 { samples = stride(from: 0, to: samples.count, by: 2).map { Int16((Int32(samples[$0]) + Int32(samples[$0 + 1])) >> 1) } }
            }
            nextAudioTime = CMTimeAdd(presentation, CMTime(value: Int64(converted), timescale: outputRate))
            return .init(samples: samples, presentationTime: presentation, sampleRate: Int(outputRate),
                channels: channels, startsDecodedBuffer: true)
        }

        private func drainConverter() throws {
            guard converter != nil, let format = audioFormat, let nextAudioTime else { return }
            let delay = swr_get_delay(converter, Int64(format.rate))
            let capacity = av_rescale_rnd(delay, Int64(outputRate), Int64(format.rate), AV_ROUND_UP)
            if let chunk = try convert(input: nil, count: 0, capacity: capacity, presentation: nextAudioTime) {
                pendingAudio.append(chunk)
            }
        }
    }
}
