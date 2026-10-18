import Foundation
import SQLite3
import Testing
@testable import NotTennaPodCore

/// Canonical preservation with independent expected deltas: before each action every canonical table is read out of the
/// database (kept in memory, outside it); the action's intended change (`Intent`) is applied to that copy using only the
/// pre-action rows and the action's own input (episode and feed records edited with a frozen encoder, rows added or
/// removed with what the schema's foreign keys cascade to, other tables' rows computed); afterwards every column of every
/// row of every table must equal it. Nothing expected is ever read from the resulting database. A rollback must leave
/// every canonical byte as it was. Complements the derived-data oracle, which compares keys with the records after the fact.
@Suite(.serialized) struct CanonicalPreservationTests {
    /// Every canonical table's rows by rowid (derived tables and columns left out, `sqlite_sequence` kept), each table's
    /// columns, and what deleting a row of a table cascades to (the schema's foreign keys).
    struct Snapshot: Equatable {
        var tables: [String: [Int64: [Value]]] = [:]
        var columns: [String: [String]] = [:]
        /// By parent table: the child columns its deletion deletes (`ON DELETE CASCADE`) or clears (`SET NULL`).
        var cascades: [String: [Cascade]] = [:]

        struct Cascade: Equatable { var table: String; var column: String; var setNull: Bool }

        enum Value: Hashable, CustomStringConvertible {
            case integer(Int64), real(UInt64), text([UInt8]), blob(Data), null
            static func string(_ text: String) -> Value { .text(Array(text.utf8)) }
            var description: String {
                switch self {
                case .integer(let value): "\(value)"
                case .real(let bits): "\(Double(bitPattern: bits))"
                case .text(let bytes): "'\(String(decoding: bytes, as: UTF8.self))'"
                case .blob(let data): "x(\(data.count) bytes)"
                case .null: "NULL"
                }
            }
            var data: Data? {
                switch self { case .blob(let data): data; case .text(let bytes): Data(bytes); default: nil }
            }
            var integer: Int64? { if case .integer(let value) = self { value } else { nil } }
            var stringValue: String? { if case .text(let bytes) = self { String(decoding: bytes, as: UTF8.self) } else { nil } }
        }

        static func take(_ url: URL) throws -> Snapshot {
            let database = try LibrarySQLite(readingOnly: url)
            defer { try? database.close() }
            return try database.transaction(write: false) {
                var snapshot = Snapshot()
                let tables = try database.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_stat%' ORDER BY name")
                    .compactMap { $0[0].text }.filter { !DerivedDataOracle.derivedTables.contains($0) }
                for table in tables {
                    let columns = try database.rows("PRAGMA table_info(\"\(table)\")").compactMap { $0[1].text }
                        .filter { !(DerivedDataOracle.derivedColumns[table]?.contains($0) ?? false) }
                    snapshot.columns[table] = columns
                    var rows: [Int64: [Value]] = [:]
                    for row in try database.rows("SELECT rowid, " + columns.map { "\"\($0)\"" }.joined(separator: ", ") + " FROM \"\(table)\"") {
                        guard let rowid = row[0].integer else { continue }
                        rows[rowid] = row.dropFirst().map { value in
                            switch value {
                            case .integer(let number): .integer(number)
                            case .real(let number): .real(number.bitPattern)
                            case .text(let text): .string(text)
                            case .blob(let data): .blob(data)
                            case .null: .null
                            }
                        }
                    }
                    snapshot.tables[table] = rows
                    // id, seq, table, from, to, on_update, on_delete, match
                    for key in try database.rows("PRAGMA foreign_key_list(\"\(table)\")") {
                        guard let parent = key[2].text, let column = key[3].text, let action = key[6].text,
                              action == "CASCADE" || action == "SET NULL" else { continue }
                        snapshot.cascades[parent, default: []].append(Cascade(table: table, column: column, setNull: action == "SET NULL"))
                    }
                }
                return snapshot
            }
        }

        func rows(_ table: String) -> Rows { Rows(columns: columns[table] ?? [], rows: tables[table] ?? [:]) }

        // episodes: id, feed_id, pubdate, record; feeds: id, title, record
        func episode(_ id: Int64) throws -> LibraryEpisode? {
            try tables["episodes"]?[id]?[3].data.map { try JSONDecoder().decode(LibraryEpisode.self, from: $0) }
        }
        func feed(_ id: Int64) throws -> LibraryFeed? {
            try tables["feeds"]?[id]?[2].data.map { try JSONDecoder().decode(LibraryFeed.self, from: $0) }
        }
        func episodeIDs(feed: Int64) -> [Int64] {
            (tables["episodes"] ?? [:]).filter { $0.value[1] == .integer(feed) }.keys.sorted()
        }
        /// The last ID `library_ids` allocated of a kind (`feed`, `episode`).
        func allocated(_ kind: String) -> Int64 { rows("library_ids").first(where: "kind", is: .string(kind))?["value"]?.integer ?? 0 }
    }

    /// One table's rows by rowid, with its column names: what an intent edits.
    struct Rows {
        var columns: [String]
        var rows: [Int64: [Snapshot.Value]]

        func index(_ column: String) -> Int {
            guard let index = columns.firstIndex(of: column) else { preconditionFailure("no column \(column) in \(columns)") }
            return index
        }
        func first(where column: String, is value: Snapshot.Value) -> [String: Snapshot.Value]? {
            let index = index(column)
            return rows.sorted { $0.key < $1.key }.first { $0.value[index] == value }.map { Dictionary(uniqueKeysWithValues: zip(columns, $0.value)) }
        }
        /// The column's values (none for a table the library does not have).
        func values(_ column: String) -> [Snapshot.Value] {
            if columns.isEmpty { return [] }
            let index = index(column)
            return rows.keys.sorted().map { rows[$0]![index] }
        }
        /// A new row (a column not given is NULL).
        mutating func insert(_ values: [String: Snapshot.Value]) {
            precondition(Set(values.keys).isSubset(of: columns), "unknown columns \(values.keys) of \(columns)")
            rows[(rows.keys.max() ?? 0) + 1] = columns.map { values[$0] ?? .null }
        }
        mutating func remove(where column: String, in keys: Set<Snapshot.Value>) {
            let index = index(column)
            rows = rows.filter { !keys.contains($0.value[index]) }
        }
        mutating func update(where column: String, is key: Snapshot.Value, _ change: (inout [String: Snapshot.Value]) -> Void) {
            let index = index(column)
            for (rowid, row) in rows where row[index] == key {
                var values = Dictionary(uniqueKeysWithValues: zip(columns, row))
                change(&values)
                rows[rowid] = columns.map { values[$0] ?? .null }
            }
        }
        /// Sets `column` of the row whose `key` column is `value`, adding that row if there is none.
        mutating func upsert(where key: String, is value: Snapshot.Value, set column: String, to new: Snapshot.Value) {
            if first(where: key, is: value) == nil { insert([key: value, column: new]) } else { update(where: key, is: value) { $0[column] = new } }
        }
        var multiset: [[Snapshot.Value]: Int] {
            var counts: [[Snapshot.Value]: Int] = [:]
            for row in rows.values { counts[row, default: 0] += 1 }
            return counts
        }
    }

