import Foundation
import Testing
@testable import NotTennaPodCore

/// Recovery after a server restore against the pinned server, restored with its own `backup`, `keys` and `restore`
/// commands while stopped (PROTOCOL §6.11; scenarios 20, 30, 32 and 42 PROTOCOL §16): every device
/// signs in again, takes a successor installation with its own nonce, tells the server what it holds, uploads what the
/// restored server lacks with the original receipts, catches up, pushes its renumbered outbox and finishes, saying
/// truthfully whether everything was restored. Every step resumes after a crash and after a second restore.
@Suite(.serialized) struct ServerRecoveryTests {
    typealias Copies = ServerCopiesTests
    typealias PushPull = ServerExchangePushPullTests

    static func same(_ id: Int64, from a: DevicePhone, on phone: DevicePhone) async throws -> Int64 {
        let wire = try #require(try await a.store.wireEpisodeForTesting(id))
        return try #require(try await phone.store.localEpisodeForTesting(wire: wire))
    }

    /// After a restore the token is gone: the first exchange asks to sign in again, the next one recovers.
    static func recover(_ phone: DevicePhone, sourceLocation: SourceLocation = #_sourceLocation) async throws -> ServerExchangeReport {
        let first = await phone.engine.exchange()
        #expect(first.pause == .signIn, "\(phone.name): \(String(describing: first.pause)) \(first.error ?? "")", sourceLocation: sourceLocation)
        try await phone.signInAgain()
        return await phone.exchange(sourceLocation: sourceLocation)
    }

    static func recovery(_ phone: DevicePhone) async throws -> ServerRecoveryRecord? { try await phone.store.serverRecovery() }

    /// 20. The server is restored from an older backup while three devices have newer changes, one of them a change
    /// another device had only received (its author never returns): after recovery every device converges to the
    /// newest state, nothing is lost, and the recovery says it is complete.
    @Test func scenario20EveryDeviceRecoversAndConverges() async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Copies.subscribed(world)
            let b = try await world.device("B"), c = try await world.device("C")
            let backup = try await world.backUp()
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            await a.exchange()
            await b.exchange()
            try await c.store.markEpisodePlayed(episodeID: try await Self.same(ids[1], from: a, on: c), played: true)
            await c.exchange()
            _ = try await b.store.enqueue([try await Self.same(ids[2], from: a, on: b)])
            let before = try await b.view()
            var wires: [String] = []
            for id in ids.prefix(3) { wires.append(try #require(try await a.store.wireEpisodeForTesting(id))) }
            await a.close()
            try await world.restore(backup)
            for phone in [b, c] {
                let report = try await Self.recover(phone)
                #expect(report.recovery == nil, "\(phone.name): recovered completely")
                let recovery = try await Self.recovery(phone)
                #expect(recovery?.finished == true && recovery?.complete == true)
                #expect(try phone.rows("SELECT count(*) FROM ntp_retained") == [["0"]], "\(phone.name): nothing retained after recovery")
            }
            #expect(try await b.view().withoutTitles.differences(from: before.withoutTitles).isEmpty, "B shows what it showed")
            try await world.converge([b, c], "restored")
            let view = try await c.view()
            #expect(view.episodes[wires[0]]?.favorite == true, "A's change, restored from B, which had only received it")
            #expect(view.episodes[wires[1]]?.playState == .played, "C's change")
            #expect(view.queue == [wires[2]], "B's unsent change, pushed under its successor")
            #expect(try await b.log().contains { $0.kind == "recovery" && $0.detail.hasPrefix("finished: every change") })
        }
    }

