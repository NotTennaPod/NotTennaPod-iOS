import CoreMedia
import Foundation
import os
import Synchronization

/// One serialized receiver owner. Native implementations must fence callbacks after close.
@MainActor protocol PCMPresentationTransport: AnyObject {
    var currentTime: CMTime { get }
    var onTimeChanged: (@MainActor () -> Void)? { get set }
    var onFailure: (@MainActor (any Error) -> Void)? { get set }
    func enqueue(_ buffer: CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>) async throws
    func setPlaying(_ playing: Bool, at time: CMTime)
    func observeEnd(_ time: CMTime)
    func finishEnqueuing()
    func stopMonitoring()
    func close()
    /// How often presentation is checked for freed queue space. The output asks for at least ten checks per
    /// queued duration, so a refill always has most of the queue as margin (none needed for test transports).
    func setRefreshInterval(_ interval: CMTime)
}

extension PCMPresentationTransport {
    func setRefreshInterval(_ interval: CMTime) {}
}

/// Compressed audio uses Apple's time-pitch processing. Processed PCM keeps its
/// existing natural-rate presentation and maps speed in its upstream processor.
@MainActor protocol VariableRatePresentationTransport: PCMPresentationTransport {
    func setRate(_ rate: Float, at time: CMTime)
}

/// Output controller of every processed playback route: coordinates accepted audio frames
/// with a presentation clock, never a decoder clock.
/// Seek/replacement closes this generation and constructs another output at frame zero.
@MainActor final class SampleBufferPCMOutput {
    enum State: Equatable { case idle, paused, playing, buffering, ended, failed, closed }
    enum Failure: Error, Equatable { case invalidCapacity, full, enqueueInProgress, finished, closed, invalidClock, invalidPacket, unsupportedRate }
    private(set) var state: State = .idle
    private(set) var wantsPlayback = false
    private(set) var writtenFrames: Int64 = 0
    private(set) var presentedFrames: Int64 = 0
    private(set) var sourceEnded = false
    private(set) var failure: (any Error)?
    /// Separate from the published monotonic position: a delayed automatic flush may name
    /// earlier discarded audio. Recovery must map that point or explicitly refuse it.
    private(set) var recoveryFrame: Int64?
    private(set) var enqueueInProgress = false
    var onChange: (@MainActor () -> Void)?
    var canStartPlayback: (@MainActor (_ rebuffering: Bool) throws -> Bool)?
    private(set) var isRebuffering = false
    var queuedBufferCount: Int { ends.count }
    /// After the renderer ran dry while playing, wait for this much queued audio (or the source end) before
    /// restarting, so a struggling producer gives one clean pause instead of rapid stutter, like ExoPlayer's
    /// rebuffer threshold. Zero restarts at the first written buffer.
    var starvationResumeFrames: Int64 = 0
    /// The producer has drained and waits for a source retry: nothing more can arrive in this generation.
    /// Like the source end, but only for the restart decision; it is not an end and completes nothing.
    private(set) var inputDrained = false
    private var refilledAfterStarvation: Bool {
        !isRebuffering || sourceEnded || inputDrained || writtenFrames - presentedFrames >= starvationResumeFrames
    }
    var availableBufferCount: Int { capacity - ends.count - (enqueueInProgress ? 1 : 0) }

    private let transport: any PCMPresentationTransport
    private let factory: PCMSampleBufferFactory
    private let capacity: Int
    private var ends: [Int64] = []
    private var pendingID: UUID?
    private(set) var presentationRate: Float = 1
    /// Video shares this clock but never inflates accepted PCM frame counters.
    private var additionalEnd: CMTime = .zero
    private var additionalPresented: CMTime = .zero
    private var additionalFinished = true
    private var hasAdditionalPresentation = false
    var presentationTime: CMTime { max(time(presentedFrames), additionalPresented) }

