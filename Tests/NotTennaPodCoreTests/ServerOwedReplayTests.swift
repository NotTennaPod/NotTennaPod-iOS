import Foundation
import Testing
@testable import NotTennaPodCore

/// Owed facts: a play load's queue add whose recording failed is replayed later. The
/// replay keeps the queue policy of the moment the add happened; since the queue replay that is the account's policy
/// at the add's place (PROTOCOL §7.6), so the owed add is recorded with the action's time and place, before any
/// later eligible write (a policy change included) records its own action.
@MainActor @Suite(.serialized) struct ServerOwedReplayTests {
    private func withFixture(_ body: (ServerLibraryFixture) async throws -> Void) async throws {
        let fixture = try await ServerLibraryFixture()
        do { try await body(fixture); await fixture.close() } catch { await fixture.close(); throw error }
    }

    /// Keep sorted on this phone and on the account, as the settings screen sets both.
    static func keepSorted(_ store: FeedLibraryStore, _ order: QueueSortOrder?) async throws {
        store.setQueueInsertionSettings(.init(keepSortedOrder: order))
        try await store.setServerAccountPolicy(.sorting(keepSorted: order != nil, order: order ?? .episodeTitleAZ))
    }

    // MARK: The owed add keeps its queue policy

    @Test func anOwedSortedAddIsRecordedBeforeKeepSortedIsTurnedOff() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let ids = try await fixture.subscribeRegistered().feed.episodes.map(\.id).sorted()
            _ = try await store.enqueue([ids[3], ids[0]])
            try await Self.keepSorted(store, .episodeTitleAZ)
            let count = try fixture.outboxCount()
            await store.injectRecorderFailure(after: 1)
            _ = try await store.beginPlayback(episodeID: ids[1])
            await store.injectRecorderFailure(after: nil)
            #expect(try await store.queue().map(\.id) == [ids[0], ids[1], ids[3]])
            let record = try ContractJSON.decode(try #require(try fixture.rows("SELECT CAST(record AS TEXT) FROM ntp_owed WHERE intent = 'queue.add'").first?.first ?? nil))
            #expect(record["keep_sorted"]?.boolValue == true && record["sort_order"]?.stringValue == "EPISODE_TITLE_A_Z")
            let time = try #require(record["client_time"]?.integerValue)
            #expect(record["place"] == ["kind": "end"], "the load added at the back, then sorted")
            // Keep sorted is turned off before anything replays the debt: that write records the owed add first.
            try await Self.keepSorted(store, nil)
            try await store.replayOwedFacts()
            #expect(try fixture.rows("SELECT count(*) FROM ntp_owed") == [["0"]])
            #expect(try fixture.queueOrderMatchesKeys())
            let facts = try fixture.newFacts(after: count)
            #expect(facts.map(\.type) == ["queue.add", "account.set_queue_policy"])
            #expect(facts[0].episodeIDs == [try #require(try fixture.wireID(ids[1]))])
            #expect(facts[0].json["client_time"]?.integerValue == time, "the action's time")
            #expect(facts[0].payload["place"] == ["kind": "end"] && facts[0].payload["moves"] == nil)
            // The replay of the outbox (keep sorted on at the add's place) reads like the phone's queue.
            #expect(try await outboxQueue(fixture) == (try await localWireQueue(fixture)))
        }
    }

    @Test func anOwedUnsortedAddStaysUnsortedAfterKeepSortedIsTurnedOn() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let ids = try await fixture.subscribeRegistered().feed.episodes.map(\.id).sorted()
            _ = try await store.enqueue([ids[3], ids[0]])
            let count = try fixture.outboxCount()
            await store.injectRecorderFailure(after: 1)
            _ = try await store.beginPlayback(episodeID: ids[1])
            await store.injectRecorderFailure(after: nil)
            #expect(try await store.queue().map(\.id) == [ids[3], ids[0], ids[1]])
            try await Self.keepSorted(store, .episodeTitleAZ)
            try await store.replayOwedFacts()
            let replayed = try fixture.newFacts(after: count)
            #expect(replayed.map(\.type) == ["queue.add", "account.set_queue_policy"])
            #expect(replayed.first?.payload["place"] == ["kind": "end"] && replayed.first?.payload["moves"] == nil)
            #expect(try fixture.queueOrderMatchesKeys())
            #expect(try await outboxQueue(fixture) == (try await localWireQueue(fixture)))
        }
    }
}

