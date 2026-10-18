import Foundation
import Testing
@testable import NotTennaPodCore

/// Sync never stalls behind a large unit while a person listens: a write that changes nothing is not
/// made and not counted (exactly: a real change is never skipped), the content records a commit changes are staged ahead
/// of the unit's switch with the shown rows only they change, and later small commits apply while playing.
@Suite(.serialized) struct ServerLargeUnitTests {
    typealias Cutover = ServerBoundedCutoverTests
    typealias Saver = ServerStagedPublicationTests.Saver

    /// A server that sends `commits` in order after the library's cursor (a fresh log): everything after the cursor a pull
    /// names.
    static func serve(_ fixture: ServerLibraryFixture, _ commits: [[ServerRecord]], playing: PlayingFlag, foreground: PlayingFlag = PlayingFlag(),
                      eligibility: ServerPublicationEligibility = ServerPublicationEligibility()) async throws -> ServerSyncEngine {
        let start = try SyncCursor(logID: ContractIdentity.randomUUID(), epoch: 1, seq: 0, digest: String(repeating: "0", count: 64))
        try await fixture.store.setCursorForTesting(start)
        var bodies: [(cursor: String, commit: ContractJSON, head: String)] = []
        var previous = start
        for (index, records) in commits.enumerated() {
            let seq = Int64(index + 1)
            let commit: ContractJSON = ["epoch": 1, "seq": .integer(seq), "accepted": [], "decisions": [], "slots": [],
                                        "records": .array(records.map { record in
                                            var json: ContractObject = ["entity": .string(record.entity), "id": .string(record.id), "field_group": .string(record.fieldGroup),
                                                                        "provenance": .array(record.provenance.map(ContractJSON.string))]
                                            if let value = record.value { json["value"] = value } else { json["tombstone"] = true }
                                            return .object(json) })]
            let digest = try ContractHash.nextDigest(previous: ContractHex.decode(previous.digest) ?? [], commit)
            let next = try SyncCursor(logID: start.logID, epoch: 1, seq: seq, digest: ContractHex.encode(digest))
            bodies.append((previous.encoded, commit, next.encoded))
            previous = next
        }
        let all = bodies, head = previous.encoded
        return try ServerSyncEngine(store: fixture.store, database: fixture.url, syncDatabase: fixture.directory.appendingPathComponent("sync.sqlite"),
                                    staging: fixture.directory.appendingPathComponent("staging"), transport: ServerSyncEngineUnitTests.Transport { path, body in
            switch path {
            case "v1/pull":
                let after = body?["cursor"]?.stringValue
                let index = all.firstIndex { $0.cursor == after }
                guard let index else { return ["head": .string(head), "has_more": false, "items": [], "install_watermark": 0] }
                return ["head": .string(head), "has_more": false, "items": .array(all[index...].map { ["commit": $0.commit] }), "install_watermark": 0]
            case "v1/push": return ["results": []]
            default: return [:]
            }
        }, vault: fixture.vault, isPlaying: { playing.value }, isForeground: { foreground.value }, eligibility: eligibility)
    }

    static func record(_ fixture: ServerLibraryFixture, _ key: ServerRecordKey) throws -> [String?]? {
        try fixture.rows("SELECT CAST(value AS TEXT), provenance FROM ntp_records WHERE entity = '\(key.entity)' AND id = '\(key.id)' AND field_group = '\(key.fieldGroup)'").first
    }

    // MARK: - (b) No-op writes are skipped, exactly

