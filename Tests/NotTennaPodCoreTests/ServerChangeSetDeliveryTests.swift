import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// Delivery at the consumers' boundary: the change hub's subscribers (every origin, several subscribers, a late one, the
/// store's close), the persisted order of visible changes, and the sync engine telling what each step committed before
/// it goes on to the network.
@Suite(.serialized) struct ServerChangeSetDeliveryTests {
    /// The stream's sets until it finishes, or nil when it has not finished within `limit` (a stalled or never-finished
    /// stream).
    static func drain<T: Sendable>(_ stream: AsyncStream<T>, within limit: Duration = .seconds(10)) async -> [T]? {
        await withTaskGroup(of: [T]?.self) { group in
            group.addTask {
                var values: [T] = []
                for await value in stream { values.append(value) }
                return Task.isCancelled ? nil : values
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The first element `matching` within `limit`, nil when none came (it was never told, or told too late).
    static func first<T: Sendable>(_ stream: AsyncStream<T>, within limit: Duration = .seconds(5), matching: @escaping @Sendable (T) -> Bool) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                for await value in stream where matching(value) { return value }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// `rounds` writes, each a visible change (a favorite toggled), alternately of the sync engine's and the person's.
    static func writes(_ store: FeedLibraryStore, _ ids: [Int64], rounds: Int) async throws {
        for round in 0..<rounds {
            let id = ids[round % ids.count]
            let on = !(try await store.episode(id: id)?.userState.isFavorite ?? false)
            if round % 2 == 0 {
                try await LibraryChangeOrigin.$current.withValue(.sync) { try await store.setFavorite(episodeID: id, favorite: on) }
            } else {
                try await store.setFavorite(episodeID: id, favorite: on)
            }
        }
    }

    /// Two subscribers from the start and a late one: every set reaches each, in order, with consecutive sequences, the
    /// right identity and origins; the late one gets exactly the suffix after its baseline; the store's close finishes all
    /// three and its receipt is the last set. A hub that drops delivery (a mutation) leaves the subscribers empty.
    @Test(arguments: [false, true]) func everySubscriberGetsEverySetInOrder(mutated: Bool) async throws {
        let fixture = try await ServerLibraryFixture(server: false)
        let store = fixture.store
        let feed = try await store.insert(ServerLibraryFixture.fetched(count: 6))
        let ids = feed.episodes.map(\.id)
        if mutated { store.changes.setFaultsForTesting([.dropDelivery]) }
        let first = store.changes.subscribe(), second = store.changes.subscribe()
        #expect(first.baseline == second.baseline && first.identity == store.changes.identity)
        try await Self.writes(store, ids, rounds: 40)
        let late = store.changes.subscribe()
        #expect(late.baseline == first.baseline + 40, "the late baseline is the receipt so far: \(late.baseline)")
        try await Self.writes(store, ids.reversed(), rounds: 20)
        let receipt = store.changes.emitted
        try await store.close()
        let early = await Self.drain(first.changes), other = await Self.drain(second.changes), after = await Self.drain(late.changes)
        #expect(early != nil && other != nil && after != nil, "every stream finished at the close")
        if mutated {
            #expect(early?.isEmpty == true && after?.isEmpty == true, "dropped")
            await fixture.close()
            return
        }
        for (name, sets, baseline) in [("first", early ?? [], first.baseline), ("second", other ?? [], second.baseline), ("late", after ?? [], late.baseline)] {
            #expect(sets.map(\.sequence) == Array((baseline + 1)...receipt), "\(name): \(sets.map(\.sequence))")
            #expect(sets.allSatisfy { $0.identity == store.changes.identity && !$0.isEmpty }, "\(name)")
        }
        let origins = (early ?? []).map(\.origin)
        #expect(origins.prefix(4) == [.sync, .local, .sync, .local], "\(origins.prefix(4))")
        await fixture.close()
    }

    /// A set is with its subscribers when the write returns (the store's transaction emits it before returning), never
    /// stalled until a later write.
    @Test func aSetIsDeliveredWhenItsWriteReturns() async throws {
        let fixture = try await ServerLibraryFixture(server: false)
        let store = fixture.store
        let feed = try await store.insert(ServerLibraryFixture.fetched(count: 2))
        let subscription = store.changes.subscribe()
        try await store.setFavorite(episodeID: feed.episodes[0].id, favorite: true)
        let told = await Self.first(subscription.changes, within: .seconds(5)) { _ in true }
        #expect(told?.episodes[feed.episodes[0].id] != nil, "\(String(describing: told))")
        await fixture.close()
    }

    /// A subscription made after (or while) the store closes finishes at once: no consumer of a closed library waits for
    /// sets that never come. Without the terminal state (a mutation), it never finishes.
    @Test(arguments: [false, true]) func aSubscriptionAfterTheCloseFinishesAtOnce(mutated: Bool) async throws {
        let fixture = try await ServerLibraryFixture(server: false)
        let store = fixture.store
        if mutated { store.changes.setFaultsForTesting([.noTerminalFlag]) }
        try await store.close()
        let late = store.changes.subscribe()
        let sets = await Self.drain(late.changes, within: .seconds(mutated ? 2 : 10))
        if mutated { #expect(sets == nil, "never finishes") } else { #expect(sets?.isEmpty == true) }
        await fixture.close()
    }

    // MARK: - The persisted order

    /// Sets the persisted order's row (schema 21 creates the table with its row at 0), or deletes it (nil: a damaged library).
    static func setSequence(_ store: FeedLibraryStore, row: Int64?) async throws {
        try await store.databaseForTesting { db in
            if let row {
                try db.execute("UPDATE \(LibraryChangeCapture.sequenceTable) SET seq = ? WHERE id = 1", [.integer(row)])
            } else {
                try db.execute("DELETE FROM \(LibraryChangeCapture.sequenceTable)")
            }
            try db.refreshChangeCapture()
        }
    }

    /// The order's table without its row is damaged: a visible write fails and changes nothing (never a silent
    /// per-opening count).
    @Test func aSequenceTableWithoutItsRowFailsClosed() async throws {
        let fixture = try await ServerLibraryFixture(server: false)
        let store = fixture.store
        let feed = try await store.insert(ServerLibraryFixture.fetched(count: 2))
        try await Self.setSequence(store, row: nil)
        await #expect(throws: LibraryChangeSequenceError.missingRow) {
            try await store.setFavorite(episodeID: feed.episodes[0].id, favorite: true)
        }
        #expect(try await store.episode(id: feed.episodes[0].id)?.userState.isFavorite == false, "rolled back")
        await fixture.close()
    }

    /// With its row, the persisted sequence moves on before COMMIT for each visible set only (a net-zero write takes
    /// none), the hub's baseline and receipt are it, and a reopened library continues from it.
    @Test func thePersistedSequenceOrdersVisibleSetsAcrossAReopen() async throws {
        let fixture = try await ServerLibraryFixture(server: false)
        var store = fixture.store
        let feed = try await store.insert(ServerLibraryFixture.fetched(count: 2))
        try await Self.setSequence(store, row: 7)
        let id = feed.episodes[0].id
        #expect(store.changes.subscribe().baseline >= 0)
        let log = await store.recordCommitsForTesting()
        try await store.setFavorite(episodeID: id, favorite: true)
        try await store.setFavorite(episodeID: id, favorite: true)
        try await store.setFavorite(episodeID: id, favorite: false)
        #expect(log.sets.map(\.sequence) == [8, 9], "the net-zero write took no sequence: \(log.sets.map(\.sequence))")
        #expect(try await store.databaseForTesting { try $0.changeSequence() } == 9)
        try await store.close()
        store = try FeedLibraryStore(url: fixture.url)
        let subscription = store.changes.subscribe()
        #expect(subscription.baseline == 9, "continues from the persisted order: \(subscription.baseline)")
        try await store.setFavorite(episodeID: id, favorite: true)
        let told = await Self.first(subscription.changes) { _ in true }
        #expect(told?.sequence == 10)
        try await store.close()
        await fixture.close()
    }

    /// Schema 21's own row (created at 0 with every library) is the persisted order: each visible set takes the next
    /// number before its COMMIT, so any read transaction reads exactly the prefix of sets its snapshot holds. A snapshot
    /// opened before a write keeps reading the earlier number with the earlier state while the write commits; a new one
    /// reads the write's number, which is the hub's receipt when the write returns; a net-zero write moves nothing.
    @Test func schema21sRowIsTheOrderAReadSnapshotReadsItsPrefixBy() async throws {
        let fixture = try await ServerLibraryFixture(server: false)
        let store = fixture.store
        #expect(try RawLibrary.rows(fixture.url, "SELECT count(*) FROM \(LibraryChangeCapture.sequenceTable)") == [["1"]], "schema 21's row")
        let feed = try await store.insert(ServerLibraryFixture.fetched(count: 3))
        let ids = feed.episodes.map(\.id).sorted()
        let reader = try LibrarySQLite(readingOnly: fixture.url)
        defer { try? reader.close() }
        /// One read transaction: the order's number and the favorites it shows.
        func snapshot(_ body: () async throws -> Void = {}) async throws -> (seq: Int64, favorites: [Bool]) {
            try reader.execute("BEGIN")
            defer { try? reader.execute("COMMIT") }
            let seq = try reader.scalar("SELECT seq FROM \(LibraryChangeCapture.sequenceTable) WHERE id = 1")
            try await body()
            var favorites: [Bool] = []
            for id in ids {
                let record = try #require(try reader.rows("SELECT record FROM episodes WHERE id = ?", [.integer(id)]).first?.first?.data)
                favorites.append(try JSONDecoder().decode(LibraryEpisode.self, from: record).userState.isFavorite)
            }
            #expect(try reader.scalar("SELECT seq FROM \(LibraryChangeCapture.sequenceTable) WHERE id = 1") == seq, "one snapshot, one number")
            return (seq, favorites)
        }
        let start = try await snapshot()
        #expect(start.seq == store.changes.emitted, "the persisted number is the receipt so far: \(start.seq)")
        var states: [Int64: [Bool]] = [start.seq: start.favorites]
        var shown = start.favorites
        for (step, id) in [ids[0], ids[1], ids[0], ids[2]].enumerated() {
            let index = ids.firstIndex(of: id)!
            shown[index].toggle()
            let value = shown[index]
            // A snapshot open across the write still reads the earlier prefix.
            let held = try await snapshot { try await store.setFavorite(episodeID: id, favorite: value) }
            #expect(held.seq == start.seq + Int64(step) && states[held.seq] == held.favorites, "the earlier prefix: \(held)")
            let receipt = store.changes.emitted
            let now = try await snapshot()
            #expect(now.seq == receipt && receipt == start.seq + Int64(step) + 1, "the write's number is its receipt: \(now.seq), \(receipt)")
            #expect(now.favorites == shown, "the snapshot holds exactly the sets up to its number")
            states[now.seq] = now.favorites
        }
        try await store.setFavorite(episodeID: ids[0], favorite: shown[0])
        #expect(try await snapshot().seq == start.seq + 4 && store.changes.emitted == start.seq + 4, "a net-zero write takes no number")
        await fixture.close()
    }

    /// The derived tables are model tables of relation `episode` covered by the capture's sources: every trigger the schema
    /// keeps them with fires on a table the capture watches (or on a derived table itself), so no write changes them without
    /// a change the capture reports in the same transaction.
    @Test func everyDerivedTriggerFiresOnATableTheCaptureWatches() async throws {
        let fixture = try await ServerLibraryFixture()
        let rows = try RawLibrary.rows(fixture.url, "SELECT name, tbl_name, sql FROM sqlite_master WHERE type = 'trigger'")
        let watched = Set(LibraryChangeCapture.modelTables + LibraryChangeCapture.derivedTables)
        var derived = 0
        for row in rows {
            guard let name = row[0], let table = row[1], let sql = row[2],
                  LibraryChangeCapture.derivedTables.contains(where: { sql.contains("INTO \($0)") || sql.contains("UPDATE \($0)") || sql.contains("DELETE FROM \($0)") }) else { continue }
            derived += 1
            #expect(watched.contains(table), "\(name) keeps the derived data from \(table), which the capture does not watch")
        }
        #expect(derived >= 15, "the derived triggers were found: \(derived)")
        await fixture.close()
    }

    /// A negative control of the oracle's derived model: a derived key row (and its podcast's counts) changed directly, with
    /// no change of what they derive from, is reported (the set covers nothing of it, and the data no longer equals the
    /// records' derivation).
    @Test func theOracleReportsADerivedChangeTheSetDoesNotCover() async throws {
        let fixture = try await ServerLibraryFixture(server: false)
        let store = fixture.store
        let feed = try await store.insert(ServerLibraryFixture.fetched(count: 3))
        let oracle = ChangeSetOracle()
        await store.installChangeOracleForTesting(oracle)
        try await store.setFavorite(episodeID: feed.episodes[0].id, favorite: true)
        #expect(oracle.mismatches.isEmpty, "a real write is covered: \(oracle.report)")
        try await store.databaseForTesting { db in
            try db.transaction { try db.execute("UPDATE episode_list_keys SET favorite = 1 - favorite WHERE id = ?", [.integer(feed.episodes[1].id)]) }
        }
        let report = oracle.report
        #expect(report.contains("derived: expected") && report.contains("the key row of episode \(feed.episodes[1].id) changed")
                    && report.contains("the counts of podcast \(feed.id) changed"), "\(report)")
        #expect(report.contains("derived data"), "\(report)")
        await store.removeChangeOracleForTesting()
        await fixture.close()
    }

    // MARK: - The engine tells before it goes on

    static func engine(_ fixture: ServerLibraryFixture) throws -> ServerSyncEngine {
        try ServerSyncEngine(store: fixture.store, database: fixture.url, syncDatabase: fixture.directory.appendingPathComponent("sync.sqlite"),
                             staging: fixture.directory.appendingPathComponent("staging"),
                             transport: ServerSyncEngineUnitTests.Transport { _, _ in [:] }, vault: fixture.vault)
    }

    /// Paused at 10 s while a recovery holds the position; the base already has another device's 25 s. The hold's release
    /// commits; its knowledge reaches the adoption before the step returns, so the player adopts and Play starts at 25 s.
    /// Telling only at the exchange's end (a mutation) leaves the release untold while the exchange goes on: Play starts
    /// at the stale 10 s.
    @Test(arguments: [false, true]) func aHoldsReleaseIsToldBeforeTheExchangeGoesOn(mutated: Bool) async throws {
        typealias Baseline = ServerAdoptionBaselineTests
        let (fixture, store, one, _) = try await Baseline.library(at: 10_000)
        let player = StorePlayer(store)
        try await player.load(one)
        let newer = ContractIdentity.randomUUID()
        try await store.installBaseUnderHoldForTesting(ServerLocalPlaybackTests.one, Baseline.position(newer, 25_000, lastPlayed: Baseline.now + 100_000))
        let engine = try Self.engine(fixture)
        if mutated { await engine.setDeferDeliveryForTesting(true) }
        let events = await engine.events()
        _ = try await LibraryChangeOrigin.$current.withValue(.sync) { try await engine.releaseHoldsForTesting() }
        let untold = !store.syncChanges.isEmpty
        let knowledge = await Self.first(events, within: .seconds(mutated ? 2 : 10)) { event in
            if case .positionKnowledge(let known) = event { return known.concerns(one) }
            return false
        }
        // The app's driver: knowledge about the paused player's episode attempts its adoption.
        if knowledge != nil { _ = try await player.adopt() }
        try await player.play()
        let start = try #require(try Baseline.lastStart(fixture))
        if mutated {
            #expect(untold && knowledge == nil && start["start_position"]?.integerValue == 10_000, "\(start)")
        } else {
            #expect(!untold, "nothing committed is left untold")
            #expect(start["start_position"]?.integerValue == 25_000 && start["observed_claim"]?.stringValue == newer, "\(start)")
        }
        await engine.close()
        await fixture.close()
    }

    /// Against the server: another device's changes are pulled and archived but not applied yet, and this phone has a
    /// change to push. The Force full synchronization applies them as units, then pushes: at that request, and at every
    /// request of the engine, nothing it committed is left untold (the request barrier). Telling only at the exchange's
    /// end (a mutation) leaves the units untold at the push.
    @Test(arguments: [false, true]) func nothingCommittedIsUntoldAtARequest(mutated: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, ids, _) = try await ServerExchangeConcurrencyTests.twoPhones(world)
            let onB = try await ServerExchangeConcurrencyTests.same(ids[0], from: a, on: b)
            try await b.store.setFavorite(episodeID: onB, favorite: true)
            try await b.store.markEpisodePlayed(episodeID: onB, played: true)
            await b.exchange()
            await a.run([.pull])
            try await a.store.setFavorite(episodeID: ids[1], favorite: true)
            let store = a.store
            let violations = Mutex<[String]>([])
            let requests = Mutex<[String]>([])
            await a.engine.setRequestBarrierHook { path in
                requests.withLock { $0.append(path) }
                if !store.syncChanges.isEmpty { violations.withLock { $0.append(path) } }
            }
            if mutated { await a.engine.setDeferDeliveryForTesting(true) }
            await a.engine.requestFullSynchronization()
            _ = await a.engine.forceFullSynchronization()
            await a.exchange()
            let found = violations.withLock { $0 }
            #expect(requests.withLock { $0.contains("v1/push") }, "\(requests.withLock { $0 })")
            #expect(try await a.store.episode(id: ids[0])?.userState.isFavorite == true, "B's change applied")
            if mutated { #expect(!found.isEmpty, "the deferred delivery is caught") } else { #expect(found.isEmpty, "untold at \(found)") }
        }
    }
}
