import Foundation
import Testing
@testable import NotTennaPodCore

/// Records to rows (PROTOCOL §6.8) with commits made here, without a server: device-only queue runs,
/// working media URLs, placeholders, secrets before a unit, and the queue safeguard.
@Suite struct ServerProjectionUnitTests {
    /// A server library with a cursor, applying commits written by the test.
    final class Applier: @unchecked Sendable {
        let fixture: ServerLibraryFixture
        let log = ContractIdentity.randomUUID()
        var seq: Int64 = 0

        init(_ fixture: ServerLibraryFixture) async throws {
            self.fixture = fixture
            try await fixture.store.setCursorForTesting(try SyncCursor(logID: log, epoch: 1, seq: 0, digest: String(repeating: "0", count: 64)))
        }

        @discardableResult
        func apply(_ records: [ServerRecord]) async throws -> ServerUnitResult {
            let next = seq + 1
            let cursor = try SyncCursor(logID: log, epoch: 1, seq: next, digest: ContractIdentity.sha256Hex(Array("\(log)\(next)".utf8)))
            let result = try await fixture.store.applyServerUnit(
                ServerUnitInput(commit: ServerCommit(epoch: 1, seq: next, records: records), cursor: cursor, watermark: nil,
                                now: 1_760_000_000_000), history: nil, maxWork: nil)
            seq = next
            return result
        }
    }

    static func membership(_ episode: String, _ generation: String, _ inQueue: Bool) -> ServerRecord {
        ServerRecord(entity: "episode", id: episode, fieldGroup: "queue_membership",
                     value: ["generation_id": .string(generation), "in_queue": .bool(inQueue)])
    }

    static func position(_ episode: String, _ generation: String, _ key: QueueKey) -> ServerRecord {
        ServerRecord(entity: "episode", id: episode, fieldGroup: "queue_position",
                     value: ["generation_id": .string(generation), "key": .string(key.wire), "position_id": .string(ContractIdentity.randomUUID())])
    }

    /// A registered podcast with its pending facts retired (as if the server had acknowledged them).
    static func registered(_ fixture: ServerLibraryFixture) async throws -> (feed: LibraryFeed, podcast: String, generation: String, wire: [String]) {
        let registered = try await fixture.subscribeRegistered()
        var wire: [String] = []
        for episode in registered.feed.episodes.sorted(by: { $0.id < $1.id }) {
            wire.append(try fixture.expectedEpisodeID(podcast: registered.podcast, guid: episode.details.identifier ?? ""))
        }
        return (registered.feed, registered.podcast, registered.generation, wire)
    }