    /// A commit repeating a record the base holds identically writes nothing for it and does not count it; a value
    /// change, a provenance-only change and a tombstone in the same commit are all applied.
    @Test func aRecordTheBaseHoldsIdenticallyIsNotWrittenButEveryRealChangeIs() async throws {
        let fixture = try await ServerLibraryFixture()
        let applier = try await ServerProjectionUnitTests.Applier(fixture)
        try await applier.apply(try Cutover.arrivingRecords(count: 3))
        let one = Cutover.metadata(1, title: "One"), two = Cutover.metadata(2, title: "Two")
        var three = Cutover.metadata(3, title: "Three")
        three.provenance = [ContractIdentity.randomUUID()]
        let favorite = ServerRecord(entity: "episode", id: Cutover.wire(2), fieldGroup: "favorite", value: ["generation_id": .string(Cutover.arrivingGeneration), "on": true])
        try await applier.apply([one, two, three, favorite])
        let local2 = try #require(try await fixture.store.localEpisodeForTesting(wire: Cutover.wire(2)))
        let local3 = try #require(try await fixture.store.localEpisodeForTesting(wire: Cutover.wire(3)))
        // The same records again, but: two renamed, three with other provenance only, the favorite gone.
        var renamed = two
        renamed.value = Cutover.metadata(2, title: "Two, renamed").value
        if var value = renamed.value?.objectValue, let original = two.value?["revision"] { value["revision"] = original; renamed.value = .object(value) }
        var moved = three
        moved.provenance = [ContractIdentity.randomUUID()]
        let unfavorite = ServerRecord(entity: "episode", id: Cutover.wire(2), fieldGroup: "favorite", value: nil)
        let result = try await applier.apply([one, renamed, moved, unfavorite])
        #expect(result.work == 3 + 1, "three real record changes and one changed row; the identical record is not counted: \(result.work)")
        #expect(try Self.record(fixture, ServerRecordKey(entity: "episode", id: Cutover.wire(2), fieldGroup: "metadata"))?[0]?.contains("Two, renamed") == true)
        #expect(try Self.record(fixture, ServerRecordKey(entity: "episode", id: Cutover.wire(3), fieldGroup: "metadata"))?[1]?.contains(moved.provenance[0]) == true,
                "a provenance-only change is a real change")
        #expect(try Self.record(fixture, ServerRecordKey(entity: "episode", id: Cutover.wire(2), fieldGroup: "favorite")) == nil, "the tombstone deletes")
        let shown2 = try #require(try await fixture.store.episode(id: local2))
        #expect(shown2.details.title == "Two, renamed" && !shown2.userState.isFavorite)
        #expect(try await fixture.store.episode(id: local3)?.details.title == "Three")
        // Nothing but identical records: no record write, nothing counted.
        let nothing = try await applier.apply([one, renamed, moved])
        #expect(nothing.work == 0, "\(nothing.work)")
        await fixture.close()
    }

    // MARK: - (c) Content updates are staged ahead of the switch

    /// Another device's observation of a catalog the library shows: every episode's metadata record changes (its
    /// revision), nothing a person sees does. While audio plays, its records are staged ahead in bounded transactions
    /// and its switch is small: it applies while playing, within the budget, and changes no row.
    @Test func anObservationOfAShownCatalogAppliesWhilePlaying() async throws {
        let fixture = try await ServerLibraryFixture()
        try await ServerProjectionUnitTests.Applier(fixture).apply(try Cutover.arrivingRecords(count: 1_200))
        let before = try fixture.rows("SELECT id, CAST(record AS TEXT) FROM episodes ORDER BY id")
        let observation = (1...1_200).map { Cutover.metadata($0, title: "Arriving \($0)") }
        let playing = PlayingFlag()
        playing.value = true
        let engine = try await Self.serve(fixture, [observation], playing: playing)
        await engine.setBudgets(playingInterval: 0.001)
        let report = await engine.exchange()
        #expect(report.completed && report.appliedUnits == 1 && !report.waitingForPause, "\(report)")
        let unit = try #require(report.units.first)
        #expect(unit.published && unit.rowsWritten <= 1_000, "a small switch: \(unit)")
        #expect(report.stagingBatches >= 3, "1,200 records staged ahead, 500 at a time: \(report.stagingBatches)")
        #expect(try fixture.rows("SELECT id, CAST(record AS TEXT) FROM episodes ORDER BY id") == before, "no row a person sees changed")
        let revision = try #require(observation[0].value?["revision"]?.stringValue)
        #expect(try Self.record(fixture, ServerRecordKey(entity: "episode", id: Cutover.wire(1), fieldGroup: "metadata"))?[0]?.contains(revision) == true,
                "the base holds the observation")
        #expect(try fixture.rows("SELECT count(*) FROM ntp_staging") == [["0"]])
        await engine.close()
        await fixture.close()
    }

    /// Staged content updates taken out (a crash after staging, then a relaunch) get their previous values and
    /// provenance back exactly, and the unit is then applied once.
    @Test func stagedContentUpdatesTakenOutRestoreThePreviousRecordsExactly() async throws {
        let fixture = try await ServerLibraryFixture()
        try await ServerProjectionUnitTests.Applier(fixture).apply(try Cutover.arrivingRecords(count: 600))
        let records = { try fixture.rows("SELECT entity, id, field_group, CAST(value AS TEXT), provenance FROM ntp_records ORDER BY entity, id, field_group") }
        let original = try records()
        let observation = (1...600).map { number -> ServerRecord in
            var record = Cutover.metadata(number, title: "Arriving \(number)")
            record.provenance = [ContractIdentity.randomUUID()]
            return record
        }
        let playing = PlayingFlag()
        let engine = try await Self.serve(fixture, [observation], playing: playing)
        await engine.setCrashPoint(ServerExchangePushPullTests.crashOnce(at: "staging.staged"))
        let crashed = await engine.exchange()
        #expect(crashed.error == "InjectedCrash()", "\(crashed)")
        #expect(try records() != original, "staged ahead")
        // Taken out: exactly the records before.
        while try await fixture.store.discardServerStagingBatch() {}
        #expect(try records() == original, "the previous values and provenance are back")
        let report = await engine.exchange()
        #expect(report.completed && report.appliedUnits == 1, "\(report)")
        let applied = try records()
        #expect(applied != original && applied.count == original.count)
        await engine.close()
        await fixture.close()
    }

    // MARK: - (c) A content change shown on many rows applies while playing

    /// 1,200 episodes renamed (another device's observation, a host moving every enclosure: more shown rows than one
    /// switch writes) while audio plays. The content records are staged ahead and each renamed row is shown ahead whole,
    /// in bounded transactions; the unit's switch is small. Local changes made meanwhile stay: a favorite before the rows
    /// are shown (that row is left to the switch, which re-projects it) and one after (the switch re-projects it over
    /// the shown row).
    @Test func aContentChangeShownOnManyRowsAppliesWhilePlaying() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        try await ServerProjectionUnitTests.Applier(fixture).apply(try Cutover.arrivingRecords(count: 1_200))
        let renames = (1...1_200).map { Cutover.metadata($0, title: "Renamed \($0)") }
        let early = try #require(try await store.localEpisodeForTesting(wire: Cutover.wire(600)))
        let late = try #require(try await store.localEpisodeForTesting(wire: Cutover.wire(900)))
        let playing = PlayingFlag()
        playing.value = true
        let engine = try await Self.serve(fixture, [renames], playing: playing)
        await engine.setBudgets(playingInterval: 0.001)
        let before = PlayingFlag(), after = PlayingFlag()
        await engine.setBeforeStagingBatch {
            guard !before.value else { return }
            before.value = true
            try await store.setFavorite(episodeID: early, favorite: true)
        }
        await engine.setBeforePublish {
            guard !after.value else { return }
            after.value = true
            try await store.setFavorite(episodeID: late, favorite: true)
        }
        let report = await engine.exchange()
        #expect(report.completed && report.appliedUnits == 1 && !report.waitingForPause, "applied while playing: \(report)")
        let unit = try #require(report.units.first)
        #expect(unit.published && unit.rowsWritten <= 1_000, "a small switch: \(unit)")
        #expect(report.shownAhead == 1_199, "every renamed row shown ahead but the one touched before: \(report.shownAhead)")
        #expect(report.stagingBatches >= 3 + 12, "records 500 and rows 100 at a time: \(report.stagingBatches)")
        for number in [1, 600, 900, 1_200] {
            let local = try #require(try await store.localEpisodeForTesting(wire: Cutover.wire(number)))
            #expect(try await store.episode(id: local)?.details.title == "Renamed \(number)")
        }
        #expect(try await store.episode(id: early)?.userState.isFavorite == true, "the favorite made before the rows were shown")
        #expect(try await store.episode(id: late)?.userState.isFavorite == true, "the favorite made after")
        #expect(try fixture.rows("SELECT count(*) FROM ntp_staging") == [["0"]])
        await engine.close()
        await fixture.close()
    }

    /// A row the commit changes beyond its content (here a favorite with the rename) is not shown ahead: the content alone
    /// would not give its image. After a crash with the other rows shown ahead (the staging is taken out, so the base has
    /// its previous records back while those rows show the new content), the unit applies while playing and the library
    /// is exactly the one the same commit applied whole gives.
    @Test func aRowTheCommitAlsoChangesOtherwiseIsShownOnlyByItsUnit() async throws {
        let commit = (1...600).map { Cutover.metadata($0, title: "Renamed \($0)") }
            + [ServerRecord(entity: "episode", id: Cutover.wire(300), fieldGroup: "favorite", value: ["generation_id": .string(Cutover.arrivingGeneration), "on": true])]
        let library = { (fixture: ServerLibraryFixture) in
            try fixture.rows("SELECT id, pubdate, CAST(record AS TEXT) FROM episodes ORDER BY id")
                + fixture.rows("SELECT entity, id, field_group, CAST(value AS TEXT), provenance FROM ntp_records ORDER BY entity, id, field_group")
        }
        // The same commit applied whole, when nothing plays, on the same library.
        let arriving = try Cutover.arrivingRecords(count: 600)
        let whole = try await ServerLibraryFixture()
        try await ServerProjectionUnitTests.Applier(whole).apply(arriving)
        let control = try await Self.serve(whole, [commit], playing: PlayingFlag())
        #expect(await control.exchange().completed)
        let expected = try library(whole)
        await control.close()
        await whole.close()

        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        try await ServerProjectionUnitTests.Applier(fixture).apply(arriving)
        let playing = PlayingFlag()
        playing.value = true
        let engine = try await Self.serve(fixture, [commit], playing: playing)
        await engine.setBudgets(playingInterval: 0.001)
        await engine.setCrashPoint(ServerExchangePushPullTests.crashOnce(at: "staging.staged"))
        let crashed = await engine.exchange()
        #expect(crashed.error == "InjectedCrash()" && crashed.shownAhead == 599, "\(crashed)")
        let shared = try #require(try await store.localEpisodeForTesting(wire: Cutover.wire(300)))
        let other = try #require(try await store.localEpisodeForTesting(wire: Cutover.wire(301)))
        #expect(try await store.episode(id: other)?.details.title == "Renamed 301", "shown ahead")
        let unshown = try #require(try await store.episode(id: shared))
        #expect(unshown.details.title == "Arriving 300" && !unshown.userState.isFavorite, "left to its unit: \(unshown.details.title ?? "-")")
        let report = await engine.exchange()
        #expect(report.completed && report.appliedUnits == 1 && !report.waitingForPause, "applied while playing: \(report)")
        let actual = try library(fixture)
        let differing = zip(actual, expected).filter { $0.0 != $0.1 }.prefix(3).map { "\($0.0)\n  vs \($0.1)" }
        #expect(actual == expected, "the library the commit applied whole gives (\(actual.count) vs \(expected.count) rows): \(differing.joined(separator: "\n"))")
        await engine.close()
        await fixture.close()
    }

    /// Counts the calls of a test hook.
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
    }

    /// A download the person starts on one of the renamed episodes while its rows are being shown ahead: a structural
    /// dependency of the unit (PROTOCOL §6.8), so showing rows ahead stops and the unit waits for the pause, kept. There it is
    /// published as a whole over the rows already shown, and every episode shows the commit's content, the base holding
    /// exactly the commit's records.
    @Test func showingAheadStopsAtADeferringLocalChangeAndThePausePublishesTheWhole() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        try await ServerProjectionUnitTests.Applier(fixture).apply(try Cutover.arrivingRecords(count: 600))
        let renames = (1...600).map { Cutover.metadata($0, title: "Renamed \($0)") }
        let downloaded = try #require(try await store.localEpisodeForTesting(wire: Cutover.wire(500)))
        let playing = PlayingFlag()
        playing.value = true
        let engine = try await Self.serve(fixture, [renames], playing: playing)
        await engine.setBudgets(playingInterval: 0.001)
        // Two transactions stage the records, then six show the rows: after the second of those, the download starts.
        let calls = Calls(), media = fixture.directory
        await engine.setBeforeStagingBatch {
            guard calls.next() == 5 else { return }
            _ = try await store.requestDownload(episodeID: downloaded, directory: media, enqueue: false)
        }
        let waiting = await engine.exchange()
        #expect(waiting.waitingForPause && waiting.appliedUnits == 0, "kept for the pause: \(waiting)")
        #expect(waiting.shownAhead == 200, "showing ahead stopped at the download: \(waiting.shownAhead)")
        playing.value = false
        let paused = await engine.exchange()
        #expect(paused.completed && paused.appliedUnits == 1 && paused.shadowsBuilt == 0, "published at the pause, not built again: \(paused)")
        let titles = try fixture.rows("SELECT CAST(record AS TEXT) FROM episodes").compactMap { $0[0] }
            .compactMap { try? JSONDecoder().decode(LibraryEpisode.self, from: Data($0.utf8)).details.title }
        #expect(titles.count == 600 && titles.allSatisfy { $0.hasPrefix("Renamed ") }, "every episode shows the commit")
        for record in renames {
            let stored = try #require(try Self.record(fixture, record.key))
            #expect(try stored[0] == String(decoding: try #require(record.value).canonicalData(), as: UTF8.self), "the base holds the commit's record")
        }
        #expect(try fixture.rows("SELECT count(*) FROM ntp_staging") == [["0"]])
        await engine.close()
        await fixture.close()
    }

    // MARK: - Large changes to state people act on: whole, in the background while playing

    /// Another device's listening of 5,000 episodes in one commit (position, played time, last played: about 20,000 row
    /// writes), then a favorite and a queue edit behind it.
    static func listeningAndBehind(_ count: Int = 5_000) -> [[ServerRecord]] {
        let generation = Cutover.arrivingGeneration
        let listening = (1...count).flatMap { number -> [ServerRecord] in
            let id = Cutover.wire(number)
            return [ServerRecord(entity: "episode", id: id, fieldGroup: "position", value: ["generation_id": .string(generation), "position": 30_000]),
                    ServerRecord(entity: "episode", id: id, fieldGroup: "played_time", value: ["generation_id": .string(generation), "played_ms": 30_000]),
                    ServerRecord(entity: "episode", id: id, fieldGroup: "last_played", value: ["generation_id": .string(generation), "time": 1_760_000_000_000])]
        }
        let favorite = [ServerRecord(entity: "episode", id: Cutover.wire(10), fieldGroup: "favorite", value: ["generation_id": .string(generation), "on": true])]
        let key = try! QueueKey.between(nil, nil, positionWriteID: UUID())
        let queueEdit = [ServerProjectionUnitTests.membership(Cutover.wire(4_000), generation, true), ServerProjectionUnitTests.position(Cutover.wire(4_000), generation, key)]
        return [listening, favorite, queueEdit]
    }

    /// Whether each commit of `listeningAndBehind` shows on the library.
    static func applied(_ fixture: ServerLibraryFixture) async throws -> (listening: Bool, favorite: Bool, queued: Bool) {
        let store = fixture.store
        let listened = try #require(try await store.localEpisodeForTesting(wire: Cutover.wire(2_500)))
        let favored = try #require(try await store.localEpisodeForTesting(wire: Cutover.wire(10)))
        let queued = try #require(try await store.localEpisodeForTesting(wire: Cutover.wire(4_000)))
        return (try await store.episode(id: listened)?.userState.positionMilliseconds == 30_000,
                try await store.episode(id: favored)?.userState.isFavorite == true,
                try await store.queue().map(\.id).contains(queued))
    }

    /// While audio plays with no scene in the foreground (the screen locked, another app in front), the 5,000-episode
    /// listening commit is published whole, in one transaction within the background budget, and the commits behind it
    /// apply too: nothing waits for a pause.
    @Test func aLargeListeningCommitAndThoseBehindItApplyInTheBackgroundWhilePlaying() async throws {
        let fixture = try await ServerLibraryFixture()
        try await ServerProjectionUnitTests.Applier(fixture).apply(try Cutover.arrivingRecords(count: 5_000))
        let playing = PlayingFlag()
        playing.value = true
        let engine = try await Self.serve(fixture, Self.listeningAndBehind(), playing: playing)
        await engine.setBudgets(playingInterval: 0.001)
        let report = await engine.exchange()
        #expect(report.completed && !report.waitingForPause && !report.waitingForBackground && report.appliedUnits == 3, "\(report)")
        let whole = try #require(report.units.first)
        #expect(whole.published && whole.background && whole.work > 1_000 && whole.work <= 24_000, "one whole publication within the background budget: \(whole)")
        #expect(report.units.dropFirst().allSatisfy { !$0.background }, "the small commits behind it as usual: \(report.units)")
        let shown = try await Self.applied(fixture)
        #expect(shown.listening && shown.favorite && shown.queued, "\(shown)")
        #expect(try await engine.logEntries().contains { $0.detail.contains("published whole while audio plays in the background") })
        await engine.close()
        await fixture.close()
    }

    /// While audio plays and the app is in use, the listening commit waits for the app to leave the foreground (nothing
    /// of it, nor of the commits behind it, shows); once the person leaves the app, still playing, all of them apply.
    @Test func inTheForegroundTheyWaitAndApplyOnceThePersonLeavesTheApp() async throws {
        let fixture = try await ServerLibraryFixture()
        try await ServerProjectionUnitTests.Applier(fixture).apply(try Cutover.arrivingRecords(count: 5_000))
        let playing = PlayingFlag(), foreground = PlayingFlag(), eligibility = ServerPublicationEligibility()
        playing.value = true
        foreground.value = true
        let engine = try await Self.serve(fixture, Self.listeningAndBehind(), playing: playing, foreground: foreground, eligibility: eligibility)
        await engine.setBudgets(playingInterval: 0.001)
        for _ in 0..<2 {
            let waiting = await engine.exchange()
            #expect(waiting.waitingForBackground && !waiting.waitingForPause && waiting.appliedUnits == 0, "\(waiting)")
            let shown = try await Self.applied(fixture)
            #expect(!shown.listening && !shown.favorite && !shown.queued, "nothing while the app is in use: \(shown)")
        }
        foreground.value = false
        eligibility.changed()
        let left = await engine.exchange()
        #expect(left.completed && left.appliedUnits == 3 && left.units.first?.background == true, "\(left)")
        let shown = try await Self.applied(fixture)
        #expect(shown.listening && shown.favorite && shown.queued, "\(shown)")
        await engine.close()
        await fixture.close()
    }

    /// Over the background budget, a publication waits for the pause even with the app in the background, kept; the pause
    /// publishes it, and what is behind it.
    @Test func overTheBackgroundBudgetItWaitsForThePause() async throws {
        let fixture = try await ServerLibraryFixture()
        try await ServerProjectionUnitTests.Applier(fixture).apply(try Cutover.arrivingRecords(count: 5_000))
        let playing = PlayingFlag(), eligibility = ServerPublicationEligibility()
        playing.value = true
        let engine = try await Self.serve(fixture, Self.listeningAndBehind(), playing: playing, eligibility: eligibility)
        await engine.setBudgets(background: 5_000, playingInterval: 0.001)
        let waiting = await engine.exchange()
        #expect(waiting.waitingForPause && waiting.appliedUnits == 0, "\(waiting)")
        #expect(try await !Self.applied(fixture).listening)
        playing.value = false
        eligibility.changed()
        let paused = await engine.exchange()
        #expect(paused.completed && paused.appliedUnits == 3 && paused.units.allSatisfy { !$0.background }, "\(paused)")
        let shown = try await Self.applied(fixture)
        #expect(shown.listening && shown.favorite && shown.queued, "\(shown)")
        await engine.close()
        await fixture.close()
    }

    /// Admitted in the background while playing and built, the publication is refused when the person opens the app before
    /// its switch (checked again then, and by the store): it waits for the app to leave the foreground again,
    /// kept, then applies from what it built.
    @Test func openingTheAppBeforeTheSwitchRefusesTheBackgroundPublication() async throws {
        let fixture = try await ServerLibraryFixture()
        try await ServerProjectionUnitTests.Applier(fixture).apply(try Cutover.arrivingRecords(count: 5_000))
        let playing = PlayingFlag(), foreground = PlayingFlag(), eligibility = ServerPublicationEligibility(), once = PlayingFlag()
        playing.value = true
        let engine = try await Self.serve(fixture, Self.listeningAndBehind(), playing: playing, foreground: foreground, eligibility: eligibility)
        await engine.setBudgets(playingInterval: 0.001)
        await engine.setBeforePublish {
            guard !once.value else { return }
            once.value = true
            foreground.value = true
            eligibility.changed()
        }
        let refused = await engine.exchange()
        #expect(refused.waitingForBackground && refused.appliedUnits == 0 && refused.shadowsBuilt == 1, "\(refused)")
        #expect(try await !Self.applied(fixture).listening)
        foreground.value = false
        eligibility.changed()
        let left = await engine.exchange()
        #expect(left.completed && left.appliedUnits == 3 && left.shadowsBuilt == 0, "published from what it built: \(left)")
        await engine.close()
        await fixture.close()
    }

    // MARK: - (d) Small commits never wait behind a big unit while playing

    /// While a person listens (minute exports on another podcast): a 20,000-episode catalog arrives, then another
    /// device's observation of it that every episode shows (its titles), then a queue edit, a favorite and a history
    /// clear. Every commit applies while playing, in order, none stuck behind a big unit, and every unit stays within
    /// its budget.
    @Test func aCatalogItsObservationAndLaterSmallCommitsAllApplyWhilePlaying() async throws {
        let fixture = try await ServerLibraryFixture()
        let small = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/small.xml", title: "Small", count: 2)).feed
        try await fixture.store.retireEverythingForTesting()
        let count = 20_000, generation = Cutover.arrivingGeneration
        let history = (1...3).map { ServerRecord(entity: "episode", id: Cutover.wire($0), fieldGroup: "history", value: ["generation_id": .string(generation), "time": 1_760_000_000_000]) }
        let catalog = try Cutover.arrivingRecords(count: count) + history
        let observation = (1...count).map { Cutover.metadata($0, title: "Observed \($0)") }
        let key = try QueueKey.between(nil, nil, positionWriteID: UUID())
        let queueEdit = [ServerProjectionUnitTests.membership(Cutover.wire(5_000), generation, true), ServerProjectionUnitTests.position(Cutover.wire(5_000), generation, key)]
        let favorite = [ServerRecord(entity: "episode", id: Cutover.wire(10), fieldGroup: "favorite", value: ["generation_id": .string(generation), "on": true])]
        let historyClear = (1...3).map { ServerRecord(entity: "episode", id: Cutover.wire($0), fieldGroup: "history", value: nil) }
        let playing = PlayingFlag()
        playing.value = true
        let engine = try await Self.serve(fixture, [catalog, observation, queueEdit, favorite, historyClear], playing: playing)
        await engine.setBudgets(playingInterval: 0.001)
        let player = StorePlayer(fixture.store)
        try await player.load(small.episodes.map(\.id).sorted()[1])
        try await player.play()
        let saver = Saver(player)
        saver.start()
        var reports: [ServerExchangeReport] = []
        for _ in 0..<3 {
            let report = await engine.exchange()
            reports.append(report)
            if report.completed { break }
        }
        let saves = try await saver.stop()
        let units = reports.flatMap(\.units)
        #expect(reports.allSatisfy { !$0.waitingForPause && !$0.waitingForBackground }, "nothing waited for the pause: \(reports.map(\.appliedUnits))")
        #expect(units.count == 5 && units.map(\.seq) == [1, 2, 3, 4, 5],
                "every commit applied while playing, in order: \(units.map(\.seq)); \(reports.map { "pulled \($0.pulledCommits) applied \($0.appliedUnits) error \($0.error ?? "-") retry \($0.retryAfter ?? -1)" })")
        for unit in units {
            #expect(unit.published ? unit.rowsWritten <= 1_000 : unit.work <= 250, "within its budget: \(unit)")
        }
        #expect(saves >= 3, "the player exported meanwhile: \(saves) saves")
        #expect(try await Cutover.arrived(fixture.store)?.episodes.count == count)
        #expect(reports.map(\.shownAhead).reduce(0, +) >= count - 10, "the observation's rows shown ahead: \(reports.map(\.shownAhead))")
        let observed = try #require(try await fixture.store.localEpisodeForTesting(wire: Cutover.wire(count)))
        #expect(try await fixture.store.episode(id: observed)?.details.title == "Observed \(count)", "the observation shows")
        let queued = try #require(try await fixture.store.localEpisodeForTesting(wire: Cutover.wire(5_000)))
        #expect(try await fixture.store.queue().map(\.id).contains(queued), "the queue edit")
        let favored = try #require(try await fixture.store.localEpisodeForTesting(wire: Cutover.wire(10)))
        #expect(try await fixture.store.episode(id: favored)?.userState.isFavorite == true, "the favorite")
        let cleared = try #require(try await fixture.store.localEpisodeForTesting(wire: Cutover.wire(1)))
        #expect(try await fixture.store.episode(id: cleared)?.userState.lastPlayedHistoryMilliseconds == nil, "the history clear")
        await engine.close()
        await fixture.close()
    }
}
