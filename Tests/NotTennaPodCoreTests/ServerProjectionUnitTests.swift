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

    /// A closed generation's queue: the server opens the podcast's next generation and tombstones the old generation's
    /// queue membership and position records. The incremental projection drops those entries, as a full projection of the
    /// same records does; every device shows the same queue.
    @Test func closedGenerationDropsQueue() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let (feed, podcast, generation, wire) = try await Self.registered(fixture)
        let episodes = feed.episodes.sorted { $0.id < $1.id }
        _ = try await store.enqueue(episodes.map(\.id))
        try await store.retireEverythingForTesting()
        let keys = try fixture.queueKeys()
        let applier = try await Applier(fixture)
        // The server's records of the podcast's episodes and their queue entries.
        var records: [ServerRecord] = []
        for (index, episode) in episodes.enumerated() {
            let guid = episode.details.identifier ?? ""
            records.append(ServerRecord(entity: "episode", id: wire[index], fieldGroup: "identity", value: ["podcast_id": .string(podcast),
                "occurrence": ["k": "rss-guid", "v": .string(guid), "guid": .string(guid)]]))
            records += [Self.position(wire[index], generation, keys[index].key), Self.membership(wire[index], generation, true)]
        }
        try await applier.apply(records)
        #expect(try await store.queue().count == episodes.count)
        // The next generation opens; the old generation's queue records are tombstoned.
        let next = try ContractIdentity.generationID(namespace: fixture.identity.namespace, podcastID: podcast, creatingOpID: ContractIdentity.randomUUID())
        var closing = [ServerRecord(entity: "podcast", id: podcast, fieldGroup: "subscription", value: ["state": "subscribed", "generation_id": .string(next)])]
        for id in wire {
            closing += [ServerRecord(entity: "episode", id: id, fieldGroup: "queue_membership", value: nil),
                        ServerRecord(entity: "episode", id: id, fieldGroup: "queue_position", value: nil)]
        }
        try await applier.apply(closing)
        #expect(try await store.queue().isEmpty, "the closed generation's entries leave the queue")
        // A full projection of the same records agrees.
        try await ServerLocalPlaybackTests.repair(fixture)
        #expect(try await store.queue().isEmpty, "a full projection shows the same queue")
        await fixture.close()
    }

    /// The closed generation's queue through a retained publication: the shadow of the next generation (the old queue
    /// records tombstoned) is built; before it is published the person queues a local-folder episode, so the switch
    /// re-projects the queue live. Only that episode stays, as a full projection shows it.
    @Test func closedGenerationQueueRebaseKeepsTombstones() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let (feed, podcast, generation, wire) = try await Self.registered(fixture)
        let episodes = feed.episodes.sorted { $0.id < $1.id }
        _ = try await store.enqueue(episodes.map(\.id))
        let context = try await store.registerLocalFolder(title: "Folder", directoryIdentity: "folder-1", bookmark: Data([1]))
        let scan = ParsedFeed(format: .rss, title: "Folder", episodes: [
            ParsedEpisode(identifier: "a.mp3", title: "A", publicationDate: ServerLibraryFixture.now, media: ParsedMedia(url: "a.mp3", size: 10))])
        _ = try await store.applyLocalFolderScan(scan, context: context)
        let local = try #require(try await store.feed(id: context.feed.id)?.episodes.first?.id)
        try await store.retireEverythingForTesting()
        let keys = try fixture.queueKeys()
        let applier = try await Applier(fixture)
        var records: [ServerRecord] = []
        for (index, episode) in episodes.enumerated() {
            let guid = episode.details.identifier ?? ""
            records.append(ServerRecord(entity: "episode", id: wire[index], fieldGroup: "identity", value: ["podcast_id": .string(podcast),
                "occurrence": ["k": "rss-guid", "v": .string(guid), "guid": .string(guid)]]))
            records += [Self.position(wire[index], generation, keys[index].key), Self.membership(wire[index], generation, true)]
        }
        try await applier.apply(records)
        #expect(try await store.queue().count == episodes.count)
        let next = try ContractIdentity.generationID(namespace: fixture.identity.namespace, podcastID: podcast, creatingOpID: ContractIdentity.randomUUID())
        var closing = [ServerRecord(entity: "podcast", id: podcast, fieldGroup: "subscription", value: ["state": "subscribed", "generation_id": .string(next)])]
        for id in wire {
            closing += [ServerRecord(entity: "episode", id: id, fieldGroup: "queue_membership", value: nil),
                        ServerRecord(entity: "episode", id: id, fieldGroup: "queue_position", value: nil)]
        }
        let input = try await ServerRetainedPublicationTests.nextInput(fixture, closing)
        let shadow = try await ServerRetainedPublicationTests.build(fixture, input)
        #expect(shadow.plan.queue?.isEmpty == true, "the shadow's own queue is empty")
        _ = try await store.enqueue([local])
        let result = try await store.publishServerShadow(shadow, input: input, history: nil, workLimit: 1_000)
        #expect(result.rebased > 0, "the queue was re-projected live")
        #expect(try await store.queue().map(\.id) == [local], "only the local episode stays")
        try await ServerLocalPlaybackTests.repair(fixture)
        #expect(try await store.queue().map(\.id) == [local], "a full projection shows the same queue")
        await fixture.close()
    }

    /// The closed generation's queue through a retained publication's retry: the first publication of the shadow is
    /// deferred (over its budget) after the person queued a local-folder episode; the retry re-projects the queue live and
    /// keeps only that episode, as a full projection does.
    @Test func closedGenerationQueueRetainedRetryKeepsTombstones() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let (feed, podcast, generation, wire) = try await Self.registered(fixture)
        let episodes = feed.episodes.sorted { $0.id < $1.id }
        _ = try await store.enqueue(episodes.map(\.id))
        let context = try await store.registerLocalFolder(title: "Folder", directoryIdentity: "folder-1", bookmark: Data([1]))
        let scan = ParsedFeed(format: .rss, title: "Folder", episodes: [
            ParsedEpisode(identifier: "a.mp3", title: "A", publicationDate: ServerLibraryFixture.now, media: ParsedMedia(url: "a.mp3", size: 10))])
        _ = try await store.applyLocalFolderScan(scan, context: context)
        let local = try #require(try await store.feed(id: context.feed.id)?.episodes.first?.id)
        try await store.retireEverythingForTesting()
        let keys = try fixture.queueKeys()
        let applier = try await Applier(fixture)
        var records: [ServerRecord] = []
        for (index, episode) in episodes.enumerated() {
            let guid = episode.details.identifier ?? ""
            records.append(ServerRecord(entity: "episode", id: wire[index], fieldGroup: "identity", value: ["podcast_id": .string(podcast),
                "occurrence": ["k": "rss-guid", "v": .string(guid), "guid": .string(guid)]]))
            records += [Self.position(wire[index], generation, keys[index].key), Self.membership(wire[index], generation, true)]
        }
        try await applier.apply(records)
        let next = try ContractIdentity.generationID(namespace: fixture.identity.namespace, podcastID: podcast, creatingOpID: ContractIdentity.randomUUID())
        var closing = [ServerRecord(entity: "podcast", id: podcast, fieldGroup: "subscription", value: ["state": "subscribed", "generation_id": .string(next)])]
        for id in wire {
            closing += [ServerRecord(entity: "episode", id: id, fieldGroup: "queue_membership", value: nil),
                        ServerRecord(entity: "episode", id: id, fieldGroup: "queue_position", value: nil)]
        }
        let input = try await ServerRetainedPublicationTests.nextInput(fixture, closing)
        let shadow = try await ServerRetainedPublicationTests.build(fixture, input)
        _ = try await store.enqueue([local])
        await #expect(throws: (any Error).self, "over its budget: deferred") {
            _ = try await store.publishServerShadow(shadow, input: input, history: nil, workLimit: 1)
        }
        #expect(try await store.queue().count == episodes.count + 1, "nothing published yet")
        let result = try await store.publishServerShadow(shadow, input: input, history: nil, workLimit: 1_000)
        #expect(result.rebased > 0, "the retry re-projected the queue live")
        #expect(try await store.queue().map(\.id) == [local], "only the local episode stays")
        try await ServerLocalPlaybackTests.repair(fixture)
        #expect(try await store.queue().map(\.id) == [local], "a full projection shows the same queue")
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
    /// The server removes a podcast while the player holds one of its episodes, then the person subscribes to it again
    /// elsewhere: the held row is cut loose from the account at the removal (no mapping names it or its feed, which is
    /// detached and hidden), so the reopened subscription shows at once in a feed of its own; once the player leaves the
    /// episode and the pins are released only the detached feed goes, never the reopened subscription.
    @Test func resubscribeWhileOldEpisodeIsHeld() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let (feed, podcast, generation, _) = try await Self.registered(fixture)
        let held = try #require(feed.episodes.map(\.id).sorted().first)
        try await store.retireEverythingForTesting()
        let applier = try await Applier(fixture)
        _ = try await store.beginPlayback(episodeID: held)
        try await applier.apply([ServerRecord(entity: "podcast", id: podcast, fieldGroup: "subscription",
                                              value: ["state": "removed", "generation_id": .string(generation)])])
        #expect(try await store.feed(id: feed.id) == nil, "removed from every list while the player holds its episode")
        #expect(try await store.episode(id: held) != nil, "the held episode stays for the player")
        #expect(try fixture.rows("SELECT count(*) FROM ntp_episodes WHERE local_id = \(held)") == [["0"]], "no mapping names the held row")
        #expect(try fixture.rows("SELECT count(*) FROM ntp_podcasts WHERE feed_id = \(feed.id) OR pinned_removal = 1") == [["0"]], "nor its feed")
        let next = try ContractIdentity.generationID(namespace: fixture.identity.namespace, podcastID: podcast, creatingOpID: ContractIdentity.randomUUID())
        try await applier.apply([ServerRecord(entity: "podcast", id: podcast, fieldGroup: "subscription",
                                              value: ["state": "subscribed", "generation_id": .string(next)])])
        let reopened = try #require(try fixture.rows("SELECT feed_id FROM ntp_podcasts WHERE podcast_id = '\(podcast)'").first?.first?.flatMap { Int64($0) })
        #expect(reopened != feed.id, "the reopened subscription has a feed of its own")
        #expect(try await store.feed(id: reopened)?.subscriptionState == .subscribed, "shown at once while the episode is held")
        #expect(try await store.feeds().map(\.id) == [reopened])
        #expect(try fixture.rows("SELECT live_generation, pinned_removal FROM ntp_podcasts WHERE podcast_id = '\(podcast)'") == [[next, "0"]])
        #expect(try fixture.rows("SELECT feed_id FROM pinned_feed_removals") == [["\(feed.id)"]], "the held row's feed is detached")
        #expect(try await store.episode(id: held) != nil, "the held row stays")
        #expect(try await store.feed(id: feed.id) == nil, "hidden")
        // The player leaves the episode; the release deletes only the retained feed.
        try await store.resetPlaybackPosition(episodeID: held)
        _ = try await store.releaseServerPins()
        #expect(try await store.feed(id: reopened)?.subscriptionState == .subscribed, "still subscribed after the player left")
        #expect(try await store.episode(id: held) == nil, "the closed generation's row is gone")
        #expect(try fixture.rows("SELECT count(*) FROM pinned_feed_removals") == [["0"]])
        await fixture.close()
    }

    /// A library an earlier version left with a pinned removal still linked to its podcast (`ntp_podcasts.pinned_removal`,
    /// the held row still mapped) while the player holds the episode: the next release of the pins detaches it as a
    /// removal does now, so the podcast subscribed again gets a feed of its own and the held row stays for the player.
    @Test func anEarlierPinnedRemovalIsDetachedWhileHeld() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let (feed, podcast, generation, wire) = try await Self.registered(fixture)
        let held = try #require(feed.episodes.map(\.id).sorted().first)
        try await store.retireEverythingForTesting()
        let applier = try await Applier(fixture)
        _ = try await store.beginPlayback(episodeID: held)
        try await applier.apply([ServerRecord(entity: "podcast", id: podcast, fieldGroup: "subscription",
                                              value: ["state": "removed", "generation_id": .string(generation)])])
        // The earlier version's state: the podcast pinned to the held feed, the held row still mapped.
        try await store.withDatabaseForTesting { database in
            try database.transaction {
                try database.execute("DELETE FROM pinned_feed_removals")
                try database.execute("UPDATE ntp_podcasts SET feed_id = ?, live_generation = NULL, pinned_removal = 1 WHERE podcast_id = ?", [.integer(feed.id), .text(podcast)])
                try database.execute("UPDATE ntp_episodes SET local_id = ? WHERE episode_id = ?", [.integer(held), .text(wire[0])])
            }
        }
        #expect(try await store.feed(id: feed.id) == nil)
        _ = try await store.releaseServerPins()
        #expect(try fixture.rows("SELECT count(*) FROM ntp_episodes WHERE local_id = \(held)") == [["0"]], "no mapping names the held row")
        #expect(try fixture.rows("SELECT count(*) FROM ntp_podcasts WHERE feed_id = \(feed.id) OR pinned_removal = 1") == [["0"]], "nor its feed")
        #expect(try fixture.rows("SELECT feed_id FROM pinned_feed_removals") == [["\(feed.id)"]], "detached")
        #expect(try await store.episode(id: held) != nil, "held for the player")
        #expect(try await store.feed(id: feed.id) == nil, "in no list")
        let next = try ContractIdentity.generationID(namespace: fixture.identity.namespace, podcastID: podcast, creatingOpID: ContractIdentity.randomUUID())
        try await applier.apply([ServerRecord(entity: "podcast", id: podcast, fieldGroup: "subscription",
                                              value: ["state": "subscribed", "generation_id": .string(next)])])
        let reopened = try #require(try await store.feeds().first)
        #expect(reopened.id != feed.id && reopened.subscriptionState == .subscribed, "the podcast subscribed again shows, a feed of its own")
        try await store.resetPlaybackPosition(episodeID: held)
        _ = try await store.releaseServerPins()
        #expect(try await store.episode(id: held) == nil)
        #expect(try await store.feeds().map(\.id) == [reopened.id])
        await fixture.close()
    }

    /// After a server restore, an earlier resolution can join the podcast's live generation into another (the same podcast,
    /// a new effective generation ID, nothing closed). The player's episode is not cut loose: the podcast keeps its rows,
    /// the held session keeps its sync identity, and listening on after the join is recorded on top of the earlier.
    @Test func joiningALiveGenerationKeepsTheHeldSession() async throws {
        let fixture = try await ServerLibraryFixture()
        let store = fixture.store
        let (feed, podcast, _, _) = try await Self.registered(fixture)
        let held = try #require(feed.episodes.map(\.id).sorted().first)
        let player = StorePlayer(store)
        try await player.load(held); try await player.play(); try await player.listen(31); try await player.pause()
        try await store.retireEverythingForTesting()
        let applier = try await Applier(fixture)
        let joined = try ContractIdentity.generationID(namespace: fixture.identity.namespace, podcastID: podcast, creatingOpID: ContractIdentity.randomUUID())
        try await applier.apply([ServerRecord(entity: "podcast", id: podcast, fieldGroup: "subscription",
                                              value: ["state": "subscribed", "generation_id": .string(joined)])])
        #expect(try await store.feeds().map(\.id) == [feed.id], "the podcast keeps its rows")
        #expect(try fixture.rows("SELECT count(*) FROM ntp_episodes WHERE local_id = \(held)") == [["1"]], "the held episode keeps its mapping")
        #expect(try fixture.rows("SELECT count(*) FROM pinned_feed_removals") == [["0"]], "nothing is detached")
        #expect(try fixture.rows("SELECT count(*) FROM ntp_sessions WHERE episode_id = \(held)") != [["0"]], "the held session stays")
        try await player.play(); try await player.listen(5); try await player.pause()
        let contributions = try fixture.outbox().filter { $0.type.hasPrefix("session.") }.compactMap { $0.payload["contribution"]?.integerValue }
        #expect(contributions.max() == 36_000, "the listening after the join is recorded: \(contributions)")
        await fixture.close()
    }

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

