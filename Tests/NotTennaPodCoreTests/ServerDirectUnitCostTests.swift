import Foundation
import Testing
@testable import NotTennaPodCore

/// A direct unit's statements cost what the commit changes, not what the library holds (PROTOCOL §6.8: a direct unit holds the
/// live lock at most 20 ms): the removal of a large podcast, another podcast subscribed elsewhere and a queue edit cost
/// about the same in a library ten times larger. Counted in SQLite's virtual machine steps, not in time.
@Suite(.serialized, .timeLimit(.minutes(10))) struct ServerDirectUnitCostTests {
    typealias Cutover = ServerBoundedCutoverTests

    /// The steps the store's connection runs to apply `records` as a direct unit, on a library holding the arriving
    /// podcast with `episodes` episodes (its first three queued), every other one of which was queued once and left.
    static func steps(episodes: Int, _ records: [ServerRecord]) async throws -> Int64 {
        let fixture = try await ServerLibraryFixture()
        let applier = try await ServerProjectionUnitTests.Applier(fixture)
        try await applier.apply(try Cutover.arrivingRecords(count: episodes))
        try await applier.apply(stride(from: 4, through: episodes, by: 2).map {
            ServerProjectionUnitTests.membership(Cutover.wire($0), Cutover.arrivingGeneration, false)
        })
        let before = await fixture.store.statementStepsForTesting()
        let result = try await applier.apply(records)
        let after = await fixture.store.statementStepsForTesting()
        #expect(!result.published && result.work < 250, "a direct unit: \(result)")
        await fixture.close()
        return after - before
    }

    /// The same unit on a library of 600 and of 6,000 episodes: within a small allowance of each other.
    static func expectBounded(_ label: String, _ records: @autoclosure () throws -> [ServerRecord],
                              sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let small = try await steps(episodes: 600, try records())
        let large = try await steps(episodes: 6_000, try records())
        print("COST \(label): \(small) steps with 600 episodes, \(large) with 6,000")
        #expect(large < small + small / 2 + 2_000, "\(label): \(small) steps with 600 episodes, \(large) with 6,000", sourceLocation: sourceLocation)
    }

    /// Another device removes the podcast: hidden in its unit, its episodes never listed there (they go afterwards).
    @Test func aLargeRemovalsUnitDoesNotGrowWithThePodcast() async throws {
        try await Self.expectBounded("removal", [Cutover.removal(Cutover.arriving, Cutover.arrivingGeneration)])
    }

    /// Another podcast subscribed elsewhere: its episodes are found by podcast, the queue's members by their own index.
    @Test func aSubscriptionsUnitDoesNotGrowWithTheLibrary() async throws {
        let podcast = "p1:" + String(repeating: "9", count: 64)
        try await Self.expectBounded("subscription", [
            ServerRecord(entity: "podcast", id: podcast, fieldGroup: "identity", value: ["refresh_url": "https://example.test/queue.xml",
                "aliases": [["url": "https://example.test/queue.xml", "normalized": "https://example.test/queue.xml"]]]),
            ServerRecord(entity: "podcast", id: podcast, fieldGroup: "subscription", value: ["state": "subscribed", "generation_id": .string("g1:" + String(repeating: "9", count: 64))]),
            ServerRecord(entity: "podcast", id: podcast, fieldGroup: "policy", value: ["keep_updated": true, "new_episodes_action": "global"])])
    }

    /// One bounded transaction of a hidden removal reads its next batch only, not the podcast's whole list.
    @Test func aHiddenRemovalBatchDoesNotGrowWithThePodcast() async throws {
        func batch(_ episodes: Int) async throws -> Int64 {
            let fixture = try await ServerLibraryFixture()
            let applier = try await ServerProjectionUnitTests.Applier(fixture)
            try await applier.apply(try Cutover.arrivingRecords(count: episodes))
            try await applier.apply([Cutover.removal(Cutover.arriving, Cutover.arrivingGeneration)])
            let before = await fixture.store.statementStepsForTesting()
            #expect(try await fixture.store.deleteHiddenRemovalBatch().progressed)
            let after = await fixture.store.statementStepsForTesting()
            await fixture.close()
            return after - before
        }
        let small = try await batch(600), large = try await batch(6_000)
        print("COST hidden removal batch: \(small) steps with 600 episodes, \(large) with 6,000")
        #expect(large < small + small / 2 + 2_000, "\(small) steps with 600 episodes, \(large) with 6,000")
    }

    /// Queue edits of twenty episodes: the projection reads and decodes each row once (the feed's and the twenty
    /// episodes', which nothing of the edit changes and which are not projected as rows), not again for every step, and
    /// reads the episodes' mappings, identities, queue records and overlays a few statements for all of them.
    @Test func aProjectionDecodesEachRowOnce() async throws {
        let fixture = try await ServerLibraryFixture()
        try await ServerProjectionUnitTests.Applier(fixture).apply(try Cutover.arrivingRecords(count: 600))
        var low: QueueKey?
        let records = try (100..<120).flatMap { number -> [ServerRecord] in
            let key = try QueueKey.between(low, nil, positionWriteID: UUID())
            low = key
            return [ServerProjectionUnitTests.membership(Cutover.wire(number), Cutover.arrivingGeneration, true),
                    ServerProjectionUnitTests.position(Cutover.wire(number), Cutover.arrivingGeneration, key)]
        }
        let connection = try LibrarySQLite(readingOnly: fixture.url)
        defer { try? connection.close() }
        let library = try #require(try connection.rows("SELECT namespace, account_id FROM ntp_library WHERE id = 1").first)
        let projector = ServerProjector(db: connection, namespace: try #require(library[0].text), accountID: try #require(library[1].text),
                                        now: 1_760_000_000_000) { _ in throw ServerApplyError.needsLocalIDs }
        var scope = ServerProjectionScope()
        for record in records {
            projector.delta[record.key] = record
            scope.add(record: record.entity, id: record.id, group: record.fieldGroup)
        }
        let before = connection.statementsRun
        try connection.transaction(write: false) { try projector.project(scope) }
        let statements = connection.statementsRun - before
        print("COST queue edits of twenty episodes: \(projector.rowDecodes) rows decoded, \(statements) statements")
        #expect(projector.rowDecodes <= 3 + 1 + 20, "the feed and the queued episodes once each: \(projector.rowDecodes)")
        #expect(statements <= 60, "a few statements for all twenty, not several each: \(statements)")
        #expect(projector.plan.queue?.count == 23, "the queue is projected: \(String(describing: projector.plan.queue?.count))")
        await fixture.close()
    }

    /// A direct unit prepares each distinct statement once and reuses it (its keyed statements run hundreds of times
    /// inside the lock).
    @Test func aDirectUnitReusesItsStatements() async throws {
        let fixture = try await ServerLibraryFixture()
        let applier = try await ServerProjectionUnitTests.Applier(fixture)
        try await applier.apply(try Cutover.arrivingRecords(count: 600))
        var low: QueueKey?
        let records = try (100..<120).flatMap { number -> [ServerRecord] in
            let key = try QueueKey.between(low, nil, positionWriteID: UUID())
            low = key
            return [ServerProjectionUnitTests.membership(Cutover.wire(number), Cutover.arrivingGeneration, true),
                    ServerProjectionUnitTests.position(Cutover.wire(number), Cutover.arrivingGeneration, key),
                    ServerRecord(entity: "episode", id: Cutover.wire(number), fieldGroup: "play_state",
                                 value: ["generation_id": .string(Cutover.arrivingGeneration), "play_state": "unplayed"])]
        }
        let before = await fixture.store.statementCountsForTesting()
        try await applier.apply(records)
        let after = await fixture.store.statementCountsForTesting()
        let run = after.run - before.run, prepared = after.prepared - before.prepared
        print("COST a direct unit of twenty queue edits: \(run) statements run, \(prepared) prepared")
        #expect(prepared * 3 < run, "each distinct statement prepared once: \(prepared) of \(run)")
        await fixture.close()
    }

    /// A library from before the units' indexes opens without building them (on a large library that would hold its
    /// launch); its first exchange while nothing plays builds them, never one while audio plays.
    @Test func aLibraryFromBeforeTheIndexesGetsThemAtAnExchangeWhileNothingPlays() async throws {
        let fixture = try await ServerLibraryFixture()
        try await ServerProjectionUnitTests.Applier(fixture).apply(try Cutover.arrivingRecords(count: 300))
        try await fixture.store.close()
        let names = "('ntp_records_in_queue', 'ntp_episodes_by_podcast')"
        let raw = try LibrarySQLite(url: fixture.url)
        try raw.execute("DROP INDEX ntp_records_in_queue")
        try raw.execute("DROP INDEX ntp_episodes_by_podcast")
        try raw.close()
        let store = try FeedLibraryStore(url: fixture.url)
        let indexes = { try fixture.rows("SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name IN \(names)") }
        #expect(try indexes() == [["0"]], "not built while it opens")
        let playing = PlayingFlag()
        playing.value = true
        let cursor = try #require(try await store.serverExchangeState().cursor)
        let engine = try ServerSyncEngine(store: store, database: fixture.url, syncDatabase: fixture.directory.appendingPathComponent("sync.sqlite"),
                                          staging: fixture.directory.appendingPathComponent("staging"), transport: ServerSyncEngineUnitTests.Transport { path, _ in
            path == "v1/pull" ? ["head": .string(cursor.encoded), "has_more": false, "items": [], "install_watermark": 0] : ["results": []]
        }, vault: fixture.vault, isPlaying: { playing.value })
        _ = await engine.exchange()
        #expect(try indexes() == [["0"]], "not while audio plays")
        playing.value = false
        _ = await engine.exchange()
        #expect(try indexes() == [["2"]], "built at an exchange while nothing plays")
        await engine.close()
        try await store.close()
        await fixture.close()
    }

    /// A staged catalog (a podcast another device subscribed): each staging transaction and the switch that reveals it
    /// cost the same for a catalog ten times larger. Staging examines a window of the shadow's records at a time, and
    /// the switch reads what it writes itself by its stage, never scanning what staging wrote ahead.
    @Test func aStagedCatalogsTransactionsDoNotGrowWithTheCatalog() async throws {
        func steps(_ episodes: Int) async throws -> (staging: Int64, switch: Int64, unit: ServerUnitResult) {
            let fixture = try await ServerLibraryFixture()
            let input = try await ServerRetainedPublicationTests.nextInput(fixture, try Cutover.arrivingRecords(count: episodes))
            let shadow = try await ServerRetainedPublicationTests.build(fixture, input)
            var cursor = ServerStagingCursor(), longest: Int64 = 0
            while true {
                let before = await fixture.store.statementStepsForTesting()
                let step = try await fixture.store.stageServerShadowBatch(shadow, seq: input.commit.seq, cursor: cursor)
                longest = max(longest, await fixture.store.statementStepsForTesting() - before)
                if step.rows == 0 { break }
                cursor = step.cursor
            }
            let before = await fixture.store.statementStepsForTesting()
            let unit = try await fixture.store.publishServerShadow(shadow, input: input, history: nil)
            let after = await fixture.store.statementStepsForTesting()
            #expect(try await Cutover.arrived(fixture.store)?.episodes.count == episodes)
            await fixture.close()
            return (longest, after - before, unit)
        }
        let small = try await steps(1_000), large = try await steps(10_000)
        print("COST staged catalog: longest staging transaction \(small.staging) steps for 1,000 episodes, \(large.staging) for 10,000; "
              + "switch \(small.switch) (\(small.unit.rowsWritten) rows) and \(large.switch) (\(large.unit.rowsWritten) rows)")
        #expect(large.staging < small.staging * 2 + 5_000, "staging: \(small.staging) steps for 1,000 episodes, \(large.staging) for 10,000")
        #expect(large.switch < small.switch * 2 + 5_000, "switch: \(small.switch) steps for 1,000 episodes, \(large.switch) for 10,000")
    }

    /// A queue edit: the queue's projection reads the queue membership records, not every episode record.
    @Test func aQueueEditsUnitDoesNotGrowWithTheLibrary() async throws {
        try await Self.expectBounded("queue edit", [
            ServerProjectionUnitTests.membership(Cutover.wire(500), Cutover.arrivingGeneration, true),
            ServerProjectionUnitTests.position(Cutover.wire(500), Cutover.arrivingGeneration, try QueueKey.between(nil, nil, positionWriteID: UUID()))])
    }
}

extension FeedLibraryStore {
    func statementStepsForTesting() -> Int64 { database.statementSteps }
    func statementCountsForTesting() -> (run: Int, prepared: Int) { (database.statementsRun, database.statementsPrepared) }
}
