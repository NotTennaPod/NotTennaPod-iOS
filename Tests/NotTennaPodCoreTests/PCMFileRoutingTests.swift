import CoreMedia
import CryptoKit
import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized) struct PCMFileRoutingTests {
    nonisolated static let names = ["playback-30sec.mp3", "tone.wav", "tone.aac", "tone.m4a", "tone.flac",
                        "tone-vorbis.ogg", "tone-opus.ogg", "tone-opus.webm", "he-stereo.m4a", "hev2-stereo.m4a"]
    private func fixture(_ name: String) throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: nil,
            subdirectory: name.hasPrefix("he") ? "Fixtures/AACProfiles" : (name.hasPrefix("playback") ? "Fixtures" : "Fixtures/StreamingFormats")))
#else
        try #require(Bundle(for: FileRoutingFixtures.self).url(forResource: name, withExtension: nil, subdirectory: name.hasPrefix("he") ? "AACProfiles" : nil))
#endif
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(predicate())
    }
    /// Expected audio: sample count (8 s tones / 30 s MP3) and, where an
    /// independent native decode exists, the reference samples themselves.
    private func expected(_ name: String) async throws -> (samples: [Int16]?, count: Int, channels: Int, rate: Int) {
        // Vorbis (stereo) and Opus (mono) lengths from the original codec timing (Fixtures/android-codec-timing.json).
        if name == "tone-vorbis.ogg" { return (nil, 384000 * 2, 2, 48000) }
        if name == "tone-opus.ogg" || name == "tone-opus.webm" { return (nil, 384648, 1, 48000) }
        // Implicit-profile M4A is compared with the packet-identical ADTS file.
        let reference = name.hasPrefix("he") ? name.replacingOccurrences(of: ".m4a", with: ".aac") : name
        let decoder = try NativePCMDecoder(url: fixture(reference))
        var samples: [Int16] = [], channels = 1, rate = 48000
        while let packet = try await decoder.next() {
            samples += packet.samples; channels = packet.channels; rate = packet.sampleRate
        }
        await decoder.cancel()
        return (samples, samples.count, channels, rate)
    }

    @Test(arguments: names, ["download", "download.media", "download.wrong", "download.mp3"])
    func downloadedFilesUseContentAndCompleteThroughCoordinator(name: String, filename: String) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("file-routing-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: fixture(name), to: url)
        let expected = try await expected(name)
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        _ = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Local", episodes: [
            .init(identifier: "one", title: "One", media: .init(url: "http://unused.invalid/wrong.mp3", size: 0,
                mimeType: "audio/mpeg", durationMilliseconds: 999000))]), source: "http://unused.invalid/feed",
            responseURL: URL(string: "http://unused.invalid/feed")!, validator: nil, permanentRedirectURL: nil))
        try await store.updateEpisode(id: 1) { $0.userState.isDownloaded = true; $0.userState.localFileURL = url.path }
        let outputs = PCMPlaybackEngineTests.Outputs()
        let cache = root.appendingPathComponent("cache")
        let owner = PCMPlaybackFactory(cacheDirectory: cache, makeTransport: {
            let value = SampleBufferPCMOutputTests.Transport(); outputs.values.append(value); return value
        })
        let engine = PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), resolveFactory: { _, selected in
            #expect(selected == url)
            return try await owner.make(.local(selected))
        }, positionTicker: outputs.ticker)
        defer { engine.unload() }
        let player = PlaybackCoordinator(store: store, engine: engine, preferences: { _ in
            var value = PlaybackPreferences(); value.end.smartMarkAsPlayedSeconds = 0; return value
        })
        var failures: [String] = []
        let consumeEvent = engine.onEvent
        engine.onEvent = { event in
            if case .failed(_, let message) = event { failures.append(message) }
            consumeEvent?(event)
        }
        if filename == "download.wrong", !name.contains("ogg"), !name.contains("webm") {
            let direct = try NativePCMDecoder(url: url)
            await direct.cancel()
        }
        try await player.select(episodeID: 1, play: false)
        try await wait { player.phase == .paused || player.phase == .failed }
        try #require(player.phase == .paused, "Native failure: \(failures)")
        let duration = try #require(engine.reading?.sample.durationMilliseconds)
        #expect(duration > 0 && duration < 31000 && !FileManager.default.fileExists(atPath: cache.path))
        try await player.play()
        let output = try #require(outputs.values.first)
        let deadline = ContinuousClock.now + .seconds(10)
        while player.phase != .idle, player.phase != .failed, ContinuousClock.now < deadline {
            if output.playing { output.currentTime = output.end; output.onTimeChanged?() }
            await Task.yield()
        }
        try #require(player.phase == .idle)
        var actual: [Int16] = []
        for buffer in output.buffers {
            let bytes = try #require(buffer.content.withContiguousStorageIfAvailable { Data($0) })
            actual += bytes.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        }
        // The whole episode was heard (within 50 ms) and it is real audio.
        #expect(abs(actual.count - expected.count) <= expected.rate * expected.channels / 20)
        #expect(actual.contains { $0 != 0 })
        if let reference = expected.samples {
            #expect(AudibleMatch.matches(actual, reference, channels: expected.channels, sampleRate: expected.rate))
        }
        let episode = try #require(try await store.episode(id: 1))
        #expect(episode.userState.playState == .played && episode.userState.positionMilliseconds == 0)
        #expect(episode.details.media?.durationMilliseconds == duration && output.closed)
        #expect(try await store.queue().isEmpty)
        #expect(try await store.playbackSession() == nil)
        try await store.close()
    }

    @Test(arguments: [Data(), Data("<html>not audio</html>".utf8), Data([0x4f, 0x67, 0x67, 0x53, 0, 2])])
    func malformedMediaFailsInsteadOfCompleting(bytes: Data) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("file-invalid-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("claimed.mp3"); try bytes.write(to: url)
        let owner = PCMPlaybackFactory(cacheDirectory: root.appendingPathComponent("cache"), makeTransport: {
            Issue.record("Malformed input must not allocate an output")
            return SampleBufferPCMOutputTests.Transport()
        })
        let factory = try await owner.make(.local(url))
        await #expect(throws: (any Error).self) {
            try await factory.make(positionMilliseconds: 0, parameters: .init(speed: 1, skipSilence: false))
        }
    }

    @Test func missingFileAndCancellationRemainErrors() async throws {
        let url = URL.temporaryDirectory.appendingPathComponent("absent-\(UUID()).ogg")
        await #expect(throws: (any Error).self) { try await PCMFileContainer.select(url: url) }
        let fixture = try fixture("tone-vorbis.ogg")
        let task = Task { try await PCMFileContainer.select(url: fixture) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
private final class FileRoutingFixtures: NSObject {}
