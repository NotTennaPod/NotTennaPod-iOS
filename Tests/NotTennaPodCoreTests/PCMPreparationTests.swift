import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) @MainActor struct PCMPreparationTests {
    typealias Gate = PCMPlaybackEngineTests.DurationGate
    typealias Events = PCMSystemSessionTests.SystemEvents

    private func withPreparing(activationGranted: Bool = true, _ body: (FeedLibraryStore, PlaybackCoordinator, PCMPlaybackEngine,
        PCMPlaybackEngineTests.Outputs, PCMPlaybackEngineTests.Driver, Gate, Events) async throws -> Void) async throws {
        let gate = Gate(); let events = Events()
        do {
            try await PCMPlaybackEngineTests().withPlayer(events: events.subscribe, duration: { _ in await gate.duration() }) {
                store, player, engine, outputs, _, driver in
                driver.activationGranted = activationGranted
                try await player.select(episodeID: 1)
                try await gate.waitForCount(1)
                try await wait { driver.requests.contains(true) }
                try await player.awaitPendingOperations()
                #expect(player.phase == .preparing && player.wantsPlayback == activationGranted)
                #expect(engine.reading?.isPrepared == false)
                #expect(outputs.values.allSatisfy { !$0.playing })
                try await body(store, player, engine, outputs, driver, gate, events)
            }
        } catch { await gate.releaseAll(); throw error }
        await gate.releaseAll()
    }

    @Test func declinedActivationLeavesPreparedMediaPausedAndAllowsExplicitRetry() async throws {
        try await withPreparing(activationGranted: false) { store, player, engine, outputs, driver, gate, _ in
            await gate.release(0)
            try await wait { player.phase == .paused }
            #expect(engine.reading?.isPrepared == true)
            #expect(!player.wantsPlayback && engine.reading != nil && !outputs.values[0].playing)
            #expect(try await store.episode(id: 1)?.userState.playState != .played)
            driver.activationGranted = true
            try await player.play()
            try await wait { player.phase == .playing && outputs.values[0].playing }
            #expect(outputs.values.count == 1)
        }
    }

    @Test func preReadySeekPreservesKnownMetadataAndPauseIntent() async throws {
        try await withPreparing { _, player, engine, _, _, gate, _ in
            #expect(engine.reading?.sample.durationMilliseconds == -1 && player.sample?.durationMilliseconds == 600)
            try await player.seek(to: 300)
            try await gate.waitForCount(2)
            #expect(player.sample?.positionMilliseconds == 300 && engine.reading?.sample.positionMilliseconds == 300)
            #expect(player.sample?.durationMilliseconds == 600)
            try await player.pause()
            await gate.release(1)
            try await wait { player.phase == .paused }
            #expect(engine.reading?.isPrepared == true)
            #expect(engine.reading?.sample.durationMilliseconds == 600)
        }
    }

    @Test func preReadyForwardIntervalBeyondKnownEndCompletesInsteadOfPreparingAgain() async throws {
        try await withPreparing { store, player, engine, outputs, _, _, _ in
            #expect(engine.reading?.sample.durationMilliseconds == -1 && player.sample?.durationMilliseconds == 600)
            try await player.skipInterval(seconds: 10)
            #expect(player.phase == .idle && player.episode == nil && !player.wantsPlayback)
            #expect(engine.reading == nil)
            #expect(outputs.values.allSatisfy { !$0.playing })
            #expect(try await store.episode(id: 1)?.userState.playState == .played)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 0)
            #expect(try await store.queue().isEmpty == true)
            #expect(try await store.playbackSession() == nil)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func readinessPreservesInterruptionAndResumptionIntent(resumeBeforeReady: Bool, shouldResume: Bool) async throws {
        try await withPreparing { store, player, engine, outputs, _, gate, events in
            events.post(.interrupted(reason: 0))
            try await player.awaitPendingOperations()
            #expect(player.phase == .preparing && !player.wantsPlayback)
            #expect(try await store.episode(id: 1)?.userState.lastPlayedTimeMilliseconds == 0)
            if resumeBeforeReady { events.post(.resumptionRecommended(shouldResume)) }
            await gate.release(0)
            try await wait { player.phase != .preparing }
            if !resumeBeforeReady {
                #expect(player.phase == .paused && !player.wantsPlayback && !outputs.values[0].playing)
                events.post(.resumptionRecommended(shouldResume))
            }
            try await wait { player.phase == (shouldResume ? .playing : .paused) }
            #expect(outputs.values.count == 1 && outputs.values[0].playing == shouldResume)
            #expect(player.wantsPlayback == shouldResume && engine.reading?.sample.positionMilliseconds == 0)
            #expect(await gate.requestCount() == 1) // No-op rewind waits for initial preparation.
        }
    }

    enum UserAction: Sendable { case pause, play, pauseThenPlay }
    @Test(arguments: [UserAction.pause, .play, .pauseThenPlay])
    func explicitCommandsDuringInterruptedPreparationTakePrecedence(action: UserAction) async throws {
        try await withPreparing { _, player, _, outputs, _, gate, events in
            events.post(.interrupted(reason: 0))
            try await player.awaitPendingOperations()
            if action != .play { try await player.pause() }
            if action != .pause { try await player.play() }
            events.post(.resumptionRecommended(true))
            await gate.release(0)
            let playing = action != .pause
            try await wait { player.phase == (playing ? .playing : .paused) }
            #expect(player.wantsPlayback == playing && outputs.values[0].playing == playing)
            #expect(outputs.values.count == 1)
            #expect(await gate.requestCount() == 1)
        }
    }

    @Test func seekBeforeReadyRetainsSuppressionAndNoOpRecoveryAwaitsLatestSeek() async throws {
        try await withPreparing { _, player, engine, outputs, _, gate, events in
            events.post(.interrupted(reason: 0))
            try await player.awaitPendingOperations()
            try await player.seek(to: 300)
            try await gate.waitForCount(2)
            #expect(engine.reading?.sample.positionMilliseconds == 300 && !player.wantsPlayback)
            events.post(.resumptionRecommended(true))
            await gate.release(1)
            try await wait { player.phase == .playing }
            #expect(engine.reading?.sample.positionMilliseconds == 300)
            #expect(outputs.values.last?.playing == true)
            #expect(await gate.requestCount() == 2)
            let current = engine.reading
            await gate.release(0)
            try await player.awaitPendingOperations()
            #expect(engine.reading == current)
        }
    }

    @Test(arguments: [false, true])
    func replacementBeforeReadyRejectsOldInterruptionAndCompletion(play: Bool) async throws {
        try await withPreparing { _, player, engine, outputs, driver, gate, events in
            try await wait { outputs.values.count == 1 }
            events.post(.interrupted(reason: 0))
            try await player.awaitPendingOperations()
            try await player.select(episodeID: 2, play: play)
            try await gate.waitForCount(2)
            await gate.release(1)
            try await wait { player.phase == (play ? .playing : .paused) }
            #expect(outputs.values[0].closed && player.episode?.id == 2 && player.wantsPlayback == play)
            let reading = engine.reading; let requests = driver.requests
            await gate.release(0)
            try await Task.sleep(for: .milliseconds(20))
            try await player.awaitPendingOperations()
            #expect(engine.reading == reading && driver.requests == requests)
            #expect(outputs.values.last?.playing == play)
        }
    }

    private func wait(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition(), sourceLocation: sourceLocation)
    }
}
