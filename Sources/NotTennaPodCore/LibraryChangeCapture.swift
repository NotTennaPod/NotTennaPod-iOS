import CommonCrypto
import Foundation
import SQLite3

/// The capture of each write transaction's committed visible difference (`LibraryChangeSet`), installed on a library's
/// write connection as TEMP objects only: connection-local, nothing in the library's schema or file.
///
/// * BEFORE triggers on every table the visible model reads record, at the first touch of each key in the transaction,
///   that key's image as of the transaction's start (present, parent, a 128-bit digest of what the screens read) in
///   `temp.ntp_vis_before`. The capture tables have no constraints and every insert is guarded by `NOT EXISTS`, so no
///   outer conflict policy (`OR REPLACE`, `OR IGNORE`, an upsert) can make a capture abort, block or alter a write, and an
///   image's digest is computed once per key and transaction. A parent's trigger captures what its delete cascades to
///   before the cascade runs.
/// * Visibility as of the start: the first write to a podcast's or an episode's hide sources (pinned removals, hidden
///   staging or removal, the server's pinned removal) records whether it was visible then (`feedvis`, `epvis`), and every
///   later before-image reads that instead of the changed sources. A podcast's visibility change costs its own keys and
///   the queue, never its episodes: they go with the podcast in the change set.
/// * The visible queue order is captured whole, once, at the first change that can move it (proportional to the queue).
/// * At the boundary, before COMMIT, the after-images of exactly the captured keys are compared with the before-images;
///   only real differences are reported, then the capture tables are emptied. A rollback (or `ROLLBACK TO`) takes the
///   captures with it.
/// * Position knowledge is a separate AFTER-trigger log of the episodes whose position records, overlays, sessions,
///   pins, holds or recovery state changed.
final class LibraryChangeCapture {
    enum Relation: String, CaseIterable {
        case feed, episode, statistics, download, undo, folder
        var episodeKeyed: Bool { self != .feed && self != .folder }
    }

    /// Test-only faults (mutation checks): each must make a named witness fail.
    enum Fault: Hashable, Sendable {
        /// A capture trigger is not installed.
        case dropTrigger(String)
        /// Removals do not carry their former feed.
        case noFormerParent
        /// Every member present before and after is reported relinked.
        case queueAllMembers
        /// Every captured key is reported changed (a write union, no net difference).
        case rawWrites
        /// Before-images read the visibility as it is at their capture (no `feedvis`/`epvis`).
        case noStartVisibility
        /// The digest is computed before the presence check, at every touch.
        case digestBeforeGuard
        /// Constrained capture keys inserted with an inner `OR IGNORE` (the outer conflict policy overrides it).
        case uniqueKeyOrIgnore
        /// The podcast mapping's capture fires on the columns an update names, not on changed values.
        case gateByColumns
        /// Removals of the feed are not collapsed into the feed: its episodes are listed too.
        case noCollapse
        /// An episode's statistics image hashes all its units (an episode-only update reads them all).
        case unitsInEpisodeDigest
        /// The queue's order captured by a per-member rank count (same order, quadratic work).
        case quadraticQueueOrder
        /// The download image's lookup made unkeyed (`+ 0` on the key column: the same rows by a scan).
        case unkeyedDownloadDigest
        /// A podcast's hide expanded over every podcast's image (work that grows with the other podcasts).
        case hideScansAllFeeds
    }

    /// The main tables whose writes the capture watches. A table missing in this library (the server tables of a
    /// standalone one) is left out, and the capture is installed again when it appears.
    static let modelTables = ["feeds", "episodes", "queue", "statistics_units", "download_jobs", "episode_swipe_undo",
                              "local_folder_links", "pinned_feed_removals", "ntp_hidden_feeds", "ntp_hidden_episodes", "ntp_podcasts"]
    static let knowledgeTables = ["ntp_records", "ntp_overlays", "ntp_sessions", "ntp_episodes", "ntp_deferred_pins",
                                  "ntp_recovery_holds", "ntp_library", "ntp_podcasts"]
    /// The derived keys and counts (schema 21) are model tables of relation `episode`. Only the schema's
    /// own triggers write them, from model tables above in the same transaction (and their background fill, which nothing
    /// reads until it is complete), so their change is the change of an episode, or of a podcast with its episodes, that
    /// the capture reports from those sources: no trigger of their own, whose before-image could only repeat the episode's.
    static let derivedTables = ["episode_list_keys", "feed_list_counts"]
    static let sequenceTable = "library_change_sequence"
    static let triggerPrefix = "ntp_vis_"

    private(set) var tables: Set<String> = []
    /// The watched tables' definitions (`sqlite_master.sql`) the triggers were installed for: a table created, dropped or
    /// defined again since is installed again.
    private var definitions: [String: String] = [:]
    private(set) var triggerNames: [String] = []
    private(set) var hasSequenceTable = false
    /// The sequence when no persisted row exists: this opening's own, from 0.
    var memorySequence: Int64 = 0
    var faults: Set<Fault> = []
    /// Rows the capture wrote into and cleared from its tables, kept out of the connection's measured row writes.
    var changesWritten: Int64 = 0
    /// Digest inputs (one per scalar call or aggregated row), for the capture's own work budgets.
    let counter = LibraryDigestCounter()
    /// Rows the drains read to find differences (before-images read back, queue members, knowledge entries).
    private(set) var drainRows: Int64 = 0
    /// Commits whose capture found nothing (a cheap probe only).
    private(set) var emptyDrains = 0

    // MARK: - Installation

