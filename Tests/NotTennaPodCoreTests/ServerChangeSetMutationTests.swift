import Foundation
import Testing
@testable import NotTennaPodCore

/// The capture's correctness mutations: each test-only fault of the capture, run against its named deterministic witness, must be
/// detected (an oracle mismatch, a failed write, or a broken work bound), never pass silently; and every witness passes
/// without its fault. The adoption and last-played mutations are the `mutated` cases of `ServerAdoptionBaselineTests`
/// and `ServerJournalListeningTests`. Each detection's first failure is printed (`MUTATION`) for the record.
@Suite(.serialized) struct ServerChangeSetMutationTests {
    typealias Fault = LibraryChangeCapture.Fault

    struct Witness: Sendable {
        let name: String
        let body: @Sendable (Bench) async throws -> Void
    }

    /// A server library (every watched table exists) with two podcasts, a queue, statistics units and the oracle.
    final class Bench: @unchecked Sendable {
        let fixture: ServerLibraryFixture
        let oracle = ChangeSetOracle()
        let log: CommitLog
        let feed: LibraryFeed, other: LibraryFeed
        var store: FeedLibraryStore { fixture.store }
        var ids: [Int64] { feed.episodes.map(\.id).sorted() }
        /// Failures that are not oracle mismatches (a write the capture made fail, a broken bound).
        var failures: [String] = []

        init(faults: Set<Fault>) async throws {
            fixture = try await ServerLibraryFixture()
            feed = try await fixture.store.insert(ServerLibraryFixture.fetched(count: 6))
            other = try await fixture.store.insert(ServerLibraryFixture.fetched("https://example.test/other.xml", title: "Other", count: 3))
            _ = try await fixture.store.enqueue([feed.episodes[0].id, other.episodes[0].id, feed.episodes[1].id])
            try await fixture.store.setChangeCaptureFaultsForTesting(faults)
            await fixture.store.installChangeOracleForTesting(oracle)
            log = await fixture.store.recordCommitsForTesting()
        }

        /// The queue's members in order, and an episode of the first podcast not in it.
        func queued() async throws -> [Int64] { try await store.queue().map(\.id) }
        func unqueued() async throws -> Int64 {
            let queue = Set(try await queued())
            return try #require(ids.first { !queue.contains($0) })
        }

        func sql(_ statements: String...) async throws {
            try await store.databaseForTesting { db in try db.transaction { for statement in statements { try db.execute(statement) } } }
        }

        var detected: [String] { oracle.mismatches.map(\.description) + failures }
    }

    static func run(_ witness: Witness, faults: Set<Fault>) async throws -> [String] {
        let bench = try await Bench(faults: faults)
        do { try await witness.body(bench) } catch { bench.failures.append("\(witness.name) threw \(error)") }
        let detected = bench.detected
        await bench.fixture.close()
        return detected
    }

    // MARK: - Witnesses

