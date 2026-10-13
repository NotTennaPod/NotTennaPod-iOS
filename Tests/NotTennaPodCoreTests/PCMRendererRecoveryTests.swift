import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized) @MainActor struct PCMRendererRecoveryTests {
    private let helper = PCMPlaybackEngineTests()

    @Test func configurationChangeRecoversUnobservedPresentationWithoutCompletingEpisode() async throws {
        try await helper.withPlayer { store, player, engine, outputs, _, driver in
            try await player.select(episodeID: 1)
            try await helper.wait { outputs.values.first?.playing == true }
            let old = outputs.values[0]
            old.advance(4800)
            #expect(engine.reading?.sample.positionMilliseconds == 100)
            old.currentTime = CMTime(value: 9600, timescale: 48000) // Observer has not run.
            let stale = old.onFailure
            old.onFailure?(NativeSampleBufferTransport.Failure.reconfigurationRequired)
            try await helper.wait { outputs.values.count == 2 && outputs.values[1].playing }
            #expect(old.closed && engine.reading?.sample.positionMilliseconds == 200)
            #expect(engine.reading?.sample.durationMilliseconds == 600)
            #expect(player.episode?.id == 1 && player.phase != .failed)
            #expect(try await store.episode(id: 1)?.userState.playState != .played)
            let requests = driver.requests
            stale?(NativeSampleBufferTransport.Failure.reconfigurationRequired)
            await Task.yield()
            #expect(outputs.values.count == 2 && driver.requests == requests)
            outputs.values[1].advance(4800)
            #expect(engine.reading?.sample.positionMilliseconds == 300)
        }
    }

    @Test(arguments: [false, true])
    func automaticFlushAfterEOFReplaysFromFirstDiscardedTime(paused: Bool) async throws {
        try await helper.withPlayer(maximumOutputFrames: 32768, maximumQueuedBuffers: 2) {
            store, player, engine, outputs, _, _ in
            try await player.select(episodeID: 1)
            try await helper.wait { outputs.values.first?.playing == true && outputs.values.first?.monitoring == true }
            let old = outputs.values[0]
            old.advance(4800)
            if paused { try await player.pause() }
            old.currentTime = CMTime(value: 14400, timescale: 48000)
            old.onFailure?(NativeSampleBufferTransport.Failure.automaticallyFlushed(
                at: CMTime(value: 9600, timescale: 48000)))
            try await helper.wait { outputs.values.count == 2 && engine.reading?.buffering == false }
            #expect(engine.reading?.sample.positionMilliseconds == (paused ? 100 : 200))
            #expect(outputs.values[1].playing == !paused && old.closed)
            #expect(try await store.episode(id: 1)?.userState.playState != .played)
            let (fixtureURL, original) = try PCMTestFixture.waveFixture()
            defer { try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent()) }
            let firstFrame = paused ? 4800 : 9600
            if paused { try await player.play() }
            try await helper.wait { outputs.values[1].playing }
            try await helper.drain(outputs.values[1]) { player.phase == .idle }
            #expect(try await store.episode(id: 1)?.userState.playState == .played)
            let resumedBytes = try outputs.values[1].buffers.reduce(into: Data()) { data, buffer in
                data.append(try #require(buffer.content.withContiguousStorageIfAvailable { Data($0) }))
            }
            let expected = Array(original.dropFirst(firstFrame * 2)).withUnsafeBytes { Data($0) }
            // Replays from the first discarded time: nothing audible lost or repeated.
            PCMTestFixture.expectAudiblyEquivalent(resumedBytes, expected)
        }
    }

    @Test(arguments: [Float(0.5), 1, 2], [false, true])
    func recoveryKeepsSpeedSilenceAndSuppressedIntent(speed: Float, silence: Bool) async throws {
        try await helper.withPlayer(speed: speed, skipSilence: silence) { _, player, engine, outputs, _, _ in
            try await player.select(episodeID: 1)
            try await helper.wait { outputs.values.first?.playing == true }
            let old = outputs.values[0]
            old.advance(2400)
            engine.receive(.interrupted(reason: 0))
            let position = engine.reading?.sample.positionMilliseconds
            old.onFailure?(NativeSampleBufferTransport.Failure.reconfigurationRequired)
            try await helper.wait { outputs.values.count == 2 && !engine.reading!.buffering }
            #expect(engine.reading?.sample.positionMilliseconds == position)
            #expect(engine.reading?.speed == speed && engine.reading?.skipSilence == silence)
            #expect(engine.reading?.sample.status == .paused && !outputs.values[1].playing)
            engine.receive(.resumptionRecommended(true))
            try await helper.wait { outputs.values.last?.playing == true }
            #expect(engine.reading?.speed == speed && engine.reading?.skipSilence == silence)
            // Media3 renderer recovery seeks and flushes its processors. Compare the complete
            // resumed output with fresh processing at the mapped target, not an uninterrupted
            // Sonic phase or silence-detection state that the original also discards.
            let target = try #require(position)
            let resumed = outputs.values[1]
            try await helper.drain(resumed) { player.phase == .idle }
            let actual = try resumed.buffers.reduce(into: Data()) { data, buffer in
                data.append(try #require(buffer.content.withContiguousStorageIfAvailable { Data($0) }))
            }
            PCMTestFixture.expectAudiblyEquivalent(actual, try freshProcessedBytes(at: target, speed: speed, silence: silence))
        }
    }

    private func freshProcessedBytes(at milliseconds: Int32, speed: Float, silence: Bool) throws -> Data {
        let (url, input) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var skip = silence ? try SilenceSkippingProcessor(sampleRate: 48000, channels: 2) : nil
        var rate = speed == 1 ? nil : try PCMSpeedProcessor(sampleRate: 48000, channels: 2, speed: speed)
        let samples = Array(input.dropFirst(Int(milliseconds) * 48 * 2))
        var processed: [Int16] = []
        for offset in stride(from: 0, to: samples.count, by: 8192) {
            let packet = Array(samples[offset..<min(samples.count, offset + 8192)])
            let shortened = try skip?.process(packet) ?? packet
            processed += try rate?.process(shortened) ?? shortened
        }
        let tail = skip?.finish() ?? []
        processed += try rate?.process(tail) ?? tail
        processed += rate?.finish() ?? []
        return processed.withUnsafeBytes { Data($0) }
    }

    @Test(arguments: [Float(0.5), 2], [false, true])
    func delayedFlushBeforeConsumedSpeedBoundaryRebuildsAtOriginalMediaTime(speed: Float, paused: Bool) async throws {
        try await helper.withPlayer(maximumOutputFrames: 127, maximumQueuedBuffers: 1) {
            store, player, engine, outputs, _, _ in
            try await player.select(episodeID: 1)
            try await helper.wait { outputs.values.first?.playing == true }
            let old = outputs.values[0]
            try await player.setSpeed(speed)
            // The first decoded 4096-frame input packet drains at 1x. Advance through that
            // boundary into the new processing segment before reporting the older flush.
            while old.end.value < 5100 {
                let count = old.buffers.count
                old.advance(old.end.value)
                try await helper.wait { old.buffers.count > count && old.playing }
            }
            old.advance(5000)
            if paused { try await player.pause() }
            #expect(engine.reading!.sample.positionMilliseconds > 85)
            old.onFailure?(NativeSampleBufferTransport.Failure.automaticallyFlushed(
                at: CMTime(value: 2400, timescale: 48000)))
            try await helper.wait { outputs.values.count == 2 && engine.reading?.buffering == false }
            #expect(old.closed && engine.reading?.sample.positionMilliseconds == 50)
            #expect(engine.reading?.speed == speed && outputs.values[1].playing == !paused)
            #expect(player.episode?.id == 1 && player.phase != .failed)
            #expect(try await store.episode(id: 1)?.userState.playState != .played)
            if paused { try await player.play() }
            let resumed = outputs.values[1]
            try await helper.wait { resumed.playing }
            try await helper.drain(resumed) { player.phase == .idle }
            let actual = try resumed.buffers.reduce(into: Data()) { data, buffer in
                data.append(try #require(buffer.content.withContiguousStorageIfAvailable { Data($0) }))
            }
            PCMTestFixture.expectAudiblyEquivalent(actual, try freshProcessedBytes(at: 50, speed: speed, silence: false))
            #expect(try await store.episode(id: 1)?.userState.playState == .played)
        }
    }

    @Test(arguments: [CMTime.invalid, .indefinite, CMTime(value: -1, timescale: 48000)])
    func invalidFlushTimeRemainsAnErrorAndCannotInventRecovery(time: CMTime) async throws {
        try await helper.withPlayer { store, player, _, outputs, _, _ in
            try await player.select(episodeID: 1)
            try await helper.wait { outputs.values.first?.playing == true }
            outputs.values[0].onFailure?(NativeSampleBufferTransport.Failure.automaticallyFlushed(at: time))
            try await helper.wait { player.phase == .failed }
            #expect(outputs.values.count == 1 && outputs.values[0].closed)
            #expect(try await store.episode(id: 1)?.userState.playState != .played)
        }
    }

    enum PendingAction: CaseIterable { case pause, seek, replacement, unload }
    @Test(arguments: PendingAction.allCases)
    func commandsDuringRecoveryFenceObsoleteOutput(action: PendingAction) async throws {
        try await helper.withPlayer { store, player, engine, outputs, _, _ in
            try await player.select(episodeID: 1)
            try await helper.wait { outputs.values.first?.playing == true }
            outputs.values[0].advance(4800)
            outputs.configure = { $0.hold = true }
            outputs.values[0].onFailure?(NativeSampleBufferTransport.Failure.reconfigurationRequired)
            try await helper.wait { outputs.values.count == 2 && outputs.values[1].pending != nil }
            let pending = outputs.values[1]
            defer { pending.release() }
            outputs.configure = nil
            switch action {
            case .pause: try await player.pause()
            case .seek: try await player.seek(to: 400)
            case .replacement: try await player.select(episodeID: 2, play: false)
            case .unload: engine.unload()
            }
            // This scenario blocks one enqueue to admit a user command. Leaving
            // hold enabled would suspend every later preparation buffer as well.
            if case .pause = action { pending.hold = false }
            pending.release()
            switch action {
            case .pause:
                try await helper.wait { engine.reading?.buffering == false }
                #expect(!pending.playing && engine.reading?.sample.status == .paused)
                #expect(engine.reading?.sample.positionMilliseconds == 100)
                #expect(try await store.episode(id: 1)?.userState.playState != .played)
                try await player.play()
                try await helper.wait { pending.playing }
                pending.advance(4800)
                #expect(engine.reading?.sample.positionMilliseconds == 200)
            case .seek:
                try await helper.wait { outputs.values.count == 3 && outputs.values[2].playing }
                #expect(engine.reading?.sample.positionMilliseconds == 400 && pending.closed)
            case .replacement:
                try await helper.wait { player.episode?.id == 2 && player.phase == .paused }
                #expect(engine.reading?.sample.positionMilliseconds == 0 && pending.closed)
            case .unload:
                await Task.yield()
                #expect(engine.reading == nil && pending.closed && !pending.playing)
            }
        }
    }

    @Test func replacementDecoderFailureDoesNotLoopOrCompleteEpisode() async throws {
        try await helper.withPlayer { store, player, _, outputs, _, _ in
            try await player.select(episodeID: 1)
            try await helper.wait { outputs.values.first?.playing == true }
            outputs.configure = { $0.error = NativeSampleBufferTransport.Failure.reconfigurationRequired }
            outputs.values[0].onFailure?(NativeSampleBufferTransport.Failure.reconfigurationRequired)
            try await helper.wait { player.phase == .failed }
            #expect(outputs.values.count == 2 && outputs.values.allSatisfy { $0.closed && !$0.playing })
            #expect(try await store.episode(id: 1)?.userState.playState != .played)
        }
    }

    @Test func suggestedFlushReasonsPreserveEarliestTimeAndRejectUnknownTiming() {
        typealias Reason = AVSampleBufferAudioRenderer.Receiver.SuggestedFlushReason
        let later = CMTime(value: 2, timescale: 1), earlier = CMTime(value: 1, timescale: 1)
        let reasons: [Reason] = [.outputConfigurationChanged, .wasFlushedAutomatically(at: later),
                                .wasFlushedAutomatically(at: earlier)]
        if case .automaticallyFlushed(let time) = NativeSampleBufferTransport.discontinuity(reasons) {
            #expect(time == earlier)
        } else { Issue.record("Discarded the automatic flush timestamp") }
        if case .reconfigurationRequired = NativeSampleBufferTransport.discontinuity([.outputConfigurationChanged]) {}
        else { Issue.record("Lost the configuration reason") }
        for reasons: [Reason] in [[], [.wasFlushedAutomatically(at: .invalid)]] {
            if case .flushed = NativeSampleBufferTransport.discontinuity(reasons) {}
            else { Issue.record("Invented a recoverable timestamp") }
        }
    }
}
