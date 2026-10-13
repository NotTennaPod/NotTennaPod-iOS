import Foundation

/// What local writes touched since a point (PROTOCOL §6.8: a staged result is "published by a bounded atomic
/// switch that keeps concurrent local operations"). A staged publication is no longer judged by library-wide counters:
/// at its switch it asks what changed since it was built, keeps only what lies in its own scope, and re-projects exactly
/// those entities from the base and the current overlays inside the bounded transaction.
///
/// The log is the store connection's own: temporary triggers on the projected tables append to a temporary table, so it
/// holds no saved data, adds nothing to the library's schema, and every writer of the connection is seen (a local action,
/// a playback save, a download finishing, a deferred observation). A write rolled back takes its entries with it. A
/// staging or publication marks its own writes as not local (`quietServerTouches`).
struct ServerTouchWatermark: Sendable, Equatable {
    /// The log this watermark belongs to: a new log (another store, or one pruned past its bound) knows nothing of it.
    var epoch: UUID
    var id: Int64
}

/// Local changes since a watermark, by what they touch.
struct ServerTouches: Sendable, Equatable {
    /// Local episode rows written (and their local playback marks).
    var episodes: Set<Int64> = []
    /// Local feed rows written (and their credentials).
    var feeds: Set<Int64> = []
    /// Overlays added, changed or removed, as `entity|id`.
    var overlays: Set<String> = []
    /// Wire episodes whose deferred pins changed.
    var wire: Set<String> = []
    /// The queue, its keys' owners or its owed adds changed.
    var queue = false
    /// The player's selection or session changed.
    var player = false
    /// An account-level overlay changed (a statistics reset, an account policy): every episode's projection may differ.
    var account = false
    /// Episodes whose download jobs started, stopped or changed owner (a progress update is not a change): a working
    /// media URL and a merge's transfers depend on them.
    var jobs: Set<Int64> = []
    /// Recovery holds changed.
    var holds = false
    /// The log since the watermark is gone (another store, or pruned): nothing is known.
    var unknown = false
    /// More distinct things touched since the watermark than the reader may take, or more entries than it scans
    /// (`serverTouches(since:limit:)`): not read.
    var overflow = false

    var isEmpty: Bool {
        episodes.isEmpty && feeds.isEmpty && overlays.isEmpty && wire.isEmpty && jobs.isEmpty && !queue && !player && !account && !holds
            && !unknown && !overflow
    }
}

extension FeedLibraryStore {
    /// Entries the log keeps at most; past it, it starts over under a new epoch, and a staged result built before cannot
    /// know its local changes: it is published as a whole when it may run (`rebase` defers it meanwhile).
    static let serverTouchLimit = 200_000

    /// The tables whose writes a projection depends on, with what each write touches (an update only when `changed`).
    private static let touchedTables: [(table: String, kind: String, new: String, old: String, changed: String?)] = [
        ("episodes", "'episode'", "NEW.id", "OLD.id", nil),
        ("feeds", "'feed'", "NEW.id", "OLD.id", nil),
        ("feed_credentials", "'feed'", "NEW.feed_id", "OLD.feed_id", nil),
        ("queue", "'queue'", "NULL", "NULL", nil),
        ("ntp_queue_keys", "'queue'", "NULL", "NULL", nil),
        ("ntp_owed", "'queue'", "NULL", "NULL", nil),
        ("playback_selection", "'player'", "NULL", "NULL", nil),
        ("playback_session", "'player'", "NULL", "NULL", nil),
        ("ntp_local_playback", "'episode'", "NEW.episode_id", "OLD.episode_id", nil),
        ("ntp_deferred_pins", "'wire'", "NEW.episode_id", "OLD.episode_id", nil),
        ("ntp_overlays", "CASE WHEN %@.entity = 'account' THEN 'account' ELSE 'overlay' END", "NEW.entity || '|' || NEW.id", "OLD.entity || '|' || OLD.id", nil),
        // A job started or stopped, or moved to another episode (both owners); its progress is not a change.
        ("download_jobs", "'job'", "NEW.episode_id", "OLD.episode_id", "OLD.episode_id IS NOT NEW.episode_id OR OLD.active IS NOT NEW.active OR OLD.source IS NOT NEW.source"),
        ("ntp_recovery_holds", "'hold'", "NULL", "NULL", nil),
    ]

