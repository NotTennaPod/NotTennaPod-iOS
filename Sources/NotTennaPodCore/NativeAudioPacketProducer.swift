import AudioToolbox
import CoreMedia
import Foundation

/// Native packet extraction continues independently of PCM pulls. Retained
/// encoded bytes, source timestamps and renderer position drive load control.
final class NativeAudioPacketProducer: Sendable {
    struct ADTSStart: Sendable {
        let bytePosition: Int64
        let time: CMTime
    }
    let adtsStart: ADTSStart?
    let mp4Edit: NativeMP4SourceTimeline.AudioEdit?
    let mp4Sequence: [NativeMP4SourceTimeline.AudioEdit]?
    var hasMP4SourceTiming: Bool { mp4Edit != nil || mp4Sequence != nil }
    struct Snapshot: Sendable {
        let unreadPackets: Int, retainedPackets: Int
        let parsedFrames: Int64, allocatedBytes: Int64, encodedBytes: Int64
        let bufferedRange: ClosedRange<Int64>?
        let waitingForBudget: Bool, waitingConsumer: Bool, ended: Bool, cancelled: Bool, exited: Bool
    }
    private let worker: Worker
    let bufferState: PCMBufferState
    let sourceFailure: PCMSourceFailure
    init(input: any MediaByteInput, timeline: NativeAudioSourceTimeline, format: NativeAudioSourceTimeline.Format,
         targetBytes: Int64 = PlaybackLoadControl.audioTargetBytes, indexedStart: CMTime? = nil, adtsStart: ADTSStart? = nil, flacStart: CMTime? = nil, applyMP4Edits: Bool = false) {
        self.adtsStart = adtsStart
        mp4Edit = applyMP4Edits && format == .mp4 ? timeline.mp4AudioEdit : nil
        mp4Sequence = applyMP4Edits && format == .mp4 ? timeline.mp4AudioSequence : nil
        worker = Worker(input: input, timeline: timeline, format: format, targetBytes: targetBytes, indexedStart: indexedStart, adtsStart: adtsStart, flacStart: flacStart, mp4Edit: mp4Edit, mp4Sequence: mp4Sequence, exactMP4Interval: format == .mp4 && !applyMP4Edits)
        bufferState = worker.bufferState; sourceFailure = worker.sourceFailure
        worker.start()
    }
    deinit { worker.stop() }
    func makeReadLease() -> ReadLease { ReadLease(worker: worker) }
    func updatePlayback(_ state: PCMPlaybackLoadState) throws { try worker.updatePlayback(state) }
    func snapshot() -> Snapshot { worker.snapshot() }
    func seek(to positionMicroseconds: Int64) -> Bool { worker.seek(to: positionMicroseconds) }
    func stop() { worker.stop() }
    func waitForExit() async { await worker.waitForExit() }

