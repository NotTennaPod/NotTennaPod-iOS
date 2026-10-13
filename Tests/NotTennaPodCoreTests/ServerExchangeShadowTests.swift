import Foundation
import Testing
@testable import NotTennaPodCore

/// Apply units built in a shadow and published (PROTOCOL §6.8), the work budget while audio plays (PROTOCOL §6.8),
/// and the player's pin (PROTOCOL §6.8). Small budgets force the shadow path on small commits.
@Suite(.serialized, .timeLimit(.minutes(30))) struct ServerExchangeShadowTests {
    typealias Agreement = ServerExchangeAgreementTests
    typealias Concurrency = ServerExchangeConcurrencyTests

    /// One commit of C's: marks, favorites and queue adds in one push.
    static func oneLargeCommit(_ c: ExchangePhone, _ ids: [Int64]) async throws {
        try await c.store.markEpisodesPlayed(episodeIDs: [ids[0], ids[1]], played: true)
        try await c.store.setFavorite(episodeIDs: [ids[2], ids[3]], favorite: true)
        _ = try await c.store.enqueue([ids[4], ids[3]])
        await c.exchange()
    }

    @Test func aLargeCommitIsNeverVisibleHalfAppliedAndLocalActionsDuringItsBuildSurvive() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            _ = try await a.store.enqueue([ids[0], ids[1]])
            await a.exchange()
            await c.exchange()
            let onC = try await ids.asyncMap { try await Concurrency.same($0, from: a, on: c) }
            try await Self.oneLargeCommit(c, onC)
            await a.engine.setBudgets(direct: 1)
            let before = try await a.view()
            let store = a.store
            let seen = SeenViews(), acted = PlayingFlag()
            await a.engine.setBeforePublish {
                // While the shadow first stages, nothing of the commit shows, and the person acts: a queue clear
                // and a mark of an episode the commit changes (its feed's generation changes).
                guard !acted.value else { return }
                acted.value = true
                seen.duringBuild = try await store.syncedViewForTesting()
                _ = try await store.clearQueue()
                try await store.markEpisodePlayed(episodeID: ids[2], played: true)
            }
            let report = await a.run([.pull, .apply])
            #expect(report.publishedUnits >= 1, "built in a shadow")
            #expect(seen.duringBuild == before, "nothing of the commit was visible before its publication")
            // A bounded switch that keeps the local operations (PROTOCOL §6.8): the episode and the queue they touched are
            // re-projected at the publication; the shadow is not built again.
            #expect(report.shadowsBuilt == 1 && report.rebasedEntities >= 2, "\(report)")
            #expect(try await !a.engine.logEntries().contains { $0.kind == "apply" && $0.detail.hasSuffix("staged again") })
            await a.engine.setBeforePublish(nil)
            let after = try await a.view()
            var wires: [String] = []
            for id in ids { wires.append(try #require(try await a.store.wireEpisodeForTesting(id))) }
            // A's clear removed what it observed (ids 0 and 1); C's concurrent adds stay (scenario 9).
            #expect(after.queue == [wires[4], wires[3]], "the clear made during staging is not undone: \(after.queue)")
            let marked = after.episodes[wires[2]]
            #expect(marked?.playState == .played, "the local mark made during staging stays")
            #expect(marked?.favorite == true, "beside the commit's own change of the same episode")
            #expect(after.episodes[wires[3]]?.favorite == true, "the commit's changes are published")
            #expect(after.episodes[wires[0]]?.playState == .played)
            try await Concurrency.converge(world, [a, c], "shadow")
        }
    }

    /// A large publication over episodes that have a playback session, a playback selection, queue entries and
    /// download jobs keeps all of them.
    @Test func aPublicationKeepsPlaybackQueueAndDownloadRows() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            _ = try await a.store.beginPlayback(episodeID: ids[3])
            _ = try await a.store.enqueue([ids[2]])
            _ = try await a.store.requestDownload(episodeID: ids[2], directory: world.root.appendingPathComponent("media-a"), enqueue: false)
            await a.exchange()
            await c.exchange()
            let onC = try await ids.asyncMap { try await Concurrency.same($0, from: a, on: c) }
            try await Self.oneLargeCommit(c, onC)
            await a.engine.setBudgets(direct: 1)
            let dependents = "SELECT (SELECT count(*) FROM playback_session WHERE episode_id = \(ids[3])), (SELECT count(*) FROM playback_selection WHERE episode_id = \(ids[3])), (SELECT count(*) FROM queue WHERE episode_id = \(ids[2])), (SELECT count(*) FROM download_jobs WHERE episode_id = \(ids[2]))"
            #expect(try a.rows(dependents) == [["1", "1", "1", "1"]])
            let report = await a.run([.pull, .apply])
            #expect(report.publishedUnits >= 1)
            #expect(try a.rows(dependents) == [["1", "1", "1", "1"]], "keyed writes only: nothing cascaded away")
            #expect(try await a.store.episode(id: ids[3])?.userState.isFavorite == true)
        }
    }

    /// PROTOCOL §6.8: while audio plays, a publication over its budget waits for a pause or stop; local work never
    /// waits; units are paced.
    @Test func aPublicationOverItsBudgetWaitsForAPause() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let onC = try await ids.asyncMap { try await Concurrency.same($0, from: a, on: c) }
            try await Self.oneLargeCommit(c, onC)
            // Over the background budget too: with the app in the background, it waits for the pause.
            await a.engine.setBudgets(direct: 1, publish: 2, background: 2)
            a.playing.value = true
            let cursor = try a.rows("SELECT seq FROM ntp_library")
            let waiting = await a.engine.exchange()
            #expect(waiting.waitingForPause)
            #expect(try a.rows("SELECT seq FROM ntp_library") == cursor, "nothing applied while playing")
            try await a.store.setFavorite(episodeID: ids[4], favorite: true)
            a.playing.value = false
            let paused = await a.engine.exchange()
            #expect(!paused.waitingForPause && paused.publishedUnits >= 1)
            try await Concurrency.converge(world, [a, c], "budget")
        }
    }

    @Test func unitsArePacedWhileAudioPlays() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let onC = try await ids.asyncMap { try await Concurrency.same($0, from: a, on: c) }
            // A's own observation of its first population comes back first: the four units are C's.
            await a.exchange()
            for id in onC.prefix(4) { try await c.store.setFavorite(episodeID: id, favorite: true); await c.exchange() }
            a.playing.value = true
            await a.run([.pull])
            let clock = ContinuousClock(), started = clock.now
            let report = await a.run([.apply])
            #expect(report.appliedUnits == 4)
            #expect(started.duration(to: clock.now) >= .milliseconds(3 * 250), "at most one unit per 250 ms while playing")
        }
    }

    /// PROTOCOL §6.8: the loaded episode's position waits while the player holds it, and is applied when it leaves it.
    @Test func theLoadedEpisodesRemotePositionWaitsForThePlayer() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            _ = try await a.store.beginPlayback(episodeID: ids[0])
            var listening = RemoteSession(store: c.store, episode: try await Concurrency.same(ids[0], from: a, on: c))
            try await listening.start(at: 0)
            try await listening.checkpoint(position: 120_000, contribution: 120_000)
            await c.exchange()
            await a.exchange()
            let held = try #require(try await a.store.episode(id: ids[0]))
            #expect(held.userState.positionMilliseconds == 0, "the player's episode keeps its position")
            #expect(held.userState.playedDurationMilliseconds == 120_000, "everything else about it is projected")
            #expect(try a.rows("SELECT count(*) FROM ntp_deferred_pins") == [["1"]])
            _ = try await a.store.beginPlayback(episodeID: ids[1])
            await a.exchange()
            #expect(try await a.store.episode(id: ids[0])?.userState.positionMilliseconds == 120_000, "applied once the player left it")
            #expect(try a.rows("SELECT count(*) FROM ntp_deferred_pins") == [["0"]])
        }
    }
}

final class SeenViews: @unchecked Sendable {
    private let lock = NSLock()
    private var view: SyncedView?
    var duringBuild: SyncedView? {
        get { lock.withLock { view } }
        set { lock.withLock { view = newValue } }
    }
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
