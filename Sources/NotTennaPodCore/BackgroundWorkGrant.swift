import Foundation
import os

/// The system's background time as the grant sees it: UIKit's background task in the app (`UIKitBackgroundTime`), a
/// fake in tests.
@MainActor public protocol BackgroundTimeProviding: AnyObject {
    /// No scene of the app is in the foreground.
    var isInBackground: Bool { get }
    /// Asks the system for background time; nil when it refuses. `expired` runs on the main actor when the system ends
    /// the time.
    func begin(expired: @escaping @MainActor () -> Void) -> Int?
    /// Gives back the time `begin` returned; `expired` when the system's expiration ended it.
    func end(_ grant: Int, expired: Bool)
}

/// Bounded platform adaptation: Android's WorkManager keeps running downloads, a pending synchronization, a refresh
/// and an import or export after the app leaves the foreground. iOS gives a backgrounded app a short grant of time.
/// While the app is in the background, work that needs the app process (sync, foreground-engine downloads and the
/// bookkeeping of finished background transfers, a manual refresh, the automatic backup, a database import, an export)
/// holds one grant: the first participant with work asks for it, the others join it, and it is given back as soon as
/// nothing needs the process any more. When the time ends (expired, or refused), the grant is given back at once and
/// exactly once, and every participant parks: it stops cleanly and keeps its durable state (the outbox and the sync
/// request, a partial download for Range resume, the saved refresh request, a due backup), and resumes when the app is
/// active again. Time that ran out is never renewed by work that starts later in the same background period; it parks
/// at once instead. Nothing keeps the app awake. Transfers in the background URLSession continue in the system
/// regardless of this grant.
@MainActor public final class BackgroundWorkGrant {
    /// One kind of work that holds the grant while it has work.
    public struct Participant {
        public var hasWork: @MainActor () -> Bool
        /// The time ended: stop at once, keeping durable state. Called on every participant, with work or not.
        public var park: @MainActor () -> Void
        /// The app left the foreground (true) or a scene became active (false).
        public var changed: (@MainActor (_ background: Bool) -> Void)?
        /// The work runs now under an execution window of its own (a server exchange in its `BGTask`): it needs no grant
        /// and the grant's end, refusal or exhaustion never parks it; its own window's expiration does.
        public var ownTime: (@MainActor () -> Bool)?

        public init(hasWork: @escaping @MainActor () -> Bool, park: @escaping @MainActor () -> Void,
                    changed: (@MainActor (_ background: Bool) -> Void)? = nil, ownTime: (@MainActor () -> Bool)? = nil) {
            self.hasWork = hasWork; self.park = park; self.changed = changed; self.ownTime = ownTime
        }

        @MainActor var coveredElsewhere: Bool { ownTime?() ?? false }
    }

    /// A participant that joined for one piece of work (an import, an export); `leave` (or the end of the membership)
    /// ends it.
    @MainActor public final class Membership {
        fileprivate weak var grant: BackgroundWorkGrant?
        fileprivate let id: UUID
        fileprivate init(grant: BackgroundWorkGrant, id: UUID) { self.grant = grant; self.id = id }
        public func leave() { grant?.leave(id); grant = nil }
        isolated deinit { leave() }
    }

    private let time: any BackgroundTimeProviding
    private var participants: [(id: UUID, participant: Participant)] = []
    private var held: Int?
    /// Which grant is held: an expiration from an earlier grant never ends a newer one.
    private var generation = 0
    private var heldGeneration = 0
    /// The time of this background period ran out (or was refused): later work parks instead of asking again, until a
    /// scene becomes active or the system gives the app new time.
    public private(set) var isExhausted = false
    private var watcher: Task<Void, Never>?
    private let pollInterval: Duration

    public init(time: any BackgroundTimeProviding, participants: [Participant] = [], pollInterval: Duration = .seconds(1)) {
        self.time = time; self.pollInterval = pollInterval
        self.participants = participants.map { (UUID(), $0) }
    }

    /// Whether the grant holds background time now.
    public var isHeld: Bool { held != nil }

    /// Adds a participant for the app's lifetime.
    public func add(_ participant: Participant) { participants.append((UUID(), participant)) }

    /// Joins `participant` for one piece of work that starts now: in the background it shares the held grant, asks
    /// for one, or parks at once when the time ran out or is refused.
    public func join(_ participant: Participant) -> Membership {
        let id = UUID()
        participants.append((id, participant))
        workStarted()
        return Membership(grant: self, id: id)
    }