    /// 30, 32. The device that made the changes comes back after another device restored them from what it had only
    /// received: its own upload is known, nothing applies twice. Changes made after the backup (a podcast created, a
    /// queue removal and its Undo, marks) are restored from two replicas, in both orders.
    @Test(arguments: [false, true]) func twoReplicasRecoverTheSameChangesInEitherOrder(authorFirst: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Copies.subscribed(world)
            let b = try await world.device("B")
            let backup = try await world.backUp()
            let two = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("two.xml"), title: "Two", prefix: "two", count: 3))
            try await Copies.waitForCatalog(a, feedID: two.id)
            _ = try await a.store.enqueue([ids[0], ids[1]])
            let receipt = try #require(try await a.store.removeFromQueueWithUndo(ids[0]).receipt)
            #expect(try await a.store.undoQueueRemoval(receipt).status == .restored)
            try await a.store.markEpisodePlayed(episodeID: ids[2], played: true)
            try await a.store.setFavorite(episodeID: two.episodes[0].id, favorite: true)
            await a.exchange()
            await b.exchange()
            let expected = try await a.view()
            try await world.restore(backup)
            for phone in authorFirst ? [a, b] : [b, a] { _ = try await Self.recover(phone) }
            try await world.converge([a, b], authorFirst ? "author first" : "replica first")
            let view = try await b.view()
            #expect(view.withoutTitles.differences(from: expected.withoutTitles).isEmpty, "every change once: \(view.withoutTitles.differences(from: expected.withoutTitles))")
            #expect(view.queue.count == 2)
        }
    }

    /// A prefix recovery (PROTOCOL §6.11): the backup still has this device's history up to its cursor, so only what it pushed
    /// after (retained, receipted entries) is inventoried and uploaded; the cursor is re-issued and the device catches
    /// up by pulls.
    @Test func aPrefixRecoveryUploadsOnlyWhatFollowsTheCursor() async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Copies.subscribed(world)
            await a.exchange()
            let backup = try await world.backUp()
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            _ = await a.engine.run([.push])
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox WHERE receipt IS NOT NULL") == [["1"]], "acknowledged, not pulled")
            try await world.restore(backup)
            let first = await a.engine.exchange()
            #expect(first.pause == .signIn)
            try await a.signInAgain()
            await a.exchange()
            let recovery = try #require(try await Self.recovery(a))
            #expect(recovery.prefix == true && recovery.finished && recovery.complete == true)
            #expect(try await a.log().contains { $0.kind == "recovery" && $0.detail.hasPrefix("the server still holds") })
            #expect(try a.rows("SELECT count(*) FROM ntp_retained") == [["0"]] && a.rows("SELECT count(*) FROM ntp_overlays") == [["0"]])
            try await world.converge([a], "prefix")
            #expect(try await a.view().episodes[try #require(try await a.store.wireEpisodeForTesting(ids[0]))]?.favorite == true)
        }
    }

    /// 42 (an oversize command and a refused operation): a fact over the unframed bound that the server refused is
    /// recovered in parts with its original receipt, across a crash between two parts, and the change after it in the
    /// device's chain is restored too; nothing is reported lost.
    @Test func aFramedRefusedFactIsRecoveredInPartsAcrossACrash() async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Copies.subscribed(world)
            let backup = try await world.backUp()
            let reference = try #require(try await a.store.episodeRefForTesting(ids[0]))
            let oversize = try await a.store.appendFactForTesting(type: "favorite.set", targets: [reference.target], payload: [
                "episode": reference.ref, "favorite": true, "note": .string(String(repeating: "x", count: 300 * 1_024))])
            try await a.store.setFavorite(episodeID: ids[1], favorite: true)
            await a.exchange()
            let archive = try ServerArchive(url: try #require(a.location.syncDatabase))
            let receipt = try archive.receipt(opID: oversize)
            try archive.close()
            #expect(receipt?["outcome"]?.stringValue == "rejected", "the server refused it: \(String(describing: receipt))")
            try await world.restore(backup)
            #expect(await a.engine.exchange().pause == .signIn)
            try await a.signInAgain()
            await a.engine.setCrashPoint(PushPull.crashOnce(at: "recovery.part"))
            #expect(await a.engine.exchange().error == "InjectedCrash()", "a crash between two parts")
            try await a.relaunch()
            await a.exchange()
            let recovery = try #require(try await Self.recovery(a))
            #expect(recovery.finished && recovery.complete == true, "\(recovery)")
            try await world.converge([a], "framed")
            #expect(try await a.view().episodes[try #require(try await a.store.wireEpisodeForTesting(ids[1]))]?.favorite == true)
        }
    }

    /// A crash (a failure after a commit, before the next step) at every step of the recovery handoff: the transition
    /// (PROTOCOL §6.11–3), the recovery snapshot, inventory, upload, catch-up and finish. After a relaunch the recovery
    /// resumes from the live database, finishes once, and every device converges.
    @Test(arguments: ["recovery.started", "transition.token", "transition.issued", "transition.committed", "recovery.opened",
                      "recovery.inventoried", "recovery.upload.response", "recovery.uploaded", "recovery.caught_up", "recovery.finish"])
    func aCrashAtEveryRecoveryStepResumes(point: String) async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Copies.subscribed(world)
            let b = try await world.device("B")
            let backup = try await world.backUp()
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            await a.exchange()
            try await b.store.markEpisodePlayed(episodeID: try await Self.same(ids[1], from: a, on: b), played: true)
            await b.exchange()
            try await a.store.markEpisodePlayed(episodeID: ids[3], played: true)
            try await world.restore(backup)
            #expect(await a.engine.exchange().pause == .signIn)
            try await a.signInAgain()
            await a.engine.setCrashPoint(PushPull.crashOnce(at: point))
            let crashed = await a.engine.exchange()
            #expect(crashed.error == "InjectedCrash()", "\(point): \(crashed.error ?? "no crash") \(String(describing: crashed.pause))")
            try await a.relaunch()
            await a.exchange()
            let recovery = try #require(try await Self.recovery(a))
            #expect(recovery.finished && recovery.complete == true, "\(point): \(recovery)")
            _ = try await Self.recover(b)
            try await world.converge([a, b], point)
            let view = try await b.view()
            #expect(view.episodes[try #require(try await a.store.wireEpisodeForTesting(ids[0]))]?.favorite == true, "\(point)")
            #expect(view.episodes[try #require(try await a.store.wireEpisodeForTesting(ids[3]))]?.playState == .played, "\(point)")
        }
    }

    /// A second restore during recovery (PROTOCOL §6.11: "a repeated crash or a second restore resumes from the persisted state"):
    /// the device stopped after its uploads, then the server was restored again; its next run finds the new epoch,
    /// inventories again and uploads again, and nothing is lost.
    @Test func aSecondRestoreDuringRecoveryResumes() async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Copies.subscribed(world)
            let backup = try await world.backUp()
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            await a.exchange()
            try await world.restore(backup)
            #expect(await a.engine.exchange().pause == .signIn)
            try await a.signInAgain()
            await a.engine.setCrashPoint(PushPull.crashOnce(at: "recovery.uploaded"))
            #expect(await a.engine.exchange().error == "InjectedCrash()")
            let interrupted = try #require(try await Self.recovery(a))
            #expect(!interrupted.finished && interrupted.epoch != nil)
            try await a.relaunch()
            try await a.store.markEpisodePlayed(episodeID: ids[1], played: true)
            try await world.restore(backup)
            _ = try await Self.recover(a)
            let recovery = try #require(try await Self.recovery(a))
            #expect(recovery.finished && recovery.complete == true && recovery.epoch != interrupted.epoch)
            #expect(try await a.log().contains { $0.detail.hasPrefix("the server was restored again") })
            try await world.converge([a], "second restore")
            let view = try await a.view()
            #expect(view.episodes[try #require(try await a.store.wireEpisodeForTesting(ids[0]))]?.favorite == true)
            #expect(view.episodes[try #require(try await a.store.wireEpisodeForTesting(ids[1]))]?.playState == .played)
        }
    }

    /// A restore after a finished recovery starts a new one: the receipts the successor got move aside too.
    @Test func aRestoreAfterARecoveryStartsAnotherOne() async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Copies.subscribed(world)
            let backup = try await world.backUp()
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            await a.exchange()
            try await world.restore(backup)
            _ = try await Self.recover(a)
            let first = try #require(try await Self.recovery(a))
            try await a.store.markEpisodePlayed(episodeID: ids[1], played: true)
            await a.exchange()
            try await world.restore(backup)
            _ = try await Self.recover(a)
            let second = try #require(try await Self.recovery(a))
            #expect(second.recoveryID != first.recoveryID && second.finished && second.complete == true)
            try await world.converge([a], "two restores")
            let view = try await a.view()
            #expect(view.episodes[try #require(try await a.store.wireEpisodeForTesting(ids[0]))]?.favorite == true)
            #expect(view.episodes[try #require(try await a.store.wireEpisodeForTesting(ids[1]))]?.playState == .played)
        }
    }

    /// The podcast of the episode B's player holds is removed and subscribed again elsewhere while B does not exchange;
    /// the server is then restored from a backup older than the subscription and A's recovery restores the history. B's
    /// full recovery (its cursor is not in the restored log) jumps over the removal and the new subscription: the re-added
    /// podcast gets rows of its own, the held episode is detached at 41 s, and resuming it after a relaunch records nothing
    /// in the new generation (a fresh attachment and A's Force full show no listening). A known issue: the snapshot carries
    /// no sign that the old generation closed (a generation joined into another changes the ID the same way), so the
    /// phone cannot tell the skipped removal from a live join.
    @Test func aFullRecoveryCatchingAMissedRemoveAndReaddDetachesTheOldPlayer() async throws {
        await withKnownIssue("ledger: held-detach — a full recovery that skips a remove and re-add") {
            try await ExchangeWorld.run { world in
                let a = try await world.device("A")
                let backup = try await world.backUp()
                let feed = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
                try await Copies.waitForCatalog(a, feedID: feed.id)
                let b = try await world.device("B")
                let onB = try await Self.same(feed.episodes.map(\.id).sorted()[0], from: a, on: b)
                let identifier = try #require(try await b.store.episode(id: onB)?.details.identifier)
                let feedB = try await b.store.feedID(forEpisode: onB)
                var player = StorePlayer(b.store, realTime: ())
                try await player.load(onB); try await player.play(); try await player.listen(41); try await player.pause()
                await b.exchange()
                _ = try await a.store.requestFeedDeletion(feedID: feed.id)
                await a.exchange()
                let again = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
                try await Copies.waitForCatalog(a, feedID: again.id)
                await a.exchange()
                try await world.restore(backup)
                _ = try await Self.recover(a)
                _ = try await Self.recover(b)
                for phone in [a, b] {
                    let recovery = try await Self.recovery(phone)
                    #expect(recovery?.finished == true && recovery?.complete == true, "\(phone.name): recovered completely")
                }
                #expect(try await Self.recovery(b)?.prefix == false, "B's recovery is a full snapshot")
                func reopened(_ phone: DevicePhone) async throws -> LibraryEpisode? {
                    try await phone.store.feeds().flatMap(\.episodes).first { $0.details.identifier == identifier }
                }
                let shown = try #require(try await reopened(b), "B shows the re-added podcast")
                #expect(shown.id != onB, "in rows of its own")
                #expect(shown.userState.positionMilliseconds == 0 && shown.userState.playedDurationMilliseconds == 0, "fresh")
                #expect(try b.rows("SELECT count(*) FROM ntp_episodes WHERE local_id = \(onB)") == [["0"]], "the held row is detached")
                #expect(try b.rows("SELECT count(*) FROM ntp_podcasts WHERE feed_id = \(feedB)") == [["0"]])
                #expect(try await b.store.episode(id: onB)?.userState.positionMilliseconds == 41_000, "the player keeps its position")
                try await b.relaunch()
                player = try await StorePlayer.restored(b.store)
                try await player.load(onB); try await player.play(); try await player.listen(5); try await player.pause()
                for _ in 0..<3 { await b.exchange(); await a.exchange() }
                #expect(try await b.store.serverUnsentChanges() == 0)
                let fresh = try await world.attach("fresh")
                let onFresh = try #require(try await fresh.store.feeds().flatMap(\.episodes).first { $0.details.identifier == identifier })
                #expect(onFresh.userState.playedDurationMilliseconds == 0 && onFresh.userState.positionMilliseconds == 0, "no listening in the new generation")
                await fresh.close()
                await a.engine.requestFullSynchronization()
                _ = await a.engine.forceFullSynchronization()
                #expect(try await reopened(a)?.userState.playedDurationMilliseconds == 0, "A after its Force full")
            }
        }
    }

    /// An episode already detached on B (its podcast removed while B held it) stays detached through a restore and both
    /// devices' recoveries: its position stays, listening on pushes nothing, the server library stays empty, and the
    /// release deletes it.
    @Test func recoveryWhileDetachedDoesNotReconnectIt() async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Copies.subscribed(world)
            let b = try await world.device("B")
            let backup = try await world.backUp()
            let onB = try await Self.same(ids[0], from: a, on: b)
            let feedB = try await b.store.feedID(forEpisode: onB)
            let player = StorePlayer(b.store, realTime: ())
            try await player.load(onB); try await player.play(); try await player.listen(41); try await player.pause()
            _ = try await a.store.requestFeedDeletion(feedID: try await a.store.feedID(forEpisode: ids[0]))
            await a.exchange(); await b.exchange(); await b.exchange()
            #expect(try b.rows("SELECT count(*) FROM ntp_episodes WHERE local_id = \(onB)") == [["0"]], "detached")
            try await world.restore(backup)
            _ = try await Self.recover(a)
            _ = try await Self.recover(b)
            #expect(try b.rows("SELECT count(*) FROM ntp_episodes WHERE local_id = \(onB)") == [["0"]], "still detached")
            #expect(try b.rows("SELECT count(*) FROM ntp_podcasts WHERE feed_id = \(feedB)") == [["0"]])
            #expect(try await b.store.feeds().isEmpty)
            #expect(try await b.store.episode(id: onB)?.userState.positionMilliseconds == 41_000)
            let mark = b.transport.requests.count
            try await player.play(); try await player.listen(5); try await player.pause()
            for _ in 0..<2 { await b.exchange(); await a.exchange() }
            let pushes = b.transport.requests.dropFirst(mark).filter { $0.path == "v1/push" }
            let operations: [ContractJSON] = pushes.flatMap { request -> [ContractJSON] in request.body?["operations"]?.arrayValue ?? [] }
            #expect(operations.isEmpty, "nothing of it reached the server")
            let fresh = try await world.attach("fresh")
            #expect(try await fresh.store.feeds().isEmpty, "the server library stays empty")
            await fresh.close()
            _ = try await player.end(.skipped)
            await b.engine.releasePins()
            #expect(try await b.store.episode(id: onB) == nil, "released")
        }
    }
}
