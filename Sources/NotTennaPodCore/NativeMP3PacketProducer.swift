import CoreMedia
import Foundation

/// Parses encoded audio independently of PCM pulls. The owner supplies a cancellable
/// cache lease; stopping this producer does not cancel the item's shared HTTP cache.
final class NativeMP3PacketProducer: Sendable {
    private let worker: Worker
    let bufferState: PCMBufferState
    let sourceFailure: PCMSourceFailure

    /// Bounded native parser bootstrap and original source timeline. It belongs
    /// to the item, so retiring an encoded queue does not discard its seek map.
    struct PreparedSource: Sendable {
        var seed: Data
        let firstAudioOffset: Int64
        let mllt: MP3MLLTSeekTable?
        let timing: NativeMP3PacketParser.Timing
        let timeline: MP3SourceTimeline
        let framesPerPacket: Int64
        var initialRollDistance: Int64
        func point(at time: Int64) throws -> MP3SeekIndex.Point? {
            if let mllt { return try mllt.point(for: .timeMicroseconds(time), firstFramePosition: firstAudioOffset) }
            return timeline.byteIndex?.points(at: time).first
        }
        func time(at position: Int64) throws -> Int64? {
            if let mllt { return try mllt.point(for: .bytePosition(position), firstFramePosition: firstAudioOffset)?.timeMicroseconds }
            return timeline.byteIndex?.time(at: position)
        }
    }
    struct RangeRequest: Sendable {
        let source: PreparedSource
        let targetMicroseconds: Int64
    }

    struct Snapshot: Sendable {
        let unreadPackets, retainedPackets: Int
        let parsedFrames, allocatedBytes: Int64
        let reading, waitingForBudget, waitingConsumer, ended, cancelled, exited: Bool
        let bufferedRange: ClosedRange<Int64>?
        let timeline: MP3SourceTimeline?
        var sourceSeekable: Bool? { timeline?.seekable }
        let progressiveLive: Bool?
        let preparedSource: PreparedSource?
    }

    init(input: any MediaByteInput, prepareSourceTimeline: Bool,
         targetBytes: Int64 = PlaybackLoadControl.audioTargetBytes, rangeRequest: RangeRequest? = nil,
         initialSeekMicroseconds: Int64 = 0) {
        worker = Worker(input: input, prepareSourceTimeline: prepareSourceTimeline, targetBytes: targetBytes, rangeRequest: rangeRequest,
                        initialSeekMicroseconds: initialSeekMicroseconds)
        bufferState = worker.bufferState; sourceFailure = worker.sourceFailure
        worker.start()
    }
    /// A prepared period beyond its known end has no load to start. Preserve
    /// its source metadata without retaining a cancelled HTTP input or queue.
    init(completed snapshot: Snapshot, duration: Int64, retry: PCMSourceRetry?) {
        worker = Worker(completed: snapshot, duration: duration, retry: retry)
        bufferState = worker.bufferState; sourceFailure = worker.sourceFailure
    }
    deinit { worker.cancel() }
    /// Blocking only on the decoder's dedicated executor, never a cooperative task.
    func next() throws -> NativeMP3PacketParser.Batch? { try worker.next() }
    func makeReadLease() -> ReadLease { ReadLease(worker: worker) }
    func seek(to positionMicroseconds: Int64) -> Bool { worker.seek(to: positionMicroseconds) }
    func updatePlayback(_ state: PCMPlaybackLoadState) throws { try worker.updatePlayback(state) }
    func snapshot() -> Snapshot { worker.snapshot() }
    func stop() { worker.cancel() }
    func waitForExit() async { await worker.waitForExit() }

    fileprivate final class Cursor: @unchecked Sendable { var cancelled = false }
    final class ReadLease: Sendable {
        private let worker: Worker
        private let cursor = Cursor()
        fileprivate init(worker: Worker) { self.worker = worker }
        func next() throws -> NativeMP3PacketParser.Batch? { try worker.next(cursor) }
        func cancel() { worker.cancelRead(cursor) }
        deinit { cancel() }
    }

