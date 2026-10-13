import CoreMedia
import Foundation

/// Candidate local PCM session. Owns ordered output, bounded refill and processor checkpoints.
/// Its rendered-media clock is diagnostic until device presentation timing is established;
/// this type deliberately does not yet conform to the app's PlaybackEngine protocol.
@MainActor public final class NativePCMPlaybackSession {
    public enum State: Equatable, Sendable { case idle, buffering, playing, paused, ended, failed, closed }
    public enum Failure: Error, Equatable { case closed, ended, outOfOrderPacket, devicePresentationUnverified }
    public private(set) var state: State = .idle
    public private(set) var wantsPlayback = false
    public private(set) var sourceEnded = false
    public private(set) var failure: (any Error)?
    public var onStateChanged: (@MainActor (State) -> Void)?
    public var writtenFrames: Int64 { output.scheduledFrames }
    public var renderedFrames: Int64 { output.renderedFrames }
    public var queuedBufferCount: Int { output.queuedBufferCount }
    public var pendingCheckpointCount: Int { clock?.pendingCheckpointCount ?? 0 }

    /// Freeze both output time and producer-dependent mapping while paused/buffering. The
    /// renderer/session layer, not the source processor's counters, owns this playback clock.
    public var renderedMediaMicroseconds: Int64? {
        get throws {
            if state == .playing { frozenMediaMicroseconds = try mappedPosition() }
            return frozenMediaMicroseconds
        }
    }

    let output: NativePCMOutput
    private let stream: LocalPCMPlaybackStream
    private var clock: PCMPlaybackClock?
    private var progress: PCMProcessingProgress?
    private var segment: LocalPCMPlaybackStream.Segment?
    private var epoch = UUID()
    private var refillTask: Task<Void, Error>?
    private var frozenMediaMicroseconds: Int64?

    /// Construct the stream on its decoder worker before creating this MainActor output owner.
    public init(stream: LocalPCMPlaybackStream, mode: NativePCMOutput.Mode, maximumQueuedBuffers: Int = 4) throws {
        guard mode == .offline else { throw Failure.devicePresentationUnverified }
        self.stream = stream
        output = try NativePCMOutput(sampleRate: stream.sampleRate, channels: stream.channels, mode: mode,
                                     bufferCapacity: stream.maximumOutputFrames, maximumQueuedBuffers: maximumQueuedBuffers)
        output.onBufferCompleted = { [weak self] _ in self?.bufferCompleted() }
    }

    isolated deinit {
        refillTask?.cancel()
        output.onBufferCompleted = nil
        output.reset()
    }

    /// Prime without starting audio. Multiple callers share the same bounded refill task.
    public func prepare() async throws {
        try Task.checkCancellation()
        guard state != .closed else { throw Failure.closed }
        if let failure { throw failure }
        guard state != .ended else { return }
        try await startRefill().value
        guard state != .closed else { throw Failure.closed }
        try Task.checkCancellation()
    }

    public func play() throws {
        guard state != .closed else { throw Failure.closed }
        guard state != .ended else { throw Failure.ended }
        if let failure { throw failure }
        wantsPlayback = true
        if output.queuedBufferCount > 0 {
            do {
                try output.play()
                setState(.playing)
            } catch { fail(error); throw error }
        } else {
            setState(.buffering)
            if state != .closed && state != .failed { _ = startRefill() }
        }
    }

    public func pause() throws {
        guard state != .closed else { throw Failure.closed }
        if state == .playing {
            do { frozenMediaMicroseconds = try mappedPosition() }
            catch { fail(error); throw error }
        }
        wantsPlayback = false
        output.pause()
        if state != .ended && state != .failed { setState(.paused) }
    }

    public func setParameters(speed: Float, skipSilence: Bool) async throws {
        let token = epoch
        guard state != .closed else { throw Failure.closed }
        try await stream.setParameters(speed: speed, skipSilence: skipSilence)
        try validate(token)
    }

    /// Manual output clock/completion advance when actual PCM is returned, not when an
    /// upstream player callback fires. Device presentation is a separate gate before this session can use hardware output.
    public func renderOffline(frames: Int) throws -> [Float] {
        let samples = try output.renderOffline(frames: frames)
        if !finishIfDrained() && output.queuedBufferCount == 0 && renderedFrames == writtenFrames {
            if wantsPlayback {
                frozenMediaMicroseconds = try mappedPosition()
                setState(.buffering)
            }
            if state != .closed && state != .failed && refillTask == nil { _ = startRefill() }
        }
        return samples
    }

