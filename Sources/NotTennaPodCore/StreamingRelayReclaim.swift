import Foundation
import Synchronization

/// Something that reads through a loopback `NativeStreamingRelay` iOS may reclaim.
protocol StreamingRelayReclaimParticipant: AnyObject, Sendable {
    /// The registry's lifecycle changed, or the participant registered. The participant
    /// reconciles with the registry's current `lifecycle`, read inside its own transition, and
    /// applies each epoch once: when suspended it closes the relay's listener and every
    /// connection, keeping cursors and buffered bytes, and opens nothing until a newer epoch
    /// that is not suspended (a demand) starts a new listener. A delayed notification therefore
    /// never undoes a newer one. Called on the caller's thread, never under the registry's lock.
    func reclaimLifecycleChanged()
#if DEBUG
    /// Test hook: iOS closes the relay's listener and connections without notice.
    func simulateSocketReclaim()
    /// Test view: the relay is retired (no listener).
    var isRelayRetired: Bool { get }
#endif
}
#if DEBUG
extension StreamingRelayReclaimParticipant {
    func simulateSocketReclaim() {}
    var isRelayRetired: Bool { false }
}
#endif

/// The loopback relays of streamed playback, closed when the app may be suspended and
/// rebuilt on the next demand (Apple TN2277; DTS: close listeners when you become
/// eligible for suspension, reopen them on return). Nothing here keeps the app awake.
public final class StreamingRelayReclaim: Sendable {
    public static let shared = StreamingRelayReclaim()
    private final class Entry: @unchecked Sendable { weak var participant: (any StreamingRelayReclaimParticipant)? }
    private struct State {
        var suspended = false
        var epoch: UInt64 = 0
        var suspensions: UInt64 = 0
        var entries: [ObjectIdentifier: Entry] = [:]
        mutating func live() -> [any StreamingRelayReclaimParticipant] {
            entries = entries.filter { $0.value.participant != nil }
            return entries.values.compactMap(\.participant)
        }
    }
    private let state = Mutex(State())
    public init() {}

    /// The authoritative state participants reconcile with. The epoch advances at every
    /// suspension and every demand; ending a suspension without a demand keeps it, so
    /// retired relays stay closed until something needs them.
    struct Lifecycle: Equatable, Sendable { let suspended: Bool; let epoch: UInt64 }
    var lifecycle: Lifecycle { state.withLock { Lifecycle(suspended: $0.suspended, epoch: $0.epoch) } }
    /// New relays start retired until the next demand.
    public var isSuspended: Bool { state.withLock { $0.suspended } }
    /// Advances at every suspension and every demand: a relay is repaired after a
    /// local connection failure at most once per epoch until it makes progress.
    var epoch: UInt64 { state.withLock { $0.epoch } }
    /// Advances at every suspension: a relay started before the latest one is not trusted.
    var suspensions: UInt64 { state.withLock { $0.suspensions } }

    /// The app became eligible for suspension: retire every relay.
    public func suspend() {
        let participants = state.withLock { state -> [any StreamingRelayReclaimParticipant] in
            guard !state.suspended else { return [] }
            state.suspended = true; state.epoch &+= 1; state.suspensions &+= 1
            return state.live()
        }
        deliver(participants)
    }

    /// No longer eligible (a scene came to the foreground) without a demand: new relays
    /// start normally; retired ones stay closed until something needs them.
    public func endSuspension() { state.withLock { $0.suspended = false } }

    /// Play, seek or a refill of playback the person asked for: rebuild every retired relay.
    public func demand() {
        let participants = state.withLock { state -> [any StreamingRelayReclaimParticipant] in
            state.suspended = false; state.epoch &+= 1
            return state.live()
        }
        deliver(participants)
    }

    /// The participant reconciles at once: one registered while suspended starts retired.
    func register(_ participant: any StreamingRelayReclaimParticipant) {
        let entry = Entry(); entry.participant = participant
        state.withLock { state in
            _ = state.live()
            state.entries[ObjectIdentifier(participant)] = entry
        }
        deliver([participant])
    }

    private func deliver(_ participants: [any StreamingRelayReclaimParticipant]) {
#if DEBUG
        beforeDelivery.withLock { $0 }?()
#endif
        for participant in participants { participant.reclaimLifecycleChanged() }
    }

    func unregister(_ participant: any StreamingRelayReclaimParticipant) {
        _ = state.withLock { $0.entries.removeValue(forKey: ObjectIdentifier(participant)) }
    }
#if DEBUG
    /// Test hook: runs after a lifecycle change is committed and before participants hear of it,
    /// where another change can overtake the delivery.
    let beforeDelivery = Mutex<(@Sendable () -> Void)?>(nil)
    /// Test hook: closes every registered relay's listener and connections as iOS would.
    func simulateSocketReclaim() {
        for participant in state.withLock({ $0.live() }) { participant.simulateSocketReclaim() }
    }
    var participantCount: Int { state.withLock { $0.live().count } }
    var retiredRelayCount: Int { state.withLock { $0.live() }.filter(\.isRelayRetired).count }
#endif
}

/// The app's own loopback relay could not be reached, even after it was rebuilt.
/// Retried like a dropped connection; never a problem with the media or its download.
public struct StreamingRelayUnavailable: LocalizedError, CustomNSError {
    /// The error's description, which a failed playback reports as its details.
    public static let message = "The connection to the stream inside the app was lost."
    let underlying: URLError
    public var errorDescription: String? { Self.message }
    public var errorUserInfo: [String: Any] { [NSUnderlyingErrorKey: underlying, NSLocalizedDescriptionKey: Self.message] }
}

/// Which explanation a failed playback shows above its details: a failure of the app's own
/// relay never advises deleting and re-downloading the episode.
public enum PlaybackFailureExplanation: Sendable {
    case generic, tryAgain
    public init(details: String) { self = details == StreamingRelayUnavailable.message ? .tryAgain : .generic }
    /// The localized string's key.
    public var key: String { self == .tryAgain ? "playback_error_try_again" : "playback_error_generic" }
}

/// The app's one suspension-eligibility and demand state for streaming relays:
/// eligible when no scene is in the foreground and no audio is playing or preparing for
/// playback the person asked for (paused, stopped, interrupted, ended, sleep-timer stop),
/// including a pause that starts while already in the background. A Lock Screen or
/// remote Play is a demand even when no scene becomes active.
@MainActor public final class StreamingRelayEligibility {
    private let reclaim: StreamingRelayReclaim
    public private(set) var isForeground = false
    public private(set) var isPlaybackActive = false
    public var isEligible: Bool { !isForeground && !isPlaybackActive }

    public init(reclaim: StreamingRelayReclaim = .shared) { self.reclaim = reclaim }

    /// Any connected scene is in the foreground (active or inactive).
    public func setForeground(_ foreground: Bool) {
        isForeground = foreground
        update(demand: false)
    }

    /// Playback wants to play, or is preparing or buffering for playback the person asked
    /// for. Working audio counts by intent, never by an instantaneous rate of zero.
    public func setPlaybackActive(_ active: Bool) {
        let started = active && !isPlaybackActive
        isPlaybackActive = active
        update(demand: started)
    }

    private func update(demand: Bool) {
        if isEligible { reclaim.suspend() }
        else if demand { reclaim.demand() }
        else { reclaim.endSuspension() }
    }
}
