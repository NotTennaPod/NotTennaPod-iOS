import Foundation

/// Seeking must leave output paused and fence superseded native work. The engine owns media
/// identity and persistence; this port supplies the current source-media position/statistics.
@MainActor protocol PlaybackRecoverySession: AnyObject {
    var positionMilliseconds: Int64 { get throws }
    var lastPlayedMilliseconds: Int64 { get }
    func synchronizeStatistics() async throws
    func pause() throws
    func play() throws
    func seekPaused(to positionMilliseconds: Int64) async throws
    func recoverPaused(to positionMilliseconds: Int64) async throws
    func close()
}

extension PlaybackRecoverySession {
    func recoverPaused(to positionMilliseconds: Int64) async throws {
        try await seekPaused(to: positionMilliseconds)
    }
}

/// Recovery owner of processed playback. Connects system facts and serialized activation to
/// source-derived focus/rewind decisions. It never ends an episode as a recovery side effect.
@MainActor final class PlaybackRecoveryController {
    enum State: Equatable { case paused, activating, seeking, playing, interrupted, requiresRebuild, failed, closed }
    enum Failure: Error { case closed, activationDeclined, rebuildRequired }
    private(set) var state: State = .paused
    private(set) var failure: (any Error)?
    var wantsPlayback: Bool { policy.playWhenReady }
    var isSuppressed: Bool { policy.suppressed }
    var onChange: (@MainActor () -> Void)?
    private var policy: PlaybackFocusPolicy
    private let activation: AudioSessionActivationController
    private let session: any PlaybackRecoverySession
    private let now: @MainActor () -> Int64
    private let ownsActivation: Bool
    private let pauseOnDisconnectProvider: (@MainActor () -> Bool)?
    private var activationRequest: UUID?
    private var seekID: UUID?
    private var seekTask: Task<Void, any Error>?
    private var interruptionPending = false

    init(session: any PlaybackRecoverySession, activation: AudioSessionActivationController,
         pauseOnDisconnect: Bool = true, pauseOnDisconnectProvider: (@MainActor () -> Bool)? = nil,
         ownsActivation: Bool = true, now: @escaping @MainActor () -> Int64) {
        self.session = session
        self.activation = activation
        self.now = now
        self.ownsActivation = ownsActivation
        self.pauseOnDisconnectProvider = pauseOnDisconnectProvider
        policy = PlaybackFocusPolicy(pauseOnDisconnect: pauseOnDisconnect)
        activation.onResult = { [weak self] result in self?.activationFinished(result) }
    }

    isolated deinit {
        seekTask?.cancel()
        session.close()
        if ownsActivation { activation.close() }
    }

    func play() throws {
        try validate()
        guard state != .playing else { return }
        interruptionPending = false
        let transition = policy.apply(.requestPlay(granted: true))
        try applyRewind(transition)
        activationRequest = try activation.request(active: true)
        updateState()
    }

    /// The audio session stays active while paused, as Media3 keeps audio focus; it is released when
    /// playback stops for good (`close`, failure).
    func pause() throws {
        try validate()
        policy.apply(.requestPause)
        try session.pause()
        updateState()
    }

    func seek(to positionMilliseconds: Int64) throws {
        try beginSeek(to: positionMilliseconds, pauseOutput: true)
    }

    /// The failed native generation is already closed. Retain focus and user intent while
    /// the session port replaces it; ordinary pause would rethrow its terminal error.
    func recoverOutput(at positionMilliseconds: Int64) throws {
        try beginSeek(to: positionMilliseconds, pauseOutput: false)
    }

    private func beginSeek(to positionMilliseconds: Int64, pauseOutput: Bool) throws {
        try validate()
        let id = UUID()
        seekID = id
        seekTask?.cancel()
        updateState()
        try validate()
        if pauseOutput { try session.pause() }
        let session = session
        seekTask = Task { @MainActor [weak self] in
            do {
                if pauseOutput { try await session.seekPaused(to: positionMilliseconds) }
                else { try await session.recoverPaused(to: positionMilliseconds) }
                guard let self, self.seekID == id, self.state != .closed else { return }
                self.seekID = nil
                self.seekTask = nil
                self.updateState()
                try self.startIfReady()
            } catch {
                if let self, self.seekID == id, self.state != .closed { self.fail(error) }
                throw error
            }
        }
    }

    func receive(_ event: AudioSessionEvent) {
        guard state != .closed else { return }
        if activation.receive(event) { receiveObserved(event) }
    }