    fileprivate final class Worker: @unchecked Sendable {
        private static let loadCheckInterval: Int64 = 1_048_576
        let bufferState: PCMBufferState
        let sourceFailure = PCMSourceFailure()
        private let condition = NSCondition()
        private let execution = DispatchQueue(label: "AntennaPod.MP3EncodedProducer")
        private var input: (any MediaByteInput)?
        private let prepareSourceTimeline: Bool
        private let targetBytes: Int64
        private let rangeRequest: RangeRequest?
        private let initialSeekMicroseconds: Int64
        private var preparedSource: PreparedSource?
        /// Per-packet queue accounting shares the original bounded parser batch.
        /// Decoder delivery preserves those batches and their existing PCM boundaries.
        private struct Packet: Sendable { let batch: NativeMP3PacketParser.Batch; let index: Int }
        private var queue = EncodedAudioQueue<Packet>()
        private var parsedFrames: Int64 = 0
        private var timeline: MP3SourceTimeline?
        // Initial source classification survives EOF's estimated duration.
        private var progressiveLive: Bool?
        private var duration: Int64?
        // Preserve the last admitted range through decoder teardown so the item
        // owner can distinguish a buffered seek from a new loading period.
        private var bufferedRange: ClosedRange<Int64>?
        private var playbackPosition: Int64 = 0
        private var speed: Float = 1
        private var checkBudget = true
        private var reading = false, waiting = false, waitingConsumer = false
        private var ended = false, cancelled = false, exited = false
        private var error: (any Error)?
        private var exitWaiters: [CheckedContinuation<Void, Never>] = []
        private var failureObserver: Task<Void, Never>?
        private var retryObserver: Task<Void, Never>?
        private let retry: PCMSourceRetry?

        init(input: any MediaByteInput, prepareSourceTimeline: Bool, targetBytes: Int64, rangeRequest: RangeRequest?, initialSeekMicroseconds: Int64) {
            self.rangeRequest = rangeRequest; self.initialSeekMicroseconds = initialSeekMicroseconds
            retry = input.sourceRetry; bufferState = PCMBufferState(sourceRetry: input.sourceRetry)
            self.input = input; self.prepareSourceTimeline = prepareSourceTimeline; self.targetBytes = targetBytes
        }
        init(completed snapshot: Snapshot, duration: Int64, retry: PCMSourceRetry?) {
            self.retry = retry; bufferState = PCMBufferState(sourceRetry: retry)
            prepareSourceTimeline = true; targetBytes = PlaybackLoadControl.audioTargetBytes
            rangeRequest = nil; initialSeekMicroseconds = 0; preparedSource = snapshot.preparedSource
            timeline = snapshot.timeline; progressiveLive = snapshot.progressiveLive
            self.duration = duration; ended = true; exited = true
            publish()
        }
        func start() {
            if let retry {
                let events = retry.events()
                retryObserver = Task { [weak self] in
                    for await _ in events {
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
        func cancelRead(_ cursor: Cursor) {
            condition.lock(); defer { condition.unlock() }
            cursor.cancelled = true; condition.broadcast()
        }
        func seek(to position: Int64) -> Bool {
            condition.lock(); defer { condition.unlock() }
            guard !cancelled, error == nil, !waitingConsumer,
                  queue.seek(to: position, allowTimeBeyondBuffer: ended),
                  let selected = queue.nextSample?.packet,
                  let distance = selected.batch.rollDistances?[selected.index] else { return false }
            // Native dependencies include the MP3 reservoir and decoder refresh.
            // If their history was discarded, this cannot be a retained seek.
            let first = queue.readIndex - distance
            guard first >= queue.firstIndex, queue.seek(toSampleIndex: first) else { return false }
            playbackPosition = position
            checkBudget = true; publish(); condition.broadcast()
            return true
        }
        func next(_ cursor: Cursor? = nil) throws -> NativeMP3PacketParser.Batch? {
            condition.lock(); defer { condition.unlock() }
            guard !waitingConsumer else { throw NativeMP3ProcessingInput.Failure.concurrentRead }
            while !cancelled, cursor?.cancelled != true, error == nil, !ended, queue.unreadCount == 0 {
                // End this decoder period so its codec and processors can flush
                // their tails. The presentation owner distinguishes this from EOF.
                if retry?.requiresDeferredRestart == true || retry?.committedError != nil { return nil }
                // A replacement decoder must consume available cached packets
                // before surfacing an outstanding network error. Read waiting is
                // scoped to this lease, so a retiring decoder cannot block it.
                if let retry, !retry.snapshot.presentationOwned, let error = retry.currentError,
                   input?.isWaitingForData == true { throw error }
                waitingConsumer = true; publish()
                condition.wait()
                waitingConsumer = false; publish()
            }
            if let error { throw error }
            if cancelled || cursor?.cancelled == true { throw CancellationError() }
            guard let first = queue.next()?.packet else { return nil }
            for index in (first.index + 1)..<first.batch.descriptions.count {
                guard queue.next()?.packet.index == index else { throw NativeMP3PacketParser.Failure.invalidPacket }
            }
            // A seek can consume the retained prefix before a renderer exists.
            // Recheck the same source policy when that consumption frees bytes;
            // never use decoder progress as the playback position.
            if waiting { checkBudget = true; condition.broadcast() }
            guard first.index > 0 else { return first.batch }
            let batch = first.batch
            guard let basic = batch.format.audioStreamBasicDescription else { throw NativeMP3PacketParser.Failure.invalidFormat }
            let skipped = batch.descriptions.prefix(first.index).reduce(Int64(0)) {
                $0 + Int64($1.mVariableFramesInPacket == 0 ? basic.mFramesPerPacket : $1.mVariableFramesInPacket)
            }
            let offset = batch.descriptions[first.index].mStartOffset
            let descriptions = batch.descriptions.dropFirst(first.index).map { value in
                var value = value; value.mStartOffset -= offset; return value
            }
            let skippedTime = CMTime(value: skipped, timescale: batch.sampleRate)
            return .init(bytes: batch.bytes.subdata(in: Int(offset)..<batch.bytes.count), descriptions: descriptions,
                format: batch.format, firstFrame: batch.firstFrame + skipped, frameCount: batch.frameCount - skipped,
                timing: batch.timing, rollDistances: batch.rollDistances.map { Array($0.dropFirst(first.index)) },
                rangeOrigin: batch.rangeOrigin.map { $0 + skippedTime }, sourceTime: batch.startTime + skippedTime,
                afterFormatChange: batch.afterFormatChange)
        }
        func updatePlayback(_ state: PCMPlaybackLoadState) throws {
            condition.lock(); defer { condition.unlock() }
            if let error { throw error }
            if cancelled { throw CancellationError() }
            playbackPosition = state.positionMicroseconds; speed = state.speed
            queue.retainBackBuffer(at: playbackPosition)
            checkBudget = true
            publish()
            condition.broadcast()
        }
        func snapshot() -> Snapshot {
            condition.lock(); defer { condition.unlock() }
            return Snapshot(unreadPackets: queue.unreadCount, retainedPackets: queue.retainedCount,
                parsedFrames: parsedFrames, allocatedBytes: queue.allocatedBytes,
                reading: reading, waitingForBudget: waiting, waitingConsumer: waitingConsumer,
                ended: ended, cancelled: cancelled, exited: exited,
                bufferedRange: bufferedRange, timeline: timeline, progressiveLive: progressiveLive, preparedSource: preparedSource)
        }
        func cancel() {
            condition.lock()
            guard !cancelled else { condition.unlock(); return }
            cancelled = true
            queue.reset(); bufferState.finish()
            let input = self.input, observer = failureObserver; failureObserver = nil
            condition.broadcast(); condition.unlock()
            retryObserver?.cancel(); observer?.cancel(); input?.cancel(); sourceFailure.finish()
        }
        private func fail(_ failure: any Error) {
            condition.lock()
            guard !cancelled, error == nil else { condition.unlock(); return }
            // A chosen source error is being delivered after codec/processor
            // drainage. Later loader cleanup must not erase that remaining PCM.
            if retry?.committedError != nil { condition.broadcast(); condition.unlock(); return }
            error = failure
            queue.reset(); bufferState.finish()
            let input = self.input
            condition.broadcast(); condition.unlock()
            retryObserver?.cancel(); sourceFailure.fail(failure); input?.cancel()
        }
        func waitForExit() async {
            await withCheckedContinuation { continuation in
                condition.lock()
                if exited { condition.unlock(); continuation.resume() }
                else { exitWaiters.append(continuation); condition.unlock() }
            }
        }
        private func retryChanged() {
            condition.lock(); defer { condition.unlock() }
            guard !cancelled, error == nil else { return }
            publish(); bufferState.notifySourceRetryChange(); condition.broadcast()
        }
        private func publish() {
            if !cancelled, error == nil {
                if let first = queue.firstQueuedTimestampMicroseconds, let last = queue.largestQueuedTimestampMicroseconds {
                    bufferedRange = first...last
                } else { bufferedRange = nil }
            }
            bufferState.update(.init(bufferedThroughMicroseconds: queue.largestQueuedTimestampMicroseconds,
                allocatedBytes: queue.allocatedBytes, targetBytes: targetBytes,
                isLoading: !waiting && !ended, isFinalBuffered: ended,
                isWaitingForSamples: waitingConsumer,
                isWaitingForSource: waitingConsumer && input?.isWaitingForData == true,
                isUsable: !cancelled && error == nil, durationMicroseconds: duration,
                sourceSeekable: timeline?.seekable))
        }
        private func run() {
            do {
                while true {
                    do { try produce(); break }
                    catch is PCMSourceRetry.RestartUnprepared {
                        // The previous period never admitted packets. Unwind its
                        // ID3 cursor/parser and begin at zero on the same lease;
                        // the input retains retry delay/count and cancellation.
                        guard retry?.snapshot.prepared == false else { throw NativeMP3PacketParser.Failure.invalidPacket }
                    }
                }
            } catch { fail(error) }
            condition.lock()
            reading = false; waiting = false; exited = true
            input = nil
            let waiters = exitWaiters; exitWaiters.removeAll()
            condition.unlock()
            for waiter in waiters { waiter.resume() }
        }
        private struct Positioned {
            let parser: NativeMP3PacketParser
            let source: PreparedSource
            let offset: Int64
            let batches: [NativeMP3PacketParser.Batch]
            let firstFrame: Int64
            /// The first batch's parser time; later batches are this far apart in source time.
            let firstTime: CMTime
            let origin: CMTime
            let ended: Bool
        }

        private func prepareRange(_ request: RangeRequest, input: any MediaByteInput) throws -> Positioned? {
            let source = request.source
            guard source.mllt != nil || source.timeline.byteIndex != nil, request.targetMicroseconds > 0,
                  let duration = source.timeline.durationMicroseconds, request.targetMicroseconds < duration else { return nil }
            let targetFrames = Int64(clamping: Int128(request.targetMicroseconds) * Int128(source.timing.sampleRate) / 1_000_000)
            let targetPacket = targetFrames / source.framesPerPacket
            var history = max(1, source.initialRollDistance)
            // Source-map positions need not be packet boundaries. Inspect the
            // actual first packet and its source clock, then verify dependency
            // history at the target. Retreat when the map did not supply enough. Unsupported
            // maps/history fall back to the existing complete sequential path.
            for _ in 0..<16 {
                let packet = max(0, targetPacket - history)
                guard packet > 0 else { return nil }
                let parser = try NativeMP3PacketParser()
                var keepParser = false
                defer { if !keepParser { parser.close() } }
                _ = try parser.append(source.seed)
                guard parser.timing != nil else { return nil }
                let seekTime = max(0, request.targetMicroseconds - Int64(clamping:
                    Int128(history) * Int128(source.framesPerPacket) * 1_000_000 / Int128(source.timing.sampleRate)))
                guard let seek = try source.point(at: seekTime), seek.bytePosition > source.firstAudioOffset else { return nil }
                try parser.beginDiscontinuity()
                let offset = seek.bytePosition
                input.prepareForIndexedSeek(to: offset)
                var cursor = offset, prefix = Data(), batches: [NativeMP3PacketParser.Batch] = []
                var origin: CMTime?
                var insufficientHistory = false
                while true {
                    let bytes = try input.read(at: cursor, maximumCount: 4096)
                    cursor += Int64(bytes.count)
                    if origin == nil {
                        prefix.append(bytes)
                        guard prefix.count <= 65_536 else { return nil }
                    }
                    let added = try bytes.isEmpty ? parser.finish() : parser.append(bytes)
                    batches += added
                    if origin == nil, let first = batches.first, let description = first.descriptions.first {
                        let packetBytes = first.bytes.subdata(in: Int(description.mStartOffset)..<(Int(description.mStartOffset) + Int(description.mDataByteSize)))
                        guard let match = prefix.range(of: packetBytes) else { return nil }
                        guard let time = try source.time(at: offset + Int64(match.lowerBound)) else { return nil }
                        origin = CMTime(value: time, timescale: 1_000_000)
                            - CMTime(value: source.timing.primingFrameCount ?? 0, timescale: source.timing.sampleRate)
                    }
                    if origin != nil {
                        prefix.removeAll(keepingCapacity: false)
                        // Sparse VBRI entries may precede the target by more
                        // than64KiB. Keep scanning the chosen range with a
                        // bounded packet window instead of reopening at zero.
                        // Retained native dependency distances still decide
                        // whether this window is sufficient for the target.
                        var retainedBytes = batches.reduce(0) { $0 + $1.bytes.count }
                        while retainedBytes > 65_536, batches.count > 1 {
                            let removed = batches.removeFirst()
                            retainedBytes -= removed.bytes.count
                            origin = origin! + removed.duration
                        }
                    }
                    if let origin, let first = batches.first {
                        var available: Int64 = 0
                        for batch in batches {
                            guard let distances = batch.rollDistances,
                                  let packet = batch.format.audioStreamBasicDescription?.mFramesPerPacket else { return nil }
                            // Each packet at its own batch's rate: a later run of frames can differ.
                            let batchStart = origin + (batch.startTime - first.startTime)
                            for (i, _) in batch.descriptions.enumerated() {
                                let time = batchStart + CMTime(value: Int64(i) * Int64(packet), timescale: batch.sampleRate)
                                if time >= CMTime(value: request.targetMicroseconds, timescale: 1_000_000) {
                                    if available >= distances[i] {
                                        keepParser = true
                                        return Positioned(parser: parser, source: source, offset: cursor, batches: batches,
                                            firstFrame: first.firstFrame, firstTime: first.startTime, origin: origin, ended: bytes.isEmpty)
                                    }
                                    insufficientHistory = true; break
                                }
                                available += 1
                            }
                            if insufficientHistory { break }
                        }
                    }
                    if insufficientHistory || bytes.isEmpty { break }
                }
                history = min(targetPacket, history * 2)
            }
            return nil
        }

        private func produce() throws {
            guard let input = condition.withLock({ self.input }) else { throw CancellationError() }
            var positioned = try rangeRequest.flatMap { try prepareRange($0, input: input) }
            if rangeRequest != nil, positioned == nil { input.prepareForIndexedSeek(to: 0) }
            let required = positioned == nil && prepareSourceTimeline ? try MP3RequiredID3Metadata.read(from: input, retainSeekTable: true) : nil
            var parser = try positioned?.parser ?? NativeMP3PacketParser(captureSourceFrame: prepareSourceTimeline)
            defer { parser.close() }
            var offset: Int64 = positioned?.offset ?? 0, checkPosition: Int64 = positioned?.offset ?? 0, extractedPackets: Int64 = 0
            var pending = positioned?.batches
            var configured = positioned != nil
            var preparingSource: PreparedSource?
            var initialSeekPending = prepareSourceTimeline && rangeRequest == nil && initialSeekMicroseconds > 0
            var staged: [NativeMP3PacketParser.Batch] = []
            if let positioned {
                condition.withLock {
                    preparedSource = positioned.source; timeline = positioned.source.timeline
                    duration = timeline?.durationMicroseconds; progressiveLive = false
                    playbackPosition = rangeRequest!.targetMicroseconds
                }
            }
            while true {
                condition.lock()
                while !cancelled && error == nil && checkBudget {
                    do {
                        if try queue.shouldContinueLoadingPreparedAudio(at: playbackPosition, speed: speed, targetBytes: targetBytes) {
                            checkBudget = false; waiting = false; publish(); break
                        }
                    } catch { condition.unlock(); throw error }
                    waiting = true; publish(); condition.wait(); waiting = false
                }
                guard !cancelled, error == nil else { condition.unlock(); return }
                reading = true
                condition.unlock()
                let reachedEnd: Bool
                let rawBatches: [NativeMP3PacketParser.Batch]
                if let prepared = pending {
                    pending = nil; reachedEnd = positioned?.ended == true; rawBatches = prepared
                } else {
                    let data = try input.read(at: offset, maximumCount: 4096)
                    offset += Int64(data.count); reachedEnd = data.isEmpty
                    rawBatches = try data.isEmpty ? parser.finish() : parser.append(data)
                }
                var batches = rawBatches.map { batch in
                    guard let positioned else { return batch }
                    var batch = batch
                    batch.rangeOrigin = positioned.origin + (batch.startTime - positioned.firstTime)
                    batch.timing = positioned.source.timing
                    return batch
                }
                let initialTimeline: MP3SourceTimeline?
                var preparedMetadata: PreparedSource?
                if !configured, let first = batches.first, prepareSourceTimeline {
                    guard let frame = parser.takeSourceFrame() else { throw MP3SourceTimeline.Failure.invalidMetadata }
                    initialTimeline = try MP3SourceTimeline(frame: frame, firstAudioBytes: first.bytes,
                        declaredLength: input.declaredLength).applying(required)
                    // The first decoded MLLT overrides the frame's seek map.
                    // Its source-owned file outlives this input/producer period.
                    if let timeline = initialTimeline, timeline.byteIndex != nil || required?.seekTable != nil,
                       let distance = first.rollDistances?.max(), (0...65_536).contains(first.timing.remainderFrameCount ?? 0) {
                        let marker = frame.bytes.dropFirst(frame.xingOffset).prefix(4)
                        let hasHeader = marker == Data("Xing".utf8) || marker == Data("Info".utf8)
                            || frame.bytes.dropFirst(36).prefix(4) == Data("VBRI".utf8)
                        var seed = hasHeader ? frame.bytes : Data()
                        seed.append(first.bytes.prefix(4096))
                        let candidate = PreparedSource(seed: seed, firstAudioOffset: frame.offset + (hasHeader ? Int64(frame.bytes.count) : 0),
                            mllt: required?.seekTable, timing: first.timing, timeline: timeline, framesPerPacket: frame.framesPerPacket,
                            initialRollDistance: distance)
                        if seed.count >= 2048 { preparedMetadata = candidate }
                        else { preparingSource = candidate }
                    }
                } else {
                    initialTimeline = nil
                    if var candidate = preparingSource {
                        for batch in batches {
                            candidate.seed.append(batch.bytes.prefix(max(0, 4096 - candidate.seed.count)))
                            candidate.initialRollDistance = max(candidate.initialRollDistance, batch.rollDistances?.max() ?? 0)
                        }
                        if candidate.seed.count >= 2048 { preparedMetadata = candidate; preparingSource = nil }
                        else { preparingSource = candidate }
                    }
                }
                condition.lock()
                reading = false
                guard !cancelled, error == nil, retry?.committedError == nil else { condition.unlock(); return }
                if !configured, !batches.isEmpty {
                    configured = true; preparedSource = preparedMetadata; timeline = initialTimeline; duration = initialTimeline?.durationMicroseconds
                    if prepareSourceTimeline {
                        progressiveLive = input.declaredLength == nil && initialTimeline?.durationMicroseconds == nil
                    }
                }
                if let preparedMetadata { preparedSource = preparedMetadata }
                condition.unlock()
                if configured, initialSeekPending {
                    // Hold only the bounded parser bootstrap until its native
                    // dependency metadata is complete. No old-position audio is
                    // admitted before a saved-position range has been considered.
                    if preparingSource != nil, !reachedEnd {
                        staged += batches
                        continue
                    }
                    initialSeekPending = false
                    // Targets within the ordinary acquisition interval retain
                    // sequential packet history and the current HTTP response.
                    // Index only a first seek beyond that existing loading window.
                    if let preparedMetadata, let point = try preparedMetadata.point(at: initialSeekMicroseconds),
                       point.bytePosition > offset, point.bytePosition - offset > Self.loadCheckInterval {
                        let request = RangeRequest(source: preparedMetadata, targetMicroseconds: initialSeekMicroseconds)
                        if let initial = try prepareRange(request, input: input) {
                            parser.close(); parser = initial.parser; positioned = initial
                            offset = initial.offset; checkPosition = initial.offset
                            pending = initial.batches; staged.removeAll()
                            condition.withLock { playbackPosition = initialSeekMicroseconds }
                            continue
                        }
                        // A map with insufficient native history keeps the
                        // original sequential path and its already parsed prefix.
                        input.prepareForIndexedSeek(to: offset)
                    }
                    if !staged.isEmpty { batches = staged + batches; staged.removeAll() }
                }
                condition.lock()
                guard !cancelled, error == nil, retry?.committedError == nil else { condition.unlock(); return }
                do {
                    for batch in batches {
                        guard let basic = batch.format.audioStreamBasicDescription else { throw NativeMP3PacketParser.Failure.invalidFormat }
                        var frame = batch.firstFrame
                        let batchStart = batch.rangeOrigin ?? batch.startTime
                        for (index, packet) in batch.descriptions.enumerated() {
                            // Source time, so a seek within loaded audio lands where continuous playback is.
                            let sampleTime = batchStart + CMTime(value: frame - batch.firstFrame, timescale: batch.sampleRate)
                            let time = CMTimeConvertScale(sampleTime, timescale: 1_000_000, method: .roundTowardZero).value
                            try queue.append(Packet(batch: batch, index: index), encodedByteCount: Int(packet.mDataByteSize),
                                timestampMicroseconds: time)
                            frame += Int64(packet.mVariableFramesInPacket == 0 ? basic.mFramesPerPacket : packet.mVariableFramesInPacket)
                        }
                    }
                } catch { condition.unlock(); throw error }
                parsedFrames = parser.parsedFrames
                let added = batches.reduce(0) { $0 + $1.descriptions.count }
                extractedPackets = Int64(clamping: Int128(extractedPackets) + Int128(added))
                retry?.recordSamples(added, durationKnown: duration != nil, extractedThrough: extractedPackets)
                if reachedEnd {
                    ended = true
                    if duration == nil, prepareSourceTimeline {
                        // ProgressiveMediaPeriod.onLoadCompleted estimates only the
                        // final sample's duration. It does not make a source seekable.
                        duration = queue.largestQueuedTimestampMicroseconds.map { Int64(clamping: Int128($0) + 10_000) } ?? 0
                    }
                }
                if offset > checkPosition + Self.loadCheckInterval { checkPosition = offset; checkBudget = true }
                publish(); condition.broadcast(); condition.unlock()
                if reachedEnd { return }
            }
        }
    }
}
