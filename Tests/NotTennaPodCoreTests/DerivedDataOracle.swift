import CryptoKit
import Foundation
import SQLite3
@testable import NotTennaPodCore

/// The whole-table oracle of the derived list keys and counts (schema 21): every episode record decoded in Swift and
/// mapped by the reference (`EpisodeListKeys.init(episode:…)`, `FeedListCounts.init(feedID:episodes:)`), with
/// visibility from the decoded headers and the visibility tables, compared with what SQLite stored. Read through its
/// own read-only connection, so it sees only committed data.
enum DerivedDataOracle {
    struct Expected {
        var keys: [Int64: EpisodeListKeys] = [:]
        var counts: [Int64: FeedListCounts] = [:]
    }

    static func connection(_ url: URL) throws -> LibrarySQLite { try LibrarySQLite(readingOnly: url) }

    static func ids(_ database: LibrarySQLite, _ sql: String) throws -> Set<Int64> {
        Set(try database.rows(sql).compactMap { $0[0].integer })
    }

    /// The reference keys of every episode, from the records, and the visible counts of those in `keyed` (every episode
    /// when nil): the counts always cover exactly the key rows that exist.
    static func expected(_ url: URL, keyed: Set<Int64>? = nil) throws -> Expected {
        let database = try connection(url)
        defer { try? database.close() }
        return try database.transaction(write: false) {
            let hiddenEpisodes = try ids(database, "SELECT episode_id FROM ntp_hidden_episodes")
            // Eligibility: subscribed and not a pinned removal (a hidden podcast is left out when read, not here).
            let hiddenFeeds = try ids(database, "SELECT feed_id FROM pinned_feed_removals UNION SELECT feed_id FROM ntp_podcasts WHERE pinned_removal = 1 AND feed_id IS NOT NULL")
            var subscribed: Set<Int64> = []
            for row in try database.rows("SELECT id, record FROM feeds") {
                guard let id = row[0].integer, let data = row[1].data else { continue }
                if let feed = try? JSONDecoder().decode(LibraryFeed.self, from: data), feed.subscriptionState == .subscribed { subscribed.insert(id) }
            }
            var expected = Expected()
            var visible: [Int64: [LibraryEpisode]] = [:]
            for row in try database.rows("SELECT id, feed_id, record FROM episodes ORDER BY id") {
                guard let id = row[0].integer, let feed = row[1].integer, let data = row[2].data else { continue }
                let hidden = hiddenEpisodes.contains(id), eligible = subscribed.contains(feed) && !hiddenFeeds.contains(feed)
                let counted = keyed.map { $0.contains(id) } ?? true
                if let episode = try? JSONDecoder().decode(LibraryEpisode.self, from: data) {
                    expected.keys[id] = EpisodeListKeys(episode: episode, feedID: feed, hidden: hidden, feedEligible: eligible)
                    if !hidden && counted { visible[feed, default: []].append(episode) }
                    if counted { visible[feed, default: []] += [] }
                } else {
                    // Only a record that is not valid JSON is keyed with defaults; anything else here is a test error.
                    precondition((try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) == nil, "an undecodable JSON record in the oracle")
                    var keys = EpisodeListKeys.malformed(id: id, feedID: feed, hidden: hidden, feedEligible: eligible)
                    keys.id = id
                    expected.keys[id] = keys
                    if !hidden && counted { visible[feed, default: []].append(LibraryEpisode(id: id, details: ParsedEpisode())) }
                }
            }
            for (feed, episodes) in visible { expected.counts[feed] = FeedListCounts(feedID: feed, episodes: episodes) }
            return expected
        }
    }

    static func storedKeys(_ url: URL) throws -> [Int64: EpisodeListKeys] {
        let database = try connection(url)
        defer { try? database.close() }
        var keys: [Int64: EpisodeListKeys] = [:]
        for row in try database.rows("SELECT \(LibrarySchema21.keyColumns.joined(separator: ", ")) FROM episode_list_keys") {
            let value = try EpisodeListKeys(row: row)
            keys[value.id] = value
        }
        return keys
    }

    static func storedCounts(_ url: URL) throws -> [Int64: FeedListCounts] {
        let database = try connection(url)
        defer { try? database.close() }
        var counts: [Int64: FeedListCounts] = [:]
        for row in try database.rows("SELECT feed_id, \(LibrarySchema21.countColumns.joined(separator: ", ")) FROM feed_list_counts") {
            let value = try FeedListCounts(row: row)
            counts[value.feedID] = value
        }
        return counts
    }

    static func isComplete(_ url: URL) throws -> Bool {
        let database = try connection(url)
        defer { try? database.close() }
        return try LibrarySchema21.isComplete(database)
    }

    /// Every difference between the stored derived data and the reference (empty when exact). Before the fill is
    /// complete, only the key rows that exist are compared, and the counts against those rows.
    static func mismatches(_ url: URL, limit: Int = 8) throws -> [String] {
        let stored = try storedKeys(url), complete = try isComplete(url)
        let expected = try expected(url, keyed: complete ? nil : Set(stored.keys))
        var found: [String] = []
        for (id, keys) in stored.sorted(by: { $0.key < $1.key }) {
            guard let reference = expected.keys[id] else { found.append("orphan key row \(id)"); continue }
            if reference != keys { found.append("episode \(id): stored \(keys) reference \(reference)") }
        }
        if complete {
            for id in Set(expected.keys.keys).subtracting(stored.keys).sorted() { found.append("missing key row \(id)") }
        }
        do {
            let counts = try storedCounts(url)
            for feed in Set(counts.keys).union(expected.counts.keys).sorted() {
                let have = counts[feed] ?? FeedListCounts(feedID: feed), want = expected.counts[feed] ?? FeedListCounts(feedID: feed)
                if have != want { found.append("feed \(feed): counts \(have) reference \(want)") }
            }
        }
        return Array(found.prefix(limit))
    }