    fileprivate final class Cursor: @unchecked Sendable { var cancelled = false }
    final class ReadLease: Sendable {
        private let worker: Worker, cursor: Cursor
        fileprivate init(worker: Worker) { self.worker = worker; cursor = worker.makeCursor() }
        func configuration() throws -> NativeAudioStreamParser.Configuration { try worker.configuration(cursor) }
        func next() throws -> NativeAudioStreamParser.Batch? { try worker.next(cursor) }
        func cancel() { worker.cancelRead(cursor) }
        deinit { cancel() }
    }
    fileprivate final class Worker: @unchecked Sendable {
        private struct Packet: Sendable {
            let batch: NativeAudioStreamParser.Batch; let index: Int; let count: Int
            let firstFrame: Int64, rollDistance: Int64?
        }
        let bufferState: PCMBufferState, sourceFailure = PCMSourceFailure()
        private let condition = NSCondition(), execution = DispatchQueue(label: "AntennaPod.NativeEncodedProducer")
        private var input: (any MediaByteInput)?
        private let timeline: NativeAudioSourceTimeline, format: NativeAudioSourceTimeline.Format
        private let targetBytes: Int64, retry: PCMSourceRetry?
        private let indexedStart: CMTime?
        private let exactMP4Interval: Bool
        private let adtsStart: ADTSStart?
        private let mp4Edit: NativeMP4SourceTimeline.AudioEdit?
        private let mp4Sequence: [NativeMP4SourceTimeline.AudioEdit]?
        private let flacStart: CMTime?
        private var timestampOffset: Int64 = 0
        /// Raw ADTS segments after a configuration change. Segment zero keeps the
        /// producer's configuration and timing exactly; a later one has its own
        /// configuration, and its clock continues from the previous frame's end.
        private var segment = 0
        private var segmentConfig: NativeAudioStreamParser.Configuration?
        private var segmentTime: Int64 = 0, segmentPackets: Int64 = 0, nextFrameTime: Int64 = 0
        /// A seek's first parsed frame has been placed: in the stream's first
        /// configuration (segment zero) or, landing in another, as a later segment.
        private var adtsPositioned = false
        private var activeReaders = 0
        private var config: NativeAudioStreamParser.Configuration?
        private var queue = EncodedAudioQueue<Packet>()
        private var parsedFrames: Int64 = 0, position: Int64 = 0, duration: Int64?
        private var speed: Float = 1
        private var checkBudget = true, waiting = false, consumer = false, ended = false, cancelled = false, exited = false
        private var error: (any Error)?
        private var failureObserver: Task<Void, Never>?, retryObserver: Task<Void, Never>?
        private var waiters: [CheckedContinuation<Void, Never>] = []
        init(input: any MediaByteInput, timeline: NativeAudioSourceTimeline, format: NativeAudioSourceTimeline.Format,
             targetBytes: Int64, indexedStart: CMTime?, adtsStart: ADTSStart?, flacStart: CMTime?, mp4Edit: NativeMP4SourceTimeline.AudioEdit?, mp4Sequence: [NativeMP4SourceTimeline.AudioEdit]?, exactMP4Interval: Bool) {
            self.input = input; self.timeline = timeline; self.format = format; self.targetBytes = targetBytes
            self.exactMP4Interval = exactMP4Interval
            retry = input.sourceRetry; duration = timeline.durationMicroseconds
            bufferState = PCMBufferState(sourceRetry: input.sourceRetry)
            self.mp4Edit = mp4Edit; self.mp4Sequence = mp4Sequence
            self.indexedStart = indexedStart; self.adtsStart = adtsStart; self.flacStart = flacStart
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
        func makeCursor() -> Cursor {
            condition.lock(); defer { condition.unlock() }
            activeReaders += 1
            return Cursor()
        }
        func configuration(_ cursor: Cursor) throws -> NativeAudioStreamParser.Configuration {
            condition.lock(); defer { condition.unlock() }
            while config == nil && error == nil && !cancelled && !cursor.cancelled && !ended { condition.wait() }
            try validate(cursor)
            guard let config else { throw NativeAudioStreamParser.Failure.invalidFormat }
            return config
        }
        func next(_ cursor: Cursor) throws -> NativeAudioStreamParser.Batch? {
            condition.lock(); defer { condition.unlock() }
            guard !consumer else { throw FFmpegPCMDecoder.Failure.concurrentRead }
            while queue.unreadCount == 0 && error == nil && !ended && !cancelled && !cursor.cancelled {
                if retry?.requiresDeferredRestart == true || retry?.committedError != nil { return nil }
                if let retry, !retry.snapshot.presentationOwned, let error = retry.currentError, input?.isWaitingForData == true { throw error }
                consumer = true; publish(); condition.wait(); consumer = false; publish()
            }
            try validate(cursor)
            guard let first = queue.next()?.packet else { return nil }
            if first.index + 1 < first.count {
                for i in (first.index + 1)..<first.count {
                    guard queue.next()?.packet.index == i else { throw NativeAudioStreamParser.Failure.invalidPacket }
                }
            }
            if waiting { checkBudget = true; condition.broadcast() }
            var batch = first.batch
            if first.index > 0 {
                let offset = batch.descriptions?[first.index].mStartOffset
                    ?? Int64(first.index) * Int64(config!.basic.mBytesPerPacket)
                guard offset >= 0, offset < batch.bytes.count else { throw NativeAudioStreamParser.Failure.invalidPacket }
                batch = .init(bytes: Data(batch.bytes.dropFirst(Int(offset))), packetCount: batch.packetCount - UInt32(first.index),
                    descriptions: batch.descriptions.map { Array($0.dropFirst(first.index)).map { value in
                        var value = value; value.mStartOffset -= offset; return value
                    } }, firstFrame: first.firstFrame,
                    rollDistances: batch.rollDistances.map { Array($0.dropFirst(first.index)) },
                    sourceTimes: batch.sourceTimes.map { Array($0.dropFirst(first.index)) },
                    segment: batch.segment, configuration: batch.configuration)
            } else { batch.firstFrame = first.firstFrame }
            return batch
        }
        func seek(to target: Int64) -> Bool {
            condition.lock(); defer { condition.unlock() }
            guard target >= 0, !cancelled, error == nil, activeReaders == 0, !consumer,
                  queue.seek(to: target, allowTimeBeyondBuffer: ended),
                  let selected = queue.nextSample?.packet else { return false }
            let distance: Int64
            if selected.firstFrame == 0 { distance = 0 }
            else if let roll = selected.rollDistance { distance = roll }
            else { return false }
            let start = queue.readIndex - distance
            guard start >= queue.firstIndex, queue.seek(toSampleIndex: start) else { return false }
            position = target; checkBudget = true; publish(); condition.broadcast()
            return true
        }
        private func validate(_ cursor: Cursor) throws {
            if let error { throw error }
            if cancelled || cursor.cancelled { throw CancellationError() }
        }
        func cancelRead(_ cursor: Cursor) {
            condition.lock(); defer { condition.unlock() }
            guard !cursor.cancelled else { return }
            cursor.cancelled = true; activeReaders -= 1; condition.broadcast()
        }
        func updatePlayback(_ state: PCMPlaybackLoadState) throws {
            condition.lock(); defer { condition.unlock() }
            if let error { throw error }
            guard !cancelled else { throw CancellationError() }
            position = state.positionMicroseconds; speed = state.speed
            queue.retainBackBuffer(at: position); checkBudget = true
            publish(); condition.broadcast()
        }
        func snapshot() -> Snapshot {
            condition.lock(); defer { condition.unlock() }
            return Snapshot(unreadPackets: queue.unreadCount, retainedPackets: queue.retainedCount,
                parsedFrames: parsedFrames, allocatedBytes: queue.allocatedBytes, encodedBytes: queue.totalBytesWritten,
                bufferedRange: queue.firstQueuedTimestampMicroseconds.flatMap { first in
                    queue.largestQueuedTimestampMicroseconds.map { first...$0 }
                }, waitingForBudget: waiting,
                waitingConsumer: consumer, ended: ended, cancelled: cancelled, exited: exited)
        }
        func stop() {
            condition.lock()
            guard !cancelled else { condition.unlock(); return }
            cancelled = true; queue.reset(); bufferState.finish()
            let input = input
            condition.broadcast(); condition.unlock()
            input?.cancel(); failureObserver?.cancel(); retryObserver?.cancel(); sourceFailure.finish()
        }
        func waitForExit() async {
            await withCheckedContinuation { continuation in
                condition.lock()
                if exited { condition.unlock(); continuation.resume() }
                else { waiters.append(continuation); condition.unlock() }
            }
        }
        private func fail(_ failure: any Error) {
            condition.lock()
            guard error == nil && !cancelled else { condition.unlock(); return }
            if retry?.committedError != nil { condition.broadcast(); condition.unlock(); return }
            error = failure; queue.reset(); bufferState.finish()
            let input = input
            condition.broadcast(); condition.unlock()
            input?.cancel(); retryObserver?.cancel(); sourceFailure.fail(failure)
        }
        private func retryChanged() {
            condition.lock(); defer { condition.unlock() }
            guard !cancelled && error == nil else { return }
            publish(); bufferState.notifySourceRetryChange(); condition.broadcast()
        }
        private func publish() {
            bufferState.update(.init(bufferedThroughMicroseconds: queue.largestQueuedTimestampMicroseconds,
                allocatedBytes: queue.allocatedBytes, targetBytes: targetBytes, isLoading: !waiting && !ended,
                isFinalBuffered: ended, isWaitingForSamples: consumer,
                isWaitingForSource: consumer && input?.isWaitingForData == true,
                isUsable: !cancelled && error == nil, durationMicroseconds: duration, sourceSeekable: timeline.seekable))
        }
        private func run() {
            do { try produce() } catch { fail(error) }
            condition.lock()
            exited = true; waiting = false; input = nil
            let waiters = waiters; self.waiters.removeAll()
            condition.unlock()
            for waiter in waiters { waiter.resume() }
        }
        private func produce() throws {
            guard let input = condition.withLock({ self.input }) else { throw CancellationError() }
            if let mp4Sequence {
                try produceSequence(input: input, edits: mp4Sequence, start: indexedStart ?? .zero)
                return
            }
            if let indexedStart {
                // Native file frame-to-packet lookup rejects variable-block
                // FLAC. The validated source map supplies the containing frame;
                // the decoder's exact/whole-buffer admission remains unchanged.
                if format == .flac, timeline.flacByteIndex != nil { try produceFLAC(input: input, start: indexedStart) }
                else { try produceIndexed(input: input, start: indexedStart) }
                return
            }
            if let flacStart { try produceFLAC(input: input, start: flacStart); return }
            var original: NativeAudioStreamParser.Configuration?
            if let adtsStart {
                guard format == .adts, adtsStart.bytePosition >= 0, adtsStart.time.isNumeric,
                      adtsStart.time.epoch == 0, adtsStart.time >= .zero else { throw NativeAudioStreamParser.Failure.invalidPacket }
                // Every presentation keeps the stream's first format,
                // so a seek first learns it from the stream's own start: a bounded read
                // there, before the seek byte, in the same input and coordinates.
                let first = try emptyADTSConfiguration(input: input)
                original = first
                input.prepareForIndexedSeek(to: adtsStart.bytePosition)
                timestampOffset = CMTimeConvertScale(adtsStart.time, timescale: 1_000_000, method: .roundTowardZero).value
                condition.withLock {
                    position = timestampOffset; nextFrameTime = timestampOffset
                    config = first; publish(); condition.broadcast()
                }
            }
            var parser = try NativeAudioStreamParser()
            defer { parser.close() }
            // Starts at the first parsed byte: the file's start or the synchronized frame.
            var scanner = format == .adts && adtsStart == nil ? ADTSSegmentScanner(start: 0) : nil
            var offset = adtsStart?.bytePosition ?? 0, checkOffset = adtsStart?.bytePosition ?? 0, extracted: Int64 = 0
            var wavePending = Data(), syncPending = Data()
            var needsSync = adtsStart != nil
            var choseExactInterval = false
            while true {
                guard try awaitLoadBudget() else { return }
                let bytes = try input.read(at: offset, maximumCount: 4096)
                guard bytes.count <= 4096, offset <= Int64.max - Int64(bytes.count) else { throw NativeAudioStreamParser.Failure.invalidCapacity }
                offset += Int64(bytes.count)
                let eof = bytes.isEmpty
                var parsingBytes = bytes
                if needsSync {
                    syncPending.append(bytes)
                    if try synchronizeADTS(&syncPending, eof: eof) {
                        parsingBytes = syncPending; syncPending.removeAll(); needsSync = false
                        scanner = ADTSSegmentScanner(start: 0)
                    } else {
                        if eof {
                            // No complete frame remains after the source byte
                            // point. Preserve native format discovery without
                            // inventing audio or turning ordinary EOF into error.
                            let configuration = try original ?? emptyADTSConfiguration(input: input)
                            _ = try enqueue([], configuration: configuration, eof: true,
                                extracted: &extracted, checkLoad: false)
                            return
                        }
                        continue
                    }
                }
                var batches: [NativeAudioStreamParser.Batch] = []
                if var active = scanner {
                    // A new configuration ends this parser and starts the next at
                    // the same byte; nothing is read again or skipped.
                    let pieces = active.consume(parsingBytes, eof: eof)
                    scanner = active
                    for piece in pieces {
                        switch piece {
                        case .bytes(let data): batches += try parser.append(data)
                        case .segment:
                            batches += try parser.finish()
                            guard try enqueue(batches, configuration: parser.configuration, eof: false,
                                extracted: &extracted, checkLoad: false) else { return }
                            batches.removeAll()
                            parser.close(); parser = try NativeAudioStreamParser()
                            condition.withLock {
                                segment += 1; segmentConfig = nil; segmentTime = nextFrameTime; segmentPackets = 0
                            }
                        }
                    }
                } else { batches = try parser.append(parsingBytes) }
                if eof { batches += try parser.finish() }
                // Some MP4 files without an edit list expose a native valid
                // interval through AudioFile but omit it from AudioFileStream.
                // Exact readers must retain that interval before admitting any
                // audio. Source whole-buffer mode keeps its separate trim policy.
                if exactMP4Interval, !choseExactInterval, let configuration = parser.configuration {
                    choseExactInterval = true
                    if configuration.validFrames == nil, input.length != nil {
                        try produceIndexed(input: input, start: .zero)
                        return
                    }
                }
                if let config = parser.configuration, format == .wav {
                    let basic = config.basic
                    guard basic.mFramesPerPacket == 1, basic.mBytesPerPacket > 0 else { throw NativeAudioStreamParser.Failure.invalidFormat }
                    let block = Int(basic.mBytesPerPacket)
                    let target = min(NativeAudioStreamParser.maximumBatchBytes / block, max(1, Int(basic.mSampleRate) / 10)) * block
                    for batch in batches { wavePending.append(batch.bytes) }
                    batches.removeAll()
                    while wavePending.count >= target || (eof && !wavePending.isEmpty) {
                        let size = min(target, wavePending.count)
                        guard size % block == 0 else { throw NativeAudioStreamParser.Failure.invalidPacket }
                        batches.append(.init(bytes: Data(wavePending.prefix(size)), packetCount: UInt32(size / block), descriptions: nil))
                        wavePending.removeFirst(size)
                    }
                }
                let checkLoad = offset > checkOffset + 1_048_576
                if checkLoad { checkOffset = offset }
                guard try enqueue(batches, configuration: parser.configuration, eof: eof,
                    extracted: &extracted, checkLoad: checkLoad) else { return }
                if eof { return }
            }
        }
        /// ADTS synchronization follows Media3 AdtsReader (Apache-2.0); see
        /// Licenses/Android-Native-Audio-Metadata.txt.
        /// The CBR byte point can fall inside an ADTS frame. Native parsing
        /// starts only after synchronization to this stream's version/rate, or
        /// to a differently encoded segment's frame confirmed by two more headers.
        /// At most two 8191-byte ADTS frames plus the next header are retained.
        private func synchronizeADTS(_ bytes: inout Data, eof: Bool) throws -> Bool {
            guard let identity = timeline.adtsSyncFormat else { throw NativeAudioStreamParser.Failure.invalidFormat }
            var offset = 0
            func matches(_ at: Int) -> Bool {
                bytes[at] == 0xff && bytes[at + 1] & 0xf6 == 0xf0 &&
                    UInt16(bytes[at + 1] & 8) << 8 | UInt16(bytes[at + 2] & 0x3c) == identity
            }
            while offset + 7 <= bytes.count {
                if !matches(offset) {
                    // A differently encoded segment (another rate) is not skipped:
                    // its frame counts when the next two headers repeat its whole
                    // configuration, stricter than the stream-format rule below.
                    guard let frame = ADTSSegmentScanner.header(bytes, at: offset) else { offset += 1; continue }
                    let next = offset + frame.length
                    let second = ADTSSegmentScanner.header(bytes, at: next)
                    let third = second.flatMap { ADTSSegmentScanner.header(bytes, at: next + $0.length) }
                    if third == nil, !eof, next + (second?.length ?? 0) + 7 > bytes.count {
                        bytes = Data(bytes.dropFirst(offset)); return false
                    }
                    if next > bytes.count { bytes.removeAll(); return false }
                    let agrees = [second, third].allSatisfy { $0.map { $0.key == frame.key } ?? eof }
                    guard agrees, second != nil || next == bytes.count else { offset += 1; continue }
                    bytes = Data(bytes.dropFirst(offset)); return true
                }
                let size = Int(bytes[offset + 3] & 3) << 11 | Int(bytes[offset + 4]) << 3 | Int(bytes[offset + 5] >> 5)
                let headerSize = bytes[offset + 1] & 1 == 0 ? 9 : 7
                if size < headerSize { offset += 1; continue }
                let next = offset + size
                if next + 3 > bytes.count && !eof {
                    bytes = Data(bytes.dropFirst(offset)); return false
                }
                if next > bytes.count {
                    // The original extractor ends without emitting metadata for
                    // an incomplete terminal frame. Reaching EOF here leaves no
                    // complete sample; input failures still propagate from read.
                    bytes.removeAll(); return false
                }
                if next + 3 <= bytes.count && !matches(next) && bytes[next..<(next + 3)] != Data("ID3".utf8) {
                    offset += 1; continue
                }
                bytes = Data(bytes.dropFirst(offset)); return true
            }
            if eof { bytes.removeAll(); return false }
            bytes = Data(bytes.dropFirst(offset)); return false
        }

        /// The decoded format two configurations produce is the same.
        static func sameFormat(_ a: NativeAudioStreamParser.Configuration, _ b: NativeAudioStreamParser.Configuration) -> Bool {
            a.basic.mFormatID == b.basic.mFormatID && a.basic.mSampleRate == b.basic.mSampleRate
                && a.basic.mChannelsPerFrame == b.basic.mChannelsPerFrame && a.basic.mFramesPerPacket == b.basic.mFramesPerPacket
        }
        /// The stream's own first configuration, from at most four maximum-sized frames at its start.
        private func emptyADTSConfiguration(input: any MediaByteInput) throws -> NativeAudioStreamParser.Configuration {
            guard let index = timeline.adtsByteIndex else { throw NativeAudioStreamParser.Failure.invalidFormat }
            let prefix = try NativeAudioStreamParser()
            defer { prefix.close() }
            let start = index.points(at: 0).first.bytePosition
            input.prepareForIndexedSeek(to: start)
            var offset = start, readCount = 0
            // ADTS frames are at most8191 bytes. This bounds native format
            // discovery to four maximum-sized frames; parsed audio is discarded.
            while readCount < 32768 {
                guard try awaitLoadBudget() else { throw CancellationError() }
                try input.checkFailure()
                let bytes = try input.read(at: offset, maximumCount: min(4096, 32768 - readCount))
                guard bytes.count <= min(4096, 32768 - readCount), offset <= Int64.max - Int64(bytes.count) else {
                    throw NativeAudioStreamParser.Failure.invalidCapacity
                }
                _ = try prefix.append(bytes)
                if bytes.isEmpty { _ = try prefix.finish() }
                if let configuration = prefix.configuration { return configuration }
                if bytes.isEmpty { break }
                offset += Int64(bytes.count); readCount += bytes.count
            }
            throw NativeAudioStreamParser.Failure.invalidFormat
        }

        private func awaitLoadBudget() throws -> Bool {
            condition.lock()
            while checkBudget && !cancelled && error == nil {
                do {
                    if try queue.shouldContinueLoadingPreparedAudio(at: position, speed: speed, targetBytes: targetBytes) {
                        checkBudget = false; waiting = false; publish(); break
                    }
                } catch { condition.unlock(); throw error }
                waiting = true; publish(); condition.wait(); waiting = false
            }
            let usable = !cancelled && error == nil
            condition.unlock()
            return usable
        }
        private func produceFLAC(input: any MediaByteInput, start: CMTime) throws {
            guard format == .flac, let index = timeline.flacByteIndex else { throw NativeAudioStreamParser.Failure.invalidFormat }
            let target = CMTimeConvertScale(start, timescale: 1_000_000, method: .roundTowardZero)
            guard target.isNumeric, target.value >= 0 else { throw NativePCMDecoder.Failure.invalidStart }
            let point = try index.position(at: target.value, input: input)
            let parser = try NativeAudioStreamParser()
            defer { parser.close() }
            _ = try parser.append(index.nativePrefix)
            input.prepareForIndexedSeek(to: point.byte)
            condition.withLock { parsedFrames = point.sample; position = target.value }
            var offset = point.byte, checkOffset = point.byte, extracted: Int64 = 0
            while true {
                guard try awaitLoadBudget() else { return }
                let bytes = try input.read(at: offset, maximumCount: 4096)
                guard bytes.count <= 4096, offset <= Int64.max - Int64(bytes.count) else { throw NativeAudioStreamParser.Failure.invalidCapacity }
                offset += Int64(bytes.count)
                let eof = bytes.isEmpty
                var batches = try eof ? parser.finish() : parser.append(bytes)
                // FLAC predictors/warmup are contained in each complete frame.
                // A retained frame needs stream info, not an earlier audio frame.
                for i in batches.indices { batches[i].rollDistances = Array(repeating: 0, count: Int(batches[i].packetCount)) }
                let checkLoad = offset > checkOffset + 1_048_576
                if checkLoad { checkOffset = offset }
                guard try enqueue(batches, configuration: parser.configuration, eof: eof,
                    extracted: &extracted, checkLoad: checkLoad) else { return }
                if eof { return }
            }
        }

        private func rawTime(edit: NativeMP4SourceTimeline.AudioEdit, packet: Int64) throws -> CMTime {
            guard let units = Int64(exactly: Int128(packet) * Int128(edit.packetDuration)) else { throw NativeAudioStreamParser.Failure.invalidFormat }
            return CMTime(value: units, timescale: Int32(edit.mediaScale))
        }
        private func produceSequence(input: any MediaByteInput, edits: [NativeMP4SourceTimeline.AudioEdit], start: CMTime) throws {
            guard let last = edits.last else { throw NativeAudioStreamParser.Failure.invalidFormat }
            let target = CMTimeConvertScale(start, timescale: 1_000_000, method: .roundTowardZero).value
            let total = last.outputPacketOffset + Int64(last.packets.count)
            func segment(at packet: Int64) -> Int {
                edits.lastIndex(where: { $0.outputPacketOffset <= packet }) ?? 0
            }
            // Search the composed sample table, not the unedited file clock.
            // Keeping ordinals compact avoids allocating one entry per packet.
            func time(at packet: Int64) throws -> Int64 {
                let edit = edits[segment(at: packet)]
                return try edit.time(at: edit.packets.lowerBound + packet - edit.outputPacketOffset)
            }
            // Match Util.binarySearchFloor's Arrays.binarySearch and first
            // equal timestamp. An upper-bound search is not interchangeable
            // when edit preroll produces a small overlap between segments.
            var lower: Int64 = 0, upper = total - 1, found: Int64?
            while lower <= upper {
                let middle = lower + (upper - lower) / 2
                let value = try time(at: middle)
                if value < target { lower = middle + 1 }
                else if value > target { upper = middle - 1 }
                else { found = middle; break }
            }
            var selected = max(0, found ?? upper)
            if found != nil {
                while selected > 0 {
                    guard try time(at: selected - 1) == target else { break }
                    selected -= 1
                }
            }
            let firstSegment = segment(at: selected)
            var extracted: Int64 = 0
            for index in firstSegment..<edits.count {
                let edit = edits[index]
                let selectedRaw = index == firstSegment ? edit.packets.lowerBound + selected - edit.outputPacketOffset : edit.packets.lowerBound
                let rawStart = try rawTime(edit: edit, packet: selectedRaw)
                let reader = try NativeAudioPacketFileReader(input: input, format: .mp4, start: .zero, rawStart: rawStart)
                let sourceConfig = try sourceConfiguration(reader.configuration)
                let frames = Int64(sourceConfig.basic.mFramesPerPacket)
                condition.lock()
                if config == nil {
                    config = sourceConfig
                    parsedFrames = (edit.outputPacketOffset + max(edit.packets.lowerBound, reader.firstPacket) - edit.packets.lowerBound) * frames
                    extracted = parsedFrames / frames
                    position = target; publish(); condition.broadcast()
                }
                condition.unlock()
                while true {
                    guard try awaitLoadBudget() else { return }
                    guard let raw = try reader.next() else { throw NativeMP3PCMDecoder.Failure.incompleteStream }
                    if let selected = try sourceBatch(raw, configuration: sourceConfig, edit: edit) {
                        let firstRaw = selected.firstFrame / frames
                        let times = try (0..<Int64(selected.packetCount)).map { try edit.time(at: firstRaw + $0) }
                        let batch = NativeAudioStreamParser.Batch(bytes: selected.bytes, packetCount: selected.packetCount,
                            descriptions: selected.descriptions,
                            firstFrame: (edit.outputPacketOffset + firstRaw - edit.packets.lowerBound) * frames,
                            rollDistances: selected.rollDistances, sourceTimes: times)
                        guard try enqueue([batch], configuration: sourceConfig, eof: false, extracted: &extracted, checkLoad: true) else { return }
                    }
                    if raw.firstFrame / frames + Int64(raw.packetCount) >= edit.packets.upperBound { break }
                }
            }
            _ = try enqueue([], configuration: nil, eof: true, extracted: &extracted, checkLoad: true)
        }

        private func produceIndexed(input: any MediaByteInput, start: CMTime) throws {
            let rawStart = try mp4Edit.map { edit in
                min(start + CMTime(value: edit.mediaStart, timescale: Int32(edit.mediaScale)),
                    try rawTime(edit: edit, packet: max(edit.packets.lowerBound, edit.packets.upperBound - 1)))
            }
            let reader = try NativeAudioPacketFileReader(input: input, format: format, start: start, rawStart: rawStart)
            let sourceConfig = try sourceConfiguration(reader.configuration)
            condition.lock()
            config = sourceConfig; parsedFrames = reader.firstFrame
            position = CMTimeConvertScale(start, timescale: 1_000_000, method: .roundTowardZero).value
            publish(); condition.broadcast(); condition.unlock()
            var extracted = mp4Edit.map { max(0, reader.firstPacket - $0.packets.lowerBound) } ?? reader.firstSampleOrdinal
            var checkOffset = reader.bytesRead
            while true {
                guard try awaitLoadBudget() else { return }
                let batch = try reader.next(), offset = reader.bytesRead
                let checkLoad = offset > checkOffset + 1_048_576
                if checkLoad { checkOffset = offset }
                guard try enqueue(batch.map { [$0] } ?? [], configuration: reader.configuration, eof: batch == nil,
                    extracted: &extracted, checkLoad: checkLoad) else { return }
                if batch == nil { return }
            }
        }
        private func sourceConfiguration(_ value: NativeAudioStreamParser.Configuration) throws -> NativeAudioStreamParser.Configuration {
            guard let edit = mp4Edit ?? mp4Sequence?.first else { return value }
            let basic = value.basic
            guard [kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2].contains(basic.mFormatID),
                  basic.mFramesPerPacket > 0,
                  Int128(basic.mFramesPerPacket) * Int128(edit.mediaScale) == Int128(edit.packetDuration) * Int128(Int64(basic.mSampleRate)),
                  let endPackets = mp4Sequence.map({ $0.reduce(Int128(0)) { $0 + Int128($1.packets.count) } }) ?? Optional(Int128(edit.packets.upperBound)),
                  let end = Int64(exactly: endPackets * Int128(basic.mFramesPerPacket)) else {
                throw NativeAudioStreamParser.Failure.invalidFormat
            }
            return .init(basic: basic, cookie: value.cookie, primingFrames: 0, validFrames: end,
                maximumPacketFrames: value.maximumPacketFrames, channelLayout: value.channelLayout)
        }
        private func sourceBatch(_ batch: NativeAudioStreamParser.Batch,
                                 configuration: NativeAudioStreamParser.Configuration, edit explicitEdit: NativeMP4SourceTimeline.AudioEdit? = nil) throws -> NativeAudioStreamParser.Batch? {
            guard let edit = explicitEdit ?? mp4Edit else { return batch }
            let frames = Int64(configuration.basic.mFramesPerPacket)
            guard batch.firstFrame >= 0, batch.firstFrame % frames == 0 else { throw NativeAudioStreamParser.Failure.invalidPacket }
            let ordinal = batch.firstFrame / frames
            let lower = max(0, edit.packets.lowerBound - ordinal)
            let upper = min(Int64(batch.packetCount), edit.packets.upperBound - ordinal)
            guard lower < upper else { return nil }
            guard let descriptions = batch.descriptions, descriptions.count == Int(batch.packetCount) else {
                throw NativeAudioStreamParser.Failure.invalidPacket
            }
            let selected = descriptions[Int(lower)..<Int(upper)]
            guard selected.allSatisfy({ $0.mVariableFramesInPacket == 0 || $0.mVariableFramesInPacket == frames }),
                  let first = selected.first, let last = selected.last else { throw NativeAudioStreamParser.Failure.invalidPacket }
            let end = last.mStartOffset + Int64(last.mDataByteSize)
            guard first.mStartOffset >= 0, end <= batch.bytes.count else { throw NativeAudioStreamParser.Failure.invalidPacket }
            return .init(bytes: batch.bytes.subdata(in: Int(first.mStartOffset)..<Int(end)), packetCount: UInt32(upper - lower),
                descriptions: selected.map { item in var item = item; item.mStartOffset -= first.mStartOffset; return item },
                firstFrame: batch.firstFrame + lower * frames,
                rollDistances: batch.rollDistances.map { Array($0[Int(lower)..<Int(upper)]) })
        }

        private func enqueue(_ batches: [NativeAudioStreamParser.Batch], configuration: NativeAudioStreamParser.Configuration?,
                             eof: Bool, extracted: inout Int64, checkLoad: Bool) throws -> Bool {
            condition.lock()
            guard !cancelled && error == nil && retry?.committedError == nil else { condition.unlock(); return false }
            var added = 0
            do {
                if config == nil { config = try configuration.map(sourceConfiguration) }
                if let configuration, let adtsStart, !adtsPositioned, let config {
                    adtsPositioned = true
                    if Self.sameFormat(configuration, config) {
                        parsedFrames = CMTimeConvertScale(adtsStart.time, timescale: Int32(configuration.basic.mSampleRate), method: .roundTowardZero).value
                    } else {
                        // Landed in a differently encoded segment: its own configuration,
                        // converted to the stream's first format by the decoder.
                        segment = 1; segmentConfig = nil; segmentTime = timestampOffset; segmentPackets = 0
                    }
                }
                if segment > 0, segmentConfig == nil, let configuration {
                    // The segment's first frame starts where the previous one ended.
                    segmentConfig = configuration
                    parsedFrames = CMTimeConvertScale(CMTime(value: segmentTime, timescale: 1_000_000),
                        timescale: Int32(configuration.basic.mSampleRate), method: .roundTowardZero).value
                }
                if let config = segment > 0 ? segmentConfig : config {
                    for var original in batches {
                        if segment > 0 { original.segment = segment; original.configuration = config }
                        guard let batch = try sourceBatch(original, configuration: config) else { continue }
                        if mp4Edit != nil || mp4Sequence != nil { parsedFrames = batch.firstFrame }
                        let count = format == .wav ? 1 : Int(batch.packetCount)
                        guard count > 0 else { throw NativeAudioStreamParser.Failure.invalidPacket }
                        for i in 0..<count {
                            let description = batch.descriptions?[i]
                            let frames = format == .wav ? Int64(batch.packetCount) : Int64(description?.mVariableFramesInPacket ?? 0) == 0
                                ? Int64(config.basic.mFramesPerPacket) : Int64(description!.mVariableFramesInPacket)
                            let size = format == .wav ? batch.bytes.count : Int(description?.mDataByteSize ?? config.basic.mBytesPerPacket)
                            guard frames > 0, size > 0, parsedFrames <= Int64.max - frames, extracted < Int64.max else { throw NativeAudioStreamParser.Failure.invalidPacket }
                            // ADTS advances by its integer per-frame duration; it does
                            // not recompute a rational cumulative timestamp.
                            let rate = Int128(Int64(config.basic.mSampleRate))
                            var time = Int64(clamping: format == .adts
                                ? segment > 0 ? Int128(segmentTime) + Int128(segmentPackets) * (Int128(frames) * 1_000_000 / rate)
                                    : Int128(timestampOffset) + Int128(extracted) * (Int128(frames) * 1_000_000 / rate)
                                : Int128(parsedFrames) * 1_000_000 / rate)
                            if format == .adts {
                                nextFrameTime = Int64(clamping: Int128(time) + Int128(frames) * 1_000_000 / rate)
                                if segment > 0 { segmentPackets += 1 }
                            }
                            if let edit = mp4Edit {
                                time = Int64(clamping: (Int128(parsedFrames) * Int128(edit.mediaScale) - Int128(edit.mediaStart) * rate) * 1_000_000 / (rate * Int128(edit.mediaScale)))
                            }
                            if let times = batch.sourceTimes { time = times[i] }
                            try queue.append(Packet(batch: batch, index: i, count: count, firstFrame: parsedFrames,
                                rollDistance: format == .wav ? 0 : batch.rollDistances?[i]), encodedByteCount: size, timestampMicroseconds: time)
                            parsedFrames += frames; extracted += 1; added += 1
                        }
                    }
                }
            } catch { condition.unlock(); throw error }
            retry?.recordSamples(added, durationKnown: duration != nil, extractedThrough: extracted)
            let reachedEditEnd = mp4Edit != nil && config.map { parsedFrames >= ($0.validFrames ?? .max) } == true
            if eof || reachedEditEnd {
                ended = true
                if duration == nil { duration = queue.largestQueuedTimestampMicroseconds.map { Int64(clamping: Int128($0) + 10_000) } ?? 0 }
            }
            if checkLoad { checkBudget = true }
            publish(); condition.broadcast(); condition.unlock()
            return !reachedEditEnd
        }
    }
}
