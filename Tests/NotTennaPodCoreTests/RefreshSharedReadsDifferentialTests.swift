import Foundation
import SQLite3
import Testing
@testable import NotTennaPodCore

/// A server library's refresh reads its feed's server tables once and hands what it read on (the
/// merge's observed hashes to the recorder, the decoded feed to the capture, the local identities' rows to the merge).
/// Differential byte test: the same random refreshes (new, renamed, re-described, re-dated and re-hosted items, repeated
/// and changed GUIDs, canonical metadata and observations, a played mark between them) on two copies of one library,
/// one with the shared reads and one without (the code before, `refreshSharesReads = false`); after every step every
/// table of both is equal row by row, random identifiers and wall-clock times normalized.
@Suite(.serialized)
struct RefreshSharedReadsDifferentialTests {
    /// Every table's rows in rowid order (key order for tables without rowid), blobs as text when they are text. A
    /// fact's content hash covers its random op ID, so it is checked against its own fact here and then compared as that
    /// verdict; every other value, stable hashes included, is compared as stored (`normalized`).
    static func dump(_ url: URL) throws -> [Row] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { throw FeedLibraryError.invalidLocation }
        defer { sqlite3_close(db) }
        func query(_ sql: String) throws -> [[String]] { try columnsAndRows(sql).rows }
        func columnsAndRows(_ sql: String) throws -> (columns: [String], rows: [[String]]) {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw FeedLibraryError.sqlite(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            var rows: [[String]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append((0..<sqlite3_column_count(statement)).map { index in
                    switch sqlite3_column_type(statement, index) {
                    case SQLITE_NULL: return "NULL"
                    case SQLITE_BLOB:
                        let count = Int(sqlite3_column_bytes(statement, index))
                        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return "x''" }
                        let data = Data(bytes: bytes, count: count)
                        return String(data: data, encoding: .utf8) ?? data.map { String(format: "%02x", $0) }.joined()
                    default: return sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
                    }
                })
            }
            return ((0..<sqlite3_column_count(statement)).map { String(cString: sqlite3_column_name(statement, $0)) }, rows)
        }
        var dumped: [Row] = []
        for table in try query("SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name") {
            let order = table[1].contains("WITHOUT ROWID") ? "1, 2, 3" : "rowid"
            let (columns, rows) = try columnsAndRows("SELECT * FROM \(table[0]) ORDER BY \(order)")
            for var row in rows {
                if table[0] == "ntp_outbox", let hash = columns.firstIndex(of: "content_hash"), let fact = columns.firstIndex(of: "fact") {
                    let computed = try ContractHash.contentHash(try ContractJSON.decode(Data(row[fact].utf8)))
                    row[hash] = computed == row[hash] ? "<content hash of its fact>" : "<content hash \(row[hash]) != \(computed)>"
                }
                dumped.append(Row(table: table[0], cells: Array(zip(columns, row))))
            }
        }
        return dumped
    }

    /// One row of a dump: its table and its columns' values.
    struct Row {
        let table: String
        let cells: [(column: String, value: String)]
        var text: String { "\(table): \(cells.map(\.value).joined(separator: " | "))" }
    }

    /// The columns whose values are random in each run: IDs the recorder draws (op, node, ledger entry and observation
    /// IDs), and the outbox's wall-clock creation time. The library's own folder differs between copies.
    static let randomIDColumns: Set<String> = [
        "ntp_authors.last_op_id", "ntp_ledger.entry_id", "ntp_nodes.node_id", "ntp_observed.catalog_node",
        "ntp_observed.observation_op", "ntp_outbox.op_id", "ntp_overlays.op_id",
    ]
    static let wallClockColumns: Set<String> = ["ntp_outbox.created_at"]
    static let folderColumns: Set<String> = ["library_identity.paths_root"]
    /// The JSON members (in any record or fact) whose values are random IDs, and the one that may hold the wall clock.
    static let randomIDMember = try! NSRegularExpression(pattern: "\"(op_id|previous_op_id|batch_id|proposal_id|catalog_only_observation)\":\"([^\"]*)\"")
    static let dependenciesMember = try! NSRegularExpression(pattern: "\"dependencies\":\\[([^\\]]*)\\]")
    static let clientTimeMember = try! NSRegularExpression(pattern: "\"client_time\":([0-9]+)")

    /// Normalizes only what is random in each run (above): those columns' values and those members' values, by order
    /// of appearance (a fact's dependencies, sorted by their random values, as sorted names); a wall-clock value as T.
    /// Everything else (stable identities, GUIDs, addresses, parsed content and hashes) is compared as stored.
    static func normalized(_ rows: [Row]) -> [String] {
        var names: [String: String] = [:]
        func name(_ value: String) -> String {
            if let known = names[value] { return known }
            names[value] = "#\(names.count)"
            return names[value]!
        }
        let now = Date().timeIntervalSince1970 * 1_000
        func wallClock(_ text: String) -> Bool { Double(text).map { abs($0 - now) < 2 * 86_400_000 } ?? false }
        return rows.map { row in
            let cells = row.cells.map { cell -> String in
                let key = "\(row.table).\(cell.column)"
                if randomIDColumns.contains(key) { return cell.value == "NULL" ? "NULL" : name(cell.value) }
                if wallClockColumns.contains(key) { return wallClock(cell.value) ? "T" : cell.value }
                if folderColumns.contains(key) { return "<folder>" }
                var text = cell.value
                for match in randomIDMember.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                    let value = Range(match.range(at: 2), in: text)!
                    text.replaceSubrange(value, with: name(String(text[value])))
                }
                for match in dependenciesMember.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                    let list = Range(match.range(at: 1), in: text)!
                    let items = text[list].split(separator: ",").map { "\"\(name(String($0.trimmingCharacters(in: ["\""]))))\"" }.sorted()
                    text.replaceSubrange(list, with: items.joined(separator: ","))
                }
                for match in clientTimeMember.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                    let value = Range(match.range(at: 1), in: text)!
                    if wallClock(String(text[value])) { text.replaceSubrange(value, with: "T") }
                }
                return text
            }
            return "\(row.table): \(cells.joined(separator: " | "))"
        }
    }

    /// The oracle sees a stable hash that differs on one side only: a library whose observed parse hash changed is not
    /// equal to one whose did not, though both were refreshed alike.
    @Test func aStableObservedHashDifferenceFailsTheComparison() async throws {
        let base = try await ServerLibraryFixture()
        defer { Task { await base.close() } }
        let registered = try await base.subscribeRegistered(Self.feed((0..<5).map {
            Item(guid: "guid-\($0)", title: "Episode \($0)", description: "About \($0)", day: Double($0), url: "https://media.example.test/\($0).mp3")
        }))
        let a = try await base.copy(), b = try await base.copy()
        defer { Task { await a.close(); await b.close() } }
        let local = try #require(registered.feed.episodes.first?.id)
        for fixture in [a, b] {
            try await fixture.store.executeForTesting(
                "INSERT OR REPLACE INTO ntp_observed(entity, id, parse_hash) VALUES ('episode', ?, ?)",
                [.text("local-episode:\(local)"), .text(String(repeating: "a", count: 64))])
        }
        #expect(Self.normalized(try Self.dump(a.url)) == Self.normalized(try Self.dump(b.url)), "alike before the change")
        try await b.store.executeForTesting("UPDATE ntp_observed SET parse_hash = ? WHERE entity = 'episode' AND id = ?",
                                            [.text(String(repeating: "b", count: 64)), .text("local-episode:\(local)")])
        let left = Self.normalized(try Self.dump(a.url)), right = Self.normalized(try Self.dump(b.url))
        #expect(left != right, "one stable observed hash differs on one side")
        #expect(zip(left, right).filter { $0 != $1 }.count == 1)
    }

    /// Two copies of a library whose first episode has a UUID-shaped GUID and a media address carrying the current
    /// time in its query, alike before `change` is made to the second.
    static let guid = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
    static let stamp = Int64(Date().timeIntervalSince1970 * 1_000)

    static func oneSided(_ change: (ServerLibraryFixture, Int64) async throws -> Void) async throws -> (before: Bool, after: [String: Int]) {
        let now = Self.stamp
        let base = try await ServerLibraryFixture()
        defer { Task { await base.close() } }
        let registered = try await base.subscribeRegistered(Self.feed((0..<3).map {
            Item(guid: $0 == 0 ? Self.guid : "guid-\($0)", title: "Episode \($0)", description: "About \($0)",
                 day: Double($0), url: "https://media.example.test/\($0).mp3?v=\(now)")
        }))
        let a = try await base.copy(), b = try await base.copy()
        defer { Task { await a.close(); await b.close() } }
        let local = try #require(registered.feed.episodes.map(\.id).min())
        let before = Self.normalized(try Self.dump(a.url)) == Self.normalized(try Self.dump(b.url))
        try await change(b, local)
        let left = Self.normalized(try Self.dump(a.url)), right = Self.normalized(try Self.dump(b.url))
        var differing: [String: Int] = [:]
        for (l, r) in zip(left, right) where l != r { differing[String(l.prefix { $0 != ":" }), default: 0] += 1 }
        return (before, differing)
    }

    /// A stable UUID-shaped RSS GUID changed on one side only is a difference, not a random identifier.
    @Test func stableUUIDContentMustSurviveNormalization() async throws {
        let (before, differing) = try await Self.oneSided { fixture, local in
            // Only those characters of the stored record change (the rest of its encoding stays byte for byte).
            try await fixture.store.executeForTesting(
                "UPDATE episodes SET record = CAST(replace(CAST(record AS TEXT), ?, ?) AS BLOB) WHERE id = ?",
                [.text(Self.guid), .text("9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"), .integer(local)])
        }
        #expect(before, "alike before the change")
        // The episode row, and its feed's change generation that the write bumped.
        #expect(differing["episodes"] == 1, "\(differing)")
    }

    /// A media address whose query holds a current timestamp, changed on one side only, is a difference, not a wall-clock
    /// field.
    @Test func stableNumericContentMustSurviveNormalization() async throws {
        let (before, differing) = try await Self.oneSided { fixture, local in
            try await fixture.store.executeForTesting(
                "UPDATE episodes SET record = CAST(replace(CAST(record AS TEXT), ?, ?) AS BLOB) WHERE id = ?",
                [.text("v=\(Self.stamp)"), .text("v=\(Self.stamp + 1_000)"), .integer(local)])
        }
        #expect(before, "alike before the change")
        // The episode row, and its feed's change generation that the write bumped.
        #expect(differing["episodes"] == 1, "\(differing)")
    }

    struct Item { var guid: String; var title: String; var description: String; var day: Double; var url: String? }

    static func feed(_ items: [Item]) -> FetchedFeed {
        let episodes = items.map {
            ParsedEpisode(identifier: $0.guid, title: $0.title, description: $0.description,
                          publicationDate: ServerLibraryFixture.now.addingTimeInterval($0.day * 86_400),
                          media: $0.url.map { ParsedMedia(url: $0, size: 1_000, durationMilliseconds: 600_000) })
        }
        var fetched = FetchedFeed(feed: ParsedFeed(format: .rss, title: "Show", episodes: episodes), source: "https://example.test/feed.xml",
                                  responseURL: URL(string: "https://example.test/feed.xml")!, validator: nil, permanentRedirectURL: nil)
        fetched.catalog = ServerCatalogRecords.interim(fetched.feed)
        return fetched
    }

    @Test(arguments: [11, 23, 37])
    func sharedReadsWriteExactlyWhatSeparateReadsWrote(seed: UInt64) async throws {
        var random = SeededRandom(seed: seed)
        // Every seventh item without media, which a later step may give it (gained media files the episode).
        var items = (0..<40).map { Item(guid: "guid-\($0)", title: "Episode \($0)", description: "About \($0)", day: Double($0),
                                        url: $0 % 7 == 3 ? nil : "https://media.example.test/\($0).mp3") }
        let base = try await ServerLibraryFixture()
        defer { Task { await base.close() } }
        let registered = try await base.subscribeRegistered(Self.feed(items))
        try await base.store.executeForTesting("INSERT INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('podcast', ?, 'metadata', ?, '[]')",
                                               [.text(registered.podcast), .blob(try (["title": "Show"] as ContractJSON).canonicalData())])
        // Two copies made alike (a copy's rows may be renumbered, so both are copies).
        let a = try await base.copy(), b = try await base.copy()
        defer { Task { await a.close(); await b.close() } }
        await b.store.setRefreshSharesReads(false)
        let feedID = registered.feed.id
        var next = 40
        // The first two items are never edited: their canonical metadata, shown from step 5, must stay shown.
        func any() -> Int { 2 + Int(random.next() % UInt64(items.count - 2)) }
        for step in 0..<16 {
            switch random.next() % 8 {
            case 0: for _ in 0..<(1 + random.next() % 3) { items.append(Item(guid: "guid-\(next)", title: "Episode \(next)", description: "New \(next)",
                                                                             day: Double(next), url: "https://media.example.test/\(next).mp3")); next += 1 }
            case 1: for _ in 0..<3 { items[any()].title += " (edited)" }
            case 2: for _ in 0..<3 { items[any()].description += " more" }
            case 3: let i = any(); if items[i].url != nil { items[i].url = "https://other.example.test/\(i)-\(step).mp3" }
            case 4: items.append(items[any()])
            case 5: items[any()].guid += "-changed"
            case 6: if let i = items.indices.first(where: { $0 >= 2 && items[$0].url == nil }) { items[i].url = "https://media.example.test/gained-\(i).mp3" }
            default: items[any()].day += 0.5
            }
            let fetched = Self.feed(items)
            let options = FeedRefreshOptions(now: ServerLibraryFixture.now.addingTimeInterval(Double(30_000 + step) * 86_400))
            for fixture in [a, b] {
                let result = try await fixture.store.applyRefresh(fetched, feedID: feedID, options: options)
                if step % 3 == 1 || step == 4 {
                    try await FeedLibraryStore.drainObservations(fixture.store, feedID: feedID, catalog: fetched.catalog, items: result.serverItems)
                }
                if step == 5 {
                    // Canonical metadata arrives for the first two items' episodes and is shown (as a projection writes it):
                    // a refresh whose parse of them is unchanged since observed keeps it.
                    for row in try fixture.rows("SELECT local_id FROM ntp_local_items WHERE value IN ('guid-0', 'guid-1')") {
                        guard let local = row[0].flatMap({ Int64($0) }), let wire = try fixture.wireID(local) else { continue }
                        try await fixture.store.executeForTesting(
                            "INSERT OR IGNORE INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('episode', ?, 'metadata', ?, '[]')",
                            [.text(wire), .blob(try (["title": "Canonical"] as ContractJSON).canonicalData())])
                        try await fixture.store.executeForTesting(
                            "UPDATE episodes SET record = CAST(json_set(CAST(record AS TEXT), '$.details.title', 'Canonical') AS BLOB) WHERE id = ?",
                            [.integer(local)])
                    }
                }
                if step == 8, let first = try await fixture.store.feed(id: feedID)?.episodes.map(\.id).min() {
                    try await fixture.store.markEpisodePlayed(episodeID: first, played: true)
                }
            }
            let left = Self.normalized(try Self.dump(a.url)), right = Self.normalized(try Self.dump(b.url))
            #expect(left.count == right.count, "step \(step)")
            let differences = zip(left, right).filter { $0 != $1 }.prefix(5)
            #expect(differences.isEmpty, "step \(step): \(differences.map { "\n- \($0)\n+ \($1)" }.joined())")
        }
    }
}

/// SplitMix64: the same sequence for a seed, everywhere.
struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension FeedLibraryStore {
    func setRefreshSharesReads(_ value: Bool) { refreshSharesReads = value }
}
