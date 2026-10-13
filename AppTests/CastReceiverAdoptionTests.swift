import XCTest
import GoogleCast
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor final class CastReceiverAdoptionTests: XCTestCase {
    typealias Client = CastPlaybackEngineTests.Client
    typealias Local = RoutedPlaybackEngineTests.Engine
    let id = CastSessionIdentity(deviceID: "receiver", sessionID: "session")
    func snapshot(_ client: Client, id: CastSessionIdentity? = nil) -> CastSessionSnapshot {
        .init(identity: id ?? self.id, client: client,
            media: .init(contentURL: "https://foreign.example/media", mediaID: client.snapshot?.mediaID,
                         localPlaybackURL: "file:///another-device/private-file"), status: client.snapshot)
    }
    func status(_ mediaID: String = "1", position: Int32 = 60_000, state: GCKMediaPlayerState = .playing) -> CastRemoteSnapshot {
        .init(mediaID: mediaID, loadID: nil, mediaSessionID: 42, positionMilliseconds: position,
              durationMilliseconds: 100_000, state: state, speed: 1.75, contentURL: "https://foreign.example/media")
    }
    func media(_ episode: LibraryEpisode) -> CastPlaybackMedia {
        .init(item: .init(contentURL: "https://authorized.example/relay", mediaID: String(episode.id)))
    }
    func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        guard condition() else { XCTFail("Expected adoption operation"); throw URLError(.timedOut) }
    }
    func withLibrary(_ body: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("cast-adoption-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        do {
            let episodes = (1...2).map { ParsedEpisode(identifier: String($0), title: "Episode \($0)",
                media: .init(url: "https://canonical.example/\($0).mp3", size: 1, durationMilliseconds: 100_000)) }
            _ = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Cast", episodes: episodes),
                source: "https://canonical.example/feed", responseURL: URL(string: "https://canonical.example/feed")!,
                validator: nil, permanentRedirectURL: nil))
            try await body(store, root)
        } catch { try? await store.close(); throw error }
        try await store.close()
    }

    func testColdReceiverAdoptionPreservesIntentUsesPreferencesAndStartsAccountingAtReceiverPosition() async throws {
        try await withLibrary { store, root in
            let local = Local(); local.automaticReady = true
            let routes = RoutedPlaybackEngine(local: local)
            defer { routes.unload() }
            let settings = try PlaybackSpeedPreferenceStore(file: root.appendingPathComponent("speed.json"))
            try settings.setCurrent(1.25, alsoGlobal: true)
            try settings.setGlobalSkipSilence(true)
            try await store.updatePreferences(feedID: 1) { $0.volumeAdaptation = .heavyReduction }
            let player = PlaybackCoordinator(store: store, engine: routes, speedPreferences: settings)
            let client = Client(); client.snapshot = status()
            var preparations = 0
            let controller = CastReceiverSessionController(player: player, routes: routes, automaticallyPoll: false,
                prepareMedia: { [self] in preparations += 1; return media($0) }, onProblem: { XCTFail($0) })
            controller.receive(.connected(snapshot(client), resumed: true))
            try await wait { client.requests.count == 1 }; client.requests[0].callback(.completed)
            await controller.awaitRestoration(); try await player.awaitPendingOperations()
            XCTAssertNil(controller.unresolved); XCTAssertEqual(player.phase, .playing)
            XCTAssertEqual(player.episode?.id, 1); XCTAssertEqual(player.speed, 1.25)
            XCTAssertTrue(player.skipSilence); XCTAssertEqual(player.volumeAdaptation, .heavyReduction)
            XCTAssertEqual(preparations, 0); XCTAssertTrue(client.loads.isEmpty)
            for request in client.requests {
                switch request.command {
                case .status, .speed: break
                case .volume(let value): XCTAssertEqual(value, 0.2, accuracy: 0.00001)
                default: XCTFail("Adoption changed transport intent")
                }
            }
            let first = try await store.episode(id: 1), session = try await store.playbackSession()
            XCTAssertEqual(session?.startPositionMilliseconds, 60_000)
            XCTAssertEqual(first?.userState.positionMilliseconds, 60_000)
            XCTAssertEqual(first?.userState.playedDurationMilliseconds, 0)
            client.snapshot?.speed = 1.25
            client.requests.dropFirst().forEach { $0.callback(.completed) }
            client.snapshot?.positionMilliseconds = 75_000; client.snapshot?.state = .paused; client.onStatus?()
            try await player.awaitPendingOperations()
            let paused = try await store.episode(id: 1)
            XCTAssertEqual(paused?.userState.positionMilliseconds, 75_000)
            XCTAssertEqual(paused?.userState.playedDurationMilliseconds, 15_000)
            controller.receive(.ending(snapshot(client)))
            XCTAssertEqual(local.loaded.last?.0.details.media?.url, "https://canonical.example/1.mp3")
            XCTAssertEqual(local.loaded.last?.2, 75_000); XCTAssertFalse(local.wantsPlayback)
        }
    }

    func testPausedReceiverPersistsPositionAndExplicitRestartUsesAuthorizedSource() async throws {
        try await withLibrary { store, _ in
            let routes = RoutedPlaybackEngine(local: Local()); defer { routes.unload() }
            let player = PlaybackCoordinator(store: store, engine: routes, clock: { Date(timeIntervalSince1970: 1000) })
            let client = Client(); client.snapshot = status("01", state: .paused)
            let controller = CastReceiverSessionController(player: player, routes: routes, automaticallyPoll: false,
                prepareMedia: media, onProblem: { XCTFail($0) })
            controller.receive(.connected(snapshot(client), resumed: true))
            try await wait { !client.requests.isEmpty }; client.requests[0].callback(.completed)
            await controller.awaitRestoration(); try await player.awaitPendingOperations()
            XCTAssertEqual(player.phase, .paused)
            let saved = try await store.episode(id: 1)
            XCTAssertEqual(saved?.userState.positionMilliseconds, 60_000)
            client.snapshot?.state = .idle; client.snapshot?.idleReason = .cancelled; client.onStatus?()
            try await player.awaitPendingOperations(); try await player.play()
            try await wait { client.loads.count == 1 }
            let loaded = client.loadData(client.loads[0])
            XCTAssertEqual(loaded.queueData?.items?.first?.mediaInformation.contentID, "https://authorized.example/relay")
            XCTAssertEqual(loaded.startTime, 60)
        }
    }

    func testMissingOrInvalidReceiverIdentityDoesNotReplaceLibrarySelection() async throws {
        try await withLibrary { store, _ in
            let local = Local(); local.automaticReady = true
            let routes = RoutedPlaybackEngine(local: local); defer { routes.unload() }
            let player = PlaybackCoordinator(store: store, engine: routes)
            try await player.select(episodeID: 2, play: false); try await player.awaitPendingOperations()
            let controller = CastReceiverSessionController(player: player, routes: routes, automaticallyPoll: false,
                prepareMedia: media, onProblem: { XCTFail($0) })
            for (mediaID, issue) in [("foreign", CastReceiverSessionController.Unresolved.invalidMediaID), ("999", .missingEpisode)] {
                let client = Client(); client.snapshot = status(mediaID)
                controller.receive(.connected(snapshot(client), resumed: true))
                try await wait { !client.requests.isEmpty }; client.requests[0].callback(.completed)
                await controller.awaitRestoration()
                XCTAssertEqual(controller.unresolved, issue); XCTAssertEqual(player.episode?.id, 2)
                XCTAssertFalse(routes.isRemote); XCTAssertEqual(client.requests.count, 1)
            }
        }
    }

    /// PROTOCOL §15.4: local IDs repeat across libraries, so receiver media is adopted only by the library that loaded it
    /// (a server library's loads name it; standalone loads carry no tag). After a recorded switch the new graph's
    /// controller finds the other library's media on the resumed session: it is foreign, exactly as media this app does
    /// not know, and the player keeps its own library's selection. Same-library media is adopted as before.
    func testReceiverMediaIsAdoptedOnlyByTheLibraryThatLoadedIt() async throws {
        let server = "0b5a3c1e-7c43-4a5e-9d1f-2b9a0e7f6c11"
        let cases: [(LibraryReference, String?, Bool)] = [
            (.standalone, nil, true), (.server(server), server, true),
            (.standalone, server, false), (.server(server), nil, false),
            (.server(server), "f1d2c3b4-a5e6-4f70-8a9b-0c1d2e3f4a5b", false)]
        for (library, tag, adopted) in cases {
            try await withLibrary { store, _ in
                let local = Local(); local.automaticReady = true
                let routes = RoutedPlaybackEngine(local: local); defer { routes.unload() }
                let player = PlaybackCoordinator(store: store, engine: routes)
                try await player.select(episodeID: 2, play: false); try await player.awaitPendingOperations()
                let controller = CastReceiverSessionController(player: player, routes: routes, automaticallyPoll: false,
                    library: library, prepareMedia: media, onProblem: { XCTFail($0) })
                let client = Client(); client.snapshot = status("1"); client.snapshot?.libraryID = tag
                controller.receive(.connected(snapshot(client), resumed: true))
                XCTAssertTrue(controller.isRestoring)
                try await wait { !client.requests.isEmpty }; client.requests[0].callback(.completed)
                await controller.awaitRestoration(); try await player.awaitPendingOperations()
                XCTAssertFalse(controller.isRestoring)
                let label = "\(library) receiving \(tag ?? "standalone")"
                if adopted {
                    XCTAssertNil(controller.unresolved, label)
                    XCTAssertEqual(player.episode?.id, 1, label); XCTAssertEqual(player.phase, .playing, label)
                } else {
                    XCTAssertEqual(controller.unresolved, .invalidMediaID, label)
                    XCTAssertEqual(player.episode?.id, 2, label); XCTAssertFalse(routes.isRemote, label)
                    XCTAssertEqual(client.requests.count, 1, label); XCTAssertTrue(client.loads.isEmpty, label)
                    let first = try await store.episode(id: 1)
                    XCTAssertEqual(first?.userState.positionMilliseconds, 0, label)
                }
            }
        }
    }

    /// Another library's item under the same local ID that is first seen already idle, finished or in
    /// an unknown state takes ownership away all the same, so its later unload (no media identity) completes and saves
    /// nothing in this library.
    func testForeignItemFirstSeenIdleOrUnknownNeverCompletesTheLocalEpisode() async throws {
        let server = "0b5a3c1e-7c43-4a5e-9d1f-2b9a0e7f6c11"
        let firstSeen: [(GCKMediaPlayerState, GCKMediaPlayerIdleReason)] = [(.idle, .finished), (.idle, .cancelled), (.unknown, .none)]
        for (state, reason) in firstSeen {
            try await withLibrary { store, _ in
                let routes = RoutedPlaybackEngine(local: Local()); defer { routes.unload() }
                let player = PlaybackCoordinator(store: store, engine: routes)
                let controller = CastReceiverSessionController(player: player, routes: routes, automaticallyPoll: false,
                    library: .server(server), prepareMedia: media, onProblem: { XCTFail($0) })
                let client = Client(); client.snapshot = status(); client.snapshot?.libraryID = server
                controller.receive(.connected(snapshot(client), resumed: true))
                try await wait { client.requests.count == 1 }; client.requests[0].callback(.completed)
                await controller.awaitRestoration(); try await player.awaitPendingOperations()
                XCTAssertEqual(player.episode?.id, 1); XCTAssertTrue(routes.isRemote)
                let before = try await store.episode(id: 1), reads = client.requests.count
                // The other library's episode 1, first observed already ended.
                client.snapshot = status("1", position: 100_000, state: state)
                client.snapshot?.mediaSessionID = 99; client.snapshot?.idleReason = reason
                client.onStatus?()
                // The receiver clears it; this final unload carries no media identity.
                client.snapshot?.mediaID = nil; client.snapshot?.mediaSessionID = 0
                client.snapshot?.state = .idle; client.snapshot?.idleReason = .finished
                client.onStatus?()
                // Ownership was taken away: the receiver is read again to restore (and finds nothing to adopt).
                try await wait { client.requests.count > reads }; client.requests.last!.callback(.completed)
                await controller.awaitRestoration(); try await player.awaitPendingOperations()
                let after = try await store.episode(id: 1)
                let label = "first seen \(state.rawValue)/\(reason.rawValue)"
                XCTAssertEqual(after?.userState.playState, before?.userState.playState, label)
                XCTAssertEqual(after?.userState.positionMilliseconds, before?.userState.positionMilliseconds, label)
                XCTAssertEqual(after?.userState.playedDurationMilliseconds, before?.userState.playedDurationMilliseconds, label)
                XCTAssertEqual(player.episode?.id, 1, label)
            }
        }
    }

    /// The receiver moves to this library's episode 2 and first reports it with no usable state
    /// (`unknown`), then playing, with the same identity. The first status takes the old item's ownership away; when
    /// the state becomes usable the item is restored and adopted, and Pause reaches it.
    func testItemFirstReportedUnknownIsAdoptedWhenItPlays() async throws {
        try await withLibrary { store, _ in
            let routes = RoutedPlaybackEngine(local: Local()); defer { routes.unload() }
            let player = PlaybackCoordinator(store: store, engine: routes)
            let controller = CastReceiverSessionController(player: player, routes: routes, automaticallyPoll: false,
                prepareMedia: media, onProblem: { XCTFail($0) })
            let client = Client(); client.snapshot = status("1")
            controller.receive(.connected(snapshot(client), resumed: true))
            try await wait { client.requests.count == 1 }; client.requests[0].callback(.completed)
            await controller.awaitRestoration(); try await player.awaitPendingOperations()
            XCTAssertEqual(player.episode?.id, 1)
            var count = client.requests.count
            client.snapshot = status("2", position: 80_000, state: .unknown)
            client.snapshot?.mediaSessionID = 99; client.onStatus?()
            if controller.isRestoring {
                try await wait { client.requests.count > count }; client.requests.last!.callback(.completed)
                await controller.awaitRestoration(); try await player.awaitPendingOperations()
            }
            // No identity change: only the receiver's state becomes usable.
            count = client.requests.count
            client.snapshot?.state = .playing; client.onStatus?()
            if controller.isRestoring {
                try await wait { client.requests.count > count }; client.requests.last!.callback(.completed)
                await controller.awaitRestoration()
            }
            try await player.awaitPendingOperations()
            XCTAssertEqual(player.episode?.id, 2, "the receiver's now-playing episode must be adopted")
            XCTAssertEqual(player.sample?.positionMilliseconds, 80_000)
            let beforePause = client.requests.count
            try await player.pause()
            XCTAssertTrue(client.requests.dropFirst(beforePause).contains { if case .pause = $0.command { true } else { false } },
                "Pause must reach the now-playing receiver item")
            let first = try await store.episode(id: 1)
            XCTAssertEqual(first?.userState.playState, .unplayed, "episode 2's progress is not attributed to episode 1")
        }
    }

    /// The same transition for another library's item (colliding local ID): when it becomes usable it is checked again
    /// and is still foreign, so it is never adopted and receives no command.
    func testForeignItemFirstReportedUnknownIsNeverAdoptedWhenItPlays() async throws {
        let server = "0b5a3c1e-7c43-4a5e-9d1f-2b9a0e7f6c11"
        try await withLibrary { store, _ in
            let routes = RoutedPlaybackEngine(local: Local()); defer { routes.unload() }
            let player = PlaybackCoordinator(store: store, engine: routes)
            let controller = CastReceiverSessionController(player: player, routes: routes, automaticallyPoll: false,
                library: .server(server), prepareMedia: media, onProblem: { XCTFail($0) })
            let client = Client(); client.snapshot = status("1"); client.snapshot?.libraryID = server
            controller.receive(.connected(snapshot(client), resumed: true))
            try await wait { client.requests.count == 1 }; client.requests[0].callback(.completed)
            await controller.awaitRestoration(); try await player.awaitPendingOperations()
            XCTAssertEqual(player.episode?.id, 1)
            let before = try await store.episode(id: 1)
            var count = client.requests.count
            client.snapshot = status("2", position: 80_000, state: .unknown)
            client.snapshot?.mediaSessionID = 99; client.onStatus?()
            try await wait { client.requests.count > count }; client.requests.last!.callback(.completed)
            await controller.awaitRestoration(); try await player.awaitPendingOperations()
            XCTAssertEqual(controller.unresolved, .invalidMediaID)
            count = client.requests.count
            client.snapshot?.state = .playing; client.onStatus?()
            try await wait { client.requests.count > count }; client.requests.last!.callback(.completed)
            await controller.awaitRestoration(); try await player.awaitPendingOperations()
            XCTAssertEqual(controller.unresolved, .invalidMediaID, "checked again and still foreign")
            XCTAssertEqual(player.episode?.id, 1)
            let beforePause = client.requests.count
            try await player.pause()
            XCTAssertFalse(client.requests.dropFirst(beforePause).contains { if case .status = $0.command { false } else { true } },
                "nothing is sent to the foreign item")
            let after = try await store.episode(id: 1)
            XCTAssertEqual(after?.userState.playState, before?.userState.playState)
            XCTAssertEqual(after?.userState.positionMilliseconds, before?.userState.positionMilliseconds)
        }
    }

    /// At runtime: after adopting its own media, a receiver item another library loaded is foreign.
    func testReceiverItemOfAnotherLibraryAtRuntimeIsForeign() async throws {
        let server = "0b5a3c1e-7c43-4a5e-9d1f-2b9a0e7f6c11"
        try await withLibrary { store, _ in
            let routes = RoutedPlaybackEngine(local: Local()); defer { routes.unload() }
            let player = PlaybackCoordinator(store: store, engine: routes, clock: { Date(timeIntervalSince1970: 1000) })
            let controller = CastReceiverSessionController(player: player, routes: routes, automaticallyPoll: false,
                library: .server(server), prepareMedia: media, onProblem: { XCTFail($0) })
            let client = Client(); client.snapshot = status(); client.snapshot?.libraryID = server
            controller.receive(.connected(snapshot(client), resumed: true))
            try await wait { client.requests.count == 1 }; client.requests[0].callback(.completed)
            await controller.awaitRestoration(); try await player.awaitPendingOperations()
            XCTAssertNil(controller.unresolved); XCTAssertEqual(player.episode?.id, 1)
            client.snapshot = status("2", position: 5000); client.snapshot?.mediaSessionID = 99
            let before = client.requests.count; client.onStatus?()
            try await wait { client.requests.count > before }; client.requests.last!.callback(.completed)
            await controller.awaitRestoration()
            XCTAssertEqual(controller.unresolved, .invalidMediaID)
            XCTAssertEqual(player.episode?.id, 1)
        }
    }

    /// Commands that act on the receiver's media (status requests only read it).
    private func mediaCommands(_ client: Client, after index: Int = 0) -> [String] {
        client.requests.dropFirst(index).compactMap { request -> String? in
            if case .status = request.command { return nil }
            return String(describing: request.command)
        }
    }

    /// Colliding local IDs at launch (after a recorded switch): server library B has its episode 1 loaded and paused
    /// before the resumed session is restored, while the receiver holds the standalone library's episode 1. The
    /// receiver item is foreign: B's episode stays unbound from it, and nothing of the receiver's playing, progress
    /// or end reaches B's row, selection or playback session.
    func testForeignItemUnderTheLoadedEpisodesIDNeverReachesItAtLaunch() async throws {
        let server = "0b5a3c1e-7c43-4a5e-9d1f-2b9a0e7f6c11"
        try await withLibrary { store, _ in
            let local = Local(); local.automaticReady = true
            let routes = RoutedPlaybackEngine(local: local); defer { routes.unload() }
            let player = PlaybackCoordinator(store: store, engine: routes, clock: { Date(timeIntervalSince1970: 1000) })
            try await store.updateEpisode(id: 1) { $0.userState.positionMilliseconds = 12_000 }
            try await player.select(episodeID: 1, play: false); try await player.awaitPendingOperations()
            let before = try await store.episode(id: 1), session = try await store.playbackSession()
            let controller = CastReceiverSessionController(player: player, routes: routes, automaticallyPoll: false,
                library: .server(server), prepareMedia: media, onProblem: { XCTFail($0) })
            let client = Client(); client.snapshot = status("1")
            controller.receive(.connected(snapshot(client), resumed: true))
            try await wait { !client.requests.isEmpty }; client.requests[0].callback(.completed)
            await controller.awaitRestoration(); try await player.awaitPendingOperations()
            XCTAssertEqual(controller.unresolved, .invalidMediaID)
            XCTAssertFalse(routes.isRemote); XCTAssertEqual(player.episode?.id, 1); XCTAssertNotEqual(player.phase, .playing)
            // The receiver plays on and finishes its item; its final unload reads the receiver again.
            for position: Int32 in [61_000, 90_000] { client.snapshot?.positionMilliseconds = position; client.onStatus?() }
            client.snapshot?.state = .idle; client.snapshot?.idleReason = .finished; client.onStatus?()
            let reads = client.requests.count
            client.snapshot?.mediaID = nil; client.snapshot?.mediaSessionID = 0; client.onStatus?()
            try await wait { client.requests.count > reads }; client.requests.last!.callback(.completed)
            await controller.awaitRestoration(); try await player.awaitPendingOperations()
            XCTAssertEqual(mediaCommands(client), [])
            let after = try await store.episode(id: 1)
            XCTAssertEqual(after, before, "no position, completion, history or played time from the receiver")
            let sessionAfter = try await store.playbackSession(), selection = try await store.playbackSelectionEpisodeID()
            XCTAssertEqual(sessionAfter, session); XCTAssertEqual(selection, 1)
            XCTAssertEqual(player.episode?.id, 1)
        }
    }

    /// Colliding local IDs at runtime: B adopted its own episode 1 from the receiver; another sender then loads the
    /// standalone library's episode 1 there (same media ID, no library tag, a new media session). The engine stops
    /// observing it and the item is foreign: its progress and end never reach B's row, and B's commands never reach it.
    func testForeignItemUnderTheLoadedEpisodesIDNeverReachesItAtRuntime() async throws {
        let server = "0b5a3c1e-7c43-4a5e-9d1f-2b9a0e7f6c11"
        try await withLibrary { store, _ in
            let routes = RoutedPlaybackEngine(local: Local()); defer { routes.unload() }
            let player = PlaybackCoordinator(store: store, engine: routes, clock: { Date(timeIntervalSince1970: 1000) })
            let controller = CastReceiverSessionController(player: player, routes: routes, automaticallyPoll: false,
                library: .server(server), prepareMedia: media, onProblem: { XCTFail($0) })
            let client = Client(); client.snapshot = status(); client.snapshot?.libraryID = server
            controller.receive(.connected(snapshot(client), resumed: true))
            try await wait { client.requests.count == 1 }; client.requests[0].callback(.completed)
            await controller.awaitRestoration(); try await player.awaitPendingOperations()
            XCTAssertNil(controller.unresolved); XCTAssertEqual(player.episode?.id, 1); XCTAssertTrue(routes.isRemote)
            let adopted = try await store.episode(id: 1), session = try await store.playbackSession()
            let queued = try await store.queue().map(\.id)

            client.snapshot = status("1", position: 5_000); client.snapshot?.mediaSessionID = 99
            let before = client.requests.count; client.onStatus?()
            try await wait { client.requests.count > before }; client.requests.last!.callback(.completed)
            await controller.awaitRestoration(); try await player.awaitPendingOperations()
            XCTAssertEqual(controller.unresolved, .invalidMediaID)
            let commands = client.requests.count
            // The foreign item plays on and finishes (its final unload reads the receiver again); the person pauses.
            client.snapshot?.positionMilliseconds = 30_000; client.onStatus?()
            client.snapshot?.state = .idle; client.snapshot?.idleReason = .finished; client.snapshot?.mediaID = nil
            client.snapshot?.mediaSessionID = 0; client.onStatus?()
            try await wait { client.requests.count > commands }; client.requests.last!.callback(.completed)
            await controller.awaitRestoration(); try await player.awaitPendingOperations()
            try await player.pause(); try await player.awaitPendingOperations()
            XCTAssertEqual(mediaCommands(client, after: commands), [], "B's pause is not sent to the foreign item")
            let after = try await store.episode(id: 1)
            XCTAssertEqual(after?.userState.positionMilliseconds, adopted?.userState.positionMilliseconds)
            XCTAssertEqual(after?.userState.playState, adopted?.userState.playState, "the foreign item's end completes nothing")
            XCTAssertEqual(after?.userState.playedDurationMilliseconds, adopted?.userState.playedDurationMilliseconds)
            let queue = try await store.queue().map(\.id)
            XCTAssertEqual(queue, queued, "no completion removed it from the queue")
            let sessionAfter = try await store.playbackSession()
            XCTAssertEqual(sessionAfter?.id, session?.id); XCTAssertEqual(sessionAfter?.episodeID, 1)
            XCTAssertEqual(player.episode?.id, 1)
        }
    }

    func testCancelledStatusAndUserSelectionRetireAdoptionWithoutRemoteCommands() async throws {
        try await withLibrary { store, _ in
            let local = Local(); local.automaticReady = true
            let routes = RoutedPlaybackEngine(local: local); defer { routes.unload() }
            let player = PlaybackCoordinator(store: store, engine: routes)
            let controller = CastReceiverSessionController(player: player, routes: routes, automaticallyPoll: false,
                prepareMedia: media, onProblem: { XCTFail($0) })
            let client = Client(); client.snapshot = status()
            controller.receive(.connected(snapshot(client), resumed: true))
            try await wait { client.requests.count == 1 }
            controller.receive(.connected(snapshot(client), resumed: true))
            XCTAssertEqual(client.requests.count, 1)
            controller.receive(.ended(id, message: nil))
            try await wait { client.requests[0].token.cancelled }
            client.requests[0].callback(.completed)
            XCTAssertNil(player.episode)
            let other = Client(); other.snapshot = status()
            controller.receive(.connected(snapshot(other), resumed: true))
            try await wait { !other.requests.isEmpty }
            try await player.select(episodeID: 2, play: false)
            other.requests[0].callback(.completed); await controller.awaitRestoration()
            XCTAssertEqual(player.episode?.id, 2); XCTAssertFalse(routes.isRemote)
            XCTAssertEqual(other.requests.count, 1)
        }
    }

    func testConfirmedEmptyReceiverPreparesSavedSelectionPausedButUnknownStatusDoesNot() async throws {
        try await withLibrary { store, _ in
            _ = try await store.beginPlayback(episodeID: 1, positionMilliseconds: 0)
            let routes = RoutedPlaybackEngine(local: Local()); defer { routes.unload() }
            let player = PlaybackCoordinator(store: store, engine: routes)
            let controller = CastReceiverSessionController(player: player, routes: routes, automaticallyPoll: false,
                prepareMedia: media, onProblem: { XCTFail($0) })
            let unknown = Client(); controller.receive(.connected(snapshot(unknown), resumed: true))
            try await wait { !unknown.requests.isEmpty }; unknown.requests[0].callback(.completed)
            await controller.awaitRestoration()
            XCTAssertEqual(controller.unresolved, .unavailableStatus); XCTAssertFalse(routes.isRemote)
            let empty = Client()
            empty.snapshot = .init(mediaID: nil, loadID: nil, mediaSessionID: 0, positionMilliseconds: 0,
                durationMilliseconds: 0, state: .idle)
            controller.receive(.connected(snapshot(empty), resumed: true))
            try await wait { !empty.requests.isEmpty }; empty.requests[0].callback(.completed)
            await controller.awaitRestoration(); try await wait { empty.loads.count == 1 }
            XCTAssertEqual(empty.loadData(empty.loads[0]).autoplay, false)
        }
    }

    func testReceiverDeviceTransferKeepsActiveStatisticsAndAuthorizedMediaLease() async throws {
        try await withLibrary { store, _ in
            let local = Local(); local.automaticReady = true
            let routes = RoutedPlaybackEngine(local: local); defer { routes.unload() }
            let player = PlaybackCoordinator(store: store, engine: routes)
            var prepared = 0, released = 0
            let controller = CastReceiverSessionController(player: player, routes: routes, automaticallyPoll: false,
                prepareMedia: { episode in
                    prepared += 1
                    return .init(item: .init(contentURL: "https://owned.example/relay", mediaID: String(episode.id)),
                        release: { released += 1 })
                }, onProblem: { XCTFail($0) })
            try await player.select(episodeID: 1); try await player.awaitPendingOperations()
            let original = try await store.playbackSession()
            let first = Client(); controller.receive(.connected(snapshot(first), resumed: false))
            try await wait { first.loads.count == 1 }; first.finishLoad(0, state: .playing, position: 25_000)
            first.snapshot?.contentURL = "https://owned.example/relay"
            try await player.awaitPendingOperations()
            let second = Client(); second.snapshot = first.snapshot
            second.snapshot?.positionMilliseconds = 40_000; second.snapshot?.mediaSessionID = 200
            let destination = CastSessionIdentity(deviceID: "destination", sessionID: "transferred")
            controller.receive(.connected(snapshot(second, id: destination), resumed: true))
            try await wait { second.requests.count == 1 }; second.requests[0].callback(.completed)
            await controller.awaitRestoration(); try await player.awaitPendingOperations()
            XCTAssertNil(controller.unresolved); XCTAssertTrue(second.loads.isEmpty)
            XCTAssertEqual(prepared, 1); XCTAssertEqual(released, 0)
            let retained = try await store.playbackSession(), advanced = try await store.episode(id: 1)
            XCTAssertEqual(retained?.id, original?.id)
            XCTAssertEqual(advanced?.userState.positionMilliseconds, 40_000)
            XCTAssertEqual(advanced?.userState.playedDurationMilliseconds, 40_000)
            controller.receive(.ending(snapshot(second, id: destination)))
            XCTAssertEqual(local.loaded.last?.2, 40_000)
            XCTAssertEqual(released, 1)
        }
    }

    func testReceiverChangeDuringLibraryLookupAdoptsOnlyTheLatestEpisode() async throws {
        try await withLibrary { store, _ in
            let routes = RoutedPlaybackEngine(local: Local()); defer { routes.unload() }
            let gate = CastPlaybackEngineTests.Gate()
            let player = PlaybackCoordinator(store: store, engine: routes, skipPreferences: { episode in
                if episode.id == 1 { await gate.hold() }
                return .init()
            })
            defer { gate.release() }
            let controller = CastReceiverSessionController(player: player, routes: routes, automaticallyPoll: false,
                prepareMedia: media, onProblem: { XCTFail($0) })
            let client = Client(); client.snapshot = status()
            controller.receive(.connected(snapshot(client), resumed: true))
            try await wait { client.requests.count == 1 }; client.requests[0].callback(.completed)
            try await wait { gate.waiting }
            client.snapshot = status("2", position: 80_000); client.snapshot?.mediaSessionID = 43; client.onStatus?()
            try await wait { client.requests.count == 2 }; client.requests[1].callback(.completed)
            gate.release(); await controller.awaitRestoration(); try await player.awaitPendingOperations()
            XCTAssertEqual(player.episode?.id, 2); XCTAssertEqual(player.sample?.positionMilliseconds, 80_000)
            let queue = try await store.queue().map(\.id), first = try await store.episode(id: 1)
            XCTAssertEqual(queue, [2]); XCTAssertEqual(first?.userState.playedDurationMilliseconds, 0)
            XCTAssertTrue(client.loads.isEmpty)
        }
    }

    func testExplicitPlayCanReplaceAnUnresolvedForeignItemUsingAuthorizedMedia() async throws {
        try await withLibrary { store, _ in
            let routes = RoutedPlaybackEngine(local: Local()); defer { routes.unload() }
            let player = PlaybackCoordinator(store: store, engine: routes, clock: { Date(timeIntervalSince1970: 1000) })
            let controller = CastReceiverSessionController(player: player, routes: routes, automaticallyPoll: false,
                prepareMedia: media, onProblem: { XCTFail($0) })
            let client = Client(); client.snapshot = status()
            controller.receive(.connected(snapshot(client), resumed: true))
            try await wait { client.requests.count == 1 }; client.requests[0].callback(.completed)
            await controller.awaitRestoration(); try await player.awaitPendingOperations()
            client.snapshot = status("foreign", position: 5000); client.snapshot?.mediaSessionID = 99
            let before = client.requests.count; client.onStatus?()
            try await wait { client.requests.count > before }; client.requests.last!.callback(.completed)
            await controller.awaitRestoration()
            XCTAssertEqual(controller.unresolved, .invalidMediaID)
            try await player.play(); try await wait { client.loads.count == 1 }
            XCTAssertEqual(client.loadData(client.loads[0]).queueData?.items?.first?.mediaInformation.contentID,
                "https://authorized.example/relay")
            client.finishLoad(client.loads[0], state: .playing, position: 60_000)
            try await player.awaitPendingOperations()
            XCTAssertEqual(player.phase, .playing)
        }
    }

    func testAdoptedNaturalCompletionCountsOnlyObservedProgressAndFinishesQueueOnce() async throws {
        try await withLibrary { store, _ in
            let routes = RoutedPlaybackEngine(local: Local()); defer { routes.unload() }
            let player = PlaybackCoordinator(store: store, engine: routes)
            let controller = CastReceiverSessionController(player: player, routes: routes, automaticallyPoll: false,
                prepareMedia: media, onProblem: { XCTFail($0) })
            let client = Client(); client.snapshot = status()
            controller.receive(.connected(snapshot(client), resumed: true))
            try await wait { client.requests.count == 1 }; client.requests[0].callback(.completed)
            await controller.awaitRestoration(); try await player.awaitPendingOperations()
            client.snapshot?.state = .idle; client.snapshot?.idleReason = .finished
            client.snapshot?.positionMilliseconds = 100_000; client.snapshot?.mediaID = nil
            let callback = client.onStatus
            callback?(); callback?()
            try await player.awaitPendingOperations()
            let finished = try await store.episode(id: 1), session = try await store.playbackSession()
            let queue = try await store.queue()
            XCTAssertEqual(finished?.userState.playState, .played)
            XCTAssertEqual(finished?.userState.playedDurationMilliseconds, 40_000)
            XCTAssertNil(session); XCTAssertTrue(queue.isEmpty)
        }
    }
}
