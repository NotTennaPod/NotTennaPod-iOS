import Foundation
import Testing
@testable import NotTennaPodCore

/// The queue merges as one device would have made it (PROTOCOL §7.6), against the pinned server: two phones
/// act while neither sees the other (the server off for them), each at its own moment on its action clock, then push
/// in either order. Both phones and a phone attached afterwards show single-device order.
@Suite(.serialized) struct ServerQueueReplayAgreementTests {
    /// Episodes titled T 1 … T 6, oldest first.
    static let feeds: [String: ExchangeWorld.Feed] = ["/t.xml": ("T", "t", 6)]

    /// Two phones on the podcast, A having subscribed and queued `initial` (A's local IDs, T 1 … T 6 in order), both
    /// caught up. Returns the episodes and the moment after which every fact the phones know was received.
    static func pair(_ world: ExchangeWorld, initial: ([Int64]) -> [Int64]) async throws -> (a: ExchangePhone, b: ExchangePhone, t: [Int64], now: Date) {
        let a = try await world.attach("A")
        let feed = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("t.xml"), title: "T", prefix: "t", count: 6))
        try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: feed.id)
        let t = feed.episodes.map(\.id).sorted()
        _ = try await a.store.enqueue(initial(t))
        await a.exchange()
        let b = try await world.attach("B")
        await b.exchange()
        #expect(try await b.view().queue == (try await a.view().queue), "B starts from A's queue")
        return (a, b, t, Date())
    }

    /// `first` pushes, then `second`; then both exchange until nothing is pending. Both, and a phone attached now,
    /// show `expected` (A's local IDs).
    static func expectMerged(_ world: ExchangeWorld, first: ExchangePhone, second: ExchangePhone, a: ExchangePhone, _ expected: [Int64],
                             _ label: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        await first.exchange(sourceLocation: sourceLocation)
        await second.exchange(sourceLocation: sourceLocation)
        for _ in 0..<2 { for phone in [first, second] { await phone.exchange(sourceLocation: sourceLocation) } }
        var wires: [String] = []
        for id in expected { wires.append(try #require(try await a.store.wireEpisodeForTesting(id), sourceLocation: sourceLocation)) }
        for phone in [first, second] {
            #expect(try await phone.store.serverUnsentChanges() == 0, "\(label): \(phone.name) has unsent changes", sourceLocation: sourceLocation)
            #expect(try await phone.view().queue == wires, "\(label): \(phone.name)", sourceLocation: sourceLocation)
        }
        let fresh = try await world.attach("fresh-\(label)")
        #expect(try await fresh.view().queue == wires, "\(label): a fresh attach", sourceLocation: sourceLocation)
        await fresh.close()
        let log = try await first.engine.logEntries() + second.engine.logEntries()
        #expect(!log.contains { $0.kind == "outcome" && $0.detail.contains("rejected") },
                "\(label): nothing rejected: \(log.filter { $0.kind == "outcome" })", sourceLocation: sourceLocation)
    }

    /// The moment `step` after `start` (milliseconds apart, after every fact either phone depends on).
    static func at(_ start: Date, _ step: Int) -> Date { start.addingTimeInterval(Double(step) * 0.002) }

    // MARK: examples

    @Test(arguments: [true, false]) func addsAtTheBackOnTwoDaysFollowEachOther(aFirst: Bool) async throws {
        try await ExchangeWorld.run(feeds: Self.feeds) { world in
            let (a, b, t, start) = try await Self.pair(world) { [$0[5]] }
            // Monday, the iPhone adds X at the back; Tuesday, the other phone adds Y at the back.
            try await a.store.enqueueForTesting([t[0]], at: Self.at(start, 1))
            try await b.store.enqueueForTesting([try await ServerExchangeConcurrencyTests.same(t[1], from: a, on: b)], at: Self.at(start, 2))
            try await Self.expectMerged(world, first: aFirst ? a : b, second: aFirst ? b : a, a: a, [t[5], t[0], t[1]], "back, A first \(aFirst)")
        }
    }

    @Test(arguments: [true, false]) func addsAtTheFrontOnTwoDaysFollowEachOther(aFirst: Bool) async throws {
        try await ExchangeWorld.run(feeds: Self.feeds) { world in
            let (a, b, t, start) = try await Self.pair(world) { [$0[5]] }
            try await a.store.enqueueForTesting([t[0]], location: .front, at: Self.at(start, 1))
            try await b.store.enqueueForTesting([try await ServerExchangeConcurrencyTests.same(t[1], from: a, on: b)], location: .front,
                                                at: Self.at(start, 2))
            try await Self.expectMerged(world, first: aFirst ? a : b, second: aFirst ? b : a, a: a, [t[1], t[0], t[5]], "front, A first \(aFirst)")
        }
    }

    @Test(arguments: [true, false]) func interleavedAddsFollowTheirTimes(aFirst: Bool) async throws {
        try await ExchangeWorld.run(feeds: Self.feeds) { world in
            // The queue is Z. The iPhone adds X (time 1); the other phone adds Y (time 2), then W (time 3).
            let (a, b, t, start) = try await Self.pair(world) { [$0[5]] }
            try await a.store.enqueueForTesting([t[0]], at: Self.at(start, 1))
            try await b.store.enqueueForTesting([try await ServerExchangeConcurrencyTests.same(t[1], from: a, on: b)], at: Self.at(start, 2))
            try await b.store.enqueueForTesting([try await ServerExchangeConcurrencyTests.same(t[2], from: a, on: b)], at: Self.at(start, 3))
            try await Self.expectMerged(world, first: aFirst ? a : b, second: aFirst ? b : a, a: a, [t[5], t[0], t[1], t[2]],
                                        "interleaved, A first \(aFirst)")
        }
    }

    @Test(arguments: [true, false]) func anAddLaterThanKeepSortedIsSortedIn(aFirst: Bool) async throws {
        try await ExchangeWorld.run(feeds: Self.feeds) { world in
            // The queue is Z, A (T 3, T 1). The iPhone turns on Keep sorted by title (the sheet records the policy and
            // sorts); later the other phone, not having seen it, adds B (T 2) at the back.
            let (a, b, t, start) = try await Self.pair(world) { [$0[2], $0[0]] }
            try await a.store.setServerAccountPolicy(.sorting(keepSorted: true, order: .episodeTitleAZ), now: Self.at(start, 1))
            try await a.store.sortForTesting(.episodeTitleAZ, at: Self.at(start, 2))
            #expect(try await a.store.queue().map(\.id) == [t[0], t[2]])
            try await b.store.enqueueForTesting([try await ServerExchangeConcurrencyTests.same(t[1], from: a, on: b)], at: Self.at(start, 3))
            try await Self.expectMerged(world, first: aFirst ? a : b, second: aFirst ? b : a, a: a, [t[0], t[1], t[2]],
                                        "keep sorted, A first \(aFirst)")
        }
    }

    @Test(arguments: [true, false]) func twoDragsToTheSameGapKeepTheLaterFirst(aFirst: Bool) async throws {
        try await ExchangeWorld.run(feeds: Self.feeds) { world in
            // The queue is P, Q, R, E, F. Each phone drags a different episode to just after P: E first, F later.
            let (a, b, t, start) = try await Self.pair(world) { Array($0[0...4]) }
            try await a.store.moveForTesting(t[3], to: 1, at: Self.at(start, 1))
            try await b.store.moveForTesting(try await ServerExchangeConcurrencyTests.same(t[4], from: a, on: b), to: 1, at: Self.at(start, 2))
            try await Self.expectMerged(world, first: aFirst ? a : b, second: aFirst ? b : a, a: a, [t[0], t[4], t[3], t[1], t[2]],
                                        "drags, A first \(aFirst)")
        }
    }

    @Test(arguments: [true, false]) func anAddOfAnEpisodeAlreadyQueuedPlacesNothing(aFirst: Bool) async throws {
        try await ExchangeWorld.run(feeds: Self.feeds) { world in
            // The queue is A. The iPhone adds X (time 1). The other phone, not having seen X, adds Y (time 2), then X
            // (time 3): Android ignores an add of an episode already queued.
            let (a, b, t, start) = try await Self.pair(world) { [$0[5]] }
            try await a.store.enqueueForTesting([t[0]], at: Self.at(start, 1))
            try await b.store.enqueueForTesting([try await ServerExchangeConcurrencyTests.same(t[1], from: a, on: b)], at: Self.at(start, 2))
            try await b.store.enqueueForTesting([try await ServerExchangeConcurrencyTests.same(t[0], from: a, on: b)], at: Self.at(start, 3))
            try await Self.expectMerged(world, first: aFirst ? a : b, second: aFirst ? b : a, a: a, [t[5], t[0], t[1]],
                                        "duplicate add, A first \(aFirst)")
        }
    }

    // MARK: Queue places

    /// A batch mixing a registered podcast's episodes with a pending registration's keeps its order, at the
    /// back and at the front: the pending runs' drafts go into their own gaps after the batch's main-author add.
    @Test(arguments: [EnqueueLocation.back, .front]) func aMixedBatchWithAPendingPodcastKeepsItsOrder(location: EnqueueLocation) async throws {
        try await ExchangeWorld.run(feeds: ["/r.xml": ("R", "r", 2), "/p.xml": ("P", "p", 2)]) { world in
            let a = try await world.attach("A")
            let rFeed = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("r.xml"), title: "R", prefix: "r", count: 2))
            try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: rFeed.id)
            let pFeed = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("p.xml"), title: "P", prefix: "p", count: 2))
            let r = rFeed.episodes.map(\.id).sorted(), p = pFeed.episodes.map(\.id).sorted()
            let wanted = [r[0], p[0], r[1], p[1]]
            _ = try await a.store.enqueue(wanted, location: location)
            #expect(try await a.store.queue().map(\.id) == wanted)
            for _ in 0..<4 { await a.exchange() }
            #expect(try await a.store.serverUnsentChanges() == 0)
            #expect(try await a.store.queue().map(\.id) == wanted, "the requested order survives convergence")
            let b = try await world.attach("B")
            #expect(try await b.view().queue == (try await a.view().queue))
            await b.close()
        }
    }

    /// For multi-select moves: a selection interleaving a pending registration's episodes keeps its
    /// order.
    @Test func anInterleavedMoveWithAPendingPodcastKeepsItsOrder() async throws {
        try await ExchangeWorld.run(feeds: ["/r.xml": ("R", "r", 3), "/p.xml": ("P", "p", 2)]) { world in
            let a = try await world.attach("A")
            let rFeed = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("r.xml"), title: "R", prefix: "r", count: 3))
            try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: rFeed.id)
            let pFeed = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("p.xml"), title: "P", prefix: "p", count: 2))
            let r = rFeed.episodes.map(\.id).sorted(), p = pFeed.episodes.map(\.id).sorted()
            _ = try await a.store.enqueue([r[0], r[1], p[0], r[2], p[1]])
            _ = try await a.store.performQueueMove(.boundary([r[1], p[0], r[2], p[1]], .top), expected: try await a.store.queue().map(QueueEpisodeIdentity.init))
            let wanted = [r[1], p[0], r[2], p[1], r[0]]
            #expect(try await a.store.queue().map(\.id) == wanted)
            for _ in 0..<4 { await a.exchange() }
            #expect(try await a.store.serverUnsentChanges() == 0)
            #expect(try await a.store.queue().map(\.id) == wanted, "the moved order survives convergence")
            let b = try await world.attach("B")
            #expect(try await b.view().queue == (try await a.view().queue))
            await b.close()
        }
    }

    /// The duration sort uses the durations the server will have when it replays the sort, so nothing jumps back
    /// when the server acknowledges it. The phone observes its copy of the feed (PROTOCOL §9.4): a duration in its
    /// observation still unanswered is the server's by then and counts; a duration only this phone's row has (its
    /// own value, never sent) never does.
    @Test func aDurationTheServerDoesNotHaveSortsNothingAndNothingJumpsBack() async throws {
        try await ExchangeWorld.run(feeds: ["/t.xml": ("T", "t", 1)]) { world in
            let a = try await world.attach("A")
            let source = world.url("t.xml")
            // The phone's copy of the feed has three episodes with durations; the server's fetch finds only the first.
            let items = (1...3).map { n in
                ParsedEpisode(identifier: "t-\(n)", title: "T \(n)", publicationDate: Date(timeIntervalSince1970: 1_760_000_000 + Double(n) * 86_400),
                              media: ParsedMedia(url: "https://media.example/t-\(n).mp3", size: 1_000, durationMilliseconds: Int32(n * 60_000)))
            }
            let feed = try await a.store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "T", link: "https://example.com/", episodes: items),
                                                            source: source, responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil))
            try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: feed.id)
            // The phone's observation of its copy is sent; its answer has not come back.
            await a.run([.push])
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox WHERE type = 'catalog.observe'") != [["0"]])
            let ids = feed.episodes.map(\.id).sorted()
            _ = try await a.store.enqueue([ids[1], ids[2]])
            #expect(try a.rows("SELECT count(*) FROM ntp_records WHERE entity = 'episode' AND field_group = 'metadata'") == [["1"]],
                    "the catalog this phone holds lacks T 2 and T 3")
            _ = try await a.store.reorderQueue(.durationLongShort)
            #expect(try await a.store.queue().map(\.id) == [ids[2], ids[1]], "by the durations the server has when it replays the sort")
            await a.exchange()
            await a.exchange()
            #expect(try await a.store.serverUnsentChanges() == 0)
            #expect(try a.rows("SELECT count(*) FROM ntp_records WHERE entity = 'episode' AND field_group = 'metadata'") == [["3"]])
            #expect(try await a.store.queue().map(\.id) == [ids[2], ids[1]], "the sort does not jump back on its acknowledgement")
            // A duration only this phone's row has is not the server's: the sort keeps to the server's.
            try await a.store.projectForTesting(ids[1]) { $0.details.media?.durationMilliseconds = 3_600_000 }
            _ = try await a.store.reorderQueue(.durationLongShort)
            #expect(try await a.store.queue().map(\.id) == [ids[2], ids[1]], "never this phone's own value")
            await a.exchange()
            await a.exchange()
            #expect(try await a.store.queue().map(\.id) == [ids[2], ids[1]])
        }
    }

    // MARK: Queue places across chains

    /// A podcast subscribed while the server is away stays pending for the whole outage; the main author's
    /// later commands cannot name its episodes, and its drafts replay after them. After [R1, P1, R2, P2], each later
    /// command (and the front add, a control) settles to the phone's order, with or without another phone's change
    /// made meanwhile (merged around the anchors), and a fresh phone agrees.
    @Test(arguments: ["append", "front", "randomSort", "move"], [false, true])
    func aPendingPodcastsEpisodesSettleWhereThePhoneShowsThemAfterLaterCommands(action: String, concurrent: Bool) async throws {
        try await ExchangeWorld.run(feeds: ["/r.xml": ("R", "r", 4), "/p.xml": ("P", "p", 2)]) { world in
            let a = try await world.attach("A")
            let rFeed = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("r.xml"), title: "R", prefix: "r", count: 4))
            try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: rFeed.id)
            let r = rFeed.episodes.map(\.id).sorted()
            let c = try await world.attach("C")
            // Another phone, while this one is away, adds R 4 at the front.
            if concurrent {
                _ = try await c.store.enqueue([try await ServerExchangeConcurrencyTests.same(r[3], from: a, on: c)], location: .front)
                await c.exchange()
            }
            // Away from the server: P is subscribed (pending throughout), then the batch and a later command.
            let pFeed = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("p.xml"), title: "P", prefix: "p", count: 2))
            let p = pFeed.episodes.map(\.id).sorted()
            _ = try await a.store.enqueue([r[0], p[0], r[1], p[1]])
            switch action {
            case "randomSort": _ = try await a.store.reorderQueue(.random, shuffle: { $0.reverse() })
            case "move": _ = try await a.store.performQueueMove(.item(r[0], finalIndex: 3), expected: try await a.store.queue().map(QueueEpisodeIdentity.init))
            default: _ = try await a.store.enqueue([r[2]], location: action == "front" ? .front : .back)
            }
            let wanted = try await a.store.queue().map(\.id)
            for _ in 0..<4 { await a.exchange(); await c.exchange() }
            #expect(try await a.store.serverUnsentChanges() == 0)
            let settled = try await a.store.queue().map(\.id)
            let other = concurrent ? [r[3]] : []
            #expect(settled.filter { !other.contains($0) } == wanted, "\(action), concurrent \(concurrent): the phone's order settles")
            #expect(Set(settled) == Set(wanted + other))
            #expect(try await c.view().queue == (try await a.view().queue), "the other phone agrees")
            let b = try await world.attach("B")
            #expect(try await b.view().queue == (try await a.view().queue), "a fresh phone agrees")
            await b.close()
        }
    }

    /// A refused main-author add retires, and its members, which nothing else holds in the queue, leave this
    /// phone's queue as they never joined the server's; the pending podcast's pieces are accepted. With a refused
    /// registration (the control) the registered members are the server's queue, and the registration's chain ends.
    @Test(arguments: [false, true]) func aRefusedAddLeavesOnlyWhatTheServerAccepted(registration: Bool) async throws {
        try await ExchangeWorld.run(feeds: ["/r.xml": ("R", "r", 2), "/p.xml": ("P", "p", 2)]) { world in
            let a = try await world.attach("A")
            let rFeed = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("r.xml"), title: "R", prefix: "r", count: 2))
            try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: rFeed.id)
            let pFeed = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("p.xml"), title: "P", prefix: "p", count: 2))
            let r = rFeed.episodes.map(\.id).sorted(), p = pFeed.episodes.map(\.id).sorted()
            _ = try await a.store.enqueue([r[0], p[0], r[1], p[1]])
            try await a.store.refuseLastFactForTesting(type: registration ? "podcast.subscribe" : "queue.add")
            for _ in 0..<4 { await a.exchange() }
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox") == [["0"]])
            #expect(try a.rows("SELECT count(*) FROM ntp_attention") == [["1"]])
            let shown = registration ? r : p
            var expected: [String] = []
            for id in shown { expected.append(try #require(try await a.store.wireEpisodeForTesting(id))) }
            let b = try await world.attach("B")
            #expect(try await b.view().queue == expected, "the server's queue")
            await b.close()
            if registration {
                #expect(try a.rows("SELECT count(*) FROM ntp_drafts") == [["0"]], "a refused registration's chain ends")
                #expect(try await a.store.queue().map(\.id) == [r[0], p[0], r[1], p[1]], "what the person did stays shown")
            } else {
                #expect(try a.rows("SELECT count(*) FROM ntp_drafts") == [["0"]])
                #expect(try await a.store.queue().map(\.id) == p, "the refused add's members are no longer shown")
            }
        }
    }

    // MARK: The replay mechanism

    /// The placement snapshots through a pending registration's lifecycle, after [R1, P1, R2, P2], an append and a
    /// move: a removal, a completion, an unsubscribe, a refusal (the chain ends and takes nothing more), a
    /// resolution between commands, an anchor removed, a later add of a refused add's episode, Keep sorted (with
    /// another phone's add meanwhile: the queue settles sorted), and pending-only moves and adds.
    @Test(arguments: ["remove", "complete", "unsubscribe", "reject", "midResolve", "removeAnchor", "laterAddSame", "keepSorted",
                      "keepSortedRemote", "pendingOnlyMove", "pendingOnlyAdd"])
    func aPendingRegistrationsLifecycleSettles(action: String) async throws {
        try await ExchangeWorld.run(feeds: ["/r.xml": ("R", "r", 5), "/p.xml": ("P", "p", 3), "/o.xml": ("O", "o", 1)]) { world in
            let a = try await world.attach("A")
            let rf = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("r.xml"), title: "R", prefix: "r", count: 5))
            try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: rf.id)
            let pf = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("p.xml"), title: "P", prefix: "p", count: 3))
            let r = rf.episodes.map(\.id).sorted(), p = pf.episodes.map(\.id).sorted()
            _ = try await a.store.enqueue([r[0], p[0], r[1], p[1]])
            _ = try await a.store.enqueue([r[2]])
            _ = try await a.store.performQueueMove(.item(r[0], finalIndex: 4), expected: try await a.store.queue().map(QueueEpisodeIdentity.init))
            switch action {
            case "remove": _ = try await a.store.removeFromQueue([p[0]])
            case "complete":
                let play = try await a.store.beginPlayback(episodeID: p[0])
                _ = try await a.store.endPlayback(sessionID: play.id, reason: .ended, continueQueue: false)
            case "unsubscribe": _ = try await a.store.requestFeedDeletion(feedID: pf.id)
            case "reject": try await a.store.refuseLastFactForTesting(type: "podcast.subscribe")
            case "removeAnchor": _ = try await a.store.removeFromQueue([r[1]])
            case "midResolve":
                let before = try await a.store.queue().map(\.id)
                await a.run([.push, .pull, .apply])
                #expect(try await a.store.queue().map(\.id) == before)
            case "laterAddSame":
                try await a.store.refuseLastFactForTesting(type: "queue.add")
                _ = try await a.store.removeFromQueue([r[2]])
                _ = try await a.store.enqueue([r[2]], location: .front)
            case "keepSorted", "keepSortedRemote":
                try await a.store.setServerAccountPolicy(.sorting(keepSorted: true, order: .episodeTitleAZ))
                a.store.setQueueInsertionSettings(.init(keepSortedOrder: .episodeTitleAZ))
                _ = try await a.store.reorderQueue(.episodeTitleAZ)
            case "pendingOnlyMove":
                _ = try await a.store.performQueueMove(.item(p[0], finalIndex: 4), expected: try await a.store.queue().map(QueueEpisodeIdentity.init))
            case "pendingOnlyAdd": _ = try await a.store.enqueue([p[2]], location: .front)
            default: break
            }
            _ = try await a.store.enqueue([r[3]])
            let wanted = try await a.store.queue().map(\.id)
            if action == "keepSortedRemote" {
                let b = try await world.attach("B")
                let of = try await b.store.insert(ServerExchangeAgreementTests.fetched(world.url("o.xml"), title: "O", prefix: "o", count: 1))
                try await ServerExchangeAgreementTests.waitForCatalog(b, feedID: of.id)
                _ = try await b.store.enqueue(of.episodes.map(\.id))
                await b.exchange()
                await b.close()
            }
            if action == "laterAddSame" {
                await a.run([.push, .pull])
                for _ in 0..<12 {
                    await a.run([.applyOne])
                    #expect(try await a.store.queue().map(\.id).contains(r[2]), "the later pending add survives each retirement")
                }
            }
            for _ in 0..<4 { await a.exchange() }
            let actual = try await a.store.queue().map(\.id)
            if action == "keepSortedRemote" {
                let titles = try await a.store.queue().map { $0.details.title ?? "" }
                #expect(titles == ["O 1", "P 1", "P 2", "R 1", "R 2", "R 3", "R 4"], "Keep sorted settles sorted, the other phone's add included")
            } else {
                #expect(actual == wanted, "\(action)")
            }
            if action == "unsubscribe" { #expect(try await a.store.feed(id: pf.id) == nil) }
            if action == "reject" {
                #expect(try a.rows("SELECT count(*) FROM ntp_drafts") == [["0"]], "a refused registration's chain ends")
                _ = try await a.store.enqueue([r[4]])
                await a.exchange()
                #expect(try a.rows("SELECT count(*) FROM ntp_drafts") == [["0"]], "an unrelated command adds nothing to it")
                #expect(try await a.store.serverUnsentChanges() == 0)
                #expect(try await a.store.queue().map(\.id) == wanted + [r[4]], "what the person did stays shown")
            } else {
                #expect(try await a.store.serverUnsentChanges() == 0)
                let b = try await world.attach("B")
                // A completion through the store alone is this device's: it is not compared.
                if action != "complete" { #expect(try await b.view().queue == (try await a.view().queue)) }
                await b.close()
            }
        }
    }

    /// Keep sorted with a pending podcast's adds and another phone's add meanwhile settles sorted.
    @Test func keepSortedWithAPendingPodcastAndAnotherPhonesAddSettlesSorted() async throws {
        try await ExchangeWorld.run(feeds: ["/r.xml": ("R", "r", 2), "/p.xml": ("P", "p", 2), "/o.xml": ("O", "o", 1)]) { world in
            let a = try await world.attach("A")
            let rf = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("r.xml"), title: "R", prefix: "r", count: 2))
            try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: rf.id)
            try await a.store.setServerAccountPolicy(.sorting(keepSorted: true, order: .episodeTitleAZ))
            a.store.setQueueInsertionSettings(.init(keepSortedOrder: .episodeTitleAZ))
            _ = try await a.store.enqueue(rf.episodes.map(\.id).sorted())
            await a.exchange()
            let pf = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("p.xml"), title: "P", prefix: "p", count: 2))
            _ = try await a.store.enqueue(pf.episodes.map(\.id).sorted())
            #expect(try a.rows("SELECT count(*) FROM ntp_drafts WHERE kind = 'queue.reorder'") == [["0"]])
            let b = try await world.attach("B")
            let of = try await b.store.insert(ServerExchangeAgreementTests.fetched(world.url("o.xml"), title: "O", prefix: "o", count: 1))
            try await ServerExchangeAgreementTests.waitForCatalog(b, feedID: of.id)
            _ = try await b.store.enqueue(of.episodes.map(\.id))
            await b.exchange()
            for _ in 0..<4 { await a.exchange() }
            #expect(try await a.store.queue().map { $0.details.title ?? "" } == ["O 1", "P 1", "P 2", "R 1", "R 2"])
            #expect(try await a.store.serverUnsentChanges() == 0)
            await b.close()
        }
    }

    /// Three pending podcasts of 30 queued episodes between registered anchors, one
    /// registered episode moved between top and bottom 280 times (20 a day for two weeks). One snapshot per
    /// registration is kept, so reconnecting sends little and settles in the phone's order.
    @Test func aLongOutageKeepsOneSnapshotPerRegistration() async throws {
        try await ExchangeWorld.run(feeds: ["/r.xml": ("R", "r", 32), "/p.xml": ("P", "p", 30), "/q.xml": ("Q", "q", 30), "/s.xml": ("S", "s", 30)]) { world in
            let a = try await world.attach("A")
            let rf = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("r.xml"), title: "R", prefix: "r", count: 32))
            try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: rf.id)
            let r = rf.episodes.map(\.id).sorted()
            var queue = [r[0]]
            for (path, name) in [("p", "P"), ("q", "Q"), ("s", "S")] {
                let pf = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("\(path).xml"), title: name, prefix: path, count: 30))
                queue += pf.episodes.map(\.id).sorted()
                queue += [r[queue.count / 30]]
            }
            _ = try await a.store.enqueue(queue)
            let recording = ContinuousClock.now
            for i in 0..<280 {
                let shown = try await a.store.queue().map(QueueEpisodeIdentity.init)
                _ = try await a.store.performQueueMove(.item(r[0], finalIndex: i % 2 == 0 ? shown.count - 1 : 0), expected: shown)
            }
            let recorded = recording.duration(to: .now)
            let drafts = try a.rows("SELECT count(*), sum(length(template)) FROM ntp_drafts")
            #expect(drafts.first?.first == "6", "the batch's three adds and one snapshot per registration")
            let wanted = try await a.store.queue().map(\.id)
            let requests = a.transport.requests.count
            let reconnecting = ContinuousClock.now
            for _ in 0..<4 { await a.exchange() }
            let reconnected = reconnecting.duration(to: .now)
            let sizes = try a.transport.requests.dropFirst(requests).filter { $0.path == "v1/push" }.map { try $0.body?.canonicalBytes().count ?? 0 }
            print("OUTAGE VOLUME recording \(recorded) for 280 moves; drafts \(drafts); reconnection \(reconnected), \(sizes.count) pushes, \(sizes.reduce(0, +)) bytes, largest \(sizes.max() ?? 0)")
            #expect(try await a.store.queue().map(\.id) == wanted)
            #expect(try await a.store.serverUnsentChanges() == 0)
        }
    }

    // MARK: A pending placement under a pulled layout (PROTOCOL §7.6)

    @Test func aPendingAddSurvivesAPulledLayoutThatMovesItsNeighbours() async throws {
        try await ExchangeWorld.run(feeds: Self.feeds) { world in
            // [T 1, T 2, T 3]: the iPhone sorts by title Z → A, which the server publishes as a layout; later the other
            // phone adds X right after T 1 and, before pushing it, applies the sort. X stays queued over the moved
            // neighbours, and once pushed it lands after T 1 in the sorted queue.
            let (a, b, t, start) = try await Self.pair(world) { Array($0[0...2]) }
            try await a.store.sortForTesting(.episodeTitleZA, at: Self.at(start, 1))
            await a.exchange()
            let x = try await ServerExchangeConcurrencyTests.same(t[5], from: a, on: b)
            try await b.store.enqueueForTesting([x], location: .random, index: 1, at: Self.at(start, 2))
            await b.run([.pull, .apply])
            let shown = try await b.store.queue().map(\.id)
            #expect(shown.contains(x), "the pending add stays queued")
            var neighbours: [Int64] = []
            for id in [t[2], t[1], t[0]] { neighbours.append(try await ServerExchangeConcurrencyTests.same(id, from: a, on: b)) }
            #expect(shown.filter { $0 != x } == neighbours, "the layout's order shows")
            try await Self.expectMerged(world, first: b, second: a, a: a, [t[2], t[1], t[0], t[5]], "pending add under a layout")
        }
    }

    // MARK: Undo and a no-op sort against another phone's unseen add

    @Test func anUndoAfterAnotherPhonesFrontAddRestoresAtItsIndexThere() async throws {
        try await ExchangeWorld.run(feeds: Self.feeds) { world in
            // [P, Q, R]: the iPhone removes Q and, after the other phone's unseen front add of X has arrived, undoes the
            // removal: Q goes back to index 1 of the queue it finds, after X (Android's `addQueueItemAt`).
            let (a, b, t, _) = try await Self.pair(world) { Array($0[0...2]) }
            let receipt = try #require(try await a.store.removeFromQueueWithUndo(t[1]).receipt)
            _ = try await b.store.enqueue([try await ServerExchangeConcurrencyTests.same(t[5], from: a, on: b)], location: .front)
            await b.exchange()
            await a.run([.pull, .apply])
            #expect(try await a.store.queue().map(\.id) == [t[5], t[0], t[2]])
            #expect(try await a.store.undoQueueRemoval(receipt).status == .restored)
            #expect(try await a.store.queue().map(\.id) == [t[5], t[1], t[0], t[2]])
            try await Self.expectMerged(world, first: a, second: b, a: a, [t[5], t[1], t[0], t[2]], "undo")
        }
    }

    @Test func aSortThatChangedNothingHereSortsAnotherPhonesUnseenAdd() async throws {
        try await ExchangeWorld.run(feeds: Self.feeds) { world in
            // [T 1, T 3] is already in title order on the iPhone; the other phone's earlier add of T 2 at the back has
            // not reached it. The iPhone's sort changes nothing here, but it is sent and sorts T 2 in.
            let (a, b, t, start) = try await Self.pair(world) { [$0[0], $0[2]] }
            try await b.store.enqueueForTesting([try await ServerExchangeConcurrencyTests.same(t[1], from: a, on: b)], at: Self.at(start, 1))
            try await a.store.sortForTesting(.episodeTitleAZ, at: Self.at(start, 2))
            #expect(try await a.store.queue().map(\.id) == [t[0], t[2]])
            try await Self.expectMerged(world, first: a, second: b, a: a, [t[0], t[1], t[2]], "no-op sort")
        }
    }

    // MARK: Episodes without media

    /// A feed whose second item has no enclosure (a text post), as the server and the phone both read it.
    static let textPostRSS = "<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>M</title><link>https://example.com/</link>"
        + "<item><title>M 1</title><guid>m-1</guid><pubDate>Fri, 10 Oct 2025 12:00:00 GMT</pubDate>"
        + "<enclosure url=\"https://media.example/m-1.mp3\" length=\"1000\" type=\"audio/mpeg\"/></item>"
        + "<item><title>M 2</title><guid>m-2</guid><pubDate>Sat, 11 Oct 2025 12:00:00 GMT</pubDate></item>"
        + "</channel></rss>"

    static func textPostFeed(_ url: String) -> FetchedFeed {
        let items = [
            ParsedEpisode(identifier: "m-1", title: "M 1", publicationDate: Date(timeIntervalSince1970: 1_760_097_600),
                          media: ParsedMedia(url: "https://media.example/m-1.mp3", size: 1_000, durationMilliseconds: 0)),
            ParsedEpisode(identifier: "m-2", title: "M 2", publicationDate: Date(timeIntervalSince1970: 1_760_184_000), media: nil),
        ]
        return FetchedFeed(feed: ParsedFeed(format: .rss, title: "M", link: "https://example.com/", episodes: items), source: url,
                           responseURL: URL(string: url)!, validator: nil, permanentRedirectURL: nil)
    }

    /// Another client queues an episode without media (the web client's episode menu can). The server queues it and lists
    /// it in the browser's queue, as Android's queue (which joins media optionally) would show it; every phone shows the
    /// same queue, the one that already had the podcast and one attached afterwards (PROTOCOL §7.6).
    @Test func anEpisodeWithoutMediaQueuedElsewhereShowsInThePhonesQueue() async throws {
        try await ExchangeWorld.run(feeds: [:]) { world in
            world.setResponse("/m.xml", .init(headers: ["Content-Type": "application/rss+xml"], body: Data(Self.textPostRSS.utf8)))
            let a = try await world.attach("A")
            let feed = try await a.store.subscribeForTesting(Self.textPostFeed(world.url("m.xml")))
            try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: feed.id)
            let text = try #require(feed.episodes.first { $0.details.title == "M 2" }?.id)
            let audio = try #require(feed.episodes.first { $0.details.title == "M 1" }?.id)
            _ = try await a.store.enqueue([audio])
            await a.exchange()
            let b = try await world.attach("B")
            await b.exchange()
            let onB = try await ServerExchangeConcurrencyTests.same(text, from: a, on: b)
            // B stands in for the other client: the add its menu sends, at the back after M 1.
            let (ref, target) = try #require(try await b.store.episodeRefForTesting(onB))
            let (audioRef, _) = try #require(try await b.store.episodeRefForTesting(try await ServerExchangeConcurrencyTests.same(audio, from: a, on: b)))
            let audioKey = try #require(try b.rows("SELECT key FROM ntp_queue_keys").first?.first ?? nil)
            let positionID = UUID()
            let key = try QueueKey.between(try QueueKey(wire: audioKey), nil, positionWriteID: positionID)
            try await b.store.appendFactForTesting(type: "queue.add", targets: [target], payload: [
                "members": [["episode": ref, "key": .string(key.wire), "position_id": .string(positionID.uuidString.lowercased())]],
                "place": ["kind": "after", "after": audioRef]])
            await b.exchange()
            await a.exchange()
            let wireText = try #require(try await a.store.wireEpisodeForTesting(text))
            let wireAudio = try #require(try await a.store.wireEpisodeForTesting(audio))
            let membership = try a.rows("SELECT CAST(value AS TEXT) FROM ntp_records WHERE entity = 'episode' AND id = '\(wireText)' AND field_group = 'queue_membership'")
            #expect(membership.first?.first??.contains("\"in_queue\":true") == true, "the server queued it: \(membership)")
            #expect(try await a.view().queue == [wireAudio, wireText], "the phone that had the podcast shows the server's queue")
            #expect(try await a.store.queue().map(\.id) == [audio, text], "its queue screen lists both")
            let fresh = try await world.attach("fresh")
            #expect(try await fresh.view().queue == [wireAudio, wireText], "a phone attached afterwards shows the server's queue")
            await fresh.close()
        }
    }
}

