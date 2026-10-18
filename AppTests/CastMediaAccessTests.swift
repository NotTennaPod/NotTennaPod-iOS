import XCTest
import Synchronization
import GoogleCast
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor final class CastMediaAccessTests: XCTestCase {
    private final class Vault: SynchronizationCredentialStore, Sendable {
        let values = Mutex<[UUID: String]>([:])
        /// Runs once, at the next credential read (while the access owner awaits it).
        let onRead = Mutex<(@Sendable () -> Void)?>(nil)
        /// Runs once, at the given credential read (counting from 1).
        let onReadNumber = Mutex<(Int, @Sendable () -> Void)?>(nil)
        let reads = Mutex(0)
        func insert(_ password: String, id: UUID) { values.withLock { $0[id] = password } }
        func password(id: UUID) throws -> String {
            let number = reads.withLock { $0 += 1; return $0 }
            onRead.withLock { hook in defer { hook = nil }; return hook }?()
            onReadNumber.withLock { entry -> (@Sendable () -> Void)? in
                guard let value = entry, value.0 == number else { return nil }
                entry = nil; return value.1
            }?()
            return try values.withLock { guard let value = $0[id] else { throw URLError(.userAuthenticationRequired) }; return value }
        }
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

    // MARK: Direct versus relay

    private final class Count: Sendable {
        let value = Mutex(0)
        func increment() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }
    private static let markers = ["marker-user", "marker-pass", "marker-stored-user", "marker-stored-pass",
                                  "marker-proxy-user", "marker-proxy-pass"]

    /// One feed whose enclosure, pictures, stored credentials and download state the test chooses.
    private func library(enclosure: String, feedImage: String? = nil, episodeImage: String? = nil,
                         credentials: FeedCredentials? = nil, downloaded: Bool = false, vault: Vault = Vault(),
                         _ body: (FeedLibraryStore, FeedAuthentication, LibraryEpisode) async throws -> Void) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("cast-route-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        do {
            var item = ParsedEpisode(identifier: "1", title: "Library episode", media: .init(url: enclosure, size: 1))
            item.imageURL = episodeImage
            let feed = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Library podcast", imageURL: feedImage,
                episodes: [item]), source: "https://publisher.invalid/feed", responseURL: URL(string: "https://publisher.invalid/feed")!,
                validator: nil, permanentRedirectURL: nil))
            let auth = FeedAuthentication(store: store, vault: vault)
            if let credentials { try await auth.save(credentials, feedID: feed.id) }
            if downloaded {
                try await store.updateEpisode(id: feed.episodes[0].id) { $0.userState.isDownloaded = true; $0.userState.localFileURL = "file:///app/downloaded.mp3" }
            }
            let stored = try await store.episode(id: feed.episodes[0].id)
            try await body(store, auth, try XCTUnwrap(stored))
            try await store.close()
        } catch { try? await store.close(); throw error }
    }

    private func makeOwner(_ store: FeedLibraryStore, _ auth: FeedAuthentication, proxy: PodcastProxy = .init(),
                           network: ProxyNetworkEnvironment? = nil,
                           admission: AuxiliaryNetworkAdmission = .unrestricted, routes: Count) -> CastMediaAccessOwner {
        let owner = CastMediaAccessOwner(store: store, authentication: auth, network: network ?? .init(configuration: proxy),
            userAgent: "AntennaPod/test", admission: admission, resolveEndpoint: {
                routes.increment(); return try await ReceiverNetworkRoute.endpoint(address: $0.address, port: $0.port)
            })
        owner.setReceiver(receiver)
        return owner
    }

    /// Every address-bearing field the receiver gets: content ID and URL, every metadata value, every picture.
    private func emittedFields(_ item: CastMediaItemCodec.Item) -> [String] {
        let information = CastMediaItemCodec.encode(item, loadID: UUID()).mediaInformation
        var fields = [information.contentID ?? "", information.contentURL?.absoluteString ?? ""]
        if let metadata = information.metadata {
            fields += metadata.allKeys().map { String(describing: metadata.object(forKey: $0) ?? "") }
            fields += metadata.images().compactMap { ($0 as? GCKImage)?.url.absoluteString }
        }
        return fields
    }

    /// Android sends the publisher's URL (`ApMediaItemConverter`): the receiver fetches a public enclosure itself, so
    /// the phone resolves no route, starts no relay and makes no request, streamed or downloaded.
    func testPublicFeedIsCastByItsEnclosureWithoutARelay() async throws {
        let publisher = try await LoopbackHTTPServer.start { _ in .init(body: Data("audio".utf8)) }
        defer { publisher.stop() }
        let enclosure = "http://127.0.0.1:\(publisher.url.port!)/audio.mp3?token=public"
        for downloaded in [false, true] {
            try await library(enclosure: enclosure + "#start", feedImage: "https://publisher.invalid/art.png", downloaded: downloaded) { store, auth, episode in
                let routes = Count()
                let owner = makeOwner(store, auth, routes: routes)
                let media = try await owner.prepare(episode); defer { media.close() }
                XCTAssertEqual(media.item.contentURL, enclosure, "the enclosure without its fragment")
                XCTAssertEqual(media.item.localPlaybackURL, downloaded ? "file:///app/downloaded.mp3" : enclosure)
                XCTAssertEqual(media.item.artworkURL?.absoluteString, "https://publisher.invalid/art.png")
                XCTAssertEqual(media.item.mediaID, String(episode.id))
                XCTAssertEqual(routes.count, 0, "no relay, no route resolution")
            }
        }
        XCTAssertTrue(publisher.requests.isEmpty, "the phone fetched the enclosure")
    }

    /// Userinfo in the raw enclosure is a phone-held secret: the item is relayed (judged before userinfo is removed),
    /// and neither it, stored credentials nor proxy credentials reach any field the receiver gets. A picture whose
    /// address carries userinfo is left out.
    func testUserinfoForcesRelayAndNoCredentialMarkerReachesTheReceiver() async throws {
        let publisher = try await LoopbackHTTPServer.start { _ in .init(body: Data("audio".utf8)) }
        defer { publisher.stop() }
        let port = publisher.url.port!
        let art = "https://marker-user:marker-pass@publisher.invalid/art.png"
        try await library(enclosure: "http://marker-user:marker-pass@127.0.0.1:\(port)/audio.mp3",
                          feedImage: art, episodeImage: art) { store, auth, episode in
            let routes = Count()
            let owner = makeOwner(store, auth, routes: routes)
            let media = try await owner.prepare(episode); defer { media.close() }
            XCTAssertEqual(routes.count, 1, "relayed")
            XCTAssertNil(media.item.artworkURL)
            XCTAssertEqual(media.item.localPlaybackURL, "http://127.0.0.1:\(port)/audio.mp3")
            for field in emittedFields(media.item) {
                for marker in Self.markers { XCTAssertFalse(field.contains(marker), field) }
            }
        }
        // Stored credentials and an authenticated proxy: relayed, and still nothing of them in the item.
        let proxy = try await LoopbackHTTPServer.start { _ in .init(body: Data("audio".utf8)) }
        defer { proxy.stop() }
        try await library(enclosure: "http://publisher.invalid/audio.mp3", feedImage: "https://publisher.invalid/art.png",
                          credentials: .init(username: "marker-stored-user", password: "marker-stored-pass")) { store, auth, episode in
            let routes = Count()
            let owner = makeOwner(store, auth, proxy: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!,
                                                        username: "marker-proxy-user", password: "marker-proxy-pass"), routes: routes)
            let media = try await owner.prepare(episode); defer { media.close() }
            XCTAssertEqual(routes.count, 1)
            XCTAssertEqual(media.item.artworkURL?.absoluteString, "https://publisher.invalid/art.png")
            for field in emittedFields(media.item) {
                for marker in Self.markers { XCTAssertFalse(field.contains(marker), field) }
            }
        }
    }

    /// The relay keeps publisher credentials for the publisher's origin: a redirect to another origin loses them.
    func testRelayedCredentialsAreNotSentAcrossARedirect() async throws {
        let seen = Mutex<[String: String?]>([:])
        let other = try await LoopbackHTTPServer.start { request in
            seen.withLock { _ = $0.updateValue(request.headers["authorization"], forKey: "other") }; return .init(body: Data("moved audio".utf8))
        }
        defer { other.stop() }
        let publisher = try await LoopbackHTTPServer.start { request in
            seen.withLock { _ = $0.updateValue(request.headers["authorization"], forKey: "publisher") }
            return .init(status: 302, headers: ["Location": "http://127.0.0.1:\(other.url.port!)/moved.mp3"], body: Data())
        }
        defer { publisher.stop() }
        try await library(enclosure: "http://127.0.0.1:\(publisher.url.port!)/audio.mp3",
                          credentials: .init(username: "publisher", password: "fixture")) { store, auth, episode in
            let routes = Count()
            let owner = makeOwner(store, auth, routes: routes)
            let media = try await owner.prepare(episode); defer { media.close() }
            let (bytes, _) = try await URLSession.shared.data(from: URL(string: media.item.contentURL!)!)
            XCTAssertEqual(bytes, Data("moved audio".utf8))
            let headers = seen.withLock { $0 }
            XCTAssertEqual(headers["publisher"] ?? nil, "Basic " + Data("publisher:fixture".utf8).base64EncodedString())
            XCTAssertTrue(headers.keys.contains("other")); XCTAssertNil(headers["other"] ?? nil, "credentials crossed origins")
        }
    }

    /// A direct item is re-adopted (after a relaunch, without a lease) when the receiver plays the current public
    /// enclosure, and never resolves the receiver's route. It is not, once the enclosure changes, credentials are
    /// added or a proxy is configured.
    func testDirectAdoptionNeverResolvesTheReceiverRoute() async throws {
        let enclosure = "https://publisher.invalid/audio.mp3"
        try await library(enclosure: enclosure) { store, auth, episode in
            let routes = Count()
            let owner = makeOwner(store, auth, routes: routes)
            let adopted = try await owner.authorizedMedia(episodeID: episode.id, contentURL: enclosure)
            XCTAssertEqual(adopted?.item.contentURL, enclosure)
            let prepared = try await owner.prepare(episode); defer { prepared.close() }
            let again = try await owner.authorizedMedia(episodeID: episode.id, contentURL: prepared.item.contentURL)
            XCTAssertEqual(again?.item, prepared.item)
            let foreign = try await owner.authorizedMedia(episodeID: episode.id, contentURL: "https://foreign.invalid/audio.mp3")
            XCTAssertNil(foreign)
            XCTAssertEqual(routes.count, 0)
            let proxied = makeOwner(store, auth, proxy: .init(kind: .http, host: "127.0.0.1", port: 9), routes: routes)
            let viaProxy = try await proxied.authorizedMedia(episodeID: episode.id, contentURL: enclosure)
            XCTAssertNil(viaProxy, "a proxy needs the relay")
            try await auth.save(.init(username: "publisher", password: "fixture"), feedID: store.feedID(forEpisode: episode.id))
            let withCredentials = try await owner.authorizedMedia(episodeID: episode.id, contentURL: enclosure)
            XCTAssertNil(withCredentials, "credentials need the relay")
            try await auth.save(.init(username: nil, password: nil), feedID: store.feedID(forEpisode: episode.id))
            try await store.updateEpisode(id: episode.id) { $0.details.media?.url = "https://publisher.invalid/replaced.mp3" }
            let changed = try await owner.authorizedMedia(episodeID: episode.id, contentURL: enclosure)
            XCTAssertNil(changed, "the enclosure changed")
            let replaced = try await owner.authorizedMedia(episodeID: episode.id, contentURL: "https://publisher.invalid/replaced.mp3")
            XCTAssertNotNil(replaced, "cleared credentials are none")
            XCTAssertEqual(routes.count, 0)
        }
    }

    /// The relay's admission waits for the first network observation. Credentials that change meanwhile are read again
    /// after it: the relay uses the current ones, and credentials removed meanwhile make the item direct.
    func testRelayPreparationRereadsTheSourceAfterAdmission() async throws {
        let seen = Mutex<[String?]>([])
        let publisher = try await LoopbackHTTPServer.start { request in
            seen.withLock { $0.append(request.headers["authorization"]) }; return .init(body: Data("audio".utf8))
        }
        defer { publisher.stop() }
        let enclosure = "http://127.0.0.1:\(publisher.url.port!)/audio.mp3"
        let directory = URL.temporaryDirectory.appendingPathComponent("cast-admission-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = try MobileNetworkPreferenceStore(file: directory.appendingPathComponent("mobile.json"))
        for removed in [false, true] {
            try await library(enclosure: enclosure, credentials: .init(username: "first", password: "fixture")) { store, auth, episode in
                let network = DownloadNetworkMonitor(startMonitoring: false)
                let admission = AuxiliaryNetworkAdmission(network: network, preferences: preferences)
                let routes = Count()
                let owner = makeOwner(store, auth, admission: admission, routes: routes)
                let preparing = Task { try await owner.prepare(episode) }
                try await wait { network.pendingObservationCount == 1 }
                XCTAssertEqual(routes.count, 0, "nothing before the admission")
                try await auth.save(removed ? .init(username: nil, password: nil) : .init(username: "second", password: "fixture"),
                                    feedID: store.feedID(forEpisode: episode.id))
                network.update(.init(connected: true, metered: false, cellular: false, transport: .wifi))
                let media = try await preparing.value; defer { media.close() }
                if removed {
                    XCTAssertEqual(media.item.contentURL, enclosure); XCTAssertEqual(routes.count, 0)
                } else {
                    XCTAssertEqual(routes.count, 1)
                    _ = try await URLSession.shared.data(from: URL(string: media.item.contentURL!)!)
                    XCTAssertEqual(seen.withLock { $0.last ?? nil }, "Basic " + Data("second:fixture".utf8).base64EncodedString())
                }
            }
        }
    }

    /// On a restricted network with Streaming off and no Once consent, a relay is refused before anything is prepared;
    /// a public enclosure is not asked.
    func testRelayIsRefusedOnARestrictedNetworkWithoutStreaming() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("cast-admission-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = try MobileNetworkPreferenceStore(file: directory.appendingPathComponent("mobile.json"))
        try preferences.updateAllowed(["images"])
        let network = DownloadNetworkMonitor(startMonitoring: false)
        network.update(.init(connected: true, metered: true, cellular: true))
        let admission = AuxiliaryNetworkAdmission(network: network, preferences: preferences)
        try await library(enclosure: "https://publisher.invalid/audio.mp3", credentials: .init(username: "publisher", password: "fixture"),
                          downloaded: true) { store, auth, episode in
            let routes = Count()
            let owner = makeOwner(store, auth, admission: admission, routes: routes)
            do { _ = try await owner.prepare(episode); XCTFail("Relayed without consent") }
            catch let denied as CastRelayStreamingDenied { XCTAssertEqual(denied.episodeID, episode.id) }
            XCTAssertEqual(routes.count, 0)
            try preferences.setAllowed(.streaming, true)
            let media = try await owner.prepare(episode); defer { media.close() }
            XCTAssertEqual(routes.count, 1)
        }
        try await library(enclosure: "https://publisher.invalid/audio.mp3") { store, auth, episode in
            let routes = Count()
            try preferences.updateAllowed(["images"])
            let media = try await makeOwner(store, auth, admission: admission, routes: routes).prepare(episode)
            XCTAssertEqual(media.item.contentURL, "https://publisher.invalid/audio.mp3"); XCTAssertEqual(routes.count, 0)
        }
    }

    /// A proxy is a privacy choice. One configured while the owner awaits the episode's library and credential reads is
    /// seen when the route is decided: the receiver never gets the publisher's URL (preparation is relayed, through the
    /// proxy) and a receiver playing that URL is not adopted. Cleared credentials make the owner read the vault, where
    /// the proxy is configured.
    func testProxyConfiguredDuringTheSourceReadsIsNeverBypassed() async throws {
        let proxy = try await LoopbackHTTPServer.start { request in
            XCTAssertEqual(request.path, "http://publisher.invalid/audio.mp3"); return .init(body: Data("proxied audio".utf8))
        }
        defer { proxy.stop() }
        let enclosure = "http://publisher.invalid/audio.mp3"
        for adoption in [true, false] {
            let vault = Vault()
            try await library(enclosure: enclosure, credentials: .init(username: nil, password: nil), vault: vault) { store, auth, episode in
                let network = ProxyNetworkEnvironment(configuration: .init())
                _ = network.sharedClient() // In use before the proxy is configured, as in the app.
                let fired = Mutex(false)
                vault.onRead.withLock { $0 = {
                    network.update(.init(kind: .http, host: "127.0.0.1", port: proxy.url.port!), reinitializeShared: true)
                    fired.withLock { $0 = true }
                } }
                let routes = Count()
                let owner = makeOwner(store, auth, network: network, routes: routes)
                if adoption {
                    let adopted = try await owner.authorizedMedia(episodeID: episode.id, contentURL: enclosure)
                    XCTAssertTrue(fired.withLock { $0 })
                    XCTAssertNil(adopted, "adopted the publisher's URL while a proxy is configured")
                } else {
                    let client = CastPlaybackEngineTests.Client()
                    let engine = CastPlaybackEngine(client: client, automaticallyPoll: false, prepareMedia: owner.prepare)
                    defer { engine.unload() }
                    engine.load(episode: episode, generation: UUID(), positionMilliseconds: 0)
                    try await wait { client.loads.count == 1 }
                    XCTAssertTrue(fired.withLock { $0 })
                    let contentID = try XCTUnwrap(client.loadData(client.loads[0]).queueData?.items?.first?.mediaInformation.contentID)
                    XCTAssertNotEqual(contentID, enclosure, "the receiver got the publisher's URL while a proxy is configured")
                    XCTAssertEqual(routes.count, 1, "relayed")
                    let (bytes, _) = try await URLSession.shared.data(from: try XCTUnwrap(URL(string: contentID)))
                    XCTAssertEqual(bytes, Data("proxied audio".utf8), "through the proxy")
                }
            }
        }
    }

    /// The proxy holds through every await of a relay's preparation, not only the source reads: one configured while
    /// the receiver's route is resolved, or while the relay starts, is seen before the relay is handed out. The relay
    /// handed out fetches through that proxy; the publisher is never asked directly.
    func testProxyConfiguredWhileTheRelayIsPreparedIsUsed() async throws {
        let publisher = try await LoopbackHTTPServer.start { _ in .init(body: Data("publisher audio".utf8)) }
        defer { publisher.stop() }
        let enclosure = "http://127.0.0.1:\(publisher.url.port!)/audio.mp3"
        let proxy = try await LoopbackHTTPServer.start { request in
            XCTAssertEqual(request.path, enclosure); return .init(body: Data("proxied audio".utf8))
        }
        defer { proxy.stop() }
        let configured = PodcastProxy(kind: .http, host: "127.0.0.1", port: proxy.url.port!)
        for stage in ["route resolution", "relay start"] {
            let vault = Vault(), before = (publisher.requests.count, proxy.requests.count)
            try await library(enclosure: enclosure, credentials: .init(username: "publisher", password: "fixture"),
                              vault: vault) { store, auth, episode in
                let network = ProxyNetworkEnvironment(configuration: .init())
                _ = network.sharedClient()
                let fired = Mutex(false)
                let commit: @Sendable () -> Void = {
                    network.update(configured, reinitializeShared: true); fired.withLock { $0 = true }
                }
                let duringResolution = stage == "route resolution"
                // Credential reads: the first lookup, after the admission, after route resolution, after the relay starts.
                if !duringResolution { vault.onReadNumber.withLock { $0 = (4, commit) } }
                let resolutions = Count()
                let owner = CastMediaAccessOwner(store: store, authentication: auth, network: network,
                    userAgent: "AntennaPod/test", resolveEndpoint: {
                        resolutions.increment()
                        if duringResolution, !fired.withLock({ $0 }) { commit() }
                        return try await ReceiverNetworkRoute.endpoint(address: $0.address, port: $0.port)
                    })
                owner.setReceiver(receiver)
                let media = try await owner.prepare(episode); defer { media.close() }
                XCTAssertTrue(fired.withLock { $0 }, stage)
                XCTAssertEqual(resolutions.count, 2, "decided again: \(stage)")
                let (bytes, _) = try await URLSession.shared.data(from: try XCTUnwrap(URL(string: try XCTUnwrap(media.item.contentURL))))
                XCTAssertEqual(bytes, Data("proxied audio".utf8), stage)
                XCTAssertEqual(publisher.requests.count, before.0, "the publisher was asked directly: \(stage)")
                XCTAssertEqual(proxy.requests.count, before.1 + 1, stage)
            }
        }
    }
}
