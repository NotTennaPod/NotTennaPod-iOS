import Foundation

/// What one exchange did (PROTOCOL §6.8), for the scheduler, the status row and the sync
/// log.
public struct ServerExchangeReport: Sendable, Equatable {
    /// Receipts stored by pushes.
    public var acknowledged = 0
    /// Commits verified and archived by pulls.
    public var pulledCommits = 0
    /// Commits applied to the live library.
    public var appliedUnits = 0
    /// Why the exchange is paused, if it is.
    public var pause: ServerPauseReason?
    /// Paused by `version_unsupported` because this app, not the server, needs updating (PROTOCOL §15.5 "This app needs updating").
    public var appNeedsUpdate = false
    /// What that pause refused: only this work waits for an explicit retry or an update.
    public var refusedRequests: Set<ServerRefusedRequest> = []
    /// A publication over its budget waits for playback to pause or stop (PROTOCOL §6.8).
    public var waitingForPause = false
    /// A publication over its budget waits for the app to leave the foreground: it never runs
    /// while someone uses the app. The page says so.
    public var waitingForBackground = false
    /// A transient failure: retry after this delay (PROTOCOL §6.4: from 2 s, doubling, capped at 5 minutes, with jitter).
    public var retryAfter: Double?
    /// An outbox entry waits for dependencies the server does not have yet (`dependency_missing`).
    public var waitingForDependencies = false
    /// Rows the screens show changed.
    public var libraryChanged = false
    /// Feeds whose deletion effects the feed-deletion coordinator drains (a remote unsubscribe).
    public var deletedFeeds: [Int64] = []
    /// The account's policies changed (the `AccountPolicy` facade reloads).
    public var accountPoliciesChanged = false
    /// An unexpected failure (a bug or a damaged file), for the sync log and tests.
    public var error: String?
    /// The longest a unit held the live write lock, and the longest shadow build, in milliseconds (PROTOCOL §6.8).
    public var longestLockMilliseconds: Double = 0
    public var shadowBuildMilliseconds: Double = 0
    /// Units built in a shadow and published.
    public var publishedUnits = 0
    /// Each applied unit's work (row writes) and live-lock hold, for measurements (PROTOCOL §6.8).
    public var units: [ServerUnitTiming] = []
    /// The last request found no server: no network, the host unknown, refused or timed out, or an answer that is
    /// not a NotTennaPod server's (a captive portal). The page says "Waiting for the server" (PROTOCOL §15.5).
    public var unreachable = false
    /// The live cursor after the exchange: a change hint naming it needs no exchange.
    public var head: ServerHead?
    /// Facts not yet acknowledged and drafts, after the exchange (PROTOCOL §15.5 "changes not yet synchronized").
    public var unsentChanges = 0
    /// Force full synchronization (PROTOCOL §6.14) reprojected the live rows in this exchange.
    public var reprojected = false
    /// Items of the page's "Needs attention" list (PROTOCOL §15.5).
    public var attentionItems = 0
    /// A requested Force full synchronization's download holds later commits from other devices until it is published.
    public var fullSynchronizationHolds = false
    /// A requested Force full synchronization waits for a network its download may use; the ordinary exchange ran.
    public var fullSynchronizationWaitsForNetwork: ServerNetworkWait?
    /// A snapshot download or its staging stopped before eating into the space the app keeps for its own writes; it
    /// continues once space was freed (`download_error_insufficient_space`). No backoff: never retried in a loop.
    public var insufficientSpace = false
    /// The exchange was stopped before it finished (the graph stopped, background time ended): nothing about the
    /// server is known from it, and it is never a successful synchronization.
    public var cancelled = false
    /// A request was refused before it was sent: sync may not use this network now. Nothing was sent.
    public var networkNotPermitted = false
    /// No exchange ran: the library's stored state (its pause, unsent changes, attention items), for the page at
    /// launch before any exchange can run.
    public var stateOnly = false
    /// Bounded transactions that deleted a hidden removal's rows, or staged a new podcast.
    public var removalBatches = 0
    public var stagingBatches = 0
    /// A recovery after a server restore (PROTOCOL §6.11) is running, or finished without restoring everything (PROTOCOL §15.5 status row).
    public var recovery: ServerRecoveryProgress?
    /// A request the recovery needs next was refused with `version_unsupported` (PROTOCOL §10): it waits for an explicit
    /// retry or an update, and no processing time is asked for it.
    public var recoveryBlocked = false
    /// Staged publications built (a shadow or a Force full synchronization): one kept for a later exchange is not
    /// built again unless the base it was built on moved (PROTOCOL §6.8).
    public var shadowsBuilt = 0
    /// Entities local changes touched in a staged publication's scope since it was built, re-projected at its switch.
    public var rebasedEntities = 0
    /// Shown rows only a unit's content changes, shown ahead of it in bounded transactions (stall fix (c)).
    public var shownAhead = 0
    /// The longest synchronization transaction of each kind (`ServerTransactionKind`) this exchange committed: its hold
    /// of the live write lock and its commit's part.
    public var transactionTimes: [String: LibraryTransactionTime] = [:]

    public init() {}