    func install(_ db: LibrarySQLite) throws {
        try registerFunctions(db)
        // A capture installed again (test faults) starts from empty tables of its own shape.
        for table in ["ntp_vis_before", "ntp_vis_queue", "ntp_vis_knowledge", "ntp_vis_units"] { try db.execute("DROP TABLE IF EXISTS temp.\(table)") }
        let constraint = faults.contains(.uniqueKeyOrIgnore) ? ", UNIQUE(rel, key)" : ""
        try db.execute("CREATE TEMP TABLE IF NOT EXISTS ntp_vis_before (rel TEXT, key INTEGER, present INTEGER, parent INTEGER, digest BLOB\(constraint))")
        try db.execute("CREATE INDEX IF NOT EXISTS temp.ntp_vis_before_key ON ntp_vis_before(rel, key)")
        try db.execute("CREATE TEMP TABLE IF NOT EXISTS ntp_vis_queue (episode_id INTEGER)")
        // Statistics units, each at its first touch: an episode's statistics change when one of its units does, at the cost
        // of the units written, never of the units it already has.
        try db.execute("CREATE TEMP TABLE IF NOT EXISTS ntp_vis_units (episode_id INTEGER, unit_id TEXT, present INTEGER, digest BLOB)")
        try db.execute("CREATE INDEX IF NOT EXISTS temp.ntp_vis_units_key ON ntp_vis_units(episode_id, unit_id)")
        try db.execute("CREATE TEMP TABLE IF NOT EXISTS ntp_vis_knowledge (kind TEXT, key)")
        try db.execute("CREATE INDEX IF NOT EXISTS temp.ntp_vis_knowledge_key ON ntp_vis_knowledge(kind, key)")
        try reinstall(db)
    }

    /// Installs the triggers again when the watched tables changed (a schema created after the library opened).
    func refresh(_ db: LibrarySQLite) throws {
        guard try existingDefinitions(db) != definitions || existsSequenceTable(db) != hasSequenceTable else { return }
        try reinstall(db)
    }

    private func existingDefinitions(_ db: LibrarySQLite) throws -> [String: String] {
        let names = Self.modelTables + Self.knowledgeTables
        let list = names.map { "'\($0)'" }.joined(separator: ", ")
        var result: [String: String] = [:]
        for row in try db.rows("SELECT name, sql FROM main.sqlite_master WHERE type = 'table' AND name IN (\(list))") {
            if let name = row[0].text { result[name] = row[1].text ?? "" }
        }
        return result
    }

