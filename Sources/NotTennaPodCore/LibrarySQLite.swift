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
    case integer(Int64), text(String), blob(Data), null

    var integer: Int64? { if case .integer(let value) = self { value } else { nil } }
    var data: Data? { if case .blob(let value) = self { value } else { nil } }
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
    /// Statements this connection ran, and how many of them it prepared (the rest were reused).
    private(set) var statementsRun = 0
    private(set) var statementsPrepared = 0
    /// The kind of synchronization transaction the store runs now (nil for everything else, which is not measured), and
    /// the longest committed write transaction of each kind since they were last taken: its whole hold of the write
    /// lock, its COMMIT's part (where SQLite also runs an automatic WAL checkpoint), and how many there were.
    var transactionKind: String?
    private(set) var transactionTimes: [String: LibraryTransactionTime] = [:]

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
        let status = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
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
                    guard (1...20).contains(version) else { throw FeedLibraryError.unsupportedSchema(version) }
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

    func close() throws {
        guard let handle else { return }
        let status = sqlite3_close(handle)
        guard status == SQLITE_OK else { throw error(status) }
        self.handle = nil
    }

    /// `durable: false` commits without waiting for the disk (`synchronous = NORMAL`): the commit survives an app
    /// crash or kill, and the database stays consistent, but a power loss can undo it until the next durable
    /// commit. Only for frequent writes that are superseded seconds later (the playing position).
    func transaction<T>(write: Bool = true, durable: Bool = true, _ operation: () throws -> T) throws -> T {
        if !durable { try execute("PRAGMA synchronous = NORMAL") }
        defer { if !durable { try? execute("PRAGMA synchronous = FULL") } }
        let clock = ContinuousClock()
        let measured = write && transactionKind != nil
        let began = measured ? clock.now : nil
        try execute(write ? "BEGIN IMMEDIATE" : "BEGIN")
        do {
            let result = try operation()
            let committing = measured ? clock.now : nil
            try execute("COMMIT")
            if write { writeCommits += 1 }
            if let kind = transactionKind, let began, let committing {
                let end = clock.now
                transactionTimes[kind, default: LibraryTransactionTime()].add(Self.milliseconds(began.duration(to: end)),
                                                                              commit: Self.milliseconds(committing.duration(to: end)))
            }
            return result
        } catch {
            rollbacks += 1
            try? execute("ROLLBACK")
            throw error
        }
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

    func rows(_ sql: String, _ values: [LibrarySQLValue] = []) throws -> [[LibrarySQLValue]] {
        guard let handle else { throw FeedLibraryError.closed }
        var statement: OpaquePointer?
        if let reused = statementCache?.removeValue(forKey: sql) {
            statement = reused
        } else {
            let preparation = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
            guard preparation == SQLITE_OK, statement != nil else { throw error(preparation) }
            statementsPrepared += 1
        }
        guard let statement else { throw FeedLibraryError.closed }
        defer {
            statementsRun += 1
            let stepsRun = Int64(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 1))
            statementSteps += stepsRun
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
        var results: [[LibrarySQLValue]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return results }
            guard status == SQLITE_ROW else { throw error(status) }
            var row: [LibrarySQLValue] = []
            for index in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, index)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    if count == 0 { row.append(.blob(Data())) }
                    else if let bytes = sqlite3_column_blob(statement, index) { row.append(.blob(Data(bytes: bytes, count: count))) }
                    else { throw FeedLibraryError.corruptRecord }
                case SQLITE_TEXT:
                    guard let bytes = sqlite3_column_text(statement, index) else { throw FeedLibraryError.corruptRecord }
                    let count = Int(sqlite3_column_bytes(statement, index))
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
