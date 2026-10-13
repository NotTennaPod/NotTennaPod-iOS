import Foundation

/// Encoded samples retained independently of the decoder and PCM output queue.
/// Confine this value to one owner. Packet storage may use native references; allocation
/// accounting follows the pinned sample queue's shared 64 KiB blocks, not packet count.
struct EncodedAudioQueue<Packet: Sendable>: Sendable {
    enum Failure: Error { case invalidSize, positionOverflow }
    enum SeekMode { case previousKeyframe, firstSampleAtOrAfter }
    struct Sample: Sendable {
        let packet: Packet
        let timestampMicroseconds: Int64
        let isKeyframe: Bool
        let size: Int64
        let byteOffset: Int64
    }
    private var samples: [Sample?] = []
    private var head = 0
    private var read = 0
    private var firstAllocationOffset: Int64 = 0
    private(set) var totalBytesWritten: Int64 = 0
    private(set) var largestQueuedTimestampMicroseconds: Int64?
    private(set) var firstIndex: Int64 = 0
    private(set) var startTimeMicroseconds: Int64 = .min
    private var loadControl = PlaybackLoadControl()
    static var allocationLength: Int64 { 65_536 }
    var retainedCount: Int { samples.count - head }
    var firstQueuedTimestampMicroseconds: Int64? { head < samples.count ? samples[head]?.timestampMicroseconds : nil }
    var unreadCount: Int { samples.count - read }
    var readPosition: Int { read - head }
    var readIndex: Int64 { firstIndex + Int64(readPosition) }
    var writeIndex: Int64 { firstIndex + Int64(retainedCount) }
    var allocatedBytes: Int64 {
        let remainder = totalBytesWritten % Self.allocationLength
        let end = totalBytesWritten - remainder + (remainder == 0 ? 0 : Self.allocationLength)
        return end - firstAllocationOffset
    }

    mutating func append(_ packet: Packet, encodedByteCount: Int, timestampMicroseconds: Int64,
                         isKeyframe: Bool = true) throws {
        guard encodedByteCount >= 0 else { throw Failure.invalidSize }
        let end = totalBytesWritten.addingReportingOverflow(Int64(encodedByteCount))
        guard !end.overflow, end.partialValue <= Int64.max - Self.allocationLength else { throw Failure.positionOverflow }
        samples.append(Sample(packet: packet, timestampMicroseconds: timestampMicroseconds,
            isKeyframe: isKeyframe, size: Int64(encodedByteCount), byteOffset: totalBytesWritten))
        totalBytesWritten = end.partialValue
        largestQueuedTimestampMicroseconds = max(largestQueuedTimestampMicroseconds ?? .min, timestampMicroseconds)
    }

    mutating func next() -> Sample? {
        guard read < samples.count else { return nil }
        defer { read += 1 }
        return samples[read]
    }
    var nextSample: Sample? { read < samples.count ? samples[read] : nil }

    /// SampleQueue rewinds even when a seek fails. Keep admission time unchanged
    /// on failure so the period owner can decide whether it must reset loading.
    mutating func seek(to timestamp: Int64, allowTimeBeyondBuffer: Bool,
                       mode: SeekMode = .previousKeyframe, readEndTimeMicroseconds: Int64? = nil) -> Bool {
        read = head
        guard head < samples.count, let first = samples[head],
              timestamp >= first.timestampMicroseconds, let largestQueuedTimestampMicroseconds else { return false }
        let maximum = min(largestQueuedTimestampMicroseconds, readEndTimeMicroseconds ?? .max)
        guard timestamp <= maximum || allowTimeBeyondBuffer else { return false }
        var selected: Int?
        switch mode {
        case .previousKeyframe:
            for index in head..<samples.count {
                guard let sample = samples[index], sample.timestampMicroseconds <= timestamp else { break }
                if sample.isKeyframe {
                    selected = index
                    if sample.timestampMicroseconds == timestamp { break }
                }
            }
        case .firstSampleAtOrAfter:
            selected = (head..<samples.count).first { samples[$0]!.timestampMicroseconds >= timestamp }
            if selected == nil && allowTimeBeyondBuffer { selected = samples.count }
        }
        guard let selected else { return false }
        read = selected
        startTimeMicroseconds = timestamp
        return true
    }