    private func columns(_ db: LibrarySQLite, _ tables: Set<String>) throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for table in tables { result[table] = Set(try db.rows("PRAGMA main.table_info(\(table))").compactMap { $0[1].text }) }
        return result
    }

    private func existsSequenceTable(_ db: LibrarySQLite) throws -> Bool {
        try db.scalar("SELECT count(*) FROM main.sqlite_master WHERE type = 'table' AND name = ?", [.text(Self.sequenceTable)]) == 1
    }

    private func reinstall(_ db: LibrarySQLite) throws {
        for row in try db.rows("SELECT name FROM temp.sqlite_master WHERE type = 'trigger' AND name LIKE 'ntp\\_vis\\_%' ESCAPE '\\'") {
            if let name = row.first?.text { try db.execute("DROP TRIGGER IF EXISTS temp.\(name)") }
        }
        definitions = try existingDefinitions(db)
        tables = Set(definitions.keys)
        hasSequenceTable = try existsSequenceTable(db)
        let sql = SQL(tables: tables, columns: try columns(db, tables), faults: faults)
        var names: [String] = []
        for trigger in sql.triggers() {
            if faults.contains(.dropTrigger(trigger.name)) { continue }
            try db.execute(trigger.statement)
            names.append(trigger.name)
        }
        triggerNames = names
        statements = sql.drainStatements()
    }

    /// The installed trigger count, checked against SQLite's at each write transaction's start in debug builds.
    func verifyInstalled(_ db: LibrarySQLite) throws {
        let count = try db.scalar("SELECT count(*) FROM temp.sqlite_master WHERE type = 'trigger' AND name LIKE 'ntp\\_vis\\_%' ESCAPE '\\'")
        guard count == Int64(triggerNames.count) else {
            throw FeedLibraryError.sqlite(code: SQLITE_INTERNAL, message: "change capture: \(count) of \(triggerNames.count) triggers installed")
        }
    }

    // MARK: - The boundary

    private var statements: SQL.Drain?

    /// Before COMMIT: the transaction's visible difference and knowledge, and the sequence the set takes (persisted in
    /// the same transaction when the library has its sequence row). Empties the capture tables.
    func drain(_ db: LibrarySQLite, identity: LibraryChangeHub.Identity, origin: LibraryChangeOrigin) throws -> Pending? {
        guard let statements else { return nil }
        let probe = try db.rows("SELECT EXISTS (SELECT 1 FROM temp.ntp_vis_before) OR EXISTS (SELECT 1 FROM temp.ntp_vis_units), EXISTS (SELECT 1 FROM temp.ntp_vis_knowledge)")
        let hasImages = probe.first?[0].integer == 1, hasKnowledge = probe.first?[1].integer == 1
        guard hasImages || hasKnowledge else { emptyDrains += 1; return nil }
        var written: Int64 = 0
        var set = LibraryChangeSet(identity: identity, sequence: 0, origin: origin)
        var knowledge: LibraryPositionKnowledge?
        if hasImages {
            written += try db.scalar("SELECT count(*) FROM temp.ntp_vis_before")
            var raw: [Relation: [Row]] = [:]
            for relation in Relation.allCases {
                let rows = try db.rows(faults.contains(.rawWrites) ? statements.raw[relation]! : statements.changed[relation]!)
                drainRows += Int64(rows.count)
                raw[relation] = rows.map { Row(key: $0[0].integer ?? 0, bp: $0[1].integer == 1, bpar: $0[2].integer,
                                                ap: $0[3].integer == 1, apar: $0[4].integer) }
            }
            // Units that changed: their episodes' statistics changed, unless already decided by the episode's own image.
            let units = try db.scalar("SELECT count(*) FROM temp.ntp_vis_units")
            if units > 0 {
                written += units
                let episodes = try db.rows(statements.unitsChanged).compactMap { $0[0].integer }
                drainRows += units
                let decided = Set((raw[.statistics] ?? []).map(\.key))
                for episode in episodes where !decided.contains(episode) {
                    guard let row = try db.rows(statements.unitEpisode, [.integer(episode)]).first else { continue }
                    let bp = row[0].integer == 1, ap = row[1].integer == 1
                    guard bp || ap else { continue }
                    raw[.statistics, default: []].append(Row(key: episode, bp: bp, bpar: row[2].integer, ap: ap, apar: row[2].integer))
                }
                try db.execute("DELETE FROM temp.ntp_vis_units")
            }
            if try db.scalar("SELECT count(*) FROM temp.ntp_vis_before WHERE rel = 'queue'") > 0 {
                let before = try db.rows("SELECT episode_id FROM temp.ntp_vis_queue ORDER BY rowid").compactMap { $0[0].integer }
                let after = try db.rows(statements.queueAfter).compactMap { $0[0].integer }
                drainRows += Int64(before.count + after.count)
                written += Int64(before.count)
                let change = Self.queueChange(before: before, after: after, allMembers: faults.contains(.queueAllMembers))
                if !change.isEmpty { set.queue = change }
            }
            assemble(&set, raw)
            try db.execute("DELETE FROM temp.ntp_vis_before")
            try db.execute("DELETE FROM temp.ntp_vis_queue")
        }
        if hasKnowledge {
            var found = LibraryPositionKnowledge()
            var wire: [String] = []
            let rows = try db.rows("SELECT kind, key FROM temp.ntp_vis_knowledge")
            written += Int64(rows.count)
            drainRows += Int64(rows.count)
            for row in rows {
                switch row[0].text {
                case "all": found.all = true
                case "local": if let id = row[1].integer { found.episodes.insert(id) }
                default:
                    guard let text = row[1].text else { continue }
                    if text.hasPrefix("local-episode:"), let id = Int64(text.dropFirst("local-episode:".count)) { found.episodes.insert(id) }
                    else { wire.append(text) }
                }
            }
            if !wire.isEmpty, tables.contains("ntp_episodes") {
                let list = ContractJSON.array(wire.map(ContractJSON.string)).canonicalText
                for row in try db.rows("SELECT local_id FROM main.ntp_episodes WHERE episode_id IN (SELECT value FROM json_each(?)) AND local_id IS NOT NULL", [.text(list)]) {
                    if let id = row[0].integer { found.episodes.insert(id) }
                }
            }
            if !found.isEmpty { knowledge = found }
            try db.execute("DELETE FROM temp.ntp_vis_knowledge")
        }
        // Each captured row was inserted and then deleted.
        changesWritten += 2 * written
        guard !set.isEmpty else { return Pending(set: nil, knowledge: knowledge, persisted: false) }
        if hasSequenceTable {
            // The table's row is created with the table; a table without it is a damaged order, never silently replaced by
            // a per-opening count: the transaction fails and rolls back.
            guard let next = try db.rows("UPDATE main.\(Self.sequenceTable) SET seq = seq + 1 WHERE id = 1 RETURNING seq").first?.first?.integer else {
                throw LibraryChangeSequenceError.missingRow
            }
            changesWritten += 1
            set.sequence = next
            return Pending(set: set, knowledge: knowledge, persisted: true)
        }
        set.sequence = memorySequence + 1
        return Pending(set: set, knowledge: knowledge, persisted: false)
    }

    struct Pending {
        var set: LibraryChangeSet?
        var knowledge: LibraryPositionKnowledge?
        var persisted: Bool
    }

    /// After COMMIT succeeded: an in-memory sequence moves on only now.
    func committed(_ pending: Pending) {
        if let set = pending.set, !pending.persisted { memorySequence = set.sequence }
    }

    /// The last sequence of the library's order of visible changes.
    func currentSequence(_ db: LibrarySQLite) throws -> Int64 {
        if hasSequenceTable {
            guard let value = try db.rows("SELECT seq FROM main.\(Self.sequenceTable) WHERE id = 1").first?.first?.integer else {
                throw LibraryChangeSequenceError.missingRow
            }
            return value
        }
        return memorySequence
    }

    struct Row { var key: Int64; var bp: Bool; var bpar: Int64?; var ap: Bool; var apar: Int64? }

    private func assemble(_ set: inout LibraryChangeSet, _ raw: [Relation: [Row]]) {
        func change(_ row: Row) -> LibraryChangeSet.Change { row.bp == row.ap ? .changed : row.ap ? .added : .removed }
        for row in raw[.feed] ?? [] { set.feeds[row.key] = change(row) }
        let collapse = !faults.contains(.noCollapse)
        // A feed entering or leaving the visible model carries its own keys.
        func implied(_ kind: LibraryChangeSet.Change, feed: Int64?) -> Bool {
            guard collapse, kind != .changed, let feed else { return false }
            return set.feeds[feed] == kind
        }
        for row in raw[.folder] ?? [] {
            let kind = change(row)
            if !implied(kind, feed: row.key) { set.localFolders[row.key] = kind }
        }
        let noFormer = faults.contains(.noFormerParent)
        for relation in [Relation.episode, .statistics, .download, .undo] {
            var result: [Int64: LibraryChangeSet.EpisodeChange] = [:]
            for row in raw[relation] ?? [] {
                let kind = change(row)
                switch kind {
                case .added:
                    if !implied(.added, feed: row.apar) { result[row.key] = .init(change: .added, feed: row.apar) }
                case .removed:
                    if !implied(.removed, feed: row.bpar) { result[row.key] = .init(change: .removed, feed: noFormer ? nil : row.bpar) }
                case .changed:
                    result[row.key] = .init(change: .changed, feed: row.apar,
                                            formerFeed: noFormer || row.bpar == row.apar ? nil : row.bpar)
                }
            }
            switch relation {
            case .episode: set.episodes = result
            case .statistics: set.statistics = result
            case .download: set.downloads = result
            case .undo: set.undo = result
            default: break
            }
        }
    }

    /// The queue contract: members added and removed, and the members present before and after whose visible
    /// predecessor (in the whole visible order) changed.
    static func queueChange(before: [Int64], after: [Int64], allMembers: Bool = false) -> LibraryChangeSet.QueueChange {
        guard before != after else { return .init() }
        let old = Set(before), new = Set(after)
        var change = LibraryChangeSet.QueueChange(added: new.subtracting(old), removed: old.subtracting(new))
        var predecessor: [Int64: Int64?] = [:]
        for (index, id) in before.enumerated() { predecessor[id] = index == 0 ? nil : before[index - 1] }
        for (index, id) in after.enumerated() where old.contains(id) {
            let now: Int64? = index == 0 ? nil : after[index - 1]
            if allMembers || predecessor[id].map({ $0 != now }) == true { change.relinked.insert(id) }
        }
        return change
    }

    // MARK: - Digest functions

    private var registered = false

    private func registerFunctions(_ db: LibrarySQLite) throws {
        guard !registered else { return }
        let flags = SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS
        let data = Unmanaged.passUnretained(counter).toOpaque()
        try db.withHandle { handle in
            var status = sqlite3_create_function_v2(handle, "ntp_digest", -1, flags, data, libraryDigestScalar, nil, nil, nil)
            guard status == SQLITE_OK else { return status }
            status = sqlite3_create_function_v2(handle, "ntp_digest_rows", -1, flags, data, nil, libraryDigestStep, libraryDigestFinal, nil)
            return status
        }
        registered = true
    }
}

