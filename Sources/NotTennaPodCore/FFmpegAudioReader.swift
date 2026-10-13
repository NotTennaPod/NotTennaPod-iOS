import CFFmpegCodec
import CoreMedia
import Foundation

/// Ogg/Matroska audio decoding and seek admission, before playback timeline adaptation.
/// The actor owns decoding; buffered factories use independent producer demux execution.
/// The app plays single-track Ogg/Matroska Vorbis and Opus through the buffered factories
/// (`FFmpegPlaybackSource`); the direct factories keep the serialized demux path.
actor FFmpegAudioReader {
    enum Timing: Sendable { case native, media3 }
    struct Chunk: Sendable {
        let samples: [Int16]
        let presentationTime: CMTime
        let sampleRate: Int
        let channels: Int
        let startsDecodedBuffer: Bool
        var frameCount: Int { samples.count / channels }
    }
    enum Failure: Error, Equatable {
        case notLocal, invalidCapacity, invalidFormat, invalidSeek, allocation, cancelled, concurrentOperation, decoding(Int32)
    }
    enum Status: Equatable { case ready, ended, cancelled, failed }
    nonisolated let sampleRate: Int
    nonisolated let channels: Int
    nonisolated let maximumFrames: Int
    private(set) var status = Status.ready
    private(set) var seekDiscardedFrames: Int64 = 0
    private var resources: Resources?
    private var pending: [Int16] = []
    private var pendingTime = CMTime.invalid
    private var offset = 0
    private var draining = false
    private var terminalError: (any Error)?
    nonisolated private let executor: BlockingReadExecutor
    nonisolated private let timelineLoader = MatroskaTimelineLoader()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    nonisolated private let byteInput: (any MediaByteInput)?
    nonisolated private let bufferedFailure: PCMSourceFailure?
    nonisolated let bufferState: PCMBufferState?
    nonisolated var sourceFailure: PCMSourceFailure? { bufferedFailure ?? byteInput?.sourceFailure }
    private let url: URL?
    private let timing: Timing
    private var seekTargetUs: Int64?
    private var producer: FFmpegPacketProducer?
    nonisolated private let packetReadLease: FFmpegPacketProducer.ReadLease?
    private var playbackReadLease: FFmpegPacketProducer.ReadLease?
    private var hasPlaybackReader = false
    private var producerFailureTask: Task<Void, Never>?
    private var producerBufferTask: Task<Void, Never>?
    private var bufferedSource: BufferedSource?
    private let bufferedConfiguration: FFmpegStreamConfiguration?
    private var generation = UUID()
    private var activeRead: UUID?
    private var seeking = false

    private struct BufferedSource: Sendable {
        let url: URL?
        let input: (any MediaByteLeaseSource)?
        let timing: Timing
        let targetBytes: Int64
        var useContainerDuration = true
        var sourceSeekable: Bool?
        var sourceDurationMicroseconds: Int64?
        var matroskaTimeline: MatroskaTimeline?
        var isLive = false
        func open(at position: Int64, useDefaultSeekPointAtZero: Bool = false) async throws -> FFmpegPacketProducer {
            try input?.checkFailure()
            return try await FFmpegPacketProducer.open(url: url, input: input?.makeReadLease(),
                startMicroseconds: position, timing: timing, useContainerDuration: useContainerDuration,
                sourceSeekable: sourceSeekable, sourceDurationMicroseconds: sourceDurationMicroseconds,
                sourceSeekPoint: (position > 0 || useDefaultSeekPointAtZero) && matroskaTimeline?.isSeekable == true
                    ? matroskaTimeline?.defaultSeekPoints(at: position).first : nil, targetBytes: targetBytes)
        }
    }

    /// Explicit playback buffering; offline decoding retains the direct factories.
    static func openBuffered(url: URL, maximumFrames: Int = 4096, timing: Timing = .native,
                             targetBytes: Int64 = PlaybackLoadControl.audioTargetBytes) async throws -> FFmpegAudioReader {
        guard url.isFileURL else { throw Failure.notLocal }
        return try await openBuffered(source: BufferedSource(url: url, input: nil, timing: timing, targetBytes: targetBytes),
                                      maximumFrames: maximumFrames)
    }

    static func openBuffered(input: any MediaByteLeaseSource, maximumFrames: Int = 4096, timing: Timing = .native,
                             targetBytes: Int64 = PlaybackLoadControl.audioTargetBytes) async throws -> FFmpegAudioReader {
        try await openBuffered(source: BufferedSource(url: nil, input: input, timing: timing, targetBytes: targetBytes),
                               maximumFrames: maximumFrames)
    }

    private static func openBuffered(source: BufferedSource, maximumFrames: Int) async throws -> FFmpegAudioReader {
        guard (1...65_536).contains(maximumFrames) else { throw Failure.invalidCapacity }
        var producer: FFmpegPacketProducer?
        do {
            let prepared = try await source.open(at: 0)
            producer = prepared
            try Task.checkCancellation()
            let reader = try FFmpegAudioReader(source: source, producer: prepared, maximumFrames: maximumFrames)
            await reader.observeProducerFailure()
            try Task.checkCancellation()
            return reader
        } catch { await producer?.cancel(); source.input?.cancel(); throw error }
    }

    private init(source: BufferedSource, producer: FFmpegPacketProducer, maximumFrames: Int,
                 readLease: FFmpegPacketProducer.ReadLease? = nil, seekTargetMicroseconds: Int64? = nil,
                 decodePreroll: Bool = false) throws {
        executor = BlockingReadExecutor()
        packetReadLease = readLease
        bufferedConfiguration = producer.configuration
        bufferedFailure = PCMSourceFailure()
        bufferState = PCMBufferState(producer.bufferState.snapshot, sourceRetry: producer.bufferState.sourceRetry)
        byteInput = readLease == nil ? source.input : nil; url = source.url; timing = source.timing
        self.maximumFrames = maximumFrames
        let resources = try Resources(configuration: producer.configuration, timing: source.timing)
        if decodePreroll {
            // Feed the retained preroll into the codec. The whole-output timestamp
            // admission below still discards everything before the requested target.
            resources.hasAdmittedOpusPacket = true
        }
        self.resources = resources
        self.producer = readLease == nil ? producer : nil
        bufferedSource = readLease == nil ? source : nil
        seekTargetUs = seekTargetMicroseconds
        sampleRate = Int(resources.context!.pointee.sample_rate)
        channels = resources.outputChannels
    }

    func producerSnapshot() -> FFmpegPacketProducer.Snapshot? { producer?.snapshot() }

    /// The caller supplies presented media time, never decoded-ahead PCM position.
    func updatePlayback(positionMicroseconds: Int64, speed: Float) throws {
        if let packetReadLease { try packetReadLease.updatePlayback(positionMicroseconds: positionMicroseconds, speed: speed) }
        else { try producer?.updatePlayback(positionMicroseconds: positionMicroseconds, speed: speed) }
    }

    init(url: URL, maximumFrames: Int = 4096, timing: Timing = .native) throws {
        guard url.isFileURL else { throw Failure.notLocal }
        guard (1...65_536).contains(maximumFrames) else { throw Failure.invalidCapacity }
        try Task.checkCancellation()
        let resources = try Resources(url: url, timing: timing)
        try Task.checkCancellation()
        self.resources = resources
        executor = BlockingReadExecutor()
        byteInput = nil
        packetReadLease = nil
        bufferedConfiguration = nil
        bufferedFailure = nil
        bufferState = nil
        self.url = url
        self.timing = timing
        sampleRate = Int(resources.context!.pointee.sample_rate)
        channels = resources.outputChannels
        self.maximumFrames = maximumFrames
    }

    /// Opening and native callbacks use a dedicated executor, not a cooperative pool thread.
    static func open(input: any MediaByteInput, maximumFrames: Int = 4096,
                     timing: Timing = .native) async throws -> FFmpegAudioReader {
        guard (1...65_536).contains(maximumFrames) else { throw Failure.invalidCapacity }
        try Task.checkCancellation()
        let executor = BlockingReadExecutor()
        let reader = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FFmpegAudioReader, any Error>) in
                executor.queue.async {
                    do { continuation.resume(returning: try FFmpegAudioReader(input: input, executor: executor,
                        maximumFrames: maximumFrames, timing: timing)) }
                    catch { input.cancel(); continuation.resume(throwing: error) }
                }
            }
        } onCancel: { input.cancel() }
        do { try Task.checkCancellation(); return reader }
        catch { await reader.cancel(); throw error }
    }

    private init(input: any MediaByteInput, executor: BlockingReadExecutor,
                 maximumFrames: Int, timing: Timing) throws {
        self.executor = executor
        byteInput = input
        packetReadLease = nil
        bufferedConfiguration = nil
        bufferedFailure = nil
        bufferState = nil
        url = nil
        self.timing = timing
        self.maximumFrames = maximumFrames
        let resources = try Resources(url: nil, byteInput: input, timing: timing)
        self.resources = resources
        sampleRate = Int(resources.context!.pointee.sample_rate)
        channels = resources.outputChannels
    }

    deinit {
        producerFailureTask?.cancel(); producerBufferTask?.cancel()
        packetReadLease?.cancel(); playbackReadLease?.cancel(); producer?.stop()
        bufferedFailure?.finish(); bufferState?.finish(); byteInput?.cancel()
    }

    private func observeProducerFailure() {
        producerFailureTask?.cancel()
        guard let sourceFailure = packetReadLease?.sourceFailure ?? producer?.sourceFailure,
              let sourceBuffer = packetReadLease?.bufferState ?? producer?.bufferState,
              let bufferedFailure else { return }
        let token = generation
        producerBufferTask?.cancel()
        bufferState?.update(sourceBuffer.snapshot)
        let changes = sourceBuffer.events()
        producerBufferTask = Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await self?.publishProducerBuffer(sourceBuffer.snapshot, generation: token)
            }
        }
        let events = sourceFailure.events()
        if let error = sourceFailure.error { bufferedFailure.fail(error) }
        producerFailureTask = Task { [weak self] in
            for await error in events {
                guard !Task.isCancelled else { return }
                await self?.publishProducerFailure(error, generation: token)
            }
        }
    }

    private func publishProducerBuffer(_ snapshot: PCMBufferState.Snapshot, generation token: UUID) {
        guard generation == token else { return }
        bufferState?.update(snapshot)
    }

    private func publishProducerFailure(_ error: any Error, generation token: UUID) {
        guard generation == token else { return }
        bufferedFailure?.fail(error)
    }

    func next() async throws -> Chunk? {
        guard activeRead == nil, !seeking, !hasPlaybackReader else { throw Failure.concurrentOperation }
        let token = generation, read = UUID(), producer = self.producer
        activeRead = read
        defer { if activeRead == read { activeRead = nil } }
        return try await withTaskCancellationHandler {
            try await nextChunk(generation: token)
        } onCancel: {
            if let packetReadLease { packetReadLease.cancel() }
            else if let producer { producer.stop() }
            else { byteInput?.cancel() }
        }
    }

    /// Adapters retaining an admitted chunk must validate it before delivery too.
    /// This does not consume PCM or replace asynchronous session failure delivery.
    func checkFailure() throws {
        guard status != .cancelled else { throw Failure.cancelled }
        if let terminalError { throw terminalError }
        do {
            try Task.checkCancellation()
            try bufferedFailure?.check()
            try byteInput?.checkFailure()
            try packetReadLease?.checkFailure()
            try producer?.sourceFailure.check()
        } catch {
            if !(error is CancellationError) { terminalError = error; bufferedFailure?.fail(error) }
            retire(as: error is CancellationError ? .cancelled : .failed)
            throw error
        }
    }

    private func nextChunk(generation token: UUID) async throws -> Chunk? {
        let stopped = producer
        do {
            try checkFailure()
            guard status != .ended else { return nil }
            if offset == pending.count {
                pending.removeAll(keepingCapacity: true)
                offset = 0
                guard try await decodeFrame(generation: token) else {
                    resources = nil
                    status = .ended
                    return nil
                }
            }
            guard generation == token else { throw CancellationError() }
            try checkFailure()
            let end = min(pending.count, offset + maximumFrames * channels)
            let time = pendingTime.isNumeric
                ? CMTimeAdd(pendingTime, CMTime(value: Int64(offset / channels), timescale: Int32(sampleRate)))
                : .invalid
            let chunk = Chunk(samples: Array(pending[offset..<end]), presentationTime: time,
                              sampleRate: sampleRate, channels: channels, startsDecodedBuffer: offset == 0)
            try Task.checkCancellation()
            offset = end
            return chunk
        } catch {
            if generation == token {
                if !(error is CancellationError) { terminalError = error; bufferedFailure?.fail(error) }
                retire(as: error is CancellationError ? .cancelled : .failed)
            }
            await stopped?.cancel()
            throw error
        }
    }

    nonisolated func cancel() async {
        // Wake any native read before waiting for the actor that currently owns it.
        timelineLoader.cancel()
        packetReadLease?.cancel()
        byteInput?.cancel()
        await cancelOwnedProducer()
    }

    private func cancelOwnedProducer() async {
        let stopped = producer
        retire(as: .cancelled)
        await stopped?.cancel()
    }

    /// Repositions decoding; the next pull provides the first admitted output buffer.
    /// Pinned MediaCodecRenderer marks a whole output buffer decode-only when its PTS
    /// precedes the reset position. Apply that rule before splitting into Swift chunks.
    func seek(to position: CMTime) async throws {
        guard packetReadLease == nil else { throw Failure.concurrentOperation }
        if bufferedSource != nil { try await seekBuffered(to: position) }
        else { try await withTaskCancellationHandler { try seekSynchronous(to: position) } onCancel: { byteInput?.cancel() } }
    }

    /// Called by playback preparation before the fresh seek/demux generation opens.
    /// Ogg uses declared length; WebM uses declared duration and cues. Metadata
    /// discovery finishes before the replacement decoder admits a seek target.
    func prepareSourceTimeline() async throws -> Bool? {
        try checkFailure()
        guard !seeking, activeRead == nil, !hasPlaybackReader else { throw Failure.concurrentOperation }
        guard var source = bufferedSource, let container = producer?.configuration.containerName else { return nil }
        if container == "ogg" {
            let knownLength = source.input.map { $0.initialDeclaredLength != nil } ?? true
            source.sourceSeekable = knownLength
            source.useContainerDuration = knownLength
            source.isLive = !knownLength
            if knownLength { source.input?.prepareForSeek() }
            bufferedSource = source
            return knownLength
        }
        guard container.split(separator: ",").contains("matroska") else { return nil }
        // Retire the first producer before requesting metadata ranges. It must not
        // compete with cue discovery for the shared source's active range request.
        let token = UUID()
        generation = token; seeking = true
        producerFailureTask?.cancel(); producerFailureTask = nil
        producerBufferTask?.cancel(); producerBufferTask = nil
        bufferState?.update(.initial)
        let stopped = producer
        producer = nil; resources = nil; pending.removeAll(); offset = 0
        defer { if generation == token { seeking = false } }
        await stopped?.cancel()
        do {
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            let timeline = try await timelineLoader.load(url: source.url, input: source.input)
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            try checkFailure()
            source.sourceSeekable = timeline.isSeekable
            source.useContainerDuration = false
            source.sourceDurationMicroseconds = timeline.durationMicroseconds
            source.matroskaTimeline = timeline
            source.isLive = source.input?.initialDeclaredLength == nil && source.input != nil && timeline.durationMicroseconds == nil
            bufferedSource = source
            return timeline.isSeekable
        } catch {
            if generation == token {
                if !(error is CancellationError) { terminalError = error; bufferedFailure?.fail(error) }
                retire(as: error is CancellationError ? .cancelled : .failed)
            }
            throw error
        }
    }

    /// A playback source owns this reader and its encoded queue across decoder
    /// replacements. Returned readers own fresh codec state and only a read lease.
    /// Prepare the source timeline once before calling this method.
    func makePlaybackReader(to position: CMTime) async throws -> FFmpegAudioReader {
        guard position.isNumeric, position.epoch == 0, position >= .zero else { throw Failure.invalidSeek }
        let requested = CMTimeConvertScale(position, timescale: 1_000_000, method: .roundTowardZero)
        guard requested.isNumeric, requested.value >= 0 else { throw Failure.invalidSeek }
        guard !seeking, activeRead == nil, let source = bufferedSource else { throw Failure.concurrentOperation }
        try checkFailure()
        let target = source.sourceSeekable == false ? Int64(0) : requested.value
        let opus = timing == .media3 && bufferedConfiguration?.codecID == AV_CODEC_ID_OPUS
        var preroll: Int64 = 0
        if opus, let configuration = bufferedConfiguration, configuration.sampleRate > 0 {
            // RFC 7845 §4.6: warm the codec before the target, never discard
            // 80 ms after it. At stream start use the ordinary codec pre-skip.
            // The specification's 80-ms minimum still leaves a measurable native
            // decoder transient in the retained tone controls. Decode half a
            // second of retained history to converge before admitting output.
            preroll = max(500_000, av_rescale_q(Int64(max(0, configuration.seekPreroll)),
                AVRational(num: 1, den: configuration.sampleRate), AVRational(num: 1, den: 1_000_000)))
        }
        let loadTarget = max(0, target - preroll)
        playbackReadLease?.cancel(); playbackReadLease = nil
        var retained: FFmpegPacketProducer.ReadLease?
        if hasPlaybackReader, !source.isLive, let producer {
            let candidate = producer.makeReadLease()
            if try candidate.seekWithinBuffer(to: loadTarget) { retained = candidate }
            else { candidate.cancel() }
        }
        if retained == nil {
            try await seekBuffered(to: CMTime(value: loadTarget, timescale: 1_000_000),
                useDefaultSeekPointAtZero: hasPlaybackReader)
        }
        try Task.checkCancellation()
        guard let producer else { throw Failure.invalidFormat }
        let lease = retained ?? producer.makeReadLease()
        // Loading/back-buffer accounting follows the requested playback target;
        // the earlier read cursor is decoder conditioning, not presented progress.
        try lease.updatePlayback(positionMicroseconds: target, speed: producer.snapshot().speed)
        let child = try FFmpegAudioReader(source: source, producer: producer, maximumFrames: maximumFrames,
            readLease: lease, seekTargetMicroseconds: target, decodePreroll: opus)
        playbackReadLease = lease; hasPlaybackReader = true
        resources = nil
        await child.observeProducerFailure()
        guard playbackReadLease === lease, !Task.isCancelled else {
            await child.cancel(); throw CancellationError()
        }
        return child
    }

    private func seekBuffered(to position: CMTime, useDefaultSeekPointAtZero: Bool = false) async throws {
        guard position.isNumeric, position.epoch == 0, position >= .zero else { throw Failure.invalidSeek }
        let target = CMTimeConvertScale(position, timescale: 1_000_000, method: .roundTowardZero)
        guard target.isNumeric, target.value >= 0 else { throw Failure.invalidSeek }
        guard !seeking else { throw Failure.concurrentOperation }
        try checkFailure()
        guard let bufferedSource else { throw Failure.invalidFormat }
        playbackReadLease?.cancel(); playbackReadLease = nil
        let token = UUID()
        generation = token; seeking = true; activeRead = nil
        producerFailureTask?.cancel(); producerFailureTask = nil
        producerBufferTask?.cancel(); producerBufferTask = nil
        defer { if generation == token { seeking = false } }
        bufferState?.update(.initial)
        let stopped = producer
        producer = nil; resources = nil; pending.removeAll(); offset = 0
        await stopped?.cancel()
        do {
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            let replacement = try await bufferedSource.open(at: target.value, useDefaultSeekPointAtZero: useDefaultSeekPointAtZero)
            guard generation == token, !Task.isCancelled else {
                await replacement.cancel(); throw CancellationError()
            }
            producer = replacement
            let resources = try Resources(configuration: replacement.configuration, timing: timing)
            guard resources.context!.pointee.sample_rate == sampleRate,
                  resources.outputChannels == channels else { throw Failure.invalidFormat }
            self.resources = resources
            pendingTime = .invalid; draining = false
            seekTargetUs = target.value; seekDiscardedFrames = 0; status = .ready
            observeProducerFailure()
        } catch {
            if generation == token {
                let stopped = producer
                if !(error is CancellationError) { terminalError = error; bufferedFailure?.fail(error) }
                retire(as: error is CancellationError ? .cancelled : .failed)
                await stopped?.cancel()
            }
            throw error
        }
    }

    private func seekSynchronous(to position: CMTime) throws {
        guard position.isNumeric, position.epoch == 0, position >= .zero else { throw Failure.invalidSeek }
        let target = CMTimeConvertScale(position, timescale: 1_000_000, method: .roundTowardZero)
        guard target.isNumeric, target.value >= 0 else { throw Failure.invalidSeek }
        guard status != .cancelled else { throw Failure.cancelled }
        if let terminalError { throw terminalError }
        do {
            try Task.checkCancellation()
            try byteInput?.checkFailure()
            if target.value > 0 { byteInput?.prepareForSeek() }
            // Matroska adds index entries while decoding. Reusing that context changed
            // the selected preroll and PCM across identical seeks. Prepare a fresh
            // context through supported APIs, then replace the old owner atomically.
            let replacement = try Resources(url: url, byteInput: byteInput, timing: timing)
            let resources = replacement
            let prerollUs = av_rescale_q(Int64(resources.opusPacketAdmission ? 0 : resources.seekPrerollFrames),
                                        AVRational(num: 1, den: Int32(sampleRate)),
                                        AVRational(num: 1, den: 1_000_000))
            let sourceTimeUs = max(0, target.value - prerollUs)
            if sourceTimeUs > 0 {
                let timestamp = av_rescale_q_rnd(sourceTimeUs, AVRational(num: 1, den: 1_000_000),
                                                resources.timeBase, AV_ROUND_DOWN)
                guard timestamp >= 0 else { throw Failure.invalidSeek }
                guard let demux = resources.demux else { throw Failure.invalidFormat }
                try demux.seekBackward(to: timestamp)
                avcodec_flush_buffers(resources.context)
            }
            try Task.checkCancellation()
            self.resources = replacement
            pending.removeAll()
            offset = 0
            pendingTime = .invalid
            draining = false
            seekTargetUs = target.value
            seekDiscardedFrames = 0
            status = .ready
        } catch {
            if !(error is CancellationError) { terminalError = error; bufferedFailure?.fail(error) }
            retire(as: error is CancellationError ? .cancelled : .failed)
            throw error
        }
    }

    private func retire(as status: Status) {
        timelineLoader.cancel()
        generation = UUID(); activeRead = nil; seeking = false
        producerFailureTask?.cancel(); producerFailureTask = nil
        producerBufferTask?.cancel(); producerBufferTask = nil
        bufferedFailure?.finish()
        bufferState?.finish()
        packetReadLease?.cancel(); playbackReadLease?.cancel(); playbackReadLease = nil
        producer?.stop(); producer = nil
        byteInput?.cancel()
        self.status = status
        pending.removeAll()
        offset = 0
        resources = nil
    }

    private func decodeFrame(generation token: UUID) async throws -> Bool {
        guard let resources, let context = resources.context, let frame = resources.frame else { throw Failure.invalidFormat }
        let producer = self.producer
        guard producer != nil || packetReadLease != nil || resources.demux != nil else { throw Failure.invalidFormat }
        while true {
            try Task.checkCancellation()
            let received = avcodec_receive_frame(context, frame)
            if received == apCodecEOF() { return false }
            if received == 0 {
                defer { av_frame_unref(frame) }
                let count = frame.pointee.nb_samples
                guard count > 0, count <= 65_536,
                      frame.pointee.sample_rate == sampleRate,
                      frame.pointee.ch_layout.nb_channels == resources.sourceChannels,
                      frame.pointee.format == context.pointee.sample_fmt.rawValue else { throw Failure.invalidFormat }
                let initialDiscard = min(Int(count), resources.remainingInitialFrames)
                resources.remainingInitialFrames -= initialDiscard
                if initialDiscard == count { continue }
                let timestamp = try resources.presentationTimestamp(frame.pointee.pts)
                if let seekTargetUs {
                    guard timestamp != Int64.min else { throw Failure.invalidFormat }
                    let frameTimeUs = av_rescale_q_rnd(timestamp, resources.timeBase,
                                                      AVRational(num: 1, den: 1_000_000), AV_ROUND_ZERO)
                    if frameTimeUs < seekTargetUs {
                        seekDiscardedFrames += Int64(count) - Int64(initialDiscard)
                        continue
                    }
                }
                pending = [Int16](repeating: 0, count: Int(count) * resources.sourceChannels)
                let converted = pending.withUnsafeMutableBytes { bytes -> Int32 in
                    var output = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self) as UnsafeMutablePointer<UInt8>?
                    let input = UnsafeRawPointer(frame.pointee.extended_data)
                        .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
                    return swr_convert(resources.converter, &output, count, input, count)
                }
                try Self.check(converted)
                guard converted == count else { throw Failure.invalidFormat }
                if resources.downmix != nil {
                    // The matrix follows each frame's own layout (same channel count).
                    var layout = frame.pointee.ch_layout
                    if av_channel_layout_compare(&resources.matrixLayout, &layout) != 0 {
                        guard let downmix = PCMStereoDownmix(ffmpeg: layout),
                              av_channel_layout_copy(&resources.matrixLayout, &layout) >= 0 else { throw Failure.invalidFormat }
                        resources.downmix = downmix
                    }
                }
                if let downmix = resources.downmix { pending = pending.withUnsafeBufferPointer { downmix.apply($0) } }
                if initialDiscard > 0 { pending.removeFirst(initialDiscard * channels) }
                if timestamp == Int64.min {
                    pendingTime = .invalid
                } else {
                    let scaled = timestamp.multipliedReportingOverflow(by: Int64(resources.timeBase.num))
                    guard !scaled.overflow else { throw Failure.invalidFormat }
                    pendingTime = CMTime(value: scaled.partialValue, timescale: resources.timeBase.den)
                }
                return true
            }
            if received != apCodecAgain() { try Self.check(received) }
            guard !draining else { throw Failure.invalidFormat }
            while true {
                try Task.checkCancellation()
                let next: FFmpegEncodedPacket?
                if let packetReadLease { next = try await packetReadLease.next() }
                else if let producer { next = try await producer.next() }
                else { next = try resources.demux?.next() }
                guard generation == token else { throw CancellationError() }
                guard let packet = next else {
                    try Self.check(avcodec_send_packet(context, nil))
                    draining = true
                    break
                }
                if resources.opusPacketAdmission, !resources.hasAdmittedOpusPacket, let target = seekTargetUs {
                    // Ogg StreamReader admits compressed input whose granule span reaches
                    // the reset position. This precedes the renderer's whole-output discard.
                    let timestamp = try resources.presentationTimestamp(packet.presentationTimestamp)
                    guard timestamp != Int64.min else { throw Failure.invalidFormat }
                    let start = av_rescale_q_rnd(timestamp, resources.timeBase,
                                                AVRational(num: 1, den: 1_000_000), AV_ROUND_ZERO)
                    guard let firstByte = packet.firstByte else { throw Failure.invalidFormat }
                    let duration = try Self.opusPacketDuration(firstByte: firstByte, secondByte: packet.secondByte)
                    if Int128(start) + Int128(duration) < Int128(target) { continue }
                    resources.hasAdmittedOpusPacket = true
                }
                try Self.check(packet.send(to: context))
                break
            }
        }
    }

    private static func check(_ result: Int32) throws {
        if result < 0 { throw Failure.decoding(result) }
    }

    /// Opus TOC duration, matching Media3 OpusUtil (microseconds, maximum 120 ms).
    static func opusPacketDuration(firstByte: UInt8, secondByte: UInt8?) throws -> Int64 {
        let toc = Int(firstByte)
        let config = toc >> 3
        let code = toc & 3
        if code == 3 && secondByte == nil { throw Failure.invalidFormat }
        let frames = code == 0 ? 1 : code == 3 ? Int(secondByte! & 63) : 2
        let frameUs = config >= 16 ? 2500 << (config & 3)
            : config >= 12 ? 10000 << (config & 1)
            : (config & 3) == 3 ? 60000 : 10000 << (config & 3)
        let duration = frameUs * frames
        guard duration > 0, duration <= 120_000 else { throw Failure.invalidFormat }
        return Int64(duration)
    }

    /// Created within initialization, then exclusively owned by the reader actor.
    /// This class gives partial initialization and actor destruction the same cleanup path.
    private final class Resources {
        var demux: FFmpegDemuxContext?
        var context: UnsafeMutablePointer<AVCodecContext>?
        var frame: UnsafeMutablePointer<AVFrame>?
        var converter: OpaquePointer?
        var timeBase = AVRational(num: 0, den: 1)
        var seekPrerollFrames: Int32 = 0
        var opusPacketAdmission = false
        var hasAdmittedOpusPacket = false
        var remainingInitialFrames = 0
        var timestampOffset: Int64 = 0
        /// More than two decoded channels play as stereo (`PCMStereoDownmix`).
        var sourceChannels = 0
        var downmix: PCMStereoDownmix?
        var matrixLayout = AVChannelLayout()
        var outputChannels: Int { downmix == nil ? sourceChannels : 2 }

        convenience init(url: URL?, byteInput: (any MediaByteInput)? = nil, timing: Timing) throws {
            let demux = try FFmpegDemuxContext(url: url, byteInput: byteInput)
            guard let configuration = demux.configuration else { throw Failure.invalidFormat }
            try self.init(configuration: configuration, timing: timing)
            self.demux = demux
        }

        init(configuration: FFmpegStreamConfiguration, timing: Timing) throws {
            do {
                timeBase = configuration.timeBase
                seekPrerollFrames = max(0, configuration.seekPreroll)
                guard timeBase.num > 0, timeBase.den > 0 else { throw Failure.invalidFormat }
                let opusPlayback = timing == .media3 && configuration.codecID == AV_CODEC_ID_OPUS
                context = try configuration.makeCodecContext(manualSkip: opusPlayback)
                guard let context else { throw Failure.allocation }
                let rate = context.pointee.sample_rate
                var layout = context.pointee.ch_layout
                guard rate > 0, rate <= 768_000, (1...32).contains(layout.nb_channels) else { throw Failure.invalidFormat }
                sourceChannels = Int(layout.nb_channels)
                if sourceChannels > 2 {
                    guard let downmix = PCMStereoDownmix(ffmpeg: layout), av_channel_layout_copy(&matrixLayout, &layout) >= 0 else {
                        throw Failure.invalidFormat
                    }
                    self.downmix = downmix
                }
                if opusPlayback {
                    // A fresh C2 Opus decoder removes codec delay from the initial samples
                    // without advancing their packet PTS. It does not remove the end tail.
                    remainingInitialFrames = Int(max(0, configuration.initialPadding))
                    timestampOffset = av_rescale_q(Int64(remainingInitialFrames),
                                                    AVRational(num: 1, den: rate), timeBase)
                    opusPacketAdmission = configuration.containerName == "ogg"
                }
                try FFmpegAudioReader.check(swr_alloc_set_opts2(&converter, &layout, AV_SAMPLE_FMT_S16, rate,
                                                                &layout, context.pointee.sample_fmt, rate, 0, nil))
                try FFmpegAudioReader.check(swr_init(converter))
                frame = av_frame_alloc()
                guard frame != nil else { throw Failure.allocation }
            } catch {
                close()
                throw error
            }
        }

        deinit { close() }

        func presentationTimestamp(_ timestamp: Int64) throws -> Int64 {
            if timestamp == Int64.min { return timestamp }
            let result = timestamp.addingReportingOverflow(timestampOffset)
            guard !result.overflow else { throw Failure.invalidFormat }
            return result.partialValue
        }

        private func close() {
            av_channel_layout_uninit(&matrixLayout)
            swr_free(&converter)
            av_frame_free(&frame)
            avcodec_free_context(&context)
            demux = nil
        }
    }
}