extension ServerOwedReplayTests {
    /// The queue the server's replay would read from this outbox alone (PROTOCOL §7.6), for one device whose
    /// facts replay in outbox order: an add or a restore places its members not yet queued at its `place` (an add then
    /// sorts if the account's Keep sorted is on there), a move takes its run there, a removal or a clear takes members
    /// out (they keep their place), the sort sheet sorts the members in the queue among their slots. Sorts use this
    /// library's canonical values (the server's own, here).
    func outboxQueue(_ fixture: ServerLibraryFixture) async throws -> [String] {
        var structure: [String] = [], member = Set<String>()
        var keepSorted: QueueSortOrder?
        func place(_ run: [String], _ place: ContractJSON?) {
            structure.removeAll { run.contains($0) }
            var index = structure.count
            if place?["kind"] == "start" { index = 0 }
            if place?["kind"] == "after", let anchor = place?["after"]?["episode_id"]?.stringValue, let at = structure.firstIndex(of: anchor) { index = at + 1 }
            structure.insert(contentsOf: run, at: index)
        }
        func sort(_ order: QueueSortOrder, permutation: [String]? = nil) async throws {
            let inMembers = structure.filter(member.contains)
            var sorted: [String]
            if let permutation {
                var rest = permutation.filter(member.contains).makeIterator()
                sorted = inMembers.map { permutation.contains($0) ? rest.next()! : $0 }
            } else {
                var episodes: [LibraryEpisode] = []
                for wire in inMembers {
                    guard let local = try await fixture.store.localEpisodeForTesting(wire: wire), let episode = try await fixture.store.episode(id: local) else { continue }
                    episodes.append(episode)
                }
                sorted = []
                for episode in try await fixture.store.canonicalSortedQueue(episodes, order: order) { sorted.append(try #require(try fixture.wireID(episode.id))) }
            }
            var next = sorted.makeIterator()
            structure = structure.map { member.contains($0) ? next.next()! : $0 }
        }
        func ids(_ list: ContractJSON?, _ path: String?) -> [String] {
            (list?.arrayValue ?? []).compactMap { item in
                let reference: ContractJSON? = if let path { item[path] } else { item }
                return reference?["episode_id"]?.stringValue
            }
        }
        for fact in try fixture.outbox() {
            let payload = fact.payload
            switch fact.type {
            case "queue.add", "queue.restore":
                let run = ids(payload["members"], "episode").filter { !member.contains($0) }
                guard !run.isEmpty else { continue }
                place(run, payload["place"])
                member.formUnion(run)
                if fact.type == "queue.add", let order = keepSorted { try await sort(order) }
            case "queue.move":
                place(ids(.array([payload["episode"] ?? .null]), nil), payload["place"])
            case "queue.reorder":
                if payload["run"] != nil { place(ids(payload["run"], nil), payload["place"]) }
                else if let order = payload["sort"]?["sort_order"]?.stringValue.flatMap({ QueueSortOrder(rawValue: $0.uppercased()) }) {
                    try await sort(order, permutation: order == .random ? ids(payload["sort"]?["permutation"], nil) : nil)
                }
            case "queue.remove", "queue.clear":
                member.subtract(fact.episodeIDs)
            case "account.set_queue_policy":
                if let sorting = payload["sorting"] {
                    keepSorted = sorting["keep_sorted"]?.boolValue == true
                        ? sorting["sort_order"]?.stringValue.flatMap { QueueSortOrder(rawValue: $0.uppercased()) } : nil
                }
            default: break
            }
        }
        return structure.filter(member.contains)
    }

    func localWireQueue(_ fixture: ServerLibraryFixture) async throws -> [String] {
        var result: [String] = []
        for id in try await fixture.store.queue().map(\.id) { result.append(try #require(try fixture.wireID(id))) }
        return result
    }
}

// MARK: Replaying a large debt never holds a playback save for more than one step

extension ServerOwedReplayTests {
    private static func median(_ values: [Duration]) -> Duration { values.sorted()[values.count / 2] }

    /// On a 701-member queue the replay of a failed Keep sorted play load (and, when the load could not settle the
    /// keys either, the settlement) took hundreds of milliseconds in one transaction, and a playback save submitted
    /// meanwhile waited for all of it (420 ms; 250 ms for a settlement). Now:
    /// - every replay transaction is small (a few members, or a settlement's few statements);
    /// - each save submitted during the replay waits for at most one of them;
    /// - the first and the worst such save take no longer than this run's saves without a replay (their worst plus twice
    ///   their median, at least 20 ms), plus what the machine added to the slowest replay transaction over its median:
    ///   on a loaded host a transaction can stall for a WAL checkpoint or a descheduled thread, and a save behind it
    ///   waits for that too.
    @Test(arguments: [false, true]) func aConcurrentReplayCannotGateAPlaybackSave(unsettled: Bool) async throws {
        let f = try await ServerLibraryFixture()
        do {
            let s = f.store
            let ids = try await f.subscribeRegistered(ServerLibraryFixture.fetched(count: 702)).feed.episodes.map(\.id).sorted()
            _ = try await s.enqueue(Array(ids.prefix(700)))
            let before = try f.queueKeys()
            s.setQueueInsertionSettings(.init(keepSortedOrder: .dateNewOld))
            await s.injectRecorderFailure(after: 1)
            let session = try await s.beginPlayback(episodeID: ids[700])
            await s.injectRecorderFailure(after: nil)
            #expect(try f.rows("SELECT count(*) FROM ntp_owed WHERE intent = 'queue.add'") == [["1"]])
            if unsettled {
                try await s.unsettleQueueForTesting(before)
                #expect(try f.rows("SELECT count(*) FROM ntp_queue_keys") == [["700"]], "the loaded episode has no key yet")
            } else {
                #expect(try f.queueOrderMatchesKeys(), "the failed load settled the queue keys")
            }
            let order = try await s.queue().map(\.id)
            var position: Int32 = 1_000
            func sample() -> PlaybackSample {
                position += 1_000
                return PlaybackSample(positionMilliseconds: position, durationMilliseconds: 600_000, status: .playing)
            }
            // Saves with the debt owed and nothing replaying: this run's baseline.
            var plain: [Duration] = []
            for _ in 0..<40 {
                let start = ContinuousClock.now
                _ = try await s.recordPlayback(sessionID: session.id, sample: sample())
                plain.append(start.duration(to: .now))
            }
            await s.traceOwedReplayForTesting()
            let (starts, continuation) = AsyncStream<Void>.makeStream()
            let recovery = Task.detached {
                try await s.replayTimedForTesting {
                    continuation.yield(())
                    continuation.finish()
                }
            }
            for await _ in starts { break }
            // Saves submitted while the replay runs, the first as it takes the store, until it has recorded everything.
            var waits: [Duration] = [], waitedFor: [Int] = []
            while waits.count < 120 {
                let submitted = s.owedReplayTransactions.withLock { $0 }
                let start = ContinuousClock.now
                let ran = try await s.recordPlaybackCountingReplayForTesting(sessionID: session.id, sample: sample())
                waits.append(start.duration(to: .now))
                waitedFor.append(ran - submitted)
                guard try f.rows("SELECT count(*) FROM ntp_owed") != [["0"]] else { break }
            }
            let replay = try await recovery.value
            let trace = await s.owedReplayTrace ?? []
            let steps = trace.map(\.duration).sorted()
            let median = Self.median(plain), worstPlain = plain.max()!
            let stall = max(.zero, steps.last! - steps[steps.count / 2])
            let bound = worstPlain + max(.milliseconds(20), median * 2) + stall
            print("701-member queue, unsettled \(unsettled): saves without a replay median \(median), worst \(worstPlain); whole replay \(replay) in \(trace.count) transactions (median \(steps[steps.count / 2]), slowest \(steps.last!), most writes \(trace.map(\.writes).max()!)); \(waits.count) saves during it: first \(waits[0]), median \(Self.median(waits)), worst \(waits.max()!), each after at most \(waitedFor.max()!) replay transactions; bound \(bound)")
            #expect(waits.count >= 4, "saves complete while the replay is still running")
            #expect(waitedFor.contains(1), "saves ran between replay steps")
            #expect(trace.count >= 700 / FeedLibraryStore.owedReplayStepMembers, "the replay is made of small transactions")
            #expect(trace.allSatisfy { $0.writes <= 64 }, "no replay transaction does a whole queue's work: \(trace.map(\.writes).max()!) writes")
            #expect(trace.filter(\.settlement).count == (unsettled ? 1 : 0))
            #expect(waitedFor.allSatisfy { $0 <= 1 }, "each save waits for one replay transaction at most: \(waitedFor)")
            #expect(waits[0] < bound, "the first save waits for one replay step at most")
            #expect(waits.max()! < bound, "no save waits for more than one replay step")
            #expect(try await s.episode(id: ids[700])?.userState.positionMilliseconds == position)
            #expect(try f.rows("SELECT count(*) FROM ntp_owed") == [["0"]])
            #expect(try await s.queue().map(\.id) == order, "the queue's order never changed")
            #expect(try f.queueOrderMatchesKeys())
            await f.close()
        } catch { await f.close(); throw error }
    }
}

extension FeedLibraryStore {
    func traceOwedReplayForTesting() { owedReplayTrace = [] }

    /// A playback save, returning how many replay transactions had finished when it ran on the store.
    func recordPlaybackCountingReplayForTesting(sessionID: UUID, sample: PlaybackSample) throws -> Int {
        let finished = owedReplayTransactions.withLock { $0 }
        _ = try recordPlayback(sessionID: sessionID, sample: sample)
        return finished
    }
}

extension ServerOwedReplayTests {
    /// A failed Keep sorted play load on a queue of `size`: the loaded episode is the newest, so date new → old moves
    /// it to the front and reverses every other member. Returns the episode IDs (the loaded one is `ids[size]`).
    private func failedSortedLoad(_ fixture: ServerLibraryFixture, size: Int) async throws -> (ids: [Int64], session: LibraryPlaybackSession) {
        let store = fixture.store
        let ids = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched(count: size + 2)).feed.episodes.map(\.id).sorted()
        _ = try await store.enqueue(Array(ids.prefix(size)))
        try await Self.keepSorted(store, .dateNewOld)
        await store.injectRecorderFailure(after: 1)
        let session = try await store.beginPlayback(episodeID: ids[size])
        await store.injectRecorderFailure(after: nil)
        return (ids, session)
    }


    // An eligible write records the owed add before its own action but takes one bounded step only.
    @Test func anEligibleWriteRecordsTheOwedAddFirstAndTakesOneStep() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let (ids, _) = try await failedSortedLoad(fixture, size: 40)
            let count = try fixture.outboxCount()
            try await store.setFavorite(episodeID: ids[41], favorite: true)
            let facts = try fixture.newFacts(after: count)
            #expect(facts.first?.type == "queue.add")
            #expect(facts.first?.json["payload"]?["members"]?.arrayValue?.compactMap { $0["episode"]?["episode_id"]?.stringValue } == [try fixture.wireID(ids[40])])
            #expect(facts.map(\.type) == ["queue.add", "favorite.set"])
            #expect(facts.first?.json["payload"]?["moves"] == nil && facts.first?.json["payload"]?["place"] == ["kind": "end"])
            // The members the add re-sorted are shown with it (overlays of its fact), a step at a time.
            let shown = try fixture.overlays(opID: facts[0].opID).filter { $0[2] == "queue_position" }.count
            #expect(shown == FeedLibraryStore.owedReplayStepMembers, "the add and the first re-sorted members")
            #expect(try fixture.rows("SELECT count(*) FROM ntp_owed WHERE intent = 'queue.place'") != [["0"]], "the rest waits for the replay")
            try await store.replayOwedFacts()
            #expect(try fixture.rows("SELECT count(*) FROM ntp_owed") == [["0"]])
            #expect(try fixture.overlays(opID: facts[0].opID).filter { $0[2] == "queue_position" }.count == 41)
            #expect(try await outboxQueue(fixture) == (try await localWireQueue(fixture)))
        }
    }

    // Writes made while the replay runs, between its steps, leave the outbox telling the phone's queue.
    @Test func writesBetweenReplayStepsKeepTheQueueAgreed() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let (ids, session) = try await failedSortedLoad(fixture, size: 40)
            try await Self.keepSorted(store, nil)
            let replay = Task.detached { try await store.replayOwedFacts() }
            _ = try await store.removeFromQueue([ids[5]])
            _ = try await store.enqueue([ids[41]])
            _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 2_000, durationMilliseconds: 600_000, status: .playing))
            _ = try await store.performQueueMove(.item(ids[20], finalIndex: 0), expected: try await store.queue().map(QueueEpisodeIdentity.init))
            try await replay.value
            try await store.replayOwedFacts()
            #expect(try fixture.rows("SELECT count(*) FROM ntp_owed") == [["0"]])
            #expect(try fixture.queueOrderMatchesKeys())
            #expect(try await outboxQueue(fixture) == (try await localWireQueue(fixture)))
            #expect(try await !store.queue().map(\.id).contains(ids[5]))
        }
    }

    // A play load whose key settlement failed as well leaves the queue owed a settlement; the replay settles it first.
    @Test func aQueueLeftUnsettledIsSettledByTheReplay() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let ids = try await fixture.subscribeRegistered().feed.episodes.map(\.id).sorted()
            _ = try await store.enqueue([ids[3], ids[0]])
            try await Self.keepSorted(store, .episodeTitleAZ)
            let before = try fixture.queueKeys()
            await store.injectRecorderFailure(after: 1)
            _ = try await store.beginPlayback(episodeID: ids[1])
            await store.injectRecorderFailure(after: nil)
            try await store.unsettleQueueForTesting(before)
            #expect(try fixture.rows("SELECT intent FROM ntp_owed ORDER BY intent") == [["queue.add"], ["queue.settle"]])
            try await store.replayOwedFacts()
            #expect(try fixture.rows("SELECT count(*) FROM ntp_owed") == [["0"]])
            #expect(try fixture.queueOrderMatchesKeys())
            #expect(try await outboxQueue(fixture) == (try await localWireQueue(fixture)))
            #expect(try await store.queue().map(\.id) == [ids[0], ids[1], ids[3]])
        }
    }
}

