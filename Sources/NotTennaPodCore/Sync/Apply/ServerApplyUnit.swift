import Foundation
import Synchronization

/// Why an apply unit did not commit (PROTOCOL §6.8). Nothing of the unit is visible then.
enum ServerApplyError: Error, Equatable, Sendable {
    /// The unit needs feed-credential secrets this library has not fetched (PROTOCOL §6.8): fetch, then apply again.
    case missingSecrets(Set<String>)
    /// The unit's work is above the direct budget: build a shadow and publish (PROTOCOL §6.8).
    case overBudget(Int)
    /// The live cursor is not the commit's predecessor (another lineage, or a commit missing).
    case outOfOrder(live: Int64?, commit: Int64)
    /// A shadow's reserved local IDs ran out.
    case needsLocalIDs
    /// What a staged publication was built on moved (the base: another lineage, an earlier commit): it is built again.
    case stale
    /// A retained publication cannot be switched within the publication budget now (PROTOCOL §6.8): a local change since
    /// it was built meets a structural dependency of its plan or its projection context, or the switch's work is over
    /// the budget. Nothing was written; it is kept and published as a whole when the budget is relaxed (the pause).
    case deferred(String)
    /// A plan whose queue still needs projecting reached the writer: nothing of it is written (a queue is written only
    /// once computed).
    case unprojectedQueue
    /// The app came to the foreground or audio started since a publication over the budget was allowed:
    /// nothing was written, and the unit waits.
    case ineligible
}

/// Whether a publication over the budget may still run: the app moves it on at every foreground or
/// playback transition, and a publication admitted to the store checks that it has not moved since the engine
/// allowed it, so one queued behind other store work never starts once someone is using the app.
public final class ServerPublicationEligibility: Sendable {
    private let generation = Mutex<UInt64>(0)
    private let deferred = Mutex<UInt64?>(nil)
    public init() {}
    /// A scene came to the foreground or left it, or playback started or stopped.
    public func changed() { generation.withLock { $0 &+= 1 } }
    var current: UInt64 { generation.withLock { $0 } }

    /// A publication admitted in the background while audio plays was deferred (over the background budget, or a local
    /// change it cannot re-project): until the next transition, large publications wait for the pause instead of trying
    /// again.
    func noteDeferred(_ at: UInt64) { deferred.withLock { $0 = at } }
    var deferredSinceTransition: Bool {
        let now = current
        return deferred.withLock { $0 == now }
    }
}

/// The kinds of synchronization transaction on the live library and their hold budgets while audio plays (PROTOCOL §6.8), in
/// milliseconds: what `SyncLoadStarvationTests` asserts and the sync log's measures name.
public enum ServerTransactionKind {
    public static let directUnit = "direct unit"
    public static let publication = "publication"
    public static let backgroundPublication = "background publication"
    public static let staging = "staging"
    public static let shownAhead = "shown ahead"
    public static let hiddenRemoval = "hidden removal"
    public static let stagingTakeOut = "staging take-out"
    public static let bookkeeping = "bookkeeping"

    public static let budgets: [String: Double] = [
        directUnit: 20, publication: 100, backgroundPublication: 500, staging: 100, shownAhead: 100, hiddenRemoval: 100,
        stagingTakeOut: 100, bookkeeping: 20,
    ]
}

extension FeedLibraryStore {
    /// Labels the write transactions `body` commits on the store's connection as `kind`, so each one's hold of the write
    /// lock is measured (`LibrarySQLite.transactionTimes`).
    func syncTransactions<T>(_ kind: String, _ body: () throws -> T) rethrows -> T {
        let previous = database.transactionKind
        database.transactionKind = kind
        defer { database.transactionKind = previous }
        return try body()
    }

    /// The longest synchronization transaction of each kind since the last call.
    func takeSyncTransactionTimes() -> [String: LibraryTransactionTime] { database.takeTransactionTimes() }
}

/// A publication's admission: valid while no transition happened since the engine's checks. Admitted in
/// the background while audio plays, it carries the background publication budget: the switch, a whole publication
/// in one transaction, is bounded by it, and anything over it waits for the pause.
struct ServerPublicationTicket: Sendable {
    let eligibility: ServerPublicationEligibility
    let generation: UInt64
    /// Row writes the publication may make (nil: no limit, nothing plays and nobody uses the app).
    var budget: Int? = nil
    var isCurrent: Bool { eligibility.current == generation }
}

extension FeedLibraryStore {
    /// A retained publication's limit (PROTOCOL §6.8): the caller's `workLimit` (the 1,000-row budget while audio plays or
    /// someone uses the app), else its ticket's background budget, else none (whole, as at a pause). Only with none is a
    /// deferred publication projected again as a whole; a deferral under a ticket's budget is noted for the engine.
    static func publicationLimit(workLimit: Int?, ticket: ServerPublicationTicket?) -> Int? { workLimit ?? ticket?.budget }

    static func deferred(_ reason: String, workLimit: Int?, ticket: ServerPublicationTicket?) -> ServerApplyError {
        if workLimit == nil, let ticket, ticket.budget != nil { ticket.eligibility.noteDeferred(ticket.generation) }
        return .deferred(reason)
    }
}

/// What an applied unit changed, for the engine, the sync log and the screens.
struct ServerUnitResult: Sendable {
    struct Retired: Sendable, Equatable {
        var opID: String
        var type: String
        var outcome: String?
        var reason: String?
    }
    var seq: Int64
    var work = 0
    /// Rows the unit's transaction wrote (SQLite's change count): what its lock hold scales with.
    var rowsWritten = 0
    var retired: [Retired] = []
    /// Feeds whose deletion effects the feed-deletion coordinator now drains.
    var deletedFeeds: [Int64] = []
    /// Episodes were removed (a pinned removal's other episodes, or Force full synchronization's obsolete ones):
    /// their files go through the feed-deletion coordinator too.
    var removedEpisodes = false
    /// A large removal was hidden: its rows are deleted in bounded transactions after the unit.
    var hiddenRemovals = false
    var queueChanged = false
    /// Releases arrived (admissions new to the discovery ledger, PROTOCOL §9.9): to download and notify about.
    var releases = false
    /// Podcasts merged whose per-feed settings outside the database the app carries (`ntp_feed_merges`, PROTOCOL §9.7).
    var feedsMerged = false
    var accountPoliciesChanged = false
    /// The queue before the unit when the unit removed more than 75% of it (PROTOCOL §15 queue safeguard).
    var queueSafeguard: ContractJSON?
    var transportConflict = false
    var alreadyApplied = false
    /// How long the unit held the live write lock (its transaction, commit included), in milliseconds (PROTOCOL §6.8).
    var lockMilliseconds: Double = 0
    /// Entities of a staged publication's scope that local changes touched since it was built, re-projected at its
    /// switch (`ServerTouchedRebase`).
    var rebased = 0
    /// A retained publication was published as a whole at the pause (a local change since its staging needed its whole
    /// original projection): its staging taken out and the unit applied from the intact local rows.
    var wholeAtPause = false
    /// Built in a shadow and published.
    var published = false
    /// Published under the background budget, while audio plays and no scene is in the foreground.
    var background = false
}

/// The unit's context computed outside the live lock.
struct ServerUnitInput: Sendable {
    var commit: ServerCommit
    var cursor: SyncCursor
    /// The pull view's `install_watermark` (acknowledgement never goes above it).
    var watermark: Int64?
    var now: Int64
    /// Test failure injection inside the unit's transaction (crash permutations): throwing rolls it back.
    var crash: (@Sendable (String) throws -> Void)?
}

