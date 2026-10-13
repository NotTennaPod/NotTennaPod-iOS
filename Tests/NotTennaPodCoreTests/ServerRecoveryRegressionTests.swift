import Foundation
import Testing
@testable import NotTennaPodCore

/// Recovery against the pinned server restored with its own commands.
@Suite(.serialized, .timeLimit(.minutes(30))) struct ServerRecoveryRegressionTests {
    typealias Copies = ServerCopiesTests
    typealias Recovery = ServerRecoveryTests
    typealias Quarantine = ServerRecoveryQuarantineTests
    typealias Agreement = ServerExchangeAgreementTests
    typealias PushPull = ServerExchangePushPullTests

    /// A finished download of `episode`: the file attached and the episode marked downloaded, as the downloader leaves it.
    static func download(_ phone: DevicePhone, _ episode: Int64) async throws -> LibraryEpisode {
        let directory = phone.location.folder.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let job = try #require(try await phone.store.requestDownload(episodeID: episode, directory: directory, enqueue: false))
        let started = try #require(try await phone.store.beginDownloadAttempt(id: job.id))
        try Data(count: 64).write(to: job.destination)
        #expect(try await phone.store.attachDownloadFile(id: job.id, attempt: started.attempts))
        #expect(try await phone.store.completeDownload(id: job.id, attempt: started.attempts))
        let downloaded = try #require(try await phone.store.episode(id: episode))
        #expect(downloaded.userState.isDownloaded && downloaded.userState.localFileURL != nil)
        return downloaded
    }

    static func feedDeletions(_ phone: DevicePhone) async throws -> Int {
        try await phone.store.pendingEffects().filter { if case .deleteFeed = $0.effect.kind { true } else { false } }.count
    }


    /// A podcast subscribed after the backup, its catalog synchronized and an episode downloaded: the restored server
    /// lacks it until this device uploads it. The recovery's base switch holds everything the uploads restored, so the
    /// podcast is never removed and put back: the same local episode, still downloaded, no feed deletion. A crash in the
    /// publication window resumes the same way.
    @Test(arguments: [nil, "recovery.uploaded", "full.staged", "full.built", "full.written", "full.published"])
    func fullRecoveryKeepsPostBackupDownloads(crash point: String?) async throws {
        try await ExchangeWorld.run { world in
            let (a, _) = try await Copies.subscribed(world)
            let backup = try await world.backUp()
            let two = try await a.store.insert(Agreement.fetched(world.url("two.xml"), title: "Two", prefix: "two", count: 3))
            try await Copies.waitForCatalog(a, feedID: two.id)
            let episode = try #require(two.episodes.map(\.id).min())
            let before = try await Self.download(a, episode)
            await a.exchange()
            try await world.restore(backup)
            #expect(await a.engine.exchange().pause == .signIn)
            try await a.signInAgain()
            var deleted: [Int64] = []
            if let point {
                await a.engine.setCrashPoint(PushPull.crashOnce(at: point))
                let crashed = await a.engine.exchange()
                #expect(crashed.error == "InjectedCrash()", "\(point): \(crashed.error ?? "no crash")")
                deleted += crashed.deletedFeeds
                try await a.relaunch()
            }
            let report = await a.exchange()
            deleted += report.deletedFeeds
            let recovery = try #require(try await Recovery.recovery(a))
            #expect(recovery.finished && recovery.complete == true, "\(recovery)")
            #expect(deleted.isEmpty, "no podcast removed: \(deleted)")
            #expect(try await Self.feedDeletions(a) == 0, "no feed deletion queued")
            let after = try #require(try await a.store.episode(id: episode), "the same local episode")
            #expect(after.userState.isDownloaded && after.userState.localFileURL == before.userState.localFileURL,
                    "still downloaded: \(after.userState)")
            #expect(try await a.store.feed(id: two.id) != nil, "the same local podcast")
            try await world.converge([a], point ?? "downloads")
        }
    }


    /// B favorites e0 (X), and A pulls X; B then favorites e1 (Y, chained after X) and, with `queue`, queues e2 (Z,
    /// after Y): all accepted, pulled and retired. B lost X (only A holds it). The server is restored from before X and
    /// B recovers first: Y and Z wait for X, and the base B switches to lacks all three. Without `recover`, B has signed
    /// in again and its recovery has not run yet.
    static func heldChain(_ world: ExchangeWorld, queue: Bool, recover: Bool = true) async throws -> (a: DevicePhone, b: DevicePhone, onB: [Int64], wires: [String]) {
        let (a, ids) = try await Copies.subscribed(world)
        let b = try await world.device("B")
        let onB = try await ids.asyncMap { try await Recovery.same($0, from: a, on: b) }
        let wires = try await onB.asyncMap { try #require(try await b.store.wireEpisodeForTesting($0)) }
        let backup = try await world.backUp()
        try await b.store.setFavorite(episodeID: onB[0], favorite: true)
        await b.exchange()
        let lost = try await Quarantine.favoriteFact(b, onB[0])
        await a.exchange()
        try await b.store.setFavorite(episodeID: onB[1], favorite: true)
        if queue { _ = try await b.store.enqueue([onB[2]]) }
        await b.exchange()
        #expect(try b.rows("SELECT (SELECT count(*) FROM ntp_outbox) + (SELECT count(*) FROM ntp_overlays)") == [["0"]], "accepted, pulled, retired")
        try Quarantine.removeFromArchive(b, lost)
        try await world.restore(backup)
        #expect(await b.engine.exchange().pause == .signIn)
        try await b.signInAgain()
        guard recover else { return (a, b, onB, wires) }
        let report = await b.engine.exchange()
        #expect(report.error == nil && report.recovery == .waiting, "\(report.error ?? "") \(String(describing: report.recovery))")
        return (a, b, onB, wires)
    }

    /// The changes waiting for X keep what they showed through the base switch, a relaunch and later exchanges; once A
    /// restores X they join and B ends as the server.
    @Test func aWaitingPreviouslyAppliedChangeStaysVisible() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, wires) = try await Self.heldChain(world, queue: false)
            var view = try await b.view()
            #expect(view.episodes[wires[0]]?.favorite == true && view.episodes[wires[1]]?.favorite == true,
                    "the waiting changes stay shown: \(view)")
            try await b.relaunch()
            #expect(await b.engine.exchange().recovery == .waiting)
            view = try await b.view()
            #expect(view.episodes[wires[0]]?.favorite == true && view.episodes[wires[1]]?.favorite == true, "after a relaunch: \(view)")
            // A repair projects every row from the server's library: what is held stays.
            #expect(await b.engine.forceFullSynchronization().reprojected)
            view = try await b.view()
            #expect(view.episodes[wires[0]]?.favorite == true && view.episodes[wires[1]]?.favorite == true, "after a repair: \(view)")
            _ = try await Recovery.recover(a)
            await b.engine.exchange()
            await b.engine.exchange()
            let recovery = try #require(try await Recovery.recovery(b))
            #expect(recovery.finished && recovery.complete == true, "\(recovery)")
            #expect(try b.rows("SELECT count(*) FROM ntp_recovery_holds") == [["0"]], "nothing held once they joined")
            try await world.converge([a, b], "held")
            view = try await b.view()
            #expect(view.episodes[wires[0]]?.favorite == true && view.episodes[wires[1]]?.favorite == true)
        }
    }

    /// The person changes held entities afterwards (unfavorites e1, takes e2 out of the queue). The new
    /// facts depend on the base, not on the waiting ones (they are concurrent with them, later in time): they are sent
    /// at once, show at once, and the server's register rule (PROTOCOL §7: later clamped time) keeps them once Y and Z
    /// join. Phone, server and the other library end the same.
    @Test func aLaterChangeToAHeldEntityStandsWhenTheWaitingChangeJoins() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, onB, wires) = try await Self.heldChain(world, queue: true)
            var view = try await b.view()
            #expect(view.episodes[wires[1]]?.favorite == true && view.queue == [wires[2]], "held: \(view)")
            try await b.store.setFavorite(episodeID: onB[1], favorite: false)
            _ = try await b.store.removeFromQueue([onB[2]])
            #expect(await b.engine.exchange().recovery == .waiting)
            view = try await b.view()
            #expect(view.episodes[wires[1]]?.favorite == false && view.queue.isEmpty && view.episodes[wires[0]]?.favorite == true,
                    "the later changes show, the untouched waiting one stays: \(view)")
            #expect(try await b.store.serverUnsentChanges() == 0, "the later changes were sent")
            _ = try await Recovery.recover(a)
            await b.engine.exchange()
            await b.engine.exchange()
            let recovery = try #require(try await Recovery.recovery(b))
            #expect(recovery.finished && recovery.complete == true, "\(recovery)")
            try await world.converge([a, b], "later change")
            for phone in [a, b] {
                let shown = try await phone.view()
                #expect(shown.episodes[wires[1]]?.favorite == false && shown.queue.isEmpty && shown.episodes[wires[0]]?.favorite == true,
                        "\(phone.name): \(shown)")
            }
        }
    }


    /// The waiting chain (Y waits for X, W parked behind Y); A restores X; before B tries again the server is backed up
    /// and restored once more. B's new recovery uploads Y, which joins: W, parked by the first recovery, is released and
    /// sent, and only then is the recovery complete.
    @Test func aSecondRestoreReleasesAlreadyParkedFacts() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, onB, _) = try await Quarantine.waitingChain(world)
            #expect(try await b.store.parkedFacts().count == 1)
            _ = try await Recovery.recover(a)
            await a.close()
            let again = try await world.backUp()
            try await world.restore(again)
            _ = try await Recovery.recover(b)
            for _ in 0..<3 { await b.exchange() }
            let recovery = try #require(try await Recovery.recovery(b))
            #expect(recovery.finished && recovery.complete == true, "\(recovery)")
            #expect(try await b.store.serverUnsentChanges() == 0, "W was sent")
            #expect(try b.rows("SELECT count(*) FROM ntp_retained") == [["0"]], "nothing parked or retained is left")
            try await world.converge([b], "second restore")
            let shown = try await Quarantine.shows(b, onB)
            #expect(shown.queued == [shown.wires[0], shown.wires[1]] && shown.favorites == [shown.wires[3]], "\(shown)")
        }
    }


    /// A phone backup of B, waiting with W parked, restored onto another device: the copy takes its own installation
    /// and recovery, signs in, and once A restores X the copy's recovery opens, inventories, uploads Y, releases W and
    /// finishes complete.
    @Test func aCopiedWaitingRecoveryCanFinish() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, onB, _) = try await Quarantine.waitingChain(world)
            let copy = try await b.copy("B-copy", root: world.root)
            await b.close()
            #expect(await copy.engine.exchange().pause == .signIn)
            try await copy.signInAgain()
            let reset = try #require(try await Recovery.recovery(copy))
            #expect(!reset.caughtUp && !reset.finishSent && reset.epoch == nil, "the copy's recovery starts its phases again: \(reset)")
            _ = try await Recovery.recover(a)
            for _ in 0..<3 { await copy.exchange() }
            let recovery = try #require(try await Recovery.recovery(copy))
            #expect(recovery.epoch != nil && recovery.finished && recovery.complete == true, "\(recovery)")
            #expect(try await copy.store.serverUnsentChanges() == 0)
            try await world.converge([a, copy], "copied waiting")
            let shown = try await Quarantine.shows(copy, onB)
            #expect(shown.queued == [shown.wires[0], shown.wires[1]] && shown.favorites == [shown.wires[3]], "\(shown)")
        }
    }


    /// A favorite pushed but not pulled (its receipt only in `ntp_outbox`) whose receipt is damaged there: after the
    /// restore it is retained with that receipt, the server answers `invalid_receipt`, and it is quarantined. A crash
    /// right after the quarantine must not turn the outcome into complete success.
    @Test(arguments: [nil, "recovery.quarantined"])
    func quarantiningAnUnarchivedReceiptCannotBecomeCompleteAfterCrash(crash point: String?) async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Copies.subscribed(world)
            await a.exchange()
            let backup = try await world.backUp()
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            _ = await a.engine.run([.push])
            let row = try #require(try a.rows("SELECT install_seq, CAST(receipt AS TEXT) FROM ntp_outbox WHERE receipt IS NOT NULL").first)
            guard case .object(var receipt) = try ContractJSON.decode(Data(try #require(row[1]).utf8)) else { Issue.record("no receipt"); return }
            receipt["mac"] = .string(String(repeating: "0", count: (receipt["mac"]?.stringValue ?? "").count))
            let slot = try #require(row[0].flatMap { Int64($0) })
            try await a.store.executeForTesting("UPDATE ntp_outbox SET receipt = ? WHERE install_seq = ?",
                                                [.blob(try ContractJSON.object(receipt).canonicalData()), .integer(slot)])
            try await world.restore(backup)
            #expect(await a.engine.exchange().pause == .signIn)
            try await a.signInAgain()
            if let point {
                await a.engine.setCrashPoint(PushPull.crashOnce(at: point))
                let crashed = await a.engine.exchange()
                #expect(crashed.error == "InjectedCrash()", "\(crashed.error ?? "no crash")")
                try await a.relaunch()
            }
            await a.exchange()
            let recovery = try #require(try await Recovery.recovery(a))
            #expect(recovery.finished && recovery.complete == false && recovery.problems > 0 && recovery.quarantined > 0, "\(recovery)")
            #expect(try a.rows("SELECT count(*) FROM ntp_retained WHERE CAST(lineage AS TEXT) LIKE '%unrestored%'") == [["1"]])
            #expect(await a.engine.exchange().recovery == .incomplete, "the page says some changes could not be restored")
        }
    }


    /// B listened to e4 (history H) before the backup; then the waiting chain: B's queue add Y names A's X, which B lost,
    /// and B's favorite W is parked behind Y. Y was B's next fact after H, so only Y covered H in B's frontier. B clears
    /// its playback history: the cut must still observe H (the frontier is repaired from what Y named), so H stays
    /// cleared on B and on the server.
    @Test func parkingKeepsTheCausalPastForHistoryClear() async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Copies.subscribed(world)
            let b = try await world.device("B")
            let onB = try await ids.asyncMap { try await Recovery.same($0, from: a, on: b) }
            let wire = try #require(try await b.store.wireEpisodeForTesting(onB[4]))
            var listened = RemoteSession(store: b.store, episode: onB[4])
            try await listened.start(at: 0)
            try await listened.end(position: 30_000, contribution: 30_000, completed: false)
            await b.exchange()
            #expect(try await b.view().episodes[wire]?.history != nil, "H")
            let backup = try await world.backUp()
            _ = try await a.store.enqueue([ids[0]])
            await a.exchange()
            await b.exchange()
            let lost = try await Quarantine.provenance(b, onB[0], "queue_membership")
            _ = try await b.store.enqueue([onB[1]])
            _ = await b.engine.run([.push])
            try Quarantine.removeFromArchive(b, lost)
            await a.close()
            try await world.restore(backup)
            #expect(await b.engine.exchange().pause == .signIn)
            try await b.store.setFavorite(episodeID: onB[3], favorite: true)
            try await b.signInAgain()
            #expect(await b.engine.exchange().recovery == .waiting)
            #expect(try await b.store.parkedFacts().count == 1, "W is parked")
            _ = try await b.store.clearPlaybackHistory()
            #expect(try await b.view().episodes[wire]?.history == nil, "the clear shows at once")
            await b.engine.exchange()
            await b.engine.exchange()
            #expect(try await b.view().episodes[wire]?.history == nil, "and stays cleared once synchronized")
            let fresh = try await world.attach("fresh-clear")
            #expect(try await fresh.view().episodes[wire]?.history == nil, "the server's clear covered H")
            await fresh.close()
        }
    }
}

