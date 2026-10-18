import Foundation

/// Keeps one screen's library current from the committed change sets of its library (`LibraryChangeHub`), patch by patch,
/// instead of reading the whole library after every change.
///
/// - Delivery never pauses: every set after the screen's covered sequence is kept. Presentation (a read and a patch) runs
///   only while the screen is active; in the background the sets accumulate and are applied once at activation.
/// - Each patch reads, in one read transaction, everything the pending sets named, and is applied only when that
///   transaction saw exactly the commits delivered so far (its sequence equals the last pending set's): a snapshot that
///   already contains a later commit is read again once that commit is delivered, so no mixture of states is ever shown.
/// - What is shown always covers a contiguous prefix of the library's commits (`covered`). Local sets are applied at once,
///   together with any held sync sets; a patch of sync sets only is started at most once per `syncPacing`.
/// - `settle(receipt:)` waits until the screen covers a write's receipt (`LibraryChangeHub.emitted` read right after it).
/// - A screen open (a full read) stops patching until `opened(at:)` gives the sequence it read at.
@MainActor public final class LibraryScreenUpdater {
    public enum Settled: Equatable, Sendable { case settled, deferred, cancelled }

    public struct Configuration: Sendable {
        public var syncPacing: Duration = .seconds(1)
        public var raceRetry: Duration = .milliseconds(50)
        public var errorRetry: Duration = .seconds(2)
        public var maximumRaces = 3
        public var maximumErrors = 3
        public init() {}
    }

    /// What the updater did, for budgets and tests.
    public struct Metrics: Equatable, Sendable {
        public var reads = 0
        public var patches = 0
        public var reopens = 0
        public var races = 0
        public var errors = 0
        public var discarded = 0
    }

    public let identity: LibraryChangeHub.Identity
    public private(set) var covered: Int64
    public private(set) var delivered: Int64
    public private(set) var metrics = Metrics()
    public var configuration: Configuration

    /// The request bringing the screen up to date after the given sets, or nil when the screen should open again instead
    /// (more changed than a patch is worth).
    public var request: ([LibraryChangeSet]) -> LibraryMirrorRequest? = { _ in nil }
    public var read: @Sendable (LibraryMirrorRequest) async throws -> LibraryMirrorRead = { _ in throw CancellationError() }
    public var apply: (LibraryMirrorRead) -> Void = { _ in }
    /// Asks the screen to open again (it calls `beginOpen` and later `opened(at:)`).
    public var reopen: () -> Void = {}
    public var failed: (any Error) -> Void = { _ in }
    public var isActive: () -> Bool = { true }
    public var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

#if DEBUG
    /// Test-only mutations (`LibraryScreenMutationTests`). `applyMixedReads`: a read is applied whatever sequence it saw.
    /// `dropDuringOpen`: sets delivered while the screen opens are dropped. `settleEarly`: settle returns at once.
    /// `paceLocal`: local sets wait for the sync pacing. `dropOvertakenSync`: sync sets held by the pacing are dropped
    /// when a local set overtakes them.
    enum Fault: Hashable, Sendable { case applyMixedReads, dropDuringOpen, settleEarly, paceLocal, dropOvertakenSync }
    var faults: Set<Fault> = []
#endif
    private var pending: [LibraryChangeSet] = []
    private var listener: Task<Void, Never>?
    private var running: Task<Void, Never>?
    private var pacing: Task<Void, Never>?
    private var lastSyncPatch: ContinuousClock.Instant?
    private var opening = 0
    /// A reopen was asked for the pending sets: nothing is patched until the open begins or another set arrives.
    private var awaitingOpen = false
    private var generation = 0
    private var failures = 0
    /// The configured read attempts failed: nothing is patched until a new delivery, an activation or an open.
    private var parked = false
    private var failureShown = false
    private var stopped = false
    private var waiters: [(receipt: Int64, continuation: CheckedContinuation<Settled, Never>)] = []
    private var deliveryWaiters: [CheckedContinuation<Void, Never>] = []

    public init(subscription: LibraryChangeHub.Subscription, configuration: Configuration = .init()) {
        identity = subscription.identity
        covered = subscription.baseline
        delivered = subscription.baseline
        self.configuration = configuration
        let changes = subscription.changes
        listener = Task { [weak self] in
            for await set in changes {
                guard let self else { return }
                self.receive(set)
            }
        }
    }

    /// The sets not yet shown.
    public var pendingCount: Int { pending.count }

    public func stop() {
        stopped = true
        listener?.cancel(); running?.cancel(); pacing?.cancel()
        listener = nil; running = nil; pacing = nil
        resumeWaiters(all: .cancelled)
        wakeDeliveryWaiters()
    }

    isolated deinit { listener?.cancel(); running?.cancel(); pacing?.cancel() }

    // MARK: - Delivery

    func receive(_ set: LibraryChangeSet) {
        guard !stopped, set.identity == identity else { return }
        delivered = max(delivered, set.sequence)
        wakeDeliveryWaiters()
        guard set.sequence > covered else { return }
#if DEBUG
        if faults.contains(.dropDuringOpen), opening > 0 { return }
#endif
        pending.append(set)
        awaitingOpen = false
        unpark()
        schedule()
    }

    // MARK: - Opens

    /// A full read of the screen begins: no patch starts, and a running one is not applied.
    public func beginOpen() {
        awaitingOpen = false
        unpark()
        opening += 1
        generation += 1
    }

