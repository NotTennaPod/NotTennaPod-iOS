import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Schema 21's derived list keys and counts: the migration creates them empty with no row work, the background fill
/// makes them exact and resumes where it stopped, every writer keeps them exact (a whole-table decoded oracle after each
/// step), a malformed record never blocks a write, and canonical data is byte-for-byte preserved.
@Suite(.serialized) struct EpisodeListKeysTests {
    static let now = Date(timeIntervalSince1970: 1_760_000_000)

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ListKeys-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func fetched(_ source: String, title: String = "Show", count: Int, offset: Int = 0, removing: Set<Int> = []) -> FetchedFeed {
        let items = (1...max(1, count)).filter { !removing.contains($0) }.map { number in
            ParsedEpisode(identifier: "\(source)#\(number + offset)", title: "Episode \(number + offset)", description: "Notes \(number)",
                          publicationDate: now.addingTimeInterval(Double(number + offset) * 3_600 + 0.0005),
                          media: number % 7 == 0 ? nil : ParsedMedia(url: "https://media.example.test/\(number + offset).mp3", size: 1_000,
                                                                     durationMilliseconds: Int32(60_000 + number)))
        }
        return FetchedFeed(feed: ParsedFeed(format: .rss, title: title, episodes: count == 0 ? [] : items), source: source,
                           responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil)
    }

    static func expectExact(_ url: URL, _ step: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let found = try DerivedDataOracle.mismatches(url)
        #expect(found.isEmpty, "\(step): \(found)", sourceLocation: sourceLocation)
    }

    /// The shape of a restored test library of about `episodes` episodes in `feeds` feeds.
    static func shape(episodes: Int, feeds: Int) -> LargeAndroidLibrary.Shape {
        var shape = LargeAndroidLibrary.Shape()
        shape.feeds = feeds; shape.episodes = episodes
        shape.heavyFeeds = 2; shape.heavyEpisodes = episodes / 7
        shape.mediumFeeds = feeds / 4; shape.mediumEpisodes = episodes / (feeds / 4) / 3
        shape.archivedFeeds = 3; shape.previewFeeds = 2; shape.queue = 30; shape.favorites = 40
        shape.chapteredEpisodes = 50; shape.downloadLog = 50
        return shape
    }

    /// A restored Android library (`LargeAndroidLibrary`) of about `episodes` episodes, closed.
    static func restoredLibrary(in directory: URL, episodes: Int = 2_000, feeds: Int = 40) async throws -> URL {
        let backup = directory.appendingPathComponent("backup.db")
        try LargeAndroidLibrary.write(to: backup, shape: shape(episodes: episodes, feeds: feeds))
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let library = try AndroidDatabaseRestore.read(backup, staging: directory.appendingPathComponent("staging"))
        try await store.installRestoredLibrary(library, carrying: try await store.restoreCarryOver())
        try await store.close()
        return url
    }

    // MARK: - A new library

    @Test func aNewLibraryIsCompleteAtOnceAndSeedsItsBookkeeping() async throws {
        let directory = try Self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        #expect(store.derivedReady)
        try await store.waitForDerivedData()
        #expect(try RawLibrary.rows(url, "PRAGMA user_version") == [["22"]])
        #expect(try RawLibrary.rows(url, "SELECT id, seq FROM library_change_sequence") == [["1", "0"]])
        #expect(try RawLibrary.rows(url, "SELECT count(*) FROM derived_fill") == [["0"]])
        #expect(try RawLibrary.rows(url, "SELECT count(*) FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'derived_counts_%'") == [["3"]])
        #expect(try RawLibrary.rows(url, "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name LIKE 'ntp_ledger_%'") == [["3"]])
        // Every library has the hidden-row tables the derived triggers read, empty in a standalone library.
        #expect(try RawLibrary.rows(url, "SELECT count(*) FROM ntp_hidden_feeds") == [["0"]])
        #expect(try RawLibrary.rows(url, "SELECT count(*) FROM ntp_hidden_episodes") == [["0"]])
        let feed = try await store.insert(Self.fetched("https://example.test/a.xml", count: 30), options: .init(now: Self.now))
        try Self.expectExact(url, "subscribe")
        #expect(try DerivedDataOracle.storedKeys(url).count == 30)
        #expect(try DerivedDataOracle.storedCounts(url)[feed.id]?.total == 30)
        try await store.close()
    }

    // MARK: - Migration and fill

    /// A schema-20 library (restored from Android, 2,000 episodes) opened by this build: the migration creates the
    /// tables empty (no row work at open), lists of derived data are not ready, the background fill makes the keys and
    /// counts exactly the reference, and every canonical table keeps its bytes across the migration, the fill and the
    /// read-only paths.
    @Test func aSchema20LibraryMigratesEmptyAndTheFillMakesItExactWithEveryCanonicalByteKept() async throws {
        let directory = try Self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await Self.restoredLibrary(in: directory)
        try DerivedDataOracle.downgradeTo20(url)
        let before = try DerivedDataOracle.canonicalHashes(url)
        let store = try FeedLibraryStore(url: url)
        #expect(!store.derivedReady)
        #expect(try RawLibrary.rows(url, "PRAGMA user_version") == [["22"]])
        #expect(try RawLibrary.rows(url, "SELECT count(*) FROM episode_list_keys") == [["0"]], "no fill work at open")
        #expect(try RawLibrary.rows(url, "SELECT count(*) FROM feed_list_counts") == [["0"]])
        #expect(try RawLibrary.rows(url, "SELECT next_id, end_id FROM derived_fill") == [["\(Int64.min)", "2000"]], "from the start to the last episode now")
        #expect(DerivedDataOracle.byteChanges(before: before, after: try DerivedDataOracle.canonicalHashes(url)) == [], "the migration")
        let readers = try await store.readers()
        await #expect(throws: LibraryReader.Failure.derivedDataNotReady) { try await readers.quick.counts() }
        try await store.fillDerivedData(batch: 300)
        #expect(store.derivedReady)
        try await store.waitForDerivedData()
        try Self.expectExact(url, "after the fill")
        #expect(try DerivedDataOracle.storedKeys(url).count == 2_000)
        #expect(DerivedDataOracle.byteChanges(before: before, after: try DerivedDataOracle.canonicalHashes(url)) == [], "the fill")
        // Read-only paths read; nothing canonical changes.
        let counts = try await readers.quick.counts()
        let headers = try await readers.bulk.listFeedHeaders()
        _ = try await readers.quick.keys(ids: Array(1...200))
        _ = try await readers.bulk.listEpisodes(ids: Array(1...200))
        _ = try await store.snapshot()
        _ = try await store.search(query: "history")
        _ = try await store.statistics()
        #expect(headers.count == 40 && counts.count == 40)
        #expect(DerivedDataOracle.byteChanges(before: before, after: try DerivedDataOracle.canonicalHashes(url)) == [], "read-only paths")
        // The visible counts are the drawer's counters.
        let snapshot = try await store.snapshot()
        for counter in FeedCounter.allCases where counter != .showNone {
            let reference = SubscriptionListQueries.counters(snapshot.feeds, counter)
            for feed in snapshot.feeds where feed.subscriptionState == .subscribed {
                #expect(Int64(reference[feed.id] ?? 0) == counts[feed.id]?.count(for: counter), "\(counter) of feed \(feed.id)")
            }
        }
        await store.closeReaders()
        try await store.close()
    }