/// How many digest inputs the capture hashed (one per scalar call or aggregated row).
final class LibraryDigestCounter: @unchecked Sendable {
    var inputs: Int64 = 0
}

// MARK: - SQL

extension LibraryChangeCapture {
    struct Trigger { var name: String; var statement: String }

    /// The capture's SQL for a library holding `tables`.
    struct SQL {
        let tables: Set<String>
        var columns: [String: Set<String>] = [:]
        let faults: Set<Fault>
        func has(_ table: String) -> Bool { tables.contains(table) }

        // Visibility (PROTOCOL §6.8, §15.4): a podcast no list shows is a pinned removal (every library), and in a server
        // library a hidden podcast (staging or removing) or the server's pinned removal; an episode is shown when its
        // podcast is, unless it is staged and not yet revealed.

        func feedHiddenNow(_ feed: String) -> String {
            var sources: [String] = []
            if has("pinned_feed_removals") { sources.append("EXISTS (SELECT 1 FROM main.pinned_feed_removals AS hp WHERE hp.feed_id = \(feed))") }
            if has("ntp_hidden_feeds") { sources.append("EXISTS (SELECT 1 FROM main.ntp_hidden_feeds AS hh WHERE hh.feed_id = \(feed))") }
            if has("ntp_podcasts") { sources.append("EXISTS (SELECT 1 FROM main.ntp_podcasts AS hs WHERE hs.feed_id = \(feed) AND hs.pinned_removal = 1)") }
            return sources.isEmpty ? "0" : "(" + sources.joined(separator: " OR ") + ")"
        }

        func episodeMarkedNow(_ episode: String) -> String {
            has("ntp_hidden_episodes") ? "EXISTS (SELECT 1 FROM main.ntp_hidden_episodes AS he WHERE he.episode_id = \(episode))" : "0"
        }

        /// Hidden at the transaction's start (`start`) or now.
        func feedHidden(_ feed: String, start: Bool) -> String {
            guard start, !faults.contains(.noStartVisibility) else { return feedHiddenNow(feed) }
            return "coalesce((SELECT 1 - mf.present FROM temp.ntp_vis_before AS mf WHERE mf.rel = 'feedvis' AND mf.key = \(feed) LIMIT 1), \(feedHiddenNow(feed)))"
        }

        func episodeMarked(_ episode: String, start: Bool) -> String {
            guard start, !faults.contains(.noStartVisibility) else { return episodeMarkedNow(episode) }
            return "coalesce((SELECT 1 - me.present FROM temp.ntp_vis_before AS me WHERE me.rel = 'epvis' AND me.key = \(episode) LIMIT 1), \(episodeMarkedNow(episode)))"
        }

        func episodePresent(_ key: String, start: Bool) -> String {
            "coalesce((SELECT NOT \(feedHidden("pv.feed_id", start: start)) AND NOT \(episodeMarked("pv.id", start: start)) FROM main.episodes AS pv WHERE pv.id = \(key)), 0)"
        }

        func feedPresent(_ key: String, start: Bool) -> String {
            "(EXISTS (SELECT 1 FROM main.feeds AS pf WHERE pf.id = \(key)) AND NOT \(feedHidden(key, start: start)))"
        }

        func present(_ relation: Relation, _ key: String, start: Bool) -> String {
            switch relation {
            case .feed: feedPresent(key, start: start)
            case .episode, .statistics: episodePresent(key, start: start)
            case .download: "(\(episodePresent(key, start: start)) AND EXISTS (SELECT 1 FROM main.download_jobs AS pd WHERE pd.episode_id = \(key) AND pd.active = 1))"
            case .undo: "(\(episodePresent(key, start: start)) AND EXISTS (SELECT 1 FROM main.episode_swipe_undo AS pu WHERE pu.episode_id = \(key)))"
            case .folder: "(\(feedPresent(key, start: start)) AND EXISTS (SELECT 1 FROM main.local_folder_links AS pl WHERE pl.feed_id = \(key)))"
            }
        }

        func parent(_ relation: Relation, _ key: String) -> String {
            relation.episodeKeyed ? "(SELECT pe.feed_id FROM main.episodes AS pe WHERE pe.id = \(key))" : "NULL"
        }

        /// The fields statistics read of an episode record (`LibraryStatistics`, `LibraryStatisticsUnit.statisticsRow`).
        static let statisticsFields = [
            "json_extract(t, '$.userState.playState')",
            "coalesce(json_extract(t, '$.userState.positionMilliseconds'), 0) > 0",
            "json_extract(t, '$.userState.playedDurationMilliseconds')",
            "json_extract(t, '$.userState.lastPlayedTimeMilliseconds')",
            "json_extract(t, '$.userState.lastPlayedHistoryMilliseconds')",
            "json_extract(t, '$.userState.downloadDate')",
            "json_extract(t, '$.details.publicationDate')",
            "json_type(t, '$.details.media')",
            "json_extract(t, '$.details.media.durationMilliseconds')",
            "json_extract(t, '$.details.media.size')",
        ]

