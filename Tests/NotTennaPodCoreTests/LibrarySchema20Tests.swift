import Foundation
import SQLite3
import Testing
@testable import NotTennaPodCore

/// Raw SQL on a library file, as another process or an older build would see it.
enum RawLibrary {
    static func execute(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { throw FeedLibraryError.invalidLocation }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 5_000)
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(message)
            throw FeedLibraryError.sqlite(code: -1, message: text)
        }
    }

    static func rows(_ url: URL, _ sql: String) throws -> [[String?]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { throw FeedLibraryError.invalidLocation }
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FeedLibraryError.sqlite(code: -1, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        var result: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) }
            })
        }
        return result
    }

    /// Takes a schema-20 library back to schema 19, as an older build left it.
    static func downgradeTo19(_ url: URL) throws {
        try execute(url, "DROP TABLE library_identity; DROP TABLE statistics_units; DROP TABLE pinned_feed_removals; PRAGMA user_version = 19;")
    }

    static func insertUnit(_ url: URL, episode: Int64, unit: String, played: Int64 = 0, lastPlayed: Int64 = 0, history: Int64? = nil,
                           duration: Int64 = 0, isPlayed: Bool = false, position: Int64 = 0) throws {
        try execute(url, "INSERT INTO statistics_units(episode_id, unit_id, played_ms, last_played, history, duration_ms, played, position) VALUES (\(episode), '\(unit)', \(played), \(lastPlayed), \(history.map(String.init) ?? "NULL"), \(duration), \(isPlayed ? 1 : 0), \(position))")
    }
}