    private func leave(_ id: UUID) {
        participants.removeAll { $0.id == id }
        workChanged()
    }

    /// The last scene left the foreground, or the system launched or woke the app for background events
    /// (`freshTime`: the system gave the app new time, so time that ran out earlier no longer counts).
    public func enterBackground(freshTime: Bool = false) {
        if freshTime { isExhausted = false }
        for entry in participants { entry.participant.changed?(true) }
        acquireIfNeeded()
    }

    /// A scene became active: the work runs in the foreground again and the grant is given back.
    public func enterForeground() {
        isExhausted = false
        for entry in participants { entry.participant.changed?(false) }
        release(expired: false)
    }

    /// A participant started work: in the background it joins the grant (or parks when there is no time).
    public func workStarted() {
        guard time.isInBackground else { return }
        acquireIfNeeded()
    }

    /// A participant's work ended: the grant is given back as soon as nothing needs the process.
    public func workChanged() {
        guard held != nil, !hasWork else { return }
        release(expired: false)
    }

    private var hasWork: Bool { participants.contains { $0.participant.hasWork() && !$0.participant.coveredElsewhere } }

    private func acquireIfNeeded() {
        guard held == nil, hasWork else { return }
        // Time that ran out is never renewed by work that starts later in the same period.
        guard !isExhausted else { parkAll(); return }
        generation += 1
        let current = generation
        guard let grant = time.begin(expired: { [weak self] in self?.expired(current) }) else {
            // Refused: the app gets no time now, so the work parks as at expiration.
            isExhausted = true
            parkAll()
            return
        }
        held = grant
        heldGeneration = current
        let interval = pollInterval
        watcher = Task { [weak self] in
            // A grant is given back as soon as nothing needs the process any more.
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, self.held != nil else { return }
                self.workChanged()
            }
        }
    }

    /// The system's expiration: every participant parks and the grant is given back at once, exactly once, whatever
    /// the work still has to wind down.
    private func expired(_ expiring: Int) {
        guard expiring == heldGeneration, let grant = held else { return }
        held = nil
        watcher?.cancel(); watcher = nil
        isExhausted = true
        parkAll()
        time.end(grant, expired: true)
    }

    private var parking = false
    private func parkAll() {
        // A participant that parks may report its change; parking is not started again from inside.
        guard !parking else { return }
        parking = true
        defer { parking = false }
        // Work running under its own execution window keeps it.
        for entry in participants where !entry.participant.coveredElsewhere { entry.participant.park() }
    }

    private func release(expired: Bool) {
        watcher?.cancel(); watcher = nil
        guard let grant = held else { return }
        held = nil
        time.end(grant, expired: expired)
    }
}

extension BackgroundWorkGrant.Participant {
    /// A server library's exchange: a push waiting or an exchange running holds the grant; parked, it stops
    /// cleanly (everything is resumable). While it runs in a server-sync background task of its own (`inWindow`), the
    /// grant neither covers nor parks it: that task's expiration does.
    public static func serverSync(_ scheduler: @escaping @MainActor () -> ServerSyncScheduler?,
                                  inWindow: @escaping @MainActor () -> Bool) -> Self {
        .init(hasWork: { scheduler()?.hasPendingWork == true },
              park: { scheduler()?.suspendForBackground() },
              changed: { background in scheduler()?.setExpedited(background) },
              ownTime: inWindow)
    }

    /// A manual refresh (pull to refresh, the Refresh shortcut, the refresh after an OPML import) holds the grant while
    /// it runs, as Android's FeedUpdateWorker keeps running. Parked, it stops at once and keeps its saved request,
    /// and requests made before the app is active again wait with it; its feeds in flight end as cancelled, which marks
    /// no podcast as failed and writes no failure to the log. It runs again when the app is active (`resume`).
    public static func manualRefresh(_ refresh: @escaping @MainActor () -> ManualFeedRefreshCoordinator?) -> Self {
        .init(hasWork: {
            if case .active? = refresh()?.state { true } else { false }
        }, park: {
            guard let owner = refresh() else { return }
            if case .active = owner.state {
                Logger(subsystem: "org.nottennapod.app", category: "Refresh")
                    .notice("Refresh interrupted by the end of background time; it runs again when the app is active")
            }
            owner.suspend()
        })
    }
}