    static let markPlayed = Witness(name: "a played mark (episode upsert)") { try await $0.store.markEpisodePlayed(episodeID: $0.ids[2], played: true) }
    static let episodeUpdate = Witness(name: "an episode UPDATE (shown-ahead rows' statement form)") { bench in
        try await bench.sql("UPDATE episodes SET pubdate = pubdate + 1 WHERE id = \(bench.ids[2])")
    }
    static let episodeInsert = Witness(name: "an episode inserted into a shown podcast") { bench in
        try await bench.sql("INSERT INTO episodes(id, feed_id, pubdate, record) SELECT 9000, feed_id, pubdate + 1, record FROM episodes WHERE id = \(bench.ids[3])")
    }
    static let episodeDelete = Witness(name: "an episode deleted") { bench in try await bench.sql("DELETE FROM episodes WHERE id = \(bench.ids[4])") }
    static let feedInsert = Witness(name: "a podcast subscribed") { _ = try await $0.store.insert(ServerLibraryFixture.fetched("https://example.test/new.xml", title: "New", count: 2)) }
    static let feedUpdate = Witness(name: "a podcast's title changed") { bench in try await bench.sql("UPDATE feeds SET title = 'Changed' WHERE id = \(bench.feed.id)") }
    static let feedDelete = Witness(name: "a podcast deleted") { bench in try await bench.sql("DELETE FROM feeds WHERE id = \(bench.other.id)") }
    static let queueAdd = Witness(name: "a queue append") { _ = try await $0.store.enqueue([try await $0.unqueued()]) }
    static let queueInsert = Witness(name: "a queue row inserted (INSERT first)") { bench in
        try await bench.sql("INSERT INTO queue(position, episode_id) VALUES (100, \(try await bench.unqueued()))")
    }
    static let queueUpdate = Witness(name: "two queue positions swapped in place") { bench in
        let queue = try await bench.queued()
        try await bench.sql("UPDATE queue SET position = -1 WHERE episode_id = \(queue[0])",
                            "UPDATE queue SET position = 0 WHERE episode_id = \(queue[1])",
                            "UPDATE queue SET position = 1 WHERE episode_id = \(queue[0])")
    }
    static let queueDelete = Witness(name: "a queue removal") { _ = try await $0.store.removeFromQueue([try await $0.queued()[1]]) }
    static let queueRowDelete = Witness(name: "a queue row deleted (DELETE only)") { bench in
        try await bench.sql("DELETE FROM queue WHERE episode_id = \(try await bench.queued()[1])")
    }
    static let statisticsInsert = Witness(name: "statistics units added") { bench in
        try await bench.store.databaseForTesting { db in
            try db.transaction { try db.replaceStatisticsUnits(episode: bench.ids[0], with: [LibraryStatisticsUnit(episodeID: bench.ids[0], unitID: "u", playedMilliseconds: 5)]) }
        }
    }
    static let statisticsUpdate = Witness(name: "a statistics unit changed") { bench in
        try await bench.sql("INSERT INTO statistics_units(episode_id, unit_id, played_ms) VALUES (\(bench.ids[0]), 'v', 1)")
        bench.log.removeAll()
        try await bench.sql("UPDATE statistics_units SET played_ms = 2 WHERE unit_id = 'v'")
    }
    static let statisticsDelete = Witness(name: "statistics units deleted") { bench in
        try await bench.sql("INSERT INTO statistics_units(episode_id, unit_id, played_ms) VALUES (\(bench.ids[0]), 'w', 1)")
        try await bench.sql("DELETE FROM statistics_units WHERE unit_id = 'w'")
    }
    static let downloadInsert = Witness(name: "a download requested") { bench in
        _ = try await bench.store.requestDownload(episodeID: bench.ids[2], directory: bench.fixture.directory, enqueue: false)
    }
    static let downloadUpdate = Witness(name: "a download cancelled (job UPDATE)") { bench in
        let job = try #require(try await bench.store.requestDownload(episodeID: bench.ids[2], directory: bench.fixture.directory, enqueue: false))
        _ = try await bench.store.cancelDownload(id: job.id)
    }
    static let downloadActiveUpdate = Witness(name: "an active job's record changed while it stays active") { bench in
        let job = try #require(try await bench.store.requestDownload(episodeID: bench.ids[2], directory: bench.fixture.directory, enqueue: false))
        _ = try await bench.store.beginDownloadAttempt(id: job.id)
    }
    static let downloadDelete = Witness(name: "an active job deleted") { bench in
        _ = try await bench.store.requestDownload(episodeID: bench.ids[2], directory: bench.fixture.directory, enqueue: false)
        try await bench.sql("DELETE FROM download_jobs")
    }
    static let undoInsert = Witness(name: "a swipe's Undo guard written") { _ = try await $0.store.applySwipeMark(episodeID: $0.ids[3], action: .togglePlayed) }
    static let undoUpdate = Witness(name: "an Undo guard changed") { bench in
        try await bench.sql("INSERT INTO episode_swipe_undo(episode_id, operation_id) VALUES (\(bench.ids[3]), 'a')")
        try await bench.sql("UPDATE episode_swipe_undo SET operation_id = 'b'")
    }
    static let undoDelete = Witness(name: "an Undo guard removed") { bench in
        try await bench.sql("INSERT INTO episode_swipe_undo(episode_id, operation_id) VALUES (\(bench.ids[3]), 'a')")
        try await bench.sql("DELETE FROM episode_swipe_undo")
    }
    static let folderInsert = Witness(name: "a local folder link written") { bench in
        try await bench.sql("INSERT INTO local_folder_links(feed_id, record) VALUES (\(bench.feed.id), x'01')")
    }
    static let folderUpdate = Witness(name: "a local folder link changed") { bench in
        try await bench.sql("INSERT INTO local_folder_links(feed_id, record) VALUES (\(bench.feed.id), x'01')")
        try await bench.sql("UPDATE local_folder_links SET record = x'02'")
    }
    static let folderDelete = Witness(name: "a local folder link removed") { bench in
        try await bench.sql("INSERT INTO local_folder_links(feed_id, record) VALUES (\(bench.feed.id), x'01')")
        try await bench.sql("DELETE FROM local_folder_links")
    }
    static let pinnedInsert = Witness(name: "a pinned removal") { bench in try await bench.sql("INSERT INTO pinned_feed_removals(feed_id) VALUES (\(bench.feed.id))") }
    static let pinnedDelete = Witness(name: "a pinned removal released") { bench in
        try await bench.sql("INSERT INTO pinned_feed_removals(feed_id) VALUES (\(bench.feed.id))")
        try await bench.sql("DELETE FROM pinned_feed_removals")
    }
    static let hiddenFeedInsert = Witness(name: "a podcast hidden for removal") { bench in
        try await bench.sql("INSERT INTO ntp_hidden_feeds(feed_id, podcast_id, state) VALUES (\(bench.feed.id), NULL, 'removing')")
    }
    static let hiddenFeedDelete = Witness(name: "a staged podcast revealed") { bench in
        try await bench.sql("INSERT INTO ntp_hidden_feeds(feed_id, podcast_id, state) VALUES (\(bench.feed.id), NULL, 'staging')")
        try await bench.sql("DELETE FROM ntp_hidden_feeds")
    }
    static let hiddenEpisodeInsert = Witness(name: "an episode hidden") { bench in
        try await bench.sql("INSERT INTO ntp_hidden_episodes(episode_id, feed_id) VALUES (\(bench.ids[0]), \(bench.feed.id))")
    }
    static let hiddenEpisodeDelete = Witness(name: "a staged episode revealed") { bench in
        try await bench.sql("INSERT INTO ntp_hidden_episodes(episode_id, feed_id) VALUES (\(bench.ids[0]), \(bench.feed.id))")
        try await bench.sql("DELETE FROM ntp_hidden_episodes")
    }
    static let podcastPinned = Witness(name: "the server's pinned removal set and released") { bench in
        try await bench.sql("INSERT INTO ntp_podcasts(podcast_id, feed_id, pinned_removal) VALUES ('p1:test', \(bench.feed.id), 0) ON CONFLICT(podcast_id) DO NOTHING")
        try await bench.sql("UPDATE ntp_podcasts SET pinned_removal = 1 WHERE podcast_id = 'p1:test'")
        try await bench.sql("DELETE FROM ntp_podcasts WHERE podcast_id = 'p1:test'")
    }
    static let podcastInsertPinned = Witness(name: "a pinned podcast mapping inserted") { bench in
        try await bench.sql("INSERT INTO ntp_podcasts(podcast_id, feed_id, pinned_removal) VALUES ('p1:test', \(bench.feed.id), 1)")
    }
    static let appendRelinksNothing = Witness(name: "an append relinks nothing") { bench in
        _ = try await bench.store.enqueue([try await bench.unqueued()])
        let set = try #require(bench.log.take().set)
        if set.queue?.relinked.isEmpty != true { bench.failures.append("an append relinked \(set.queue?.relinked ?? [])") }
    }
    static let netZero = Witness(name: "an A→B→A transaction is empty") { bench in
        try await bench.sql("UPDATE episodes SET pubdate = pubdate + 9 WHERE id = \(bench.ids[0])", "UPDATE episodes SET pubdate = pubdate - 9 WHERE id = \(bench.ids[0])")
    }
    static let hideThenDelete = Witness(name: "a hide then a delete in one transaction") { bench in
        try await bench.sql("INSERT INTO pinned_feed_removals(feed_id) VALUES (\(bench.other.id))", "DELETE FROM episodes WHERE id = \(bench.other.episodes[1].id)",
                            "DELETE FROM pinned_feed_removals", "DELETE FROM episodes WHERE id = \(bench.other.episodes[2].id)")
    }
    static let upsertCommits = Witness(name: "a changed episode upsert commits") { bench in
        try await bench.store.setFavorite(episodeID: bench.ids[1], favorite: true)
        try await bench.store.databaseForTesting { db in
            try db.transaction { try db.replaceStatisticsUnits(episode: bench.ids[1], with: [LibraryStatisticsUnit(episodeID: bench.ids[1], unitID: "x", playedMilliseconds: 1)]) }
            try db.transaction { try db.replaceStatisticsUnits(episode: bench.ids[1], with: [LibraryStatisticsUnit(episodeID: bench.ids[1], unitID: "x", playedMilliseconds: 1)]) }
        }
    }
    static let digestOnce = Witness(name: "every image hashed once, at its first touch") { bench in
        let id = bench.ids[2]
        try await bench.store.databaseForTesting { db in
            try db.transaction { try db.replaceStatisticsUnits(episode: id, with: (0..<1_000).map { LibraryStatisticsUnit(episodeID: id, unitID: "u\($0)", playedMilliseconds: 1) }) }
        }
        // An episode and one of its units rewritten 500 times in one transaction: each image once.
        var before = await bench.store.captureDigestInputsForTesting()
        try await bench.store.databaseForTesting { db in
            try db.transaction {
                for round in 1...500 {
                    try db.execute("UPDATE episodes SET pubdate = pubdate + \(round % 2 == 0 ? 1 : -1) WHERE id = \(id)")
                    try db.execute("UPDATE statistics_units SET played_ms = played_ms + \(round % 2 == 0 ? 1 : -1) WHERE episode_id = \(id) AND unit_id = 'u7'")
                }
            }
        }
        var inputs = await bench.store.captureDigestInputsForTesting() - before
        if inputs > 16 { bench.failures.append("500 rewrites of an episode and a unit: \(inputs) digest inputs") }
        // 1,000 units deleted: each unit once.
        before = await bench.store.captureDigestInputsForTesting()
        try await bench.sql("DELETE FROM statistics_units WHERE episode_id = \(id)")
        inputs = await bench.store.captureDigestInputsForTesting() - before
        if inputs > 1_004 { bench.failures.append("1,000 units deleted: \(inputs) digest inputs") }
    }
    static let favoriteWithUnits = Witness(name: "a favorite on an episode with 1,000 statistics units reads none of them") { bench in
        let id = bench.ids[2]
        try await bench.store.databaseForTesting { db in
            try db.transaction { try db.replaceStatisticsUnits(episode: id, with: (0..<1_000).map { LibraryStatisticsUnit(episodeID: id, unitID: "u\($0)", playedMilliseconds: 1) }) }
        }
        let before = await bench.store.captureDigestInputsForTesting()
        try await bench.store.setFavorite(episodeID: id, favorite: true)
        let inputs = await bench.store.captureDigestInputsForTesting() - before
        if inputs > 16 { bench.failures.append("a favorite: \(inputs) digest inputs") }
    }
    static let unchangedMapping = Witness(name: "an unchanged podcast mapping captures nothing") { bench in
        try await bench.sql("INSERT INTO ntp_podcasts(podcast_id, feed_id, pinned_removal) VALUES ('p1:same', \(bench.feed.id), 0) ON CONFLICT(podcast_id) DO NOTHING")
        let before = await bench.store.captureChangesWrittenForTesting()
        try await bench.sql("INSERT INTO ntp_podcasts(podcast_id, feed_id, pinned_removal) VALUES ('p1:same', \(bench.feed.id), 0) ON CONFLICT(podcast_id) DO UPDATE SET feed_id = excluded.feed_id, pinned_removal = excluded.pinned_removal")
        let written = await bench.store.captureChangesWrittenForTesting() - before
        if written > 0 { bench.failures.append("an unchanged mapping wrote \(written) capture rows") }
    }
    static let knowledge = Witness(name: "position knowledge from records, overlays, sessions, pins and holds") { bench in
        let local = bench.ids[0]
        try await bench.sql("INSERT INTO ntp_episodes(episode_id, local_id, podcast_id, kind, value) VALUES ('e1:k', \(local), 'p1:k', 'guid', 'k')")
        bench.log.removeAll()
        let steps: [(String, String)] = [
            ("record", "INSERT INTO ntp_records(entity, id, field_group, value) VALUES ('episode', 'e1:k', 'position', x'7b7d')"),
            ("overlay", "INSERT INTO ntp_overlays(op_id, entity, id, property, kind, clock) VALUES ('o', 'episode', 'e1:k', 'position', 'claim', 1)"),
            ("overlay retired", "DELETE FROM ntp_overlays WHERE op_id = 'o'"),
            ("pin", "INSERT INTO ntp_deferred_pins(episode_id, fields) VALUES ('e1:k', 1)"),
            ("pin released", "DELETE FROM ntp_deferred_pins"),
            ("hold", "INSERT INTO ntp_recovery_holds(entity, id, field_group, nodes) VALUES ('episode', 'e1:k', 'position', '[]')"),
            ("hold released", "DELETE FROM ntp_recovery_holds"),
            ("recovery state", "UPDATE ntp_library SET recovery = x'7b7d' WHERE id = 1"),
        ]
        for (label, statement) in steps {
            try await bench.store.databaseForTesting { db in try db.transaction { for part in statement.split(separator: ";") { try db.execute(String(part)) } } }
            let knowledge = bench.log.take().knowledge
            let told = label == "recovery state" ? knowledge?.all == true : knowledge?.episodes.contains(local) == true
            if !told { bench.failures.append("\(label): no position knowledge") }
        }
    }

