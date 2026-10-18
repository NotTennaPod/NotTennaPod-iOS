import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) @MainActor struct PCMSystemSessionTests {
    @MainActor final class SystemEvents {
        let center = NotificationCenter()
        let subject = NSObject()
        var subscriptions = 0
        weak var source: AudioSessionEventSource?

        func subscribe(_ handler: @escaping @MainActor (AudioSessionEvent) -> Void) -> AudioSessionEventSource {
            subscriptions += 1
            let source = AudioSessionEventSource(center: center, subject: subject,
                names: AudioSessionEventSourceTests.names, handler: handler)
            source.observe(subject: subject, message: AudioSessionEventSourceTests.SystemFact.self) { $0.event }
            self.source = source
            return source
        }

        func post(_ event: AudioSessionEvent) {
            center.post(AudioSessionEventSourceTests.SystemFact(event: event), subject: subject)
        }

        func route(_ reason: UInt64) {
            center.post(name: AudioSessionEventSourceTests.names.routeChanged, object: subject,
                        userInfo: [AudioSessionEventSourceTests.names.routeReasonKey: NSNumber(value: reason)])
        }
    }

    @Test(arguments: [Int64(0), 1])
    func oneSubscriptionSurvivesEpisodeReplacementStopAndInterruptionRecovery(elapsed: Int64) async throws {
        let events = SystemEvents()
        try await PCMPlaybackEngineTests().withPlayer(events: events.subscribe) { store, player, engine, outputs, clock, driver in
            #expect(events.subscriptions == 1 && driver.preparations == 0 && driver.requests.isEmpty)
            try await player.select(episodeID: 1, play: false)
            try await wait { player.phase == .paused }
            #expect(driver.preparations == 0 && driver.requests.isEmpty)
            try await player.play(); try await wait { outputs.values[0].playing }
            #expect(driver.preparations == 1)
            outputs.values[0].advance(9600)
            clock.now += 1000
            events.post(.interrupted(reason: 0))
            try await wait { player.phase == .paused }
            #expect(!outputs.values[0].playing && !player.wantsPlayback)
            // The pause does not wait for its save (it is stored after the engine paused): the stored position follows.
            let saved = ContinuousClock.now.advanced(by: .seconds(3))
            while try await store.episode(id: 1)?.userState.positionMilliseconds != 200, ContinuousClock.now < saved { await Task.yield() }
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 200)
            clock.now += elapsed
            events.post(.resumptionRecommended(true))
            // Original rewind has a strict >0-ms boundary. Zero elapsed time reuses the
            // current stream; one millisecond rewinds this short fixture to the start.
            let resumed = elapsed == 0 ? 0 : 1
            try await wait { outputs.values.count == resumed + 1 && outputs.values[resumed].playing }
            #expect(outputs.values[0].closed == (elapsed > 0))
            #expect(engine.reading?.sample.positionMilliseconds == (elapsed == 0 ? 200 : 0))
            #expect(driver.preparations == 2 && events.subscriptions == 1)
            try await player.select(episodeID: 2)
            try await wait { outputs.values.count == resumed + 2 && outputs.values[resumed + 1].playing }
            #expect(outputs.values[resumed].closed && events.subscriptions == 1)
            try await player.stop()
            #expect(events.source?.isClosed == false)
            events.post(.becameActive)
            let previousRequests = driver.requests.count
            try await player.play(); try await wait { outputs.values.count == resumed + 3 && outputs.values[resumed + 2].playing }
            #expect(driver.preparations >= 4 && events.subscriptions == 1)
            // A cached OS active observation cannot bypass configuration. Depending on pending
            // stop reconciliation, activation may be reused or requested again.
            #expect(driver.requests.count >= previousRequests)
        }
    }

    @Test(arguments: [false, true])
    func realRouteNotificationsHonorCapturedDisconnectPreferenceAndDoNotReconnect(pauseOnDisconnect: Bool) async throws {
        let events = SystemEvents()
        try await PCMPlaybackEngineTests().withPlayer(events: events.subscribe, pauseOnDisconnect: pauseOnDisconnect) {
            _, player, _, outputs, _, _ in
            try await player.select(episodeID: 1)
            try await wait { outputs.values.first?.playing == true }
            events.route(2)
            try await player.awaitPendingOperations()
            #expect(outputs.values[0].playing == !pauseOnDisconnect)
            #expect(player.wantsPlayback == !pauseOnDisconnect)
            events.route(1)
            try await player.awaitPendingOperations()
            #expect(outputs.values[0].playing == !pauseOnDisconnect)
            #expect(player.wantsPlayback == !pauseOnDisconnect)
            #expect(events.subscriptions == 1)
        }
    }

    @Test func configurationFailureDoesNotStartNativeOutputOrMarkEpisodeCompleted() async throws {
        try await PCMPlaybackEngineTests().withPlayer { store, player, engine, outputs, _, driver in
            driver.configurationError = AudioSessionActivationControllerTests.Problem.rejected
            try await player.select(episodeID: 1)
            try await wait { player.phase == .failed }
            // Configuration now precedes preparation; failure may prevent allocation entirely.
            #expect(outputs.values.count <= 1 && outputs.values.allSatisfy { $0.closed && !$0.playing })
            #expect(!driver.requests.contains(true) && driver.preparations == 1)
            #expect(engine.reading == nil && !player.wantsPlayback)
            #expect(try await store.episode(id: 1)?.userState.playState != .played)
            #expect(try await store.queue().map(\.id) == [1])
        }
    }

    /// What the engine told the coordinator: a reset must never arrive as a playback failure (its dialog).
    @MainActor final class EngineReports {
        var failures: [String] = []
        var resets: [PlaybackEngineReading] = []
        init(_ engine: any PlaybackEngine) {
            let forward = engine.onEvent
            engine.onEvent = { [weak self] event in
                switch event {
                case .failed(_, let message): self?.failures.append(message)
                case .mediaServicesReset(let final): self?.resets.append(final)
                default: break
                }
                forward?(event)
            }
        }
    }

    /// A media-services reset keeps the episode selected at its position as after a relaunch (phase stopped:
    /// shown paused, Play rebuilds it, seeking and skipping wait for that Play), with no failed phase and no dialog;
    /// its audio objects are closed at once, late callbacks and the session's recovery events start nothing, and only
    /// an explicit Play builds them again (QA1749).
    @Test(arguments: [false, true], [false, true])
    func mediaServiceResetRetainsPositionAndOnlyExplicitPlayRebuilds(paused: Bool, lostFirst: Bool) async throws {
        let events = SystemEvents()
        try await PCMPlaybackEngineTests().withPlayer(speed: 1.5, skipSilence: true, events: events.subscribe) {
            store, player, engine, outputs, clock, driver in
            let reports = EngineReports(engine)
            _ = try await store.enqueue([1, 2])
            try await player.select(episodeID: 1)
            try await wait { outputs.values.first?.playing == true }
            let old = outputs.values[0]
            let late = old.onTimeChanged
            old.advance(4800)
            clock.now += 1000
            if paused { try await player.pause() }
            let position = try #require(engine.reading?.sample.positionMilliseconds)
            #expect(position > 0)
            if lostFirst { events.post(.mediaServicesLost) }
            events.post(.mediaServicesReset)
            // Disposed at once, in the step the system reported the reset.
            #expect(old.closed && !old.playing && engine.reading == nil)
            try await wait { player.phase == .stopped }
            try await player.awaitPendingOperations()
            #expect(reports.failures.isEmpty && reports.resets.count == 1 && player.phase == .stopped)
            #expect(player.episode?.id == 1 && player.sample?.positionMilliseconds == Int32(position) && player.sample?.status == .paused)
            #expect(old.closed && !old.playing && !player.wantsPlayback)
            #expect(player.systemSnapshot?.canPlay == true && player.systemSnapshot?.rate == 0)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == position)
            #expect(try await store.episode(id: 1)?.userState.playState != .played)
            #expect(try await store.queue().map(\.id) == [1, 2])
            let activations = driver.preparations
            events.post(.becameActive)
            events.post(.resumptionRecommended(true))
            late?()
            try await player.awaitPendingOperations()
            #expect(outputs.values.count == 1 && driver.preparations == activations)
            try await player.play()
            try await wait { outputs.values.count == 2 && outputs.values[1].playing }
            #expect(engine.reading?.sample.positionMilliseconds == position)
            #expect(engine.reading?.speed == 1.5 && engine.reading?.skipSilence == true)
            #expect(driver.preparations == activations + 1 && events.subscriptions == 1)
            #expect(player.episode?.id == 1 && player.wantsPlayback && reports.failures.isEmpty, "\(player.phase)")
            try await player.pause()
        }
    }

    private func wait(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    @Test(arguments: [false, true], [false, true])
    func resetDuringSuspendedPreparationCannotReviveRetiredOutput(seeking: Bool, replaceEpisode: Bool) async throws {
        let events = SystemEvents()
        try await PCMPlaybackEngineTests().withPlayer(events: events.subscribe) {
            store, player, engine, outputs, _, driver in
            if seeking {
                try await player.select(episodeID: 1)
                try await wait { outputs.values.first?.playing == true }
            }
            outputs.configure = { $0.hold = true }
            defer { outputs.configure = nil; outputs.values.forEach { $0.release() } }
            if seeking { try await player.seek(to: 300) }
            else { try await player.select(episodeID: 1) }
            try await wait { outputs.values.last?.pending != nil }
            let retired = try #require(outputs.values.last)
            let late = retired.onTimeChanged
            let reports = EngineReports(engine)
            events.post(.mediaServicesReset)
            try await wait { player.phase == .stopped }
            try await player.awaitPendingOperations()
            #expect(retired.closed && !retired.playing && reports.failures.isEmpty && player.episode?.id == 1)
            outputs.configure = nil
            let count = outputs.values.count
            if replaceEpisode { try await player.select(episodeID: 2) }
            else { try await player.play() }
            try await wait { outputs.values.count == count + 1 && outputs.values.last?.playing == true }
            let generation = engine.reading?.generation
            let preparations = driver.preparations
            retired.release(); late?()
            // Let the obsolete native enqueue and its preparing task return after the retry.
            try await Task.sleep(for: .milliseconds(20))
            try await player.awaitPendingOperations()
            #expect(engine.reading?.generation == generation && player.wantsPlayback)
            #expect(engine.reading?.sample.positionMilliseconds == (seeking && !replaceEpisode ? 300 : 0))
            #expect(player.episode?.id == (replaceEpisode ? 2 : 1))
            #expect(outputs.values.last?.playing == true && driver.preparations == preparations)
            #expect(try await store.episode(id: 1)?.userState.playState != .played)
            #expect(events.subscriptions == 1)
            try await player.pause()
        }
    }

    @Test func controlledResetClosesRealNativeOutputAndExplicitRetryFinishesSameEpisode() async throws {
        let events = SystemEvents()
        try await PCMPlaybackEngineTests().withPlayer(nativeOutput: true, events: events.subscribe) {
            store, player, engine, outputs, _, driver in
            try await player.select(episodeID: 1)
            try await wait { engine.reading?.isPrepared == true && engine.reading?.buffering == false }
            let old = try #require(outputs.nativeValues.first)
            let reports = EngineReports(engine)
            events.post(.mediaServicesReset)
            try await wait { player.phase == .stopped }
            #expect(old.onTimeChanged == nil && old.onFailure == nil && !player.wantsPlayback)
            #expect(reports.failures.isEmpty && player.episode?.id == 1)
            let packet = try PCMSampleBufferFactory(sampleRate: 48000, channels: 1)
                .makeBuffer([1], outputStartFrame: 0)
            do { try await old.enqueue(packet); Issue.record("Retired native receiver accepted audio") }
            catch NativeSampleBufferTransport.Failure.closed { }
            catch { Issue.record("Unexpected retired receiver error: \(error)") }
            #expect(try await store.episode(id: 1)?.userState.playState != .played)
            try await player.play()
            try await wait { outputs.nativeValues.count == 2 }
            try await wait { player.phase == .idle }
            #expect(try await store.episode(id: 1)?.userState.playState == .played)
            #expect(try await store.queue().isEmpty)
            #expect(events.subscriptions == 1 && driver.preparations == 2)
        }
    }
}
