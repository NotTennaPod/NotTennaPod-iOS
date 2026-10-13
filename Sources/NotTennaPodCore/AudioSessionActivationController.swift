import Foundation
#if os(iOS)
import AVFAudio
#endif

@MainActor protocol AudioSessionActivationDriver: AnyObject {
    func prepareForActivation() throws
    func setActive(_ active: Bool) async throws -> Bool
}

extension AudioSessionActivationDriver {
    func prepareForActivation() throws {}
}

/// The app's one owner of audio-session activation. Every engine (processed and AVPlayer) holds a
/// claim through an `AudioSessionActivationController`, and the application engine holds one more that
/// keeps the session while one item replaces another. The owner makes the OS activate/deactivate calls
/// one at a time and is itself responsible for every activation it applied or has in flight: the session
/// stays active while any live claim wants it (or holds it, for an item replacement), and is released
/// once none does. A retired engine's release therefore never stops a newer engine; a release already
/// in flight is followed by the newer engine's activation; a claim closed before its request reached
/// the OS cannot leave an inherited or in-flight activation behind. An obsolete operation may still
/// finish: the owner reconciles with current intent before answering and never answers a superseded
/// request with success. A claim that never used the session releases nothing.
///
/// System interruptions and media-services events stay authoritative. The app's own deactivation
/// notification is not forwarded: every app deactivation is the owner's (its result is already known),
/// and the notification can arrive after a newer activation for another engine.
///
/// The session is released when playback stops for good (end of queue, stop, close, failure), not on
/// pause or between items, as Media3 keeps audio focus while its player is paused or changes items.
/// Holding it holds no resources: iOS still suspends the app when nothing plays.
@MainActor final class AudioSessionOwner {
    typealias EventSourceFactory = @MainActor (@escaping @MainActor (AudioSessionEvent) -> Void) -> AudioSessionEventSource
#if os(iOS)
    static let shared = AudioSessionOwner(driver: NativeAudioSessionActivationDriver(),
        events: { AudioSessionEventSource.system(handler: $0) })
#else
    /// Host builds have no OS audio session.
    static let shared = AudioSessionOwner(driver: UnmanagedAudioSessionDriver())
#endif

    @MainActor final class Claim {
        /// `hold` keeps a session the owner already has (an item replacement) and never activates one.
        enum Desire { case none, hold, active }
        struct Request {
            let id = UUID()
            let desire: Desire
            let prepare: Bool
            var prepared = false
            var active: Bool { desire == .active }
        }
        /// The latest request not yet answered.
        fileprivate var pending: Request?
        fileprivate var desire = Desire.none
        fileprivate var closed = false
        /// The claimant has asked for the session to be active: its explicit release still reaches the OS
        /// when the owner cannot know the session is inactive (a declined or failed activation, a
        /// media-services reset).
        fileprivate var asked = false
        /// An OS call was made (or an activation applied) for this claim.
        fileprivate var operated = false
        fileprivate var onResult: (@MainActor (AudioSessionActivationController.Result) -> Void)?
        fileprivate var onSystemEvent: (@MainActor (AudioSessionEvent) -> Void)?
    }

    private(set) var actual: Bool?
    /// No request or OS call is outstanding (a barrier for tests).
    var isIdle: Bool { task == nil }
    /// The owner applied an activation (or has one in flight) that it has not released.
    private var owned = false
    /// Counts closes that handed the owner a session it cannot know is inactive, so a result arriving
    /// after such a close cannot clear that responsibility.
    private var handovers = 0
    private let driver: any AudioSessionActivationDriver
    private var events: AudioSessionEventSource?
    private var observationID = UUID()
    private var claims: [Claim] = []
    private var task: Task<Void, Never>?

    init(driver: any AudioSessionActivationDriver, events: EventSourceFactory? = nil) {
        self.driver = driver
        if let events { self.events = events { [weak self] event in self?.receive(event) } }
    }

    isolated deinit { events?.close() }

    fileprivate func makeClaim() -> Claim {
        claims.removeAll(where: \.closed)
        let claim = Claim()
        claims.append(claim)
        return claim
    }

    fileprivate func request(_ claim: Claim, _ desire: Claim.Desire, prepare: Bool) -> UUID {
        let request = Claim.Request(desire: desire, prepare: prepare)
        claim.pending = request
        claim.desire = desire
        if desire == .active { claim.asked = true }
        start()
        return request.id
    }