    static let controls: [Witness] = [markPlayed, episodeUpdate, queueInsert, queueRowDelete, episodeInsert, episodeDelete, feedInsert, feedUpdate, feedDelete, queueAdd, queueUpdate, queueDelete,
                                      statisticsInsert, statisticsUpdate, statisticsDelete, downloadInsert, downloadUpdate, downloadActiveUpdate, downloadDelete,
                                      undoInsert, undoUpdate, undoDelete, folderInsert, folderUpdate, folderDelete, pinnedInsert, pinnedDelete,
                                      hiddenFeedInsert, hiddenFeedDelete, hiddenEpisodeInsert, hiddenEpisodeDelete, podcastPinned, podcastInsertPinned,
                                      appendRelinksNothing, netZero, hideThenDelete, upsertCommits, digestOnce, favoriteWithUnits, unchangedMapping, knowledge]

    /// Each fault and the witness that must catch it.
    static let mutations: [(String, Set<Fault>, Witness)] = [
        ("episodes INSERT trigger dropped", [.dropTrigger("ntp_vis_episodes_bi")], episodeInsert),
        ("episodes UPDATE trigger dropped", [.dropTrigger("ntp_vis_episodes_bu")], episodeUpdate),
        ("episodes DELETE trigger dropped", [.dropTrigger("ntp_vis_episodes_bd")], episodeDelete),
        ("feeds INSERT trigger dropped", [.dropTrigger("ntp_vis_feeds_bi")], feedInsert),
        ("feeds UPDATE trigger dropped", [.dropTrigger("ntp_vis_feeds_bu")], feedUpdate),
        ("feeds DELETE trigger dropped", [.dropTrigger("ntp_vis_feeds_bd")], feedDelete),
        ("queue INSERT trigger dropped", [.dropTrigger("ntp_vis_queue_bi")], queueInsert),
        ("queue UPDATE trigger dropped", [.dropTrigger("ntp_vis_queue_bu")], queueUpdate),
        ("queue DELETE trigger dropped", [.dropTrigger("ntp_vis_queue_bd")], queueRowDelete),
        ("statistics INSERT trigger dropped", [.dropTrigger("ntp_vis_statistics_units_bi")], statisticsInsert),
        ("statistics UPDATE trigger dropped", [.dropTrigger("ntp_vis_statistics_units_bu")], statisticsUpdate),
        ("statistics DELETE trigger dropped", [.dropTrigger("ntp_vis_statistics_units_bd")], statisticsDelete),
        ("download INSERT trigger dropped", [.dropTrigger("ntp_vis_download_jobs_bi")], downloadInsert),
        ("download UPDATE trigger dropped", [.dropTrigger("ntp_vis_download_jobs_bu")], downloadUpdate),
        ("download UPDATE trigger dropped (active to active)", [.dropTrigger("ntp_vis_download_jobs_bu")], downloadActiveUpdate),
        ("download DELETE trigger dropped", [.dropTrigger("ntp_vis_download_jobs_bd")], downloadDelete),
        ("undo INSERT trigger dropped", [.dropTrigger("ntp_vis_episode_swipe_undo_bi")], undoInsert),
        ("undo UPDATE trigger dropped", [.dropTrigger("ntp_vis_episode_swipe_undo_bu")], undoUpdate),
        ("undo DELETE trigger dropped", [.dropTrigger("ntp_vis_episode_swipe_undo_bd")], undoDelete),
        ("folder INSERT trigger dropped", [.dropTrigger("ntp_vis_local_folder_links_bi")], folderInsert),
        ("folder UPDATE trigger dropped", [.dropTrigger("ntp_vis_local_folder_links_bu")], folderUpdate),
        ("folder DELETE trigger dropped", [.dropTrigger("ntp_vis_local_folder_links_bd")], folderDelete),
        ("pinned removal INSERT trigger dropped", [.dropTrigger("ntp_vis_pinned_feed_removals_bi")], pinnedInsert),
        ("pinned removal DELETE trigger dropped", [.dropTrigger("ntp_vis_pinned_feed_removals_bd")], pinnedDelete),
        ("hidden podcast INSERT trigger dropped", [.dropTrigger("ntp_vis_ntp_hidden_feeds_bi")], hiddenFeedInsert),
        ("hidden podcast DELETE trigger dropped", [.dropTrigger("ntp_vis_ntp_hidden_feeds_bd")], hiddenFeedDelete),
        ("hidden episode INSERT trigger dropped", [.dropTrigger("ntp_vis_ntp_hidden_episodes_bi")], hiddenEpisodeInsert),
        ("hidden episode DELETE trigger dropped", [.dropTrigger("ntp_vis_ntp_hidden_episodes_bd")], hiddenEpisodeDelete),
        ("podcast mapping UPDATE trigger dropped", [.dropTrigger("ntp_vis_ntp_podcasts_bu")], podcastPinned),
        ("podcast mapping INSERT trigger dropped", [.dropTrigger("ntp_vis_ntp_podcasts_bi")], podcastInsertPinned),
        ("former feed dropped", [.noFormerParent], episodeDelete),
        ("queue: every member relinked", [.queueAllMembers], appendRelinksNothing),
        ("raw writes, no net difference", [.rawWrites], netZero),
        ("no start visibility (expansion)", [.noStartVisibility], hideThenDelete),
        ("constrained keys with inner OR IGNORE", [.uniqueKeyOrIgnore], upsertCommits),
        ("digest before the presence check", [.digestBeforeGuard], digestOnce),
        ("an episode's statistics image hashes its units", [.unitsInEpisodeDigest], favoriteWithUnits),
        ("expansion on columns named", [.gateByColumns], unchangedMapping),
        ("a podcast's removal not collapsed", [.noCollapse], feedDelete),
        ("records knowledge trigger dropped", [.dropTrigger("ntp_vis_ntp_records_ai")], knowledge),
        ("overlay retirement knowledge dropped", [.dropTrigger("ntp_vis_ntp_overlays_ad")], knowledge),
        ("pin release knowledge dropped", [.dropTrigger("ntp_vis_ntp_deferred_pins_ad")], knowledge),
        ("hold release knowledge dropped", [.dropTrigger("ntp_vis_ntp_recovery_holds_ad")], knowledge),
        ("recovery state knowledge dropped", [.dropTrigger("ntp_vis_ntp_library_au")], knowledge),
    ]

