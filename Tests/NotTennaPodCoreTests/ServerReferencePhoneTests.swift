import Foundation
import Testing
@testable import NotTennaPodCore

/// The reference phones' own checks: their expectations follow the protocol's register rule through pending writes and
/// deliveries, and a wrong local value on a phone is reported.
@Suite(.serialized) struct ServerReferencePhoneTests {
    typealias Capture = ServerChangeSetCaptureTests

    /// A pending favorite masks a later one pulled from the other phone (PROTOCOL §6.8), and once it is retired the later
    /// one wins (the last explicit write in fact order, PROTOCOL §7); both phones match the reference at every point. Then
    /// one local value is made wrong on a phone: the reference reports it.
    @Test(arguments: ["favorite", "play state", "downloaded", "transfer"])
    func theReferenceFollowsPendingWritesAndReportsAWrongLocalValue(field: String) async throws {
        try await ExchangeWorld.run { world in
            let (pa, pb, _, ids, _) = try await ServerExchangeConcurrencyTests.twoPhones(world)
            let a = Capture.Side(pa), b = Capture.Side(pb)
            let run = Capture.Run(world: world, a: a, b: b, seed: 1)
            run.reader = try await ServerReadOracle(world.server)
            for _ in 0..<2 { for side in run.sides { await side.phone.exchange(); try await run.observe(side) } }
            let onB = try await ServerExchangeConcurrencyTests.same(ids[0], from: pa, on: pb)
            let wire = try #require(try await run.wire(a, ids[0]))
            func agree(_ label: String) async throws {
                for side in run.sides {
                    let found = try await run.referenceDifferences(side)
                    #expect(found.isEmpty, "\(label): \(found)")
                }
            }
            try await agree("settled")
            // A favorites it and exchanges; B pulls it.
            try await a.store.setFavorite(episodeID: ids[0], favorite: true); run.reference.favorite(wire, true, side: a.name)
            await a.phone.exchange(); try await run.observe(a)
            await b.phone.run([.pull, .apply]); try await run.observe(b, pushed: false)
            try await agree("delivered")
            // B removes it (pending); A then removes and adds it again, and exchanges; B pulls without pushing.
            try await b.store.setFavorite(episodeID: onB, favorite: false); run.reference.favorite(wire, false, side: b.name)
            try await a.store.setFavorite(episodeID: ids[0], favorite: false); run.reference.favorite(wire, false, side: a.name)
            try await a.store.setFavorite(episodeID: ids[0], favorite: true); run.reference.favorite(wire, true, side: a.name)
            await a.phone.exchange(); try await run.observe(a)
            await b.phone.run([.pull, .apply]); try await run.observe(b, pushed: false)
            #expect(run.reference.expected(.favorite(wire), side: b.name) == .some(0), "B's pending removal masks A's later add")
            try await agree("masked")
            // B exchanges: its removal is ordered before A's later add, which wins.
            await b.phone.exchange(); try await run.observe(b)
            #expect(run.reference.expected(.favorite(wire), side: b.name) == .some(1), "the later add wins once B's removal is retired")
            try await agree("retired")
            // One local value made wrong on B.
            let other = try await ServerExchangeConcurrencyTests.same(ids[1], from: pa, on: pb)
            let otherWire = try #require(try await run.wire(b, other))
            func set(_ path: String, _ value: String, id: Int64) -> String {
                "UPDATE episodes SET record = CAST(json_set(CAST(record AS TEXT), '\(path)', \(value)) AS BLOB) WHERE id = \(id)"
            }
            let statement: String
            switch field {
            case "favorite":
                statement = set("$.userState.isFavorite", "json('false')", id: onB)
            case "play state":
                try await b.store.markEpisodePlayed(episodeID: other, played: true); run.reference.playState(otherWire, .played, side: b.name)
                statement = set("$.userState.playState", "0", id: other)
            case "downloaded":
                statement = set("$.userState.isDownloaded", "json('true')", id: other)
            default:
                _ = try await b.store.requestDownload(episodeID: other, directory: world.root.appendingPathComponent("downloads-B"), enqueue: false)
                run.reference.requestDownload(otherWire, side: b.name)
                try await agree("requested")
                statement = "DELETE FROM download_jobs"
            }
            try await b.store.databaseForTesting { db in try db.execute(statement) }
            let found = try await run.referenceDifferences(b)
            #expect(!found.isEmpty, "a wrong \(field) passes the reference")
        }
    }

