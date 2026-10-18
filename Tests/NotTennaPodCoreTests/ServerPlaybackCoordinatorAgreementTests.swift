import Foundation
import Testing
@testable import NotTennaPodCore

/// The coordinator's playback hooks against the pinned server (PROTOCOL §8): a phone's real
/// `PlaybackCoordinator`, with the hook tests' engine, on the real clock, and every phone compared field by field with a
/// fresh attachment.
@MainActor @Suite(.serialized) struct ServerPlaybackCoordinatorAgreementTests {
    typealias Concurrency = ServerExchangeConcurrencyTests
    typealias Engine = ServerPlaybackHookTests.Engine

    /// A phone's coordinator as the app makes it: a pause or stop saves synchronized.
    static func player(_ phone: ExchangePhone, _ engine: Engine) -> PlaybackCoordinator {
        PlaybackCoordinator(store: phone.store, engine: engine, preferences: { _ in
            var preferences = PlaybackPreferences(); preferences.end.synchronize = true; return preferences
        })
    }

    /// Selects `episode` paused and lets the engine become ready.
    static func load(_ playback: PlaybackCoordinator, _ engine: Engine, _ episode: Int64) async throws {
        try await playback.select(episodeID: episode, play: false)
        engine.ready()
        try await playback.awaitPendingOperations()
    }

    static func state(_ phone: ExchangePhone, _ episode: Int64) async throws -> EpisodeUserState {
        try #require(try await phone.store.episode(id: episode)).userState
    }

    /// An episode loaded paused and never played, then left for another: its leave records the history mark only, and
    /// nothing local invents listening (no last-played date, no played time, still new).
    @Test func leavingANeverPlayedPausedLoadMustNotCreateListeningTime() async throws {
        try await ServerSyncSchedulingServerTests.inWorld { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let before = try await Self.state(a, ids[1])
            let engine = Engine()
            let playback = Self.player(a, engine)
            try await Self.load(playback, engine, ids[1])
            try await Self.load(playback, engine, ids[2])
            let left = try await Self.state(a, ids[1])
            #expect(left.lastPlayedTimeMilliseconds == 0, "no listening, no last-played date")
            #expect(left.playedDurationMilliseconds == 0)
            #expect(left.playState == before.playState, "a load that never played leaves the play state")
            #expect((left.lastPlayedHistoryMilliseconds ?? 0) > 0, "the leave's history mark")
            try await Concurrency.converge(world, [a, c], "paused load then switch")
        }
    }

    /// A paused player adopts the position another phone listened to, then the person switches to another episode
    /// without playing: the adopted listening's date stays the other phone's, and the switch adds none.
    @Test func leavingAnAdoptedPositionMustNotCreateListeningTime() async throws {
        try await ServerSyncSchedulingServerTests.inWorld { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let onC = try await Concurrency.same(ids[1], from: a, on: c)
            let engine = Engine()
            let playback = Self.player(a, engine)
            try await Self.load(playback, engine, ids[1])
            let playerC = StorePlayer(c.store, realTime: ())
            try await playerC.load(onC); try await playerC.play(); try await playerC.listen(120, every: 60); try await playerC.pause()
            await c.exchange()
            await a.exchange()
            let store = a.store, episode = ids[1]
            try await playback.adoptRemotePosition(episodeID: episode) { stillPaused in
                try await store.adoptRemotePosition(episodeID: episode, stillPaused: stillPaused)
            }
            let adopted = try await Self.state(a, ids[1])
            #expect(adopted.positionMilliseconds == 120_000, "the paused player adopted C's position")
            try await Self.load(playback, engine, ids[2])
            let left = try await Self.state(a, ids[1])
            let other = try await Self.state(c, onC)
            #expect(left.lastPlayedTimeMilliseconds == other.lastPlayedTimeMilliseconds, "C's listening date, not the switch's")
            #expect(left.playedDurationMilliseconds == 120_000)
            try await Concurrency.converge(world, [a, c], "adopt then switch")
        }
    }
}