    @Test func everyWitnessPassesWithoutItsFault() async throws {
        for witness in Self.controls {
            let detected = try await Self.run(witness, faults: [])
            #expect(detected.isEmpty, "\(witness.name): \(detected.prefix(3).joined(separator: "\n"))")
            if !detected.isEmpty { print("CONTROL \(witness.name): \(detected.first.map { String($0.prefix(400)) } ?? "")") }
        }
    }

    @Test func everyFaultIsCaughtByItsWitness() async throws {
        for (name, faults, witness) in Self.mutations {
            let detected = try await Self.run(witness, faults: faults)
            #expect(!detected.isEmpty, "\(name) passed \(witness.name) silently")
            print("MUTATION \(name) | \(witness.name) | \(detected.first.map { String($0.prefix(300)) } ?? "NOT DETECTED")")
        }
    }

    /// The engine's per-step delivery: another device's change applied by a unit is told to the screens with its
    /// exact set; skipping the delivery (a fault) tells nothing.
    @Test(arguments: [false, true]) func aUnitsChangeIsToldExactly(mutated: Bool) async throws {
        let fixture = try await ServerLibraryFixture()
        let small = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/small.xml", title: "Small", count: 2)).feed
        try await fixture.store.retireEverythingForTesting()
        let engine = try await ServerBoundedCutoverTests.serve(fixture, try ServerBoundedCutoverTests.arrivingRecords(count: 5))
        await engine.recordPublishedChangesForTesting()
        if mutated { await engine.setSkipChangeDelivery(true) }
        let log = await fixture.store.recordCommitsForTesting()
        let report = await engine.exchange()
        let told = await engine.takePublishedChangesForTesting()
        let committed = log.commits.filter { $0.origin == .sync }.compactMap(\.set)
        #expect(!committed.isEmpty && report.appliedUnits == 1, "\(report)")
        if mutated {
            #expect(told.isEmpty && !report.libraryChanged)
            print("MUTATION engine delivery skipped | a unit's change told | told \(told.count) sets for \(committed.count) committed")
        } else {
            let keys = { (sets: [LibraryChangeSet]) in sets.reduce(into: Set<String>()) { $0.formUnion(ServerChangeSetCaptureTests.Run.keys($1)) } }
            #expect(keys(told) == keys(committed) && report.libraryChanged, "told \(keys(told)) committed \(keys(committed))")
            #expect(told.allSatisfy { $0.origin == .sync && !$0.isEmpty })
        }
        _ = small
        await engine.close()
        await fixture.close()
    }
}

extension FeedLibraryStore {
    func captureChangesWrittenForTesting() -> Int64 { database.capture?.changesWritten ?? 0 }
}
