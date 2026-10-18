import Foundation
import Testing
@testable import NotTennaPodCore

/// Failure injection for playback writes (PROTOCOL §15.2): a failure after every individual recorder
/// write of a playback path rolls back everything the recorder wrote, the playback write still commits with its
/// journal, and the next recording records exactly the facts the path owes, with the identities and times fixed when
/// it happened (PROTOCOL §8.1). An ordinary mutation that flushes a session rolls back whole.
@Suite struct ServerPlaybackFailureTests {
    /// One playback path: `setup` prepares the library and player, `act` is the playback write under test.
    struct Path: Sendable, CustomStringConvertible {
        let name: String
        let setup: @Sendable (ServerLibraryFixture, StorePlayer, [Int64]) async throws -> Void
        let act: @Sendable (ServerLibraryFixture, StorePlayer, [Int64]) async throws -> Void
        var description: String { name }
    }

    /// A position another device claimed, over this library's retired listening: what a takeover or adoption takes.
    static func remoteClaim(_ fixture: ServerLibraryFixture, _ episode: Int64, position: Int64, provenance: [String] = []) async throws {
        let wire = try #require(try fixture.wireID(episode))
        let generation = try #require(try fixture.rows("SELECT live_generation FROM ntp_podcasts").first?.first ?? nil)
        _ = try await fixture.store.retireOutboxForTesting(records: [
            ServerRecord(entity: "episode", id: wire, fieldGroup: "position", value: ["generation_id": .string(generation), "position": .integer(position),
                                                                                   "claim_id": .string(ContractIdentity.randomUUID())],
                         provenance: provenance)])
    }

