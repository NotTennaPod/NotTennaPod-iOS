import Foundation
import Testing
@testable import NotTennaPodCore

/// Displayed last played and history are PROTOCOL §8.7 over the accepted records and pending activity plus this
/// device's unexported listening. Another device's newer listening shows at once; this device's own receipt never rolls
/// its unexported listening back, so it changes nothing visible unless the server normalized its time.
@Suite(.serialized) struct ServerJournalListeningTests {
    typealias Local = ServerLocalPlaybackTests
    static let now: Int64 = 1_760_000_000_000

    static func listening(_ time: Int64) -> [ServerRecord] {
        [ServerRecord(entity: "episode", id: Local.one, fieldGroup: "last_played", value: ["generation_id": .string(Local.generation), "time": .integer(time)]),
         ServerRecord(entity: "episode", id: Local.one, fieldGroup: "history", value: ["generation_id": .string(Local.generation), "time": .integer(time)])]
    }

    static func state(_ store: FeedLibraryStore, _ id: Int64) async throws -> EpisodeUserState {
        try #require(try await store.episode(id: id)).userState
    }

    /// Overlapping sessions: this phone listens (its saves not exported yet) while another device's later listening of the
    /// episode arrives. Its last played and history show at once; marks that freeze both hide them.
    @Test(arguments: [false, true]) func anotherDevicesNewerListeningShowsDuringUnexportedListening(mutated: Bool) async throws {
        let (fixture, _, one, _) = try await Local.library()
        let store = fixture.store
        if mutated { await store.setAdoptionFaultsForTesting([.recordsOnlyListening]) }
        let player = StorePlayer(store)
        try await player.load(one)
        try await player.play(); try await player.listen(30)
        let own = try await Self.state(store, one).lastPlayedTimeMilliseconds
        #expect(own > Self.now, "this phone listened")
        let later = own + 3_600_000
        _ = try await store.applyRecordsForTesting(Self.listening(later))
        let state = try await Self.state(store, one)
        if mutated {
            #expect(state.lastPlayedTimeMilliseconds == own, "frozen by the marks")
        } else {
            #expect(state.lastPlayedTimeMilliseconds == later && state.lastPlayedHistoryMilliseconds == later, "\(state)")
        }
        await fixture.close()
    }

    static func historyCut() -> [ServerRecord] {
        [ServerRecord(entity: "episode", id: Local.one, fieldGroup: "history", value: ["generation_id": .string(Local.generation), "time": .null])]
    }

    /// A remote history cut while this phone's listening is unexported (five and thirty seconds of
    /// listening, a remote entry a minute and an hour later): the cut removes the remote entry and the history shows this
    /// phone's unexported save, which no remote cut can cover. Taking the unexported listening from what the row showed
    /// (the first revision, a mutation) keeps the removed remote time.
    @Test(arguments: [(5, Int64(60_000), false), (30, Int64(3_600_000), false), (5, Int64(60_000), true)])
    func aRemoteHistoryCutLeavesOnlyTheUnexportedListening(seconds: Int, later: Int64, mutated: Bool) async throws {
        let (fixture, _, one, _) = try await Local.library()
        let store = fixture.store
        if mutated { await store.setAdoptionFaultsForTesting([.displayedRowListening]) }
        let player = StorePlayer(store)
        try await player.load(one)
        try await player.play(); try await player.listen(seconds)
        let own = try #require(try await Self.state(store, one).lastPlayedHistoryMilliseconds)
        _ = try await store.applyRecordsForTesting(Self.listening(own + later))
        #expect(try await Self.state(store, one).lastPlayedHistoryMilliseconds == own + later, "the other device's later entry shows")
        _ = try await store.applyRecordsForTesting(Self.historyCut())
        let shown = try await Self.state(store, one).lastPlayedHistoryMilliseconds
        if mutated {
            #expect(shown == own + later, "the removed remote time stays")
        } else {
            #expect(shown == own, "only the unexported save stays: \(String(describing: shown)) vs \(own)")
        }
        await fixture.close()
    }