// MARK: A settlement is planned off the store and applied only to the queue it was planned for

extension ServerOwedReplayTests {
    /// A failed Keep sorted load of a queue of `size` whose keys could not be settled either.
    private func unsettledLoad(_ fixture: ServerLibraryFixture, size: Int) async throws -> [Int64] {
        let store = fixture.store
        let ids = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched(count: size + 4)).feed.episodes.map(\.id).sorted()
        _ = try await store.enqueue(Array(ids.prefix(size)))
        try await Self.keepSorted(store, .dateNewOld)
        let before = try fixture.queueKeys()
        await store.injectRecorderFailure(after: 1)
        _ = try await store.beginPlayback(episodeID: ids[size])
        await store.injectRecorderFailure(after: nil)
        try await store.unsettleQueueForTesting(before)
        return ids
    }

    @Test func aSettlementPlannedForAnotherQueueIsNotApplied() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let ids = try await unsettledLoad(fixture, size: 70)
            let snapshot = try await store.owedSettlementSnapshot()
            let plan = try FeedLibraryStore.planOwedSettlement(snapshot)
            #expect(!plan.rows.isEmpty && plan.placements.count == 70)
            // The queue changed after the plan was made (here: as a remote unsubscribe's cascade would change it).
            var stale = snapshot
            stale.order.removeLast()
            let tables = try fixture.serverTables()
            #expect(try await store.applyOwedSettlementForTesting(plan, snapshot: stale) == false)
            #expect(try fixture.serverTables() == tables, "nothing of a stale settlement is written")
            try await store.replayOwedFacts()
            #expect(try fixture.rows("SELECT count(*) FROM ntp_owed") == [["0"]])
            #expect(try fixture.queueOrderMatchesKeys())
            #expect(try await outboxQueue(fixture) == (try await localWireQueue(fixture)))
            #expect(try await store.queue().map(\.id).first == ids[70])
        }
    }

    /// A long unsettled queue is not settled inside an eligible write's step (that would hold the store for the whole
    /// queue); a queue write keys the whole queue anyway, which settles it and owes what it re-keys.
    @Test func aQueueWriteSettlesALongUnsettledQueueAndOwesWhatItReKeys() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let ids = try await unsettledLoad(fixture, size: 70)
            try await store.setFavorite(episodeID: ids[72], favorite: true)
            #expect(try fixture.rows("SELECT count(*) FROM ntp_owed WHERE intent = 'queue.settle'") == [["1"]], "a favorite does not settle 71 members")
            _ = try await store.enqueue([ids[73]])
            #expect(try fixture.rows("SELECT count(*) FROM ntp_owed WHERE intent = 'queue.settle'") == [["0"]])
            #expect(try fixture.queueOrderMatchesKeys())
            try await store.replayOwedFacts()
            #expect(try fixture.rows("SELECT count(*) FROM ntp_owed") == [["0"]])
            #expect(try await outboxQueue(fixture) == (try await localWireQueue(fixture)))
        }
    }

    /// A short unsettled queue is settled by the next eligible write's step, before its own action.
    @Test func anEligibleWriteSettlesAShortUnsettledQueueFirst() async throws {
        try await withFixture { fixture in
            let store = fixture.store
            let ids = try await unsettledLoad(fixture, size: 6)
            try await store.setFavorite(episodeID: ids[8], favorite: true)
            #expect(try fixture.rows("SELECT count(*) FROM ntp_owed WHERE intent = 'queue.settle'") == [["0"]])
            #expect(try fixture.queueOrderMatchesKeys())
            try await store.replayOwedFacts()
            #expect(try await outboxQueue(fixture) == (try await localWireQueue(fixture)))
        }
    }
}

