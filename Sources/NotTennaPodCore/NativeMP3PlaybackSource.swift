import CoreMedia
import Foundation

/// Item lifetime, independent of any decoder generation. Captures routing and
/// credentials once; replacement decoders cancel only their own cache read lease.
/// Source seekability/loading policy is deliberately separate from this reader.
actor NativeMP3PlaybackSource {
    private let localFile: LocalAudioBytes?
    private let url: URL
    private let proxy: PodcastProxy
    private let credentials: FeedCredentials?
    private let userAgent: String
    /// Where this item's relays are retired when the app may be suspended.
    private let reclaim: StreamingRelayReclaim?
    private var preparedInput: PCMRemoteInput?
    private var relay: NativeStreamingRelay?
    private var input: HTTPCodecByteInput?
    private var cachedInput: SharedCachedByteInput?
    private let sharedCache: SharedStreamingCache?
    private var retry: PCMSourceRetry?
    private var reader: NativeMP3SourceReader?
    private var retainedProducer: NativeMP3PacketProducer?
    private var preparedSource: NativeMP3PacketProducer.PreparedSource?
    private var preparedHTTPRepresentation: HTTPMediaRepresentation?
    private var preparedPeriod: (snapshot: NativeMP3PacketProducer.Snapshot, duration: Int64?,
                                 timing: NativeMP3PacketParser.Timing, channels: Int)?
    // Source policy outlives a reader, including cancelled seek preparation.
    private var sourceClassification: (seekable: Bool, progressiveLive: Bool)?
    private var operation: (id: UUID, task: Task<NativeMP3SourceDecoder, any Error>)?

    init(url: URL, proxy: PodcastProxy, credentials: FeedCredentials? = nil, cache: SharedStreamingCache? = nil, retry: PCMSourceRetry? = nil,
         preparedInput: PCMRemoteInput? = nil, reclaim: StreamingRelayReclaim? = .shared) {
        localFile = nil
        self.url = url
        self.proxy = proxy
        self.credentials = credentials
        self.userAgent = preparedInput?.userAgent ?? HTTPUserAgent.unversioned
        self.reclaim = preparedInput.map(\.reclaim) ?? reclaim
        self.sharedCache = cache
        self.retry = preparedInput?.retry ?? retry ?? cache.map { _ in PCMSourceRetry() }
        self.preparedInput = preparedInput
        self.relay = preparedInput?.relay
        self.input = preparedInput?.input
        self.cachedInput = preparedInput?.cached
    }
    init(localURL: URL, file: LocalAudioBytes) {
        url = localURL; localFile = file
        proxy = PodcastProxy(); credentials = nil; sharedCache = nil; userAgent = HTTPUserAgent.unversioned; reclaim = nil
    }
    deinit {
        // Cancel item-owned work even if a closed decoder still exposes its
        // diagnostics/reader. Those references must not extend network lifetime.
        retainedProducer?.stop()
        input?.cancel(); relay?.cancel()
    }

    /// Low-level decoder positioning, not a declaration that a source is seekable.
    /// The playback policy must map unseekable requests to zero before calling here.
    func makeDecoder(start: CMTime = .zero, prepareSourceTimeline: Bool = false) async throws -> NativeMP3SourceDecoder {
        guard start.isNumeric, start.epoch == 0, start >= .zero else {
            throw NativePCMDecoder.Failure.invalidStart
        }
        try Task.checkCancellation()
        let id = UUID(), previous = operation?.task
        previous?.cancel()
        let task = Task {
            if let previous { _ = await previous.result }
            try Task.checkCancellation()
            let cacheReplaced = cachedInput.map { $0.generation != sharedCache?.generation(for: url) } ?? false
            try await retireRejectedRepresentation(force: cacheReplaced)
            let previousState = reader?.snapshot()
            if let representation = input?.httpRepresentation { preparedHTTPRepresentation = representation }
            if let seekable = previousState?.sourceSeekable {
                preparedSource = previousState?.preparedSource
                sourceClassification = (seekable, previousState?.progressiveLive == true)
                if let previousState, let period = preparedPeriod {
                    preparedPeriod = (previousState, reader?.bufferState.snapshot.durationMicroseconds,
                                      period.timing, period.channels)
                }
            }
            if let reader {
                reader.interrupt()
                await reader.close()
            }
            self.reader = nil
            try Task.checkCancellation()
            let target = sourceClassification?.seekable == false ? Int64(0)
                : CMTimeConvertScale(start, timescale: 1_000_000, method: .roundTowardZero).value
            let insideBuffer = previousState?.bufferedRange.map {
                target >= $0.lowerBound && (previousState?.ended == true || target <= $0.upperBound)
            } ?? false
            let outsideBuffer = prepareSourceTimeline && sourceClassification?.seekable == true && !insideBuffer
            let liveReset = prepareSourceTimeline && sourceClassification?.progressiveLive == true
            if liveReset { preparedSource = nil; preparedPeriod = nil; preparedHTTPRepresentation = nil }
            let rangeRequest = outsideBuffer && !liveReset ? preparedSource.map {
                NativeMP3PacketProducer.RangeRequest(source: $0, targetMicroseconds: target)
            } : nil
            let reuse = prepareSourceTimeline && !liveReset && insideBuffer && retry?.requiresDeferredRestart != true
                && retainedProducer?.seek(to: target) == true
            if !reuse, let retainedProducer {
                retainedProducer.stop()
                await retainedProducer.waitForExit()
                self.retainedProducer = nil
                try Task.checkCancellation()
            }
            if retry?.requiresDeferredRestart == true || outsideBuffer || liveReset {
                // Live and outside-buffer seeks start a new load/retry budget.
                // Retire both HTTP and relay callbacks; retain only the shared
                // cache and this item's captured routing and credentials.
                input?.cancel(); relay?.cancel()
                preparedInput = nil; cachedInput = nil; input = nil; relay = nil
                if let retry { self.retry = PCMSourceRetry(sleep: retry.sleep) }
            }
            if outsideBuffer, let period = preparedPeriod, let duration = period.duration, target > duration {
                // ProgressiveMediaPeriod.startLoading uses strict >, not >=.
                // This is the source duration, not the gapless PCM duration.
                let producer = NativeMP3PacketProducer(completed: period.snapshot, duration: duration, retry: retry)
                retainedProducer = producer
                let prepared = NativeMP3SourceReader.Prepared(first: nil, timing: period.timing,
                    channels: period.channels, target: start, decodingStartFrame: 0)
                let decoder = try await NativeMP3SourceDecoder.open(producer: producer, start: start,
                    prepareSourceTimeline: true, ownsProducer: false, owner: self, completed: prepared)
                reader = decoder.reader
                return decoder
            }
            if input == nil && localFile == nil {
                let retry = self.retry
                let opened = try await NativeStreamingRelay.start(url: url, playlist: false,
                    proxy: proxy, credentials: credentials, userAgent: userAgent, onFailure: { error in retry?.recordRelayFailure(error) })
                do {
                    try Task.checkCancellation()
                    input = try HTTPCodecByteInput(relay: opened, reclaim: reclaim, sequentialReadAheadBytes: 65_536,
                        backing: sharedCache.map { .memory(capacity: 131_072, knownLength: $0.length(for: url)) } ?? .disk,
                        retry: retry, expectedRepresentation: preparedHTTPRepresentation ?? sharedCache?.representation(for: url))
                    if let sharedCache, let input {
                        cachedInput = SharedCachedByteInput(upstream: input, cache: sharedCache, url: url)
                    }
                    relay = opened
                } catch { opened.cancel(); throw error }
            }
            let producer: NativeMP3PacketProducer
            if reuse {
                producer = retainedProducer!
            } else {
                guard let lease = localFile?.lease() ?? preparedInput?.makeReadLease()
                    ?? cachedInput?.makeReadLease() ?? input?.makeReadLease() else {
                    throw NativePCMDecoder.Failure.invalidFormat
                }
                producer = NativeMP3PacketProducer(input: lease, prepareSourceTimeline: prepareSourceTimeline,
                    rangeRequest: rangeRequest,
                    initialSeekMicroseconds: prepareSourceTimeline && preparedPeriod == nil && sourceClassification == nil ? target : 0)
            }
            if prepareSourceTimeline { retainedProducer = producer }
            // Normalize using the old source before opening its replacement:
            // a live endpoint may now return a finite, seekable recording.
            let normalizedStart = sourceClassification?.seekable == false ? CMTime.zero : start
            let decoder: NativeMP3SourceDecoder
            do {
                decoder = try await NativeMP3SourceDecoder.open(producer: producer, start: normalizedStart,
                    prepareSourceTimeline: prepareSourceTimeline, ownsProducer: !prepareSourceTimeline, owner: self)
            } catch {
                let cacheError = error as? SharedStreamingCache.Failure
                let cacheChanged = cacheError == .staleGeneration || cacheError == .conflictingRepresentation
                if input?.snapshot().representationRejected == true || cacheChanged {
                    producer.stop(); await producer.waitForExit()
                    try await retireRejectedRepresentation(force: cacheChanged)
                }
                if cacheChanged { throw URLError(.resourceUnavailable) }
                throw error
            }
            reader = decoder.reader
            if prepareSourceTimeline {
                preparedPeriod = (producer.snapshot(), producer.bufferState.snapshot.durationMicroseconds,
                                  decoder.timing, decoder.channels)
            }
            return decoder
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

    var networkSnapshot: HTTPCodecByteInput.Snapshot? { input?.snapshot() }
    var cacheURL: URL? { input?.cacheURL }

    private func retireRejectedRepresentation(force: Bool = false) async throws {
        guard let input, force || input.snapshot().representationRejected else { return }
        let rejected = input.httpRepresentation
        let cacheGeneration = cachedInput?.generation
        reader?.interrupt(); await reader?.close(); reader = nil
        if let retainedProducer { retainedProducer.stop(); await retainedProducer.waitForExit() }
        retainedProducer = nil
        input.cancel(); relay?.cancel()
        preparedInput = nil; self.input = nil; relay = nil; cachedInput = nil
        preparedHTTPRepresentation = nil; preparedSource = nil; preparedPeriod = nil; sourceClassification = nil
        if let retry { self.retry = PCMSourceRetry(sleep: retry.sleep) }
        try sharedCache?.invalidate(for: url, matching: rejected, generation: cacheGeneration)
    }
}

/// Conversion and blocking encoded-queue pulls use a dedicated serial queue.
/// Parsing/loading has its own executor and continues while PCM output is paused.
/// Cancellation wakes both queues without needing to enter this actor.
fileprivate actor NativeMP3SourceReader {
    private nonisolated let executor = BlockingReadExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private nonisolated let producer: NativeMP3PacketProducer
    private nonisolated let lease: NativeMP3PacketProducer.ReadLease
    private nonisolated let ownsProducer: Bool
    private var decodingStartFrame: Int64 = 0
    private var decoder: NativeMP3PCMDecoder?
    private var inputEnded = false
    private var closed = false
    private var failure: (any Error)?

    init(producer: NativeMP3PacketProducer, ownsProducer: Bool) {
        self.producer = producer
        lease = producer.makeReadLease()
        self.ownsProducer = ownsProducer
    }

    struct Prepared: Sendable {
        let first: NativePCMDecoder.Packet?
        let timing: NativeMP3PacketParser.Timing
        let channels: Int
        let target: CMTime
        let decodingStartFrame: Int64
    }

    func prepare(start: CMTime) throws -> Prepared {
        do {
            // The first packet fixes the decoder's source grid and the period's
            // seekability; nothing is decoded before admission is known.
            while decoder == nil { try pull() }
            guard let decoder else { throw NativePCMDecoder.Failure.invalidFormat }
            let target = producer.bufferState.snapshot.sourceSeekable == false ? CMTime.zero : start
            try producer.updatePlayback(PCMPlaybackLoadState(positionMicroseconds: CMTimeConvertScale(target,
                timescale: 1_000_000, method: .roundTowardZero).value, speed: 1))
            try decoder.admit(from: target)
            let first = try next()
            return Prepared(first: first, timing: decoder.timing, channels: decoder.channels,
                target: target, decodingStartFrame: decodingStartFrame)
        } catch { retire(error); throw error }
    }

    func next() throws -> NativePCMDecoder.Packet? {
        do {
            while true {
                if let decoder {
                    try check()
                    switch try decoder.next() {
                    case .audio(let packet): return packet
                    case .ended: return nil
                    case .needsInput: break
                    }
                }
                try pull()
            }
        } catch { retire(error); throw error }
    }

    private func check() throws {
        try Task.checkCancellation()
        if let failure { throw failure }
        guard !closed else { throw NativePCMDecoder.Failure.cancelled }
        try producer.sourceFailure.check()
    }

    /// Hands the decoder one encoded batch, creating it from the first, or the source's end.
    private func pull() throws {
        try check()
        guard !inputEnded else { throw NativePCMDecoder.Failure.invalidFormat }
        if let batch = try lease.next() {
            if decoder == nil {
                decodingStartFrame = batch.firstFrame
                decoder = try NativeMP3PCMDecoder(format: batch.format, timing: batch.timing, firstFrame: batch.firstFrame,
                    rangeOrigin: batch.rangeOrigin, sourceTime: batch.sourceTime, afterFormatChange: batch.afterFormatChange)
            }
            try decoder?.accept(batch)
        } else {
            guard let decoder else { throw NativePCMDecoder.Failure.invalidFormat }
            inputEnded = true
            try decoder.finish(afterSourceFailure: producer.bufferState.sourceRetry?.committedError != nil)
        }
    }

    nonisolated var bufferState: PCMBufferState { producer.bufferState }
    nonisolated var sourceFailure: PCMSourceFailure { producer.sourceFailure }
    nonisolated func updatePlayback(_ state: PCMPlaybackLoadState) throws { try producer.updatePlayback(state) }
    nonisolated func snapshot() -> NativeMP3PacketProducer.Snapshot { producer.snapshot() }
    nonisolated func interrupt() {
        lease.cancel()
        if ownsProducer { producer.stop() }
    }
    func close() async {
        retire(nil)
        if ownsProducer { await producer.waitForExit() }
    }
    private func retire(_ error: (any Error)?) {
        guard !closed else { return }
        closed = true
        failure = error
        decoder?.close(); interrupt()
    }
}

/// Fresh decoder state over retained encoded packets, with native dependency
/// preroll. No PCM for an entire episode is retained.
actor NativeMP3SourceDecoder: PCMDecoding {
    nonisolated let sampleRate: Int
    nonisolated let channels: Int
    nonisolated let startTime: CMTime
    nonisolated let startFrame: Int64
    nonisolated let timing: NativeMP3PacketParser.Timing
    nonisolated let decodingStartFrame: Int64
    nonisolated let sourceFailure: PCMSourceFailure?
    nonisolated let bufferState: PCMBufferState?
    fileprivate nonisolated let reader: NativeMP3SourceReader
    private var owner: NativeMP3PlaybackSource?
    private var first: NativePCMDecoder.Packet?
    private var ended: Bool
    private var cancelled = false
    private var reading = false

    fileprivate static func open(producer: NativeMP3PacketProducer, start: CMTime,
                                 prepareSourceTimeline: Bool, ownsProducer: Bool,
                                 owner: NativeMP3PlaybackSource,
                                 completed: NativeMP3SourceReader.Prepared? = nil) async throws -> NativeMP3SourceDecoder {
        let reader = NativeMP3SourceReader(producer: producer, ownsProducer: ownsProducer)
        return try await withTaskCancellationHandler {
            do {
                let prepared: NativeMP3SourceReader.Prepared
                if let completed { prepared = completed }
                else { prepared = try await reader.prepare(start: start) }
                try Task.checkCancellation()
                return NativeMP3SourceDecoder(reader: reader, prepared: prepared,
                    prepareSourceTimeline: prepareSourceTimeline, owner: owner)
            } catch { await reader.close(); throw error }
        } onCancel: { reader.interrupt() }
    }

    private init(reader: NativeMP3SourceReader, prepared: NativeMP3SourceReader.Prepared,
                 prepareSourceTimeline: Bool, owner: NativeMP3PlaybackSource) {
        self.reader = reader
        self.owner = owner
        first = prepared.first
        ended = first == nil
        timing = prepared.timing
        decodingStartFrame = prepared.decodingStartFrame
        sampleRate = Int(timing.sampleRate)
        channels = prepared.channels
        startTime = prepared.first?.presentationTime ?? prepared.target
        startFrame = CMTimeConvertScale(startTime, timescale: timing.sampleRate, method: .roundTowardZero).value
        sourceFailure = reader.sourceFailure
        bufferState = prepareSourceTimeline ? reader.bufferState : nil
    }

    func next() async throws -> NativePCMDecoder.Packet? {
        guard !cancelled else { throw NativePCMDecoder.Failure.cancelled }
        guard !reading else { throw NativeMP3ProcessingInput.Failure.concurrentRead }
        reading = true
        defer { reading = false }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try sourceFailure?.check()
                guard !ended else { return nil }
                if let packet = first { first = nil; return packet }
                let packet = try await reader.next()
                try Task.checkCancellation()
                guard !cancelled else { throw NativePCMDecoder.Failure.cancelled }
                if packet == nil { ended = true }
                return packet
            } catch { await cancel(); throw error }
        } onCancel: { reader.interrupt() }
    }

    func updatePlayback(_ state: PCMPlaybackLoadState) async throws {
        guard !cancelled else { throw NativePCMDecoder.Failure.cancelled }
        try reader.updatePlayback(state)
    }
    nonisolated var producerSnapshot: NativeMP3PacketProducer.Snapshot { reader.snapshot() }

    nonisolated func cancel() async {
        reader.interrupt()
        await retire()
    }

    private func retire() async {
        cancelled = true
        first = nil
        owner = nil
        await reader.close()
    }

    deinit { reader.interrupt() }
}