    /// A save below an already shown remote time changes nothing the row shows, yet it is this phone's unexported entry: a
    /// later remote cut must leave it, not an empty history.
    @Test(arguments: [false, true]) func aSaveBelowARemoteTimeSurvivesTheRemoteCut(mutated: Bool) async throws {
        let (fixture, _, one, _) = try await Local.library()
        let store = fixture.store
        if mutated { await store.setAdoptionFaultsForTesting([.displayedRowListening]) }
        _ = try await store.applyRecordsForTesting(Self.listening(Self.now + 3_600_000))
        let player = StorePlayer(store)
        try await player.load(one)
        try await player.play(); try await player.listen(30)
        let state = try await Self.state(store, one)
        #expect(state.lastPlayedHistoryMilliseconds == Self.now + 3_600_000, "the row still shows the remote time")
        _ = try await store.applyRecordsForTesting(Self.historyCut())
        let shown = try await Self.state(store, one).lastPlayedHistoryMilliseconds
        let own = Self.now + 30_000
        if mutated {
            #expect(shown != own, "the save is lost: \(String(describing: shown))")
        } else {
            #expect(shown == own, "this phone's unexported listening: \(String(describing: shown))")
        }
        await fixture.close()
    }

    /// Another device's later listening, then an accepted value that lowers it (its normalized time) while this phone's
    /// earlier listening is still unexported: last played and history show the lowered value, not the one replaced.
    @Test(arguments: [false, true]) func aLoweredRemoteValueIsShownOverTheReplacedOne(mutated: Bool) async throws {
        let (fixture, _, one, _) = try await Local.library()
        let store = fixture.store
        if mutated { await store.setAdoptionFaultsForTesting([.displayedRowListening]) }
        let player = StorePlayer(store)
        try await player.load(one)
        try await player.play(); try await player.listen(5)
        let own = try await Self.state(store, one).lastPlayedTimeMilliseconds
        _ = try await store.applyRecordsForTesting(Self.listening(own + 120_000))
        _ = try await store.applyRecordsForTesting(Self.listening(own + 60_000))
        let state = try await Self.state(store, one)
        if mutated {
            #expect(state.lastPlayedTimeMilliseconds == own + 120_000, "the replaced value stays")
        } else {
            #expect(state.lastPlayedTimeMilliseconds == own + 60_000 && state.lastPlayedHistoryMilliseconds == own + 60_000, "\(state)")
        }
        await fixture.close()
    }

    /// The unexported entries survive a relaunch (the journal is the source), and once exported and accepted at a later
    /// normalized time the row shows that time; a remote cut after the export leaves the accepted local entry.
    @Test func theJournalsEntriesSurviveARelaunchAndExportAndARemoteCut() async throws {
        let (fixture, _, one, _) = try await Local.library()
        var store = fixture.store
        var player = StorePlayer(store)
        try await player.load(one)
        try await player.play(); try await player.listen(20)
        let own = try await Self.state(store, one).lastPlayedHistoryMilliseconds
        player = try await player.relaunch(fixture.url)
        store = player.store
        _ = try await store.applyRecordsForTesting(Self.listening(Self.now + 3_600_000))
        _ = try await store.applyRecordsForTesting(Self.historyCut())
        #expect(try await Self.state(store, one).lastPlayedHistoryMilliseconds == own, "after a relaunch")
        try await store.close()
        await fixture.close()
    }