        func digest(_ relation: Relation, _ key: String) -> String {
            switch relation {
            case .feed: "(SELECT ntp_digest(df.title, df.record) FROM main.feeds AS df WHERE df.id = \(key))"
            case .episode: "(SELECT ntp_digest(de.pubdate, de.record) FROM main.episodes AS de WHERE de.id = \(key))"
            case .statistics:
                // A malformed record never makes the capture raise: its bytes stand for its fields.
                // The units are captured one by one (`captureUnit`); here only the episode's own fields, so an episode's
                // update never reads its units.
                "(SELECT ntp_digest(CASE WHEN json_valid(ds.t) THEN json_array(\(Self.statisticsFields.map { $0.replacingOccurrences(of: "(t,", with: "(ds.t,") }.joined(separator: ", "))) ELSE ds.t END"
                    + (faults.contains(.unitsInEpisodeDigest) ? ", (SELECT ntp_digest_rows(su.unit_id, su.played_ms, su.last_played, su.history, su.duration_ms, su.played, su.position ORDER BY su.unit_id) FROM main.statistics_units AS su WHERE su.episode_id = \(key))" : "")
                    + ") FROM (SELECT CAST(dse.record AS TEXT) AS t FROM main.episodes AS dse WHERE dse.id = \(key)) AS ds)"
            case .download: "(SELECT ntp_digest_rows(dd.id, dd.source, dd.record ORDER BY dd.id) FROM main.download_jobs AS dd WHERE dd.episode_id\(faults.contains(.unkeyedDownloadDigest) ? " + 0" : "") = \(key) AND dd.active = 1)"
            case .undo: "(SELECT ntp_digest(du.operation_id) FROM main.episode_swipe_undo AS du WHERE du.episode_id = \(key))"
            case .folder: "(SELECT ntp_digest(dl.record) FROM main.local_folder_links AS dl WHERE dl.feed_id = \(key))"
            }
        }

        private func notCaptured(_ relation: String, _ key: String) -> String {
            "NOT EXISTS (SELECT 1 FROM temp.ntp_vis_before AS c WHERE c.rel = '\(relation)' AND c.key = \(key))"
        }

        /// The first image of `relation` at `key` (as of the transaction's start): presence and parent, and its digest
        /// only when present and not captured yet.
        func capture(_ relation: Relation, _ key: String) -> String {
            let present = present(relation, key, start: true)
            if faults.contains(.uniqueKeyOrIgnore) {
                return "INSERT OR IGNORE INTO ntp_vis_before(rel, key, present, parent, digest) SELECT '\(relation.rawValue)', \(key), \(present), \(parent(relation, key)), CASE WHEN \(present) THEN \(digest(relation, key)) END WHERE \(key) IS NOT NULL;"
            }
            let eager = faults.contains(.digestBeforeGuard) ? "SELECT \(digest(relation, key));" : ""
            return eager + "INSERT INTO ntp_vis_before(rel, key, present, parent, digest) SELECT '\(relation.rawValue)', \(key), \(present), \(parent(relation, key)), CASE WHEN \(present) THEN \(digest(relation, key)) END WHERE \(key) IS NOT NULL AND \(notCaptured(relation.rawValue, key));"
        }

        /// A statistics unit's first image: whether it existed and its digest, once per unit and transaction.
        func captureUnit(_ episode: String, _ unit: String) -> String {
            let image = "(SELECT ntp_digest(cu.played_ms, cu.last_played, cu.history, cu.duration_ms, cu.played, cu.position) FROM main.statistics_units AS cu WHERE cu.episode_id = \(episode) AND cu.unit_id = \(unit))"
            let eager = faults.contains(.digestBeforeGuard) ? "SELECT \(image);" : ""
            return eager + "INSERT INTO ntp_vis_units(episode_id, unit_id, present, digest) SELECT \(episode), \(unit), "
                + "EXISTS (SELECT 1 FROM main.statistics_units AS cp WHERE cp.episode_id = \(episode) AND cp.unit_id = \(unit)), \(image) "
                + "WHERE NOT EXISTS (SELECT 1 FROM temp.ntp_vis_units AS c WHERE c.episode_id = \(episode) AND c.unit_id = \(unit));"
        }

        /// The visible queue order as of the transaction's start. Runs in its own trigger whose WHEN is
        /// `queueCondition`: once per transaction (a trigger body cannot skip its scan on a constant guard).
        func captureQueue() -> String {
            guard has("queue") else { return "" }
            let order = faults.contains(.quadraticQueueOrder) ? "(SELECT count(*) FROM main.queue AS qr WHERE qr.position <= q.position)" : "q.position"
            return "INSERT INTO ntp_vis_queue(episode_id) SELECT q.episode_id FROM main.queue AS q JOIN main.episodes AS qv ON qv.id = q.episode_id WHERE NOT \(feedHidden("qv.feed_id", start: true)) AND NOT \(episodeMarked("qv.id", start: true)) ORDER BY \(order);"
                + "INSERT INTO ntp_vis_before(rel, key, present, parent, digest) VALUES ('queue', 0, 1, NULL, NULL);"
        }

        /// The queue capture's WHEN: `condition`, and the queue not captured yet in this transaction.
        func queueCondition(_ condition: String = "1") -> String {
            "(\(condition)) AND \(notCaptured("queue", "0"))"
        }

        func queuedCondition(_ episode: String) -> String {
            has("queue") ? "EXISTS (SELECT 1 FROM main.queue AS qq WHERE qq.episode_id = \(episode))" : "0"
        }

        /// A write to a podcast's hide source: whether it was visible at the start and its own keys (the queue is captured
        /// by the source's queue trigger).
        func captureHide(_ feed: String) -> String {
            let expansion = faults.contains(.hideScansAllFeeds)
                ? "INSERT INTO ntp_vis_before(rel, key, present, parent, digest) SELECT 'feedscan', af.id, 1, NULL, ntp_digest(af.record) FROM main.feeds AS af WHERE \(notCaptured("feedscan", "af.id"));"
                : ""
            let marker = expansion + (faults.contains(.noStartVisibility) ? "" :
                "INSERT INTO ntp_vis_before(rel, key, present, parent, digest) SELECT 'feedvis', \(feed), NOT \(feedHiddenNow(feed)), NULL, NULL WHERE \(feed) IS NOT NULL AND \(notCaptured("feedvis", feed));")
            return marker + capture(.feed, feed) + capture(.folder, feed)
        }

        /// A write to an episode's staging mark: whether it was visible at the start and its keys.
        func captureMark(_ episode: String) -> String {
            let marker = faults.contains(.noStartVisibility) ? "" :
                "INSERT INTO ntp_vis_before(rel, key, present, parent, digest) SELECT 'epvis', \(episode), NOT \(episodeMarkedNow(episode)), NULL, NULL WHERE \(episode) IS NOT NULL AND \(notCaptured("epvis", episode));"
            return marker + capture(.episode, episode) + capture(.statistics, episode) + capture(.download, episode) + capture(.undo, episode)
        }

        func knowledge(_ kind: String, _ key: String) -> String {
            "INSERT INTO ntp_vis_knowledge(kind, key) SELECT '\(kind)', \(key) WHERE \(key) IS NOT NULL AND NOT EXISTS (SELECT 1 FROM temp.ntp_vis_knowledge AS k WHERE k.kind = '\(kind)' AND k.key = \(key));"
        }

        func triggers() -> [Trigger] {
            var list: [Trigger] = []
            func add(_ table: String, _ timing: String, _ event: String, suffix: String = "", when: String? = nil, _ body: String) {
                guard has(table), !body.isEmpty else { return }
                // Only on a table holding every column the trigger reads of its row.
                if let known = columns[table] {
                    let text = (when ?? "") + " " + body
                    let pattern = /(?:NEW|OLD)\.([a-z_]+)/
                    for match in text.matches(of: pattern) where !known.contains(String(match.output.1)) { return }
                }
                let name = "ntp_vis_\(table)_\(timing.prefix(1).lowercased())\(event.prefix(1).lowercased())\(suffix)"
                let condition = when.map { " WHEN \($0)" } ?? ""
                list.append(Trigger(name: name, statement: "CREATE TEMP TRIGGER \(name) \(timing) \(event) ON main.\(table)\(condition) BEGIN \(body) END"))
            }
            // Rows the screens read.
            add("feeds", "BEFORE", "INSERT", capture(.feed, "NEW.id"))
            add("feeds", "BEFORE", "UPDATE", capture(.feed, "OLD.id"))
            // Its folder link cascades away with it; its episodes' own triggers run as they cascade.
            add("feeds", "BEFORE", "DELETE", capture(.feed, "OLD.id") + capture(.folder, "OLD.id"))
            add("episodes", "BEFORE", "INSERT", capture(.episode, "NEW.id") + capture(.statistics, "NEW.id"))
            add("episodes", "BEFORE", "UPDATE", capture(.episode, "OLD.id") + capture(.statistics, "OLD.id"))
            add("episodes", "BEFORE", "UPDATE", suffix: "_move", when: "OLD.feed_id IS NOT NEW.feed_id",
                capture(.download, "OLD.id") + capture(.undo, "OLD.id"))
            add("episodes", "BEFORE", "UPDATE", suffix: "_move_queue", when: queueCondition("OLD.feed_id IS NOT NEW.feed_id AND " + queuedCondition("OLD.id")),
                captureQueue())
            // What the delete cascades to (statistics units, jobs, the Undo guard, the queue entry) before it goes.
            add("episodes", "BEFORE", "DELETE", capture(.episode, "OLD.id") + capture(.statistics, "OLD.id") + capture(.download, "OLD.id")
                + capture(.undo, "OLD.id"))
            add("episodes", "BEFORE", "DELETE", suffix: "_queue", when: queueCondition(queuedCondition("OLD.id")), captureQueue())
            for event in ["INSERT", "UPDATE", "DELETE"] { add("queue", "BEFORE", event, when: queueCondition(), captureQueue()) }
            add("statistics_units", "BEFORE", "INSERT", captureUnit("NEW.episode_id", "NEW.unit_id"))
            add("statistics_units", "BEFORE", "UPDATE", captureUnit("OLD.episode_id", "OLD.unit_id") + captureUnit("NEW.episode_id", "NEW.unit_id"))
            add("statistics_units", "BEFORE", "DELETE", captureUnit("OLD.episode_id", "OLD.unit_id"))
            add("download_jobs", "BEFORE", "INSERT", capture(.download, "NEW.episode_id"))
            add("download_jobs", "BEFORE", "UPDATE", capture(.download, "OLD.episode_id") + capture(.download, "NEW.episode_id"))
            add("download_jobs", "BEFORE", "DELETE", capture(.download, "OLD.episode_id"))
            add("episode_swipe_undo", "BEFORE", "INSERT", capture(.undo, "NEW.episode_id"))
            add("episode_swipe_undo", "BEFORE", "UPDATE", capture(.undo, "OLD.episode_id") + capture(.undo, "NEW.episode_id"))
            add("episode_swipe_undo", "BEFORE", "DELETE", capture(.undo, "OLD.episode_id"))
            add("local_folder_links", "BEFORE", "INSERT", capture(.folder, "NEW.feed_id"))
            add("local_folder_links", "BEFORE", "UPDATE", capture(.folder, "OLD.feed_id") + capture(.folder, "NEW.feed_id"))
            add("local_folder_links", "BEFORE", "DELETE", capture(.folder, "OLD.feed_id"))
            // Visibility sources.
            // A visibility source's write captures the podcast's keys, and the queue once (its own trigger).
            for table in ["pinned_feed_removals", "ntp_hidden_feeds"] {
                add(table, "BEFORE", "INSERT", captureHide("NEW.feed_id"))
                add(table, "BEFORE", "UPDATE", captureHide("OLD.feed_id") + captureHide("NEW.feed_id"))
                add(table, "BEFORE", "DELETE", captureHide("OLD.feed_id"))
                for event in ["INSERT", "UPDATE", "DELETE"] { add(table, "BEFORE", event, suffix: "_queue", when: queueCondition(), captureQueue()) }
            }
            add("ntp_podcasts", "BEFORE", "INSERT", when: "NEW.pinned_removal = 1", captureHide("NEW.feed_id"))
            add("ntp_podcasts", "BEFORE", "INSERT", suffix: "_queue", when: queueCondition("NEW.pinned_removal = 1"), captureQueue())
            add("ntp_podcasts", "BEFORE", "DELETE", when: "OLD.pinned_removal = 1", captureHide("OLD.feed_id"))
            add("ntp_podcasts", "BEFORE", "DELETE", suffix: "_queue", when: queueCondition("OLD.pinned_removal = 1"), captureQueue())
            // Changed values, not the columns an upsert names: an unchanged mapping captures nothing.
            if faults.contains(.gateByColumns) {
                add("ntp_podcasts", "BEFORE", "UPDATE OF pinned_removal, feed_id", captureHide("OLD.feed_id") + captureHide("NEW.feed_id"))
                add("ntp_podcasts", "BEFORE", "UPDATE OF pinned_removal, feed_id", suffix: "_queue", when: queueCondition(), captureQueue())
            } else {
                let changed = "(OLD.pinned_removal IS NOT NEW.pinned_removal OR OLD.feed_id IS NOT NEW.feed_id) AND (OLD.pinned_removal = 1 OR NEW.pinned_removal = 1)"
                add("ntp_podcasts", "BEFORE", "UPDATE", when: changed, captureHide("OLD.feed_id") + captureHide("NEW.feed_id"))
                add("ntp_podcasts", "BEFORE", "UPDATE", suffix: "_queue", when: queueCondition(changed), captureQueue())
            }
            add("ntp_hidden_episodes", "BEFORE", "INSERT", captureMark("NEW.episode_id"))
            add("ntp_hidden_episodes", "BEFORE", "UPDATE", captureMark("OLD.episode_id") + captureMark("NEW.episode_id"))
            add("ntp_hidden_episodes", "BEFORE", "DELETE", captureMark("OLD.episode_id"))
            add("ntp_hidden_episodes", "BEFORE", "INSERT", suffix: "_queue", when: queueCondition(queuedCondition("NEW.episode_id")), captureQueue())
            add("ntp_hidden_episodes", "BEFORE", "UPDATE", suffix: "_queue",
                when: queueCondition(queuedCondition("OLD.episode_id") + " OR " + queuedCondition("NEW.episode_id")), captureQueue())
            add("ntp_hidden_episodes", "BEFORE", "DELETE", suffix: "_queue", when: queueCondition(queuedCondition("OLD.episode_id")), captureQueue())
            // Position knowledge: what can change an adoption decision.
            let groups = "IN ('position', 'play_state', 'last_played')"
            add("ntp_records", "AFTER", "INSERT", when: "NEW.entity = 'episode' AND NEW.field_group \(groups)", knowledge("wire", "NEW.id"))
            add("ntp_records", "AFTER", "UPDATE", when: "NEW.entity = 'episode' AND NEW.field_group \(groups)", knowledge("wire", "NEW.id"))
            add("ntp_records", "AFTER", "DELETE", when: "OLD.entity = 'episode' AND OLD.field_group \(groups)", knowledge("wire", "OLD.id"))
            add("ntp_overlays", "AFTER", "INSERT", when: "NEW.entity = 'episode' AND NEW.property = 'position'", knowledge("wire", "NEW.id"))
            add("ntp_overlays", "AFTER", "UPDATE", when: "NEW.entity = 'episode' AND NEW.property = 'position'", knowledge("wire", "NEW.id"))
            add("ntp_overlays", "AFTER", "DELETE", when: "OLD.entity = 'episode' AND OLD.property = 'position'", knowledge("wire", "OLD.id"))
            add("ntp_sessions", "AFTER", "INSERT", knowledge("local", "NEW.episode_id"))
            add("ntp_sessions", "AFTER", "UPDATE", knowledge("local", "OLD.episode_id") + knowledge("local", "NEW.episode_id"))
            add("ntp_sessions", "AFTER", "DELETE", knowledge("local", "OLD.episode_id"))
            add("ntp_episodes", "AFTER", "INSERT", when: "NEW.local_id IS NOT NULL", knowledge("local", "NEW.local_id"))
            add("ntp_episodes", "AFTER", "UPDATE", when: "OLD.local_id IS NOT NEW.local_id", knowledge("local", "OLD.local_id") + knowledge("local", "NEW.local_id"))
            add("ntp_episodes", "AFTER", "DELETE", when: "OLD.local_id IS NOT NULL", knowledge("local", "OLD.local_id"))
            add("ntp_deferred_pins", "AFTER", "INSERT", knowledge("wire", "NEW.episode_id"))
            add("ntp_deferred_pins", "AFTER", "UPDATE", knowledge("wire", "OLD.episode_id") + knowledge("wire", "NEW.episode_id"))
            add("ntp_deferred_pins", "AFTER", "DELETE", knowledge("wire", "OLD.episode_id"))
            add("ntp_recovery_holds", "AFTER", "INSERT", when: "NEW.entity = 'episode' AND NEW.field_group = 'position'", knowledge("wire", "NEW.id"))
            add("ntp_recovery_holds", "AFTER", "DELETE", when: "OLD.entity = 'episode' AND OLD.field_group = 'position'", knowledge("wire", "OLD.id"))
            add("ntp_library", "AFTER", "UPDATE", when: "OLD.recovery IS NOT NEW.recovery OR OLD.log_id IS NOT NEW.log_id OR OLD.epoch IS NOT NEW.epoch",
                knowledge("all", "0"))
            add("ntp_podcasts", "AFTER", "UPDATE", suffix: "_generation", when: "OLD.live_generation IS NOT NEW.live_generation", knowledge("all", "0"))
            return list
        }

        struct Drain {
            var changed: [Relation: String] = [:]
            var raw: [Relation: String] = [:]
            var queueAfter = ""
            var unitsChanged = ""
            var unitEpisode = ""
        }

        func drainStatements() -> Drain {
            var drain = Drain()
            for relation in Relation.allCases {
                let images = "WITH b AS MATERIALIZED (SELECT v.key AS key, v.present AS bp, v.parent AS bpar, v.digest AS bd, "
                    + "\(present(relation, "v.key", start: false)) AS ap, \(parent(relation, "v.key")) AS apar "
                    + "FROM temp.ntp_vis_before AS v WHERE v.rel = '\(relation.rawValue)') "
                drain.changed[relation] = images + "SELECT b.key, b.bp, b.bpar, b.ap, b.apar FROM b WHERE b.bp IS NOT b.ap OR "
                    + "(b.bp AND (b.bpar IS NOT b.apar OR b.bd IS NOT \(digest(relation, "b.key"))))"
                drain.raw[relation] = images + "SELECT b.key, b.bp, b.bpar, b.ap, b.apar FROM b"
            }
            let unit = "FROM main.statistics_units AS a WHERE a.episode_id = u.episode_id AND a.unit_id = u.unit_id"
            drain.unitsChanged = has("statistics_units")
                ? "SELECT u.episode_id FROM temp.ntp_vis_units AS u WHERE u.present IS NOT EXISTS (SELECT 1 \(unit)) "
                    + "OR (u.present AND u.digest IS NOT (SELECT ntp_digest(a.played_ms, a.last_played, a.history, a.duration_ms, a.played, a.position) \(unit))) "
                    + "GROUP BY u.episode_id"
                : "SELECT NULL WHERE 0"
            drain.unitEpisode = "SELECT \(present(.statistics, "?1", start: true)), \(present(.statistics, "?1", start: false)), \(parent(.statistics, "?1"))"
            drain.queueAfter = has("queue")
                ? "SELECT q.episode_id FROM main.queue AS q JOIN main.episodes AS qv ON qv.id = q.episode_id WHERE NOT \(feedHiddenNow("qv.feed_id")) AND NOT \(episodeMarkedNow("qv.id")) ORDER BY q.position"
                : "SELECT NULL WHERE 0"
            return drain
        }
    }
}

// MARK: - Digest functions (C callbacks)

/// The 128-bit digest of the arguments: SHA-256 over each value's type, length and bytes, truncated.
private func libraryDigestUpdate(_ context: UnsafeMutablePointer<CC_SHA256_CTX>, _ count: Int32,
                                 _ values: UnsafeMutablePointer<OpaquePointer?>?) {
    guard let values else { return }
    for index in 0..<Int(count) {
        let value = values[index]
        let type = sqlite3_value_type(value)
        var tag = UInt8(truncatingIfNeeded: type)
        CC_SHA256_Update(context, &tag, 1)
        switch type {
        case SQLITE_INTEGER:
            var number = sqlite3_value_int64(value).littleEndian
            CC_SHA256_Update(context, &number, 8)
        case SQLITE_FLOAT:
            var number = sqlite3_value_double(value).bitPattern.littleEndian
            CC_SHA256_Update(context, &number, 8)
        case SQLITE_TEXT:
            let bytes = sqlite3_value_text(value)
            var length = UInt64(sqlite3_value_bytes(value)).littleEndian
            CC_SHA256_Update(context, &length, 8)
            if let bytes, length > 0 { CC_SHA256_Update(context, bytes, CC_LONG(UInt64(littleEndian: length))) }
        case SQLITE_BLOB:
            let bytes = sqlite3_value_blob(value)
            var length = UInt64(sqlite3_value_bytes(value)).littleEndian
            CC_SHA256_Update(context, &length, 8)
            if let bytes, length > 0 { CC_SHA256_Update(context, bytes, CC_LONG(UInt64(littleEndian: length))) }
        default:
            break
        }
    }
}

private func libraryDigestResult(_ context: OpaquePointer?, _ sha: UnsafeMutablePointer<CC_SHA256_CTX>) {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    CC_SHA256_Final(&digest, sha)
    sqlite3_result_blob(context, digest, 16, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
}

private func libraryDigestCount(_ context: OpaquePointer?) {
    guard let data = sqlite3_user_data(context) else { return }
    Unmanaged<LibraryDigestCounter>.fromOpaque(data).takeUnretainedValue().inputs += 1
}

private let libraryDigestScalar: @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void = { context, count, values in
    libraryDigestCount(context)
    var sha = CC_SHA256_CTX()
    CC_SHA256_Init(&sha)
    libraryDigestUpdate(&sha, count, values)
    libraryDigestResult(context, &sha)
}

private struct LibraryDigestAggregate {
    var started: Int32
    var sha: CC_SHA256_CTX
}

private let libraryDigestStep: @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void = { context, count, values in
    libraryDigestCount(context)
    guard let raw = sqlite3_aggregate_context(context, Int32(MemoryLayout<LibraryDigestAggregate>.stride)) else {
        sqlite3_result_error_nomem(context)
        return
    }
    let state = raw.assumingMemoryBound(to: LibraryDigestAggregate.self)
    if state.pointee.started == 0 {
        CC_SHA256_Init(&state.pointee.sha)
        state.pointee.started = 1
    }
    libraryDigestUpdate(&state.pointee.sha, count, values)
}

private let libraryDigestFinal: @convention(c) (OpaquePointer?) -> Void = { context in
    guard let raw = sqlite3_aggregate_context(context, 0) else { sqlite3_result_null(context); return }
    let state = raw.assumingMemoryBound(to: LibraryDigestAggregate.self)
    guard state.pointee.started == 1 else { sqlite3_result_null(context); return }
    libraryDigestResult(context, &state.pointee.sha)
}

/// The persisted order of visible changes is damaged: its table exists without its row.
public enum LibraryChangeSequenceError: Error, Equatable, Sendable {
    case missingRow
}
