import Foundation
import Testing
@testable import NotTennaPodCore

/// The big kinds of publication change the library in bounded transactions behind a hidden
/// podcast, so no transaction holds the library long while a person uses it, and nobody sees a partial podcast.
@Suite struct ServerBoundedCutoverTests {
    static let large = 300

    /// A large registered podcast (300 episodes) and a small one, everything acknowledged, the large podcast's first
    /// three episodes and the small one's first queued.
    static func library() async throws -> (fixture: ServerLibraryFixture, large: LibraryFeed, podcast: String, generation: String,
                                           small: LibraryFeed, applier: ServerProjectionUnitTests.Applier) {
        let fixture = try await ServerLibraryFixture()
        let big = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/large.xml", title: "Large", count: large))
        let small = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/small.xml", title: "Small", count: 2))
        let largeEpisodes = big.feed.episodes.map(\.id).sorted(), smallEpisodes = small.feed.episodes.map(\.id).sorted()
        _ = try await fixture.store.enqueue(Array(largeEpisodes.prefix(3)) + [smallEpisodes[0]])
        try await fixture.store.retireEverythingForTesting()
        return (fixture, big.feed, big.podcast, big.generation, small.feed, try await ServerProjectionUnitTests.Applier(fixture))
    }

    static func removal(_ podcast: String, _ generation: String) -> ServerRecord {
        ServerRecord(entity: "podcast", id: podcast, fieldGroup: "subscription", value: ["state": "removed", "generation_id": .string(generation)])
    }

    static func episodeRows(_ fixture: ServerLibraryFixture, _ feed: Int64) throws -> Int {
        Int(try fixture.rows("SELECT count(*) FROM episodes WHERE feed_id = \(feed)").first?.first.flatMap { $0 } ?? "0") ?? 0
    }

    /// Everything a person can see of the library: the podcast list, every episode list, the queue, search and
    /// statistics leave the removed podcast out at once, in the removal's own small unit.
    static func expectGoneFromEveryList(_ store: FeedLibraryStore, _ feed: Int64, _ small: LibraryFeed,
                                        sourceLocation: SourceLocation = #_sourceLocation) async throws {
        #expect(try await store.feeds().map(\.id) == [small.id], sourceLocation: sourceLocation)
        let snapshot = try await store.snapshot()
        #expect(snapshot.feeds.map(\.id) == [small.id], sourceLocation: sourceLocation)
        #expect(snapshot.queue.map(\.id) == [small.episodes.map(\.id).sorted()[0]], "the queue", sourceLocation: sourceLocation)
        let episodes = try await store.search(query: "Episode").episodes
        #expect(!episodes.isEmpty && episodes.allSatisfy { $0.feedID == small.id }, "episode search", sourceLocation: sourceLocation)
        #expect(try await store.search(query: "Large").feeds.isEmpty, "podcast search", sourceLocation: sourceLocation)
        #expect(try await store.statistics().feeds.map(\.feedID) == [small.id], "statistics", sourceLocation: sourceLocation)
    }