/// The server's `refresh_status` of a podcast on this device (PROTOCOL §9.4): kept apart from this device's own
/// refresh outcome, so neither erases the other, and shown whatever the published or creation times.
extension ServerProjectionUnitTests {
    static func refreshStatus(_ podcast: String, attempt: Int64, error: ContractJSON? = nil) -> ServerRecord {
        ServerRecord(entity: "podcast", id: podcast, fieldGroup: "refresh_status",
                     value: ["last_attempt": .integer(attempt), "last_success": .null, "error": error ?? .null, "next_attempt": .null])
    }

    static let words = ["ntp_refresh_by_server": "The server: %1$@", "ntp_refresh_by_device": "This device: %1$@",
                        "gpodnetsync_pref_report_successful": "Successful", "gpodnetsync_pref_report_failed": "Failed"]
    static func text(_ key: String) -> String { words[key] ?? key }
    static func date(_ date: Date) -> String { String(Int64(date.timeIntervalSince1970)) }

    /// A podcast another device subscribed to, created here by a commit whose refresh status (older than the commit)
    /// says the server's refresh fails: the failure shows, though this device never refreshed it and its creation set
    /// the preview's aging time; the server recovering, it goes; failing again with an old published time, it shows again.
    @Test func aPodcastCreatedHereShowsTheServersFailureWhateverTheTimes() async throws {
        let fixture = try await ServerLibraryFixture()
        let applier = try await Applier(fixture)
        let podcast = "p1:" + String(repeating: "d", count: 64), generation = "g1:" + String(repeating: "e", count: 64)
        try await applier.apply([
            ServerRecord(entity: "podcast", id: podcast, fieldGroup: "identity", value: [
                "aliases": [["url": "https://example.test/failing.xml", "normalized": "https://example.test/failing.xml"]],
                "refresh_url": "https://example.test/failing.xml"]),
            ServerRecord(entity: "podcast", id: podcast, fieldGroup: "subscription", value: ["state": "subscribed", "generation_id": .string(generation)]),
            Self.refreshStatus(podcast, attempt: 1_750_000_000_000, error: ["label": "parser_exception"])])
        var feed = try #require(try await fixture.store.feeds().first)
        #expect(feed.lastRefreshAttempt == Date(timeIntervalSince1970: 1_760_000_000), "created here, after the server's attempt")
        #expect(!feed.lastUpdateFailed && feed.serverRefresh?.label == "parser_exception" && feed.refreshFailed)
        let details = try #require(FeedLogDetails.refreshFailure(latestLog: nil, feed: feed, text: Self.text, date: Self.date))
        #expect(details.statusKey == "download_error_parser_exception" && details.technical.isEmpty && details.fileURL == feed.source)
        #expect(details.origins == ["The server: Failed (1750000000)"], "no line for a refresh this device never made")
        // The server recovers: nothing failed any more.
        try await applier.apply([Self.refreshStatus(podcast, attempt: 1_760_000_100_000)])
        feed = try #require(try await fixture.store.feed(id: feed.id))
        #expect(!feed.refreshFailed && feed.serverRefresh?.failed == false)
        #expect(FeedLogDetails.refreshFailure(latestLog: nil, feed: feed, text: Self.text, date: Self.date) == nil)
        // Failing again, published with a time older than everything else here: it shows.
        try await applier.apply([Self.refreshStatus(podcast, attempt: 1_600_000_000_000, error: ["label": "http_status", "code": 500])])
        feed = try #require(try await fixture.store.feed(id: feed.id))
        #expect(feed.refreshFailed)
        let again = try #require(FeedLogDetails.refreshFailure(latestLog: nil, feed: feed, text: Self.text, date: Self.date))
        #expect(again.statusKey == "download_error_http_data_error" && again.technical == "500")
        // This device's own failure while the server's refresh works: both show, this device's first.
        try await applier.apply([Self.refreshStatus(podcast, attempt: 1_760_000_200_000)])
        try await fixture.store.recordFailure(.unauthorized, feedID: feed.id, date: Date(timeIntervalSince1970: 1_760_000_300))
        feed = try #require(try await fixture.store.feed(id: feed.id))
        #expect(feed.refreshFailed && feed.lastUpdateFailed && feed.serverRefresh?.failed == false)
        let log = try #require(try await fixture.store.logs(feedID: feed.id).first)
        let local = try #require(FeedLogDetails.refreshFailure(latestLog: log, feed: feed, text: Self.text, date: Self.date))
        #expect(local.statusKey == "download_error_unauthorized")
        #expect(local.origins == ["The server: Successful (1760000200)", "This device: Failed (1760000300)"])
        await fixture.close()
    }