    /// Closing withdraws the claim's interest and suppresses its callbacks. Responsibility for any
    /// activation stays with the owner, which releases it once no live claim wants it; a claim that used
    /// the session also hands over one the owner cannot know is inactive. A claim that never used the
    /// session releases nothing.
    fileprivate func close(_ claim: Claim) {
        guard !claim.closed else { return }
        if claim.operated && actual != false { owned = true; handovers += 1 }
        claim.closed = true
        claim.onResult = nil
        claim.onSystemEvent = nil
        claim.pending = nil
        claim.desire = .none
        start()
    }

    /// Session notifications are newer evidence than the cached state; returns whether claimants should
    /// see the event. A resumption recommendation is deliberately not evidence of activation.
    @discardableResult func observe(_ event: AudioSessionEvent) -> Bool {
        switch event {
        case .becameActive: actual = true
        case .interrupted: actual = false
        // The services restarted: the owner's activations did not survive (a claimant that used the
        // session may still release it explicitly or when it closes).
        case .mediaServicesLost, .mediaServicesReset: actual = nil; owned = false
        case .appDeactivated: return false
        default: return true
        }
        observationID = UUID()
        return true
    }

    private func receive(_ event: AudioSessionEvent) {
        guard observe(event) else { return }
        for claim in claims where !claim.closed { claim.onSystemEvent?(event) }
    }

    private func answer(_ claim: Claim, _ request: Claim.Request, _ outcome: AudioSessionActivationController.Outcome, _ error: (any Error)? = nil) {
        guard claim.pending?.id == request.id else { return }
        claim.pending = nil
        if outcome != .applied, claim.desire == request.desire { claim.desire = .none }
        guard !claim.closed else { return }
        claim.onResult?(.init(requestID: request.id, active: request.active, outcome: outcome, error: error))
    }

    private func start() {
        guard task == nil else { return }
        // Retains the owner (not the engines) until every in-flight OS call is reconciled.
        task = Task { @MainActor [self] in
            defer { task = nil }
            await run()
        }
    }

    private func run() async {
        while true {
            let live = claims.filter { !$0.closed }
            // Holding has no OS effect: answer it at once.
            if let claim = live.first(where: { $0.pending?.desire == .hold }), let request = claim.pending {
                answer(claim, request, .applied); continue
            }
            if live.contains(where: { $0.desire == .active }) {
                // Configuration first, for each request that asks for it. It may synchronously deliver a
                // system event or a newer request: re-evaluate before touching OS activation.
                if let claim = live.first(where: { $0.pending.map { $0.active && $0.prepare && !$0.prepared } == true }),
                   var request = claim.pending {
                    do { try driver.prepareForActivation() }
                    catch { answer(claim, request, .failed, error); continue }
                    request.prepared = true
                    if claim.pending?.id == request.id { claim.pending = request }
                    continue
                }
                let asked = live.compactMap { claim in claim.pending.flatMap { $0.active ? (claim, $0) : nil } }
                // A release by another live claim is moot while this one wants the session.
                let moot = live.compactMap { claim in claim.pending.flatMap { $0.active ? nil : (claim, $0) } }
                for (claim, request) in moot { answer(claim, request, .applied) }
                // Only a request activates: a wanted session lost to the system (an interruption) waits for one.
                guard !asked.isEmpty else { if moot.isEmpty { break } else { continue } }
                owned = true
                for (claim, _) in asked { claim.operated = true }
                if actual == true {
                    for (claim, request) in asked { answer(claim, request, .applied) }
                    continue
                }
                let handoversBeforeCall = handovers
                let outcome = await perform(true)
                for (claim, request) in asked { answer(claim, request, outcome.0, outcome.1) }
                if outcome.0 == .declined && handovers == handoversBeforeCall { owned = false }
                continue
            }
            // No live claim wants the session. Releases are moot while a live claim holds one we have.
            let releases = live.compactMap { claim in claim.pending.map { (claim, $0) } }
            if owned && live.contains(where: { $0.desire == .hold }) {
                for (claim, request) in releases { answer(claim, request, .applied) }
                break
            }
            // The owner releases its own activation. A claimant that asked for the session may also release
            // one the owner cannot know is inactive; a claim that never asked releases nothing.
            guard owned || releases.contains(where: { $0.0.asked }) else {
                for (claim, request) in releases { answer(claim, request, .applied) }
                break
            }
            if actual == false {
                owned = false
                for (claim, request) in releases { answer(claim, request, .applied) }
                continue
            }
            for (claim, _) in releases { claim.operated = true }
            let handoversBeforeCall = handovers
            let outcome = await perform(false)
            if handovers == handoversBeforeCall { owned = false }
            for (claim, request) in releases { answer(claim, request, outcome.0, outcome.1) }
        }
        claims.removeAll(where: \.closed)
    }