    /// Seek/replacement creates a fresh stream/session. Closing fences every outstanding pull
    /// and native callback before cancellation crosses to the decoder actor.
    public func close() {
        guard state != .closed else { return }
        epoch = UUID()
        wantsPlayback = false
        refillTask?.cancel()
        refillTask = nil
        output.reset()
        clock = nil
        progress = nil
        segment = nil
        frozenMediaMicroseconds = nil
        setState(.closed)
        let stream = stream
        Task { await stream.cancel() }
    }

    private func startRefill() -> Task<Void, Error> {
        if let refillTask { return refillTask }
        let token = epoch
        let task = Task { @MainActor [weak self] in
            guard let self else { throw Failure.closed }
            defer { if self.epoch == token { self.refillTask = nil } }
            do { try await self.refill(token) }
            catch {
                if self.epoch == token && self.state != .closed {
                    self.failure = error
                    self.wantsPlayback = false
                    self.output.pause()
                    self.setState(.failed)
                }
                throw error
            }
        }
        refillTask = task
        return task
    }

    private func refill(_ token: UUID) async throws {
        try validate(token)
        if clock == nil {
            let initial = await stream.segment
            try validate(token)
            segment = initial
            let anchor = initial.mediaStartMicroseconds
            clock = try PCMPlaybackClock(sampleRate: stream.sampleRate, mediaMicroseconds: anchor,
                                         speed: initial.parameters.speed)
            frozenMediaMicroseconds = anchor
        }
        while !sourceEnded && output.availableBufferCount > 0 {
            let packet = try await stream.nextPacket()
            try validate(token)
            guard let packet else {
                progress = try await stream.progress
                try validate(token)
                sourceEnded = true
                break
            }
            guard packet.outputStartFrame == writtenFrames else { throw Failure.outOfOrderPacket }
            var nextClock = clock
            if packet.segment.id != segment?.id {
                guard packet.segment.outputStartFrame == writtenFrames else { throw Failure.outOfOrderPacket }
                try nextClock?.enqueueCheckpoint(outputFrame: writtenFrames,
                    mediaMicroseconds: packet.segment.mediaStartMicroseconds, speed: packet.segment.parameters.speed)
            }
            try output.enqueue(packet.samples)
            clock = nextClock
            segment = packet.segment
            progress = packet.progress
        }
        if finishIfDrained() { return }
        if wantsPlayback && output.queuedBufferCount > 0 {
            if !output.wantsPlayback { try output.play() }
            setState(.playing)
        } else if !wantsPlayback { setState(.paused) }
    }

    private func bufferCompleted() {
        if state == .closed || state == .failed || state == .ended { return }
        if finishIfDrained() { return }
        if output.queuedBufferCount == 0 && renderedFrames == writtenFrames && wantsPlayback {
            // Every native buffer completed, but source EOF is not known yet. Preserve the
            // episode position while refill obtains more audio or confirms the true ending.
            do { frozenMediaMicroseconds = try mappedPosition() }
            catch { fail(error); return }
            setState(.buffering)
        }
        if refillTask == nil && state != .closed && state != .failed { _ = startRefill() }
    }

    @discardableResult private func finishIfDrained() -> Bool {
        guard sourceEnded && output.queuedBufferCount == 0 && renderedFrames == writtenFrames else { return false }
        if state != .ended {
            do { frozenMediaMicroseconds = try mappedPosition() }
            catch { fail(error); return true }
            wantsPlayback = false
            output.pause()
            setState(.ended)
        }
        return true
    }

    private func mappedPosition() throws -> Int64? {
        guard let progress else { return frozenMediaMicroseconds }
        return try clock?.position(presentedFrames: renderedFrames, writtenFrames: writtenFrames, progress: progress)
    }


    private func validate(_ token: UUID) throws {
        guard token == epoch && state != .closed else { throw Failure.closed }
        try Task.checkCancellation()
    }

    private func setState(_ value: State) {
        guard state != value else { return }
        state = value
        onStateChanged?(value)
    }

    private func fail(_ error: any Error) {
        failure = error
        wantsPlayback = false
        output.pause()
        setState(.failed)
    }

}
