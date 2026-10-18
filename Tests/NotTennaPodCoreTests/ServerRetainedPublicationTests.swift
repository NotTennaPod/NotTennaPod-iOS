import Foundation
import Testing
@testable import NotTennaPodCore

/// A retained (staged, not yet published) publication is correct before it is live (server-mode PROTOCOL §6.8): local
/// changes inside its scope that are simple row images (a favorite, a checkpoint, a play-state change) are re-projected
/// at its switch while audio plays; one that meets a structural dependency of its plan (a removal, a merge or transfer,
/// ownership, an identity match, a download job) or the original projection's context keeps it for the pause, where it
/// is published correctly as a whole; and its switch's work is bounded before it is done. Against a server that sends
/// one commit (`ServerBoundedCutoverTests.serve`), and the pinned server for repairs.
@Suite(.serialized) struct ServerRetainedPublicationTests {
    typealias Cutover = ServerBoundedCutoverTests

    // MARK: - The publication's result accumulates across its plans

    /// A staged commit changing the account's queue policy and an episode the person favorites before its switch: the
    /// switch's re-projection does not clear the account-policy reload signal.
    @Test func aRebasedPublicationKeepsItsAccountPolicySignal() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let podcast = try await Cutover.registeredElsewhere(fixture)
        let first = podcast.episodes[0].id
        let account = fixture.identity.accountID
        let records = [Cutover.metadata(1, title: "Arriving 1, renamed"),
                       ServerRecord(entity: "account", id: account, fieldGroup: "queue_policy",
                                    value: ["enqueue_location": "front", "keep_sorted": false, "sort_order": "episode_title_a_z"])]
        let engine = try await Cutover.serve(fixture, records)
        await engine.setBudgets(direct: 1)
        let once = PlayingFlag()
        await engine.setBeforePublish {
            guard !once.value else { return }
            once.value = true
            try await store.setFavorite(episodeID: first, favorite: true)
        }
        let report = await engine.exchange()
        #expect(report.completed && report.publishedUnits == 1, "\(report)")
        #expect(report.accountPoliciesChanged, "the account-policy facade is told to reload")
        #expect(try await store.serverAccountPolicies()?.enqueueLocation == .front)
        #expect(try await store.episode(id: first)?.userState.isFavorite == true)
        await engine.close()
        await fixture.close()
    }

    // MARK: - Store-level checks: a shadow built, a local change, its publication

    /// The commit after the library's cursor (one is set when the library has none).
    static func nextInput(_ fixture: ServerLibraryFixture, _ records: [ServerRecord], slots: [ServerSlot] = []) async throws -> ServerUnitInput {
        var cursor = try await fixture.store.serverExchangeState().cursor
        if cursor == nil {
            let initial = try SyncCursor(logID: ContractIdentity.randomUUID(), epoch: 1, seq: 0, digest: String(repeating: "0", count: 64))
            try await fixture.store.setCursorForTesting(initial)
            cursor = initial
        }
        let live = try #require(cursor)
        let next = try SyncCursor(logID: live.logID, epoch: 1, seq: live.seq + 1, digest: String(repeating: "2", count: 64))
        return ServerUnitInput(commit: ServerCommit(epoch: 1, seq: next.seq, accepted: [], slots: slots, records: records), cursor: next,
                               watermark: nil, now: 1_760_000_000_000)
    }

    /// The shadow of `input`, built now (the local-change log's end taken first).
    static func build(_ fixture: ServerLibraryFixture, _ input: ServerUnitInput) async throws -> ServerShadowBuild {
        let ids = try await fixture.store.reserveServerLocalIDs(feeds: 4, episodes: 64 + input.commit.records.count)
        let touches = try await fixture.store.serverTouchWatermark()
        return try ServerShadow.build(input, database: fixture.url, shadow: fixture.directory.appendingPathComponent("probe-\(UUID()).sqlite"),
                                      history: nil, feedIDs: ids.feeds, episodeIDs: ids.episodes, touches: touches)
    }

    static func localEpisode(_ fixture: ServerLibraryFixture, guid: String) async throws -> LibraryEpisode? {
        try await fixture.store.feeds().flatMap(\.episodes).first { $0.details.identifier == guid }
    }

    /// An arriving episode's metadata with another media URL.
    static func metadata(_ number: Int, media url: String) -> ServerRecord {
        var record = Cutover.metadata(number, title: "Arriving \(number)")
        if var value = record.value?.objectValue, var media = value["media"]?.objectValue {
            media["url"] = .string(url)
            value["media"] = .object(media)
            record.value = .object(value)
        }
        return record
    }

    /// An episode merge staged while neither row is downloaded; the merged row's download finishes
    /// before the switch. The survivor takes the download, as a fresh merge projection gives it.
    @Test func aMergeStagedBeforeADownloadFinishesGivesTheSurvivorTheDownload() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let (_, podcast, generation, wire) = try await ServerMergeTests.registered(fixture)
        let survivor = try #require(try await Self.localEpisode(fixture, guid: "guid-1"))
        let merged = try #require(try await Self.localEpisode(fixture, guid: "guid-2"))
        try await store.retireEverythingForTesting()
        let input = try await Self.nextInput(fixture, [ServerMergeTests.identity(wire["guid-1"]!, podcast: podcast, guid: "guid-1"),
                                                       ServerMergeTests.identity(wire["guid-2"]!, podcast: podcast, guid: "guid-2", mergedInto: wire["guid-1"]!),
                                                       ServerMergeTests.playState(wire["guid-1"]!, generation, "unplayed")])
        let shadow = try await Self.build(fixture, input)
        let file = fixture.directory.appendingPathComponent("merged.mp3")
        try Data([1, 2, 3]).write(to: file)
        try await store.projectForTesting(merged.id) {
            $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path; $0.userState.downloadDate = ServerLibraryFixture.now
        }
        _ = try await store.publishServerShadow(shadow, input: input, history: nil)
        #expect(try await store.episode(id: merged.id) == nil, "the merged row goes")
        let kept = try #require(try await store.episode(id: survivor.id))
        #expect(kept.userState.isDownloaded && kept.userState.localFileURL == file.path, "the survivor owns the download: \(kept.userState)")
        await fixture.close()
    }

    /// The library's base records as a Force full synchronization's staged snapshot, but those `excluding` drops, built
    /// now (the local-change log's end taken first).
    static func fullBuild(_ fixture: ServerLibraryFixture, excluding: ([String?]) -> Bool) async throws -> (build: ServerFullBuild, head: SyncCursor) {
        let records = try ServerLibraryFixture.read(fixture.url, "SELECT entity, id, field_group, CAST(value AS TEXT) FROM ntp_records").filter { !excluding($0) }
        let items: [ContractJSON] = try records.map { row in
            ["record": ["entity": .string(row[0]!), "id": .string(row[1]!), "field_group": .string(row[2]!),
                        "value": try ContractJSON.decode(Array(row[3]!.utf8)), "provenance": []]]
        }
        let page = fixture.directory.appendingPathComponent("page-\(UUID()).json")
        try ContractJSON.object(["items": .array(items)]).canonicalData().write(to: page)
        let head = try #require(try await fixture.store.serverExchangeState().cursor)
        let snapshot = ServerAttachSnapshot(head: head.encoded, installWatermark: 0, itemCount: items.count, podcastCount: 1, pages: [page])
        let staged = fixture.directory.appendingPathComponent("full-\(UUID()).sqlite")
        try ServerFullReprojection.stageBase(snapshot, into: staged)
        let ids = try await fixture.store.reserveServerLocalIDs(feeds: 64, episodes: 64)
        let build = try ServerFullReprojection.build(database: fixture.url, file: staged, history: nil, now: 3_000_000,
                                                     feedIDs: ids.feeds, episodeIDs: ids.episodes, touches: try await fixture.store.serverTouchWatermark())
        return (build, head)
    }

    /// A Force full snapshot no longer holds episode two; the person favorites it after the build.
    /// The repair keeps it while that fact is pending (a deferred absence), with its favorite.
    @Test func aFullRepairKeepsAnEpisodeFavoritedSinceItsBuild() async throws {
        let (fixture, _, _, two) = try await ServerLocalPlaybackTests.library()
        let store = fixture.store
        let (build, head) = try await Self.fullBuild(fixture) { $0[1] == ServerLocalPlaybackTests.two }
        try await store.setFavorite(episodeID: two, favorite: true)
        _ = try await store.publishFullReprojection(build, head: head, now: 3_000_000, crash: nil)
        let kept = try #require(try await store.episode(id: two), "kept while its favorite is pending")
        #expect(kept.userState.isFavorite)
        await fixture.close()
    }

    /// A remotely subscribed podcast is built; before its switch the person subscribes to the same address.
    /// The arriving podcast attaches to that local feed: one feed, not two.
    @Test func aLocalSubscriptionToTheArrivingAddressDuringTheBuildIsMatched() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let input = try await Self.nextInput(fixture, try Cutover.arrivingRecords(count: 3))
        let shadow = try await Self.build(fixture, input)
        _ = try await store.insert(ServerLibraryFixture.fetched("https://example.test/arriving.xml", title: "Arriving", count: 3))
        _ = try await store.publishServerShadow(shadow, input: input, history: nil)
        let feeds = try await store.feeds().filter { $0.source == "https://example.test/arriving.xml" }
        #expect(feeds.count == 1, "one podcast for the address: \(feeds.map(\.id))")
        await fixture.close()
    }

    /// A commit replacing an episode's media URL is built; before its switch the person starts its download
    /// (without queueing). The working URL stays while the job uses it, as a fresh projection keeps it.
    @Test func aDownloadStartedDuringTheBuildKeepsItsWorkingMediaURL() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let podcast = try await Cutover.registeredElsewhere(fixture)
        let first = podcast.episodes[0].id
        let before = try #require(try await store.episode(id: first)?.details.media?.url)
        let input = try await Self.nextInput(fixture, [Self.metadata(1, media: "https://cdn.example.test/staged-1-moved.mp3")])
        let shadow = try await Self.build(fixture, input)
        _ = try await store.requestDownload(episodeID: first, directory: fixture.directory, enqueue: false)
        _ = try await store.publishServerShadow(shadow, input: input, history: nil)
        #expect(try await store.episode(id: first)?.details.media?.url == before, "the job's URL is kept")
        await fixture.close()
    }

    /// A commit retiring a queue add the server refused is built (its staged queue drops that
    /// episode); before its switch the person queues another. The refused one still leaves the queue.
    @Test func aQueueAddDuringTheBuildKeepsTheRetirementsWithdrawal() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let registered = try await fixture.subscribeRegistered()
        let ids = registered.feed.episodes.map(\.id).sorted()
        try await store.retireEverythingForTesting()
        _ = try await store.enqueue([ids[0]])
        let refused = try #require(try fixture.outbox().last { $0.type == "queue.add" })
        try await store.executeForTesting("UPDATE ntp_outbox SET receipt = ? WHERE op_id = ?",
                                          [.blob(try ContractJSON.object(["outcome": "rejected", "reason": "test"]).canonicalData()), .text(refused.opID)])
        let slot = try ServerSlot(["install_id": .string(fixture.identity.installID), "install_seq": .integer(refused.installSeq),
                                   "op_id": .string(refused.opID), "result": "accepted"])
        let input = try await Self.nextInput(fixture, [], slots: [slot])
        let shadow = try await Self.build(fixture, input)
        _ = try await store.enqueue([ids[1]])
        _ = try await store.publishServerShadow(shadow, input: input, history: nil)
        #expect(try await store.queue().map(\.id) == [ids[1]], "the refused add leaves, the new one stays")
        await fixture.close()
    }

    /// A full snapshot knows episode one but holds no queue membership for it, while it is queued
    /// here; after the build the person removes episode two from the queue. The repair empties the queue.
    @Test func aQueueRemovalDuringAFullBuildKeepsTheSnapshotsMembership() async throws {
        let (fixture, _, one, two) = try await ServerLocalPlaybackTests.library()
        let store = fixture.store
        #expect(try await store.queue().map(\.id) == [one, two])
        let (build, head) = try await Self.fullBuild(fixture) {
            $0[1] == ServerLocalPlaybackTests.one && ($0[2] == "queue_membership" || $0[2] == "queue_position")
        }
        _ = try await store.removeFromQueue([two])
        _ = try await store.publishFullReprojection(build, head: head, now: 3_000_000, crash: nil)
        let queue = try await store.queue().map(\.id)
        #expect(queue.isEmpty, "the repair removes what the snapshot does not queue: \(queue)")
        await fixture.close()
    }

    /// A small commit about a two-entry queue is built in a shadow while audio plays; before its switch the
    /// person queues 1,100 more episodes. Its switch would rewrite the whole queue: over the publication budget, it waits
    /// for the pause instead of running under the lock while playing, and then publishes.
    @Test func aQueueGrownDuringTheBuildIsNotRewrittenOverTheBudgetWhilePlaying() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        try await ServerProjectionUnitTests.Applier(fixture).apply(try Cutover.arrivingRecords(count: 1_103))
        var grown: [Int64] = []
        for number in 4...1_103 { grown.append(try #require(try await store.localEpisodeForTesting(wire: Cutover.wire(number)))) }
        let generation = Cutover.arrivingGeneration
        let first = try QueueKey.between(nil, nil, positionWriteID: UUID())
        let records = [ServerProjectionUnitTests.membership(Cutover.wire(1), generation, false)]
        _ = first
        let playing = PlayingFlag()
        playing.value = true
        let engine = try await Cutover.serve(fixture, records, playingFlag: playing)
        await engine.setBudgets(direct: 1, playingInterval: 0.001)
        let once = PlayingFlag(), queued = grown
        await engine.setBeforePublish {
            guard !once.value else { return }
            once.value = true
            _ = try await store.enqueue(queued)
        }
        let waiting = await engine.exchange()
        #expect(waiting.units.allSatisfy { !$0.published || $0.rowsWritten <= 1_000 }, "no publication over the budget while playing: \(waiting.units)")
        #expect(waiting.appliedUnits == 0 && waiting.waitingForPause, "\(waiting)")
        playing.value = false
        let paused = await engine.exchange()
        #expect(paused.completed && paused.appliedUnits == 1, "\(paused)")
        let queue = try await store.queue().map(\.id)
        #expect(Set(grown).isSubset(of: Set(queue)), "the person's queue is kept")
        await engine.close()
        await fixture.close()
    }

    // MARK: - Explicit cases

    /// An engine on `store` whose server sends one commit of `records` after the library's cursor as it is (a relaunch
    /// of `Cutover.serve`'s engine: the same commit, the same head).
    static func engine(_ fixture: ServerLibraryFixture, store: FeedLibraryStore, _ records: [ServerRecord], playing: PlayingFlag) async throws -> ServerSyncEngine {
        let cursor = try #require(try await store.serverExchangeState().cursor)
        let commit: ContractJSON = ["epoch": 1, "seq": .integer(cursor.seq + 1), "accepted": [], "decisions": [], "slots": [],
                                    "records": .array(records.map { record in
                                        ["entity": .string(record.entity), "id": .string(record.id), "field_group": .string(record.fieldGroup),
                                         "value": record.value ?? .null, "provenance": []] })]
        let digest = try ContractHash.nextDigest(previous: ContractHex.decode(cursor.digest) ?? [], commit)
        let head = try SyncCursor(logID: cursor.logID, epoch: 1, seq: cursor.seq + 1, digest: ContractHex.encode(digest)).encoded
        return try ServerSyncEngine(store: store, database: fixture.url, syncDatabase: fixture.directory.appendingPathComponent("sync.sqlite"),
                                    staging: fixture.directory.appendingPathComponent("staging"), transport: ServerSyncEngineUnitTests.Transport { path, body in
            switch path {
            case "v1/pull":
                let sent = body?["cursor"]?.stringValue == head
                return ["head": .string(head), "has_more": false, "items": sent ? [] : [["commit": commit]], "install_watermark": 0]
            case "v1/push": return ["results": []]
            default: return [:]
            }
        }, vault: fixture.vault, isPlaying: { playing.value }, isForeground: { false })
    }

    /// A catalog for the podcast shown with one episode, renaming that episode, deferred while playing by a download
    /// the person starts on it before the switch.
    static func deferredCatalog(_ fixture: ServerLibraryFixture, playing: PlayingFlag) async throws -> (engine: ServerSyncEngine, first: Int64, records: [ServerRecord]) {
        let store = fixture.store
        let podcast = try await Cutover.registeredElsewhere(fixture)
        let first = podcast.episodes[0].id
        let records = try Cutover.episodeRecords(2...301) + [Cutover.metadata(1, title: "Arriving 1, renamed")]
        let engine = try await Cutover.serve(fixture, records, playingFlag: playing)
        await engine.setBudgets(playingInterval: 0.001)
        let once = PlayingFlag(), media = fixture.directory
        await engine.setBeforePublish {
            guard !once.value else { return }
            once.value = true
            _ = try await store.requestDownload(episodeID: first, directory: media, enqueue: false)
        }
        return (engine, first, records)
    }

    /// A queue clear made between the staging and the switch survives the publication: what the
    /// person cleared stays gone, the arriving podcast's queued episodes arrive, and nothing is
    /// staged again.
    @Test func aQueueClearDuringStagingIsKept() async throws {
        let (fixture, small, engine) = try await Cutover.arrival()
        let store = fixture.store
        _ = try await store.enqueue([small.episodes.map(\.id).sorted()[1]])
        let once = PlayingFlag()
        await engine.setBeforePublish {
            guard !once.value else { return }
            once.value = true
            _ = try await store.clearQueue()
        }
        let report = await engine.exchange()
        #expect(report.completed && report.shadowsBuilt == 1, "\(report)")
        let queue = try await store.queue()
        #expect(queue.count == 3 && queue.allSatisfy { !small.episodes.map(\.id).contains($0.id) }, "\(queue.map(\.id))")
        await engine.close()
        await fixture.close()
    }

    /// A discovery filing the server refused retires in a staged commit; the person queues another episode before the
    /// switch. The refused filing still leaves the queue (the retirement's withdrawal is the rebase's context).
    @Test func aRefusedDiscoveryFilingStillLeavesTheQueueAfterARebase() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let registered = try await fixture.subscribeRegistered()
        let ids = registered.feed.episodes.map(\.id).sorted()
        try await store.retireEverythingForTesting()
        _ = try await store.enqueue([ids[0]])
        let filing = try #require(try fixture.outbox().last { $0.type == "queue.add" })
        // As a discovery proposal's optimistic filing, refused.
        try await store.executeForTesting("UPDATE ntp_outbox SET type = 'discovery.propose', receipt = ? WHERE op_id = ?",
                                          [.blob(try ContractJSON.object(["outcome": "rejected", "reason": "test"]).canonicalData()), .text(filing.opID)])
        let slot = try ServerSlot(["install_id": .string(fixture.identity.installID), "install_seq": .integer(filing.installSeq),
                                   "op_id": .string(filing.opID), "result": "accepted"])
        let input = try await Self.nextInput(fixture, [], slots: [slot])
        let shadow = try await Self.build(fixture, input)
        _ = try await store.enqueue([ids[1]])
        let result = try await store.publishServerShadow(shadow, input: input, history: nil, workLimit: 1_000)
        #expect(result.rebased >= 1 && !result.wholeAtPause, "re-projected at the switch: \(result.rebased)")
        #expect(try await store.queue().map(\.id) == [ids[1]])
        await fixture.close()
    }

    /// A local refresh of the podcast whose catalog is being staged adds an item no wire ID names yet (identity
    /// re-resolution could match it): the switch cannot re-project that, so the unit is published as a whole at the pause,
    /// and the local item stays beside the catalog.
    @Test func aLocalRefreshDuringStagingPublishesTheCatalogAsAWhole() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let podcast = try await Cutover.registeredElsewhere(fixture)
        let engine = try await Cutover.serve(fixture, try Cutover.episodeRecords(2...301))
        let once = PlayingFlag()
        await engine.setBeforePublish {
            guard !once.value else { return }
            once.value = true
            _ = try await store.applyRefresh(ServerLibraryFixture.fetched("https://example.test/arriving.xml", title: "Arriving", count: 1), feedID: podcast.id)
        }
        let report = await engine.exchange()
        #expect(report.completed && report.shadowsBuilt == 1, "\(report)")
        let log = try await Self.log(engine)
        #expect(log.contains { $0.contains("published as a whole") } && !log.contains { $0.contains("staged again") }, "\(log)")
        let episodes = try #require(try await Cutover.arrived(store)).episodes
        #expect(episodes.count == 302, "the catalog and the local item: \(episodes.count)")
        #expect(Set(episodes.compactMap(\.details.identifier)).count == episodes.count, "no item twice")
        #expect(try fixture.rows("SELECT (SELECT count(*) FROM ntp_hidden_episodes) + (SELECT count(*) FROM ntp_staging)") == [["0"]])
        await engine.close()
        await fixture.close()
    }

    static func log(_ engine: ServerSyncEngine) async throws -> [String] { try await engine.logEntries().map(\.detail) }

    /// A repair whose snapshot no longer holds an episode the person favorites after its build: within the publication
    /// budget it is deferred, nothing written; at the pause (no budget) it is published as a whole, the episode kept with
    /// its favorite, and the request fulfilled.
    @Test func aFullRepairIsDeferredAndPublishedAsAWholeAtThePause() async throws {
        let (fixture, _, one, two) = try await ServerLocalPlaybackTests.library()
        let store = fixture.store
        try await store.requestServerFullSynchronization()
        let (build, head) = try await Self.fullBuild(fixture) { $0[1] == ServerLocalPlaybackTests.two }
        try await store.setFavorite(episodeID: two, favorite: true)
        await #expect {
            _ = try await store.publishFullReprojection(build, head: head, now: 3_000_000, crash: nil, workLimit: 1_000)
        } throws: { error in
            if case ServerApplyError.deferred = error { return true }
            return false
        }
        #expect(try await store.serverFullSynchronizationRequested(), "nothing written while deferred")
        let result = try await store.publishFullReprojection(build, head: head, now: 3_000_000, crash: nil)
        #expect(result.wholeAtPause && result.published)
        #expect(try await store.episode(id: two)?.userState.isFavorite == true, "kept while its favorite is pending")
        #expect(try await store.episode(id: one) != nil)
        #expect(try await !store.serverFullSynchronizationRequested(), "the request is fulfilled")
        await fixture.close()
    }

    /// A unit deferred while playing is kept; the app is stopped (its store reopened: the local-change log and the kept
    /// build are gone). After the relaunch the staging is taken out and the unit published correctly at the pause.
    @Test func aRetainedUnitSurvivesAStoreReopen() async throws {
        let fixture = try await ServerLibraryFixture()
        let playing = PlayingFlag()
        playing.value = true
        let (engine, first, records) = try await Self.deferredCatalog(fixture, playing: playing)
        let waiting = await engine.exchange()
        #expect(waiting.waitingForPause && waiting.appliedUnits == 0, "\(waiting)")
        #expect(try fixture.rows("SELECT count(*) FROM ntp_hidden_episodes") == [["300"]], "kept, staged")
        await engine.close()
        try await fixture.store.close()
        let reopened = try FeedLibraryStore(url: fixture.url)
        _ = FeedAuthentication(store: reopened, vault: fixture.vault)
        playing.value = false
        let relaunched = try await Self.engine(fixture, store: reopened, records, playing: playing)
        let report = await relaunched.exchange()
        #expect(report.completed && report.appliedUnits == 1, "\(report)")
        #expect(try await Self.log(relaunched).contains { $0.contains("taken out") }, "the staging of the earlier opening is taken out")
        #expect(try await reopened.episode(id: first)?.details.title == "Arriving 1, renamed")
        #expect(try await reopened.downloadJobs().contains { $0.episodeID == first }, "the download goes on")
        #expect(try await reopened.feeds().first { $0.source == "https://example.test/arriving.xml" }?.episodes.count == 301)
        #expect(try fixture.rows("SELECT (SELECT count(*) FROM ntp_hidden_episodes) + (SELECT count(*) FROM ntp_staging)") == [["0"]])
        await relaunched.close()
        try await reopened.close()
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    /// A unit kept for the pause stops being next when the live cursor moves under it (another lineage): before the next
    /// commit applies, the kept build and its staging are taken out.
    @Test func aRetainedUnitIsDroppedWhenTheBaseCursorMoves() async throws {
        let fixture = try await ServerLibraryFixture()
        let playing = PlayingFlag()
        playing.value = true
        let (engine, _, _) = try await Self.deferredCatalog(fixture, playing: playing)
        let waiting = await engine.exchange()
        #expect(waiting.waitingForPause, "\(waiting)")
        #expect(await engine.keptShadow != nil)
        try await fixture.store.setCursorForTesting(try SyncCursor(logID: ContractIdentity.randomUUID(), epoch: 1, seq: 0, digest: String(repeating: "0", count: 64)))
        try await engine.reconcileKeptShadow()
        #expect(await engine.keptShadow == nil, "dropped")
        #expect(try fixture.rows("SELECT (SELECT count(*) FROM ntp_hidden_episodes) + (SELECT count(*) FROM ntp_staging)") == [["0"]], "its staging taken out")
        await engine.close()
        await fixture.close()
    }
}
