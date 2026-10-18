import Foundation
import SQLite3

public enum FeedLibraryError: Error, Equatable, Sendable {
    case invalidLocation
    case closed
    case foreignDatabase
    case unsupportedSchema(Int64)
    case corruptRecord
    case missingFeed(Int64)
    case missingEpisode(Int64)
    case invalidMutation
    case sqlite(code: Int32, message: String)
}

enum LibrarySQLValue: Sendable {
    case integer(Int64), real(Double), text(String), blob(Data), null

    var integer: Int64? { if case .integer(let value) = self { value } else { nil } }
    var real: Double? { if case .real(let value) = self { value } else { nil } }
    var data: Data? { if case .blob(let value) = self { value } else { nil } }
    /// A record's bytes, stored (a BLOB) or produced by a JSON function (`json_remove` returns TEXT).
    var recordData: Data? {
        switch self {
        case .blob(let value): value
        case .text(let value): Data(value.utf8)
        default: nil
        }
    }
}

/// The longest write transaction of a kind: how long it held the write lock, how long its COMMIT took, and how many.
public struct LibraryTransactionTime: Sendable, Equatable {
    public var milliseconds = 0.0
    public var commitMilliseconds = 0.0
    public var count = 0

    mutating func add(_ held: Double, commit: Double) {
        if held > milliseconds { milliseconds = held; commitMilliseconds = commit }
        count += 1
    }

    mutating func merge(_ other: LibraryTransactionTime) {
        if other.milliseconds > milliseconds { milliseconds = other.milliseconds; commitMilliseconds = other.commitMilliseconds }
        count += other.count
    }
}

final class LibrarySQLite {
    private var handle: OpaquePointer?
    /// Incremented whenever a transaction is rolled back, so caches filled from its uncommitted
    /// writes can be discarded before they are trusted again.
    private(set) var rollbacks = 0
    /// Committed write transactions on this connection (each one is a durable commit).
    private(set) var writeCommits = 0
    /// SQLite's virtual machine steps of every statement this connection ran: what statements cost, whatever the size
    /// of what they read (the bounds of a synchronization unit's statements are tested with it).
    private(set) var statementSteps: Int64 = 0
    /// A read-only connection (`init(readingOnly:)`), for the work meter's labels.
    private(set) var readOnly = false
    /// This connection's number for the work meter (its plans' identity; files of one name on two connections stay apart).
    private let meterNumber = SQLWorkMeter.shared.connectionNumber()
    /// Pages this connection read from its cache or the file (`SQLITE_DBSTATUS_CACHE_HIT` + `_MISS`).
    var pagesTouched: Int64 {
        guard let handle else { return 0 }
        var hit: Int32 = 0, miss: Int32 = 0, highwater: Int32 = 0
        sqlite3_db_status(handle, SQLITE_DBSTATUS_CACHE_HIT, &hit, &highwater, 0)
        sqlite3_db_status(handle, SQLITE_DBSTATUS_CACHE_MISS, &miss, &highwater, 0)
        return Int64(hit) + Int64(miss)
    }
    /// Pages this connection wrote to the WAL (`SQLITE_DBSTATUS_CACHE_WRITE`): what its commits wrote, whatever the log's
    /// layout (restarts, checkpoints, sector padding).
    var pagesWritten: Int64 {
        guard let handle else { return 0 }
        var written: Int32 = 0, highwater: Int32 = 0
        sqlite3_db_status(handle, SQLITE_DBSTATUS_CACHE_WRITE, &written, &highwater, 0)
        return Int64(written)
    }
    /// Statements this connection ran, and how many of them it prepared (the rest were reused).
    private(set) var statementsRun = 0
    private(set) var statementsPrepared = 0
    /// The kind of synchronization transaction the store runs now (nil for everything else, which is not measured), and
    /// the longest committed write transaction of each kind since they were last taken: its whole hold of the write
    /// lock, its COMMIT's part (where SQLite also runs an automatic WAL checkpoint), and how many there were.
    var transactionKind: String?
    private(set) var transactionTimes: [String: LibraryTransactionTime] = [:]
    /// The capture of each write transaction's visible difference (`LibraryChangeCapture`), on a store's write connection.
    private(set) var capture: LibraryChangeCapture?
    /// Called after each write transaction that changed something visible or position knowledge has committed, with its
    /// change set (sequenced) and knowledge. Never for a rolled-back or net-zero transaction.
    var onCommit: ((LibraryCommit) -> Void)?
    /// The identity change sets carry (set by the store that owns the connection).
    var changeIdentity = LibraryChangeHub.Identity(library: nil, incarnation: UUID())
    /// Test hooks (the capture oracle), in every build so the release-mode proof runs too: right after BEGIN of each write
    /// transaction, and after its COMMIT with what was delivered (nil: nothing visible and no knowledge).
    var writeBegan: ((LibrarySQLite) throws -> Void)?
    var writeCommitted: ((LibrarySQLite, LibraryCommit?) -> Void)?
    /// A reader's request was cancelled: the next statement fails with `SQLITE_INTERRUPT` instead of running, and a running
    /// one stops at SQLite's next progress check (an interrupt arriving before a statement starts is otherwise forgotten).
    var interruptRequested: (@Sendable () -> Bool)? {
        didSet {
            guard let handle else { return }
            guard let check = interruptRequested else { sqlite3_progress_handler(handle, 0, nil, nil); progressCheck = nil; return }
            let box = ProgressCheck(check)
            progressCheck = box
            sqlite3_progress_handler(handle, 1_000, { context in
                guard let context else { return 0 }
                return Unmanaged<ProgressCheck>.fromOpaque(context).takeUnretainedValue().check() ? 1 : 0
            }, Unmanaged.passUnretained(box).toOpaque())
        }
    }
    private final class ProgressCheck {
        let check: @Sendable () -> Bool
        init(_ check: @escaping @Sendable () -> Bool) { self.check = check }
    }
    private var progressCheck: ProgressCheck?
    /// A rollback always runs, a cancelled request's included.
    private var rollingBack = false
    /// Tests: every write transaction checks, before it commits, that the derived keys and counts equal what the records
    /// give (`LibrarySchema21.discrepancies`), and fails otherwise. On by default in a debug build run with
    /// `NTP_VERIFY_DERIVED=1`.
    var verifiesDerivedData = LibrarySQLite.verifiesDerivedDataByDefault
#if DEBUG
    static let verifiesDerivedDataByDefault = ProcessInfo.processInfo.environment["NTP_VERIFY_DERIVED"] == "1"
#else
    static let verifiesDerivedDataByDefault = false
#endif

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    func takeTransactionTimes() -> [String: LibraryTransactionTime] {
        defer { transactionTimes = [:] }
        return transactionTimes
    }

