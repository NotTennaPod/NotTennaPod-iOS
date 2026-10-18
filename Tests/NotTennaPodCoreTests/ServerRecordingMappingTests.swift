import Foundation
import Testing
@testable import NotTennaPodCore

/// One test per row of PROTOCOL §15.2: each store mutation in a server library records exactly its
/// facts, with their overlays.
struct ServerRecordingMappingTests {
    private func withFixture(_ body: (ServerLibraryFixture) async throws -> Void) async throws {
        let fixture = try await ServerLibraryFixture()
        do { try await body(fixture); await fixture.close() } catch { await fixture.close(); throw error }
    }

    private func episode(_ feed: LibraryFeed, _ guid: String) throws -> LibraryEpisode {
        try #require(feed.episodes.first { $0.details.identifier == guid })
    }

    // MARK: Subscriptions and podcast policies

    @Test func previewStaysLocalUntilASyncedActionRegistersIt() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let preview = try await store.preparePreview(ServerLibraryFixture.fetched(), now: ServerLibraryFixture.now)
            #expect(try fixture.outboxCount() == 0)
            #expect(try fixture.rows("SELECT count(*) FROM ntp_registrations") == [["0"]])
            // The first synced action on a preview episode registers the preview; the action is a draft.
            let item = try episode(preview, "guid-1")
            try await store.setFavorite(episodeID: item.id, favorite: true)
            let facts = try fixture.outbox()
            #expect(facts.map(\.type) == ["podcast.register_preview"])
            #expect(facts[0].payload == ["feed_url": "https://example.test/feed.xml"])
            let drafts = try fixture.drafts()
            #expect(drafts.map(\.type) == ["favorite.set"])
            #expect(drafts[0].registration == facts[0].opID)
            #expect(try fixture.rows("SELECT kind, state FROM ntp_registrations") == [["register_preview", "pending"]])
            // A device-only preference of the preview records nothing.
            try await store.updatePreferences(feedID: preview.id) { $0.tags = ["News"] }
            #expect(try fixture.outboxCount() == 1 && fixture.drafts().count == 1)
        }
    }

    @Test func subscribingARegisteredPreviewObservesItsGeneration() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let preview = try await store.preparePreview(ServerLibraryFixture.fetched(), now: ServerLibraryFixture.now)
            try await store.setFavorite(episodeID: try episode(preview, "guid-1").id, favorite: true)
            let registration = try fixture.registrationOp(feedID: preview.id)
            let ids = try fixture.created(registration)
            try await store.resolveRegistration(opID: registration, .init(podcastID: ids.podcast, generationID: ids.generation, mode: "created", decisionID: nil))
            let before = try fixture.outboxCount()
            #expect(try await store.subscribePreview(feedID: preview.id))
            let subscribe = try #require(try fixture.newFacts(after: before).first)
            #expect(subscribe.type == "podcast.subscribe")
            #expect(subscribe.payload["observed"] == ["podcast_id": .string(ids.podcast), "generation_id": .string(ids.generation), "state": "not_subscribed"])
            #expect(subscribe.targets == [["entity": "podcast", "id": .string(ids.podcast)]])
            // Repeated taps cannot record twice.
            #expect(try await store.subscribePreview(feedID: preview.id) == false)
            #expect(try fixture.outboxCount() == before + 1)
        }
    }

    @Test func importsAreRefusedInAServerLibrary() async throws {
        try await withFixture { fixture in
            await #expect(throws: ServerRecordingError.refusedInServerLibrary("OPML import")) {
                try await fixture.store.importOPMLEntry(.init(title: "Show", xmlURL: "https://example.test/feed.xml"))
            }
            let feeds = try fixture.rows("SELECT count(*) FROM feeds")
            #expect(feeds == [["0"]])
        }
    }

    @Test func unsubscribeRecordsForRegisteredAndPendingPodcastsOnly() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let registered = try await fixture.subscribeRegistered()
            var before = try fixture.outboxCount()
            #expect(try await store.requestFeedDeletion(feedID: registered.feed.id))
            let unsubscribe = try fixture.newFacts(after: before)
            #expect(unsubscribe.map(\.type) == ["podcast.unsubscribe"])
            #expect(unsubscribe[0].targets == [["entity": "podcast", "id": .string(registered.podcast), "generation": .string(registered.generation)]])
            #expect(unsubscribe[0].payload == [:])
            // Pending: a draft on the registration's chain.
            let pending = try await store.insert(ServerLibraryFixture.fetched("https://example.test/other.xml", title: "Other"))
            #expect(try await store.requestFeedDeletion(feedID: pending.id))
            #expect(try fixture.drafts().map(\.type) == ["podcast.unsubscribe"])
            // A preview the account does not know, and preview expiry: nothing.
            before = try fixture.outboxCount()
            let preview = try await store.preparePreview(ServerLibraryFixture.fetched("https://example.test/p.xml", title: "P"), now: ServerLibraryFixture.now)
            #expect(try await store.requestFeedDeletion(feedID: preview.id))
            let expiring = try await store.preparePreview(ServerLibraryFixture.fetched("https://example.test/q.xml", title: "Q"), now: ServerLibraryFixture.now)
            _ = try await store.requestExpiredFeedDeletions(expiredAt: ServerLibraryFixture.now.addingTimeInterval(86_400 * 30))
            #expect(try await store.feed(id: expiring.id) == nil)
            #expect(try fixture.outboxCount() == before)
        }
    }

    @Test func archiveRestoreAndPolicyRecordOneRegisterPerChangedProperty() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let one = try await fixture.subscribeRegistered()
            let two = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/two.xml", title: "Two"))
            var before = try fixture.outboxCount()
            try await store.updatePreferences(feedID: one.feed.id) { $0.subscriptionState = .archived }
            try await store.updatePreferences(feedID: one.feed.id) { $0.subscriptionState = .subscribed }
            var facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["podcast.archive", "podcast.restore"])
            #expect(facts[0].targets == [["entity": "podcast", "id": .string(one.podcast), "generation": .string(one.generation)]])
            before = try fixture.outboxCount()
            try await store.applyBulk(.keepUpdated(false), feedIDs: [one.feed.id, two.feed.id])
            try await store.updatePreferences(feedID: two.feed.id) { $0.newEpisodesAction = .queue; $0.tags = ["x"]; $0.autoDelete = .always }
            facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["podcast.set_policy", "podcast.set_policy", "podcast.set_policy"])
            #expect(facts.map(\.payload) == [["keep_updated": false], ["keep_updated": false], ["new_episodes_action": "queue"]])
            #expect(try fixture.overlays(opID: facts[2].opID) == [["podcast", two.podcast, "new_episodes_action", "register", "\"queue\""]])
            // Device-only settings record nothing.
            before = try fixture.outboxCount()
            try await store.updatePreferences(feedID: two.feed.id) { $0.customTitle = "Mine"; $0.skip = .init(introSeconds: 5, endingSeconds: 0); $0.showEpisodeNotification = true }
            try await store.setEpisodeFilter(feedID: two.feed.id, filter: .init(values: ["unplayed"]))
            #expect(try fixture.outboxCount() == before)
        }
    }

    @Test func credentialsRecordTheirSecretAndClearing() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let registered = try await fixture.subscribeRegistered()
            let vault = MemoryCredentialVault()
            let authentication = FeedAuthentication(store: store, vault: vault)
            var before = try fixture.outboxCount()
            try await authentication.save(.init(username: "alice", password: "s3cret"), feedID: registered.feed.id)
            var facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["podcast.set_credentials"])
            let secret = try #require(facts[0].payload["secret_id"]?.stringValue)
            #expect(ContractIdentity.isUUID(secret))
            let credential = try #require(try await store.feedCredentialID(feedID: registered.feed.id))
            #expect(try fixture.rows("SELECT secret_id, credential_id, approved_origins, origin FROM ntp_secrets")
                    == [[secret, credential.uuidString, "[\"https:\\/\\/example.test:443\"]", "local"]])
            #expect(try fixture.rows("SELECT secret_ids FROM ntp_outbox WHERE op_id = '\(facts[0].opID)'") == [["[\"\(secret)\"]"]])
            // Passwords never enter the database.
            #expect(try !fixture.rows("SELECT CAST(fact AS TEXT) FROM ntp_outbox").flatMap { $0 }.contains { $0?.contains("s3cret") == true })
            // Replacing keeps the superseded credential (a secret) for recovery; clearing records {clear: true}.
            before = try fixture.outboxCount()
            try await authentication.save(.init(username: "", password: ""), feedID: registered.feed.id)
            facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.payload) == [["clear": true]])
            #expect(vault.contains(credential))
        }
    }

    @Test func changingTheFeedURLRecordsChangeURLWithoutUserinfo() async throws {
        try await withFixture { fixture in
            let registered = try await fixture.subscribeRegistered()
            let before = try fixture.outboxCount()
            #expect(try await fixture.store.updateFeedDownloadURL(original: registered.feed.source, updated: "https://user:pw@moved.example.test/feed.xml") == [registered.feed.id])
            let facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["podcast.change_url"])
            #expect(facts[0].payload == ["url": "https://moved.example.test/feed.xml"])
        }
    }

    // MARK: Episode state, Inbox and favorites

    @Test func marksRecordPerEpisodeWithTheResetDecision() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let registered = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched(medialess: [4]))
            let one = try episode(registered.feed, "guid-1"), two = try episode(registered.feed, "guid-2"), four = try episode(registered.feed, "guid-4")
            var before = try fixture.outboxCount()
            try await store.markEpisodesPlayed(episodeIDs: [one.id, four.id, 999], played: true)
            try await store.markEpisodePlayed(episodeID: two.id, played: true, resetPosition: false)
            var facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["episode.mark_played", "episode.mark_played", "episode.mark_played"])
            #expect(facts.map { $0.payload["reset_position"] } == [true, false, false])
            #expect(try facts[0].episodeIDs == [fixture.expectedEpisodeID(podcast: registered.podcast, guid: "guid-1")])
            #expect(try fixture.overlays(opID: facts[0].opID).map { $0[2] } == ["play_state", "position"])
            before = try fixture.outboxCount()
            try await store.markEpisodesPlayed(episodeIDs: [one.id, two.id], played: false)
            facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["episode.mark_unplayed", "episode.mark_unplayed"])
            #expect(facts[0].payload["episode"]?["occurrence"] == [
                "k": "rss-guid", "v": "guid-1", "guid": "guid-1", "enclosure_url": "https://media.example.test/Show/1.mp3",
                "title": "Episode 1", "publication_time": .integer(Int64((ServerLibraryFixture.now.timeIntervalSince1970 + 86_400) * 1000))])
        }
    }

    @Test func swipeMarksAndUndoRecordTheirFacts() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let registered = try await fixture.subscribeRegistered()
            let one = try episode(registered.feed, "guid-1"), two = try episode(registered.feed, "guid-2"), three = try episode(registered.feed, "guid-3")
            try await store.updatePreferences(feedID: registered.feed.id) { $0.newEpisodesAction = .inbox }
            // NEW comes from a refresh filing; here from projecting records.
            for id in [two.id, three.id] { try await store.projectForTesting(id) { $0.userState.playState = .new } }
            let before = try fixture.outboxCount()
            let played = try #require(try await store.applySwipeMark(episodeID: one.id, action: .togglePlayed))
            _ = try await store.applySwipeMark(episodeID: one.id, action: .togglePlayed)
            _ = try await store.applySwipeMark(episodeID: two.id, action: .togglePlayed)
            _ = try await store.applySwipeMark(episodeID: three.id, action: .removeInbox)
            let facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["episode.mark_played", "episode.mark_unplayed", "inbox.dismiss", "inbox.dismiss"])
            #expect(facts[0].payload["reset_position"] == false)
            #expect(try fixture.overlays(opID: facts[2].opID).map { $0[3] } == ["dismiss"])
            _ = played
            let receipt = try #require(try await store.applySwipeMark(episodeID: one.id, action: .togglePlayed))
            let count = try fixture.outboxCount()
            #expect(try await store.undoSwipeMark(receipt) == .restored)
            let undo = try fixture.newFacts(after: count)
            #expect(undo.map(\.type) == ["episode.restore_state"])
            #expect(undo[0].payload["play_state"] == "unplayed" && undo[0].payload["position"] == 0)
        }
    }

    @Test func resetPositionRecordsResetPosition() async throws {
        try await withFixture { fixture in
            let registered = try await fixture.subscribeRegistered()
            let before = try fixture.outboxCount()
            try await fixture.store.resetPlaybackPosition(episodeID: try episode(registered.feed, "guid-3").id)
            let facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["episode.reset_position"])
            #expect(Set(try fixture.overlays(opID: facts[0].opID).map { $0[2] }) == ["play_state", "position"])
        }
    }

    @Test func inboxRemovalsDismissOnlyNewMembersAndUnplayPlayedOnes() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let registered = try await fixture.subscribeRegistered()
            let ids = registered.feed.episodes.map(\.id).sorted()
            for (index, id) in ids.enumerated() {
                let state: EpisodePlayState = index == 3 ? .played : .new
                try await store.projectForTesting(id) { $0.userState.playState = state }
            }
            var before = try fixture.outboxCount()
            try await store.removeEpisodesFromInbox(episodeIDs: [ids[0], ids[1], ids[3]])
            var facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["inbox.dismiss", "episode.mark_unplayed"])
            let expected = try [ids[0], ids[1]].map { try #require(try fixture.wireID($0)) }.sorted()
            #expect(facts[0].episodeIDs == expected)
            #expect(facts[0].targets.count == 2)
            before = try fixture.outboxCount()
            try await store.removeFeedFromInbox(feedID: registered.feed.id)
            facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["inbox.dismiss"])
            #expect(facts[0].episodeIDs == [try #require(try fixture.wireID(ids[2]))])
            // Remove all from inbox names exactly the episodes that were NEW.
            try await store.projectForTesting(ids[0]) { $0.userState.playState = .new }
            before = try fixture.outboxCount()
            try await store.removeAllFromInbox()
            facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["inbox.dismiss_all"])
            #expect(facts[0].episodeIDs == [try #require(try fixture.wireID(ids[0]))])
        }
    }

    @Test func favoritesRecordOnlyChangedEpisodes() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let registered = try await fixture.subscribeRegistered()
            let ids = registered.feed.episodes.map(\.id).sorted()
            try await store.setFavorite(episodeID: ids[0], favorite: true)
            let before = try fixture.outboxCount()
            try await store.setFavorite(episodeIDs: [ids[0], ids[1]], favorite: true)
            let facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["favorite.set"])
            #expect(facts[0].episodeIDs == [try #require(try fixture.wireID(ids[1]))])
        }
    }

    // MARK: Queue

    @Test func addsRecordTheirKeysBetweenNeighboursAndQueueOrderEqualsKeyOrder() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let registered = try await fixture.subscribeRegistered()
            let ids = registered.feed.episodes.map(\.id).sorted()
            try await store.projectForTesting(ids[0]) { $0.userState.playState = .new }
            var before = try fixture.outboxCount()
            _ = try await store.enqueue([ids[2], ids[0]])
            _ = try await store.enqueue([ids[1]], location: .front)
            let facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["queue.add", "queue.add"])
            #expect(facts[0].episodeIDs == [try #require(try fixture.wireID(ids[2])), try #require(try fixture.wireID(ids[0]))])
            #expect(facts[0].payload["moves"] == nil)
            #expect(facts[0].payload["place"] == ["kind": "end"])
            #expect(facts[1].payload["place"] == ["kind": "start"])
            #expect(try fixture.queueOrderMatchesKeys())
            let keys = try fixture.queueKeys()
            #expect(keys.map(\.episode) == [ids[1], ids[2], ids[0]])
            #expect(facts[1].payload["members"]?.arrayValue?.first?["key"]?.stringValue == keys[0].key.wire)
            #expect(try fixture.overlays(opID: facts[0].opID).filter { $0[2] == "play_state" }.map { $0[3] } == ["dismiss", "dismiss"])
            #expect(try await store.episode(id: ids[0])?.userState.playState == .unplayed)
            // An episode already queued is not added again.
            before = try fixture.outboxCount()
            _ = try await store.enqueue([ids[1]])
            #expect(try fixture.outboxCount() == before)
        }
    }

    @Test func playLoadAndEnqueueDownloadedRecordQueueAdd() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let registered = try await fixture.subscribeRegistered()
            let ids = registered.feed.episodes.map(\.id).sorted()
            let before = try fixture.outboxCount()
            _ = try await store.beginPlayback(episodeID: ids[0])
            _ = try await store.requestDownload(episodeID: ids[1], directory: fixture.directory, enqueue: true)
            _ = try await store.beginPlayback(episodeID: ids[0])
            let facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["queue.add", "queue.add"])
            #expect(try fixture.queueOrderMatchesKeys())
        }
    }

    @Test func removalsRecordTheirReasonAndUndoRestoresTheRemovedKey() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let registered = try await fixture.subscribeRegistered()
            let ids = registered.feed.episodes.map(\.id).sorted()
            _ = try await store.enqueue(ids)
            let keys = try fixture.queueKeys()
            var before = try fixture.outboxCount()
            let removal = try await store.removeFromQueueWithUndo(ids[1])
            let receipt = try #require(removal.receipt)
            var facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["queue.remove"])
            #expect(facts[0].payload["reason"] == "user")
            before = try fixture.outboxCount()
            #expect(try await store.undoQueueRemoval(receipt).status == .restored)
            facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["queue.restore"])
            let member = try #require(facts[0].payload["members"]?.arrayValue?.first)
            #expect(member["key"]?.stringValue == keys[1].key.wire && member["position_id"]?.stringValue == keys[1].positionID)
            // When the old key no longer lies between the restored neighbours, a new key is allocated there.
            // [0, 1, 2, 3] → remove 2 → [0, 1, 3] → 1 to the end → [0, 3, 1]; Undo puts 2 between 3 and 1, where its
            // old key (above 1's) no longer lies.
            let second = try #require(try await store.removeFromQueueWithUndo(ids[2]).receipt)
            _ = try await store.performQueueMove(.item(ids[1], finalIndex: 2), expected: try await store.queue().map(QueueEpisodeIdentity.init))
            before = try fixture.outboxCount()
            #expect(try await store.undoQueueRemoval(second).status == .restored)
            #expect(try await store.queue().map(\.id) == [ids[0], ids[3], ids[2], ids[1]])
            let restored = try #require(try fixture.newFacts(after: before).first?.payload["members"]?.arrayValue?.first)
            #expect(restored["key"]?.stringValue != keys[2].key.wire)
            #expect(try fixture.queueOrderMatchesKeys())
            // Download deletion removing from the queue.
            before = try fixture.outboxCount()
            try await store.requestMediaDeletion(episodeID: ids[2], deleteRemovesFromQueue: true)
            facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["queue.remove"])
            #expect(facts[0].payload["reason"] == "download_deleted")
            _ = try await store.removeFromQueue([ids[3]])
            #expect(try fixture.outbox().last?.payload["reason"] == "user")
        }
    }

    @Test func movesRecordMoveOrReorder() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let registered = try await fixture.subscribeRegistered()
            let ids = registered.feed.episodes.map(\.id).sorted()
            _ = try await store.enqueue(ids)
            let keys = try fixture.queueKeys()
            var before = try fixture.outboxCount()
            _ = try await store.performQueueMove(.item(ids[0], finalIndex: 2), expected: try await store.queue().map(QueueEpisodeIdentity.init))
            var facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["queue.move"])
            #expect(facts[0].episodeIDs == [try #require(try fixture.wireID(ids[0]))])
            #expect(facts[0].payload["key"]?.stringValue != keys[0].key.wire)
            #expect(try fixture.queueKeys().filter { $0.episode != ids[0] }.map(\.key) == keys.filter { $0.episode != ids[0] }.map(\.key))
            before = try fixture.outboxCount()
            _ = try await store.performQueueMove(.boundary([ids[2], ids[3]], .top), expected: try await store.queue().map(QueueEpisodeIdentity.init))
            facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["queue.reorder"])
            #expect(facts[0].episodeIDs.count == 2)
            #expect(try fixture.queueOrderMatchesKeys())
        }
    }

    @Test func sortSheetSortsWithTheCanonicalComparatorAndKeepSortedSortsAfterInserting() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let registered = try await fixture.subscribeRegistered()
            let ids = registered.feed.episodes.map(\.id).sorted()
            _ = try await store.enqueue([ids[2], ids[0], ids[1]])
            var before = try fixture.outboxCount()
            let change = try await store.reorderQueue(.episodeTitleAZ)
            #expect(change.episodeIDs == [ids[0], ids[1], ids[2]])
            var facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["queue.reorder"])
            // The sort and every member it observed, on the account (PROTOCOL §7.6).
            #expect(facts[0].payload["sort"] == ["sort_order": "episode_title_a_z"])
            #expect(facts[0].episodeIDs == [ids[2], ids[0], ids[1]].compactMap { try? fixture.wireID($0) })
            #expect(facts[0].targets == [["entity": "account", "id": .string(fixture.identity.accountID)]])
            #expect(try fixture.queueOrderMatchesKeys())
            store.setQueueInsertionSettings(.init(location: .back, keepSortedOrder: .episodeTitleZA, locale: .init(identifier: "en_US")))
            before = try fixture.outboxCount()
            _ = try await store.enqueue([ids[3]])
            facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["queue.add"])
            #expect(facts[0].payload["members"]?.arrayValue?.count == 1)
            #expect(facts[0].payload["moves"] == nil && facts[0].payload["place"] == ["kind": "end"])
            #expect(try await store.queue().map(\.id) == [ids[3], ids[2], ids[1], ids[0]])
            #expect(try fixture.queueOrderMatchesKeys())
        }
    }

    @Test func clearRecordsTheObservedSyncedMembers() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let registered = try await fixture.subscribeRegistered()
            let ids = registered.feed.episodes.map(\.id).sorted()
            _ = try await store.enqueue(ids)
            let before = try fixture.outboxCount()
            _ = try await store.clearQueue()
            let facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["queue.clear"])
            #expect(facts[0].payload["observed"]?.arrayValue?.count == 4)
            #expect(try fixture.rows("SELECT count(*) FROM ntp_queue_keys") == [["0"]])
        }
    }

    // MARK: Downloads, history, statistics, account policies

    @Test func downloadCompletionDismissesANewEpisode() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let registered = try await fixture.subscribeRegistered()
            let id = try episode(registered.feed, "guid-1").id
            try await store.projectForTesting(id) { $0.userState.playState = .new }
            let job = try #require(try await store.requestDownload(episodeID: id, directory: fixture.directory, enqueue: false))
            let started = try #require(try await store.beginDownloadAttempt(id: job.id))
            try Data(count: 64).write(to: job.destination)
            #expect(try await store.attachDownloadFile(id: job.id, attempt: started.attempts))
            let before = try fixture.outboxCount()
            #expect(try await store.completeDownload(id: job.id, attempt: started.attempts))
            #expect(try fixture.newFacts(after: before).map(\.type) == ["inbox.dismiss"])
        }
    }

    @Test func historyRemovalDependsOnTheFrontierAndUndoRestoresEveryCut() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let registered = try await fixture.subscribeRegistered()
            let id = try episode(registered.feed, "guid-1").id
            try await store.projectForTesting(id) { $0.userState.lastPlayedHistoryMilliseconds = 1_000 }
            // A pending podcast whose drafts name an episode keep a deferred removal of their own.
            let tip = try #require(try fixture.outbox().last).opID
            let before = try fixture.outboxCount()
            let receipt = try #require(try await store.removeFromPlaybackHistoryWithUndo(id))
            let facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["history.remove"])
            #expect(facts[0].dependencies == [tip])
            #expect(try fixture.overlays(opID: facts[0].opID).map { $0[3] } == ["history_cut"])
            let count = try fixture.outboxCount()
            #expect(try await store.undoHistoryRemoval(receipt).status == .restored)
            let restores = try fixture.newFacts(after: count)
            #expect(restores.map(\.type) == ["history.restore"])
            #expect(restores[0].payload["removal"]?.stringValue == facts[0].opID)
            #expect(restores[0].payload["time"] == 1_000)
            #expect(restores[0].dependencies == [facts[0].opID])
        }
    }

    @Test func deferredCutsCoverExactlyTheDraftsBeforeThem() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            _ = try await fixture.subscribeRegistered()
            let pending = try await store.insert(ServerLibraryFixture.fetched("https://example.test/pending.xml", title: "Pending"))
            let item = try episode(pending, "guid-1")
            try await store.setFavorite(episodeID: item.id, favorite: true)
            try await store.projectForTesting(item.id) { $0.userState.lastPlayedHistoryMilliseconds = 5_000 }
            let before = try fixture.outboxCount()
            _ = try await store.clearPlaybackHistory()
            try await store.resetPlayedDurationStatistics()
            #expect(try fixture.newFacts(after: before).map(\.type) == ["history.clear", "statistics.reset"])
            // The deferred cuts follow the favorite on the pending chain, and are followed by what comes after.
            try await store.setFavorite(episodeID: item.id, favorite: false)
            #expect(try fixture.drafts().map(\.type) == ["favorite.set", "history.clear", "statistics.reset", "favorite.set"])
            // History removal of an episode named by drafts: a deferred removal on that chain; Undo restores it there.
            try await store.projectForTesting(item.id) { $0.userState.lastPlayedHistoryMilliseconds = 6_000 }
            let receipt = try #require(try await store.removeFromPlaybackHistoryWithUndo(item.id))
            #expect(try fixture.drafts().last?.type == "history.remove")
            #expect(try await store.undoHistoryRemoval(receipt).status == .restored)
            let drafts = try fixture.drafts()
            #expect(drafts.last?.type == "history.restore")
            #expect(drafts.last?.template["payload"]?["removal"]?.stringValue == drafts[drafts.count - 2].opID)
            // Materialized in author order on the resolved podcast.
            let op = try fixture.registrationOp(feedID: pending.id)
            let ids = try fixture.created(op)
            try await store.resolveRegistration(opID: op, .init(podcastID: ids.podcast, generationID: ids.generation, mode: "created", decisionID: ContractIdentity.randomUUID()))
            #expect(try fixture.drafts().isEmpty)
            let materialized = Array(try fixture.outbox().suffix(6))
            #expect(materialized.map(\.type) == ["favorite.set", "history.clear", "statistics.reset", "favorite.set", "history.remove", "history.restore"])
            #expect(zip(materialized, materialized.dropFirst()).allSatisfy { $1.json["previous_op_id"]?.stringValue == $0.opID })
        }
    }

    @Test func accountPoliciesRecordRegistersAndReadBackWithPendingChanges() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            #expect(try await store.serverAccountPolicies() == ServerAccountPolicyValues())
            try await store.setServerAccountPolicy(.newEpisodesAction(.queue))
            try await store.setServerAccountPolicy(.enqueueLocation(.afterCurrentlyPlaying))
            try await store.setServerAccountPolicy(.sorting(keepSorted: true, order: .random))
            try await store.setServerAccountPolicy(.sorting(keepSorted: true, order: .durationLongShort))
            let facts = try fixture.outbox()
            #expect(facts.map(\.type) == ["account.set_discovery_policy", "account.set_queue_policy", "account.set_queue_policy", "account.set_queue_policy"])
            #expect(facts.map(\.payload) == [["new_episodes_action": "queue"], ["enqueue_location": "after_current"],
                                            ["sorting": ["keep_sorted": false, "sort_order": "random"]],
                                            ["sorting": ["keep_sorted": true, "sort_order": "duration_long_short"]]])
            #expect(facts[0].targets == [["entity": "account", "id": .string(fixture.identity.accountID)]])
            #expect(try await store.serverAccountPolicies() == .init(newEpisodesAction: .queue, enqueueLocation: .afterCurrentlyPlaying,
                                                                    keepSorted: true, keepSortedOrder: .durationLongShort))
        }
    }

    @Test func refreshObservesAndProposesWhileRemoteProjectionAndLocalFoldersRecordNothing() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let registered = try await fixture.subscribeRegistered()
            var before = try fixture.outboxCount()
            _ = try await store.applyRefresh(ServerLibraryFixture.fetched(count: 6), feedID: registered.feed.id,
                                             options: .init(now: ServerLibraryFixture.now.addingTimeInterval(86_400 * 7)))
            // Its releases are observed and proposed (PROTOCOL §9.4; the rest of the observation waits for the first
            // canonical metadata); `ServerDiscoveryTests` covers them.
            #expect(try fixture.newFacts(after: before).map(\.type) == ["catalog.observe", "discovery.propose", "discovery.propose"])
            before = try fixture.outboxCount()
            try await store.projectForTesting(registered.feed.episodes[0].id) { $0.userState.isFavorite = true }
            let folder = try await store.registerLocalFolder(title: "Folder", directoryIdentity: "folder-1", bookmark: Data([1]))
            #expect(try await store.feed(id: folder.feed.id) != nil)
            #expect(try fixture.outboxCount() == before)
        }
    }

    // MARK: The seam's rules

    @Test func anUnmappedChangeRollsBackTheWholeTransaction() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let registered = try await fixture.subscribeRegistered()
            let id = registered.feed.episodes[0].id
            let rows = try fixture.libraryRows(), tables = try fixture.serverTables()
            await #expect(throws: ServerRecordingError.unmappedChange(intent: "registers", change: "episode \(id) play_state")) {
                try await store.updateEpisode(id: id) { $0.userState.playState = .played }
            }
            #expect(try fixture.libraryRows() == rows)
            #expect(try fixture.serverTables() == tables)
        }
    }

    @Test func aSyncedWriteOutsideTheSeamIsRefused() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let registered = try await fixture.subscribeRegistered()
            let id = registered.feed.episodes[0].id
            await #expect(throws: ServerRecordingError.writeOutsideSeam) {
                try await store.saveOutsideSeamForTesting(id: id, feedID: registered.feed.id)
            }
            // A device-only write outside the seam (download bookkeeping) is allowed.
            let file = fixture.directory.appendingPathComponent("clone.media")
            try Data(count: 8).write(to: file)
            #expect(try await store.adoptReusedDownload(episodeID: id, file: file, downloadDate: nil))
        }
    }
}

