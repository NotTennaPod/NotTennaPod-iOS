import Foundation
import Testing
@testable import NotTennaPodCore

/// PROTOCOL §16's playback scenarios (5–8c, 31, 36, 37, 41, 43, 44) and the named playback agreement cases, with
/// each phone's own recorder against the pinned server: the phones' players are driven
/// through the store as the coordinator drives it (`StorePlayer`, on the real clock: the order of a scenario's actions
/// is the order the test makes them), the sync layer's adoption runs where a paused player would adopt, and every
/// phone converges with a fresh attachment.
@Suite(.serialized, .timeLimit(.minutes(30))) struct ServerPlaybackScenarioTests {
    typealias Concurrency = ServerExchangeConcurrencyTests

    static func state(_ phone: ExchangePhone, _ episode: Int64) async throws -> EpisodeUserState {
        try #require(try await phone.store.episode(id: episode)).userState
    }

    /// 5. Two phones offline for a day each listen to the same episode; once both reconnect and are paused, the
    /// position is the one from the device where play was pressed last, and statistics count both. In both orders.
    @Test(arguments: [true, false]) func scenario5TwoOfflinePhonesListenToTheSameEpisode(aFirst: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let onC = try await Concurrency.same(ids[0], from: a, on: c)
            let playerA = StorePlayer(a.store, realTime: ()), playerC = StorePlayer(c.store, realTime: ())
            try await playerA.load(ids[0]); try await playerA.play(); try await playerA.listen(600, every: 60); try await playerA.pause()
            try await playerC.load(onC); try await playerC.play(); try await playerC.listen(300, every: 60); try await playerC.pause()
            if aFirst { await a.exchange(); await c.exchange(); await a.exchange() } else { await c.exchange(); await a.exchange(); await c.exchange() }
            // The paused players adopt where play was pressed last (C's): A's session is sealed there.
            #expect(try await playerA.adopt() == 300_000)
            #expect(try await playerC.adopt() == nil, "C's own claim owns the position")
            try await Concurrency.converge(world, [a, c], "scenario 5")
            for (phone, id) in [(a, ids[0]), (c, onC)] {
                let state = try await Self.state(phone, id)
                #expect(state.positionMilliseconds == 300_000, "\(phone.name): where play was pressed last")
                #expect(state.playedDurationMilliseconds == 900_000, "\(phone.name): both sessions count")
            }
        }
    }

    /// 5a. A starts Monday and pauses with the app open; B plays to 60% Tuesday; A, still offline, resumes Wednesday to
    /// 30%: every device resumes at A's 30%, and statistics count A's one session and B's one session (PROTOCOL §8.1:
    /// the resume is a claim).
    @Test func scenario5aWherePlayWasPressedLast() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, ids, _) = try await Concurrency.twoPhones(world)
            let onB = try await Concurrency.same(ids[0], from: a, on: b)
            let playerA = StorePlayer(a.store, realTime: ()), playerB = StorePlayer(b.store, realTime: ())
            playerA.duration = 1_000_000; playerB.duration = 1_000_000
            try await playerA.load(ids[0]); try await playerA.play(); try await playerA.listen(100, every: 50); try await playerA.pause()
            try await playerB.load(onB); try await playerB.play(); try await playerB.listen(600, every: 60); try await playerB.pause()
            try await playerA.play(); try await playerA.listen(200, every: 50); try await playerA.pause()
            await b.exchange(); await a.exchange(); await b.exchange()
            #expect(try await playerB.adopt() == 300_000, "B adopts A's resumed listening")
            #expect(try await playerA.adopt() == nil)
            try await Concurrency.converge(world, [a, b], "scenario 5a")
            for (phone, id) in [(a, ids[0]), (b, onB)] {
                let state = try await Self.state(phone, id)
                #expect(state.positionMilliseconds == 300_000, "\(phone.name): where play was pressed last")
                #expect(state.playedDurationMilliseconds == 900_000, "\(phone.name): A's 300 s and B's 600 s")
            }
        }
    }

    /// A start whose recording failed stays owed while another phone's later listening arrives: recorded at last, it
    /// depends only on what its Play observed, so the position stays where play was pressed last (B's), and both
    /// sessions count (PROTOCOL §8.1).
    @Test func anOwedOlderStartMustNotAcquireALaterRemoteClaimAsItsDependency() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, ids, _) = try await Concurrency.twoPhones(world)
            let onB = try await Concurrency.same(ids[0], from: a, on: b)
            let playerA = StorePlayer(a.store, realTime: ()), playerB = StorePlayer(b.store, realTime: ())
            try await playerA.load(ids[0])
            await a.store.injectRecorderFailure(after: 1)
            try await playerA.play(); try await playerA.listen(100, every: 50); try await playerA.pause()
            try await playerB.load(onB); try await playerB.play(); try await playerB.listen(300, every: 60); try await playerB.pause()
            await b.exchange()
            await a.exchange() // A pulls B while its start is still owed
            #expect(try await a.store.serverExportOwedForTesting(), "A's start is still owed")
            await a.store.injectRecorderFailure(after: nil)
            try await a.store.flushServerPlayback()
            await a.exchange(); await b.exchange()
            #expect(try await playerA.adopt() == 300_000, "A adopts where play was pressed last")
            #expect(try await playerB.adopt() == nil)
            try await Concurrency.converge(world, [a, b], "owed older start")
            for (phone, id) in [(a, ids[0]), (b, onB)] {
                let state = try await Self.state(phone, id)
                #expect(state.positionMilliseconds == 300_000, "\(phone.name): where play was pressed last")
                #expect(state.playedDurationMilliseconds == 400_000, "\(phone.name): both sessions count")
            }
        }
    }

    /// 6. An old session elsewhere keeps sending checkpoints; this phone's newer listening is never rewound.
    @Test func scenario6AnOldSessionNeverRewindsNewerListening() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            var old = RemoteSession(store: c.store, episode: try await Concurrency.same(ids[0], from: a, on: c))
            try await old.start(at: 0)
            try await old.checkpoint(position: 60_000, contribution: 60_000)
            await c.exchange()
            await a.exchange()
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(ids[0]); try await player.play(); try await player.listen(300, every: 60); try await player.pause()
            await a.exchange()
            try await old.checkpoint(position: 120_000, contribution: 120_000)
            await c.exchange()
            await a.exchange()
            #expect(try await player.adopt() == nil, "the old session takes nothing back")
            try await Concurrency.converge(world, [a, c], "scenario 6")
            #expect(try await Self.state(a, ids[0]).positionMilliseconds == 360_000)
        }
    }

    /// 7. Paused 10 s from the end on A, replayed from the start on C; later A, offline, switches to another episode: its
    /// end reports a completion under a claim C took over, so the episode is not marked played.
    @Test func scenario7AStaleCompletionDoesNotMarkPlayed() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let onC = try await Concurrency.same(ids[0], from: a, on: c)
            let playerA = StorePlayer(a.store, realTime: ())
            try await playerA.load(ids[0], at: 560_000); try await playerA.play(); try await playerA.listen(30, every: 10); try await playerA.pause()
            await a.exchange(); await c.exchange()
            let playerC = StorePlayer(c.store, realTime: ())
            try await playerC.load(onC, at: 0); try await playerC.play(); try await playerC.listen(30, every: 10); try await playerC.pause()
            await c.exchange()
            try await playerA.load(ids[1])
            #expect(try await Self.state(a, ids[0]).playState == .played, "A's own decision shows while it is pending")
            await a.exchange()
            try await Concurrency.converge(world, [a, c], "scenario 7")
            let state = try await Self.state(a, ids[0])
            #expect(state.playState != .played)
            #expect(state.positionMilliseconds == 30_000)
            #expect(try await a.view().queue.contains(try #require(try await a.store.wireEpisodeForTesting(ids[0]))), "still queued")
        }
    }

    /// 8a. A pauses at 100 s; B continues to 300 s; A adopts 300 s and the person resumes on A to 450 s: every device
    /// resumes at 450 s, and statistics count A's 0→100, B's 100→300 and A's 300→450 only (the jump is not listening).
    @Test func scenario8aAdoptionThenResume() async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, ids, _) = try await Concurrency.twoPhones(world)
            let onB = try await Concurrency.same(ids[0], from: a, on: b)
            let playerA = StorePlayer(a.store, realTime: ())
            try await playerA.load(ids[0]); try await playerA.play(); try await playerA.listen(100, every: 50); try await playerA.pause()
            await a.exchange(); await b.exchange()
            let playerB = StorePlayer(b.store, realTime: ())
            try await playerB.load(onB); try await playerB.play(); try await playerB.listen(200, every: 50); try await playerB.pause()
            await b.exchange(); await a.exchange()
            let before = try await Self.state(a, ids[0])
            #expect(before.playedDurationMilliseconds == 300_000, "B's listening shows on A's paused player")
            #expect(try await playerA.adopt() == 300_000)
            let adopted = try await Self.state(a, ids[0])
            #expect(adopted.positionMilliseconds == 300_000 && adopted.playedDurationMilliseconds == 300_000, "the jump adds nothing")
            #expect(adopted.lastPlayedHistoryMilliseconds == before.lastPlayedHistoryMilliseconds, "nor a history time")
            try await playerA.play(); try await playerA.listen(150, every: 50); try await playerA.pause()
            await a.exchange(); await b.exchange()
            #expect(try await playerB.adopt() == 450_000)
            try await Concurrency.converge(world, [a, b], "scenario 8a")
            for (phone, id) in [(a, ids[0]), (b, onB)] {
                let state = try await Self.state(phone, id)
                #expect(state.positionMilliseconds == 450_000 && state.playedDurationMilliseconds == 450_000, "\(phone.name)")
            }
        }
    }

    /// 8b, 31 (second part). B takes over from A's paused session before A's lazy finalization in the deterministic
    /// order, without observing it; A's finalization reaches the server first or second. With no other played mark the
    /// episode is unplayed at B's position and queued in both cases.
    @Test(arguments: [true, false]) func scenario8bATakeoverBeforeALazyFinalization(finalizationFirst: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, ids, _) = try await Concurrency.twoPhones(world)
            let onB = try await Concurrency.same(ids[0], from: a, on: b)
            var playerA = StorePlayer(a.store, realTime: ())
            try await playerA.load(ids[0], at: 560_000); try await playerA.play(); try await playerA.listen(30, every: 10); try await playerA.pause()
            await a.exchange(); await b.exchange()
            // A's app is closed and opened again: its player is restored paused, the session finalizable.
            try await a.relaunch()
            playerA = try await StorePlayer.restored(a.store)
            let playerB = StorePlayer(b.store, realTime: ())
            try await playerB.load(onB, at: 100_000); try await playerB.play(); try await playerB.listen(10, every: 10); try await playerB.pause()
            try await playerA.load(ids[1]) // the switch finalizes, completed (A's position is within the threshold)
            if finalizationFirst { await a.exchange(); await b.exchange() } else { await b.exchange(); await a.exchange() }
            try await Concurrency.converge(world, [a, b], "scenario 8b")
            let state = try await Self.state(a, ids[0])
            #expect(state.playState != .played, "the takeover ordered before it suppresses the completion")
            #expect(state.positionMilliseconds == 110_000)
            #expect(try await a.view().queue.contains(try #require(try await a.store.wireEpisodeForTesting(ids[0]))))
        }
    }

    /// 8c. Two offline phones each reset statistics after listening: neither phone's listening before its own reset is
    /// counted; listening after it is.
    @Test func scenario8cTwoOfflineResetsCountNothingBeforeThem() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let onC = try await Concurrency.same(ids[0], from: a, on: c)
            let playerA = StorePlayer(a.store, realTime: ()), playerC = StorePlayer(c.store, realTime: ())
            try await playerA.load(ids[0]); try await playerA.play(); try await playerA.listen(100, every: 50); try await playerA.pause()
            try await playerC.load(onC); try await playerC.play(); try await playerC.listen(200, every: 50); try await playerC.pause()
            try await a.store.resetPlayedDurationStatistics()
            try await c.store.resetPlayedDurationStatistics()
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 0)
            await a.exchange(); await c.exchange()
            #expect(try await Self.state(c, onC).playedDurationMilliseconds == 0, "A's listening was covered by A's own reset")
            try await playerC.play(); try await playerC.listen(20, every: 10); try await playerC.pause()
            #expect(try await Self.state(c, onC).playedDurationMilliseconds == 20_000, "listening after the resets counts")
            await c.exchange(); await a.exchange()
            _ = try await playerA.adopt()
            try await Concurrency.converge(world, [a, c], "scenario 8c")
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 20_000)
        }
    }

    /// 8d. Starting at 100 s, playing to 150 s, rewinding to 50 s while playing, playing to 80 s and switching episodes
    /// counts 50 s, as Android 3.12.1 does (PROTOCOL §8.8: the contribution freezes below the session's start), here and on the
    /// server.
    @Test func scenario8dARewindBelowTheStartThenASwitch() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(ids[0], at: 100_000); try await player.play(); try await player.listen(50, every: 10)
            try await player.seek(to: 50_000)
            try await player.listen(30, every: 10)
            try await player.load(ids[1]) // the switch
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 50_000)
            await a.exchange()
            try await Concurrency.converge(world, [a, c], "scenario 8d")
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 50_000)
            #expect(try await Self.state(c, try await Concurrency.same(ids[0], from: a, on: c)).playedDurationMilliseconds == 50_000)
        }
    }

    /// 31 (first part). Finished normally, the completion is seen everywhere; replaying without marking unplayed keeps
    /// it PLAYED (a new session that follows a completion does not undo it).
    @Test func scenario31ReplayingAPlayedEpisodeKeepsItPlayed() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let onC = try await Concurrency.same(ids[0], from: a, on: c)
            let playerA = StorePlayer(a.store, realTime: ())
            try await playerA.load(ids[0], at: 590_000); try await playerA.play(); try await playerA.listen(10, every: 10)
            #expect(try await playerA.end(.ended)?.markedPlayed == true)
            await a.exchange(); await c.exchange()
            #expect(try await Self.state(c, onC).playState == .played)
            let playerC = StorePlayer(c.store, realTime: ())
            try await playerC.load(onC); try await playerC.play(); try await playerC.listen(30, every: 10); try await playerC.pause()
            await c.exchange(); await a.exchange()
            try await Concurrency.converge(world, [a, c], "scenario 31")
            let state = try await Self.state(a, ids[0])
            #expect(state.playState == .played && state.positionMilliseconds == 30_000)
        }
    }

    /// 31 (third part). An explicit position reset elsewhere, ordered before A's lazy completion, suppresses it.
    @Test func scenario31ARemoteResetBeforeALazyCompletionSuppressesIt() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            var playerA = StorePlayer(a.store, realTime: ())
            try await playerA.load(ids[0], at: 560_000); try await playerA.play(); try await playerA.listen(30, every: 10); try await playerA.pause()
            await a.exchange(); await c.exchange()
            try await a.relaunch()
            playerA = try await StorePlayer.restored(a.store)
            try await c.store.resetPlaybackPosition(episodeID: try await Concurrency.same(ids[0], from: a, on: c))
            await c.exchange()
            // A's finalization is decided after the reset (A has not seen it): the reset is ordered before it.
            try await playerA.load(ids[1])
            await a.exchange()
            try await Concurrency.converge(world, [a, c], "scenario 31 reset")
            let state = try await Self.state(a, ids[0])
            #expect(state.playState == .unplayed && state.positionMilliseconds == 0)
            #expect(try await a.view().queue.contains(try #require(try await a.store.wireEpisodeForTesting(ids[0]))),
                    "the suppressed completion did not take it out of the queue")
        }
    }

    /// 36. Reset at 20 s, rewind to 10 s, reset again, then advance to 15 s: 5 s count, as the server folds it.
    @Test func scenario36ResetsAndARewind() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(ids[0]); try await player.play(); try await player.listen(20, every: 10); try await player.pause()
            try await a.store.resetPlayedDurationStatistics()
            try await player.seek(to: 10_000)
            try await player.play(); try await player.pause()
            try await a.store.resetPlayedDurationStatistics()
            try await player.play(); try await player.listen(5); try await player.pause()
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 5_000)
            await a.exchange()
            try await Concurrency.converge(world, [a, c], "scenario 36")
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 5_000)
        }
    }

    ///: reset at 20 s, advance to 25 s, rewind to 15 s: nothing counts (`max(0, 15 − 20)`), as the server
    /// computes; Android's rebased baseline would show 5 s.
    @Test func aResetThenARewindBelowItCountsNothing() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(ids[0]); try await player.play(); try await player.listen(20, every: 10)
            try await a.store.resetPlayedDurationStatistics()
            try await player.listen(5)
            try await player.seek(to: 15_000)
            try await player.listen(0); try await player.pause()
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 0)
            await a.exchange()
            try await Concurrency.converge(world, [a, c], "reset and rewind")
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 0)
        }
    }

    /// 37. Listen 0→100 s, restart the player, rewind to 50 s and save: the total stays 100 s. Pause near the end,
    /// relaunch and start another episode: the lazy finalization completes once.
    @Test func scenario37ARestartedPlayerAndALazyCompletion() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            var player = StorePlayer(a.store, realTime: ())
            try await player.load(ids[0]); try await player.play(); try await player.listen(100, every: 50); try await player.pause()
            try await player.load(ids[0], at: 50_000); try await player.play(); try await player.pause()
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 100_000, "a rewind below the new baseline adds nothing")
            try await player.load(ids[0], at: 575_000); try await player.play(); try await player.listen(10, every: 10); try await player.pause()
            await a.exchange()
            try await a.relaunch()
            player = try await StorePlayer.restored(a.store)
            try await player.load(ids[1])
            await a.exchange()
            try await Concurrency.converge(world, [a, c], "scenario 37")
            let state = try await Self.state(a, ids[0])
            #expect(state.playState == .played && state.positionMilliseconds == 0)
            #expect(state.playedDurationMilliseconds == 100_000 + 10_000)
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox") == [["0"]], "the finalization was sent once, and retired")
        }
    }

    /// 41. A remote unsubscribe while this phone plays: playing continues from the pinned episode, the podcast leaves
    /// every list at once, the remaining listening is recorded (the server does not apply it, PROTOCOL §7.2), and the podcast's
    /// rows go when the player leaves the episode.
    @Test func scenario41ARemoteUnsubscribeWhilePlaying() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, feed, ids, podcast) = try await Concurrency.twoPhones(world)
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(ids[0]); try await player.play(); try await player.listen(60, every: 30)
            await a.exchange()
            #expect(try await c.store.requestFeedDeletion(feedID: try await Concurrency.feed(of: podcast, on: c)))
            await c.exchange()
            a.playing.value = true
            await a.run([.pull, .apply])
            #expect(try await a.store.feeds().contains { $0.id == feed.id } == false, "shared state hides at once")
            try await player.listen(60, every: 30); try await player.pause()
            #expect(try await a.store.episode(id: ids[0]) != nil, "the player keeps its episode")
            a.playing.value = false
            await a.exchange()
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox") == [["0"]], "the later listening was sent, and retired")
            try await player.end(.skipped) // the player leaves the episode
            await a.exchange()
            #expect(try await a.store.episode(id: ids[0]) == nil, "the podcast's rows went once the player left")
            #expect(try await a.store.feeds().isEmpty)
            try await Concurrency.converge(world, [a, c], "scenario 41")
        }
    }

    /// 43. A exits paused at 100 s; B reaches 300 s. A relaunched without pulling first, and separately after pulling
    /// B: the passive restore records nothing; after sync the shared position is still 300 s; A's deliberate resume
    /// adopts 300 s and then advances it.
    @Test(arguments: [true, false]) func scenario43ARelaunchedPausedPlayer(pullFirst: Bool) async throws {
        try await ExchangeWorld.run { world in
            let (a, b, _, ids, _) = try await Concurrency.twoPhones(world)
            let onB = try await Concurrency.same(ids[0], from: a, on: b)
            var playerA = StorePlayer(a.store, realTime: ())
            try await playerA.load(ids[0]); try await playerA.play(); try await playerA.listen(100, every: 50); try await playerA.pause()
            await a.exchange(); await b.exchange()
            let playerB = StorePlayer(b.store, realTime: ())
            try await playerB.load(onB); try await playerB.play(); try await playerB.listen(200, every: 50); try await playerB.pause()
            await b.exchange()
            if pullFirst { await a.exchange() }
            try await a.relaunch()
            let outbox = try a.rows("SELECT count(*) FROM ntp_outbox")
            playerA = try await StorePlayer.restored(a.store)
            try await a.store.flushServerPlayback()
            #expect(try a.rows("SELECT count(*) FROM ntp_outbox") == outbox, "the passive restore records nothing")
            await a.exchange()
            #expect(try await Self.state(b, onB).positionMilliseconds == 300_000, "the shared position is still B's")
            #expect(try await playerA.adopt() == 300_000, "the restored player adopts")
            let sealed = try a.rows("SELECT type FROM ntp_outbox ORDER BY install_seq")
            #expect(sealed.allSatisfy { $0 == ["session.end"] }, "only the seal, no ownership, queue, Inbox or history fact: \(sealed)")
            try await playerA.load(ids[0]); try await playerA.play(); try await playerA.listen(50, every: 50); try await playerA.pause()
            await a.exchange(); await b.exchange()
            #expect(try await playerB.adopt() == 350_000)
            try await Concurrency.converge(world, [a, b], "scenario 43")
            #expect(try await Self.state(a, ids[0]).positionMilliseconds == 350_000)
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 350_000)
        }
    }

    /// 44. A standalone library's playback is never recorded: its listening stays in the standalone library, and
    /// nothing reaches a server library (the switch waits for playback to stop).
    @Test func scenario44StandalonePlaybackStaysStandalone() async throws {
        let fixture = try await ServerLibraryFixture(server: false)
        defer { Task { await fixture.close() } }
        let feed = try await fixture.store.insert(ServerLibraryFixture.fetched())
        let player = StorePlayer(fixture.store)
        try await player.load(feed.episodes[0].id, at: 600_000 - 30_000)
        try await player.play(); try await player.listen(30, every: 10)
        #expect(try await player.end(.ended)?.markedPlayed == true)
        #expect(try fixture.rows("SELECT (SELECT count(*) FROM ntp_sessions) + (SELECT count(*) FROM ntp_outbox) + (SELECT count(*) FROM ntp_library)") == [["0"]])
    }
}

