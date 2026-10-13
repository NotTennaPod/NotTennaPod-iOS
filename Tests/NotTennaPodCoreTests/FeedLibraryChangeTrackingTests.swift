import Foundation
import Testing
@testable import NotTennaPodCore

/// Unchanged records are not rewritten on refresh, and the library reload re-reads only changed feeds
/// while always returning exactly what a fresh load of the committed database returns.
struct FeedLibraryChangeTrackingTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func options(_ offset: TimeInterval = 0) -> FeedRefreshOptions {
        FeedRefreshOptions(now: now.addingTimeInterval(offset), timeZone: .gmt)
    }

    private func fetched(_ identifiers: [String], source: String = "https://example.test/feed",
                         title: String = "Feed", description: (String) -> String = { "Notes \($0)" }) -> FetchedFeed {
        let episodes = identifiers.enumerated().map { offset, id in
            ParsedEpisode(identifier: id, title: "Episode \(id)", description: description(id),
                          publicationDate: now.addingTimeInterval(Double(offset)),
                          media: ParsedMedia(url: "https://example.test/\(id).mp3", size: 32_768, mimeType: "audio/mpeg",
                                             durationMilliseconds: 60_000))
        }
        return FetchedFeed(feed: ParsedFeed(format: .rss, title: title, episodes: episodes),
                           source: source, responseURL: URL(string: source)!, validator: "etag", permanentRedirectURL: nil)
    }

    private func withLibrary(_ operation: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AntennaPodChanges-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        do {
            try await operation(store, url)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    /// Records every row write to `episodes` and `feeds` made by any connection.
    private func installWriteLog(_ db: LibrarySQLite) throws {
        try db.execute("CREATE TABLE test_write_log (kind TEXT NOT NULL, id INTEGER NOT NULL)")
        for event in ["INSERT", "UPDATE"] {
            try db.execute("CREATE TRIGGER test_log_episode_\(event) AFTER \(event) ON episodes BEGIN INSERT INTO test_write_log VALUES ('episode', NEW.id); END")
            try db.execute("CREATE TRIGGER test_log_feed_\(event) AFTER \(event) ON feeds BEGIN INSERT INTO test_write_log VALUES ('feed', NEW.id); END")
        }
    }

    private func writes(_ db: LibrarySQLite, _ kind: String) throws -> [Int64] {
        try db.rows("SELECT id FROM test_write_log WHERE kind = ? ORDER BY rowid", [.text(kind)]).compactMap { $0[0].integer }
    }

    /// What a new store (empty caches) reads from the committed database.
    private func freshSnapshot(_ url: URL) async throws -> FeedLibrarySnapshot {
        let fresh = try FeedLibraryStore(url: url)
        let snapshot = try await fresh.snapshot()
        try await fresh.close()
        return snapshot
    }

    @Test func refreshWithUnchangedContentWritesNoRows() async throws {
        try await withLibrary { store, url in
            let ids = (0..<40).map { "e\($0)" }
            let feed = try await store.insert(fetched(ids), options: options())
            let db = try LibrarySQLite(url: url)
            defer { try? db.close() }
            try installWriteLog(db)

            // The first refresh records the header's source-type provenance once; no episode is rewritten.
            _ = try await store.applyRefresh(fetched(ids), feedID: feed.id, options: options())
            #expect(try writes(db, "episode") == [])
            #expect(try writes(db, "feed") == [feed.id])

            try db.execute("DELETE FROM test_write_log")
            let generation = try db.scalar("SELECT generation FROM feed_changes WHERE feed_id = ?", [.integer(feed.id)])
            let before = try await store.snapshot()
            _ = try await store.applyRefresh(fetched(ids), feedID: feed.id, options: options())
            #expect(try writes(db, "episode") == [])
            #expect(try writes(db, "feed") == [])
            #expect(try db.scalar("SELECT generation FROM feed_changes WHERE feed_id = ?", [.integer(feed.id)]) == generation)
            #expect(try await store.snapshot() == before)
        }
    }

    @Test func refreshWritesOnlyTheChangedEpisodeAndHeader() async throws {
        try await withLibrary { store, url in
            let ids = (0..<20).map { "e\($0)" }
            let feed = try await store.insert(fetched(ids), options: options())
            _ = try await store.snapshot()
            let db = try LibrarySQLite(url: url)
            defer { try? db.close() }
            try installWriteLog(db)
            let changed = fetched(ids, title: "Renamed") { $0 == "e7" ? "Corrected notes" : "Notes \($0)" }

            let result = try await store.applyRefresh(changed, feedID: feed.id, options: options(60))

            let e7 = try #require(result.feed.episodes.first { $0.details.identifier == "e7" })
            #expect(try writes(db, "episode") == [e7.id])
            #expect(try writes(db, "feed") == [feed.id])
            let reloaded = try #require(try await store.feed(id: feed.id))
            #expect(reloaded.metadata.title == "Renamed")
            #expect(reloaded.episodes.first { $0.id == e7.id }?.details.description == "Corrected notes")
            #expect(reloaded.episodes.filter { $0.id != e7.id }.allSatisfy { $0.details.description?.hasPrefix("Notes ") == true })
            #expect(try await store.snapshot() == freshSnapshot(url))
        }
    }

    @Test func snapshotAfterChangesMatchesAFreshLoadOfTheCommittedDatabase() async throws {
        try await withLibrary { store, url in
            let a = try await store.insert(fetched(["a1", "a2", "a3"], source: "https://example.test/a", title: "A"), options: options())
            let b = try await store.insert(fetched(["b1", "b2"], source: "https://example.test/b", title: "B"), options: options())
            let c = try await store.insert(fetched(["c1"], source: "https://example.test/c", title: "C"), options: options())
            #expect(try await store.snapshot() == freshSnapshot(url))

            // A single-feed refresh adding an episode.
            _ = try await store.applyRefresh(fetched(["a1", "a2", "a3", "a4"], source: "https://example.test/a", title: "A"),
                                             feedID: a.id, options: options(10))
            #expect(try await store.snapshot() == freshSnapshot(url))

            // Episode state, queue and preferences.
            try await store.markEpisodePlayed(episodeID: b.episodes[0].id, played: true)
            _ = try await store.enqueue([c.episodes[0].id])
            try await store.updatePreferences(feedID: c.id) { $0.newEpisodesAction = .queue }
            #expect(try await store.snapshot() == freshSnapshot(url))

            // A write by another connection (another store on the same file).
            let other = try FeedLibraryStore(url: url)
            try await other.updateEpisode(id: a.episodes[0].id) { $0.userState.positionMilliseconds = 12_345 }
            try await other.close()
            let afterOther = try await store.snapshot()
            #expect(afterOther == (try await freshSnapshot(url)))
            #expect(afterOther.feeds.first { $0.id == a.id }?.episodes.first { $0.id == a.episodes[0].id }?
                .userState.positionMilliseconds == 12_345)

            // Removing unlisted episodes, then deleting a whole feed.
            var removing = options(20)
            removing.removeUnlistedItems = true
            _ = try await store.applyRefresh(fetched(["b2"], source: "https://example.test/b", title: "B"), feedID: b.id, options: removing)
            #expect(try await store.snapshot() == freshSnapshot(url))
            try await store.requestFeedDeletion(feedID: c.id)
            let afterDelete = try await store.snapshot()
            #expect(afterDelete == (try await freshSnapshot(url)))
            #expect(afterDelete.feeds.map(\.id) == [a.id, b.id])
        }
    }

    @Test func rolledBackWritesNeverLeaveAStaleCachedFeed() async throws {
        try await withLibrary { store, url in
            let feed = try await store.insert(fetched(["a", "b"], title: "Original"), options: options())
            _ = try await store.snapshot()
            let db = try LibrarySQLite(url: url)
            defer { try? db.close() }
            // The OPML merge renames the feed and reloads it inside the transaction, then its second header
            // write fails: the reload saw uncommitted data under a generation that the rollback will reuse.
            try db.execute("CREATE TRIGGER test_reject_placeholder BEFORE UPDATE ON feeds WHEN NEW.record LIKE '%\"sourceTypeAbsent\":true%' BEGIN SELECT RAISE(ABORT, 'Injected failure'); END")
            await #expect(throws: FeedLibraryError.self) {
                try await store.importOPMLEntry(.init(title: "Uncommitted", xmlURL: "https://example.test/feed"), now: now)
            }
            try db.execute("DROP TRIGGER test_reject_placeholder")
            // A committed episode change (made without loading the feed) advancing the generation by the same
            // amount as the rolled-back header write.
            try await store.updateEpisode(id: feed.episodes[0].id) { $0.userState.positionMilliseconds = 4_321 }

            let snapshot = try await store.snapshot()
            #expect(snapshot == (try await freshSnapshot(url)))
            #expect(snapshot.feeds.first?.metadata.title == "Original")
            #expect(snapshot.feeds.first?.episodes.first { $0.id == feed.episodes[0].id }?.userState.positionMilliseconds == 4_321)
        }
    }

    @Test func schemaFourteenLibraryUpgradesAndTracksChanges() async throws {
        try await withLibrary { store, url in
            let feed = try await store.insert(fetched(["a", "b"]), options: options())
            _ = try await store.enqueue([feed.episodes[0].id])
            try await store.close()
            let old = try LibrarySQLite(url: url)
            for name in ["feeds_insert", "feeds_update", "feeds_delete", "episodes_insert", "episodes_update", "episodes_delete"] {
                try old.execute("DROP TRIGGER feed_changes_\(name)")
            }
            try old.execute("DROP TABLE feed_changes")
            try old.execute("PRAGMA user_version = 14")
            let tables = try old.rows("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").compactMap {
                if case .text(let name) = $0[0] { name } else { nil }
            }
            let before = try tables.map { try old.rows("SELECT * FROM \($0) ORDER BY rowid").description }
            try old.close()

            let upgraded = try FeedLibraryStore(url: url)
            let check = try LibrarySQLite(url: url)
            #expect(try check.scalar("PRAGMA user_version") == 20)
            #expect(try check.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'feed_changes_%'") == 6)
            #expect(try tables.map { try check.rows("SELECT * FROM \($0) ORDER BY rowid").description } == before)
            let loaded = try await upgraded.snapshot()
            try await upgraded.markEpisodePlayed(episodeID: feed.episodes[1].id, played: true)
            #expect(try check.scalar("SELECT generation FROM feed_changes WHERE feed_id = ?", [.integer(feed.id)]) > 0)
            let changed = try await upgraded.snapshot()
            #expect(changed != loaded)
            #expect(changed == (try await freshSnapshot(url)))
            try check.close()
            try await upgraded.close()
        }
    }
}