extension ServerRecoveryRegressionTests {
    // MARK: - Debt: parking after a materialization

    /// While B's recovery waits (Y for X), B subscribes to a podcast and favorites one of its episodes: a draft on the
    /// registration's chain, which here also names Y (as a draft that acted on what Y shows would). In one exchange the
    /// registration is pushed, accepted and pulled, and the draft materializes after the exchange's own park pass: it
    /// is parked before the push that follows, nothing pauses or starts another recovery, and a later change still
    /// goes out. Once A restores X it is released and sent.
    @Test func aDraftMaterializedWhileARecoveryWaitsIsParkedBeforeItIsPushed() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, onB, _) = try await Quarantine.waitingChain(world)
            let y = try #require(try b.rows("SELECT op_id FROM ntp_retained WHERE receipt IS NOT NULL AND CAST(lineage AS TEXT) NOT LIKE '%parked%'").first?.first ?? nil)
            let two = try await b.store.insert(Agreement.fetched(world.url("two.xml"), title: "Two", prefix: "two", count: 3))
            try await b.store.setFavorite(episodeID: try #require(two.episodes.map(\.id).min()), favorite: true)
            let draft = try #require(try b.rows("SELECT op_id FROM ntp_drafts WHERE kind = 'favorite.set'").first?.first ?? nil)
            try await b.store.executeForTesting("UPDATE ntp_drafts SET dependencies = ? WHERE op_id = ?",
                                                [.text(ContractJSON.array([.string(y)]).canonicalText), .text(draft)])
            let report = await b.engine.exchange()
            #expect(report.error == nil && report.pause == nil, "\(report.error ?? "") \(String(describing: report.pause))")
            #expect(report.recovery == .waiting)
            #expect(try b.rows("SELECT count(*) FROM ntp_drafts") == [["0"]], "the registration resolved and its draft materialized")
            #expect(try await b.store.parkedFacts().map(\.opID).contains(draft), "the materialized draft is parked")
            #expect(try await Recovery.recovery(b)?.cause == .lineageMismatch, "no other recovery started")
            // A later change still goes out.
            try await b.store.setFavorite(episodeID: onB[2], favorite: true)
            #expect(await b.engine.exchange().recovery == .waiting)
            #expect(try b.rows("SELECT count(*) FROM ntp_outbox WHERE receipt IS NULL") == [["0"]], "the later change was sent")
            _ = try await Recovery.recover(a)
            for _ in 0..<3 { await b.exchange() }
            let recovery = try #require(try await Recovery.recovery(b))
            #expect(recovery.finished && recovery.complete == true, "\(recovery)")
            try await world.converge([a, b], "materialized")
        }
    }
}

