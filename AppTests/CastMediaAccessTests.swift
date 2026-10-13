import XCTest
import Synchronization
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor final class CastMediaAccessTests: XCTestCase {
    private final class Vault: SynchronizationCredentialStore, Sendable {
        let values = Mutex<[UUID: String]>([:])
        func insert(_ password: String, id: UUID) { values.withLock { $0[id] = password } }
        func password(id: UUID) throws -> String { try values.withLock { guard let value = $0[id] else { throw URLError(.userAuthenticationRequired) }; return value } }
        func remove(id: UUID) { _ = values.withLock { $0.removeValue(forKey: id) } }
    }
    private actor Gate {
        var started = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
    private let receiver = CastReceiverAddress(address: "127.0.0.1", port: 8009)
    private func fixture(_ body: (FeedLibraryStore, FeedAuthentication, LibraryEpisode) async throws -> Void) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("cast-media-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        do {
            let feed = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Library podcast", imageURL: "https://publisher.invalid/art.png",
                episodes: [.init(identifier: "1", title: "Library episode", media: .init(url: "http://publisher.invalid/audio.mp3", size: 1))]),
                source: "https://publisher.invalid/feed", responseURL: URL(string: "https://publisher.invalid/feed")!, validator: nil, permanentRedirectURL: nil))
            let auth = FeedAuthentication(store: store, vault: Vault())
            try await auth.save(.init(username: "publisher", password: "fixture"), feedID: feed.id)
            try await store.updateEpisode(id: feed.episodes[0].id) { $0.userState.isDownloaded = true; $0.userState.localFileURL = "file:///app/downloaded.mp3" }
            let stored = try await store.episode(id: feed.episodes[0].id)
            let episode = try XCTUnwrap(stored)
            try await body(store, auth, episode)
            try await store.close()
        } catch { try? await store.close(); throw error }
    }

    func testCanonicalLibraryMetadataAndCapturedProxySupplyReceiverBytes() async throws {
        try await fixture { store, auth, episode in
            let proxy = try await LoopbackHTTPServer.start { request in
                XCTAssertEqual(request.path, "http://publisher.invalid/audio.mp3")
                XCTAssertEqual(request.headers["authorization"], "Basic " + Data("publisher:fixture".utf8).base64EncodedString())
                return .init(body: Data("canonical audio".utf8))
            }
            defer { proxy.stop() }
            let network = ProxyNetworkEnvironment(configuration: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!))
            let owner = CastMediaAccessOwner(store: store, authentication: auth, network: network, userAgent: "AntennaPod/test")
            owner.setReceiver(receiver)
            var foreign = episode; foreign.details.media?.url = "https://untrusted.invalid/audio"; foreign.details.title = "Foreign title"
            let media = try await owner.prepare(foreign); defer { media.close() }
            XCTAssertEqual(media.item.title, "Library episode"); XCTAssertEqual(media.item.subtitle, "Library podcast")
            XCTAssertEqual(media.item.mediaID, String(episode.id)); XCTAssertEqual(media.item.localPlaybackURL, "file:///app/downloaded.mp3")
            let url = try XCTUnwrap(media.item.contentURL.flatMap(URL.init(string:)))
            XCTAssertEqual(url.host, "127.0.0.1")
            let (bytes, _) = try await URLSession.shared.data(from: url)
            XCTAssertEqual(bytes, Data("canonical audio".utf8))
            let reused = try await owner.authorizedMedia(episodeID: episode.id, contentURL: media.item.contentURL)
            XCTAssertTrue(reused === media)
            let foreignURL = try await owner.authorizedMedia(episodeID: episode.id, contentURL: "https://untrusted.invalid/audio")
            XCTAssertNil(foreignURL)
            media.close(); media.close()
            let closed = try await owner.authorizedMedia(episodeID: episode.id, contentURL: media.item.contentURL)
            XCTAssertNil(closed)
        }
    }

    func testCredentialAndProxyChangesInvalidateReuseWithoutChangingExistingLease() async throws {
        try await fixture { store, auth, episode in
            let seen = Mutex<[String?]>([])
            let proxy = try await LoopbackHTTPServer.start { request in
                seen.withLock { $0.append(request.headers["authorization"]) }; return .init(body: Data("audio".utf8))
            }
            defer { proxy.stop() }
            let configuration = PodcastProxy(kind: .http, host: "127.0.0.1", port: proxy.url.port!)
            let network = ProxyNetworkEnvironment(configuration: configuration)
            let owner = CastMediaAccessOwner(store: store, authentication: auth, network: network, userAgent: "AntennaPod/test")
            owner.setReceiver(receiver)
            let first = try await owner.prepare(episode); defer { first.close() }
            try await auth.save(.init(username: "updated", password: "fixture"), feedID: store.feedID(forEpisode: episode.id))
            let reused = try await owner.authorizedMedia(episodeID: episode.id, contentURL: first.item.contentURL)
            XCTAssertNil(reused)
            _ = try await URLSession.shared.data(from: URL(string: first.item.contentURL!)!)
            XCTAssertEqual(seen.withLock { $0.last! }, "Basic " + Data("publisher:fixture".utf8).base64EncodedString())
            let second = try await owner.prepare(episode); defer { second.close() }
            _ = try await URLSession.shared.data(from: URL(string: second.item.contentURL!)!)
            XCTAssertEqual(seen.withLock { $0.last! }, "Basic " + Data("updated:fixture".utf8).base64EncodedString())
            network.update(configuration, reinitializeShared: true)
            let afterReinitialize = try await owner.authorizedMedia(episodeID: episode.id, contentURL: second.item.contentURL)
            XCTAssertNil(afterReinitialize)
        }
    }

    func testReceiverChangeRetiresPendingPreparation() async throws {
        try await fixture { store, auth, episode in
            let gate = Gate()
            let owner = CastMediaAccessOwner(store: store, authentication: auth, network: .init(configuration: .init()),
                userAgent: "AntennaPod/test", resolveEndpoint: { _ in await gate.wait(); return try .receiver(address: "127.0.0.1") })
            owner.setReceiver(receiver)
            let pending = Task { try await owner.prepare(episode) }
            let deadline = ContinuousClock.now + .seconds(3)
            while !(await gate.started), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
            let started = await gate.started; XCTAssertTrue(started)
            owner.setReceiver(nil); await gate.release()
            do { _ = try await pending.value; XCTFail("Stale receiver obtained media") } catch is CancellationError { }
        }
    }

    func testRetiringOwnerClosesLiveLeaseAndMissingMediaNeverUsesLocalFile() async throws {
        try await fixture { store, auth, episode in
            let proxy = try await LoopbackHTTPServer.start { _ in .init(body: Data("audio".utf8)) }; defer { proxy.stop() }
            var owner: CastMediaAccessOwner? = CastMediaAccessOwner(store: store, authentication: auth,
                network: .init(configuration: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!)), userAgent: "AntennaPod/test")
            owner?.setReceiver(receiver)
            let media = try await owner!.prepare(episode)
            let url = URL(string: media.item.contentURL!)!
            owner = nil
            do { _ = try await URLSession.shared.data(from: url); XCTFail("Retired owner still serves media") } catch { }
            let replacement = CastMediaAccessOwner(store: store, authentication: auth, network: .init(configuration: .init()), userAgent: "AntennaPod/test")
            replacement.setReceiver(receiver)
            try await store.updateEpisode(id: episode.id) { $0.details.media?.url = "file:///another-device/private" }
            do { _ = try await replacement.prepare(episode); XCTFail("Cast used a local file as stream URL") } catch let error as URLError { XCTAssertEqual(error.code, .unsupportedURL) }
        }
    }
    private func wait(_ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        guard predicate() else { throw URLError(.timedOut) }
    }

    func testColdForeignReceiverReconcilesToProxyAtCurrentPositionAndIntent() async throws {
        try await reconcileForeignReceiver(playing: true)
    }
    func testPausedForeignReceiverReconcilesWithoutAutoplayAndPreservesPositionAccounting() async throws {
        try await reconcileForeignReceiver(playing: false)
    }
    private func reconcileForeignReceiver(playing: Bool) async throws {
        try await fixture { store, auth, episode in
            let proxy = try await LoopbackHTTPServer.start { request in
                XCTAssertEqual(request.path, "http://publisher.invalid/audio.mp3")
                return .init(body: Data("authorized media".utf8))
            }
            defer { proxy.stop() }
            let access = CastMediaAccessOwner(store: store, authentication: auth,
                network: .init(configuration: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!)), userAgent: "AntennaPod/test")
            let local = RoutedPlaybackEngineTests.Engine(); local.automaticReady = true
            let routes = RoutedPlaybackEngine(local: local); defer { routes.unload() }
            let player = PlaybackCoordinator(store: store, engine: routes)
            let client = CastPlaybackEngineTests.Client()
            client.snapshot = .init(mediaID: String(episode.id), loadID: nil, mediaSessionID: 42,
                positionMilliseconds: 60_000, durationMilliseconds: 100_000, state: playing ? .playing : .paused, speed: 1.75,
                contentURL: "https://foreign.invalid/media")
            let id = CastSessionIdentity(deviceID: "receiver", sessionID: "session")
            let controller = CastReceiverSessionController(player: player, routes: routes, automaticallyPoll: false,
                mediaAccess: access, prepareMedia: access.prepare, onProblem: { XCTFail($0) })
            controller.receive(.connected(.init(identity: id, client: client, media: nil, status: client.snapshot,
                receiverAddress: receiver), resumed: true))
            try await wait { client.requests.count == 1 }; client.requests[0].callback(.completed)
            await controller.awaitRestoration()
            XCTAssertNil(controller.unresolved); XCTAssertEqual(client.loads.count, 1)
            let load = try XCTUnwrap(client.loads.first), data = client.loadData(load)
            XCTAssertEqual(data.startTime, 60); XCTAssertEqual(data.autoplay, NSNumber(value: playing))
            let contentID = try XCTUnwrap(data.queueData?.items?.first?.mediaInformation.contentID)
            let url = try XCTUnwrap(URL(string: contentID))
            XCTAssertEqual(url.host, "127.0.0.1")
            let (bytes, _) = try await URLSession.shared.data(from: url)
            XCTAssertEqual(bytes, Data("authorized media".utf8))
            client.finishLoad(load, state: playing ? .playing : .paused, position: 60_000)
            try await player.awaitPendingOperations()
            XCTAssertEqual(player.phase, playing ? .playing : .paused)
            let session = try await store.playbackSession()
            XCTAssertEqual(session?.startPositionMilliseconds, 60_000)
            let adopted = try await store.episode(id: episode.id)
            XCTAssertEqual(adopted?.userState.playedDurationMilliseconds, 0)
            client.snapshot?.state = .paused; client.snapshot?.positionMilliseconds = 75_000; client.onStatus?()
            try await player.awaitPendingOperations()
            XCTAssertEqual(player.sample?.positionMilliseconds, 75_000)
            if !playing {
                // Media3PlaybackService saves on playback/lifecycle transitions,
                // not every paused receiver seek. Preserve that retained state.
                let retained = try await store.episode(id: episode.id)
                XCTAssertEqual(retained?.userState.positionMilliseconds, 60_000)
                try await player.stop()
            }
            let saved = try await store.episode(id: episode.id)
            XCTAssertEqual(saved?.userState.positionMilliseconds, 75_000)
            // PlayableUtils retains a position-delta baseline across seeks,
            // including paused seeks; this field is not elapsed listening time.
            XCTAssertEqual(saved?.userState.playedDurationMilliseconds, 15_000)
        }
    }

    func testOwnedRelayAdoptionAndDeviceTransferDoNotReloadOrCloseTheLease() async throws {
        try await fixture { store, auth, episode in
            let proxy = try await LoopbackHTTPServer.start { _ in .init(body: Data("owned".utf8)) }; defer { proxy.stop() }
            let access = CastMediaAccessOwner(store: store, authentication: auth,
                network: .init(configuration: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!)), userAgent: "AntennaPod/test")
            access.setReceiver(receiver)
            let media = try await access.prepare(episode); defer { media.close() }
            let routes = RoutedPlaybackEngine(local: RoutedPlaybackEngineTests.Engine()); defer { routes.unload() }
            let player = PlaybackCoordinator(store: store, engine: routes)
            let controller = CastReceiverSessionController(player: player, routes: routes, automaticallyPoll: false,
                mediaAccess: access, prepareMedia: access.prepare, onProblem: { XCTFail($0) })
            let first = CastPlaybackEngineTests.Client()
            first.snapshot = .init(mediaID: String(episode.id), loadID: nil, mediaSessionID: 42,
                positionMilliseconds: 60_000, durationMilliseconds: 100_000, state: .playing, speed: 1,
                contentURL: media.item.contentURL)
            controller.receive(.connected(.init(identity: .init(deviceID: "first", sessionID: "session1"), client: first,
                media: media.item, status: first.snapshot, receiverAddress: receiver), resumed: true))
            try await wait { first.requests.count == 1 }; first.requests[0].callback(.completed)
            await controller.awaitRestoration(); try await player.awaitPendingOperations()
            XCTAssertTrue(first.loads.isEmpty)
            let session = try await store.playbackSession()
            let second = CastPlaybackEngineTests.Client(); second.snapshot = first.snapshot
            second.snapshot?.positionMilliseconds = 80_000
            controller.receive(.connected(.init(identity: .init(deviceID: "second", sessionID: "session2"), client: second,
                media: media.item, status: second.snapshot, receiverAddress: receiver), resumed: true))
            try await wait { second.requests.count == 1 }; second.requests[0].callback(.completed)
            await controller.awaitRestoration(); try await player.awaitPendingOperations()
            XCTAssertTrue(second.loads.isEmpty); XCTAssertNil(controller.unresolved)
            let transferredSession = try await store.playbackSession()
            XCTAssertEqual(transferredSession?.id, session?.id)
            let (bytes, _) = try await URLSession.shared.data(from: URL(string: media.item.contentURL!)!)
            XCTAssertEqual(bytes, Data("owned".utf8))
        }
    }

}