    /// Nothing went wrong: not cancelled, no pause, no retry, no error, nothing waiting.
    public var completed: Bool {
        !stateOnly && !cancelled && !networkNotPermitted && pause == nil && retryAfter == nil && error == nil && !waitingForPause
            && !waitingForBackground && !waitingForDependencies && !insufficientSpace
    }

    /// A publication waits (for a pause, or for the app to leave the foreground): later commits wait behind it.
    var waiting: Bool { waitingForPause || waitingForBackground }
}

/// A request the server answered `version_unsupported` (426), named by what it was (PROTOCOL §10, §15.5).
struct ServerRequestRefused: Error {
    let request: ServerRefusedRequest

    /// Runs one request; a `version_unsupported` answer becomes a refusal of `request`.
    static func mapping<T>(_ request: ServerRefusedRequest, isolation: isolated (any Actor)? = #isolation,
                           _ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch let error as ServerExchangeError where error.code == "version_unsupported" { throw ServerRequestRefused(request: request) }
    }
}

/// Work not started because the server refused that request until an explicit retry or an update.
struct ServerRequestGated: Error {}

extension ServerSyncEngine {
    /// One request of `request`'s kind: not sent while a `version_unsupported` pause refused that kind (it waits for an
    /// explicit retry or an update), and a `version_unsupported` answer refuses it.
    func gated<T>(_ request: ServerRefusedRequest, _ body: () async throws -> T) async throws -> T {
        guard try await store.serverExchangeState().permits(request) else { throw ServerRequestGated() }
        return try await ServerRequestRefused.mapping(request, body)
    }
}

/// Where a recovery after a server restore stands (PROTOCOL §6.11): `running` until it finishes; `incomplete` once it finished
/// with some changes not restored (the page says so and the synchronization log has the details).
public enum ServerRecoveryProgress: String, Sendable, Equatable {
    case running
    /// Caught up; some changes wait for another device to restore what they depend on.
    case waiting
    case incomplete
}

/// A position in an account's change log, as change hints name it (`GET /v1/events`, PROTOCOL §12).
public struct ServerHead: Equatable, Hashable, Sendable {
    public var logID: String
    public var epoch: Int64
    public var seq: Int64
    public init(logID: String, epoch: Int64, seq: Int64) { self.logID = logID; self.epoch = epoch; self.seq = seq }
    init(_ cursor: SyncCursor) { self.init(logID: cursor.logID, epoch: cursor.epoch, seq: cursor.seq) }
}

/// One applied unit's size and how long it held the live write lock.
public struct ServerUnitTiming: Sendable, Equatable {
    public var seq: Int64
    public var work: Int
    public var lockMilliseconds: Double
    public var published: Bool
    /// Rows the unit's transaction wrote.
    public var rowsWritten = 0
    /// Published whole under the background budget, while audio played and no scene was in the foreground.
    public var background = false
    /// This library's own facts the unit retired (a commit bringing back what this phone pushed).
    public var retired = 0
    /// VM steps the unit ran while it held the lock: its hold's work, whatever the machine's speed or load.
    public var lockSteps: Int64 = 0
}

/// A change the screens or the scheduler react to.
public enum ServerExchangeEvent: Sendable, Equatable {
    /// Rows the screens show changed, exactly (`LibraryChangeSet`): sent after every step that changed something visible
    /// (a unit, a staging or shown-ahead batch, a pin release, a removal batch, a recovery step), never for one that
    /// changed nothing, so a long catch-up shows its progress (the app reloads at most once a second, PROTOCOL §6.8).
    case libraryChanged(LibraryChangeSet)
    /// What a paused player's adoption depends on changed: position records or claims, overlays, sessions, pins,
    /// holds, the recovery state. Sent at once; the app checks adoption.
    case positionKnowledge(LibraryPositionKnowledge)
    /// A unit deleted feeds or episodes whose files the feed-deletion coordinator now removes.
    case feedsDeleted
    case accountPoliciesChanged
    case paused(ServerPauseReason)
    /// Releases arrived that this phone has not seen (PROTOCOL §9.9): its new-episode notifications follow.
    case releases
    /// Podcasts merged (PROTOCOL §9.7): the app carries their per-feed speed and skip silence.
    case feedsMerged
}