/// Auxiliary exchange tables of a server library, created when the library opens and before any exchange (no schema
/// change: server libraries are new, and every statement is idempotent).
enum ServerExchangeTables {
    static let statements = [
        // Episodes whose remote position or duration waits for the player (PROTOCOL §6.8).
        "CREATE TABLE IF NOT EXISTS ntp_deferred_pins (episode_id TEXT PRIMARY KEY, fields INTEGER NOT NULL)",
        // Listening this library did that no exported fact represents yet: every playback save and
        // end marks its episode, in the same transaction, with the fields it changed (`ServerEpisodeFields` bits)
        // and whether it changed the episode's queue membership. Projections keep those fields as this device has
        // them. The recorder clears a mark when its exported facts represent the fields; until then
        // it stays.
        "CREATE TABLE IF NOT EXISTS ntp_local_playback (episode_id INTEGER PRIMARY KEY, fields INTEGER NOT NULL, queue INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL)",
        // Projected episodes the server no longer holds that a repair had to keep because the player or a pending
        // fact held them: removed when the hold retires, unless the server holds them again. Kept
        // apart from the base, whose identity record the repair removes.
        "CREATE TABLE IF NOT EXISTS ntp_deferred_absence (local_id INTEGER PRIMARY KEY, episode_id TEXT NOT NULL, feed_id INTEGER NOT NULL)",
        // Queue safeguards (PROTOCOL §15) written in the same transaction as the unit that removed most of the queue, and
        // moved durably into `sync.sqlite` afterwards: a crash between the two loses none.
        "CREATE TABLE IF NOT EXISTS ntp_pending_safeguards (id INTEGER PRIMARY KEY AUTOINCREMENT, record BLOB NOT NULL)",
        // What the person asked for and the library still owes: `full_synchronization` from the
        // tap until a repair is durably published (the publication deletes it in its own transaction).
        "CREATE TABLE IF NOT EXISTS ntp_requests (name TEXT PRIMARY KEY, created_at INTEGER NOT NULL)",
        // Podcasts no library-wide read shows while their rows change in bounded transactions:
        // `staging`, a new podcast whose episodes are being inserted (revealed by its commit's unit); `removing`, a
        // removed podcast whose rows are being deleted (the row goes with its feed). `seq` is the commit.
        "CREATE TABLE IF NOT EXISTS ntp_hidden_feeds (feed_id INTEGER PRIMARY KEY, podcast_id TEXT, state TEXT NOT NULL CHECK(state IN ('staging', 'removing')), seq INTEGER NOT NULL DEFAULT 0)",
        // What staging inserted into the base (`records`: [entity, id, field_group] keys) and the mappings
        // (`episodes`: wire episode IDs), one row per staging transaction, so a staging that never reached its unit
        // is taken out again (ServerStaging.swift). The unit that reveals its podcasts clears them.
        "CREATE TABLE IF NOT EXISTS ntp_staging (id INTEGER PRIMARY KEY AUTOINCREMENT, seq INTEGER NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('records', 'episodes')), keys BLOB NOT NULL)",
        // New episodes staged for a unit that has not revealed them yet: no list shows them.
        "CREATE TABLE IF NOT EXISTS ntp_hidden_episodes (episode_id INTEGER PRIMARY KEY, feed_id INTEGER NOT NULL, seq INTEGER NOT NULL DEFAULT 0)",
        // The episodes that name a file: removal cleanup checks file ownership without reading the rest.
        "CREATE INDEX IF NOT EXISTS ntp_episodes_by_file ON episodes(json_extract(CAST(record AS TEXT), '$.userState.localFileURL'))",
        // Base records a recovery holds as this library had them: at the recovery's base
        // switch, each record whose provenance names a node still waiting for another device (`nodes`) is copied here,
        // and every projection reads it in place of the base until a commit writes that record again or none of its
        // nodes waits any more. The base itself is the server's.
        "CREATE TABLE IF NOT EXISTS ntp_recovery_holds (entity TEXT NOT NULL, id TEXT NOT NULL, field_group TEXT NOT NULL, value BLOB, provenance TEXT, nodes TEXT NOT NULL, PRIMARY KEY(entity, id, field_group))",
        "CREATE INDEX IF NOT EXISTS ntp_recovery_holds_by_group ON ntp_recovery_holds(entity, field_group)",
        // Played time reads an episode's playback sessions at every save (PROTOCOL §8.8).
        "CREATE INDEX IF NOT EXISTS ntp_sessions_by_episode ON ntp_sessions(episode_id)",
        "CREATE INDEX IF NOT EXISTS ntp_sessions_by_local ON ntp_sessions(local_session)",
        // Each local episode's identity in a server library (PROTOCOL §9.7): the kind and value it was identified by and
        // the evidence it was last observed with (GUID, normalized enclosure, the item's own publication time or none),
        // which its row cannot give back (a reused GUID's later occurrence, a missing date stored as the refresh time).
        // A pending registration's episodes have no wire ID yet. Goes with its episode (the cascade).
        "CREATE TABLE IF NOT EXISTS ntp_local_items (local_id INTEGER PRIMARY KEY REFERENCES episodes(id) ON DELETE CASCADE, feed_id INTEGER NOT NULL, kind TEXT NOT NULL, value TEXT NOT NULL, guid TEXT, enclosure TEXT, publication_time INTEGER)",
        // Observations still to record (PROTOCOL §9.4): a first population, a waiting podcast's batch, a large batch.
        // Each row keeps the parse it observes (its occurrence evidence and the record fields' canonical bytes); a row
        // without `local_id` is the podcast's record. Bounded transactions record up to 200 and remove their rows, so a
        // relaunch continues where it stopped. Goes with its episode or feed (the cascade).
        "CREATE TABLE IF NOT EXISTS ntp_observation_work (id INTEGER PRIMARY KEY AUTOINCREMENT, feed_id INTEGER NOT NULL REFERENCES feeds(id) ON DELETE CASCADE, local_id INTEGER REFERENCES episodes(id) ON DELETE CASCADE, batch_id TEXT NOT NULL, fetch_time INTEGER NOT NULL, hash TEXT NOT NULL, kind TEXT, value TEXT, guid TEXT, enclosure TEXT, publication_time INTEGER, title TEXT, atom INTEGER, fields BLOB NOT NULL)",
        "CREATE UNIQUE INDEX IF NOT EXISTS ntp_observation_work_episode ON ntp_observation_work(local_id) WHERE local_id IS NOT NULL",
        "CREATE UNIQUE INDEX IF NOT EXISTS ntp_observation_work_feed ON ntp_observation_work(feed_id) WHERE local_id IS NULL",
        // For the cascades and the rows a transaction takes and removes.
        "CREATE INDEX IF NOT EXISTS ntp_observation_work_local ON ntp_observation_work(local_id)",
        "CREATE INDEX IF NOT EXISTS ntp_observation_work_batch ON ntp_observation_work(feed_id, batch_id, id)",
        // A podcast merge of two feeds here (PROTOCOL §9.7) whose device-only settings outside the database (per-feed
        // speed and skip silence, in the library's playback file) the app still has to carry to the survivor: written
        // with the merge, removed by the app once its copy is saved.
        "CREATE TABLE IF NOT EXISTS ntp_feed_merges (source_feed INTEGER PRIMARY KEY, survivor_feed INTEGER NOT NULL)",
    ]

    /// Indexes a unit's statements use inside the live lock (their cost is what the commit changes, not the library's
    /// size). Created with a new library's tables (empty, at once); a library from before them gets them at its first
    /// exchange while nothing plays (`ensureServerIndexes`), never while it opens: on a large library the build takes
    /// tens of milliseconds, and the queries are correct, only slower, without them.
    static let indexes = [
        // The queue's projection reads the queue membership records that queue their episode inside a unit: these, never
        // every episode record nor every membership an episode ever had.
        "CREATE INDEX IF NOT EXISTS ntp_records_in_queue ON ntp_records(id) WHERE entity = 'episode' AND field_group = 'queue_membership' AND CAST(value AS TEXT) LIKE '%\"in_queue\":true%'",
        // A podcast's episodes by wire ID (a podcast created, merged or estimated inside or before a unit), never a scan
        // of every mapping.
        "CREATE INDEX IF NOT EXISTS ntp_episodes_by_podcast ON ntp_episodes(podcast_id)",
    ]

    static func create(_ database: LibrarySQLite) throws {
        // The earlier `ntp_observation_work` (keyed by `local_id`, without the parse; never shipped, only in development
        // libraries) is recreated: its observations are made again by the next refresh.
        let columns = try database.rows("PRAGMA table_info(ntp_observation_work)").compactMap { $0[1].text }
        if !columns.isEmpty, !columns.contains("fields") { try database.execute("DROP TABLE ntp_observation_work") }
        for statement in statements { try database.execute(statement) }
        // Added to `ntp_library` without a schema version (nothing of sync has shipped): the requests a server
        // refused with `version_unsupported`, comma-separated (`ServerRefusedRequest`).
        if try !database.rows("PRAGMA table_info(ntp_library)").contains(where: { $0[1].text == "version_refusals" }) {
            try database.execute("ALTER TABLE ntp_library ADD COLUMN version_refusals TEXT")
        }
    }
}

extension FeedLibraryStore {
    func ensureServerExchangeTables() throws { try ServerExchangeTables.create(database) }