    /// The log's current end, creating the log first (on a server library's store connection). A staged result takes it
    /// before it reads anything; whatever a local write changes afterwards is in the log after it.
    func serverTouchWatermark() throws -> ServerTouchWatermark {
        try ensureServerTouchLog()
        guard let epoch = touchEpoch else { throw ServerRecordingError.notAServerLibrary }
        return ServerTouchWatermark(epoch: epoch, id: try touchLogEnd())
    }

    /// Entries of the log a reader scans at most (about 11 hours of a player's five-second saves).
    static let serverTouchScanLimit = 50_000

    /// What local writes touched after `watermark`: at most `limit` distinct things, scanning at most
    /// `serverTouchScanLimit` entries (`overflow` past either; a save repeats the same few keys).
    func serverTouches(since watermark: ServerTouchWatermark, limit: Int = .max) throws -> ServerTouches {
        var touches = ServerTouches()
        try installLateTouchTriggers()
        guard let epoch = touchEpoch, epoch == watermark.epoch else { touches.unknown = true; return touches }
        if limit < .max {
            // Bounded: whether an entry lies past the scan limit, never a count of the whole suffix.
            let past = try database.rows("SELECT 1 FROM temp.ntp_touches WHERE id > ? ORDER BY id LIMIT 1 OFFSET ?",
                                         [.integer(watermark.id), .integer(Int64(Self.serverTouchScanLimit))])
            if !past.isEmpty { touches.overflow = true; return touches }
        }
        let rows = try database.rows("SELECT DISTINCT kind, key FROM temp.ntp_touches WHERE id > ? LIMIT ?",
                                     [.integer(watermark.id), .integer(limit < .max ? Int64(limit) + 1 : -1)])
        if limit < .max, rows.count > limit { touches.overflow = true; return touches }
        for row in rows {
            switch row[0].text {
            case "episode": if let id = row[1].integer ?? row[1].text.flatMap({ Int64($0) }) { touches.episodes.insert(id) }
            case "feed": if let id = row[1].integer ?? row[1].text.flatMap({ Int64($0) }) { touches.feeds.insert(id) }
            case "overlay": if let key = row[1].text { touches.overlays.insert(key) }
            case "wire": if let key = row[1].text { touches.wire.insert(key) }
            case "queue": touches.queue = true
            case "player": touches.player = true
            case "account": touches.account = true
            case "job":
                if let id = row[1].integer ?? row[1].text.flatMap({ Int64($0) }) { touches.jobs.insert(id) }
            case "hold": touches.holds = true
            default: break
            }
        }
        return touches
    }

    /// Forgets the log up to `id` (nothing staged needs it any more).
    func releaseServerTouches(through id: Int64?) throws {
        guard touchEpoch != nil else { return }
        if let id { try database.execute("DELETE FROM temp.ntp_touches WHERE id <= ?", [.integer(id)]) }
        else { try database.execute("DELETE FROM temp.ntp_touches") }
    }

    /// Runs `body` (inside the caller's transaction) with its writes kept out of the log: a staging's or a publication's
    /// own rows are not local changes.
    func quietServerTouches<T>(_ body: () throws -> T) throws -> T {
        guard touchEpoch != nil else { return try body() }
        try database.execute("INSERT INTO temp.ntp_touch_quiet(one) VALUES (1)")
        let mark = try database.scalar("SELECT last_insert_rowid()")
        // Only its own mark goes: a quiet section inside another leaves the outer one quiet.
        defer { try? database.execute("DELETE FROM temp.ntp_touch_quiet WHERE rowid = ?", [.integer(mark)]) }
        return try body()
    }

