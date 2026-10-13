import AVFoundation
import CoreMedia
import Foundation

/// A flush retired a pending enqueue; its packet is not in the queue.
enum PCMQueueReplacementError: Error { case replaced }

/// The SDK receiver adapter of processed playback. All control/queue ownership stays on the
/// main actor; Apple's renderer owns the audio thread. An automatic flush or reconfiguration
/// is reported as a failure instead of silently losing PCM.
@MainActor final class NativeSampleBufferTransport: VariableRatePresentationTransport, PCMVolumePresentationTransport {
    enum Failure: Error { case closed, flushed, reconfigurationRequired, automaticallyFlushed(at: CMTime), noAudioReceiver }
    var onTimeChanged: (@MainActor () -> Void)?
    var onFailure: (@MainActor (any Error) -> Void)?
    var currentTime: CMTime { synchronizer.currentTime() }
    var isMuted: Bool { renderer.isMuted }
    var rendererVolume: Float { renderer.volume }
    private let renderer: AVSampleBufferAudioRenderer
    private let synchronizer: AVSampleBufferRenderSynchronizer
    private let receiver: AVSampleBufferAudioRenderer.Receiver?
    private var periodicObserver: Any?
    private var endObserver: Any?
    private var closed = false
    private var queueRevision: UInt64 = 0
    private var monitoringTask: Task<Void, Never>?
    private(set) var videoPresentation: PlaybackVideoPresentation?

    init(muted: Bool, audioEnabled: Bool = true) {
        let renderer = AVSampleBufferAudioRenderer()
        renderer.isMuted = muted
        renderer.audioTimePitchAlgorithm = .timeDomain
        let synchronizer = AVSampleBufferRenderSynchronizer()
        // Output has its own bounded priming policy; a short final packet must also start.
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        self.renderer = renderer
        self.synchronizer = synchronizer
        receiver = audioEnabled ? synchronizer.sampleBufferReceiver(adding: renderer) : nil
        observePeriodically()
    }

