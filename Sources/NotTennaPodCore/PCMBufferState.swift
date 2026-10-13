import Foundation

/// Encoded loading state, independent of decoder pulls and queued PCM capacity.
final class PCMBufferState: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let bufferedThroughMicroseconds: Int64?
        let allocatedBytes: Int64
        let targetBytes: Int64
        let isLoading: Bool
        let isFinalBuffered: Bool
        var isWaitingForSamples = false
        var isWaitingForSource = false
        var isUsable = true
        var durationMicroseconds: Int64? = nil
        var sourceSeekable: Bool? = nil

        static let initial = Snapshot(bufferedThroughMicroseconds: nil, allocatedBytes: 0,
            targetBytes: PlaybackLoadControl.audioTargetBytes, isLoading: true, isFinalBuffered: false)
        static let retired = Snapshot(bufferedThroughMicroseconds: nil, allocatedBytes: 0,
            targetBytes: PlaybackLoadControl.audioTargetBytes, isLoading: false, isFinalBuffered: false, isUsable: false)

        func shouldStartPlayback(rendererReadyOrEnded: Bool, positionMicroseconds: Int64,
                                 speed: Float, rebuffering: Bool) throws -> Bool {
            guard rendererReadyOrEnded, isUsable else { return false }
            // ExoPlayerImplInternal 2418–2460: ready renderers need not wait for
            // unavailable further loading or for more data in a fully buffered final period.
            if !isLoading || isFinalBuffered { return true }
            let buffered = Int64(clamping: max(0, Int128(bufferedThroughMicroseconds ?? positionMicroseconds)
                - Int128(positionMicroseconds)))
            return try PlaybackLoadControl().shouldStartPlayback(bufferedMicroseconds: buffered, speed: speed,
                rebuffering: rebuffering, allocatedBytes: allocatedBytes, targetBytes: targetBytes)
        }
    }

    let sourceRetry: PCMSourceRetry?
    private let lock = NSLock()
    private var value: Snapshot
    private var finished = false
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    init(_ value: Snapshot = .initial, sourceRetry: PCMSourceRetry? = nil) { self.value = value; self.sourceRetry = sourceRetry }
    var snapshot: Snapshot { lock.withLock { value } }
    var subscriberCount: Int { lock.withLock { subscribers.count } }

    /// Notifications carry no stale snapshot: readers always obtain the current value.
    /// Each observer has at most one pending notification, even during fast demuxing.
    func events() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in self?.remove(id) }
        let ended = lock.withLock {
            if !finished { subscribers[id] = continuation }
            return finished
        }
        if ended { continuation.finish() } else { continuation.yield(()) }
        return stream
    }

    func update(_ snapshot: Snapshot) {
        let listeners = lock.withLock { () -> [AsyncStream<Void>.Continuation] in
            guard !finished, snapshot != value else { return [] }
            value = snapshot
            return Array(subscribers.values)
        }
        for listener in listeners { listener.yield(()) }
    }

    func notifySourceRetryChange() {
        let listeners = lock.withLock { finished ? [] : Array(subscribers.values) }
        for listener in listeners { listener.yield(()) }
    }
    func finish() {
        let listeners = lock.withLock { () -> [AsyncStream<Void>.Continuation] in
            guard !finished else { return [] }
            finished = true; value = .retired
            let listeners = Array(subscribers.values); subscribers.removeAll()
            return listeners
        }
        for listener in listeners { listener.yield(()); listener.finish() }
    }
    private func remove(_ id: UUID) { lock.withLock { _ = subscribers.removeValue(forKey: id) } }
}
