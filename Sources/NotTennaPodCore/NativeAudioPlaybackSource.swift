import CoreMedia
import Foundation

/// Retains one captured native-format item across disposable decoder generations.
/// Owns independent packet loading across disposable conversion generations.
/// Indexed fallback readers do not manufacture buffer state from PCM progress.
actor NativeAudioPlaybackSource {
    typealias Reopen = @Sendable () async throws -> PCMRemoteInput
    private var remote: PCMRemoteInput
    private let reopen: Reopen
    private let maximumFrames: Int
    private let cache: SharedStreamingCache, url: URL
    private var needsReopen = false
    private var resetTimelineOnReopen = false
    private var preparedPeriod = false
    private var preparedFormat: (sampleRate: Int, channels: Int)?
    private var timeline: NativeAudioSourceTimeline?
    private var retainedProducer: NativeAudioPacketProducer?
    private var requiresRandomAccess = false
    private var active: (any PCMDecoding)?
    private weak var activeDecoder: NativeAudioSourceDecoder?
    private var operation: (id: UUID, task: Task<NativeAudioSourceDecoder, any Error>)?

    init(remote: PCMRemoteInput, url: URL, proxy: PodcastProxy, credentials: FeedCredentials?,
         cache: SharedStreamingCache, maximumFrames: Int = 4096, reopen: Reopen? = nil) throws {
        guard (1...65536).contains(maximumFrames) else { throw NativeAudioStreamParser.Failure.invalidCapacity }
        _ = try NativeAudioSourceTimeline.Format(remote.format)
        self.remote = remote; self.maximumFrames = maximumFrames
        self.cache = cache; self.url = url
        let sleep = remote.retry.sleep, userAgent = remote.userAgent, reclaim = remote.reclaim
        self.reopen = reopen ?? { try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache,
            retry: PCMSourceRetry(sleep: sleep), userAgent: userAgent, reclaim: reclaim) }
    }
    deinit { retainedProducer?.stop(); remote.input.cancel(); remote.relay.cancel() }

    /// Opt-in source processing exposes full AAC units and startup metadata.
    /// It does not choose a trailing-padding policy.
    func makeDecoder(start: CMTime = .zero,
                     admission: NativeAudioSeekAdmission = .wholeBuffer,
                     processStartupTrim: Bool = false) async throws -> NativeAudioSourceDecoder {
        guard start.isNumeric, start.epoch == 0, start >= .zero else { throw NativePCMDecoder.Failure.invalidStart }
        guard !processStartupTrim || admission == .wholeBuffer else { throw NativePCMDecoder.Failure.invalidFormat }
        try Task.checkCancellation()
        let id = UUID(), previous = operation?.task
        previous?.cancel()
        let task = Task {
            if let previous { _ = await previous.result }
            try Task.checkCancellation()
            if !needsReopen || !resetTimelineOnReopen {
                let cacheReplaced = remote.cached.generation != cache.generation(for: url)
                try await retireRejectedRepresentation(force: cacheReplaced)
            }
            let normalized = timeline?.seekable == false ? CMTime.zero : start
            let emptySource = admission == .wholeBuffer && timeline?.mp4EmptyAudioFormat != nil
            let liveReset = !emptySource && timeline?.durationMicroseconds == nil && timeline != nil && remote.input.initialDeclaredLength == nil
            await activeDecoder?.cancel()
            if let active { await active.cancel(); self.active = nil }
            if needsReopen {
                if !emptySource, preparedEnd(at: normalized) == nil { try await reopenPendingLoad() }
            } else if liveReset || remote.retry.requiresDeferredRestart {
                try await restartLoad(resetTimeline: true)
            }
            while true {
                do {
                    let format = try NativeAudioSourceTimeline.Format(remote.format)
                    if timeline == nil {
                        timeline = try await NativeAudioSourceTimeline.read(input: remote.makeReadLease(), format: format)
                    }
                    try Task.checkCancellation()
                    guard let timeline else { throw NativePCMDecoder.Failure.invalidFormat }
                    guard timeline.supportsNativePacketTimeline else { throw NativePCMDecoder.Failure.invalidFormat }
                    let (decodingTimeline, trim) = try timeline.preparingStartupTrim(processStartupTrim)
                    let noAudio = admission == .wholeBuffer && timeline.mp4EmptyAudioFormat != nil
                    let target = timeline.seekable && !noAudio ? normalized : .zero
                    let decoder = try await prepareDecoder(target: target, timeline: decodingTimeline, format: format, admission: admission)
                    do {
                        try Task.checkCancellation()
                        let prepared = try await NativeAudioSourceDecoder.open(decoder: decoder, timeline: timeline,
                            start: target, admission: admission, startupTrim: trim, owner: self)
                        preparedPeriod = true
                        preparedFormat = (prepared.sampleRate, prepared.channels)
                        active = decoder
                        activeDecoder = prepared
                        return prepared
                    } catch { await decoder.cancel(); throw error }
                } catch is PCMSourceRetry.RestartUnprepared where !remote.retry.snapshot.prepared {
                    await retireProducer()
                    timeline = nil
                    try await remote.refreshIdentificationAfterStartupRestart()
                    try Task.checkCancellation()
                } catch {
                    if !(error is CancellationError) { await retireProducer() }
                    let cacheError = error as? SharedStreamingCache.Failure
                    let cacheChanged = cacheError == .staleGeneration || cacheError == .conflictingRepresentation
                    if remote.input.snapshot().representationRejected || cacheChanged {
                        try await retireRejectedRepresentation(force: cacheChanged)
                    }
                    if cacheChanged { throw URLError(.resourceUnavailable) }
                    throw error
                }
            }
        }
        operation = (id, task)
        defer { if operation?.id == id { operation = nil } }
        return try await withTaskCancellationHandler {
            let decoder = try await task.value
            do {
                try Task.checkCancellation()
                guard operation?.id == id else { throw CancellationError() }
                return decoder
            } catch { await decoder.cancel(); throw error }
        } onCancel: { task.cancel() }
    }

    private func prepareDecoder(target: CMTime, timeline: NativeAudioSourceTimeline,
                                format: NativeAudioSourceTimeline.Format,
                                admission: NativeAudioSeekAdmission) async throws -> any PCMDecoding {
        if admission == .wholeBuffer, let empty = timeline.mp4EmptyAudioFormat {
            // The original omits every selected track, then resolves normal EOF
            // to duration zero. Retire the input without parsing/decoding excluded
            // media; the file's nominal geometry only types the empty endpoint.
            await retireLoad(resetTimeline: false)
            return try NativeAudioCompletedDecoder(sampleRate: empty.sampleRate, channels: empty.channels,
                start: .zero, duration: 0, retry: PCMSourceRetry(sleep: remote.retry.sleep))
        }
        let microseconds = CMTimeConvertScale(target, timescale: 1_000_000, method: .roundTowardZero).value
        let sourceEdit = admission == .wholeBuffer ? timeline.mp4AudioEdit : nil
        let sourceSequence = admission == .wholeBuffer ? timeline.mp4AudioSequence : nil
        if let retainedProducer, retainedProducer.mp4Edit == sourceEdit, retainedProducer.mp4Sequence == sourceSequence,
           retainedProducer.seek(to: microseconds) {
            return try await NativeBufferedAudioDecoder.open(producer: retainedProducer, ownsProducer: false,
                maximumFrames: maximumFrames, start: target, admission: admission)
        }
        // A seek that cannot reuse the encoded queue starts a new loading
        // task, including a fresh retry budget. Retained seeks keep both.
        let replacesLoad = preparedPeriod || remote.retry.snapshot.prepared
        await retireProducer()
        try Task.checkCancellation()
        if let end = preparedEnd(at: target) {
            await retireLoad(resetTimeline: false)
            return try NativeAudioCompletedDecoder(sampleRate: end.sampleRate, channels: end.channels,
                start: target, duration: end.duration, retry: PCMSourceRetry(sleep: remote.retry.sleep))
        }
        if replacesLoad { try await restartLoad(resetTimeline: false) }
        if target == .zero && !requiresRandomAccess && sourceSequence == nil {
            let producer = NativeAudioPacketProducer(input: remote.makeReadLease(), timeline: timeline, format: format, applyMP4Edits: admission == .wholeBuffer)
            retainedProducer = producer
            do {
                return try await NativeBufferedAudioDecoder.open(producer: producer, ownsProducer: false,
                    maximumFrames: maximumFrames, start: target, admission: admission)
            } catch NativeAudioStreamParser.Failure.requiresRandomAccess where format == .mp4 {
                await retireProducer()
                requiresRandomAccess = true
            }
        }
        if format == .adts, admission == .wholeBuffer, let index = timeline.adtsByteIndex {
            remote.input.allowDecoderRangeSeeks()
            let point = index.points(at: microseconds).first
            let producer = NativeAudioPacketProducer(input: remote.makeReadLease(), timeline: timeline, format: format,
                adtsStart: .init(bytePosition: point.bytePosition, time: target))
            retainedProducer = producer
            return try await NativeBufferedAudioDecoder.open(producer: producer, ownsProducer: false,
                maximumFrames: maximumFrames, start: target, admission: admission)
        }
        if format == .flac, timeline.flacByteIndex != nil {
            remote.input.allowDecoderRangeSeeks()
            let producer = NativeAudioPacketProducer(input: remote.makeReadLease(), timeline: timeline, format: format, flacStart: target)
            retainedProducer = producer
            return try await NativeBufferedAudioDecoder.open(producer: producer, ownsProducer: false,
                maximumFrames: maximumFrames, start: target, admission: admission)
        }
        let indexedInput: any MediaByteInput
        if remote.cached.length != nil {
            remote.input.allowDecoderRangeSeeks()
            indexedInput = remote.makeReadLease()
        } else if format == .mp4 {
            indexedInput = try await NativeMP4Input.open(remote: remote)
        } else {
            // AudioFile requires a real finite extent. Unknown WAV remains an
            // incremental reconstruction until an extent is actually established.
            return try await NativeIncrementalPCMDecoder.open(input: remote.makeReadLease(), maximumFrames: maximumFrames)
        }
        let producer = NativeAudioPacketProducer(input: indexedInput, timeline: timeline, format: format, indexedStart: target, applyMP4Edits: admission == .wholeBuffer)
        retainedProducer = producer
        return try await NativeBufferedAudioDecoder.open(producer: producer, ownsProducer: false,
            maximumFrames: maximumFrames, start: target, admission: admission)
    }

    private func preparedEnd(at target: CMTime) -> (sampleRate: Int, channels: Int, duration: Int64)? {
        guard preparedPeriod, timeline?.seekable == true, let duration = timeline?.durationMicroseconds,
              let preparedFormat else { return nil }
        let position = CMTimeConvertScale(target, timescale: 1_000_000, method: .roundTowardZero)
        guard position.isNumeric, position.value > duration else { return nil }
        return (preparedFormat.sampleRate, preparedFormat.channels, duration)
    }

    private func retireLoad(resetTimeline: Bool) async {
        await retireProducer()
        remote.input.cancel(); remote.relay.cancel()
        needsReopen = true
        resetTimelineOnReopen = resetTimeline
    }

    private func restartLoad(resetTimeline: Bool) async throws {
        await retireLoad(resetTimeline: resetTimeline)
        try await reopenPendingLoad()
    }

    private func reopenPendingLoad() async throws {
        // Keep the pending reset and original period classification until the
        // replacement is fully identified. Failure/cancellation must leave the
        // next explicit attempt able to reopen with the captured context.
        let replacement = try await reopen()
        try Task.checkCancellation()
        if !resetTimelineOnReopen, timeline != nil,
           replacement.cached.generation != remote.cached.generation {
            // The prepared timeline belongs to the retired input's generation.
            // A newly identified cached representation cannot inherit it, even
            // if replacement happened after makeDecoder's initial check.
            try await retireRejectedRepresentation(force: true)
            throw URLError(.resourceUnavailable)
        }
        remote = replacement
        needsReopen = false
        if resetTimelineOnReopen { timeline = nil; requiresRandomAccess = false; preparedPeriod = false; preparedFormat = nil }
        resetTimelineOnReopen = false
    }

    private func retireProducer() async {
        if let retainedProducer {
            retainedProducer.stop()
            await retainedProducer.waitForExit()
            self.retainedProducer = nil
        }
    }

    private func retireRejectedRepresentation(force: Bool = false) async throws {
        guard force || remote.input.snapshot().representationRejected else { return }
        let rejected = remote.input.httpRepresentation, generation = remote.cached.generation
        await activeDecoder?.cancel(); activeDecoder = nil
        if let active { await active.cancel(); self.active = nil }
        await retireProducer()
        remote.input.cancel(); remote.relay.cancel()
        timeline = nil; requiresRandomAccess = false; preparedPeriod = false; preparedFormat = nil
        needsReopen = true; resetTimelineOnReopen = false
        // A concurrent/newer cache generation must survive retirement of this
        // old reader. The cache checks both generation and representation.
        try cache.invalidate(for: url, matching: rejected, generation: generation)
    }

    var networkSnapshot: HTTPCodecByteInput.Snapshot { remote.input.snapshot() }

}
