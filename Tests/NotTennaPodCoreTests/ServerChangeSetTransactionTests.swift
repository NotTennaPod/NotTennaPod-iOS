import Foundation
import Testing
@testable import NotTennaPodCore

/// Each committed write transaction delivers exactly its visible difference, through the one boundary
/// (`LibrarySQLite.transaction`), checked against the independent oracle (`ChangeSetOracle`) after every transaction,
/// with the app's real statements: every conflict policy, savepoints, rollbacks, cascades, hides and reveals, the queue
/// contract, statistics, downloads, Undo guards and local folders.
@Suite(.serialized) struct ServerChangeSetTransactionTests {
    /// A library (standalone or server) with the oracle and a commit log installed, and one podcast of `count` episodes.
    struct World {
        let fixture: ServerLibraryFixture
        let oracle: ChangeSetOracle
        let log: CommitLog
        let feed: LibraryFeed
        var store: FeedLibraryStore { fixture.store }
        var ids: [Int64] { feed.episodes.map(\.id).sorted() }

        static func make(server: Bool = false, count: Int = 6) async throws -> World {
            let fixture = try await ServerLibraryFixture(server: server)
            let oracle = ChangeSetOracle()
            await fixture.store.installChangeOracleForTesting(oracle)
            let log = await fixture.store.recordCommitsForTesting()
            let feed = try await fixture.store.insert(ServerLibraryFixture.fetched(count: count))
            log.removeAll()
            return World(fixture: fixture, oracle: oracle, log: log, feed: feed)
        }

        /// The union of what was delivered since the last call, and the oracle's verdict so far.
        func take(sourceLocation: SourceLocation = #_sourceLocation) -> LibraryChangeSet? {
            #expect(oracle.mismatches.isEmpty, "\(oracle.report)", sourceLocation: sourceLocation)
            return log.take().set
        }

        func raw(_ sql: String, _ values: [LibrarySQLValue] = []) async throws {
            try await store.databaseForTesting { db in try db.transaction { try db.execute(sql, values) } }
        }

        func close() async { await fixture.close() }
    }

    @Test func subscribingAddsThePodcastWithItsEpisodes() async throws {
        let fixture = try await ServerLibraryFixture(server: false)
        let oracle = ChangeSetOracle()
        await fixture.store.installChangeOracleForTesting(oracle)
        let log = await fixture.store.recordCommitsForTesting()
        let before = fixture.store.changes.emitted
        let feed = try await fixture.store.insert(ServerLibraryFixture.fetched(count: 4))
        let set = try #require(log.take().set)
        #expect(set.feeds == [feed.id: .added])
        #expect(set.episodes.isEmpty && set.statistics.isEmpty, "the podcast carries its episodes: \(set)")
        #expect(set.sequence == before + 1 && fixture.store.changes.emitted == set.sequence, "a receipt right after the write")
        #expect(oracle.mismatches.isEmpty, "\(oracle.report)")
        await fixture.close()
    }

    @Test func aPlayedMarkChangesTheEpisodeAndItsStatisticsOnly() async throws {
        let world = try await World.make()
        let id = world.ids[1]
        try await world.store.markEpisodePlayed(episodeID: id, played: true)
        let set = try #require(world.take())
        #expect(Set(set.episodes.keys) == [id] && set.episodes[id]?.change == .changed && set.episodes[id]?.feed == world.feed.id)
        #expect(Set(set.statistics.keys) == [id])
        #expect(set.feeds.isEmpty && set.queue == nil, "\(set)")
        // The same mark again changes nothing: no set, no sequence.
        let emitted = world.store.changes.emitted
        try await world.store.markEpisodePlayed(episodeID: id, played: true)
        #expect(world.take() == nil)
        #expect(world.store.changes.emitted == emitted)
        await world.close()
    }

    @Test func aFavoriteChangesTheEpisodeButNotItsStatistics() async throws {
        let world = try await World.make()
        let id = world.ids[2]
        try await world.store.setFavorite(episodeID: id, favorite: true)
        let set = try #require(world.take())
        #expect(Set(set.episodes.keys) == [id] && set.statistics.isEmpty, "\(set)")
        await world.close()
    }

