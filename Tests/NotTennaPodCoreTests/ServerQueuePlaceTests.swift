import Foundation
import Testing
@testable import NotTennaPodCore

/// The phone's side of the queue replay (PROTOCOL §7.6): every placement resolves Android 3.12.1's location
/// into `place` as it executes (PROTOCOL §15.4, `ItemEnqueuePositionCalculator`, `RemoveFromQueueSwipeAction`), moves carry the
/// complete run and the sort sheet its order and what it observed (PROTOCOL §15.4), and the device's own prediction inserts at
/// the place first, then sorts. Host tests of the recorder; the server's agreement is `ServerQueueReplayAgreementTests`.
@Suite(.serialized) struct ServerQueuePlaceTests {
    private func withFixture(_ body: (ServerLibraryFixture) async throws -> Void) async throws {
        let fixture = try await ServerLibraryFixture()
        do { try await body(fixture); await fixture.close() } catch { await fixture.close(); throw error }
    }

    enum Place: Equatable, CustomStringConvertible {
        case start, end, after(Int64)
        var description: String {
            switch self { case .start: "start"; case .end: "end"; case .after(let id): "after \(id)" }
        }
    }

    /// The place a fact or draft template names, its anchor as a local episode.
    private func place(_ payload: ContractJSON?, _ fixture: ServerLibraryFixture) throws -> Place? {
        guard let place = payload?["place"] else { return nil }
        switch place["kind"]?.stringValue {
        case "start": return .start
        case "end": return .end
        case "after":
            if let local = place["after"]?["ntp_local_episode"]?.integerValue { return .after(local) }
            guard let wire = place["after"]?["episode_id"]?.stringValue,
                  let local = try fixture.rows("SELECT local_id FROM ntp_episodes WHERE episode_id = '\(wire)'").first?.first ?? nil else { return nil }
            #expect(place["after"]?["podcast_id"] != nil && place["after"]?["generation_id"] != nil && place["after"]?["occurrence"] != nil,
                    "an anchor is a complete EpisodeRef")
            return .after(Int64(local)!)
        default: return nil
        }
    }

    private func lastFact(_ fixture: ServerLibraryFixture, after count: Int) throws -> ServerLibraryFixture.Fact {
        let facts = try fixture.newFacts(after: count)
        try #require(facts.count == 1, "one fact, got \(facts.map(\.type))")
        return facts[0]
    }

    private func mediaURL(_ store: FeedLibraryStore, _ id: Int64) async throws -> String {
        try #require(try await store.episode(id: id)?.details.media?.url)
    }

    // MARK: Adds (PROTOCOL §15.4)

    @Test func backIsTheEndAndFrontFollowsTheConsecutiveDownloadingRunAtTheHead() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let ids = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched(count: 8)).feed.episodes.map(\.id).sorted()
            var before = try fixture.outboxCount()
            _ = try await store.enqueue(Array(ids[0...3]))
            #expect(try place(try lastFact(fixture, after: before).payload, fixture) == .end)
            // Head [0, 1] downloading, 3 downloading after a gap: front goes after 1, the last of the head's run only.
            let downloading = Set([try await mediaURL(store, ids[0]), try await mediaURL(store, ids[1]), try await mediaURL(store, ids[3])])
            before = try fixture.outboxCount()
            _ = try await store.enqueue([ids[4], ids[5]], location: .front, downloadingURLs: downloading)
            let fact = try lastFact(fixture, after: before)
            #expect(try place(fact.payload, fixture) == .after(ids[1]))
            #expect(fact.episodeIDs == [ids[4], ids[5]].compactMap { try? fixture.wireID($0) }, "members in their requested order")
            #expect(try await store.queue().map(\.id) == [ids[0], ids[1], ids[4], ids[5], ids[2], ids[3]])
            // Nothing downloading: the very start.
            before = try fixture.outboxCount()
            _ = try await store.enqueue([ids[6]], location: .front)
            #expect(try place(try lastFact(fixture, after: before).payload, fixture) == .start)
            // Everything downloading: after the last episode, never `end`.
            let all = Set(try await store.queue().compactMap(\.details.media?.url))
            before = try fixture.outboxCount()
            _ = try await store.enqueue([ids[7]], location: .front, downloadingURLs: all)
            #expect(try place(try lastFact(fixture, after: before).payload, fixture) == .after(ids[3]))
            #expect(try fixture.queueOrderMatchesKeys())
        }
    }

    @Test func afterCurrentPassesTheDownloadingRunThatFollowsTheCurrentEpisode() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let ids = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched(count: 8)).feed.episodes.map(\.id).sorted()
            _ = try await store.enqueue(Array(ids[0...3]))
            let downloading = Set([try await mediaURL(store, ids[2]), try await mediaURL(store, ids[0])])
            var before = try fixture.outboxCount()
            _ = try await store.enqueue([ids[4]], location: .afterCurrentlyPlaying, playing: .episode(ids[1]), downloadingURLs: downloading)
            #expect(try place(try lastFact(fixture, after: before).payload, fixture) == .after(ids[2]))
            #expect(try await store.queue().map(\.id) == [ids[0], ids[1], ids[2], ids[4], ids[3]])
            // The current episode is not queued: the front scan from index 0 (past the downloading head).
            before = try fixture.outboxCount()
            _ = try await store.enqueue([ids[5]], location: .afterCurrentlyPlaying, playing: .episode(ids[7]), downloadingURLs: downloading)
            #expect(try place(try lastFact(fixture, after: before).payload, fixture) == .after(ids[0]))
            before = try fixture.outboxCount()
            _ = try await store.enqueue([ids[6]], location: .afterCurrentlyPlaying, playing: nil)
            #expect(try place(try lastFact(fixture, after: before).payload, fixture) == .start)
            // The current episode is the last: after it.
            before = try fixture.outboxCount()
            _ = try await store.enqueue([ids[7]], location: .afterCurrentlyPlaying, playing: .episode(ids[3]))
            #expect(try place(try lastFact(fixture, after: before).payload, fixture) == .after(ids[3]))
            #expect(try fixture.queueOrderMatchesKeys())
        }
    }

    @Test func aRandomIndexIsStartOrAfterTheEpisodeBeforeItAndTheTailIsAfterTheLast() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let ids = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched(count: 6)).feed.episodes.map(\.id).sorted()
            _ = try await store.enqueue(Array(ids[0...2]))
            for (id, index, expected) in [(ids[3], 0, Place.start), (ids[4], 2, .after(ids[0])), (ids[5], 5, .after(ids[2]))] {
                let before = try fixture.outboxCount()
                _ = try await store.enqueue([id], location: .random, randomIndex: { _ in index })
                #expect(try place(try lastFact(fixture, after: before).payload, fixture) == expected, "random index \(index)")
            }
            #expect(try await store.queue().map(\.id) == [ids[3], ids[0], ids[4], ids[1], ids[2], ids[5]])
        }
    }

    @Test func enqueueDownloadedAndAPlayLoadAddAtTheirLocation() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let ids = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched(count: 6)).feed.episodes.map(\.id).sorted()
            _ = try await store.enqueue(Array(ids[0...2]))
            var before = try fixture.outboxCount()
            _ = try await store.requestDownload(episodeID: ids[3], directory: fixture.directory, enqueue: true, location: .front)
            #expect(try place(try fixture.newFacts(after: before).first { $0.type == "queue.add" }?.payload, fixture) == .start)
            before = try fixture.outboxCount()
            _ = try await store.requestDownload(episodeID: ids[4], directory: fixture.directory, enqueue: true,
                                                location: .afterCurrentlyPlaying, playing: .episode(ids[0]))
            // ids[3]'s download is running, but it is not after the current episode's position.
            #expect(try place(try fixture.newFacts(after: before).first { $0.type == "queue.add" }?.payload, fixture) == .after(ids[0]))
            before = try fixture.outboxCount()
            _ = try await store.beginPlayback(episodeID: ids[5])
            #expect(try place(try fixture.newFacts(after: before).first { $0.type == "queue.add" }?.payload, fixture) == .end)
        }
    }

    @Test func anAddUnderKeepSortedInsertsAtItsPlaceThenSorts() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let ids = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched(count: 4)).feed.episodes.map(\.id).sorted()
            _ = try await store.enqueue([ids[2], ids[0]])
            store.setQueueInsertionSettings(.init(location: .front, keepSortedOrder: .episodeTitleAZ))
            let before = try fixture.outboxCount()
            _ = try await store.enqueueUsingSettings([ids[1]])
            let fact = try lastFact(fixture, after: before)
            // Android inserts at the location (the front), then sorts: the place is where it was inserted.
            #expect(try place(fact.payload, fixture) == .start)
            #expect(try await store.queue().map(\.id) == [ids[0], ids[1], ids[2]])
            // An episode already queued is not added again, so nothing is placed or sorted.
            let count = try fixture.outboxCount()
            _ = try await store.enqueue([ids[2]])
            #expect(try fixture.outboxCount() == count)
            #expect(try fixture.queueOrderMatchesKeys())
        }
    }

    // MARK: Undo (PROTOCOL §15.4)

    @Test func undoRestoresAtTheSavedIndexResolvedAgainstTheQueueAtUndoTime() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let ids = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched(count: 6)).feed.episodes.map(\.id).sorted()
            _ = try await store.enqueue(Array(ids[0...3]))
            // A front add after the removal: Undo inserts at index 2 of the queue it finds (addQueueItemAt).
            var receipt = try #require(try await store.removeFromQueueWithUndo(ids[2]).receipt)
            _ = try await store.enqueue([ids[4]], location: .front)
            var before = try fixture.outboxCount()
            #expect(try await store.undoQueueRemoval(receipt).status == .restored)
            var fact = try lastFact(fixture, after: before)
            #expect(fact.type == "queue.restore")
            #expect(try place(fact.payload, fixture) == .after(ids[0]))
            #expect(try await store.queue().map(\.id) == [ids[4], ids[0], ids[2], ids[1], ids[3]])
            // The queue shrank below the saved index: clamped to its length, so after its last episode.
            receipt = try #require(try await store.removeFromQueueWithUndo(ids[3]).receipt)
            _ = try await store.removeFromQueue([ids[4], ids[0], ids[2]])
            before = try fixture.outboxCount()
            #expect(try await store.undoQueueRemoval(receipt).status == .restored)
            fact = try lastFact(fixture, after: before)
            #expect(try place(fact.payload, fixture) == .after(ids[1]))
            // Index 0: the start.
            receipt = try #require(try await store.removeFromQueueWithUndo(ids[1]).receipt)
            before = try fixture.outboxCount()
            #expect(try await store.undoQueueRemoval(receipt).status == .restored)
            #expect(try place(try lastFact(fixture, after: before).payload, fixture) == .start)
            #expect(try fixture.queueOrderMatchesKeys())
        }
    }

    // MARK: Moves (PROTOCOL §15.4)

    @Test func movesCarryTheirPlaceAndMultiItemMovesTheCompleteRun() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let ids = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched(count: 5)).feed.episodes.map(\.id).sorted()
            _ = try await store.enqueue(ids)
            func expected() async throws -> [QueueEpisodeIdentity] { try await store.queue().map(QueueEpisodeIdentity.init) }
            // A drag: after the episode now before it.
            var before = try fixture.outboxCount()
            _ = try await store.performQueueMove(.item(ids[0], finalIndex: 2), expected: try await expected())
            var fact = try lastFact(fixture, after: before)
            #expect(fact.type == "queue.move")
            #expect(try place(fact.payload, fixture) == .after(ids[2]))
            #expect(fact.payload["key"]?.stringValue == (try fixture.queueKeys().first { $0.episode == ids[0] }?.key.wire))
            // A drag to the last row: the end. To the first: the start.
            before = try fixture.outboxCount()
            _ = try await store.performQueueMove(.item(ids[1], finalIndex: 4), expected: try await expected())
            #expect(try place(try lastFact(fixture, after: before).payload, fixture) == .end)
            before = try fixture.outboxCount()
            _ = try await store.performQueueMove(.item(ids[1], finalIndex: 0), expected: try await expected())
            #expect(try place(try lastFact(fixture, after: before).payload, fixture) == .start)
            // Move to top and Move to bottom from the menu: one-member runs.
            before = try fixture.outboxCount()
            _ = try await store.performQueueMove(.boundary([ids[3]], .top), expected: try await expected())
            fact = try lastFact(fixture, after: before)
            #expect(fact.type == "queue.reorder")
            #expect(fact.payload["run"]?.arrayValue?.compactMap { $0["episode_id"]?.stringValue } == [try #require(try fixture.wireID(ids[3]))])
            #expect(try place(fact.payload, fixture) == .start)
            before = try fixture.outboxCount()
            _ = try await store.performQueueMove(.boundary([ids[3]], .bottom), expected: try await expected())
            #expect(try place(try lastFact(fixture, after: before).payload, fixture) == .end)
            // Multi-select: the complete selected run in its resulting order, with the device's key predictions.
            let order = try await store.queue().map(\.id)
            before = try fixture.outboxCount()
            _ = try await store.performQueueMove(.boundary([order[3], order[1]], .top), expected: try await expected())
            fact = try lastFact(fixture, after: before)
            let run = [order[1], order[3]].compactMap { try? fixture.wireID($0) }
            #expect(fact.payload["run"]?.arrayValue?.compactMap { $0["episode_id"]?.stringValue } == run)
            #expect(try place(fact.payload, fixture) == .start)
            let keys = try fixture.queueKeys()
            #expect(fact.payload["members"]?.arrayValue?.map { $0["key"]?.stringValue } == [order[1], order[3]].map { id in keys.first { $0.episode == id }?.key.wire })
            #expect(try fixture.queueOrderMatchesKeys())
        }
    }

    // MARK: The sort sheet (PROTOCOL §15.4)

    @Test func theSortSheetIsSentEvenWhenItChangesNothingAndARandomSortCarriesItsPermutation() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let ids = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched(count: 4)).feed.episodes.map(\.id).sorted()
            // Already in title order: nothing changes here, yet the sort is sent (another phone's unseen add can make it
            // matter), with no position overlay.
            _ = try await store.enqueue(Array(ids[0...2]))
            var before = try fixture.outboxCount()
            _ = try await store.reorderQueue(.episodeTitleAZ)
            var fact = try lastFact(fixture, after: before)
            #expect(fact.type == "queue.reorder")
            #expect(fact.payload["sort"] == ["sort_order": "episode_title_a_z"])
            #expect(fact.episodeIDs == ids[0...2].compactMap { try? fixture.wireID($0) })
            #expect(try fixture.overlays(opID: fact.opID).isEmpty)
            // Random: the device's resulting order of what it observed.
            before = try fixture.outboxCount()
            _ = try await store.reorderQueue(.random, shuffle: { $0.reverse() })
            fact = try lastFact(fixture, after: before)
            #expect(fact.payload["sort"]?["sort_order"] == "random")
            #expect(fact.payload["sort"]?["permutation"]?.arrayValue?.compactMap { $0["episode_id"]?.stringValue }
                    == [ids[2], ids[1], ids[0]].compactMap { try? fixture.wireID($0) })
            #expect(fact.episodeIDs == ids[0...2].compactMap { try? fixture.wireID($0) })
            #expect(try fixture.overlays(opID: fact.opID).filter { $0[2] == "queue_position" }.count >= 2, "the re-keyed members' keys are shown")
            // An empty queue: an empty observed list is valid.
            _ = try await store.clearQueue()
            before = try fixture.outboxCount()
            _ = try await store.reorderQueue(.durationShortLong)
            fact = try lastFact(fixture, after: before)
            #expect(fact.payload["observed"] == [])
            #expect(fact.payload["sort"] == ["sort_order": "duration_short_long"])
        }
    }

    // MARK: Sort values (PROTOCOL §7.6)

    @Test func aServerLibrarySortsByTheServersDurationsNeverAnUnexportedMeasurement() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let (feed, _, generation, wire) = try await ServerProjectionUnitTests.registered(fixture)
            let ids = feed.episodes.map(\.id).sorted()
            // Every feed duration here is 600,000, but the server's catalog has none of these episodes but ids[3], for
            // which it says 300,000 (this phone keeps its stored 600,000). The server measured ids[2] at 30,000; this
            // phone's player measured ids[1] at 60,000, not exported yet.
            let applier = try await ServerProjectionUnitTests.Applier(fixture)
            let url = try #require(try await store.episode(id: ids[3])?.details.media?.url)
            try await applier.apply([
                ServerRecord(entity: "episode", id: wire[2], fieldGroup: "measured_duration",
                             value: ["generation_id": .string(generation), "duration_ms": 30_000]),
                ServerRecord(entity: "episode", id: wire[3], fieldGroup: "metadata",
                             value: ["title": "Episode 4", "media": ["url": .string(url), "duration": 300_000]]),
            ])
            #expect(try await store.episode(id: ids[3])?.details.media?.durationMilliseconds == 600_000)
            try await store.projectForTesting(ids[1]) {
                $0.details.media?.durationMilliseconds = 60_000
                $0.userState.lastPlayedTimeMilliseconds = 1_760_000_000_000
            }
            _ = try await store.enqueue(ids)
            _ = try await store.reorderQueue(.durationShortLong)
            // ids[0] and ids[1] have no duration the server knows (none: tied, in queue order), ids[2] the measured
            // 30,000, ids[3] the catalog's 300,000.
            #expect(try await store.queue().map(\.id) == [ids[0], ids[1], ids[2], ids[3]])
        }
    }

    /// A local-folder episode never reaches the server, so it keeps its media
    /// duration in a server library's sorts, played or not, as in a standalone library.
    @Test(arguments: [true, false]) func localFolderEpisodesSortByTheirOwnDuration(server: Bool) async throws {
        let fixture = try await ServerLibraryFixture(server: server)
        do {
            let store = fixture.store
            let context = try await store.registerLocalFolder(title: "Folder", directoryIdentity: "folder-1", bookmark: Data([1]))
            let episodes = [ParsedEpisode(identifier: "long.mp3", title: "Long", media: ParsedMedia(url: "long.mp3", size: 10, durationMilliseconds: 600_000)),
                            ParsedEpisode(identifier: "short.mp3", title: "Short", media: ParsedMedia(url: "short.mp3", size: 10, durationMilliseconds: 60_000))]
            _ = try await store.applyLocalFolderScan(ParsedFeed(format: .rss, title: "Folder", episodes: episodes), context: context)
            let ids = try #require(try await store.feed(id: context.feed.id)).episodes.map(\.id).sorted()
            _ = try await store.enqueue(ids)
            let playback = try await store.beginPlayback(episodeID: ids[0])
            _ = try await store.recordPlayback(sessionID: playback.id, sample: .init(positionMilliseconds: 1_000, durationMilliseconds: 600_000, status: .playing))
            _ = try await store.reorderQueue(.durationShortLong)
            #expect(try await store.queue().map(\.id) == Array(ids.reversed()), "server library \(server)")
            await fixture.close()
        } catch { await fixture.close(); throw error }
    }

    // MARK: Mixed local queues (PROTOCOL §15.4, §7.6)

    /// A local folder with one episode; returns its local episode ID.
    private func localEpisode(_ store: FeedLibraryStore) async throws -> Int64 {
        let context = try await store.registerLocalFolder(title: "Folder", directoryIdentity: "folder-1", bookmark: Data([1]))
        let scan = ParsedFeed(format: .rss, title: "Folder", episodes: [
            ParsedEpisode(identifier: "l.mp3", title: "L", publicationDate: ServerLibraryFixture.now, media: ParsedMedia(url: "l.mp3", size: 10))])
        _ = try await store.applyLocalFolderScan(scan, context: context)
        return try #require(try await store.feed(id: context.feed.id)?.episodes.first?.id)
    }

    @Test func anInsertionBesideALocalEntryIsProjectedAndTheLocalEntryKeepsItsPlaceAfterAPulledCommit() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let (feed, _, generation, wire) = try await ServerProjectionUnitTests.registered(fixture)
            let ids = feed.episodes.map(\.id).sorted()
            let l = try await localEpisode(store)
            let (a, b, x) = (ids[0], ids[1], ids[2])
            _ = try await store.enqueue([a, l, b])
            try await store.retireEverythingForTesting()
            // X inserted right after L (index 2): a gap next to a local entry is `after` the synced episode before it.
            let before = try fixture.outboxCount()
            _ = try await store.enqueue([x], location: .random, randomIndex: { _ in 2 })
            let fact = try lastFact(fixture, after: before)
            #expect(try place(fact.payload, fixture) == .after(a))
            #expect(try await store.queue().map(\.id) == [a, l, x, b])
            // In the same transaction, L's anchors were rewritten from the resulting queue: next X, previous A.
            #expect(try fixture.rows("SELECT next_anchor, previous_anchor FROM ntp_queue_keys WHERE episode_id = \(l)") == [["\(x)", "\(a)"]])
            // A pulled commit while X's add is pending: the queue is projected again from the base and X's overlay.
            let applier = try await ServerProjectionUnitTests.Applier(fixture)
            let keys = try fixture.queueKeys()
            func key(_ id: Int64) -> QueueKey { keys.first { $0.episode == id }!.key }
            try await applier.apply([ServerProjectionUnitTests.position(wire[0], generation, key(a)),
                                     ServerProjectionUnitTests.membership(wire[0], generation, true)])
            #expect(try await store.queue().map(\.id) == [a, l, x, b])
            // The server accepted X `after A` with a key of its own, below L's: L still stands before X, its next anchor.
            try await store.retireEverythingForTesting()
            let serverKey = try QueueKey.between(key(a), key(l), positionWriteID: UUID())
            try await applier.apply([ServerProjectionUnitTests.position(wire[2], generation, serverKey),
                                     ServerProjectionUnitTests.membership(wire[2], generation, true),
                                     ServerProjectionUnitTests.position(wire[1], generation, key(b)),
                                     ServerProjectionUnitTests.membership(wire[1], generation, true)])
            #expect(try await store.queue().map(\.id) == [a, l, x, b])
            #expect(try fixture.queueOrderMatchesKeys())
        }
    }

    @Test func gapsBesideLocalEntriesAreProjectedOntoSyncedNeighbours() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let ids = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched(count: 5)).feed.episodes.map(\.id).sorted()
            let l = try await localEpisode(store)
            _ = try await store.enqueue([l, ids[0], ids[1]])
            // At the very front, before the local entry: the start. After the local entry with nothing synced before it:
            // the start too.
            var before = try fixture.outboxCount()
            _ = try await store.enqueue([ids[2]], location: .random, randomIndex: { _ in 1 })
            #expect(try place(try lastFact(fixture, after: before).payload, fixture) == .start)
            #expect(try await store.queue().map(\.id) == [l, ids[2], ids[0], ids[1]])
            // A drag to just after the local entry, with nothing synced before: the start.
            before = try fixture.outboxCount()
            _ = try await store.performQueueMove(.item(ids[1], finalIndex: 1), expected: try await store.queue().map(QueueEpisodeIdentity.init))
            #expect(try place(try lastFact(fixture, after: before).payload, fixture) == .start)
            // Move to bottom past a local tail: nothing synced after it, so the end.
            _ = try await store.performQueueMove(.item(l, finalIndex: 3), expected: try await store.queue().map(QueueEpisodeIdentity.init))
            #expect(try await store.queue().map(\.id) == [ids[1], ids[2], ids[0], l])
            before = try fixture.outboxCount()
            _ = try await store.performQueueMove(.item(ids[1], finalIndex: 2), expected: try await store.queue().map(QueueEpisodeIdentity.init))
            #expect(try await store.queue().map(\.id) == [ids[2], ids[0], ids[1], l])
            #expect(try place(try lastFact(fixture, after: before).payload, fixture) == .end)
            // Dragging the local entry changes only its anchors: nothing is recorded.
            before = try fixture.outboxCount()
            _ = try await store.performQueueMove(.item(l, finalIndex: 0), expected: try await store.queue().map(QueueEpisodeIdentity.init))
            #expect(try fixture.outboxCount() == before)
            #expect(try fixture.queueOrderMatchesKeys())
        }
    }

    @Test func aPendingRegistrationsEpisodeAnchorsOnlyItsOwnChain() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let registered = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/one.xml", title: "One", count: 4))
            let r = registered.feed.episodes.map(\.id).sorted()
            let pending = try await store.insert(ServerLibraryFixture.fetched("https://example.test/p.xml", title: "Pending", count: 3))
            let p = pending.episodes.map(\.id).sorted()
            _ = try await store.enqueue([r[0], p[0]])
            // A registered episode at the tail, after the pending one: the main author cannot name it, so after r[0].
            let before = try fixture.outboxCount()
            _ = try await store.enqueue([r[1]], location: .random, randomIndex: { _ in 2 })
            #expect(try place(try lastFact(fixture, after: before).payload, fixture) == .after(r[0]))
            // The pending podcast's next episode, on its chain, after its own placeholder. (A placement snapshot of the
            // chain may be renumbered around the adds: they are found by the episode they add.)
            func add(of id: Int64) throws -> ServerLibraryFixture.Draft? {
                try fixture.drafts().first { draft in
                    draft.type == "queue.add" && draft.template["payload"]?["members"]?.arrayValue?
                        .contains { $0["episode"]?["ntp_local_episode"]?.integerValue == id } == true
                }
            }
            _ = try await store.enqueue([p[1]], location: .random, randomIndex: { _ in 2 })
            #expect(try place(try #require(try add(of: p[1])).template["payload"], fixture) == .after(p[0]))
            // One add naming both: each author's fact at its own place; the pending member follows the registered one.
            let factCount = try fixture.outboxCount()
            _ = try await store.enqueue([r[2], p[2]], location: .front)
            #expect(try place(try lastFact(fixture, after: factCount).payload, fixture) == .start)
            #expect(try place(try #require(try add(of: p[2])).template["payload"], fixture) == .after(r[2]))
            #expect(try await store.queue().map(\.id) == [r[2], p[2], r[0], p[0], p[1], r[1]])
        }
    }

    // MARK: Mixed batches with a pending registration

    @Test func aMixedBatchKeepsItsInterleavingWithAPendingRegistration() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let r = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/one.xml", title: "One", count: 4))
                .feed.episodes.map(\.id).sorted()
            let p = try await store.insert(ServerLibraryFixture.fetched("https://example.test/p.xml", title: "Pending", count: 4)).episodes.map(\.id).sorted()
            func check(_ location: EnqueueLocation, _ batch: [Int64], main expected: Place, drafts: [Place]) async throws {
                let facts = try fixture.outboxCount(), drafted = try fixture.drafts().count
                _ = try await store.enqueue(batch, location: location)
                let added = try fixture.newFacts(after: facts)
                try #require(added.count == 1, "\(location): one main-author add, got \(added.map(\.type))")
                #expect(try place(added[0].payload, fixture) == expected, "\(location): main")
                let runs = try fixture.drafts().dropFirst(drafted)
                #expect(try runs.map { try place($0.template["payload"], fixture) } == drafts.map { Optional($0) }, "\(location): drafts")
                // The drafts depend on the batch's main-author add.
                for draft in runs {
                    #expect((try fixture.rows("SELECT dependencies FROM ntp_drafts WHERE op_id = '\(draft.opID)'").first?.first ?? nil)?
                        .contains(added[0].opID) == true, "\(location): a draft depends on the main-author add")
                }
            }
            // [R1, P1, R2, P2] at the back: R1 and R2 at the end, P1 into its gap after R1, P2 into its gap after R2
            // (the trailing piece keeps its named gap).
            try await check(.back, [r[0], p[0], r[1], p[1]], main: .end, drafts: [.after(r[0]), .after(r[1])])
            _ = try await store.clearQueue()
            // At the front: R1 and R2 at the start, P1 after R1, P2 after R2.
            try await check(.front, [r[2], p[2], r[3], p[3]], main: .start, drafts: [.after(r[2]), .after(r[3])])
            #expect(try await store.queue().map(\.id) == [r[2], p[2], r[3], p[3]])
        }
    }

    /// Within one add, Undo or move, every draft a pending registration's runs get depends on all of the action's
    /// main-author facts (PROTOCOL §15.2): the action replays as this phone executed it, whatever the time of the
    /// registration the drafts also depend on. The add and the move name more registered episodes than one fact holds
    /// (500), so each has two main-author facts; a pending episode queued earlier is placed again by a snapshot.
    @Test(arguments: ["add", "undo", "move"]) func aPendingRegistrationsDraftsDependOnEveryMainAuthorFactOfTheirAction(_ action: String) async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let r = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/one.xml", title: "One", count: 502))
                .feed.episodes.map(\.id).sorted()
            let p = try await store.insert(ServerLibraryFixture.fetched("https://example.test/p.xml", title: "Pending", count: 3)).episodes.map(\.id).sorted()
            _ = try await store.enqueue([p[2]])
            let batch = Array(r[0..<501]) + [p[0], r[501], p[1]]
            if action != "add" { _ = try await store.enqueue(batch) }
            let facts = try fixture.outboxCount(), drafted = Set(try fixture.drafts().map(\.opID))
            let expected: (main: Int, drafts: [String], queue: [Int64])
            switch action {
            case "add":
                _ = try await store.enqueue(batch)
                expected = (2, ["queue.add", "queue.add", "queue.reorder"], [p[2]] + batch)
            case "undo":
                let receipt = try #require(try await store.removeFromQueueWithUndo(r[0]).receipt)
                #expect(try await store.undoQueueRemoval(receipt).status == .restored)
                expected = (1, ["queue.reorder", "queue.reorder", "queue.reorder"], [p[2]] + batch)
            default:
                let moved = Array(r[0...501]) + [p[0], p[1]]
                _ = try await store.performQueueMove(.boundary(moved, .top), expected: try await store.queue().map(QueueEpisodeIdentity.init))
                expected = (2, ["queue.reorder", "queue.reorder", "queue.reorder"], batch + [p[2]])
            }
            #expect(try await store.queue().map(\.id) == expected.queue, "\(action)")
            let main = try fixture.newFacts(after: facts).filter { $0.type.hasPrefix("queue.") && $0.type != "queue.remove" }
            #expect(main.count == expected.main, "\(action): main-author facts \(main.map(\.type))")
            let drafts = try fixture.drafts().filter { !drafted.contains($0.opID) }
            #expect(drafts.map(\.type).sorted() == expected.drafts, "\(action): drafts")
            #expect(drafts.filter { $0.template["ntp_snapshot"] == true }.count == (action == "undo" ? 3 : 1), "\(action): snapshots")
            for draft in drafts {
                let text = try fixture.rows("SELECT dependencies FROM ntp_drafts WHERE op_id = '\(draft.opID)'").first?.first ?? nil
                let dependencies = Set(try JSONDecoder().decode([String].self, from: Data((text ?? "[]").utf8)))
                #expect(Set(main.map(\.opID)).isSubset(of: dependencies), "\(action): a \(draft.type) draft depends on every main-author fact")
            }
        }
    }

    @Test func anInterleavedMultiSelectMoveSplitsThePendingRegistrationsRuns() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let r = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/one.xml", title: "One", count: 3))
                .feed.episodes.map(\.id).sorted()
            let p = try await store.insert(ServerLibraryFixture.fetched("https://example.test/p.xml", title: "Pending", count: 2)).episodes.map(\.id).sorted()
            _ = try await store.enqueue([r[0], r[1], p[0], r[2], p[1]])
            let facts = try fixture.outboxCount(), drafted = try fixture.drafts().count
            _ = try await store.performQueueMove(.boundary([r[1], p[0], r[2], p[1]], .top), expected: try await store.queue().map(QueueEpisodeIdentity.init))
            #expect(try await store.queue().map(\.id) == [r[1], p[0], r[2], p[1], r[0]])
            let main = try fixture.newFacts(after: facts)
            try #require(main.count == 1)
            #expect(main[0].payload["run"]?.arrayValue?.compactMap { $0["episode_id"]?.stringValue } == [r[1], r[2]].compactMap { try? fixture.wireID($0) })
            #expect(try place(main[0].payload, fixture) == .start)
            let runs = try fixture.drafts().dropFirst(drafted)
            #expect(try runs.map { try place($0.template["payload"], fixture) } == [.after(r[1]), .after(r[2])])
        }
    }

    /// After a main-author command, a pending registration's queued episodes are placed again where the
    /// phone shows them, by drafts on its chain depending on the command's facts.
    @Test func aLaterCommandPlacesAPendingRegistrationsEpisodesAgainOnItsChain() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let r = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/one.xml", title: "One", count: 3))
                .feed.episodes.map(\.id).sorted()
            let p = try await store.insert(ServerLibraryFixture.fetched("https://example.test/p.xml", title: "Pending", count: 2)).episodes.map(\.id).sorted()
            _ = try await store.enqueue([r[0], p[0], r[1], p[1]])
            let facts = try fixture.outboxCount(), drafted = try fixture.drafts().count
            _ = try await store.performQueueMove(.item(r[0], finalIndex: 3), expected: try await store.queue().map(QueueEpisodeIdentity.init))
            #expect(try await store.queue().map(\.id) == [p[0], r[1], p[1], r[0]])
            let move = try #require(try fixture.newFacts(after: facts).first)
            #expect(try place(move.payload, fixture) == .end)
            let again = Array(try fixture.drafts().dropFirst(drafted))
            #expect(again.map(\.type) == ["queue.reorder", "queue.reorder"])
            #expect(try again.map { try place($0.template["payload"], fixture) } == [.start, .after(r[1])])
            #expect(again.map { $0.template["payload"]?["run"]?.arrayValue?.compactMap { $0["ntp_local_episode"]?.integerValue } } == [[p[0]], [p[1]]])
            for draft in again {
                #expect((try fixture.rows("SELECT dependencies FROM ntp_drafts WHERE op_id = '\(draft.opID)'").first?.first ?? nil)?
                    .contains(move.opID) == true)
            }
            // A random sort cannot observe the pending episodes: they are placed again where it put them, by a snapshot
            // that replaces the move's (only the latest has a lasting effect).
            _ = try await store.reorderQueue(.random, shuffle: { $0.reverse() })
            #expect(try await store.queue().map(\.id) == [r[0], p[1], r[1], p[0]])
            func snapshot() throws -> [ServerLibraryFixture.Draft] { try fixture.drafts().filter { $0.template["ntp_snapshot"] == true } }
            #expect(try snapshot().map { try place($0.template["payload"], fixture) } == [.after(r[0]), .after(r[1])])
            #expect(try fixture.drafts().count == drafted + 2, "the batch's adds and one snapshot")
            // The chain stays contiguous: sequence numbers and previous links follow each other.
            let chain = try fixture.rows("SELECT op_id, author_seq, previous_op_id FROM ntp_drafts ORDER BY author_seq")
            #expect(chain.map { $0[1] } == chain.indices.map { String($0 + 1) })
            #expect(chain.dropFirst().map { $0[2] } == chain.dropLast().map { $0[0] })
            #expect(try fixture.rows("SELECT a.next_seq, a.last_op_id FROM ntp_authors a JOIN ntp_drafts d ON d.author_id = a.author_id LIMIT 1")
                    == [[String(chain.count + 1), chain.last?[0]]])
            // Under Keep sorted no snapshot is kept: the sorted adds order the queue at replay.
            store.setQueueInsertionSettings(.init(keepSortedOrder: .episodeTitleAZ))
            _ = try await store.enqueue([r[2]])
            #expect(try snapshot().isEmpty)
            #expect(try fixture.drafts().count == drafted)
        }
    }

    // MARK: Owed adds

    @Test func anOwedPlayLoadAddKeepsThePlaceItResolved() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let ids = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched(count: 6)).feed.episodes.map(\.id).sorted()
            _ = try await store.enqueue(Array(ids[0...2]))
            _ = try await store.beginPlayback(episodeID: ids[1])
            await store.injectRecorderFailure(after: 1)
            _ = try await store.beginPlayback(episodeID: ids[4], enqueueLocation: .afterCurrentlyPlaying)
            await store.injectRecorderFailure(after: nil)
            #expect(try await store.queue().map(\.id) == [ids[0], ids[1], ids[4], ids[2]])
            let before = try fixture.outboxCount()
            try await store.replayOwedFacts()
            let add = try #require(try fixture.newFacts(after: before).first { $0.type == "queue.add" })
            #expect(add.episodeIDs == [try #require(try fixture.wireID(ids[4]))])
            #expect(try place(add.payload, fixture) == .after(ids[1]))
            #expect(try fixture.rows("SELECT count(*) FROM ntp_owed") == [["0"]])
        }
    }

    /// The owed add's place is the gap the load resolved, projected past an
    /// episode the main author cannot name, never the gap a Keep sorted pass moved it to.
    @Test func anOwedAddKeepsItsGapThroughAKeepSortedPass() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let r = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched(count: 4)).feed.episodes.map(\.id).sorted()
            let p = try #require(try await store.insert(ServerLibraryFixture.fetched("https://example.test/p.xml", title: "Pending", count: 1)).episodes.first).id
            _ = try await store.enqueue([r[2], p, r[3]])
            _ = try await store.beginPlayback(episodeID: p)
            store.setQueueInsertionSettings(.init(keepSortedOrder: .episodeTitleAZ))
            await store.injectRecorderFailure(after: 1)
            // After the current episode (the pending one), then sorted to the front.
            _ = try await store.beginPlayback(episodeID: r[0], enqueueLocation: .afterCurrentlyPlaying)
            await store.injectRecorderFailure(after: nil)
            #expect(try await store.queue().map(\.id) == [p, r[0], r[2], r[3]])
            let before = try fixture.outboxCount()
            try await store.replayOwedFacts()
            let add = try #require(try fixture.newFacts(after: before).first { $0.type == "queue.add" })
            #expect(try place(add.payload, fixture) == .after(r[2]), "the gap after the pending episode, projected onto R 3")
        }
    }
}
