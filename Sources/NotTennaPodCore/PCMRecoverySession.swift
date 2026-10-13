import CoreMedia
import Foundation
import AVFoundation

/// Bridges recovery seeks to fresh processed-stream generations. Factory-created sessions
/// must be fresh and unprepared; this owner applies the latest parameters before decoding.
@MainActor final class PCMRecoverySession: PlaybackRecoverySession {
    struct Parameters: Equatable, Sendable {
        let speed: Float
        let skipSilence: Bool
        let volume: FeedVolumeAdaptation
        let baseVolume: Float
        init(speed: Float, skipSilence: Bool, volume: FeedVolumeAdaptation = .off, baseVolume: Float = 1) {
            self.speed = speed; self.skipSilence = skipSilence; self.volume = volume
            self.baseVolume = baseVolume
        }
    }
    typealias Factory = @MainActor (Int64, Parameters) async throws -> SampleBufferPlaybackSession
    enum Failure: Error { case closed, notReady, invalidGeneration }
    private(set) var parameters: Parameters
    var onChange: (@MainActor () -> Void)?
    private var presentationID: UUID?
    var mediaPresentationID: UUID? { isSeeking || current == nil ? nil : presentationID }
    var videoDisplayLayer: AVSampleBufferDisplayLayer? { isSeeking ? nil : current?.videoDisplayLayer }
    var videoPictureInPicture: PlaybackVideoPictureInPicture? { isSeeking ? nil : current?.videoPictureInPicture }
    var outputState: SampleBufferPCMOutput.State? { current?.state }
    var sourceRestartRequired: Bool { current?.sourceRestartRequired == true }
    var sourceSeekable: Bool? { current?.sourceSeekable }
    var sourceDurationMilliseconds: Int64? { current?.sourceDurationMilliseconds }
    var failure: (any Error)? { isSeeking ? nil : current?.failure }
    var recoveryPositionMilliseconds: Int64? { current?.recoveryMediaMicroseconds.map { $0 / 1000 } }
    var isSeeking: Bool { seekID != nil }
    /// Read the shared playable's saved statistics. Output pause/seek is not itself a save.
    var lastPlayedMilliseconds: Int64 { savedLastPlayedMilliseconds() }
    var positionMilliseconds: Int64 {
        get throws {
            if let current, let value = try current.mediaMicroseconds { return value / 1000 }
            return retainedPosition
        }
    }
    private var current: SampleBufferPlaybackSession?
    private var replacingPictureInPicture: PlaybackVideoPictureInPicture?
    private let factory: Factory
    private let savedLastPlayedMilliseconds: @MainActor () -> Int64
    private let settleStatistics: @MainActor () async throws -> Void
    private var retainedPosition: Int64 = 0
    private var seekID: UUID?
    private var closed = false

    init(initial: SampleBufferPlaybackSession? = nil, positionMilliseconds: Int64 = 0, parameters: Parameters,
         lastPlayedMilliseconds: @escaping @MainActor () -> Int64,
         synchronizeStatistics: @escaping @MainActor () async throws -> Void, factory: @escaping Factory) {
        current = initial
        presentationID = initial == nil ? nil : UUID()
        retainedPosition = max(0, positionMilliseconds)
        self.parameters = parameters
        savedLastPlayedMilliseconds = lastPlayedMilliseconds
        settleStatistics = synchronizeStatistics
        self.factory = factory
        if let initial { observe(initial) }
    }

    func synchronizeStatistics() async throws {
        guard !closed else { throw Failure.closed }
        try await settleStatistics()
        guard !closed else { throw Failure.closed }
    }

    /// Detach the terminal generation synchronously. Activation callbacks can arrive before
    /// the replacement task starts and must not rediscover its obsolete failure.
    func discardFailedOutput(at positionMilliseconds: Int64) {
        retainedPosition = max(0, positionMilliseconds)
        current?.onChange = nil
        if replacingPictureInPicture == nil {
            replacingPictureInPicture = current?.takePictureInPictureForReplacement()
        }
        current?.close()
        current = nil
    }

    isolated deinit { current?.close(); replacingPictureInPicture?.close() }

    func play() throws {
        guard !closed else { throw Failure.closed }
        guard seekID == nil, let current else { throw Failure.notReady }
        try current.play()
    }

    func pause() throws {
        guard !closed else { throw Failure.closed }
        if let current {
            try current.pause()
            retainedPosition = try positionMilliseconds
        }
    }

