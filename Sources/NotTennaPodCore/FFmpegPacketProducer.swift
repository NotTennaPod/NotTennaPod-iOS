import CFFmpegCodec
import Foundation

/// Independent demux execution and retained encoded samples. Each producer owns its input;
/// read leases can retire consumers independently. The source owner retains this
/// producer; dropping/stopping it cancels loading and every pending consumer.
final class FFmpegPacketProducer: Sendable {
    enum Failure: Error { case concurrentRead, invalidPosition }
    let configuration: FFmpegStreamConfiguration
    let sourceFailure: PCMSourceFailure
    let bufferState: PCMBufferState
    private let worker: Worker
    struct Snapshot: Sendable {
        let sourceID: UUID
        let unread, retained: Int
        let firstIndex, readIndex, writeIndex, startTimeMicroseconds: Int64
        let allocatedBytes: Int64
        let bufferedThroughMicroseconds: Int64?
        let playbackPositionMicroseconds: Int64
        let speed: Float
        let reading, waitingForBudget, waitingConsumer, ended, cancelled, exited: Bool
    }

    static func open(url: URL? = nil, input: (any MediaByteInput)? = nil,
                     startMicroseconds: Int64 = 0, timing: FFmpegAudioReader.Timing = .media3,
                     useContainerDuration: Bool = true, sourceSeekable: Bool? = nil, sourceDurationMicroseconds: Int64? = nil,
                     sourceSeekPoint: MatroskaTimeline.SeekPoint? = nil,
                     targetBytes: Int64 = PlaybackLoadControl.audioTargetBytes) async throws -> FFmpegPacketProducer {
        guard targetBytes > 0, startMicroseconds >= 0 else { throw PlaybackLoadControl.Failure.invalidInput }
        try Task.checkCancellation()
        let worker = Worker(url: url, input: input, targetBytes: targetBytes, start: startMicroseconds,
            timing: timing, useContainerDuration: useContainerDuration, sourceSeekable: sourceSeekable,
            sourceDurationMicroseconds: sourceDurationMicroseconds, sourceSeekPoint: sourceSeekPoint)
        worker.start()
        do {
            let configuration = try await withTaskCancellationHandler {
                try await worker.prepare()
            } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            return FFmpegPacketProducer(worker: worker, configuration: configuration)
        } catch { worker.cancel(); await worker.waitForExit(); throw error }
    }

    private init(worker: Worker, configuration: FFmpegStreamConfiguration) {
        self.worker = worker; self.configuration = configuration; sourceFailure = worker.sourceFailure; bufferState = worker.bufferState
    }
    deinit { worker.cancel() }

    func makeReadLease() -> ReadLease { ReadLease(owner: self) }

    /// One decoder's cancellation scope over the source's shared read cursor.
    /// The source owner serializes generation changes and retains the producer.
    final class ReadLease: Sendable {
        let configuration: FFmpegStreamConfiguration
        let sourceFailure: PCMSourceFailure
        let bufferState: PCMBufferState
        private let worker: Worker
        private let cancellation = ReadCancellation()
        fileprivate init(owner: FFmpegPacketProducer) {
            worker = owner.worker; configuration = owner.configuration
            sourceFailure = owner.sourceFailure; bufferState = owner.bufferState
        }
        deinit { cancel() }
        func cancel() { cancellation.cancel(); worker.cancelRead(cancellation) }
        func checkFailure() throws {
            if cancellation.cancelled { throw CancellationError() }
            try worker.checkFailure()
        }
        func next() async throws -> FFmpegEncodedPacket? {
            try Task.checkCancellation()
            try checkFailure()
            let packet = try await withTaskCancellationHandler {
                try await worker.next(cancellation: cancellation)
            } onCancel: { self.cancel() }
            try Task.checkCancellation()
            try checkFailure()
            return packet
        }
        func seekWithinBuffer(to positionMicroseconds: Int64) throws -> Bool {
            try checkFailure()
            return try worker.seekWithinBuffer(to: positionMicroseconds, cancellation: cancellation)
        }
        func updatePlayback(positionMicroseconds: Int64, speed: Float) throws {
            try checkFailure()
            try worker.updatePlayback(positionMicroseconds: positionMicroseconds, speed: speed, cancellation: cancellation)
        }
    }