    @Test func theQueueContract() async throws {
        let world = try await World.make(count: 8)
        let ids = world.ids
        _ = try await world.store.enqueue(Array(ids[0..<4]))
        var set = try #require(world.take())
        #expect(set.queue == .init(added: Set(ids[0..<4])), "\(String(describing: set.queue))")
        // An append adds only the new member.
        _ = try await world.store.enqueue([ids[4]])
        set = try #require(world.take())
        #expect(set.queue == .init(added: [ids[4]]))
        // [1,2,3,4,5] → [1,3,2,4,5]: 2, 3 and 4 have new predecessors.
        let current = try await world.store.queue().map(QueueEpisodeIdentity.init)
        _ = try await world.store.performQueueMove(.item(ids[1], finalIndex: 2), expected: current)
        set = try #require(world.take())
        #expect(set.queue == .init(relinked: [ids[1], ids[2], ids[3]]), "\(String(describing: set.queue))")
        // Removing B from [A,B,C] relinks C.
        _ = try await world.store.removeFromQueue([ids[2]])
        set = try #require(world.take())
        #expect(set.queue == .init(removed: [ids[2]], relinked: [ids[1]]), "\(String(describing: set.queue))")
        // Inserting X at the front relinks the former head.
        _ = try await world.store.enqueue([ids[5]], location: .front)
        set = try #require(world.take())
        #expect(set.queue?.added == [ids[5]] && set.queue?.relinked == [ids[0]], "\(String(describing: set.queue))")
        // A clear removes every member.
        _ = try await world.store.clearQueue()
        set = try #require(world.take())
        #expect(set.queue?.removed.count == 5 && set.queue?.added.isEmpty == true)
        await world.close()
    }

    @Test func anUnchangedQueueRewriteIsEmpty() async throws {
        let world = try await World.make()
        _ = try await world.store.enqueue(Array(world.ids[0..<3]))
        _ = world.take()
        // The whole queue deleted and inserted again in the same order: nothing visible changed.
        try await world.store.databaseForTesting { db in
            try db.transaction {
                let order = try db.rows("SELECT episode_id FROM queue ORDER BY position").compactMap { $0[0].integer }
                try db.execute("DELETE FROM queue")
                for (index, id) in order.enumerated() { try db.execute("INSERT INTO queue(position, episode_id) VALUES (?, ?)", [.integer(Int64(index)), .integer(id)]) }
            }
        }
        #expect(world.take() == nil)
        await world.close()
    }

    @Test func statisticsUnitsReplacedIdenticallyAreEmptyAndChangedOnesAreExact() async throws {
        let world = try await World.make()
        let id = world.ids[0]
        let units = (1...5).map { LibraryStatisticsUnit(episodeID: id, unitID: "u\($0)", playedMilliseconds: Int64($0) * 1_000, lastPlayedMilliseconds: 10,
                                                         historyMilliseconds: $0 == 2 ? nil : 5, durationMilliseconds: 60_000, played: false, positionMilliseconds: 0) }
        try await world.store.databaseForTesting { db in try db.transaction { try db.replaceStatisticsUnits(episode: id, with: units) } }
        var set = try #require(world.take())
        #expect(Set(set.statistics.keys) == [id] && set.episodes.isEmpty, "\(set)")
        // The real replacement writer (DELETE, then INSERT OR REPLACE) with identical units: nothing.
        try await world.store.databaseForTesting { db in try db.transaction { try db.replaceStatisticsUnits(episode: id, with: units) } }
        #expect(world.take() == nil)
        var changed = units
        changed[3].playedMilliseconds += 1
        try await world.store.databaseForTesting { db in try db.transaction { try db.replaceStatisticsUnits(episode: id, with: changed) } }
        set = try #require(world.take())
        #expect(Set(set.statistics.keys) == [id])
        await world.close()
    }

