import Foundation
import Testing
@testable import NotTennaPodCore

/// Retained publications and staging: a removal staged before the player moves into its podcast,
/// staged work counted once, and statistics fan-out counted per row.
@Suite(.serialized) struct ServerShadowStagingTests {
    typealias Cutover = ServerBoundedCutoverTests
    typealias Retained = ServerRetainedPublicationTests
    typealias Large = ServerLargeUnitTests

    /// Stages a built shadow as the engine does, every bounded transaction.
    static func stageAll(_ fixture: ServerLibraryFixture, _ shadow: ServerShadowBuild, seq: Int64) async throws {
        var cursor = ServerStagingCursor()
        while true {
            let step = try await fixture.store.stageServerShadowBatch(shadow, seq: seq, cursor: cursor)
            if step.rows == 0 { return }
            cursor = step.cursor
        }
    }

    static func favorite(_ number: Int) -> ServerRecord {
        ServerRecord(entity: "episode", id: Cutover.wire(number), fieldGroup: "favorite", value: ["generation_id": .string(Cutover.arrivingGeneration), "on": true])
    }

    // MARK: - The player moves into a podcast whose removal is staged

    /// A shadow holds a remote removal of a podcast (a podcast-only removal visits none of its episodes) built while no
    /// episode is selected; before its switch the person plays the podcast's first episode, a favorite in the queue. The
    /// switch defers before writing anything, and the publication decides the removal again as a whole from the current
    /// selection: the player's episode stays with its session and selection (a pinned removal, its shared state
    /// cleared), and the podcast leaves every list. A small removal (3 episodes) and a hidden one (300).
    @Test(arguments: [3, 300]) func thePlayerMovingIntoAPodcastWhoseRemovalIsStagedKeepsItsEpisode(count: Int) async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let removed = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/removed.xml", title: "Removed", count: count))
        let small = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/small.xml", title: "Small", count: 2))
        let playing = removed.feed.episodes.map(\.id).sorted()[0]
        try await store.setFavorite(episodeID: playing, favorite: true)
        _ = try await store.enqueue([playing, small.feed.episodes.map(\.id).sorted()[0]])
        try await store.retireEverythingForTesting()
        let input = try await Retained.nextInput(fixture, [Cutover.removal(removed.podcast, removed.generation)])
        let shadow = try await Retained.build(fixture, input)
        #expect(shadow.revisions.scope.structuralFeeds.contains(removed.feed.id) && !shadow.revisions.scope.rows.contains(playing))
        _ = try await store.beginPlayback(episodeID: playing)
        let result = try await store.publishServerShadow(shadow, input: input, history: nil)
        #expect(result.wholeAtPause, "decided again as a whole from the current selection: \(result)")
        let held = try #require(try await store.episode(id: playing), "the player's episode stays")
        #expect(!held.userState.isFavorite, "its shared state is cleared, as in a pinned removal")
        let selected = try await store.playbackSelectionEpisodeID(), session = try await store.playbackSession()?.episodeID
        #expect(selected == playing && session == playing, "the player keeps it")
        #expect(try await store.feeds().map(\.id) == [small.feed.id], "the podcast left every list")
        #expect(try await store.serverExchangeState().cursor == input.cursor)
        await fixture.close()
    }

    /// A download started on an episode of a podcast whose removal is staged (not the player's) defers its switch: the
    /// removal is decided again as a whole, with the job.
    @Test func aDownloadStartedInAPodcastWhoseRemovalIsStagedDefersIt() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let removed = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/removed.xml", title: "Removed", count: 3))
        let small = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/small.xml", title: "Small", count: 2))
        try await store.retireEverythingForTesting()
        let input = try await Retained.nextInput(fixture, [Cutover.removal(removed.podcast, removed.generation)])
        let shadow = try await Retained.build(fixture, input)
        _ = try await store.requestDownload(episodeID: removed.feed.episodes.map(\.id).sorted()[1], directory: fixture.directory, enqueue: false)
        let result = try await store.publishServerShadow(shadow, input: input, history: nil)
        #expect(result.wholeAtPause, "\(result)")
        #expect(try await store.feeds().map(\.id) == [small.feed.id])
        #expect(try fixture.rows("SELECT count(*) FROM download_jobs") == [["0"]], "the removal took the job with its episode")
        await fixture.close()
    }

    // MARK: - Staged work counted once

    /// 600 shown episodes; one commit adds 2,000 episodes to their podcast (staged hidden: their records are both new to
    /// the base and content) and favorites the 600. Its switch still writes the 600 favorites and their rows: counted
    /// from what is left unstaged, never below it, so the store's final check with the 1,000-row budget defers it.
    @Test func aCatalogArrivingWithFavoritesCountsItsSwitchFromWhatIsLeft() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        try await ServerProjectionUnitTests.Applier(fixture).apply(try Cutover.arrivingRecords(count: 600))
        let input = try await Retained.nextInput(fixture, try Cutover.episodeRecords(601...2_600) + (1...600).map(Self.favorite))
        let shadow = try await Retained.build(fixture, input)
        let staging = try #require(shadow.staging)
        #expect(staging.work <= shadow.work && shadow.switchWork >= 1_200, "work \(shadow.work), staged \(staging.work), switch \(shadow.switchWork)")
        try await Self.stageAll(fixture, shadow, seq: input.commit.seq)
        let cursor = try await store.serverExchangeState().cursor
        do {
            _ = try await store.publishServerShadow(shadow, input: input, history: nil, workLimit: 1_000)
            Issue.record("published over the 1,000-row budget")
        } catch ServerApplyError.deferred {}
        #expect(try await store.serverExchangeState().cursor == cursor, "nothing published")
        let result = try await store.publishServerShadow(shadow, input: input, history: nil)
        #expect(result.published && !result.wholeAtPause, "\(result)")
        await fixture.close()
    }

    /// The same commit at the engine, while audio plays and the app is in use: it waits for the app to leave the
    /// foreground (nothing of it shows), then is published whole within the background budget.
    @Test func aCatalogArrivingWithFavoritesWaitsWhileTheAppIsInUse() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        try await ServerProjectionUnitTests.Applier(fixture).apply(try Cutover.arrivingRecords(count: 600))
        let playing = PlayingFlag(), foreground = PlayingFlag(), eligibility = ServerPublicationEligibility()
        playing.value = true
        foreground.value = true
        let engine = try await Large.serve(fixture, [try Cutover.episodeRecords(601...2_600) + (1...600).map(Self.favorite)],
                                           playing: playing, foreground: foreground, eligibility: eligibility)
        await engine.setBudgets(playingInterval: 0.001)
        let probe = try #require(try await store.localEpisodeForTesting(wire: Cutover.wire(300)))
        let waiting = await engine.exchange()
        #expect(waiting.waitingForBackground && waiting.appliedUnits == 0, "\(waiting)")
        #expect(try await store.episode(id: probe)?.userState.isFavorite == false, "nothing of it while the app is in use")
        foreground.value = false
        eligibility.changed()
        let left = await engine.exchange()
        #expect(left.completed && left.appliedUnits == 1 && left.units.first?.background == true, "\(left)")
        #expect(try await store.episode(id: probe)?.userState.isFavorite == true)
        await engine.close()
        await fixture.close()
    }

    // MARK: - Statistics fan-out counted per row

    /// One episode with 13,000 statistics units (an import keeps duplicate source rows as separate units).
    static func manyUnits(_ count: Int, episode: Int = 1) -> ServerRecord {
        let units = (1...count).map { number -> ContractJSON in
            ["id": .string("unit-\(number)"), "played_ms": 1_000, "last_played": .integer(1_700_000_000_000 + Int64(number)), "duration_ms": 600_000,
             "played": false, "position": 1_000]
        }
        return ServerRecord(entity: "episode", id: Cutover.wire(episode), fieldGroup: "statistics_units", value: ["units": .array(units)])
    }

    /// A reset removes that episode's statistics units: 26,000 rows deleted from the two statistics tables. Its work counts
    /// them, so a publication under the background budget (24,000) defers it, and with no limit it is published.
    @Test func aResetOfAnEpisodeWithManyUnitsCountsEveryRow() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let applier = try await ServerProjectionUnitTests.Applier(fixture)
        try await applier.apply(try Cutover.arrivingRecords(count: 3) + [Self.manyUnits(13_000)])
        #expect(try fixture.rows("SELECT (SELECT count(*) FROM statistics_units), (SELECT count(*) FROM ntp_statistics_units)") == [["13000", "13000"]])
        let input = try await Retained.nextInput(fixture, [ServerRecord(entity: "episode", id: Cutover.wire(1), fieldGroup: "statistics_units", value: nil)])
        let shadow = try await Retained.build(fixture, input)
        #expect(shadow.work >= 26_000 && shadow.switchWork >= 26_000, "work \(shadow.work), switch \(shadow.switchWork)")
        let eligibility = ServerPublicationEligibility()
        let background = ServerPublicationTicket(eligibility: eligibility, generation: eligibility.current, budget: 24_000)
        do {
            _ = try await store.publishServerShadow(shadow, input: input, history: nil, ticket: background)
            Issue.record("published over the background budget")
        } catch ServerApplyError.deferred {}
        #expect(eligibility.deferredSinceTransition, "noted: it waits for the pause")
        let result = try await store.publishServerShadow(shadow, input: input, history: nil)
        #expect(result.rowsWritten >= 26_000 && result.work >= 26_000, "\(result)")
        #expect(try fixture.rows("SELECT (SELECT count(*) FROM statistics_units), (SELECT count(*) FROM ntp_statistics_units)") == [["0", "0"]])
        await fixture.close()
    }

    /// The same reset at the engine while audio plays in the background: never the direct path (its estimate counts
    /// the rows), over the background budget, it waits for the pause, which publishes it.
    @Test func aResetOfAnEpisodeWithManyUnitsWaitsForThePauseWhilePlaying() async throws {
        let fixture = try await ServerLibraryFixture()
        try await ServerProjectionUnitTests.Applier(fixture).apply(try Cutover.arrivingRecords(count: 3) + [Self.manyUnits(13_000)])
        let playing = PlayingFlag(), eligibility = ServerPublicationEligibility()
        playing.value = true
        let engine = try await Large.serve(fixture, [[ServerRecord(entity: "episode", id: Cutover.wire(1), fieldGroup: "statistics_units", value: nil)]],
                                           playing: playing, eligibility: eligibility)
        await engine.setBudgets(playingInterval: 0.001)
        let waiting = await engine.exchange()
        #expect(waiting.waitingForPause && waiting.appliedUnits == 0, "\(waiting)")
        #expect(try fixture.rows("SELECT count(*) FROM statistics_units") == [["13000"]])
        playing.value = false
        eligibility.changed()
        let paused = await engine.exchange()
        #expect(paused.completed && paused.appliedUnits == 1, "\(paused)")
        #expect(try fixture.rows("SELECT count(*) FROM statistics_units") == [["0"]])
        await engine.close()
        await fixture.close()
    }

    // MARK: - The local-change log

    /// A table the log covers created after the log started (by their first use): its writes
    /// are logged from then on, and a build from before cannot know what it held meanwhile (its touches are unknown).
    @Test func aCoveredTableCreatedAfterTheLogStartedIsLogged() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        // A library from before its first use (it is created with the exchange tables).
        try await store.executeForTesting("DROP TABLE IF EXISTS ntp_recovery_holds")
        #expect(try fixture.rows("SELECT count(*) FROM sqlite_master WHERE name = 'ntp_recovery_holds'") == [["0"]])
        let before = try await store.serverTouchWatermark()
        try await store.executeForTesting("CREATE TABLE ntp_recovery_holds (id INTEGER PRIMARY KEY)")
        try await store.executeForTesting("INSERT INTO ntp_recovery_holds(id) VALUES (1)")
        #expect(try await store.serverTouches(since: before, limit: 500).unknown, "built before: what it held meanwhile is unknown")
        let after = try await store.serverTouchWatermark()
        try await store.executeForTesting("INSERT INTO ntp_recovery_holds(id) VALUES (2)")
        #expect(try await store.serverTouches(since: after, limit: 500).holds, "logged from then on")
        await fixture.close()
    }

    /// The reader refuses more entries than it scans without counting the whole log: exactly at the limit it reads, one
    /// past it overflows.
    @Test func theTouchReaderStopsAtItsScanLimit() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let watermark = try await store.serverTouchWatermark()
        let limit = FeedLibraryStore.serverTouchScanLimit
        try await store.executeForTesting("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(limit)) INSERT INTO temp.ntp_touches(kind, key) SELECT 'player', NULL FROM n")
        let at = try await store.serverTouches(since: watermark, limit: 500)
        #expect(!at.overflow && at.player, "\(limit) entries are read")
        try await store.executeForTesting("INSERT INTO temp.ntp_touches(kind, key) VALUES ('player', NULL)")
        #expect(try await store.serverTouches(since: watermark, limit: 500).overflow, "one more is past the limit")
        await fixture.close()
    }

    /// A hidden removal deletes its episodes' statistics units in bounded transactions before their rows (the newest
    /// episode's, in its first batch).
    @Test func aHiddenRemovalDeletesManyUnitsInBoundedTransactions() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let applier = try await ServerProjectionUnitTests.Applier(fixture)
        try await applier.apply(try Cutover.arrivingRecords(count: 300) + [Self.manyUnits(2_000, episode: 300)])
        try await applier.apply([Cutover.removal(Cutover.arriving, Cutover.arrivingGeneration)])
        var units: [Int] = []
        while try await store.deleteHiddenRemovalBatch().progressed {
            units.append(Int(try fixture.rows("SELECT count(*) FROM statistics_units").first?.first.flatMap { $0 } ?? "0") ?? 0)
        }
        #expect(units.prefix(4) == [1_500, 1_000, 500, 0], "500 units a transaction before the rows: \(units)")
        #expect(try fixture.rows("SELECT count(*) FROM episodes") == [["0"]])
        await fixture.close()
    }
}

extension FeedLibraryStore {
    /// Raw SQL; a schema change is followed, as every schema-creating path is, by the change capture's installation.
    func executeForTesting(_ sql: String) throws {
        try database.execute(sql)
        try database.refreshChangeCapture()
    }
}
