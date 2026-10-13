import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

/// Muted host-device integration; no microphone, Simulator, or acoustic acceptance.
@Suite(.serialized) @MainActor struct NativeSampleBufferTransportTests {
    @Test func rendererReconstructionUsesFreshNativeOutputAndCompletesSameEpisode() async throws {
        let helper = PCMPlaybackEngineTests()
        try await helper.withPlayer(nativeOutput: true) { store, player, engine, outputs, _, _ in
            try await player.select(episodeID: 1)
            try await helper.wait { (engine.reading?.sample.positionMilliseconds ?? 0) >= 100 }
            let before = try #require(engine.reading?.sample.positionMilliseconds)
            let old = try #require(outputs.nativeValues.first)
            old.onFailure?(NativeSampleBufferTransport.Failure.reconfigurationRequired)
            try await helper.wait { outputs.nativeValues.count == 2 && engine.reading?.buffering == false }
            let resumed = try #require(engine.reading?.sample.positionMilliseconds)
            #expect(resumed >= before) // Reconfiguration uses the current presentation clock.
            #expect(player.episode?.id == 1 && player.phase != .failed)
            #expect(try await store.episode(id: 1)?.userState.playState != .played)
            try await helper.wait { player.phase == .idle }
            #expect(try await store.episode(id: 1)?.userState.playState == .played)
            #expect(try await store.queue().isEmpty)
        }
    }

    @Test(arguments: [44100, 48000, 96000])
    func nativePresentationPausesAndEndsExactlyOnce(rate: Int) async throws {
        let transport = NativeSampleBufferTransport(muted: true)
        let output = try SampleBufferPCMOutput(transport: transport, sampleRate: rate, channels: 2,
                                              maximumFrames: rate / 5, maximumQueuedBuffers: 2)
        defer { output.onChange = nil; output.close() }
        let packet = [Int16](repeating: 8192, count: rate / 5 * 2)
        try await output.enqueue(packet)
        try await output.enqueue(packet)
        try output.finishEnqueuing()
        #expect(output.presentedFrames == 0 && output.state == .paused)
        var endings = 0
        output.onChange = { if output.state == .ended { endings += 1 } }
        try output.play()
        try await wait { output.presentedFrames > Int64(rate / 20) }
        try output.pause()
        let paused = output.presentedFrames
        try await Task.sleep(for: .milliseconds(60))
        #expect(output.presentedFrames == paused && output.state == .paused)
        try output.play()
        try await wait { output.state == .ended }
        #expect(output.presentedFrames == Int64(rate * 2 / 5))
        #expect(output.queuedBufferCount == 0 && endings == 1)
        try await Task.sleep(for: .milliseconds(40))
        #expect(endings == 1 && output.presentedFrames == output.writtenFrames)
    }

    @Test func nativeStarvationStopsClockAndRefillResumesAtBoundary() async throws {
        let transport = NativeSampleBufferTransport(muted: true)
        let output = try SampleBufferPCMOutput(transport: transport, sampleRate: 48000, channels: 1,
                                              maximumFrames: 4800, maximumQueuedBuffers: 2)
        defer { output.close() }
        try await output.enqueue([Int16](repeating: 4096, count: 4800))
        try output.play()
        try await wait { output.state == .buffering }
        #expect(output.presentedFrames == 4800 && output.wantsPlayback)
        try await Task.sleep(for: .milliseconds(60))
        #expect(output.presentedFrames == 4800 && transport.currentTime == CMTime(value: 4800, timescale: 48000))
        try await output.enqueue([Int16](repeating: -4096, count: 4800))
        try output.finishEnqueuing()
        try await wait { output.state == .ended }
        #expect(output.presentedFrames == 9600 && output.writtenFrames == 9600)
    }