    nonisolated static let paths: [Path] = [
        .init(name: "start", setup: { _, p, ids in try await p.load(ids[1]) }, act: { _, p, _ in try await p.play() }),
        .init(name: "minute export", setup: { _, p, ids in try await p.load(ids[1]); try await p.play(); try await p.listen(55) },
              act: { _, p, _ in try await p.listen(5) }),
        .init(name: "pause", setup: { _, p, ids in try await p.load(ids[1]); try await p.play(); try await p.listen(15) },
              act: { _, p, _ in try await p.pause() }),
        .init(name: "resume claim", setup: { _, p, ids in try await p.load(ids[1]); try await p.play(); try await p.listen(15); try await p.pause() },
              act: { _, p, _ in try await p.play() }),
        .init(name: "end", setup: { _, p, ids in try await p.load(ids[1]); try await p.play(); try await p.listen(15) },
              act: { _, p, _ in try await p.end(.ended) }),
        .init(name: "skip", setup: { _, p, ids in p.skipKeepsEpisode = false; try await p.load(ids[1]); try await p.play(); try await p.listen(15) },
              act: { _, p, _ in try await p.end(.skipped) }),
        .init(name: "leave", setup: { _, p, ids in try await p.load(ids[1]) }, act: { _, p, _ in try await p.end(.switched) }),
        .init(name: "reload", setup: { _, p, ids in try await p.load(ids[1]); try await p.play(); try await p.listen(15) },
              act: { _, p, ids in try await p.load(ids[1], at: 0) }),
        .init(name: "timeline reset", setup: { _, p, ids in try await p.load(ids[1]); try await p.play(); try await p.listen(15) },
              act: { f, p, _ in
                  _ = try await f.store.recordPlaybackTimelineReset(sessionID: try #require(p.session).id, finalSample: .init(positionMilliseconds: 20_000,
                      durationMilliseconds: 600_000, status: .playing), now: p.time.addingTimeInterval(5))
              }),
        .init(name: "takeover", setup: { f, p, ids in
            try await p.load(ids[1]); try await p.play(); try await p.listen(65)
            try await remoteClaim(f, ids[1], position: 300_000)
        }, act: { _, p, _ in try await p.seek(to: 400_000) }),
        .init(name: "adoption", setup: { f, p, ids in
            try await p.load(ids[1]); try await p.play(); try await p.listen(15); try await p.pause()
            try await remoteClaim(f, ids[1], position: 300_000)
        }, act: { _, p, _ in _ = try await p.adopt() }),
    ]

    /// What a recorded playback fact says, without its random IDs.
    static func signature(_ fact: ServerLibraryFixture.Fact) -> String {
        let p = fact.payload
        let fields = ["ordinal", "position", "start_position", "contribution", "activity", "claim", "reason", "completed",
                      "remove_from_queue", "history", "threshold_ms"].map { "\($0)=\(String(describing: p[$0]))" }
        return "\(fact.type) t=\(fact.json["client_time"]?.integerValue ?? 0) \(fields.joined(separator: " ")) save=\(String(describing: p["save"]?["index"])) passive=\(String(describing: p["save"]?["passive"]))"
    }

    static let types: Set<String> = ServerPlaybackRecorderTests.playback

    /// The library, the player and what the path's act records with nothing failing.
    static func run(_ path: Path, failAfter: Int?) async throws -> (fixture: ServerLibraryFixture, player: StorePlayer, before: Int, writes: Int) {
        let (fixture, ids, _, _) = try await ServerPlaybackRecorderTests.library()
        let player = StorePlayer(fixture.store)
        try await path.setup(fixture, player, ids)
        let before = try fixture.outboxCount()
        await fixture.store.injectRecorderFailure(after: failAfter)
        try await path.act(fixture, player, ids)
        let writes = await fixture.store.lastRecorderWrites()
        await fixture.store.injectRecorderFailure(after: nil)
        return (fixture, player, before, writes)
    }

    @Test(arguments: paths) func aFailureAfterAnyRecorderWriteKeepsTheJournalAndOwesTheFacts(_ path: Path) async throws {
        let clean = try await Self.run(path, failAfter: nil)
        let golden = try clean.fixture.newFacts(after: clean.before).filter { Self.types.contains($0.type) }
        let goldenRows = try clean.fixture.rows("SELECT id, record FROM episodes ORDER BY id")
        await clean.fixture.close()
        #expect(!golden.isEmpty, "\(path.name) records a playback fact")
        #expect(clean.writes > 0)
        for failAfter in 1...clean.writes {
            let (fixture, _, before, _) = try await Self.run(path, failAfter: failAfter)
            let label = "\(path.name) failing after write \(failAfter)"
            #expect(try fixture.newFacts(after: before).filter { Self.types.contains($0.type) }.isEmpty, "\(label): a fact survived")
            #expect(try fixture.rows("SELECT export_owed FROM ntp_library") == [["1"]], "\(label): owed")
            #expect(try fixture.rows("SELECT id, record FROM episodes ORDER BY id") == goldenRows, "\(label): the playback write committed as it would")
            // The next recording records what was owed, at the times and with the identities it was decided with.
            try await fixture.store.flushServerPlayback()
            let owed = try fixture.newFacts(after: before).filter { Self.types.contains($0.type) }
            #expect(owed.map(Self.signature) == golden.map(Self.signature), "\(label): \(owed.map(Self.signature)) vs \(golden.map(Self.signature))")
            #expect(try fixture.rows("SELECT export_owed FROM ntp_library") == [["0"]])
            #expect(try fixture.rows("SELECT id, record FROM episodes ORDER BY id") == goldenRows, "\(label): rows after the owed facts")
            await fixture.close()
        }
    }

    /// An owed start, claim and end keep the op IDs fixed when they happened: a claim is never lost or renamed, and a
    /// transition's finalization names the claim it was decided under (PROTOCOL §8.1).
    @Test func owedFactsKeepTheirIdentities() async throws {
        let (fixture, ids, _, _) = try await ServerPlaybackRecorderTests.library()
        defer { Task { await fixture.close() } }
        let player = StorePlayer(fixture.store)
        try await player.load(ids[1])
        await fixture.store.injectRecorderFailure(after: 1)
        try await player.play()
        try await player.listen(15)
        try await player.pause()
        try await player.play()
        try await player.listen(10)
        let transition = try #require(try await fixture.store.transitionStateForTesting().current)
        let sessions = try await fixture.store.syncSessionsForTesting()
        let session = try #require(sessions.first)
        let claim = try #require(session.claims.last)
        #expect(transition.claim == claim && session.claims.first == session.startOp)
        try await player.end(.switched)
        await fixture.store.injectRecorderFailure(after: nil)
        #expect(try fixture.outbox().filter { Self.types.contains($0.type) }.isEmpty)
        // An ordinary action records what is owed first, then its own fact.
        try await fixture.store.setFavorite(episodeID: ids[2], favorite: true)
        let facts = try fixture.outbox().filter { Self.types.contains($0.type) || $0.type == "favorite.set" }
        #expect(facts.map(\.type) == ["session.start", "session.checkpoint", "session.checkpoint", "session.end", "favorite.set"])
        #expect(facts[0].opID == session.startOp)
        #expect(facts[2].opID == claim && facts[2].payload["claim"]?.boolValue == true)
        #expect(facts[2].payload["save"]?["passive"]?.boolValue == false)
        #expect(facts[3].payload["reason"]?.stringValue == "switched")
    }

    /// An owed start depends on what the person's Play observed, never on a remote claim that arrived before it was
    /// recorded (PROTOCOL §8.1).
    @Test func anOwedStartDependsOnlyOnWhatItsPlayObserved() async throws {
        let (fixture, ids, _, _) = try await ServerPlaybackRecorderTests.library()
        defer { Task { await fixture.close() } }
        let seen = ContractIdentity.randomUUID(), later = ContractIdentity.randomUUID()
        let player = StorePlayer(fixture.store)
        try await player.load(ids[1])
        try await Self.remoteClaim(fixture, ids[1], position: 50_000, provenance: [seen])
        await fixture.store.injectRecorderFailure(after: 1)
        try await player.play()
        try await player.listen(15)
        try await Self.remoteClaim(fixture, ids[1], position: 300_000, provenance: [later])
        await fixture.store.injectRecorderFailure(after: nil)
        try await fixture.store.flushServerPlayback()
        let start = try #require(try fixture.outbox().first { $0.type == "session.start" })
        #expect(start.dependencies.contains(seen), "what the Play observed")
        #expect(!start.dependencies.contains(later), "not what arrived before it was recorded")
    }

    /// The same for a resume's claim: its claiming checkpoint depends on what the resume observed.
    @Test func anOwedResumeClaimDependsOnlyOnWhatItsPlayObserved() async throws {
        let (fixture, ids, _, _) = try await ServerPlaybackRecorderTests.library()
        defer { Task { await fixture.close() } }
        let seen = ContractIdentity.randomUUID(), later = ContractIdentity.randomUUID()
        let player = StorePlayer(fixture.store)
        try await player.load(ids[1])
        try await player.play()
        try await player.listen(15)
        try await player.pause()
        try await Self.remoteClaim(fixture, ids[1], position: 50_000, provenance: [seen])
        await fixture.store.injectRecorderFailure(after: 1)
        try await player.play()
        try await player.listen(10)
        try await Self.remoteClaim(fixture, ids[1], position: 300_000, provenance: [later])
        await fixture.store.injectRecorderFailure(after: nil)
        try await fixture.store.flushServerPlayback()
        let claim = try #require(try fixture.outbox().first { $0.type == "session.checkpoint" && $0.payload["claim"]?.boolValue == true })
        #expect(claim.dependencies.contains(seen), "what the resume observed")
        #expect(!claim.dependencies.contains(later), "not what arrived before it was recorded")
    }

    /// The same for a leave: it depends on what the device had seen when it was decided.
    @Test func anOwedLeaveDependsOnlyOnWhatWasSeenWhenItWasDecided() async throws {
        let (fixture, ids, _, _) = try await ServerPlaybackRecorderTests.library()
        defer { Task { await fixture.close() } }
        let seen = ContractIdentity.randomUUID(), later = ContractIdentity.randomUUID()
        let player = StorePlayer(fixture.store)
        try await player.load(ids[1])
        try await Self.remoteClaim(fixture, ids[1], position: 50_000, provenance: [seen])
        await fixture.store.injectRecorderFailure(after: 1)
        _ = try await player.end(.switched)
        try await Self.remoteClaim(fixture, ids[1], position: 300_000, provenance: [later])
        await fixture.store.injectRecorderFailure(after: nil)
        try await fixture.store.flushServerPlayback()
        let leave = try #require(try fixture.outbox().first { $0.type == "episode.leave" })
        #expect(leave.dependencies.contains(seen), "what was seen when it was decided")
        #expect(!leave.dependencies.contains(later), "not what arrived before it was recorded")
    }

    /// A relaunch's finalization whose recording fails is owed with the transition it consumed.
    @Test func anOwedFinalizationIsRecordedLater() async throws {
        let (fixture, ids, _, _) = try await ServerPlaybackRecorderTests.library()
        var player = StorePlayer(fixture.store)
        try await player.load(ids[1])
        try await player.play()
        try await player.listen(15)
        try await player.pause()
        player = try await player.relaunch(fixture.url)
        let store = player.store
        try await store.flushServerPlayback()
        let before = try fixture.outboxCount()
        await store.injectRecorderFailure(after: 2)
        try await player.end(.switched)
        await store.injectRecorderFailure(after: nil)
        #expect(try fixture.newFacts(after: before).isEmpty)
        #expect(try await store.transitionStateForTesting().due.count == 1)
        try await store.flushServerPlayback()
        #expect(try fixture.newFacts(after: before).map(\.type) == ["session.finalize"])
        #expect(try await store.transitionStateForTesting().due.isEmpty)
        try await store.close()
        try? FileManager.default.removeItem(at: fixture.directory)
    }

    /// A cut that flushes an open session is an ordinary mutation: a failure rolls the flush back with the cut.
    @Test func aFailedCutRollsBackItsFlush() async throws {
        let clean = try await ServerPlaybackRecorderTests.library()
        let player = StorePlayer(clean.fixture.store)
        try await player.load(clean.ids[1]); try await player.play(); try await player.listen(15)
        try await clean.fixture.store.resetPlayedDurationStatistics()
        let writes = await clean.fixture.store.lastRecorderWrites()
        await clean.fixture.close()
        for failAfter in 1...writes {
            let (fixture, ids, _, _) = try await ServerPlaybackRecorderTests.library()
            let player = StorePlayer(fixture.store)
            try await player.load(ids[1]); try await player.play(); try await player.listen(15)
            let rows = try fixture.libraryRows(), tables = try fixture.serverTables()
            await fixture.store.injectRecorderFailure(after: failAfter)
            await #expect(throws: ServerRecordingError.injectedFailure) { try await fixture.store.resetPlayedDurationStatistics() }
            #expect(try fixture.libraryRows() == rows, "failing after write \(failAfter): rows changed")
            #expect(try fixture.serverTables() == tables, "failing after write \(failAfter): the flush or the cut survived")
            await fixture.close()
        }
    }
}