extension FeedLibraryStore {
    /// Projects a value onto an episode as pulled records do (`.remote`): any field, metadata as well as user state.
    func projectForTesting(_ id: Int64, _ change: @Sendable (inout LibraryEpisode) -> Void) throws {
        try write(.remote) {
            guard var episode = try loadEpisode(id) else { return }
            change(&episode)
            try saveEpisode(episode, feedID: feedID(forEpisode: id), scope: .metadata)
        }
    }

    func saveOutsideSeamForTesting(id: Int64, feedID: Int64) throws {
        guard var episode = try loadEpisode(id) else { return }
        episode.userState.isFavorite.toggle()
        try database.transaction { try saveEpisode(episode, feedID: feedID) }
    }
}

/// A Keychain stand-in for feed credentials.
final class MemoryCredentialVault: SynchronizationCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]
    func insert(_ password: String, id: UUID) throws { lock.withLock { values[id] = password } }
    func password(id: UUID) throws -> String {
        try lock.withLock { guard let value = values[id] else { throw FeedLibraryError.invalidMutation }; return value }
    }
    func remove(id: UUID) throws { _ = lock.withLock { values.removeValue(forKey: id) } }
    func contains(_ id: UUID) -> Bool { lock.withLock { values[id] != nil } }
}

// MARK: - Facts the server never accepts (PROTOCOL §6.13)