/// Interruptions and local actions between the bounded
/// steps, and what a refusal leaves once its holds end.
extension ServerRecoveryRegressionTests {
    /// A crash hook that throws at the `occurrence`th time `point` is reached.
    static func crash(at point: String, occurrence: Int) -> @Sendable (String) throws -> Void {
        let count = Counter()
        return { name in
            guard name == point, count.next() == occurrence else { return }
            throw PushPull.InjectedCrash()
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
    }

    static func favorite(_ phone: DevicePhone, _ local: Int64) async throws -> Bool? {
        try await phone.view().episodes[try #require(try await phone.store.wireEpisodeForTesting(local))]?.favorite
    }

    // MARK: - New 1

    /// A's favorite R, accepted and archived after the backup, then 101 unsent favorite changes chained behind it; R's
    /// receipt is damaged. After the restore the server refuses R, and its 101 dependents are quarantined, 100 to a
    /// step. Interrupted after any step (a crash, the person's change recorded before the relaunch) or with a change
    /// recorded at the boundary, the quarantine resumes and completes: all 101 are kept on the device only, the person's
    /// later change reaches the server, nothing else starts another recovery, and the phone ends as the server.
    @Test(arguments: [("frontier", 1, true), ("batch", 1, true), ("batch", 2, true), ("marked", 1, true),
                      ("frontier", 1, false), ("batch", 1, false), ("marked", 1, false)])
    func quarantineResumesAfterItsFirstHundredEntries(boundary: String, occurrence: Int, crash: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Copies.subscribed(world)
            await a.exchange()
            let backup = try await world.backUp()
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            await a.exchange()
            let refused = try await Quarantine.lastFact(a)
            try Quarantine.tamperReceipt(a, refused)
            for index in 0..<101 { try await a.store.setFavorite(episodeID: ids[1], favorite: index % 2 == 0) }
            try await world.restore(backup)
            #expect(await a.engine.exchange().pause == .signIn)
            try await a.signInAgain()
            let point = "quarantine.\(boundary)"
            if crash {
                await a.engine.setCrashPoint(Self.crash(at: "blocking.\(point)", occurrence: occurrence))
                let crashed = await a.engine.exchange()
                #expect(crashed.error == "InjectedCrash()", "\(point): \(crashed.error ?? "no crash")")
                try await a.store.setFavorite(episodeID: ids[3], favorite: true)
                try await a.relaunch()
            } else {
                let count = Counter(), store = a.store, suffix = ids[3]
                await a.engine.setBlockingBoundary { name in
                    if name == point, count.next() == occurrence { try await store.setFavorite(episodeID: suffix, favorite: true) }
                }
                await a.exchange()
                await a.engine.setBlockingBoundary(nil)
            }
            let recoveryID = try #require(try await Recovery.recovery(a)).recoveryID
            for _ in 0..<3 { await a.exchange() }
            let recovery = try #require(try await Recovery.recovery(a))
            #expect(recovery.recoveryID == recoveryID && recovery.cause == .lineageMismatch, "no other recovery: \(recovery)")
            #expect(recovery.finished && recovery.complete == false && recovery.quarantined >= 101, "\(recovery)")
            #expect(try a.rows("SELECT count(*) FROM ntp_retained WHERE CAST(lineage AS TEXT) LIKE '%unrestored%'") == [["101"]], "all 101 kept on this device")
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox WHERE receipt IS NULL") == [["0"]], "nothing holds a slot")
            #expect(try await Self.favorite(a, ids[1]) == false, "the refused chain shows as the server has it")
            #expect(try await Self.favorite(a, ids[3]) == true, "the change made meanwhile")
            try await world.converge([a], "\(point) \(crash)")
        }
    }

    // MARK: - New 2

    /// The waiting chain with B's listening H before the backup, as `parkingKeepsTheCausalPastForHistoryClear`; the
    /// person clears playback history at a boundary between the parking's steps. Every committed step keeps the known
    /// past covered, so the cut observes H: cleared on B and on the server.
    @Test(arguments: ["park.frontier", "park.batch", "park.marked"])
    func aCutBetweenFrontierStepsStillCoversKnownHistory(boundary: String) async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Copies.subscribed(world)
            let b = try await world.device("B")
            let onB = try await ids.asyncMap { try await Recovery.same($0, from: a, on: b) }
            let wire = try #require(try await b.store.wireEpisodeForTesting(onB[4]))
            var listened = RemoteSession(store: b.store, episode: onB[4])
            try await listened.start(at: 0)
            try await listened.end(position: 30_000, contribution: 30_000, completed: false)
            await b.exchange()
            let backup = try await world.backUp()
            _ = try await a.store.enqueue([ids[0]])
            await a.exchange()
            await b.exchange()
            let lost = try await Quarantine.provenance(b, onB[0], "queue_membership")
            _ = try await b.store.enqueue([onB[1]])
            _ = await b.engine.run([.push])
            try Quarantine.removeFromArchive(b, lost)
            await a.close()
            try await world.restore(backup)
            #expect(await b.engine.exchange().pause == .signIn)
            try await b.store.setFavorite(episodeID: onB[3], favorite: true)
            try await b.signInAgain()
            let fired = PlayingFlag(), store = b.store
            await b.engine.setBlockingBoundary { name in
                guard name == boundary, !fired.value else { return }
                fired.value = true
                _ = try await store.clearPlaybackHistory()
            }
            #expect(await b.engine.exchange().recovery == .waiting)
            await b.engine.setBlockingBoundary(nil)
            #expect(fired.value, "the history was cleared at \(boundary)")
            await b.engine.exchange()
            await b.engine.exchange()
            #expect(try await b.view().episodes[wire]?.history == nil, "cleared on B")
            let fresh = try await world.attach("fresh-cut")
            #expect(try await fresh.view().episodes[wire]?.history == nil, "the server's clear covered H")
            await fresh.close()
        }
    }

    // MARK: - New 3

    /// `heldChain(queue: true)`: Z (queue add of e2), accepted and retired, waits behind Y and the missing X and is held.
    /// Z's own receipt is damaged: the server refuses it for good. Then A restores X and Y joins: nothing waits, and Z's
    /// membership must leave B's queue as it never reached the server.
    @Test func aRefusedHeldQueueFactMustLeaveWhenTheOtherFactsJoin() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, wires) = try await Self.heldChain(world, queue: true)
            #expect(try await b.view().queue == [wires[2]], "Z held")
            let z = try #require(try b.rows("SELECT value FROM json_each((SELECT provenance FROM ntp_recovery_holds WHERE entity = 'episode' AND field_group = 'queue_membership' AND id = '\(wires[2])'))").first?.first ?? nil)
            try Quarantine.tamperReceipt(b, z)
            await b.engine.exchange()
            _ = try await Recovery.recover(a)
            for _ in 0..<3 { await b.engine.exchange() }
            let recovery = try #require(try await Recovery.recovery(b))
            #expect(recovery.finished && recovery.complete == false, "\(recovery)")
            #expect(try b.rows("SELECT count(*) FROM ntp_recovery_holds") == [["0"]])
            let view = try await b.view()
            #expect(view.queue.isEmpty, "the refused queue add left: \(view.queue)")
            #expect(view.episodes[wires[0]]?.favorite == true && view.episodes[wires[1]]?.favorite == true, "X and Y joined")
            try await world.converge([a, b], "refused held queue fact")
        }
    }

    /// The waiting chain; Y's retained receipt is damaged, so the server refuses Y for good and B quarantines Y and W.
    /// Nothing of B's waits for X any more, so X's hold ends as well: B ends exactly as the server, its queue empty,
    /// with ordinary exchanges (and a repair changes nothing).
    @Test func aHeldXIsReleasedWhenTheWaitingReceiptIsRefused() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, onB, _) = try await Quarantine.waitingChain(world)
            await a.close()
            let y = try #require(try b.rows("SELECT op_id FROM ntp_retained WHERE receipt IS NOT NULL AND CAST(lineage AS TEXT) NOT LIKE '%parked%'").first?.first ?? nil)
            let receipt = try #require(try b.rows("SELECT CAST(receipt AS TEXT) FROM ntp_retained WHERE op_id = '\(y)'").first?.first ?? nil)
            guard case .object(var damaged) = try ContractJSON.decode(Data(receipt.utf8)) else { Issue.record("no receipt"); return }
            damaged["mac"] = .string(String(repeating: "0", count: (damaged["mac"]?.stringValue ?? "").count))
            try await b.store.executeForTesting("UPDATE ntp_retained SET receipt = ? WHERE op_id = ?", [.blob(try ContractJSON.object(damaged).canonicalData()), .text(y)])
            for _ in 0..<3 { await b.engine.exchange() }
            let recovery = try #require(try await Recovery.recovery(b))
            #expect(recovery.finished && recovery.complete == false, "\(recovery)")
            #expect(try b.rows("SELECT (SELECT count(*) FROM ntp_recovery_holds) + (SELECT count(*) FROM ntp_overlays)") == [["0"]])
            let fresh = try await world.attach("fresh-refused")
            let server = try await fresh.view()
            await fresh.close()
            var shown = try await Quarantine.shows(b, onB)
            #expect(shown.queued == server.queue && server.queue.isEmpty, "B's queue is the server's: \(shown.queued)")
            #expect(shown.favorites.isEmpty, "W was refused with Y: \(shown.favorites)")
            #expect(await b.engine.forceFullSynchronization().reprojected)
            shown = try await Quarantine.shows(b, onB)
            #expect(shown.queued.isEmpty && shown.favorites.isEmpty)
        }
    }

    // MARK: - New 4

    /// After the backup B favorites e0 (X) and subscribes to Two (chained after X), whose catalog the server fetches. B
    /// loses X and recovers first: Two's creation and catalog wait and are held, still shown. Then the subscription's
    /// receipt is damaged and the server refuses it for good: Two must go from B (feed and episodes, never left as a
    /// local preview), also after a repair, as the server never had it.
    @Test func aRefusedHeldPodcastIsRemovedAfterHoldRelease() async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Copies.subscribed(world)
            let b = try await world.device("B")
            let onB = try await ids.asyncMap { try await Recovery.same($0, from: a, on: b) }
            let backup = try await world.backUp()
            try await b.store.setFavorite(episodeID: onB[0], favorite: true)
            await b.exchange()
            let lost = try await Quarantine.favoriteFact(b, onB[0])
            await a.exchange()
            let two = try await b.store.insert(Agreement.fetched(world.url("two.xml"), title: "Two", prefix: "two", count: 3))
            try await Copies.waitForCatalog(b, feedID: two.id)
            await b.exchange()
            let registration = try #require(try b.rows("SELECT op_id FROM ntp_registrations WHERE feed_id = \(two.id)").first?.first ?? nil)
            try Quarantine.removeFromArchive(b, lost)
            await a.close()
            try await world.restore(backup)
            #expect(await b.engine.exchange().pause == .signIn)
            try await b.signInAgain()
            #expect(await b.engine.exchange().recovery == .waiting)
            #expect(try await b.store.feed(id: two.id)?.subscriptionState == .subscribed, "Two waits and stays shown")
            try Quarantine.tamperReceipt(b, registration)
            for _ in 0..<3 { await b.engine.exchange() }
            let recovery = try #require(try await Recovery.recovery(b))
            #expect(recovery.finished && recovery.complete == false, "\(recovery)")
            #expect(try b.rows("SELECT count(*) FROM ntp_recovery_holds") == [["0"]])
            #expect(try await b.store.feed(id: two.id) == nil, "Two is gone, not kept as a preview")
            #expect(try b.rows("SELECT count(*) FROM episodes WHERE feed_id = \(two.id)") == [["0"]])
            #expect(try b.rows("SELECT (SELECT count(*) FROM ntp_local_items WHERE feed_id = \(two.id)) + (SELECT count(*) FROM ntp_observation_work WHERE feed_id = \(two.id))") == [["0"]],
                    "no local item or observation work of it is left")
            let fresh = try await world.attach("fresh-two")
            let server = try await fresh.view()
            await fresh.close()
            #expect(!server.podcasts.values.contains { $0.title == "Two" })
            #expect(try await b.view().withoutTitles.differences(from: server.withoutTitles).isEmpty)
            #expect(await b.engine.forceFullSynchronization().reprojected)
            #expect(try await b.store.feed(id: two.id) == nil)
        }
    }
}

