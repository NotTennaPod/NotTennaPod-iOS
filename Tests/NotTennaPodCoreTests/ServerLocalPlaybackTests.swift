import Foundation
import Testing
@testable import NotTennaPodCore

/// Listening this library did: playback saves and ends mark their episodes in the same transaction
/// until the facts that represent them are recorded, and every projection, ordinary units and Force full
/// synchronization alike, shows this device's listening through the marks or those facts' overlays, whatever the
/// clocks say.
@Suite struct ServerLocalPlaybackTests {
    static let podcast = "p1:" + String(repeating: "a", count: 64), generation = "g1:" + String(repeating: "b", count: 64)
    static let one = "e1:" + String(repeating: "c", count: 64), two = "e1:" + String(repeating: "d", count: 64)

    static func episode(_ id: String, guid: String, lastPlayed: Int64, position: Int64, key: QueueKey) -> [ServerRecord] {
        [ServerRecord(entity: "episode", id: id, fieldGroup: "identity", value: ["podcast_id": .string(podcast), "occurrence": ["k": "rss-guid", "v": .string(guid), "guid": .string(guid)]]),
         ServerRecord(entity: "episode", id: id, fieldGroup: "metadata", value: [
            "title": .string(guid), "description": .null, "link": .null, "pub_date": 1_700_000_000_000, "image_url": .null, "payment_link": .null,
            "media": ["url": .string("https://example.test/\(guid).mp3"), "size": "1000", "mime_type": "audio/mpeg", "duration": 600_000],
            "chapters": .null, "chapter_url": .null, "transcript_url": .null, "transcript_type": .null, "social_interact_url": .null,
            "revision": .string(ContractIdentity.randomUUID()), "fetch_time": 1_700_000_000_000]),
         ServerRecord(entity: "episode", id: id, fieldGroup: "last_played", value: ["generation_id": .string(generation), "time": .integer(lastPlayed)]),
         ServerRecord(entity: "episode", id: id, fieldGroup: "position", value: ["generation_id": .string(generation), "position": .integer(position)]),
         ServerRecord(entity: "episode", id: id, fieldGroup: "played_time", value: ["generation_id": .string(generation), "played_ms": .integer(position)]),
         ServerRecord(entity: "episode", id: id, fieldGroup: "queue_membership", value: ["generation_id": .string(generation), "in_queue": true]),
         ServerRecord(entity: "episode", id: id, fieldGroup: "queue_position", value: ["generation_id": .string(generation), "key": .string(key.wire), "position_id": .string(ContractIdentity.randomUUID())])]
    }

    /// A podcast another device made, with two episodes the server last saw played at 2,000 s (10 s in).
    static func library() async throws -> (fixture: ServerLibraryFixture, applier: ServerProjectionUnitTests.Applier, one: Int64, two: Int64) {
        let fixture = try await ServerLibraryFixture()
        let applier = try await ServerProjectionUnitTests.Applier(fixture)
        let first = try QueueKey.between(nil, nil, positionWriteID: UUID()), second = try QueueKey.between(first, nil, positionWriteID: UUID())
        try await applier.apply([
            ServerRecord(entity: "podcast", id: podcast, fieldGroup: "identity", value: ["refresh_url": "https://example.test/feed.xml",
                "aliases": [["url": "https://example.test/feed.xml", "normalized": "https://example.test/feed.xml"]]]),
            ServerRecord(entity: "podcast", id: podcast, fieldGroup: "subscription", value: ["state": "subscribed", "generation_id": .string(generation)])]
            + episode(one, guid: "one", lastPlayed: 2_000_000, position: 10_000, key: first)
            + episode(two, guid: "two", lastPlayed: 2_000_000, position: 10_000, key: second))
        let local1 = try #require(try await fixture.store.localEpisodeForTesting(wire: one))
        let local2 = try #require(try await fixture.store.localEpisodeForTesting(wire: two))
        return (fixture, applier, local1, local2)
    }

    /// Force full synchronization from a snapshot holding exactly the library's base records, but those of the
    /// `excluding` entities (the server no longer holds them).
    static func repair(_ fixture: ServerLibraryFixture, excluding: Set<String> = []) async throws {
        let records = try ServerLibraryFixture.read(fixture.url, "SELECT entity, id, field_group, CAST(value AS TEXT) FROM ntp_records")
            .filter { !excluding.contains($0[1] ?? "") }
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
        _ = try await fixture.store.publishFullReprojection(build, head: head, now: 3_000_000, crash: nil)
    }

