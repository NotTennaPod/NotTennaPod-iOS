import Foundation

/// Recoverable source errors are separate from fatal decoder/renderer failures.
/// A presentation owner may continue consuming already decoded audio after the
/// source retry threshold; an unprepared/raw reader must still surface exhaustion.
final class PCMSourceRetry: @unchecked Sendable {
    /// The network period changed before any packets were admitted. Recreate
    /// parser/metadata state while retaining this source's retry budget.
    struct RestartUnprepared: Error {}
    typealias Sleep = @Sendable (Int64) async throws -> Void
    struct Plan: Sendable { let delayMilliseconds: Int64; let restartAtZero: Bool; var deferredUntilDrained = false }
    struct Snapshot: Sendable {
        let errorCount: Int
        let extractedSamples: Int64
        let prepared: Bool
        let durationKnown: Bool
        let presentationOwned: Bool
    }
    private let lock = NSLock()
    private var count = 0
    private var samples: Int64 = 0
    private var furthestExtractedPacket: Int64 = 0
    private var samplesAtLastFailure: Int64 = 0
    private var prepared = false, durationKnown = false
    private var pending: (any Error)?
    private var committed: (any Error)?
    private var deferred = false
    private var relayFailure: (any Error)?
    private var presentations: Set<UUID> = []
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    let sleep: Sleep
    init(sleep: @escaping Sleep = { try await Task.sleep(for: .milliseconds($0)) }) { self.sleep = sleep }
    var snapshot: Snapshot {
        lock.withLock { Snapshot(errorCount: count, extractedSamples: samples, prepared: prepared,
            durationKnown: durationKnown, presentationOwned: !presentations.isEmpty) }
    }
    var currentError: (any Error)? { lock.withLock { committed ?? pending } }
    var committedError: (any Error)? { lock.withLock { committed } }
    /// Commit only after buffered presentation drains. Until this point newly
    /// extracted samples may clear the error and continue the same decoder.
    @discardableResult func commitErrorForDrain() -> Bool {
        let listeners = lock.withLock { () -> [AsyncStream<Void>.Continuation]? in
            guard committed == nil, let pending else { return nil }
            committed = pending
            return Array(subscribers.values)
        }
        guard let listeners else { return false }
        for listener in listeners { listener.yield(()) }
        return true
    }
    var requiresDeferredRestart: Bool { lock.withLock { deferred } }
    // A loopback close can appear as clean EOF to Foundation for an unknown
    // body. Preserve the actual upstream outcome before the relay closes it.
    func recordRelayFailure(_ error: any Error) { lock.withLock { relayFailure = error } }
    func takeRelayFailure() -> (any Error)? {
        lock.withLock { let error = relayFailure; relayFailure = nil; return error }
    }
    /// A replacement parser may replay cached packets. Only previously unseen
    /// source packet ordinals establish new load progress and clear a pending error.
    func recordSamples(_ added: Int, durationKnown: Bool, extractedThrough: Int64? = nil) {
        guard added > 0 else { return }
        let listeners = lock.withLock {
            let progress: Int64
            if let extractedThrough {
                progress = max(0, extractedThrough - furthestExtractedPacket)
                furthestExtractedPacket = max(furthestExtractedPacket, extractedThrough)
            } else { progress = Int64(added) }
            samples = Int64(clamping: Int128(samples) + Int128(progress))
            prepared = true; self.durationKnown = self.durationKnown || durationKnown
            if progress > 0, committed == nil { pending = nil }
            return Array(subscribers.values)
        }
        for listener in listeners { listener.yield(()) }
    }
    func plan(for error: any Error, lengthKnown: Bool) throws -> Plan? {
        let causes = Self.causes(of: error)
        let result: (Plan?, [AsyncStream<Void>.Continuation]) = try lock.withLock {
            let next = count == Int.max ? Int.max : count + 1
            guard let delay = try PlaybackLoadRetryPolicy.retryDelayMilliseconds(errorCount: next, causes: causes) else { return (nil, []) }
            let recovery = PlaybackLoadRetryPolicy.recovery(lengthKnown: lengthKnown, durationKnown: durationKnown,
                prepared: prepared, readSuppressed: false)
            if recovery == .deferUntilSamplesExhausted {
                deferred = true; pending = nil
                return (Plan(delayMilliseconds: 0, restartAtZero: true, deferredUntilDrained: true), Array(subscribers.values))
            }
            count = samples > samplesAtLastFailure ? 1 : next
            samplesAtLastFailure = samples
            pending = PlaybackLoadRetryPolicy.mayThrowCurrentError(errorCount: count, progressiveLive: false) ? error : nil
            return (Plan(delayMilliseconds: delay, restartAtZero: recovery != .resumeCurrentPosition), Array(subscribers.values))
        }
        for listener in result.1 { listener.yield(()) }
        return result.0
    }
    func notifyReadWaitChanged() {
        let listeners = lock.withLock { Array(subscribers.values) }
        for listener in listeners { listener.yield(()) }
    }
    func events() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in self?.remove(id) }
        lock.withLock { subscribers[id] = continuation }
        continuation.yield(())
        return stream
    }
    private func remove(_ id: UUID) { lock.withLock { _ = subscribers.removeValue(forKey: id) } }
    func claimPresentation() -> Presentation {
        let id = UUID()
        lock.withLock { _ = presentations.insert(id) }
        return Presentation(owner: self, id: id)
    }
    private func releasePresentation(_ id: UUID) {
        let listeners = lock.withLock { presentations.remove(id); return Array(subscribers.values) }
        for listener in listeners { listener.yield(()) }
    }
    final class Presentation: Sendable {
        private let owner: PCMSourceRetry
        private let id: UUID
        fileprivate init(owner: PCMSourceRetry, id: UUID) { self.owner = owner; self.id = id }
        deinit { owner.releasePresentation(id) }
    }
    static func causes(of error: any Error) -> [PlaybackLoadRetryPolicy.Cause] {
        var result: [PlaybackLoadRetryPolicy.Cause] = []
        var current: (any Error)? = error
        var seen: [NSError] = []
        while let error = current {
            let object = error as NSError
            guard !seen.contains(where: { $0 === object }) else { break }
            seen.append(object)
            if let media = error as? MediaDownloadError {
                switch media {
                case .httpStatus(let status): result.append(status == 416 ? .positionOutOfRange : .httpResponse)
                case .wrongSize: result.append(.network)
                default: result.append(.unexpectedLoader)
                }
            } else if object.domain == NSURLErrorDomain || object.domain == "kCFErrorDomainCFNetwork" {
                switch URLError.Code(rawValue: object.code) {
                case .cancelled, .badURL, .unsupportedURL, .resourceUnavailable: result.append(.unexpectedLoader)
                case .fileDoesNotExist: result.append(.fileNotFound)
                case .appTransportSecurityRequiresSecureConnection: result.append(.cleartextNotPermitted)
                case .cannotDecodeContentData, .cannotDecodeRawData: result.append(.parser)
                default: result.append(.network)
                }
            } else if object.domain == NSCocoaErrorDomain && object.code == NSFileReadNoSuchFileError {
                result.append(.fileNotFound)
            } else if object.userInfo[NSUnderlyingErrorKey] == nil { result.append(.unexpectedLoader) }
            current = object.userInfo[NSUnderlyingErrorKey] as? any Error
        }
        return result.isEmpty ? [.unexpectedLoader] : result
    }
}