extension FeedLibraryStore {
    func applyOwedSettlementForTesting(_ plan: OwedSettlementPlan, snapshot: OwedSettlementSnapshot) throws -> Bool {
        guard let context = serverContext else { return false }
        return try database.transaction(durable: false) {
            try database.savepoint("ntp_owed") {
                try applyOwedSettlement(plan, snapshot: snapshot, writer: ServerOutboxWriter(database: database, context: context, failAfter: nil))
            }
        }
    }
}

extension FeedLibraryStore {
    /// What a play load leaves when settling its keys fails as well: the keys from before the load, and the queue
    /// owed a settlement instead of placements.
    func unsettleQueueForTesting(_ keys: [(episode: Int64, key: QueueKey, positionID: String)]) throws {
        try database.transaction {
            try database.execute("DELETE FROM ntp_queue_keys")
            for entry in keys {
                try database.execute("INSERT INTO ntp_queue_keys(episode_id, key, position_id, device_only) VALUES (?, ?, ?, 0)",
                                     [.integer(entry.episode), .text(entry.key.wire), .text(entry.positionID)])
            }
            try database.execute("DELETE FROM ntp_owed WHERE intent = 'queue.place'")
            try database.execute("INSERT INTO ntp_owed(intent, subject, record, created_at) SELECT 'queue.settle', 'queue', record, created_at FROM ntp_owed WHERE intent = 'queue.add' LIMIT 1")
        }
    }
}

