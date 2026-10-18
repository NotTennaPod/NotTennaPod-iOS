import Foundation
import Testing
@testable import NotTennaPodCore

/// What a recovery cannot restore (PROTOCOL §6.11, §16 scenario 42): a fact the server refuses for good is quarantined
/// at once with everything that names it, kept on the device, never sent, and the library's new changes continue on
/// fresh authors, so synchronization never stops; a fact missing a dependency waits for another device to restore it,
/// retried at later exchanges indefinitely, with the facts chained behind it parked and still shown; it is never given
/// up (PROTOCOL §1.3). The recovery never claims to be complete while anything is refused.
@Suite(.serialized) struct ServerRecoveryQuarantineTests {
    typealias Copies = ServerCopiesTests
    typealias Recovery = ServerRecoveryTests
    typealias PushPull = ServerExchangePushPullTests

    /// Rewrites an archived fact's receipt in a phone's `sync.sqlite` (a damaged or tampered copy: its MAC no longer
    /// verifies, so the server answers `invalid_receipt`).
    static func tamperReceipt(_ phone: DevicePhone, _ opID: String) throws {
        let archive = try ServerArchive(url: try #require(phone.location.syncDatabase))
        defer { try? archive.close() }
        guard case .object(var receipt) = try #require(try archive.receipt(opID: opID)) else { Issue.record("no receipt"); return }
        receipt["mac"] = .string(String(repeating: "0", count: (receipt["mac"]?.stringValue ?? "").count))
        let data = try ServerArchive.compress(try ContractJSON.object(receipt).canonicalBytes())
        try archive.database.transaction { try archive.database.execute("UPDATE archive_entries SET receipt = ? WHERE op_id = ?", [.blob(data), .text(opID)]) }
    }

    static func removeFromArchive(_ phone: DevicePhone, _ opID: String) throws {
        let archive = try ServerArchive(url: try #require(phone.location.syncDatabase))
        defer { try? archive.close() }
        try archive.database.transaction { try archive.database.execute("DELETE FROM archive_entries WHERE op_id = ?", [.text(opID)]) }
    }

    static func lastFact(_ phone: DevicePhone) async throws -> String {
        try #require(try phone.rows("SELECT a.last_op_id FROM ntp_authors a JOIN ntp_library l ON l.main_author = a.author_id").first?.first ?? nil)
    }

    /// The provenance of a phone's favorite record of an episode: the fact that set it.
    static func favoriteFact(_ phone: DevicePhone, _ local: Int64) async throws -> String {
        let wire = try #require(try await phone.store.wireEpisodeForTesting(local))
        return try #require(try phone.rows("SELECT value FROM json_each((SELECT provenance FROM ntp_records WHERE entity = 'episode' AND field_group = 'favorite' AND id = '\(wire)'))").first?.first ?? nil)
    }

    /// A fact the server refuses for good (its receipt no longer verifies) in the middle of this device's chain: it and
    /// every later fact naming it are quarantined at once; new changes continue on a fresh author the server admits, and
    /// the library shows exactly what the server has.
    @Test(arguments: [nil, "recovery.quarantined"]) func aRefusedFactMidChainIsQuarantinedAndLaterChangesFlow(crash point: String?) async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Copies.subscribed(world)
            let b = try await world.device("B")
            let onB = try await ids.asyncMap { try await Recovery.same($0, from: a, on: b) }
            let backup = try await world.backUp()
            try await b.store.setFavorite(episodeID: onB[0], favorite: true)
            await b.exchange()
            let refused = try await Self.lastFact(b)
            try await b.store.markEpisodePlayed(episodeID: onB[1], played: true)
            await b.exchange()
            let dependent = try await Self.lastFact(b)
            let author = try #require(try b.rows("SELECT main_author FROM ntp_library").first?.first ?? nil)
            try Self.tamperReceipt(b, refused)
            await a.close()
            try await world.restore(backup)
            #expect(await b.engine.exchange().pause == .signIn)
            try await b.signInAgain()
            if let point { await b.engine.setCrashPoint(PushPull.crashOnce(at: point)) }
            let report = await b.engine.exchange()
            if point != nil {
                #expect(report.error == "InjectedCrash()", "\(report.error ?? "no crash")")
                try await b.relaunch()
                await b.exchange()
            }
            let recovery = try #require(try await Recovery.recovery(b))
            #expect(recovery.finished && recovery.complete == false && !recovery.waiting, "\(recovery)")
            #expect(try await b.engine.exchange().recovery == .incomplete, "the page says some changes could not be restored")
            #expect(try b.rows("SELECT main_author != '\(author)' FROM ntp_library") == [["1"]], "a fresh author continues")
            #expect(try b.rows("SELECT count(*) FROM ntp_overlays") == [["0"]])
            #expect(try await b.log().contains { $0.kind == "recovery" && $0.detail.contains("can never be restored") })
            // A later change flows on the fresh author: the server admits a first fact without a fork.
            try await b.store.setFavorite(episodeID: onB[2], favorite: true)
            try await world.converge([b], point ?? "refused")
            let view = try await b.view()
            let wires = try await onB.prefix(3).map { $0 }.asyncMap { try #require(try await b.store.wireEpisodeForTesting($0)) }
            #expect(view.episodes[wires[2]]?.favorite == true, "the later change reached the server")
            #expect(view.episodes[wires[0]]?.favorite == false && view.episodes[wires[1]]?.playState != .played,
                    "the unrestorable changes show as the server has them")
            _ = dependent
        }
    }