    /// What an action intends to change, from the pre-action rows and its own input only.
    struct Intent {
        /// Episode records edited (decoded from the pre-action bytes, changed, encoded again; their `pubdate` follows a
        /// changed publication date and is otherwise unchanged), added with their feed, removed, moved to another feed.
        var edits: [Int64: (inout LibraryEpisode) -> Void] = [:]
        var added: [Int64: (feed: Int64, episode: LibraryEpisode)] = [:]
        var removed: Set<Int64> = []
        var moved: [Int64: Int64] = [:]
        /// Feed headers edited, added, removed (with their episodes); edited `formatKnown` feeds record their format as
        /// known (a refresh: the private `sourceTypeAbsent` becomes false).
        var feedEdits: [Int64: (inout LibraryFeed) -> Void] = [:]
        var feedsAdded: [Int64: LibraryFeed] = [:]
        var feedsRemoved: Set<Int64> = []
        var formatKnown: Set<Int64> = []
        /// Other tables' intended rows, computed from the pre-action rows.
        var tables: [String: (inout Rows, Context) throws -> Void] = [:]
        /// Logs and work for later (effects, the synchronization outbox, the refresh log): every existing row stays as it
        /// was, rows may be added.
        var appended: Set<String> = []
        /// Change counters (`feed_changes`) and state another oracle checks; not compared.
        var free: Set<String> = ["feed_changes"]
        /// A server step's own tables (`ntp_*`): those it writes, and the identities its rows there carry. Every other
        /// server table stays exactly as it was; in a written table, every row carrying none of the identities stays
        /// exactly as it was, and every new row carries one (except the step's bookkeeping tables).
        var server: ServerScope?
        /// Episodes a server's records add, each constructed from its records with the protocol's defaults (its ID 0 until
        /// resolved), by GUID, with its feed (nil: the arriving podcast); and the podcast the records add (its ID 0).
        var arrivals: [String: (wire: String?, feed: Int64?, episode: LibraryEpisode)] = [:]
        var arrivingFeed: LibraryFeed?
        /// The step reserves local IDs ahead (a server's unit or shadow): each `library_ids` counter may grow past its
        /// intended value, never lower and never behind an ID in use.
        var reservesIDs = false

        /// Values the store generates (a new fact's random op ID, an episode's wire ID, the action's time), each resolved
        /// from the result by a resolver that checks its relationships (its findings), for the table changes to use.
        var resolvers: [(Snapshot, Snapshot) throws -> (values: [String: Snapshot.Value], found: [String])] = []

        struct Context {
            var before: Snapshot
            /// The arrivals' episode IDs by GUID, as the store allocated them.
            var arrived: [String: Int64]
            var resolved: [String: Snapshot.Value] = [:]
        }

        /// A server step's own tables: those it writes, each with its rule, and the step's identities by domain (wire IDs
        /// of episodes, podcasts and generations; local episode IDs; local feed IDs). A row is the step's only through a
        /// table's identity columns, compared exactly in their domain: counters, sequence numbers, timestamps and text
        /// that merely contains an identity never are.
        struct ServerScope {
            /// `wireIn`: a JSON value holding one of the wire IDs as one of its strings.
            enum Domain { case wire, episode, feed, wireIn }
            enum Rule {
                /// Rows the step's identities name may change, appear or go; every other row stays exactly as it was.
                case identified([String: Domain])
            }
            var tables: [String: Rule] = [:]
            var wires: Set<String> = []
            var episodes: Set<Int64> = []
            var feeds: Set<Int64> = []

            func owns(_ row: [Snapshot.Value], columns: [String], _ identity: [String: Domain]) -> Bool {
                identity.contains { column, domain in
                    guard let index = columns.firstIndex(of: column), index < row.count else { return false }
                    let value = row[index]
                    switch domain {
                    case .wire: return value.stringValue.map(wires.contains) ?? false
                    case .episode: return value.integer.map(episodes.contains) ?? false
                    case .feed: return value.integer.map(feeds.contains) ?? false
                    case .wireIn:
                        guard let data = value.data, let object = try? JSONSerialization.jsonObject(with: data) else { return false }
                        return Self.strings(object).contains(where: wires.contains)
                    }
                }
            }

            static func strings(_ object: Any) -> [String] {
                if let text = object as? String { return [text] }
                if let array = object as? [Any] { return array.flatMap(strings) }
                if let dictionary = object as? [String: Any] { return dictionary.values.flatMap(strings) }
                return []
            }
        }

        static func editing(_ id: Int64, _ change: @escaping (inout LibraryEpisode) -> Void) -> Intent {
            var intent = Intent(); intent.edits[id] = change; return intent
        }
        /// Adds a change to the episode's edits.
        mutating func edit(_ id: Int64, _ change: @escaping (inout LibraryEpisode) -> Void) {
            let previous = edits[id]
            edits[id] = { previous?(&$0); change(&$0) }
        }
    }

