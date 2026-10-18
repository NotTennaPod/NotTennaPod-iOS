import Foundation
import Testing
@testable import NotTennaPodCore

/// A paused player decides against an observed-record baseline that is consumed only when a decision is settled
/// (adopted, its own claim, a rebaseline, the loaded position), with a listened high-water mark that only settled
/// decisions move. Checked through the player's actual resume (`session.start` and its observed claim), the
/// written baseline, and every witness's mutation of the rule.
@Suite(.serialized) struct ServerAdoptionBaselineTests {
    typealias Local = ServerLocalPlaybackTests
    /// The players' clock (`StorePlayer`): their listening is at about this time.
    static let now: Int64 = 1_760_000_000_000

    static func position(_ claim: String, _ position: Int64, lastPlayed: Int64, provenance: [String] = []) -> [ServerRecord] {
        [ServerRecord(entity: "episode", id: Local.one, fieldGroup: "position",
                      value: ["generation_id": .string(Local.generation), "position": .integer(position), "claim_id": .string(claim)],
                      provenance: provenance.isEmpty ? [ContractIdentity.randomUUID()] : provenance),
         ServerRecord(entity: "episode", id: Local.one, fieldGroup: "last_played",
                      value: ["generation_id": .string(Local.generation), "time": .integer(lastPlayed)])]
    }

    /// The library of `ServerLocalPlaybackTests` with episode one's position under another device's claim O at `position`,
    /// last played an hour before the players' clock.
    static func library(claim: String = ContractIdentity.randomUUID(), at position: Int64 = 0)
        async throws -> (fixture: ServerLibraryFixture, store: FeedLibraryStore, one: Int64, log: CommitLog) {
        let (fixture, _, one, _) = try await Local.library()
        _ = try await fixture.store.applyRecordsForTesting(Self.position(claim, position, lastPlayed: now - 3_600_000))
        let log = await fixture.store.recordCommitsForTesting()
        return (fixture, fixture.store, one, log)
    }

    static func transition(_ store: FeedLibraryStore) async throws -> ServerPendingTransition? {
        try await store.transitionStateForTesting().current
    }

    static func lastStart(_ fixture: ServerLibraryFixture) throws -> ContractJSON? {
        try fixture.outbox().last { $0.type == "session.start" }?.payload
    }

    // MARK: - A version seen while own intent is pending is reconsidered

    /// Paused at 120 s with this phone's start P still pending; another device resets the episode to 0 with a later claim C
    /// that does not depend on P. While P is pending nothing is decided or written; once P is accepted (C still owns the
    /// position, the record unchanged) the retirement is a knowledge event, and the check adopts C: Play then starts at 0
    /// observing C. A rebaseline under pending intent would never adopt.
    @Test(arguments: [false, true]) func aForeignResetSeenWhileTheOwnStartIsPendingIsAdoptedOnceItRetires(mutated: Bool) async throws {
        let (fixture, store, one, log) = try await Self.library()
        if mutated { await store.setAdoptionFaultsForTesting([.rebaselineWhilePending]) }
        let player = StorePlayer(store)
        try await player.load(one)
        let observed = try #require(try await Self.transition(store)?.observed)
        #expect(observed.settled, "the loaded position came from the record")
        try await player.play(); try await player.listen(120, every: 60); try await player.pause()
        let reset = ContractIdentity.randomUUID()
        _ = try await store.applyRecordsForTesting(Self.position(reset, 0, lastPlayed: Self.now + 200_000))
        if !mutated {
            #expect(try await store.serverAdoptionCheck(episodeID: one) == .none, "own intent pending")
            #expect(try await player.adopt() == nil)
            #expect(try await Self.transition(store)?.observed == observed, "nothing written while the intent is pending")
        } else {
            _ = try await player.adopt()
        }
        log.removeAll()
        _ = try await store.retireOutboxForTesting()
        #expect(log.take().knowledge?.episodes.contains(one) == true, "the retirement is a knowledge event")
        let adopted = try await player.adopt()
        if mutated {
            #expect(adopted == nil, "a rebaseline under pending intent keeps the stale 120 s")
            await fixture.close()
            return
        }
        #expect(adopted == 0)
        try await player.play()
        let start = try #require(try Self.lastStart(fixture))
        #expect(start["start_position"]?.integerValue == 0 && start["observed_claim"]?.stringValue == reset, "\(start)")
        await fixture.close()
    }

