import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized) struct PCMLocalSourceSelectionTests {
    nonisolated static let files = ["StreamingFormats/tone.wav", "StreamingFormats/tone.flac", "FLACVariants/variable.flac", "FLACVariants/variable-table.flac"]
    private func fixture(_ path: String) throws -> URL {
        let pieces = path.split(separator: "/").map(String.init)
#if SWIFT_PACKAGE
        return try #require(Bundle.module.url(forResource: pieces.last!, withExtension: nil, subdirectory: pieces[0] == "Root" ? "Fixtures" : "Fixtures/" + pieces[0]))
#else
        return try #require(Bundle(for: LocalSelectionFixtures.self).url(forResource: pieces.last!, withExtension: nil, subdirectory: pieces[0] == "FLACVariants" ? pieces[0] : nil))
#endif
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(predicate())
    }
    private func expected(_ path: String) throws -> Data {
        let file = try AVAudioFile(forReading: fixture(path.contains("variable") ? "StreamingFormats/tone.flac" : path), commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        var data = Data()
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: UInt32(min(4096, file.length - file.framePosition)))
            try #require(buffer.frameLength > 0)
            data.append(Data(bytes: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * Int(file.processingFormat.channelCount) * 2))
        }
        return data
    }
    private func finish(_ session: SampleBufferPlaybackSession, output: SampleBufferPCMOutputTests.Transport) async throws -> Data {
        try session.play()
        let deadline = ContinuousClock.now + .seconds(10)
        while session.state != .ended, session.failure == nil, ContinuousClock.now < deadline {
            if output.playing { output.currentTime = output.end; output.onTimeChanged?() }
            await Task.yield()
        }
        try #require(session.state == .ended && session.failure == nil)
        var data = Data()
        for buffer in output.buffers { data.append(try #require(buffer.content.withContiguousStorageIfAvailable { Data($0) })) }
        session.close()
        return data
    }

    @Test(arguments: files, ["download", "wrong.mp3", "opaque.media"])
    func downloadedFileWithAnyNamePlaysFromStartAndSeekTarget(path: String, filename: String) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("selected-local-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(filename), cache = root.appendingPathComponent("cache")
        try FileManager.default.copyItem(at: fixture(path), to: url)
        try Data([19]).write(to: cache)
        let outputs = PCMPlaybackEngineTests.Outputs()
        let owner = PCMPlaybackFactory(cacheDirectory: cache, maximumOutputFrames: 1024, makeTransport: {
            let output = SampleBufferPCMOutputTests.Transport(); outputs.values.append(output); return output
        })
        // Capture the existing shared-cache failure, then require local playback
        // through that same graph without touching the obstructing file.
        await #expect(throws: (any Error).self) { try await owner.make(.remote(URL(string: "http://unused.invalid/audio")!, proxy: PodcastProxy())) }
        let factory = try await owner.make(.local(url))
        #expect(factory.providesSourceDuration)
        try FileManager.default.removeItem(at: url)
        try Data("Replacement after selection, before any decoder opens".utf8).write(to: url)
        let all = try expected(path)
        for start: Int64 in [4000, 0] {
            let session = try await factory.make(positionMilliseconds: start, parameters: .init(speed: 1, skipSilence: false))
            defer { session.close() }
            let output = try #require(outputs.values.last)
            try await session.prepare()
            // Shown position lands within 0.25 s of the requested start.
            let position = try #require(try session.mediaMicroseconds)
            #expect(abs(position - start * 1000) <= 250_000)
            #expect(session.sourceDurationMilliseconds == 8000 && session.sourceSeekable == true)
            let firstFrame = Int((Double(position) * 48_000 / 1_000_000).rounded())
            let actual = try await finish(session, output: output)
            // Lossless: exactly the file's audio from the shown position to the end.
            #expect(actual == Data(all.dropFirst(firstFrame * 2)) && output.closed)
        }
        // Newly selecting the replaced (non-audio) file fails instead of playing.
        let fresh = try await owner.make(.local(url))
        await #expect(throws: (any Error).self) { try await fresh.make(positionMilliseconds: 0, parameters: .init(speed: 1, skipSilence: false)) }
    }

    @Test(arguments: files + ["Root/playback-30sec.mp3"])
    func coordinatorSavesPlaybackAfterSeekAndRestoresBeforeCompletion(path: String) async throws {
        let isMP3 = path.hasSuffix(".mp3"), duration: Int32 = path.hasSuffix(".mp3") ? 30040 : 8000
        let root = URL.temporaryDirectory.appendingPathComponent("selected-local-coordinator-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("episode.media"), database = root.appendingPathComponent("library.sqlite"), cache = root.appendingPathComponent("cache")
        try FileManager.default.copyItem(at: fixture(path), to: url)
        let store = try FeedLibraryStore(url: database)
        _ = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Downloaded", episodes: [
            .init(identifier: "one", title: "Episode", media: .init(url: "https://unused.invalid/wrong.mp3", size: 0, durationMilliseconds: 999000))]),
            source: "https://unused.invalid/feed", responseURL: URL(string: "https://unused.invalid/feed")!, validator: nil, permanentRedirectURL: nil))
        try await store.updateEpisode(id: 1) { $0.userState.isDownloaded = true; $0.userState.localFileURL = url.path }
        func graph(_ store: FeedLibraryStore) -> (PlaybackCoordinator, PCMPlaybackEngine, PCMPlaybackEngineTests.Outputs) {
            let outputs = PCMPlaybackEngineTests.Outputs()
            let owner = PCMPlaybackFactory(cacheDirectory: cache, maximumOutputFrames: 1024, makeTransport: {
                let output = SampleBufferPCMOutputTests.Transport(); outputs.values.append(output); return output
            })
            let engine = PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), resolveFactory: { _, selected in
                #expect(selected == url)
                return try await owner.make(.local(selected))
            }, positionTicker: outputs.ticker, now: { 5000 })
            let player = PlaybackCoordinator(store: store, engine: engine, preferences: { _ in
                var result = PlaybackPreferences(); result.end.smartMarkAsPlayedSeconds = 0; return result
            }, clock: { Date(timeIntervalSince1970: 5) })
            return (player, engine, outputs)
        }
        let (player, engine, outputs) = graph(store)
        defer { engine.unload() }
        try await player.select(episodeID: 1, play: false)
        try await wait { player.phase == .paused || player.phase == .failed }
        try #require(player.phase == .paused)
        #expect(engine.reading?.sample.durationMilliseconds == duration)
        try await player.play(); try await wait { outputs.values.first?.playing == true }
        outputs.values[0].advance(2400)
        try await wait { outputs.values[0].end >= CMTime(value: 4800, timescale: 48000) }
        outputs.values[0].advance(4800)
        try await player.pause()
        #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 100)
        try await player.seek(to: 4000)
        try await wait { outputs.values.count == 2 && engine.reading?.isPrepared == true }
        #expect(outputs.values[0].closed && !outputs.values[1].playing)
        // The original retains the last played position across a paused seek.
        #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 100)
        try await player.play(); try await wait { outputs.values[1].playing }
        outputs.values[1].advance(2400)
        try await wait { outputs.values[1].end >= CMTime(value: 4800, timescale: 48000) }
        outputs.values[1].advance(4800)
        try await player.pause()
        let saved = try #require(try await store.episode(id: 1)?.userState.positionMilliseconds)
        #expect(saved >= 4100 && saved <= (isMP3 ? 4193 : 4122))
        engine.unload(); try await store.close()
        let reopened = try FeedLibraryStore(url: database)
        let (restored, nextEngine, nextOutputs) = graph(reopened)
        defer { nextEngine.unload() }
        try await restored.restore()
        #expect(restored.phase == .stopped && !restored.wantsPlayback && restored.sample?.positionMilliseconds == saved)
        try await restored.play(); try await wait { nextOutputs.values.first?.playing == true || restored.phase == .failed }
        try #require(restored.phase != .failed)
        let deadline = ContinuousClock.now + .seconds(10)
        while restored.phase != .idle, restored.phase != .failed, ContinuousClock.now < deadline {
            if let output = nextOutputs.values.last, output.playing { output.currentTime = output.end; output.onTimeChanged?() }
            await Task.yield()
        }
        try #require(restored.phase == .idle)
        try await restored.awaitPendingOperations()
        let finished = try #require(try await reopened.episode(id: 1))
        #expect(finished.userState.playState == .played && finished.userState.positionMilliseconds == 0)
        #expect(finished.details.media?.durationMilliseconds == duration && finished.userState.isDownloaded)
        #expect(try await reopened.playbackSession() == nil)
        #expect(nextOutputs.values.allSatisfy(\.closed) && !FileManager.default.fileExists(atPath: cache.path))
        nextEngine.unload(); try await reopened.close()
    }

    @Test(arguments: files)
    func selectedSourceCompletesNativeProcessedSeekRecovery(path: String) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("selected-local-native-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = PCMPlaybackFactory(cacheDirectory: root, makeTransport: { NativeSampleBufferTransport(muted: true) })
        let factory = try await owner.make(.local(fixture(path)))
        #expect(factory.providesSourceDuration)
        for start: Int64 in [7000, 7500] {
            let session = try await factory.make(positionMilliseconds: start, parameters: .init(speed: 1.5, skipSilence: true, volume: .heavyBoost))
            defer { session.close() }
            try await session.prepare(); try session.play()
            try await wait { session.state == .ended || session.failure != nil }
            #expect(session.state == .ended && session.failure == nil)
            #expect(session.writtenFrames > 0 && session.writtenFrames == session.presentedFrames)
            #expect(session.sourceDurationMilliseconds == 8000)
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
private final class LocalSelectionFixtures: NSObject {}
