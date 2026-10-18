import Foundation

/// What the scheduler drives: a server library's exchange engine. `ServerSyncEngine` in the app; tests give one of
/// their own to check timing without a server.
public protocol ServerExchangeDriving: AnyObject, Sendable {
    func exchange() async -> ServerExchangeReport
    /// An exchange that may start or continue a snapshot download only when `snapshots` (not in a background app
    /// refresh task, whose few seconds would cut a large download off).
    func exchange(snapshots: Bool) async -> ServerExchangeReport
    func forceFullSynchronization() async -> ServerExchangeReport
    /// The stored state without an exchange (`ServerExchangeReport.stateOnly`).
    func storedState() async -> ServerExchangeReport
    /// Force full synchronization's request, persisted until a repair is published.
    func requestFullSynchronization() async
    func fullSynchronizationRequested() async -> Bool
    /// What a Force full synchronization would download, estimated from the last download (nil: unknown).
    func fullSynchronizationEstimate() async -> Int64?
    func resume() async throws
    /// Pauses the exchange for `reason` until `resume()` (PROTOCOL §6.11 `lineage_unknown` found by signing in again).
    func pause(_ reason: ServerPauseReason) async
    /// An installation for "Sign in again" when the server says this one was replaced (PROTOCOL §6.10).
    func planNewInstallation() async -> ServerSignInInstallation?
    func releasePins() async
    func events() async -> AsyncStream<ServerExchangeEvent>
    func cancelExchange() async
    func note(_ kind: String, _ detail: String) async
    func close() async
    /// Asks the server to refresh a podcast, or every one (`POST /v1/refresh`); never waited for.
    func requestServerRefresh(feedID: Int64?) async
    /// An explicit retry of changes the server refused or found too large (PROTOCOL §6.13).
    func retryRefusedChanges() async
}

extension ServerSyncEngine: ServerExchangeDriving {}

extension ServerExchangeDriving {
    public func exchange(snapshots: Bool) async -> ServerExchangeReport { await exchange() }
    public func fullSynchronizationEstimate() async -> Int64? { nil }
    public func pause(_ reason: ServerPauseReason) async {}
    public func planNewInstallation() async -> ServerSignInInstallation? { nil }
    public func requestServerRefresh(feedID: Int64?) async {}
    public func retryRefusedChanges() async {}
}

/// Why no exchange can run now (PROTOCOL §15.5): no network, or only mobile data that sync may not use.
public enum ServerNetworkWait: Sendable, Equatable {
    case offline
    case mobileDataOff
}

/// Whether the network may be used for sync now (the "Synchronization" mobile-data preference), and when it
/// changes.
public protocol ServerSyncNetworkGate: Sendable {
    func permitted() async -> Bool
    func changes() -> AsyncStream<Void>
    /// Whether sync may use an expensive (mobile) network at all; requests ask the system to refuse one otherwise.
    func allowsMobile() async -> Bool
    /// Why sync may not use the network now; nil when it may.
    func waitReason() async -> ServerNetworkWait?
    /// Why a whole-library download (attach, Force full synchronization, a recovery's snapshot) may not use the network
    /// now; nil when it may. Besides mobile data, Low Data Mode counts as a network sync's mobile-data preference
    /// governs.
    func bulkWaitReason() async -> ServerNetworkWait?
}

extension ServerSyncNetworkGate {
    public func allowsMobile() async -> Bool { true }
    public func waitReason() async -> ServerNetworkWait? { await permitted() ? nil : .offline }
    public func bulkWaitReason() async -> ServerNetworkWait? { await waitReason() }
    public func permittedForBulk() async -> Bool { await bulkWaitReason() == nil }
}

/// The device's network through `DownloadNetworkMonitor`, with the mobile-data rule of gpodder.net sync: a metered
/// network only when the "Synchronization" mobile-data preference allows it. Low Data Mode does not stop ordinary
/// sync (positions and changes keep flowing); it is Android's metered network only for what Mobile updates govern.
public struct DownloadNetworkSyncGate: ServerSyncNetworkGate {
    let monitor: DownloadNetworkMonitor
    let allowMobile: @Sendable () async -> Bool

    public init(monitor: DownloadNetworkMonitor = .shared, allowMobile: @escaping @Sendable () async -> Bool) {
        self.monitor = monitor; self.allowMobile = allowMobile
    }

    public func permitted() async -> Bool { await waitReason() == nil }

    public func waitReason() async -> ServerNetworkWait? {
        // Not known yet (the monitor's first report): try; the requests themselves refuse an expensive network.
        guard let network = monitor.current else { return nil }
        return Self.waitReason(network, allowMobile: await allowMobile())
    }

    static func waitReason(_ network: DownloadNetworkState, allowMobile: Bool) -> ServerNetworkWait? {
        guard network.connected else { return .offline }
        return allowMobile || !network.metered ? nil : .mobileDataOff
    }