    private final class ReadCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var cancelled: Bool { lock.withLock { value } }
        func cancel() { lock.withLock { value = true } }
    }

    func next() async throws -> FFmpegEncodedPacket? {
        try Task.checkCancellation()
        let packet = try await withTaskCancellationHandler { try await worker.next() } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        try worker.checkFailure()
        return packet
    }
    func updatePlayback(positionMicroseconds: Int64, speed: Float) throws {
        try worker.updatePlayback(positionMicroseconds: positionMicroseconds, speed: speed)
    }
    func snapshot() -> Snapshot { worker.snapshot() }
    func stop() { worker.cancel() }
    func cancel() async { worker.cancel(); await worker.waitForExit() }

    /// The condition protects queue/control/continuations. Only run() accesses the native
    /// demux context, which is destroyed there after the final native read returns.
    private final class Worker: @unchecked Sendable {
        private let sourceID = UUID()
        let sourceFailure: PCMSourceFailure
        let bufferState: PCMBufferState
        private let condition = NSCondition()
        private let execution = DispatchQueue(label: "AntennaPod.FFmpegDemuxProducer")
        private let url: URL?
        private let input: (any MediaByteInput)?
        private let targetBytes: Int64
        private let initialPosition: Int64
        private let timing: FFmpegAudioReader.Timing
        private let useContainerDuration: Bool
        private let sourceSeekable: Bool?
        private let initialSourceDuration: Int64?
        private let sourceSeekPoint: MatroskaTimeline.SeekPoint?
        private var queue = EncodedAudioQueue<FFmpegEncodedPacket>()
        private var configuration: FFmpegStreamConfiguration?
        private var preparation: CheckedContinuation<FFmpegStreamConfiguration, any Error>?
        private struct ReadRequest {
            let continuation: CheckedContinuation<FFmpegEncodedPacket?, any Error>
            let cancellation: ReadCancellation?
            func resume(returning packet: FFmpegEncodedPacket?) {
                if cancellation?.cancelled == true { continuation.resume(throwing: CancellationError()) }
                else { continuation.resume(returning: packet) }
            }
            func resume(throwing error: any Error) { continuation.resume(throwing: error) }
        }
        private var pendingRead: ReadRequest?
        private var exitWaiters: [CheckedContinuation<Void, Never>] = []
        private var failureObserver: Task<Void, Never>?
        private var retryObserver: Task<Void, Never>?
        private var error: (any Error)?
        private var cancelled = false, ended = false, exited = false, reading = false, waiting = false
        private var checkBudget = true
        private var playbackPosition: Int64 = 0
        private var speed: Float = 1
        private var durationMicroseconds: Int64?

        init(url: URL?, input: (any MediaByteInput)?, targetBytes: Int64,
             start: Int64, timing: FFmpegAudioReader.Timing, useContainerDuration: Bool, sourceSeekable: Bool?, sourceDurationMicroseconds: Int64?,
             sourceSeekPoint: MatroskaTimeline.SeekPoint?) {
            self.url = url; self.input = input; self.targetBytes = targetBytes
            self.initialPosition = start; self.timing = timing; playbackPosition = start
            self.useContainerDuration = useContainerDuration
            self.sourceSeekable = sourceSeekable
            initialSourceDuration = sourceDurationMicroseconds
            self.sourceSeekPoint = sourceSeekPoint
            // The input may be a lease over a shared cache. Retiring this producer
            // must never finish the source signal observed by a later generation.
            sourceFailure = PCMSourceFailure()
            bufferState = PCMBufferState(sourceRetry: input?.sourceRetry)
        }
        func start() {
            if let retry = input?.sourceRetry {
                let changes = retry.events()
                retryObserver = Task { [weak self] in
                    for await _ in changes {
                        guard !Task.isCancelled else { return }
                        self?.retryChanged()
                    }
                }
            }
            if let failure = input?.sourceFailure {
                let events = failure.events()
                failureObserver = Task { [weak self] in
                    for await error in events {
                        guard !Task.isCancelled else { return }
                        self?.fail(error)
                    }
                }
            }
            execution.async { self.run() }
        }
        func prepare() async throws -> FFmpegStreamConfiguration {
            try await withCheckedThrowingContinuation { continuation in
                condition.lock()
                let result: Result<FFmpegStreamConfiguration, any Error>?
                if let error { result = .failure(error) }
                else if cancelled { result = .failure(CancellationError()) }
                else if let configuration { result = .success(configuration) }
                else { preparation = continuation; result = nil }
                condition.unlock()
                if let result { continuation.resume(with: result) }
            }
        }
        func next(cancellation: ReadCancellation? = nil) async throws -> FFmpegEncodedPacket? {
            try await withCheckedThrowingContinuation { continuation in
                condition.lock()
                let result: Result<FFmpegEncodedPacket?, any Error>?
                if cancellation?.cancelled == true { result = .failure(CancellationError()) }
                else if let error { result = .failure(error) }
                else if cancelled { result = .failure(CancellationError()) }
                else if pendingRead != nil { result = .failure(Failure.concurrentRead) }
                else if let packet = queue.next()?.packet { result = .success(packet) }
                else if ended { result = .success(nil) }
                else {
                    pendingRead = ReadRequest(continuation: continuation, cancellation: cancellation); result = nil
                    // Wake a loader held by the budget: a starving reader can release it.
                    condition.broadcast()
                }
                publishBufferState()
                condition.unlock()
                if let result { continuation.resume(with: result) }
            }
        }
        func cancelRead(_ cancellation: ReadCancellation) {
            condition.lock()
            let pending = pendingRead?.cancellation === cancellation ? pendingRead : nil
            if pending != nil { pendingRead = nil }
            condition.unlock()
            pending?.resume(throwing: CancellationError())
        }
        func seekWithinBuffer(to position: Int64, cancellation: ReadCancellation) throws -> Bool {
            guard position >= 0 else { throw Failure.invalidPosition }
            condition.lock(); defer { condition.unlock() }
            if cancellation.cancelled { throw CancellationError() }
            if let error { throw error }
            if cancelled { throw CancellationError() }
            guard pendingRead == nil else { throw Failure.concurrentRead }
            // The current codec boundary handles Opus/Vorbis. Both use the
            // original previous-keyframe mode, not the all-sync audio mode.
            let found = queue.seek(to: position, allowTimeBeyondBuffer: ended)
            if found {
                playbackPosition = position
                checkBudget = true
                publishBufferState()
                condition.broadcast()
            }
            return found
        }
        func updatePlayback(positionMicroseconds: Int64, speed: Float, cancellation: ReadCancellation? = nil) throws {
            guard positionMicroseconds >= 0, speed.isFinite, speed > 0 else { throw Failure.invalidPosition }
            condition.lock(); defer { condition.unlock() }
            if cancellation?.cancelled == true { throw CancellationError() }
            if let error { throw error }
            if cancelled { throw CancellationError() }
            playbackPosition = positionMicroseconds; self.speed = speed
            queue.retainBackBuffer(at: positionMicroseconds)
            publishBufferState()
            checkBudget = true
            condition.broadcast()
        }
        func checkFailure() throws {
            // Forwarding an AsyncStream error can be scheduled after this consumer.
            // Validate the input synchronously before exposing an already-queued packet.
            do { try input?.checkFailure() } catch { fail(error) }
            condition.lock(); defer { condition.unlock() }
            if let error { throw error }
            if cancelled { throw CancellationError() }
        }
        func snapshot() -> Snapshot {
            condition.lock(); defer { condition.unlock() }
            return Snapshot(sourceID: sourceID, unread: queue.unreadCount, retained: queue.retainedCount,
                firstIndex: queue.firstIndex, readIndex: queue.readIndex, writeIndex: queue.writeIndex,
                startTimeMicroseconds: queue.startTimeMicroseconds,
                allocatedBytes: queue.allocatedBytes,
                bufferedThroughMicroseconds: queue.largestQueuedTimestampMicroseconds,
                playbackPositionMicroseconds: playbackPosition, speed: speed,
                reading: reading, waitingForBudget: waiting, waitingConsumer: pendingRead != nil,
                ended: ended, cancelled: cancelled, exited: exited)
        }
        func cancel() {
            condition.lock()
            guard !cancelled else { condition.unlock(); return }
            cancelled = true
            bufferState.finish()
            queue.reset()
            let preparation = self.preparation, pendingRead = self.pendingRead
            self.preparation = nil; self.pendingRead = nil
            let observer = failureObserver; failureObserver = nil
            condition.broadcast(); condition.unlock()
            observer?.cancel()
            retryObserver?.cancel()
            input?.cancel()
            sourceFailure.finish()
            preparation?.resume(throwing: CancellationError())
            pendingRead?.resume(throwing: CancellationError())
        }
        func waitForExit() async {
            await withCheckedContinuation { continuation in
                condition.lock()
                if exited { condition.unlock(); continuation.resume() }
                else { exitWaiters.append(continuation); condition.unlock() }
            }
        }
        private func fail(_ error: any Error) {
            condition.lock()
            guard self.error == nil, !cancelled else { condition.unlock(); return }
            self.error = error
            bufferState.finish()
            queue.reset()
            let preparation = self.preparation, pendingRead = self.pendingRead
            self.preparation = nil; self.pendingRead = nil
            condition.broadcast(); condition.unlock()
            sourceFailure.fail(error)
            retryObserver?.cancel()
            input?.cancel()
            preparation?.resume(throwing: error)
            pendingRead?.resume(throwing: error)
        }
        /// Called with condition held, so control and demux updates publish in order.
        /// Buffer notifications are bounded and cannot execute arbitrary observer code here.
        private func publishBufferState() {
            bufferState.update(.init(bufferedThroughMicroseconds: queue.largestQueuedTimestampMicroseconds,
                allocatedBytes: queue.allocatedBytes, targetBytes: targetBytes,
                isLoading: !waiting && !ended, isFinalBuffered: ended,
                isWaitingForSamples: pendingRead != nil,
                isWaitingForSource: pendingRead != nil && input?.isWaitingForData == true,
                isUsable: !cancelled && error == nil, durationMicroseconds: durationMicroseconds,
                sourceSeekable: sourceSeekable))
        }
        private func retryChanged() {
            condition.lock(); defer { condition.unlock() }
            guard !cancelled, error == nil else { return }
            publishBufferState(); bufferState.notifySourceRetryChange()
        }
        private func run() {
            // Local ownership guarantees that even cancellation never frees a format in use.
            do { try produce() } catch { fail(error) }
            condition.lock()
            reading = false; waiting = false; exited = true
            let waiters = exitWaiters; exitWaiters.removeAll()
            condition.unlock()
            for waiter in waiters { waiter.resume() }
        }
        private func produce() throws {
            if initialPosition > 0 { input?.prepareForSeek() }
            let demux = try FFmpegDemuxContext(url: url, byteInput: input)
            guard let descriptor = demux.configuration else { throw FFmpegAudioReader.Failure.invalidFormat }
            if let sourceSeekPoint {
                try demux.seek(to: sourceSeekPoint)
            } else if initialPosition > 0 {
                guard descriptor.sampleRate > 0 else { throw FFmpegAudioReader.Failure.invalidFormat }
                let opusAdmission = timing == .media3 && descriptor.codecID == AV_CODEC_ID_OPUS && descriptor.containerName == "ogg"
                let preroll = av_rescale_q(Int64(opusAdmission ? 0 : max(0, descriptor.seekPreroll)),
                    AVRational(num: 1, den: descriptor.sampleRate), AVRational(num: 1, den: 1_000_000))
                let sourceTime = max(0, initialPosition - preroll)
                if sourceTime > 0 {
                    let timestamp = av_rescale_q_rnd(sourceTime, AVRational(num: 1, den: 1_000_000), descriptor.timeBase, AV_ROUND_DOWN)
                    guard timestamp >= 0 else { throw FFmpegAudioReader.Failure.invalidSeek }
                    try demux.seekBackward(to: timestamp)
                }
            }
            condition.lock()
            guard !cancelled, error == nil else { condition.unlock(); return }
            configuration = descriptor
            durationMicroseconds = useContainerDuration ? descriptor.durationMicroseconds : initialSourceDuration
            publishBufferState()
            let preparation = self.preparation; self.preparation = nil
            condition.unlock()
            preparation?.resume(returning: descriptor)
            var checkPosition = demux.inputPosition ?? 0
            var firstPacket = true
            while true {
                condition.lock()
                while !cancelled && error == nil && checkBudget {
                    do {
                        if try queue.shouldContinueLoadingPreparedAudio(at: playbackPosition, speed: speed, targetBytes: targetBytes) {
                            checkBudget = false; waiting = false; publishBufferState(); break
                        }
                    } catch { condition.unlock(); throw error }
                    // The half-second safeguard measures from the heard position, but decoded audio
                    // not yet heard (decoder, speed processing and output packet assembly) can itself
                    // exceed half a second: large output packets, low sample rates or high speed.
                    // If the reader has consumed every loaded sample and is waiting, playback can
                    // only advance with more input, so waiting for playback progress would stall it
                    // permanently. Load on demand, one packet per waiting read, keeping the budget
                    // check for the next decision.
                    if pendingRead != nil && queue.unreadCount == 0 {
                        waiting = false; publishBufferState(); break
                    }
                    waiting = true
                    publishBufferState()
                    condition.wait()
                    waiting = false
                }
                guard !cancelled, error == nil else { condition.unlock(); return }
                reading = true
                condition.unlock()
                let packet = try demux.next()
                let inputPosition = demux.inputPosition
                condition.lock()
                reading = false
                guard !cancelled, error == nil else { condition.unlock(); return }
                let pendingRead = self.pendingRead
                if let packet {
                    var timestamp = packet.presentationTimestamp
                    if timing == .media3, descriptor.codecID == AV_CODEC_ID_OPUS, descriptor.sampleRate > 0 {
                        timestamp = Int64(clamping: Int128(timestamp) + Int128(av_rescale_q(Int64(descriptor.initialPadding),
                            AVRational(num: 1, den: descriptor.sampleRate), descriptor.timeBase)))
                    }
                    var time = av_rescale_q(timestamp, descriptor.timeBase, AVRational(num: 1, den: 1_000_000))
                    if firstPacket, initialPosition == 0, timing == .media3,
                       descriptor.codecID == AV_CODEC_ID_VORBIS, descriptor.containerName == "ogg", time < 0 {
                        // StreamReader starts currentGranule at zero; VorbisReader's
                        // first audio packet contributes zero granules. Keep this
                        // overlap/preroll packet at queue time zero so an exact-zero
                        // seek selects it before the next packet at the same time.
                        // Native packet timestamps/data remain intact for decoding.
                        time = 0
                    }
                    firstPacket = false
                    do { try queue.append(packet, encodedByteCount: packet.encodedByteCount,
                        timestampMicroseconds: time, isKeyframe: packet.isKeyframe) }
                    catch { condition.unlock(); throw error }
                    // A byte-coordinate identity survives parser recreation and cached
                    // packet replay. Do not clear a retry merely by re-reading old PCM.
                    let identity = packet.bytePosition >= 0 ? packet.bytePosition : inputPosition
                    if let identity, identity >= 0 {
                        input?.sourceRetry?.recordSamples(1, durationKnown: durationMicroseconds != nil,
                            extractedThrough: identity == Int64.max ? identity : identity + 1)
                    }
                    self.pendingRead = nil
                    // Cancellation marks the scope before acquiring this condition.
                    // Do not consume a packet for a read already known to be retired.
                    let canDeliver = pendingRead != nil && pendingRead?.cancellation?.cancelled != true
                    let delivery = canDeliver ? queue.next()?.packet : nil
                    publishBufferState()
                    // Media3 requests another load decision after >1 MiB of extractor input.
                    if let inputPosition, Int128(inputPosition) > Int128(checkPosition) + 1_048_576 {
                        checkPosition = inputPosition; checkBudget = true
                    }
                    condition.unlock()
                    pendingRead?.resume(returning: delivery)
                } else {
                    ended = true; self.pendingRead = nil
                    if durationMicroseconds == nil, timing == .media3 {
                        // ProgressiveMediaPeriod.onLoadCompleted: unknown duration is
                        // resolved only at EOF, with the original 10-ms final-sample estimate.
                        durationMicroseconds = queue.largestQueuedTimestampMicroseconds.map {
                            Int64(clamping: Int128($0) + 10_000)
                        } ?? 0
                    }
                    publishBufferState()
                    condition.unlock()
                    pendingRead?.resume(returning: nil)
                    return
                }
            }
        }
    }
}
