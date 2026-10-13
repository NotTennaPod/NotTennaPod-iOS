import Foundation
import Testing
@testable import NotTennaPodCore

/// Crash permutations (scenarios 2 and 29 PROTOCOL §16): the process dies at every step of push,
/// pull, apply, shadow build and publish; after a relaunch the exchange continues, nothing is lost or applied twice,
/// and a unit that crashed inside its transaction left nothing of itself visible.
@Suite(.serialized, .timeLimit(.minutes(30))) struct ServerExchangeCrashTests {
    typealias Concurrency = ServerExchangeConcurrencyTests
    typealias PushPull = ServerExchangePushPullTests

    /// Steps outside any live transaction, steps inside a unit's (rolled back), and the shadow path's.
    static let points = ["push.barrier", "push.response", "push.recorded", "pull.spooled", "pull.archived", "apply.before",
                         "unit.base", "unit.retired", "unit.written", "apply.after",
                         "shadow.built", "publish.base", "publish.written", "shadow.published"]

    static func shadowed(_ point: String) -> Bool { point.hasPrefix("shadow") || point.hasPrefix("publish") }

    @Test(arguments: points) func aCrashAtEveryStepLosesNothingAndAppliesNothingTwice(point: String) async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let onC = try await ids.asyncMap { try await Concurrency.same($0, from: a, on: c) }
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            _ = try await a.store.enqueue([ids[1], ids[2]])
            try await c.store.markEpisodePlayed(episodeID: onC[3], played: true)
            try await c.store.setFavorite(episodeID: onC[4], favorite: true)
            _ = try await c.store.enqueue([onC[4]])
            await c.exchange()
            if Self.shadowed(point) { await a.engine.setBudgets(direct: 1) }
            let cursorBefore = try a.rows("SELECT seq FROM ntp_library")
            let recordsBefore = try a.rows("SELECT count(*), coalesce(sum(length(value)), 0) FROM ntp_records")
            await a.engine.setCrashPoint(PushPull.crashOnce(at: point))
            let crashed = await a.engine.exchange()
            #expect(crashed.error == "InjectedCrash()", "\(point): the crash happened: \(String(describing: crashed.error))")
            if point.hasPrefix("unit.") || point.hasPrefix("publish.") {
                // Inside the unit's transaction: nothing of the unit is visible.
                #expect(try a.rows("SELECT seq FROM ntp_library") == cursorBefore, "\(point): the cursor did not move")
                #expect(try a.rows("SELECT count(*), coalesce(sum(length(value)), 0) FROM ntp_records") == recordsBefore,
                        "\(point): no record of the unit is in the base")
            }
            try await a.relaunch()
            if Self.shadowed(point) { await a.engine.setBudgets(direct: 1) }
            try await Concurrency.converge(world, [a, c], point)
            #expect(try await a.store.serverUnsentChanges() == 0, "\(point): nothing left unsent")
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox") == [["0"]], "\(point): every fact retired")
            let view = try await a.view()
            #expect(view.queue.count == 3, "\(point): A's two adds and C's one, each once: \(view.queue.count)")
            #expect(view.episodes[try #require(try await a.store.wireEpisodeForTesting(ids[0]))]?.favorite == true)
            #expect(view.episodes[try #require(try await a.store.wireEpisodeForTesting(ids[3]))]?.playState == .played)
            #expect(try a.rows("SELECT count(*) FROM ntp_overlays") == [["0"]], "\(point): every overlay retired")
        }
    }

    /// The process dies right after the unit that removed most of the queue committed, before its
    /// safeguard reached the archive. After the relaunch the copy is there, once.
    @Test func aCrashAfterAQueueRemovingUnitKeepsItsSafeguard() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            _ = try await a.store.enqueue(Array(ids.prefix(4)))
            await a.exchange()
            await c.exchange()
            _ = try await c.store.clearQueue()
            await c.exchange()
            await a.run([.pull])
            await a.engine.setCrashPoint(PushPull.crashOnce(at: "apply.after"))
            #expect(await a.engine.run([.apply]).error == "InjectedCrash()")
            #expect(try await a.store.queue().isEmpty, "the unit committed")
            try await a.relaunch()
            await a.exchange()
            let archive = try ServerArchive(url: try #require(a.location.syncDatabase))
            let copies = try archive.queueSafeguards()
            try archive.close()
            #expect(copies.count == 1, "\(copies.count) copies")
            let members = copies.first?["episodes"]?.arrayValue ?? []
            #expect(members.count == 4 && members.allSatisfy { $0["title"]?.stringValue != nil })
            #expect(try a.rows("SELECT count(*) FROM ntp_pending_safeguards") == [["0"]], "moved into the archive")
        }
    }
}