    /// Every conflict policy of the app's statement forms on every visible table (Undo guards, statistics units, episodes,
    /// feeds, pinned removals, the queue, download jobs including an active job's active-to-active change, and local folder
    /// links): no write fails because of the capture, the first image stays the transaction-start image, and the set is
    /// exact (checked by the oracle).
    @Test func everyConflictPolicyCommitsAndIsExact() async throws {
        for server in [false, true] {
            let world = try await World.make(server: server)
            let (f, a, b) = (world.feed.id, world.ids[0], world.ids[1])
            let record = try await world.store.databaseForTesting { db in
                try db.rows("SELECT record FROM episodes WHERE id = ?", [.integer(a)]).first?[0] ?? .null
            }
            let statements: [(String, [LibrarySQLValue])] = [
                ("INSERT INTO episode_swipe_undo(episode_id, operation_id) VALUES (?, 'x')", [.integer(a)]),
                ("INSERT OR REPLACE INTO episode_swipe_undo(episode_id, operation_id) VALUES (?, 'y')", [.integer(a)]),
                ("INSERT OR IGNORE INTO episode_swipe_undo(episode_id, operation_id) VALUES (?, 'z')", [.integer(a)]),
                ("INSERT INTO episode_swipe_undo(episode_id, operation_id) VALUES (?, 'w') ON CONFLICT(episode_id) DO UPDATE SET operation_id = excluded.operation_id", [.integer(a)]),
                ("INSERT INTO episode_swipe_undo(episode_id, operation_id) VALUES (?, 'v') ON CONFLICT(episode_id) DO NOTHING", [.integer(a)]),
                ("UPDATE episode_swipe_undo SET operation_id = 'x' WHERE episode_id = ?", [.integer(a)]),
                ("DELETE FROM episode_swipe_undo WHERE episode_id = ?", [.integer(a)]),
                ("INSERT OR REPLACE INTO statistics_units(episode_id, unit_id, played_ms) VALUES (?, 'u', 5)", [.integer(b)]),
                ("INSERT OR REPLACE INTO statistics_units(episode_id, unit_id, played_ms) VALUES (?, 'u', 5)", [.integer(b)]),
                ("INSERT OR IGNORE INTO statistics_units(episode_id, unit_id, played_ms) VALUES (?, 'u', 6)", [.integer(b)]),
                ("INSERT INTO statistics_units(episode_id, unit_id, played_ms) VALUES (?, 'u', 7) ON CONFLICT(episode_id, unit_id) DO UPDATE SET played_ms = excluded.played_ms", [.integer(b)]),
                ("INSERT INTO statistics_units(episode_id, unit_id, played_ms) VALUES (?, 'u', 8) ON CONFLICT DO NOTHING", [.integer(b)]),
                ("DELETE FROM statistics_units WHERE episode_id = ?", [.integer(b)]),
                ("INSERT INTO episodes(id, feed_id, pubdate, record) VALUES (?, ?, 1, ?) ON CONFLICT(id) DO UPDATE SET pubdate = excluded.pubdate, record = excluded.record", [.integer(a), .integer(f), record]),
                ("INSERT INTO episodes(id, feed_id, pubdate, record) VALUES (?, ?, 1, ?) ON CONFLICT(id) DO NOTHING", [.integer(a), .integer(f), record]),
                ("INSERT OR IGNORE INTO episodes(id, feed_id, pubdate, record) VALUES (?, ?, 2, ?)", [.integer(a), .integer(f), record]),
                ("UPDATE episodes SET pubdate = pubdate + 1 WHERE id = ?", [.integer(a)]),
                ("INSERT INTO feeds(id, title, record) SELECT id, 'T', record FROM feeds WHERE id = ? ON CONFLICT(id) DO UPDATE SET title = excluded.title", [.integer(f)]),
                ("INSERT OR IGNORE INTO pinned_feed_removals(feed_id) VALUES (?)", [.integer(f)]),
                ("INSERT OR REPLACE INTO pinned_feed_removals(feed_id) VALUES (?)", [.integer(f)]),
                ("DELETE FROM pinned_feed_removals WHERE feed_id = ?", [.integer(f)]),
                ("INSERT INTO queue(position, episode_id) VALUES (0, ?) ON CONFLICT(episode_id) DO UPDATE SET position = excluded.position", [.integer(a)]),
                ("INSERT OR REPLACE INTO queue(position, episode_id) VALUES (0, ?)", [.integer(b)]),
                ("INSERT OR IGNORE INTO queue(position, episode_id) VALUES (1, ?)", [.integer(a)]),
                ("DELETE FROM queue", []),
                // Download jobs: every policy on the active-source key, an active job's record changed while it stays
                // active (active to active), moved to another episode, made inactive and active again, and deleted.
                ("INSERT INTO download_jobs(id, episode_id, source, active, record) VALUES (900, ?, 'https://example.test/d-1', 1, x'7b7d')", [.integer(a)]),
                ("INSERT OR REPLACE INTO download_jobs(id, episode_id, source, active, record) VALUES (900, ?, 'https://example.test/d-1', 1, x'7b2261223a317d')", [.integer(a)]),
                ("INSERT OR IGNORE INTO download_jobs(id, episode_id, source, active, record) VALUES (901, ?, 'https://example.test/d-1', 1, x'7b7d')", [.integer(a)]),
                ("INSERT INTO download_jobs(id, episode_id, source, active, record) VALUES (900, ?, 'https://example.test/d-1', 1, x'7b2261223a327d') ON CONFLICT(id) DO UPDATE SET record = excluded.record", [.integer(a)]),
                ("INSERT INTO download_jobs(id, episode_id, source, active, record) VALUES (900, ?, 'https://example.test/d-1', 1, x'7b7d') ON CONFLICT DO NOTHING", [.integer(a)]),
                ("UPDATE download_jobs SET record = x'7b2261223a337d' WHERE id = 900 AND active = 1", []),
                ("UPDATE download_jobs SET episode_id = ? WHERE id = 900", [.integer(b)]),
                ("UPDATE download_jobs SET active = 0 WHERE id = 900", []),
                ("UPDATE download_jobs SET active = 1 WHERE id = 900", []),
                ("DELETE FROM download_jobs WHERE id = 900", []),
                // Local folder links: every policy on the feed key, a changed and an unchanged record, and deletion.
                ("INSERT INTO local_folder_links(feed_id, record) VALUES (?, x'7b7d')", [.integer(f)]),
                ("INSERT OR REPLACE INTO local_folder_links(feed_id, record) VALUES (?, x'7b2261223a317d')", [.integer(f)]),
                ("INSERT OR REPLACE INTO local_folder_links(feed_id, record) VALUES (?, x'7b2261223a317d')", [.integer(f)]),
                ("INSERT OR IGNORE INTO local_folder_links(feed_id, record) VALUES (?, x'7b7d')", [.integer(f)]),
                ("INSERT INTO local_folder_links(feed_id, record) VALUES (?, x'7b2261223a327d') ON CONFLICT(feed_id) DO UPDATE SET record = excluded.record", [.integer(f)]),
                ("INSERT INTO local_folder_links(feed_id, record) VALUES (?, x'7b7d') ON CONFLICT DO NOTHING", [.integer(f)]),
                ("UPDATE local_folder_links SET record = record WHERE feed_id = ?", [.integer(f)]),
                ("UPDATE local_folder_links SET record = x'7b2261223a337d' WHERE feed_id = ?", [.integer(f)]),
                ("DELETE FROM local_folder_links WHERE feed_id = ?", [.integer(f)]),
            ]
            for (sql, values) in statements {
                // Each on its own, then (unless the table's own key refuses a second plain insert) twice in one
                // transaction: a repeated key, whose first image must stay the transaction-start one.
                try await world.raw(sql, values)
                if sql.hasPrefix("INSERT INTO"), !sql.contains("ON CONFLICT") { continue }
                try await world.store.databaseForTesting { db in try db.transaction { try db.execute(sql, values); try db.execute(sql, values) } }
            }
            try await world.store.databaseForTesting { db in
                try db.transaction {
                    try db.execute("UPDATE episodes SET pubdate = pubdate + 7 WHERE id = ?", [.integer(a)])
                    try db.execute("UPDATE episodes SET pubdate = pubdate - 7 WHERE id = ?", [.integer(a)])
                }
            }
            #expect(world.oracle.mismatches.isEmpty, "server \(server): \(world.oracle.report)")
            #expect(world.oracle.transactions >= statements.count + 1)
            await world.close()
        }
    }

