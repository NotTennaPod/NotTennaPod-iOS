import Foundation
import Testing
@testable import NotTennaPodCore

/// The rebuild equivalence's own checks: it compares the complete visible model (a wrong projected field is a
/// difference, whatever the field), and a clean full reprojection keeps the device's own inputs (a paused player's
/// resume point no fact carries) as the live library does.
@Suite(.serialized) struct ServerChangeSetRebuildTests {
    /// Negative controls: one projected field of an episode made wrong while its records stand (the title, the media
    /// size, the publication date, the favorite, the played state, the played time): the rebuild comparison reports each.
    @Test(arguments: ["title", "media size", "publication date", "favorite", "played", "played time"])
    func theRebuildDetectsAWrongProjectedField(field: String) async throws {
        let (fixture, _, one, _) = try await ServerLocalPlaybackTests.library()
        let store = fixture.store
        let clean = try await ServerChangeSetCaptureTests.rebuildDifferences(store, ownedRoot: fixture.directory, archive: nil)
        #expect(clean.isEmpty, "clean before: \(clean.prefix(3))")
        func set(_ path: String, _ value: String) -> String { "record = CAST(json_set(CAST(record AS TEXT), '\(path)', \(value)) AS BLOB)" }
        let change = switch field {
        case "title": set("$.details.title", "'Wrong'")
        case "media size": set("$.details.media.size", "123456")
        case "publication date": "pubdate = pubdate + 86400000, " + set("$.details.publicationDate", "json_extract(CAST(record AS TEXT), '$.details.publicationDate') + 86400")
        case "favorite": set("$.userState.isFavorite", "json('true')")
        case "played": set("$.userState.playState", "1")
        default: set("$.userState.playedDurationMilliseconds", "777777")
        }
        try await store.databaseForTesting { db in try db.execute("UPDATE episodes SET \(change) WHERE id = \(one)") }
        let differences = try await ServerChangeSetCaptureTests.rebuildDifferences(store, ownedRoot: fixture.directory, archive: nil)
        #expect(!differences.isEmpty, "a wrong \(field) passes the rebuild comparison")
        await fixture.close()
    }