extension FeedLibraryStore {
    /// Runs the replay after telling the caller it holds the store, and returns how long it took.
    func replayTimedForTesting(_ started: @Sendable () -> Void) async throws -> Duration {
        started()
        let start = ContinuousClock.now
        try await replayOwedFacts()
        return start.duration(to: .now)
    }
}

/// A pulled queue commit applied between two replay steps must not overwrite what the replay has not recorded yet;
/// owed placements are protected like pending overlays, and once the owed add is recorded they are overlays of its
/// fact.
@Suite(.serialized) struct ServerOwedReplayProjectionTests {
    /// 40 members sorted by duration, durations of 1–12 measured by another phone's player and reported to the server,
    /// a failed play load of 41 re-sorts them to [13…41, 1…12], one replay step runs (a favorite), then another phone's
    /// queue add already pulled is applied. The control drains the replay first.
    @Test(arguments: [(false, false), (true, false), (false, true)])
    func aPulledQueueCommitBetweenReplayStepsKeepsTheOwedOrder(drainFirst: Bool, shadow: Bool) async throws {
        try await ExchangeWorld.run(feeds: ["/one.xml": ("One", "one", 42)]) { w in
            let a = try await w.attach("A")
            let feed = try await a.store.insert(ServerAgreementTests.fetched(w.url("one.xml"), title: "One", prefix: "one", count: 42))
            try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: feed.id)
            let ids = try await a.store.feed(id: feed.id)!.episodes.map(\.id).sorted()
            a.store.setQueueInsertionSettings(.init(keepSortedOrder: .durationShortLong))
            try await a.store.setServerAccountPolicy(.sorting(keepSorted: true, order: .durationShortLong))
            _ = try await a.store.enqueue(Array(ids.prefix(40)))
            await a.exchange()
            // Another phone's player measures durations the feed lacks and reports them (the server's measured_duration
            // register, which sorts use); queued items are not re-sorted until an add.
            let d = try await w.attach("D")
            for id in ids.prefix(12) {
                var listening = RemoteSession(store: d.store, episode: try await ServerExchangeConcurrencyTests.same(id, from: a, on: d))
                try await listening.start(at: 0)
                try await listening.end(position: 0, contribution: 0, completed: false, duration: 600_000)
            }
            await d.exchange()
            await a.run([.pull, .apply])
            #expect(try await a.store.queue().map(\.id) == Array(ids.prefix(40)), "a measured duration alone re-sorts nothing")
            let c = try await w.attach("C")
            let other = try await ServerExchangeConcurrencyTests.same(ids[41], from: a, on: c)
            _ = try await c.store.enqueue([other])
            await c.exchange()
            await a.run([.pull])
            await a.store.injectRecorderFailure(after: 1)
            _ = try await a.store.beginPlayback(episodeID: ids[40])
            await a.store.injectRecorderFailure(after: nil)
            if drainFirst { try await a.store.replayOwedFacts() }
            try await a.store.setFavorite(episodeID: ids[40], favorite: true) // otherwise exactly one replay step
            let wanted = try await a.store.queue().map(\.id)
            #expect(wanted == Array(ids[12...40]) + Array(ids.prefix(12)), "the load re-sorted the queue")
            if !drainFirst { #expect(try await a.store.owedCountForTesting() > 0, "the replay is unfinished") }
            // Direct, or built in a shadow and published (the same projection on a read-only connection).
            if shadow { await a.engine.setBudgets(direct: 1) }
            let applied = await a.run([.apply])
            if shadow { #expect(applied.publishedUnits > 0, "the commit was published from a shadow") }
            let shown = try await a.store.queue().map(\.id).filter { $0 != ids[41] }
            #expect(shown == wanted, "applying another phone's queue commit keeps the unsent placements")
            try await a.store.replayOwedFacts()
            #expect(try await a.store.queue().map(\.id).filter { $0 != ids[41] } == wanted, "the finished replay keeps the order")
            // The server learns it: a fresh attach shows the phone's order.
            await a.exchange()
            let fresh = try await w.attach("fresh")
            var served: [Int64] = []
            for id in try await fresh.store.queue().map(\.id) {
                served.append(try await ServerExchangeConcurrencyTests.same(id, from: fresh, on: a))
            }
            #expect(served.filter { $0 != ids[41] } == wanted, "the server's queue reads like the phone's")
        }
    }
}

extension ServerOwedReplayProjectionTests {
    /// Applies one synthetic commit of `records` after the live cursor, directly (PROTOCOL §6.8).
    private func apply(_ fixture: ServerLibraryFixture, seq: Int64, log: String, _ records: [ServerRecord]) async throws {
        let digest = { (n: Int64) in String(repeating: String(n % 10), count: 64) }
        if seq == 1 { try await fixture.store.setCursor(try SyncCursor(logID: log, epoch: 1, seq: 0, digest: digest(0)), watermark: nil) }
        let cursor = try SyncCursor(logID: log, epoch: 1, seq: seq, digest: digest(seq))
        _ = try await fixture.store.applyServerUnit(.init(commit: .init(epoch: 1, seq: seq, records: records), cursor: cursor, now: 1_760_000_000_000),
                                                    history: nil, maxWork: nil)
    }

