import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.serialized) struct PCMSourceResolutionTests {
    private enum Failure: Error { case credentials }
    @MainActor private final class Gate {
        private var pending: CheckedContinuation<Void, Never>?
        private var opened = false
        var waiting = false
        func wait() async {
            waiting = true
            if opened { return }
            await withCheckedContinuation { pending = $0 }
        }
        func release() { opened = true; pending?.resume(); pending = nil }
    }
    private func fixture() throws -> URL {
#if SWIFT_PACKAGE
        try #require(Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures"))
#else
        try #require(Bundle(for: SourceResolutionFixtures.self).url(forResource: "playback-30sec", withExtension: "mp3"))
#endif
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(predicate())
    }
    private func store(_ root: URL) async throws -> FeedLibraryStore {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let episodes = (1...3).map { ParsedEpisode(identifier: "\($0)", title: "Episode \($0)",
            media: .init(url: "http://context.invalid/\($0).mp3", size: 0, durationMilliseconds: 30040)) }
        _ = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Context", episodes: episodes),
            source: "http://context.invalid/feed", responseURL: URL(string: "http://context.invalid/feed")!,
            validator: nil, permanentRedirectURL: nil))
        let file = try fixture().path
        try await store.updateEpisode(id: 2) { $0.userState.isDownloaded = true; $0.userState.localFileURL = file }
        return store
    }

    @Test func savedCredentialsAndProxyAreCapturedOnceAndLocalDownloadsBypassThem() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("source-context-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await store(root)
        let auth = FeedAuthentication(store: store, vault: SourceResolutionVault())
        let old = FeedCredentials(username: "feed", password: "original")
        let new = FeedCredentials(username: "feed", password: "replacement")
        try await auth.save(old, feedID: 1)
        let media = try Data(contentsOf: fixture())
        let first = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == old.authorization(utf8: false))
            return .init(headers: ["Content-Type": "audio/mpeg"], body: media)
        }
        defer { first.stop() }
        let second = try await LoopbackHTTPServer.start { request in
            #expect(request.headers["authorization"] == new.authorization(utf8: false))
            return .init(headers: ["Content-Type": "audio/mpeg"], body: media)
        }
        defer { second.stop() }
        var proxy = PodcastProxy(kind: .http, host: "127.0.0.1", port: first.url.port!)
        let outputs = PCMPlaybackEngineTests.Outputs(), gate = Gate()
        defer { gate.release() }
        let factory = PCMPlaybackFactory(cacheDirectory: root.appendingPathComponent("cache"), makeTransport: {
            let value = SampleBufferPCMOutputTests.Transport(); outputs.values.append(value); return value
        })
        var remoteResolutions: [Int64] = []
        let engine = PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), resolveFactory: { episode, url in
            if url.isFileURL { return try await factory.make(.local(url)) }
            let capturedProxy = proxy
            let login = try await auth.credentials(feedID: store.feedID(forEpisode: episode.id))
            remoteResolutions.append(episode.id)
            if episode.id == 1 { await gate.wait() }
            return try await factory.make(.mp3(url, proxy: capturedProxy, credentials: login))
        }, positionTicker: outputs.ticker)
        defer { engine.unload() }
        let player = PlaybackCoordinator(store: store, engine: engine)
        try await player.select(episodeID: 1)
        try await wait { gate.waiting }
        try await player.pause()
        try await player.setSpeed(1.5)
        try await player.seek(to: 4000)
        #expect(engine.reading?.sample.positionMilliseconds == 4000)
        proxy = PodcastProxy(kind: .http, host: "127.0.0.1", port: second.url.port!)
        try await auth.save(new, feedID: 1)
        gate.release()
        try await wait { (engine.reading?.isPrepared == true && player.phase == .paused) || player.phase == .failed }
        try #require(player.phase == .paused && engine.reading?.isPrepared == true)
        #expect(engine.reading?.speed == 1.5)
        // Source admission keeps the first whole decoded buffer at/after the target.
        // The fixture is44.1kHz and decoder output is bounded to4096 frames.
        let firstPosition = try #require(engine.reading?.sample.positionMilliseconds)
        #expect((4000..<4093).contains(firstPosition))
        #expect(remoteResolutions == [1] && first.requests.count == 1 && second.requests.isEmpty)
        try await player.seek(to: 8000)
        try await wait {
            outputs.values.count == 2 && !outputs.values[1].buffers.isEmpty
                && (8000..<8093).contains(engine.reading?.sample.positionMilliseconds ?? -1)
        }
        #expect(remoteResolutions == [1] && first.requests.count == 1 && second.requests.isEmpty)
        try await player.select(episodeID: 2, play: false)
        try await wait { player.phase == .paused || player.phase == .failed }
        try #require(player.phase == .paused && player.episode?.id == 2)
        #expect(remoteResolutions == [1])
        try await player.select(episodeID: 3, play: false)
        try await wait { player.phase == .paused || player.phase == .failed }
        try #require(player.phase == .paused && player.episode?.id == 3)
        #expect(remoteResolutions == [1, 3] && first.requests.count == 1 && second.requests.count == 1)
        try await player.stop()
        let allClosed = outputs.values.allSatisfy(\.closed)
        #expect(allClosed)
        try await store.close()
    }

    @Test(arguments: [false, true])
    func supersededResolutionCannotInstallSourceOrFailSuccessor(throwsAfterRelease: Bool) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("source-superseded-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await store(root), gate = Gate(), outputs = PCMPlaybackEngineTests.Outputs()
        defer { gate.release() }
        var oldExited = false, oldCancelled = false
        let url = try fixture()
        let engine = PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), resolveFactory: { episode, _ in
            if episode.id == 1 {
                await gate.wait()
                oldCancelled = Task.isCancelled
                defer { oldExited = true }
                if throwsAfterRelease { throw Failure.credentials }
            }
            return try PCMRecoveryFactory(url: url, makeTransport: {
                let value = SampleBufferPCMOutputTests.Transport(); outputs.values.append(value); return value
            })
        }, source: { _ in url }, positionTicker: outputs.ticker)
        defer { engine.unload() }
        let player = PlaybackCoordinator(store: store, engine: engine)
        try await player.select(episodeID: 1)
        try await wait { gate.waiting }
        try await player.select(episodeID: 2, play: false)
        try await wait { player.phase == .paused || player.phase == .failed }
        try #require(player.phase == .paused && player.episode?.id == 2)
        let current = engine.reading
        gate.release()
        try await wait { oldExited }
        try await player.awaitPendingOperations()
        #expect(oldCancelled && player.phase == .paused && player.episode?.id == 2)
        #expect(engine.reading == current && outputs.values.count == 1 && !outputs.values[0].playing)
        try await player.stop(); try await store.close()
    }

    @Test func currentResolutionFailureIsReportedAndNewLoadCanRetry() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("source-retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await store(root), outputs = PCMPlaybackEngineTests.Outputs()
        let url = try fixture()
        var attempts = 0
        let engine = PCMPlaybackEngine(driver: PCMPlaybackEngineTests.Driver(), resolveFactory: { _, _ in
            attempts += 1
            if attempts == 1 { throw Failure.credentials }
            return try PCMRecoveryFactory(url: url, makeTransport: {
                let value = SampleBufferPCMOutputTests.Transport(); outputs.values.append(value); return value
            })
        }, source: { _ in url }, positionTicker: outputs.ticker)
        defer { engine.unload() }
        let player = PlaybackCoordinator(store: store, engine: engine)
        try await player.select(episodeID: 1)
        try await wait { player.phase == .failed }
        #expect(outputs.values.isEmpty && engine.reading == nil && !player.wantsPlayback)
        try await player.select(episodeID: 1, play: false)
        try await wait { player.phase == .paused || player.phase == .failed }
        try #require(player.phase == .paused && attempts == 2 && outputs.values.count == 1)
        try await player.stop(); try await store.close()
    }
}
private final class SourceResolutionFixtures: NSObject {}
private final class SourceResolutionVault: SynchronizationCredentialStore, Sendable {
    private let values = Mutex<[UUID: String]>([:])
    func insert(_ password: String, id: UUID) throws { values.withLock { $0[id] = password } }
    func password(id: UUID) throws -> String {
        try values.withLock { guard let value = $0[id] else { throw SynchronizationCredentialError.missing }; return value }
    }
    func remove(id: UUID) throws { values.withLock { $0[id] = nil } }
}
