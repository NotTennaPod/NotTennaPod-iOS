import Foundation
import Testing
@testable import NotTennaPodCore

/// The coordinator's three hooks (PROTOCOL §8) through the real `PlaybackCoordinator` with an
/// engine of the test's own: intentional play and resume start or claim, an intentional seek takes over from a waiting
/// claim, adoption moves only a paused, stopped or restored player, and no hook ever fails playback. In a standalone
/// library they do nothing.
@MainActor @Suite(.timeLimit(.minutes(5))) struct ServerPlaybackHookTests {
    @MainActor class Engine: PlaybackEngine {
        enum Command: Equatable { case load(Int64), adopt(Int64), play, pause, seek(Int64), unload }
        var reading: PlaybackEngineReading?
        var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
        var commands: [Command] = []
        var generation: UUID?, commandID: UUID?
        var position: Int64 = 0
        var wantsPlayback = false

        func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
            self.generation = generation; commandID = generation; position = positionMilliseconds
            reading = nil; wantsPlayback = false
            commands.append(.load(episode.id))
        }
        func play(commandID: UUID) {
            wantsPlayback = true; self.commandID = commandID
            reading?.commandID = commandID; reading?.sample.status = .playing
            commands.append(.play)
        }
        func pause(commandID: UUID) {
            wantsPlayback = false; self.commandID = commandID
            reading?.commandID = commandID; reading?.sample.status = .paused
            commands.append(.pause)
        }
        func seek(to positionMilliseconds: Int64, commandID: UUID) {
            self.commandID = commandID; position = positionMilliseconds
            reading?.commandID = commandID; reading?.sample.positionMilliseconds = Int32(positionMilliseconds)
            commands.append(.seek(positionMilliseconds))
        }
        func setSpeed(_ speed: Float, commandID: UUID) throws { self.commandID = commandID; reading?.commandID = commandID }
        func unload() { commands.append(.unload); reading = nil; generation = nil; commandID = nil; wantsPlayback = false }

        /// The engine is prepared (`.ready`), playing if Play came first.
        func ready() {
            guard let generation, let commandID else { return }
            let value = PlaybackEngineReading(generation: generation, commandID: commandID,
                sample: .init(positionMilliseconds: Int32(position), durationMilliseconds: 600_000, status: wantsPlayback ? .playing : .paused),
                speed: 1, skipSilence: false)
            reading = value
            onEvent?(.ready(value))
        }
        /// The engine resumed by itself (an interruption ended): a state change, never a press of play.
        func resumedByItself() {
            guard var value = reading else { return }
            wantsPlayback = true
            value.sample.status = .playing
            reading = value
            onEvent?(.stateChanged(value))
        }
        /// Playback moved on by itself to `position` (no event: the next save reads it).
        func advance(to position: Int32) {
            self.position = Int64(position)
            reading?.sample.positionMilliseconds = position
        }
    }

    /// A Cast receiver: the coordinator restores the state it already has (another sender's, or its own after a
    /// relaunch) instead of loading the episode.
    @MainActor final class Receiver: Engine, PlaybackExternalStateAdopting {
        func adopt(episode: LibraryEpisode, generation: UUID, state: PlaybackExternalState) throws {
            self.generation = generation; commandID = generation
            position = Int64(state.sample.positionMilliseconds)
            wantsPlayback = state.sample.status == .playing
            reading = nil
            commands.append(.adopt(episode.id))
        }
    }

    @MainActor final class Clock {
        var date = Date(timeIntervalSince1970: 1_760_000_000)
    }

    @MainActor struct World {
        let fixture: ServerLibraryFixture
        let ids: [Int64]
        let engine: Engine
        let clock = Clock()
        let playback: PlaybackCoordinator

        init(server: Bool = true, receiver: Bool = false) async throws {
            engine = receiver ? Receiver() : Engine()
            if server {
                let library = try await ServerPlaybackRecorderTests.library()
                fixture = library.fixture; ids = library.ids
            } else {
                fixture = try await ServerLibraryFixture(server: false)
                ids = try await fixture.store.insert(ServerLibraryFixture.fetched()).episodes.map(\.id).sorted()
            }
            let clock = clock
            // As the app resolves them (`PlaybackApplicationPreferences`): a pause or stop saves synchronized.
            playback = PlaybackCoordinator(store: fixture.store, engine: engine, preferences: { _ in
                var preferences = PlaybackPreferences(); preferences.end.synchronize = true; return preferences
            }, clock: { clock.date })
        }

        func facts() throws -> [String] {
            try fixture.outbox().map(\.type).filter { ServerPlaybackRecorderTests.playback.contains($0) }
        }

        /// Waits until every command queued so far has run.
        func settled() async throws { try await playback.awaitPendingOperations() }

        /// Another coordinator on the same library and clock (the app relaunched with another engine).
        func coordinator(_ engine: Engine) -> PlaybackCoordinator {
            let clock = clock
            return PlaybackCoordinator(store: fixture.store, engine: engine, preferences: { _ in
                var preferences = PlaybackPreferences(); preferences.end.synchronize = true; return preferences
            }, clock: { clock.date })
        }
    }

    /// How far the person's Play seeks back on a prepared, paused engine (the rewind after a pause), 0 without a seek.
    static func rewind(_ playback: PlaybackCoordinator, _ engine: Engine) async throws -> Int64 {
        let before = Int64(engine.reading?.sample.positionMilliseconds ?? Int32(engine.position))
        let issued = engine.commands.count
        try await playback.play()
        let seeks = engine.commands[issued...].compactMap { command -> Int64? in if case .seek(let target) = command { target } else { nil } }
        return seeks.last.map { before - $0 } ?? 0
    }

    @Test func aResumeOnAPreparedEngineStartsTheSessionAndThenClaims() async throws {
        let world = try await World()
        defer { Task { await world.fixture.close() } }
        try await world.playback.select(episodeID: world.ids[1], play: false)
        world.engine.ready()
        try await world.settled()
        #expect(world.playback.phase == .paused)
        #expect(try world.facts().isEmpty, "a paused load records nothing")
        try await world.playback.play()
        #expect(try world.facts() == ["session.start"])
        try await world.playback.pause()
        try await world.playback.play()
        let facts = try world.fixture.outbox().filter { ServerPlaybackRecorderTests.playback.contains($0.type) }
        #expect(facts.map(\.type) == ["session.start", "session.checkpoint", "session.checkpoint"])
        #expect(facts.last?.payload["claim"]?.boolValue == true, "the person's resume claims (PROTOCOL §8.1)")
        #expect(facts.first?.payload["baseline"]?.stringValue.map(ContractIdentity.isUUID) == true)
    }

    @Test func playbackStartingAtReadyStartsTheSessionAndAResumptionByItselfClaimsNothing() async throws {
        let world = try await World()
        defer { Task { await world.fixture.close() } }
        try await world.playback.select(episodeID: world.ids[1], play: true)
        world.engine.ready()
        try await world.settled()
        #expect(world.playback.phase == .playing)
        #expect(try world.facts() == ["session.start"])
        try await world.playback.pause()
        world.engine.resumedByItself()
        try await world.settled()
        #expect(world.playback.wantsPlayback)
        #expect(try world.fixture.outbox().filter { $0.payload["claim"]?.boolValue == true }.isEmpty, "an interruption's end is no press of play")
    }

    @Test func aFailingRecordingNeverStopsPlayback() async throws {
        let world = try await World()
        defer { Task { await world.fixture.close() } }
        var failures = 0
        let events = world.playback.events()
        let watcher = Task { for await event in events { if case .storageFailed = event { failures += 1 } } }
        await world.fixture.store.injectRecorderFailure(after: 1)
        try await world.playback.select(episodeID: world.ids[1], play: false)
        world.engine.ready()
        try await world.settled()
        try await world.playback.play()
        try await world.playback.seek(to: 100_000)
        try await world.playback.pause()
        try await world.playback.play()
        #expect(world.playback.phase == .playing && world.playback.wantsPlayback)
        await world.fixture.store.injectRecorderFailure(after: nil)
        watcher.cancel()
        #expect(failures == 0)
        #expect(try world.fixture.rows("SELECT export_owed FROM ntp_library") == [["1"]])
        try await world.fixture.store.flushServerPlayback()
        #expect(try world.facts() == ["session.start", "session.checkpoint", "session.checkpoint"], "owed, then recorded")
    }

    /// Adoption (PROTOCOL §8.6): a paused player moves to the remote position with the paused seek a slider drag makes; a
    /// playing or preparing one is never moved, and the position keeps waiting.
    @Test func adoptionMovesOnlyAPlayerThatIsNotPlaying() async throws {
        let world = try await World()
        defer { Task { await world.fixture.close() } }
        let store = world.fixture.store, episode = world.ids[1]
        try await world.playback.select(episodeID: episode, play: true)
        world.engine.ready()
        try await world.settled()
        try await ServerPlaybackFailureTests.remoteClaim(world.fixture, episode, position: 300_000)
        let adopt: @Sendable (@escaping @Sendable () -> Bool) async throws -> Int32? = { stillPaused in
            try await store.adoptRemotePosition(episodeID: episode, stillPaused: stillPaused)
        }
        // Playing: nothing moves.
        try await world.playback.adoptRemotePosition(episodeID: episode, adopt: adopt)
        #expect(!world.engine.commands.contains(.seek(300_000)))
        #expect(try await store.serverAdoptionWaiting(episodeID: episode), "it keeps waiting")
        // Paused: adopted.
        try await world.playback.pause()
        try await world.playback.adoptRemotePosition(episodeID: episode, adopt: adopt)
        #expect(world.engine.commands.last == .seek(300_000))
        #expect(world.playback.sample?.positionMilliseconds == 300_000)
        #expect(try await store.episode(id: episode)?.userState.positionMilliseconds == 300_000)
        #expect(try await !store.serverAdoptionWaiting(episodeID: episode))
        #expect(try world.facts().suffix(1) == ["session.end"], "the session is sealed at its pre-adoption save")
        let end = try #require(try world.fixture.outbox().last)
        #expect(end.payload["reason"]?.stringValue == "superseded" && end.payload["history"]?.boolValue == false)
        // The next intentional play starts a new session there.
        try await world.playback.play()
        let start = try #require(try world.fixture.outbox().last)
        #expect(start.type == "session.start" && start.payload["start_position"]?.integerValue == 300_000)
    }

    @Test func aPreparingPlayerIsNeverMoved() async throws {
        let world = try await World()
        defer { Task { await world.fixture.close() } }
        let store = world.fixture.store, episode = world.ids[1]
        try await world.playback.select(episodeID: episode, play: false)
        world.engine.ready()
        try await world.playback.play(); try await world.playback.pause()
        try await ServerPlaybackFailureTests.remoteClaim(world.fixture, episode, position: 300_000)
        try await world.playback.select(episodeID: world.ids[2], play: false) // switched: no longer its episode
        try await world.playback.select(episodeID: episode, play: true)       // preparing again
        #expect(world.playback.phase == .preparing)
        try await world.playback.adoptRemotePosition(episodeID: episode) { _ in try await store.adoptRemotePosition(episodeID: episode) }
        #expect(!world.engine.commands.contains(.seek(300_000)))
    }

    /// Playback the engine resumes by itself (a Cast receiver resumed by another sender, an interruption's end) does
    /// not wait for an adoption in progress; its event waits behind it. Resumed after the store committed: the engine
    /// is not moved. Listening this phone did not start is not recorded until a Play here, and that Play starts a
    /// claiming session where the engine then plays.
    @Test func adoptionMustNotSeekAnEngineThatResumedDuringTheStoreAwait() async throws {
        let world = try await World()
        defer { Task { await world.fixture.close() } }
        let store = world.fixture.store, episode = world.ids[1], engine = world.engine
        try await world.playback.select(episodeID: episode, play: true)
        world.engine.ready()
        try await world.settled()
        world.engine.advance(to: 100_000)
        try await world.playback.pause()
        try await ServerPlaybackFailureTests.remoteClaim(world.fixture, episode, position: 300_000)
        try await world.playback.adoptRemotePosition(episodeID: episode) { stillPaused in
            let adopted = try await store.adoptRemotePosition(episodeID: episode, stillPaused: stillPaused)
            await engine.resumedByItself() // after the commit, before the coordinator goes on
            return adopted
        }
        #expect(!world.engine.commands.contains(.seek(300_000)), "sync never moves playing audio")
        #expect(world.engine.position == 100_000 && world.playback.sample?.positionMilliseconds != 300_000)
        try await world.settled()
        #expect(world.playback.wantsPlayback && world.playback.phase == .playing, "the resumption plays on")
        let recorded = try world.facts()
        // The person pauses and plays here: a claiming session starts where the engine plays.
        world.engine.advance(to: 130_000)
        try await world.playback.pause()
        #expect(try await store.episode(id: episode)?.userState.positionMilliseconds == 130_000, "the phone's own resume point")
        try await world.playback.play()
        #expect(try world.facts() == recorded + ["session.start"])
        let start = try #require(try world.fixture.outbox().last)
        #expect(start.payload["start_position"]?.integerValue == 130_000)
        // It counts what plays after the Play here, from where it started (not from the adopted position).
        world.engine.advance(to: 150_000)
        try await world.playback.pause()
        let pause = try #require(try world.fixture.outbox().last)
        #expect(pause.type == "session.checkpoint" && pause.payload["contribution"]?.integerValue == 20_000)
    }

    /// Resumed before the store decided: the adoption commits nothing, the engine is not moved, and the position keeps
    /// waiting.
    @Test func anAdoptionOvertakenByAResumptionCommitsNothing() async throws {
        let world = try await World()
        defer { Task { await world.fixture.close() } }
        let store = world.fixture.store, episode = world.ids[1], engine = world.engine
        try await world.playback.select(episodeID: episode, play: true)
        world.engine.ready()
        try await world.settled()
        world.engine.advance(to: 100_000)
        try await world.playback.pause()
        try await ServerPlaybackFailureTests.remoteClaim(world.fixture, episode, position: 300_000)
        let recorded = try world.fixture.outboxCount()
        try await world.playback.adoptRemotePosition(episodeID: episode) { stillPaused in
            await engine.resumedByItself() // before the store's transaction decides
            return try await store.adoptRemotePosition(episodeID: episode, stillPaused: stillPaused)
        }
        #expect(!world.engine.commands.contains(.seek(300_000)), "sync never moves playing audio")
        #expect(try await store.serverAdoptionWaiting(episodeID: episode), "it keeps waiting")
        #expect(try await store.episode(id: episode)?.userState.positionMilliseconds == 100_000)
        #expect(try world.fixture.outboxCount() == recorded, "nothing sealed")
    }

    /// Stopped and restored players have no engine: the store write and the shown position only; the next Play loads
    /// from the row.
    @Test(arguments: [false, true]) func aStoppedOrRestoredPlayerAdoptsWithoutAnEngine(restored: Bool) async throws {
        let world = try await World()
        defer { Task { await world.fixture.close() } }
        let episode = world.ids[1]
        try await world.playback.select(episodeID: episode, play: false)
        world.engine.ready()
        try await world.playback.play(); try await world.playback.pause()
        try await world.playback.stop()
        var playback = world.playback
        if restored {
            playback = PlaybackCoordinator(store: world.fixture.store, engine: Engine(), preferences: { _ in
                var preferences = PlaybackPreferences(); preferences.end.synchronize = true; return preferences
            }, clock: { Date(timeIntervalSince1970: 1_760_000_100) })
            try await playback.restore()
        }
        #expect(playback.phase == .stopped)
        try await ServerPlaybackFailureTests.remoteClaim(world.fixture, episode, position: 300_000)
        let adoption = ServerPlaybackAdoption(store: world.fixture.store, playback: playback)
        adoption.attempt()
        await adoption.settle()
        #expect(playback.sample?.positionMilliseconds == 300_000)
        #expect(try await world.fixture.store.episode(id: episode)?.userState.positionMilliseconds == 300_000)
    }

    /// The sync layer's adoption waits while the player plays and adopts at the next attempt once it pauses.
    @Test func theSyncLayersAdoptionWaitsForAPause() async throws {
        let world = try await World()
        defer { Task { await world.fixture.close() } }
        let episode = world.ids[1]
        try await world.playback.select(episodeID: episode, play: true)
        world.engine.ready()
        try await world.settled()
        try await ServerPlaybackFailureTests.remoteClaim(world.fixture, episode, position: 300_000)
        let adoption = ServerPlaybackAdoption(store: world.fixture.store, playback: world.playback)
        adoption.attempt()
        await adoption.settle()
        #expect(world.playback.sample?.positionMilliseconds != 300_000, "sync never moves playing audio")
        try await world.playback.pause()
        adoption.attempt()
        await adoption.settle()
        #expect(world.playback.sample?.positionMilliseconds == 300_000)
    }

    /// An intentional seek while playing takes over from a waiting claim (PROTOCOL §8.6): the audio moves first, then the old
    /// session is sealed at the pre-seek position and a new one starts at the target, observing the claim.
    @Test func anIntentionalSeekTakesOverFromAWaitingClaim() async throws {
        let world = try await World()
        defer { Task { await world.fixture.close() } }
        let episode = world.ids[1]
        try await world.playback.select(episodeID: episode, play: true)
        world.engine.ready()
        try await world.settled()
        try await ServerPlaybackFailureTests.remoteClaim(world.fixture, episode, position: 300_000)
        let claim = try #require(try world.fixture.rows("SELECT CAST(value AS TEXT) FROM ntp_records WHERE field_group = 'position'").first?.first ?? nil)
        try await world.playback.seek(to: 400_000)
        #expect(world.engine.commands.last == .seek(400_000))
        let facts = try world.fixture.outbox()
        #expect(facts.map(\.type) == ["session.end", "session.start"])
        #expect(facts[0].payload["reason"]?.stringValue == "superseded" && facts[0].payload["completed"]?.boolValue == false)
        #expect(facts[1].payload["start_position"]?.integerValue == 400_000)
        #expect(claim.contains(try #require(facts[1].payload["observed_claim"]?.stringValue)))
        // Without a waiting claim a seek is part of the open session: nothing is recorded.
        try await world.playback.seek(to: 450_000)
        #expect(try world.fixture.outbox().count == 2)
    }

    /// A Cast receiver already playing is restored on this phone with a new load (after a relaunch): listening this
    /// phone did not start is not recorded until a Play here. Nothing is claimed or
    /// owed, the receiver's saves keep the position on the device, and the next Play here starts a claiming session
    /// where the receiver then stands.
    @Test func castRestorationOfAPendingLoadMustNotClaim() async throws {
        let world = try await World(receiver: true)
        defer { Task { await world.fixture.close() } }
        let store = world.fixture.store, episode = world.ids[1]
        let restored = PlaybackExternalState(sample: .init(positionMilliseconds: 200_000, durationMilliseconds: 600_000, status: .playing))
        try await world.playback.adoptExternalPlayback(episodeID: episode, state: { restored }, activateEngine: {}, isCurrent: { true })
        world.engine.ready()
        try await world.settled()
        #expect(world.engine.commands.contains(.adopt(episode)))
        #expect(world.playback.phase == .playing)
        #expect(try world.facts().isEmpty, "a restoration is no Play here: nothing is claimed")
        let local = try #require(try await store.playbackSession()?.id)
        #expect(try await store.liveSyncSessionStateForTesting(local) == "pending")
        // The receiver plays on; the pause saves where it stands, on the device alone.
        world.engine.advance(to: 260_000)
        try await world.playback.pause()
        let saved = try #require(try await store.episode(id: episode)).userState
        #expect(saved.positionMilliseconds == 260_000, "the phone's own resume point")
        #expect(saved.lastPlayedTimeMilliseconds == 0 && saved.playedDurationMilliseconds == 0, "not recorded as listening here")
        // Nothing owed or due that a later write could turn into a claim.
        #expect(try world.fixture.rows("SELECT export_owed FROM ntp_library") == [["0"]])
        try await store.setFavorite(episodeID: world.ids[2], favorite: true)
        try await store.flushServerPlayback()
        #expect(try world.facts().isEmpty)
        // The next Play here starts a claiming session where the receiver stands, and counts only what plays after it.
        try await world.playback.play()
        let start = try #require(try world.fixture.outbox().last)
        #expect(start.type == "session.start")
        #expect(start.payload["start_position"]?.integerValue == 260_000)
        world.engine.advance(to: 270_000)
        try await world.playback.pause()
        let pause = try #require(try world.fixture.outbox().last)
        #expect(pause.type == "session.checkpoint" && pause.payload["contribution"]?.integerValue == 10_000,
                "the receiver's listening before the Play here is not counted")
    }

    // MARK: - The rewind after a pause is a standalone library's (owner's rule: listening behaviour never changes)

    /// Plays, pauses after 30 s, waits `wait` seconds (another phone's listening of the episode arriving and adopted
    /// meanwhile, with `adopting`) and returns the Play's rewind.
    static func pauseThenPlayRewind(server: Bool, wait: TimeInterval, adopting: Bool = false) async throws -> Int64 {
        let world = try await World(server: server)
        defer { Task { await world.fixture.close() } }
        let episode = world.ids[1]
        try await world.playback.select(episodeID: episode, play: true)
        world.engine.ready()
        try await world.settled()
        world.clock.date += 30
        world.engine.advance(to: 30_000)
        try await world.playback.pause()
        world.clock.date += wait - 10
        if adopting {
            let store = world.fixture.store
            try await Self.remoteListening(world.fixture, episode, position: 300_000, at: world.clock.date)
            #expect(try await store.episode(id: episode)?.userState.lastPlayedTimeMilliseconds
                    == Int64(world.clock.date.timeIntervalSince1970 * 1_000), "the synced last-played date is the other phone's")
            try await world.playback.adoptRemotePosition(episodeID: episode) { stillPaused in
                try await store.adoptRemotePosition(episodeID: episode, stillPaused: stillPaused)
            }
            #expect(world.engine.commands.last == .seek(300_000), "adopted")
        }
        world.clock.date += 10
        return try await Self.rewind(world.playback, world.engine)
    }

    /// Another phone's listening of the episode, as an exchange applies it: its position under its claim, and its date.
    static func remoteListening(_ fixture: ServerLibraryFixture, _ episode: Int64, position: Int64, at time: Date) async throws {
        let wire = try #require(try fixture.wireID(episode))
        let generation = try #require(try fixture.rows("SELECT live_generation FROM ntp_podcasts").first?.first ?? nil)
        _ = try await fixture.store.retireOutboxForTesting(records: [
            ServerRecord(entity: "episode", id: wire, fieldGroup: "position", value: ["generation_id": .string(generation), "position": .integer(position),
                                                                                   "claim_id": .string(ContractIdentity.randomUUID())]),
            ServerRecord(entity: "episode", id: wire, fieldGroup: "last_played", value: ["generation_id": .string(generation),
                                                                                      "time": .integer(Int64(time.timeIntervalSince1970 * 1_000))])])
    }

    /// An ordinary pause and Play: the same rewind as a standalone library.
    @Test func anOrdinaryPauseThenPlayRewindsAsAStandaloneLibraryDoes() async throws {
        let standalone = try await Self.pauseThenPlayRewind(server: false, wait: 120)
        #expect(standalone == 3_000)
        #expect(try await Self.pauseThenPlayRewind(server: true, wait: 120) == standalone)
    }

    /// A paused player adopts another phone's later listening, then the person plays: the rewind measures from when
    /// this player last played, as a standalone library's does, not from the other phone's listening.
    @Test func playAfterAnAdoptedPositionRewindsAsAStandaloneLibraryDoes() async throws {
        let standalone = try await Self.pauseThenPlayRewind(server: false, wait: 7_200)
        #expect(standalone == 10_000)
        #expect(try await Self.pauseThenPlayRewind(server: true, wait: 7_200, adopting: true) == standalone)
    }

    /// Played here two hours ago; after a relaunch a Cast receiver playing the episode is restored, plays on, and the
    /// person pauses it and plays here 30 s later: the same rewind as a standalone library (from the pause, 0.8 s),
    /// although no listening here was recorded and the synced last-played date stayed two hours old.
    static func castRestorationThenPlayRewind(server: Bool) async throws -> Int64 {
        let world = try await World(server: server)
        defer { Task { await world.fixture.close() } }
        let episode = world.ids[1]
        try await world.playback.select(episodeID: episode, play: true)
        world.engine.ready()
        try await world.settled()
        world.clock.date += 10
        world.engine.advance(to: 10_000)
        try await world.playback.pause()
        world.clock.date += 7_200
        let receiver = Receiver()
        let playback = world.coordinator(receiver)
        let restored = PlaybackExternalState(sample: .init(positionMilliseconds: 200_000, durationMilliseconds: 600_000, status: .playing))
        try await playback.adoptExternalPlayback(episodeID: episode, state: { restored }, activateEngine: {}, isCurrent: { true })
        receiver.ready()
        try await playback.awaitPendingOperations()
        #expect(playback.phase == .playing)
        world.clock.date += 20
        receiver.advance(to: 220_000)
        try await playback.pause()
        world.clock.date += 30
        return try await Self.rewind(playback, receiver)
    }

    @Test func playAfterACastRestorationAndAPauseRewindsAsAStandaloneLibraryDoes() async throws {
        let standalone = try await Self.castRestorationThenPlayRewind(server: false)
        #expect(standalone == 800)
        #expect(try await Self.castRestorationThenPlayRewind(server: true) == standalone)
    }

    /// Played here two hours ago; loaded paused, never played, left for another episode; selected again two minutes
    /// later: its load's rewind is a standalone library's (from the switch, 3 s), although the switch recorded no
    /// listening and the synced last-played date stayed two hours old.
    static func reselectAfterAPausedLoadRewind(server: Bool) async throws -> Int64 {
        let world = try await World(server: server)
        defer { Task { await world.fixture.close() } }
        let episode = world.ids[1], other = world.ids[2]
        try await world.playback.select(episodeID: episode, play: true)
        world.engine.ready()
        try await world.settled()
        world.clock.date += 30
        world.engine.advance(to: 30_000)
        try await world.playback.pause()
        try await world.playback.select(episodeID: other, play: false)
        world.engine.ready()
        try await world.settled()
        world.clock.date += 7_200
        for id in [episode, other] {
            try await world.playback.select(episodeID: id, play: false)
            world.engine.ready()
            try await world.settled()
        }
        let left = Int64(try #require(try await world.fixture.store.episode(id: episode)).userState.positionMilliseconds)
        world.clock.date += 120
        try await world.playback.select(episodeID: episode, play: false)
        return left - world.engine.position
    }

    @Test func reselectingAnEpisodeLeftWithoutPlayingRewindsAsAStandaloneLibraryDoes() async throws {
        let standalone = try await Self.reselectAfterAPausedLoadRewind(server: false)
        #expect(standalone == 3_000)
        #expect(try await Self.reselectAfterAPausedLoadRewind(server: true) == standalone)
    }

    /// A standalone library measures the rewind from its last-played date even when a record holds a device-local play
    /// time, from whatever source: Play 30 s after a pause rewinds 0.8 s, not from that time.
    @Test func aStandaloneLibraryIgnoresADeviceLocalPlayTimeARecordHolds() async throws {
        let world = try await World(server: false)
        defer { Task { await world.fixture.close() } }
        let episode = world.ids[1]
        let stale = Int64(world.clock.date.timeIntervalSince1970 * 1_000) - 7_200_000
        try await world.fixture.store.updateEpisode(id: episode) { $0.userState.playedHereMilliseconds = stale }
        try await world.playback.select(episodeID: episode, play: true)
        world.engine.ready()
        try await world.settled()
        world.clock.date += 30
        world.engine.advance(to: 30_000)
        try await world.playback.pause()
        world.clock.date += 30
        #expect(try await world.fixture.store.episode(id: episode)?.userState.playedHereMilliseconds == stale, "a standalone save leaves it")
        #expect(try await Self.rewind(world.playback, world.engine) == 800)
    }

    /// In a standalone library the hooks do nothing.
    @Test func aStandaloneLibraryRecordsNothing() async throws {
        let world = try await World(server: false)
        defer { Task { await world.fixture.close() } }
        try await world.playback.select(episodeID: world.ids[1], play: false)
        world.engine.ready()
        try await world.playback.play()
        try await world.playback.seek(to: 100_000)
        try await world.playback.pause()
        try await world.playback.play()
        #expect(world.playback.phase == .playing)
        #expect(try world.fixture.rows("SELECT (SELECT count(*) FROM ntp_sessions) + (SELECT count(*) FROM ntp_outbox)") == [["0"]])
        #expect(try await world.fixture.store.adoptRemotePosition(episodeID: world.ids[1]) == nil)
    }
}
