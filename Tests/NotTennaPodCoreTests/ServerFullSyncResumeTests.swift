import Foundation
import Testing
@testable import NotTennaPodCore

/// Force full synchronization's download against the real server (PROTOCOL §6.14, §6.4): interrupted, it continues
/// from its next page (nothing received is asked again) after a relaunch too; once its first page named the view's head
/// H, other devices' commits wait behind H until the repair is published; playback starting after the download keeps
/// it for the pause, which publishes it without the network; too little free space stops it before anything is asked;
/// and a background app refresh never downloads.
@Suite(.serialized) struct ServerFullSyncResumeTests {
    typealias Full = ServerExchangeFullSyncTests
    typealias Concurrency = ServerExchangeConcurrencyTests
    typealias Agreement = ServerExchangeAgreementTests

    /// The snapshot requests sent since `from`, and the bytes their answers carried.
    final class SnapshotLog: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [ContractJSON?] = []
        private var answered: Int64 = 0
        /// Fails the snapshot request with this number (1-based, counted from the start) once.
        var failAt: Int?
        /// Runs after a snapshot answer was received (the last page's, `has_more: false`).
        var afterLastPage: (@Sendable () -> Void)?

        func handler() -> ProxyTransport.Handler {
            { [self] method, path, body, server in
                guard path == "v1/snapshot" else { return try await server.send(method, path, body: body) }
                let number = lock.withLock { bodies.append(body); return bodies.count }
                if number == failAt { failAt = nil; throw ServerExchangeError.unreachable }
                let answer = try await server.send(method, path, body: body)
                let size = Int64(try answer.canonicalData().count)
                lock.withLock { answered += size }
                if answer["has_more"]?.boolValue == false { afterLastPage?() }
                return answer
            }
        }