    /// An owed add is a pending membership and dismissal: a commit about its episode (the server still has it out of the
    /// queue and new) leaves it queued and out of the Inbox.
    @Test func anOwedAddStaysQueuedAndOutOfTheInboxThroughAPulledCommit() async throws {
        let f = try await ServerLibraryFixture()
        do {
            let s = f.store, log = ContractIdentity.randomUUID()
            let ids = try await f.subscribeRegistered(ServerLibraryFixture.fetched(count: 6)).feed.episodes.map(\.id).sorted()
            _ = try await s.enqueue([ids[0], ids[1]])
            try await s.setFavorite(episodeID: ids[3], favorite: true) // the account knows the episode
            let wire3 = try #require(try f.wireID(ids[3]))
            try await apply(f, seq: 1, log: log, [ServerRecord(entity: "episode", id: wire3, fieldGroup: "play_state", value: ["play_state": "new"])])
            #expect(try await s.episode(id: ids[3])?.userState.playState == .new)
            await s.injectRecorderFailure(after: 1)
            _ = try await s.beginPlayback(episodeID: ids[3])
            await s.injectRecorderFailure(after: nil)
            #expect(try await s.queue().map(\.id) == [ids[0], ids[1], ids[3]])
            #expect(try await s.episode(id: ids[3])?.userState.playState == .unplayed)
            try await apply(f, seq: 2, log: log, [
                ServerRecord(entity: "episode", id: wire3, fieldGroup: "play_state", value: ["play_state": "new"]),
                ServerRecord(entity: "episode", id: wire3, fieldGroup: "queue_membership", value: ["in_queue": false]),
            ])
            #expect(try await s.queue().map(\.id) == [ids[0], ids[1], ids[3]], "the owed add stays queued")
            #expect(try await s.episode(id: ids[3])?.userState.playState == .unplayed, "the queued episode does not go back to the Inbox")
            #expect(try f.queueOrderMatchesKeys())
            await f.close()
        } catch { await f.close(); throw error }
    }