    /// Until the output states its queue (`setRefreshInterval`), the former 10 ms check; video frames need
    /// at least 30 checks a second while attached.
    private var audioRefreshInterval = CMTime(value: 1, timescale: 100)
    static let videoRefreshInterval = CMTime(value: 1, timescale: 30)
    private(set) var periodicInterval: CMTime = .invalid
    func setRefreshInterval(_ interval: CMTime) {
        guard interval.isNumeric, interval > .zero else { return }
        audioRefreshInterval = interval
        observePeriodically()
    }
    private func observePeriodically() {
        guard !closed else { return }
        let interval = videoPresentation == nil ? audioRefreshInterval : min(audioRefreshInterval, Self.videoRefreshInterval)
        guard interval != periodicInterval else { return }
        if let periodicObserver { synchronizer.removeTimeObserver(periodicObserver) }
        periodicInterval = interval
        periodicObserver = synchronizer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.notify() }
        }
    }

    isolated deinit {
        videoPresentation?.close()
        monitoringTask?.cancel()
        synchronizer.rate = 0
        if let periodicObserver { synchronizer.removeTimeObserver(periodicObserver) }
        if let endObserver { synchronizer.removeTimeObserver(endObserver) }
        receiver?.flush()
    }

    func enqueue(_ buffer: CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>) async throws {
        guard !closed else { throw Failure.closed }
        guard let receiver else { throw Failure.noAudioReceiver }
        let revision = queueRevision
        // SampleBufferPCMOutput bounds unpresented audio (maximumQueuedBuffers). The
        // receiver's async enqueue additionally suspends at about one second of queued
        // audio and, observed on the 27.x SDK, never resumes while the synchronizer
        // rate is 0. Paused preparation or drain-to-buffering of low-rate PCM
        // (e.g. 8 kHz WAV: two 4096-frame buffers) then waits forever.
        let result = receiver.enqueueImmediately(CMReadySampleBuffer(buffer))
        guard !closed else { throw Failure.closed }
        if case .cancelledDueToError(let error) = result { throw error }
        guard revision == queueRevision else { throw PCMQueueReplacementError.replaced }
        switch result {
        case .enqueued: break
        case .enqueuedWithSuggestedFlush(let reasons): throw Self.discontinuity(reasons)
        case .cancelledDueToFlush: throw Failure.flushed
        case .cancelledDueToError(let error): throw error
        @unknown default: throw Failure.reconfigurationRequired
        }
    }

    /// Preserve the first discarded timestamp, including when configuration also changed.
    /// Unknown/invalid reasons must not masquerade as a known recoverable discontinuity.
    static func discontinuity(_ reasons: [AVSampleBufferAudioRenderer.Receiver.SuggestedFlushReason]) -> Failure {
        var first: CMTime?
        for reason in reasons {
            switch reason {
            case .outputConfigurationChanged: break
            case .wasFlushedAutomatically(let time):
                guard time.isNumeric, time >= .zero else { return .flushed }
                if first == nil || time < first! { first = time }
            @unknown default: return .flushed
            }
        }
        if let first { return .automaticallyFlushed(at: first) }
        return reasons.isEmpty ? .flushed : .reconfigurationRequired
    }

    func setPlaying(_ playing: Bool, at time: CMTime) {
        setRate(playing ? 1 : 0, at: time)
    }

    func setRate(_ rate: Float, at time: CMTime) {
        guard !closed else { return }
        synchronizer.setRate(rate, time: time)
    }

    /// The renderer's own volume, which the SDK intends "for frequent volume changes, for example via
    /// a volume knob or fader". It acts on the audio being presented; the queue, clock, rate and video
    /// are untouched, and `isMuted` stays independent.
    func setRendererVolume(_ volume: Float) {
        guard !closed else { return }
        renderer.volume = volume
    }

    /// Retain the same output timeline while discarding unpresented PCM (with video: a seek
    /// in place). A pending enqueue reports a distinct retirement result.
    func flush(at time: CMTime) throws {
        guard !closed else { throw Failure.closed }
        queueRevision &+= 1
        stopMonitoring()
        synchronizer.setRate(0, time: time)
        receiver?.flush()
    }

    /// Optional video uses this exact audio clock; attaching another player would
    /// lose processed-time correspondence. One surface/receiver per transport.
    func attachVideo(displayLayer: AVSampleBufferDisplayLayer, maximumQueuedFrames: Int = 12,
                     maximumQueuedBytes: Int = 64 * 1024 * 1024) throws -> PlaybackVideoPresentation {
        guard !closed else { throw Failure.closed }
        guard videoPresentation == nil else { throw PlaybackVideoPresentation.Failure.invalidCapacity }
        let video = try PlaybackVideoPresentation(synchronizer: synchronizer, displayLayer: displayLayer,
            maximumQueuedFrames: maximumQueuedFrames, maximumQueuedBytes: maximumQueuedBytes)
        video.onFailure = { [weak self] error in self?.onFailure?(error) }
        videoPresentation = video
        observePeriodically()
        return video
    }

    /// Seek/source replacement in place must retire both queues and obtain a new video
    /// generation token. Gain changes never flush (`setRendererVolume`).
    func flushAudioAndVideo(at time: CMTime) throws {
        try flush(at: time)
        videoPresentation?.invalidate()
    }

    func observeEnd(_ time: CMTime) {
        guard !closed else { return }
        if let endObserver { synchronizer.removeTimeObserver(endObserver) }
        endObserver = synchronizer.addBoundaryTimeObserver(forTimes: [NSValue(time: time)], queue: .main) { [weak self] in
            Task { @MainActor [weak self] in self?.notify() }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        onTimeChanged = nil
        onFailure = nil
        stopMonitoring()
        synchronizer.rate = 0
        if let periodicObserver { synchronizer.removeTimeObserver(periodicObserver) }
        if let endObserver { synchronizer.removeTimeObserver(endObserver) }
        periodicObserver = nil
        endObserver = nil
        receiver?.flush()
        videoPresentation?.close()
        videoPresentation = nil
    }

    func finishEnqueuing() {
        guard !closed && monitoringTask == nil, let receiver else { return }
        let events = receiver.renderingEventsAfterFinishedEnqueuing
        monitoringTask = Task { @MainActor [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self, !self.closed else { return }
                let failure: any Error
                switch event {
                case .wasFlushedAutomatically(let time): failure = Failure.automaticallyFlushed(at: time)
                case .outputConfigurationChanged: failure = Failure.reconfigurationRequired
                case .failed(let error): failure = error
                @unknown default: failure = Failure.reconfigurationRequired
                }
                self.onFailure?(failure)
                return
            }
        }
    }

    func stopMonitoring() { monitoringTask?.cancel(); monitoringTask = nil }

    private func notify() {
        guard !closed else { return }
        videoPresentation?.refresh()
        onTimeChanged?()
    }
}