    /// A healthy refresh on this device does not erase the server's failure: the icon stays, and the notice opens the
    /// server's details with when each side last refreshed. A status-only commit writes only the podcast's header.
    @Test func aHealthyRefreshHereKeepsTheServersFailure() async throws {
        let fixture = try await ServerLibraryFixture()
        let (feed, podcast, _, _) = try await Self.registered(fixture)
        try await fixture.store.retireEverythingForTesting()
        let applier = try await Applier(fixture)
        try await applier.apply([Self.refreshStatus(podcast, attempt: 1_758_000_000_000)])
        let generations = "SELECT feed_id, generation, episode_generation FROM feed_changes ORDER BY feed_id"
        let before = try fixture.rows(generations)
        try await applier.apply([Self.refreshStatus(podcast, attempt: 1_759_000_000_000,
                                                    error: ["label": "forbidden", "code": 403, "detail": "Forbidden"])])
        let after = try fixture.rows(generations)
        #expect(before.map { [$0[0], $0[2]] } == after.map { [$0[0], $0[2]] }, "no episode row written")
        #expect(zip(before, after).filter { $0 != $1 }.map { $0.1[0] } == [String(feed.id)], "only the podcast's header changed")
        #expect(try await fixture.store.feed(id: feed.id)?.localRefreshAttempt == nil, "never refreshed here")
        struct Transport: FeedHTTPTransport {
            func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
                FeedHTTPResponse(url: request.url!, status: 200, body: ServerDiscoveryTests.rss(""))
            }
        }
        let service = FeedRefreshService(store: fixture.store, fetcher: FeedFetcher(transport: Transport()),
                                         clock: { Date(timeIntervalSince1970: 1_760_000_500) })
        guard case .updated = try await service.refresh(feedID: feed.id, force: true) else { Issue.record("not refreshed"); return }
        let refreshed = try #require(try await fixture.store.feed(id: feed.id))
        #expect(!refreshed.lastUpdateFailed && refreshed.serverRefresh?.label == "forbidden" && refreshed.refreshFailed)
        let log = try await fixture.store.logs(feedID: feed.id).first
        #expect(log?.kind.isSuccessful != false, "no failure of this device's")
        let details = try #require(FeedLogDetails.refreshFailure(latestLog: log, feed: refreshed, text: Self.text, date: Self.date))
        #expect(details.statusKey == "download_error_forbidden" && details.technical == "Forbidden")
        #expect(details.origins == ["The server: Failed (1759000000)", "This device: Successful (1760000500)"])
        #expect(details.clipboard.hasSuffix("ntp_refresh_last_title: \nThe server: Failed (1759000000)\nThis device: Successful (1760000500)"))
        await fixture.close()
    }

    /// The server's labels in Android's DownloadErrorLabel words, as the web shows them; the technical detail is the
    /// sanitized detail, else the HTTP status, never the label; a record without an error is a success.
    @Test func theServersStatusInAndroidsWords() throws {
        let table: [(String, String)] = [
            ("unauthorized", "download_error_unauthorized"), ("forbidden", "download_error_forbidden"), ("not_found", "download_error_not_found"),
            ("http_status", "download_error_http_data_error"), ("io", "download_error_io_error"), ("too_many_redirects", "download_error_io_error"),
            ("time_limit", "download_error_connection_error"), ("refused_destination", "download_error_unknown_host"),
            ("parser_exception", "download_error_parser_exception"), ("unsupported_type", "download_error_unsupported_type"),
            ("unsupported_type_html", "download_error_unsupported_type_html"), ("size_limit", "download_error_error_unknown"),
            ("unknown", "download_error_error_unknown"), ("a_label_from_a_later_server", "download_error_error_unknown")]
        for (label, key) in table {
            let status = try #require(ServerRefreshStatus(record: ["last_attempt": 1_000, "last_success": .null, "error": ["label": .string(label)]]))
            #expect(status.failed && status.statusKey == key && status.technical == nil, "\(label)")
        }
        let coded = try #require(ServerRefreshStatus(record: ["last_attempt": 2_000, "error": ["label": "http_status", "code": 503]]))
        #expect(coded.technical == "503" && coded.lastAttempt == Date(timeIntervalSince1970: 2))
        let detailed = try #require(ServerRefreshStatus(record: ["last_attempt": 2_000, "error": ["label": "not_found", "code": 404, "detail": "Gone"]]))
        #expect(detailed.technical == "Gone")
        let ok = try #require(ServerRefreshStatus(record: ["last_attempt": 3_000, "last_success": 3_000, "error": .null]))
        #expect(!ok.failed && ok.lastSuccess == Date(timeIntervalSince1970: 3))
        #expect(ServerRefreshStatus(record: nil) == nil && ServerRefreshStatus(record: .null) == nil)
        var feed = LibraryFeed(id: 1, source: "https://example.test/feed.xml", metadata: ParsedFeed(format: .rss), episodes: [])
        for (local, server, shown) in [(false, nil, false), (true, nil, true), (false, ok, false), (true, ok, true), (false, coded, true), (true, coded, true)] {
            feed.lastUpdateFailed = local; feed.serverRefresh = server
            #expect(feed.refreshFailed == shown, "this device \(local), server \(String(describing: server?.failed))")
        }
    }

    /// A library that pulled refresh statuses before projections showed them shows them at its next exchange, once, with
    /// what a projection shows; a library with nothing to show writes nothing.
    @Test func refreshStatusesPulledBeforeTheyWereShownAreShownOnce() async throws {
        let fixture = try await ServerLibraryFixture()
        let (feed, podcast, _, _) = try await Self.registered(fixture)
        try await fixture.store.retireEverythingForTesting()
        let applier = try await Applier(fixture)
        try await applier.apply([Self.refreshStatus(podcast, attempt: 1_759_000_000_000, error: ["label": "not_found", "code": 404])])
        let projected = try #require(try await fixture.store.feed(id: feed.id)?.serverRefresh)
        // As the earlier projection left it: the record stored, the feed without it.
        try await fixture.store.setServerRefreshForTesting(nil, feedID: feed.id)
        #expect(try await fixture.store.feed(id: feed.id)?.refreshFailed == false)
        #expect(try await fixture.store.projectStoredRefreshStatuses())
        #expect(try await fixture.store.feed(id: feed.id)?.serverRefresh == projected)
        try await fixture.store.setServerRefreshForTesting(nil, feedID: feed.id)
        #expect(try await !fixture.store.projectStoredRefreshStatuses(), "once")
        #expect(try await fixture.store.feed(id: feed.id)?.serverRefresh == nil)
        await fixture.close()
        let empty = try await ServerLibraryFixture()
        #expect(try await !empty.store.projectStoredRefreshStatuses())
        await empty.close()
    }
}

extension FeedLibraryStore {
    /// A feed's server refresh status as it would be without a projection of it.
    func setServerRefreshForTesting(_ status: ServerRefreshStatus?, feedID: Int64) throws {
        try write(.remote) {
            guard var feed = try loadFeedHeader(feedID) else { throw FeedLibraryError.missingFeed(feedID) }
            feed.serverRefresh = status
            try saveHeader(feed)
        }
    }

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