    /// The same, but P wins (accepted after C): the record becomes P, this phone's own claim, a rebaseline; the player
    /// stays at 120 s and the baseline is P.
    @Test func whenTheOwnStartWinsTheVersionIsARebaseline() async throws {
        let (fixture, store, one, _) = try await Self.library()
        let player = StorePlayer(store)
        try await player.load(one)
        try await player.play(); try await player.listen(120, every: 60); try await player.pause()
        _ = try await store.applyRecordsForTesting(Self.position(ContractIdentity.randomUUID(), 0, lastPlayed: Self.now + 100))
        let start = try #require(try fixture.outbox().first { $0.type == "session.start" }).opID
        _ = try await store.retireOutboxForTesting(records: Self.position(start, 120_000, lastPlayed: Self.now + 120_000))
        #expect(try await store.serverAdoptionCheck(episodeID: one) == .rebaseline)
        #expect(try await player.adopt() == nil)
        #expect(try await store.episode(id: one)?.userState.positionMilliseconds == 120_000)
        #expect(try await Self.transition(store)?.observed?.claim == start, "the own claim is the baseline")
        #expect(try await store.serverAdoptionCheck(episodeID: one) == .none, "then nothing new")
        await fixture.close()
    }

    /// A load while own intent is pending: the baseline is unsettled, so the same version is adopted once the intent retires.
    @Test func aLoadUnderPendingIntentLeavesTheBaselineUnsettled() async throws {
        let (fixture, store, one, two) = try await { () async throws -> (ServerLibraryFixture, FeedLibraryStore, Int64, Int64) in
            let (fixture, _, one, two) = try await Local.library()
            _ = try await fixture.store.applyRecordsForTesting(Self.position(ContractIdentity.randomUUID(), 0, lastPlayed: Self.now - 3_600_000))
            return (fixture, fixture.store, one, two)
        }()
        let player = StorePlayer(store)
        try await player.load(one)
        try await player.play(); try await player.listen(60, every: 60); try await player.pause()
        let reset = ContractIdentity.randomUUID()
        _ = try await store.applyRecordsForTesting(Self.position(reset, 0, lastPlayed: Self.now + 100_000))
        try await player.load(two)
        try await player.load(one)
        let observed = try #require(try await Self.transition(store)?.observed)
        #expect(observed.claim == reset && !observed.settled, "loaded under pending intent: \(observed)")
        _ = try await store.retireOutboxForTesting()
        #expect(try await store.serverAdoptionCheck(episodeID: one) == .adopt)
        await fixture.close()
    }

    // MARK: - The high-water mark