    /// A queue whose keys the load could not settle keeps its order and keys through a pulled queue commit, until the
    /// replay settles and records them.
    @Test func anUnsettledQueueKeepsItsOrderThroughAPulledCommit() async throws {
        let f = try await ServerLibraryFixture()
        do {
            let s = f.store, log = ContractIdentity.randomUUID()
            let ids = try await f.subscribeRegistered(ServerLibraryFixture.fetched(count: 6)).feed.episodes.map(\.id).sorted()
            _ = try await s.enqueue([ids[3], ids[0], ids[1]])
            let before = try f.queueKeys()
            s.setQueueInsertionSettings(.init(keepSortedOrder: .episodeTitleAZ))
            await s.injectRecorderFailure(after: 1)
            _ = try await s.beginPlayback(episodeID: ids[2])
            await s.injectRecorderFailure(after: nil)
            try await s.unsettleQueueForTesting(before)
            let order = try await s.queue().map(\.id)
            #expect(order == [ids[0], ids[1], ids[2], ids[3]])
            let keys = try f.rows("SELECT episode_id, key FROM ntp_queue_keys ORDER BY episode_id")
            // The server still has [3, 0, 1]; another phone moves 1 to the front.
            let wire1 = try #require(try f.wireID(ids[1]))
            let front = try QueueKey.between(nil, before.map(\.key).min(), positionWriteID: UUID())
            try await apply(f, seq: 1, log: log, [
                ServerRecord(entity: "episode", id: wire1, fieldGroup: "queue_membership", value: ["in_queue": true]),
                ServerRecord(entity: "episode", id: wire1, fieldGroup: "queue_position", value: ["key": .string(front.wire), "position_id": .string(ContractIdentity.randomUUID())]),
            ])
            #expect(try await s.queue().map(\.id) == order, "the owed order is kept")
            #expect(try f.rows("SELECT episode_id, key FROM ntp_queue_keys ORDER BY episode_id") == keys)
            try await s.replayOwedFacts()
            #expect(try await s.queue().map(\.id) == order)
            #expect(try f.queueOrderMatchesKeys())
            #expect(try f.rows("SELECT count(*) FROM ntp_owed") == [["0"]])
            await f.close()
        } catch { await f.close(); throw error }
    }
}

extension FeedLibraryStore {
    func owedCountForTesting() throws -> Int64 { try database.scalar("SELECT count(*) FROM ntp_owed") }
}