    /// An interrupted fill resumes from its marker after a relaunch, and writes made meanwhile keep their own rows.
    @Test func anInterruptedFillResumesWhereItStoppedAndWritesDuringItKeepTheirRows() async throws {
        let directory = try Self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await Self.restoredLibrary(in: directory)
        try DerivedDataOracle.downgradeTo20(url)
        var store = try FeedLibraryStore(url: url)
        for _ in 0..<3 { #expect(try await store.fillDerivedBatch(250) == false) }
        #expect(try RawLibrary.rows(url, "SELECT count(*) FROM episode_list_keys") == [["750"]])
        let cursor = try #require(try RawLibrary.rows(url, "SELECT next_id FROM derived_fill").first?.first ?? nil)
        try Self.expectExact(url, "partial")
        // Writes before and beyond the cursor: their own rows are made or kept by the triggers.
        try await store.setFavorite(episodeID: 10, favorite: true)
        try await store.markEpisodePlayed(episodeID: 1_900, played: true)
        try await store.updateEpisode(id: 1_950) { $0.userState.positionMilliseconds = 4_321 }
        #expect(try DerivedDataOracle.storedKeys(url)[1_950]?.positionMilliseconds == 4_321, "a write beyond the cursor keys its row")
        try Self.expectExact(url, "writes during the fill")
        // A relaunch: the fill resumes from its cursor.
        try await store.close()
        store = try FeedLibraryStore(url: url)
        #expect(!store.derivedReady)
        #expect(try RawLibrary.rows(url, "SELECT next_id FROM derived_fill").first?.first == cursor)
        let feed = try #require(try await store.feeds().first { $0.subscriptionState == .subscribed })
        try await store.requestFeedDeletion(feedID: feed.id)
        try await store.fillDerivedData(batch: 250)
        try Self.expectExact(url, "after the resumed fill")
        #expect(store.derivedReady)
        try await store.close()
    }

    /// Readiness is awaitable by any consumer: a waiter resumes when the fill completes, and a waiter on a library that
    /// closes first is told so (it never reads partial derived data).
    @Test func derivedReadinessIsAwaitable() async throws {
        let directory = try Self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await Self.restoredLibrary(in: directory)
        try DerivedDataOracle.downgradeTo20(url)
        var store = try FeedLibraryStore(url: url)
        let waiting = Task { [store] in try await store.waitForDerivedData(); return store.derivedReady }
        #expect(try await store.fillDerivedBatch(500) == false)
        try await store.fillDerivedData()
        #expect(try await waiting.value, "resumed once complete")
        try await store.close()
        try DerivedDataOracle.downgradeTo20(url)
        store = try FeedLibraryStore(url: url)
        let closing = Task { [store] in try await store.waitForDerivedData() }
        try await store.close()
        await #expect(throws: FeedLibraryError.closed) { try await closing.value }
        let cancelled = Task { [store] in try await store.waitForDerivedData() }
        cancelled.cancel()
        await #expect(throws: (any Error).self) { try await cancelled.value }
    }

    /// The counts are maintained from the migration on: at every fill step they equal the key rows that exist (each
    /// counted once, when it is made, by the fill or by a write), through writes between steps: a feed and episodes born
    /// with IDs behind the fill's cursor, moves, a deletion and reinsertion, a rolled-back insert. The ledger indexes are
    /// built one per step; the marker goes last. Exact again after a relaunch.
    @Test func theCountsEqualTheKeyRowsAtEveryStepWhateverIsWrittenBehindTheCursor() async throws {
        let directory = try Self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await Self.restoredLibrary(in: directory)
        // Two IDs reserved before the update (a server shadow's), used only once the fill has passed them.
        let reservedFeed: Int64 = 1, reservedEpisode: Int64 = 1
        try RawLibrary.execute(url, "DELETE FROM episodes WHERE id IN (1, 3)")
        try DerivedDataOracle.downgradeTo20(url)
        var store = try FeedLibraryStore(url: url)
        let feeds = try RawLibrary.rows(url, "SELECT id FROM feeds ORDER BY id").compactMap { $0[0].flatMap { Int64($0) } }
        #expect(!feeds.contains(reservedFeed))
        let header = try #require(try await store.feeds().first { $0.subscriptionState == .subscribed })
        var keySteps = 0, ledgerSteps = 0, step = 0
        func ledgerIndexes() throws -> [[String?]] {
            try RawLibrary.rows(url, "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name LIKE 'ntp_ledger_%'")
        }
        while true {
            let indexesBefore = try ledgerIndexes()
            let complete = try await store.fillDerivedBatch(400)
            step += 1
            #expect(try RawLibrary.rows(url, "SELECT count(*) FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'derived_counts_%'") == [["3"]])
            try Self.expectExact(url, "step \(step)")
            if complete { break }
            if try ledgerIndexes() != indexesBefore { ledgerSteps += 1 } else { keySteps += 1 }
            switch step {
            case 2:
                // The reserved feed and its episode arrive behind the cursor.
                var reserved = header
                reserved.id = reservedFeed; reserved.source = "https://example.test/reserved.xml"; reserved.episodes = []
                var episode = try #require(try await store.episode(id: 2))
                episode.id = reservedEpisode; episode.details.identifier = "reserved"; episode.userState.isFavorite = true
                try DerivedDataOracle.write(url, [("BEGIN", []), ("INSERT INTO feeds(id, title, record) VALUES (?, 'Reserved', ?)", [.integer(reservedFeed), .blob(try CanonicalPreservationTests.encode(reserved))]),
                                                  ("INSERT INTO episodes(id, feed_id, pubdate, record) VALUES (?, ?, 0, ?)", [.integer(reservedEpisode), .integer(reservedFeed), .blob(try DerivedDataOracle.record(episode))]),
                                                  ("COMMIT", [])])
            case 3:
                // Moves across the cursor, a deletion and reinsertion behind it, a rolled-back insert.
                try DerivedDataOracle.write(url, "UPDATE episodes SET feed_id = ? WHERE id = ?", [.integer(reservedFeed), .integer(1_990)])
                try DerivedDataOracle.write(url, "UPDATE episodes SET feed_id = ? WHERE id = ?", [.integer(feeds[0]), .integer(5)])
                let removed = try #require(try await store.episode(id: 7))
                let feedOf7 = try await store.feedID(forEpisode: 7)
                try DerivedDataOracle.write(url, "DELETE FROM episodes WHERE id = 7")
                try DerivedDataOracle.write(url, "INSERT INTO episodes(id, feed_id, pubdate, record) VALUES (7, ?, 0, ?)", [.integer(feedOf7), .blob(try DerivedDataOracle.record(removed))])
                try DerivedDataOracle.write(url, [("BEGIN", []), ("INSERT INTO episodes(id, feed_id, pubdate, record) VALUES (3, ?, 0, ?)", [.integer(feeds[1]), .blob(try DerivedDataOracle.record(removed))]),
                                                  ("ROLLBACK", [])])
            case 4:
                try await store.setFavorite(episodeID: 1_999, favorite: true)
                try await store.markEpisodePlayed(episodeID: 10, played: true)
            default: break
            }
        }
        #expect(keySteps >= 4 && ledgerSteps == 3, "key steps \(keySteps), one step per ledger index (\(ledgerSteps))")
        let readers = try await store.readers()
        #expect(try await readers.quick.counts(feeds: [reservedFeed])[reservedFeed]?.total == 2, "the reserved feed's episode and the moved one")
        await store.closeReaders()
        try await store.close()
        store = try FeedLibraryStore(url: url)
        #expect(store.derivedReady)
        try Self.expectExact(url, "reopened")
        #expect(try await store.derivedDiscrepancies() == [])
        try await store.close()
    }

    /// A library with no episodes is complete at its migration only when its release ledger is empty too; a populated
    /// ledger's indexes are built by the fill, one per step, never at open.
    @Test func aLibraryWithoutEpisodesButWithALedgerBuildsItsIndexesInTheFill() async throws {
        let directory = try Self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        try await FeedLibraryStore(url: url).close()
        try DerivedDataOracle.downgradeTo20(url)
        try RawLibrary.execute(url, "DROP INDEX IF EXISTS ntp_ledger_pending; DROP INDEX IF EXISTS ntp_ledger_unnotified; DROP INDEX IF EXISTS ntp_ledger_pending_occurrence; "
                               + "INSERT INTO ntp_ledger(generation_id, occurrence, state, notified) VALUES ('g', 'o1', 'pending', 0), ('g', 'o2', 'done', 1)")
        let store = try FeedLibraryStore(url: url)
        #expect(!store.derivedReady)
        #expect(try RawLibrary.rows(url, "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name LIKE 'ntp_ledger_%'") == [["0"]], "nothing built at open")
        var steps = 0
        while try await !store.fillDerivedBatch(1_000) { steps += 1 }
        #expect(steps == 3 && store.derivedReady)
        #expect(try RawLibrary.rows(url, "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name LIKE 'ntp_ledger_%'") == [["3"]])
        try await store.close()
    }

    /// A failed fill step is reported and retried; readiness and its waiters wait for the retry that succeeds.
    @Test func aFailedFillStepIsReportedAndRetried() async throws {
        let directory = try Self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await Self.restoredLibrary(in: directory)
        try DerivedDataOracle.downgradeTo20(url)
        let store = try FeedLibraryStore(url: url)
        try await store.withDatabaseForTesting { database in
            try database.execute("CREATE TEMP TABLE fail_fill (x)")
            try database.execute("INSERT INTO temp.fail_fill VALUES (1)")
            try database.execute("CREATE TEMP TRIGGER fail_key BEFORE INSERT ON main.episode_list_keys WHEN EXISTS (SELECT 1 FROM temp.fail_fill) BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        }
        final class Failures: @unchecked Sendable { let count = Mutex(0) }
        let failures = Failures()
        let fill = Task { try await store.fillDerivedData(batch: 300, retryDelay: .milliseconds(5), onFailure: { _ in failures.count.withLock { $0 += 1 } }) }
        let waiter = Task { try await store.waitForDerivedData(); return store.derivedReady }
        while failures.count.withLock({ $0 }) < 2 { await Task.yield() }
        #expect(!store.derivedReady && store.derived.failure?.contains("injected failure") == true, "reported, not ready")
        try await store.withDatabaseForTesting { try $0.execute("DELETE FROM temp.fail_fill") }
        try await fill.value
        #expect(try await waiter.value, "the waiter resumes once a retry succeeds")
        #expect(store.derived.failure == nil)
        try Self.expectExact(url, "after the retry")
        try await store.close()
    }

    /// The disk the derived data adds depends on the text it keeps (titles, GUIDs, media addresses, file names): with
    /// long, realistic values it stays within a fixed part plus what that text takes in its row and its indexes.
    @Test func theAddedSizeFollowsTheKeptText() async throws {
        let directory = try Self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let feed = try await store.insert(Self.fetched("https://example.test/size.xml", count: 1), options: .init(now: Self.now))
        try await store.close()
        let title = String(repeating: "Long episode title ", count: 8).prefix(156)
        let guid = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"
        let media = "https://media.example.test/" + String(repeating: "path/segment-", count: 17).prefix(218)
        let file = "/var/mobile/Containers/Data/Application/library/media/" + String(repeating: "f", count: 46) + ".mp3"
        var statements: [(String, [LibrarySQLValue])] = [("BEGIN", [])]
        var template = feed.episodes[0]
        for number in 0..<3_000 {
            template.id = 10_000 + Int64(number)
            template.details.title = String(title.dropLast(5)) + "\(number + 10_000)"
            template.details.identifier = String(guid.dropLast(5)) + "\(number + 10_000)"
            template.details.media?.url = String(media.dropLast(5)) + "\(number + 10_000)"
            template.userState.localFileURL = number.isMultiple(of: 2) ? String(file.dropLast(9)) + "\(number + 10_000).mp3" : nil
            template.details.description = String(repeating: "notes ", count: 200)
            statements.append(("INSERT INTO episodes(id, feed_id, pubdate, record) VALUES (?, ?, 0, ?)", [.integer(template.id), .integer(feed.id), .blob(try DerivedDataOracle.record(template))]))
        }
        statements.append(("COMMIT", []))
        try DerivedDataOracle.write(url, statements)
        try DerivedDataOracle.downgradeTo20(url)
        try RawLibrary.execute(url, "VACUUM")
        let before = try DerivedScaleTests.bytes(url)
        let migrated = try FeedLibraryStore(url: url)
        try await migrated.fillDerivedData()
        try await migrated.close()
        let perEpisode = Double(try DerivedScaleTests.bytes(url) - before) / 3_001
        // Kept text per episode: the title in the row; the GUID and media address in the row and their indexes; the file
        // name (about 50 B, half the episodes) in the row and its index.
        let text = Double(title.utf8.count + 2 * (guid.utf8.count + media.utf8.count) + 50)
        print("DERIVED size with long text: \(Int(perEpisode)) B/episode (kept text about \(Int(text)) B)")
        #expect(perEpisode <= DerivedScaleTests.sizeBudget(textBytes: text), "\(perEpisode) B/episode")
        try Self.expectExact(url, "long text")
    }

    /// A restart during the fill, with a pending cleanup whose surviving owner lies beyond the fill cursor. Until
    /// the fill completes no reader serves the partial keys, the existing (canonical) cleanup keeps the shared file, and
    /// the pending work and requests stay as they were; the completed keys then name the owner's file.
    @Test func aRestartDuringTheFillKeepsAFileAnEpisodeBeyondTheCursorOwns() async throws {
        let directory = try Self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        var store = try FeedLibraryStore(url: url)
        let source = "https://example.test/shared.xml"
        let feed = try await store.insert(Self.fetched(source, count: 1_200), options: .init(now: Self.now))
        let ids = feed.episodes.map(\.id).sorted()
        let removed = ids[0], owner = ids[1_100]
        let file = directory.appendingPathComponent("media/shared.mp3")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: file)
        for id in [removed, owner] {
            try await store.updateEpisode(id: id) { $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path }
        }
        _ = try await store.enqueue([ids[5]])
        // A refresh no longer lists the first episode: its removal leaves a pending cleanup of the shared file.
        var removing = FeedRefreshOptions(now: Self.now.addingTimeInterval(60))
        removing.removeUnlistedItems = true
        let remaining = feed.episodes.filter { $0.id != removed }.map(\.details)
        _ = try await store.applyRefresh(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Show", episodes: remaining), source: source,
                                                     responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil),
                                         feedID: feed.id, options: removing)
        let effect = try #require(try await store.pendingEffects().first { if case .removeEpisodes = $0.effect.kind { true } else { false } })
        try await store.close()
        // The update: schema 20 → 21, a first batch, then the app is killed.
        try DerivedDataOracle.downgradeTo20(url)
        store = try FeedLibraryStore(url: url)
        #expect(try await store.fillDerivedBatch(500) == false)
        try await store.close()
        let pending = try RawLibrary.rows(url, "SELECT id, kind, hex(record) FROM pending_effects ORDER BY id")
        let requests = try RawLibrary.rows(url, "SELECT * FROM queue_work"), queue = try RawLibrary.rows(url, "SELECT * FROM queue ORDER BY position")
        // The relaunch, before the fill completes.
        store = try FeedLibraryStore(url: url)
        #expect(!store.derivedReady)
        #expect(try DerivedDataOracle.storedKeys(url)[owner] == nil, "the owner lies beyond the fill cursor")
        let readers = try await store.readers()
        await #expect(throws: LibraryReader.Failure.derivedDataNotReady) { try await readers.quick.keys(ids: [owner]) }
        await #expect(throws: LibraryReader.Failure.derivedDataNotReady) { try await readers.bulk.counts(feeds: [feed.id]) }
        // The cleanup runs on the canonical tables: the surviving owner keeps the file.
        try await store.removeFilesForRemovedEpisodes(effectID: effect.id) { try FileManager.default.removeItem(at: $0) }
        #expect(FileManager.default.fileExists(atPath: file.path), "the file the owner still names survives")
        #expect(try RawLibrary.rows(url, "SELECT id, kind, hex(record) FROM pending_effects ORDER BY id") == pending)
        #expect(try RawLibrary.rows(url, "SELECT * FROM queue_work") == requests && RawLibrary.rows(url, "SELECT * FROM queue ORDER BY position") == queue)
        // Once complete, the keys name the owner's file.
        try await store.fillDerivedData()
        try Self.expectExact(url, "complete")
        let keys = try await readers.quick.keys(ids: [owner])
        #expect(keys.first?.localFileName == "shared.mp3" && keys.first?.isDownloaded == true)
        await store.closeReaders()
        try await store.close()
    }

    // MARK: - Writers

    /// Every standalone writer path keeps the keys and counts exact (whole-table oracle after each step), with the
    /// store's own invariant check on every commit.
    @Test func everyStandaloneWriterKeepsTheKeysAndCountsExact() async throws {
        let directory = try Self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        await store.verifyDerivedDataOnCommit()
        let a = try await store.insert(Self.fetched("https://example.test/a.xml", title: "A", count: 40), options: .init(now: Self.now))
        let b = try await store.insert(Self.fetched("https://example.test/b.xml", title: "B", count: 25), options: .init(now: Self.now))
        try Self.expectExact(url, "subscribe")
        let preview = try await store.preparePreview(Self.fetched("https://example.test/p.xml", title: "P", count: 5), now: Self.now)
        try Self.expectExact(url, "preview")
        #expect(try DerivedDataOracle.storedKeys(url).values.filter { $0.feedID == preview.id }.allSatisfy { !$0.feedEligible })
        try await store.subscribePreview(feedID: preview.id, now: Self.now)
        try Self.expectExact(url, "subscribe a preview")
        // Refreshes: one new episode, changed metadata, then removal of unlisted episodes.
        _ = try await store.applyRefresh(Self.fetched("https://example.test/a.xml", title: "A", count: 41), feedID: a.id, options: .init(now: Self.now))
        try Self.expectExact(url, "refresh adds one")
        var changed = Self.fetched("https://example.test/a.xml", title: "A", count: 41)
        changed.feed.episodes[3].title = "Renamed"; changed.feed.episodes[4].publicationDate = Self.now.addingTimeInterval(-0.0005)
        changed.feed.episodes[5].media?.durationMilliseconds = 0
        _ = try await store.applyRefresh(changed, feedID: a.id, options: .init(now: Self.now))
        try Self.expectExact(url, "refresh changes metadata")
        var removing = FeedRefreshOptions(now: Self.now)
        removing.removeUnlistedItems = true
        _ = try await store.applyRefresh(Self.fetched("https://example.test/b.xml", title: "B", count: 25, removing: [2, 3, 4]), feedID: b.id, options: removing)
        try Self.expectExact(url, "refresh removes three")
        // User state through the store's writers.
        let ids = try await store.feed(id: a.id)!.episodes.map(\.id).sorted()
        try await store.setFavorite(episodeID: ids[0], favorite: true)
        try await store.markEpisodePlayed(episodeID: ids[1], played: true)
        try await store.markEpisodePlayed(episodeID: ids[1], played: false)
        _ = try await store.enqueue([ids[2], ids[3]])
        _ = try await store.removeFeedFromInbox(feedID: a.id)
        try Self.expectExact(url, "marks")
        try await store.updateEpisode(id: ids[6]) { $0.userState.isDownloaded = true; $0.userState.localFileURL = "/x/y/z.mp3"; $0.userState.downloadDate = Self.now }
        try Self.expectExact(url, "download")
        let session = try await store.beginPlayback(episodeID: ids[7])
        _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 5_000, durationMilliseconds: 90_000, status: .playing), now: Self.now)
        _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 10_000, durationMilliseconds: 90_000, status: .playing), now: Self.now.addingTimeInterval(5))
        try Self.expectExact(url, "listening")
        // Archive and restore of the subscription, a pinned removal set and released.
        try await store.updatePreferences(feedID: b.id) { $0.subscriptionState = .archived }
        try Self.expectExact(url, "archive")
        try await store.updatePreferences(feedID: b.id) { $0.subscriptionState = .subscribed }
        try DerivedDataOracle.write(url, "INSERT INTO pinned_feed_removals(feed_id) VALUES (?)", [.integer(b.id)])
        try Self.expectExact(url, "pinned removal")
        try DerivedDataOracle.write(url, "DELETE FROM pinned_feed_removals WHERE feed_id = ?", [.integer(b.id)])
        try Self.expectExact(url, "pinned removal released")
        // Raw writers: Keep's record-only update, a feed move, savepoint and full rollbacks.
        var episode = try #require(try await store.episode(id: ids[8]))
        episode.userState.positionMilliseconds = 777; episode.userState.lastPlayedHistoryMilliseconds = 1
        try DerivedDataOracle.write(url, "UPDATE episodes SET record = ? WHERE id = ?", [.blob(try DerivedDataOracle.record(episode)), .integer(ids[8])])
        try Self.expectExact(url, "record-only update")
        try DerivedDataOracle.write(url, "UPDATE episodes SET feed_id = ? WHERE id = ?", [.integer(b.id), .integer(ids[9])])
        try Self.expectExact(url, "feed move")
        try await store.updatePreferences(feedID: a.id) { $0.subscriptionState = .archived }
        try DerivedDataOracle.write(url, "UPDATE episodes SET feed_id = ? WHERE id = ?", [.integer(a.id), .integer(ids[9])])
        try Self.expectExact(url, "move to an archived feed")
        episode.userState.isFavorite = true
        let favorite = try DerivedDataOracle.record(episode)
        episode.userState.playState = .new
        try DerivedDataOracle.write(url, [("BEGIN", []), ("UPDATE episodes SET record = ? WHERE id = ?", [.blob(favorite), .integer(ids[8])]),
                                          ("SAVEPOINT s", []), ("UPDATE episodes SET record = ? WHERE id = ?", [.blob(try DerivedDataOracle.record(episode)), .integer(ids[8])]),
                                          ("DELETE FROM episodes WHERE id = ?", [.integer(ids[10])]),
                                          ("ROLLBACK TO s", []), ("RELEASE s", []), ("COMMIT", [])])
        try Self.expectExact(url, "savepoint rollback")
        #expect(try DerivedDataOracle.storedKeys(url)[ids[8]]?.isFavorite == true && DerivedDataOracle.storedKeys(url)[ids[10]] != nil)
        try DerivedDataOracle.write(url, [("BEGIN", []), ("DELETE FROM episodes WHERE feed_id = ?", [.integer(b.id)]), ("ROLLBACK", [])])
        try Self.expectExact(url, "full rollback")
        // A REPLACE (banned in production; still exact) and an episode deletion and a feed deletion's cascade.
        let replaced = try #require(try await store.episode(id: ids[11]))
        var toggled = replaced; toggled.userState.isFavorite.toggle(); toggled.userState.playState = .played
        try DerivedDataOracle.write(url, "INSERT OR REPLACE INTO episodes(id, feed_id, pubdate, record) VALUES (?, ?, 0, ?)",
                                    [.integer(ids[11]), .integer(a.id), .blob(try DerivedDataOracle.record(toggled))])
        try Self.expectExact(url, "replace")
        try DerivedDataOracle.write(url, "DELETE FROM episodes WHERE id = ?", [.integer(ids[12])])
        try Self.expectExact(url, "episode delete")
        try await store.requestFeedDeletion(feedID: b.id)
        try Self.expectExact(url, "feed delete")
        #expect(try RawLibrary.rows(url, "SELECT count(*) FROM feed_list_counts WHERE feed_id = \(b.id)") == [["0"]])
        try await store.close()
    }

    static let derivedTriggerCount = LibrarySchema21.keyTriggers.count + LibrarySchema21.visibilityTriggers.count + LibrarySchema21.countTriggers.count

    /// A database import (`installRestoredLibrary`) keys every row it writes in its own transaction (one rebuild at its
    /// end, with every trigger back); a failed import rolls the whole of it back, its triggers included.
    @Test func aRestoreKeysEveryRowItWritesAndAFailedOneLeavesTheTriggers() async throws {
        let directory = try Self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await Self.restoredLibrary(in: directory)
        #expect(try DerivedDataOracle.isComplete(url))
        try Self.expectExact(url, "restore")
        #expect(try RawLibrary.rows(url, "SELECT count(*) FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'derived_%'") == [["\(Self.derivedTriggerCount)"]])
        // A restore whose second feed cannot be written (an episode without a date): nothing of it stays.
        let failing = directory.appendingPathComponent("failing.sqlite")
        let store = try FeedLibraryStore(url: failing)
        let first = LibraryFeed(id: 1, source: "https://example.test/one.xml", metadata: ParsedFeed(format: .rss, title: "One"),
                                episodes: [LibraryEpisode(id: 1, details: ParsedEpisode(identifier: "a", publicationDate: Self.now))])
        let second = LibraryFeed(id: 2, source: "https://example.test/two.xml", metadata: ParsedFeed(format: .rss, title: "Two"),
                                 episodes: [LibraryEpisode(id: 2, details: ParsedEpisode(identifier: "b"))])
        let library = AndroidDatabaseRestore.Library(feeds: [first, second], queue: [], credentials: [:], feedSpeeds: [:], feedSilence: [:],
                                                     downloadLog: [], skipped: [:], sourceVersion: 3_110_000)
        await #expect(throws: FeedLibraryError.invalidMutation) { try await store.installRestoredLibrary(library, carrying: try await store.restoreCarryOver()) }
        #expect(try RawLibrary.rows(failing, "SELECT count(*) FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'derived_%'") == [["\(Self.derivedTriggerCount)"]])
        #expect(try RawLibrary.rows(failing, "SELECT count(*) FROM derived_fill") == [["0"]] && store.derivedReady)
        _ = try await store.insert(Self.fetched("https://example.test/after.xml", count: 3), options: .init(now: Self.now))
        try Self.expectExact(failing, "after a failed restore")
        try await store.close()
    }

    /// Keep's conversion rewrites records directly (`UPDATE episodes SET record`): their keys follow.
    @Test func keepsDirectRecordRewriteKeepsTheKeysExact() async throws {
        let directory = try Self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let feed = try await store.insert(Self.fetched("https://example.test/k.xml", count: 10), options: .init(now: Self.now))
        for id in feed.episodes.map(\.id).prefix(4) {
            try await store.updateEpisode(id: id) { $0.userState.playedHereMilliseconds = 5; $0.userState.positionMilliseconds = 9 }
        }
        try await store.close()
        let database = try LibrarySQLite(url: url)
        try database.transaction { try LibraryKeep.convert(database, operation: "keep-test") }
        try database.close()
        #expect(try RawLibrary.rows(url, "SELECT count(*) FROM episodes WHERE instr(CAST(record AS TEXT), 'playedHereMilliseconds') > 0") == [["0"]])
        try Self.expectExact(url, "keep conversion")
    }

    // MARK: - Malformed records

    /// A record that is not valid JSON commits (its keys defaulted), and decoding it fails as before; a malformed feed
    /// header makes its episodes ineligible without blocking the write.
    @Test func aMalformedRecordNeverBlocksAWrite() async throws {
        let directory = try Self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let feed = try await store.insert(Self.fetched("https://example.test/m.xml", count: 5), options: .init(now: Self.now))
        let id = feed.episodes[0].id
        try await store.setFavorite(episodeID: id, favorite: true)
        try DerivedDataOracle.write(url, "UPDATE episodes SET record = CAST('{not json' AS BLOB) WHERE id = ?", [.integer(id)])
        let keys = try #require(try DerivedDataOracle.storedKeys(url)[id])
        #expect(keys == EpisodeListKeys.malformed(id: id, feedID: feed.id, hidden: false, feedEligible: true))
        try Self.expectExact(url, "malformed episode")
        await #expect(throws: (any Error).self) { try await store.episode(id: id) }
        try DerivedDataOracle.write(url, "INSERT INTO episodes(id, feed_id, pubdate, record) VALUES (900001, ?, 0, X'00FF')", [.integer(feed.id)])
        try DerivedDataOracle.write(url, "UPDATE feeds SET record = CAST('[' AS BLOB) WHERE id = ?", [.integer(feed.id)])
        #expect(try DerivedDataOracle.storedKeys(url).values.filter { $0.feedID == feed.id }.allSatisfy { !$0.feedEligible })
        try DerivedDataOracle.write(url, "UPDATE episodes SET record = ? WHERE id = ?", [.blob(try DerivedDataOracle.record(feed.episodes[0])), .integer(id)])
        let restored = try #require(try DerivedDataOracle.storedKeys(url)[id])
        #expect(!restored.isFavorite && restored.title == feed.episodes[0].details.title && !restored.feedEligible)
        try Self.expectExact(url, "valid again")
        try await store.close()
    }

    // MARK: - Hidden rows and eligibility

    /// The transactional hidden flag: a marker before its row, after it, a reveal, a hidden row's update, move and
    /// deletion, rollbacks, and a staging's take-out, with counts that never include a hidden row.
    @Test func hiddenRowsFollowTheirMarkersAndNeverCount() async throws {
        let directory = try Self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let a = try await store.insert(Self.fetched("https://example.test/h.xml", title: "H", count: 6), options: .init(now: Self.now))
        let b = try await store.insert(Self.fetched("https://example.test/i.xml", title: "I", count: 2), options: .init(now: Self.now))
        try await store.close()
        var staged = a.episodes[0]
        staged.id = 800_001; staged.details.identifier = "staged"; staged.userState.playState = .new; staged.userState.isFavorite = true
        // Marker before its row (as staging inserts them).
        try DerivedDataOracle.write(url, [("BEGIN", []), ("INSERT INTO ntp_hidden_episodes(episode_id, feed_id, seq) VALUES (800001, ?, 1)", [.integer(a.id)]),
                                          ("INSERT INTO episodes(id, feed_id, pubdate, record) VALUES (800001, ?, 0, ?)", [.integer(a.id), .blob(try DerivedDataOracle.record(staged))]),
                                          ("COMMIT", [])])
        try Self.expectExact(url, "marker before row")
        #expect(try DerivedDataOracle.storedKeys(url)[800_001]?.hidden == true)
        #expect(try DerivedDataOracle.storedCounts(url)[a.id]?.total == 6, "the hidden row does not count")
        // A marker after its row, the hidden row updated and moved, then rolled-back reveals.
        try DerivedDataOracle.write(url, "INSERT INTO ntp_hidden_episodes(episode_id, feed_id, seq) VALUES (?, ?, 2)", [.integer(a.episodes[1].id), .integer(a.id)])
        try Self.expectExact(url, "marker after row")
        staged.userState.isDownloaded = true
        try DerivedDataOracle.write(url, "UPDATE episodes SET record = ? WHERE id = 800001", [.blob(try DerivedDataOracle.record(staged))])
        try DerivedDataOracle.write(url, "UPDATE episodes SET feed_id = ? WHERE id = 800001", [.integer(b.id)])
        try Self.expectExact(url, "hidden row updated and moved")
        try DerivedDataOracle.write(url, [("BEGIN", []), ("DELETE FROM ntp_hidden_episodes", []), ("ROLLBACK", [])])
        try DerivedDataOracle.write(url, [("BEGIN", []), ("SAVEPOINT s", []), ("DELETE FROM ntp_hidden_episodes WHERE episode_id = 800001", []),
                                          ("ROLLBACK TO s", []), ("RELEASE s", []), ("COMMIT", [])])
        try Self.expectExact(url, "rolled-back reveals")
        #expect(try DerivedDataOracle.storedKeys(url)[800_001]?.hidden == true)
        // A reveal (the unit's), then a staging taken out (rows that were never shown).
        try DerivedDataOracle.write(url, "DELETE FROM ntp_hidden_episodes WHERE episode_id = ?", [.integer(a.episodes[1].id)])
        try Self.expectExact(url, "reveal")
        try DerivedDataOracle.write(url, [("BEGIN", []), ("DELETE FROM episodes WHERE id IN (SELECT episode_id FROM ntp_hidden_episodes)", []),
                                          ("DELETE FROM ntp_hidden_episodes", []), ("COMMIT", [])])
        try Self.expectExact(url, "take-out")
        #expect(try DerivedDataOracle.storedKeys(url)[800_001] == nil)
    }

    /// Eligibility follows subscription and every visibility source, including overlapping ones and the server's pinned
    /// removal on its podcast row (inserted, updated, moved and deleted).
    @Test func eligibilityFollowsSubscriptionAndEveryVisibilitySource() async throws {
        let directory = try Self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let a = try await store.insert(Self.fetched("https://example.test/e.xml", title: "E", count: 8), options: .init(now: Self.now))
        let b = try await store.insert(Self.fetched("https://example.test/f.xml", title: "F", count: 3), options: .init(now: Self.now))
        func eligible() throws -> Set<Int64> {
            Set(try DerivedDataOracle.storedKeys(url).values.filter(\.feedEligible).map(\.feedID))
        }
        #expect(try eligible() == [a.id, b.id])
        try await store.updatePreferences(feedID: a.id) { $0.subscriptionState = .archived }
        try Self.expectExact(url, "archived"); #expect(try eligible() == [b.id])
        try await store.updatePreferences(feedID: a.id) { $0.subscriptionState = .subscribed }
        try Self.expectExact(url, "subscribed again"); #expect(try eligible() == [a.id, b.id])
        // Hidden while staged (left out when read, its rows untouched), overlapping with a pinned removal, each released.
        let before = try DerivedDataOracle.storedKeys(url)
        try DerivedDataOracle.write(url, "INSERT INTO ntp_hidden_feeds(feed_id, podcast_id, state, seq) VALUES (?, 'p', 'staging', 1)", [.integer(a.id)])
        #expect(try DerivedDataOracle.storedKeys(url) == before, "hiding a podcast rewrites none of its rows")
        let readers = try await store.readers()
        let shownCounts = try await readers.quick.counts().keys.sorted(), shownHeaders = try await readers.bulk.listFeedHeaders().map(\.id)
        #expect(shownCounts == [b.id] && shownHeaders == [b.id], "but no list shows it")
        try DerivedDataOracle.write(url, "INSERT INTO pinned_feed_removals(feed_id) VALUES (?)", [.integer(a.id)])
        try Self.expectExact(url, "hidden and pinned"); #expect(try eligible() == [b.id])
        try DerivedDataOracle.write(url, "DELETE FROM ntp_hidden_feeds WHERE feed_id = ?", [.integer(a.id)])
        try Self.expectExact(url, "still pinned"); #expect(try eligible() == [b.id])
        try DerivedDataOracle.write(url, "DELETE FROM pinned_feed_removals WHERE feed_id = ?", [.integer(a.id)])
        try Self.expectExact(url, "released"); #expect(try eligible() == [a.id, b.id])
        #expect(try await readers.quick.counts().keys.sorted() == [a.id, b.id].sorted())
        await store.closeReaders()
        // The server's pinned removal on its podcast row: inserted, moved to another feed, cleared, deleted.
        try DerivedDataOracle.write(url, "INSERT INTO ntp_podcasts(podcast_id, feed_id, pinned_removal) VALUES ('p1', ?, 1)", [.integer(a.id)])
        try Self.expectExact(url, "podcast pinned"); #expect(try eligible() == [b.id])
        try DerivedDataOracle.write(url, "UPDATE ntp_podcasts SET feed_id = ? WHERE podcast_id = 'p1'", [.integer(b.id)])
        try Self.expectExact(url, "mapping moved"); #expect(try eligible() == [a.id])
        try DerivedDataOracle.write(url, "UPDATE ntp_podcasts SET pinned_removal = 0 WHERE podcast_id = 'p1'")
        try Self.expectExact(url, "cleared"); #expect(try eligible() == [a.id, b.id])
        try DerivedDataOracle.write(url, "UPDATE ntp_podcasts SET pinned_removal = 1 WHERE podcast_id = 'p1'")
        try DerivedDataOracle.write(url, "DELETE FROM ntp_podcasts WHERE podcast_id = 'p1'")
        try Self.expectExact(url, "deleted"); #expect(try eligible() == [a.id, b.id])
        // An episode moved to an archived parent.
        try await store.updatePreferences(feedID: b.id) { $0.subscriptionState = .archived }
        try DerivedDataOracle.write(url, "UPDATE episodes SET feed_id = ? WHERE id = ?", [.integer(b.id), .integer(a.episodes[0].id)])
        try Self.expectExact(url, "moved to an archived parent")
        #expect(try DerivedDataOracle.storedKeys(url)[a.episodes[0].id]?.feedEligible == false)
        try await store.close()
    }

    // MARK: - details_generation

    @Test func detailsGenerationMovesWithDetailsNeverWithUserState() async throws {
        let directory = try Self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let a = try await store.insert(Self.fetched("https://example.test/d.xml", count: 4), options: .init(now: Self.now))
        let b = try await store.insert(Self.fetched("https://example.test/g.xml", title: "G", count: 2), options: .init(now: Self.now))
        func generation(_ feed: Int64) throws -> Int64 {
            Int64(try RawLibrary.rows(url, "SELECT details_generation FROM feed_changes WHERE feed_id = \(feed)").first?.first.flatMap { $0 }.flatMap { Int64($0) } ?? -1)
        }
        let start = try generation(a.id)
        #expect(start == 4, "each inserted episode")
        let id = a.episodes[0].id
        try await store.setFavorite(episodeID: id, favorite: true)
        try await store.updateEpisode(id: id) { $0.userState.positionMilliseconds = 10; $0.userState.lastPlayedHistoryMilliseconds = 5 }
        #expect(try generation(a.id) == start, "user state never bumps it")
        try await store.updateEpisode(id: id) { $0.details.description = "Changed" }
        #expect(try generation(a.id) == start + 1)
        try await store.updateEpisode(id: id) { $0.hasStoredChapters = true }
        #expect(try generation(a.id) == start + 2)
        try DerivedDataOracle.write(url, "UPDATE episodes SET feed_id = ? WHERE id = ?", [.integer(b.id), .integer(id)])
        #expect(try generation(a.id) == start + 3 && generation(b.id) == 3)
        try DerivedDataOracle.write(url, "DELETE FROM episodes WHERE id = ?", [.integer(id)])
        #expect(try generation(b.id) == 4)
        // The memo goes with its feed.
        try DerivedDataOracle.write(url, "INSERT INTO feed_refresh_memo(feed_id, details_generation) VALUES (?, 1)", [.integer(b.id)])
        try await store.requestFeedDeletion(feedID: b.id)
        #expect(try RawLibrary.rows(url, "SELECT count(*) FROM feed_refresh_memo") == [["0"]])
        try await store.close()
    }

    // MARK: - REPLACE guard

    /// No production statement replaces rows of `episodes` or `feeds` (a REPLACE skips delete triggers).
    @Test func noProductionSQLReplacesEpisodesOrFeeds() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources").standardized
        var offenders: [String] = []
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            offenders += Self.replacements(in: text).map { "\(file.lastPathComponent): \($0)" }
        }
        #expect(offenders.isEmpty, "\(offenders)")
        // The scanner itself finds each banned form.
        for banned in ["INSERT OR REPLACE INTO episodes(id) VALUES (1)", "REPLACE INTO feeds VALUES (1)", "insert or replace into main.episodes",
                       "UPDATE OR REPLACE episodes SET id = 2"] {
            #expect(!Self.replacements(in: "x(\"\(banned)\")").isEmpty, "\(banned)")
        }
    }

    static func replacements(in text: String) -> [String] {
        let pattern = #"(?i)(\bREPLACE\s+INTO|\bOR\s+REPLACE\s+INTO|\bUPDATE\s+OR\s+REPLACE)\s+(main\.)?"?(episodes|feeds)\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return ["bad pattern"] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// The store's commit-time invariant catches derived data that no longer matches its records (any cause), and the
    /// write that would commit on it fails.
    @Test func theCommitInvariantRefusesDriftedDerivedData() async throws {
        let directory = try Self.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        await store.verifyDerivedDataOnCommit()
        let feed = try await store.insert(Self.fetched("https://example.test/v.xml", count: 3), options: .init(now: Self.now))
        try DerivedDataOracle.write(url, "UPDATE feed_list_counts SET favorite = favorite + 1 WHERE feed_id = ?", [.integer(feed.id)])
        await #expect(throws: (any Error).self) { try await store.setFavorite(episodeID: feed.episodes[0].id, favorite: true) }
        #expect(try await store.derivedDiscrepancies() == ["counts differ for feed \(feed.id)"])
        try DerivedDataOracle.write(url, "UPDATE feed_list_counts SET favorite = favorite - 1 WHERE feed_id = ?", [.integer(feed.id)])
        try DerivedDataOracle.write(url, "UPDATE episode_list_keys SET position = 99 WHERE id = ?", [.integer(feed.episodes[1].id)])
        #expect(try await store.derivedDiscrepancies() == ["keys differ for episode \(feed.episodes[1].id)"])
        try DerivedDataOracle.write(url, "UPDATE episode_list_keys SET position = 0 WHERE id = ?", [.integer(feed.episodes[1].id)])
        try await store.setFavorite(episodeID: feed.episodes[0].id, favorite: true)
        #expect(try await store.derivedDiscrepancies() == [])
        try await store.close()
    }
}
