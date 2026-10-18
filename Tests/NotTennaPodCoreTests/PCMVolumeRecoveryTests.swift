import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized) struct PCMVolumeRecoveryTests {
    private typealias Transport = GainRecordingTransport
    private final class Outputs { var values: [Transport] = [] }
    private func factory(_ url: URL, _ outputs: Outputs) throws -> PCMRecoveryFactory {
        try PCMRecoveryFactory(url: url, maximumOutputFrames: 65536, makeTransport: {
            let output = Transport(); outputs.values.append(output); return output
        })
    }
    private func engine(_ url: URL, _ outputs: Outputs) -> PCMPlaybackEngine {
        PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), makeFactory: { try factory($0, outputs) },
            source: { _ in url }, duration: { _ in 600 }, positionTicker: PCMPlaybackEngineTests.Ticker())
    }
    /// The PCM before the volume stage.
    private func input(_ url: URL, position: Int64, speed: Float, skip: Bool) async throws -> [Int16] {
        let stream = try LocalPCMPlaybackStream(url: url, start: CMTime(value: position, timescale: 1000),
            skipSilence: skip, speed: speed, maximumOutputFrames: 65536)
        var samples: [Int16] = []
        while let packet = try await stream.nextPacket() { samples += packet.samples }
        return samples
    }
    /// Composed check of a whole queued output: renderer volume × PCM against Android's split, with
    /// `processedWith` the `v` every queued frame was processed with and `renderer` the `v` now in force.
    private func expectHeard(_ output: Transport, _ input: [Int16], processedWith: Float, renderer: Float,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(output.payload.count == input.count, "queued \(output.payload.count) of \(input.count) samples", sourceLocation: sourceLocation)
        #expect(output.rendererVolume == VolumeOracle.Command(v: renderer).playerVolume, sourceLocation: sourceLocation)
        VolumeOracle.expectComposed(actualPCM: output.payload, actualRenderer: [(0, output.rendererVolume)],
            referencePCM: VolumeOracle.processedPCM(input, channels: 2, sampleRate: 48000, commands: [(0, .init(v: processedWith))]),
            referenceRenderer: [(0, VolumeOracle.Command(v: renderer).playerVolume)], channels: 2, frames: input.count / 2,
            label: "processed at \(processedWith), renderer at \(renderer)", sourceLocation: sourceLocation)
    }

    @Test(arguments: FeedVolumeAdaptation.allCases)
    func storedVolumeSurvivesSpeedSilenceSeekAndLibraryReopen(volume: FeedVolumeAdaptation) async throws {
        let (url, _) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let database = url.deletingLastPathComponent().appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: database)
        _ = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "PCM volume", episodes: [
            .init(identifier: "one", title: "Episode", media: .init(url: "https://example.test/one.wav", size: 0, durationMilliseconds: 600))]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        try await store.updatePreferences(feedID: 1) { $0.volumeAdaptation = volume }
        let outputs = Outputs()
        let first = self.engine(url, outputs)
        let player = PlaybackCoordinator(store: store, engine: first, clock: { Date(timeIntervalSince1970: 5) })
        do {
            try await player.select(episodeID: 1, play: false)
            try await wait { player.phase == .paused }
            #expect(player.volumeAdaptation == volume)
            expectHeard(try #require(outputs.values.first), try await input(url, position: 0, speed: 1, skip: false),
                processedWith: volume.factor, renderer: volume.factor)
            try await player.setSpeed(2)
            try await player.setSkipSilence(true)
            try await player.seek(to: 300)
            try await wait { outputs.values.count == 2 && outputs.values[1].finished && first.reading?.sample.positionMilliseconds == 300 && !first.reading!.buffering }
            #expect(outputs.values[0].closed && !outputs.values[1].playing)
            #expect(first.reading?.speed == 2 && first.reading?.skipSilence == true)
            expectHeard(outputs.values[1], try await input(url, position: 300, speed: 2, skip: true),
                processedWith: volume.factor, renderer: volume.factor)
            try await player.pause()
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 300)
            first.unload(); try await store.close()
        } catch { first.unload(); try? await store.close(); throw error }

        let reopened = try FeedLibraryStore(url: database)
        let restoredOutputs = Outputs()
        let second = self.engine(url, restoredOutputs)
        let restored = PlaybackCoordinator(store: reopened, engine: second, clock: { Date(timeIntervalSince1970: 6) })
        do {
            try await restored.restore()
            #expect(restored.volumeAdaptation == volume && restored.sample?.positionMilliseconds == 300)
            try await restored.select(episodeID: 1, play: false)
            try await wait { restored.phase == .paused }
            // A positive elapsed pause rewinds800ms, clamped at zero.
            // Restored display retains300ms; loading one second later starts at0.
            #expect(second.reading?.sample.positionMilliseconds == 0)
            expectHeard(try #require(restoredOutputs.values.first),
                try await input(url, position: 0, speed: restored.speed, skip: restored.skipSilence),
                processedWith: volume.factor, renderer: volume.factor)
            second.unload(); try await reopened.close()
        } catch { second.unload(); try? await reopened.close(); throw error }
    }

    @Test func volumeChangedDuringFactoryWinsBeforeFirstPreparedAudio() async throws {
        let (url, _) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outputs = Outputs()
        let activeFactory = try self.factory(url, outputs)
        var gate: CheckedContinuation<Void, Never>?
        let owner = PCMRecoverySession(parameters: .init(speed: 1, skipSilence: false, volume: .lightBoost),
            lastPlayedMilliseconds: { 0 }, synchronizeStatistics: {}) { position, parameters in
                await withCheckedContinuation { gate = $0 }
                return try await activeFactory.make(positionMilliseconds: position, parameters: parameters)
            }
        defer { gate?.resume(); owner.close() }
        let seek = Task { try await owner.seekPaused(to: 100) }
        defer { seek.cancel() }
        try await wait { gate != nil }
        try owner.setVolumeAdaptation(.heavyReduction)
        try await owner.setParameters(speed: 2, skipSilence: true)
        let continuation = gate; gate = nil; continuation?.resume()
        try await seek.value
        #expect(owner.parameters == .init(speed: 2, skipSilence: true, volume: .heavyReduction))
        #expect(try owner.positionMilliseconds == 100)
        let output = try #require(outputs.values.first)
        // The renderer created with the factory's (older) value takes the latest one before its first enqueue.
        #expect(output.volumes.last { $0.processedFrames == 0 }?.value == 0.2 && output.volumes.allSatisfy { $0.processedFrames == 0 })
        expectHeard(output, try await input(url, position: 100, speed: 2, skip: true), processedWith: 0.2, renderer: 0.2)
    }

    @Test func sleepFadeSurvivesParameterChangeAndSeekThenRestoresFeedBoost() async throws {
        let (url, _) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outputs = Outputs()
        let engine = self.engine(url, outputs)
        engine.bindStatistics(lastPlayed: { _ in 0 }, synchronize: { _ in })
        defer { engine.unload() }
        let token = UUID()
        let episode = LibraryEpisode(id: 1, details: .init(identifier: "sleep", title: "Sleep fade",
            media: .init(url: url.absoluteString, size: 0, durationMilliseconds: 600)))
        engine.load(episode: episode, generation: token, positionMilliseconds: 0)
        try engine.setVolumeAdaptation(.heavyBoost)
        try engine.setSleepTimerVolume(0.1)
        try await wait { outputs.values.first?.finished == true && engine.reading?.isPrepared == true }
        // v = 0.1 × 2.5 = 0.25: all attenuation (renderer), the enhancer off.
        expectHeard(try #require(outputs.values.first), try await input(url, position: 0, speed: 1, skip: false),
            processedWith: 0.25, renderer: 0.25)
        try engine.setSpeed(2, commandID: UUID())
        engine.setSkipSilence(true, commandID: UUID())
        engine.seek(to: 300, commandID: UUID())
        try await wait { outputs.values.count == 2 && outputs.values[1].finished && engine.reading?.sample.positionMilliseconds == 300 }
        let seeked = try await input(url, position: 300, speed: 2, skip: true)
        expectHeard(outputs.values[1], seeked, processedWith: 0.25, renderer: 0.25)
        try engine.setSleepTimerVolume(1)
        // The restore reaches the renderer at once; the already queued audio keeps the gain history it was
        // processed with (no boost) until it drains, and nothing is flushed or restarted.
        expectHeard(outputs.values[1], seeked, processedWith: 0.25, renderer: 2.5)
        #expect(!outputs.values[1].playing && outputs.values[1].playingChanges.allSatisfy { !$0.playing })
    }

    @Test func retiredOutputCannotFailReplacementAndSeekStartsAtTheCurrentBoost() async throws {
        let (url, _) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let outputs = Outputs()
        let activeFactory = try self.factory(url, outputs)
        let owner = PCMRecoverySession(parameters: .init(speed: 1, skipSilence: false),
            lastPlayedMilliseconds: { 0 }, synchronizeStatistics: {}, factory: activeFactory.make)
        defer { owner.close() }
        try await owner.seekPaused(to: 0)
        let first = outputs.values[0]
        try owner.setVolumeAdaptation(.heavyBoost)
        #expect(first.rendererVolume == 1 && first.playingChanges.isEmpty)
        let stale = first.onFailure
        try await owner.seekPaused(to: 300)
        stale?(NativeSampleBufferTransport.Failure.flushed)
        #expect(owner.failure == nil && first.closed)
        #expect(owner.parameters.volume == .heavyBoost)
        // A new output starts with the current boost from its first frame, no ramp, fresh envelope.
        expectHeard(outputs.values[1], try await input(url, position: 300, speed: 1, skip: false), processedWith: 2.5, renderer: 2.5)
    }

    @Test func nativeCoordinatorAppliesSavedAndLiveVolumeAcrossSeek() async throws {
        let helper = PCMPlaybackEngineTests()
        try await helper.withPlayer(nativeOutput: true) { store, player, engine, outputs, _, _ in
            try await store.updatePreferences(feedID: 1) { $0.volumeAdaptation = .lightReduction }
            try await player.select(episodeID: 1, play: false)
            try await helper.wait { player.phase == .paused }
            for setting in FeedVolumeAdaptation.displayOrder {
                try await store.updatePreferences(feedID: 1) { $0.volumeAdaptation = setting }
                try await player.refreshVolumeAdaptation(feedID: 1)
            }
            #expect(player.volumeAdaptation == .heavyBoost && outputs.nativeValues.count == 1)
            #expect(outputs.nativeValues[0].rendererVolume == 1 && outputs.nativeValues[0].isMuted)
            try await player.play()
            try await helper.wait { (engine.reading?.sample.positionMilliseconds ?? 0) > 50 }
            try await player.pause()
            try await player.seek(to: 200)
            try await helper.wait { outputs.nativeValues.count == 2 && engine.reading?.sample.positionMilliseconds == 200 && !engine.reading!.buffering }
            #expect(player.volumeAdaptation == .heavyBoost && player.phase == .paused)
            try await store.updatePreferences(feedID: 1) { $0.volumeAdaptation = .lightReduction }
            try await player.refreshVolumeAdaptation(feedID: 1)
            #expect(outputs.nativeValues[1].rendererVolume == 0.5 && outputs.nativeValues[1].isMuted)
            try await store.updatePreferences(feedID: 1) { $0.volumeAdaptation = .heavyBoost }
            try await player.refreshVolumeAdaptation(feedID: 1)
            #expect(outputs.nativeValues[1].rendererVolume == 1)
            try await player.play()
            try await helper.wait { (engine.reading?.sample.positionMilliseconds ?? 0) > 250 }
            try await player.pause()
            #expect(try await store.volumeAdaptation(forEpisode: 1) == .heavyBoost)
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }
}