    /// A fact missing a dependency waits (scenario 20 PROTOCOL §16 style): the device that holds the dependency recovers
    /// later, the waiting fact is uploaded again at the next exchange and joins, and the recovery completes.
    @Test(arguments: [nil, "recovery.retried"]) func aMissingDependencyAnotherDeviceRestoresLaterJoins(crash point: String?) async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Copies.subscribed(world)
            let b = try await world.device("B")
            let onB = try await ids.asyncMap { try await Recovery.same($0, from: a, on: b) }
            let backup = try await world.backUp()
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            await a.exchange()
            await b.exchange()
            let dependency = try await Self.favoriteFact(b, onB[0])
            try await b.store.setFavorite(episodeID: onB[0], favorite: false)
            await b.exchange()
            try Self.removeFromArchive(b, dependency)
            try await world.restore(backup)
            #expect(await b.engine.exchange().pause == .signIn)
            try await b.signInAgain()
            let first = await b.engine.exchange()
            #expect(first.recovery == .waiting, "\(String(describing: first.recovery))")
            let waiting = try #require(try await Recovery.recovery(b))
            #expect(waiting.caughtUp && waiting.waiting && !waiting.finished && waiting.finishSent)
            #expect(try await b.log().contains { $0.detail.contains("wait for another device") })
            // A, which holds the dependency, recovers: it is restored.
            _ = try await Recovery.recover(a)
            if let point {
                await b.engine.setCrashPoint(PushPull.crashOnce(at: point))
                #expect(await b.engine.exchange().error == "InjectedCrash()")
                try await b.relaunch()
            }
            await b.engine.exchange()
            await b.engine.exchange()
            let recovery = try #require(try await Recovery.recovery(b))
            #expect(recovery.finished && recovery.complete == true, "\(recovery)")
            try await world.converge([a, b], point ?? "joined later")
            #expect(try await b.view().episodes[try #require(try await b.store.wireEpisodeForTesting(onB[0]))]?.favorite == false,
                    "B's later change, which waited, is applied")
        }
    }

    /// The provenance of a phone's record of an episode: the fact that wrote it.
    static func provenance(_ phone: DevicePhone, _ local: Int64, _ group: String) async throws -> String {
        let wire = try #require(try await phone.store.wireEpisodeForTesting(local))
        return try #require(try phone.rows("SELECT value FROM json_each((SELECT provenance FROM ntp_records WHERE entity = 'episode' AND field_group = '\(group)' AND id = '\(wire)'))").first?.first ?? nil)
    }

    /// A waiting chain (scenario 42 PROTOCOL §16's "every copy destroyed" until another device returns): A queues e0 (X); B
    /// pulls it and queues e1 (Y, which names X's queue record), acknowledged but not pulled before the server is
    /// restored from an earlier backup; B has lost X, which only A still holds. After the restore, before signing in
    /// again, B favorites e3 (W, chained behind Y). B's recovery cannot join Y: it waits, W is parked, both still shown,
    /// and so is X, which B had received (a restored server never rolls the phone back).
    static func waitingChain(_ world: ExchangeWorld, crash point: String? = nil) async throws -> (a: DevicePhone, b: DevicePhone, onB: [Int64], author: String) {
        let (a, ids) = try await Copies.subscribed(world)
        let b = try await world.device("B")
        let onB = try await ids.asyncMap { try await Recovery.same($0, from: a, on: b) }
        let backup = try await world.backUp()
        _ = try await a.store.enqueue([ids[0]])
        await a.exchange()
        await b.exchange()
        let lost = try await Self.provenance(b, onB[0], "queue_membership")
        _ = try await b.store.enqueue([onB[1]])
        _ = await b.engine.run([.push])
        #expect(try b.rows("SELECT count(*) FROM ntp_outbox WHERE receipt IS NOT NULL") == [["1"]], "Y acknowledged, not pulled")
        try Self.removeFromArchive(b, lost)
        let author = try #require(try b.rows("SELECT main_author FROM ntp_library").first?.first ?? nil)
        try await world.restore(backup)
        #expect(await b.engine.exchange().pause == .signIn)
        try await b.store.setFavorite(episodeID: onB[3], favorite: true)
        try await b.signInAgain()
        if let point { await b.engine.setCrashPoint(PushPull.crashOnce(at: point)) }
        let report = await b.engine.exchange()
        if point != nil {
            #expect(report.error == "InjectedCrash()", "\(report.error ?? "no crash")")
            try await b.relaunch()
            await b.engine.exchange()
        }
        let recovery = try #require(try await Recovery.recovery(b))
        #expect(recovery.caughtUp && recovery.waiting && !recovery.finished && recovery.finishSent, "\(recovery)")
        return (a, b, onB, author)
    }

    static func shows(_ phone: DevicePhone, _ onB: [Int64]) async throws -> (queued: [String], favorites: Set<String>, wires: [String]) {
        let view = try await phone.view()
        let wires = try await onB.asyncMap { try #require(try await phone.store.wireEpisodeForTesting($0)) }
        return (view.queue, Set(view.episodes.filter { $0.value.favorite }.keys), wires)
    }

    /// Never resolved (PROTOCOL §1.3, §6: unsent changes never expire): the waiting changes keep being shown and are tried
    /// again at every exchange, across relaunches, while the device's new changes flow on a fresh author.
    @Test(arguments: [nil, "recovery.parked"]) func aDependencyNobodyRestoresKeepsWaitingWhileNewChangesFlow(crash point: String?) async throws {
        try await ExchangeWorld.run { world in
            let (a, b, onB, author) = try await Self.waitingChain(world, crash: point)
            await a.close()
            #expect(try b.rows("SELECT count(*) FROM ntp_retained WHERE CAST(lineage AS TEXT) LIKE '%\"parked\"%'") == [["1"]], "W is parked")
            #expect(try await b.store.serverUnsentChanges() == 1, "the parked change counts as not yet synchronized")
            var shown = try await Self.shows(b, onB)
            #expect(shown.queued == [shown.wires[0], shown.wires[1]] && shown.favorites == [shown.wires[3]], "the waiting changes stay shown: \(shown)")
            #expect(try b.rows("SELECT main_author != '\(author)' FROM ntp_library") == [["1"]], "a fresh author continues")
            #expect(try await b.log().contains { $0.detail.contains("wait behind changes another device may restore") })
            // A new change flows on the fresh author.
            try await b.store.setFavorite(episodeID: onB[2], favorite: true)
            #expect(await b.engine.exchange().recovery == .waiting)
            let fresh = try await world.attach("fresh-waiting")
            let server = try await fresh.view()
            await fresh.close()
            #expect(server.episodes[shown.wires[2]]?.favorite == true, "the new change reached the server")
            #expect(server.queue.isEmpty && server.episodes[shown.wires[3]]?.favorite == false, "the waiting ones did not")
            // A relaunch keeps waiting and showing them.
            try await b.relaunch()
            #expect(await b.engine.exchange().recovery == .waiting)
            shown = try await Self.shows(b, onB)
            #expect(shown.queued == [shown.wires[0], shown.wires[1]] && shown.favorites == [shown.wires[2], shown.wires[3]], "\(shown)")
            #expect(try await Recovery.recovery(b)?.finished == false)
        }
    }

    /// Resolved much later: A, which holds what Y needs, recovers; B's next exchange uploads Y again, it joins, W goes back
    /// to the end of the outbox and is sent, and B ends exactly as the server.
    @Test(arguments: [nil, "recovery.unparked"]) func aDependencyRestoredMuchLaterReleasesTheParkedChanges(crash point: String?) async throws {
        try await ExchangeWorld.run { world in
            let (a, b, onB, _) = try await Self.waitingChain(world)
            _ = try await Recovery.recover(a)
            if let point {
                await b.engine.setCrashPoint(PushPull.crashOnce(at: point))
                #expect(await b.engine.exchange().error == "InjectedCrash()")
                try await b.relaunch()
            }
            await b.engine.exchange()
            await b.engine.exchange()
            let recovery = try #require(try await Recovery.recovery(b))
            #expect(recovery.finished && recovery.complete == true, "\(recovery)")
            #expect(try b.rows("SELECT count(*) FROM ntp_retained") == [["0"]], "nothing parked or retained is left")
            try await world.converge([a, b], point ?? "released")
            let shown = try await Self.shows(b, onB)
            #expect(shown.queued == [shown.wires[0], shown.wires[1]] && shown.favorites == [shown.wires[3]], "\(shown)")
        }
    }
}