/// Recovery with pending changes.
extension ServerRecoveryRegressionTests {
    // MARK: - R3-1

    /// H listened before the backup; then A's favorite R (its receipt damaged) and an unsent change chained after it.
    /// While the quarantine prepares, the person records a change after every plan (each makes the plan stale), then
    /// clears playback history right after the frontier step. The clear must not depend on anything refused: it
    /// reaches the server, which forgets H.
    @Test func fourthStalePlanDoesNotQuarantineTheNextHistoryClear() async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Copies.subscribed(world)
            let wire = try #require(try await a.store.wireEpisodeForTesting(ids[4]))
            var listened = RemoteSession(store: a.store, episode: ids[4])
            try await listened.start(at: 0)
            try await listened.end(position: 30_000, contribution: 30_000, completed: false)
            await a.exchange()
            let backup = try await world.backUp()
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            await a.exchange()
            try Quarantine.tamperReceipt(a, try await Quarantine.lastFact(a))
            try await a.store.setFavorite(episodeID: ids[1], favorite: true)
            try await world.restore(backup)
            #expect(await a.engine.exchange().pause == .signIn)
            try await a.signInAgain()
            let plans = Counter(), cleared = PlayingFlag(), store = a.store, other = ids[2]
            await a.engine.setBlockingBoundary { name in
                if name == "quarantine.planned" {
                    let count = plans.next()
                    if count <= 4 { try await store.setFavorite(episodeID: other, favorite: count % 2 == 1) }
                }
                if name == "quarantine.frontier", !cleared.value {
                    cleared.value = true
                    _ = try await store.clearPlaybackHistory()
                }
            }
            let report = await a.engine.exchange()
            #expect(report.error == nil, "\(report.error ?? "")")
            await a.engine.setBlockingBoundary(nil)
            #expect(cleared.value)
            for _ in 0..<3 { await a.exchange() }
            #expect(try a.rows("SELECT count(*) FROM ntp_retained WHERE CAST(lineage AS TEXT) LIKE '%unrestored%' AND CAST(fact AS TEXT) LIKE '%history.clear%'") == [["0"]],
                    "the clear is not kept back")
            #expect(try await a.view().episodes[wire]?.history == nil, "H stays cleared")
            let fresh = try await world.attach("fresh-stale")
            #expect(try await fresh.view().episodes[wire]?.history == nil, "the server's clear covered H")
            await fresh.close()
        }
    }

    // MARK: - R3-2

    /// B favorites e0 (X), registers the preview Two by favoriting one of its episodes (chained after X), the server
    /// fetches its catalog, and B downloads an episode of it. B lost X; after the restore Two waits and is held. Its
    /// creation's receipt is damaged, so the server refuses it; as the quarantine prepares, the person subscribes to
    /// the preview. That subscription wins: the same feed and episode, still downloaded, never deleted.
    @Test func realRefusalMustKeepASubscriptionMadeDuringHoldRelease() async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Copies.subscribed(world)
            let b = try await world.device("B")
            let onB = try await ids.asyncMap { try await Recovery.same($0, from: a, on: b) }
            let backup = try await world.backUp()
            try await b.store.setFavorite(episodeID: onB[0], favorite: true)
            await b.exchange()
            let lost = try await Quarantine.favoriteFact(b, onB[0])
            await a.exchange()
            let preview = try await b.store.preparePreview(Agreement.fetched(world.url("two.xml"), title: "Two", prefix: "two", count: 3))
            let item = try #require(preview.episodes.map(\.id).min())
            try await b.store.setFavorite(episodeID: item, favorite: true)
            try await Copies.waitForCatalog(b, feedID: preview.id)
            let downloaded = try await Self.download(b, item)
            await b.exchange()
            let registration = try #require(try b.rows("SELECT op_id FROM ntp_registrations WHERE feed_id = \(preview.id)").first?.first ?? nil)
            try Quarantine.removeFromArchive(b, lost)
            await a.close()
            try await world.restore(backup)
            #expect(await b.engine.exchange().pause == .signIn)
            try await b.signInAgain()
            #expect(await b.engine.exchange().recovery == .waiting)
            #expect(try await b.store.feed(id: preview.id) != nil, "the preview waits and stays")
            try Quarantine.tamperReceipt(b, registration)
            let subscribed = PlayingFlag(), store = b.store, feed = preview.id
            await b.engine.setBlockingBoundary { name in
                guard name == "quarantine.frontier", !subscribed.value else { return }
                subscribed.value = true
                _ = try await store.subscribePreview(feedID: feed)
            }
            var deleted = (await b.engine.exchange()).deletedFeeds
            await b.engine.setBlockingBoundary(nil)
            #expect(subscribed.value)
            for _ in 0..<3 { deleted += (await b.engine.exchange()).deletedFeeds }
            #expect(deleted.isEmpty, "no feed deleted: \(deleted)")
            #expect(try await b.store.feed(id: preview.id)?.subscriptionState == .subscribed, "the same feed, subscribed")
            let episode = try await b.store.episode(id: item)
            #expect(episode?.userState.isDownloaded == true && episode?.userState.localFileURL == downloaded.userState.localFileURL,
                    "the same episode, still downloaded: \(String(describing: episode?.userState))")
            #expect(try await Self.feedDeletions(b) == 0)
            let fresh = try await world.attach("fresh-subscribed")
            let server = try await fresh.view()
            await fresh.close()
            #expect(server.podcasts.values.contains { $0.title == "Two" && $0.subscription == .subscribed }, "the server took the subscription")
        }
    }
}

