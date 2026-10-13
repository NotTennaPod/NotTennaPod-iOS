import CoreMedia
import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct PCMPlaybackFactoryTests {
    typealias Transport = SampleBufferPCMOutputTests.Transport
    private func fixture() throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures"))
#else
        try #require(Bundle(for: PlaybackFactoryFixtures.self).url(forResource: "playback-30sec", withExtension: "mp3"))
#endif
    }
    private func directory() -> URL { .temporaryDirectory.appendingPathComponent("playback-factory-\(UUID())") }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(predicate())
    }
    private func play(_ factory: PCMRecoveryFactory, outputs: PCMPlaybackEngineTests.Outputs) async throws -> Data {
        let session = try await factory.make(positionMilliseconds: 0, parameters: .init(speed: 1, skipSilence: false))
        defer { session.close() }
        let output = try #require(outputs.values.last)
        try await session.prepare(); try session.play()
        let deadline = ContinuousClock.now + .seconds(10)
        while session.state != .ended, session.failure == nil, ContinuousClock.now < deadline {
            if output.playing { output.currentTime = output.end; output.onTimeChanged?() }
            await Task.yield()
        }
        try #require(session.state == .ended && session.failure == nil)
        var bytes = Data()
        for buffer in output.buffers {
            bytes.append(try #require(buffer.content.withContiguousStorageIfAvailable { Data($0) }))
        }
        return bytes
    }
    private func sounds(_ actual: Data, like expected: Data) -> Bool {
        func pcm(_ data: Data) -> [Int16] { data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) } }
        return AudibleMatch.matches(pcm(actual), pcm(expected), channels: 1, sampleRate: 44100)
    }
    private func samples() async throws -> Data {
        let decoder = try NativePCMDecoder(url: fixture())
        var result = Data()
        while let packet = try await decoder.next() { result.append(packet.samples.withUnsafeBytes { Data($0) }) }
        await decoder.cancel()
        return result
    }

    @Test(arguments: [false, true])
    func streamedEpisodesReplayOfflineIncludingAfterRelaunch(proxyEnabled: Bool) async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let media = try Data(contentsOf: fixture()), expected = try await samples()
        let credentials = FeedCredentials(username: "graph", password: "captured")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            return .init(headers: ["Content-Type": "audio/mpeg", "ETag": "\"original\""], body: media)
        }
        defer { server.stop() }
        let base = proxyEnabled ? URL(string: "http://factory.invalid")! : server.url
        let urls = [base.appendingPathComponent("first.mp3"), base.appendingPathComponent("second.mp3")]
        let proxy = proxyEnabled ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let outputs = PCMPlaybackEngineTests.Outputs()
        func owner() -> PCMPlaybackFactory {
            PCMPlaybackFactory(cacheDirectory: root, makeTransport: {
                let value = Transport(); outputs.values.append(value); return value
            })
        }
        var graph: PCMPlaybackFactory? = owner()
        for url in urls {
            let factory = try await graph!.make(.mp3(url, proxy: proxy, credentials: credentials))
            let decoded = try await play(factory, outputs: outputs)
            #expect(sounds(decoded, like: expected))
        }
        // Offline: both episodes replay from the loaded data.
        server.stop()
        for url in urls {
            let factory = try await graph!.make(.mp3(url, proxy: proxy, credentials: credentials))
            let decoded = try await play(factory, outputs: outputs)
            #expect(sounds(decoded, like: expected))
        }
        // After the player is torn down and recreated (relaunch), still offline.
        graph = nil
        try await wait { (try? SharedStreamingCache(directory: root)) != nil }
        let reopened = owner()
        for url in urls {
            let factory = try await reopened.make(.mp3(url, proxy: proxy, credentials: credentials))
            let decoded = try await play(factory, outputs: outputs)
            #expect(sounds(decoded, like: expected))
        }
        #expect(outputs.values.allSatisfy { $0.closed })
    }

    @Test func queuePlaysThroughMarksPlayedAndReplaysOffline() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = root.appendingPathComponent("streaming")
        let media = try Data(contentsOf: fixture()), expected = try await samples()
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mpeg", "ETag": "\"original\""], body: media)
        }
        defer { server.stop() }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let feedURL = server.url.appendingPathComponent("feed")
        let episodes = (1...2).map { index in
            ParsedEpisode(identifier: "\(index)", title: "Episode \(index)",
                media: ParsedMedia(url: server.url.appendingPathComponent("\(index).mp3").absoluteString,
                    size: Int64(media.count), durationMilliseconds: 30040))
        }
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Factory", episodes: episodes),
            source: feedURL.absoluteString, responseURL: feedURL, validator: nil, permanentRedirectURL: nil))
        let outputs = PCMPlaybackEngineTests.Outputs()
        do {
            let owner = PCMPlaybackFactory(cacheDirectory: cache, makeTransport: {
                let output = Transport(); outputs.values.append(output); return output
            })
            let engine = PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(),
                resolveFactory: { _, url in try await owner.make(.mp3(url, proxy: PodcastProxy())) }, positionTicker: outputs.ticker)
            let player = PlaybackCoordinator(store: store, engine: engine, preferences: { _ in
                var value = PlaybackPreferences(); value.end.smartMarkAsPlayedSeconds = 0; return value
            })
            func finish() async throws {
                let deadline = ContinuousClock.now + .seconds(10)
                while player.phase != .idle, player.phase != .failed, ContinuousClock.now < deadline {
                    if let output = outputs.values.last, output.playing {
                        output.currentTime = output.end; output.onTimeChanged?()
                    }
                    await Task.yield()
                }
                try #require(player.phase == .idle)
                try await player.awaitPendingOperations()
            }
            _ = try await store.enqueue([1, 2])
            try await player.select(episodeID: 1)
            try await finish()
            #expect(try await store.queue().isEmpty)
            #expect(try await store.playbackSession() == nil)
            for id: Int64 in [1, 2] {
                let episode = try #require(try await store.episode(id: id))
                #expect(episode.userState.playState == .played && episode.userState.positionMilliseconds == 0)
            }
            server.stop()
            try await player.select(episodeID: 1, play: false)
            try await wait { player.phase == .paused || player.phase == .failed }
            try #require(player.phase == .paused && !player.wantsPlayback)
            try await player.play()
            try await finish()
            // Every playback (two streamed, one offline replay) heard the whole episode.
            for output in outputs.values {
                var actual = Data()
                for buffer in output.buffers {
                    actual.append(try #require(buffer.content.withContiguousStorageIfAvailable { Data($0) }))
                }
                #expect(sounds(actual, like: expected))
            }
            try await player.stop()
            #expect(engine.reading == nil && outputs.values.allSatisfy(\.closed))
        }
        try await store.close()
    }

    @Test func brokenStreamingCacheDoesNotBlockDownloadedEpisodes() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = root.appendingPathComponent("streaming")
        try Data([19]).write(to: cache) // A file obstructs creation of this test-owned directory.
        let outputs = PCMPlaybackEngineTests.Outputs()
        var graph: PCMPlaybackFactory? = PCMPlaybackFactory(cacheDirectory: cache, makeTransport: {
            let value = Transport(); outputs.values.append(value); return value
        })
        let source = PCMPlaybackFactory.Source.mp3(URL(string: "http://unused.invalid/audio.mp3")!, proxy: PodcastProxy())
        await #expect(throws: (any Error).self) { try await graph!.make(source) }
        let local = try await graph!.make(.local(fixture()))
        let actual = try await play(local, outputs: outputs)
        #expect(sounds(actual, like: try await samples()))
        // Once the obstruction is gone, a new player can stream again.
        try FileManager.default.removeItem(at: cache)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        graph = nil
        let replacement = PCMPlaybackFactory(cacheDirectory: cache, makeTransport: { Transport() })
        _ = try await replacement.make(source)
    }
}
private final class PlaybackFactoryFixtures: NSObject {}