    @Test(arguments: [Float(0.5), 1, 2], [false, true])
    func realOutputPlaysWholeEpisodeAtRequestedSpeedAndEndsAtEpisodeEnd(speed: Float, skipSilence: Bool) async throws {
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let stream = try LocalPCMPlaybackStream(url: url, skipSilence: skipSilence, speed: speed, maximumOutputFrames: 4096)
        let session = try SampleBufferPlaybackSession(stream: stream, transport: NativeSampleBufferTransport(muted: true))
        defer { session.close() }
        try await session.prepare()
        #expect(try session.mediaMicroseconds == 0)
        try session.play()
        try await wait { session.state == .ended || session.failure != nil }
        try #require(session.failure == nil)
        var shortened = input
        if skipSilence {
            var silence = try SilenceSkippingProcessor(sampleRate: 48000, channels: 2)
            shortened = try silence.process(input) + silence.finish()
        }
        var expected = shortened
        if speed != 1 {
            var processor = try PCMSpeedProcessor(sampleRate: 48000, channels: 2, speed: speed)
            expected = try processor.process(shortened) + processor.finish()
        }
        #expect(session.presentedFrames == Int64(expected.count / 2))
        #expect(session.writtenFrames == session.presentedFrames && session.sourceEnded)
        // Heard duration is the (silence-trimmed) media duration / speed, within 3% (min 20 ms).
        let heard = Double(session.presentedFrames), intended = Double(shortened.count / 2) / Double(speed)
        #expect(abs(heard - intended) <= max(intended * 0.03, 960), "speed \(speed): \(heard) frames, expected \(intended)")
        // The shown position at the end matches the mapped media time (within 0.25 s).
        let progress = try await stream.progress
        var clock = try PCMPlaybackClock(sampleRate: 48000, mediaMicroseconds: 0, speed: speed)
        let expectedTime = try clock.position(presentedFrames: Int64(expected.count / 2),
            writtenFrames: Int64(expected.count / 2), progress: progress)
        let position = try #require(try session.mediaMicroseconds)
        #expect(abs(position - expectedTime) <= 250_000)
        if !skipSilence { #expect(abs(position - 600_000) <= 250_000) }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    enum RecoveryAction: Sendable { case resume, pauseDuringPreparation, doNotResume }
    @MainActor final class RecoveryClock { var now: Int64 = 5000; var lastSaved: Int64 = 1000 }

    @Test(arguments: [false, true])
    func nativeEnginePauseResumeAndCompletionPersistThroughCoordinator(skipSilence: Bool) async throws {
        try await PCMPlaybackEngineTests().withPlayer(nativeOutput: true, skipSilence: skipSilence) { store, player, engine, _, clock, _ in
            try await player.select(episodeID: 1)
            try await wait { (engine.reading?.sample.positionMilliseconds ?? 0) >= 60 }
            clock.now += 1000
            try await player.pause()
            let paused = try #require(engine.reading?.sample.positionMilliseconds)
            #expect(engine.reading?.skipSilence == skipSilence && player.skipSilence == skipSilence)
            #expect(paused > 0 && paused < 600 && player.phase == .paused)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == paused)
            try await Task.sleep(for: .milliseconds(60))
            #expect(engine.reading?.sample.positionMilliseconds == paused)
            try await player.setSkipSilence(!skipSilence)
            #expect(engine.reading?.skipSilence == !skipSilence && !player.wantsPlayback)
            #expect(engine.reading?.sample.positionMilliseconds == paused)
            try await player.play()
            try await wait { player.phase == .idle }
            let saved = try #require(try await store.episode(id: 1))
            #expect(saved.userState.playState == .played && saved.userState.positionMilliseconds == 0)
            #expect(try await store.queue().isEmpty)
            #expect(try await store.playbackSession() == nil)
        }
    }

    @Test(arguments: [Float(0.5), 1, 2], [RecoveryAction.resume, .pauseDuringPreparation, .doNotResume])
    func interruptionRecoveryUsesFreshNativeStreamAndHonorsIntent(speed: Float, action: RecoveryAction) async throws {
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let factory = try PCMRecoveryFactory(url: url, muted: true)
        let parameters = PCMRecoverySession.Parameters(speed: speed, skipSilence: false)
        let initial = try await factory.make(positionMilliseconds: 0, parameters: parameters)
        try await initial.prepare()
        let clock = RecoveryClock()
        var replacement: SampleBufferPlaybackSession?
        var pending: CheckedContinuation<Void, Never>?
        var requestedPosition: Int64?
        let port = PCMRecoverySession(initial: initial, parameters: parameters,
            lastPlayedMilliseconds: { clock.lastSaved }, synchronizeStatistics: {}, factory: { position, requested in
                requestedPosition = position
                await withCheckedContinuation { pending = $0 }
                let session = try await factory.make(positionMilliseconds: position, parameters: requested)
                replacement = session
                return session
            })
        let driver = AudioSessionActivationControllerTests.Driver()
        let activation = AudioSessionActivationController(driver: driver)
        let recovery = PlaybackRecoveryController(session: port, activation: activation, now: { clock.now })
        defer {
            pending?.resume(); pending = nil
            recovery.close()
            driver.complete()
        }
        try recovery.play(); try await wait { driver.pending != nil }; driver.complete()
        try await wait { initial.presentedFrames >= 2400 }
        try #require(initial.state == .playing)
        recovery.receive(.interrupted(reason: 0))
        // The shared service's position save owns statistics, not the native pause call.
        clock.lastSaved = clock.now
        let paused = try port.positionMilliseconds
        #expect(paused > 0 && port.lastPlayedMilliseconds == 5000 && initial.state == .paused)
        try await Task.sleep(for: .milliseconds(40))
        #expect(try port.positionMilliseconds == paused)
        // A deterministic clock crosses Android's strict one-minute rewind threshold.
        clock.now = 65001
        recovery.receive(.resumptionRecommended(action != .doNotResume))
        try await wait { pending != nil }
        #expect(requestedPosition == 0 && initial.state == .closed)
        if action == .pauseDuringPreparation { try recovery.pause() }
        pending?.resume(); pending = nil
        if action == .resume {
            try await wait { driver.pending != nil }; driver.complete()
            try await wait { replacement?.state == .ended || recovery.failure != nil }
            try #require(recovery.failure == nil)
            let next = try #require(replacement)
            #expect(next.sourceEnded && next.presentedFrames == next.writtenFrames)
            // A dropped speed parameter must fail even if a replacement eventually ends.
            // This processor has separate exact original-Java waveform oracle coverage.
            var expected = input
            if speed != 1 {
                var processor = try PCMSpeedProcessor(sampleRate: 48000, channels: 2, speed: speed)
                expected = try processor.process(input) + processor.finish()
            }
            #expect(next.presentedFrames == Int64(expected.count / 2) && recovery.wantsPlayback)
        } else {
            // Any activation already dispatched before Pause finishes; the paused player keeps the session.
            if driver.pending != nil {
                driver.complete()
                try await wait { activation.knownActive == true }
                #expect(driver.pending == nil && driver.requests.last == true)
            }
            try await wait { recovery.state == .paused && replacement?.state == .paused }
            try await Task.sleep(for: .milliseconds(60))
            #expect(replacement?.presentedFrames == 0 && !recovery.wantsPlayback)
            #expect(try port.positionMilliseconds == 0)
        }
        recovery.close()
        if activation.knownActive != false {
            try await wait { driver.pending != nil }; driver.complete()
        }
    }

    /// Fade steps and volume changes set the renderer's own volume: mute stays as it was, and the clock keeps
    /// running at the same rate through every change, with the audio and video queues left as they are.
    @Test func rendererVolumeLeavesMuteClockRateAndVideoUntouched() async throws {
        let transport = NativeSampleBufferTransport(muted: true)
        defer { transport.close() }
        #expect(transport.rendererVolume == 1 && transport.isMuted)
        let video = try transport.attachVideo(displayLayer: AVSampleBufferDisplayLayer())
        let generation = video.generation
        let factory = try PCMSampleBufferFactory(sampleRate: 48000, channels: 1, maximumFrames: 4800)
        for start in stride(from: 0, to: 48_000, by: 4800) {
            try await transport.enqueue(factory.makeBuffer([Int16](repeating: 1000, count: 4800), outputStartFrame: Int64(start)))
        }
        // A picture due later stays queued throughout.
        try await video.enqueue(try pixel(), presentation: CMTimeRange(start: CMTime(value: 2, timescale: 1),
            duration: CMTime(value: 1, timescale: 10)), generation: generation)
        var ended = false
        transport.onTimeChanged = { if transport.currentTime >= CMTime(value: 1, timescale: 1) { ended = true } }
        transport.observeEnd(CMTime(value: 1, timescale: 1))
        transport.setPlaying(true, at: .zero)
        try await wait { transport.currentTime > CMTime(value: 1, timescale: 20) }
        var previous = transport.currentTime
        for volume: Float in [0.9, 0.8, 0.5, 0.1, 1, 0.25, 0.2] {
            transport.setRendererVolume(volume)
            #expect(transport.rendererVolume == volume && transport.isMuted)
            let now = transport.currentTime
            #expect(now >= previous) // Never re-anchored backwards.
            previous = now
        }
        #expect(video.generation == generation && video.queuedFrameCount == 1)
        let start = (ContinuousClock.now, transport.currentTime.seconds)
        try await wait { transport.currentTime > CMTime(value: 3, timescale: 10) }
        let elapsed = start.0.duration(to: .now)
        let clock = transport.currentTime.seconds - start.1
        // The clock still runs in real time (rate 1), within the loaded machine's timer slack.
        #expect(clock > 0 && clock <= Double(elapsed.components.attoseconds) / 1e18 + Double(elapsed.components.seconds) + 0.05)
        try await wait { ended }
        #expect(video.generation == generation && video.queuedFrameCount == 1)
        let unmuted = NativeSampleBufferTransport(muted: false)
        defer { unmuted.close() }
        unmuted.setRendererVolume(0.3)
        #expect(!unmuted.isMuted && unmuted.rendererVolume == 0.3)
    }

    nonisolated private func pixel() throws -> CVReadOnlyPixelBuffer {
        var value: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &value)
        try #require(status == kCVReturnSuccess)
        return CVReadOnlyPixelBuffer(unsafeBuffer: try #require(value))
    }
}