/// Push, pull, archive and apply for one server library (PROTOCOL §6.4). Network, decoding, digest
/// checks, archiving, planning and shadow building run here, at utility priority, on `sync.sqlite`, read-only
/// connections and staging files; only apply units and the small bookkeeping writes take the live store's write lock.
/// The scheduler runs it (triggers, events, polling, background tasks) and shows its state.
public actor ServerSyncEngine {
    let store: FeedLibraryStore
    let transport: any ServerExchangeTransport
    let vault: any SynchronizationCredentialStore
    let archive: ServerArchive
    let history: ServerArchiveReader
    let databaseURL: URL
    let staging: URL
    let clock: @Sendable () -> Date
    /// Whether the coordinator is playing (PROTOCOL §6.8): units are paced and large publications wait.
    let isPlaying: @Sendable () async -> Bool
    /// Whether a scene of the app is in the foreground (someone may be using it): a publication over the budget
    /// waits until none is.
    let isForeground: @Sendable () async -> Bool
    /// Moved on by the app at every foreground or playback transition.
    let eligibility: ServerPublicationEligibility
    /// The Keychain items the installation transitions need (PROTOCOL §15.4): without them a copy, a transport
    /// conflict or a restored server only pause.
    let installations: ServerInstallationKeychain?

    /// Direct units up to this many row writes; larger commits are built in a shadow and published.
    /// Lower than 500, to measured bounds: a unit's durable commit costs 5-30 ms on a loaded Mac
    /// before its rows (about 35-60 µs each), so 250 keeps a direct unit near the 20 ms budget.
    var directWorkLimit = 250
    /// A publication up to this many row writes runs while audio plays or the app is in use; a larger one waits for the
    /// app to leave the foreground (while audio plays, whole within `backgroundPublishWorkLimit`) or for a pause or stop
    /// (PROTOCOL §6.8). Lowered from 2,000 to measured bounds: 1,500-2,000-row publications held the
    /// lock 50-90 ms on a quiet run and up to 270-600 ms under load, so 1,000 keeps the 100 ms budget with a margin.
    var publishWorkLimit = 1_000
    /// A publication up to this many row writes also runs whole, in one transaction, while audio plays and no scene is
    /// in the foreground (the screen locked, another app in front): nobody looks at the app, playback saves can wait a
    /// few hundred milliseconds, and the renderer never waits on the store. A larger one waits for a pause or stop.
    /// Measured whole publications (Debug build, a Mac at load 11-13; row writes counted, SQLite rows written, lock):
    /// 5,000 episodes' listening in one commit 20,000, 30,005, 208 ms; 5,000 favorites 10,000, 20,005, 169 ms; a history
    /// clear over 5,000 episodes 10,000, 20,050, 205 ms; a 1,000-item queue rewrite 2,105, 5,124, 93 ms; a 999-item queue
    /// arriving 3,497, 5,507, 128 ms. Large units cost about 10 µs a row written and write up to two rows a row write
    /// counted, so 24,000 keeps the costliest measured kind near 500 ms of store lock and lets a 5,000-episode listening
    /// commit through with a margin (small units cost more a row with their fixed commit, but stay far below it).
    var backgroundPublishWorkLimit = 24_000
    /// The disk policy of snapshot downloads and their staging (a reserve they never use).
    var disk = ServerBulkDiskPolicy()
    /// The last shortfall: bulk work starts again only once free space grew past it (plus 100 MB).
    var spaceWait: (free: Int64, shortfall: Int64)?
    /// Test hook: items per snapshot page (the server's own page size otherwise).
    var snapshotPageLimit: Int?
    /// Whether this exchange may start or continue a snapshot download: not in a background app refresh task (only
    /// processing tasks and the app may), where a large download would be cut off and repeated.
    var snapshotsAllowed = true
    /// While playing, at most one unit per this interval (PROTOCOL §6.8: 250 ms).
    var playingUnitInterval: Double = 0.25
    /// Force full synchronization projects a library of at most this many records while audio plays; a larger one
    /// waits for a pause or stop (measured: about 14 s of processing for 20,000 episodes on a loaded Mac).
    var fullStagingWhilePlaying = 5_000
    /// The largest recovery inventory request body, in bytes: under the 64 KiB body limit of every deployed server,
    /// halved after `payload_too_large` (down to 4 KiB) for the rest of the engine's life.
    var inventoryBudget = 60 << 10
    /// Operations per push; lowered after `payload_too_large` (PROTOCOL §6.4).
    var operationLimit: Int?
    /// The server answered `invalid_part` in this exchange: nothing more is pushed until the next one (PROTOCOL §6.4).
    var pushRefusedThisExchange = false
    /// Secrets the server named missing, sent with the next push.
    var extraSecrets: Set<String> = []
    /// The last pull view's `install_watermark` (PROTOCOL §6.6).
    var pullWatermark: Int64?
    /// The recovery caught up in this exchange: its waiting entries are tried again at the next one, not now.
    var caughtUpNow = false
    /// The next commit, known to be over the budget: while it may not run, it is not read and
    /// estimated again at every exchange.
    var deferredUnit: (logID: String, seq: Int64, unit: Int)?
    /// A shadow staged for the next commit and not published yet, and a Force full synchronization built and not
    /// published yet (PROTOCOL §6.8): retried at the next exchange or pause, never built again from scratch unless what
    /// they were built on moved.
    var keptShadow: ServerKeptShadow?
    var keptFull: ServerKeptFull?
    /// Whether this engine made sure the units' indexes exist (`FeedLibraryStore.ensureServerIndexes`).
    var indexesEnsured = false
    /// The last wait logged, so an exchange in the foreground does not log it again and again.
    private var lastWaitLogged: String?
    /// A read-only connection to the live library for planning, opened once.
    private var planning: LibrarySQLite?
    var failures = 0
    var running: Task<ServerExchangeReport, Never>?
    private var lastUnit: Date?
    private var listeners: [UUID: AsyncStream<ServerExchangeEvent>.Continuation] = [:]

    /// Test hooks: called at each named step; throwing simulates a crash there (crash permutations).
    var crashPoint: (@Sendable (String) throws -> Void)?
    /// Test hook: runs after a shadow is built (and its new rows staged) and before it is published (local actions
    /// during staging, PROTOCOL §6.8).
    var beforePublish: (@Sendable () async throws -> Void)?
    /// Test hook: runs at each boundary between the bounded steps of parking, quarantine and release (a local action
    /// there); the crash hook sees `blocking.<boundary>` first.
    var blockingBoundary: (@Sendable (String) async throws -> Void)?
    /// Test hook: runs before each bounded staging transaction (local actions while rows are shown ahead).
    var beforeStagingBatch: (@Sendable () async throws -> Void)?
    /// Test-only fault (mutation check): the steps' change sets are taken but never told.
    var skipChangeDelivery = false
    func setSkipChangeDelivery(_ skip: Bool) { skipChangeDelivery = skip }
    /// Test-only fault (mutation check): what a step commits is told only at the exchange's end, as the first revision
    /// did (no telling after each recorded step or the recovery's catch-up, no request barrier).
    var deferDelivery = false
    func setDeferDeliveryForTesting(_ defer: Bool) { deferDelivery = `defer` }
    /// Tests only: every change set the engine told, in order (compared with the commits); kept only while recording.
    var recordsPublishedChanges = false
    var publishedChanges: [LibraryChangeSet] = []
    func recordPublishedChangesForTesting() { recordsPublishedChanges = true }
    func takePublishedChangesForTesting() -> [LibraryChangeSet] {
        defer { publishedChanges = [] }
        return publishedChanges
    }
    /// Test hook: runs at every request, after what committed before it was told (the request barrier).
    var requestBarrierHook: (@Sendable (String) async -> Void)?
    func setRequestBarrierHook(_ hook: (@Sendable (String) async -> Void)?) { requestBarrierHook = hook }
    /// A visible change told since the exchange's report last took it.
    private var toldSinceReport = false

    public init(store: FeedLibraryStore, database: URL, syncDatabase: URL, staging: URL, transport: any ServerExchangeTransport,
                vault: any SynchronizationCredentialStore = KeychainSynchronizationCredentials(service: "org.nottennapod.app.feeds"),
                clock: @escaping @Sendable () -> Date = { Date() },
                isPlaying: @escaping @Sendable () async -> Bool = { false },
                isForeground: @escaping @Sendable () async -> Bool = { false },
                eligibility: ServerPublicationEligibility = ServerPublicationEligibility(),
                installations: ServerInstallationKeychain? = nil) throws {
        let barrier = ServerRequestBarrier()
        self.store = store; self.transport = ServerBarrierTransport(inner: transport, barrier: barrier); self.vault = vault; self.clock = clock
        self.isPlaying = isPlaying
        self.isForeground = isForeground; self.eligibility = eligibility; self.installations = installations
        databaseURL = database
        self.staging = staging
        archive = try ServerArchive(url: syncDatabase)
        history = try ServerArchiveReader(url: syncDatabase)
        barrier.engine = self
    }

    /// The engine of a library folder (`Server Libraries/<id>/`).
    public init(store: FeedLibraryStore, location: LibraryLocation, transport: any ServerExchangeTransport,
                vault: any SynchronizationCredentialStore = KeychainSynchronizationCredentials(service: "org.nottennapod.app.feeds"),
                clock: @escaping @Sendable () -> Date = { Date() },
                isPlaying: @escaping @Sendable () async -> Bool = { false },
                isForeground: @escaping @Sendable () async -> Bool = { false },
                eligibility: ServerPublicationEligibility = ServerPublicationEligibility(),
                installations: ServerInstallationKeychain? = nil) throws {
        guard let sync = location.syncDatabase, let staging = location.staging else { throw ServerRecordingError.notAServerLibrary }
        try self.init(store: store, database: location.database, syncDatabase: sync, staging: staging, transport: transport,
                      vault: vault, clock: clock, isPlaying: isPlaying, isForeground: isForeground, eligibility: eligibility,
                      installations: installations)
    }

    func planningConnection() throws -> LibrarySQLite {
        if let planning { return planning }
        let connection = try LibrarySQLite(readingOnly: databaseURL)
        planning = connection
        return connection
    }

    public func close() {
        try? planning?.close()
        planning = nil
        try? archive.close()
        history.close()
        for listener in listeners.values { listener.finish() }
        listeners.removeAll()
    }

    public func events() -> AsyncStream<ServerExchangeEvent> {
        let (stream, continuation) = AsyncStream<ServerExchangeEvent>.makeStream()
        let id = UUID()
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(id) } }
        return stream
    }

    private func removeListener(_ id: UUID) { listeners[id] = nil }

    func publish(_ event: ServerExchangeEvent) { for listener in listeners.values { listener.yield(event) } }

    func now() -> Int64 { Int64((clock().timeIntervalSince1970 * 1_000).rounded(.down)) }

    func log(_ kind: String, _ detail: String) { try? archive.log(kind, detail, now: now()) }

    func crash(_ point: String) throws { try stepCrashPoint?(point) }

    // MARK: - The exchange (PROTOCOL §6.14 "Synchronize now" pushes, then pulls)

    /// Applies what the archive holds beyond the live cursor, pushes, pulls and applies, and pushes what the pull
    /// materialized. Never throws for the server's or the network's sake: the report says what happened.
    public func exchange() async -> ServerExchangeReport {
        // One exchange at a time: a caller arriving during one gets its report.
        if let running { return await running.value }
        // Utility priority whoever asks (PROTOCOL §6.8): the exchange never competes with the player for the processor. A
        // caller that is cancelled (background time ended) stops it.
        let task = Task(priority: .utility) { await LibraryChangeOrigin.$current.withValue(.sync) { await self.performExchange() } }
        running = task
        let report = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        running = nil
        return report
    }

    /// An exchange that starts or continues no snapshot download unless `snapshots` (a background app refresh task:
    /// its seconds would cut a large download off).
    public func exchange(snapshots: Bool) async -> ServerExchangeReport {
        snapshotsAllowed = snapshots
        defer { snapshotsAllowed = true }
        return await exchange()
    }

    func performExchange() async -> ServerExchangeReport {
        var report = ServerExchangeReport()
        pushRefusedThisExchange = false
        do {
            // A library from before the units' indexes gets them here, off the launch and while nothing plays (until
            // then its queries are correct, only slower).
            if !indexesEnsured, !(await isPlaying()) {
                if try await store.ensureServerIndexes() { log("apply", "indexes built") }
                // Refresh statuses pulled before they were shown are shown once (PROTOCOL §9.4); a failure never stops
                // the exchange (the next engine tries again).
                do { _ = try await store.projectStoredRefreshStatuses(); await publishChanges(&report) }
                catch { log("apply", "refresh statuses not shown yet: \(ServerLogValue.failure(error))") }
                indexesEnsured = true
            }
            try await store.releaseServerPins()
            await publishChanges(&report)
            // A copy, another library on this transport and a restored server move this library to a new installation
            // (PROTOCOL §6.10); the exchange then runs again on it, a few times at most.
            for round in 1...3 {
                do {
                    try await exchangeSteps(&report)
                    guard round < 3, try await transitionNeeded(after: report.pause) else { break }
                } catch let error as ServerExchangeError {
                    guard round < 3, try await transitionNeeded(after: error) else { throw error }
                }
                report.pause = nil
            }
            // The backoff starts again only after an exchange that needed no retry (a dependency wait backs off
            // progressively, PROTOCOL §6.4).
            if report.retryAfter == nil, !report.waitingForDependencies { failures = 0 }
        } catch let error as ServerExchangeError {
            await handle(error, &report)
        } catch let refused as ServerRequestRefused {
            await refuse(refused.request, &report)
        } catch is ServerRequestGated {
            // What the server refused waits for an explicit retry or an update.
        } catch let space as ServerInsufficientSpace {
            noteInsufficientSpace(space, &report)
        } catch is CancellationError {
            report.cancelled = true
        } catch {
            log("error", ServerLogValue.failure(error))
            report.error = String(describing: error)
            backoff(&report)
        }
        return await finish(report)
    }

    /// One exchange on the current installation: what waits for the installation first (PROTOCOL §6.10), then apply, push,
    /// pull, apply and push again, and a recovery's finish once its outbox went out.
    private func exchangeSteps(_ report: inout ServerExchangeReport) async throws {
        guard try await prepareInstallation(&report) else { return }
        try await applyPending(&report)
        // A hidden removal's rows go before anything needs the network (and resume after a crash).
        try await finishHiddenRemovals(&report)
        // A publication waiting for a pause holds back later commits, never this library's own facts: they are
        // pushed (and checkpoints reach the server while the person listens). Pulling waits with the commits.
        try await push(&report)
        // Whether this exchange reached the server's head and applied every commit up to it: a recovery's finish and
        // the release of its holds need that evidence, never a pull or secret the server refused.
        // Everything else goes on as before.
        var caughtUp = false
        if !report.waiting {
            let reach = try await pull(&report)
            if report.pause == nil || report.pause?.pullsContinue == true {
                caughtUp = try await applyPending(&report) && reach == .head
                try await finishHiddenRemovals(&report)
            }
            if !report.waiting { try await push(&report) }
        }
        try await retireAppliedRetained(&report)
        if report.pause == nil, !report.waiting, report.retryAfter == nil {
            if caughtUp { try await finishRecovery(&report) }
            try await releaseLeftHolds(&report, caughtUp: caughtUp)
        }
    }

    /// The exchange's steps one at a time, for prefixes of an exchange (agreement tests): `applyOne` applies the
    /// next archived commit only.
    enum Step: Sendable { case push, pull, apply, applyOne }

    func run(_ steps: [Step]) async -> ServerExchangeReport {
        await LibraryChangeOrigin.$current.withValue(.sync) { await runSteps(steps) }
    }

    private func runSteps(_ steps: [Step]) async -> ServerExchangeReport {
        var report = ServerExchangeReport()
        pushRefusedThisExchange = false
        do {
            try await store.releaseServerPins()
            guard try await prepareInstallation(&report) else { return await finish(report) }
            for step in steps {
                switch step {
                case .push: try await push(&report)
                case .pull: try await pull(&report)
                case .apply: try await applyPending(&report)
                case .applyOne:
                    if let live = try await store.serverExchangeState().cursor { try await applyPending(&report, through: live.seq + 1) }
                }
            }
        } catch let error as ServerExchangeError {
            await handle(error, &report)
        } catch let refused as ServerRequestRefused {
            await refuse(refused.request, &report)
        } catch is ServerRequestGated {
            // What the server refused waits for an explicit retry or an update.
        } catch let space as ServerInsufficientSpace {
            noteInsufficientSpace(space, &report)
        } catch is CancellationError {
            report.cancelled = true
        } catch {
            log("error", ServerLogValue.failure(error))
            report.error = String(describing: error)
            backoff(&report)
        }
        return await finish(report)
    }

    /// The report's closing facts (the live head, what is unsent) and the events units did not send.
    func finish(_ report: ServerExchangeReport) async -> ServerExchangeReport {
        var report = report
        // Whatever a step left untold.
        await publishChanges(&report)
        // A cancellation can surface as any error on its way out (or none, when a step returns early): whatever was
        // caught, an exchange whose task was cancelled did not finish.
        if Task.isCancelled { report.cancelled = true }
        if report.cancelled { log("cancelled", "stopped before it finished") }
        // What the store noted since the last exchange (PROTOCOL §15.5): refused writes, owed facts recorded late.
        for line in await store.takeServerDiagnostics() { log(line.kind, line.detail) }
        let state = try? await store.serverExchangeState()
        if let state {
            report.head = state.cursor.map(ServerHead.init)
            if report.pause == nil, let pause = state.pause { report.pause = pause }
            report.appNeedsUpdate = report.pause == .versionUnsupported && state.appNeedsUpdate
            report.refusedRequests = report.pause == .versionUnsupported ? state.refusedRequests : []
        }
        report.recovery = await recoveryProgress()
        report.recoveryBlocked = await recoveryWaitsForRetry(state)
        // Every synchronization transaction's hold of the live write lock, the longest of each kind (PROTOCOL §6.8).
        for (kind, time) in await store.takeSyncTransactionTimes() { report.transactionTimes[kind, default: LibraryTransactionTime()].merge(time) }
        report.unsentChanges = (try? await store.serverUnsentChanges()) ?? report.unsentChanges
        report.attentionItems = (try? await store.serverAttentionCount()) ?? report.attentionItems
        if report.accountPoliciesChanged { publish(.accountPoliciesChanged) }
        if let pause = report.pause { publish(.paused(pause)) }
        return report
    }

    /// The answers that pause sync, and the transient ones that back off (PROTOCOL §6.4).
    func handle(_ error: ServerExchangeError, _ report: inout ServerExchangeReport) async {
        let pause: ServerPauseReason?
        switch (error.status, error.code) {
        case (401, _), (403, _): pause = .signIn
        case (409, "lineage_mismatch"): pause = .lineageMismatch
        case (409, "lineage_unknown"): pause = .lineageUnknown
        case (409, "installation_superseded"), (409, "installation_conflict"): pause = .transportConflict
        // A request no wrapper named (`ServerRequestRefused` names the others): taken as a push.
        case (_, "version_unsupported"): await refuse(.push, &report); return
        default: pause = nil
        }
        if let pause {
            try? await store.setServerPause(pause)
            log("paused", pause.rawValue)
            report.pause = pause
            return
        }
        switch error {
        case .server(let status, let code, let wait):
            log("retry", "HTTP \(status) \(ServerLogValue.error(code))")
            if let wait { report.retryAfter = Double(wait) } else { backoff(&report) }
        case .noToken:
            // No usable token (logged out, or refused before): sync waits for "Sign in again" (PROTOCOL §15.4).
            report.pause = .signIn
            log("paused", "\(ServerPauseReason.signIn.rawValue) no usable login on this device")
        case .networkNotPermitted:
            // Not a failure of the server: no backoff; the scheduler waits for a permitted network.
            report.networkNotPermitted = true
            log("waiting", "the network may not be used for sync now")
        case .unreachable, .notAServer:
            report.unreachable = true
            log("retry", error.description)
            backoff(&report)
        }
    }

    /// A whole request refused with `version_unsupported` (PROTOCOL §10, 426): that request waits, beside what the pause
    /// refused before, until an explicit retry or an update, and the rest goes on; never retried as a transient failure.
    /// Which side needs updating is asked once per pause, from the protocol versions the server speaks.
    func refuse(_ request: ServerRefusedRequest, _ report: inout ServerExchangeReport) async {
        let before = try? await store.serverExchangeState()
        let known = before?.pause == .versionUnsupported ? before?.refusingProtocol : nil
        let refused = await refusingProtocol(known)
        try? await store.refuseServerRequest(request, refusedProtocol: refused)
        report.pause = .versionUnsupported
        if known == nil || !(before?.refusedRequests.contains(request) ?? false) {
            let side = refused >= ServerClient.protocolVersions.lowerBound ? "this app" : "the server"
            log("paused", "\(ServerPauseReason.versionUnsupported.rawValue) HTTP 426 refused the \(request.rawValue): \(side) needs updating")
        }
    }

    /// The newest protocol version the server speaks (`GET /v1/info`), once per pause (`known` after the first). When it
    /// cannot say, this app's own newest: a server refusing this app's own version means this app needs updating, as
    /// sign-in reads `version_unsupported` (`ServerClient`).
    private func refusingProtocol(_ known: Int?) async -> Int {
        if let known { return known }
        if let info = try? await transport.send("GET", "v1/info", body: nil), let newest = info["protocol"]?["max"]?.integerValue {
            return Int(clamping: newest)
        }
        return ServerClient.protocolVersions.upperBound
    }

    /// Bulk work stopped short of the reserve: it waits, without a backoff, until free space grew by the shortfall
    /// plus 100 MB (checked whenever an exchange runs: at launch, in the foreground, in background tasks).
    func noteInsufficientSpace(_ space: ServerInsufficientSpace, _ report: inout ServerExchangeReport) {
        report.insufficientSpace = true
        spaceWait = (disk.available(staging) ?? 0, space.shortfall)
        log("waiting", "not enough free space for the snapshot: \(space.shortfall / 1_000_000) MB more needed")
    }

    /// Whether bulk work may try again after a shortfall: free space grew by it plus 100 MB.
    func bulkSpaceReturned(_ report: inout ServerExchangeReport) -> Bool {
        guard let wait = spaceWait else { return true }
        if let free = disk.available(staging), free >= wait.free + wait.shortfall + 100_000_000 {
            spaceWait = nil
            return true
        }
        report.insufficientSpace = true
        return false
    }

    /// Exponential backoff with jitter from 2 s, capped at 5 minutes, forever (PROTOCOL §6).
    func backoff(_ report: inout ServerExchangeReport) {
        failures += 1
        let base = min(300, 2 * pow(2, Double(min(failures - 1, 10))))
        report.retryAfter = base * Double.random(in: 0.8...1.2)
    }

    /// An explicit retry (Synchronize now, Force full synchronization, Needs attention's "Try again"): a change the server
    /// refused or found too large is tried once more now, and so is listening refused as too large (PROTOCOL §6.13).
    public func retryRefusedChanges() async {
        do {
            if let cleared = try await store.retryRefusedServerPushes() { log("resumed", cleared.rawValue) }
            if try await store.retryRefusedListening() { log("requested", "listening or queue additions refused as too large are tried again") }
            if try await store.resumeRefusedDrafts() { log("requested", "changes waiting behind one too large are sent") }
        } catch { log("error", "retrying refused changes: \(ServerLogValue.failure(error))") }
    }

    /// Clears a pause the person or the scheduler resolved (signed in again, the server or app
    /// updated).
    public func resume() async throws {
        let paused = try await store.serverExchangeState().pause
        try await store.setServerPause(nil)
        failures = 0
        if let paused { log("resumed", paused.rawValue) }
    }

    /// Pauses for `reason` until `resume()` (PROTOCOL §6.11 `lineage_unknown` found by signing in again).
    public func pause(_ reason: ServerPauseReason) async {
        try? await store.setServerPause(reason)
        log("paused", reason.rawValue)
    }

    /// The library's stored state without an exchange: a pause persisted by an earlier run says so at once (PROTOCOL §15.5).
    public func storedState() async -> ServerExchangeReport {
        var report = ServerExchangeReport()
        report.stateOnly = true
        let state = try? await store.serverExchangeState()
        if let state {
            report.head = state.cursor.map(ServerHead.init)
            report.pause = state.pause
            report.appNeedsUpdate = state.appNeedsUpdate
            report.refusedRequests = state.pause == .versionUnsupported ? state.refusedRequests : []
        }
        report.recovery = await recoveryProgress()
        report.recoveryBlocked = await recoveryWaitsForRetry(state)
        report.unsentChanges = (try? await store.serverUnsentChanges()) ?? 0
        report.attentionItems = (try? await store.serverAttentionCount()) ?? 0
        return report
    }

    /// The live cursor: a change hint naming it needs no exchange.
    public func liveHead() async -> ServerHead? {
        (try? await store.serverExchangeState().cursor).flatMap { $0.map(ServerHead.init) }
    }

    /// Applies what waited for the player (PROTOCOL §6.8) as soon as it leaves an episode, without an exchange.
    public func releasePins() async {
        await LibraryChangeOrigin.$current.withValue(.sync) {
            var report = ServerExchangeReport()
            do {
                try await store.releaseServerPins()
                await publishChanges(&report)
                // A hidden removal waiting for the player's episode finishes now.
                try await finishHiddenRemovals(&report)
            } catch { log("error", "releasing the player's pins: \(ServerLogValue.failure(error))") }
            await publishChanges(&report)
        }
    }

    /// Publishes what this engine's steps committed since the last call: the exact visible change set (none for a step
    /// that changed nothing visible) and the position knowledge it touched.
    func publishChanges(_ report: inout ServerExchangeReport) async {
        await announceCommitted()
        if toldSinceReport { report.libraryChanged = true; toldSinceReport = false }
    }

    /// Tells what the engine's committed steps changed and the position knowledge they touched, now. Every request waits
    /// for it (`ServerBarrierTransport`), so nothing committed is left untold while the exchange goes on to the network: a
    /// paused player adopts a position a recovery or full publication made eligible before the person can press Play.
    func announceCommitted() async {
        let taken = await store.takeSyncChanges()
        if skipChangeDelivery { return }
        if let set = taken.set, !set.isEmpty {
            toldSinceReport = true
            publish(.libraryChanged(set))
            if recordsPublishedChanges { publishedChanges.append(set) }
        }
        if let knowledge = taken.knowledge, !knowledge.isEmpty { publish(.positionKnowledge(knowledge)) }
    }

    /// The request barrier: what committed is told before a request goes out.
    func beforeRequest(_ path: String) async {
        if !deferDelivery { await announceCommitted() }
        await requestBarrierHook?(path)
    }

    // MARK: - Pacing (PROTOCOL §6.8)

    /// Whether a publication over the 100 ms budget may run now: never while a scene of the app is
    /// in the foreground (someone may be using it); whole, in one transaction, when no audio plays; and while audio
    /// plays with no scene in the foreground, when its `work` (row writes, nil: not known yet, bounded by the store) is
    /// within the background budget and no publication admitted so since the last transition was deferred. Otherwise
    /// the report says what it waits for.
    func largePublicationMayRun(_ report: inout ServerExchangeReport, _ what: String, work: Int? = nil) async -> Bool {
        let line: String
        if await isForeground() {
            report.waitingForBackground = true
            line = "\(what) wait until NotTennaPod is in the background"
        } else if await isPlaying() {
            if (work ?? 0) <= backgroundPublishWorkLimit, !eligibility.deferredSinceTransition {
                lastWaitLogged = nil
                return true
            }
            report.waitingForPause = true
            line = "\(what) wait for playback to pause"
        } else {
            lastWaitLogged = nil
            return true
        }
        if line != lastWaitLogged { log("apply", line) }
        lastWaitLogged = line
        return false
    }

    /// `largePublicationMayRun`, with the admission ticket the store checks: read before the checks, so a
    /// transition during them also refuses the publication. Admitted while audio plays, it carries the background budget.
    func largePublicationTicket(_ report: inout ServerExchangeReport, _ what: String, work: Int? = nil) async -> ServerPublicationTicket? {
        let generation = eligibility.current
        guard await largePublicationMayRun(&report, what, work: work) else { return nil }
        return ServerPublicationTicket(eligibility: eligibility, generation: generation, budget: await isPlaying() ? backgroundPublishWorkLimit : nil)
    }

    func pace() async throws {
        guard await isPlaying(), let last = lastUnit else { lastUnit = clock(); return }
        let wait = playingUnitInterval - clock().timeIntervalSince(last)
        if wait > 0 { try await Task.sleep(for: .milliseconds(Int(wait * 1_000))) }
        lastUnit = clock()
    }

    // MARK: - Inspection (sync log, safeguards)

    public func logEntries() throws -> [(time: Int64, kind: String, detail: String)] {
        try archive.logEntries().map { ($0.time, $0.kind, $0.detail) }
    }

    /// A line in the sync log for what the person asked (Synchronize now, Force full synchronization).
    public func note(_ kind: String, _ detail: String) { log(kind, detail) }

    func setBudgets(direct: Int? = nil, publish: Int? = nil, background: Int? = nil, playingInterval: Double? = nil) {
        if let direct { directWorkLimit = direct }
        if let publish { publishWorkLimit = publish }
        if let background { backgroundPublishWorkLimit = background }
        if let playingInterval { playingUnitInterval = playingInterval }
    }

    func setCrashPoint(_ hook: (@Sendable (String) throws -> Void)?) { crashPoint = hook }
    func setSnapshotTesting(pageLimit: Int? = nil, stagingWhilePlaying: Int? = nil, disk: ServerBulkDiskPolicy? = nil) {
        snapshotPageLimit = pageLimit
        if let stagingWhilePlaying { fullStagingWhilePlaying = stagingWhilePlaying }
        if let disk { self.disk = disk }
    }
    func setBeforePublish(_ hook: (@Sendable () async throws -> Void)?) { beforePublish = hook }
    func setBlockingBoundary(_ hook: (@Sendable (String) async throws -> Void)?) { blockingBoundary = hook }

    /// What runs between two bounded steps (`ServerBlockingSteps`): the crash hook (`blocking.<boundary>`), then the
    /// test hook.
    var betweenSteps: @Sendable (String) async throws -> Void {
        let crash = stepCrashPoint, hook = blockingBoundary
        return { name in
            try crash?("blocking.\(name)")
            try await hook?(name)
        }
    }
    func setBeforeStagingBatch(_ hook: (@Sendable () async throws -> Void)?) { beforeStagingBatch = hook }
}

/// The engine, for its transport's request barrier (set once the engine exists).
final class ServerRequestBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private weak var stored: ServerSyncEngine?
    var engine: ServerSyncEngine? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// The engine's transport: every request first tells what committed before it (`ServerSyncEngine.beforeRequest`).
struct ServerBarrierTransport: ServerExchangeTransport {
    let inner: any ServerExchangeTransport
    let barrier: ServerRequestBarrier

    func send(_ method: String, _ path: String, body: ContractJSON?) async throws -> ContractJSON {
        await barrier.engine?.beforeRequest(path)
        return try await inner.send(method, path, body: body)
    }

    /// The wrapped transport's network decision (a waiting repair lets ordinary sync go on); its requests still check.
    func bulkWaitReason() async -> ServerNetworkWait? { await inner.bulkWaitReason() }
}