    @Test func aRolledBackTransactionAndARolledBackSavepointDeliverOnlyWhatCommitted() async throws {
        let world = try await World.make()
        let (a, b) = (world.ids[0], world.ids[1])
        struct Failure: Error {}
        let emitted = world.store.changes.emitted
        await #expect(throws: Failure.self) {
            try await world.store.databaseForTesting { db in
                try db.transaction { try db.execute("UPDATE episodes SET pubdate = pubdate + 1 WHERE id = ?", [.integer(a)]); throw Failure() }
            }
        }
        #expect(world.log.take().commits.isEmpty && world.store.changes.emitted == emitted, "a rollback delivers nothing")
        try await world.store.databaseForTesting { db in
            try db.transaction {
                try db.execute("UPDATE episodes SET pubdate = pubdate + 1 WHERE id = ?", [.integer(a)])
                _ = try? db.savepoint { () throws -> Void in
                    try db.execute("UPDATE episodes SET pubdate = pubdate + 1 WHERE id = ?", [.integer(b)])
                    throw Failure()
                }
            }
        }
        let set = try #require(world.take())
        #expect(Set(set.episodes.keys) == [a], "the savepoint's write went with it: \(set)")
        #expect(set.sequence == emitted + 1, "the rollback took no sequence")
        await world.close()
    }

    @Test func aPinnedRemovalHidesThePodcastWithItsQueuedEpisodesAndReleasingItShowsThemAgain() async throws {
        let world = try await World.make()
        let other = try await world.store.insert(ServerLibraryFixture.fetched("https://example.test/other.xml", title: "Other", count: 2))
        _ = try await world.store.enqueue([world.ids[0], other.episodes[0].id, world.ids[1]])
        _ = world.take()
        try await world.raw("INSERT INTO pinned_feed_removals(feed_id) VALUES (?)", [.integer(world.feed.id)])
        var set = try #require(world.take())
        #expect(set.feeds == [world.feed.id: .removed] && set.episodes.isEmpty, "the podcast carries its episodes: \(set)")
        #expect(set.queue == .init(removed: [world.ids[0], world.ids[1]], relinked: [other.episodes[0].id]), "\(String(describing: set.queue))")
        try await world.raw("DELETE FROM pinned_feed_removals WHERE feed_id = ?", [.integer(world.feed.id)])
        set = try #require(world.take())
        #expect(set.feeds == [world.feed.id: .added] && set.queue?.added == [world.ids[0], world.ids[1]])
        await world.close()
    }

    @Test func aHiddenEpisodeChangedWhileItsPodcastIsHiddenThenRevealedIsJudgedFromTheStart() async throws {
        let world = try await World.make()
        let a = world.ids[0]
        // In one transaction: the podcast hidden, then one of its episodes deleted and another changed.
        try await world.store.databaseForTesting { db in
            try db.transaction {
                try db.execute("INSERT INTO pinned_feed_removals(feed_id) VALUES (?)", [.integer(world.feed.id)])
                try db.execute("DELETE FROM episodes WHERE id = ?", [.integer(a)])
                try db.execute("UPDATE episodes SET pubdate = pubdate + 1 WHERE id = ?", [.integer(world.ids[1])])
            }
        }
        let set = try #require(world.take())
        #expect(set.feeds == [world.feed.id: .removed] && set.episodes.isEmpty, "\(set)")
        await world.close()
    }

    @Test func downloadJobsUndoGuardsAndLocalFoldersAreTheirOwnRelations() async throws {
        let world = try await World.make()
        let a = world.ids[0]
        let job = try #require(try await world.store.requestDownload(episodeID: a, directory: world.fixture.directory, enqueue: false))
        var set = try #require(world.take())
        #expect(Set(set.downloads.keys) == [a] && set.downloads[a]?.change == .added, "\(set)")
        _ = try await world.store.cancelDownload(id: job.id)
        set = try #require(world.take())
        #expect(set.downloads[a]?.change == .removed)
        let receipt = try #require(try await world.store.applySwipeMark(episodeID: world.ids[1], action: .togglePlayed))
        set = try #require(world.take())
        #expect(set.undo[world.ids[1]]?.change == .added && set.episodes[world.ids[1]] != nil)
        _ = try await world.store.undoSwipeMark(receipt)
        set = try #require(world.take())
        #expect(set.undo[world.ids[1]]?.change == .removed)
        await world.close()
    }

    @Test func aDeletedPodcastIsOneRemovalAndItsQueueEntriesGo() async throws {
        let world = try await World.make(count: 5)
        _ = try await world.store.enqueue([world.ids[1], world.ids[3]])
        _ = world.take()
        try await world.raw("DELETE FROM feeds WHERE id = ?", [.integer(world.feed.id)])
        let set = try #require(world.take())
        #expect(set.feeds == [world.feed.id: .removed] && set.episodes.isEmpty && set.statistics.isEmpty)
        #expect(set.queue == .init(removed: [world.ids[1], world.ids[3]]))
        await world.close()
    }

    @Test func anEpisodeMovedToAnotherPodcastNamesBoth() async throws {
        let world = try await World.make()
        let other = try await world.store.insert(ServerLibraryFixture.fetched("https://example.test/other.xml", title: "Other", count: 2))
        _ = world.take()
        try await world.raw("UPDATE episodes SET feed_id = ? WHERE id = ?", [.integer(other.id), .integer(world.ids[0])])
        let set = try #require(world.take())
        #expect(set.episodes[world.ids[0]] == .init(change: .changed, feed: other.id, formerFeed: world.feed.id))
        await world.close()
    }

    @Test func aDataChangeOutsideATransactionGoesThroughTheBoundary() async throws {
        let world = try await World.make()
        try await world.store.databaseForTesting { db in try db.execute("UPDATE episodes SET pubdate = pubdate + 1 WHERE id = ?", [.integer(world.ids[2])]) }
        let set = try #require(world.take())
        #expect(Set(set.episodes.keys) == [world.ids[2]])
        await world.close()
    }

    /// The capture's own work: each key's image is computed once per transaction (deleting N statistics units of one
    /// episode hashes N rows, not N(N+1)/2), and an unchanged podcast mapping captures nothing.
    @Test func eachImageIsComputedOncePerTransaction() async throws {
        let world = try await World.make()
        let id = world.ids[0]
        for count in [100, 1_000] {
            let units = (0..<count).map { LibraryStatisticsUnit(episodeID: id, unitID: "u\($0)", playedMilliseconds: 1, lastPlayedMilliseconds: 1,
                                                                 historyMilliseconds: nil, durationMilliseconds: 1, played: false, positionMilliseconds: 0) }
            try await world.store.databaseForTesting { db in try db.transaction { try db.replaceStatisticsUnits(episode: id, with: units) } }
            let before = await world.store.captureDigestInputsForTesting()
            try await world.raw("DELETE FROM statistics_units WHERE episode_id = ?", [.integer(id)])
            let inputs = await world.store.captureDigestInputsForTesting() - before
            // The before-image hashes the N units once; the after-image none (no units) plus the record fields.
            #expect(inputs <= Int64(count) + 4, "\(count) units: \(inputs) digest inputs")
        }
        #expect(world.oracle.mismatches.isEmpty, "\(world.oracle.report)")
        await world.close()
    }
}
