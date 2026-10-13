import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

/// Exercises the application resolver and selected PCM engine with real encoded
/// media; only the output clock/session activation are deterministic test ports.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct PlaybackProcessedSelectionTests {
    private final class Transport: PCMVolumePresentationTransport {
        var currentTime = CMTime.zero
        var onTimeChanged: (@MainActor () -> Void)?
        var onFailure: (@MainActor (any Error) -> Void)?
        var buffers: [CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>] = []
        var playing = false, closed = false
        func enqueue(_ buffer: CMReadySampleBuffer<CMReadOnlyDataBlockBuffer>) async throws {
            guard !closed else { throw CancellationError() }; buffers.append(buffer)
        }
        private(set) var rendererVolume: Float = 1
        func setRendererVolume(_ volume: Float) { rendererVolume = volume }
        func setPlaying(_ playing: Bool, at time: CMTime) { self.playing = playing; currentTime = time }
        func observeEnd(_ time: CMTime) {}
        func finishEnqueuing() {}
        func stopMonitoring() {}
        func close() { playing = false; closed = true }
        func consumeAvailable() {
            guard playing, let last = buffers.last else { return }
            currentTime = CMTimeAdd(last.presentationTimeStamp, last.duration)
            onTimeChanged?()
        }
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }
    private final class Selection {
        var outputs: [Transport] = []
        var failures: [String] = []
        var ended = false
        var publications = 0
    }
    private func withSelected(_ url: URL, _ body: (ApplicationPlaybackEngine, Selection) async throws -> Void) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("selected-controls-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Controls", episodes: [
            ParsedEpisode(identifier: "one", title: "Media", media: ParsedMedia(url: url.absoluteString, size: 0, durationMilliseconds: 0))]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        let state = Selection()
        let factory = PCMPlaybackFactory(cacheDirectory: directory.appendingPathComponent("cache"), makeTransport: {
            let output = Transport(); state.outputs.append(output); return output
        })
        let engine = ApplicationPlaybackEngine(muted: true, source: { _ in url }, localAccess: nil, factories: factory,
            makePCMEngine: { captured, source in
                PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), resolveFactory: { _, _ in captured }, source: { _ in source })
            })
        defer { engine.unload() }
        engine.bindStatistics(lastPlayed: { _ in 0 }, synchronize: { _ in })
        engine.onEvent = { event in
            state.publications += 1
            if case .failed(_, let message) = event { state.failures.append(message) }
            if case .ended = event { state.ended = true }
        }
        engine.load(episode: try #require(try await store.episode(id: 1)), generation: UUID(), positionMilliseconds: 0)
        try await wait { !state.failures.isEmpty || engine.reading?.isPrepared == true && engine.reading?.buffering == false }
        try #require(state.failures.isEmpty)
        try await body(engine, state)
        engine.unload(); try await store.close()
    }
    private func fixture(_ name: String, directory: String = "PlaybackDecoder") throws -> URL {
        try FFmpegBufferedSeekReferenceTests.resource(name, directory: directory)
    }
    private func samples(_ transport: Transport) throws -> [Int16] {
        try transport.buffers.flatMap { packet in
            let bytes = try #require(packet.content.withContiguousStorageIfAvailable { Data($0) })
            return bytes.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        }
    }
    private func drain(_ engine: ApplicationPlaybackEngine, _ state: Selection) async throws {
        engine.play(commandID: UUID())
        let deadline = ContinuousClock.now + .seconds(8)
        while !state.ended && state.failures.isEmpty && ContinuousClock.now < deadline {
            state.outputs.last?.consumeAvailable(); await Task.yield()
        }
        try #require(state.failures.isEmpty && state.ended)
    }

    @Test func actualAudioTrackSelectionPublishesNewIdentityAndPreservesLatestIntent() async throws {
        try await withSelected(fixture("audio-multitrack.m4a")) { engine, state in
            #expect(engine.mediaTracks.map(\.id) == [0, 1])
            #expect(engine.mediaTracks.map(\.title) == ["English 440 Hz", "Deutsch 880 Hz"])
            #expect(engine.selectedAudioTrackID == 0 && engine.videoDisplayLayer == nil)
            let token = try #require(engine.mediaPresentationID), publications = state.publications
            let command = UUID()
            try engine.selectAudioTrack(id: 1, commandID: command)
            #expect(engine.mediaPresentationID == nil && engine.reading?.buffering == true)
            try await wait { !state.failures.isEmpty || engine.selectedAudioTrackID == 1 && engine.reading?.buffering == false }
            try #require(state.failures.isEmpty)
            #expect(engine.mediaPresentationID != token && engine.mediaPresentationID != nil)
            #expect(engine.reading?.commandID == command && !state.outputs.last!.playing && state.publications > publications)
            let pcm = try samples(state.outputs.last!)
            let crossings = zip(pcm, pcm.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
            #expect(abs(Double(crossings) / (Double(pcm.count) / 48_000) - 880) < 20)
            // A queued selection cannot override the user's immediate return or seek.
            try engine.selectAudioTrack(id: 0, commandID: UUID())
            try engine.selectAudioTrack(id: 1, commandID: UUID())
            let last = UUID(); engine.seek(to: 4_000, commandID: last)
            try await wait { !state.failures.isEmpty || engine.reading?.commandID == last && engine.reading?.buffering == false }
            try #require(state.failures.isEmpty)
            #expect(engine.selectedAudioTrackID == 1 && engine.reading?.sample.positionMilliseconds == 4_000)
            #expect(state.outputs.dropLast().allSatisfy(\.closed) && !state.outputs.last!.playing)
            try await drain(engine, state)
            #expect(state.outputs.last?.currentTime == CMTime(value: 4, timescale: 1))
        }
    }

    @Test func selectedWaveAppliesLiveGainThenSpeedAndSilenceWithoutPlayingPausedOutput() async throws {
        let (url, _) = try PCMTestFixture.waveFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var durations: [Double] = []
        for (speed, silence) in [(Float(1), false), (Float(1.5), false), (Float(1.5), true)] {
            try await withSelected(url) { engine, state in
                let original = try samples(state.outputs[0])
                #expect(original.prefix(4) == [8192, 8192, -8192, -8192])
                // A boost applies to audio processed from now on: queued audio is neither flushed nor
                // re-processed, and the paused renderer is not restarted.
                try engine.setVolumeAdaptation(.heavyBoost)
                #expect(try samples(state.outputs[0]) == original && state.outputs[0].rendererVolume == 1)
                #expect(!state.outputs[0].playing && state.outputs[0].currentTime == .zero)
                try engine.setVolumeAdaptation(.heavyReduction)
                #expect(try samples(state.outputs[0]) == original && state.outputs[0].rendererVolume == 0.2)
                try engine.setVolumeAdaptation(.off)
                #expect(try samples(state.outputs[0]) == original && state.outputs[0].rendererVolume == 1)
                let command = UUID(); try engine.setSpeed(speed, commandID: command)
                engine.setSkipSilence(silence, commandID: command)
                try await wait { engine.reading?.buffering == false && engine.reading?.speed == speed && engine.reading?.skipSilence == silence }
                #expect(!state.outputs.last!.playing)
                try await drain(engine, state)
                durations.append(state.outputs.last!.currentTime.seconds)
                #expect(engine.reading?.sample.durationMilliseconds == 600)
            }
        }
        // Already queued samples retain their committed old parameter segment.
        // Compare complete live runs on independently generated identical audio:
        // speed must shorten output, and skipping500ms of quiet must shorten it further.
        #expect(durations[0] == 0.6)
        #expect(durations[1] < durations[0] && durations[2] < durations[1])
    }

    @Test func unknownLengthRemoteMultitrackRetainsBytesForBackwardSeekAndSelection() async throws {
        let bytes = try Data(contentsOf: fixture("audio-multitrack.m4a"))
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mp4"], body: bytes, includeAutomaticContentLength: false)
        }
        defer { server.stop() }
        try await withSelected(server.url) { engine, state in
            #expect(engine.mediaTracks.map(\.id) == [0, 1])
            let first = UUID(); engine.seek(to: 4_000, commandID: first)
            try await wait { !state.failures.isEmpty || engine.reading?.commandID == first && engine.reading?.buffering == false }
            try #require(state.failures.isEmpty)
            #expect(engine.reading?.sample.positionMilliseconds == 4_000)
            try engine.selectAudioTrack(id: 1, commandID: UUID())
            try await wait { !state.failures.isEmpty || engine.selectedAudioTrackID == 1 && engine.reading?.buffering == false }
            let back = UUID(); engine.seek(to: 0, commandID: back)
            try await wait { !state.failures.isEmpty || engine.reading?.commandID == back && engine.reading?.buffering == false }
            try #require(state.failures.isEmpty)
            #expect(engine.reading?.sample.positionMilliseconds == 0 && server.requests.count == 1)
            try await drain(engine, state)
            #expect(engine.reading?.sample.durationMilliseconds == 8_000)
            #expect(state.outputs.last?.currentTime == CMTime(value: 8, timescale: 1))
        }
    }

    private func toneEnergy(_ samples: [Int16], channel: Int, frequency: Double) -> Double {
        let coefficient = 2 * cos(2 * Double.pi * frequency / 48_000)
        var previous = 0.0, beforePrevious = 0.0
        for offset in stride(from: channel, to: samples.count, by: 2) {
            let current = Double(samples[offset]) + coefficient * previous - beforePrevious
            beforePrevious = previous; previous = current
        }
        let frames = Double(samples.count / 2)
        return (previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious) / (frames * frames)
    }

    private func processedProfile(_ input: [Int16], frames: Int) throws -> [Int16] {
        // Independent public Apple sequential PCM supplies the source waveform;
        // established codec-independent processors supply their separately tested
        // transforms. This integration oracle detects dropped/reordered channels
        // and bypassed settings; it is not a new DSP implementation oracle.
        var silence = try SilenceSkippingProcessor(sampleRate: 48_000, channels: 2)
        var rate = try PCMSpeedProcessor(sampleRate: 48_000, channels: 2, speed: 1.5)
        var samples: [Int16] = []
        for offset in stride(from: 0, to: input.count, by: frames * 2) {
            samples += try rate.process(silence.process(Array(input[offset..<min(input.count, offset + frames * 2)])))
        }
        samples += try rate.process(silence.finish()); samples += rate.finish()
        var volume = PodcastLoudnessCompressor(); volume.configure(.heavyBoost, sampleRate: 48_000)
        for offset in stride(from: 0, to: samples.count, by: 2) {
            let peak = max(abs(Float(samples[offset]) / 32768), abs(Float(samples[offset + 1]) / 32768))
            let multiplier = volume.multiplier(peak: peak)
            for channel in 0..<2 {
                let value = volume.output(Float(samples[offset + channel]) / 32768, multiplier: multiplier)
                samples[offset + channel] = Int16(clamping: Int(max(-1, min(1, value)) * 32768))
            }
        }
        return samples
    }

    @Test(arguments: ["StreamingFormats/tone.wav", "StreamingFormats/tone.aac", "StreamingFormats/tone.m4a",
        "StreamingFormats/tone.flac", "StreamingFormats/tone-vorbis.ogg", "StreamingFormats/tone-opus.webm",
        "PlaybackDecoder/amr-nb.amr", "PlaybackDecoder/amr-wb.amr", "PlaybackDecoder/ogg-flac.ogg",
        "PlaybackDecoder/wav-ima.wav", "PlaybackDecoder/wav-alaw.wav", "PlaybackDecoder/wav-mulaw.wav",
        "PlaybackDecoder/wav-float.wav", "PlaybackDecoder/wav-s24.wav", "PlaybackDecoder/wav-u8.wav",
        "AACProfiles/he-stereo.aac", "AACProfiles/hev2-stereo.aac", "AACProfiles/he-stereo.m4a", "AACProfiles/hev2-stereo.m4a"])
    func applicationSelectsProcessedAudioWithPersistedEffectsAndPausedSeek(path: String) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("selected-processed-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parts = path.split(separator: "/")
        let url = try fixture(String(parts[1]), directory: String(parts[0]))
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Processing", episodes: [
            ParsedEpisode(identifier: "one", title: "Media", media: ParsedMedia(url: url.absoluteString, size: 0, durationMilliseconds: 0))]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        let episode = try #require(try await store.episode(id: 1))
        var outputs: [Transport] = [], pcm: PCMPlaybackEngine?, failures: [String] = [], ended = false
        let factory = PCMPlaybackFactory(cacheDirectory: directory.appendingPathComponent("cache"), makeTransport: {
            let output = Transport(); outputs.append(output); return output
        })
        let engine = ApplicationPlaybackEngine(muted: true, source: { _ in url }, localAccess: nil, factories: factory,
            makePCMEngine: { captured, source in
                let result = PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), resolveFactory: { _, _ in captured }, source: { _ in source })
                pcm = result; return result
            })
        defer { engine.unload() }
        engine.bindStatistics(lastPlayed: { _ in 0 }, synchronize: { _ in })
        engine.onEvent = { event in
            if case .failed(_, let message) = event { failures.append(message) }
            if case .ended = event { ended = true }
        }
        let generation = UUID()
        engine.load(episode: episode, generation: generation, positionMilliseconds: 1000)
        try engine.setSpeed(1.5, commandID: generation)
        engine.setSkipSilence(true, commandID: generation)
        try engine.setVolumeAdaptation(.heavyBoost)
        try await wait { !failures.isEmpty || engine.reading?.isPrepared == true && engine.reading?.buffering == false }
        try #require(failures.isEmpty)
        #expect(pcm != nil && engine.supportsSkipSilence)
        #expect(engine.reading?.speed == 1.5 && engine.reading?.skipSilence == true)
        #expect(outputs.count == 1 && !outputs[0].playing && !outputs[0].buffers.isEmpty)
        if path.hasPrefix("AACProfiles/") {
            let packet = try #require(outputs[0].buffers.first)
            #expect(packet.totalSampleSize == packet.sampleCount * 4)
            // HEv2 positioned decoding can begin with a correlated transient.
            // The full zero replay below checks the channels with independent native PCM.
        }
        let duration = try #require(engine.reading?.sample.durationMilliseconds)
        if path.contains("amr-") { #expect(duration == -1 || duration >= 2900) }
        else { #expect(duration >= 2900) }
        // Loading at 1 s lands there (within an imperceptible 250 ms, which covers codec
        // packet boundaries). Replay then returns to zero and presents the source through EOF.
        let coldPosition = try #require(engine.reading?.sample.positionMilliseconds)
        #expect(abs(coldPosition - 1000) <= 250)
        #expect(outputs[0].currentTime == .zero)
        let oldPresentation = try #require(engine.mediaPresentationID)
        let command = UUID()
        engine.seek(to: 0, commandID: command)
        #expect(engine.reading?.buffering == true && engine.reading?.commandID == command)
        #expect(engine.mediaPresentationID == nil)
        try await wait { !failures.isEmpty || outputs.count == 2 && engine.reading?.buffering == false }
        try #require(failures.isEmpty)
        #expect(outputs[0].closed && !outputs[1].playing)
        #expect(engine.reading?.sample.positionMilliseconds == 0)
        #expect(engine.mediaPresentationID != nil && engine.mediaPresentationID != oldPresentation)
        engine.play(commandID: UUID())
        let deadline = ContinuousClock.now + .seconds(8)
        while !ended && failures.isEmpty && ContinuousClock.now < deadline {
            outputs.last?.consumeAvailable(); await Task.yield()
        }
        #expect(failures.isEmpty && ended)
        if path.hasPrefix("AACProfiles/") {
            let adts = try fixture(String(parts[1]).replacingOccurrences(of: ".m4a", with: ".aac"), directory: "AACProfiles")
            let native = try PCNativeAACOracle().sequential(adts, target: 0)
            let expected = try processedProfile(native, frames: path.hasSuffix(".m4a") ? 2048 : 4096)
            let actual = try samples(outputs.last!)
            PCMTestFixture.expectAudibleDuration(actual, expectedFrames: expected.count / 2, channels: 2, sampleRate: 48_000)
            // Fixture provenance gives independent440Hz-left /733Hz-right markers.
            // Cross-instance native decode can differ by a few PCM units; sample
            // identity is diagnostic, while exact counts and channel-specific
            // tone dominance detect truncation, swapped channels and downmixing.
            let left440 = toneEnergy(actual, channel: 0, frequency: 440)
            let left733 = toneEnergy(actual, channel: 0, frequency: 733)
            let right440 = toneEnergy(actual, channel: 1, frequency: 440)
            let right733 = toneEnergy(actual, channel: 1, frequency: 733)
            #expect(left440 > left733 && right733 > right440)
            #expect(left440 > right440 && right733 > left733)
            #expect(left440 > toneEnergy(actual, channel: 0, frequency: 480))
            #expect(right733 > toneEnergy(actual, channel: 1, frequency: 773))

        }
        let renderedSeconds = outputs.last?.currentTime.seconds ?? 0
        let sourceSeconds = path.contains("amr-") ? 3.0 : Double(duration) / 1000
        if path.contains("amr-") { #expect(engine.reading?.sample.durationMilliseconds == 3000) }
        // Independently generated fixtures are non-silent tones. The actual
        // output clock must shorten at1.5x; an ignored speed setting fails here.
        #expect(renderedSeconds > sourceSeconds * 0.5 && renderedSeconds < sourceSeconds * 0.8)
        engine.unload()
        #expect(outputs.allSatisfy(\.closed) && engine.mediaPresentationID == nil)
        try await store.close()
    }
}