    /// `ownedRoot` is the folder that holds the library's `media/` now (its database's folder unless a Keep at logout
    /// has not finished moving it, PROTOCOL §15.4): owned paths written under another folder are rewritten onto it before the
    /// library is used.
    init(url: URL, ownedRoot: URL? = nil) throws {
        guard url.isFileURL, !url.path.contains("\0") else { throw FeedLibraryError.invalidLocation }
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, SQLiteWriteBudget.vfs)
        guard status == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open library"
            if let connection { sqlite3_close_v2(connection) }
            throw FeedLibraryError.sqlite(code: status, message: message)
        }
        handle = connection
        do {
            sqlite3_extended_result_codes(connection, 1)
            sqlite3_busy_timeout(connection, 5_000)
            try execute("PRAGMA foreign_keys = ON")
            try transaction {
                let version = try scalar("PRAGMA user_version")
                let applicationID = try scalar("PRAGMA application_id")
                if version == 0 && applicationID == 0 {
                    guard try scalar("SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'") == 0 else {
                        throw FeedLibraryError.foreignDatabase
                    }
                    try execute("CREATE TABLE library_ids (kind TEXT PRIMARY KEY, value INTEGER NOT NULL)")
                    try execute("INSERT INTO library_ids VALUES ('feed', 0), ('episode', 0)")
                    try execute("CREATE TABLE feeds (id INTEGER PRIMARY KEY, title TEXT, record BLOB NOT NULL)")
                    try execute("CREATE TABLE episodes (id INTEGER PRIMARY KEY, feed_id INTEGER NOT NULL REFERENCES feeds(id) ON DELETE CASCADE, pubdate INTEGER NOT NULL, record BLOB NOT NULL)")
                    try execute("CREATE INDEX episodes_by_feed ON episodes(feed_id, pubdate DESC)")
                    try execute("CREATE TABLE refresh_log (id INTEGER PRIMARY KEY AUTOINCREMENT, feed_id INTEGER NOT NULL REFERENCES feeds(id) ON DELETE CASCADE, completed_at INTEGER NOT NULL, record BLOB NOT NULL)")
                    try execute("CREATE INDEX refresh_log_by_feed ON refresh_log(feed_id, completed_at DESC)")
                    try execute("CREATE TABLE pending_effects (id INTEGER PRIMARY KEY AUTOINCREMENT, record BLOB NOT NULL)")
                    try execute("PRAGMA application_id = 1095782212")
                    try execute("PRAGMA user_version = 1")
                } else {
                    guard applicationID == 1_095_782_212 else { throw FeedLibraryError.foreignDatabase }
                    guard (1...22).contains(version) else { throw FeedLibraryError.unsupportedSchema(version) }
                }
                if try scalar("PRAGMA user_version") == 1 {
                    try execute("CREATE TABLE queue (position INTEGER PRIMARY KEY, episode_id INTEGER NOT NULL UNIQUE REFERENCES episodes(id) ON DELETE CASCADE)")
                    try execute("CREATE TABLE queue_work (kind TEXT PRIMARY KEY CHECK(kind = 'autoDownload'))")
                    try execute("PRAGMA user_version = 2")
                }
                if try scalar("PRAGMA user_version") == 2 {
                    try execute("CREATE TABLE download_jobs (id INTEGER PRIMARY KEY AUTOINCREMENT, episode_id INTEGER NOT NULL REFERENCES episodes(id) ON DELETE CASCADE, source TEXT NOT NULL, active INTEGER NOT NULL CHECK(active IN (0, 1)), record BLOB NOT NULL)")
                    try execute("CREATE UNIQUE INDEX download_active_source ON download_jobs(source) WHERE active = 1")
                    try execute("PRAGMA user_version = 3")
                }
                if try scalar("PRAGMA user_version") == 3 {
                    try execute("CREATE TABLE playback_session (id INTEGER PRIMARY KEY CHECK(id = 1), episode_id INTEGER NOT NULL REFERENCES episodes(id) ON DELETE CASCADE, record BLOB NOT NULL)")
                    try execute("PRAGMA user_version = 4")
                }
                if try scalar("PRAGMA user_version") == 4 {
                    try execute("CREATE TABLE playback_selection (id INTEGER PRIMARY KEY CHECK(id = 1), episode_id INTEGER NOT NULL REFERENCES episodes(id) ON DELETE CASCADE)")
                    try execute("INSERT INTO playback_selection SELECT id, episode_id FROM playback_session")
                    try execute("PRAGMA user_version = 5")
                }
                if try scalar("PRAGMA user_version") == 5 {
                    try execute("CREATE TABLE local_folder_links (feed_id INTEGER PRIMARY KEY REFERENCES feeds(id) ON DELETE CASCADE, record BLOB NOT NULL)")
                    try execute("PRAGMA user_version = 6")
                }
                if try scalar("PRAGMA user_version") == 6 {
                    try execute("CREATE TABLE manual_feed_refresh (id INTEGER PRIMARY KEY CHECK(id = 1), record BLOB NOT NULL)")
                    try execute("PRAGMA user_version = 7")
                }
                if try scalar("PRAGMA user_version") == 7 {
                    try execute("CREATE TABLE episode_notification_attempt (id INTEGER PRIMARY KEY CHECK(id = 1) REFERENCES manual_feed_refresh(id) ON DELETE CASCADE, record BLOB NOT NULL)")
                    try execute("CREATE TABLE episode_notification_work (feed_id INTEGER PRIMARY KEY REFERENCES feeds(id) ON DELETE CASCADE, request_slot INTEGER NOT NULL CHECK(request_slot = 1) REFERENCES manual_feed_refresh(id) ON DELETE CASCADE, record BLOB NOT NULL)")
                    try execute("PRAGMA user_version = 8")
                }
                if try scalar("PRAGMA user_version") == 8 {
                    // Preserve an older pending queue trigger while giving each
                    // subsequent request an identity for conditional acknowledgement.
                    try execute("ALTER TABLE queue_work ADD COLUMN token TEXT NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000'")
                    try execute("PRAGMA user_version = 9")
                }
                if try scalar("PRAGMA user_version") == 9 {
                    try execute("CREATE TABLE synchronization_state (id INTEGER PRIMARY KEY CHECK(id = 1), record BLOB NOT NULL)")
                    try execute("CREATE TABLE synchronization_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, phase TEXT NOT NULL CHECK(phase IN ('subscriptions', 'episodes')), record BLOB NOT NULL)")
                    try execute("PRAGMA user_version = 10")
                }
                if try scalar("PRAGMA user_version") == 10 {
                    try execute("CREATE TABLE feed_credentials (feed_id INTEGER PRIMARY KEY REFERENCES feeds(id) ON DELETE CASCADE, credential_id TEXT NOT NULL UNIQUE)")
                    try execute("CREATE TABLE feed_credential_cleanup (credential_id TEXT PRIMARY KEY)")
                    // Cascading feed deletion must retire its secret in the same commit,
                    // including expiry and synchronization deletion while the UI is absent.
                    try execute("CREATE TRIGGER retire_feed_credential AFTER DELETE ON feed_credentials BEGIN INSERT OR IGNORE INTO feed_credential_cleanup VALUES (OLD.credential_id); END")
                    try execute("PRAGMA user_version = 11")
                }
                if try scalar("PRAGMA user_version") == 11 {
                    // Keep existing manual recovery data while giving periodic work
                    // independent ownership, including per-feed notification recovery.
                    try execute("CREATE TABLE feed_refresh_request (id INTEGER PRIMARY KEY CHECK(id IN (1, 2)), record BLOB NOT NULL)")
                    try execute("INSERT INTO feed_refresh_request SELECT * FROM manual_feed_refresh")
                    try execute("CREATE TABLE notification_attempt_v12 (id INTEGER PRIMARY KEY REFERENCES feed_refresh_request(id) ON DELETE CASCADE, record BLOB NOT NULL)")
                    try execute("INSERT INTO notification_attempt_v12 SELECT * FROM episode_notification_attempt")
                    try execute("CREATE TABLE notification_work_v12 (feed_id INTEGER NOT NULL REFERENCES feeds(id) ON DELETE CASCADE, request_slot INTEGER NOT NULL REFERENCES feed_refresh_request(id) ON DELETE CASCADE, record BLOB NOT NULL, PRIMARY KEY(feed_id, request_slot))")
                    try execute("INSERT INTO notification_work_v12 SELECT * FROM episode_notification_work")
                    try execute("DROP TABLE episode_notification_work")
                    try execute("DROP TABLE episode_notification_attempt")
                    try execute("DROP TABLE manual_feed_refresh")
                    try execute("ALTER TABLE notification_attempt_v12 RENAME TO episode_notification_attempt")
                    try execute("ALTER TABLE notification_work_v12 RENAME TO episode_notification_work")
                    try execute("CREATE TABLE periodic_feed_schedule (id INTEGER PRIMARY KEY CHECK(id = 1), record BLOB NOT NULL)")
                    try execute("PRAGMA user_version = 12")
                }
                if try scalar("PRAGMA user_version") == 12 {
                    // Only guards for live state-delta receipts. These rows do
                    // not schedule or restore an Undo after process recreation.
                    try execute("CREATE TABLE episode_swipe_undo (episode_id INTEGER PRIMARY KEY REFERENCES episodes(id) ON DELETE CASCADE, operation_id TEXT NOT NULL)")
                    try execute("PRAGMA user_version = 13")
                }
                if try scalar("PRAGMA user_version") == 13 {
                    // Source DownloadLog rows restored from an Android backup, kept verbatim
                    // (no FK: source rows outlive their feed or media).
                    try execute("CREATE TABLE imported_download_log (id INTEGER PRIMARY KEY AUTOINCREMENT, completed_at INTEGER NOT NULL, record BLOB NOT NULL)")
                    // Per-feed speed/silence from a restored backup, applied to preferences on the next graph start.
                    try execute("CREATE TABLE restore_journal (id INTEGER PRIMARY KEY CHECK(id = 1), record BLOB NOT NULL)")
                    try execute("PRAGMA user_version = 14")
                }
                if try scalar("PRAGMA user_version") == 14 {
                    // Per-feed change generation, bumped by every committed write to a feed header or any of
                    // its episodes, whatever the write path (refresh, import, restore, sync, cascade delete).
                    // The store reuses decoded feeds whose generation is unchanged instead of re-reading the
                    // whole library. Rows are never deleted, so a generation never repeats for a feed id.
                    // IF NOT EXISTS keeps a reopened partial schema (tests lowering user_version) upgradable.
                    try execute("CREATE TABLE IF NOT EXISTS feed_changes (feed_id INTEGER PRIMARY KEY, generation INTEGER NOT NULL)")
                    for (name, event, ids) in [("feeds_insert", "INSERT ON feeds", ["NEW.id"]),
                                               ("feeds_update", "UPDATE ON feeds", ["OLD.id", "NEW.id"]),
                                               ("feeds_delete", "DELETE ON feeds", ["OLD.id"]),
                                               ("episodes_insert", "INSERT ON episodes", ["NEW.feed_id"]),
                                               ("episodes_update", "UPDATE ON episodes", ["OLD.feed_id", "NEW.feed_id"]),
                                               ("episodes_delete", "DELETE ON episodes", ["OLD.feed_id"])] {
                        let body = ids.map {
                            // No conflict clause: an outer upsert's conflict policy would override it.
                            "UPDATE feed_changes SET generation = generation + 1 WHERE feed_id = \($0); INSERT INTO feed_changes SELECT \($0), 1 WHERE NOT EXISTS (SELECT 1 FROM feed_changes WHERE feed_id = \($0));"
                        }.joined(separator: " ")
                        try execute("CREATE TRIGGER IF NOT EXISTS feed_changes_\(name) AFTER \(event) BEGIN \(body) END")
                    }
                    try execute("PRAGMA user_version = 15")
                }
                if try scalar("PRAGMA user_version") == 15 {
                    // A second generation per feed, bumped only by writes to its episode rows. A header-only write
                    // (every refresh records its attempt time) bumps `generation` but not this, so the store keeps
                    // the feed's decoded episodes instead of re-reading and hashing every record of the feed.
                    // Same row as `generation`, so an episode write still changes one row of this table.
                    if try !rows("PRAGMA table_info(feed_changes)").contains(where: {
                        if case .text("episode_generation") = $0[1] { true } else { false }
                    }) {
                        try execute("ALTER TABLE feed_changes ADD COLUMN episode_generation INTEGER NOT NULL DEFAULT 0")
                    }
                    for (name, event, ids, episodes) in [("feeds_insert", "INSERT ON feeds", ["NEW.id"], false),
                                                         ("feeds_update", "UPDATE ON feeds", ["OLD.id", "NEW.id"], false),
                                                         ("feeds_delete", "DELETE ON feeds", ["OLD.id"], false),
                                                         ("episodes_insert", "INSERT ON episodes", ["NEW.feed_id"], true),
                                                         ("episodes_update", "UPDATE ON episodes", ["OLD.feed_id", "NEW.feed_id"], true),
                                                         ("episodes_delete", "DELETE ON episodes", ["OLD.feed_id"], true)] {
                        let bump = episodes ? "generation = generation + 1, episode_generation = episode_generation + 1" : "generation = generation + 1"
                        let body = ids.map {
                            // No conflict clause: an outer upsert's conflict policy would override it.
                            "UPDATE feed_changes SET \(bump) WHERE feed_id = \($0); INSERT INTO feed_changes(feed_id, generation, episode_generation) SELECT \($0), 1, \(episodes ? 1 : 0) WHERE NOT EXISTS (SELECT 1 FROM feed_changes WHERE feed_id = \($0));"
                        }.joined(separator: " ")
                        try execute("DROP TRIGGER IF EXISTS feed_changes_\(name)")
                        try execute("CREATE TRIGGER feed_changes_\(name) AFTER \(event) BEGIN \(body) END")
                    }
                    try execute("PRAGMA user_version = 16")
                }
                if try scalar("PRAGMA user_version") == 16 {
                    // Each pending effect records its kind, so a consumer reads only its own rows instead of
                    // decoding the whole table. Synchronization-only kinds were never read after the transaction
                    // that created them (the outbox received them there) and grew without bound: delete them.
                    if try !rows("PRAGMA table_info(pending_effects)").contains(where: {
                        if case .text("kind") = $0[1] { true } else { false }
                    }) {
                        try execute("ALTER TABLE pending_effects ADD COLUMN kind TEXT")
                    }
                    for row in try rows("SELECT id, record FROM pending_effects WHERE kind IS NULL") {
                        // An undecodable row keeps no kind; readers include such rows and fail on them as before.
                        guard let id = row[0].integer, let data = row[1].data,
                              let effect = try? JSONDecoder().decode(FeedLibraryEffect.self, from: data) else { continue }
                        if effect.kind.isSynchronizationOnly {
                            try execute("DELETE FROM pending_effects WHERE id = ?", [.integer(id)])
                        } else {
                            try execute("UPDATE pending_effects SET kind = ? WHERE id = ?", [.text(effect.kind.name), .integer(id)])
                        }
                    }
                    try execute("CREATE INDEX IF NOT EXISTS pending_effects_by_kind ON pending_effects(kind)")
                    try execute("PRAGMA user_version = 17")
                }
                if try scalar("PRAGMA user_version") == 17 {
                    // Deleting an episode cascades to its download jobs; without this index every deleted episode
                    // scanned the whole job table (an unsubscribe of a 2,000-episode feed: 2,000 scans).
                    try execute("CREATE INDEX IF NOT EXISTS download_jobs_by_episode ON download_jobs(episode_id)")
                    try execute("PRAGMA user_version = 18")
                }
                if try scalar("PRAGMA user_version") == 18 {
                    // Server mode (PROTOCOL §15.2): the `ntp_*` tables, empty and unused in a standalone library.
                    for statement in ServerLibrarySchema.statements { try execute(statement) }
                    try execute("PRAGMA user_version = 19")
                } else if try scalar("PRAGMA user_version") >= 19,
                          try scalar("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'ntp_owed'") == 0 {
                    // A schema-19 library made before the owed table existed (development builds only).
                    try execute(ServerLibrarySchema.owedTable)
                }
                if try scalar("PRAGMA user_version") == 19 {
                    // Schema 20 (PROTOCOL §15.2): the library's identity, statistics units and pinned
                    // removals, which every library reads, filled in the same transaction.
                    try LibrarySchema20.migrate(self, folder: url.deletingLastPathComponent())
                    try execute("PRAGMA user_version = 20")
                }
                if try scalar("PRAGMA user_version") == 20 {
                    // Schema 21: the derived list keys and counts (`LibrarySchema21`). Objects only: a library with
                    // episodes is filled in background batches after its graph starts.
                    try LibrarySchema21.migrate(self)
                    try execute("PRAGMA user_version = 21")
                }
                if try scalar("PRAGMA user_version") == 21 {
                    // Schema 22: the file-name index also holds the names a stored path's last component
                    // gives when that is not its file's name ("" for a path ending in "/"), so a file's owners are read
                    // by name alone.
                    for statement in LibrarySchema21.schema22 { try execute(statement) }
                    try execute("PRAGMA user_version = 22")
                }
            }
            try LibraryOwnedPaths.normalize(self, folder: ownedRoot ?? url.deletingLastPathComponent())
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
        } catch {
            sqlite3_close_v2(connection)
            handle = nil
            throw error
        }
    }

    /// A read-only connection to a library another graph owns or nobody has open (an inactive library): no
    /// schema change, no write. Only a library database written by this app is accepted.
    init(readingOnly url: URL) throws {
        guard url.isFileURL, !url.path.contains("\0") else { throw FeedLibraryError.invalidLocation }
        do { try open(readingOnly: url, flags: SQLITE_OPEN_READONLY) }
        catch FeedLibraryError.sqlite(let code, _) where code & 0xff == SQLITE_CANTOPEN {
            // A WAL library whose shared-memory file is gone (never written since it switched to WAL, or restored from
            // a backup) cannot be read through a read-only connection, which may not create that file. This connection
            // never creates the database (no CREATE) and refuses every SQL write (`query_only`), so the library's data
            // never changes; SQLite itself may still create the `-wal` and `-shm` files and, when the last connection
            // closes, checkpoint pages other connections committed into the main file. (Never `immutable=1`: the
            // library may be live.)
            try open(readingOnly: url, flags: SQLITE_OPEN_READWRITE)
        }
    }

    private func open(readingOnly url: URL, flags: Int32) throws {
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &connection, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open library"
            if let connection { sqlite3_close_v2(connection) }
            throw FeedLibraryError.sqlite(code: status, message: message)
        }
        handle = connection
        readOnly = true
        do {
            sqlite3_extended_result_codes(connection, 1)
            sqlite3_busy_timeout(connection, 5_000)
            try execute("PRAGMA query_only = ON")
            guard try scalar("PRAGMA application_id") == 1_095_782_212 else { throw FeedLibraryError.foreignDatabase }
            let version = try scalar("PRAGMA user_version")
            guard version >= 1 else { throw FeedLibraryError.unsupportedSchema(version) }
        } catch {
            sqlite3_close_v2(connection)
            handle = nil
            throw error
        }
    }

    deinit { if let handle { sqlite3_close_v2(handle) } }

    /// Runs `body` with bulk writes limited to `budget` bytes (`SQLiteWriteBudget`); nil: no limit.
    func withWriteBudget<T>(_ budget: Int64?, _ body: () throws -> T) throws -> T { try SQLiteWriteBudget.run(handle, budget: budget, body) }

    /// The armed budget's state (tests).
    var writeBudget: (charged: Int64, refused: Bool)? { SQLiteWriteBudget.state(handle).map { ($0.charged, $0.refused != 0) } }

    func close() throws {
        guard let handle else { return }
        let status = sqlite3_close(handle)
        guard status == SQLITE_OK else { throw error(status) }
        self.handle = nil
    }

    /// `durable: false` commits without waiting for the disk (`synchronous = NORMAL`): the commit survives an app
    /// crash or kill, and the database stays consistent, but a power loss can undo it until the next durable
    /// commit. Only for frequent writes that are superseded seconds later (the playing position).
    /// The one boundary every write uses: a write transaction's visible difference is captured here (`LibraryChangeCapture`),
    /// sequenced before COMMIT and delivered to `onCommit` after it.
    func transaction<T>(write: Bool = true, durable: Bool = true, _ operation: () throws -> T) throws -> T {
        if !durable { try execute("PRAGMA synchronous = NORMAL") }
        defer { if !durable { try? execute("PRAGMA synchronous = FULL") } }
        let clock = ContinuousClock()
        let measured = write && transactionKind != nil
        let began = measured ? clock.now : nil
        try execute(write ? "BEGIN IMMEDIATE" : "BEGIN")
        do {
#if DEBUG
            if write, let capture { try capture.verifyInstalled(self) }
#endif
            if write { try writeBegan?(self) }
            // A write transaction prepares each distinct statement once: a statement writing `episodes` or `feeds` compiles
            // the derived-data triggers (schema 21) with it, which repeated per row made bulk writes (a restore, a
            // refresh's new episodes) several times slower.
            let result = try write ? reusingStatements(operation) : operation()
            if write, verifiesDerivedData, try scalar("SELECT count(*) FROM sqlite_master WHERE name = 'derived_fill'") == 1 {
                let found = try LibrarySchema21.discrepancies(self)
                if !found.isEmpty { throw FeedLibraryError.sqlite(code: SQLITE_CORRUPT, message: "derived data: " + found.joined(separator: "; ")) }
            }
            let pending = write ? try capture?.drain(self, identity: changeIdentity, origin: LibraryChangeOrigin.current) : nil
            SQLWorkMeter.shared.noteKeys(pending?.set?.keyCount ?? 0)
            let committing = measured ? clock.now : nil
            try execute("COMMIT")
            if write { writeCommits += 1 }
            if let kind = transactionKind, let began, let committing {
                let end = clock.now
                transactionTimes[kind, default: LibraryTransactionTime()].add(Self.milliseconds(began.duration(to: end)),
                                                                              commit: Self.milliseconds(committing.duration(to: end)))
            }
            var delivered: LibraryCommit?
            if let pending, let capture {
                capture.committed(pending)
                delivered = LibraryCommit(set: pending.set, knowledge: pending.knowledge, origin: LibraryChangeOrigin.current)
                if let delivered { onCommit?(delivered) }
            }
            if write { writeCommitted?(self, delivered) }
            _ = delivered
            return result
        } catch {
            rollbacks += 1
            rollingBack = true
            defer { rollingBack = false }
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Installs the change capture on this connection (`LibraryChangeCapture`); `faults` are test-only mutations.
    func enableChangeCapture(faults: Set<LibraryChangeCapture.Fault> = []) throws {
        let capture = LibraryChangeCapture()
        capture.faults = faults
        if let previous = self.capture {
            capture.memorySequence = previous.memorySequence
            capture.changesWritten = previous.changesWritten
        }
        try capture.install(self)
        self.capture = capture
    }

    /// Re-installs the capture's triggers when tables it watches were created after it was installed.
    func refreshChangeCapture() throws { try capture?.refresh(self) }

    /// The last sequence of the library's visible changes (its persisted row, or this opening's own count).
    func changeSequence() throws -> Int64 { try capture?.currentSequence(self) ?? 0 }

    /// Rows INSERT, UPDATE and DELETE statements changed since the connection opened, triggers included, without the
    /// change capture's own rows: what a transaction's writes are measured by.
    var totalChanges: Int64 {
        guard let handle else { return 0 }
        return sqlite3_total_changes64(handle) - (capture?.changesWritten ?? 0)
    }

    /// The main database's file (nil in memory).
    var fileURL: URL? {
        guard let handle, let name = sqlite3_db_filename(handle, "main") else { return nil }
        let path = String(cString: name)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    /// Pages this connection's statements fetched (page-cache hits and misses since it opened): the B-tree work a single
    /// VM step can hide (a whole-table count), for the routine-work budgets.
    var pagesFetched: Int64 {
        guard let handle else { return 0 }
        var current: Int32 = 0, highest: Int32 = 0, total: Int64 = 0
        for status in [SQLITE_DBSTATUS_CACHE_HIT, SQLITE_DBSTATUS_CACHE_MISS] {
            sqlite3_db_status(handle, status, &current, &highest, 0)
            total += Int64(current)
        }
        return total
    }

    func withHandle(_ body: (OpaquePointer) -> Int32) throws {
        guard let handle else { throw FeedLibraryError.closed }
        let status = body(handle)
        guard status == SQLITE_OK else { throw error(status) }
    }

    /// A data change outside any transaction is its own transaction through the boundary, so its visible difference is
    /// captured and sequenced like every other (its effect, atomicity and durability are those of the autocommit it
    /// replaces). Statements on the connection's TEMP tables are left alone.
    private func needsBoundary(_ sql: String) -> Bool {
        guard capture != nil, let handle, sqlite3_get_autocommit(handle) != 0 else { return false }
        let head = sql.drop(while: { $0 == " " || $0 == "\n" }).prefix(48).uppercased()
        guard head.hasPrefix("INSERT") || head.hasPrefix("UPDATE") || head.hasPrefix("DELETE") || head.hasPrefix("REPLACE") else { return false }
        return !head.contains("TEMP.")
    }

    /// Runs `operation` inside the current transaction as one savepoint: on any error everything it wrote is
    /// rolled back (`ROLLBACK TO` plus `RELEASE`) and the error is rethrown, leaving the enclosing transaction's
    /// earlier writes in place. The recorder's writes run here (PROTOCOL §15.2).
    func savepoint<T>(_ name: String = "ntp_record", _ operation: () throws -> T) throws -> T {
        try execute("SAVEPOINT \(name)")
        do {
            let result = try operation()
            try execute("RELEASE \(name)")
            return result
        } catch {
            rollbacks += 1
            try? execute("ROLLBACK TO \(name)")
            try? execute("RELEASE \(name)")
            throw error
        }
    }

    func allocateID(_ kind: String) throws -> Int64 {
        try execute("UPDATE library_ids SET value = value + 1 WHERE kind = ?", [.text(kind)])
        return try scalar("SELECT value FROM library_ids WHERE kind = ?", [.text(kind)])
    }

    func scalar(_ sql: String, _ values: [LibrarySQLValue] = []) throws -> Int64 {
        guard let result = try rows(sql, values).first?.first?.integer else { throw FeedLibraryError.corruptRecord }
        return result
    }

    func execute(_ sql: String, _ values: [LibrarySQLValue] = []) throws {
        _ = try rows(sql, values)
    }

    /// Rows the last INSERT, UPDATE or DELETE changed (`SELECT changes()` without a statement of its own).
    var changes: Int64 { handle.map { Int64(sqlite3_changes($0)) } ?? 0 }

    /// Prepared statements kept for reuse while `reusingStatements` runs, by SQL text (a synchronization unit runs the
    /// same keyed statements hundreds of times inside the live lock); finalized when it ends.
    private var statementCache: [String: OpaquePointer]?

    /// Runs `body` preparing each distinct statement once and reusing it (reset, its bindings cleared) for every later
    /// run of the same text. A statement is taken out of the cache while it runs, so a nested run of the same text
    /// prepares its own.
    func reusingStatements<T>(_ body: () throws -> T) rethrows -> T {
        if statementCache != nil { return try body() }
        statementCache = [:]
        defer {
            if let cache = statementCache { for statement in cache.values { sqlite3_finalize(statement) } }
            statementCache = nil
        }
        return try body()
    }

    /// Interrupts the statement running on this connection now (`sqlite3_interrupt`); callable from another thread while
    /// the connection is open.
    func interrupt() { if let handle { sqlite3_interrupt(handle) } }

    /// Pages this connection looked up in its page cache (hits and misses) since it opened.
    var pageLookups: Int64 {
        guard let handle else { return 0 }
        var hit: Int32 = 0, miss: Int32 = 0, high: Int32 = 0
        sqlite3_db_status(handle, SQLITE_DBSTATUS_CACHE_HIT, &hit, &high, 0)
        sqlite3_db_status(handle, SQLITE_DBSTATUS_CACHE_MISS, &miss, &high, 0)
        return Int64(hit) + Int64(miss)
    }

    func rows(_ sql: String, _ values: [LibrarySQLValue] = []) throws -> [[LibrarySQLValue]] {
        if needsBoundary(sql) { return try transaction { try rows(sql, values) } }
        guard let handle else { throw FeedLibraryError.closed }
        if !rollingBack, let interruptRequested, interruptRequested() { throw FeedLibraryError.sqlite(code: SQLITE_INTERRUPT, message: "interrupted") }
        var statement: OpaquePointer?
        if let reused = statementCache?.removeValue(forKey: sql) {
            statement = reused
        } else {
            let preparation = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
            guard preparation == SQLITE_OK, statement != nil else { throw error(preparation) }
            statementsPrepared += 1
        }
        guard let statement else { throw FeedLibraryError.closed }
        let metering = SQLWorkMeter.shared.enabled
        // Explained before it is measured: the explanation's own reads are not the statement's.
        if metering, SQLWorkMeter.shared.recording {
            SQLWorkMeter.shared.explain(sql, handle: handle,
                                        connection: "library #\(meterNumber) \(fileURL?.lastPathComponent ?? "memory")\(readOnly ? " (read-only)" : "")")
        }
        let pagesBefore = metering ? pagesFetched : 0
        let changesBefore = metering ? sqlite3_total_changes64(handle) : 0
        var results: [[LibrarySQLValue]] = []
        var bytesRead: Int64 = 0
        defer {
            statementsRun += 1
            let stepsRun = Int64(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 1))
            statementSteps += stepsRun
            if metering {
                SQLWorkMeter.shared.add(sql: sql, steps: stepsRun, pages: pagesFetched - pagesBefore, rows: Int64(results.count), bytes: bytesRead,
                                        written: sqlite3_total_changes64(handle) - changesBefore)
            }
            if statementCache != nil, statementCache?[sql] == nil {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                statementCache?[sql] = statement
            } else {
                sqlite3_finalize(statement)
            }
        }
        guard sqlite3_bind_parameter_count(statement) == values.count else { throw FeedLibraryError.invalidMutation }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .integer(let integer): status = sqlite3_bind_int64(statement, index, integer)
            case .real(let real): status = sqlite3_bind_double(statement, index, real)
            case .text(let text):
                status = text.withCString {
                    sqlite3_bind_text64(statement, index, $0, UInt64(text.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self), UInt8(SQLITE_UTF8))
                }
            case .blob(let data):
                if data.isEmpty { status = sqlite3_bind_zeroblob(statement, index, 0) }
                else {
                    status = data.withUnsafeBytes {
                        sqlite3_bind_blob64(statement, index, $0.baseAddress, UInt64(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    }
                }
            case .null: status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw error(status) }
        }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return results }
            guard status == SQLITE_ROW else { throw error(status) }
            var row: [LibrarySQLValue] = []
            for index in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, index)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, index)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    bytesRead += Int64(count)
                    if count == 0 { row.append(.blob(Data())) }
                    else if let bytes = sqlite3_column_blob(statement, index) { row.append(.blob(Data(bytes: bytes, count: count))) }
                    else { throw FeedLibraryError.corruptRecord }
                case SQLITE_TEXT:
                    guard let bytes = sqlite3_column_text(statement, index) else { throw FeedLibraryError.corruptRecord }
                    let count = Int(sqlite3_column_bytes(statement, index))
                    bytesRead += Int64(count)
                    row.append(.text(String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)))
                case SQLITE_NULL: row.append(.null)
                default: throw FeedLibraryError.corruptRecord
                }
            }
            results.append(row)
        }
    }

    private func error(_ code: Int32) -> FeedLibraryError {
        .sqlite(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Library is closed")
    }
}