    /// Builds `ServerExchangeTables.indexes` a library from before them lacks. Returns whether it built any.
    @discardableResult
    func ensureServerIndexes() throws -> Bool {
        guard serverContext != nil else { return false }
        let names = ["ntp_records_in_queue", "ntp_episodes_by_podcast"]
        let missing = try names.filter { try database.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = ?", [.text($0)]) == 0 }
        guard !missing.isEmpty else { return false }
        try database.transaction { for statement in ServerExchangeTables.indexes { try database.execute(statement) } }
        return true
    }

    /// Marks the episodes a playback save or end changed. Runs inside that write's transaction,
    /// outside the recorder's savepoint, so the mark is never lost when recording fails; the recorder clears what the
    /// facts it records represent. Played time follows the server's rule from the session journal (PROTOCOL §8.8), and
    /// a write that is no listening (a pending session's save, an adoption) marks nothing.
    func markLocalPlayback(_ capture: ChangeCapture, intent: ServerIntent) throws {
        let queueAfter = intent == .playbackEnd ? Set(try queueEpisodeIDs()) : Set(capture.queueBefore)
        let queueBefore = Set(capture.queueBefore)
        let now = try milliseconds(Date())
        for (id, change) in capture.episodes where !capture.playbackUnmarked.contains(id) {
            guard let before = change.before?.userState, let after = change.after?.userState else { continue }
            var fields: ServerEpisodeFields = []
            if before.positionMilliseconds != after.positionMilliseconds { fields.insert(.position) }
            if before.lastPlayedTimeMilliseconds != after.lastPlayedTimeMilliseconds { fields.insert(.lastPlayed) }
            if before.lastPlayedHistoryMilliseconds != after.lastPlayedHistoryMilliseconds { fields.insert(.history) }
            if before.playState != after.playState { fields.insert(.playState) }
            let queue = queueBefore.contains(id) != queueAfter.contains(id)
            guard !fields.isEmpty || queue else { continue }
            try database.execute("INSERT INTO ntp_local_playback(episode_id, fields, queue, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(episode_id) DO UPDATE SET fields = fields | excluded.fields, queue = max(queue, excluded.queue), updated_at = excluded.updated_at",
                                 [.integer(id), .integer(Int64(fields.rawValue)), .integer(queue ? 1 : 0), .integer(now)])
        }
    }

    // MARK: - Direct units (PROTOCOL §6.8)

    /// Applies one verified commit as one live transaction: base records, nodes and frontier, registration
    /// resolutions, retirements of this library's facts, the projection onto rows, the cursor. Throws
    /// `ServerApplyError.overBudget` (rolled back) when its work exceeds `maxWork`.
    func applyServerUnit(_ input: ServerUnitInput, history: ServerHistoryOracle?, maxWork: Int?) throws -> ServerUnitResult {
        guard let context = serverContext else { throw ServerRecordingError.notAServerLibrary }
        try ensureServerExchangeTables()
        let clock = ContinuousClock(), started = clock.now
        let changes = try database.scalar("SELECT total_changes()")
        // Its keyed statements run hundreds of times inside the lock: each prepared once.
        var result = try database.reusingStatements { try syncTransactions(ServerTransactionKind.directUnit) { try write(.remote, durable: true) {
            var result = ServerUnitResult(seq: input.commit.seq)
            guard try checkUnitOrder(input, &result) else { return result }
            try applyUnitInTransaction(input, context: context, history: history, maxWork: maxWork, result: &result)
            return result
        } } }
        result.lockMilliseconds = Self.milliseconds(started.duration(to: clock.now))
        result.rowsWritten = Int(try database.scalar("SELECT total_changes()") - changes)
        return result
    }

    /// A unit's whole application inside the caller's write transaction (its order checked): the base, nodes,
    /// decisions, retirements, the projection from intact local rows with the commit's full context, the plan, the
    /// cursor. A direct unit, and a retained shadow published as a whole at the pause (`publishServerShadow`).
    func applyUnitInTransaction(_ input: ServerUnitInput, context: ServerLibraryContext, history: ServerHistoryOracle?, maxWork: Int?,
                                result: inout ServerUnitResult) throws {
        let projector = try unitProjector(context: context, now: input.now)
        projector.history = history
        var (scope, written) = try writeBase(input.commit, projector: projector)
        try input.crash?("unit.base")
        try addNodes(input.commit)
        try applyDecisions(input.commit, context: context, projector: projector, inTransaction: true)
        try retire(input.commit, context: context, scope: &scope, result: &result)
        try noteRetiredPlayback(input.commit, retired: result.retired, history: history)
        try input.crash?("unit.retired")
        try projector.addHistoryScope(input.commit, scope: &scope)
        try projector.project(scope)
        let plan = projector.plan
        if !plan.missingSecrets.isEmpty { throw ServerApplyError.missingSecrets(plan.missingSecrets) }
        // Only real changes count: records the base already held identically were not written.
        result.work = plan.work + written + Self.retirementWork * result.retired.count
        if let maxWork, result.work > maxWork { throw ServerApplyError.overBudget(result.work) }
        try writePlan(plan, now: input.now, result: &result)
        try setCursor(input.cursor, watermark: input.watermark)
        try input.crash?("unit.written")
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    /// The live cursor must be the commit's predecessor; a commit at or below it was applied already.
    private func checkUnitOrder(_ input: ServerUnitInput, _ result: inout ServerUnitResult) throws -> Bool {
        let live = try serverExchangeState().cursor
        if let live, live.logID == input.cursor.logID, input.commit.seq <= live.seq { result.alreadyApplied = true; return false }
        if let live, live.logID == input.cursor.logID, input.commit.seq == live.seq + 1 { return true }
        throw ServerApplyError.outOfOrder(live: live?.seq, commit: input.commit.seq)
    }

    func unitProjector(context: ServerLibraryContext, now: Int64) throws -> ServerProjector {
        ServerProjector(db: database, namespace: context.namespace, accountID: context.accountID, now: now) { [database] kind in
            try database.allocateID(kind)
        }
    }

    /// Writes the commit's records into `ntp_records` (the base) and returns what they make the unit re-project. Every
    /// episode identity record is mapped in `ntp_episodes` as it arrives.
    private func writeBase(_ commit: ServerCommit, projector: ServerProjector) throws -> (scope: ServerProjectionScope, written: Int) {
        var scope = ServerProjectionScope()
        // A record the commit writes is the server's newer answer: a recovery's hold on it ends.
        try projector.dropHolds(commit.records.map(\.key))
        var written = 0
        for record in commit.records {
            scope.add(record: record.entity, id: record.id, group: record.fieldGroup)
            if record.entity == "episode", record.fieldGroup == "played_time" {
                try projector.notePlayedTimeChange(episode: record.id, previous: try projector.record("episode", record.id, "played_time")?["played_ms"]?.integerValue ?? 0)
            }
            if try writeRecord(record) { written += 1 }
        }
        return (scope, written)
    }

    @discardableResult
    func writeRecord(_ record: ServerRecord) throws -> Bool { try Self.writeRecord(record, to: database) }

    /// A record into `ntp_records` (a tombstone deletes it); an episode identity record is mapped in `ntp_episodes` as
    /// it arrives, keeping its local row. A record the base already holds with exactly the same value and provenance is
    /// not written. Returns whether the base changed.
    @discardableResult
    static func writeRecord(_ record: ServerRecord, to database: LibrarySQLite) throws -> Bool {
        let changed: Bool
        if let value = record.value {
            try database.execute("INSERT INTO ntp_records(entity, id, field_group, value, provenance) VALUES (?, ?, ?, ?, ?) ON CONFLICT(entity, id, field_group) DO UPDATE SET value = excluded.value, provenance = excluded.provenance WHERE ntp_records.value IS NOT excluded.value OR ntp_records.provenance IS NOT excluded.provenance",
                                 [.text(record.entity), .text(record.id), .text(record.fieldGroup), .blob(try value.canonicalData()),
                                  .text(ContractJSON.array(record.provenance.map(ContractJSON.string)).canonicalText)])
            changed = database.changes > 0
        } else {
            try database.execute("DELETE FROM ntp_records WHERE entity = ? AND id = ? AND field_group = ?",
                                 [.text(record.entity), .text(record.id), .text(record.fieldGroup)])
            changed = database.changes > 0
        }
        if record.entity == "episode", record.fieldGroup == "identity", let value = record.value,
           let podcast = value["podcast_id"]?.stringValue {
            let occurrence = value["occurrence"]
            try database.execute("INSERT INTO ntp_episodes(episode_id, local_id, podcast_id, kind, value, occurrence, merged_into) VALUES (?, NULL, ?, ?, ?, ?, ?) ON CONFLICT(episode_id) DO UPDATE SET podcast_id = excluded.podcast_id, occurrence = excluded.occurrence, merged_into = excluded.merged_into WHERE ntp_episodes.podcast_id IS NOT excluded.podcast_id OR ntp_episodes.occurrence IS NOT excluded.occurrence OR ntp_episodes.merged_into IS NOT excluded.merged_into",
                                 [.text(record.id), .text(podcast), .text(occurrence?["k"]?.stringValue ?? "none"), .text(occurrence?["v"]?.stringValue ?? ""),
                                  try occurrence.map { .blob(try $0.canonicalData()) } ?? .null,
                                  value["merged_into"]?.stringValue.map(LibrarySQLValue.text) ?? .null])
        }
        return changed
    }

    /// The commit's causal nodes join the known nodes at the next knowledge clock; what they depend on leaves the
    /// frontier (PROTOCOL §6.8 coverage, PROTOCOL §15.2 cut dependencies).
    func addNodes(_ commit: ServerCommit) throws {
        let clock = try database.scalar("SELECT knowledge_clock FROM ntp_library WHERE id = 1") + 1
        try database.execute("UPDATE ntp_library SET knowledge_clock = ? WHERE id = 1", [.integer(clock)])
        var nodes: [(id: String, dependencies: [String])] = commit.accepted.filter(\.isCausalNode).map { ($0.opID, $0.dependencies) }
        nodes += commit.decisions.map { ($0.decisionID, $0.dependencies) }
        // A node this library already knew (its own fact) keeps its clock and frontier flag; a new one joins the
        // frontier (no node known before can depend on it). Then whatever the commit's nodes depend on leaves it.
        for chunk in Self.chunks(nodes.map(\.id)) {
            try database.execute("INSERT INTO ntp_nodes(node_id, knowledge_clock, publication_seq, frontier, kind) SELECT value, ?, ?, 1, 'pulled' FROM json_each(?) WHERE true ON CONFLICT(node_id) DO UPDATE SET publication_seq = excluded.publication_seq",
                                 [.integer(clock), .integer(commit.seq), .text(ContractJSON.array(chunk.map(ContractJSON.string)).canonicalText)])
        }
        for chunk in Self.chunks(Array(Set(nodes.flatMap(\.dependencies)))) {
            try database.execute("UPDATE ntp_nodes SET frontier = 0 WHERE frontier != 0 AND node_id IN (SELECT value FROM json_each(?))",
                                 [.text(ContractJSON.array(chunk.map(ContractJSON.string)).canonicalText)])
        }
    }

    /// A retirement's cost in row writes (its outbox entry, overlays and re-projection), measured (PROTOCOL §6.8 work).
    static let retirementWork = 3

    static func chunks<T>(_ list: [T], size: Int = 500) -> [[T]] {
        stride(from: 0, to: list.count, by: size).map { Array(list[$0..<min(list.count, $0 + size)]) }
    }

    /// The commit's decisions that act on this library itself, by kind. Most decisions' effects arrive as records (a
    /// `queue.layout`'s keys are `queue_position` records of the members whose key changed, projected like any record;
    /// the phone never replays, PROTOCOL §7.6); only these need the phone: a `podcast.resolution` of this library's
    /// pending registration materializes its drafts (PROTOCOL §15.2), and the shadow projector learns the podcast's
    /// local feed. A new kind that needs the phone gets its case here.
    func applyDecisions(_ commit: ServerCommit, context: ServerLibraryContext, projector: ServerProjector, inTransaction: Bool) throws {
        for decision in commit.decisions {
            switch decision.type {
            case "podcast.resolution":
                try resolveRegistration(decision, context: context, projector: projector, inTransaction: inTransaction)
            default:
                break
            }
        }
    }

    private func resolveRegistration(_ decision: ServerDecision, context: ServerLibraryContext, projector: ServerProjector,
                                     inTransaction: Bool) throws {
        guard let podcast = decision.result["podcast_id"]?.stringValue, let mode = decision.result["mode"]?.stringValue,
              let row = try database.rows("SELECT feed_id, state FROM ntp_registrations WHERE op_id = ?", [.text(decision.subject)]).first else { return }
        if let feed = row[0].integer { projector.resolvedFeeds[podcast] = feed }
        guard inTransaction, row[1].text == "pending" else { return }
        try materializeRegistration(opID: decision.subject, .init(podcastID: podcast, generationID: decision.result["generation_id"]?.stringValue,
                                                                  mode: mode, decisionID: decision.decisionID), context: context)
    }

    /// Retires this library's outbox entries whose slots the commit consumed (PROTOCOL §6.4): their overlays go in this
    /// unit and what they showed is re-projected from the base. A slot of this installation holding another op means
    /// another library writes this transport (PROTOCOL §6.10).
    func retire(_ commit: ServerCommit, context: ServerLibraryContext, scope: inout ServerProjectionScope,
                        result: inout ServerUnitResult) throws {
        let ours = commit.slots.filter { $0.installID == context.installID }
        guard !ours.isEmpty else { return }
        var outbox: [Int64: (opID: String, type: String, receipt: Data?)] = [:]
        for chunk in Self.chunks(ours.map(\.installSeq)) {
            for row in try database.rows("SELECT install_seq, op_id, type, receipt FROM ntp_outbox WHERE install_seq IN (SELECT value FROM json_each(?))",
                                         [.text(ContractJSON.array(chunk.map(ContractJSON.integer)).canonicalText)]) {
                guard let seq = row[0].integer, case .text(let op) = row[1], case .text(let type) = row[2] else { continue }
                outbox[seq] = (op, type, row[3].data)
            }
        }
        let receipts = Dictionary(commit.accepted.map { ($0.opID, $0.receipt) }, uniquingKeysWith: { first, _ in first })
        var retiring: [(seq: Int64, opID: String)] = []
        for slot in ours {
            guard let entry = outbox[slot.installSeq] else { continue }
            guard entry.opID == slot.opID else { result.transportConflict = true; continue }
            retiring.append((slot.installSeq, entry.opID))
            var receipt = receipts[entry.opID]
            if receipt == nil, let data = entry.receipt { receipt = try? ContractJSON.decode(data) }
            let retired = ServerUnitResult.Retired(opID: entry.opID, type: entry.type,
                                                   outcome: slot.result == "op_id_conflict" ? "op_id_conflict" : receipt?["outcome"]?.stringValue,
                                                   reason: receipt?["reason"]?.stringValue)
            result.retired.append(retired)
            try noteAttention(retired, now: commit.seq)
            try scope.withdraw(database, opID: entry.opID, type: entry.type, outcome: retired.outcome)
            if entry.type == "podcast.subscribe" || entry.type == "podcast.register_preview",
               retired.outcome == "rejected" || retired.outcome == "op_id_conflict" {
                try terminateRegistration(entry.opID, scope: &scope)
            }
        }
        for chunk in Self.chunks(retiring) {
            let ops = ContractJSON.array(chunk.map { .string($0.opID) }).canonicalText
            for overlay in try database.rows("SELECT entity, id, property FROM ntp_overlays WHERE op_id IN (SELECT value FROM json_each(?))", [.text(ops)]) {
                guard case .text(let entity) = overlay[0], case .text(let id) = overlay[1], case .text(let property) = overlay[2] else { continue }
                scope.add(overlay: entity, id: id, property: property)
            }
            try database.execute("DELETE FROM ntp_overlays WHERE op_id IN (SELECT value FROM json_each(?))", [.text(ops)])
            try database.execute("DELETE FROM ntp_outbox WHERE install_seq IN (SELECT value FROM json_each(?))",
                                 [.text(ContractJSON.array(chunk.map { .integer($0.seq) }).canonicalText)])
        }
        if result.transportConflict {
            // It replaces any other pause, and what a version pause refused with it (as `setServerPause` does).
            try database.execute("UPDATE ntp_library SET pause_reason = ?, protocol_version = NULL, version_refusals = NULL WHERE id = 1",
                                 [.text(ServerPauseReason.transportConflict.rawValue)])
        }
    }

    /// A refused registration ends: its drafts can never materialize, so they go with their overlays and nodes, and
    /// nothing joins its chain again (it is no longer pending). What the person did locally stays as they left it; the
    /// next synced action on the podcast registers it again, and the refusal is a "needs attention" item.
    private func terminateRegistration(_ opID: String, scope: inout ServerProjectionScope) throws {
        guard try database.rows("SELECT author_id FROM ntp_registrations WHERE op_id = ? AND state = 'pending'", [.text(opID)]).first?.first?.text != nil else { return }
        // Every chain of the registration (a copy forked its author, PROTOCOL §6.10).
        let drafts = try database.rows("SELECT op_id FROM ntp_drafts WHERE registration_op = ?", [.text(opID)]).compactMap { $0[0].text }
        for chunk in Self.chunks(drafts) {
            let ops = ContractJSON.array(chunk.map(ContractJSON.string)).canonicalText
            for overlay in try database.rows("SELECT entity, id, property FROM ntp_overlays WHERE op_id IN (SELECT value FROM json_each(?))", [.text(ops)]) {
                guard case .text(let entity) = overlay[0], case .text(let id) = overlay[1], case .text(let property) = overlay[2] else { continue }
                scope.add(overlay: entity, id: id, property: property)
            }
            try database.execute("DELETE FROM ntp_overlays WHERE op_id IN (SELECT value FROM json_each(?))", [.text(ops)])
            try database.execute("DELETE FROM ntp_nodes WHERE kind = 'draft' AND node_id IN (SELECT value FROM json_each(?))", [.text(ops)])
            try database.execute("DELETE FROM ntp_drafts WHERE op_id IN (SELECT value FROM json_each(?))", [.text(ops)])
        }
        try database.execute("UPDATE ntp_registrations SET state = 'resolved', mode = 'refused' WHERE op_id = ?", [.text(opID)])
    }

    /// The "needs attention" items a person can act on (PROTOCOL §15.5): refusals, a subscription not completed because the
    /// podcast was removed elsewhere, a feed URL another podcast owns.
    private func noteAttention(_ retired: ServerUnitResult.Retired, now: Int64) throws {
        let kind: String
        switch (retired.outcome, retired.reason) {
        case ("rejected", _), ("op_id_conflict", _): kind = "rejected"
        case ("not_applied", "stale_subscribe"): kind = "stale_subscribe"
        case ("not_applied", "alias_conflict"): kind = "alias_conflict"
        default: return
        }
        var record: ContractObject = ["op_id": .string(retired.opID), "type": .string(retired.type), "reason": retired.reason.map(ContractJSON.string) ?? .null]
        if kind == "alias_conflict" { for member in try aliasOwner(ofRefused: retired.opID).members { record[member.name] = member.value } }
        for member in try attentionContext(kind, opID: retired.opID).members { record[member.name] = member.value }
        try database.execute("INSERT OR REPLACE INTO ntp_attention(id, kind, record, created_at) VALUES (?, ?, ?, ?)",
                             [.text(retired.opID), .text(kind), .blob(try ContractJSON.object(record).canonicalData()), .integer(Int64(Date().timeIntervalSince1970 * 1_000))])
    }

    /// For a refused feed URL edit (`alias_conflict`, PROTOCOL §9.7): the URL and the podcast that owns it, with its title,
    /// for "This feed URL already belongs to …". Read before the refused fact leaves the outbox.
    private func aliasOwner(ofRefused opID: String) throws -> ContractObject {
        guard let data = try database.rows("SELECT fact FROM ntp_outbox WHERE op_id = ?", [.text(opID)]).first?.first?.data,
              let url = try ContractJSON.decode(data)["payload"]?["url"]?.stringValue else { return [:] }
        var result: ContractObject = ["url": .string(url)]
        let normalized = ContractURL.normalize(url)
        for row in try database.rows("SELECT id, value FROM ntp_records WHERE entity = 'podcast' AND field_group = 'identity'") {
            guard let podcast = row[0].text, let value = try row[1].data.map({ try ContractJSON.decode($0) }),
                  value["aliases"]?.arrayValue?.contains(where: { $0["normalized"]?.stringValue == normalized }) == true else { continue }
            result["owner_podcast"] = .string(podcast)
            var title = try serverRecord("podcast", podcast, "metadata")?["title"]?.stringValue
            if title == nil, let feed = try database.rows("SELECT feed_id FROM ntp_podcasts WHERE podcast_id = ?", [.text(podcast)]).first?.first?.integer {
                title = try loadFeedHeader(feed)?.title
            }
            if let title { result["owner_title"] = .string(title) }
            break
        }
        return result
    }

    // MARK: - Writing a plan (keyed statements only, PROTOCOL §6.8)

    private static func encodeRecord<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    /// Writes a plan's rows with `INSERT … ON CONFLICT DO UPDATE` or keyed updates: no replaced row can cascade away
    /// a playback session, selection, queue entry or download job. Deletes only feeds the server removed.
    func writePlan(_ plan: ServerProjectionPlan, now: Int64, result: inout ServerUnitResult) throws {
        guard !plan.queueStale else { throw ServerApplyError.unprojectedQueue }
        for (id, feed) in plan.feeds.sorted(by: { $0.key < $1.key }) {
            var header = feed
            header.episodes = []
            try database.execute("INSERT INTO feeds(id, title, record) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET title = excluded.title, record = excluded.record WHERE feeds.title IS NOT excluded.title OR feeds.record IS NOT excluded.record",
                                 [.integer(id), feed.metadata.title.map(LibrarySQLValue.text) ?? .null, .blob(try Self.encodeRecord(header))])
        }
        for (id, entry) in plan.episodes.sorted(by: { $0.key < $1.key }) {
            try writeEpisodeImage(id: id, feedID: entry.feedID, episode: entry.episode)
        }
        for (podcast, mapping) in plan.podcastMappings.sorted(by: { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }) {
            if let feed = mapping.feedID {
                try database.execute("UPDATE ntp_podcasts SET feed_id = NULL WHERE feed_id = ? AND podcast_id != ?", [.integer(feed), .text(podcast)])
            }
            try database.execute("INSERT INTO ntp_podcasts(podcast_id, feed_id, live_generation) VALUES (?, ?, ?) ON CONFLICT(podcast_id) DO UPDATE SET feed_id = coalesce(excluded.feed_id, feed_id), live_generation = excluded.live_generation",
                                 [.text(podcast), mapping.feedID.map(LibrarySQLValue.integer) ?? .null, mapping.liveGeneration.map(LibrarySQLValue.text) ?? .null])
        }
        for (podcast, rules) in plan.identityRules {
            try database.execute("INSERT INTO ntp_podcasts(podcast_id, identity_rules) VALUES (?, ?) ON CONFLICT(podcast_id) DO UPDATE SET identity_rules = excluded.identity_rules",
                                 [.text(podcast), try rules.map { .blob(try $0.canonicalData()) } ?? .null])
        }
        // Ledger entries keyed by a local episode (a provisional release) take its episode when it is
        // mapped (with the other ownership moves below).
        let localLedger = plan.episodeMappings.isEmpty ? [] : Set(try database.rows("SELECT occurrence FROM ntp_ledger WHERE occurrence LIKE 'local-episode:%' AND generation_id NOT LIKE 'registration:%'").compactMap { $0[0].text })
        var ownership: [(from: String, to: String)] = []
        for (episode, mapping) in plan.episodeMappings.sorted(by: { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }) {
            if let local = mapping.localID {
                try database.execute("UPDATE ntp_episodes SET local_id = NULL WHERE local_id = ? AND episode_id != ?", [.integer(local), .text(episode)])
                if localLedger.contains(Self.ledgerKey(localEpisode: local)) { ownership.append((Self.ledgerKey(localEpisode: local), episode)) }
            }
            try database.execute("INSERT INTO ntp_episodes(episode_id, local_id, podcast_id, kind, value, occurrence, merged_into) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(episode_id) DO UPDATE SET local_id = coalesce(excluded.local_id, local_id), podcast_id = excluded.podcast_id, occurrence = coalesce(excluded.occurrence, occurrence), merged_into = excluded.merged_into",
                                 [.text(episode), mapping.localID.map(LibrarySQLValue.integer) ?? .null, .text(mapping.podcast), .text(mapping.kind),
                                  .text(mapping.value), try mapping.occurrence.map { .blob(try $0.canonicalData()) } ?? .null,
                                  mapping.mergedInto.map(LibrarySQLValue.text) ?? .null])
        }
        for (feedID, credential) in plan.credentials {
            try database.execute("DELETE FROM feed_credentials WHERE feed_id = ?", [.integer(feedID)])
            if let credential {
                try database.execute("INSERT INTO feed_credentials VALUES (?, ?)", [.integer(feedID), .text(credential.uuidString)])
                try database.execute("DELETE FROM feed_credential_cleanup WHERE credential_id = ?", [.text(credential.uuidString)])
            }
        }
        for (episode, units) in plan.statisticsUnits {
            try database.execute("DELETE FROM ntp_statistics_units WHERE episode_id = ?", [.text(episode)])
            for unit in units?["units"]?.arrayValue ?? [] {
                guard let id = unit["id"]?.stringValue else { continue }
                try database.execute("INSERT OR REPLACE INTO ntp_statistics_units(episode_id, unit_id, record) VALUES (?, ?, ?)",
                                     [.text(episode), .text(id), .blob(try unit.canonicalData())])
            }
        }
        for (local, units) in plan.libraryStatisticsUnits.sorted(by: { $0.key < $1.key }) {
            // Units belong to their local episode (schema 20): an episode already gone has none.
            guard try database.scalar("SELECT count(*) FROM episodes WHERE id = ?", [.integer(local)]) == 1 else { continue }
            try database.replaceStatisticsUnits(episode: local, with: units)
        }
        // Every ledger entry changing episode (a merged episode's to its survivor, PROTOCOL §9.9; a re-resolved row's
        // to its release; a provisional release's local key to its mapping) first leaves its key, then joins the new
        // one, before any admission is inserted: an entry only ever coalesces with one of the same release, finished
        // work kept.
        let ledgerMoves = (ownership + plan.ledgerMoves).filter { $0.from != $0.to }
        for move in ledgerMoves {
            try database.execute("UPDATE OR IGNORE ntp_ledger SET occurrence = ? WHERE occurrence = ? AND generation_id NOT LIKE 'registration:%'",
                                 [.text("moving:" + move.from), .text(move.from)])
        }
        for move in ledgerMoves {
            let from = "moving:" + move.from
            try database.execute("UPDATE ntp_ledger SET state = CASE WHEN EXISTS (SELECT 1 FROM ntp_ledger o WHERE o.generation_id = ntp_ledger.generation_id AND o.occurrence = ? AND o.state = 'done') THEN 'done' ELSE state END, notified = max(notified, coalesce((SELECT max(o.notified) FROM ntp_ledger o WHERE o.generation_id = ntp_ledger.generation_id AND o.occurrence = ?), 0)) WHERE occurrence = ?",
                                 [.text(from), .text(from), .text(move.to)])
            try database.execute("UPDATE OR IGNORE ntp_ledger SET occurrence = ? WHERE occurrence = ?", [.text(move.to), .text(from)])
            try database.execute("DELETE FROM ntp_ledger WHERE occurrence = ?", [.text(from)])
        }
        // A re-resolved row's pending overlays stay its own (the facts are unchanged).
        for move in plan.overlayMoves {
            try database.execute("UPDATE OR REPLACE ntp_overlays SET id = ? WHERE entity = 'episode' AND id = ?",
                                 [.text(Self.ledgerKey(localEpisode: move.local)), .text(move.from)])
        }
        var releases = false
        for admission in plan.admissions {
            // The discovery ledger (PROTOCOL §9.9): a snapshot's admissions are seen, a pull's are releases this phone downloads
            // and notifies about once, unless it has the release already (its own proposal, the same entry).
            let record: ContractJSON = ["episode_id": .string(admission.episode), "admission_id": admission.admission.map(ContractJSON.string) ?? .null]
            try database.execute("INSERT OR IGNORE INTO ntp_ledger(generation_id, occurrence, entry_id, state, notified, record) VALUES (?, ?, ?, ?, ?, ?)",
                                 [.text(admission.generation), .text(admission.episode), admission.admission.map(LibrarySQLValue.text) ?? .null,
                                  .text(plan.admissionsSeen ? "done" : "pending"), .integer(plan.admissionsSeen ? 1 : 0), .blob(try record.canonicalData())])
            if !plan.admissionsSeen, try database.scalar("SELECT changes()") == 1 { releases = true }
        }
        // New releases are the automatic download's to consider (PROTOCOL §9.9), as a refresh's are.
        if releases { try requestQueueAutoDownload(); result.releases = true }
        // A merged row's active downloads go on as the survivor's, before the row goes.
        for transfer in plan.jobTransfers where transfer.from != transfer.to {
            for var job in try downloadJobs(activeOnly: true) where job.episodeID == transfer.from {
                job.episodeID = transfer.to
                try database.execute("UPDATE download_jobs SET episode_id = ?, record = ? WHERE id = ?",
                                     [.integer(transfer.to), .blob(try JSONEncoder().encode(job)), .integer(job.id)])
            }
        }
        // A merged podcast's live generation joins the survivor's: its entries become the survivor generation's, an entry
        // both have keeping whichever work is finished.
        for move in plan.generationMoves where move.from != move.to {
            try database.execute("UPDATE ntp_ledger SET state = CASE WHEN EXISTS (SELECT 1 FROM ntp_ledger o WHERE o.generation_id = ? AND o.occurrence = ntp_ledger.occurrence AND o.state = 'done') THEN 'done' ELSE state END, notified = max(notified, coalesce((SELECT max(o.notified) FROM ntp_ledger o WHERE o.generation_id = ? AND o.occurrence = ntp_ledger.occurrence), 0)) WHERE generation_id = ?",
                                 [.text(move.from), .text(move.from), .text(move.to)])
            try database.execute("UPDATE OR IGNORE ntp_ledger SET generation_id = ? WHERE generation_id = ?", [.text(move.to), .text(move.from)])
            try database.execute("DELETE FROM ntp_ledger WHERE generation_id = ?", [.text(move.from)])
        }
        // A merged podcast's per-feed speed and skip silence, in the library's playback file, are the app's to carry
        // (PROTOCOL §9.7); a pair not carried yet whose survivor merged on follows it.
        for merge in plan.feedMerges where merge.source != merge.survivor {
            try database.execute("UPDATE ntp_feed_merges SET survivor_feed = ? WHERE survivor_feed = ?", [.integer(merge.survivor), .integer(merge.source)])
            try database.execute("INSERT INTO ntp_feed_merges(source_feed, survivor_feed) VALUES (?, ?) ON CONFLICT(source_feed) DO UPDATE SET survivor_feed = excluded.survivor_feed",
                                 [.integer(merge.source), .integer(merge.survivor)])
            result.feedsMerged = true
        }
        for addition in plan.overlayAdditions {
            try database.execute("INSERT OR REPLACE INTO ntp_overlays(op_id, entity, id, property, kind, value, clock) SELECT ?, ?, ?, ?, ?, ?, clock FROM ntp_overlays WHERE op_id = ? AND entity = 'account' LIMIT 1",
                                 [.text(addition.op), .text(addition.entity), .text(addition.id), .text(addition.property), .text(addition.kind),
                                  .blob(try addition.value.canonicalData()), .text(addition.op)])
        }
        for (episode, fields) in plan.deferredPins {
            try database.execute("INSERT INTO ntp_deferred_pins(episode_id, fields) VALUES (?, ?) ON CONFLICT(episode_id) DO UPDATE SET fields = fields | excluded.fields",
                                 [.text(episode), .integer(Int64(fields.rawValue))])
        }
        // Removals last among rows, so their cascades see the final rows. The queue is read only when needed, with
        // what a safeguard copies of each member (title and key) taken before any row is deleted.
        let queueBefore: [(id: Int64, record: Data?, key: String?)] = plan.queue != nil || !plan.removedFeeds.isEmpty || !plan.pinnedRemovals.isEmpty
            || !plan.removedEpisodes.isEmpty
            ? try database.rows("SELECT q.episode_id, e.record, k.key FROM queue q LEFT JOIN episodes e ON e.id = q.episode_id LEFT JOIN ntp_queue_keys k ON k.episode_id = q.episode_id ORDER BY q.position").compactMap { row in
                row[0].integer.map { ($0, row[1].data, row[2].text) }
            } : []
        var queue = plan.removedFeeds.isEmpty ? [] : try loadQueue()
        for feedID in plan.removedFeeds {
            guard let feed = try loadFeed(feedID) else { continue }
            // Projected removals stop only their own downloads: another row's of the same address (a merge's survivor)
            // goes on, here and in every removal below.
            try deleteFeedInTransaction(feed, queue: &queue, now: Date(timeIntervalSince1970: Double(now) / 1_000), sharedAddressJobs: false)
            result.deletedFeeds.append(feedID)
        }
        for removal in plan.pinnedRemovals {
            try applyPinnedRemoval(removal, now: now)
            result.removedEpisodes = true
        }
        for (feedID, ids) in plan.removedEpisodes.sorted(by: { $0.key < $1.key }) {
            try removeProjectedEpisodes(Set(ids), feedID: feedID, now: now)
            result.removedEpisodes = true
        }
        for removal in plan.hiddenRemovals {
            // A large removal leaves every list at once, in this unit; its rows go in bounded transactions after it.
            // The player's episode is cleared as in a pinned removal (PROTOCOL §6.8) and goes when the player leaves it.
            if let playing = removal.playing { try clearRemovedPlayingEpisode(playing, feedID: removal.feedID) }
            try database.execute("INSERT INTO ntp_hidden_feeds(feed_id, podcast_id, state, seq) VALUES (?, ?, 'removing', ?) ON CONFLICT(feed_id) DO UPDATE SET podcast_id = excluded.podcast_id, state = 'removing', seq = excluded.seq",
                                 [.integer(removal.feedID), .text(removal.podcast), .integer(result.seq)])
            result.hiddenRemovals = true
        }
        for absence in plan.deferredAbsences {
            try database.execute("INSERT OR REPLACE INTO ntp_deferred_absence(local_id, episode_id, feed_id) VALUES (?, ?, ?)",
                                 [.integer(absence.localID), .text(absence.episode), .integer(absence.feedID)])
        }
        if let order = plan.queue {
            var present = Set<Int64>()
            for chunk in Self.chunks(order) {
                for row in try database.rows("SELECT id FROM episodes WHERE id IN (SELECT value FROM json_each(?))",
                                             [.text(ContractJSON.array(chunk.map(ContractJSON.integer)).canonicalText)]) {
                    if let id = row[0].integer { present.insert(id) }
                }
            }
            let final = order.filter(present.contains)
            let stored = try queueEpisodeIDs()
            if final != stored {
                try database.execute("DELETE FROM queue")
                for (index, id) in final.enumerated() {
                    try database.execute("INSERT INTO queue(position, episode_id) VALUES (?, ?)", [.integer(Int64(index)), .integer(id)])
                }
                result.queueChanged = true
                if Set(final).subtracting(stored).isEmpty == false { try requestQueueAutoDownload() }
            }
            // The queue safeguard (PROTOCOL §6.8): a copy of the queue before a commit that removes more than 75% of it, kept in
            // this same transaction (the engine moves it into the archive).
            let removed = Set(queueBefore.map(\.id)).subtracting(final).count
            if queueBefore.count >= 2, removed * 4 > queueBefore.count * 3 {
                let safeguard: ContractJSON = ["time": .integer(now), "id": .string(UUID().uuidString), "episodes": .array(try queueBefore.map { member in
                    let title = try member.record.flatMap { try JSONDecoder().decode(LibraryEpisode.self, from: $0).details.title }
                    return ["local_id": .integer(member.id), "title": title.map(ContractJSON.string) ?? .null,
                            "key": member.key.map(ContractJSON.string) ?? .null]
                })]
                result.queueSafeguard = safeguard
                try database.execute("INSERT INTO ntp_pending_safeguards(record) VALUES (?)", [.blob(try safeguard.canonicalData())])
            }
            try database.execute("DELETE FROM ntp_queue_keys WHERE episode_id NOT IN (SELECT episode_id FROM queue)")
            for id in final {
                guard let key = plan.queueKeys[id] else { continue }
                try database.execute("INSERT INTO ntp_queue_keys(episode_id, key, position_id, device_only, next_anchor, previous_anchor) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(episode_id) DO UPDATE SET key = excluded.key, position_id = excluded.position_id, device_only = excluded.device_only, next_anchor = excluded.next_anchor, previous_anchor = excluded.previous_anchor",
                                     [.integer(id), .text(key.key.wire), .text(key.positionID), .integer(key.deviceOnly ? 1 : 0),
                                      key.nextAnchor.map(LibrarySQLValue.integer) ?? .null, key.previousAnchor.map(LibrarySQLValue.integer) ?? .null])
            }
        }
        // Accumulated: a publication writes more than one plan (a staged plan and its switch's re-projection), and every
        // result field only ever turns on.
        if plan.accountPoliciesChanged { result.accountPoliciesChanged = true }
    }

    /// One episode row, keyed (`saveEpisode`'s statement): a changed play state withdraws a swipe Undo offer, as a
    /// local write does.
    func writeEpisodeImage(id: Int64, feedID: Int64, episode: LibraryEpisode) throws {
        guard let date = episode.details.publicationDate else { throw FeedLibraryError.invalidMutation }
        if try database.scalar("SELECT count(*) FROM episode_swipe_undo WHERE episode_id = ?", [.integer(id)]) > 0,
           try loadEpisode(id)?.userState.playState != episode.userState.playState {
            try database.execute("DELETE FROM episode_swipe_undo WHERE episode_id = ?", [.integer(id)])
        }
        try database.execute("INSERT INTO episodes(id, feed_id, pubdate, record) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET pubdate = excluded.pubdate, record = excluded.record WHERE episodes.feed_id = excluded.feed_id AND (episodes.pubdate IS NOT excluded.pubdate OR episodes.record IS NOT excluded.record)",
                             [.integer(id), .integer(feedID), .integer(try milliseconds(date)), .blob(try Self.encodeRecord(episode))])
    }

    /// PROTOCOL §6.8: every other episode of the podcast goes as in a normal removal; the playing episode's shared state is
    /// cleared; the podcast is a pinned removal every library-wide read skips until the selection leaves it.
    private func applyPinnedRemoval(_ removal: (feedID: Int64, podcast: String, episodeID: Int64), now: Int64) throws {
        guard let feed = try loadFeed(removal.feedID) else { return }
        let date = Date(timeIntervalSince1970: Double(now) / 1_000)
        let others = feed.episodes.filter { $0.id != removal.episodeID }
        if !others.isEmpty {
            let cleanup = try captureEpisodeRemoval(others, feed: feed, now: date, sharedAddressJobs: false)
            try removePendingQueueEpisodes(cleanup.episodeIDs)
            for episode in others {
                try captureEpisodeDeletion(episode, feedID: feed.id)
                try database.execute("DELETE FROM episodes WHERE id = ? AND feed_id = ?", [.integer(episode.id), .integer(feed.id)])
            }
            try appendEffect(.init(feedID: feed.id, date: date, kind: .removeEpisodes(others), removedEpisodeCleanup: cleanup))
        }
        try clearRemovedPlayingEpisode(removal.episodeID, feedID: feed.id)
        try database.execute("INSERT INTO ntp_podcasts(podcast_id, feed_id, pinned_removal) VALUES (?, ?, 1) ON CONFLICT(podcast_id) DO UPDATE SET feed_id = excluded.feed_id, live_generation = NULL, pinned_removal = 1",
                             [.text(removal.podcast), .integer(removal.feedID)])
    }

    /// The player's episode of a podcast the server removed (PROTOCOL §6.8): its shared state is cleared and it leaves the
    /// queue; it stays for the player until the player leaves it.
    private func clearRemovedPlayingEpisode(_ id: Int64, feedID: Int64) throws {
        if var playing = try loadEpisode(id) {
            playing.userState.isFavorite = false
            playing.userState.lastPlayedHistoryMilliseconds = nil
            playing.userState.playedDurationMilliseconds = 0
            if playing.userState.playState == .new { playing.userState.playState = .unplayed }
            try writeEpisodeImage(id: id, feedID: feedID, episode: playing)
        }
        try database.execute("DELETE FROM queue WHERE episode_id = ?", [.integer(id)])
    }

    /// Force full synchronization's obsolete episodes (PROTOCOL §6.14): removed as a refresh removes episodes, their files
    /// and downloads through the existing two-phase cleanup.
    func removeProjectedEpisodes(_ ids: Set<Int64>, feedID: Int64, now: Int64) throws {
        guard let feed = try loadFeed(feedID) else { return }
        let episodes = feed.episodes.filter { ids.contains($0.id) }
        guard !episodes.isEmpty else { return }
        let date = Date(timeIntervalSince1970: Double(now) / 1_000)
        // Another row's download of the same address is that row's own (a merge's survivor): only their jobs stop.
        let cleanup = try captureEpisodeRemoval(episodes, feed: feed, now: date, sharedAddressJobs: false)
        try removePendingQueueEpisodes(cleanup.episodeIDs)
        for episode in episodes {
            try captureEpisodeDeletion(episode, feedID: feed.id)
            try database.execute("DELETE FROM episodes WHERE id = ? AND feed_id = ?", [.integer(episode.id), .integer(feed.id)])
        }
        try appendEffect(.init(feedID: feed.id, date: date, kind: .removeEpisodes(episodes), removedEpisodeCleanup: cleanup))
    }

    /// The live cursor names the applied commit; acknowledgement advances over consumed slots (PROTOCOL §6.6).
    func setCursor(_ cursor: SyncCursor, watermark: Int64?) throws {
        try database.execute("UPDATE ntp_library SET cursor = ?, log_id = ?, epoch = ?, seq = ?, digest = ?, updated_at = ? WHERE id = 1",
                             [.text(cursor.encoded), .text(cursor.logID), .integer(cursor.epoch), .integer(cursor.seq), .text(cursor.digest),
                              .integer(Int64(Date().timeIntervalSince1970 * 1_000))])
        try advanceAcknowledgement(watermark: watermark)
    }

    // MARK: - The player's pin (PROTOCOL §6.8)

    /// Applies what waited for the player: remote positions and durations of episodes it no longer holds, and pinned
    /// removals whose podcast it left. Returns whether rows changed.
    @discardableResult
    public func releaseServerPins(now: Date = Date()) throws -> Bool {
        try syncTransactions(ServerTransactionKind.bookkeeping) { try releaseServerPinsLabelled(now: now) }
    }

    private func releaseServerPinsLabelled(now: Date) throws -> Bool {
        guard let context = serverContext else { return false }
        try ensureServerExchangeTables()
        let selection = try playbackSelectionEpisodeID(), session = try playbackSession()?.episodeID
        let pinned = Set([selection, session].compactMap { $0 })
        let deferred = try database.rows("SELECT d.episode_id, d.fields, n.local_id FROM ntp_deferred_pins d LEFT JOIN ntp_episodes n ON n.episode_id = d.episode_id")
            .filter { row in row[2].integer.map { !pinned.contains($0) } ?? true }
        let removals = try database.rows("SELECT podcast_id, feed_id FROM ntp_podcasts WHERE pinned_removal = 1").filter { row in
            guard let feed = row[1].integer else { return true }
            let episodes = try database.rows("SELECT id FROM episodes WHERE feed_id = ?", [.integer(feed)]).compactMap { $0[0].integer }
            return !episodes.contains(where: pinned.contains)
        }
        // Deferred absences whose hold retired (or whose episode the server holds again).
        let absences = try database.rows("SELECT local_id, episode_id, feed_id FROM ntp_deferred_absence").filter { row in
            guard let local = row[0].integer, let episode = row[1].text else { return true }
            if pinned.contains(local) { return false }
            if try database.scalar("SELECT count(*) FROM ntp_owed WHERE subject = ?", [.text("episode:\(local)")]) > 0 { return false }
            // A recovery still holds some of its fields, or newer local work on its feed decides.
            if try database.scalar("SELECT count(*) FROM ntp_recovery_holds WHERE entity = 'episode' AND id = ?", [.text(episode)]) > 0 { return false }
            if let feed = row[2].integer,
               try database.scalar("SELECT count(*) FROM ntp_registrations WHERE feed_id = ? AND state = 'pending'", [.integer(feed)]) > 0 { return false }
            return try database.scalar("SELECT count(*) FROM ntp_overlays WHERE entity = 'episode' AND id IN (?, ?)",
                                       [.text(episode), .text("local-episode:\(local)")]) == 0
        }
        guard !deferred.isEmpty || !removals.isEmpty || !absences.isEmpty else { return false }
        return try write(.remote) {
            let projector = try unitProjector(context: context, now: try milliseconds(now))
            // Projected as every unit is, so what the released fields change of the queue (a completion whose claim no
            // longer owns the position) is projected before anything is written.
            var scope = ServerProjectionScope()
            for row in deferred {
                guard let episode = row[0].text, let fields = row[1].integer else { continue }
                try database.execute("DELETE FROM ntp_deferred_pins WHERE episode_id = ?", [.text(episode)])
                scope.episodes[episode, default: []].formUnion(ServerEpisodeFields(rawValue: Int(fields)))
            }
            try projector.project(scope)
            var result = ServerUnitResult(seq: 0)
            try writePlan(projector.plan, now: try milliseconds(now), result: &result)
            var queue = try loadQueue()
            for row in removals {
                guard let podcast = row[0].text else { continue }
                if let feedID = row[1].integer, let feed = try loadFeed(feedID) {
                    try deleteFeedInTransaction(feed, queue: &queue, now: now, sharedAddressJobs: false)
                }
                try database.execute("UPDATE ntp_podcasts SET pinned_removal = 0 WHERE podcast_id = ?", [.text(podcast)])
            }
            for row in absences {
                guard let local = row[0].integer, let episode = row[1].text, let feedID = row[2].integer else { continue }
                try database.execute("DELETE FROM ntp_deferred_absence WHERE local_id = ?", [.integer(local)])
                // The server holds it again: it stays, as any episode the base holds (a merged one is held as its survivor).
                guard try database.scalar("SELECT count(*) FROM ntp_records WHERE entity = 'episode' AND id = ? AND field_group = 'identity' AND CAST(value AS TEXT) NOT LIKE '%\"merged_into\":\"%'",
                                          [.text(episode)]) == 0 else { continue }
                // Its feed belongs to another podcast now (a newer subscription won): the row is that podcast's.
                if let owner = try database.rows("SELECT podcast_id FROM ntp_episodes WHERE episode_id = ?", [.text(episode)]).first?.first?.text,
                   let mapped = try database.rows("SELECT podcast_id FROM ntp_podcasts WHERE feed_id = ?", [.integer(feedID)]).first?.first?.text,
                   mapped != owner { continue }
                try removeProjectedEpisodes([local], feedID: feedID, now: try milliseconds(now))
            }
            return true
        }
    }
}

extension FeedLibraryStore {
    /// Queue safeguards written by units and not yet moved into the archive.
    func pendingQueueSafeguards() throws -> [(id: Int64, record: ContractJSON)] {
        try database.rows("SELECT id, record FROM ntp_pending_safeguards ORDER BY id").compactMap { row in
            guard let id = row[0].integer, let data = row[1].data else { return nil }
            return (id, try ContractJSON.decode(data))
        }
    }

    func removePendingQueueSafeguards(_ ids: [Int64]) throws {
        try syncTransactions(ServerTransactionKind.bookkeeping) { try removePendingQueueSafeguardsLabelled(ids) }
    }

    private func removePendingQueueSafeguardsLabelled(_ ids: [Int64]) throws {
        try database.transaction {
            for id in ids { try database.execute("DELETE FROM ntp_pending_safeguards WHERE id = ?", [.integer(id)]) }
        }
    }
}

extension FeedLibraryStore {
    static let fullSynchronizationRequest = "full_synchronization"

    /// Records that a Force full synchronization is owed.
    func requestServerFullSynchronization() throws {
        try database.transaction {
            try database.execute("INSERT OR IGNORE INTO ntp_requests(name, created_at) VALUES (?, ?)",
                                 [.text(Self.fullSynchronizationRequest), .integer(try milliseconds(Date()))])
        }
    }

    func serverFullSynchronizationRequested() throws -> Bool {
        try database.scalar("SELECT count(*) FROM ntp_requests WHERE name = ?", [.text(Self.fullSynchronizationRequest)]) > 0
    }

    /// Base records the library holds: a measure of a repair's size known before anything is downloaded.
    func serverRecordCount() throws -> Int { Int(try database.scalar("SELECT count(*) FROM ntp_records")) }
}

extension FeedLibraryStore {
    /// A removal or a staging this large is done in bounded transactions behind a hidden podcast.
    static let removalBatch = 250
    /// Episodes a bounded removal transaction deletes at most: measured up to 96 ms for 250 on a loaded Mac, so 100
    /// keeps a margin under the 100 ms budget.
    static let removalTransaction = 100

    /// One bounded transaction of a hidden removal: up to `limit` episodes of a podcast hidden as
    /// `removing` are deleted as a refresh removes episodes (files and downloads through the two-phase cleanup), or,
    /// when none is left, the feed itself; an episode the player holds stays until it leaves it (PROTOCOL §6.8). Returns
    /// whether anything is left to do. Crash-safe: a hidden podcast stays hidden and its deletion resumes.
    func deleteHiddenRemovalBatch(limit: Int = removalTransaction, now: Date = Date()) throws -> (progressed: Bool, remaining: Bool) {
        try syncTransactions(ServerTransactionKind.hiddenRemoval) { try deleteHiddenRemovalBatchLabelled(limit: limit, now: now) }
    }

    private func deleteHiddenRemovalBatchLabelled(limit: Int, now: Date) throws -> (progressed: Bool, remaining: Bool) {
        guard serverContext != nil else { return (false, false) }
        // Not synced to disk one by one: a transaction a crash loses leaves its rows hidden, and the deletion resumes.
        return try write(.remote, durable: false) {
            let pinned = Set([try playbackSelectionEpisodeID(), try playbackSession()?.episodeID].compactMap { $0 })
            var waiting = false
            for row in try database.rows("SELECT feed_id FROM ntp_hidden_feeds WHERE state = 'removing' ORDER BY feed_id") {
                guard let feedID = row[0].integer else { continue }
                guard let header = try loadFeedHeader(feedID) else {
                    try database.execute("DELETE FROM ntp_hidden_feeds WHERE feed_id = ?", [.integer(feedID)])
                    return (true, true)
                }
                // The next batch only, newest first in the feed's index order (the player's episodes are at most two more),
                // never the whole podcast's list.
                let ids = try database.rows("SELECT id FROM episodes WHERE feed_id = ? ORDER BY pubdate DESC LIMIT ?", [.integer(feedID), .integer(Int64(limit + pinned.count))])
                    .compactMap { $0[0].integer }
                let deletable = ids.filter { !pinned.contains($0) }.prefix(limit)
                if !deletable.isEmpty {
                    // The batch's statistics units first, a bounded number a transaction (one episode can hold thousands,
                    // which its row's deletion would cascade to): hidden with the podcast, nobody sees them go.
                    try database.execute("DELETE FROM statistics_units WHERE rowid IN (SELECT rowid FROM statistics_units WHERE episode_id IN (SELECT value FROM json_each(?)) LIMIT ?)",
                                         [.text(ContractJSON.array(deletable.map(ContractJSON.integer)).canonicalText), .integer(Int64(Self.stagingRows))])
                    if try database.scalar("SELECT changes()") > 0 { return (true, true) }
                    let episodes = try deletable.compactMap { try loadEpisode($0) }
                    let cleanup = try captureEpisodeRemoval(episodes, feed: header, now: now, sharedAddressJobs: false)
                    try removePendingQueueEpisodes(cleanup.episodeIDs)
                    for episode in episodes {
                        try captureEpisodeDeletion(episode, feedID: feedID)
                        try database.execute("DELETE FROM episodes WHERE id = ? AND feed_id = ?", [.integer(episode.id), .integer(feedID)])
                    }
                    try appendEffect(.init(feedID: feedID, date: now, kind: .removeEpisodes(episodes), removedEpisodeCleanup: cleanup))
                    return (true, true)
                }
                if ids.isEmpty {
                    guard let feed = try loadFeed(feedID) else { continue }
                    var queue = try loadQueue()
                    try deleteFeedInTransaction(feed, queue: &queue, now: now, sharedAddressJobs: false)
                    try database.execute("DELETE FROM ntp_hidden_feeds WHERE feed_id = ?", [.integer(feedID)])
                    return (true, true)
                }
                // Only the player's episode is left: it goes when the player leaves it.
                waiting = true
            }
            return (false, waiting)
        }
    }

    /// Whether a hidden removal has rows left to delete now.
    func hasHiddenRemovals() throws -> Bool {
        guard serverContext != nil else { return false }
        return try database.scalar("SELECT count(*) FROM ntp_hidden_feeds WHERE state = 'removing'") > 0
    }
}