    /// Against the server: the person moves a paused, never-played episode 120 s on, then plays another. No fact carries
    /// that position (PROTOCOL §8: it is this phone's resume point), and the server keeps its own. A rebuild of the same
    /// library and a Force full synchronization keep the person's 120 s. Dropping the device's own position in a full
    /// projection (a mutation, the earlier behaviour) loses it.
    @Test(arguments: [false, true]) func aPausedSeekStaysThroughARebuildAndForceFullSynchronization(mutated: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, _, _, ids, _) = try await ServerExchangeConcurrencyTests.twoPhones(world)
            ServerProjector.dropsDevicePositionsForTesting = mutated
            defer { ServerProjector.dropsDevicePositionsForTesting = false }
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(ids[0])
            let chosen = player.position + 120_000
            try await player.seek(to: chosen); try await player.pause()
            try await player.load(ids[1])
            await a.exchange()
            #expect(try await a.store.episode(id: ids[0])?.userState.positionMilliseconds == chosen, "the live library keeps it")
            let differences = try await ServerChangeSetCaptureTests.rebuildDifferences(a)
            await a.engine.requestFullSynchronization()
            _ = await a.engine.forceFullSynchronization()
            let after = try await a.store.episode(id: ids[0])?.userState.positionMilliseconds
            if mutated {
                #expect(!differences.isEmpty && after != chosen, "lost: \(String(describing: after))")
            } else {
                #expect(differences.isEmpty, "\(differences.prefix(3))")
                #expect(after == chosen, "after Force full synchronization: \(String(describing: after))")
            }
        }
    }

    /// Negative controls inside the own-parse population: on the phone that registered the feed itself, after the
    /// server's canonical records arrived (its registration resolved), a wrong title and media size, a wrong duration
    /// where a measured duration is canonical, and a publication date shifted in both its column and its record are each
    /// reported, and a real Force full synchronization repairs each.
    /// Found by seed 1: a NEW episode swiped (dismissed), then played and still playing (the session's start dismisses it
    /// too, its saves not exported yet), then the swipe undone (NEW restored). The live library shows NEW, the person's last
    /// action, and a full reprojection of the same inputs shows NEW too: the Undo exports the session's listening before
    /// its restore, so the session's dismissal is ordered before the restore.
    @Test func aSessionDismissalBeforeAnUndoKeepsItsOrderInARebuild() async throws {
        try await ExchangeWorld.run { world in
            let (a, _, _, _, podcast) = try await ServerExchangeConcurrencyTests.twoPhones(world)
            world.setFeed("/one.xml", ("One", "one", 6))
            _ = try? await a.transport.server.send("POST", "v1/refresh", body: ["podcast_id": .string(podcast)])
            func newest() async throws -> LibraryEpisode? { try await a.store.feeds().flatMap(\.episodes).first { $0.details.identifier == "one-6" } }
            let deadline = ContinuousClock.now + .seconds(60)
            while ContinuousClock.now < deadline, try await newest() == nil { await a.exchange(); try await Task.sleep(for: .milliseconds(100)) }
            let episode = try #require(try await newest())
            try #require(episode.userState.playState == .new, "filed in the Inbox")
            let receipt = try #require(try await a.store.applySwipeMark(episodeID: episode.id, action: .togglePlayed))
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(episode.id); try await player.play(); try await player.listen(41)
            #expect(try await a.store.undoSwipeMark(receipt) == .restored)
            #expect(try await a.store.episode(id: episode.id)?.userState.playState == .new, "the Undo restores NEW")
            let differences = try await Capture.rebuildDifferences(a)
            #expect(differences.isEmpty, "\(differences.prefix(2))")
        }
    }

    /// The own parse supplies a registered feed's header and its episodes' details only until the canonical records next
    /// change: after the publisher renames the podcast (a new canonical revision, applied), the live header or an
    /// episode's title rolled back to the obsolete parse's, the new records kept, is reported.
    @Test(arguments: ["podcast", "episode"])
    func obsoleteOwnParseMustNotExcuseRollback(rolledBack: String) async throws {
        try await ExchangeWorld.run { world in
            let (a, _, feed, ids, podcast) = try await ServerExchangeConcurrencyTests.twoPhones(world)
            for _ in 0..<2 { await a.exchange() }
            #expect(try await Capture.rebuildDifferences(a).isEmpty, "clean, the first canonical records seen")
            let path = try #require(try await a.store.databaseForTesting { $0.fileURL?.path })
            let parse = try #require(OwnParses.parses(of: path)[OwnParses.address(feed.source)])
            // A new canonical revision: the publisher renames the podcast (and so its episodes' titles).
            world.setFeed("/one.xml", ("One renamed", "one", 5))
            _ = try? await a.transport.server.send("POST", "v1/refresh", body: ["podcast_id": .string(podcast)])
            let deadline = ContinuousClock.now + .seconds(60)
            func renamed() async throws -> Bool { try await a.store.feeds().first { $0.id == feed.id }?.title == "One renamed" }
            while ContinuousClock.now < deadline, !(try await renamed()) { await a.exchange(); try await Task.sleep(for: .milliseconds(100)) }
            try #require(try await renamed(), "the canonical revision applied")
            #expect(try await Capture.rebuildDifferences(a).isEmpty, "the live library shows the canonical revision")
            // Rolled back to the obsolete parse, the new canonical records kept.
            if rolledBack == "podcast" {
                let metadata = String(decoding: try JSONSerialization.data(withJSONObject: parse.feed["metadata"] ?? [:]), as: UTF8.self)
                try await a.store.databaseForTesting { db in
                    try db.execute("UPDATE feeds SET title = ?, record = CAST(json_set(CAST(record AS TEXT), '$.metadata', json(?)) AS BLOB) WHERE id = ?",
                                   [parse.title.map(LibrarySQLValue.text) ?? .null, .text(metadata), .integer(feed.id)])
                }
            } else {
                let episode = try #require(try await a.store.episode(id: ids[0]))
                let old = try #require((parse.episodes[episode.details.identifier ?? ""]?["details"] as? NSDictionary)?["title"] as? String)
                try await a.store.databaseForTesting { db in
                    try db.execute("UPDATE episodes SET record = CAST(json_set(CAST(record AS TEXT), '$.details.title', ?) AS BLOB) WHERE id = ?",
                                   [.text(old), .integer(ids[0])])
                }
            }
            let found = try await Capture.rebuildDifferences(a)
            #expect(!found.isEmpty, "a \(rolledBack) rolled back to the obsolete parse passes the rebuild")
        }
    }

    @Test(arguments: ["title and size", "measured duration", "publication date"])
    func ownParseFeedsStayComparedAfterCanonicalReceipt(corruption: String) async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, ids, _) = try await ServerExchangeConcurrencyTests.twoPhones(world)
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(ids[0])
            try await player.play(); try await player.listen(10); try await player.pause()
            player.skipKeepsEpisode = true
            _ = try await player.end(.skipped)
            for _ in 0..<2 { await a.exchange(); await b.exchange() }
            #expect(try await a.store.pendingServerRegistrationsForTesting().isEmpty, "resolved")
            let wire = try #require(try await a.store.wireEpisodeForTesting(ids[0]))
            let clean = try await ServerChangeSetCaptureTests.rebuildDifferences(a)
            #expect(clean.isEmpty, "clean: \(clean.prefix(3))")
            func set(_ path: String, _ value: String) -> String { "record = CAST(json_set(CAST(record AS TEXT), '\(path)', \(value)) AS BLOB)" }
            let change: String
            switch corruption {
            case "title and size":
                change = "record = CAST(json_set(CAST(record AS TEXT), '$.details.title', 'Wrong', '$.details.media.size', 123456) AS BLOB)"
            case "measured duration":
                #expect(try a.rows("SELECT CAST(value AS TEXT) FROM ntp_records WHERE entity = 'episode' AND id = '\(wire)' AND field_group = 'measured_duration'").count == 1,
                        "a measured duration is canonical")
                change = set("$.details.media.durationMilliseconds", "1234")
            default:
                change = "pubdate = pubdate + 86400000, " + set("$.details.publicationDate", "json_extract(CAST(record AS TEXT), '$.details.publicationDate') + 86400")
            }
            let before = try #require(try await a.store.episode(id: ids[0]))
            try await a.store.databaseForTesting { db in try db.execute("UPDATE episodes SET \(change) WHERE id = \(ids[0])") }
            let differences = try await ServerChangeSetCaptureTests.rebuildDifferences(a)
            #expect(!differences.isEmpty, "\(corruption) passes the rebuild comparison on the registering phone")
            await a.engine.requestFullSynchronization()
            _ = await a.engine.forceFullSynchronization()
            let repaired = try #require(try await a.store.episode(id: ids[0]))
            #expect(repaired.details.title == before.details.title && repaired.details.media?.size == before.details.media?.size
                    && repaired.details.media?.durationMilliseconds == before.details.media?.durationMilliseconds
                    && repaired.details.publicationDate == before.details.publicationDate, "Force full repairs it: \(repaired.details)")
        }
    }

    // MARK: - The named exceptions, each reached, set aside and gone once its condition resolves

    typealias Capture = ServerChangeSetCaptureTests

    /// "own parse": the second seeded run (each phone subscribes, unsubscribes and subscribes again to
    /// podcasts whose metadata the server holds) reaches it; every rebuild difference it sets aside is confined to a
    /// registered feed's header or its episodes' details, and the run passes every oracle.
    @Test func ownParseIsReachedAndConfined() async throws {
        let before = Capture.knownStatusGaps.withLock { $0 }
        let run = try await Capture.run(seed: 2, steps: 60)
        #expect(run.problems.isEmpty, "\(run.problems.prefix(2))")
        #expect(Capture.knownStatusGaps.withLock { $0 } > before, "reached")
    }

    /// "pending registration": A unsubscribes the podcast and subscribes to it again before exchanging. While that
    /// registration is pending the rebuild's difference is set aside (counted); once it resolves there is none.
    @Test func aPendingRegistrationIsSetAsideUntilItResolves() async throws {
        try await ExchangeWorld.run { world in
            let (a, _, feed, _, _) = try await ServerExchangeConcurrencyTests.twoPhones(world)
            _ = try await a.store.requestFeedDeletion(feedID: feed.id)
            _ = try await a.store.subscribeForTesting(ServerExchangeAgreementTests.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            let before = Capture.knownRegistrationGaps.withLock { $0 }
            #expect(try await Capture.rebuildDifferences(a).isEmpty)
            #expect(Capture.knownRegistrationGaps.withLock { $0 } > before, "reached while pending")
            for _ in 0..<3 { await a.exchange() }
            #expect(try await a.store.pendingServerRegistrationsForTesting().isEmpty, "resolved")
            let resolved = Capture.knownRegistrationGaps.withLock { $0 }
            #expect(try await Capture.rebuildDifferences(a).isEmpty)
            #expect(Capture.knownRegistrationGaps.withLock { $0 } == resolved, "nothing set aside once resolved")
        }
    }

    /// "downloaded size": a finished download's file size differs from the feed's; the rebuild applies the stored
    /// metadata's size, which the live library keeps until that record changes. Only that is set aside (counted).
    @Test func aDownloadedSizeIsSetAside() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, ids, _) = try await ServerExchangeConcurrencyTests.twoPhones(world)
            await b.exchange()
            let onB = try await ServerExchangeConcurrencyTests.same(ids[0], from: a, on: b)
            let job = try #require(try await b.store.requestDownload(episodeID: onB, directory: world.root.appendingPathComponent("downloads"), enqueue: false))
            let attempt = try #require(try await b.store.beginDownloadAttempt(id: job.id))
            try FileManager.default.createDirectory(at: attempt.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 2_345).write(to: attempt.destination)
            #expect(try await b.store.attachDownloadFile(id: job.id, attempt: attempt.attempts))
            #expect(try await b.store.completeDownload(id: job.id, attempt: attempt.attempts))
            try await b.store.noteDownloadedSizeForTesting(episode: onB)
            let before = Capture.knownDownloadSizes.withLock { $0 }
            #expect(try await Capture.rebuildDifferences(b).isEmpty)
            #expect(Capture.knownDownloadSizes.withLock { $0 } > before, "reached")
        }
    }

    /// "superseded own claim": B listens to an episode without pausing (its start accepted); A then plays it (A's claim
    /// owns the position); B, still playing, receives A's record and ends its session. B shows its own listening position while
    /// its end is pending; the projection of that pending end under a claim that no longer owns the position shows A's.
    /// That difference is set aside (counted); once B's end is received, B shows A's position and nothing differs.
    @Test func aSupersededOwnClaimIsSetAsideUntilItsReceipt() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, ids, _) = try await ServerExchangeConcurrencyTests.twoPhones(world)
            let onB = try await ServerExchangeConcurrencyTests.same(ids[0], from: a, on: b)
            await b.exchange()
            let playerB = StorePlayer(b.store, realTime: ())
            try await playerB.load(onB)
            try await playerB.play(); try await playerB.listen(30)
            await b.exchange()
            let playerA = StorePlayer(a.store, realTime: ())
            try await playerA.load(ids[0])
            try await playerA.play(); try await playerA.listen(10); try await playerA.pause()
            await a.exchange()
            await b.run([.pull, .apply])
            try await playerB.listen(10)
            // A skip that leaves the player (the episode no longer selected, so nothing pins it).
            playerB.skipKeepsEpisode = true
            _ = try await playerB.end(.skipped)
            let before = Capture.knownCompletionGaps.withLock { $0 }
            let pending = try await Capture.rebuildDifferences(b)
            #expect(pending.isEmpty, "\(pending.prefix(3))")
            let reached = Capture.knownCompletionGaps.withLock { $0 } > before
            for _ in 0..<2 { await b.exchange(); await a.exchange() }
            #expect(try await Capture.rebuildDifferences(b).isEmpty)
            let shownB = try await b.store.episode(id: onB)?.userState.positionMilliseconds
            let shownA = try await a.store.episode(id: ids[0])?.userState.positionMilliseconds
            #expect(shownB == shownA, "B shows the owner's position once received: \(String(describing: shownB)) vs \(String(describing: shownA))")
            #expect(reached, "the superseded own claim was reached")
        }
    }
}

extension FeedLibraryStore {
    func pendingServerRegistrationsForTesting() throws -> [String: Int64?] { try pendingServerRegistrations() }
}
