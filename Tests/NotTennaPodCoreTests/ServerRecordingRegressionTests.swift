import Foundation
import Testing
@testable import NotTennaPodCore

/// Recording regressions. Each failed before its fix.
@MainActor @Suite(.serialized) struct ServerRecordingRegressionTests {
    private func withFixture(_ body: (ServerLibraryFixture) async throws -> Void) async throws {
        let fixture = try await ServerLibraryFixture()
        do { try await body(fixture); await fixture.close() } catch { await fixture.close(); throw error }
    }

    // MARK: Since the queue replay, a keep-sorted add names only its members and its place; the server sorts
    // at that place (PROTOCOL §7.6; the former `moves` are retired), and the members the sort re-keyed are overlays

    @Test func aKeepSortedAddNamesItsMembersAndPlaceAndShowsTheSortedOrderByOverlays() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let one = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/one.xml", title: "One", count: 5))
            let two = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/two.xml", title: "Two", count: 3))
            let a = one.feed.episodes.map(\.id).sorted(), b = two.feed.episodes.map(\.id).sorted()
            _ = try await store.enqueue([a[4], a[0], b[2]])
            let keysBefore = try fixture.queueKeys()
            store.setQueueInsertionSettings(.init(keepSortedOrder: .episodeTitleAZ))
            let before = try fixture.outboxCount()
            _ = try await store.enqueue([b[0]])
            let facts = try fixture.newFacts(after: before)
            try #require(facts.map(\.type) == ["queue.add"])
            #expect(facts[0].payload["moves"] == nil)
            #expect(facts[0].payload["place"] == ["kind": "end"], "an add at the back is placed at the end, then sorted")
            #expect(facts[0].episodeIDs == [try #require(try fixture.wireID(b[0]))])
            #expect(facts[0].targets.count == 1)
            // Every member the sort re-keyed shows its predicted key until the server's keys arrive.
            let keys = try fixture.queueKeys()
            let rekeyed = keys.filter { key in key.episode != b[0] && keysBefore.first { $0.episode == key.episode }?.key != key.key }
            #expect(!rekeyed.isEmpty)
            let overlays = try fixture.overlays(opID: facts[0].opID).filter { $0[2] == "queue_position" }
            for key in rekeyed + keys.filter({ $0.episode == b[0] }) {
                let wire = try #require(try fixture.wireID(key.episode))
                let value = try #require(overlays.first { $0[1] == wire }?[4] ?? nil)
                #expect(try ContractJSON.decode(Data(value.utf8))["key"]?.stringValue == key.key.wire)
            }
            #expect(try fixture.queueOrderMatchesKeys())
        }
    }

    @Test func aPendingPodcastsKeepSortedAddIsOnlyItsDraft() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let one = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/one.xml", title: "One", count: 5))
            let a = one.feed.episodes.map(\.id).sorted()
            _ = try await store.enqueue([a[4], a[0]])
            let pending = try await store.insert(ServerLibraryFixture.fetched("https://example.test/p.xml", title: "Pending", count: 2))
            store.setQueueInsertionSettings(.init(keepSortedOrder: .episodeTitleAZ))
            let before = try fixture.outboxCount()
            _ = try await store.enqueue([pending.episodes[0].id])
            // The re-sort moved One 5 after One 1 and the new episode; the server sorts at the add's place, so nothing
            // else is recorded: the registered member's predicted key is the draft's overlay.
            #expect(try fixture.newFacts(after: before).isEmpty)
            let draft = try #require(try fixture.drafts().last)
            #expect(try fixture.drafts().map(\.type) == ["queue.add"])
            // At the back, after the last episode before it its chain can name (a named gap).
            #expect(draft.template["payload"]?["place"]?["after"]?["episode_id"]?.stringValue == (try fixture.wireID(a[0])))
            let overlaid = try fixture.overlays(opID: draft.opID).filter { $0[2] == "queue_position" }.compactMap { $0[1] }
            #expect(overlaid.contains(try #require(try fixture.wireID(a[4]))))
            #expect(try fixture.queueOrderMatchesKeys())
        }
    }

    @Test func queueFactsSplitAtFiveHundredPlacements() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let registered = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched(count: 702))
            let ids = registered.feed.episodes.map(\.id).sorted()
            var before = try fixture.outboxCount()
            _ = try await store.enqueue(Array(ids.prefix(600)))
            var facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["queue.add", "queue.add"])
            #expect(facts.map { $0.payload["members"]?.arrayValue?.count } == [500, 100])
            // The second chunk follows the first: both at the end, as one add at the back would be.
            #expect(facts.map { $0.payload["place"] } == [["kind": "end"], ["kind": "end"]])
            store.setQueueInsertionSettings(.init(keepSortedOrder: .dateNewOld))
            before = try fixture.outboxCount()
            _ = try await store.enqueue([ids[600], ids[601]])
            facts = try fixture.newFacts(after: before)
            // Keep sorted: one add of its 2 members; the server sorts at its place, so no other member is sent.
            try #require(facts.map(\.type) == ["queue.add"])
            #expect(facts[0].payload["members"]?.arrayValue?.count == 2 && facts[0].payload["moves"] == nil)
            before = try fixture.outboxCount()
            _ = try await store.reorderQueue(.dateOldNew)
            facts = try fixture.newFacts(after: before)
            // The sort sheet is one command whatever the queue's length: the account's sort and what it observed.
            try #require(facts.map(\.type) == ["queue.reorder"])
            #expect(facts[0].payload["sort"] == ["sort_order": "date_old_new"])
            #expect(facts[0].payload["observed"]?.arrayValue?.count == 602)
            #expect(try fixture.queueOrderMatchesKeys())
            // A chunk after the first of a run inserted at the front follows the chunk before it.
            store.setQueueInsertionSettings(.init())
            _ = try await store.removeFromQueue(Array(ids.prefix(600)))
            before = try fixture.outboxCount()
            _ = try await store.enqueue(Array(ids.prefix(600)), location: .front)
            facts = try fixture.newFacts(after: before)
            try #require(facts.map(\.type) == ["queue.add", "queue.add"])
            #expect(facts[0].payload["place"] == ["kind": "start"])
            #expect(facts[1].payload["place"]?["after"]?["episode_id"]?.stringValue == (try fixture.wireID(ids[499])))
        }
    }

    // MARK: Causal order follows the person's actions across a registration's chain

    @Test func aFactAfterMaterializationDependsOnTheMaterializedDraft() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let feed = try await store.insert(ServerLibraryFixture.fetched())
            let id = feed.episodes[0].id
            try await store.setFavorite(episodeID: id, favorite: true)
            let draft = try #require(try fixture.drafts().first).opID
            let op = try fixture.registrationOp(feedID: feed.id)
            let ids = try fixture.created(op)
            try await store.resolveRegistration(opID: op, .init(podcastID: ids.podcast, generationID: ids.generation, mode: "created", decisionID: nil))
            try await store.favoriteForTesting(id, on: false, at: Date().addingTimeInterval(-60))
            let unfavorite = try #require(try fixture.outbox().last)
            #expect(unfavorite.type == "favorite.set" && unfavorite.json["author_id"]?.stringValue == fixture.identity.installID)
            #expect(unfavorite.dependencies.contains(draft))
        }
    }

    @Test func aFactOnAFeedWhoseRegistrationStillHoldsDraftsJoinsThatChain() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            // A preview registered by its first synced action (a draft), then subscribed while that registration is
            // pending: later facts about the podcast join the chain holding its drafts, in the person's order.
            let preview = try await store.preparePreview(ServerLibraryFixture.fetched(), now: ServerLibraryFixture.now)
            let ids = preview.episodes.map(\.id).sorted()
            try await store.setFavorite(episodeID: ids[0], favorite: true)
            let register = try fixture.registrationOp(feedID: preview.id)
            #expect(try await store.subscribePreview(feedID: preview.id))
            let subscribe = try fixture.registrationOp(feedID: preview.id)
            #expect(subscribe != register)
            try await store.markEpisodePlayed(episodeID: ids[0], played: true)
            #expect(try fixture.drafts().map(\.registration) == [register, register])
            // The subscription resolves first (it joins the preview's generation): the preview's chain still holds drafts.
            let created = try fixture.created(register)
            try await store.resolveRegistration(opID: subscribe, .init(podcastID: created.podcast, generationID: created.generation, mode: "joined", decisionID: nil))
            let before = try fixture.outboxCount()
            try await store.markEpisodePlayed(episodeID: ids[0], played: false)
            #expect(try fixture.outboxCount() == before)
            #expect(try fixture.drafts().map(\.type) == ["favorite.set", "episode.mark_played", "episode.mark_unplayed"])
            // Once it resolves, later facts go to the main author, after the last materialized one on the episode.
            try await store.resolveRegistration(opID: register, .init(podcastID: created.podcast, generationID: created.generation, mode: "created", decisionID: nil))
            #expect(try fixture.drafts().isEmpty)
            let materialized = try #require(try fixture.outbox().last { $0.type == "episode.mark_unplayed" })
            try await store.setFavorite(episodeID: ids[0], favorite: false)
            let last = try #require(try fixture.outbox().last)
            #expect(last.json["author_id"]?.stringValue == fixture.identity.installID)
            #expect(last.dependencies.contains(materialized.opID))
        }
    }

    // MARK: A removal and its Undo depend on what they remove or restore

    @Test func removeAndRestoreDependOnObservedQueueRecord() async throws {
        try await withFixture { fixture in
            let feed = try await fixture.subscribeRegistered().feed
            let id = feed.episodes[0].id
            _ = try await fixture.store.enqueue([id])
            let wire = try #require(try fixture.wireID(id))
            let remote = ContractIdentity.randomUUID()
            try await fixture.store.seedRecordForTesting(entity: "episode", id: wire, group: "queue_membership", provenance: [remote])
            let receipt = try #require(try await fixture.store.removeFromQueueWithUndo(id).receipt)
            #expect(try #require(try fixture.outbox().last).dependencies.contains(remote))
            _ = try await fixture.store.undoQueueRemoval(receipt)
            let restore = try #require(try fixture.outbox().last)
            #expect(restore.type == "queue.restore")
            #expect(restore.dependencies.contains(remote))
        }
    }

    @Test func aClearAndADownloadDeletionDependOnWhatTheyRemove() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let feed = try await fixture.subscribeRegistered().feed
            let ids = feed.episodes.map(\.id).sorted()
            _ = try await store.enqueue([ids[0], ids[1]])
            let remote = ContractIdentity.randomUUID()
            try await store.seedRecordForTesting(entity: "episode", id: try #require(try fixture.wireID(ids[1])), group: "queue_position", provenance: [remote])
            try await store.requestMediaDeletion(episodeID: ids[1], deleteRemovesFromQueue: true)
            #expect(try #require(try fixture.outbox().last).dependencies.contains(remote))
            let other = ContractIdentity.randomUUID()
            try await store.seedRecordForTesting(entity: "episode", id: try #require(try fixture.wireID(ids[0])), group: "queue_membership", provenance: [other])
            _ = try await store.clearQueue()
            let clear = try #require(try fixture.outbox().last)
            #expect(clear.type == "queue.clear" && clear.dependencies.contains(other))
        }
    }

    // MARK: A failed play load's queue add is owed durably and replayed

    @Test func failedPlayLoadQueueAddIsRetried() async throws {
        try await withFixture { fixture in
            let registered = try await fixture.subscribeRegistered()
            let ids = registered.feed.episodes.map(\.id).sorted()
            await fixture.store.injectRecorderFailure(after: 1)
            _ = try await fixture.store.beginPlayback(episodeID: ids[0])
            await fixture.store.injectRecorderFailure(after: nil)
            _ = try await fixture.store.beginPlayback(episodeID: ids[0])
            _ = try await fixture.store.enqueue([ids[1]])
            let expected = try fixture.expectedEpisodeID(podcast: registered.podcast, guid: "guid-1")
            let adds = try fixture.outbox().filter { $0.type == "queue.add" }
            #expect(adds.contains { $0.episodeIDs.contains(expected) })
            #expect(try fixture.rows("SELECT export_owed FROM ntp_library") == [["0"]])
            #expect(try fixture.rows("SELECT count(*) FROM ntp_owed") == [["0"]])
            #expect(try fixture.queueOrderMatchesKeys())
        }
    }

    @Test func anOwedQueueAddIsReplayedAtLaunchWithTheActionsTime() async throws {
        let fixture = try await ServerLibraryFixture()
        let registered = try await fixture.subscribeRegistered()
        let ids = registered.feed.episodes.map(\.id).sorted()
        _ = try await fixture.store.enqueue([ids[1]])
        await fixture.store.injectRecorderFailure(after: 1)
        _ = try await fixture.store.beginPlayback(episodeID: ids[0])
        try await fixture.store.close()
        // The process died; the next launch replays what is owed before anything else.
        let reopened = try FeedLibraryStore(url: fixture.url)
        try await reopened.replayOwedFacts()
        let add = try #require(try fixture.outbox().last)
        #expect(add.type == "queue.add")
        #expect(add.episodeIDs == [try fixture.expectedEpisodeID(podcast: registered.podcast, guid: "guid-1")])
        #expect(try fixture.rows("SELECT count(*) FROM ntp_owed") == [["0"]])
        #expect(try fixture.queueOrderMatchesKeys())
        // Replayed once only.
        try await reopened.replayOwedFacts()
        #expect(try fixture.outbox().filter { $0.type == "queue.add" }.count == 2)
        try await reopened.close()
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    // MARK: A subscription URL's userinfo becomes the credentials secret

    @Test func urlUserinfoBecomesASecret() async throws {
        try await withFixture { fixture in
            let preview = try await fixture.store.preparePreview(ServerLibraryFixture.fetched("https://alice:password@example.test/feed.xml"))
            _ = try await fixture.store.subscribePreview(feedID: preview.id)
            let fact = try #require(try fixture.outbox().last)
            #expect(fact.payload["feed_url"]?.stringValue == "https://example.test/feed.xml")
            let secret = try #require(fact.payload["credentials_secret"]?.stringValue)
            let row = try #require(try fixture.rows("SELECT credential_id, approved_origins FROM ntp_secrets WHERE secret_id = '\(secret)'").first)
            #expect(row[1] == "[\"https:\\/\\/example.test:443\"]")
            let value = try JSONDecoder().decode(FeedCredentials.self, from: Data(try fixture.vault.password(id: try #require(UUID(uuidString: row[0] ?? ""))).utf8))
            #expect(value == FeedCredentials(username: "alice", password: "password"))
            #expect(try fixture.rows("SELECT count(*) FROM feed_credential_cleanup") == [["0"]])
            // The feed itself is unchanged: its URL keeps the userinfo it is fetched with, and no stored credential.
            #expect(try await fixture.store.feed(id: preview.id)?.source == "https://alice:password@example.test/feed.xml")
            #expect(try await fixture.store.feedCredentialID(feedID: preview.id) == nil)
            #expect(try !fixture.rows("SELECT CAST(fact AS TEXT) FROM ntp_outbox").flatMap { $0 }.contains { $0?.contains("password") == true })
        }
    }

    @Test func percentEncodedUserinfoWinsOverAStoredCredentialAsFetchingUsesIt() async throws {
        try await withFixture { fixture in
            let authentication = FeedAuthentication(store: fixture.store, vault: fixture.vault)
            let preview = try await authentication.preparePreview(ServerLibraryFixture.fetched("https://b%40b:p%3As@example.test/feed.xml"),
                                                                  credentials: .init(username: "stored", password: "other"))
            _ = try await fixture.store.subscribePreview(feedID: preview.id)
            let secret = try #require(try fixture.outbox().last?.payload["credentials_secret"]?.stringValue)
            let credential = try #require(try fixture.rows("SELECT credential_id FROM ntp_secrets WHERE secret_id = '\(secret)'").first?.first ?? nil)
            let value = try JSONDecoder().decode(FeedCredentials.self, from: Data(try fixture.vault.password(id: try #require(UUID(uuidString: credential))).utf8))
            #expect(value == FeedCredentials(username: "b@b", password: "p:s"))
            // Without userinfo the stored credential is the secret, as before; a user without a password is no credential.
            let plain = try await authentication.preparePreview(ServerLibraryFixture.fetched("https://example.test/plain.xml", title: "Plain"),
                                                                credentials: .init(username: "stored", password: "other"))
            _ = try await fixture.store.subscribePreview(feedID: plain.id)
            let stored = try #require(try await fixture.store.feedCredentialID(feedID: plain.id))
            #expect(try fixture.rows("SELECT credential_id FROM ntp_secrets WHERE secret_id = '\(try #require(try fixture.outbox().last?.payload["credentials_secret"]?.stringValue))'") == [[stored.uuidString]])
            _ = try await fixture.store.insert(ServerLibraryFixture.fetched("https://nobody@example.test/user.xml", title: "User"))
            #expect(try fixture.outbox().last?.payload["credentials_secret"] == nil)
        }
    }

    @Test func aRolledBackSubscriptionLeavesItsStagedCredentialToCleanup() async throws {
        try await withFixture { fixture in
            await fixture.store.injectRecorderFailure(after: 1)
            await #expect(throws: ServerRecordingError.injectedFailure) {
                _ = try await fixture.store.insert(ServerLibraryFixture.fetched("https://alice:pw@example.test/feed.xml"))
            }
            await fixture.store.injectRecorderFailure(after: nil)
            let staged = try fixture.rows("SELECT credential_id FROM feed_credential_cleanup").compactMap { $0[0] }
            try #require(staged.count == 1)
            try await FeedAuthentication(store: fixture.store, vault: fixture.vault).recoverCredentialCleanup()
            #expect(!fixture.vault.contains(try #require(UUID(uuidString: staged[0]))))
            #expect(try fixture.rows("SELECT count(*) FROM feed_credential_cleanup") == [["0"]])
        }
    }
}

/// Owed work: recorded queue adds, replays and secrets.
@MainActor @Suite(.serialized) struct ServerRecordingOwedWorkTests {
    private func withFixture(_ body: (ServerLibraryFixture) async throws -> Void) async throws {
        let fixture = try await ServerLibraryFixture()
        do { try await body(fixture); await fixture.close() } catch { await fixture.close(); throw error }
    }

    // Since the queue replay, a keep-sorted add records no other author's members; the members its
    // sort re-keyed, pending chains' included, show their predicted keys as overlays of the add
    // (PROTOCOL §7.6).
    @Test func aRegisteredKeepSortedAddShowsAPendingPodcastsReSortedMembersByOverlays() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let two = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/two.xml", title: "Two", count: 3))
            let one = try await store.insert(ServerLibraryFixture.fetched("https://example.test/one.xml", title: "One", count: 5))
            let other = try await store.insert(ServerLibraryFixture.fetched("https://example.test/other.xml", title: "Other", count: 2))
            let a = one.episodes.map(\.id).sorted()
            _ = try await store.enqueue([a[4], a[0]])
            _ = try await store.enqueue([other.episodes.map(\.id).sorted()[1]])
            store.setQueueInsertionSettings(.init(keepSortedOrder: .episodeTitleAZ))
            let drafts = Set(try fixture.drafts().map(\.opID))
            _ = try await store.enqueue([two.feed.episodes.map(\.id).sorted()[0]])
            // Under Keep sorted no chain gets a placement snapshot: the sorted adds order the queue
            // at replay.
            #expect(try fixture.drafts().filter { !drafts.contains($0.opID) }.isEmpty, "no draft on another chain")
            let add = try #require(try fixture.outbox().last)
            #expect(add.type == "queue.add")
            let overlays = try fixture.overlays(opID: add.opID).filter { $0[2] == "queue_position" }
            // One 5 moved to the end: its predicted key is shown by its local placeholder until its chain resolves.
            let keys = try fixture.queueKeys()
            let moved = try #require(overlays.first { $0[1] == "local-episode:\(a[4])" }?[4] ?? nil)
            #expect(try ContractJSON.decode(Data(moved.utf8))["key"]?.stringValue == keys.first { $0.episode == a[4] }?.key.wire)
            #expect(try fixture.queueOrderMatchesKeys())
        }
    }

    // Owed facts are recorded before the next action changes anything.
    @Test func anOwedAddIsReplayedBeforeAnExplicitSortWhoseOwnKeysItRecords() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let ids = try await fixture.subscribeRegistered().feed.episodes.map(\.id).sorted()
            _ = try await store.enqueue([ids[3], ids[0]])
            await store.injectRecorderFailure(after: 1)
            _ = try await store.beginPlayback(episodeID: ids[2])
            await store.injectRecorderFailure(after: nil)
            let before = try fixture.outboxCount()
            _ = try await store.reorderQueue(.episodeTitleAZ)
            let facts = try fixture.newFacts(after: before)
            #expect(facts.map(\.type) == ["queue.add", "queue.reorder"])
            #expect(facts.first?.episodeIDs == [try #require(try fixture.wireID(ids[2]))])
            // The sort observed the queue with the owed add in it.
            #expect(facts.last?.episodeIDs == [ids[3], ids[0], ids[2]].compactMap { try? fixture.wireID($0) })
            #expect(try await store.queue().map(\.id) == [ids[0], ids[2], ids[3]])
            #expect(try fixture.queueOrderMatchesKeys())
        }
    }

    // Playback writes never replay owed facts; the debt waits for an eligible write, launch or the exchange.
    @Test func playbackSaveDoesNotDrainOwedJournal() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            // Behaviour, not size: a queue of a few is enough for keep-sorted to owe a reorder.
            let ids = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched(count: 6)).feed.episodes.map(\.id).sorted()
            _ = try await store.enqueue(Array(ids.prefix(4)))
            store.setQueueInsertionSettings(.init(keepSortedOrder: .dateNewOld))
            let id = ids[4]
            await store.injectRecorderFailure(after: 1)
            let session = try await store.beginPlayback(episodeID: id)
            await store.injectRecorderFailure(after: nil)
            let count = try fixture.outboxCount()
            // The add, and the placements of the members it re-sorted.
            let owed = try fixture.rows("SELECT intent, subject FROM ntp_owed ORDER BY intent, subject")
            #expect(owed.filter { $0[0] == "queue.add" } == [["queue.add", "episode:\(id)"]])
            let sample = PlaybackSample(positionMilliseconds: 1_000, durationMilliseconds: 600_000, status: .playing)
            for _ in 0..<3 { _ = try await store.recordPlayback(sessionID: session.id, sample: sample) }
            #expect(try fixture.outboxCount() == count, "a playback save must not replay owed facts")
            #expect(try fixture.rows("SELECT intent, subject FROM ntp_owed ORDER BY intent, subject") == owed)
            #expect(try await store.episode(id: id)?.userState.positionMilliseconds == 1_000)
            // The next eligible write pays the debt.
            try await store.replayOwedFacts()
            #expect(try fixture.rows("SELECT count(*) FROM ntp_owed") == [["0"]])
        }
    }

    @Test func aPlayLoadAndAnEndLeaveTheDebtToTheNextEligibleWrite() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let ids = try await fixture.subscribeRegistered().feed.episodes.map(\.id).sorted()
            await store.injectRecorderFailure(after: 1)
            let session = try await store.beginPlayback(episodeID: ids[0])
            await store.injectRecorderFailure(after: nil)
            _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 5_000, durationMilliseconds: 600_000, status: .paused), synchronize: true)
            _ = try await store.endPlayback(sessionID: session.id, reason: .switched)
            _ = try await store.beginPlayback(episodeID: ids[1])
            #expect(try fixture.rows("SELECT subject FROM ntp_owed") == [["episode:\(ids[0])"]])
            let wire = try fixture.wireID(ids[0]) ?? "-"
            #expect(try !fixture.outbox().contains { $0.episodeIDs.contains(wire) && $0.type == "queue.add" })
            try await store.setFavorite(episodeID: ids[2], favorite: true)
            #expect(try fixture.rows("SELECT count(*) FROM ntp_owed") == [["0"]])
            let replayed = try fixture.wireID(ids[0]) ?? "-"
            #expect(try fixture.outbox().contains { $0.type == "queue.add" && $0.episodeIDs.contains(replayed) })
        }
    }
    @Test func removedOwedItemIsNotReplayedAndUndoIsNotDuplicated() async throws {
        try await withFixture { f in
            let id = try await f.subscribeRegistered().feed.episodes[0].id
            await f.store.injectRecorderFailure(after: 1)
            _ = try await f.store.beginPlayback(episodeID: id)
            await f.store.injectRecorderFailure(after: nil)
            // The owed add is recorded before the removal changes anything, so the server sees what the person
            // did: the play load queued it, then it was removed.
            let receipt = try #require(try await f.store.removeFromQueueWithUndo(id).receipt)
            #expect(try f.rows("SELECT count(*) FROM ntp_owed") == [["0"]])
            #expect(try f.outbox().map(\.type).suffix(2) == ["queue.add", "queue.remove"])
            _ = try await f.store.undoQueueRemoval(receipt)
            try await f.store.replayOwedFacts()
            #expect(try f.outbox().filter { $0.type == "queue.restore" }.count == 1)
            #expect(try f.outbox().filter { $0.type == "queue.add" }.count == 1)
        }
    }

    @Test func retainedURLSecretsAreEnumeratedAndDiscarded() async throws {
        try await withFixture { f in
            _ = try await f.store.insert(ServerLibraryFixture.fetched("https://alice:pw@example.test/feed.xml"))
            let all = try await f.store.allFeedCredentialIDs()
            try #require(all.count == 1)
            #expect(f.vault.contains(all[0]))
            try await FeedAuthentication(store: f.store, vault: f.vault).discardAllCredentials()
            #expect(!f.vault.contains(all[0]))
            #expect(try f.rows("SELECT count(*) FROM ntp_secrets") == [["0"]])
        }
    }

    @Test func partialRemovalAndUndoRetainAllObservedProvenance() async throws {
        try await withFixture { f in
            let ids = try await f.subscribeRegistered().feed.episodes.map(\.id).sorted()
            _ = try await f.store.enqueue(Array(ids.prefix(3)))
            var nodes: [String] = []
            for id in ids.prefix(3) {
                let node = ContractIdentity.randomUUID()
                nodes.append(node)
                try await f.store.seedRecordForTesting(entity: "episode", id: try #require(try f.wireID(id)), group: "queue_membership", provenance: [node])
            }
            let receipt = try #require(try await f.store.removeFromQueueWithUndo(ids[1]).receipt)
            #expect(Set(try #require(try f.outbox().last).dependencies).isSuperset(of: nodes))
            _ = try await f.store.undoQueueRemoval(receipt)
            #expect(Set(try #require(try f.outbox().last).dependencies).isSuperset(of: nodes))
            #expect(try await f.store.queue().map(\.id) == Array(ids.prefix(3)))
        }
    }

    @Test func replayFailuresRemainAtomicAndExactlyOnce() async throws {
        for threshold in [1, 5, 15, 25, 50] {
            let f = try await ServerLibraryFixture()
            let id = try await f.subscribeRegistered().feed.episodes[0].id
            await f.store.injectRecorderFailure(after: 1)
            _ = try await f.store.beginPlayback(episodeID: id)
            await f.store.injectRecorderFailure(after: threshold)
            try await f.store.replayOwedFacts()
            let remains = try f.rows("SELECT count(*) FROM ntp_owed") == [["1"]]
            #expect(try f.outbox().filter { $0.type == "queue.add" }.count == (remains ? 0 : 1))
            await f.store.injectRecorderFailure(after: nil)
            try await f.store.replayOwedFacts()
            try await f.store.replayOwedFacts()
            #expect(try f.outbox().filter { $0.type == "queue.add" }.count == 1)
            #expect(try f.rows("SELECT count(*) FROM ntp_owed") == [["0"]])
            await f.close()
        }
    }
}

extension FeedLibraryStore {
    /// A favorite change at a given action time (a slow phone clock: the seam takes the action's clock).
    func favoriteForTesting(_ id: Int64, on: Bool, at: Date) throws {
        try write(.registers, now: at) {
            guard var episode = try loadEpisode(id) else { return }
            episode.userState.isFavorite = on
            try saveEpisode(episode, feedID: feedID(forEpisode: id))
        }
    }

    /// A base record with the given provenance, as the applier keeps them.
    func seedRecordForTesting(entity: String, id: String, group: String, provenance: [String]) throws {
        try database.execute("INSERT OR REPLACE INTO ntp_records(entity, id, field_group, value, provenance) VALUES (?, ?, ?, NULL, ?)",
                             [.text(entity), .text(id), .text(group), .text(try ContractJSON.array(provenance.map(ContractJSON.string)).canonicalString())])
    }
}