    // MARK: - Byte preservation

    /// Tables the oracle leaves out: derived ones (recomputed, not preserved).
    static let derivedTables: Set<String> = ["episode_list_keys", "feed_list_counts", "library_change_sequence", "feed_refresh_memo", "derived_fill"]
    /// Derived columns of canonical tables, left out of their rows.
    static let derivedColumns: [String: Set<String>] = ["feed_changes": ["details_generation"]]

    /// The tables `canonicalHashes` covers: every table but SQLite's statistics and the derived ones (`sqlite_sequence`,
    /// the AUTOINCREMENT high-water marks, included).
    static func canonicalTables(_ database: LibrarySQLite) throws -> [(name: String, rowid: Bool)] {
        try database.rows("SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_stat%' ORDER BY name").compactMap { row in
            guard let name = row[0].text, !derivedTables.contains(name) else { return nil }
            return (name, !(row[1].text ?? "").uppercased().contains("WITHOUT ROWID"))
        }
    }

    /// A SHA-256 of every row of every canonical table (`canonicalTables`), kept outside the database under test: each
    /// row's rowid (its identity, and the order readers such as the release ledger rely on) and typed values, in rowid
    /// order; a table without rowids by its key.
    static func canonicalHashes(_ url: URL) throws -> [String: String] {
        let database = try connection(url)
        defer { try? database.close() }
        return try database.transaction(write: false) {
            var result: [String: String] = [:]
            for (table, hasRowid) in try canonicalTables(database) {
                var columns = try database.rows("PRAGMA table_info(\"\(table)\")").compactMap { $0[1].text }
                    .filter { !(derivedColumns[table]?.contains($0) ?? false) }.map { "\"\($0)\"" }
                let order = hasRowid ? "rowid" : columns.joined(separator: ", ")
                if hasRowid { columns.insert("rowid", at: 0) }
                var hasher = SHA256()
                var count = 0
                for row in try database.rows("SELECT " + columns.joined(separator: ", ") + " FROM \"\(table)\" ORDER BY \(order)") {
                    count += 1
                    for value in row {
                        switch value {
                        case .integer(let number): hasher.update(data: Data("i\(number);".utf8))
                        case .real(let number): hasher.update(data: Data("r\(number.bitPattern);".utf8))
                        case .text(let text): hasher.update(data: Data("t\(text.utf8.count):".utf8)); hasher.update(data: Data(text.utf8))
                        case .blob(let data): hasher.update(data: Data("b\(data.count):".utf8)); hasher.update(data: data)
                        case .null: hasher.update(data: Data("n;".utf8))
                        }
                    }
                    hasher.update(data: Data("|".utf8))
                }
                result[table] = "\(count):" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
            }
            return result
        }
    }

    /// The differences between two canonical hashings: a table present before must keep exactly its rows; a table
    /// present only after must be empty (made by the migration, like the hidden-row tables).
    static func byteChanges(before: [String: String], after: [String: String]) -> [String] {
        var changes: [String] = []
        for (table, hash) in before.sorted(by: { $0.key < $1.key }) where after[table] != hash {
            changes.append("\(table) changed")
        }
        for (table, hash) in after.sorted(by: { $0.key < $1.key }) where before[table] == nil && !hash.hasPrefix("0:") {
            changes.append("\(table) appeared with rows")
        }
        return changes
    }

    // MARK: - Schema 20

    /// Takes a schema-21 library back to schema 20, as the previous build left it: the schema-21 objects go, and in a
    /// standalone library the hidden-row tables too (a server library had them since its first exchange).
    static func downgradeTo20(_ url: URL, server: Bool = false) throws {
        var statements = (LibrarySchema21.keyTriggers + LibrarySchema21.visibilityTriggers + LibrarySchema21.countTriggers).map { "DROP TRIGGER IF EXISTS \($0.name);" }
        statements += LibrarySchema21.ledgerIndexes.map { "DROP INDEX IF EXISTS \($0.name);" }
        statements += LibrarySchema21.createdTables.map { "DROP TABLE IF EXISTS \($0);" }
        statements.append("ALTER TABLE feed_changes DROP COLUMN details_generation;")
        if !server { statements += ["DROP TABLE IF EXISTS ntp_hidden_feeds;", "DROP TABLE IF EXISTS ntp_hidden_episodes;"] }
        statements.append("PRAGMA user_version = 20;")
        try RawLibrary.execute(url, statements.joined(separator: " "))
    }

    // MARK: - Raw writes

    /// Runs `statements` in order on a connection of its own (foreign keys on, as the store's), as another writer would.
    static func write(_ url: URL, _ statements: [(String, [LibrarySQLValue])]) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { throw FeedLibraryError.invalidLocation }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 5_000)
        sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)
        for (sql, values) in statements {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw FeedLibraryError.sqlite(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                switch value {
                case .integer(let number): sqlite3_bind_int64(statement, index, number)
                case .real(let number): sqlite3_bind_double(statement, index, number)
                case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
                case .blob(let data): _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
                case .null: sqlite3_bind_null(statement, index)
                }
            }
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW { status = sqlite3_step(statement) }
            guard status == SQLITE_DONE else {
                throw FeedLibraryError.sqlite(code: status, message: String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    static func write(_ url: URL, _ sql: String, _ values: [LibrarySQLValue] = []) throws { try write(url, [(sql, values)]) }

    static func record(_ episode: LibraryEpisode) throws -> Data { try FeedLibraryStore.newEpisodeRecord(episode) }
}