    @Test func aLargeRemovalLeavesEveryListAtOnceAndItsRowsGoInBoundedTransactions() async throws {
        let (fixture, large, podcast, generation, small, applier) = try await Self.library()
        let store = fixture.store
        let result = try await applier.apply([Self.removal(podcast, generation)])
        #expect(result.hiddenRemovals && result.work < 10, "a small unit: \(result.work)")
        try await Self.expectGoneFromEveryList(store, large.id, small)
        #expect(try Self.episodeRows(fixture, large.id) == Self.large, "its rows go afterwards")
        #expect(result.queueSafeguard == nil && result.queueChanged)
        var remaining = [try Self.episodeRows(fixture, large.id)]
        while try await store.deleteHiddenRemovalBatch().progressed {
            remaining.append(try Self.episodeRows(fixture, large.id))
            try await Self.expectGoneFromEveryList(store, large.id, small)
        }
        #expect(remaining == [300, 200, 100, 0, 0], "at most \(FeedLibraryStore.removalTransaction) episodes a transaction, then the podcast: \(remaining)")
        #expect(try await store.feed(id: large.id) == nil)
        #expect(try fixture.rows("SELECT count(*) FROM ntp_hidden_feeds") == [["0"]])
        let effects = try await store.pendingEffects().map(\.effect.kind)
        #expect(effects.contains { if case .removeEpisodes = $0 { true } else { false } }
                && effects.contains { if case .deleteFeed = $0 { true } else { false } }, "files go through the two-phase cleanup")
        await fixture.close()
    }

    /// The app stops between two bounded transactions: after the relaunch the podcast is still hidden and its
    /// deletion resumes.
    @Test func aRemovalStoppedHalfwayStaysHiddenAndResumes() async throws {
        let (fixture, large, podcast, generation, small, applier) = try await Self.library()
        try await applier.apply([Self.removal(podcast, generation)])
        #expect(try await fixture.store.deleteHiddenRemovalBatch().progressed)
        try await fixture.store.close()
        let store = try FeedLibraryStore(url: fixture.url)
        _ = FeedAuthentication(store: store, vault: fixture.vault)
        try await Self.expectGoneFromEveryList(store, large.id, small)
        #expect(try await store.hasHiddenRemovals())
        while try await store.deleteHiddenRemovalBatch().progressed {}
        let gone = try await store.feed(id: large.id) == nil, left = try await store.hasHiddenRemovals()
        #expect(gone && !left)
        try? await store.close()
        await fixture.close()
    }

    /// The player holds an episode of the removed podcast: it stays for the player (its shared state cleared, as in a
    /// pinned removal), everything else goes; once the player leaves it, it goes too, with the podcast.
    @Test func aLargeRemovalWaitsForThePlayersEpisode() async throws {
        let (fixture, large, podcast, generation, small, applier) = try await Self.library()
        let store = fixture.store
        let playing = large.episodes.map(\.id).sorted()[10]
        try await store.setFavorite(episodeID: playing, favorite: true)
        try await store.retireEverythingForTesting()
        _ = try await store.beginPlayback(episodeID: playing)
        try await applier.apply([Self.removal(podcast, generation)])
        try await Self.expectGoneFromEveryList(store, large.id, small)
        #expect(try await store.episode(id: playing)?.userState.isFavorite == false, "its shared state is cleared")
        while try await store.deleteHiddenRemovalBatch().progressed {}
        let held = try await store.episode(id: playing)
        #expect(try Self.episodeRows(fixture, large.id) == 1 && held != nil, "the player's episode stays")
        try await Self.expectGoneFromEveryList(store, large.id, small)
        let engine = try ServerSyncEngine(store: store, database: fixture.url, syncDatabase: fixture.directory.appendingPathComponent("sync.sqlite"),
                                          staging: fixture.directory.appendingPathComponent("staging"),
                                          transport: ServerSyncEngineUnitTests.Transport { _, _ in [:] }, vault: fixture.vault)
        _ = try await store.beginPlayback(episodeID: small.episodes.map(\.id).sorted()[0])
        await engine.releasePins()
        let episodeAfter = try await store.episode(id: playing), feedAfter = try await store.feed(id: large.id)
        #expect(episodeAfter == nil && feedAfter == nil, "gone once the player left it")
        await engine.close()
        await fixture.close()
    }

    /// An exchange finishes a hidden removal by itself, one bounded transaction at a time.
    @Test func anExchangeFinishesAHiddenRemoval() async throws {
        let (fixture, large, podcast, generation, _, applier) = try await Self.library()
        try await applier.apply([Self.removal(podcast, generation)])
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
        #expect(report.completed && report.removalBatches == 4, "\(report)")
        #expect(try await fixture.store.feed(id: large.id) == nil)
        await engine.close()
        await fixture.close()
    }

    // MARK: - A new podcast, staged

    static let arriving = "p1:" + String(repeating: "7", count: 64), arrivingGeneration = "g1:" + String(repeating: "8", count: 64)

    static func wire(_ number: Int) -> String { "e1:" + ContractIdentity.sha256Hex(Array("staged-\(number)".utf8)) }

    /// The records of a podcast another device subscribed, `count` episodes, its first three queued.
    static func arrivingRecords(count: Int) throws -> [ServerRecord] {
        [ServerRecord(entity: "podcast", id: arriving, fieldGroup: "identity", value: ["refresh_url": "https://example.test/arriving.xml",
            "aliases": [["url": "https://example.test/arriving.xml", "normalized": "https://example.test/arriving.xml"]]]),
         ServerRecord(entity: "podcast", id: arriving, fieldGroup: "subscription", value: ["state": "subscribed", "generation_id": .string(arrivingGeneration)])]
            + (try episodeRecords(1...count))
    }

    static func metadata(_ number: Int, title: String) -> ServerRecord {
        let guid = "staged-\(number)"
        return ServerRecord(entity: "episode", id: wire(number), fieldGroup: "metadata", value: [
            "title": .string(title), "description": .null, "link": .null, "pub_date": .integer(1_700_000_000_000 + Int64(number) * 60_000),
            "image_url": .null, "payment_link": .null,
            "media": ["url": .string("https://example.test/\(guid).mp3"), "size": "1000", "mime_type": "audio/mpeg", "duration": 600_000],
            "chapters": .null, "chapter_url": .null, "transcript_url": .null, "transcript_type": .null, "social_interact_url": .null,
            "revision": .string(ContractIdentity.randomUUID()), "fetch_time": 1_700_000_000_000])
    }

    /// The arriving podcast's episodes `numbers` (the first three of all queued).
    static func episodeRecords(_ numbers: ClosedRange<Int>) throws -> [ServerRecord] {
        var records: [ServerRecord] = []
        var key: QueueKey?
        for number in numbers {
            let id = wire(number), guid = "staged-\(number)"
            records.append(ServerRecord(entity: "episode", id: id, fieldGroup: "identity", value: ["podcast_id": .string(arriving),
                "occurrence": ["k": "rss-guid", "v": .string(guid), "guid": .string(guid)]]))
            records.append(metadata(number, title: "Arriving \(number)"))
            if number <= 3 {
                key = try QueueKey.between(key, nil, positionWriteID: UUID())
                records += [ServerProjectionUnitTests.membership(id, arrivingGeneration, true), ServerProjectionUnitTests.position(id, arrivingGeneration, key!)]
            }
        }
        return records
    }

    /// A small subscribed podcast with its first episode queued, everything acknowledged, and an engine whose server
    /// sends one commit: the arriving podcast.
    static func arrival(count: Int = 300, playing: Bool = false, foreground: Bool = false) async throws -> (fixture: ServerLibraryFixture, small: LibraryFeed, engine: ServerSyncEngine) {
        let fixture = try await ServerLibraryFixture()
        let small = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/small.xml", title: "Small", count: 2)).feed
        _ = try await fixture.store.enqueue([small.episodes.map(\.id).sorted()[0]])
        try await fixture.store.retireEverythingForTesting()
        let flag = PlayingFlag()
        flag.value = foreground
        let engine = try await serve(fixture, try arrivingRecords(count: count), playing: playing, foreground: flag)
        return (fixture, small, engine)
    }

    /// An engine whose server sends one commit of `records` after the library's cursor (seq 0).
    static func serve(_ fixture: ServerLibraryFixture, _ records: [ServerRecord], playing: Bool = false,
                      foreground: PlayingFlag = PlayingFlag(), playingFlag flag: PlayingFlag? = nil) async throws -> ServerSyncEngine {
        let cursor = try SyncCursor(logID: ContractIdentity.randomUUID(), epoch: 1, seq: 0, digest: String(repeating: "0", count: 64))
        try await fixture.store.setCursorForTesting(cursor)
        let commit: ContractJSON = ["epoch": 1, "seq": 1, "accepted": [], "decisions": [], "slots": [],
                                    "records": .array(records.map { record in
                                        ["entity": .string(record.entity), "id": .string(record.id), "field_group": .string(record.fieldGroup),
                                         "value": record.value ?? .null, "provenance": []] })]
        let digest = try ContractHash.nextDigest(previous: ContractHex.decode(cursor.digest) ?? [], commit)
        let head = try SyncCursor(logID: cursor.logID, epoch: 1, seq: 1, digest: ContractHex.encode(digest)).encoded
        let engine = try ServerSyncEngine(store: fixture.store, database: fixture.url, syncDatabase: fixture.directory.appendingPathComponent("sync.sqlite"),
                                          staging: fixture.directory.appendingPathComponent("staging"), transport: ServerSyncEngineUnitTests.Transport { path, body in
            switch path {
            case "v1/pull":
                let sent = body?["cursor"]?.stringValue == head
                return ["head": .string(head), "has_more": false, "items": sent ? [] : [["commit": commit]], "install_watermark": 0]
            case "v1/push": return ["results": []]
            default: return [:]
            }
        }, vault: fixture.vault, isPlaying: { flag?.value ?? playing }, isForeground: { foreground.value })
        return engine
    }

    /// VM steps the unit revealing a 300-episode catalog may run inside its lock for the derived data: 204,257 measured
    /// (before the change capture), and a fifth more. The change capture adds its own work on top,
    /// proportional to the keys its set reports (each revealed episode's relations imaged before and after, and
    /// compared): about 740 a key measured here (648,707 steps for the 602 keys of 300 episodes), 850 allowed. A scan of
    /// the library for each revealed episode (the witness, 1,193,513 steps) still exceeds the gate.
    static let catalogRevealLockSteps: Int64 = 250_000
    static let captureStepsPerRevealKey: Int64 = 850

    static func arrived(_ store: FeedLibraryStore) async throws -> LibraryFeed? {
        try await store.feeds().first { $0.source == "https://example.test/arriving.xml" }
    }

    /// The podcast is staged in bounded transactions while hidden from every list, and its unit reveals it writing
    /// only the rest. A crash after staging leaves it hidden; the next exchange takes the staging out and does it again.
    @Test func aNewPodcastIsStagedHiddenAndRevealedByASmallUnit() async throws {
        // In the foreground: its unit is small enough to run while someone uses the app.
        let (fixture, small, engine) = try await Self.arrival(foreground: true)
        let store = fixture.store
        await engine.setCrashPoint(ServerExchangePushPullTests.crashOnce(at: "staging.staged"))
        let crashed = await engine.exchange()
        #expect(crashed.error == "InjectedCrash()", "\(crashed)")
        // Staged, hidden: nothing of it shows.
        #expect(try fixture.rows("SELECT count(*) FROM episodes WHERE feed_id IN (SELECT feed_id FROM ntp_hidden_feeds WHERE state = 'staging')") == [["300"]])
        #expect(try await store.feeds().map(\.id) == [small.id])
        #expect(try await store.snapshot().queue.map(\.id) == [small.episodes.map(\.id).sorted()[0]])
        #expect(try await store.search(query: "Arriving").episodes.isEmpty)
        #expect(try await store.statistics().feeds.map(\.feedID) == [small.id])
        let report = await engine.exchange()
        #expect(report.completed, "\(report)")
        let arrived = try #require(try await Self.arrived(store))
        #expect(arrived.episodes.count == 300)
        #expect(try await store.queue().count == 4, "its queued episodes arrive with it")
        #expect(report.stagingBatches == 7, "the podcast, 3 x 100 episodes, their 300 mappings, their 608 records: \(report.stagingBatches)")
        let unit = try #require(report.units.first)
        #expect(unit.published && unit.rowsWritten < 100, "the revealing unit writes only the rest: \(unit)")
        #expect(try await engine.logEntries().contains { $0.detail.contains("taken out") }, "the crashed staging was taken out first")
        #expect(try fixture.rows("SELECT count(*) FROM feeds") == [["2"]], "nothing of the first staging is left")
        #expect(try fixture.rows("SELECT (SELECT count(*) FROM ntp_hidden_feeds) + (SELECT count(*) FROM ntp_staging)") == [["0"]])
        #expect(try fixture.rows("SELECT count(*) FROM ntp_episodes n JOIN episodes e ON e.id = n.local_id WHERE n.podcast_id = '\(Self.arriving)'") == [["300"]])
        await engine.close()
        await fixture.close()
    }

    /// A local queue edit while the podcast is staged is kept by the unit's switch (PROTOCOL §6.8): the queue it touched is
    /// re-projected at the publication, and the staging is not done again.
    @Test func aQueueEditDuringStagingIsKeptWithoutStagingAgain() async throws {
        let (fixture, small, engine) = try await Self.arrival()
        let store = fixture.store
        let once = PlayingFlag()
        await engine.setBeforePublish {
            guard !once.value else { return }
            once.value = true
            _ = try await store.enqueue([small.episodes.map(\.id).sorted()[1]])
        }
        let report = await engine.exchange()
        #expect(report.completed, "\(report)")
        let log = try await engine.logEntries().map(\.detail)
        #expect(!log.contains { $0.contains("staged again") } && log.filter { $0.contains("staged in") }.count == 1, "\(log)")
        #expect(try await Self.arrived(store)?.episodes.count == 300)
        #expect(try await store.queue().map(\.id).contains(small.episodes.map(\.id).sorted()[1]), "the local add is kept")
        #expect(try await store.queue().count == 5, "the local add beside the arriving podcast's three")
        #expect(try fixture.rows("SELECT count(*) FROM feeds") == [["2"]])
        #expect(try fixture.rows("SELECT count(*) FROM episodes") == [["302"]])
        await engine.close()
        await fixture.close()
    }

    /// The person removes the podcast whose catalog is being staged, before the switch: the switch re-projects the
    /// podcast it touched, so the removal stands and the staged episodes go with it, without staging again.
    @Test func aPodcastRemovedLocallyDuringStagingStaysRemoved() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let podcast = try await Self.registeredElsewhere(fixture)
        let engine = try await Self.serve(fixture, try Self.episodeRecords(2...301))
        let once = PlayingFlag()
        await engine.setBeforePublish {
            guard !once.value else { return }
            once.value = true
            _ = try await store.requestFeedDeletion(feedID: podcast.id)
        }
        let report = await engine.exchange()
        #expect(report.completed, "\(report)")
        #expect(try await !engine.logEntries().contains { $0.detail.contains("staged again") })
        #expect(try await Self.arrived(store) == nil, "the person's removal stands")
        #expect(try fixture.rows("SELECT (SELECT count(*) FROM ntp_hidden_episodes) + (SELECT count(*) FROM ntp_hidden_feeds WHERE state = 'staging') + (SELECT count(*) FROM ntp_staging)") == [["0"]])
        #expect(try fixture.rows("SELECT count(*) FROM episodes WHERE feed_id = \(podcast.id)") == [["0"]])
        await engine.close()
        await fixture.close()
    }

    /// An account-level change during the staging (a statistics reset, on which every episode's projection depends)
    /// cannot be re-projected at the switch: when nothing plays and nobody uses the app, the unit is published as a
    /// whole instead, its staging taken out and the commit applied from the intact local rows, without building it again.
    @Test func anAccountLevelChangeDuringStagingPublishesTheUnitAsAWhole() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let podcast = try await Self.registeredElsewhere(fixture)
        let engine = try await Self.serve(fixture, try Self.episodeRecords(2...301))
        let once = PlayingFlag()
        await engine.setBeforePublish {
            guard !once.value else { return }
            once.value = true
            try await store.resetPlayedDurationStatistics()
        }
        let report = await engine.exchange()
        #expect(report.completed && report.shadowsBuilt == 1, "\(report)")
        let log = try await engine.logEntries().map(\.detail)
        #expect(log.contains { $0.contains("published as a whole") } && !log.contains { $0.contains("staged again") }, "\(log)")
        #expect(try await Self.arrived(store)?.episodes.count == 301)
        #expect(try fixture.rows("SELECT count(*) FROM episodes WHERE feed_id = \(podcast.id)") == [["301"]], "nothing of the staging is left twice")
        #expect(try fixture.rows("SELECT (SELECT count(*) FROM ntp_hidden_episodes) + (SELECT count(*) FROM ntp_staging)") == [["0"]])
        await engine.close()
        await fixture.close()
    }

    /// While audio plays, a new podcast arrives at once (its unit is small); before staging it waited for a pause.
    @Test func aNewPodcastArrivesWhileListening() async throws {
        let (fixture, _, engine) = try await Self.arrival(playing: true)
        let report = await engine.exchange()
        #expect(report.completed && !report.waitingForPause, "\(report)")
        #expect(try await Self.arrived(fixture.store)?.episodes.count == 300)
        await engine.close()
        await fixture.close()
    }

    // MARK: - Over the budget: only when nobody uses the app

    /// A commit changing 300 episodes of a podcast four ways (well over the budget) waits while the app is in the
    /// foreground, says so once, and applies once the app is in the background.
    @Test func aLargeCommitWaitsUntilTheAppIsInTheBackground() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        try await ServerProjectionUnitTests.Applier(fixture).apply(try Self.arrivingRecords(count: 300))
        var records: [ServerRecord] = []
        for number in 1...300 {
            let id = Self.wire(number), generation = Self.arrivingGeneration
            records += [ServerRecord(entity: "episode", id: id, fieldGroup: "favorite", value: ["on": true]),
                        ServerRecord(entity: "episode", id: id, fieldGroup: "position", value: ["generation_id": .string(generation), "position": 30_000]),
                        ServerRecord(entity: "episode", id: id, fieldGroup: "played_time", value: ["generation_id": .string(generation), "played_ms": 30_000]),
                        ServerRecord(entity: "episode", id: id, fieldGroup: "last_played", value: ["generation_id": .string(generation), "time": 1_760_000_000_000])]
        }
        let foreground = PlayingFlag()
        foreground.value = true
        let engine = try await Self.serve(fixture, records, foreground: foreground)
        let probe = try #require(try await fixture.store.localEpisodeForTesting(wire: Self.wire(1)))
        for _ in 0..<2 {
            let waiting = await engine.exchange()
            #expect(waiting.waitingForBackground && !waiting.completed && waiting.appliedUnits == 0, "\(waiting)")
            #expect(try await store.episode(id: probe)?.userState.isFavorite == false, "nothing of it while the app is in use")
        }
        #expect(try await engine.logEntries().filter { $0.detail.contains("in the background") }.count == 1, "said once")
        foreground.value = false
        let applied = await engine.exchange()
        #expect(applied.completed && applied.appliedUnits == 1, "\(applied)")
        let state = try await store.episode(id: probe)?.userState
        #expect(state?.isFavorite == true && state?.positionMilliseconds == 30_000, "\(String(describing: state))")
        await engine.close()
        await fixture.close()
    }

    // MARK: - A catalog arriving for a podcast the library shows

    /// The arriving podcast as a registration elsewhere makes it: subscribed, one episode, before its catalog.
    static func registeredElsewhere(_ fixture: ServerLibraryFixture) async throws -> LibraryFeed {
        try await ServerProjectionUnitTests.Applier(fixture).apply(try arrivingRecords(count: 1))
        return try #require(try await arrived(fixture.store))
    }

    /// The common way a podcast arrives: it shows (empty) first, then its catalog's 300 episodes arrive. They are
    /// staged hidden, one at a time, and the unit reveals them; a crash after staging leaves the podcast as it was.
    /// `scanning`: the gate's witness, the reveal doing more work inside the lock with the same rows written (a scan of
    /// the episodes for each revealed one, from a temporary trigger): its VM steps exceed the gate.
    @Test(arguments: [false, true])
    func aCatalogArrivingIsStagedHiddenAndRevealedByASmallUnit(scanning: Bool) async throws {
        let (steps, keys) = try await Self.revealCatalog(scanning: scanning)
        // The lock's work, whatever the machine's speed or load: VM steps inside the unit's transaction (the test's write
        // log included), calibrated on this reveal with a margin, and the capture's per key of its set. The time is
        // reported by the reveal.
        #expect(keys >= 300, "the set reports every revealed episode: \(keys)")
        #expect(steps > 0 && (steps <= Self.catalogRevealLockSteps + Self.captureStepsPerRevealKey * keys) != scanning,
                "\(steps) VM steps inside the lock, \(keys) keys")
    }

    /// The control: the reveal's work does not grow with the library it arrives in (the existing podcasts' episodes are
    /// never visited).
    @Test func aCatalogRevealIsFlatInTheExistingLibrary() async throws {
        let alone = try await Self.revealCatalog(scanning: false)
        let amid = try await Self.revealCatalog(scanning: false, existing: 2_000)
        #expect(abs(amid.keys - alone.keys) <= 2, "the same reveal: \(amid) vs \(alone)")
        #expect(amid.steps <= alone.steps + alone.steps / 100, "\(amid.steps) VM steps amid 2,000 episodes, \(alone.steps) alone")
    }

    /// The reveal of a 300-episode catalog (`existing`: episodes of another podcast already in the library): its unit's
    /// VM steps inside the lock and the keys its change set reports.
    static func revealCatalog(scanning: Bool, existing: Int = 0) async throws -> (steps: Int64, keys: Int64) {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        if existing > 0 {
            _ = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/existing.xml", title: "Existing", count: existing))
        }
        let podcast = try await Self.registeredElsewhere(fixture)
        #expect(podcast.episodes.count == 1)
        let foreground = PlayingFlag()
        foreground.value = true
        let engine = try await Self.serve(fixture, try Self.episodeRecords(2...301), foreground: foreground)
        // With the budget below the catalog's size: only what the unit itself writes counts, and that is small (the rest
        // and, since schema 21, the reveal of its 300 staged episodes).
        await engine.setBudgets(publish: 500)
        await engine.setCrashPoint(ServerExchangePushPullTests.crashOnce(at: "staging.staged"))
        let crashed = await engine.exchange()
        #expect(crashed.error == "InjectedCrash()", "\(crashed)")
        #expect(try fixture.rows("SELECT count(*) FROM episodes WHERE feed_id = \(podcast.id)") == [["301"]], "staged")
        #expect(try await Self.arrived(store)?.episodes.count == 1, "nothing of it shows")
        #expect(try await store.search(query: "Arriving").episodes.map(\.episode.id) == [podcast.episodes[0].id])
        #expect(try await store.statistics().feeds.first { $0.feedID == podcast.id }?.episodes == 1)
        // A screen reads the podcast while it is staged (its image is cached): the unit's reveal still shows the rest.
        let read = PlayingFlag()
        try await DerivedWriteBudgetTests.install(store)
        await engine.setBeforePublish {
            guard !read.value else { return }
            read.value = true
            _ = try await store.feeds()
            // From here, only the unit's own writes are logged.
            _ = try await DerivedWriteBudgetTests.take(store)
            if scanning {
                try await store.withDatabaseForTesting { try $0.execute("CREATE TEMP TRIGGER test_scan_on_reveal AFTER UPDATE OF hidden ON main.episode_list_keys BEGIN SELECT count(*) FROM main.episodes WHERE length(record) > 0; END") }
            }
        }
        let log = await store.recordCommitsForTesting()
        let report = await engine.exchange()
        #expect(report.completed && report.stagingBatches == 6, "3 x 100 episodes, their 300 mappings, their 604 records: \(report)")
        #expect(try await Self.arrived(store)?.episodes.count == 301)
        #expect(try await store.search(query: "Arriving 250").episodes.count == 1, "the new episodes are found")
        #expect(try await store.statistics().feeds.first { $0.feedID == podcast.id }?.episodes == 301)
        let unit = try #require(report.units.first)
        // The reveal's derived writes, exactly: each revealed episode's key row and its podcast's counts once (schema 21).
        let derived = try await DerivedWriteBudgetTests.take(store)
        #expect(derived.keyUpdates == Array(repeating: "hidden", count: 300) && derived.countWrites == 300 && derived.keyInserts == 0, "\(derived)")
        // Besides clearing the 300 episodes' hidden marks, the unit writes only the rest (its rows written less the derived
        // rows and the test log's own rows).
        let canonical = unit.rowsWritten - derived.derivedWrites - derived.entries
        #expect(unit.published && canonical < 450, "\(unit), \(canonical) canonical rows")
        let keys = Int64(log.sets.filter { $0.episodes.count >= 300 }.reduce(0) { $0 + $1.keyCount })
        print("DERIVED catalog reveal of 300 (\(existing) existing): \(canonical) canonical rows, \(derived.derivedWrites) derived rows, lock \(unit.lockMilliseconds) ms, \(unit.lockSteps) VM steps, \(keys) keys")
        #expect(try fixture.rows("SELECT count(*) FROM episodes WHERE feed_id = \(podcast.id)") == [["301"]], "nothing of the first staging is left")
        #expect(try fixture.rows("SELECT (SELECT count(*) FROM ntp_hidden_episodes) + (SELECT count(*) FROM ntp_staging)") == [["0"]])
        await engine.close()
        await fixture.close()
        return (unit.lockSteps, keys)
    }

    /// A download finishing (a change no fact records) on an episode the commit changes, between two staging
    /// transactions: the staging goes on, and the unit's switch re-projects that episode, so the download is kept and the
    /// rename applied (PROTOCOL §6.8).
    @Test func aDownloadFinishingDuringStagingIsKept() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let podcast = try await Self.registeredElsewhere(fixture)
        let first = podcast.episodes[0].id
        // The catalog also renames the episode whose download is about to finish.
        let records = try Self.episodeRecords(2...301) + [Self.metadata(1, title: "Arriving 1, renamed")]
        let engine = try await Self.serve(fixture, records, playing: true)
        let exchange = Task { await engine.exchange() }
        #expect(try await ServerSyncSchedulingServerTests.waitFor {
            (try fixture.rows("SELECT count(*) FROM ntp_hidden_episodes").first?.first ?? nil).flatMap { Int($0) } ?? 0 > 0
        })
        try await store.projectForTesting(first) { $0.userState.isDownloaded = true; $0.userState.localFileURL = "/tmp/arriving-1.mp3" }
        let report = await exchange.value
        #expect(report.completed, "\(report)")
        #expect(try await !engine.logEntries().contains { $0.detail.contains("staged again") })
        #expect(report.shadowsBuilt == 1 && report.rebasedEntities >= 1, "\(report)")
        let kept = try #require(try await store.episode(id: first))
        #expect(kept.userState.isDownloaded && kept.userState.localFileURL == "/tmp/arriving-1.mp3" && kept.details.title == "Arriving 1, renamed",
                "the download is kept, the rename applied: \(kept.userState)")
        #expect(try await Self.arrived(store)?.episodes.count == 301)
        await engine.close()
        await fixture.close()
    }

    // MARK: - Eligibility up to the publication

    /// 300 shown episodes and a commit changing each of them four ways, over a lowered publication budget.
    static func largeChange() async throws -> (fixture: ServerLibraryFixture, records: [ServerRecord]) {
        let fixture = try await ServerLibraryFixture()
        try await ServerProjectionUnitTests.Applier(fixture).apply(try arrivingRecords(count: 300))
        let records = (1...300).flatMap { number in
            ["favorite", "position", "played_time", "last_played"].map { field in
                ServerRecord(entity: "episode", id: wire(number), fieldGroup: field,
                             value: ["on": true, "position": 30_000, "played_ms": 30_000, "time": 2_000_000, "generation_id": .string(arrivingGeneration)])
            }
        }
        return (fixture, records)
    }

    /// The app comes to the foreground while a large unit is staged and about to be
    /// published. It is not published then: it waits, kept, and is published in the background.
    @Test(arguments: ["foreground", "playback"])
    func aTransitionAfterStagingKeepsTheUnitWaiting(transition: String) async throws {
        let (fixture, records) = try await Self.largeChange()
        let foreground = PlayingFlag(), playing = PlayingFlag()
        let engine = try await Self.serve(fixture, records, foreground: foreground, playingFlag: playing)
        // Over the background budget too: playback starting with the app in the background makes it wait for the pause.
        await engine.setBudgets(publish: 100, background: 100)
        let once = PlayingFlag()
        await engine.setBeforePublish {
            guard !once.value else { return }
            once.value = true
            if transition == "foreground" { foreground.value = true } else { playing.value = true }
        }
        let waiting = await engine.exchange()
        #expect(waiting.appliedUnits == 0 && !waiting.completed, "\(waiting)")
        #expect(transition == "foreground" ? waiting.waitingForBackground : waiting.waitingForPause, "\(waiting)")
        let probe = try #require(try await fixture.store.localEpisodeForTesting(wire: Self.wire(1)))
        #expect(try await fixture.store.episode(id: probe)?.userState.isFavorite == false, "nothing of it is published")
        foreground.value = false; playing.value = false
        let applied = await engine.exchange()
        #expect(applied.completed && applied.appliedUnits == 1, "kept and published later: \(applied)")
        #expect(try await fixture.store.episode(id: probe)?.userState.isFavorite == true)
        await engine.close()
        await fixture.close()
    }

    /// A publication allowed, then queued for the store while the app comes to the foreground, is refused at admission:
    /// nothing written, the cursor where it was. A current admission publishes.
    @Test func aPublicationQueuedPastATransitionIsRefusedAtAdmission() async throws {
        let (fixture, records) = try await Self.largeChange()
        let store = fixture.store
        let cursor = try #require(try await store.serverExchangeState().cursor)
        let next = try SyncCursor(logID: cursor.logID, epoch: 1, seq: cursor.seq + 1, digest: String(repeating: "2", count: 64))
        let input = ServerUnitInput(commit: ServerCommit(epoch: 1, seq: next.seq, records: records), cursor: next, watermark: nil, now: 1_760_000_000_000)
        let ids = try await store.reserveServerLocalIDs(feeds: 4, episodes: 64)
        let shadow = try ServerShadow.build(input, database: fixture.url, shadow: fixture.directory.appendingPathComponent("admission.sqlite"),
                                            history: nil, feedIDs: ids.feeds, episodeIDs: ids.episodes,
                                            touches: try await store.serverTouchWatermark())
        let eligibility = ServerPublicationEligibility()
        let allowed = ServerPublicationTicket(eligibility: eligibility, generation: eligibility.current)
        eligibility.changed() // the app came to the foreground meanwhile
        await #expect(throws: ServerApplyError.ineligible) { _ = try await store.publishServerShadow(shadow, input: input, history: nil, ticket: allowed) }
        #expect(try await store.serverExchangeState().cursor == cursor, "nothing was published")
        let current = ServerPublicationTicket(eligibility: eligibility, generation: eligibility.current)
        let result = try await store.publishServerShadow(shadow, input: input, history: nil, ticket: current)
        let published = try await store.serverExchangeState().cursor
        #expect(result.published && published == next)
        await fixture.close()
    }

    // MARK: - Removal cleanup reads only what names a file

    /// The first bounded removal transaction's file cleanup, as the deletion coordinator runs it: the files it unlinks,
    /// the store time it took, and whether it decoded feeds.
    static func firstRemovalCleanup(_ fixture: ServerLibraryFixture) async throws -> (removed: [URL], milliseconds: Double, reloads: Int) {
        let store = fixture.store
        #expect(try await store.deleteHiddenRemovalBatch().progressed)
        let pending = try #require(try await store.pendingEffects().first { if case .removeEpisodes = $0.effect.kind { true } else { false } })
        let reloads = await store.feedEpisodeReads
        let removed = RemovedFiles()
        // The recipient's store steps (the app's playback and download retirement in between are not the store's).
        let clock = ContinuousClock(), start = clock.now
        _ = try await store.prepareRemovedEpisodeCleanup(effectID: pending.id)
        try await store.removeFilesForRemovedEpisodes(effectID: pending.id, removeFile: { removed.append($0) })
        try await store.completeRemovedEpisodeCleanup(effectID: pending.id)
        let elapsed = FeedLibraryStore.milliseconds(start.duration(to: clock.now))
        return (removed.urls, elapsed, await store.feedEpisodeReads - reloads)
    }

    final class RemovedFiles: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [URL] = []
        var urls: [URL] { lock.withLock { list } }
        func append(_ url: URL) { lock.withLock { list.append(url) } }
    }

    /// Without downloads the cleanup has nothing to unlink and decodes nothing.
    @Test func aRemovalWithoutDownloadsCleansUpWithoutReadingTheLibrary() async throws {
        let (fixture, _, podcast, generation, _, applier) = try await Self.library()
        try await applier.apply([Self.removal(podcast, generation)])
        let cleanup = try await Self.firstRemovalCleanup(fixture)
        print("MEASURE removal cleanup without files: \(String(format: "%.1f", cleanup.milliseconds)) ms")
        #expect(cleanup.removed.isEmpty && cleanup.reloads == 0, "\(cleanup)")
        await fixture.close()
    }

    /// With downloads, the files of the removed episodes are unlinked, except one another episode still owns; the
    /// check reads only the episodes that name a file.
    @Test func aRemovalWithDownloadsUnlinksOnlyFilesNobodyElseOwns() async throws {
        let (fixture, large, podcast, generation, small, applier) = try await Self.library()
        let store = fixture.store
        let folder = fixture.directory.appendingPathComponent("media", isDirectory: true)
        // A hidden removal deletes the newest episodes first (the feed's index order).
        let newestFirst = large.episodes.sorted { ($0.details.publicationDate ?? .distantPast, -$0.id) > ($1.details.publicationDate ?? .distantPast, -$1.id) }
        let removedFirst = newestFirst.map(\.id).prefix(FeedLibraryStore.removalTransaction)
        for id in large.episodes.map(\.id) {
            try await store.projectForTesting(id) { $0.userState.isDownloaded = true; $0.userState.localFileURL = folder.appendingPathComponent("large-\(id).mp3").path }
        }
        let shared = folder.appendingPathComponent("large-\(removedFirst.first!).mp3").path
        try await store.projectForTesting(small.episodes.map(\.id).sorted()[1]) { $0.userState.isDownloaded = true; $0.userState.localFileURL = shared }
        try await store.retireEverythingForTesting()
        try await applier.apply([Self.removal(podcast, generation)])
        let cleanup = try await Self.firstRemovalCleanup(fixture)
        print("MEASURE removal cleanup of \(removedFirst.count) downloaded episodes beside \(large.episodes.count - removedFirst.count + 1) others: \(String(format: "%.1f", cleanup.milliseconds)) ms")
        let expected = Set(removedFirst.dropFirst().map { folder.appendingPathComponent("large-\($0).mp3").standardizedFileURL.path })
        #expect(Set(cleanup.removed.map(\.standardizedFileURL.path)) == expected, "every removed episode's file but the shared one")
        #expect(cleanup.reloads == 0, "no feed decoded")
        await fixture.close()
    }

    // MARK: - A hidden podcast's retained episode is played, never queued

    /// The screens' direct reads do not show a hidden removal (only the player's own read does), and the
    /// player's episode played late, or downloaded, does not come back into the queue.
    @Test func aHiddenRemovalIsNotReadByTheScreensAndItsEpisodeIsNotQueuedAgain() async throws {
        let (fixture, large, podcast, generation, _, applier) = try await Self.library()
        let store = fixture.store
        let id = large.episodes.map(\.id).max()!
        _ = try await store.beginPlayback(episodeID: id)
        try await applier.apply([Self.removal(podcast, generation)])
        #expect(try await store.feed(id: large.id) == nil, "the podcast is gone for the screens")
        #expect(try await store.statisticsSnapshot(feedID: large.id) == nil)
        #expect(try await store.playbackFeed(id: large.id) != nil, "the player still reads its episode's podcast")
        while try await store.deleteHiddenRemovalBatch().progressed {}
        let session = try await store.beginPlayback(episodeID: id) // a late Play
        _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 10_000, durationMilliseconds: 600_000, status: .playing))
        #expect(try await store.episode(id: id) != nil, "it plays")
        let shown = try await store.queue(), snapshot = try await store.snapshot()
        #expect(shown.allSatisfy { $0.id != id } && snapshot.queue.allSatisfy { $0.id != id })
        #expect(try fixture.rows("SELECT count(*) FROM queue WHERE episode_id = \(id)") == [["0"]], "not queued, not only hidden")
        _ = try await store.requestDownload(episodeID: id, directory: fixture.directory, enqueue: true)
        #expect(try fixture.rows("SELECT count(*) FROM queue WHERE episode_id = \(id)") == [["0"]], "a download request does not queue it either")
        await fixture.close()
    }

    /// After a relaunch the player restores and plays the retained episode; it stays out of the
    /// queue.
    @Test func theRetainedEpisodePlayedAfterARelaunchStaysOutOfTheQueue() async throws {
        let (fixture, large, podcast, generation, _, applier) = try await Self.library()
        let id = large.episodes.map(\.id).max()!
        _ = try await fixture.store.beginPlayback(episodeID: id)
        try await applier.apply([Self.removal(podcast, generation)])
        while try await fixture.store.deleteHiddenRemovalBatch().progressed {}
        try await fixture.store.close()
        let reopened = try FeedLibraryStore(url: fixture.url)
        #expect(try await reopened.playbackSelectionEpisodeID() == id)
        _ = try await reopened.beginPlayback(episodeID: id) // PlaybackCoordinator.restore → playCurrent → load
        #expect(try await reopened.queue().allSatisfy { $0.id != id })
        #expect(try fixture.rows("SELECT count(*) FROM queue WHERE episode_id = \(id)") == [["0"]])
        try await reopened.close()
        await fixture.close()
    }

    // MARK: - Notifications see what the screens see

    /// A refresh found a release to notify about; the server then removes the podcast (hidden at once).
    /// Nothing is notified, and the counts leave the podcast out. (A server library notifies once per
    /// release of its discovery ledger; the refresh's baseline journal is the standalone library's.)
    @Test func aNotificationForAPodcastHiddenSinceIsNotPublished() async throws {
        let (fixture, large, podcast, generation, _, applier) = try await Self.library()
        let store = fixture.store
        try await store.updatePreferences(feedID: large.id) { $0.showEpisodeNotification = true }
        let request = FeedRefreshRequest(feedID: large.id, enqueuedAt: .distantPast)
        try await store.enqueueManualRefresh(request)
        let baseline = try await store.beginEpisodeNotificationAttempt(requestID: request.id)
        let fresh = try await store.applyRefresh(ServerLibraryFixture.fetched(large.source, title: "Large", count: 301), feedID: large.id,
                                                 manualRequestID: request.id)
        #expect(try await store.stageEpisodeNotification(fresh.feed, baseline: baseline) == nil, "no refresh journal in a server library")
        #expect(try await store.serverReleaseNotifications().contains { $0.feedID == large.id && $0.count > 0 }, "the release is to notify")
        let before = try await store.newEpisodeCounts()
        #expect(before[large.id] != nil, "the new episode is counted while the podcast shows: \(before)")
        try await store.retireEverythingForTesting()
        try await applier.apply([Self.removal(podcast, generation)])
        #expect(try await store.serverReleaseNotifications().allSatisfy { $0.feedID != large.id }, "a hidden podcast notifies nothing")
        #expect(try await store.newEpisodeCounts()[large.id] == nil, "nor is it counted")
        await fixture.close()
    }
}
