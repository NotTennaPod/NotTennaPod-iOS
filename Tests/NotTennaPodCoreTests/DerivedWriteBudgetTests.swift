import Foundation
import Testing
@testable import NotTennaPodCore

/// What derived data costs each write (schema 21): key rows and counts rows written, index operations (the column groups'
/// SET lists, counted by EXPLAIN), and the details generation. A position-only save writes one key row with no index
/// operation and no counts row; a real listening checkpoint maintains only the history and last-played indexes it
/// changes; bulk paths stay within one key row per episode and one counts row per feed.
@Suite(.serialized) struct DerivedWriteBudgetTests {
    /// The log of derived writes on the store's own connection (TEMP triggers, this connection only).
    struct Log: Equatable, CustomStringConvertible {
        var keyInserts = 0, keyDeletes = 0
        /// Updated key rows by the set of indexes their statement maintained.
        var keyUpdates: [String] = []
        var keyRows: Set<Int64> = []
        var countWrites = 0
        var countRows: Set<Int64> = []
        var sequenceWrites = 0
        var detailsBumps = 0
        /// Rows the log itself wrote (they count in `total_changes()` too).
        var entries = 0
        /// Derived rows written: key inserts, deletes and updates, and counts writes.
        var derivedWrites: Int { keyInserts + keyDeletes + keyUpdates.count + countWrites }
        /// Index operations (an IdxDelete and an IdxInsert per maintained index of each updated row, an IdxInsert or
        /// IdxDelete per index of each inserted or deleted row).
        var indexOperations = 0
        var description: String {
            let updates = Dictionary(keyUpdates.map { ($0, 1) }, uniquingKeysWith: +).sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }
            return "inserts \(keyInserts), deletes \(keyDeletes), updates [\(updates.joined(separator: ", "))], key rows \(keyRows.count), counts writes \(countWrites) rows \(countRows.count), index operations \(indexOperations), sequence \(sequenceWrites), details \(detailsBumps)"
        }
    }

    static let groupColumns: [String: [String]] = Dictionary(uniqueKeysWithValues: LibrarySchema21.columnGroups.map { ($0.name, $0.columns) }
        + [("metadata+", ["feed_id", "pub_ref", "pub_ms", "has_media", "duration", "feed_eligible"]), ("hidden", ["hidden"]), ("eligible", ["feed_eligible"])])

    /// The indexes an UPDATE setting `columns` maintains, from SQLite's own program (EXPLAIN).
    static func maintainedIndexes(_ database: LibrarySQLite, _ columns: [String]) throws -> [String] {
        let program = try database.rows("EXPLAIN UPDATE episode_list_keys SET " + columns.map { "\($0) = \($0)" }.joined(separator: ", ") + " WHERE id = 1")
        let deleted = program.filter { $0[1].text == "IdxDelete" }.compactMap { $0[5].text }.sorted()
        let inserted = program.filter { $0[1].text == "IdxInsert" }.count
        precondition(deleted.count == inserted, "every maintained index is deleted from and inserted into")
        return deleted
    }

    static func install(_ store: FeedLibraryStore) async throws {
        try await store.withDatabaseForTesting { database in
            try database.execute("CREATE TEMP TABLE IF NOT EXISTS derived_log (kind TEXT, id INTEGER, column TEXT, image TEXT)")
            try database.execute("DELETE FROM temp.derived_log")
            var statements = [
                "CREATE TEMP TRIGGER IF NOT EXISTS log_key_insert AFTER INSERT ON main.episode_list_keys BEGIN INSERT INTO temp.derived_log VALUES ('key_insert', NEW.id, NULL, NULL); END",
                "CREATE TEMP TRIGGER IF NOT EXISTS log_key_delete AFTER DELETE ON main.episode_list_keys BEGIN INSERT INTO temp.derived_log VALUES ('key_delete', OLD.id, NULL, NULL); END",
                "CREATE TEMP TRIGGER IF NOT EXISTS log_counts_insert AFTER INSERT ON main.feed_list_counts BEGIN INSERT INTO temp.derived_log VALUES ('counts', NEW.feed_id, NULL, NULL); END",
                "CREATE TEMP TRIGGER IF NOT EXISTS log_counts_update AFTER UPDATE ON main.feed_list_counts BEGIN INSERT INTO temp.derived_log VALUES ('counts', NEW.feed_id, NULL, NULL); END",
                "CREATE TEMP TRIGGER IF NOT EXISTS log_counts_delete AFTER DELETE ON main.feed_list_counts BEGIN INSERT INTO temp.derived_log VALUES ('counts', OLD.feed_id, NULL, NULL); END",
                "CREATE TEMP TRIGGER IF NOT EXISTS log_sequence AFTER UPDATE ON main.library_change_sequence BEGIN INSERT INTO temp.derived_log VALUES ('sequence', NEW.id, NULL, NULL); END",
                "CREATE TEMP TRIGGER IF NOT EXISTS log_details AFTER UPDATE OF details_generation ON main.feed_changes WHEN OLD.details_generation IS NOT NEW.details_generation BEGIN INSERT INTO temp.derived_log VALUES ('details', NEW.feed_id, NULL, NULL); END",
            ]
            // An UPDATE OF trigger fires for every column in the statement's SET list, changed or not: exactly what decides
            // which indexes SQLite maintains. The triggers of one row's update see the same old and new row (`image`), which
            // a later statement on that row never repeats; their firing order is not defined.
            let image = (LibrarySchema21.keyColumns.map { "quote(OLD.\($0))" } + LibrarySchema21.keyColumns.map { "quote(NEW.\($0))" }).joined(separator: " || ',' || ")
            for column in LibrarySchema21.keyColumns.dropFirst() {
                statements.append("CREATE TEMP TRIGGER IF NOT EXISTS log_set_\(column) AFTER UPDATE OF \(column) ON main.episode_list_keys BEGIN INSERT INTO temp.derived_log VALUES ('set', NEW.id, '\(column)', \(image)); END")
            }
            for statement in statements { try database.execute(statement) }
        }
    }

    /// The log since `install`, cleared.
    static func take(_ store: FeedLibraryStore) async throws -> Log {
        try await store.withDatabaseForTesting { database in
            var log = Log()
            let all = try database.rows("SELECT count(*) FROM pragma_index_list('episode_list_keys')")[0][0].integer ?? 0
            var updates: [(id: Int64, image: String, columns: [String])] = []
            for row in try database.rows("SELECT kind, id, column, image FROM temp.derived_log ORDER BY rowid") {
                log.entries += 1
                let id = row[1].integer ?? 0
                switch row[0].text {
                case "set":
                    let image = row[3].text ?? ""
                    if let index = updates.lastIndex(where: { $0.id == id && $0.image == image }) { updates[index].columns.append(row[2].text ?? "") }
                    else { updates.append((id, image, [row[2].text ?? ""])) }
                case "key_insert": log.keyInserts += 1; log.keyRows.insert(id); log.indexOperations += Int(all)
                case "key_delete": log.keyDeletes += 1; log.keyRows.insert(id); log.indexOperations += Int(all)
                case "counts": log.countWrites += 1; log.countRows.insert(id)
                case "sequence": log.sequenceWrites += 1
                case "details": log.detailsBumps += 1
                default: break
                }
            }
            var cache: [[String]: Int] = [:]
            for update in updates {
                let columns = Set(update.columns).sorted()
                log.keyRows.insert(update.id)
                let group = Self.groupColumns.first { Set($0.value) == Set(columns) }?.key ?? "set(\(columns.joined(separator: ",")))"
                log.keyUpdates.append(group)
                if cache[columns] == nil { cache[columns] = try maintainedIndexes(database, columns).count }
                log.indexOperations += 2 * (cache[columns] ?? 0)
            }
            try database.execute("DELETE FROM temp.derived_log")
            return log
        }
    }

    /// Each column group's SET list maintains only its own indexes (EXPLAIN); the state, favorite and download indexes
    /// are apart from the history ones.
    @Test func eachColumnGroupMaintainsOnlyItsOwnIndexes() async throws {
        let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let maintained = try await store.withDatabaseForTesting { database in
            try Dictionary(uniqueKeysWithValues: Self.groupColumns.map { ($0.key, try Self.maintainedIndexes(database, $0.value)) })
        }
        #expect(maintained["listening"] == [])
        #expect(maintained["state"] == ["episode_list_keys_downloaded", "episode_list_keys_favorite", "episode_list_keys_inbox_date",
                                        "episode_list_keys_inbox_duration", "episode_list_keys_new", "episode_list_keys_surprise"])
        #expect(maintained["history"] == ["episode_list_keys_classics", "episode_list_keys_history", "episode_list_keys_history_any"])
        #expect(maintained["lookup"] == ["episode_list_keys_file_name", "episode_list_keys_guid", "episode_list_keys_media_url"])
        #expect(maintained["metadata+"]?.contains("episode_list_keys_by_feed") == true && maintained["metadata+"]?.contains("episode_list_keys_favorite") == false)
        try await store.close()
    }

    /// A position-only save writes one key row, no index and no counts row; a real listening checkpoint (position,
    /// played time, last played and history) maintains only the three history indexes, writes no counts row and no
    /// details generation. Each is a visible change, so the persisted order moves once for it (one row update per
    /// visible commit, by the change capture).
    @Test func aSaveWritesOneKeyRowAndOnlyTheIndexesItChanges() async throws {
        let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let feed = try await store.insert(EpisodeListKeysTests.fetched("https://example.test/s.xml", count: 30), options: .init(now: EpisodeListKeysTests.now))
        let id = try #require(feed.episodes.first { $0.details.media != nil }?.id)
        // A favorite, downloaded episode: their indexes hold it, and a save must not maintain them.
        try await store.updateEpisode(id: id) { $0.userState.isFavorite = true; $0.userState.isDownloaded = true; $0.userState.localFileURL = "/m/f.mp3" }
        let session = try await store.beginPlayback(episodeID: id)
        _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 1_000, durationMilliseconds: 90_000, status: .playing),
                                           now: EpisodeListKeysTests.now)
        try await Self.install(store)
        try await store.updateEpisode(id: id) { $0.userState.positionMilliseconds = 2_000 }
        let positionOnly = try await Self.take(store)
        #expect(positionOnly.keyRows == [id] && positionOnly.keyUpdates == ["listening"], "\(positionOnly)")
        #expect(positionOnly.indexOperations == 0 && positionOnly.countWrites == 0 && positionOnly.detailsBumps == 0, "\(positionOnly)")
        #expect(positionOnly.sequenceWrites == 1, "the order moves once: \(positionOnly)")
        _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 6_000, durationMilliseconds: 90_000, status: .playing),
                                           now: EpisodeListKeysTests.now.addingTimeInterval(5))
        let checkpoint = try await Self.take(store)
        #expect(checkpoint.keyRows == [id] && Set(checkpoint.keyUpdates) == ["listening", "history"], "\(checkpoint)")
        #expect(checkpoint.indexOperations == 6, "the history, history-entry and classics indexes only: \(checkpoint)")
        #expect(checkpoint.countWrites == 0 && checkpoint.detailsBumps == 0 && checkpoint.sequenceWrites == 1, "\(checkpoint)")
        // A duration correction (metadata) changes no counted value: no counts row.
        _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 7_000, durationMilliseconds: 91_000, status: .playing),
                                           now: EpisodeListKeysTests.now.addingTimeInterval(5))
        let correction = try await Self.take(store)
        #expect(correction.keyUpdates.contains("metadata+") && correction.countWrites == 0, "\(correction)")
        try EpisodeListKeysTests.expectExact(url, "saves")
        try await store.close()
    }

    /// A 4,234-item refresh: unchanged writes no derived row; one new episode writes one key row and one counts row; every
    /// description changed writes no key row and no index (descriptions are not derived), only the details generation.
    @Test func aLargeRefreshWritesOnlyWhatChanged() async throws {
        let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let source = "https://example.test/big.xml"
        let feed = try await store.insert(EpisodeListKeysTests.fetched(source, count: 4_234), options: .init(now: EpisodeListKeysTests.now))
        try await Self.install(store)
        _ = try await store.applyRefresh(EpisodeListKeysTests.fetched(source, count: 4_234), feedID: feed.id, options: .init(now: EpisodeListKeysTests.now))
        _ = try await Self.take(store)
        _ = try await store.applyRefresh(EpisodeListKeysTests.fetched(source, count: 4_234), feedID: feed.id, options: .init(now: EpisodeListKeysTests.now))
        let unchanged = try await Self.take(store)
        #expect(unchanged == Log(), "\(unchanged)")
        _ = try await store.applyRefresh(EpisodeListKeysTests.fetched(source, count: 4_235), feedID: feed.id, options: .init(now: EpisodeListKeysTests.now))
        let one = try await Self.take(store)
        #expect(one.keyInserts == 1 && one.keyUpdates.isEmpty && one.countRows == [feed.id] && one.countWrites == 1, "\(one)")
        var described = EpisodeListKeysTests.fetched(source, count: 4_235)
        for index in described.feed.episodes.indices { described.feed.episodes[index].description = "Rewritten \(index)" }
        _ = try await store.applyRefresh(described, feedID: feed.id, options: .init(now: EpisodeListKeysTests.now))
        let notes = try await Self.take(store)
        #expect(notes.keyRows.isEmpty && notes.indexOperations == 0 && notes.countWrites == 0, "\(notes)")
        #expect(notes.detailsBumps == 4_235, "each changed episode's details move the generation")
        try EpisodeListKeysTests.expectExact(url, "refreshes")
        try await store.close()
    }

    /// A restore writes each key row once and each feed's counts row once (actual writes, not distinct rows).
    @Test func aRestoreWritesOneKeyRowPerEpisodeAndOneCountsRowPerFeed() async throws {
        let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let log = try await Self.restore(in: directory, episodes: 2_000, feeds: 40)
        #expect(Self.writesOnce(log, episodes: 2_000, feeds: 40), "\(log)")
    }

    static func writesOnce(_ log: Log, episodes: Int, feeds: Int) -> Bool {
        log.keyInserts == episodes && log.keyDeletes == 0 && log.keyUpdates.isEmpty && log.countWrites == feeds && log.countRows.count == feeds
    }

    /// A trigger that writes each new counts row a second time: the restore's write gate catches it.
    @Test func theRestoreGateCatchesARepeatedCountsWrite() async throws {
        let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let log = try await Self.restore(in: directory, episodes: 2_000, feeds: 40) { store in
            try await store.withDatabaseForTesting { try $0.execute("CREATE TRIGGER derived_mutation_restore_counts AFTER INSERT ON feed_list_counts BEGIN UPDATE feed_list_counts SET total = total WHERE feed_id = NEW.feed_id; END") }
        }
        #expect(!Self.writesOnce(log, episodes: 2_000, feeds: 40), "\(log)")
        print("MUTATION derived_mutation_restore_counts: \(log.countWrites) counts writes for 40 feeds")
    }

    static func restore(in directory: URL, episodes: Int, feeds: Int,
                        prepare: (@Sendable (FeedLibraryStore) async throws -> Void)? = nil) async throws -> Log {
        var shape = LargeAndroidLibrary.Shape()
        shape.feeds = feeds; shape.episodes = episodes
        shape.heavyFeeds = min(10, feeds / 7); shape.heavyEpisodes = episodes / 4 / max(1, min(10, feeds / 7))
        shape.mediumFeeds = feeds / 2; shape.mediumEpisodes = episodes / 3 / (feeds / 2)
        shape.archivedFeeds = 3; shape.previewFeeds = 2
        let backup = directory.appendingPathComponent("backup.db")
        try LargeAndroidLibrary.write(to: backup, shape: shape)
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try await prepare?(store)
        try await install(store)
        let library = try AndroidDatabaseRestore.read(backup, staging: directory.appendingPathComponent("staging"))
        try await store.installRestoredLibrary(library, carrying: try await store.restoreCarryOver())
        let log = try await take(store)
        try await store.close()
        return log
    }

    /// Counts stay flat while the feed holds a growing hidden backlog: a favorite toggle on a visible episode and the
    /// feed's counts read cost the same with 100, 1,000 and 3,000 staged hidden episodes.
    @Test func countsStayFlatUnderAHiddenBacklog() async throws {
        var writes: [Int64] = [], reads: [Int64] = []
        for backlog in [100, 1_000, 3_000] {
            let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("library.sqlite")
            let store = try FeedLibraryStore(url: url)
            let feed = try await store.insert(EpisodeListKeysTests.fetched("https://example.test/f.xml", count: 50), options: .init(now: EpisodeListKeysTests.now))
            var statements: [(String, [LibrarySQLValue])] = [("BEGIN", [])]
            var template = feed.episodes[0]
            for index in 0..<backlog {
                template.id = 700_000 + Int64(index); template.details.identifier = "staged-\(index)"; template.userState.playState = .new
                statements.append(("INSERT INTO ntp_hidden_episodes(episode_id, feed_id) VALUES (?, ?)", [.integer(template.id), .integer(feed.id)]))
                statements.append(("INSERT INTO episodes(id, feed_id, pubdate, record) VALUES (?, ?, 0, ?)", [.integer(template.id), .integer(feed.id), .blob(try DerivedDataOracle.record(template))]))
            }
            statements.append(("COMMIT", []))
            try DerivedDataOracle.write(url, statements)
            let id = feed.episodes[1].id
            try await store.setFavorite(episodeID: id, favorite: false)
            let before = try await store.withDatabaseForTesting { $0.statementSteps }
            try await store.setFavorite(episodeID: id, favorite: true)
            writes.append(try await store.withDatabaseForTesting { $0.statementSteps } - before)
            let readers = try await store.readers()
            _ = try await readers.quick.counts(feeds: [feed.id])
            let start = await readers.quick.metrics.statementSteps
            let counts = try await readers.quick.counts(feeds: [feed.id])
            reads.append(await readers.quick.metrics.statementSteps - start)
            #expect(counts[feed.id]?.total == 50 && counts[feed.id]?.favorite == 1, "the backlog never counts")
            try EpisodeListKeysTests.expectExact(url, "backlog \(backlog)")
            await store.closeReaders()
            try await store.close()
        }
        #expect(Double(writes[2]) <= 1.1 * Double(writes[0]) + 16, "favorite toggle VM steps \(writes)")
        #expect(Double(reads[2]) <= 1.1 * Double(reads[0]) + 16, "counts read VM steps \(reads)")
        print("DERIVED budget: favorite toggle steps \(writes), counts read steps \(reads) at hidden backlogs 100/1000/3000")
    }
    /// A real listening checkpoint (`recordPlayback`) costs the same VM steps and pages in a library ten times larger.
    @Test func aListeningCheckpointIsFlatAcrossLibrarySizes() async throws {
        let small = try await Self.checkpointCost(episodes: 1_000), large = try await Self.checkpointCost(episodes: 10_000)
        print("DERIVED budget: a listening checkpoint at 1k/10k episodes: VM steps \(small.steps)/\(large.steps), pages \(small.pages)/\(large.pages)")
        #expect(Self.flat(small, large), "\(small) \(large)")
    }

    /// A derived trigger that scans every key row on each history change: the checkpoint slope gate catches it.
    @Test func theCheckpointGateCatchesALibrarySizedScan() async throws {
        let scan = "CREATE TRIGGER derived_mutation_history_scan AFTER UPDATE OF history_ms ON episode_list_keys WHEN OLD.history_ms IS NOT NEW.history_ms BEGIN SELECT sum(position) FROM episode_list_keys; END"
        let small = try await Self.checkpointCost(episodes: 1_000, extra: scan), large = try await Self.checkpointCost(episodes: 10_000, extra: scan)
        #expect(!Self.flat(small, large), "\(small) \(large)")
        print("MUTATION derived_mutation_history_scan: checkpoint VM steps \(small.steps) at 1k, \(large.steps) at 10k")
    }

    static func flat(_ small: (steps: Int64, pages: Int64), _ large: (steps: Int64, pages: Int64)) -> Bool {
        Double(large.steps) <= 1.1 * Double(small.steps) + 16 && Double(large.pages) <= 1.1 * Double(small.pages) + 16
    }

    /// VM steps and page lookups of the store's connection for one ordinary listening checkpoint (the third save of a
    /// playing session) in a restored library of `episodes`.
    static func checkpointCost(episodes: Int, feeds: Int = 40, extra: String? = nil) async throws -> (steps: Int64, pages: Int64) {
        let directory = try EpisodeListKeysTests.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = feeds == 40 ? try await EpisodeListKeysTests.restoredLibrary(in: directory, episodes: episodes, feeds: 40)
            : try await DerivedScaleTests.restored(in: directory, episodes: episodes, feeds: feeds).0
        let store = try FeedLibraryStore(url: url)
        if let extra { try await store.withDatabaseForTesting { try $0.execute(extra) } }
        let id = Int64(episodes / 2)
        let session = try await store.beginPlayback(episodeID: id)
        let duration = try #require(try await store.episode(id: id)?.details.media?.durationMilliseconds)
        for second in 1...2 {
            _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: Int32(second * 5_000), durationMilliseconds: duration, status: .playing),
                                               now: EpisodeListKeysTests.now.addingTimeInterval(Double(second * 5)))
        }
        let before = try await store.withDatabaseForTesting { ($0.statementSteps, $0.pageLookups) }
        _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 15_000, durationMilliseconds: duration, status: .playing),
                                           now: EpisodeListKeysTests.now.addingTimeInterval(15))
        let after = try await store.withDatabaseForTesting { ($0.statementSteps, $0.pageLookups) }
        try await store.close()
        return (after.0 - before.0, after.1 - before.1)
    }
}