extension FeedLibraryStore {
    /// An add at `location` (a random one at `index`) made at `time` on this phone's action clock (another day while
    /// the server was away).
    func enqueueForTesting(_ ids: [Int64], location: EnqueueLocation = .back, index: Int = 0, at time: Date) throws {
        _ = try write(.queueAdd, now: time) {
            try addToQueue(ids, location: location, playing: nil, downloadingURLs: [], randomIndex: { _ in index })
        }
    }

    /// A drag of `id` to `index`, made at `time`.
    func moveForTesting(_ id: Int64, to index: Int, at time: Date) throws {
        try write(.queueMove(boundary: false), now: time) {
            var queue = try loadQueue()
            guard let from = queue.firstIndex(where: { $0.id == id }) else { return }
            let episode = queue.remove(at: from)
            queue.insert(episode, at: index)
            activeCapture?.movedQueueEpisodes = [id]
            try saveQueue(queue)
        }
    }

    /// The sort sheet's sort, made at `time`.
    func sortForTesting(_ order: QueueSortOrder, at time: Date) throws {
        try write(.queueSort, now: time) {
            activeCapture?.queueSortOrder = order
            let queue = try loadQueue()
            let sorted = try canonicalSortedQueue(queue, order: order)
            if sorted.map(\.id) != queue.map(\.id) { try saveQueue(sorted) }
        }
    }
}

extension FeedLibraryStore {
    /// Replaces the payload of the last outbox fact of `type` with an empty one (its hash updated), so the server refuses
    /// it (a fault injected before sending).
    func refuseLastFactForTesting(type: String) throws {
        guard let row = try database.rows("SELECT op_id, fact FROM ntp_outbox WHERE type = ? ORDER BY install_seq DESC LIMIT 1", [.text(type)]).first,
              let op = row[0].text, let data = row[1].data, var object = try ContractJSON.decode(data).objectValue else {
            throw ServerRecordingError.corruptState("no \(type) to refuse")
        }
        object["payload"] = [:]
        let bytes = try ContractJSON.object(object).canonicalBytes()
        try database.execute("UPDATE ntp_outbox SET fact = ?, content_hash = ? WHERE op_id = ?",
                             [.blob(Data(bytes)), .text(ContractIdentity.sha256Hex(bytes)), .text(op)])
    }
}