    public func bulkWaitReason() async -> ServerNetworkWait? {
        guard let network = monitor.current else { return nil }
        return Self.bulkWaitReason(network, allowMobile: await allowMobile())
    }

    /// A whole-library download: on mobile data or in Low Data Mode only when the mobile-data preference allows sync.
    static func bulkWaitReason(_ network: DownloadNetworkState, allowMobile: Bool) -> ServerNetworkWait? {
        guard network.connected else { return .offline }
        return allowMobile || (!network.metered && !network.constrained) ? nil : .mobileDataOff
    }

    public func allowsMobile() async -> Bool { await allowMobile() }

    /// Only real changes: path updates repeating the same network and the same answer are not passed on (each would
    /// retry an unreachable server).
    public func changes() -> AsyncStream<Void> {
        let changes = monitor.changes()
        let allowMobile = allowMobile
        return AsyncStream { continuation in
            let task = Task {
                var filter = ChangeFilter()
                for await network in changes {
                    let wait = Self.waitReason(network, allowMobile: await allowMobile())
                    if filter.isChange(network, wait) { continuation.yield(()) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The last network and answer passed on.
    struct ChangeFilter {
        private var last: (network: DownloadNetworkState, wait: ServerNetworkWait?)?
        mutating func isChange(_ network: DownloadNetworkState, _ wait: ServerNetworkWait?) -> Bool {
            if let last, last.network == network, last.wait == wait { return false }
            last = (network, wait)
            return true
        }
    }
}

/// When a server library exchanges (PROTOCOL §6.4): the app core owns one per open server library,
/// whether or not the Synchronization page is open.
///
/// - At launch, at every scene activation and when the network returns: an exchange.
/// - After a local action that recorded facts: a push 2 s later (at once while the app is in the background with
///   granted time), so actions made together go together.
/// - While a scene is active: the server's change hints (`GET /v1/events`); a hint naming another head pulls. Against
///   a server without events, or while the stream is down, every 60 s instead.
/// - After a transient failure: again after the engine's backoff or the server's `retry_after`.
/// - A publication or Force full synchronization waiting for a pause runs when playback pauses or stops.
/// - "Synchronize now" and "Force full synchronization" run at once; background tasks run one exchange, or until
///   the heavy work is done.
///
/// A pause (sign in again, recovery, a new lineage) stops every trigger until `resume()`; pauses that let pulls
/// continue (a server that needs updating, a transport conflict) keep pulling. One exchange runs at a time; triggers
/// arriving meanwhile run one more afterwards. Screens are told of library changes at most once a second.
@MainActor public final class ServerSyncScheduler {
    public struct Timing: Sendable {
        public var debounce: Duration = .seconds(2)
        public var polling: Duration = .seconds(60)
        /// The first reconnection of a dropped event stream; it doubles up to `polling` while connections stay short.
        public var reconnect: Duration = .seconds(5)
        /// A connection up this long (past its first head; the server's heartbeat is every 25 s) was stable: the
        /// reconnection backoff starts again from `reconnect`.
        public var stableAfter: Duration = .seconds(30)
        public var reloadInterval: Duration = .seconds(1)
        public init() {}
    }

    public enum Trigger: String, Sendable, CaseIterable {
        case launch, activation, network, localChange, hint, poll, retry, playbackPaused, requested, background
        /// The app left the foreground with a publication waiting for that.
        case backgrounded
    }

    public struct Callbacks {
        /// After every exchange (the page's status, the sync log's reach, background-task scheduling).
        public var reported: @MainActor (ServerExchangeReport) -> Void = { _ in }
        /// Rows the screens show changed: the union of the exact change sets since the last call, never empty; at most
        /// once per `Timing.reloadInterval`.
        public var libraryChanged: @MainActor (LibraryChangeSet) -> Void = { _ in }
        /// What a paused player's adoption depends on changed: told at once, and after every exchange that applied a
        /// unit (a backstop). The app checks adoption.
        public var positionKnowledge: @MainActor (LibraryPositionKnowledge) -> Void = { _ in }
        /// Feeds or episodes were deleted: their files go through the feed-deletion coordinator.
        public var feedsDeleted: @MainActor () -> Void = {}
        public var accountPoliciesChanged: @MainActor () -> Void = {}
        /// Releases arrived (PROTOCOL §9.9), or new-episode notifications may still be owed (at launch, in
        /// the foreground and after every exchange): the notifications not delivered yet (their automatic
        /// download is requested durably).
        public var releasesArrived: @MainActor () -> Void = {}
        /// Podcasts merged (PROTOCOL §9.7): their per-feed speed and skip silence go to the survivors.
        public var feedsMerged: @MainActor () -> Void = {}
        /// Why no exchange can run now, or nil once one may (PROTOCOL §15.5): told when it changes, from the network's
        /// changes as well as from an exchange that could not start. Apart from `reported`, so it never stands for an
        /// exchange's result (a pause, a successful synchronization, the unsent changes).
        public var networkWaitChanged: @MainActor (ServerNetworkWait?) -> Void = { _ in }
        /// Work started (an exchange, or a push waiting for the debounce): in the background it asks for granted time
        /// (`BackgroundWorkGrant.workStarted`), so a push started there, a pause on the lock screen's, is not cut off.
        public var workStarted: @MainActor () -> Void = {}
        public init() {}
    }

    public enum BackgroundWork: Sendable {
        /// `BGAppRefreshTask`: push, then one incremental pull and its units.
        case refresh
        /// `BGProcessingTask`: until a waiting publication or Force full synchronization is done.
        case processing
    }

    let engine: any ServerExchangeDriving
    private let hints: (any ServerChangeHintSource)?
    private let outbox: (@Sendable () async -> AsyncStream<Void>)?
    private let network: any ServerSyncNetworkGate
    private let timing: Timing
    public var callbacks: Callbacks

    public private(set) var lastReport: ServerExchangeReport?
    /// Triggers of the last 100 exchanges, in order: diagnostics only (tests and the log).
    public private(set) var history: [Set<Trigger>] = []
    /// Exchanges run so far: what "this request ran" is decided by (never the capped history).
    public private(set) var exchangesRun = 0
    public private(set) var isExchanging = false
    /// The event stream is connected now.
    public private(set) var hintsConnected = false
    /// The pause that stops every trigger until `resume()`.
    public private(set) var pause: ServerPauseReason?
    /// Why no exchange can run now (`Callbacks.networkWaitChanged`).
    public private(set) var networkWait: ServerNetworkWait?

    private var started = false
    /// Granted background time ended with no scene active and no audio keeping the app running: triggers are
    /// recorded but nothing runs, and timers are parked, until a scene, a new grant, a background task or audio.
    private var parked = false
    private var foreground = false
    private var playing = false
    private var expedited = false
    private var pending: Set<Trigger> = []
    private var fullRequested = false
    /// The last repair attempt waited (for a pause, or for the app to leave the foreground): automatic triggers then
    /// run ordinary exchanges, and the repair is tried again only when it may run.
    private var fullWaiting = false
    /// The server refused the repair's snapshot (`version_unsupported`): the request stays owed, but only an explicit
    /// retry (Synchronize now, Force full synchronization) or an update runs it again; exchanges go on meanwhile.
    private var fullRefused = false
    private var waitingForPause = false
    /// A publication over the budget waits for the app to leave the foreground; then it runs, while
    /// audio plays too if within the background budget.
    private var waitingForBackground = false
    private var waitingForNetwork = false
    /// The background task running now, if any: a refresh task never starts or continues a snapshot download.
    private var backgroundWork: BackgroundWork?
    /// The last known answer of the network gate: hints connect only on a permitted network.
    private var networkAllowed = false
    private var knownHead: ServerHead?
    /// After a transient failure, no automatic trigger starts an exchange before this instant (monotonic, PROTOCOL §6.4:
    /// the engine's backoff or the server's `retry_after`); triggers arriving meanwhile wait for it.
    private var retryNotBefore: ContinuousClock.Instant?
    private var loop: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?
    /// Which hint task owns the hints: every start and stop moves it on, so a stopped or replaced task (one still waiting
    /// for the gate's answer, say) never changes its successor's state, never connects, and never leaves a stream that
    /// `stopHints` cannot end. Exactly one live hint stream per scheduler.
    private var hintGeneration = 0
    /// The connection attempt in progress (its first head's time once connected): whoever ends it counts it in the backoff,
    /// the owning task when the stream ends by itself, `stopHints` when the scheduler ends it.
    private struct HintAttempt { var connectedAt: ContinuousClock.Instant? }
    private var hintAttempt: HintAttempt?
    /// The event stream's reconnection backoff, kept across network changes while this scheduler runs: the next
    /// delay after a short connection (nil: `reconnect`), and no reconnection before `reconnectNotBefore`. A stable
    /// connection, a new foreground period and a resumption start it again; another library has its own scheduler.
    private var reconnectDelay: Duration?
    private var reconnectNotBefore: ContinuousClock.Instant?
    private var watchers: [Task<Void, Never>] = []
    private var reloadTimer: Task<Void, Never>?
    private var lastReload: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    /// `outbox`: the store's wake hints after local actions that recorded facts (`serverOutboxChanges()`).
    /// `eligibility`: the engine's, moved on at every foreground and playback transition.
    public init(engine: any ServerExchangeDriving, hints: (any ServerChangeHintSource)?, outbox: (@Sendable () async -> AsyncStream<Void>)?,
                network: any ServerSyncNetworkGate, timing: Timing = .init(), callbacks: Callbacks = .init(),
                eligibility: ServerPublicationEligibility? = nil, snapshotsNeedForeground: Bool = false) {
        self.engine = engine; self.hints = hints; self.outbox = outbox; self.network = network
        self.timing = timing; self.callbacks = callbacks; self.eligibility = eligibility
        self.snapshotsNeedForeground = snapshotsNeedForeground
    }

    /// Snapshot downloads only in the foreground or a processing task (the app); tests drive the scheduler without scenes.
    private let snapshotsNeedForeground: Bool

    private let eligibility: ServerPublicationEligibility?

    // MARK: - Lifecycle

    /// Starts listening and runs the launch exchange.
    public func start() {
        guard !started else { return }
        started = true
        // Notifications an earlier run committed but did not deliver.
        callbacks.releasesArrived()
        if let outbox {
            watchers.append(Task { [weak self] in
                for await _ in await outbox() { self?.localChange() }
            })
        }
        let engine = engine
        watchers.append(Task { [weak self] in
            for await event in await engine.events() {
                guard let self else { return }
                switch event {
                case .libraryChanged(let set): self.libraryChangedSoon(set)
                case .positionKnowledge(let knowledge): self.callbacks.positionKnowledge(knowledge)
                case .feedsDeleted: self.callbacks.feedsDeleted()
                case .accountPoliciesChanged: self.callbacks.accountPoliciesChanged()
                case .releases: self.callbacks.releasesArrived()
                case .feedsMerged: self.callbacks.feedsMerged()
                case .paused: break
                }
            }
        })
        // The page shows what is stored (a pause from an earlier run) at once, before any exchange can run.
        watchers.append(Task { [weak self] in
            guard let state = await self?.engine.storedState(), let self, self.lastReport == nil else { return }
            self.fullRefused = state.refusedRequests.contains(.snapshot)
            self.callbacks.reported(state)
        })
        let changes = network.changes()
        watchers.append(Task { [weak self] in
            await self?.networkChanged()
            for await _ in changes { await self?.networkChanged() }
        })
        // A repair requested before the app stopped is owed still: the launch exchange runs it.
        watchers.append(Task { [weak self] in
            guard let requested = await self?.engine.fullSynchronizationRequested(), let self, self.started else { return }
            if requested { self.fullRequested = true }
            self.trigger(.launch)
        })
    }

    /// Stops and closes the engine's files (the library graph stops).
    public func close() async {
        await stop()
        await engine.close()
    }

    /// Ends every trigger and the running exchange; waits for the exchange to end.
    public func stop() async {
        started = false
        for task in watchers { task.cancel() }
        watchers.removeAll()
        stopHints()
        debounce?.cancel(); debounce = nil
        retry?.cancel(); retry = nil
        reloadTimer?.cancel(); reloadTimer = nil
        pending.removeAll()
        loop?.cancel()
        await engine.cancelExchange()
        await loop?.value
        loop = nil
    }

    // MARK: - Triggers

    /// A scene became active (true) or the last scene left the foreground (false). Change hints run only while a
    /// scene is active.
    public func setForeground(_ value: Bool) {
        eligibility?.changed()
        guard started, foreground != value else { return }
        foreground = value
        if value {
            expedited = false
            unpark()
            resetReconnection()
            startHints()
            callbacks.releasesArrived()
            trigger(.activation)
        } else {
            stopHints()
            // What waited for nobody to be using the app runs now, in the background time the app is granted, or while
            // audio keeps it running (whole within the background budget; a larger one then waits for a pause).
            if waitingForBackground || (fullRequested && fullWaiting) { trigger(.backgrounded) }
        }
    }

    /// The app is in the background with granted time: a waiting push starts at once (as gpodder.net sync does).
    public func setExpedited(_ value: Bool) {
        expedited = value
        if value { unpark() }
        guard value, debounce != nil else { return }
        debounce?.cancel(); debounce = nil
        trigger(.localChange)
    }

    /// The granted background time ended: the running exchange stops cleanly (everything is resumable), and
    /// nothing starts again until a scene, a new grant or a background task allows it. While audio plays the app keeps
    /// running, and sync with it: nothing is parked then.
    public func suspendForBackground() {
        guard started, !foreground, !playing else { return }
        parked = true
        if debounce != nil { pending.insert(.localChange) }
        debounce?.cancel(); debounce = nil
        retry?.cancel(); retry = nil
        stopHints()
        loop?.cancel()
        let engine = engine
        Task { await engine.cancelExchange() }
    }

    /// Work may run again: the retry timer is armed for what is left of its deadline, and recorded triggers run.
    private func unpark() {
        guard parked else { return }
        parked = false
        if let deadline = retryNotBefore, clock.now >= deadline {
            // The retry that was parked is due: it runs with whatever else waited.
            if lastReport?.retryAfter != nil { pending.insert(.retry) }
        } else if let deadline = retryNotBefore, retry == nil {
            retry = Task { [weak self] in
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                guard !Task.isCancelled else { return }
                self?.retry = nil
                self?.trigger(.retry)
            }
        }
        if !pending.isEmpty, loop == nil, !pending.allSatisfy(backingOff) { startLoop() }
    }

    /// The player's state (PROTOCOL §6.8): units are paced and large publications wait while it plays; a pause or stop runs
    /// what waited.
    public func playbackChanged(playing value: Bool) {
        if value != playing { eligibility?.changed() }
        let wasPlaying = playing
        playing = value
        if value { unpark() }
        // A repair waiting for the app to leave the foreground is not built again at every pause.
        if wasPlaying, !value, waitingForPause || (fullRequested && !waitingForBackground) { trigger(.playbackPaused) }
    }

    /// The player left an episode: what waited for it applies now (PROTOCOL §6.8), without an exchange.
    public func playerLeftEpisode() {
        guard started else { return }
        let engine = engine
        Task(priority: .utility) { await engine.releasePins() }
    }

    /// A local action recorded facts: push after the debounce.
    public func localChange() {
        guard started else { return }
        if expedited { trigger(.localChange); return }
        debounce?.cancel()
        let delay = timing.debounce
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.debounce = nil
            self?.trigger(.localChange)
        }
        callbacks.workStarted()
    }

    /// "Synchronize now" (PROTOCOL §6.14): pushes, then pulls, now. A server that needed updating is tried again.
    @discardableResult
    /// A manual refresh (pull to refresh) also asks the server to refresh (PROTOCOL §9), without waiting: the
    /// phone refreshes the feeds itself as before.
    public func requestServerRefresh(feedID: Int64?) {
        let engine = engine
        Task.detached(priority: .utility) { await engine.requestServerRefresh(feedID: feedID) }
    }

    public func synchronizeNow() async -> ServerExchangeReport? {
        await engine.note("requested", "synchronize now")
        if lastReport?.pause == .versionUnsupported { await resumeEngine() }
        // What the server refused or found too large is tried once more (PROTOCOL §6.13).
        await engine.retryRefusedChanges()
        return await runRequested()
    }

    /// "Force full synchronization" (PROTOCOL §6.14): every live row reprojected from a verified snapshot. While audio plays a
    /// large one waits for the app to leave the foreground (while audio plays, whole within the background budget) or
    /// for a pause or stop (or a processing background task).
    @discardableResult
    public func forceFullSynchronization() async -> ServerExchangeReport? {
        await engine.note("requested", "force full synchronization")
        // An explicit retry of what a server that needed updating refused, or found too large.
        if lastReport?.pause == .versionUnsupported { await resumeEngine() }
        await engine.retryRefusedChanges()
        await engine.requestFullSynchronization()
        fullRequested = true
        fullWaiting = false
        return await runRequested()
    }

    /// The size the Force full synchronization confirmation names: the last download's, scaled to the library now; nil
    /// when nothing was downloaded into this library yet. A download already kept counts as done.
    public func fullSynchronizationEstimate() async -> Int64? { await engine.fullSynchronizationEstimate() }

    /// The person's sign-in found the account without this library's history (PROTOCOL §6.11 `lineage_unknown`): sync pauses
    /// until the person signs in again or starts over.
    public func pause(_ reason: ServerPauseReason) async {
        await engine.pause(reason)
        pause = reason
        stopHints()
        retry?.cancel(); retry = nil
    }

    /// "Sign in again" found this installation replaced by another library's successor (PROTOCOL §6.10): the installation
    /// to sign in with instead.
    public func planNewInstallation() async -> ServerSignInInstallation? { await engine.planNewInstallation() }

    /// The person signed in again, or the server or app was updated: sync continues.
    public func resume() async {
        await resumeEngine()
        resetReconnection()
        startHints()
        trigger(.requested)
    }

    /// Background execution. Returns whether the work completed.
    public func runInBackground(_ work: BackgroundWork) async -> Bool {
        guard started else { return false }
        unpark()
        // Before the retry deadline (the engine's backoff, the server's Retry-After) a background task sends nothing:
        // its work joins what the retry runs, and the task ends at once (Synchronize now keeps its own policy). The
        // app schedules the next one no earlier than the deadline.
        if backingOff(.background) {
            pending.insert(.background)
            return false
        }
        backgroundWork = work
        defer { backgroundWork = nil }
        // A processing task continues while the heavy work advances; playing audio (it may run then) or a failure
        // leaves it for later.
        for _ in 0..<(work == .processing ? 8 : 1) {
            let before = exchangesRun
            pending.insert(.background)
            if loop == nil { startLoop() }
            await loop?.value
            if Task.isCancelled || exchangesRun == before { return false }
            guard work == .processing, needsProcessingTime, !playing,
                  lastReport?.completed == true || lastReport?.waitingForPause == true || lastReport?.waitingForBackground == true,
                  pause == nil, lastReport?.retryAfter == nil else { break }
        }
        return lastReport?.completed == true && (work == .refresh || !needsProcessingTime)
    }

    /// No automatic exchange (background tasks included) starts before this time: the engine's backoff or the server's
    /// Retry-After (PROTOCOL §6.4). The app asks for its next background task no earlier.
    public var retryNotBeforeDate: Date? {
        guard let deadline = retryNotBefore, clock.now < deadline else { return nil }
        let remaining = clock.now.duration(to: deadline)
        return Date().addingTimeInterval(Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18)
    }

    /// Work that holds a granted background time (`BackgroundWorkGrant`): an exchange running or a push waiting.
    public var hasPendingWork: Bool { loop != nil || debounce != nil }

    /// A push waits for the debounce (tests).
    var debouncing: Bool { debounce != nil }
    /// No reconnection of the change hints before this instant (tests).
    var hintReconnectionNotBefore: ContinuousClock.Instant? { reconnectNotBefore }
    /// Triggers waiting for the next exchange (tests).
    var pendingTriggers: Set<Trigger> { pending }

    /// Heavy work a processing background task should finish: a publication or Force full synchronization
    /// waiting for a pause, or for the app to leave the foreground, and a recovery running (PROTOCOL §6.11).
    public var needsProcessingTime: Bool { waitingForPause || waitingForBackground || (fullRequested && !fullRefused) || recoveryRuns }

    /// A recovery runs (PROTOCOL §6.11), unless the server refused a request it needs next with `version_unsupported`: that waits
    /// for an explicit retry or an update, as a refused Force full synchronization does.
    private var recoveryRuns: Bool {
        guard let lastReport, lastReport.recovery == .running else { return false }
        return !lastReport.recoveryBlocked
    }

    // MARK: - Running

    private func trigger(_ reason: Trigger) {
        guard started else { return }
        if pause != nil, reason != .requested, reason != .background { return }
        // Hints and polling belong to an active scene: one already in flight when the scene left does nothing.
        if reason == .poll || reason == .hint, !foreground { return }
        pending.insert(reason)
        guard loop == nil, !parked, !backingOff(reason) else { return }
        startLoop()
    }

    /// Runs what is pending; in the background the work asks for granted time.
    private func startLoop() {
        loop = Task { [weak self] in await self?.run() }
        callbacks.workStarted()
    }

    /// Runs an exchange that starts after this call (after a running one) and returns its report; nil when none
    /// could start (no permitted network).
    private func runRequested() async -> ServerExchangeReport? {
        guard started else { return nil }
        unpark()
        let before = exchangesRun
        // A pause stops automatic triggers, not what the person asks for: the report says why nothing happened.
        pending.insert(.requested)
        if loop == nil { startLoop() }
        await loop?.value
        return exchangesRun > before ? lastReport : nil
    }

    private func run() async {
        defer { loop = nil }
        while !pending.isEmpty, !Task.isCancelled, !parked {
            // Triggers that arrived during a failed exchange wait for its retry deadline (the retry timer runs them).
            if pending.allSatisfy(backingOff) { return }
            // A recovery waiting for playback to pause (its snapshot download or switch) is not asked again at every
            // hint, poll or local change while audio plays: those wait for the pause (a recovery holds pushes and pulls
            // anyway).
            if recoveryWaitsForPause, pending.isDisjoint(with: Self.runsWaitingRecovery) { return }
            let reasons = pending
            pending.removeAll()
            if let wait = await network.waitReason() {
                // Mobile data not allowed, or no network: the network's return runs it, and the page says why meanwhile.
                waitingForNetwork = true
                networkAllowed = false
                stopHints()
                setNetworkWait(wait)
                return
            }
            waitingForNetwork = false
            setNetworkWait(nil)
            retry?.cancel(); retry = nil
            isExchanging = true
            exchangesRun += 1
            history.append(reasons)
            if history.count > 100 { history.removeFirst(history.count - 100) }
            // A waiting repair is not staged again on every trigger: only when it may run now.
            let mayRun: Set<Trigger> = waitingForBackground ? [.requested, .background, .backgrounded, .launch]
                : [.requested, .playbackPaused, .background, .backgrounded, .launch]
            // A background app refresh task has seconds: it never starts (or continues) a snapshot download, whatever
            // triggers are pending; nor does background time that is not a processing task, when the app says so.
            let snapshots = snapshotsAllowed
            let full = fullRequested && !fullRefused && (!fullWaiting || !reasons.isDisjoint(with: mayRun)) && snapshots
            let report = full ? await engine.forceFullSynchronization()
                : snapshots ? await engine.exchange() : await engine.exchange(snapshots: false)
            isExchanging = false
            handle(report, full: full)
        }
    }

    private func handle(_ report: ServerExchangeReport, full: Bool) {
        lastReport = report
        // Owed notifications are retried after every exchange, whether or not it brought releases.
        if !report.cancelled { callbacks.releasesArrived() }
        // A backstop for adoption: after an exchange that applied something, the player's episode is checked.
        if report.appliedUnits > 0 { callbacks.positionKnowledge(LibraryPositionKnowledge(all: true)) }
        if let head = report.head { knownHead = head }
        // A request refused because sync may not use this network: the network's return runs it again, and the page
        // says why meanwhile.
        if report.networkNotPermitted {
            waitingForNetwork = true
            let network = network
            Task { [weak self] in
                guard let wait = await network.waitReason(), let self, self.started else { return }
                self.setNetworkWait(wait)
            }
        }
        // A Force full synchronization that was published is done (the engine cleared its request with it); one
        // that waits or failed stays requested and runs when it may.
        // A repair waiting for a network its download may use runs when the network changes.
        if report.fullSynchronizationWaitsForNetwork != nil { waitingForNetwork = true }
        if full {
            if report.reprojected { fullRequested = false; fullWaiting = false }
            else if report.waitingForPause || report.waitingForBackground { fullWaiting = true }
        }
        // A cancelled exchange says nothing about what waits.
        if !report.cancelled {
            waitingForPause = report.waitingForPause
            waitingForBackground = report.waitingForBackground
            fullRefused = report.refusedRequests.contains(.snapshot)
        }
        if let reason = report.pause, !reason.pullsContinue {
            pause = reason
            stopHints()
        } else { pause = nil }
        if let wait = report.retryAfter, pause == nil {
            let delay = Duration.milliseconds(Int(max(0, wait) * 1_000))
            retryNotBefore = clock.now + delay
            retry?.cancel(); retry = nil
            if parked { return callbacks.reported(report) }
            retry = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard !Task.isCancelled else { return }
                self?.retry = nil
                self?.trigger(.retry)
            }
            return callbacks.reported(report)
        }
        if !report.cancelled { retryNotBefore = nil }
        if waitingForPause, !playing, !parked {
            // The player paused while this exchange ran: what waited runs shortly (never in a tight loop).
            retry?.cancel()
            let delay = timing.debounce
            retry = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard !Task.isCancelled else { return }
                self?.retry = nil
                self?.trigger(.playbackPaused)
            }
        } else if waitingForBackground, !foreground, !parked {
            // The app left the foreground while this exchange ran: what waited runs shortly (while audio plays, whole
            // within the background budget). In the foreground it waits for the app to leave it (no retries while
            // someone uses the app).
            retry?.cancel()
            let delay = timing.debounce
            retry = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                guard !Task.isCancelled else { return }
                self?.retry = nil
                self?.trigger(.backgrounded)
            }
        }
        callbacks.reported(report)
    }

    /// Whether an exchange now may start or continue a snapshot download: never within a background app refresh task;
    /// with `snapshotsNeedForeground`, only in the foreground or a processing task (so the launch of an app started in
    /// the background for a refresh task downloads nothing either).
    var snapshotsAllowed: Bool {
        guard backgroundWork != .refresh else { return false }
        return !snapshotsNeedForeground || foreground || backgroundWork == .processing
    }

    /// Triggers that run an exchange while a recovery waits for playback to pause.
    static let runsWaitingRecovery: Set<Trigger> = [.requested, .playbackPaused, .background, .backgrounded, .launch]

    private var recoveryWaitsForPause: Bool {
        playing && lastReport?.recovery == .running && lastReport?.waitingForPause == true
    }

    /// Whether `reason` waits for the retry deadline: every automatic trigger does; what the person asks for, a
    /// background task, the deadline itself and the network's return after it was unreachable do not.
    private func backingOff(_ reason: Trigger) -> Bool {
        guard let deadline = retryNotBefore, clock.now < deadline else { return false }
        switch reason {
        case .requested, .retry: return false
        case .network: return lastReport?.unreachable != true
        case .launch, .activation, .localChange, .hint, .poll, .playbackPaused, .backgrounded, .background: return true
        }
    }

    private func resumeEngine() async {
        do { try await engine.resume() } catch { await engine.note("error", "resuming: \(ServerLogValue.failure(error))") }
        pause = nil
        fullRefused = false
    }

    /// The "Synchronization" mobile-data preference changed: the same as a network change.
    public func networkPolicyChanged() {
        Task { await networkChanged() }
    }

    /// A prohibited network stops the hints and the running exchange at once (it is cancelled, never a success);
    /// a permitted one starts them again and runs what waited for it.
    /// What the page shows meanwhile follows the network too, also when nothing waits to be sent (PROTOCOL §15.5).
    private func networkChanged() async {
        guard started else { return }
        let wait = await network.waitReason()
        guard started else { return }
        setNetworkWait(wait)
        if wait == nil {
            networkAllowed = true
            startHints()
            if waitingForNetwork || lastReport?.unreachable == true { trigger(.network) }
        } else {
            networkAllowed = false
            stopHints()
            if loop != nil {
                waitingForNetwork = true
                loop?.cancel()
                await engine.cancelExchange()
            }
        }
    }

    private func setNetworkWait(_ wait: ServerNetworkWait?) {
        // A stopped scheduler (its library closed) tells nothing any more.
        guard started, wait != networkWait else { return }
        networkWait = wait
        callbacks.networkWaitChanged(wait)
    }

    // MARK: - Change hints

    private func startHints() {
        guard started, foreground, pause == nil, networkAllowed, !parked, hintTask == nil else { return }
        guard let hints else { startPolling(); return }
        hintGeneration &+= 1
        let generation = hintGeneration
        hintTask = Task { [weak self] in
            while self?.ownsHints(generation) == true {
                // A reconnection waits for the backoff, also when the network went and came back meanwhile; polling
                // covers the wait.
                if let deadline = self?.reconnectNotBefore, let now = self?.clock.now, now < deadline {
                    self?.startPolling()
                    do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                    guard self?.ownsHints(generation) == true else { return }
                }
                // Every (re)connection asks the gate first: no hint stream over a prohibited network. An answer that
                // arrives after this task was stopped or replaced changes nothing.
                guard let network = self?.network else { return }
                let permitted = await network.permitted()
                guard self?.ownsHints(generation) == true else { return }
                guard permitted else {
                    self?.hintTask = nil; self?.hintsConnected = false
                    return
                }
                self?.hintAttempt = HintAttempt()
                do {
                    for try await head in hints.hints() {
                        guard let self, self.ownsHints(generation) else { break }
                        if self.hintAttempt?.connectedAt == nil { self.hintAttempt?.connectedAt = self.clock.now }
                        self.hintsConnected = true
                        self.stopPolling()
                        if head != self.knownHead { self.trigger(.hint) }
                    }
                } catch ServerChangeHintError.unsupported {
                    // An older server: polling for as long as the scene is active.
                    guard let self, self.ownsHints(generation) else { return }
                    self.hintAttempt = nil
                    self.hintsConnected = false
                    self.startPolling()
                    return
                } catch ServerChangeHintError.rejected {
                    // The token stopped being valid: the exchange finds the pause; polling continues meanwhile.
                    if let self, self.ownsHints(generation) { self.trigger(.hint) }
                } catch {}
                // Ended by itself (dropped, refused): the backoff counts it. Ended by `stopHints`: counted there.
                guard let self, self.ownsHints(generation) else { return }
                self.hintStreamEnded()
                self.hintsConnected = false
                self.startPolling()
            }
        }
    }

    /// Whether the running hint task, started as `generation`, still owns the hints.
    private func ownsHints(_ generation: Int) -> Bool { hintGeneration == generation && !Task.isCancelled }

    /// A connection that stayed up `stableAfter` past its first head starts the backoff again (the next reconnection
    /// after `reconnect`); any shorter one, a failed connection included, waits the delay and doubles it, up to
    /// `polling` (5, 10, 20, 40, 60 s). Heartbeats are not heads: only the stream's own time up counts.
    private func hintStreamEnded() {
        guard let attempt = hintAttempt else { return }
        hintAttempt = nil
        let connectedAt = attempt.connectedAt
        let now = clock.now
        let delay: Duration
        if let connectedAt, connectedAt.duration(to: now) >= timing.stableAfter {
            delay = timing.reconnect
            reconnectDelay = nil
        } else {
            delay = reconnectDelay.map { min($0 * 2, timing.polling) } ?? timing.reconnect
            reconnectDelay = delay
        }
        reconnectNotBefore = now + delay
    }

    /// A new foreground period or a resumption: the hints connect at once, with the backoff from its start.
    private func resetReconnection() {
        reconnectDelay = nil
        reconnectNotBefore = nil
    }

    private func stopHints() {
        // The attempt in progress ends now and counts at once, so what follows (a new foreground period resetting the
        // backoff, a replacement) sees it; the stopped task changes nothing afterwards.
        hintStreamEnded()
        hintGeneration &+= 1
        hintTask?.cancel(); hintTask = nil
        hintsConnected = false
        stopPolling()
    }

    private func startPolling() {
        guard started, foreground, poller == nil else { return }
        let interval = timing.polling
        poller = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled else { return }
                self?.trigger(.poll)
            }
        }
    }

    private func stopPolling() { poller?.cancel(); poller = nil }

    // MARK: - Screens (PROTOCOL §6.8: at most one reload a second during catch-up)

    /// The change sets waiting for the next delivery, as one union.
    private var pendingChanges: LibraryChangeSet?

    private func libraryChangedSoon(_ set: LibraryChangeSet) {
        guard !set.isEmpty else { return }
        pendingChanges = pendingChanges.map { $0.union(set) } ?? set
        guard reloadTimer == nil else { return }
        let now = clock.now
        if let last = lastReload, last.duration(to: now) < timing.reloadInterval {
            let wait = timing.reloadInterval - last.duration(to: now)
            reloadTimer = Task { [weak self] in
                do { try await Task.sleep(for: wait) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.reloadTimer = nil
                self.deliverChanges()
            }
            return
        }
        deliverChanges()
    }

    private func deliverChanges() {
        guard let changes = pendingChanges else { return }
        pendingChanges = nil
        lastReload = clock.now
        callbacks.libraryChanged(changes)
    }
}
