import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor struct PlaybackRecoveryControllerTests {
    @MainActor final class Session: PlaybackRecoverySession {
        var positionMilliseconds: Int64 = 25000
        var lastPlayedMilliseconds: Int64 = 1000
        var playing = false
        var plays = 0
        var seeks: [Int64] = []
        var pending: CheckedContinuation<Void, any Error>?
        var closed = false
        var holdStatistics = false
        var statisticsPending: CheckedContinuation<Void, any Error>?
        func synchronizeStatistics() async throws {
            if holdStatistics { try await withCheckedThrowingContinuation { statisticsPending = $0 } }
        }
        func pause() { playing = false }
        func play() { playing = true; plays += 1 }
        func seekPaused(to value: Int64) async throws {
            playing = false
            seeks.append(value)
            try await withCheckedThrowingContinuation { pending = $0 }
            positionMilliseconds = value
        }
        func finishSeek() { let c = pending; pending = nil; c?.resume() }
        func failSeek(_ error: any Error) { let c = pending; pending = nil; c?.resume(throwing: error) }
        func close() { closed = true; playing = false; let c = pending; pending = nil; c?.resume(throwing: CancellationError()) }
    }
    typealias Driver = AudioSessionActivationControllerTests.Driver

    enum PendingOutcome: Sendable { case complete, fail, close }
    enum PreparationFailure: Error { case decoder }

    @Test(arguments: [PendingOutcome.complete, .fail, .close])
    func noOpSuppressionClearRetainsPendingPreparationAndPropagatesItsOutcome(outcome: PendingOutcome) async throws {
        let session = Session(); session.positionMilliseconds = 0; session.lastPlayedMilliseconds = 0
        let driver = PCMPlaybackEngineTests.Driver()
        let activation = AudioSessionActivationController(driver: driver)
        let controller = PlaybackRecoveryController(session: session, activation: activation, now: { 5000 })
        try controller.seek(to: 0)
        try controller.play()
        try await wait { session.pending != nil && activation.knownActive == true }
        #expect(session.plays == 0)
        controller.receive(.interrupted(reason: 0))
        controller.receive(.resumptionRecommended(true))
        await Task.yield()
        #expect(session.seeks == [0] && session.pending != nil && session.plays == 0)
        switch outcome {
        case .complete:
            session.finishSeek()
            try await wait { controller.state == .playing }
            #expect(session.plays == 1 && controller.failure == nil)
        case .fail:
            session.failSeek(PreparationFailure.decoder)
            try await wait { controller.state == .failed }
            #expect(controller.failure as? PreparationFailure == .decoder && session.plays == 0)
        case .close:
            controller.close()
            await Task.yield()
            #expect(controller.state == .closed && controller.failure == nil && session.pending == nil)
            #expect(session.plays == 0)
        }
        controller.close()
    }

    @Test(arguments: [false, true])
    func interruptionRewindsBeforePlaybackRegardlessOfActivationOrder(activationFirst: Bool) async throws {
        let s = Session(); let d = Driver(); let a = AudioSessionActivationController(driver: d)
        let c = PlaybackRecoveryController(session: s, activation: a, now: { 62001 })
        try c.play(); try await wait { d.pending != nil }; d.complete()
        try await wait { s.playing }
        c.receive(.interrupted(reason: 0))
        #expect(!s.playing && c.wantsPlayback && c.state == .interrupted)
        c.receive(.resumptionRecommended(true))
        try await wait { s.pending != nil && d.pending != nil }
        #expect(s.seeks == [22000] && s.plays == 1)
        if activationFirst {
            d.complete(); await Task.yield(); #expect(!s.playing)
            s.finishSeek()
        } else {
            s.finishSeek(); await Task.yield(); #expect(!s.playing)
            d.complete()
        }
        try await wait { s.playing }
        #expect(s.positionMilliseconds == 22000 && s.plays == 2)
        c.receive(.resumptionRecommended(true))
        #expect(s.seeks == [22000] && s.plays == 2)
        c.close(); try await wait { d.pending != nil }; d.complete()
    }

    @Test func pauseDuringRecoverySeekNeverRestartsPlayback() async throws {
        let s = Session(); let d = Driver(); let a = AudioSessionActivationController(driver: d)
        let c = PlaybackRecoveryController(session: s, activation: a, now: { 62001 })
        try c.play(); try await wait { d.pending != nil }; d.complete(); try await wait { s.playing }
        c.receive(.interrupted(reason: 0)); c.receive(.resumptionRecommended(true))
        try await wait { s.pending != nil && d.pending != nil }
        try c.pause()
        // The activation already requested completes; a paused player keeps the session.
        d.complete(); try await wait { a.knownActive == true }
        s.finishSeek(); try await wait { c.state == .paused }
        #expect(s.plays == 1 && !c.wantsPlayback && s.positionMilliseconds == 22000)
        #expect(d.requests == [true, true] && d.pending == nil)
        c.close(); try await wait { d.pending != nil }; d.complete()
        #expect(d.requests == [true, true, false])
    }

    @Test func pauseDuringInterruptionStillRewindsButDoesNotRequestReactivation() async throws {
        let s = Session(); let d = Driver(); let a = AudioSessionActivationController(driver: d)
        let c = PlaybackRecoveryController(session: s, activation: a, now: { 62001 })
        try c.play(); try await wait { d.pending != nil }; d.complete(); try await wait { s.playing }
        c.receive(.interrupted(reason: 0)); try c.pause()
        c.receive(.resumptionRecommended(true)); try await wait { s.pending != nil }
        s.finishSeek(); try await wait { c.state == .paused }
        #expect(s.seeks == [22000] && !s.playing && d.requests == [true])
        c.close()
    }

    @Test func routeDisconnectClearsIntentAndReconnectDoesNotAutoplay() async throws {
        let s = Session(); let d = Driver(); let a = AudioSessionActivationController(driver: d)
        let c = PlaybackRecoveryController(session: s, activation: a, now: { 62001 })
        try c.play(); try await wait { d.pending != nil }; d.complete(); try await wait { s.playing }
        c.receive(.routeChanged(reason: 2))
        try await wait { c.state == .paused }
        c.receive(.routeChanged(reason: 1)); c.receive(.resumptionRecommended(true))
        #expect(!c.wantsPlayback && !s.playing && s.plays == 1 && s.seeks.isEmpty)
        // Paused by the disconnect, it keeps the session like any pause.
        #expect(d.requests == [true] && d.pending == nil && a.knownActive == true)
        c.close(); try await wait { d.pending != nil }; d.complete()
    }

    /// As Media3 keeps audio focus while paused, pausing keeps the session, so playing
    /// again needs no new activation; closing or failing releases it.
    @Test(arguments: [false, true])
    func pauseKeepsTheSessionAndOnlyStopOrFailureReleasesIt(failure: Bool) async throws {
        let s = Session(); let d = Driver(); let a = AudioSessionActivationController(driver: d)
        let c = PlaybackRecoveryController(session: s, activation: a, now: { 62001 })
        try c.play(); try await wait { d.pending != nil }; d.complete(); try await wait { s.playing }
        for _ in 0..<3 {
            try c.pause()
            #expect(!s.playing && c.state == .paused)
            try c.play(); try await wait { s.playing }
        }
        try c.pause(); await Task.yield()
        #expect(d.requests == [true] && d.pending == nil && a.knownActive == true && s.plays == 4)
        if failure {
            // A failed seek is a failure of this playback: the session is released.
            try c.seek(to: 1000); try await wait { s.pending != nil }
            s.failSeek(PreparationFailure.decoder)
            try await wait { c.state == .failed && d.pending != nil }
        } else {
            c.close(); try await wait { d.pending != nil }
        }
        #expect(d.requests == [true, false]); d.complete()
        try await wait { a.knownActive == false }
        c.close()
    }

    @Test func disabledDisconnectPreferenceKeepsExistingPlaybackWithoutDuplicatePlay() async throws {
        let s = Session(); let d = Driver(); let a = AudioSessionActivationController(driver: d)
        let c = PlaybackRecoveryController(session: s, activation: a, pauseOnDisconnect: false, now: { 62001 })
        try c.play(); try await wait { d.pending != nil }; d.complete(); try await wait { s.playing }
        for reason: UInt64 in [2, 1, 3, 4, 999] { c.receive(.routeChanged(reason: reason)) }
        #expect(c.state == .playing && s.plays == 1 && d.requests == [true])
        c.close(); try await wait { d.pending != nil }; d.complete()
    }

    @Test func closeFencesPendingActivationAndSeek() async throws {
        let s = Session(); let d = Driver(); let a = AudioSessionActivationController(driver: d)
        let c = PlaybackRecoveryController(session: s, activation: a, now: { 62001 })
        try c.play(); try await wait { d.pending != nil }; d.complete(); try await wait { s.playing }
        c.receive(.interrupted(reason: 0)); c.receive(.resumptionRecommended(true))
        try await wait { s.pending != nil && d.pending != nil }
        c.close(); d.complete()
        try await wait { d.requests.last == false && d.pending != nil }; d.complete()
        await Task.yield()
        #expect(c.state == .closed && s.closed && !c.wantsPlayback && s.plays == 1)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }

    @Test(arguments: [false, true]) func deniedOrFailedActivationCannotPlay(throwsError: Bool) async throws {
        let s = Session(); let d = Driver(); let a = AudioSessionActivationController(driver: d)
        let c = PlaybackRecoveryController(session: s, activation: a, now: { 62001 })
        try c.play(); try await wait { d.pending != nil }
        if throwsError { d.fail() } else { d.complete(false) }
        if throwsError {
            try await wait { c.state == .failed && d.pending != nil }
            #expect(!c.wantsPlayback && s.plays == 0 && c.failure != nil)
            d.complete(); c.receive(.becameActive); c.receive(.resumptionRecommended(true))
            #expect(s.plays == 0 && c.state == .failed)
            c.close()
        } else {
            try await wait { c.state == .paused }
            #expect(!c.wantsPlayback && s.plays == 0 && c.failure == nil && d.requests == [true])
            c.receive(.becameActive); c.receive(.resumptionRecommended(true))
            #expect(s.plays == 0 && c.state == .paused)
            try c.play(); try await wait { s.playing }
            #expect(s.plays == 1 && c.failure == nil)
            c.close(); try await wait { d.pending != nil }; d.complete()
        }
    }

    @Test func negativeRecommendationClearsIntentButRetainsSuppressionClearRewind() async throws {
        let s = Session(); let d = Driver(); let a = AudioSessionActivationController(driver: d)
        let c = PlaybackRecoveryController(session: s, activation: a, now: { 62001 })
        try c.play(); try await wait { d.pending != nil }; d.complete(); try await wait { s.playing }
        c.receive(.interrupted(reason: 0)); c.receive(.resumptionRecommended(false))
        try await wait { s.pending != nil }; s.finishSeek(); try await wait { c.state == .paused }
        #expect(!c.wantsPlayback && s.plays == 1 && s.seeks == [22000] && d.requests == [true])
        c.close()
    }

    @Test func newerInterruptionPreventsInFlightRecoveryFromStarting() async throws {
        let s = Session(); let d = Driver(); let a = AudioSessionActivationController(driver: d)
        let c = PlaybackRecoveryController(session: s, activation: a, now: { 62001 })
        try c.play(); try await wait { d.pending != nil }; d.complete(); try await wait { s.playing }
        c.receive(.interrupted(reason: 0)); c.receive(.resumptionRecommended(true))
        try await wait { s.pending != nil && d.pending != nil }
        c.receive(.interrupted(reason: 0)); d.complete(); s.finishSeek()
        try await wait { c.state == .interrupted }
        #expect(s.plays == 1 && !s.playing && c.wantsPlayback)
        c.receive(.resumptionRecommended(true))
        try await wait { s.pending != nil && d.pending != nil }
        #expect(s.seeks == [22000, 19000])
        d.complete(); s.finishSeek(); try await wait { s.playing }
        c.close(); try await wait { d.pending != nil }; d.complete()
    }

    @Test(arguments: [AudioSessionEvent.mediaServicesLost, .mediaServicesReset])
    func serviceInvalidationRequiresRebuildAndNeverAutoplays(event: AudioSessionEvent) async throws {
        let s = Session(); let d = Driver(); let a = AudioSessionActivationController(driver: d)
        let c = PlaybackRecoveryController(session: s, activation: a, now: { 62001 })
        try c.play(); try await wait { d.pending != nil }; d.complete(); try await wait { s.playing }
        c.receive(event); #expect(c.state == .requiresRebuild && !s.playing)
        try await wait { d.pending != nil }; d.complete()
        c.receive(.becameActive); c.receive(.resumptionRecommended(true))
        #expect(c.state == .requiresRebuild && s.plays == 1)
        #expect(throws: PlaybackRecoveryController.Failure.rebuildRequired) { try c.play() }
        c.close(); try await wait { d.pending != nil }; d.complete()
    }

    @Test func observerClosingAfterSeekCompletionPreventsPlay() async throws {
        let s = Session(); let d = Driver(); let a = AudioSessionActivationController(driver: d)
        let c = PlaybackRecoveryController(session: s, activation: a, now: { 62001 })
        try c.play(); try await wait { d.pending != nil }; d.complete(); try await wait { s.playing }
        try c.play(); #expect(s.plays == 1 && d.requests == [true])
        c.receive(.interrupted(reason: 0)); c.receive(.resumptionRecommended(true))
        try await wait { s.pending != nil && d.pending != nil }
        d.complete(); try await wait { a.knownActive == true }
        c.onChange = { [weak c] in if c?.state == .activating { c?.close() } }
        s.finishSeek(); try await wait { c.state == .closed }
        #expect(s.plays == 1 && s.closed)
        try await wait { d.pending != nil }; d.complete()
    }

    @Test(arguments: [false, true]) func pendingStatisticsGatePreventsStaleRewindAndPlayback(failSave: Bool) async throws {
        let s = Session(); let d = Driver(); let a = AudioSessionActivationController(driver: d)
        let c = PlaybackRecoveryController(session: s, activation: a, now: { 62001 })
        try c.play(); try await wait { d.pending != nil }; d.complete(); try await wait { s.playing }
        s.holdStatistics = true
        c.receive(.interrupted(reason: 0)); c.receive(.resumptionRecommended(true))
        try await wait { s.statisticsPending != nil && d.pending != nil }
        d.complete(); try await wait { a.knownActive == true }
        #expect(s.seeks.isEmpty && !s.playing && s.plays == 1)
        let pending = s.statisticsPending; s.statisticsPending = nil
        if failSave {
            pending?.resume(throwing: FeedLibraryError.invalidMutation)
            try await wait { c.state == .failed && d.pending != nil }; d.complete()
            #expect(s.seeks.isEmpty && s.plays == 1 && !c.wantsPlayback)
            c.close()
        } else {
            s.lastPlayedMilliseconds = 60001
            pending?.resume()
            try await wait { s.pending != nil }
            #expect(s.seeks == [24200] && s.plays == 1)
            s.finishSeek(); try await wait { s.playing }
            c.close(); try await wait { d.pending != nil }; d.complete()
        }
    }
}
