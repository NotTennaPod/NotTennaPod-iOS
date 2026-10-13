import Foundation
import Testing
@testable import NotTennaPodCore

/// `version_unsupported` (426) for what a recovery after a server restore sends (PROTOCOL §10, §6.10): its successor
/// installation, its snapshot, inventory, uploads and finish. The refused request waits: automatic work (background
/// tasks) does not send it again or ask for processing time for it, the log names what was refused, and Synchronize now
/// (an explicit retry) sends it again, after which the recovery finishes. A refused catch-up pull or secret blocks the
/// recovery the same way: it never advances without having caught up.
@Suite(.serialized, .timeLimit(.minutes(20))) struct ServerRecoveryVersionPauseTests {
    typealias Copies = ServerCopiesTests

    /// What one refusal did: the report of the Synchronize now it refused, and how often the refused path was sent by
    /// then, after automatic work, and after Synchronize now with the server updated.
    struct Observed: Sendable {
        var refused: ServerExchangeReport?
        var sentByRefusal = 0, sentAfterAutomaticWork = 0, sentAfterRetry = 0
        var needsProcessingTime = true
        var retried: ServerExchangeReport?
    }

    /// A scheduler on the phone's engine, with the pinned server refusing every request of `path` as a whole until the
    /// explicit retry.
    @MainActor static func observe(_ phone: DevicePhone, refusing path: String) async -> Observed {
        var observed = Observed()
        func sent() -> Int { phone.transport.requests.filter { $0.path.hasPrefix(path) }.count }
        phone.transport.handler = { method, requested, body, server in
            if requested.hasPrefix(path) { throw ServerExchangeError.server(status: 426, code: "version_unsupported", retryAfter: nil) }
            return try await server.send(method, requested, body: body)
        }
        let scheduler = ServerSyncScheduler(engine: phone.engine, hints: nil, outbox: nil, network: ServerSyncSurfacesTests.Permitted())
        scheduler.start()
        observed.refused = await scheduler.synchronizeNow()
        observed.sentByRefusal = sent()
        _ = await scheduler.runInBackground(.processing)
        _ = await scheduler.runInBackground(.refresh)
        observed.sentAfterAutomaticWork = sent()
        observed.needsProcessingTime = scheduler.needsProcessingTime
        phone.transport.handler = nil
        observed.retried = await scheduler.synchronizeNow()
        observed.sentAfterRetry = sent()
        await scheduler.stop()
        return observed
    }

    @Test(arguments: [("v1/installations/successor", ServerRefusedRequest.installation), ("v1/snapshot", .recovery),
                      ("v1/sync/recovery/inventory", .recovery), ("v1/sync/recovery/upload", .recovery), ("v1/sync/recovery/finish", .recovery)])
    func aRefusedRecoveryRequestWaitsForAnExplicitRetry(path: String, request: ServerRefusedRequest) async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Copies.subscribed(world)
            await a.exchange()
            let backup = try await world.backUp()
            // A change the restored server lacks: the recovery uploads it.
            try await a.store.setFavorite(episodeID: ids[0], favorite: true)
            await a.exchange()
            try await world.restore(backup)
            #expect(await a.engine.exchange().pause == .signIn)
            try await a.signInAgain()

            let observed = await Self.observe(a, refusing: path)
            let refused = try #require(observed.refused)
            #expect(refused.pause == .versionUnsupported && refused.refusedRequests == [request] && refused.retryAfter == nil, "\(refused)")
            #expect(observed.sentByRefusal >= 1, "\(path) was sent")
            #expect(observed.sentAfterAutomaticWork == observed.sentByRefusal, "automatic work does not send \(path) again")
            #expect(!observed.needsProcessingTime, "no processing time is asked for a refused recovery")
            #expect(try await a.log().contains { $0.kind == "paused" && $0.detail.contains("HTTP 426 refused the \(request.rawValue)") })
            #expect(observed.sentAfterRetry > observed.sentAfterAutomaticWork, "Synchronize now sends \(path) again")
            #expect(observed.retried?.pause == nil, "\(String(describing: observed.retried))")
            let recovery = try #require(try await a.store.serverRecovery())
            #expect(recovery.finished && recovery.complete == true, "\(recovery)")
            try await world.converge([a], path)
            #expect(try await a.view().episodes[try #require(try await a.store.wireEpisodeForTesting(ids[0]))]?.favorite == true)
            await a.close()
        }
    }

    /// A started scheduler on the phone's engine: its launch exchange is automatic work.
    @MainActor static func started(_ phone: DevicePhone) -> ServerSyncScheduler {
        let scheduler = ServerSyncScheduler(engine: phone.engine, hints: nil, outbox: nil, network: ServerSyncSurfacesTests.Permitted())
        scheduler.start()
        return scheduler
    }

    /// A on a server restored from a backup taken before A favorited an episode, signed in again. Pushed but not pulled,
    /// the restored server still holds A's history (a prefix recovery); pulled as well, it does not (a full recovery, whose
    /// snapshot becomes the base). With `otherDeviceLogin`, another device set a login for the podcast after the restore:
    /// what A catches up with, or its full snapshot, names a secret A does not hold.
    static func restored(_ world: ExchangeWorld, prefix: Bool, otherDeviceLogin: Bool) async throws -> (phone: DevicePhone, ids: [Int64]) {
        let (a, ids) = try await Copies.subscribed(world)
        await a.exchange()
        let backup = try await world.backUp()
        try await a.store.setFavorite(episodeID: ids[0], favorite: true)
        if prefix { _ = await a.engine.run([.push]) } else { await a.exchange() }
        try await world.restore(backup)
        if otherDeviceLogin {
            let b = try await world.device("B")
            let row = try #require(try b.rows("SELECT id FROM feeds").first?.first ?? nil)
            let feed = try #require(Int64(row))
            try await FeedAuthentication(store: b.store, vault: b.vault).save(.init(username: "user", password: "login-of-b"), feedID: feed)
            await b.exchange()
            await b.close()
        }
        #expect(await a.engine.exchange().pause == .signIn)
        try await a.signInAgain()
        return (a, ids)
    }

    /// The pinned server, refusing every request of `path` as a whole (426) from the recovery's successor installation on
    /// (before it, a pull is what finds the restore) until the handler is taken away.
    static func refuse(_ phone: DevicePhone, _ path: String) {
        let transport = phone.transport
        transport.handler = { method, requested, body, server in
            if requested.hasPrefix(path), transport.requests.contains(where: { $0.path == "v1/installations/successor" }) {
                throw ServerExchangeError.server(status: 426, code: "version_unsupported", retryAfter: nil)
            }
            return try await server.send(method, requested, body: body)
        }
    }

    static func sent(_ phone: DevicePhone, _ prefix: String) -> Int { phone.transport.requests.filter { $0.path.hasPrefix(prefix) }.count }

    static func path(_ request: ServerRefusedRequest) -> String { request == .pull ? "v1/pull" : "v1/secrets/" }

    /// The recovery has not advanced: the favorite it restored is shown, it is neither caught up nor finished, and no
    /// finish was sent.
    static func held(_ phone: DevicePhone, _ episode: Int64, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        #expect(try await phone.store.episode(id: episode)?.userState.isFavorite == true, "\(label): the favorite stays shown",
                sourceLocation: sourceLocation)
        let recovery = try #require(try await phone.store.serverRecovery(), sourceLocation: sourceLocation)
        #expect(!recovery.finished && !recovery.caughtUp, "\(label): \(recovery)", sourceLocation: sourceLocation)
        #expect(sent(phone, "v1/sync/recovery/finish") == 0, "\(label): no finish is sent", sourceLocation: sourceLocation)
    }

    /// After the explicit retry: the recovery finished complete and the library converges, with the favorite.
    static func converged(_ world: ExchangeWorld, _ phone: DevicePhone, _ episode: Int64, _ label: String) async throws {
        let wire = try #require(try await phone.store.wireEpisodeForTesting(episode))
        try await world.converge([phone], label)
        let recovery = try #require(try await phone.store.serverRecovery())
        #expect(recovery.finished && recovery.complete == true, "\(label): \(recovery)")
        #expect(try await phone.view().episodes[wire]?.favorite == true, "\(label)")
    }

    /// A recovery advances only once it caught up: the server's head pulled in this exchange and every commit up to it
    /// applied. In a prefix recovery whose catch-up pull or secret the server refused (426 `version_unsupported`),
    /// nothing the uploads restored gives way to a base without its commit: across automatic exchanges and a relaunch
    /// the person's favorite stays shown, the recovery is neither caught up nor finished, and no finish is sent. The
    /// explicit retry catches up and finishes it, and the library converges.
    @Test(arguments: [ServerRefusedRequest.pull, .secret])
    func aRecoveryNeverAdvancesPastARefusedCatchUp(request: ServerRefusedRequest) async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Self.restored(world, prefix: true, otherDeviceLogin: request == .secret)
            Self.refuse(a, Self.path(request))
            let refused = await a.engine.exchange()
            #expect(refused.pause == .versionUnsupported && refused.refusedRequests == [request], "\(refused)")
            try await Self.held(a, ids[0], "refused")
            for _ in 0..<2 { _ = await a.engine.exchange() }
            try await Self.held(a, ids[0], "automatic exchanges")
            try await a.relaunch()
            _ = await a.engine.exchange()
            try await Self.held(a, ids[0], "after a relaunch")
            // The explicit retry (Synchronize now) with the server updated.
            a.transport.handler = nil
            try await a.engine.resume()
            let retried = await a.engine.exchange()
            #expect(retried.pause == nil && retried.error == nil, "\(retried)")
            try await Self.converged(world, a, ids[0], "\(request)")
            await a.close()
        }
    }

    /// A recovery waiting for a request it needs next that the server refused asks no processing time and is not
    /// prepared again: a full recovery whose snapshot names a secret the server refused,
    /// and a prefix recovery whose catch-up pull it refused. Background tasks and a relaunch send nothing of it, and
    /// Synchronize now (an explicit retry) finishes it.
    @Test(arguments: [("full", ServerRefusedRequest.secret), ("prefix", .pull)])
    func aRecoveryWaitingForARefusedRequestAsksNoProcessingTime(kind: String, request: ServerRefusedRequest) async throws {
        try await ExchangeWorld.run { world in
            let (a, ids) = try await Self.restored(world, prefix: kind == "prefix", otherDeviceLogin: request == .secret)
            let path = Self.path(request)
            Self.refuse(a, path)
            var scheduler = await Self.started(a)
            let refused = try #require(await scheduler.synchronizeNow())
            #expect(refused.pause == .versionUnsupported && refused.refusedRequests == [request], "\(refused)")
            let snapshots = Self.sent(a, "v1/snapshot"), recoveries = Self.sent(a, "v1/sync/recovery/"), refusals = Self.sent(a, path)
            #expect(refusals >= 1, "\(path) was sent")
            // Automatic work: background tasks, then a relaunch with its launch exchange.
            _ = await scheduler.runInBackground(.processing)
            _ = await scheduler.runInBackground(.refresh)
            #expect(await !scheduler.needsProcessingTime, "no processing time is asked for a recovery waiting for a retry")
            await scheduler.stop()
            try await a.relaunch()
            scheduler = await Self.started(a)
            _ = await scheduler.runInBackground(.processing)
            #expect(await !scheduler.needsProcessingTime, "after a relaunch")
            #expect(Self.sent(a, "v1/snapshot") == snapshots && Self.sent(a, "v1/sync/recovery/") == recoveries && Self.sent(a, path) == refusals,
                    "nothing of the recovery is prepared or sent again")
            try await Self.held(a, ids[0], "automatic work")
            // Synchronize now with the server updated.
            a.transport.handler = nil
            let retried = try #require(await scheduler.synchronizeNow())
            #expect(retried.pause == nil && retried.error == nil, "\(retried)")
            await scheduler.stop()
            #expect(Self.sent(a, path) > refusals, "Synchronize now sends \(path) again")
            try await Self.converged(world, a, ids[0], "\(kind) \(request)")
            await a.close()
        }
    }
}