    /// Settled O in lineage L1 (listening up to an hour ago), this phone's start P pending; an accepted restore's
    /// lineage L2 shows claim C at 0 with later listening. While P is pending the check is `none` and nothing moves; once
    /// P retires, C (newer than everything known) is adopted. A high-water mark moving on
    /// `none` rebaselines it instead and keeps the stale position, as does a rule that never adopts another lineage.
    @Test(arguments: [nil, FeedLibraryStore.AdoptionFault.highWaterOnNone, .neverAdopt])
    func aCrossLineageVersionSeenWhilePendingIsAdoptedOnceItRetires(fault: FeedLibraryStore.AdoptionFault?) async throws {
        let (fixture, store, one, _) = try await Self.library()
        let mutated = fault != nil
        if let fault { await store.setAdoptionFaultsForTesting([fault]) }
        let player = StorePlayer(store)
        try await player.load(one)
        try await player.play(); try await player.listen(60, every: 60); try await player.pause()
        try await store.setLineageForTesting(log: ContractIdentity.randomUUID())
        let restored = ContractIdentity.randomUUID()
        _ = try await store.applyRecordsForTesting(Self.position(restored, 0, lastPlayed: Self.now + 600_000))
        #expect(try await store.serverAdoptionCheck(episodeID: one) == .none)
        let high = try await Self.transition(store)?.listenedHighWater
        #expect(try await player.adopt() == nil)
        if !mutated { #expect(try await Self.transition(store)?.listenedHighWater == high, "a none moves nothing") }
        _ = try await store.retireOutboxForTesting()
        let adopted = try await player.adopt()
        if mutated {
            #expect(adopted == nil, "\(String(describing: fault)) refuses the newer listening")
        } else {
            #expect(adopted == 0, "newer than everything known: adopted")
            try await player.play()
            #expect(try Self.lastStart(fixture)?["observed_claim"]?.stringValue == restored)
        }
        await fixture.close()
    }

    /// Listening known up to T; a restore L2 shows an older last played (T − 200 s): rebaselined, the mark stays
    /// T; a second restore L3 shows T − 100 s, newer than L2's but older than T: rebaselined too, never adopted.
    @Test(arguments: [false, true]) func olderListeningOfRestoredLineagesIsNeverAdopted(mutated: Bool) async throws {
        let (fixture, store, one, _) = try await Self.library()
        if mutated { await store.setAdoptionFaultsForTesting([.alwaysAdopt]) }
        let player = StorePlayer(store)
        try await player.load(one)
        let known = try #require(try await Self.transition(store)?.listenedHighWater)
        for older: Int64 in [200_000, 100_000] {
            try await store.setLineageForTesting(log: ContractIdentity.randomUUID())
            _ = try await store.applyRecordsForTesting(Self.position(ContractIdentity.randomUUID(), 99_000, lastPlayed: known - older))
            let adopted = try await player.adopt()
            if mutated { #expect(adopted == 99_000); break }
            #expect(adopted == nil, "older than \(known): \(String(describing: adopted))")
            #expect(try await Self.transition(store)?.listenedHighWater == known, "never lower")
        }
        await fixture.close()
    }

    // MARK: - Migration, idempotence, provenance

    /// A transition persisted before baselines (only the claim and its position): the same claim at the same number is
    /// rebaselined and the baseline persists; a paused seek to 120 s stands; another device's completion under the same
    /// claim back to 0 (a new provenance) is adopted, and Play starts at 0. Ignoring the provenance keeps the 120 s.
    @Test(arguments: [false, true]) func aTransitionFromBeforeBaselinesMigratesOnce(mutated: Bool) async throws {
        let claim = ContractIdentity.randomUUID()
        let (fixture, store, one, _) = try await Self.library(claim: claim, at: 0)
        if mutated { await store.setAdoptionFaultsForTesting([.ignoreProvenance]) }
        let player = StorePlayer(store)
        try await player.load(one)
        try await store.stripBaselineForTesting()
        #expect(try await Self.transition(store)?.observed == nil)
        _ = try await store.applyRecordsForTesting(Self.position(claim, 0, lastPlayed: Self.now - 3_600_000))
        #expect(try await player.adopt() == nil, "the same claim at the same number: nothing new")
        let baseline = try #require(try await Self.transition(store)?.observed, "the rebaseline persisted")
        #expect(baseline.claim == claim && baseline.settled)
        try await player.seek(to: 120_000); try await player.pause()
        #expect(try await player.adopt() == nil, "the paused seek stands")
        // A lazy completion: the same claim, a new provenance, no listening (the last played unchanged).
        _ = try await store.applyRecordsForTesting(Self.position(claim, 0, lastPlayed: Self.now - 3_600_000))
        let adopted = try await player.adopt()
        if mutated { #expect(adopted == nil); await fixture.close(); return }
        #expect(adopted == 0, "a completion back to 0 under the same claim")
        try await player.play()
        #expect(try Self.lastStart(fixture)?["start_position"]?.integerValue == 0)
        await fixture.close()
    }

    /// The settled baseline's version again is nothing, with nothing written; this device's own claim is a rebaseline;
    /// a rebaseline decided but not written (a mutation) leaves the old baseline in place.
    @Test(arguments: [false, true]) func repeatedChecksAreIdempotentAndARebaselineIsWritten(mutated: Bool) async throws {
        let (fixture, store, one, log) = try await Self.library()
        if mutated { await store.setAdoptionFaultsForTesting([.skipRebaselineWrite]) }
        let player = StorePlayer(store)
        try await player.load(one)
        log.removeAll()
        for _ in 0..<3 { #expect(try await player.adopt() == nil) }
        #expect(log.commits.isEmpty, "no write for the settled version")
        // Another lineage with older listening: a rebaseline, written once.
        try await store.setLineageForTesting(log: ContractIdentity.randomUUID())
        let older = ContractIdentity.randomUUID()
        _ = try await store.applyRecordsForTesting(Self.position(older, 5_000, lastPlayed: Self.now - 7_200_000))
        #expect(try await player.adopt() == nil)
        let observed = try await Self.transition(store)?.observed
        if mutated { #expect(observed?.claim != older); await fixture.close(); return }
        #expect(observed?.claim == older && observed?.settled == true)
        log.removeAll()
        #expect(try await player.adopt() == nil)
        #expect(log.commits.isEmpty, "then nothing")
        await fixture.close()
    }

    // MARK: - The person's newer choice, another device's newer listening

    static func lastPlayedOnly(_ time: Int64) -> [ServerRecord] {
        [ServerRecord(entity: "episode", id: Local.one, fieldGroup: "last_played", value: ["generation_id": .string(Local.generation), "time": .integer(time)])]
    }

    /// Loaded at another device's 30 s (claim O) and moved to 120 s while paused; another session that does not own the
    /// position then moves only the episode's last played. The position record did not change: nothing is adopted and the
    /// 120 s stand, through Play. Treating last played as part of the record's version rolls the choice back to 30 s.
    @Test(arguments: [false, true]) func aLastPlayedOnlyChangeNeverRollsBackAPausedSeek(mutated: Bool) async throws {
        let (fixture, store, one, _) = try await Self.library(at: 30_000)
        if mutated { await store.setAdoptionFaultsForTesting([.lastPlayedIsVersion]) }
        let player = StorePlayer(store)
        try await player.load(one)
        try await player.seek(to: 120_000); try await player.pause()
        _ = try await store.applyRecordsForTesting(Self.lastPlayedOnly(Self.now + 300_000))
        let adopted = try await player.adopt()
        if mutated { #expect(adopted == 30_000, "rolled back"); await fixture.close(); return }
        let stands = try await store.episode(id: one)?.userState.positionMilliseconds
        #expect(adopted == nil && stands == 120_000, "\(String(describing: adopted)) \(String(describing: stands))")
        try await player.play()
        #expect(try Self.lastStart(fixture)?["start_position"]?.integerValue == 120_000)
        await fixture.close()
    }

    /// This phone listened to 61 s and paused (exported, retired). Another device's record (90 s, listening at +120 s) is
    /// adopted at +600 s, which seals the paused session passively at that time. An accepted restore then shows listening
    /// at +500 s at 150 s: newer than any listening known (+120 s), so it is adopted. Counting the seal's time as listening
    /// (a mutation) puts the mark at +600 s and keeps the stale 90 s.
    @Test(arguments: [false, true]) func aPassiveSealIsNotListeningSoNewerRestoredListeningIsAdopted(mutated: Bool) async throws {
        let (fixture, store, one, _) = try await Self.library()
        if mutated { await store.setAdoptionFaultsForTesting([.endsAreListening]) }
        let player = StorePlayer(store)
        try await player.load(one)
        try await player.play(); try await player.listen(60); try await player.pause()
        _ = try await store.retireOutboxForTesting()
        _ = try await store.applyRecordsForTesting(Self.position(ContractIdentity.randomUUID(), 90_000, lastPlayed: Self.now + 120_000))
        player.time = Date(timeIntervalSince1970: Double(Self.now + 600_000) / 1_000)
        #expect(try await player.adopt() == 90_000)
        try await store.setLineageForTesting(log: ContractIdentity.randomUUID())
        _ = try await store.applyRecordsForTesting(Self.position(ContractIdentity.randomUUID(), 150_000, lastPlayed: Self.now + 500_000))
        let adopted = try await player.adopt()
        if mutated {
            #expect(adopted == nil, "the seal's time refuses the newer restored listening")
        } else {
            #expect(adopted == 150_000, "newer than every listening known")
            #expect(try await Self.transition(store)?.listenedHighWater == Self.now + 500_000)
        }
        await fixture.close()
    }

    /// A recovery holds the episode's position at O's 30 s while its base already has another device's C at 45 s (newer
    /// listening). Loaded under the hold, the player is at 30 s: C is not its settled baseline. Once the hold ends, C is
    /// adopted and Play starts at 45 s. Settling the raw base version at the load (a mutation) never adopts it.
    @Test(arguments: [false, true]) func aLoadUnderAHoldLeavesTheBaseVersionToDecideWhenItEnds(mutated: Bool) async throws {
        let (fixture, store, one, _) = try await Self.library(at: 30_000)
        if mutated { await store.setAdoptionFaultsForTesting([.settleFencedLoad]) }
        let newer = ContractIdentity.randomUUID()
        try await store.installBaseUnderHoldForTesting(Local.one, Self.position(newer, 45_000, lastPlayed: Self.now + 500_000))
        #expect(try await store.episode(id: one)?.userState.positionMilliseconds == 30_000, "the hold shows O")
        let player = StorePlayer(store)
        try await player.load(one)
        #expect(player.position == 30_000)
        #expect(try await Self.transition(store)?.listenedHighWater ?? 0 < Self.now + 500_000 || mutated,
                "an unsettled version's listening is not known yet")
        try await store.holdPositionForTesting(Local.one, held: false)
        let adopted = try await player.adopt()
        if mutated { #expect(adopted == nil, "the raw version was settled at the load"); await fixture.close(); return }
        #expect(adopted == 45_000)
        try await player.play()
        let start = try #require(try Self.lastStart(fixture))
        #expect(start["start_position"]?.integerValue == 45_000 && start["observed_claim"]?.stringValue == newer, "\(start)")
        await fixture.close()
    }

    /// Another device's 45 s is already here (its adoption still queued) when the person moves the paused player to
    /// 120 s: that choice was made against it, so it settles it, and the queued adoption finds nothing. Leaving the known
    /// version undecided (a mutation) lets the adoption undo the choice.
    @Test(arguments: [false, true]) func aPausedSeekSettlesTheVersionAlreadyKnown(mutated: Bool) async throws {
        let (fixture, store, one, _) = try await Self.library()
        if mutated { await store.setAdoptionFaultsForTesting([.ignoreChosenSeek]) }
        let player = StorePlayer(store)
        try await player.load(one)
        _ = try await store.applyRecordsForTesting(Self.position(ContractIdentity.randomUUID(), 45_000, lastPlayed: Self.now + 100_000))
        #expect(try await store.serverAdoptionCheck(episodeID: one) == .adopt, "queued")
        try await player.seek(to: 120_000); try await player.pause()
        let adopted = try await player.adopt()
        if mutated { #expect(adopted == 45_000, "the choice is undone"); await fixture.close(); return }
        let stands = try await store.episode(id: one)?.userState.positionMilliseconds
        #expect(adopted == nil && stands == 120_000, "\(String(describing: adopted)) \(String(describing: stands))")
        #expect(try await store.serverAdoptionCheck(episodeID: one) == .none)
        await fixture.close()
    }

    /// Loaded under pending own intent while the record shows listening at +100 s (unsettled); before the intent retires,
    /// a restore shows listening at +80 s, newer than this phone's (+61 s) and than anything settled. Once the intent
    /// retires, it is adopted. Taking the unsettled record's +100 s into the high-water mark at the load (a mutation)
    /// refuses it.
    @Test(arguments: [false, true]) func anUnsettledLoadMovesNoHighWaterMark(mutated: Bool) async throws {
        let (fixture, store, one, two) = try await { () async throws -> (ServerLibraryFixture, FeedLibraryStore, Int64, Int64) in
            let (fixture, _, one, two) = try await Local.library()
            _ = try await fixture.store.applyRecordsForTesting(Self.position(ContractIdentity.randomUUID(), 0, lastPlayed: Self.now - 3_600_000))
            return (fixture, fixture.store, one, two)
        }()
        if mutated { await store.setAdoptionFaultsForTesting([.highWaterFromUnsettledLoad]) }
        let player = StorePlayer(store)
        try await player.load(one)
        try await player.play(); try await player.listen(60, every: 60); try await player.pause()
        _ = try await store.applyRecordsForTesting(Self.position(ContractIdentity.randomUUID(), 0, lastPlayed: Self.now + 100_000))
        try await player.load(two)
        try await player.load(one)
        #expect(try await Self.transition(store)?.observed?.settled == false)
        try await store.setLineageForTesting(log: ContractIdentity.randomUUID())
        _ = try await store.applyRecordsForTesting(Self.position(ContractIdentity.randomUUID(), 77_000, lastPlayed: Self.now + 80_000))
        _ = try await store.retireOutboxForTesting()
        let adopted = try await player.adopt()
        if mutated { #expect(adopted == nil, "refused by an unsettled record's time") } else { #expect(adopted == 77_000) }
        await fixture.close()
    }

    // MARK: - Fences

    /// A recovery whose base is not installed fences every episode; once caught up, an unrelated episode's foreign
    /// reset is adopted. A recovery hold on the episode's position fences it until the hold goes.
    @Test func recoveryFencesAreScoped() async throws {
        let (fixture, store, one, log) = try await Self.library()
        let player = StorePlayer(store)
        try await player.load(one)
        _ = try await store.applyRecordsForTesting(Self.position(ContractIdentity.randomUUID(), 0, lastPlayed: Self.now + 100_000))
        try await store.setRecoveryForTesting(caughtUp: false)
        #expect(try await store.serverAdoptionCheck(episodeID: one) == .none, "the base is not installed")
        log.removeAll()
        try await store.setRecoveryForTesting(caughtUp: true)
        #expect(log.take().knowledge?.all == true, "the recovery state is a knowledge event")
        try await store.holdPositionForTesting(Local.one, held: true)
        #expect(try await store.serverAdoptionCheck(episodeID: one) == .none, "held")
        log.removeAll()
        try await store.holdPositionForTesting(Local.one, held: false)
        #expect(log.take().knowledge?.episodes.contains(one) == true, "the hold's release is a knowledge event")
        #expect(try await player.adopt() == 0)
        await fixture.close()
    }
}

extension FeedLibraryStore {
    /// A commit of records only (another device's facts), on the live lineage.
    func applyRecordsForTesting(_ records: [ServerRecord], history: ServerHistoryOracle? = nil) throws -> ServerUnitResult {
        let live = try serverExchangeState().cursor
        let log = live?.logID ?? ContractIdentity.randomUUID()
        let seq = (live?.seq ?? 0) + 1
        if live == nil { try setCursorForTesting(try SyncCursor(logID: log, epoch: 1, seq: 0, digest: String(repeating: "0", count: 64))) }
        let cursor = try SyncCursor(logID: log, epoch: 1, seq: seq, digest: ContractIdentity.sha256Hex(Array("\(log)\(seq)".utf8)))
        return try applyServerUnit(ServerUnitInput(commit: ServerCommit(epoch: 1, seq: seq, records: records), cursor: cursor, watermark: nil,
                                                   now: 1_760_000_000_000), history: history, maxWork: nil)
    }

    /// The library moves to another server lineage (an accepted restore or replacement).
    func setLineageForTesting(log: String) throws {
        try setCursorForTesting(try SyncCursor(logID: log, epoch: 1, seq: 0, digest: String(repeating: "0", count: 64)))
    }

    /// The pending transition as an app from before baselines stored it.
    func stripBaselineForTesting() throws {
        try database.transaction {
            var state = try transitionState()
            state.current?.observed = nil
            state.current?.listenedHighWater = nil
            try storeTransitionState(state, journal)
        }
    }

    func setRecoveryForTesting(caughtUp: Bool) throws {
        try database.transaction {
            var record = try Self.recovery(database) ?? ServerRecoveryRecord.forTesting()
            record.caughtUp = caughtUp
            try Self.storeRecovery(record, database)
        }
    }

    /// A recovery's switch: the base takes `records` while a hold keeps the episode's position as it showed (its image
    /// kept; nothing is projected until the hold ends).
    func installBaseUnderHoldForTesting(_ wire: String, _ records: [ServerRecord]) throws {
        try database.transaction {
            try database.execute("INSERT INTO ntp_recovery_holds(entity, id, field_group, value, provenance, nodes) SELECT entity, id, field_group, value, provenance, '[]' FROM ntp_records WHERE entity = 'episode' AND id = ? AND field_group = 'position'", [.text(wire)])
            for record in records { try Self.writeRecord(record, to: database) }
        }
    }

    func holdPositionForTesting(_ wire: String, held: Bool) throws {
        try database.transaction {
            if held {
                try database.execute("INSERT INTO ntp_recovery_holds(entity, id, field_group, value, provenance, nodes) VALUES ('episode', ?, 'position', NULL, NULL, '[]')", [.text(wire)])
            } else {
                try database.execute("DELETE FROM ntp_recovery_holds WHERE entity = 'episode' AND id = ? AND field_group = 'position'", [.text(wire)])
            }
        }
    }
}

extension ServerRecoveryRecord {
    static func forTesting() -> ServerRecoveryRecord {
        ServerRecoveryRecord(cause: .lineageMismatch, from: nil, startedAt: 0)
    }
}

/// The pending-intent sequence through real exchanges with the pinned server, with and without a relaunch in the middle: A is
/// paused at 120 s with its start P still unsent; B resets the episode to 0 (claim C, later, not depending on P); A pulls C
/// while P is pending (nothing decided); A pushes P, which the server orders before C, and pulls its receipt (C still owns
/// the position): A adopts 0, its Play starts at 0 observing C, and the server's position stays 0.
@Suite(.serialized) struct ServerAdoptionExchangeTests {
    @Test(arguments: [false, true]) func aForeignResetSeenWhileTheOwnStartIsUnsentIsAdoptedAfterItsReceipt(relaunch: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, ids, _) = try await ServerExchangeConcurrencyTests.twoPhones(world)
            let onB = try await ServerExchangeConcurrencyTests.same(ids[0], from: a, on: b)
            await b.exchange()
            var player = StorePlayer(a.store, realTime: ())
            try await player.load(ids[0])
            try await player.play(); try await player.listen(120, every: 60); try await player.pause()
            try await b.store.resetPlaybackPosition(episodeID: onB)
            await b.exchange()
            let wire = try #require(try await a.store.wireEpisodeForTesting(ids[0]))
            let reset = try #require(try b.rows("SELECT json_extract(CAST(value AS TEXT), '$.claim_id') FROM ntp_records WHERE entity = 'episode' AND id = '\(wire)' AND field_group = 'position'").first?.first ?? nil,
                                     "B's record names its reset's claim")
            await a.run([.pull, .apply])
            #expect(try await a.store.serverAdoptionCheck(episodeID: ids[0]) == .none, "A's start is unsent")
            #expect(try await player.adopt() == nil)
            if relaunch {
                try await a.relaunch()
                player = try await StorePlayer.restored(a.store)
            }
            await a.exchange()
            #expect(try await a.store.serverAdoptionCheck(episodeID: ids[0]) == .adopt)
            #expect(try await player.adopt() == 0)
            try await player.play()
            let start = try #require(try a.rows("SELECT CAST(fact AS TEXT) FROM ntp_outbox ORDER BY install_seq DESC").compactMap { $0[0] }
                .compactMap { try? ContractJSON.decode(Array($0.utf8)) }.first { $0["type"]?.stringValue == "session.start" })
            #expect(start["payload"]?["start_position"]?.integerValue == 0, "\(start)")
            #expect(start["payload"]?["observed_claim"]?.stringValue == reset, "observes the reset's claim")
            try await player.pause()
            await a.exchange(); await b.exchange()
            #expect(try await b.view().episodes[wire]?.position == 0,
                    "the server's position stays the reset's 0")
        }
    }
}