    private func touchLogEnd() throws -> Int64 {
        try database.rows("SELECT seq FROM temp.sqlite_sequence WHERE name = 'ntp_touches'").first?.first?.integer ?? 0
    }

    private func ensureServerTouchLog() throws {
        guard serverContext != nil else { throw ServerRecordingError.notAServerLibrary }
        if touchEpoch != nil {
            try installLateTouchTriggers()
            // Bounded: past the limit the log starts over (checked without counting it), and what was built before it is
            // published as a whole when it may run (its touches are unknown).
            if try !database.rows("SELECT 1 FROM temp.ntp_touches ORDER BY id LIMIT 1 OFFSET ?", [.integer(Int64(Self.serverTouchLimit))]).isEmpty {
                try database.execute("DELETE FROM temp.ntp_touches")
                touchEpoch = UUID()
            }
            return
        }
        try database.execute("CREATE TEMP TABLE IF NOT EXISTS ntp_touches (id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, key)")
        try database.execute("CREATE TEMP TABLE IF NOT EXISTS ntp_touch_quiet (one INTEGER)")
        let existing = Set(try database.rows("SELECT name FROM main.sqlite_master WHERE type = 'table'").compactMap { $0[0].text })
        touchTablesMissing = Set(Self.touchedTables.map(\.table)).subtracting(existing)
        try installTouchTriggers(Self.touchedTables.filter { existing.contains($0.table) })
        touchEpoch = UUID()
    }

    /// A table the log covers that appeared after the log was created (`ntp_recovery_holds`,
    /// created by its first use): its triggers are installed now, and the log starts over under a
    /// new epoch, since its writes before now were not logged (what was built before is published
    /// as a whole when it may run).
    private func installLateTouchTriggers() throws {
        guard touchEpoch != nil, !touchTablesMissing.isEmpty else { return }
        let existing = Set(try database.rows("SELECT name FROM main.sqlite_master WHERE type = 'table'").compactMap { $0[0].text })
        let appeared = touchTablesMissing.intersection(existing)
        guard !appeared.isEmpty else { return }
        try installTouchTriggers(Self.touchedTables.filter { appeared.contains($0.table) })
        touchTablesMissing.subtract(appeared)
        try database.execute("DELETE FROM temp.ntp_touches")
        touchEpoch = UUID()
    }

    private func installTouchTriggers(_ tables: [(table: String, kind: String, new: String, old: String, changed: String?)]) throws {
        for touched in tables {
            for (operation, row) in [("INSERT", "NEW"), ("UPDATE", "NEW"), ("DELETE", "OLD")] {
                let kind = touched.kind.replacingOccurrences(of: "%@", with: row)
                let key = row == "NEW" ? touched.new : touched.old
                let changed = operation == "UPDATE" ? touched.changed.map { " AND (\($0))" } ?? "" : ""
                // An update that moves a row to another owner touches the old one too.
                let previous = operation == "UPDATE" && touched.old != touched.new && touched.old != "NULL"
                    ? " INSERT INTO temp.ntp_touches(kind, key) SELECT \(touched.kind.replacingOccurrences(of: "%@", with: "OLD")), \(touched.old) WHERE \(touched.old) IS NOT \(touched.new);" : ""
                try database.execute("""
                    CREATE TEMP TRIGGER IF NOT EXISTS ntp_touch_\(touched.table)_\(operation.lowercased()) AFTER \(operation) ON main.\(touched.table)
                    WHEN NOT EXISTS (SELECT 1 FROM temp.ntp_touch_quiet)\(changed)
                    BEGIN INSERT INTO temp.ntp_touches(kind, key) VALUES (\(kind), \(key));\(previous) END
                    """)
            }
        }
    }
}