@Suite(.serialized) struct LibrarySchema20Tests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Schema20-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aNewLibraryHasItsOwnIdentityAndNoCastTag() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let identity = try await store.libraryIdentity()
        #expect(ContractIdentity.isUUID(identity.identity))
        #expect(identity.castTag == nil && identity.keepRole == nil && identity.keepOperation == nil)
        #expect(identity.pathsRoot == LibraryOwnedPaths.root(of: directory))
        try await store.close()
        // The identity stays with the library from then on.
        let reopened = try FeedLibraryStore(url: url)
        #expect(try await reopened.libraryIdentity().identity == identity.identity)
        try await reopened.close()
        #expect(try RawLibrary.rows(url, "PRAGMA user_version").first?.first == "20")
    }

    @Test func aSchema19StandaloneLibraryMigratesOnceAndKeepsItsRows() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let feed = try await store.insert(ServerLibraryFixture.fetched())
        try await store.close()
        try RawLibrary.downgradeTo19(url)
        let migrated = try FeedLibraryStore(url: url)
        let identity = try await migrated.libraryIdentity()
        #expect(identity.castTag == nil)
        #expect(try await migrated.feeds().map(\.id) == [feed.id])
        try await migrated.close()
        let again = try FeedLibraryStore(url: url)
        #expect(try await again.libraryIdentity() == identity)
        try await again.close()
    }

    @Test func aServerLibraryTakesItsIDAsIdentityAndCastTag() async throws {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let identity = try await fixture.store.libraryIdentity()
        #expect(identity.identity == fixture.identity.libraryID)
        #expect(identity.castTag == fixture.identity.libraryID)
    }

    /// An inactive server library with units is backfilled by local ID; units a pending local reset
    /// covers are left out.
    @Test func theMigrationBackfillsUnitsWithoutThoseAPendingResetCovers() async throws {
        let fixture = try await ServerLibraryFixture()
        let feed = try await fixture.store.insert(ServerLibraryFixture.fetched(count: 3))
        let episodes = feed.episodes.map(\.id).sorted()
        try await fixture.store.close()
        let url = fixture.url
        func unit(_ id: String, played: Int64) -> String {
            "{\"duration_ms\":600000,\"history\":null,\"id\":\"\(id)\",\"last_played\":1000,\"played\":false,\"played_ms\":\(played),\"position\":0}"
        }
        // e:1 has two units learned at clock 1; e:2 one unit learned at clock 5 (after the reset at clock 3).
        try RawLibrary.execute(url, """
            INSERT INTO ntp_episodes(episode_id, local_id, podcast_id, kind, value) VALUES ('e:1', \(episodes[0]), 'p', 'g', '1'), ('e:2', \(episodes[1]), 'p', 'g', '2');
            INSERT INTO ntp_statistics_units(episode_id, unit_id, record) VALUES ('e:1', 'i/1', CAST('\(unit("i/1", played: 100))' AS BLOB)), ('e:1', 'i/2', CAST('\(unit("i/2", played: 200))' AS BLOB)), ('e:2', 'i/3', CAST('\(unit("i/3", played: 300))' AS BLOB));
            INSERT INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('episode', 'e:1', 'statistics_units', '{}', '["n1"]'), ('episode', 'e:2', 'statistics_units', '{}', '["n2"]');
            INSERT INTO ntp_nodes(node_id, knowledge_clock) VALUES ('n1', 1), ('n2', 5);
            """)
        try RawLibrary.downgradeTo19(url)
        // Without a pending reset, every unit is backfilled.
        try FileManager.default.copyItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent("copy.sqlite"))
        let plain = try FeedLibraryStore(url: url.deletingLastPathComponent().appendingPathComponent("copy.sqlite"))
        let all = try await plain.statisticsLibrary().units
        #expect(all[episodes[0]]?.map(\.unitID) == ["i/1", "i/2"])
        #expect(all[episodes[1]]?.map(\.playedMilliseconds) == [300])
        try await plain.close()
        // A pending statistics reset made at clock 3 covers e:1's units (learned at 1), not e:2's (learned at 5).
        try RawLibrary.execute(url, "INSERT INTO ntp_overlays(op_id, entity, id, property, kind, value, clock) VALUES ('op-reset', 'account', '\(fixture.identity.accountID)', 'played_time', 'stat_cut', NULL, 3)")
        let store = try FeedLibraryStore(url: url)
        let units = try await store.statisticsLibrary().units
        #expect(units[episodes[0]] == nil)
        #expect(units[episodes[1]]?.map(\.unitID) == ["i/3"])
        #expect(try await store.libraryIdentity().identity == fixture.identity.libraryID)
        // The cursor and the ntp_* tables stay as they are.
        #expect(try RawLibrary.rows(url, "SELECT count(*) FROM ntp_statistics_units").first?.first == "3")
        try await store.close()
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    /// Owned paths written under another folder are rewritten onto the current one before a writable
    /// open; paths elsewhere stay; repeating it changes nothing.
    @Test func ownedPathsFollowTheLibraryToAnotherFolder() async throws {
        let first = try folder(), second = try folder()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let url = first.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let feed = try await store.insert(ServerLibraryFixture.fetched(count: 2))
        let episodes = feed.episodes.map(\.id).sorted()
        let media = first.appendingPathComponent("media", isDirectory: true)
        let outside = "/private/var/LocalFolder/episode.mp3"
        try await store.updateEpisode(id: episodes[0]) { episode in
            episode.userState.isDownloaded = true
            episode.userState.localFileURL = media.appendingPathComponent("episode-1.media").path
        }
        try await store.updateEpisode(id: episodes[1]) { episode in episode.userState.localFileURL = outside }
        _ = try await store.requestDownload(episodeID: episodes[1], directory: media)
        try await store.close()
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
            try FileManager.default.moveItem(atPath: url.path + suffix, toPath: second.appendingPathComponent("library.sqlite").path + suffix)
        }
        let moved = try FeedLibraryStore(url: second.appendingPathComponent("library.sqlite"))
        let downloaded = try #require(try await moved.episode(id: episodes[0]))
        #expect(downloaded.userState.localFileURL == second.appendingPathComponent("media/episode-1.media").path)
        #expect(try await moved.episode(id: episodes[1])?.userState.localFileURL == outside)
        let job = try #require(try await moved.downloadJobs(activeOnly: true).first)
        #expect(job.destination.deletingLastPathComponent().standardizedFileURL.path == second.appendingPathComponent("media").standardizedFileURL.path)
        #expect(try await moved.libraryIdentity().pathsRoot == LibraryOwnedPaths.root(of: second))
        try await moved.close()
        let again = try FeedLibraryStore(url: second.appendingPathComponent("library.sqlite"))
        #expect(try await again.episode(id: episodes[0]) == downloaded)
        try await again.close()
    }

    /// Units count as rows in every statistic (episodes, started, total and played time, both "include
    /// marked as played" settings, every month), and are in no list or ordinary counter.
    @Test func statisticsUnitsCountAsRowsAndNowhereElse() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let feed = try await store.insert(ServerLibraryFixture.fetched(count: 2))
        let episodes = feed.episodes.map(\.id).sorted()
        let march = Int64(1_772_323_200_000) // 2026-03-01 UTC
        try RawLibrary.insertUnit(url, episode: episodes[0], unit: "i/7", played: 120_000, lastPlayed: march, history: march,
                                  duration: 900_000, position: 0)
        try RawLibrary.insertUnit(url, episode: episodes[0], unit: "i/8", played: 0, lastPlayed: 0, duration: 300_000, isPlayed: true)
        let input = try await store.statisticsLibrary()
        #expect(input.feeds.flatMap(\.episodes).count == 2)
        let all = try LibraryStatistics(feeds: input.feeds, units: input.units, includeMarkedAsPlayed: false, now: ServerLibraryFixture.now)
        let row = try #require(all.feeds.first)
        #expect(row.episodes == 4)
        #expect(row.totalSeconds == 2_400)
        #expect(row.playedSeconds == 120)
        #expect(row.episodesStarted == 1)
        let marked = try LibraryStatistics(feeds: input.feeds, units: input.units, includeMarkedAsPlayed: true, now: ServerLibraryFixture.now)
        #expect(marked.feeds.first?.playedSeconds == 420)
        #expect(marked.feeds.first?.episodesStarted == 2)
        let years = YearsStatisticsSnapshot(feeds: input.feeds, units: input.units)
        #expect(years.monthly == [MonthlyListening(year: 2026, month: 3, playedMilliseconds: 120_000)])
        // In no list: the library's feeds, the snapshot's episodes and the per-feed statistics read only episodes.
        #expect(try await store.feeds().flatMap(\.episodes).count == 2)
        #expect(try await store.snapshot().feeds.flatMap(\.episodes).count == 2)
        #expect(try await store.statisticsSnapshot(feedID: feed.id, now: ServerLibraryFixture.now)?.statistics.episodes == 4)
        try await store.close()
    }

    /// Android's row operations in a standalone library (PROTOCOL §15.2): Reset statistics zeroes units' played time and nothing
    /// else; Clear history clears their history; marking and favorites change only the episode; deleting the episode
    /// deletes them.
    @Test func androidRowOperationsApplyToUnits() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let feed = try await store.insert(ServerLibraryFixture.fetched(count: 2))
        let episodes = feed.episodes.map(\.id).sorted()
        try RawLibrary.insertUnit(url, episode: episodes[0], unit: "i/1", played: 50_000, lastPlayed: 10, history: 10,
                                  duration: 100_000, isPlayed: true, position: 7)
        try await store.markEpisodePlayed(episodeID: episodes[0], played: false)
        try await store.setFavorite(episodeID: episodes[0], favorite: true)
        var unit = try #require(try await store.statisticsLibrary().units[episodes[0]]?.first)
        #expect(unit == LibraryStatisticsUnit(episodeID: episodes[0], unitID: "i/1", playedMilliseconds: 50_000, lastPlayedMilliseconds: 10,
                                              historyMilliseconds: 10, durationMilliseconds: 100_000, played: true, positionMilliseconds: 7))
        try await store.resetPlayedDurationStatistics()
        unit = try #require(try await store.statisticsLibrary().units[episodes[0]]?.first)
        #expect(unit.playedMilliseconds == 0 && unit.lastPlayedMilliseconds == 10 && unit.historyMilliseconds == 10 && unit.played)
        // With "include marked as played" on, a marked-played unit still counts its duration after the reset.
        let input = try await store.statisticsLibrary()
        let marked = try LibraryStatistics(feeds: input.feeds, units: input.units, includeMarkedAsPlayed: true, now: ServerLibraryFixture.now)
        #expect(marked.feeds.first?.playedSeconds == 100)
        _ = try await store.clearPlaybackHistory()
        unit = try #require(try await store.statisticsLibrary().units[episodes[0]]?.first)
        #expect(unit.historyMilliseconds == nil && unit.lastPlayedMilliseconds == 10)
        try RawLibrary.execute(url, "DELETE FROM episodes WHERE id = \(episodes[0])")
        #expect(try await store.statisticsLibrary().units.isEmpty)
        try await store.close()
    }

    /// A pinned removal kept at logout (PROTOCOL §15.4): no library-wide read shows its podcast; the player still reads its episode.
    @Test func aPinnedRemovalIsHiddenInAStandaloneLibrary() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let kept = try await store.insert(ServerLibraryFixture.fetched("https://example.test/a.xml", title: "A"))
        let removed = try await store.insert(ServerLibraryFixture.fetched("https://example.test/b.xml", title: "B"))
        try RawLibrary.execute(url, "INSERT INTO pinned_feed_removals(feed_id) VALUES (\(removed.id))")
        #expect(try await store.feeds().map(\.id) == [kept.id])
        #expect(try await store.snapshot().feeds.map(\.id) == [kept.id])
        #expect(try await store.feed(id: removed.id) == nil)
        #expect(try await store.statisticsLibrary().feeds.map(\.id) == [kept.id])
        #expect(try await store.playbackFeed(id: removed.id)?.id == removed.id)
        #expect(try await store.episode(id: removed.episodes[0].id) != nil)
        try await store.close()
    }

    /// A library never written since it switched to WAL has no shared-memory file, which a read-only connection may
    /// not create: the read-only reader still reads it (its identity, an export's rows), and refuses every write, so
    /// the library's data never changes (SQLite may create its `-wal` and `-shm` files). (The Keep's capture of a root
    /// library a fresh install never used, and an inactive library's export.)
    @Test func theReadOnlyReaderReadsALibraryWithoutItsSharedMemoryFile() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        try LibrarySQLite(url: url).close()
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        let identity = try #require(try LibraryDatabaseInspection.identity(of: url))
        #expect(try LibraryDatabaseInspection.schemaVersion(of: url) == 20)
        let reader = try FeedLibraryStore(readingOnly: url)
        #expect(try await reader.feeds().isEmpty)
        #expect(try await reader.exportContents().identity == identity.identity)
        await #expect(throws: (any Error).self) { _ = try await reader.insert(ServerLibraryFixture.fetched()) }
        try await reader.close()
        #expect(try LibraryDatabaseInspection.identity(of: url) == identity)
        let missing = directory.appendingPathComponent("missing.sqlite")
        #expect(throws: (any Error).self) { try LibraryDatabaseInspection.identity(of: missing) }
        #expect(!FileManager.default.fileExists(atPath: missing.path), "never created")
    }
}