    @Test func deviceOnlyRunsKeepTheirPlaceByTheirAnchors() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let (feed, _, generation, wire) = try await Self.registered(fixture)
        let ids = feed.episodes.map(\.id).sorted()
        let context = try await store.registerLocalFolder(title: "Folder", directoryIdentity: "folder-1", bookmark: Data([1]))
        let scan = ParsedFeed(format: .rss, title: "Folder", episodes: [
            ParsedEpisode(identifier: "a.mp3", title: "A", publicationDate: ServerLibraryFixture.now, media: ParsedMedia(url: "a.mp3", size: 10))])
        _ = try await store.applyLocalFolderScan(scan, context: context)
        let local = try #require(try await store.feed(id: context.feed.id)?.episodes.first?.id)
        _ = try await store.enqueue([ids[0], local, ids[1]])
        try await store.retireEverythingForTesting()
        let keys = try fixture.queueKeys()
        let applier = try await Applier(fixture)
        // The server orders the two synced members the other way: the device-only entry stays before its next anchor.
        try await applier.apply([Self.position(wire[0], generation, keys[2].key), Self.position(wire[1], generation, keys[0].key),
                                 Self.membership(wire[0], generation, true), Self.membership(wire[1], generation, true)])
        #expect(try await store.queue().map(\.id) == [local, ids[1], ids[0]])
        #expect(try fixture.queueOrderMatchesKeys())
        // The next anchor leaves the queue: the device-only entry follows its previous anchor.
        try await applier.apply([Self.membership(wire[1], generation, false)])
        #expect(try await store.queue().map(\.id) == [ids[0], local])
        #expect(try fixture.queueOrderMatchesKeys())
        await fixture.close()
    }

    @Test func aWorkingMediaURLIsNeverReplaced() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let (feed, podcast, _, wire) = try await Self.registered(fixture)
        let ids = feed.episodes.map(\.id).sorted()
        try await store.projectForTesting(ids[0]) { $0.userState.isDownloaded = true; $0.userState.localFileURL = "/tmp/a.mp3" }
        _ = try await store.beginPlayback(episodeID: ids[1])
        try await store.retireEverythingForTesting()
        let applier = try await Applier(fixture)
        func identity(_ episode: String, guid: String) -> ServerRecord {
            ServerRecord(entity: "episode", id: episode, fieldGroup: "identity", value: [
                "podcast_id": .string(podcast), "occurrence": ["k": "rss-guid", "v": .string(guid), "guid": .string(guid)]])
        }
        func metadata(_ episode: String, title: String) -> ServerRecord {
            ServerRecord(entity: "episode", id: episode, fieldGroup: "metadata", value: [
                "title": .string(title), "description": .null, "link": .null, "pub_date": 1_760_000_000_000, "image_url": .null,
                "payment_link": .null, "media": ["url": "https://moved.example/new.mp3", "size": "2000", "mime_type": "audio/mpeg", "duration": 0],
                "chapters": .null, "chapter_url": .null, "transcript_url": .null, "transcript_type": .null, "social_interact_url": .null,
                "revision": .string(ContractIdentity.randomUUID()), "fetch_time": 1_760_000_000_000])
        }
        let guids = feed.episodes.sorted { $0.id < $1.id }.map { $0.details.identifier ?? "" }
        try await applier.apply((0..<3).flatMap { [identity(wire[$0], guid: guids[$0])] }
                                + [metadata(wire[0], title: "Downloaded"), metadata(wire[1], title: "Playing"), metadata(wire[2], title: "Other")])
        let downloaded = try #require(try await store.episode(id: ids[0])), playing = try #require(try await store.episode(id: ids[1]))
        let other = try #require(try await store.episode(id: ids[2]))
        #expect(downloaded.details.title == "Downloaded" && playing.details.title == "Playing" && other.details.title == "Other")
        #expect(downloaded.details.media?.url != "https://moved.example/new.mp3", "downloaded: kept")
        #expect(playing.details.media?.url != "https://moved.example/new.mp3", "loaded in the player: kept")
        #expect(other.details.media?.url == "https://moved.example/new.mp3", "otherwise the canonical URL")
        await fixture.close()
    }

    @Test func anEpisodeWithStateButNoMetadataIsAPlaceholderUntilItsMetadataArrives() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let (feed, podcast, generation, _) = try await Self.registered(fixture)
        try await store.retireEverythingForTesting()
        let applier = try await Applier(fixture)
        let episode = try fixture.expectedEpisodeID(podcast: podcast, guid: "remote-1")
        try await applier.apply([
            ServerRecord(entity: "episode", id: episode, fieldGroup: "identity", value: [
                "podcast_id": .string(podcast), "occurrence": ["k": "rss-guid", "v": "remote-1", "guid": "remote-1", "title": "Remote one",
                                                               "enclosure_url": "https://media.example.test/remote-1.mp3"]]),
            ServerRecord(entity: "episode", id: episode, fieldGroup: "favorite", value: ["generation_id": .string(generation), "on": true])])
        let placeholder = try #require(try await store.feed(id: feed.id)?.episodes.first { $0.details.identifier == "remote-1" })
        #expect(placeholder.details.title == "Remote one" && placeholder.userState.isFavorite)
        #expect(placeholder.details.media?.url == "https://media.example.test/remote-1.mp3")
        #expect(placeholder.details.publicationDate == Date(timeIntervalSince1970: 1_760_000_000), "the commit's time without a date")
        await fixture.close()
    }

    @Test func aUnitNeedingAnUnfetchedSecretAppliesNothing() async throws {
        let fixture = try await ServerLibraryFixture()
        let (_, podcast, _, _) = try await Self.registered(fixture)
        try await fixture.store.retireEverythingForTesting()
        let applier = try await Applier(fixture)
        let secret = ContractIdentity.randomUUID()
        await #expect(throws: ServerApplyError.missingSecrets([secret])) {
            try await applier.apply([ServerRecord(entity: "podcast", id: podcast, fieldGroup: "credentials", value: ["secret_id": .string(secret)])])
        }
        #expect(try fixture.rows("SELECT seq FROM ntp_library") == [["0"]], "the cursor did not move")
        #expect(try fixture.rows("SELECT count(*) FROM ntp_records WHERE field_group = 'credentials'") == [["0"]])
        await fixture.close()
    }

    @Test func aCommitRemovingMostOfTheQueueKeepsASafeguardCopy() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let (feed, _, generation, wire) = try await Self.registered(fixture)
        _ = try await store.enqueue(feed.episodes.map(\.id).sorted())
        try await store.retireEverythingForTesting()
        let applier = try await Applier(fixture)
        let result = try await applier.apply(wire.map { Self.membership($0, generation, false) })
        #expect(try await store.queue().isEmpty)
        let copy = try #require(result.queueSafeguard)
        #expect(copy["episodes"]?.arrayValue?.count == 4)
        await fixture.close()
    }
}

