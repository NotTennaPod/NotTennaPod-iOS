import Foundation
import Synchronization

public struct FeedLibraryEffect: Codable, Equatable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case feedAdded(source: String)
        case deleteFeed(FeedDeletion)
        case feedRemoved(source: String)
        case queueEpisodes([Int64])
        case removeEpisodes([LibraryEpisode])
        case syncCompletedEpisodes(source: String, episodes: [FeedRefreshResult.CompletedEpisodeSync])
        case downloadCompleted(source: String, episode: LibraryEpisode, synchronize: Bool)
        case deleteDownloadFile(file: URL, episode: LibraryEpisode, source: String, synchronize: Bool)
        case deleteLocalMedia(reference: LocalDocumentReference)
        case refreshAfterLocalMediaDeletion(directoryIdentity: String)
        case downloadFileDeleted(episode: LibraryEpisode, source: String, synchronize: Bool)
        case episodePlayed(episode: LibraryEpisode, source: String, startPositionMilliseconds: Int32, completed: Bool)
        case episodeStateChanged(EpisodeStateSyncAction)

        /// The case name, as the JSON record's key and the `pending_effects.kind` column store it.
        var name: String {
            switch self {
            case .feedAdded: "feedAdded"
            case .deleteFeed: "deleteFeed"
            case .feedRemoved: "feedRemoved"
            case .queueEpisodes: "queueEpisodes"
            case .removeEpisodes: "removeEpisodes"
            case .syncCompletedEpisodes: "syncCompletedEpisodes"
            case .downloadCompleted: "downloadCompleted"
            case .deleteDownloadFile: "deleteDownloadFile"
            case .deleteLocalMedia: "deleteLocalMedia"
            case .refreshAfterLocalMediaDeletion: "refreshAfterLocalMediaDeletion"
            case .downloadFileDeleted: "downloadFileDeleted"
            case .episodePlayed: "episodePlayed"
            case .episodeStateChanged: "episodeStateChanged"
            }
        }

        /// Kinds whose only consumer is the synchronization outbox, which receives them in the transaction that
        /// creates them. Nothing reads them later, so they are not kept in `pending_effects`.
        static let synchronizationOnlyNames: Set<String> = ["feedAdded", "feedRemoved", "syncCompletedEpisodes",
            "downloadCompleted", "downloadFileDeleted", "episodePlayed", "episodeStateChanged"]
        var isSynchronizationOnly: Bool { Self.synchronizationOnlyNames.contains(name) }
    }

    public var feedID: Int64
    public var date: Date
    public var kind: Kind
    /// Optional sidecar preserves the original removeEpisodes Codable case and
    /// episode snapshots while retaining context before their rows cascade away.
    public var removedEpisodeCleanup: FeedDeletion? = nil
    /// A server library's `queueEpisodes` releases with their batch's evidence (PROTOCOL §9.5): the queue filing proposes
    /// with it, also after a relaunch. Nil in a standalone library.
    var releases: [ServerRelease]? = nil
}

public struct PendingFeedLibraryEffect: Equatable, Sendable {
    public var id: Int64
    public var effect: FeedLibraryEffect
}

public struct FeedLibraryLog: Codable, Equatable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case success
        case failure(FeedFetchError)
        case duplicate(FeedRefreshResult.Duplicate)

        public var isSuccessful: Bool { if case .success = self { true } else { false } }
    }

    public var feedID: Int64
    public var date: Date
    public var title: String?
    public var kind: Kind
    public var detail: String? = nil
}

public struct FeedLibraryPreferences: Equatable, Sendable {
    public var customTitle: String?
    public var subscriptionState: FeedSubscriptionState
    public var newEpisodesAction: NewEpisodesAction
    public var autoDownload: FeedAutoDownload
    public var keepUpdated: Bool = true
    public var showEpisodeNotification: Bool = false
    public var automaticDownloadFilter: AutomaticDownloadFilter = .init()
    public var tags: [String] = []
    public var skip: FeedSkipPreferences = .init()
    public var volumeAdaptation: FeedVolumeAdaptation = .off
    public var autoDelete: FeedAutoDelete = .global
}

/// Feed contents and queue membership from the same database read transaction.
public struct FeedLibrarySnapshot: Equatable, Sendable {
    public let feeds: [LibraryFeed]
    public let queue: [LibraryEpisode]
    public let deletionTargets: [Int64: EpisodeMediaDeletionTarget]
    /// The statistics units of the feeds' episodes (schema 20): only statistics read them, never a list.
    public let statisticsUnits: [Int64: [LibraryStatisticsUnit]]

    public init(feeds: [LibraryFeed], queue: [LibraryEpisode], deletionTargets: [Int64: EpisodeMediaDeletionTarget] = [:],
                statisticsUnits: [Int64: [LibraryStatisticsUnit]] = [:]) {
        self.feeds = feeds
        self.queue = queue
        self.deletionTargets = deletionTargets
        self.statisticsUnits = statisticsUnits
    }
}

/// What statistics read (schema 20): the library's feeds and their episodes' statistics units, from one read.
public struct LibraryStatisticsInput: Equatable, Sendable {
    public var feeds: [LibraryFeed]
    /// By local episode ID.
    public var units: [Int64: [LibraryStatisticsUnit]]
    public init(feeds: [LibraryFeed], units: [Int64: [LibraryStatisticsUnit]] = [:]) { self.feeds = feeds; self.units = units }
}