    /// Two settled phones with the reference told what they show, and `ids[0]`'s wire.
    static func settled(_ world: ExchangeWorld) async throws -> (run: Capture.Run, a: Capture.Side, b: Capture.Side, ids: [Int64], podcast: String) {
        let (pa, pb, _, ids, podcast) = try await ServerExchangeConcurrencyTests.twoPhones(world)
        let a = Capture.Side(pa), b = Capture.Side(pb)
        let run = Capture.Run(world: world, a: a, b: b, seed: 1)
        run.reader = try await ServerReadOracle(world.server)
        for _ in 0..<2 { for side in run.sides { await side.phone.exchange(); try await run.observe(side) } }
        return (run, a, b, ids, podcast)
    }

    /// Remove from inbox on an unplayed episode changes nothing and makes no fact: it is no write. Another phone's played
    /// mark then wins on both phones, and the reference expects exactly that (it once recorded an unplayed write here and
    /// took the empty outbox for its delivery).
    @Test func noopInboxDoesNotCreateAnUnplayedWrite() async throws {
        try await ExchangeWorld.run { world in
            let (run, a, b, ids, _) = try await Self.settled(world)
            let onB = try await ServerExchangeConcurrencyTests.same(ids[0], from: a.phone, on: b.phone)
            let wire = try #require(try await run.wire(a, ids[0]))
            try await run.mark(a, ids[0], played: false)
            for side in run.sides { await side.phone.exchange(); try await run.observe(side) }
            #expect(try await a.store.episode(id: ids[0])?.userState.playState == .unplayed)
            try await run.mark(b, onB, played: true)
            let outbox = try a.phone.rows("SELECT count(*) FROM ntp_outbox")
            try await run.dismiss(a, ids[0])
            #expect(try a.phone.rows("SELECT count(*) FROM ntp_outbox") == outbox, "no fact for an unplayed episode")
            for side in [a, b, a] { await side.phone.exchange(); try await run.observe(side) }
            #expect(try await a.store.episode(id: ids[0])?.userState.playState == .played, "B's played mark")
            #expect(run.reference.expected(.playState(wire), side: a.name) == .some(EpisodePlayState.played.rawValue))
            for side in run.sides { #expect(try await run.referenceDifferences(side).isEmpty) }
        }
    }

    /// A NEW episode's Remove from inbox, or its toggle-played swipe (NEW becomes unplayed), is a dismissal: while it is
    /// unsent, another phone's played mark pulled here shows played (the dismissal turns only NEW into unplayed), not
    /// unplayed as a register write would.
    @Test(arguments: ["remove from inbox", "toggle played"]) func pendingDismissIsNotUnplayedRegister(action: String) async throws {
        try await ExchangeWorld.run { world in
            let (run, a, b, _, podcast) = try await Self.settled(world)
            // A new episode published: filed NEW (the Inbox) on both phones.
            world.setFeed("/one.xml", ("One", "one", 6))
            _ = try? await a.phone.transport.server.send("POST", "v1/refresh", body: ["podcast_id": .string(podcast)])
            func newest(_ side: Capture.Side) async throws -> LibraryEpisode? {
                try await side.store.feeds().flatMap(\.episodes).first { $0.details.identifier == "one-6" }
            }
            let deadline = ContinuousClock.now + .seconds(60)
            while ContinuousClock.now < deadline {
                for side in run.sides { await side.phone.exchange(); try await run.observe(side) }
                if try await newest(a) != nil, try await newest(b) != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let onA = try #require(try await newest(a)), onB = try #require(try await newest(b))
            try #require(onA.userState.playState == .new && onB.userState.playState == .new, "filed in the Inbox")
            let wire = try #require(try await run.wire(a, onA.id))
            run.reference.initial[.playState(wire)] = EpisodePlayState.new.rawValue
            if action == "toggle played" { try await run.swipe(a, onA.id) } else { try await run.dismiss(a, onA.id) }
            #expect(try await a.store.episode(id: onA.id)?.userState.playState == .unplayed, "dismissed here")
            try await run.mark(b, onB.id, played: true)
            await b.phone.exchange(); try await run.observe(b)
            await a.phone.run([.pull, .apply]); try await run.observe(a, pushed: false)
            #expect(try await a.store.episode(id: onA.id)?.userState.playState == .played, "the pending dismissal does not undo PLAYED")
            #expect(run.reference.expected(.playState(wire), side: a.name) == .some(EpisodePlayState.played.rawValue))
            for side in run.sides { #expect(try await run.referenceDifferences(side).isEmpty) }
            await a.phone.exchange(); try await run.observe(a)
            #expect(try await a.store.episode(id: onA.id)?.userState.playState == .played)
            for side in run.sides { #expect(try await run.referenceDifferences(side).isEmpty) }
        }
    }
}