    func setParameters(speed: Float, skipSilence: Bool) async throws {
        guard !closed else { throw Failure.closed }
        guard speed.isFinite, (0.5...4).contains(speed) else { throw PCMSpeedProcessor.Failure.invalidSpeed }
        parameters = Parameters(speed: speed, skipSilence: skipSilence, volume: parameters.volume, baseVolume: parameters.baseVolume)
        if let applying = current {
            do { try await applying.setParameters(speed: speed, skipSilence: skipSilence) }
            catch {
                guard !closed else { throw Failure.closed }
                // A seek/rebuild can retire this output while its actor call is pending.
                // The retained parameters already belong to the replacement. Only an
                // error from the still-current output may fail that playback generation.
                if current === applying { throw error }
            }
        }
        guard !closed else { throw Failure.closed }
    }

    /// Synchronous: the current renderer takes the attenuation when commanded. A factory still
    /// preparing the next output receives the latest value before its first enqueue.
    func setVolumeAdaptation(_ setting: FeedVolumeAdaptation, baseVolume: Float = 1) throws {
        guard !closed else { throw Failure.closed }
        parameters = Parameters(speed: parameters.speed, skipSilence: parameters.skipSilence, volume: setting, baseVolume: baseVolume)
        try current?.setVolumeAdaptation(setting, baseVolume: baseVolume)
    }

    func seekPaused(to positionMilliseconds: Int64) async throws {
        try await preparePaused(to: positionMilliseconds, allowRecovery: true)
    }

    func recoverPaused(to positionMilliseconds: Int64) async throws {
        try await preparePaused(to: positionMilliseconds, allowRecovery: false)
    }

    private func preparePaused(to positionMilliseconds: Int64, allowRecovery: Bool) async throws {
        guard !closed else { throw Failure.closed }
        try Task.checkCancellation()
        let id = UUID()
        seekID = id
        retainedPosition = max(0, positionMilliseconds)
        current?.onChange = nil
        if replacingPictureInPicture == nil {
            replacingPictureInPicture = current?.takePictureInPictureForReplacement()
        }
        current?.close()
        current = nil
        onChange?()
        // The caller already consumed the recovery attempt when replacing a prepared
        // renderer. Ordinary preparation/seek may recover once before it reaches readiness.
        var mayRecover = allowRecovery
        while true {
            var replacement: SampleBufferPlaybackSession?
            do {
                let next = try await factory(retainedPosition, parameters)
                replacement = next
                guard !closed && seekID == id else { throw Failure.closed }
                try Task.checkCancellation()
                guard next.state == .idle && next.writtenFrames == 0 && !next.wantsPlayback else {
                    throw Failure.invalidGeneration
                }
                current = next
                observe(next)
                try await next.setParameters(speed: parameters.speed, skipSilence: parameters.skipSilence)
                try next.setVolumeAdaptation(parameters.volume, baseVolume: parameters.baseVolume)
                try await next.prepare()
                guard !closed && seekID == id else { throw Failure.closed }
                try Task.checkCancellation()
                if let retained = replacingPictureInPicture {
                    try await next.adoptPictureInPicture(retained, didAdopt: { [weak self] in
                        // Runs inside the session's synchronous ownership commit.
                        // A subsequent seek can now take the wrapper from next.
                        if self?.replacingPictureInPicture === retained { self?.replacingPictureInPicture = nil }
                    })
                    guard !closed && seekID == id else { throw Failure.closed }
                    try Task.checkCancellation()
                }
                seekID = nil
                presentationID = UUID()
                onChange?()
                return
            } catch {
                let preparationError = replacement?.failure ?? error
                replacement?.onChange = nil
                replacement?.close()
                guard !closed && seekID == id && !Task.isCancelled else {
                    if seekID == id { current = nil; seekID = nil }
                    throw error
                }
                current = nil
                if mayRecover, replacement != nil, Self.isPreparationDiscontinuity(preparationError) {
                    mayRecover = false
                    // Nothing has rendered. Recreate at the requested media target, including
                    // any prefix buffered before the renderer was flushed.
                    continue
                }
                seekID = nil
                replacingPictureInPicture?.close(); replacingPictureInPicture = nil
                throw preparationError
            }
        }
    }

    private static func isPreparationDiscontinuity(_ error: any Error) -> Bool {
        guard let error = error as? NativeSampleBufferTransport.Failure else { return false }
        switch error {
        case .reconfigurationRequired: return true
        case .automaticallyFlushed(let time): return time.isNumeric && time >= .zero
        default: return false
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        seekID = nil
        current?.onChange = nil
        current?.close()
        current = nil
        replacingPictureInPicture?.close(); replacingPictureInPicture = nil
        onChange = nil
    }

    private func observe(_ session: SampleBufferPlaybackSession) {
        session.onChange = { [weak self, weak session] in
            guard let self, let session, self.current === session, !self.closed else { return }
            if self.isSeeking && session.failure != nil {
                // Remove the failed generation before queued activation/manual commands.
                // The preparing task retains its error and owns the bounded recovery decision.
                self.current = nil
                session.onChange = nil
                session.close()
            }
            self.onChange?()
        }
    }
}