extension ServerPlaybackScenarioTests {
    // MARK: - Named agreement cases

    /// A completion overlay whose claim was taken over remotely: A's end completes under its session's claim, but C's
    /// later start arrives before A's end is sent; A shows the base (C's position, unplayed), as the server folds it.
    @Test func aCompletionWhoseClaimWasTakenOverShowsTheBase() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let onC = try await Concurrency.same(ids[0], from: a, on: c)
            let playerA = StorePlayer(a.store, realTime: ())
            try await playerA.load(ids[0], at: 560_000); try await playerA.play(); try await playerA.listen(20, every: 10); try await playerA.pause()
            await a.exchange(); await c.exchange()
            let playerC = StorePlayer(c.store, realTime: ())
            try await playerC.load(onC, at: 0); try await playerC.play(); try await playerC.listen(20, every: 10); try await playerC.pause()
            await c.exchange()
            try await playerA.load(ids[1]) // A's end completes, pending
            #expect(try await Self.state(a, ids[0]).playState == .played)
            await a.run([.pull, .apply])
            let shown = try await Self.state(a, ids[0])
            #expect(shown.playState == .unplayed && shown.positionMilliseconds == 20_000, "the completion's claim no longer holds")
            try await Concurrency.converge(world, [a, c], "completion taken over")
            #expect(try await Self.state(a, ids[0]) .playState == .unplayed)
        }
    }

    /// Other sessions total 10 s; this phone's retired 20 s are covered by a remote reset; a pending rewind to 15 s
    /// shows `10 + max(0, 15 − 20)` = 10 s, as the server will fold it (PROTOCOL §8.8).
    @Test func aRemoteResetOverARetiredContributionAndAPendingRewind() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let d = try await world.attach("D")
            let onC = try await Concurrency.same(ids[0], from: a, on: c)
            let playerA = StorePlayer(a.store, realTime: ())
            try await playerA.load(ids[0]); try await playerA.play(); try await playerA.listen(20, every: 10); try await playerA.pause()
            await a.exchange(); await d.exchange()
            // D resets having seen A's 20 s; C listens 10 s, unseen by D.
            try await d.store.resetPlayedDurationStatistics()
            await d.exchange()
            let playerC = StorePlayer(c.store, realTime: ())
            try await playerC.load(onC, at: 300_000); try await playerC.play(); try await playerC.listen(10, every: 10); try await playerC.pause()
            await c.exchange()
            await a.exchange()
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 10_000, "C's 10 s; A's 20 s are cut")
            // A, still on its own session (the adoption has not happened: A plays), rewinds to 15 s and saves.
            try await playerA.seek(to: 15_000)
            try await playerA.play(); try await playerA.pause()
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 10_000, "10 + max(0, 15 − 20)")
            await a.exchange(); await c.exchange()
            #expect(try await playerC.adopt() == 15_000, "A's resume claimed last")
            try await Concurrency.converge(world, [a, c, d], "remote reset over a retired contribution")
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 10_000)
        }
    }

    /// A paused player receiving a larger remote played total shows it, and its next save never writes back an older
    /// total from its own baseline (PROTOCOL §8.8).
    @Test func aPausedPlayerReceivesALargerRemoteTotal() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let onC = try await Concurrency.same(ids[0], from: a, on: c)
            let playerA = StorePlayer(a.store, realTime: ())
            try await playerA.load(ids[0]); try await playerA.play(); try await playerA.listen(100, every: 50); try await playerA.pause()
            await a.exchange(); await c.exchange()
            let playerC = StorePlayer(c.store, realTime: ())
            try await playerC.load(onC, at: 100_000); try await playerC.play(); try await playerC.listen(300, every: 60); try await playerC.pause()
            await c.exchange(); await a.exchange()
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 400_000)
            try await playerA.pause() // a save of the paused player
            #expect(try await Self.state(a, ids[0]).playedDurationMilliseconds == 400_000, "never an older total")
            _ = try await playerA.adopt()
            try await Concurrency.converge(world, [a, c], "larger remote total")
        }
    }

    /// A takeover seek (PROTOCOL §8.6) while another device's newer claim waits, and a resume paused again within 5 s after an
    /// adoption: both claim, and every device follows.
    @Test func aTakeoverSeekAndAResumePausedWithinFiveSeconds() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let onC = try await Concurrency.same(ids[0], from: a, on: c)
            let playerA = StorePlayer(a.store, realTime: ())
            try await playerA.load(ids[0]); try await playerA.play(); try await playerA.listen(60, every: 30)
            await a.exchange(); await c.exchange()
            let playerC = StorePlayer(c.store, realTime: ())
            try await playerC.load(onC, at: 200_000); try await playerC.play(); try await playerC.listen(30, every: 30); try await playerC.pause()
            await c.exchange()
            a.playing.value = true
            await a.exchange()
            a.playing.value = false
            #expect(try await Self.state(a, ids[0]).positionMilliseconds == 60_000, "sync never moves playing audio")
            try await playerA.seek(to: 400_000)
            try await playerA.listen(10, every: 5); try await playerA.pause()
            let types = try a.rows("SELECT type FROM ntp_outbox ORDER BY install_seq").map { $0[0] ?? "" }
            #expect(types == ["session.end", "session.start", "session.checkpoint"], "\(types)")
            await a.exchange(); await c.exchange()
            #expect(try await playerC.adopt() == 410_000)
            // C resumes and pauses again within 5 s: its start is recorded at the resume.
            try await playerC.play(); try await playerC.listen(3, every: 3); try await playerC.pause()
            await c.exchange(); await a.exchange()
            #expect(try await playerA.adopt() == 413_000)
            try await Concurrency.converge(world, [a, c], "takeover and resume")
            #expect(try await Self.state(a, ids[0]).positionMilliseconds == 413_000)
        }
    }

    /// A paused player follows the claim it adopted: another device's later checkpoint under that claim moves it again,
    /// while a seek the person makes while paused is never undone by sync.
    @Test func aPausedPlayerFollowsLaterCheckpointsOfTheClaimItAdopted() async throws {
        try await ExchangeWorld.run { world in
            let (a, c, _, ids, _) = try await Concurrency.twoPhones(world)
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(ids[0]); try await player.play(); try await player.listen(30, every: 10); try await player.pause()
            await a.exchange(); await c.exchange()
            var other = RemoteSession(store: c.store, episode: try await Concurrency.same(ids[0], from: a, on: c))
            try await other.start(at: 600_000)
            await c.exchange(); await a.exchange()
            #expect(try await player.adopt() == 600_000)
            try await other.checkpoint(position: 900_000, contribution: 300_000)
            await c.exchange(); await a.exchange()
            #expect(try await player.adopt() == 900_000, "a later checkpoint of the adopted claim")
            // The person moves the paused player: sync leaves it there.
            try await player.seek(to: 120_000)
            try await player.pause()
            await a.exchange()
            #expect(try await player.adopt() == nil)
            #expect(try await Self.state(a, ids[0]).positionMilliseconds == 120_000)
        }
    }

    /// Deferred cuts over drafts (PROTOCOL §15.2): a statistics reset while a subscription waits for the server covers the
    /// listening recorded as drafts before it and nothing after.
    @Test func aDeferredResetCoversTheDraftListeningBeforeIt() async throws {
        try await ExchangeWorld.run { world in
            let a = try await world.attach("A")
            world.server.stop(keepingData: true)
            let two = try await a.store.insert(ServerExchangeAgreementTests.fetched(world.url("two.xml"), title: "Two", prefix: "two", count: 3))
            let episode = two.episodes.map(\.id).min()!
            let player = StorePlayer(a.store, realTime: ())
            try await player.load(episode); try await player.play(); try await player.listen(100, every: 50); try await player.pause()
            try await a.store.resetPlayedDurationStatistics()
            try await player.play(); try await player.listen(50, every: 50); try await player.pause()
            #expect(try await Self.state(a, episode).playedDurationMilliseconds == 50_000)
            try await world.server.launch()
            try await ServerExchangeAgreementTests.waitForCatalog(a, feedID: two.id)
            await a.exchange()
            #expect(try a.rows("SELECT count(*) FROM ntp_drafts") == [["0"]])
            let b = try await world.attach("B")
            try await Concurrency.converge(world, [a, b], "deferred reset over drafts")
            #expect(try await Self.state(a, episode).playedDurationMilliseconds == 50_000)
        }
    }
}