extension ServerProjectionUnitTests {
    @Test func aRemoteRemovalDeletesThePodcastWithItsFilesLater() async throws {
        let fixture = try await ServerLibraryFixture()
        let (feed, podcast, generation, _) = try await Self.registered(fixture)
        try await fixture.store.retireEverythingForTesting()
        let applier = try await Applier(fixture)
        let result = try await applier.apply([ServerRecord(entity: "podcast", id: podcast, fieldGroup: "subscription",
                                                           value: ["state": "removed", "generation_id": .string(generation)])])
        #expect(result.deletedFeeds == [feed.id])
        #expect(try await fixture.store.feed(id: feed.id) == nil)
        #expect(try await fixture.store.pendingEffects().contains { if case .deleteFeed = $0.effect.kind { true } else { false } },
                "the files go through the existing two-phase feed deletion")
        #expect(try fixture.rows("SELECT live_generation FROM ntp_podcasts WHERE podcast_id = '\(podcast)'") == [[nil]])
        await fixture.close()
    }

    @Test func aPreviewRegisteredElsewhereBecomesALocalPreviewAndAMergedPodcastWaits() async throws {
        let fixture = try await ServerLibraryFixture()
        let applier = try await Applier(fixture)
        let preview = "p1:" + String(repeating: "a", count: 64), merged = "p1:" + String(repeating: "b", count: 64)
        let generation = "g1:" + String(repeating: "c", count: 64)
        try await applier.apply([
            ServerRecord(entity: "podcast", id: preview, fieldGroup: "identity", value: [
                "aliases": [["url": "https://example.test/preview.xml", "normalized": "https://example.test/preview.xml"]],
                "refresh_url": "https://example.test/preview.xml"]),
            ServerRecord(entity: "podcast", id: preview, fieldGroup: "subscription", value: ["state": "not_subscribed", "generation_id": .string(generation)]),
            ServerRecord(entity: "podcast", id: preview, fieldGroup: "policy", value: ["keep_updated": false, "new_episodes_action": "global"]),
            ServerRecord(entity: "podcast", id: merged, fieldGroup: "subscription", value: ["state": "merged", "merged_into": .string(preview)])])
        let feeds = try await fixture.store.feeds()
        #expect(feeds.count == 1)
        let local = try #require(feeds.first)
        #expect(local.subscriptionState == .notSubscribed && local.source == "https://example.test/preview.xml" && !local.keepUpdated)
        #expect(local.lastRefreshAttempt == Date(timeIntervalSince1970: 1_760_000_000), "kept as a local preview would be, from now")
        await fixture.close()
    }

    @Test func accountPolicyRecordsReachTheFacade() async throws {
        let fixture = try await ServerLibraryFixture()
        let applier = try await Applier(fixture)
        let account = fixture.identity.accountID
        let result = try await applier.apply([
            ServerRecord(entity: "account", id: account, fieldGroup: "discovery_policy", value: ["new_episodes_action": "queue"]),
            ServerRecord(entity: "account", id: account, fieldGroup: "queue_policy", value: ["enqueue_location": "front", "keep_sorted": true, "sort_order": "episode_title_a_z"])])
        #expect(result.accountPoliciesChanged)
        let policies = try #require(try await fixture.store.serverAccountPolicies())
        #expect(policies.newEpisodesAction == .queue && policies.enqueueLocation == .front && policies.keepSorted)
        await fixture.close()
    }
}