    mutating func seek(toSampleIndex index: Int64, readEndSampleIndex: Int64? = nil) -> Bool {
        read = head
        guard index >= firstIndex, index <= writeIndex,
              readEndSampleIndex.map({ index < $0 }) ?? true else { return false }
        read += Int(index - firstIndex)
        startTimeMicroseconds = .min
        return true
    }

    /// Retain the selected boundary sample, including the first exact timestamp match.
    /// The read-position guard prevents trimming unread audio when playback lags decoding.
    mutating func discard(beforeOrAt timestamp: Int64, toKeyframe: Bool = true, stopAtReadPosition: Bool = true) {
        guard head < samples.count, let first = samples[head], timestamp >= first.timestampMicroseconds else { return }
        let end = stopAtReadPosition && read < samples.count ? read + 1 : samples.count
        var boundary: Int?
        for index in head..<end {
            guard let sample = samples[index], sample.timestampMicroseconds <= timestamp else { break }
            if !toKeyframe || sample.isKeyframe {
                boundary = index
                if sample.timestampMicroseconds == timestamp { break }
            }
        }
        if let boundary { discard(count: boundary - head) }
    }

    mutating func discardConsumed() { discard(count: read - head) }

    mutating func retainBackBuffer(at playbackMicroseconds: Int64) {
        let value = Int128(playbackMicroseconds) - Int128(PlaybackLoadControl.backBufferMicroseconds)
        discard(beforeOrAt: Int64(clamping: value), toKeyframe: PlaybackLoadControl.retainBackBufferFromKeyframe)
    }

    func bufferedMicroseconds(at playbackMicroseconds: Int64) -> Int64 {
        guard let largestQueuedTimestampMicroseconds else { return 0 }
        return Int64(clamping: max(0, Int128(largestQueuedTimestampMicroseconds) - Int128(playbackMicroseconds)))
    }

    mutating func shouldContinueLoading(at playbackMicroseconds: Int64, speed: Float,
                                        targetBytes: Int64 = PlaybackLoadControl.audioTargetBytes) throws -> Bool {
        try loadControl.shouldContinueLoading(bufferedMicroseconds: bufferedMicroseconds(at: playbackMicroseconds),
            speed: speed, allocatedBytes: allocatedBytes, targetBytes: targetBytes)
    }

    func shouldStartPlayback(at playbackMicroseconds: Int64, speed: Float, rebuffering: Bool,
                             targetLiveOffsetMicroseconds: Int64? = nil) throws -> Bool {
        try loadControl.shouldStartPlayback(bufferedMicroseconds: bufferedMicroseconds(at: playbackMicroseconds),
            speed: speed, rebuffering: rebuffering, allocatedBytes: allocatedBytes,
            targetLiveOffsetMicroseconds: targetLiveOffsetMicroseconds)
    }

    /// ExoPlayerImplInternal clears retained back buffer and retries the load decision
    /// when a prepared audio period has less than 500 ms buffered but loading stopped.
    mutating func shouldContinueLoadingPreparedAudio(at position: Int64, speed: Float,
                                                     targetBytes: Int64 = PlaybackLoadControl.audioTargetBytes) throws -> Bool {
        if try shouldContinueLoading(at: position, speed: speed, targetBytes: targetBytes) { return true }
        guard bufferedMicroseconds(at: position) < 500_000 else { return false }
        discard(beforeOrAt: position, toKeyframe: false, stopAtReadPosition: true)
        return try shouldContinueLoading(at: position, speed: speed, targetBytes: targetBytes)
    }

    mutating func reset() { self = Self() }

    private mutating func discard(count: Int) {
        guard count > 0 else { return }
        let boundary = head + count
        let byteOffset = boundary == samples.count ? totalBytesWritten : samples[boundary]!.byteOffset
        for index in head..<boundary { samples[index] = nil }
        head = boundary
        firstIndex += Int64(count)
        read = max(read, head)
        firstAllocationOffset = byteOffset - byteOffset % Self.allocationLength
        if head >= 1024 && head >= samples.count / 2 {
            samples.removeFirst(head)
            read -= head
            head = 0
        }
    }
}
