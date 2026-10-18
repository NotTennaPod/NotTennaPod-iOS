import Foundation
import Testing
@testable import NotTennaPodCore

/// Scheduling against the real server (PROTOCOL §6.4): the change-hint stream with a device token, the
/// scheduler bringing another phone's change by a hint and, without hints, by polling, a local action pushed after
/// the debounce, pushes continuing while a publication waits for a pause, and the store's wake hints.
@Suite(.serialized) struct ServerSyncSchedulingServerTests {
    typealias Agreement = ServerExchangeAgreementTests
    typealias Concurrency = ServerExchangeConcurrencyTests
    typealias Shadow = ServerExchangeShadowTests

    struct Permitted: ServerSyncNetworkGate {
        func permitted() async -> Bool { true }
        func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
    }

    /// Waits for a condition, re-checked every 50 ms, for at most `seconds`.
    @MainActor static func waitFor(_ seconds: Double = 30, _ condition: @MainActor () async throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try await condition()
    }

    @Test func theEventStreamNamesTheHeadAtOnceAndAfterEveryCommit() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            await a.exchange()
            let box = a.tokenBox
            var events = ServerEventStream(base: world.server.base, token: { box.value }).hints().makeAsyncIterator()
            let first = try await events.next()
            let live = await a.engine.liveHead()
            #expect(first != nil && first == live, "the current head at once: \(String(describing: first))")
            try await c.store.setFavorite(episodeID: try await Concurrency.same(ids[0], from: a, on: c), favorite: true)
            await c.exchange()
            let next = try await events.next()
            #expect((next?.seq ?? 0) > (first?.seq ?? .max), "C's commit is named")
            // A refused token: the stream says so.
            var refused = ServerEventStream(base: world.server.base, token: { "not-a-token" }).hints().makeAsyncIterator()
            await #expect(throws: ServerChangeHintError.rejected) { _ = try await refused.next() }
        }
    }

    @Test func aServerWithoutEventsIsTold() async throws {
        let older = try await LoopbackHTTPServer.start { _ in .init(status: 404, body: Data("{\"error\":\"not_found\",\"message\":\"\"}".utf8)) }
        defer { older.stop() }
        var events = ServerEventStream(base: URL(string: "http://127.0.0.1:\(older.url.port!)")!, token: { "token" }).hints().makeAsyncIterator()
        await #expect(throws: ServerChangeHintError.unsupported) { _ = try await events.next() }
    }

    /// `ExchangeWorld.run` for a main-actor test body.
    @MainActor static func inWorld(_ body: @MainActor (ExchangeWorld) async throws -> Void) async throws {
        let world = try await ExchangeWorld.start()
        do { try await body(world) } catch { await world.stop(); throw error }
        await world.stop()
    }

    @MainActor @Test func anotherPhonesChangeArrivesByAChangeHintAndALocalActionIsPushed() async throws {
        try await Self.inWorld { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            var timing = ServerSyncScheduler.Timing()
            timing.polling = .seconds(3_600)
            timing.debounce = .milliseconds(200)
            let box = a.tokenBox
            let scheduler = ServerSyncScheduler(engine: a.engine, hints: ServerEventStream(base: world.server.base, token: { box.value }),
                                                outbox: { [store = a.store] in await store.serverOutboxChanges() }, network: Permitted(), timing: timing)
            scheduler.start()
            scheduler.setForeground(true)
            #expect(try await Self.waitFor { scheduler.hintsConnected })
            let onC = try await Concurrency.same(ids[1], from: a, on: c)
            try await c.store.setFavorite(episodeID: onC, favorite: true)
            await c.exchange()
            #expect(try await Self.waitFor { try await a.store.episode(id: ids[1])?.userState.isFavorite == true }, "C's change arrived")
            #expect(scheduler.history.contains { $0.contains(.hint) }, "by a hint: \(scheduler.history)")
            // Once that exchange has settled, A's own action is pushed after the debounce by the store's wake hint (no
            // exchange is running to take it along), and reaches C by C's next pull.
            #expect(try await Self.waitFor { !scheduler.hasPendingWork })
            let before = scheduler.exchangesRun
            try await a.store.markEpisodePlayed(episodeID: ids[2], played: true)
            #expect(try await Self.waitFor { try await a.store.serverUnsentChanges() == 0 })
            // The wake hint's debounced exchange runs (a hint for A's own commit may follow it).
            #expect(try await Self.waitFor { scheduler.history.suffix(scheduler.exchangesRun - before).contains { $0.contains(.localChange) } },
                    "\(scheduler.history)")
            await c.exchange()
            #expect(try await c.store.episode(id: try await Concurrency.same(ids[2], from: a, on: c))?.userState.playState == .played)
            await scheduler.stop()
        }
    }

    @MainActor @Test func withoutHintsAnotherPhonesChangeArrivesByPolling() async throws {
        try await Self.inWorld { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            var timing = ServerSyncScheduler.Timing()
            timing.polling = .milliseconds(300)
            // The server's event stream is gone (an older server): the proxy answers it with 404.
            let older = try await LoopbackHTTPServer.start { _ in .init(status: 404, body: Data()) }
            defer { older.stop() }
            let scheduler = ServerSyncScheduler(engine: a.engine, hints: ServerEventStream(base: URL(string: "http://127.0.0.1:\(older.url.port!)")!, token: { "t" }),
                                                outbox: nil, network: Permitted(), timing: timing)
            scheduler.start()
            scheduler.setForeground(true)
            // The launch and activation exchanges settle first: the change made after them can only arrive by polling.
            #expect(try await Self.waitFor { scheduler.history.contains { $0.contains(.launch) } && scheduler.history.contains { $0.contains(.activation) }
                && !scheduler.hasPendingWork })
            let settled = scheduler.exchangesRun
            try await c.store.setFavorite(episodeID: try await Concurrency.same(ids[0], from: a, on: c), favorite: true)
            await c.exchange()
            #expect(try await Self.waitFor { try await a.store.episode(id: ids[0])?.userState.isFavorite == true })
            #expect(scheduler.history.suffix(scheduler.exchangesRun - settled).contains { $0.contains(.poll) } && !scheduler.hintsConnected,
                    "\(scheduler.history) \(scheduler.hintsConnected)")
            await scheduler.stop()
        }
    }

    ///: checkpoints and actions reach the server while a large publication waits for a pause (later commits wait,
    /// this library's facts do not).
    @Test func aPublicationWaitingForAPauseStillPushesThisLibrarysFacts() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let onC = try await ids.asyncMap { try await Concurrency.same($0, from: a, on: c) }
            try await Shadow.oneLargeCommit(c, onC)
            await a.engine.setBudgets(direct: 1, publish: 2, background: 2)
            a.playing.value = true
            let cursor = try a.rows("SELECT seq FROM ntp_library")
            #expect(await a.engine.exchange().waitingForPause, "C's large commit waits in the archive")
            // While it waits, A's own action and the exchanges after it.
            try await a.store.setFavorite(episodeID: ids[4], favorite: true)
            let report = await a.engine.exchange()
            #expect(report.waitingForPause && report.acknowledged == 1, "waiting, and A's favorite was acknowledged")
            #expect(try a.rows("SELECT seq FROM ntp_library") == cursor, "nothing applied while playing")
            await c.exchange()
            #expect(try await c.store.episode(id: onC[4])?.userState.isFavorite == true, "A's favorite reached another phone")
            a.playing.value = false
            try await Concurrency.converge(world, [a, c], "waiting")
        }
    }

    /// Whether `stream` yields within `limit` after `action`.
    static func woke(within limit: Duration, _ stream: AsyncStream<Void>, after action: () async throws -> Void) async throws -> Bool {
        let listener = Task { () -> Bool in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next() != nil
        }
        try await action()
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await listener.value }
            group.addTask { try? await Task.sleep(for: limit); return false }
            let first = await group.next() ?? false
            // The group ends only when both children have: the listener stops waiting now.
            listener.cancel()
            group.cancelAll()
            return first
        }
    }

    @Test func aLocalActionThatRecordsFactsWakesTheScheduler() async throws {
        let fixture = try await ServerLibraryFixture()
        let (feed, _, _) = try await fixture.subscribeRegistered()
        let ids = feed.episodes.map(\.id).sorted()
        let session = try await fixture.store.beginPlayback(episodeID: ids[0])
        // A playback save records no fact in this stage: no wake.
        let saveWoke = try await Self.woke(within: .milliseconds(300), await fixture.store.serverOutboxChanges()) {
            _ = try await fixture.store.recordPlayback(sessionID: session.id, sample: PlaybackSample(positionMilliseconds: 5_000,
                durationMilliseconds: 600_000, status: .playing))
        }
        #expect(!saveWoke, "a save that records nothing wakes nothing")
        let favorite = try await Self.woke(within: .seconds(5), await fixture.store.serverOutboxChanges()) {
            try await fixture.store.setFavorite(episodeID: ids[1], favorite: true)
        }
        #expect(favorite, "a favorite wakes the scheduler")
        await fixture.close()
    }
}
