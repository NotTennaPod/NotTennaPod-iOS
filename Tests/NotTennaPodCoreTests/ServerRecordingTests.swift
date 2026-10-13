import Foundation
import Testing
@testable import NotTennaPodCore

/// The recorder (PROTOCOL §15.2): every store mutation in a server library emits exactly its facts
/// and overlays; a standalone library records nothing.
struct ServerRecordingTests {
    @Test func standaloneLibraryHasEmptyServerTablesAndRecordsNothing() async throws {
        let fixture = try await ServerLibraryFixture(server: false)
        defer { Task { await fixture.close() } }
        let store = fixture.store
        #expect(try fixture.rows("PRAGMA user_version") == [["20"]])
        #expect(await store.isServerLibrary == false)
        let feed = try await store.insert(ServerLibraryFixture.fetched())
        let ids = feed.episodes.map(\.id)
        try await store.markEpisodePlayed(episodeID: ids[0], played: true)
        _ = try await store.enqueue([ids[1], ids[2]])
        try await store.setFavorite(episodeID: ids[1], favorite: true)
        _ = try await store.removeFromQueue([ids[1]])
        try await store.updatePreferences(feedID: feed.id) { $0.keepUpdated = false; $0.subscriptionState = .archived }
        _ = try await store.clearPlaybackHistory()
        try await store.resetPlayedDurationStatistics()
        _ = try await store.requestFeedDeletion(feedID: feed.id)
        for (table, rows) in try fixture.serverTables() { #expect(rows.isEmpty, "\(table)") }
    }

    @Test func subscriptionRecordsTheRegistrationAndItsDraftsMaterializeAtResolution() async throws {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let store = fixture.store
        let feed = try await store.insert(ServerLibraryFixture.fetched())
        var facts = try fixture.outbox()
        #expect(facts.map(\.type) == ["podcast.subscribe"])
        #expect(facts[0].payload == ["feed_url": "https://example.test/feed.xml"])
        #expect(facts[0].targets.isEmpty)
        #expect(facts[0].json["author_id"]?.stringValue == fixture.identity.installID)
        #expect(facts[0].json["author_seq"] == 1)
        #expect(facts[0].json["previous_op_id"] == nil)
        let op = facts[0].opID
        // Facts about the pending podcast's episodes are drafts on the registration's own author.
        let episode = try #require(feed.episodes.first { $0.details.identifier == "guid-2" })
        try await store.markEpisodePlayed(episodeID: episode.id, played: true)
        #expect(try fixture.outboxCount() == 1)
        let drafts = try fixture.drafts()
        #expect(drafts.map(\.type) == ["episode.mark_played"])
        #expect(drafts[0].registration == op)
        #expect(drafts[0].author != fixture.identity.installID)

        let ids = try fixture.created(op)
        try await store.resolveRegistration(opID: op, .init(podcastID: ids.podcast, generationID: ids.generation, mode: "created", decisionID: nil))
        #expect(try fixture.drafts().isEmpty)
        facts = try fixture.outbox()
        #expect(facts.map(\.type) == ["podcast.subscribe", "episode.mark_played"])
        let mark = facts[1]
        let expected = try ContractIdentity.episodeID(namespace: fixture.identity.namespace, podcastID: ids.podcast, kind: .rssGUID, value: "guid-2")
        #expect(mark.payload["episode"]?["episode_id"]?.stringValue == expected)
        #expect(mark.payload["episode"]?["podcast_id"]?.stringValue == ids.podcast)
        #expect(mark.payload["episode"]?["generation_id"]?.stringValue == ids.generation)
        #expect(mark.payload["reset_position"] == true)
        #expect(mark.json["author_id"]?.stringValue == drafts[0].author)
        #expect(mark.dependencies.contains(op))
        #expect(mark.targets == [["entity": "episode", "id": .string(expected), "generation": .string(ids.generation)]])
        #expect(Set(try fixture.overlays(opID: mark.opID).map { $0[1] }) == [expected])
        #expect(facts.map(\.installSeq) == [1, 2])

        // After resolution the main author records directly.
        try await store.setFavorite(episodeID: episode.id, favorite: true)
        let favorite = try #require(try fixture.outbox().last)
        #expect(favorite.type == "favorite.set")
        #expect(favorite.json["author_id"]?.stringValue == fixture.identity.installID)
        #expect(favorite.json["previous_op_id"]?.stringValue == op)
        #expect(favorite.payload["on"] == true)
    }
}