extension ServerRecordingMappingTests {
    /// A sort whose `queue.reorder` would be larger than the server accepts is refused, random or not, never split: the
    /// queue stays as it was and nothing is recorded. Under the bound the same sort is one fact.
    @Test(arguments: [QueueSortOrder.episodeTitleAZ, .random])
    func aSortTooLargeForTheServerIsRefusedAndChangesNothing(order: QueueSortOrder) async throws {
        let fixture = try await ServerLibraryFixture()
        do {
            let store = fixture.store
            let ids = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched(count: 60)).feed.episodes.map(\.id).sorted()
            _ = try await store.enqueue(ids.reversed())
            let queue = try await store.queue().map(\.id)
            let keys = try fixture.queueKeys().map(\.key)
            let before = try fixture.outboxCount()
            await store.setServerFactBoundForTesting(8 << 10)
            var refused: ServerRecordingError?
            do { _ = try await store.reorderQueue(order) } catch let error as ServerRecordingError { refused = error }
            guard case .factTooLarge(let type, let bytes)? = refused else {
                Issue.record("the sort was not refused: \(String(describing: refused))")
                await fixture.close(); return
            }
            #expect(type == "queue.reorder" && bytes > 8 << 10)
            #expect(try await store.queue().map(\.id) == queue, "the queue is unchanged")
            #expect(try fixture.queueKeys().map(\.key) == keys)
            #expect(try fixture.outboxCount() == before, "nothing recorded")
            await store.setServerFactBoundForTesting(nil)
            _ = try await store.reorderQueue(order)
            let facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["queue.reorder"], "one fact under the bound")
            #expect(facts.first?.payload["observed"]?.arrayValue?.count == 60)
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }
}