/// Releasing recovery holds on the library's own data: what the server does not have
/// goes once its last hold ends, whichever unit that is; newer local work on it keeps it.
@Suite(.serialized) struct ServerHoldReleaseTests {
    static let groups = ["identity", "metadata", "play_state", "position", "favorite", "last_played", "played_time"]

    /// The first `count` episodes of a registered podcast with base records in `groups`, each set by `node(group)`, held
    /// and then gone from the base (a recovery switched to a base without them).
    static func held(_ fixture: ServerLibraryFixture, _ registered: (feed: LibraryFeed, podcast: String, generation: String), count: Int,
                     node: (String) -> String) async throws -> [Int64] {
        let store = fixture.store
        // The subscription was accepted and pulled long ago: its facts retired.
        try await store.executeForTesting("DELETE FROM ntp_overlays")
        let locals = Array(registered.feed.episodes.map(\.id).sorted().prefix(count))
        for local in locals {
            let wire = "e1:held-\(local)"
            try await store.executeForTesting("INSERT OR REPLACE INTO ntp_episodes(episode_id, local_id, podcast_id, kind, value) VALUES (?, ?, ?, 'guid', ?)",
                                              [.text(wire), .integer(local), .text(registered.podcast), .text(wire)])
            for group in groups {
                let value: ContractJSON = group == "identity" ? ["podcast_id": .string(registered.podcast)] : [:]
                try await store.executeForTesting("INSERT OR REPLACE INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('episode', ?, ?, ?, ?)",
                                                  [.text(wire), .text(group), .blob(try value.canonicalData()),
                                                   .text(ContractJSON.array([.string(node(group))]).canonicalText)])
            }
        }
        let records = try FeedLibraryStore.serverRecords(naming: Set(groups.map(node)), database: fixture.url)
        #expect(records.count == count * groups.count)
        try await store.holdServerRecords(records)
        try await store.executeForTesting("DELETE FROM ntp_records WHERE entity = 'episode' AND id LIKE 'e1:held-%'")
        return locals
    }