    init(transport: any PCMPresentationTransport, sampleRate: Int, channels: Int,
         maximumFrames: Int = 4096, maximumQueuedBuffers: Int = 4) throws {
        guard (1...64).contains(maximumQueuedBuffers) else { throw Failure.invalidCapacity }
        factory = try PCMSampleBufferFactory(sampleRate: sampleRate, channels: channels, maximumFrames: maximumFrames)
        capacity = maximumQueuedBuffers
        self.transport = transport
        transport.onTimeChanged = { [weak self] in self?.refresh() }
        transport.onFailure = { [weak self] error in self?.abort(error) }
        let queued = Double(maximumFrames * maximumQueuedBuffers) / Double(sampleRate)
        transport.setRefreshInterval(CMTime(seconds: min(0.1, queued / 10), preferredTimescale: 1_000_000))
    }

    isolated deinit { transport.onTimeChanged = nil; transport.onFailure = nil; transport.close() }

    /// One caller may await native backpressure. Other callers reject rather than building an
    /// unbounded task/PCM backlog. The in-flight packet reserves one slot until it resolves.
    func enqueue(_ samples: [Int16], onAccepted: @MainActor () throws -> Void = {}) async throws {
        try await enqueue(frameCount: Int64(samples.count / factory.channels), makeBuffer: {
            try factory.makeBuffer(samples, outputStartFrame: writtenFrames)
        }, onAccepted: onAccepted)
    }

