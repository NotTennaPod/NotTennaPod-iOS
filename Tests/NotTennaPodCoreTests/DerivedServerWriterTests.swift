import Foundation
import Testing
@testable import NotTennaPodCore

/// The server library's writers keep the derived keys and counts exact (whole-table oracle after each step, and the
/// store's invariant on every commit): staging (`INSERT…SELECT` from the shadow, hidden markers first), shown-ahead rows
/// (`UPDATE…FROM shadow`), an abandoned staging's take-out, the shadow publication, unit row images
/// (`writeEpisodeImage`), a pinned removal, a hidden removal's bounded deletion and Force full sync's re-projection.
@Suite(.serialized) struct DerivedServerWriterTests {
    typealias Cutover = ServerBoundedCutoverTests
    typealias Retained = ServerRetainedPublicationTests

    /// VM steps the publication of 2,000 reveals and 600 favorites may run inside its lock for the derived data: 3,726,043
    /// measured, and a fifth more. The change capture adds its own work on top, proportional to the keys its
    /// set reports (each changed episode imaged before and after, and compared): about 770 a key measured here (7,248,160
    /// steps for 4,600 keys), `captureStepsPerKey` allowed.
    static let publicationLockSteps: Int64 = 4_500_000
    static let captureStepsPerKey: Int64 = 1_000

    /// A new podcast staged hidden; a crash after staging; the next exchange takes the staging out, stages it again and
    /// reveals it.
    @Test func aStagedPodcastItsTakeOutAndItsRevealStayExact() async throws {
        let (fixture, _, engine) = try await Cutover.arrival(count: 300, foreground: true)
        await fixture.store.verifyDerivedDataOnCommit()
        await engine.setCrashPoint(ServerExchangePushPullTests.crashOnce(at: "staging.staged"))
        let crashed = await engine.exchange()
        #expect(crashed.error == "InjectedCrash()", "\(crashed)")
        try EpisodeListKeysTests.expectExact(fixture.url, "staged, hidden")
        #expect(try DerivedDataOracle.storedKeys(fixture.url).count == 302, "the staged podcast's rows are keyed")
        let readers = try await fixture.store.readers()
        let hidden = try #require(try RawLibrary.rows(fixture.url, "SELECT feed_id FROM ntp_hidden_feeds").first?.first ?? nil)
        #expect(try await !readers.quick.counts().keys.map(String.init).contains(hidden), "and no list shows it")
        let report = await engine.exchange()
        #expect(report.completed, "\(report)")
        try EpisodeListKeysTests.expectExact(fixture.url, "revealed")
        #expect(try await readers.quick.counts().values.map(\.total).sorted() == [2, 300])
        await fixture.store.closeReaders()
        await engine.close()
        await fixture.close()
    }