        var requests: [ContractJSON?] { lock.withLock { bodies } }
        var bytes: Int64 { lock.withLock { answered } }
        func reset() { lock.withLock { bodies = []; answered = 0 } }
    }

    static func spool(_ phone: ExchangePhone) -> URL { phone.location.staging!.appendingPathComponent("full", isDirectory: true) }

    /// The network fails at the fourth page; C favorites an episode meanwhile. An ordinary exchange pushes and pulls
    /// but applies nothing past H; after a relaunch the repair continues with page tokens only (no new first page, the
    /// pages received are not asked again), publishes, then applies C's commit.
    @Test func anInterruptedRepairContinuesFromItsNextPageAndHoldsLaterCommits() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, one, two) = try await Full.world(world)
            try await Full.corrupt(a, one: one, two: two)
            await a.engine.setSnapshotTesting(pageLimit: 4)
            let log = SnapshotLog()
            log.failAt = 4
            a.transport.handler = log.handler()
            let interrupted = await a.engine.forceFullSynchronization()
            #expect(interrupted.unreachable && !interrupted.reprojected)
            let manifest = try #require(ServerSnapshotSpool.manifest(in: Self.spool(a)))
            #expect(manifest.pages.count == 3 && !manifest.complete)
            let received = log.bytes
            let firstRun = log.requests
            let head = try SyncCursor(encoded: try #require(manifest.targetHead))

            // Another device's change after the view's head: pulled and archived here, held behind H.
            let favorite = try await Concurrency.same(one[4], from: a, on: c)
            try await c.store.setFavorite(episodeID: favorite, favorite: true)
            await c.exchange()
            log.reset()
            let ordinary = await a.engine.exchange()
            #expect(ordinary.fullSynchronizationHolds && ordinary.pulledCommits >= 1, "\(ordinary)")
            #expect(try await a.store.serverExchangeState().cursor?.seq == head.seq, "nothing applied past the repair's head")
            #expect(try await a.store.episode(id: one[4])?.userState.isFavorite != true)
            #expect(log.requests.isEmpty, "an ordinary exchange never downloads")
            // A second change meanwhile: later pulls wait for the publication (what is archived applies first); nothing
            // is lost, both arrive once the repair is published.
            try await c.store.setFavorite(episodeID: try await Concurrency.same(one[0], from: a, on: c), favorite: true)
            await c.exchange()
            let second = await a.engine.exchange()
            #expect(second.fullSynchronizationHolds && second.error == nil)
            #expect(try await a.store.serverExchangeState().cursor?.seq == head.seq)

            try await a.relaunch()
            log.reset()
            let report = await a.engine.forceFullSynchronization()
            #expect(report.reprojected && report.error == nil, "\(String(describing: report.error))")
            #expect(!log.requests.isEmpty && log.requests.allSatisfy { $0?["page"] != nil }, "continued with page tokens: no new first page")
            let tokens = Set(firstRun.compactMap { $0?["page"]?.stringValue })
            #expect(log.requests.first??["page"]?.stringValue == firstRun.last??["page"]?.stringValue, "from the page that failed")
            #expect(log.requests.dropFirst().allSatisfy { !tokens.contains($0?["page"]?.stringValue ?? "") }, "no received page asked again")
            let total = received + log.bytes
            print("full sync measurement: received before the interruption \(received) bytes, after it \(log.bytes), of \(total)")
            #expect(!FileManager.default.fileExists(atPath: Self.spool(a).path), "deleted once published")
            #expect(try await a.store.episode(id: one[4])?.userState.isFavorite == true, "C's commit applied after the repair")
            #expect(try await a.store.episode(id: one[0])?.userState.isFavorite == true, "and C's second one")
            try await Full.expectRepaired(world, a, "resumed")
        }
    }

    /// Playback starts once the whole library was downloaded: the repair waits for the pause with its download kept.
    /// Exchanges while playing download nothing; after a relaunch and the pause it is published without the network.
    @Test func playbackStartingAfterTheDownloadKeepsItForThePause() async throws {
        try await ExchangeWorld.run { world in
            let (a, _, one, two) = try await Full.world(world)
            try await Full.corrupt(a, one: one, two: two)
            await a.engine.setSnapshotTesting(pageLimit: 8, stagingWhilePlaying: 0)
            let log = SnapshotLog()
            let playing = a.playing
            log.afterLastPage = { playing.value = true }
            a.transport.handler = log.handler()
            let waiting = await a.engine.forceFullSynchronization()
            #expect(waiting.waitingForPause && !waiting.reprojected)
            #expect(ServerSnapshotSpool.manifest(in: Self.spool(a))?.complete == true, "the download is kept")
            log.reset()
            _ = await a.engine.exchange()
            _ = await a.engine.forceFullSynchronization()
            #expect(log.requests.isEmpty, "nothing downloaded again while playing")
            try await a.relaunch()
            await a.engine.setSnapshotTesting(stagingWhilePlaying: 0)
            a.playing.value = false
            let report = await a.engine.forceFullSynchronization()
            #expect(report.reprojected && report.error == nil, "\(String(describing: report.error))")
            #expect(log.requests.isEmpty, "published from the kept download: no snapshot request")
            try await Full.expectRepaired(world, a, "kept")
        }
    }

    /// Too little free space for its estimate: nothing is asked of the server, the page says so, and it is not tried
    /// again (no backoff loop) until space grew.
    @Test func tooLittleSpaceAsksNothingAndWaitsForSpace() async throws {
        try await ExchangeWorld.run { world in
            let (a, _, _, _) = try await Full.world(world)
            let free = ServerSnapshotSpoolTests.FreeSpace(1 << 30)
            await a.engine.setSnapshotTesting(disk: ServerBulkDiskPolicy(available: { _ in free.value }))
            let log = SnapshotLog()
            a.transport.handler = log.handler()
            let refused = await a.engine.forceFullSynchronization()
            #expect(refused.insufficientSpace && refused.retryAfter == nil && !refused.reprojected)
            #expect(log.requests.isEmpty, "nothing asked of the server")
            #expect(try await a.engine.fullSynchronizationRequested(), "still requested")
            // Space grew, but not by the shortfall: still waiting, still nothing asked.
            free.value += 50 << 20
            #expect(await a.engine.forceFullSynchronization().insufficientSpace && log.requests.isEmpty)
            free.value = 1 << 40
            let report = await a.engine.forceFullSynchronization()
            #expect(report.reprojected && !report.insufficientSpace)
        }
    }

    /// On a network the download may not use (mobile data or Low Data Mode with the preference off), Force full
    /// synchronization asks nothing of the server's snapshot and the ordinary exchange runs: other devices' changes keep
    /// arriving, and the page says the repair waits for Wi-Fi. On Wi-Fi it runs.
    @Test func onARestrictedNetworkTheRepairWaitsAndOrdinarySyncGoesOn() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, one, _) = try await Full.world(world)
            let log = SnapshotLog()
            a.transport.handler = log.handler()
            a.transport.bulkWait = .mobileDataOff
            try await c.store.setFavorite(episodeID: try await Concurrency.same(one[3], from: a, on: c), favorite: true)
            await c.exchange()
            let waiting = await a.engine.forceFullSynchronization()
            #expect(waiting.fullSynchronizationWaitsForNetwork == .mobileDataOff && !waiting.reprojected && waiting.error == nil)
            #expect(log.requests.isEmpty, "no snapshot asked")
            #expect(try await a.store.episode(id: one[3])?.userState.isFavorite == true, "ordinary sync went on")
            #expect(try await a.engine.fullSynchronizationRequested())
            a.transport.bulkWait = nil
            let report = await a.engine.forceFullSynchronization()
            #expect(report.reprojected && report.fullSynchronizationWaitsForNetwork == nil && !report.fullSynchronizationHolds)
        }
    }

    /// The same through the app's own HTTP transport and network gate: on Low Data Mode Wi-Fi with the mobile-data
    /// preference off, the transport refuses a whole-library download but carries ordinary sync. The repair says it
    /// waits for the network, asks no snapshot, and another phone's favorite still arrives; on plain Wi-Fi it runs.
    @Test func overTheAppsTransportOnLowDataWiFiTheRepairWaitsAndAnotherPhonesFavoriteArrives() async throws {
        try await ExchangeWorld.run { world in
            let monitor = DownloadNetworkMonitor(startMonitoring: false)
            monitor.update(DownloadNetworkState(connected: true, metered: false, cellular: false, transport: .wifi))
            let a = try await world.attach("A", network: DownloadNetworkSyncGate(monitor: monitor, allowMobile: { false }))
            let feed = try await a.store.subscribeForTesting(Agreement.fetched(world.url("one.xml"), title: "One", prefix: "one", count: 5))
            try await Agreement.waitForCatalog(a, feedID: feed.id)
            let c = try await world.attach("C")
            let episode = try #require(feed.episodes.map(\.id).sorted().last)
            try await c.store.setFavorite(episodeID: try await Concurrency.same(episode, from: a, on: c), favorite: true)
            await c.exchange()

            monitor.update(DownloadNetworkState(connected: true, metered: false, cellular: false, transport: .wifi, constrained: true))
            let waiting = await a.engine.forceFullSynchronization()
            #expect(waiting.fullSynchronizationWaitsForNetwork == .mobileDataOff && !waiting.networkNotPermitted, "the wait is shown")
            #expect(!waiting.reprojected && waiting.error == nil)
            #expect(!a.transport.requests.contains { $0.path == "v1/snapshot" }, "no snapshot asked")
            #expect(try await a.store.episode(id: episode)?.userState.isFavorite == true, "ordinary sync went on")
            #expect(try await a.engine.fullSynchronizationRequested())

            monitor.update(DownloadNetworkState(connected: true, metered: false, cellular: false, transport: .wifi))
            let report = await a.engine.forceFullSynchronization()
            #expect(report.reprojected && report.fullSynchronizationWaitsForNetwork == nil && !report.fullSynchronizationHolds)
        }
    }

    /// The staging would use the space the app keeps: the write gate refuses it, nothing of the live library changes, the
    /// verified download stays, and it is not staged again (no loop) until free space grew.
    @Test func stagingThatWouldUseTheReserveStopsAndWaitsForSpace() async throws {
        try await ExchangeWorld.run { world in
            let (a, _, one, two) = try await Full.world(world)
            try await Full.corrupt(a, one: one, two: two)
            let wrong = try await a.view()
            let free = ServerSnapshotSpoolTests.FreeSpace(ServerBulkDiskPolicy().reserve + (10 << 20))
            // Room to download this small library (its size unknown: A attached an empty account), not to stage it.
            var policy = ServerBulkDiskPolicy(available: { _ in free.value })
            policy.unknownAdmission = 1 << 20
            await a.engine.setSnapshotTesting(disk: policy)
            let reached = Reached()
            await a.engine.setCrashPoint { if $0 == "full.spooled" { reached.add() } }
            let stopped = await a.engine.forceFullSynchronization()
            #expect(stopped.insufficientSpace && !stopped.reprojected && stopped.retryAfter == nil && stopped.error == nil, "\(stopped)")
            #expect(reached.count == 1)
            #expect(try await a.view() == wrong, "nothing of the live library changed")
            #expect(ServerSnapshotSpool.manifest(in: Self.spool(a))?.complete == true, "the verified download stays")
            let again = await a.engine.forceFullSynchronization()
            #expect(again.insufficientSpace && reached.count == 1, "not staged again before space grew")
            free.value = 1 << 40
            let report = await a.engine.forceFullSynchronization()
            #expect(report.reprojected && reached.count == 2)
            try await Full.expectRepaired(world, a, "after-space")
        }
    }

    final class Reached: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    /// A repair waiting for space never stops ordinary sync: another device's change still arrives, and the attempt is
    /// not reported as a successful synchronization.
    @Test func aSpaceWaitStillPullsAndIsNotSuccessful() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, one, _) = try await Full.world(world)
            await a.engine.setSnapshotTesting(disk: ServerBulkDiskPolicy(available: { _ in 1 << 30 }))
            let log = SnapshotLog()
            a.transport.handler = log.handler()
            // The attempt that finds too little space, and later ones while it waits, both bring other devices' changes.
            try await c.store.setFavorite(episodeID: try await Concurrency.same(one[2], from: a, on: c), favorite: true)
            await c.exchange()
            let first = await a.engine.forceFullSynchronization()
            #expect(first.insufficientSpace && !first.completed && first.pulledCommits >= 1, "\(first)")
            #expect(try await a.store.episode(id: one[2])?.userState.isFavorite == true, "the other device's change arrived")
            try await c.store.setFavorite(episodeID: try await Concurrency.same(one[3], from: a, on: c), favorite: true)
            await c.exchange()
            let again = await a.engine.forceFullSynchronization()
            #expect(again.insufficientSpace && !again.completed && again.pulledCommits >= 1, "\(again)")
            #expect(try await a.store.episode(id: one[3])?.userState.isFavorite == true, "and the next one")
            #expect(log.requests.isEmpty)
            #expect(try await a.engine.fullSynchronizationRequested())
        }
    }

    /// Playback starts while the repair waits for space: ordinary sync still goes on (the space wait is honoured
    /// before the playback wait, which would otherwise hold everything back).
    @Test func aSpaceWaitStillPullsWhenPlaybackStarts() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, one, _) = try await Full.world(world)
            await a.engine.setSnapshotTesting(stagingWhilePlaying: 0, disk: ServerBulkDiskPolicy(available: { _ in 1 << 30 }))
            #expect(await a.engine.forceFullSynchronization().insufficientSpace)
            a.playing.value = true
            try await c.store.setFavorite(episodeID: try await Concurrency.same(one[2], from: a, on: c), favorite: true)
            await c.exchange()
            let report = await a.engine.forceFullSynchronization()
            #expect(report.insufficientSpace && report.pulledCommits >= 1, "\(report)")
            #expect(try await a.store.episode(id: one[2])?.userState.isFavorite == true, "the other device's change arrived")
            a.playing.value = false
        }
    }

    /// The same through the scheduler: Force full synchronization, then Synchronize now, while space is short.
    @Test func throughTheSchedulerASpaceWaitKeepsSynchronizing() async throws {
        try await ServerSyncSchedulingServerTests.inWorld { world in
            let (a, c, one, _) = try await Full.world(world)
            await a.engine.setSnapshotTesting(disk: ServerBulkDiskPolicy(available: { _ in 1 << 30 }))
            let scheduler = ServerSyncScheduler(engine: a.engine, hints: nil, outbox: nil, network: ServerSyncSchedulingServerTests.Permitted())
            scheduler.start()
            let full = await scheduler.forceFullSynchronization()
            #expect(full?.insufficientSpace == true && full?.completed == false)
            try await c.store.setFavorite(episodeID: try await Concurrency.same(one[1], from: a, on: c), favorite: true)
            await c.exchange()
            let now = await scheduler.synchronizeNow()
            #expect(now?.insufficientSpace == true && now?.completed == false)
            #expect(try await a.store.episode(id: one[1])?.userState.isFavorite == true, "ordinary sync went on")
            await scheduler.stop()
        }
    }

    /// A background app refresh's exchange starts no snapshot download (the scheduler never runs the repair there).
    @Test func aRefreshTasksExchangeNeverDownloads() async throws {
        try await ExchangeWorld.run { world in
            let (a, _, _, _) = try await Full.world(world)
            await a.engine.requestFullSynchronization()
            let log = SnapshotLog()
            a.transport.handler = log.handler()
            let report = await a.engine.exchange(snapshots: false)
            #expect(report.error == nil && log.requests.isEmpty)
        }
    }

    /// A kept download whose head the live library already passed (an older app applied beyond it) can never be
    /// published: it is deleted and nothing is held.
    @Test func aDownloadTheLibraryPassedIsDeletedAndHoldsNothing() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, one, _) = try await Full.world(world)
            await a.engine.setSnapshotTesting(pageLimit: 4)
            let log = SnapshotLog()
            log.failAt = 3
            a.transport.handler = log.handler()
            _ = await a.engine.forceFullSynchronization()
            #expect(ServerSnapshotSpool.manifest(in: Self.spool(a))?.targetHead != nil)
            // The request is withdrawn (a repair published elsewhere): the download no longer applies.
            try await a.store.clearServerFullSynchronizationRequestForTesting()
            try await c.store.setFavorite(episodeID: try await Concurrency.same(one[3], from: a, on: c), favorite: true)
            await c.exchange()
            let report = await a.engine.exchange()
            #expect(!report.fullSynchronizationHolds)
            #expect(!FileManager.default.fileExists(atPath: Self.spool(a).path))
            #expect(try await a.store.episode(id: one[3])?.userState.isFavorite == true, "nothing held")
        }
    }
}

extension FeedLibraryStore {
    func clearServerFullSynchronizationRequestForTesting() throws {
        try database.execute("DELETE FROM ntp_requests WHERE name = ?", [.text(Self.fullSynchronizationRequest)])
    }
}