    /// Against the server, on a correct clock: this phone's facts go out and their receipts come back at their own times (the
    /// phone's clock is right) while later saves are still unexported: the receipt changes nothing visible about the
    /// episode, so the sync engine tells the screens nothing about it.
    @Test func anOwnCheckpointComingBackWithLaterSavesChangesNothingVisible() async throws {
        try await ExchangeWorld.run { world in
            let (a, _, _, ids, _) = try await ServerExchangeConcurrencyTests.twoPhones(world)
            let oracle = ChangeSetOracle()
            await a.store.installChangeOracleForTesting(oracle)
            let log = await a.store.recordCommitsForTesting()
            // On the real clock (the server's), so the server keeps every client time as it is: the start, a pause's
            // export and the resume's claiming checkpoint go out; the saves after the resume stay unexported.
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(ids[0])
            try await player.play(); try await player.listen(5); try await player.pause()
            try await player.play(); try await player.listen(10)
            let before = try await Self.state(a.store, ids[0])
            log.removeAll()
            let report = await a.exchange()
            #expect(report.units.contains { $0.retired > 0 }, "the start and checkpoint came back: \(report.units)")
            let sets = log.commits.compactMap(\.set)
            #expect(!sets.contains { $0.episodes[ids[0]] != nil || $0.statistics[ids[0]] != nil }, "\(sets)")
            let after = try await Self.state(a.store, ids[0])
            #expect(after == before, "before \(before)\nafter \(after)")
            #expect(oracle.mismatches.isEmpty, "\(oracle.report)")
        }
    }

    /// Against the server, with a clock ahead: this phone's clock is 90 s ahead; it pauses (its last save exported) and the server
    /// accepts the export at its normalized time. With no newer save the displayed last played and history become that
    /// time, and the receipt's change set is exactly the episode and its statistics.
    @Test func aNormalizedTimeComingBackIsExactlyTheEpisodesChange() async throws {
        try await ExchangeWorld.run { world in
            let (a, _, _, ids, _) = try await ServerExchangeConcurrencyTests.twoPhones(world)
            let oracle = ChangeSetOracle()
            await a.store.installChangeOracleForTesting(oracle)
            let log = await a.store.recordCommitsForTesting()
            let player = StorePlayer(a.store, time: Date().addingTimeInterval(90))
            try await player.load(ids[0])
            try await player.play(); try await player.listen(30); try await player.pause()
            let client = try await Self.state(a.store, ids[0]).lastPlayedTimeMilliseconds
            log.removeAll()
            await a.exchange()
            let changed = log.commits.compactMap(\.set).filter { !$0.episodes.isEmpty || !$0.statistics.isEmpty }
            #expect(changed.count == 1, "one receipt changed the episode: \(changed)")
            if let set = changed.first {
                #expect(Set(set.episodes.keys) == [ids[0]] && Set(set.statistics.keys) == [ids[0]], "\(set)")
            }
            let state = try await Self.state(a.store, ids[0])
            #expect(state.lastPlayedTimeMilliseconds < client - 30_000, "the normalized time: \(state.lastPlayedTimeMilliseconds) vs \(client)")
            #expect(state.lastPlayedHistoryMilliseconds == state.lastPlayedTimeMilliseconds)
            #expect(oracle.mismatches.isEmpty, "\(oracle.report)")
        }
    }
}

/// Found by the rebuild oracle: a pending end that completes is a checkpoint then its completion (PROTOCOL §8.3); a
/// projection of the episode while it is pending (any unit touching it, or Force full synchronization) shows position 0
/// as the end itself wrote, not the position the end was at.
@Suite(.serialized) struct ServerPendingCompletionTests {
    @Test func aPendingCompletedEndIsRebuiltAsItShows() async throws {
        let (fixture, _, one, _) = try await ServerLocalPlaybackTests.library()
        let store = fixture.store
        let player = StorePlayer(store)
        try await player.load(one)
        try await player.play(); try await player.listen(60); try await player.listen(81)
        _ = try await player.end(.ended)
        #expect(try await store.episode(id: one)?.userState.positionMilliseconds == 0, "completed")
        let differences = try await ServerChangeSetCaptureTests.rebuildDifferences(store, ownedRoot: fixture.directory, archive: nil)
        #expect(differences.isEmpty, "\(differences.joined(separator: "\n"))")
        await fixture.close()
    }
}