    /// Releases what no longer waits, as the engine does, `limit` holds to a unit (10, the default).
    static func release(_ store: FeedLibraryStore, waiting: Set<String> = [], limit: Int = 10) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        while try await store.releaseServerHolds(stillWaiting: waiting, history: nil, now: now, limit: limit) != nil {}
    }

    /// Two episodes with seven held field groups each, released ten to a unit (the default): both go, whichever unit
    /// releases their identity.
    @Test func defaultTenRecordBatchesRemoveEveryRefusedEpisode() async throws {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let registered = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched(count: 4))
        let y = ContractIdentity.randomUUID()
        let locals = try await Self.held(fixture, registered, count: 2) { _ in y }
        try await Self.release(fixture.store)
        #expect(try fixture.rows("SELECT count(*) FROM ntp_recovery_holds") == [["0"]])
        for local in locals { #expect(try await fixture.store.episode(id: local) == nil, "episode \(local) is gone") }
        #expect(try fixture.rows("SELECT count(*) FROM episodes WHERE feed_id = \(registered.feed.id)") == [["2"]], "the others stay")
    }

    /// The identity hold ends before the episode's other holds (one hold to a unit, or the identity's node joined or
    /// was refused while another field still waits): the episode stays while anything holds it, and goes with the last
    /// hold; the evidence lasts until then (a repair or the next exchange removes it too).
    @Test(arguments: ["one to a unit", "identity first"]) func episodeAbsenceSurvivesSplitHoldRelease(variant: String) async throws {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let store = fixture.store
        let registered = try await fixture.subscribeRegistered(ServerLibraryFixture.fetched(count: 3))
        let identity = ContractIdentity.randomUUID(), other = ContractIdentity.randomUUID()
        let locals = try await Self.held(fixture, registered, count: 1) { $0 == "identity" ? identity : other }
        if variant == "one to a unit" {
            try await Self.release(store, limit: 1)
        } else {
            try await Self.release(store, waiting: [other])
            #expect(try await store.episode(id: locals[0]) != nil, "kept while its other fields are held")
            #expect(try fixture.rows("SELECT count(*) FROM ntp_recovery_holds") == [["6"]])
            #expect(try await store.releaseServerPins() == false, "nothing else removes it while it is held")
            #expect(try await store.episode(id: locals[0]) != nil)
            try await Self.release(store)
        }
        #expect(try fixture.rows("SELECT count(*) FROM ntp_recovery_holds") == [["0"]])
        _ = try await store.releaseServerPins()
        #expect(try await store.episode(id: locals[0]) == nil, "gone with its last hold")
        #expect(try fixture.rows("SELECT count(*) FROM ntp_deferred_absence") == [["0"]])
    }

    /// A registered preview whose creation is refused for good (its records gone from the base, its holds ending)
    /// while the person subscribes to it: the subscription is newer work on the same feed, so nothing goes while it is
    /// pending; once the server takes it (a new podcast on the same feed), the old holds end and the same feed and
    /// episode stay, still downloaded.
    @Test func subscribingHeldPreviewSurvivesItsOldCreationRefusal() async throws {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let store = fixture.store
        let preview = try await store.preparePreview(ServerLibraryFixture.fetched("https://example.test/preview.xml", title: "Preview", count: 3))
        let item = try #require(preview.episodes.map(\.id).min())
        try await store.setFavorite(episodeID: item, favorite: true)
        let op = try fixture.registrationOp(feedID: preview.id), ids = try fixture.created(op)
        try await store.resolveRegistration(opID: op, .init(podcastID: ids.podcast, generationID: ids.generation, mode: "created", decisionID: nil))
        // Accepted and pulled long ago: its facts retired.
        try await store.executeForTesting("DELETE FROM ntp_overlays")
        let job = try #require(try await store.requestDownload(episodeID: item, directory: fixture.directory, enqueue: false))
        let started = try #require(try await store.beginDownloadAttempt(id: job.id))
        try Data(count: 64).write(to: job.destination)
        #expect(try await store.attachDownloadFile(id: job.id, attempt: started.attempts))
        #expect(try await store.completeDownload(id: job.id, attempt: started.attempts))
        let file = try #require(try await store.episode(id: item)?.userState.localFileURL)
        // Its records, set by its creation, held through a switch to a base without them.
        let y = ContractIdentity.randomUUID(), provenance = ContractJSON.array([.string(y)]).canonicalText
        for (group, value) in [("identity", ContractJSON.object([:])), ("subscription", ["state": "not_subscribed", "generation_id": .string(ids.generation)])] {
            try await store.executeForTesting("INSERT OR REPLACE INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('podcast', ?, ?, ?, ?)",
                                              [.text(ids.podcast), .text(group), .blob(try value.canonicalData()), .text(provenance)])
        }
        for local in preview.episodes.map(\.id) {
            let wire = "e1:preview-\(local)"
            try await store.executeForTesting("INSERT OR REPLACE INTO ntp_episodes(episode_id, local_id, podcast_id, kind, value) VALUES (?, ?, ?, 'guid', ?)",
                                              [.text(wire), .integer(local), .text(ids.podcast), .text(wire)])
            try await store.executeForTesting("INSERT OR REPLACE INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('episode', ?, 'identity', ?, ?)",
                                              [.text(wire), .blob(try ContractJSON.object(["podcast_id": .string(ids.podcast)]).canonicalData()), .text(provenance)])
        }
        try await store.holdServerRecords(try FeedLibraryStore.serverRecords(naming: [y], database: fixture.url))
        try await store.executeForTesting("DELETE FROM ntp_records WHERE provenance = ?", [.text(provenance)])
        // The person subscribes; the old creation is refused (nothing it held waits any more).
        #expect(try await store.subscribePreview(feedID: preview.id))
        try await ServerHoldReleaseTests.release(store)
        #expect(try await store.feed(id: preview.id)?.subscriptionState == .subscribed, "kept while the subscription is pending")
        #expect(try await store.episode(id: item)?.userState.localFileURL == file)
        // The server takes the subscription: a new podcast on the same feed.
        let subscribe = try fixture.registrationOp(feedID: preview.id), created = try fixture.created(subscribe)
        try await store.resolveRegistration(opID: subscribe, .init(podcastID: created.podcast, generationID: created.generation, mode: "created", decisionID: nil))
        // Its commit retires the subscription fact (its overlays go).
        try await store.executeForTesting("DELETE FROM ntp_overlays WHERE op_id = ?", [.text(subscribe)])
        try await ServerHoldReleaseTests.release(store)
        _ = try await store.releaseServerPins()
        #expect(try fixture.rows("SELECT count(*) FROM ntp_recovery_holds") == [["0"]])
        #expect(try await store.feed(id: preview.id) != nil, "the same feed")
        let episode = try await store.episode(id: item)
        #expect(episode?.userState.isDownloaded == true && episode?.userState.localFileURL == file, "the same episode, still downloaded")
        #expect(try await store.pendingEffects().filter { if case .deleteFeed = $0.effect.kind { true } else { false } }.isEmpty)
    }
}