    /// The full read was applied, at `sequence` (nil: it failed, and the screen keeps what it showed).
    public func opened(at sequence: Int64?) {
        opening = max(0, opening - 1)
        if let sequence {
            covered = max(covered, sequence)
            pending.removeAll { $0.sequence <= covered }
            resumeWaiters()
        }
        schedule()
    }

    // MARK: - Activation

    /// The screen became active: what accumulated is applied once.
    public func activate() { unpark(); schedule() }

    /// Read attempts start again after a trigger (a delivery, an activation, an open).
    private func unpark() {
        guard parked else { return }
        parked = false
        failures = 0
    }

    /// The screen went to the background: waiters are told the screen will catch up later.
    public func deactivate() {
        pacing?.cancel(); pacing = nil
        resumeWaiters(all: .deferred)
    }

    // MARK: - Settle

    /// Returns once the screen covers `receipt`; `.deferred` at once for a screen in the background, `.cancelled` when the
    /// updater stops first.
    public func settle(receipt: Int64) async -> Settled {
#if DEBUG
        if faults.contains(.settleEarly) { return .settled }
#endif
        if covered >= receipt { return .settled }
        if stopped { return .cancelled }
        if !isActive() { return .deferred }
        return await withCheckedContinuation { continuation in
            waiters.append((receipt, continuation))
            schedule()
        }
    }

    private func resumeWaiters(all value: Settled? = nil) {
        var kept: [(receipt: Int64, continuation: CheckedContinuation<Settled, Never>)] = []
        for waiter in waiters {
            if waiter.receipt <= covered { waiter.continuation.resume(returning: .settled) }
            else if let value { waiter.continuation.resume(returning: value) }
            else { kept.append(waiter) }
        }
        waiters = kept
    }

    // MARK: - Patching

    private func schedule() {
        guard !stopped, opening == 0, !awaitingOpen, !parked, running == nil, !pending.isEmpty, isActive() else { return }
        var local = pending.contains { $0.origin == .local } || !waiters.isEmpty
#if DEBUG
        if faults.contains(.paceLocal) { local = false }
#endif
        if !local, let last = lastSyncPatch {
            let wait = configuration.syncPacing - last.duration(to: .now)
            if wait > .zero {
                guard pacing == nil else { return }
                let sleep = sleep
                pacing = Task { [weak self] in
                    do { try await sleep(wait) } catch { return }
                    guard let self else { return }
                    self.pacing = nil
                    self.schedule()
                }
                return
            }
        }
        pacing?.cancel(); pacing = nil
#if DEBUG
        if faults.contains(.dropOvertakenSync), pending.contains(where: { $0.origin == .local }), let last = pending.last?.sequence {
            pending.removeAll { $0.origin == .sync && $0.sequence < last }
        }
#endif
        running = Task { [weak self] in
            await self?.run()
            self?.running = nil
            self?.schedule()
        }
    }

    private func run() async {
        var races = 0
        while !stopped, opening == 0, isActive(), let last = pending.last {
            let target = last.sequence, sets = pending, started = generation
            guard let request = request(sets) else {
                metrics.reopens += 1
                awaitingOpen = true
                reopen()
                return
            }
            if sets.allSatisfy({ $0.origin == .sync }) { lastSyncPatch = .now }
            let result: LibraryMirrorRead
            do {
                metrics.reads += 1
                result = try await read(request)
            } catch {
                guard !stopped, !(error is CancellationError) else { return }
                metrics.errors += 1
                failures += 1
                if !failureShown { failureShown = true; failed(error) }
                // The attempts are spent: park until a trigger, never retrying the failed prefix at once.
                guard failures < configuration.maximumErrors else { parked = true; return }
                try? await sleep(configuration.errorRetry)
                continue
            }
            guard !stopped, started == generation, opening == 0 else { metrics.discarded += 1; return }
            failures = 0; failureShown = false
            var mixed = result.sequence != target
#if DEBUG
            if faults.contains(.applyMixedReads) { mixed = false }
#endif
            if mixed {
                // The read saw commits not delivered yet: read again once they are (never apply mixed inputs).
                metrics.races += 1
                races += 1
                if races > configuration.maximumRaces { try? await sleep(configuration.raceRetry); races = 0 }
                else if result.sequence > delivered { await waitForDelivery(through: result.sequence) }
                else { try? await sleep(configuration.raceRetry) }
                continue
            }
            apply(result)
            metrics.patches += 1
            covered = max(covered, target)
            pending.removeAll { $0.sequence <= covered }
            resumeWaiters()
            races = 0
            // A further patch of sync sets only waits for the pacing like any other (schedule decides); local work and
            // settle waiters go on at once.
            if !(pending.contains { $0.origin == .local } || !waiters.isEmpty) { return }
        }
    }

    /// Waits for the next delivery (at most a second: the read is simply made again then).
    private func waitForDelivery(through sequence: Int64) async {
        guard delivered < sequence, !stopped else { return }
        let sleep = sleep
        let timeout = Task { [weak self] in
            do { try await sleep(.seconds(1)) } catch { return }
            self?.wakeDeliveryWaiters()
        }
        await withCheckedContinuation { deliveryWaiters.append($0) }
        timeout.cancel()
    }

    private func wakeDeliveryWaiters() {
        for waiter in deliveryWaiters { waiter.resume() }
        deliveryWaiters = []
    }
}