    /// The frozen record encoding (sorted keys), independent of the store's.
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    /// The `pubdate` column of a publication date: whole milliseconds, truncated.
    static func milliseconds(_ date: Date?) -> Int64 { Int64((date ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970 * 1_000) }

    struct Missing: Error, CustomStringConvertible { var description: String }

    /// The feed with its format recorded as known, as a refresh records it: the type keeps that flag private, so it is set
    /// in the record's JSON and decoded.
    static func formatKnown(_ feed: LibraryFeed) throws -> LibraryFeed {
        guard var object = try JSONSerialization.jsonObject(with: encode(feed)) as? [String: Any] else { throw Missing(description: "feed \(feed.id) record") }
        object["sourceTypeAbsent"] = false
        return try JSONDecoder().decode(LibraryFeed.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// The intended canonical state: `before` with `intent` applied (arrivals as constructed, with the IDs the store
    /// allocated for them).
    static func expected(_ before: Snapshot, _ intent: Intent, arrivingFeedID: Int64? = nil, context: Intent.Context) throws -> Snapshot {
        var result = before
        var feeds = before.tables["feeds"] ?? [:]
        func feedRow(_ feed: LibraryFeed) throws -> [Snapshot.Value] {
            var header = feed; header.episodes = []
            return [.integer(feed.id), feed.metadata.title.map(Snapshot.Value.string) ?? .null, .blob(try encode(header))]
        }
        for (id, edit) in intent.feedEdits {
            guard var feed = try before.feed(id) else { throw Missing(description: "feed \(id) to edit") }
            edit(&feed)
            if intent.formatKnown.contains(id) { feed = try formatKnown(feed) }
            feeds[id] = try feedRow(feed)
        }
        for (id, feed) in intent.feedsAdded { feeds[id] = try feedRow(feed) }
        if var feed = intent.arrivingFeed, let id = arrivingFeedID { feed.id = id; feeds[id] = try feedRow(feed) }
        var episodes = before.tables["episodes"] ?? [:]
        var removed = intent.removed
        for (id, row) in episodes where intent.feedsRemoved.contains(row[1].integer ?? 0) { removed.insert(id) }
        for id in intent.feedsRemoved { feeds[id] = nil }
        for (id, edit) in intent.edits {
            guard let row = episodes[id], let data = row[3].data else { throw Missing(description: "episode \(id) to edit") }
            let was = try JSONDecoder().decode(LibraryEpisode.self, from: data)
            var episode = was
            edit(&episode)
            let pubdate = episode.details.publicationDate == was.details.publicationDate ? row[2] : .integer(milliseconds(episode.details.publicationDate))
            episodes[id] = [row[0], row[1], pubdate, .blob(try encode(episode))]
        }
        for (id, feed) in intent.moved {
            guard episodes[id] != nil else { throw Missing(description: "episode \(id) to move") }
            episodes[id]![1] = .integer(feed)
        }
        for (id, added) in intent.added {
            episodes[id] = [.integer(id), .integer(added.feed), .integer(milliseconds(added.episode.details.publicationDate)), .blob(try encode(added.episode))]
        }
        // Arrivals: as constructed, with the IDs the store allocated.
        for (guid, arrival) in intent.arrivals {
            guard let id = context.arrived[guid], let feed = arrival.feed ?? arrivingFeedID else { continue }
            var episode = arrival.episode
            episode.id = id
            episodes[id] = [.integer(id), .integer(feed), .integer(milliseconds(episode.details.publicationDate)), .blob(try encode(episode))]
        }
        for id in removed { episodes[id] = nil }
        result.tables["feeds"] = feeds
        result.tables["episodes"] = episodes
        // What the deletions cascade to.
        for (parent, keys) in [("feeds", intent.feedsRemoved), ("episodes", removed)] where !keys.isEmpty {
            let values = Set(keys.map(Snapshot.Value.integer))
            for cascade in before.cascades[parent] ?? [] where cascade.table != "episodes" {
                var rows = result.rows(cascade.table)
                if cascade.setNull {
                    let index = rows.index(cascade.column)
                    for (rowid, row) in rows.rows where values.contains(row[index]) { rows.rows[rowid]![index] = .null }
                } else {
                    rows.remove(where: cascade.column, in: values)
                }
                result.tables[cascade.table] = rows.rows
            }
        }
        for (table, change) in intent.tables {
            var rows = result.rows(table)
            try change(&rows, context)
            result.tables[table] = rows.rows
        }
        return result
    }

    /// Checks `actual` against `before` with `intent` applied. Returns the findings and the reference to carry on: the
    /// intended state (tables not compared, appended rows and the server tables the step writes as found).
    static func check(_ before: Snapshot, _ intent: Intent, _ actual: Snapshot) throws -> (reference: Snapshot, found: [String]) {
        var found: [String] = []
        // Arrivals: only the IDs the store allocated are taken from the result, through a one-to-one map. The podcast: the
        // one new feed of its source. Each episode: the one new row of its GUID (a second is a duplicate), which the
        // server's own mapping of its wire episode, when it has one, names too.
        var arrivingFeedID: Int64?, arrivedIDs: [String: Int64] = [:]
        if let feed = intent.arrivingFeed {
            let new = (actual.tables["feeds"] ?? [:]).filter { before.tables["feeds"]?[$0.key] == nil && intent.feedsAdded[$0.key] == nil }
                .filter { (try? JSONDecoder().decode(LibraryFeed.self, from: $0.value[2].data ?? Data()))?.source == feed.source }
            if new.count == 1 { arrivingFeedID = new.first?.key } else { found.append("\(new.count) podcasts of \(feed.source) arrived, expected 1") }
        }
        if !intent.arrivals.isEmpty {
            var candidates: [String: [Int64]] = [:]
            for (id, row) in actual.tables["episodes"] ?? [:] where before.tables["episodes"]?[id] == nil && intent.added[id] == nil {
                if let guid = (try? JSONDecoder().decode(LibraryEpisode.self, from: row[3].data ?? Data()))?.details.identifier { candidates[guid, default: []].append(id) }
            }
            let mappings = actual.rows("ntp_episodes")
            var mapped: [String: Int64] = [:]
            for row in mappings.rows.values { if let wire = row[mappings.index("episode_id")].stringValue, let id = row[mappings.index("local_id")].integer { mapped[wire] = id } }
            for (guid, arrival) in intent.arrivals.sorted(by: { $0.key < $1.key }) {
                let ids = candidates[guid] ?? []
                guard ids.count == 1, let id = ids.first else { found.append("arrival \(guid): \(ids.count) new rows, expected 1"); continue }
                if let wire = arrival.wire, let local = mapped[wire], local != id {
                    found.append("arrival \(guid): row \(id), the server maps it to \(local)")
                }
                arrivedIDs[guid] = id
            }
            if Set(arrivedIDs.values).count != arrivedIDs.count { found.append("arrivals share rows") }
        }
        var resolved: [String: Snapshot.Value] = [:]
        for resolver in intent.resolvers {
            let result = try resolver(before, actual)
            resolved.merge(result.values) { a, _ in a }
            found += result.found
        }
        var expected = try Self.expected(before, intent, arrivingFeedID: arrivingFeedID, context: .init(before: before, arrived: arrivedIDs, resolved: resolved))
        // The arrivals' rows are the step's own in the server tables too, and so are the wire episodes the server maps to
        // the step's local episodes (its own identity map: a local ID has one mapping at most).
        var intent = intent
        intent.server?.episodes.formUnion(arrivedIDs.values)
        if let arrivingFeedID { intent.server?.feeds.insert(arrivingFeedID) }
        if let local = intent.server?.episodes {
            let mappings = actual.rows("ntp_episodes")
            for row in mappings.rows.values {
                if let id = row[mappings.index("local_id")].integer, local.contains(id), let wire = row[mappings.index("episode_id")].stringValue { intent.server?.wires.insert(wire) }
            }
        }
        // The AUTOINCREMENT counter of a table that may gain rows (appended, not compared, a server table) goes with it:
        // it may grow, never go back or vanish.
        let grows = { (name: String) in intent.free.contains(name) || intent.appended.contains(name) || intent.server?.tables[name] != nil }
        var sequence = expected.tables["sqlite_sequence"] ?? [:]
        var intended: [String: Int64] = [:]
        for row in sequence.values { if let name = row[0].stringValue, grows(name) { intended[name] = row[1].integer ?? 0 } }
        for (rowid, row) in actual.tables["sqlite_sequence"] ?? [:] {
            guard let name = row[0].stringValue, grows(name), (row[1].integer ?? 0) >= (intended[name] ?? 0) else { continue }
            sequence = sequence.filter { $0.value[0] != row[0] }
            sequence[-rowid - 1] = row
        }
        expected.tables["sqlite_sequence"] = sequence
        found += differences(expected, actual, intent)
        for table in actual.tables.keys where intent.free.contains(table) || intent.appended.contains(table) || intent.server?.tables[table] != nil
            || (intent.reservesIDs && table == "library_ids") {
            expected.tables[table] = actual.tables[table]
        }
        expected.columns = actual.columns
        expected.cascades = actual.cascades
        return (expected, Array(found.prefix(12)))
    }

    static let arrivingSource = "https://example.test/arriving.xml"

    static func differences(_ expected: Snapshot, _ actual: Snapshot, _ intent: Intent) -> [String] {
        var found: [String] = []
        for table in Set(expected.tables.keys).union(actual.tables.keys).sorted() where !intent.free.contains(table) {
            let want = expected.tables[table] ?? [:], have = actual.tables[table] ?? [:]
            if let scope = intent.server, let rule = scope.tables[table] {
                found += Self.serverDifferences(table, rule, scope, expected, actual)
                continue
            }
            if table == "library_ids" && intent.reservesIDs {
                for (kind, used) in [("feed", actual.tables["feeds"]?.keys.max() ?? 0), ("episode", actual.tables["episodes"]?.keys.max() ?? 0)] {
                    let intended = expected.allocated(kind), reserved = actual.allocated(kind)
                    if reserved < intended || reserved < used { found.append("library_ids \(kind): \(reserved), intended at least \(intended) and \(used)") }
                }
                if want.count != have.count { found.append("library_ids rows \(have.count), expected \(want.count)") }
                continue
            }
            if table == "episodes" || table == "feeds" {
                for id in Set(want.keys).union(have.keys).sorted() {
                    guard let wanted = want[id], let had = have[id] else {
                        found.append("\(table) row \(id) \(want[id] == nil ? "added" : "removed")"); continue
                    }
                    if wanted != had {
                        found.append("\(table) row \(id): \(Self.describe(wanted, had))")
                    }
                }
                continue
            }
            // Other tables' JSON records are written with unsorted encoders (dictionary order varies from one encoding to
            // the next): compared as JSON values. Episode and feed records above are compared byte for byte.
            let wanted = Rows(columns: expected.columns[table] ?? [], rows: want.mapValues { $0.map(Self.normalized) }).multiset
            let had = Rows(columns: actual.columns[table] ?? [], rows: have.mapValues { $0.map(Self.normalized) }).multiset
            let missing = wanted.filter { (had[$0.key] ?? 0) < $0.value }.keys
            let extra = had.filter { (wanted[$0.key] ?? 0) < $0.value }.keys
            if !missing.isEmpty || (!extra.isEmpty && !intent.appended.contains(table)) {
                let show = { (rows: Dictionary<[Snapshot.Value], Int>.Keys) in rows.prefix(3).map { $0.map(\.description).joined(separator: ",").prefix(160) } }
                found.append("\(table): expected rows missing \(show(missing)), rows not expected \(intent.appended.contains(table) ? [] : show(extra))")
            }
        }
        return found
    }

    /// A server table the step writes, against its rule.
    static func serverDifferences(_ table: String, _ rule: Intent.ServerScope.Rule, _ scope: Intent.ServerScope, _ expected: Snapshot, _ actual: Snapshot) -> [String] {
        let columns = actual.columns[table] ?? expected.columns[table] ?? []
        let wanted = Rows(columns: [], rows: (expected.tables[table] ?? [:]).mapValues { $0.map(Self.normalized) }).multiset
        let had = Rows(columns: [], rows: (actual.tables[table] ?? [:]).mapValues { $0.map(Self.normalized) }).multiset
        let lost = wanted.filter { (had[$0.key] ?? 0) < $0.value }, added = had.filter { (wanted[$0.key] ?? 0) < $0.value }
        let show = { (rows: [[Snapshot.Value]]) in rows.prefix(3).map { $0.map(\.description).joined(separator: ",").prefix(160) } }
        var found: [String] = []
        switch rule {
        case .identified(let identity):
            let unrelatedLost = lost.keys.filter { !scope.owns($0, columns: columns, identity) }
            let unrelatedAdded = added.keys.filter { !scope.owns($0, columns: columns, identity) }
            if !unrelatedLost.isEmpty || !unrelatedAdded.isEmpty {
                found.append("\(table): rows of others lost \(show(Array(unrelatedLost))), rows of others written \(show(Array(unrelatedAdded)))")
            }
        }
        return found
    }

    /// A JSON record in sorted-key form, the arrays of a set's members (a deletion's episode and job IDs) in order (other
    /// values unchanged): what an unsorted encoder writes in no fixed order.
    static func normalized(_ value: Snapshot.Value) -> Snapshot.Value {
        guard case .blob(let data) = value, let first = data.first, first == UInt8(ascii: "{") || first == UInt8(ascii: "["),
              let object = try? JSONSerialization.jsonObject(with: data),
              let sorted = try? JSONSerialization.data(withJSONObject: sortingSets(object), options: [.sortedKeys]) else { return value }
        return .blob(sorted)
    }

    static let setKeys: Set<String> = ["episodeIDs", "downloadJobIDs"]

    static func sortingSets(_ object: Any) -> Any {
        if let dictionary = object as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, value) in dictionary {
                if setKeys.contains(key), let numbers = value as? [NSNumber] { result[key] = numbers.sorted { $0.int64Value < $1.int64Value } }
                else { result[key] = sortingSets(value) }
            }
            return result
        }
        if let array = object as? [Any] { return array.map(sortingSets) }
        return object
    }

    /// Two rows' first difference: the column, and for records the bytes around the first differing one.
    static func describe(_ expected: [Snapshot.Value], _ found: [Snapshot.Value]) -> String {
        guard expected.count == found.count else { return "shape \(expected.count) → \(found.count) columns" }
        for (index, (want, had)) in zip(expected, found).enumerated() where want != had {
            if let a = want.data, let b = had.data, case .blob = want {
                let first = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(a.count, b.count)
                func around(_ data: Data) -> String { String(decoding: data.dropFirst(max(0, first - 60)).prefix(160), as: UTF8.self) }
                return "column \(index) differs at byte \(first): expected …\(around(a))… found …\(around(b))…"
            }
            return "column \(index): expected \(want) found \(had)"
        }
        return "equal"
    }

    // MARK: - Intents of the library's whole-library operations

    /// Keep's conversion of a server library (`LibraryKeep.convert`): statistics units projected once more from the base
    /// (every unit of a mapped episode that stays), a pinned or removing podcast kept as a pinned removal, a staging that
    /// never reached its unit taken out, secret-only credentials sent to cleanup, every server table emptied, every
    /// episode's device-local played-here time removed, the conversion recorded in the identity.
    static func keepIntent(_ before: Snapshot, operation: String) throws -> Intent {
        var intent = Intent()
        let feeds = Set((before.tables["feeds"] ?? [:]).keys), episodes = before.tables["episodes"] ?? [:]
        let hiddenFeeds = before.rows("ntp_hidden_feeds"), hiddenEpisodes = before.rows("ntp_hidden_episodes")
        let staging = Set(hiddenFeeds.rows.values.filter { $0[hiddenFeeds.index("state")] == .string("staging") }.compactMap { $0[hiddenFeeds.index("feed_id")].integer })
        intent.feedsRemoved = staging.intersection(feeds)
        intent.removed = Set(hiddenEpisodes.values("episode_id").compactMap(\.integer)).intersection(episodes.keys)
        let gone = intent.removed.union(episodes.filter { staging.contains($0.value[1].integer ?? 0) }.keys)
        for (id, row) in episodes where !gone.contains(id) && (row[3].data?.range(of: Data("\"playedHereMilliseconds\"".utf8)) != nil) {
            intent.edit(id) { $0.userState.playedHereMilliseconds = nil }
        }
        intent.tables["statistics_units"] = { rows, context in
            rows.rows = [:]
            let mappings = context.before.rows("ntp_episodes")
            var local: [String: Int64] = [:]
            for row in mappings.rows.values { if let wire = row[mappings.index("episode_id")].stringValue, let id = row[mappings.index("local_id")].integer { local[wire] = id } }
            let base = context.before.rows("ntp_statistics_units")
            for row in base.rows.values {
                guard let wire = row[base.index("episode_id")].stringValue, let id = local[wire], episodes[id] != nil, !gone.contains(id),
                      let data = row[base.index("record")].data, let unit = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let unitID = unit["id"] as? String else { continue }
                func number(_ key: String) -> Snapshot.Value { (unit[key] as? NSNumber).map { Snapshot.Value.integer($0.int64Value) } ?? .integer(0) }
                rows.insert(["episode_id": .integer(id), "unit_id": .string(unitID), "played_ms": number("played_ms"), "last_played": number("last_played"),
                             "history": (unit["history"] as? NSNumber).map { Snapshot.Value.integer($0.int64Value) } ?? .null, "duration_ms": number("duration_ms"),
                             "played": .integer((unit["played"] as? Bool) == true ? 1 : 0), "position": number("position")])
            }
        }
        let podcasts = before.rows("ntp_podcasts")
        var pinned = Set(podcasts.rows.values.filter { $0[podcasts.index("pinned_removal")] == .integer(1) }.compactMap { $0[podcasts.index("feed_id")].integer })
        pinned.formUnion(hiddenFeeds.rows.values.filter { $0[hiddenFeeds.index("state")] == .string("removing") }.compactMap { $0[hiddenFeeds.index("feed_id")].integer })
        intent.tables["pinned_feed_removals"] = { rows, _ in
            let present = Set(rows.values("feed_id"))
            for feed in pinned.intersection(feeds).subtracting(staging).sorted() where !present.contains(.integer(feed)) { rows.insert(["feed_id": .integer(feed)]) }
        }
        intent.tables["feed_credential_cleanup"] = { rows, context in
            let kept = Set(context.before.rows("feed_credentials").values("credential_id")), present = Set(rows.values("credential_id"))
            for credential in Set(context.before.rows("ntp_secrets").values("credential_id")).subtracting(kept).subtracting(present) {
                rows.insert(["credential_id": credential])
            }
        }
        for table in before.tables.keys where table.hasPrefix("ntp_") { intent.tables[table] = { rows, _ in rows.rows = [:] } }
        intent.tables["library_identity"] = { rows, _ in
            rows.update(where: "id", is: .integer(1)) { $0["keep_operation"] = .string(operation); $0["keep_role"] = .string("converted"); $0["archive_id"] = .null }
        }
        return intent
    }

    /// An Android backup installed in a new library: its feeds and episodes exactly, its queue in order, its download log,
    /// the ID counters after its IDs, and the state the replaced library keeps outside its database (`carried`: the
    /// synchronization account and outbox, the refresh schedule). The restore journal's dictionaries encode in no fixed
    /// order: the caller compares it decoded.
    static func restoreIntent(_ library: AndroidDatabaseRestore.Library, carried old: Snapshot) -> Intent {
        var intent = Intent()
        for feed in library.feeds {
            var header = feed; header.episodes = []
            intent.feedsAdded[feed.id] = header
            for episode in feed.episodes { intent.added[episode.id] = (feed.id, episode) }
        }
        let queue = library.queue, log = library.downloadLog
        intent.tables["queue"] = { rows, _ in
            for (position, id) in queue.enumerated() { rows.insert(["position": .integer(Int64(position)), "episode_id": .integer(id)]) }
        }
        intent.tables["imported_download_log"] = { rows, context in
            let start = context.before.rows("sqlite_sequence").first(where: "name", is: .string("imported_download_log"))?["seq"]?.integer ?? 0
            for (index, entry) in log.enumerated() {
                rows.insert(["id": .integer(start + Int64(index) + 1), "completed_at": .integer(entry.completion), "record": .blob(try JSONEncoder().encode(entry))])
            }
        }
        let maxFeed = library.feeds.map(\.id).max() ?? 0, maxEpisode = library.feeds.flatMap { $0.episodes.map(\.id) }.max() ?? 0
        intent.tables["library_ids"] = { rows, _ in
            rows.update(where: "kind", is: .string("feed")) { $0["value"] = .integer(max($0["value"]?.integer ?? 0, maxFeed)) }
            rows.update(where: "kind", is: .string("episode")) { $0["value"] = .integer(max($0["value"]?.integer ?? 0, maxEpisode)) }
        }
        for name in ["synchronization_state", "synchronization_outbox", "periodic_feed_schedule"] where !(old.tables[name] ?? [:]).isEmpty {
            let carried = old.tables[name] ?? [:]
            intent.tables[name] = { rows, _ in rows.rows = carried }
        }
        let outbox = (old.tables["synchronization_outbox"] ?? [:]).keys.max()
        intent.tables["sqlite_sequence"] = { rows, _ in
            if !log.isEmpty {
                let start = rows.first(where: "name", is: .string("imported_download_log"))?["seq"]?.integer ?? 0
                rows.upsert(where: "name", is: .string("imported_download_log"), set: "seq", to: .integer(start + Int64(log.count)))
            }
            if let outbox {
                let seq = rows.first(where: "name", is: .string("synchronization_outbox"))?["seq"]?.integer ?? 0
                rows.upsert(where: "name", is: .string("synchronization_outbox"), set: "seq", to: .integer(max(seq, outbox)))
            }
        }
        intent.free.insert("restore_journal")
        return intent
    }

    /// The restore journal a backup's per-feed playback preferences make, decoded from the library's row.
    static func restoreJournal(_ snapshot: Snapshot) throws -> FeedLibraryStore.RestoreJournal? {
        try snapshot.tables["restore_journal"]?.values.first.flatMap { $0[1].data }.map { try JSONDecoder().decode(FeedLibraryStore.RestoreJournal.self, from: $0) }
    }

    // MARK: - Fixtures

    /// A library whose episodes carry every kind of canonical data the lists never read: long notes, chapters with stored
    /// chapters, provenance-like links, local files, history and statistics units.
    static func richLibrary() async throws -> (URL, FeedLibraryStore, [Int64]) {
        let directory = try EpisodeListKeysTests.directory()
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        var fetched = EpisodeListKeysTests.fetched("https://example.test/rich.xml", title: "Rich", count: 12)
        for index in fetched.feed.episodes.indices {
            fetched.feed.episodes[index].description = "<p>" + String(repeating: "Long notes, with \"quotes\" and é. ", count: 40) + "</p>"
            fetched.feed.episodes[index].chapters = [ParsedChapter(startMilliseconds: 0, title: "Intro"), ParsedChapter(startMilliseconds: 60_000, title: "Main", link: "https://example.test/c")]
            fetched.feed.episodes[index].transcript = FeedTranscript(format: .vtt, url: "https://example.test/t\(index).vtt")
            fetched.feed.episodes[index].paymentLink = "https://example.test/pay"
        }
        let feed = try await store.insert(fetched, options: .init(now: EpisodeListKeysTests.now))
        let ids = feed.episodes.map(\.id).sorted()
        for (offset, id) in ids.enumerated() {
            try await store.updateEpisode(id: id) { episode in
                episode.hasStoredChapters = offset.isMultiple(of: 2)
                episode.userState.lastPlayedHistoryMilliseconds = offset.isMultiple(of: 3) ? 1_700_000_000_000 + Int64(offset) : nil
                episode.userState.playedDurationMilliseconds = Int64(offset) * 1_000
                if offset.isMultiple(of: 4) {
                    episode.userState.isDownloaded = true; episode.userState.localFileURL = "/media/rich-\(offset).mp3"
                    episode.userState.downloadDate = EpisodeListKeysTests.now
                }
            }
        }
        try DerivedDataOracle.write(url, [("INSERT INTO statistics_units(episode_id, unit_id, played_ms, last_played, history, duration_ms, played, position) VALUES (?, 'u1', 5000, 1, 2, 60000, 0, 10)", [.integer(ids[0])]),
                                          ("INSERT INTO statistics_units(episode_id, unit_id, played_ms, last_played, history, duration_ms, played, position) VALUES (?, 'u2', 7000, 3, NULL, 60000, 1, 0)", [.integer(ids[1])])])
        return (url, store, ids)
    }

    /// Routine actions, each checked against its intended change: a favorite, a position, a download removed, a real
    /// listening checkpoint (its played time from the session's start and the sample), played and unplayed marks. The
    /// findings by action.
    static func routineFindings(_ url: URL, _ store: FeedLibraryStore, _ ids: [Int64]) async throws -> [String: [String]] {
        var findings: [String: [String]] = [:]
        func check(_ label: String, _ intent: Intent, _ action: () async throws -> Void) async throws {
            let before = try Snapshot.take(url)
            try await action()
            findings[label] = try Self.check(before, intent, Snapshot.take(url)).found
        }
        try await check("favorite", .editing(ids[0]) { $0.userState.isFavorite = true }) {
            try await store.setFavorite(episodeID: ids[0], favorite: true)
        }
        try await check("position", .editing(ids[1]) { $0.userState.positionMilliseconds = 42_000 }) {
            try await store.updateEpisode(id: ids[1]) { $0.userState.positionMilliseconds = 42_000 }
        }
        try await check("download removed", .editing(ids[4]) { $0.userState.isDownloaded = false; $0.userState.localFileURL = nil; $0.userState.downloadDate = nil }) {
            try await store.updateEpisode(id: ids[4]) { $0.userState.isDownloaded = false; $0.userState.localFileURL = nil; $0.userState.downloadDate = nil }
        }
        // A listening session: it starts from the episode as stored (its position and played time), a first save at 1 s,
        // then the checkpoint at 6 s, 5 s later.
        let start = try #require(try Snapshot.take(url).episode(ids[2]))
        let session = try await store.beginPlayback(episodeID: ids[2])
        #expect(session.startPositionMilliseconds == start.userState.positionMilliseconds && session.playedDurationWhenStarted == start.userState.playedDurationMilliseconds,
                "the session starts from the stored episode")
        let duration = try #require(start.details.media?.durationMilliseconds)
        _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 1_000, durationMilliseconds: duration, status: .playing), now: EpisodeListKeysTests.now)
        let saved = Int64(EpisodeListKeysTests.now.addingTimeInterval(5).timeIntervalSince1970 * 1_000)
        var listening = Intent.editing(ids[2]) { expected in
            expected.userState.positionMilliseconds = 6_000
            expected.userState.lastPlayedTimeMilliseconds = saved
            expected.userState.lastPlayedHistoryMilliseconds = saved
            // The played time: what was played when the session started and what it played since (from its start to 6 s).
            expected.userState.playedDurationMilliseconds = session.playedDurationWhenStarted + 6_000 - Int64(session.startPositionMilliseconds)
        }
        // The session row's record encodes in no fixed key order: compared decoded below.
        listening.free.insert("playback_session")
        try await check("listening checkpoint", listening) {
            _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 6_000, durationMilliseconds: duration, status: .playing),
                                               now: EpisodeListKeysTests.now.addingTimeInterval(5))
        }
        let row = try #require(try Snapshot.take(url).tables["playback_session"]?.values.first)
        let stored = try JSONDecoder().decode(LibraryPlaybackSession.self, from: try #require(row[2].data))
        var playing = session; playing.status = .playing
        if stored != playing || row[1] != .integer(ids[2]) { findings["listening checkpoint", default: []].append("session \(stored)") }
        // Played and unplayed marks change the play state and what a mark resets (the position), nothing else.
        for played in [true, false] {
            var mark = Intent.editing(ids[3]) { expected in
                expected.userState.playState = played ? .played : .unplayed
                if played && expected.details.media != nil { expected.userState.positionMilliseconds = 0 }
            }
            mark.appended = ["pending_effects", "synchronization_outbox"]
            mark.tables["episode_swipe_undo"] = { rows, _ in rows.remove(where: "episode_id", in: [.integer(ids[3])]) }
            try await check("marked \(played ? "played" : "unplayed")", mark) {
                try await store.markEpisodePlayed(episodeID: ids[3], played: played)
            }
        }
        return findings
    }

    /// Routine actions change exactly what they intend: every unrelated field (notes, chapters, stored-chapters flag, local
    /// file, history, the `pubdate` column), every other episode and every unrelated table (statistics units included)
    /// stay byte-identical.
    @Test func routineActionsChangeOnlyWhatTheyIntend() async throws {
        let (url, store, ids) = try await Self.richLibrary()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let findings = try await Self.routineFindings(url, store, ids)
        #expect(findings.count == 6)
        for (action, found) in findings.sorted(by: { $0.key < $1.key }) { #expect(found.isEmpty, "canonical preservation, \(action): \(found)") }
        try await store.close()
    }

    /// Canonical losses that keep the derived data coherent, so the derived-data oracle alone stays green.
    static let canonicalMutations: [String: (action: String, sql: String)] = [
        // A favorite's key update zeroes the episode's `pubdate` column (the order the canonical readers sort by).
        "lose_pubdate": ("favorite", "CREATE TRIGGER lose_pubdate AFTER UPDATE OF favorite ON episode_list_keys WHEN OLD.favorite IS NOT NEW.favorite BEGIN UPDATE episodes SET pubdate = 0 WHERE id = NEW.id; END"),
        // A history key update resets the played time a listening checkpoint accumulates (the key's played time follows).
        "lose_played_duration": ("listening checkpoint", "CREATE TRIGGER lose_played_duration AFTER UPDATE OF history_ms ON episode_list_keys WHEN NEW.history_ms IS NOT OLD.history_ms BEGIN UPDATE episodes SET record = CAST(json_set(CAST(record AS TEXT), '$.userState.playedDurationMilliseconds', 0) AS BLOB) WHERE id = NEW.id; UPDATE episode_list_keys SET played_ms = 0 WHERE id = NEW.id; END"),
    ]

    /// The preservation assertion rejects each by name, at the action it corrupts.
    @Test(arguments: ["lose_pubdate", "lose_played_duration"])
    func aCanonicalLossTheDerivedDataCannotSeeIsCaught(_ name: String) async throws {
        let (url, store, ids) = try await Self.richLibrary()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let mutation = try #require(Self.canonicalMutations[name])
        try RawLibrary.execute(url, mutation.sql)
        let findings = try await Self.routineFindings(url, store, ids)
        #expect(findings[mutation.action]?.isEmpty == false, "\(name): canonical preservation must fail at \(mutation.action)")
        #expect(findings.filter { $0.key != mutation.action }.allSatisfy { $0.value.isEmpty }, "\(name): only \(mutation.action): \(findings)")
        #expect(try DerivedDataOracle.mismatches(url) == [], "\(name): while the derived-data oracle alone stays green")
        print("MUTATION \(name): canonical preservation, \(mutation.action): \(findings[mutation.action]?.first?.prefix(240) ?? "")")
        try await store.close()
    }

    /// A rolled-back write (raw, and a store write that fails) leaves every canonical byte as it was.
    @Test func aRollbackLeavesEveryCanonicalByte() async throws {
        let (url, store, ids) = try await Self.richLibrary()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try Snapshot.take(url)
        var changed = try #require(try await store.episode(id: ids[0]))
        changed.details.description = nil; changed.userState.isFavorite = true
        try DerivedDataOracle.write(url, [("BEGIN", []), ("UPDATE episodes SET record = ? WHERE id = ?", [.blob(try Self.encode(changed)), .integer(ids[0])]),
                                          ("DELETE FROM episodes WHERE id = ?", [.integer(ids[1])]), ("DELETE FROM statistics_units", []),
                                          ("INSERT INTO pending_effects(kind, record) VALUES ('x', X'00')", []), ("ROLLBACK", [])])
        let none = Intent()
        #expect(try Self.check(before, none, Snapshot.take(url)).found == [], "raw rollback")
        await #expect(throws: (any Error).self) {
            try await store.updateEpisode(id: ids[2]) { $0.userState.isFavorite = true; $0.id = 999_999 }
        }
        #expect(try Self.check(before, none, Snapshot.take(url)).found == [], "a failed store write")
        // A store write that fails after writing (an OPML entry merging into the feed, its second header write refused).
        try RawLibrary.execute(url, "CREATE TRIGGER test_reject_placeholder BEFORE UPDATE ON feeds WHEN NEW.record LIKE '%\"sourceTypeAbsent\":true%' BEGIN SELECT RAISE(ABORT, 'refused'); END")
        await #expect(throws: (any Error).self) {
            try await store.importOPMLEntry(.init(title: "Renamed", xmlURL: "https://example.test/rich.xml"), now: EpisodeListKeysTests.now)
        }
        try RawLibrary.execute(url, "DROP TRIGGER test_reject_placeholder")
        #expect(try Self.check(before, none, Snapshot.take(url)).found == [], "a store write failing after its first writes")
        #expect(try Snapshot.take(url) == before)
        try await store.close()
    }

    /// The canonical-preservation assertion catches a derived trigger that deletes notes when a position changes, which
    /// the derived-data oracle (keys from the records after the fact) cannot see.
    @Test func aDerivedTriggerDeletingNotesIsCaught() async throws {
        let (url, store, ids) = try await Self.richLibrary()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try RawLibrary.execute(url, "CREATE TRIGGER corrupt_on_key_update AFTER UPDATE OF position ON episode_list_keys BEGIN UPDATE episodes SET record = CAST(json_remove(CAST(record AS TEXT), '$.details.description') AS BLOB) WHERE id = NEW.id; END")
        let before = try Snapshot.take(url)
        try await store.updateEpisode(id: ids[5]) { $0.userState.positionMilliseconds = 9_000 }
        let found = try Self.check(before, .editing(ids[5]) { $0.userState.positionMilliseconds = 9_000 }, Snapshot.take(url)).found
        #expect(!found.isEmpty, "canonical preservation must fail")
        #expect(try DerivedDataOracle.mismatches(url) == [], "while the derived oracle alone stays green")
        print("MUTATION corrupt_on_key_update: canonical preservation: \(found.first?.prefix(160) ?? "")")
        try await store.close()
    }

    /// A database import into a new library stores exactly the backup: its feeds and episodes (each encoded independently
    /// from the parsed backup), its queue in order, its download log and the ID counters; it carries the replaced
    /// library's synchronization account, outbox and refresh schedule exactly; its derived data only adds rows of the
    /// derived tables.
    @Test func anImportStoresExactlyTheBackup() async throws {
        let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let backup = directory.appendingPathComponent("backup.db")
        var shape = LargeAndroidLibrary.Shape()
        shape.feeds = 20; shape.episodes = 800; shape.heavyFeeds = 2; shape.heavyEpisodes = 100; shape.mediumFeeds = 5; shape.mediumEpisodes = 50
        shape.archivedFeeds = 2; shape.previewFeeds = 1; shape.queue = 10; shape.favorites = 20; shape.chapteredEpisodes = 40; shape.downloadLog = 20
        try LargeAndroidLibrary.write(to: backup, shape: shape)
        let library = try AndroidDatabaseRestore.read(backup, staging: directory.appendingPathComponent("staging"))
        // The replaced library, with what an import carries: an account with a queued change, the refresh schedule.
        let oldURL = directory.appendingPathComponent("old.sqlite")
        let old = try FeedLibraryStore(url: oldURL)
        let feed = try await old.insert(EpisodeListKeysTests.fetched("https://example.test/old.xml", count: 2), options: .init(now: EpisodeListKeysTests.now))
        try await old.selectSynchronizationAccount(UUID())
        try await old.markEpisodePlayed(episodeID: feed.episodes[0].id, played: true)
        try await old.configurePeriodicRefresh(intervalMinutes: 240, allowMobile: true, replace: true)
        let carried = try Snapshot.take(oldURL)
        let carry = try await old.restoreCarryOver()
        try await old.close()
        #expect(["synchronization_state", "periodic_feed_schedule"].allSatisfy { !(carried.tables[$0] ?? [:]).isEmpty }, "the replaced library has state to carry")
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let before = try Snapshot.take(url)
        try await store.installRestoredLibrary(library, carrying: carry)
        try await store.close()
        let after = try Snapshot.take(url)
        let found = try Self.check(before, Self.restoreIntent(library, carried: carried), after).found
        #expect(found.isEmpty, "canonical preservation, import: \(found)")
        #expect(try Self.restoreJournal(after) == FeedLibraryStore.RestoreJournal(feedSpeeds: library.feedSpeeds, feedSilence: library.feedSilence))
        #expect(after.tables["episodes"]?.count == 800 && library.queue.count == 10 && library.downloadLog.count == 20, "a populated backup")
        print("IMPORT carried: outbox \(carried.tables["synchronization_outbox"]?.count ?? 0) rows")
        try EpisodeListKeysTests.expectExact(url, "import")
    }

    /// Keep's conversion of a populated server library changes exactly its intended rows: the device-only played-here
    /// times go; statistics units are the projection of the server's base (a projected unit kept byte-identical, an
    /// unprojected unit added, an unmapped one left out); a podcast pinned as removed becomes a pinned removal; the server
    /// tables are emptied; the identity records the conversion. Everything else stays.
    @Test func keepsConversionRemovesOnlyWhatItMust() async throws {
        let fixture = try await ServerLibraryFixture()
        let registered = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/keep.xml", title: "Keep", count: 6))
        let other = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/other.xml", title: "Other", count: 2))
        // A podcast the server's records brought: its episodes are mapped to the server's episodes.
        try await ServerProjectionUnitTests.Applier(fixture).apply(try ServerBoundedCutoverTests.arrivingRecords(count: 4))
        let mapped = try fixture.rows("SELECT episode_id, local_id FROM ntp_episodes WHERE local_id IS NOT NULL ORDER BY local_id").compactMap { row -> (String, Int64)? in
            guard let wire = row[0], let local = row[1].flatMap({ Int64($0) }) else { return nil }
            return (wire, local)
        }
        try #require(mapped.count >= 3)
        let ids = registered.feed.episodes.map(\.id).sorted()
        try await fixture.store.setFavorite(episodeID: ids[0], favorite: true)
        var first = try #require(try await fixture.store.episode(id: ids[1])), second = try #require(try await fixture.store.episode(id: ids[2]))
        try await fixture.store.close()
        // Device-only played-here times as playback leaves them (written directly: the recorder refuses such a write).
        first.userState.playedHereMilliseconds = 77; first.userState.positionMilliseconds = 5
        second.userState.playedHereMilliseconds = 78; second.details.description = "Notes"
        let projected = #"{"id":"u1","played_ms":5000,"last_played":1,"history":2,"duration_ms":60000,"played":false,"position":10}"#
        let unprojected = #"{"id":"u9","played_ms":1234,"last_played":5,"duration_ms":60000,"played":true}"#
        try DerivedDataOracle.write(fixture.url, [("UPDATE episodes SET record = ? WHERE id = ?", [.blob(try Self.encode(first)), .integer(ids[1])]),
                                                  ("UPDATE episodes SET record = ? WHERE id = ?", [.blob(try Self.encode(second)), .integer(ids[2])]),
                                                  ("INSERT INTO ntp_statistics_units(episode_id, unit_id, record) VALUES (?, 'u1', ?)", [.text(mapped[0].0), .blob(Data(projected.utf8))]),
                                                  ("INSERT INTO statistics_units(episode_id, unit_id, played_ms, last_played, history, duration_ms, played, position) VALUES (?, 'u1', 5000, 1, 2, 60000, 0, 10)", [.integer(mapped[0].1)]),
                                                  ("INSERT INTO ntp_statistics_units(episode_id, unit_id, record) VALUES (?, 'u9', ?)", [.text(mapped[1].0), .blob(Data(unprojected.utf8))]),
                                                  ("INSERT INTO ntp_statistics_units(episode_id, unit_id, record) VALUES ('unmapped', 'u7', ?)", [.blob(Data(projected.utf8))]),
                                                  ("UPDATE ntp_podcasts SET pinned_removal = 1 WHERE feed_id = ?", [.integer(other.feed.id)])])
        let before = try Snapshot.take(fixture.url)
        let database = try LibrarySQLite(url: fixture.url)
        try database.transaction { try LibraryKeep.convert(database, operation: "keep-preservation") }
        try database.close()
        let after = try Snapshot.take(fixture.url)
        let found = try Self.check(before, Self.keepIntent(before, operation: "keep-preservation"), after).found
        #expect(found.isEmpty, "canonical preservation, Keep: \(found)")
        #expect(after.tables["statistics_units"]?.count == 2 && after.tables["pinned_feed_removals"]?.count == 1, "the expected rows exist")
        #expect(after.tables.filter { $0.key.hasPrefix("ntp_") }.allSatisfy { $0.value.isEmpty }, "the server tables are emptied")
        try EpisodeListKeysTests.expectExact(fixture.url, "Keep")
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    /// A shadow publication of 600 favorites and 2,000 staged episodes changes the favorites' flag only; the staged rows
    /// keep their staged bytes; every other episode, the statistics units and the canonical tables outside the server
    /// state are unchanged; effects are only added.
    @Test func aPublicationChangesOnlyItsFavorites() async throws {
        typealias Cutover = ServerBoundedCutoverTests
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        try await ServerProjectionUnitTests.Applier(fixture).apply(try Cutover.arrivingRecords(count: 600))
        let feed = try #require(try await Cutover.arrived(store))
        let shown = feed.episodes.map(\.id).sorted()
        let input = try await ServerRetainedPublicationTests.nextInput(fixture, try Cutover.episodeRecords(601...2_600) + (1...600).map(ServerShadowStagingTests.favorite))
        let shadow = try await ServerRetainedPublicationTests.build(fixture, input)
        try await ServerShadowStagingTests.stageAll(fixture, shadow, seq: input.commit.seq)
        try DerivedDataOracle.write(fixture.url, [("INSERT INTO statistics_units(episode_id, unit_id, played_ms, last_played, history, duration_ms, played, position) VALUES (?, 'u1', 5000, 1, 2, 60000, 0, 10)", [.integer(shown[0])]),
                                                  ("INSERT INTO statistics_units(episode_id, unit_id, played_ms, last_played, history, duration_ms, played, position) VALUES (?, 'u2', 7000, 3, NULL, 60000, 1, 0)", [.integer(shown[1])])])
        let before = try Snapshot.take(fixture.url)
        let start = DerivedSequenceTests.now()
        _ = try await store.publishServerShadow(shadow, input: input, history: nil)
        let window = start...DerivedSequenceTests.now()
        let after = try Snapshot.take(fixture.url)
        var intent = Intent()
        // The server tables it writes: rows of the commit's records, the podcast and its episodes (shown and staged); the
        // library row as a unit leaves it.
        intent.server = .init(tables: DerivedSequenceTests.publicationRules,
                              wires: Set([Cutover.arriving, Cutover.arrivingGeneration] + (1...2_600).map(Cutover.wire)),
                              episodes: Set(before.tables["episodes"]?.filter { $0.value[1] == .integer(feed.id) }.keys ?? [:].keys), feeds: [feed.id])
        DerivedSequenceTests.unitLibrary(&intent, cursor: input.cursor, queueKeys: 0, window: window)
        intent.appended = ["pending_effects"]
        for id in shown { intent.edits[id] = { $0.userState.isFavorite = true } }
        let found = try Self.check(before, intent, after).found
        #expect(found.isEmpty, "canonical preservation, publication: \(found)")
        try EpisodeListKeysTests.expectExact(fixture.url, "published")
        await fixture.close()
    }
}