extension ServerProjectionUnitTests {
    /// A remote removal of the podcast that fills the queue keeps a safeguard copy with every
    /// member's title and key (taken before the rows went), in the same transaction as the removal.
    @Test func aSafeguardOfARemovedPodcastsQueueKeepsTitlesAndKeys() async throws {
        let fixture = try await ServerLibraryFixture()
        let (feed, podcast, generation, _) = try await Self.registered(fixture)
        _ = try await fixture.store.enqueue(feed.episodes.map(\.id).sorted())
        try await fixture.store.retireEverythingForTesting()
        let applier = try await Applier(fixture)
        let result = try await applier.apply([ServerRecord(entity: "podcast", id: podcast, fieldGroup: "subscription",
                                                           value: ["state": "removed", "generation_id": .string(generation)])])
        let members = try #require(result.queueSafeguard?["episodes"]?.arrayValue)
        #expect(members.count == 4)
        #expect(members.allSatisfy { $0["title"]?.stringValue != nil && $0["key"]?.stringValue != nil }, "\(members)")
        #expect(try fixture.rows("SELECT count(*) FROM ntp_pending_safeguards") == [["1"]], "kept with the unit itself")
        await fixture.close()
    }

    /// A repair finds an episode the server no longer holds while the player holds
    /// it, so it stays for now; once the player leaves it, it goes, and does not linger as an orphan.
    @Test func anObsoleteEpisodeTheRepairHadToKeepGoesWhenThePlayerLeavesIt() async throws {
        let (fixture, _, one, two) = try await ServerLocalPlaybackTests.library()
        let store = fixture.store
        _ = try await store.beginPlayback(episodeID: one)
        try await ServerLocalPlaybackTests.repair(fixture, excluding: [ServerLocalPlaybackTests.one])
        #expect(try await store.episode(id: one) != nil, "the player's episode stays while it is held")
        _ = try await store.beginPlayback(episodeID: two)
        _ = try await store.releaseServerPins()
        #expect(try await store.episode(id: one) == nil, "gone once the player left it")
        #expect(try await store.pendingEffects().contains { if case .removeEpisodes = $0.effect.kind { true } else { false } },
                "its files go through the two-phase cleanup")
        try await ServerLocalPlaybackTests.repair(fixture)
        #expect(try await store.episode(id: two) != nil)
        await fixture.close()
    }

    /// The server holds the episode again before the hold retires: it stays.
    @Test func aDeferredAbsenceTheServerUndoesKeepsTheEpisode() async throws {
        let (fixture, applier, one, two) = try await ServerLocalPlaybackTests.library()
        let store = fixture.store
        _ = try await store.beginPlayback(episodeID: one)
        let identity = try #require(try ServerLibraryFixture.read(fixture.url, "SELECT CAST(value AS TEXT) FROM ntp_records WHERE id = '\(ServerLocalPlaybackTests.one)' AND field_group = 'identity'").first?.first ?? nil)
        try await ServerLocalPlaybackTests.repair(fixture, excluding: [ServerLocalPlaybackTests.one])
        try await applier.apply([ServerRecord(entity: "episode", id: ServerLocalPlaybackTests.one, fieldGroup: "identity",
                                              value: try ContractJSON.decode(Array(identity.utf8)))])
        _ = try await store.beginPlayback(episodeID: two)
        _ = try await store.releaseServerPins()
        #expect(try await store.episode(id: one) != nil)
        await fixture.close()
    }
}

extension FeedLibraryStore {
    func setCursorForTesting(_ cursor: SyncCursor) throws {
        try database.transaction { try setCursor(cursor, watermark: nil) }
    }

    /// As if the server had acknowledged and the library applied every pending fact: the outbox and overlays go.
    func retireEverythingForTesting() throws {
        try database.transaction {
            try database.execute("DELETE FROM ntp_overlays")
            try database.execute("DELETE FROM ntp_outbox")
        }
    }
}