/// The frontier through parking, joining and release, on the library's own data: a cut
/// depends on the frontier, so whatever was known stays covered by it, and nothing that may be missing on the server
/// is in it.
@Suite(.serialized) struct ServerFrontierRepairTests {
    @Test func parkingJoiningAndReleaseKeepEveryKnownNodeCovered() async throws {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let store = fixture.store
        // X: another device's node, known here; f2 names it, f1 → f2 → f3 is this library's chain.
        let x = ContractIdentity.randomUUID()
        try await store.executeForTesting("INSERT INTO ntp_nodes(node_id, knowledge_clock, frontier, kind) VALUES (?, 1, 1, 'pulled')", [.text(x)])
        let f1 = try await store.appendFactForTesting(type: "favorite.set", targets: [], payload: [:])
        let f2 = try await store.appendFactForTesting(type: "favorite.set", targets: [], payload: [:], dependencies: [x])
        let f3 = try await store.appendFactForTesting(type: "favorite.set", targets: [], payload: [:])
        func frontier() throws -> Set<String> {
            Set(try fixture.rows("SELECT node_id FROM ntp_nodes WHERE frontier = 1 AND kind != 'draft'").compactMap { $0[0] })
        }
        #expect(try frontier() == [f3])
        // X waits for another device: f2 and f3 are parked; f1, which only f2 covered, is in the frontier again.
        #expect(Set(try await store.parkWaitingFacts(behind: [x])) == [f2, f3])
        #expect(try frontier() == [f1], "the known past stays covered, nothing blocked is named")
        // X joins: it is in the frontier again, so a cut observes it.
        #expect(try await store.rejoinServerFrontier(try await store.blockedOutServerNodes(), stillWaiting: [], archived: [:]) == 1)
        #expect(try frontier() == [f1, x])
        // The parked facts go back to the outbox and cover what they name again.
        #expect(try await store.unparkFacts(stillWaiting: []) == [f2, f3])
        #expect(try frontier() == [f3])
    }
}