    /// Engine-owned observations update shared session facts even between media sessions.
    func receiveObserved(_ event: AudioSessionEvent) {
        guard state != .closed && state != .failed else { return }
        if state == .requiresRebuild { return }
        switch event {
        case .routeChanged(reason: 2), .interrupted(reason: 4):
            if let pauseOnDisconnectProvider { policy.setPauseOnDisconnect(pauseOnDisconnectProvider()) }
        default: break
        }
        do {
            switch event {
            case .interrupted(let reason):
                // iOS route-disconnect deactivation can accompany the ordinary route event.
                // Clearing intent is idempotent; it does not authorize reconnect autoplay.
                if reason == 4 { policy.apply(.audioBecomingNoisy) }
                interruptionPending = true
                policy.apply(.lostTemporarily)
                try session.pause()
                activationRequest = try activation.request(active: false)
            case .resumptionRecommended(let resume):
                // Only an interruption's end ends it (event order): the app coming to the foreground, another
                // scene's activation or the session becoming active again is no evidence. A Play since then
                // superseded it; a Pause since then gave up its playback, though the rewind still applies.
                guard interruptionPending else { return }
                interruptionPending = false
                let transition = policy.apply(resume ? .gained : .lost)
                try applyRewind(transition)
                if transition.shouldRender { activationRequest = try activation.request(active: true) }
            case .routeChanged(let reason):
                if reason == 2 {
                    // A paused player keeps the session, as for any pause.
                    let transition = policy.apply(.audioBecomingNoisy)
                    if !transition.shouldRender { try session.pause() } else { return }
                } else {
                    if reason == 1 { policy.apply(.routeConnected) }
                    return
                }
            case .appDeactivated:
                // Every app deactivation is the session owner's own; it is not forwarded and must not
                // pause a newer engine that already holds the session.
                return
            case .mediaServicesLost, .mediaServicesReset:
                // Every audio object is invalid. The fence comes first: pausing an orphaned output can call back
                // synchronously (a clock that fails as it is read), and that callback must find the reset, never
                // an ordinary failure or output recovery. Its errors are ignored; the item waits for an explicit
                // Play to be built again.
                seekTask?.cancel()
                seekID = nil
                state = .requiresRebuild
                activationRequest = try? activation.request(active: false)
                try? session.pause()
                onChange?()
                return
            case .becameActive:
                // Observation alone is not permission to resume. Wait for our request result.
                return
            case .malformedRouteChange, .unsupportedSystemMessage:
                return
            }
            updateState()
            try startIfReady()
        } catch { fail(error) }
    }

    func close() {
        guard state != .closed else { return }
        state = .closed
        policy.apply(.lost)
        seekID = nil
        activationRequest = nil
        seekTask?.cancel()
        seekTask = nil
        session.close()
        if ownsActivation { activation.close() }
        else { _ = try? activation.request(active: false) }
        onChange?()
    }

    private func applyRewind(_ transition: PlaybackFocusPolicy.Transition) throws {
        guard transition.rewindAfterTransientLoss else { return }
        let position = try session.positionMilliseconds
        let eventTime = now()
        try session.pause()
        let id = UUID()
        seekID = id
        let previous = seekTask
        let session = session
        seekTask = Task { @MainActor [weak self] in
            do {
                try await withTaskCancellationHandler {
                    // Position persistence may still be queued by the preceding interruption.
                    // Keep its timestamp authoritative and never resume before that work settles.
                    try await session.synchronizeStatistics()
                    try Task.checkCancellation()
                    guard self?.seekID == id else { return }
                    if let target = transition.rewindPosition(positionMilliseconds: position,
                        lastPlayedMilliseconds: session.lastPlayedMilliseconds, nowMilliseconds: eventTime) {
                        previous?.cancel()
                        try await session.seekPaused(to: target)
                    } else {
                        // Readiness alone must not discard an in-flight initial prepare/seek.
                        // Await it without issuing another Play or rebuilding a no-op target.
                        try await previous?.value
                    }
                    try Task.checkCancellation()
                    guard let self, self.seekID == id, self.state != .closed else { return }
                    self.seekID = nil
                    self.seekTask = nil
                    self.updateState()
                    try self.startIfReady()
                } onCancel: { previous?.cancel() }
            } catch {
                previous?.cancel()
                if let self, self.seekID == id, self.state != .closed { self.fail(error) }
                throw error
            }
        }
    }

    private func activationFinished(_ result: AudioSessionActivationController.Result) {
        guard result.requestID == activationRequest, state != .closed, state != .failed else { return }
        activationRequest = nil
        guard result.outcome == .applied else {
            // An interruption may invalidate activation while retaining future play intent.
            if interruptionPending { updateState(); return }
            if result.active && result.outcome == .declined {
                // Media3's failed focus request clears playWhenReady; it is not a decoder
                // failure. Keep preparation/media available for a later explicit Play.
                policy.apply(.lost)
                do { try session.pause(); updateState() } catch { fail(error) }
                return
            }
            fail(result.error ?? Failure.activationDeclined)
            return
        }
        updateState()
        do { try startIfReady() } catch { fail(error) }
    }

    private func startIfReady() throws {
        guard state != .closed && state != .failed && state != .requiresRebuild,
              policy.playWhenReady && !policy.suppressed, activationRequest == nil,
              activation.knownActive == true, seekID == nil else { return }
        try session.play()
        state = .playing
        onChange?()
    }

    private func updateState() {
        guard state != .closed && state != .failed && state != .requiresRebuild else { return }
        if seekID != nil { state = .seeking }
        else if policy.suppressed { state = .interrupted }
        else if policy.playWhenReady { state = .activating }
        else { state = .paused }
        onChange?()
    }

    private func validate() throws {
        guard state != .closed else { throw Failure.closed }
        guard state != .requiresRebuild else { throw Failure.rebuildRequired }
        if let failure { throw failure }
    }

    private func fail(_ error: any Error) {
        guard state != .closed else { return }
        failure = error
        state = .failed
        seekID = nil
        seekTask?.cancel()
        seekTask = nil
        policy.apply(.lost)
        try? session.pause()
        activationRequest = try? activation.request(active: false)
        onChange?()
    }
}