    /// 600 shown episodes; a commit adds 2,000 to their podcast (staged hidden, markers before rows) and favorites the
    /// 600: exact after every staging transaction and after the publication.
    @Test func episodesStagedHiddenIntoAShownPodcastStayExactThroughEveryBatch() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        await store.verifyDerivedDataOnCommit()
        try await ServerProjectionUnitTests.Applier(fixture).apply(try Cutover.arrivingRecords(count: 600))
        try EpisodeListKeysTests.expectExact(fixture.url, "600 applied")
        let input = try await Retained.nextInput(fixture, try Cutover.episodeRecords(601...2_600) + (1...600).map(ServerShadowStagingTests.favorite))
        let shadow = try await Retained.build(fixture, input)
        // The switch is charged for revealing the 2,000 staged episodes (at least one counted write each) as well as the
        // 600 favorites.
        #expect(shadow.switchWork >= 2_000 + 600, "switch work \(shadow.switchWork)")
        try await DerivedWriteBudgetTests.install(store)
        var cursor = ServerStagingCursor(), batches = 0
        while true {
            let step = try await store.stageServerShadowBatch(shadow, seq: input.commit.seq, cursor: cursor)
            if step.rows == 0 { break }
            cursor = step.cursor; batches += 1
            try EpisodeListKeysTests.expectExact(fixture.url, "staging batch \(batches)")
        }
        #expect(try RawLibrary.rows(fixture.url, "SELECT count(*) FROM episode_list_keys WHERE hidden = 1") == [["2000"]])
        let feed = try #require(try await Cutover.arrived(store))
        #expect(try DerivedDataOracle.storedCounts(fixture.url)[feed.id]?.total == 600, "hidden rows never count")
        let staged = try await DerivedWriteBudgetTests.take(store)
        #expect(staged.keyInserts == 2_000 && staged.countWrites == 0, "staging hidden rows writes no counts: \(staged)")
        let log = await store.recordCommitsForTesting()
        let result = try await store.publishServerShadow(shadow, input: input, history: nil)
        #expect(result.published, "\(result)")
        let keys = Int64(log.sets.reduce(0) { $0 + $1.keyCount })
        try EpisodeListKeysTests.expectExact(fixture.url, "published")
        // The publication's actual writes: each revealed row's hidden flag and each favorite once, and the podcast's counts
        // once for each of them (contributions change).
        let published = try await DerivedWriteBudgetTests.take(store)
        let groups = Dictionary(published.keyUpdates.map { ($0, 1) }, uniquingKeysWith: +)
        #expect(groups == ["hidden": 2_000, "state": 600] && published.keyInserts == 0 && published.keyDeletes == 0, "\(published)")
        #expect(published.countWrites == 2_600 && published.countRows == [feed.id], "\(published)")
        print("DERIVED shadow publication: staging \(staged); publication \(published); lock \(result.lockMilliseconds) ms, \(result.lockSteps) VM steps, \(result.rowsWritten) rows written, \(keys) keys in its change set")
        // The lock's work, whatever the machine's speed or load: VM steps inside the transaction (the test's write log
        // included), calibrated on this publication with a margin, and the capture's per key of its set. The time is
        // reported above.
        #expect(keys >= 2_600, "the set reports every revealed and favorited episode: \(keys)")
        #expect(result.lockSteps <= Self.publicationLockSteps + Self.captureStepsPerKey * keys, "\(result.lockSteps) VM steps inside the lock, \(keys) keys")
        let counts = try #require(try DerivedDataOracle.storedCounts(fixture.url)[feed.id])
        #expect(counts.total == 2_600 && counts.favorite == 600, "\(counts)")
        await fixture.close()
    }

    /// A remote removal published while the player moves into the podcast: its other episodes go, the playing one stays
    /// as a pinned removal, left out of every list (the counts read).
    @Test func aPinnedRemovalStaysExact() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        await store.verifyDerivedDataOnCommit()
        let removed = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/removed.xml", title: "Removed", count: 300))
        _ = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/small.xml", title: "Small", count: 2))
        let playing = removed.feed.episodes.map(\.id).sorted()[0]
        try await store.setFavorite(episodeID: playing, favorite: true)
        try await store.retireEverythingForTesting()
        let input = try await Retained.nextInput(fixture, [Cutover.removal(removed.podcast, removed.generation)])
        let shadow = try await Retained.build(fixture, input)
        _ = try await store.beginPlayback(episodeID: playing)
        _ = try await store.publishServerShadow(shadow, input: input, history: nil)
        try EpisodeListKeysTests.expectExact(fixture.url, "pinned removal")
        let keys = try #require(try DerivedDataOracle.storedKeys(fixture.url)[playing])
        #expect(!keys.isFavorite, "its shared state is cleared")
        let readers = try await store.readers()
        #expect(try await readers.quick.counts()[removed.feed.id] == nil, "a pinned removal has no counts in lists")
        await store.closeReaders()
        await fixture.close()
    }

    /// A hidden removal's rows are deleted in bounded transactions by an exchange.
    @Test func aHiddenRemovalsBoundedDeletionStaysExact() async throws {
        let (fixture, large, podcast, generation, _, applier) = try await Cutover.library()
        await fixture.store.verifyDerivedDataOnCommit()
        try await applier.apply([Cutover.removal(podcast, generation)])
        try EpisodeListKeysTests.expectExact(fixture.url, "removal hidden")
        let head = try #require(try await fixture.store.serverExchangeState().cursor?.encoded)
        let engine = try ServerSyncEngine(store: fixture.store, database: fixture.url, syncDatabase: fixture.directory.appendingPathComponent("sync.sqlite"),
                                          staging: fixture.directory.appendingPathComponent("staging"), transport: ServerSyncEngineUnitTests.Transport { path, _ in
            switch path {
            case "v1/pull": return ["head": .string(head), "has_more": false, "items": [], "install_watermark": 0]
            case "v1/push": return ["results": []]
            default: return [:]
            }
        }, vault: fixture.vault)
        let report = await engine.exchange()
        #expect(report.completed, "\(report)")
        try EpisodeListKeysTests.expectExact(fixture.url, "removal finished")
        #expect(try DerivedDataOracle.storedKeys(fixture.url).values.allSatisfy { $0.feedID != large.id })
        await engine.close()
        await fixture.close()
    }

    /// Force full sync's re-projection publishes repaired rows over wrong live ones (against the real server).
    @Test func aFullReprojectionStaysExact() async throws {
        try await ExchangeWorld.run { world in
            let (a, _, one, two) = try await ServerExchangeFullSyncTests.world(world)
            await a.store.verifyDerivedDataOnCommit()
            try await ServerExchangeFullSyncTests.corrupt(a, one: one, two: two)
            try EpisodeListKeysTests.expectExact(a.location.database, "corrupted live rows")
            let episodes = Int(try RawLibrary.rows(a.location.database, "SELECT count(*) FROM episodes")[0][0] ?? "0") ?? 0
            try await DerivedWriteBudgetTests.install(a.store)
            let report = await a.engine.forceFullSynchronization()
            #expect(report.reprojected && report.error == nil, "\(String(describing: report.error))")
            try EpisodeListKeysTests.expectExact(a.location.database, "re-projected")
            let log = try await DerivedWriteBudgetTests.take(a.store)
            #expect(log.keyRows.count <= episodes && log.countRows.count <= 2, "\(log)")
            print("DERIVED full re-projection of \(episodes) episodes: \(log)")
        }
    }
}