    /// One OS call. An observation made meanwhile is newer evidence than its result.
    private func perform(_ active: Bool) async -> (AudioSessionActivationController.Outcome, (any Error)?) {
        let observedBeforeCall = observationID
        do {
            let applied = try await driver.setActive(active)
            if observationID == observedBeforeCall { actual = applied ? active : nil }
            return (applied && actual == active ? .applied : .declined, nil)
        } catch {
            if observationID == observedBeforeCall { actual = nil }
            return (.failed, error)
        }
    }
}

/// One engine's claim on the app's audio session (`AudioSessionOwner`). Results arrive asynchronously,
/// after the request returns. A controller made from a driver has an owner of its own.
@MainActor final class AudioSessionActivationController {
    enum Failure: Error { case closed }
    enum Outcome: Equatable, Sendable { case applied, declined, failed }
    struct Result: Sendable {
        let requestID: UUID
        let active: Bool
        let outcome: Outcome
        let error: (any Error)?
    }
    var onResult: (@MainActor (Result) -> Void)? {
        get { claim.onResult }
        set { if !claim.closed { claim.onResult = newValue } }
    }
    /// System events the owner observed itself (an owner with its own event source), for this claimant.
    var onSystemEvent: (@MainActor (AudioSessionEvent) -> Void)? {
        get { claim.onSystemEvent }
        set { if !claim.closed { claim.onSystemEvent = newValue } }
    }
    var knownActive: Bool? { owner.actual }
    private let owner: AudioSessionOwner
    private let claim: AudioSessionOwner.Claim

    convenience init(driver: any AudioSessionActivationDriver) {
        self.init(owner: AudioSessionOwner(driver: driver))
    }

    init(owner: AudioSessionOwner) {
        self.owner = owner
        claim = owner.makeClaim()
    }

    /// `prepare: false` for a claimant that configures the session category itself.
    @discardableResult func request(active: Bool, prepare: Bool = true) throws -> UUID {
        guard !claim.closed else { throw Failure.closed }
        return owner.request(claim, active ? .active : .none, prepare: prepare)
    }

    /// Keeps the session through an item replacement if the owner has it; never activates one. A later
    /// `request(active: false)` or `close()` ends the hold.
    @discardableResult func hold() throws -> UUID {
        guard !claim.closed else { throw Failure.closed }
        return owner.request(claim, .hold, prepare: false)
    }

    /// Feeds a system event observed by this claimant's engine to the owner; returns whether the
    /// claimant should act on it (the app's own deactivation is never forwarded).
    @discardableResult func receive(_ event: AudioSessionEvent) -> Bool {
        guard !claim.closed else { return false }
        return owner.observe(event)
    }

    /// Withdraws this claim and suppresses its callbacks; the owner releases the session (compensating a
    /// pending activation) once no live claim wants it. Request deactivation first when errors matter.
    func close() { owner.close(claim) }
    isolated deinit { owner.close(claim) }
}

/// The host build's stand-in: there is no OS audio session to activate.
@MainActor final class UnmanagedAudioSessionDriver: AudioSessionActivationDriver {
    func setActive(_ active: Bool) async throws -> Bool { true }
}

#if os(iOS)
/// The engine's single session driver. Construction has no effects; each Play checks the
/// actual profile so media-service resets or external changes cannot leave a stale cache.
@MainActor final class NativeAudioSessionActivationDriver: AudioSessionActivationDriver {
    private let session: AVAudioSession
    init(session: AVAudioSession = .sharedInstance()) { self.session = session }
    func prepareForActivation() throws {
        guard session.category != .playback || session.mode != .spokenAudio
            || session.routeSharingPolicy != .longFormAudio || !session.categoryOptions.isEmpty else { return }
        try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio, options: [])
    }
    func setActive(_ active: Bool) async throws -> Bool {
        if active { return try await session.activate(options: []) }
        return try await session.deactivate(options: [.notifyOthersOnDeactivation])
    }
}
#endif
