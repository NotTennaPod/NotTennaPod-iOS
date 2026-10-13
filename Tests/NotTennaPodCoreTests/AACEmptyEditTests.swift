import CoreMedia
import CryptoKit
import Foundation
import Testing
@testable import NotTennaPodCore

@Suite(.serialized, .timeLimit(.minutes(2))) struct AACEmptyEditTests {
    private struct Report: Decodable {
        let complete: Bool
        let cases: [Case]
        struct Case: Decodable {
            let file: String, startMs: Int64, ended: Bool, timedOut: Bool
            let codec: String, admittedBytes: Int, skippedBytes: Int
        }
    }
    private struct Manifest: Decodable {
        let files: [File]
        struct File: Decodable { let name: String, sha256: String }
    }
    private func fixture(_ name: String) throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/AACEmptyEdits"))
#else
        try #require(Bundle(for: EmptyEditFixtures.self).url(forResource: name, withExtension: nil, subdirectory: "AACEmptyEdits"))
#endif
    }
    private func reference(_ index: Int) throws -> (Report.Case, Data) {
        let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: fixture("android-report.json")))
        try #require(report.complete && report.cases.count == 18)
        let original = report.cases[index]
        try #require(original.ended && !original.timedOut && original.codec.isEmpty)
        try #require(original.admittedBytes == 0 && original.skippedBytes == 0)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: fixture("manifest.json")))
        let entry = try #require(manifest.files.first { $0.name == original.file })
        let bytes = try Data(contentsOf: fixture(original.file))
        try #require(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == entry.sha256)
        return (original, bytes)
    }

    @Test(arguments: 0..<18, 0..<4)
    func emptySourceFinishesWithoutPCMAndCanReopenOffline(index: Int, configuration: Int) async throws {
        let (original, bytes) = try reference(index)
        let known = configuration & 2 == 0, proxied = configuration & 1 != 0
        let credentials = FeedCredentials(username: "empty", password: "edits")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            return .init(headers: ["Content-Type": "audio/mp4"], body: bytes, includeAutomaticContentLength: known)
        }
        defer { server.stop() }
        let directory = URL.temporaryDirectory.appendingPathComponent("empty-edit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try SharedStreamingCache(directory: directory)
        let proxy = proxied ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let url = proxied ? URL(string: "http://empty-edits.invalid/opaque.media")! : server.url
        let remote = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
        defer { remote.input.cancel(); remote.relay.cancel() }
        let source = try NativeAudioPlaybackSource(remote: remote, url: url, proxy: proxy, credentials: credentials, cache: cache)
        let decoder = try await source.makeDecoder(start: CMTime(value: original.startMs, timescale: 1000))
        let first = try await decoder.next()
        // A file whose edit list removes all audio ends immediately with a
        // zero duration instead of hanging or failing.
        #expect(first == nil)
        #expect(decoder.sourceDurationMilliseconds == 0 && decoder.startTime == .zero)
        #expect(decoder.sourceSeekable == true)
        await decoder.cancel()
        guard first == nil else { return }
        server.stop()
        let replay = try await source.makeDecoder(start: CMTime(value: 5000, timescale: 1000))
        #expect(try await replay.next() == nil)
        #expect(replay.startTime == .zero && replay.sourceDurationMilliseconds == 0)
        await replay.cancel()
        if known {
            let cached = try await PCMRemoteInput.open(url: url, proxy: proxy, credentials: credentials, cache: cache)
            defer { cached.input.cancel(); cached.relay.cancel() }
            let fresh = try NativeAudioPlaybackSource(remote: cached, url: url, proxy: proxy, credentials: credentials, cache: cache)
            let offline = try await fresh.makeDecoder()
            #expect(try await offline.next() == nil)
            #expect(offline.sourceDurationMilliseconds == 0)
            await offline.cancel()
        }
    }

    @MainActor @Test(arguments: 0..<9, [false, true])
    func coordinatorCompletesAndPersistsWithoutPresentingAudio(index: Int, play: Bool) async throws {
        let (_, bytes) = try reference(index * 2)
        let credentials = FeedCredentials(username: "empty", password: "coordinator")
        let server = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == credentials.authorization(utf8: false))
            return .init(headers: ["Content-Type": "audio/mp4"], body: bytes)
        }
        defer { server.stop() }
        let root = URL.temporaryDirectory.appendingPathComponent("empty-coordinator-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let proxied = index % 2 == 1
        let url = proxied ? URL(string: "http://empty-coordinator.invalid/opaque.media")! : server.url
        let proxy = proxied ? PodcastProxy(kind: .http, host: "127.0.0.1", port: server.url.port!) : PodcastProxy()
        let database = root.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: database)
        _ = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Edited feed", episodes: [
            .init(identifier: "one", title: "Empty episode", media: .init(url: url.absoluteString, size: 0, durationMilliseconds: 4000))]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        var outputs: [SampleBufferPCMOutputTests.Transport] = []
        let factory = PCMPlaybackFactory(cacheDirectory: root.appendingPathComponent("cache"), makeTransport: {
            let output = SampleBufferPCMOutputTests.Transport(); outputs.append(output); return output
        })
        let engine = PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), resolveFactory: { _, selected in
            try await factory.make(.remote(selected, proxy: proxy, credentials: credentials))
        }, positionTicker: PCMPlaybackEngineTests.Ticker(), now: { 5000 })
        let player = PlaybackCoordinator(store: store, engine: engine, preferences: { _ in
            var result = PlaybackPreferences(); result.end.smartMarkAsPlayedSeconds = 0; return result
        }, clock: { Date(timeIntervalSince1970: 5) })
        do {
            try await player.select(episodeID: 1, play: play)
            let deadline = ContinuousClock.now + .seconds(5)
            while player.phase != .idle, ContinuousClock.now < deadline { await Task.yield() }
            try #require(player.phase == .idle, "Empty source must end normally: \(player.phase)")
            try #require(outputs.count == 1)
            #expect(outputs[0].buffers.isEmpty && !outputs[0].playing)
            #expect(try await store.episode(id: 1)?.userState.playState == .played)
            engine.unload(); try await store.close()
            let reopened = try FeedLibraryStore(url: database)
            #expect(try await reopened.episode(id: 1)?.userState.playState == .played)
            try await reopened.close()
        } catch { engine.unload(); try? await store.close(); throw error }
    }

    @MainActor @Test(arguments: 0..<9)
    func nativeOutputAndProcessedRecoveryReachEmptyEnd(index: Int) async throws {
        let (_, bytes) = try reference(index * 2)
        let server = try await LoopbackHTTPServer.start { _ in
            .init(headers: ["Content-Type": "audio/mp4"], body: bytes)
        }
        defer { server.stop() }
        let directory = URL.temporaryDirectory.appendingPathComponent("empty-native-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let factory = PCMPlaybackFactory(cacheDirectory: directory, makeTransport: { NativeSampleBufferTransport(muted: true) })
        let source = try await factory.make(.remote(server.url, proxy: PodcastProxy()))
        for start: Int64 in [0, 1500] {
            let session = try await source.make(positionMilliseconds: start,
                parameters: .init(speed: 1.5, skipSilence: true, volume: .heavyBoost))
            #expect(session.state == .idle)
            try await session.prepare()
            #expect(session.state == .ended && session.sourceEnded && session.failure == nil)
            #expect(session.writtenFrames == 0 && session.presentedFrames == 0)
            #expect(session.sourceDurationMilliseconds == 0 && session.sourceSeekable == true)
            #expect(try session.mediaMicroseconds == 0)
            session.close()
            server.stop()
        }
    }
}
private final class EmptyEditFixtures: NSObject {}