public actor FeedLibraryStore {
    let database: LibrarySQLite
    let swipeUndoEpoch = UUID()
    var queueRemovalOffers: [UUID: EpisodeQueueRemovalReceipt] = [:]
    var historyRemovalOffers: [UUID: EpisodeHistoryRemovalReceipt] = [:]
    let synchronizationClock: @Sendable () -> Date
    var synchronizationExecution: UUID?
    var synchronizationListeners: [UUID: AsyncStream<Void>.Continuation] = [:]
    var automaticDownloadListeners: [UUID: AsyncStream<Void>.Continuation] = [:]
    var queueEffectListeners: [UUID: AsyncStream<Void>.Continuation] = [:]
    var downloadLogListeners: [UUID: AsyncStream<Void>.Continuation] = [:]
    /// Enqueue location and Keep sorted, read inside every `addToQueue` transaction like
    /// `UserPreferences` in `DBWriter.addQueueItem`. Set synchronously so no enqueue can precede it.
    let queueInsertion = Mutex(QueueInsertionSettings())
    /// The feed-credential Keychain store (adopted by `FeedAuthentication`), which a server library uses to keep a
    /// subscription URL's userinfo as the feed's credentials secret. Unused in a standalone library.
    let credentialVault = Mutex<(any SynchronizationCredentialStore)?>(nil)
    /// Feeds whose episode records were read (`loadFeed`), for tests of avoided whole-feed reads. Nothing decoded is kept
    /// between reads: a feed's episodes are read from the database each time a caller needs them.
    private(set) var feedEpisodeReads = 0
    /// Whole-library screen reads (`snapshot()` and `screenSnapshot()`), for the screens' budgets.
    public internal(set) var snapshotReads = 0
    /// Durable write commits made by this store, for tests of batched work.
    var writeCommits: Int { database.writeCommits }
    /// A refresh reads each of its feed's server tables once and hands what it read on (the merge's observed hashes to the
    /// recorder, the decoded feed to the capture). Tests turn it off for the differential reference.
    var refreshSharesReads = true
    /// Library records (feeds, episodes, effects, logs) decoded from JSON, for tests of work budgets.
    private(set) var recordsDecoded = 0
    /// Of `recordsDecoded`, the episode records (the budget: an unchanged refresh decodes none).
    private(set) var episodeRecordsDecoded = 0
    /// Refreshes that were identical to their feed's last applied one and wrote only its header, for tests.
    var unchangedRefreshes = 0
    /// Whether the routine readers that have a keyed path (automatic download, file owners, the bulk Inbox and
    /// history clears, sync action matching, notification counts) take it once the derived keys are complete. Tests turn it
    /// off for the canonical reference.
    var keyedReadsEnabled = true
    var keyedReads: Bool { derived.isReady && keyedReadsEnabled }
    /// Whether refreshes read and keep the refresh memo (`FeedRefreshMemo`). Tests turn it off for the differential
    /// reference.
    var refreshMemoEnabled = true
    /// Whether this library's server tables have the triggers that retire a feed's refresh memo (`ServerExchangeTables`).
    var refreshMemoGuarded: Bool?
    /// What the store's connection has done so far (tests compare two readings).
    var work: StoreWork {
        .init(recordsDecoded: recordsDecoded, statements: database.statementsRun, steps: database.statementSteps,
              pages: database.pagesTouched, commits: database.writeCommits)
    }
    /// The connection's current `PRAGMA synchronous` (2 = FULL), for tests.
    func synchronousMode() throws -> Int64 { try database.scalar("PRAGMA synchronous") }
    /// The server library's identity (`ntp_library`), nil in a standalone library (PROTOCOL §15.4).
    var serverContext: ServerLibraryContext?
    /// The capture of the `write(intent:)` transaction in progress, in a server library.
    var activeCapture: ChangeCapture?
    /// Test failure injection: the recorder fails right after its Nth write (PROTOCOL §15.2).
    var recorderFailureInjection: Int?
    /// Test-only: the fact bound in place of the one the server advertised (PROTOCOL §6.13).
    var factBoundOverride: Int?
    /// Test-only faults in the adoption decision (mutation checks).
    var adoptionFaults: Set<AdoptionFault> = []
    /// The recorder's writes in the last server-library transaction, for tests.
    var recorderWrites = 0
    /// The owed-fact replay's transactions: how many have finished, readable without the store, and,
    /// only when a test turns it on, each one's time on the store and its writes.
    nonisolated let owedReplayTransactions = Mutex(0)
    var owedReplayTrace: [OwedReplayTransaction]?
    var owedTransactionWrites = 0
    /// Undo offers' recording state, kept with the in-memory receipts (PROTOCOL §15.2): the removed queue key and the
    /// history removal's cuts.
    var queueRemovalKeys: [UUID: StoredQueueKey] = [:]
    var historyRemovalCuts: [UUID: [RecordedFact]] = [:]
    /// The removal's local cuts of listening kept on this device, each session's earlier cut, for the Undo.
    var historyRemovalLocalCuts: [UUID: [(session: String, previous: Int64?)]] = [:]
    /// Wake hints for the server sync scheduler: a local action recorded facts (PROTOCOL §6.4, push 2 s later).
    var serverOutboxListeners: [UUID: AsyncStream<Void>.Continuation] = [:]
    /// Sync log lines from the store (PROTOCOL §15.5): writes the recorder refused (an unmapped change, PROTOCOL §15.2) and owed facts
    /// recorded late, each noted once its transaction committed, logged by the next exchange outside the write lock.
    var serverDiagnostics: [(kind: String, detail: String)] = []
    /// Why observations since the last exchange differed from their canonical records, by field name (the first-refresh
    /// diagnosis).
    var observationTally = ObservationDifferenceTally()
    /// Owed queue additions the last successful `replayOwedStep` recorded.
    var owedStepAdds = 0
    /// This opening of the library (PROTOCOL §8): a playback session journaled by an earlier one is
    /// from an earlier process, its saves exported passively.
    let playbackIncarnation = ContractIdentity.randomUUID()
    /// The restart export (PROTOCOL §8.2) has not run for this opening yet.
    var playbackRestartPending = true
    /// Feeds whose deferred observations a refresh of this process is recording with its parse (PROTOCOL §9.4).
    var drainingObservationFeeds: Set<Int64> = []
    /// The connection's log of what local writes touch (`ServerTouches`), once created; a new epoch is a new log.
    var touchEpoch: UUID?
    /// Tables the log covers that did not exist when it was created (the recovery holds before
    /// their first use):
    /// their triggers are installed when they appear, under a new epoch.
    var touchTablesMissing: Set<String> = []

    /// `ownedRoot`: the folder holding the library's `media/` when it is not the database's own folder (a converted
    /// library opened before a Keep at logout has published it, PROTOCOL §15.4).
    public init(url: URL, ownedRoot: URL? = nil, synchronizationClock: @escaping @Sendable () -> Date = { Date() }) throws {
        database = try LibrarySQLite(url: url, ownedRoot: ownedRoot)
        try database.enableChangeCapture()
        databaseURL = url
        derived = DerivedReadiness(ready: try LibrarySchema21.isComplete(database))
        self.synchronizationClock = synchronizationClock
        serverContext = try Self.loadServerContext(database)
        if serverContext != nil { try ServerExchangeTables.create(database) }
        isServerLibraryAtOpen = serverContext != nil
        readOnly = false
        identityAtOpen = try database.libraryIdentity()
        (changes, syncChanges) = try Self.connectChanges(database, library: identityAtOpen?.identity)
    }

    /// Every committed visible change of this library, whatever its origin (`LibraryChangeHub`).
    public nonisolated let changes: LibraryChangeHub
    /// Sync-origin commits the sync engine has not taken yet.
    nonisolated let syncChanges: LibrarySyncChanges

    /// The hub fed by the connection's commits: every set to the hub, sync-origin commits also to the engine's list.
    private static func connectChanges(_ database: LibrarySQLite, library: String?) throws -> (LibraryChangeHub, LibrarySyncChanges) {
        let identity = LibraryChangeHub.Identity(library: library, incarnation: UUID())
        database.changeIdentity = identity
        let hub = LibraryChangeHub(identity: identity, baseline: try database.changeSequence())
        let sync = LibrarySyncChanges()
        database.onCommit = { [hub, sync] commit in
            if let set = commit.set { hub.emit(set) }
            if commit.origin == .sync { sync.add(commit) }
        }
        return (hub, sync)
    }

    /// The sync-origin changes committed since the last call (the sync engine publishes them after each step).
    func takeSyncChanges() -> (set: LibraryChangeSet?, knowledge: LibraryPositionKnowledge?) { syncChanges.take() }

    /// The library's identity and Cast tag as the store opened (schema 20), for the graph's synchronous setup. A
    /// first attachment changes a new library's identity afterwards; `libraryIdentity()` reads the current row.
    public nonisolated let identityAtOpen: LibraryIdentity?

    /// Whether the library was a server library when the store opened, for the screens' synchronous reads (a live
    /// graph's library never changes kind while open; only a new library's provisioning makes one a server library).
    public nonisolated let isServerLibraryAtOpen: Bool

    /// A read-only store over a library no graph has open (an inactive or previous library, PROTOCOL §11.5): it neither
    /// migrates nor writes, and any write fails. Only for reading a whole library once (an export's source).
    init(readingOnly url: URL) throws {
        database = try LibrarySQLite(readingOnly: url)
        databaseURL = url
        let current = try database.scalar("PRAGMA user_version") >= 21 ? try LibrarySchema21.isComplete(database) : false
        derived = DerivedReadiness(ready: current)
        synchronizationClock = { Date() }
        serverContext = try database.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'ntp_library'") == 1
            ? try Self.loadServerContext(database) : nil
        isServerLibraryAtOpen = serverContext != nil
        readOnly = true
        identityAtOpen = try database.libraryIdentity()
        (changes, syncChanges) = try Self.connectChanges(database, library: identityAtOpen?.identity)
        if serverContext != nil {
            // The exchange's tables a library-wide read names; a server library that never ran an exchange has none,
            // which reads as nothing hidden. Empty TEMP tables of this connection only; the library's data never changes.
            try database.execute("PRAGMA query_only = OFF")
            for table in ["ntp_hidden_feeds", "ntp_hidden_episodes"]
            where try database.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(table)]) == 0 {
                try database.execute(table == "ntp_hidden_feeds"
                    ? "CREATE TEMP TABLE ntp_hidden_feeds (feed_id INTEGER PRIMARY KEY, podcast_id TEXT, state TEXT, seq INTEGER)"
                    : "CREATE TEMP TABLE ntp_hidden_episodes (episode_id INTEGER PRIMARY KEY, feed_id INTEGER, seq INTEGER)")
            }
            try database.execute("PRAGMA query_only = ON")
        }
    }

    /// A read-only store (`init(readingOnly:)`).
    let readOnly: Bool
    /// The library database's file, for the readers' connections.
    let databaseURL: URL
    /// Whether the derived keys and counts (schema 21) are complete, readable without the store.
    nonisolated let derived: DerivedReadiness
    /// The graph's screen readers, opened at their first use (`readers()`).
    var openReaders: LibraryReaders?
    var readersClosed = false

    /// Interrupts the readers (closed by `closeReaders` before this), ends readiness waits and closes the library; the
    /// change stream finishes after it.
    public func close() throws {
        openReaders?.shutdown()
        readersClosed = true
        derived.close()
        try database.close()
        changes.finish()
    }

    public func feeds() throws -> [LibraryFeed] {
        try database.transaction(write: false) { try loadFeeds(skippingPinnedRemovals: true) }
    }

    /// The feeds of `feeds()`, in its order, as headers only (no episodes): what choosing the feeds a refresh covers reads.
    public func feedHeaders() throws -> [LibraryFeed] {
        try database.transaction(write: false) { try loadFeedHeaders(skippingPinnedRemovals: true) }
    }

    /// The feeds of `loadFeeds`, in its order, as headers only (no episode is read).
    func loadFeedHeaders(skippingPinnedRemovals: Bool = false) throws -> [LibraryFeed] {
        let shown = skippingPinnedRemovals ? hiddenFeedsCondition("id").map { " WHERE " + $0 } ?? "" : ""
        return try database.rows("SELECT id, record FROM feeds\(shown) ORDER BY title COLLATE NOCASE ASC, id").map { row in
            let feed: LibraryFeed = try decode(row[1])
            guard feed.id == row[0].integer, feed.episodes.isEmpty, feed.metadata.episodes.isEmpty else { throw FeedLibraryError.corruptRecord }
            return feed
        }
    }

    public func snapshot() throws -> FeedLibrarySnapshot {
        snapshotReads += 1
        return try database.transaction(write: false) { try loadSnapshot() }
    }

    /// `snapshot()` inside the caller's read transaction. `projection`: every episode as lists show it
    /// (`LibraryEpisode.listProjection`: no show notes, no chapters), the queue's included.
    func loadSnapshot(projection: Bool = false) throws -> FeedLibrarySnapshot {
        let feeds = try loadFeeds(skippingPinnedRemovals: true, projection: projection)
        var targets: [Int64: EpisodeMediaDeletionTarget] = [:]
        var shown: [Int64: LibraryEpisode] = [:]
        for feed in feeds {
            let link = feed.source.isLocalFeedSource ? try localFolder(feedID: feed.id) : nil
            for episode in feed.episodes {
                targets[episode.id] = Self.mediaDeletionTarget(episode: episode, feed: feed, localFolder: link)
                if projection { shown[episode.id] = episode }
            }
        }
        // The visible queue is of shown episodes: a projection takes them from the feeds just read.
        let queue = try projection ? try visibleQueueIDs().compactMap { shown[$0] } : loadVisibleQueue()
        return try FeedLibrarySnapshot(feeds: feeds, queue: queue, deletionTargets: targets,
                                       statisticsUnits: loadStatisticsUnits(of: feeds))
    }

    /// Statistics' read (schema 20): the feeds every library-wide read shows, with their episodes' statistics units.
    public func statisticsLibrary() throws -> LibraryStatisticsInput {
        try database.transaction(write: false) {
            // Statistics read no show notes or chapters (nothing decoded that is not shown).
            let feeds = try loadFeeds(skippingPinnedRemovals: true, projection: true)
            return LibraryStatisticsInput(feeds: feeds, units: try loadStatisticsUnits(of: feeds))
        }
    }

    /// The Downloads statistics' read: `feeds()` with each episode as lists show it (no show notes, no chapters).
    public func statisticsFeeds() throws -> [LibraryFeed] {
        try database.transaction(write: false) { try loadFeeds(skippingPinnedRemovals: true, projection: true) }
    }

    /// The statistics units of the given feeds' episodes.
    func loadStatisticsUnits(of feeds: [LibraryFeed]) throws -> [Int64: [LibraryStatisticsUnit]] {
        guard try database.scalar("SELECT EXISTS (SELECT 1 FROM statistics_units)") == 1 else { return [:] }
        let shown = Set(feeds.flatMap { $0.episodes.map(\.id) })
        return try database.statisticsUnits().filter { shown.contains($0.key) }
    }

    /// Test inspection API: not called by the app.
    func statistics(includeMarkedAsPlayed: Bool = true, timeFrom: Int64 = 0,
                           timeTo: Int64 = .max, now: Date = Date()) throws -> LibraryStatistics {
        try database.transaction(write: false) {
            let feeds = try loadFeeds(skippingPinnedRemovals: true)
            return try LibraryStatistics(feeds: feeds, units: loadStatisticsUnits(of: feeds), includeMarkedAsPlayed: includeMarkedAsPlayed,
                                         timeFrom: timeFrom, timeTo: timeTo, now: now)
        }
    }

    /// Statistics, prediction and feed preferences from the same read transaction.
    public func statisticsSnapshot(feedID: Int64, now: Date = Date(),
                                   timeZone: TimeZone = .current) throws -> FeedStatisticsSnapshot? {
        try database.transaction(write: false) {
            // A hidden podcast (being removed, or staged) has no statistics to show.
            // Statistics read no show notes or chapters.
            guard try !isHiddenFeed(feedID), let feed = try loadFeed(feedID, projection: true) else { return nil }
            return try FeedStatisticsSnapshot(feed: feed, units: loadStatisticsUnits(of: [feed]), now: now, timeZone: timeZone)
        }
    }

    /// Every feed, title order. `skippingPinnedRemovals`: library-wide reads leave out a podcast the server removed
    /// while the player still holds one of its episodes (PROTOCOL §6.8); only the player reads it then.
    func loadFeeds(skippingPinnedRemovals: Bool = false, projection: Bool = false) throws -> [LibraryFeed] {
        let pinned = skippingPinnedRemovals ? hiddenFeedsCondition("f.id").map { " WHERE " + $0 } ?? "" : ""
        let rows = try database.rows("SELECT f.id FROM feeds f\(pinned) ORDER BY f.title COLLATE NOCASE ASC, f.id")
        let feeds = try rows.map { row in
            guard let id = row[0].integer, let feed = try loadFeed(id, projection: projection) else { throw FeedLibraryError.corruptRecord }
            return feed
        }
        return feeds
    }

    /// The condition leaving out feeds no library-wide read shows: a pinned removal (PROTOCOL §6.8), in a server library
    /// also a podcast whose rows change in bounded transactions (staging or removing). A library
    /// kept at logout keeps its pinned removal in `pinned_feed_removals` (schema 20, PROTOCOL §15.4), which every library reads.
    func hiddenFeedsCondition(_ column: String) -> String? {
        let pinned = "\(column) NOT IN (SELECT feed_id FROM pinned_feed_removals)"
        guard serverContext != nil else { return pinned }
        return "\(column) NOT IN (SELECT feed_id FROM ntp_hidden_feeds) AND \(column) NOT IN (SELECT feed_id FROM ntp_podcasts WHERE pinned_removal = 1 AND feed_id IS NOT NULL) AND " + pinned
    }

    /// A podcast as the screens show it: a hidden one (a removal whose rows are going, or a podcast staged for a unit)
    /// is not there.
    public func feed(id: Int64) throws -> LibraryFeed? {
        try database.transaction(write: false) { try isHiddenFeed(id) ? nil : loadFeed(id) }
    }

    /// `feed(id:)` without its episodes: for callers that need only the podcast's own fields.
    public func listedFeedHeader(id: Int64) throws -> LibraryFeed? {
        try database.transaction(write: false) { try isHiddenFeed(id) ? nil : loadFeedHeader(id) }
    }

    /// `playbackFeed(id:)` without its episodes: the player's own displays (artwork, controls, Cast, chapters) need only the
    /// podcast's own fields.
    public func playbackFeedHeader(id: Int64) throws -> LibraryFeed? {
        try database.transaction(write: false) { try loadFeedHeader(id) }
    }

    /// The podcast of the player's episode, also while the server's removal of it waits for the player to leave the
    /// episode (PROTOCOL §6.8): for the player's own displays (artwork, controls, Cast, chapters), never for lists.
    public func playbackFeed(id: Int64) throws -> LibraryFeed? {
        try database.transaction(write: false) { try loadFeed(id) }
    }

    /// A feed no library-wide read shows: a pinned removal (`pinned_feed_removals`, every library), and in a server
    /// library a hidden podcast or the server's pinned removal.
    func isHiddenFeed(_ id: Int64) throws -> Bool {
        let pinned = try database.scalar("SELECT count(*) FROM pinned_feed_removals WHERE feed_id = ?", [.integer(id)]) > 0
        guard serverContext != nil else { return pinned }
        return try pinned || database.scalar("SELECT (SELECT count(*) FROM ntp_hidden_feeds WHERE feed_id = ?) + (SELECT count(*) FROM ntp_podcasts WHERE pinned_removal = 1 AND feed_id = ?)",
                                             [.integer(id), .integer(id)]) > 0
    }

    /// The episodes of `ids` the screens do not show: of a pinned removal, and in a server library also of a hidden
    /// feed, or staged and not yet revealed.
    func hiddenEpisodeIDs(_ ids: [Int64]) throws -> Set<Int64> {
        guard !ids.isEmpty else { return [] }
        let server = serverContext != nil
        guard try server || database.scalar("SELECT count(*) FROM pinned_feed_removals") > 0 else { return [] }
        let condition = server
            ? "e.feed_id IN (SELECT feed_id FROM ntp_hidden_feeds) OR e.feed_id IN (SELECT feed_id FROM ntp_podcasts WHERE pinned_removal = 1 AND feed_id IS NOT NULL) OR e.id IN (SELECT episode_id FROM ntp_hidden_episodes) OR e.feed_id IN (SELECT feed_id FROM pinned_feed_removals)"
            : "e.feed_id IN (SELECT feed_id FROM pinned_feed_removals)"
        var hidden: Set<Int64> = []
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = ContractJSON.array(ids[start..<min(ids.count, start + 500)].map(ContractJSON.integer)).canonicalText
            for row in try database.rows("SELECT e.id FROM episodes e WHERE e.id IN (SELECT value FROM json_each(?)) AND (\(condition))", [.text(chunk)]) {
                if let id = row[0].integer { hidden.insert(id) }
            }
        }
        return hidden
    }

    /// The feed's header (title, source, preferences) with no episodes: for callers that need no episode, so a
    /// per-episode loop does not re-read the whole feed after each change it makes.
    /// Test inspection API: not called by the app.
    func feedHeader(id: Int64) throws -> LibraryFeed? {
        try loadFeedHeader(id)
    }

    /// The header (no episodes) of a feed a refresh fetches: nil for a feed no library-wide read shows, as `feed(id:)`.
    func refreshHeader(id: Int64) throws -> LibraryFeed? {
        try database.transaction(write: false) { try isHiddenFeed(id) ? nil : loadFeedHeader(id) }
    }

    public func episode(id: Int64) throws -> LibraryEpisode? {
        try loadEpisode(id)
    }

    public func feedID(forEpisode id: Int64) throws -> Int64 {
        guard let feedID = try database.rows("SELECT feed_id FROM episodes WHERE id = ?", [.integer(id)]).first?.first?.integer else {
            throw FeedLibraryError.missingEpisode(id)
        }
        return feedID
    }

    public func insert(_ fetched: FetchedFeed, options: FeedRefreshOptions = FeedRefreshOptions(),
                       subscriptionState: FeedSubscriptionState = .subscribed) throws -> LibraryFeed {
        try Task.checkCancellation()
        let urlCredential = subscriptionState == .notSubscribed || options.isLocalFeed ? nil : try stageURLCredential(fetched.source)
        return try write(subscriptionState == .notSubscribed ? .preview : .subscribe, now: options.now) {
            activeCapture?.urlCredential = urlCredential
            return try insertRecord(fetched, options: options, subscriptionState: subscriptionState)
        }
    }

    /// One selected source row is one atomic commit. Reuse original identifying
    /// value matching/empty merge; never normalize URL, promote state or erase history.
    @discardableResult public func importOPMLEntry(_ entry: OPMLDocument.Entry,
                                                  now: Date = Date()) throws -> LibraryFeed {
        try Task.checkCancellation()
        // An OPML import would bring a library into the account from the phone (PROTOCOL §11.5).
        guard serverContext == nil else { throw ServerRecordingError.refusedInServerLibrary("OPML import") }
        return try database.transaction {
            // responseURL is transport-only metadata, unused by insertRecord.
            let fetched = FetchedFeed(feed: ParsedFeed(format: .rss, title: entry.title),
                source: entry.xmlURL, responseURL: URL(fileURLWithPath: "/"), validator: nil)
            var options = FeedRefreshOptions(now: now)
            options.refreshAttempt = Date(timeIntervalSince1970: 0)
            var feed = try insertRecord(fetched, options: options, subscriptionState: .subscribed)
            feed.markImportedPlaceholder()
            try saveHeader(feed)
            try Task.checkCancellation()
            return feed
        }
    }

    private func insertRecord(_ fetched: FetchedFeed, options: FeedRefreshOptions,
                              subscriptionState: FeedSubscriptionState) throws -> LibraryFeed {
        let candidate = LibraryFeed(id: 0, source: fetched.source, metadata: fetched.feed, episodes: [])
        // A server library matches only by normalized URL (PROTOCOL §3.3: different feeds are different podcasts, PROTOCOL §15.2).
        let serverMatch = try serverContext == nil ? nil : serverLibraryFeed(matching: fetched.source)
        for row in try database.rows("SELECT record FROM feeds ORDER BY title COLLATE NOCASE ASC, id") {
            let existing: LibraryFeed = try decode(row[0])
            let matches: Bool
            if serverContext != nil {
                matches = existing.id == serverMatch
            } else if let left = candidate.identifyingValue, let right = existing.identifyingValue {
                matches = left.utf16.elementsEqual(right.utf16)
            } else { matches = false }
            if matches {
                // Subscribing again to a podcast a kept library holds as a pinned removal clears it (PROTOCOL §15.4).
                if subscriptionState == .subscribed {
                    try database.execute("DELETE FROM pinned_feed_removals WHERE feed_id = ?", [.integer(existing.id)])
                }
                let result = try merge(fetched, feedID: existing.id, options: options, logRecovery: false)
                guard let reloaded = try loadFeed(result.feed.id) else { throw FeedLibraryError.corruptRecord }
                return reloaded
            }
        }
        var settings = options
        settings.validator = fetched.validator
        let id = try database.allocateID("feed")
        // A server library keeps the first item per derived episode, as the server does (PROTOCOL §9).
        let server = serverContext != nil && !options.isLocalFeed && !fetched.source.isLocalFeedSource
        let (population, keys) = server ? serverFirstPopulation(fetched) : (fetched, [])
        var feed = try FeedRefreshMerger.insert(population.feed, feedID: id, source: fetched.source, options: settings) {
            try database.allocateID("episode")
        }
        feed.subscriptionState = subscriptionState
        try save(feed)
        if server, let catalog = population.catalog {
            try saveServerFirstPopulation(feed, catalog: catalog, keys: keys)
            // Observed once the podcast's first canonical metadata arrives or its wait ends, with this parse, never filed.
            var entries: [ObservationEntry] = [.init(localID: nil, key: nil, evidence: nil, hash: catalog.feedHash, canonical: catalog.feedCanonical)]
            for (index, (episode, item)) in zip(feed.episodes, catalog.items).enumerated() where index < keys.count && !keys[index].isNone {
                entries.append(.init(localID: episode.id, key: keys[index], evidence: item.evidence, hash: item.hash, canonical: item.canonical))
            }
            try listObservations(feedID: feed.id, batchID: ContractIdentity.randomUUID(), fetchTime: try milliseconds(settings.refreshAttempt),
                                 entries: entries)
        }
        if !options.isLocalFeed && subscriptionState != .notSubscribed {
            try appendEffect(.init(feedID: id, date: options.now, kind: .feedAdded(source: feed.source)))
        }
        try Task.checkCancellation()
        guard let reloaded = try loadFeed(id) else { throw FeedLibraryError.corruptRecord }
        return reloaded
    }

    /// OnlineFeedViewActivity persists the preview before exposing its episodes.
    /// An identity match may already be subscribed; never demote that feed.
    public func preparePreview(_ fetched: FetchedFeed, now: Date = Date()) throws -> LibraryFeed {
        try preparePreview(fetched, now: now, stagedCredentialID: nil)
    }

    func preparePreview(_ fetched: FetchedFeed, now: Date, stagedCredentialID: UUID?) throws -> LibraryFeed {
        try Task.checkCancellation()
        return try write(.preview, now: now) {
            let result = try insertRecord(fetched, options: .init(now: now), subscriptionState: .notSubscribed)
            if result.subscriptionState == .notSubscribed {
                var preview = result; preview.keepUpdated = false
                try saveHeader(preview)
            }
            if let stagedCredentialID { try installFeedCredentialRecord(stagedCredentialID, feedID: result.id) }
            try Task.checkCancellation()
            guard let saved = try loadFeed(result.id) else { throw FeedLibraryError.corruptRecord }
            return saved
        }
    }

    /// DBWriter.setFeedState's preview-only subscription effects. The caller
    /// requests admitted refresh after commit; repeated taps cannot duplicate sync.
    @discardableResult public func subscribePreview(feedID: Int64, now: Date = Date()) throws -> Bool {
        try Task.checkCancellation()
        let header = try loadFeedHeader(feedID)
        let urlCredential = header?.subscriptionState == .notSubscribed ? try header.flatMap { try stageURLCredential($0.source) } : nil
        return try write(.subscribe, now: now) {
            activeCapture?.urlCredential = urlCredential
            guard var feed = try loadFeed(feedID) else { throw FeedLibraryError.missingFeed(feedID) }
            guard feed.subscriptionState == .notSubscribed else { return false }
            feed.subscriptionState = .subscribed; feed.keepUpdated = true
            try saveHeader(feed)
            if !feed.source.isLocalFeedSource {
                try appendEffect(.init(feedID: feed.id, date: now, kind: .feedAdded(source: feed.source)))
                for episode in FeedEpisodeSortOrder.dateNewest.sorted(feed.episodes) where episode.userState.playState == .played {
                    if let action = EpisodeStateSyncAction(episode: episode, feed: feed, played: true, providerConnected: true) {
                        try appendEffect(.init(feedID: feed.id, date: now, kind: .episodeStateChanged(action)))
                    }
                }
            }
            try Task.checkCancellation()
            return true
        }
    }

    public func applyRefresh(_ fetched: FetchedFeed, feedID: Int64,
                             options: FeedRefreshOptions = FeedRefreshOptions(),
                             manualRequestID: UUID? = nil) throws -> FeedRefreshResult {
        try Task.checkCancellation()
        return try write(.refresh, now: options.now) {
            try requireManualRefresh(manualRequestID)
            let result: FeedRefreshResult
            // A refresh identical to the feed's last applied one writes only its header; any other runs the merge.
            switch try refreshMemo(fetched, feedID: feedID, options: options) {
            case .unchanged(let header):
                result = try applyUnchangedRefresh(fetched, header: header, options: options)
            case .merge(let candidate):
                // A merge that may prove the feed unchanged arms its memo first: what the merge writes to the server tables
                // its episodes depend on retires it.
                let before = try candidate == nil ? nil : armRefreshMemo(feedID: feedID)
                // The armed feed is the stored one, read in this transaction: the merge starts from it rather than reading
                // the feed again.
                result = try merge(fetched, feedID: feedID, options: options, logRecovery: true, current: before?.before)
                if let candidate { try settleRefreshMemo(candidate, before: before, result: result, fetched: fetched) }
            }
            try stageCommittedEpisodeNotification(result.feed, manualRequestID: manualRequestID)
            try Task.checkCancellation()
            return result
        }
    }

    public func pendingEffects() throws -> [PendingFeedLibraryEffect] {
        try database.rows("SELECT id, record FROM pending_effects ORDER BY id").map(decodePendingEffect)
    }

    /// Only effects of the named kinds (`FeedLibraryEffect.Kind.name`), in creation order. A row whose kind was
    /// not recorded (it could not be decoded when the column was added) is included and filtered when decoded.
    func pendingEffects(kinds: Set<String>) throws -> [PendingFeedLibraryEffect] {
        let marks = Array(repeating: "?", count: kinds.count).joined(separator: ", ")
        return try database.rows("SELECT id, record FROM pending_effects WHERE kind IS NULL OR kind IN (\(marks)) ORDER BY id",
                                 kinds.sorted().map(LibrarySQLValue.text))
            .map(decodePendingEffect).filter { kinds.contains($0.effect.kind.name) }
    }

    func pendingEffect(id: Int64) throws -> PendingFeedLibraryEffect? {
        try database.rows("SELECT id, record FROM pending_effects WHERE id = ?", [.integer(id)]).first.map(decodePendingEffect)
    }

    private func decodePendingEffect(_ row: [LibrarySQLValue]) throws -> PendingFeedLibraryEffect {
        guard let id = row[0].integer else { throw FeedLibraryError.corruptRecord }
        return PendingFeedLibraryEffect(id: id, effect: try decode(row[1]))
    }

    public func acknowledgeEffect(id: Int64) throws {
        try database.execute("DELETE FROM pending_effects WHERE id = ?", [.integer(id)])
    }

    /// `current`: the stored feed when the caller has just read it in this transaction.
    func merge(_ fetched: FetchedFeed, feedID: Int64, options: FeedRefreshOptions,
                       logRecovery: Bool, current stored: LibraryFeed? = nil) throws -> FeedRefreshResult {
        guard let current = try stored ?? loadFeed(feedID) else { throw FeedLibraryError.missingFeed(feedID) }
        var settings = options
        settings.validator = fetched.validator
        // A server library identifies and files by the record-level parse (PROTOCOL §9.7); local folders never sync (PROTOCOL §7.6).
        let catalog = serverContext != nil && !current.source.isLocalFeedSource ? fetched.catalog ?? ServerCatalogRecords.interim(fetched.feed) : nil
        var result = try mergeSnapshot(fetched.feed, into: current, options: settings, catalog: catalog)
        if logRecovery { try recordRefreshRecovery(fetched, feedID: feedID, options: options, feed: &result.feed) }
        return result
    }

    /// After a refresh's merge: a success log entry when the feed's last one failed, and a permanent redirect followed by
    /// every feed of the old address.
    func recordRefreshRecovery(_ fetched: FetchedFeed, feedID: Int64, options: FeedRefreshOptions, feed: inout LibraryFeed) throws {
        let lastLog = try database.rows("SELECT record FROM refresh_log WHERE feed_id = ? ORDER BY completed_at DESC, id LIMIT 1", [.integer(feedID)]).first
        if let lastLog, !(try decode(lastLog[0]) as FeedLibraryLog).kind.isSuccessful {
            try appendLog(.init(feedID: feedID, date: options.now, title: fetched.feed.title, kind: .success))
        }
        if let updated = fetched.proposedSourceUpdate, !updated.utf16.elementsEqual(fetched.source.utf16) {
            for row in try database.rows("SELECT record FROM feeds") {
                var header: LibraryFeed = try decode(row[0])
                if header.source.utf16.elementsEqual(fetched.source.utf16) {
                    header.source = updated
                    try saveHeader(header)
                    if header.id == feedID { feed.source = updated }
                }
            }
        }
    }

    func mergeSnapshot(_ incoming: ParsedFeed, into current: LibraryFeed,
                               options: FeedRefreshOptions, catalog: ServerCatalogParse? = nil) throws -> FeedRefreshResult {
        let feedID = current.id
        let server = try catalog.map { try serverMerge(incoming, catalog: $0, into: current, options: options) }
        let result = try server?.0 ?? FeedRefreshMerger.merge(incoming, into: current, options: options) { try database.allocateID("episode") }
        let cleanup = result.removedEpisodes.isEmpty ? nil : try captureEpisodeRemoval(
            result.removedEpisodes, feed: current, now: options.now)
        // `current` was read in this transaction and nothing wrote its episodes since: the capture takes their before from it.
        try save(result.feed, previous: current, previousIsStored: refreshSharesReads)
        for item in server?.1 ?? [] { try saveServerLocalItem(item, feedID: feedID) }
        for episode in result.removedEpisodes {
            try captureEpisodeDeletion(episode, feedID: feedID)
            try database.execute("DELETE FROM episodes WHERE id = ? AND feed_id = ?", [.integer(episode.id), .integer(feedID)])
            downloadLogChanged()
        }
        for duplicate in result.duplicates {
            let title: String?
            switch duplicate {
            case .repeatedEpisode(let ignored, _): title = ignored.title
            case .changedIdentifier(_, let replacement, _): title = replacement.title
            }
            // Android stores only the reason text (title, ID and URL of both episodes), not the episodes.
            try appendLog(.init(feedID: feedID, date: options.now, title: title, kind: .duplicate(duplicate.logged),
                                detail: duplicate.detail))
        }
        if !result.completedEpisodeSync.isEmpty {
            try appendEffect(.init(feedID: feedID, date: options.now,
                                   kind: .syncCompletedEpisodes(source: current.source, episodes: result.completedEpisodeSync)))
        }
        if let cleanup {
            try removePendingQueueEpisodes(cleanup.episodeIDs)
            try saveQueue(loadQueue())
            try appendEffect(.init(feedID: feedID, date: options.now,
                kind: .removeEpisodes(result.removedEpisodes), removedEpisodeCleanup: cleanup))
        }
        if !result.queueEpisodeIDs.isEmpty {
            let queued = Set(result.queueEpisodeIDs)
            try appendEffect(.init(feedID: feedID, date: options.now, kind: .queueEpisodes(result.queueEpisodeIDs),
                                   releases: catalog == nil ? nil : activeCapture?.discovery?.releases.filter { queued.contains($0.localID) }))
        }
        return result
    }

    /// The feed's header (preferences, source, metadata) without its episodes (`episodes` is empty). For
    /// callers that need only header fields: a whole-feed load re-reads every episode record of a feed
    /// whose episodes just changed, which made per-episode actions cost O(feed size) each.
    func loadFeedHeader(_ id: Int64) throws -> LibraryFeed? {
        guard let row = try database.rows("SELECT record FROM feeds WHERE id = ?", [.integer(id)]).first else { return nil }
        let feed: LibraryFeed = try decode(row[0])
        guard feed.id == id, feed.episodes.isEmpty else { throw FeedLibraryError.corruptRecord }
        return feed
    }

    /// `projection`: each episode as lists show it (`LibraryEpisode.listProjection`), its show notes and chapters left out
    /// by SQLite, never decoded. A projection is only ever read: no writer takes one (`EpisodeWriteScope`).
    func loadFeed(_ id: Int64, projection: Bool = false) throws -> LibraryFeed? {
        guard let row = try database.rows("SELECT record FROM feeds WHERE id = ?", [.integer(id)]).first else { return nil }
        var feed: LibraryFeed = try decode(row[0])
        guard feed.id == id, feed.episodes.isEmpty, feed.metadata.episodes.isEmpty else { throw FeedLibraryError.corruptRecord }
        feedEpisodeReads += 1
        // A server library leaves out new episodes staged for a unit that has not revealed them.
        let hidden = serverContext != nil ? " AND id NOT IN (SELECT episode_id FROM ntp_hidden_episodes)" : ""
        let record = projection ? LibraryEpisode.listProjectionSQL("record") : "record"
        feed.episodes = try database.rows("SELECT id, \(record) FROM episodes WHERE feed_id = ?\(hidden) ORDER BY pubdate DESC, id", [.integer(id)])
            .map { row in
                let episode: LibraryEpisode = try projection ? decodeProjection(row[1]) : decode(row[1])
                guard row[0].integer == episode.id else { throw FeedLibraryError.corruptRecord }
                return episode
            }
        return feed
    }

    /// An episode projection (`LibraryEpisode.listProjectionSQL`): JSON text.
    func decodeProjection(_ value: LibrarySQLValue) throws -> LibraryEpisode {
        guard case .text = value, let data = value.recordData else { throw FeedLibraryError.corruptRecord }
        recordsDecoded += 1
        episodeRecordsDecoded += 1
        return try JSONDecoder.libraryRecord(LibraryEpisode.self, from: data)
    }

    func loadEpisode(_ id: Int64) throws -> LibraryEpisode? {
        guard let row = try database.rows("SELECT record FROM episodes WHERE id = ?", [.integer(id)]).first else { return nil }
        let episode: LibraryEpisode = try decode(row[0])
        guard episode.id == id else { throw FeedLibraryError.corruptRecord }
        return episode
    }

    /// With `previous` (the stored feed, decoded), only episodes that differ from it are saved: a refresh
    /// usually changes none, and encoding and comparing every record of the library was most of its cost.
    /// `previousIsStored`: `previous` holds exactly the stored rows (read in this transaction, nothing written to its
    /// episodes since), so a server library's capture takes an episode's before from it instead of reading it again.
    func save(_ feed: LibraryFeed, previous: LibraryFeed? = nil, previousIsStored: Bool = false) throws {
        try saveHeader(feed)
        var stored: [Int64: LibraryEpisode] = [:]
        if let previous {
            stored.reserveCapacity(previous.episodes.count)
            for episode in previous.episodes { stored[episode.id] = episode }
        }
        for episode in feed.episodes where stored[episode.id] != episode {
            try saveEpisode(episode, feedID: feed.id, before: previousIsStored ? stored[episode.id] : nil, scope: .metadata)
        }
    }

    func saveHeader(_ feed: LibraryFeed) throws {
        var header = feed
        header.episodes = []
        try captureHeaderWrite(header)
        // Unchanged rows are not rewritten (no page or WAL write, no change-generation bump): every refresh
        // saves the whole feed, and rewriting unchanged records cost ~74 MB per refresh-all of a large library.
        try database.execute("INSERT INTO feeds(id, title, record) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET title = excluded.title, record = excluded.record WHERE feeds.title IS NOT excluded.title OR feeds.record IS NOT excluded.record",
                             [.integer(feed.id), feed.metadata.title.map(LibrarySQLValue.text) ?? .null,
                              .blob(try Self.encodeRecord(header))])
    }

    /// What an episode write may change of the stored episode: a write that only meant to change user state
    /// can never rewrite the details (show notes, chapters) from a partial copy of the episode.
    public enum EpisodeWriteScope: Sendable {
        /// User state only: the stored details and stored-chapters flag stay exactly (the default).
        case userState
        /// Also what the media file itself tells: its size, duration, embedded picture and pending metadata.
        case media
        /// Any field: a refresh merge, a local folder's metadata, a new episode.
        case metadata

        /// The SQL condition over the stored record `o` and the new one `n` (record JSON text) that the scope allows.
        func allows(_ o: String, _ n: String) -> String? {
            let chapters = "json_extract(\(o), '$.hasStoredChapters') IS json_extract(\(n), '$.hasStoredChapters')"
            switch self {
            case .userState: return "json_extract(\(o), '$.details') IS json_extract(\(n), '$.details') AND \(chapters)"
            case .media:
                func fixed(_ r: String) -> String {
                    "json_remove(json_extract(\(r), '$.details'), '$.media.size', '$.media.durationMilliseconds', '$.media.hasEmbeddedPicture', '$.media.metadataPending')"
                }
                return "\(fixed(o)) IS \(fixed(n)) AND \(chapters)"
            case .metadata: return nil
            }
        }

        /// The same rule over decoded values (records whose stored text is spelled differently from today's encoding).
        func allows(stored: LibraryEpisode, new: LibraryEpisode) -> Bool {
            guard stored.hasStoredChapters == new.hasStoredChapters else { return false }
            switch self {
            case .userState: return stored.details == new.details
            case .media:
                func fixed(_ details: ParsedEpisode) -> ParsedEpisode {
                    var details = details
                    details.media?.size = 0; details.media?.durationMilliseconds = 0
                    details.media?.hasEmbeddedPicture = nil; details.media?.metadataPending = nil
                    return details
                }
                return fixed(stored.details) == fixed(new.details)
            case .metadata: return true
            }
        }
    }

    /// `before`: the stored episode, when the caller holds it (else it is read when needed). `scope`: what of the stored
    /// episode the write may change; a write outside it throws `invalidMutation` and changes nothing.
    func saveEpisode(_ episode: LibraryEpisode, feedID: Int64, explicitStateIntent: Bool = false, before: LibraryEpisode? = nil,
                     scope: EpisodeWriteScope = .userState) throws {
        guard episode.id > 0, let date = episode.details.publicationDate else { throw FeedLibraryError.invalidMutation }
        try captureEpisodeWrite(episode, feedID: feedID, before: before)
        if try database.scalar("SELECT count(*) FROM episode_swipe_undo WHERE episode_id = ?", [.integer(episode.id)]) > 0 {
            let previous = try loadEpisode(episode.id)
            var replaced = previous == nil || !exactlyEqual(previous?.details.media?.url, episode.details.media?.url)
            // Optional URL equality also distinguishes media-less items from
            // attached media. A new media object must not inherit an old offer.
            if (previous?.details.media == nil) != (episode.details.media == nil) { replaced = true }
            if let row = try database.rows("SELECT record FROM feeds WHERE id = ?", [.integer(feedID)]).first {
                let header: LibraryFeed = try decode(row[0])
                if header.source.isLocalFeedSource, let previous {
                    replaced = replaced || !exactlyEqual(previous.details.link, episode.details.link)
                        || previous.details.media?.size != episode.details.media?.size
                }
            }
            if explicitStateIntent || previous?.userState.playState != episode.userState.playState || replaced {
                try database.execute("DELETE FROM episode_swipe_undo WHERE episode_id = ?", [.integer(episode.id)])
            }
        }
        // Byte-identical records are not rewritten (see `saveHeader`); `encodeRecord` is deterministic, so an
        // unchanged episode encodes to its stored bytes.
        let record = try Self.encodeRecord(episode), pubdate = try milliseconds(date)
        func upsert(guarded: Bool) throws {
            let allowed = guarded ? scope.allows("CAST(episodes.record AS TEXT)", "CAST(excluded.record AS TEXT)").map { " AND (\($0))" } ?? "" : ""
            try database.execute("INSERT INTO episodes(id, feed_id, pubdate, record) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET pubdate = excluded.pubdate, record = excluded.record WHERE episodes.feed_id = excluded.feed_id AND (episodes.pubdate IS NOT excluded.pubdate OR episodes.record IS NOT excluded.record)\(allowed)",
                                 [.integer(episode.id), .integer(feedID), .integer(pubdate), .blob(record)])
        }
        try upsert(guarded: true)
        if try database.scalar("SELECT changes()") != 1 {
            // Unchanged is fine; a row owned by another feed is not, and neither is a change outside the scope.
            guard let row = try database.rows("SELECT feed_id, pubdate IS ? AND record IS ?, record FROM episodes WHERE id = ?",
                                              [.integer(pubdate), .blob(record), .integer(episode.id)]).first,
                  row[0].integer == feedID else { throw FeedLibraryError.invalidMutation }
            if row[1].integer != 1 {
                // The guard compares the stored JSON as written; a record written with another spelling of equal values is
                // judged on its decoded values.
                let stored: LibraryEpisode = try decode(row[2])
                guard scope.allows(stored: stored, new: episode) else { throw FeedLibraryError.invalidMutation }
                try upsert(guarded: false)
            }
        }
    }

    func appendLog(_ log: FeedLibraryLog) throws {
        try database.execute("INSERT INTO refresh_log(feed_id, completed_at, record) VALUES (?, ?, ?)",
                             [.integer(log.feedID), .integer(try milliseconds(log.date)), .blob(try JSONEncoder().encode(log))])
        downloadLogChanged()
    }

    /// Durable work for later consumers goes to `pending_effects`; a synchronization-only kind is handed to the
    /// outbox here (when an account is connected and `queueSync`) and not kept, since nothing reads it later.
    func appendEffect(_ effect: FeedLibraryEffect, queueSync: Bool = true) throws {
        if !effect.kind.isSynchronizationOnly {
            try database.execute("INSERT INTO pending_effects(kind, record) VALUES (?, ?)",
                                 [.text(effect.kind.name), .blob(try JSONEncoder().encode(effect))])
        }
        // Its consumer runs after this transaction (the store serializes it behind the commit).
        if case .queueEpisodes = effect.kind { for listener in queueEffectListeners.values { listener.yield(()) } }
        if queueSync { try queueSynchronizationEffect(effect) }
    }

    /// Feed header and episode records: sorted keys make equal values encode to equal bytes (plain
    /// `JSONEncoder` key order varies), so unchanged records are recognised and not rewritten.
    private static func encodeRecord<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    /// An episode's stored record bytes, as `saveEpisode` writes them, for a conversion rewriting records directly:
    /// `stored` is the record it replaces, read in the same transaction, whose details it must keep exactly.
    static func encodedEpisodeRecord(_ episode: LibraryEpisode, replacing stored: LibraryEpisode) throws -> Data {
        guard EpisodeWriteScope.userState.allows(stored: stored, new: episode) else { throw FeedLibraryError.invalidMutation }
        return try encodeRecord(episode)
    }
    /// A new episode's record bytes (no stored record to keep), as `saveEpisode` writes them: tests writing rows directly.
    static func newEpisodeRecord(_ episode: LibraryEpisode) throws -> Data { try encodeRecord(episode) }
    /// A feed header's stored record bytes, as `saveHeader` writes them.
    static func encodedFeedRecord(_ feed: LibraryFeed) throws -> Data { try encodeRecord(feed) }

    func decode<T: Decodable>(_ value: LibrarySQLValue) throws -> T {
        guard let data = value.data else { throw FeedLibraryError.corruptRecord }
        recordsDecoded += 1
        if T.self == LibraryEpisode.self { episodeRecordsDecoded += 1 }
        return try JSONDecoder.libraryRecord(T.self, from: data)
    }

    func milliseconds(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite, value >= Double(Int64.min), value < Double(Int64.max) else {
            throw FeedLibraryError.invalidMutation
        }
        return Int64(value)
    }
}

/// Work a store's connection did (`FeedLibraryStore.work`); the difference of two readings is what happened between them.
struct StoreWork: Equatable, Sendable, CustomStringConvertible {
    var recordsDecoded: Int, statements: Int, steps: Int64, pages: Int64, commits: Int
    static func - (a: StoreWork, b: StoreWork) -> StoreWork {
        .init(recordsDecoded: a.recordsDecoded - b.recordsDecoded, statements: a.statements - b.statements,
              steps: a.steps - b.steps, pages: a.pages - b.pages, commits: a.commits - b.commits)
    }
    var description: String {
        "\(recordsDecoded) records decoded, \(statements) statements, \(steps) VM steps, \(pages) pages, \(commits) commits"
    }
}