    /// This phone's clock is behind the server's (its save says 1,000 s; the server saw 2,000 s). The listening is
    /// session facts, which an ordinary unit and a repair show through their overlays: the position under this phone's
    /// claim stays 321,000 whatever the clocks say, and the played time follows the server's rule (PROTOCOL §8.8), this
    /// phone's 311,000 on top of what the other device added (the record's 30,000). The server's later last-played time
    /// shows, as its fold will show it.
    @Test func listeningNoFactCarriesIsKeptWhateverTheClockSays() async throws {
        let (fixture, applier, one, two) = try await Self.library()
        let store = fixture.store
        let session = try await store.beginPlayback(episodeID: two)
        try await store.recordPlaybackIntent(sessionID: session.id, positionMilliseconds: 10_000, durationMilliseconds: 600_000,
                                             baseline: UUID(), intentional: true, now: Date(timeIntervalSince1970: 1_000))
        _ = try await store.recordPlayback(sessionID: session.id, sample: PlaybackSample(positionMilliseconds: 321_000,
            durationMilliseconds: 600_000, status: .paused), now: Date(timeIntervalSince1970: 1_000))
        _ = try await store.beginPlayback(episodeID: one) // the player moves on: nothing holds `two` any more
        let listened = try #require(try await store.episode(id: two)).userState
        #expect(listened.positionMilliseconds == 321_000 && listened.playedDurationMilliseconds == 321_000)
        #expect(try fixture.rows("SELECT type FROM ntp_outbox WHERE type LIKE 'session.%' ORDER BY install_seq") == [["session.start"], ["session.checkpoint"]],
                "the load exported the closed session's save")
        // Another device's listening arrives in an ordinary unit.
        try await applier.apply([
            ServerRecord(entity: "episode", id: Self.two, fieldGroup: "position", value: ["generation_id": .string(Self.generation), "position": 20_000]),
            ServerRecord(entity: "episode", id: Self.two, fieldGroup: "played_time", value: ["generation_id": .string(Self.generation), "played_ms": 30_000]),
            ServerRecord(entity: "episode", id: Self.two, fieldGroup: "last_played", value: ["generation_id": .string(Self.generation), "time": 2_500_000])])
        var kept = try #require(try await store.episode(id: two)).userState
        #expect(kept.positionMilliseconds == 321_000 && kept.playedDurationMilliseconds == 341_000, "an ordinary unit keeps it")
        #expect(kept.lastPlayedTimeMilliseconds == 2_500_000 && kept.lastPlayedHistoryMilliseconds == listened.lastPlayedHistoryMilliseconds)
        try await Self.repair(fixture)
        kept = try #require(try await store.episode(id: two)).userState
        #expect(kept.positionMilliseconds == 321_000 && kept.playedDurationMilliseconds == 341_000, "a repair keeps it")
        #expect(kept.lastPlayedTimeMilliseconds == 2_500_000)
        await fixture.close()
    }

    /// An episode finished here (played, position 0, out of the queue) stays finished through a repair, even though the
    /// server still has it queued and unplayed; an episode this device never played is repaired.
    @Test func aCompletionHereStaysThroughARepair() async throws {
        let (fixture, _, one, two) = try await Self.library()
        let store = fixture.store
        #expect(try await store.queue().map(\.id).sorted() == [one, two].sorted())
        let session = try await store.beginPlayback(episodeID: one)
        _ = try await store.recordPlayback(sessionID: session.id, sample: PlaybackSample(positionMilliseconds: 599_000,
            durationMilliseconds: 600_000, status: .playing))
        _ = try await store.endPlayback(sessionID: session.id, reason: .ended, continueQueue: false)
        try await store.projectForTesting(two) { $0.userState.isFavorite = true } // a wrong row, nothing marks it
        try await Self.repair(fixture)
        let finished = try #require(try await store.episode(id: one)).userState
        #expect(finished.playState == .played && finished.positionMilliseconds == 0, "\(finished)")
        #expect(try await store.queue().map(\.id) == [two], "it stays out of the queue")
        #expect(try await store.episode(id: two)?.userState.isFavorite == false, "the unmarked episode is repaired")
        await fixture.close()
    }

    // MARK: - Owed debt: a repair respects it as it respects pending facts

    static let three = "e1:" + String(repeating: "e", count: 64)

    /// The library of `library()` and a third episode the server never queued, which a play load whose recording
    /// failed added to the queue here: the add is owed.
    static func owedAdd() async throws -> (fixture: ServerLibraryFixture, one: Int64, three: Int64) {
        let (fixture, applier, one, _) = try await library()
        try await applier.apply(episode(three, guid: "three", lastPlayed: 0, position: 0, key: try QueueKey.between(nil, nil, positionWriteID: UUID()))
            .filter { !$0.fieldGroup.hasPrefix("queue_") })
        let local = try #require(try await fixture.store.localEpisodeForTesting(wire: three))
        await fixture.store.injectRecorderFailure(after: 1)
        _ = try await fixture.store.beginPlayback(episodeID: local)
        await fixture.store.injectRecorderFailure(after: nil)
        #expect(try await fixture.store.queue().map(\.id).contains(local), "the play load queued it")
        #expect(try await fixture.store.owedCountForTesting() > 0, "its add is owed")
        return (fixture, one, local)
    }

    /// The snapshot never queued the episode, but this device owes its queue add: the repair keeps it queued.
    @Test func aRepairKeepsAnOwedAddQueued() async throws {
        let (fixture, one, three) = try await Self.owedAdd()
        _ = try await fixture.store.beginPlayback(episodeID: one) // the player moves on
        try await Self.repair(fixture)
        #expect(try await fixture.store.queue().map(\.id).contains(three), "the owed add stays queued")
        #expect(try fixture.queueOrderMatchesKeys())
        await fixture.close()
    }

    /// The snapshot no longer holds the episode, but this device owes a fact about it: the repair keeps it until the
    /// debt is settled, as it keeps one a pending fact names.
    @Test func aRepairKeepsAnEpisodeThisDeviceOwesAFactAbout() async throws {
        let (fixture, one, three) = try await Self.owedAdd()
        _ = try await fixture.store.beginPlayback(episodeID: one) // nothing holds it for the player
        #expect(try await fixture.store.owedCountForTesting() > 0)
        try await Self.repair(fixture, excluding: [Self.three])
        #expect(try await fixture.store.episode(id: three) != nil, "kept while the add is owed")
        #expect(try await fixture.store.queue().map(\.id).contains(three))
        _ = try await fixture.store.releaseServerPins()
        #expect(try await fixture.store.episode(id: three) != nil, "still owed: still kept")
        await fixture.close()
    }
}