    private func enqueue(frameCount: Int64,
                         makeBuffer: () throws -> CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>,
                         onAccepted: @MainActor () throws -> Void) async throws {
        try checkOpen()
        try Task.checkCancellation()
        guard !sourceEnded else { throw Failure.finished }
        guard !enqueueInProgress else { throw Failure.enqueueInProgress }
        // A producer can resume before a queued periodic observer runs. Reconcile the native
        // clock first so a late packet is not timestamped behind a still-running timebase.
        if state == .playing { refresh(); try checkOpen() }
        guard availableBufferCount > 0 else { throw Failure.full }
        let buffer = try makeBuffer()
        let pendingID = UUID()
        self.pendingID = pendingID
        enqueueInProgress = true
        defer { enqueueInProgress = false; self.pendingID = nil }
        do {
            try await withTaskCancellationHandler {
                try await transport.enqueue(buffer)
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancelPendingEnqueue(pendingID) }
            }
            try checkOpen()
            try Task.checkCancellation()
            writtenFrames += frameCount
            ends.append(writtenFrames)
            // Commit the packet's processing checkpoint before publishing new output state.
            // Native enqueue may suspend while older audio continues to be presented.
            try onAccepted()
            try checkOpen()
            transport.observeEnd(max(time(writtenFrames), additionalEnd))
            if wantsPlayback, state != .playing, refilledAfterStarvation, try canStartPlayback?(isRebuffering) ?? true {
                startTransport()
            } else if state == .idle { state = .paused }
        } catch {
            // Cancellation after native acceptance is ambiguous. Flush the whole generation;
            // do not continue with a timeline that might omit or duplicate that packet.
            let shouldNotify = state != .closed && state != .failed
            if shouldNotify { fail(error) }
            enqueueInProgress = false
            if shouldNotify { onChange?() }
            // A source failure can retire the renderer while enqueue is suspended.
            // Its eventual flush/cancellation must not replace or republish that cause.
            if state == .failed, let failure { throw failure }
            throw error
        }
        // Publish only after releasing the slot reservation, so observers see exact capacity.
        enqueueInProgress = false
        onChange?()
    }

    func play() throws {
        try checkOpen()
        guard state != .ended else { throw Failure.finished }
        guard state != .playing else { return }
        if !wantsPlayback { isRebuffering = false }
        wantsPlayback = true
        if hasPendingPresentation, refilledAfterStarvation, try canStartPlayback?(isRebuffering) ?? true {
            startTransport()
        } else { state = .buffering }
        onChange?()
    }

    func pause() throws {
        try checkOpen()
        // Read the native clock before stopping; late callbacks never advance a paused UI.
        if state == .playing { updatePosition() }
        if state == .failed { onChange?() }
        try checkOpen()
        wantsPlayback = false
        isRebuffering = false
        ends.removeAll { $0 <= presentedFrames }
        transport.setPlaying(false, at: presentationTime)
        if state != .ended { state = .paused }
        onChange?()
    }

    func finishEnqueuing() throws {
        try checkOpen()
        guard !enqueueInProgress else { throw Failure.enqueueInProgress }
        sourceEnded = true
        transport.finishEnqueuing()
        refresh()
        // A final refill shorter than the rebuffer threshold was held only because more audio could
        // still arrive. Nothing else rechecks it once the producer stops, so do it here, keeping pause intent.
        try refreshReadiness()
    }

    /// Called by native periodic/boundary observations or a deterministic test clock. A late
    /// observation may exceed the last packet; clamp and stop at that exact known boundary.
    func refresh() {
        guard state != .closed && state != .failed && state != .ended else { return }
        if state == .playing { updatePosition() }
        guard state != .failed else { onChange?(); return }
        ends.removeAll { $0 <= presentedFrames }
        if !hasPendingPresentation {
            if state == .playing {
                if !(sourceEnded && additionalFinished) {
                    PCMStarvationDiagnostics.record(overrun: CMTimeSubtract(transport.currentTime, time(writtenFrames)))
                }
                transport.setPlaying(false, at: presentationTime)
            }
            if sourceEnded && additionalFinished { wantsPlayback = false; state = .ended; transport.stopMonitoring() }
            else if wantsPlayback {
                if state == .playing { isRebuffering = true }
                state = .buffering
            }
        }
        onChange?()
    }

    /// No more audio can arrive before a source retry: let a remaining piece shorter than the rebuffer
    /// threshold restart, keeping pause intent. End, completion and the retry itself are unchanged.
    func drainBeforeRetry() throws {
        try checkOpen()
        inputDrained = true
        try refreshReadiness()
    }

    /// Encoded loading can become ready while no PCM pull is active. Recheck without
    /// changing pause intent or stopping an already-playing renderer as its buffer shrinks.
    func refreshReadiness() throws {
        guard state != .closed, state != .failed, state != .ended, state != .playing,
              wantsPlayback, hasPendingPresentation else { return }
        if refilledAfterStarvation, try canStartPlayback?(isRebuffering) ?? true {
            startTransport()
            onChange?()
        }
    }

    private func startTransport() {
        if let variable = transport as? any VariableRatePresentationTransport {
            variable.setRate(presentationRate, at: presentationTime)
        } else { transport.setPlaying(true, at: presentationTime) }
        state = .playing
        isRebuffering = false
    }

    func setPresentationRate(_ rate: Float) throws {
        try checkOpen()
        guard rate.isFinite, (0.5...4).contains(rate) else { throw PlaybackSpeedError.invalidSpeed }
        guard rate == 1 || transport is any VariableRatePresentationTransport else { throw Failure.unsupportedRate }
        if state == .playing { refresh(); try checkOpen() }
        presentationRate = rate
        if state == .playing { startTransport() }
        onChange?()
    }

    /// Call before audio EOF can be published, then advance only after native video
    /// accepts a frame. A paused/empty track cannot fabricate progress beyond its data.
    func requireAdditionalPresentation() throws {
        try checkOpen()
        guard state != .ended else { throw Failure.finished }
        additionalFinished = false
        hasAdditionalPresentation = true
    }

    func commitAdditionalPresentation(through end: CMTime, finished: Bool = false) throws {
        try checkOpen()
        guard end.isNumeric, end >= additionalEnd else { throw Failure.invalidClock }
        additionalEnd = end
        transport.observeEnd(max(time(writtenFrames), additionalEnd))
        if finished { additionalFinished = true }
        if wantsPlayback, state == .buffering, hasPendingPresentation, refilledAfterStarvation,
           try canStartPlayback?(isRebuffering) ?? true { startTransport() }
        refresh()
    }

    private var hasPendingPresentation: Bool {
        presentedFrames < writtenFrames || additionalPresented < additionalEnd
    }

    func close() {
        guard state != .closed else { return }
        state = .closed
        wantsPlayback = false
        transport.onTimeChanged = nil
        transport.onFailure = nil
        transport.close()
        ends.removeAll()
        onChange?()
    }

    /// A producer/clock failure invalidates the whole generation, without signalling EOF.
    func abort(_ error: any Error) {
        guard state != .closed && state != .failed && state != .ended else { return }
        fail(error)
        onChange?()
    }

    private func updatePosition() {
        let value = transport.currentTime
        guard value.isNumeric, value >= .zero else { fail(Failure.invalidClock); return }
        let frames = CMTimeConvertScale(value, timescale: Int32(factory.sampleRate), method: .roundTowardZero)
        guard frames.isNumeric else { fail(Failure.invalidClock); return }
        presentedFrames = min(writtenFrames, max(presentedFrames, frames.value))
        if hasAdditionalPresentation { additionalPresented = min(max(time(writtenFrames), additionalEnd), max(additionalPresented, value)) }
    }

    private func time(_ frame: Int64) -> CMTime { CMTime(value: frame, timescale: Int32(factory.sampleRate)) }
    private func checkOpen() throws {
        guard state != .closed else { throw Failure.closed }
        if let failure { throw failure }
    }
    private func fail(_ error: any Error) {
        if let error = error as? NativeSampleBufferTransport.Failure {
            let playhead = state == .playing ? transport.currentTime : time(presentedFrames)
            let restart: CMTime?
            switch error {
            case .reconfigurationRequired: restart = playhead
            case .automaticallyFlushed(let firstDiscarded):
                restart = firstDiscarded.isNumeric && firstDiscarded >= .zero && playhead.isNumeric
                    ? min(playhead, firstDiscarded) : nil
            default: restart = nil
            }
            if let restart, restart.isNumeric, restart >= .zero {
                let frames = CMTimeConvertScale(restart, timescale: Int32(factory.sampleRate), method: .roundTowardZero)
                if frames.isNumeric { recoveryFrame = min(writtenFrames, frames.value) }
            }
        }
        failure = error
        wantsPlayback = false
        state = .failed
        transport.onTimeChanged = nil
        transport.onFailure = nil
        transport.close()
    }

    private func cancelPendingEnqueue(_ id: UUID) {
        guard pendingID == id && enqueueInProgress && state != .closed && state != .failed else { return }
        fail(CancellationError())
        onChange?()
    }
}

/// Every time playing PCM ran out of written audio (an audible gap) before the source ended. Process-wide so
/// real-renderer tests can assert none happen, and logged so a device's console shows starvation directly.
enum PCMStarvationDiagnostics {
    struct Totals: Equatable, Sendable { var events = 0; var overrunSeconds = 0.0; var worstOverrunSeconds = 0.0 }
    private static let totals = Mutex(Totals())
    private static let log = Logger(subsystem: "org.nottennapod.app", category: "playback")
    static var current: Totals { totals.withLock { $0 } }
    static func reset() { totals.withLock { $0 = Totals() } }
    static func record(overrun: CMTime) {
        let seconds = overrun.isNumeric ? max(0, overrun.seconds) : 0
        totals.withLock { $0.events += 1; $0.overrunSeconds += seconds; $0.worstOverrunSeconds = max($0.worstOverrunSeconds, seconds) }
        log.error("PCM starvation: renderer ran out of audio, clock \(seconds, format: .fixed(precision: 3)) s past written end")
    }
}
