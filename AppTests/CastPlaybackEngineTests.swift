import XCTest
import GoogleCast
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor final class CastPlaybackEngineTests: XCTestCase {
    final class Token: CastRequestCancellation {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    final class Client: CastMediaClient {
        struct Request {
            var command: CastMediaCommand
            var callback: @MainActor (CastRequestOutcome) -> Void
            var token: Token
        }
        var snapshot: CastRemoteSnapshot?
        var onStatus: (@MainActor () -> Void)?
        var requests: [Request] = []
        func send(_ command: CastMediaCommand, completion: @escaping @MainActor (CastRequestOutcome) -> Void) -> any CastRequestCancellation {
            let token = Token(); requests.append(Request(command: command, callback: completion, token: token)); return token
        }
        var loads: [Int] { requests.indices.filter { if case .load = requests[$0].command { true } else { false } } }
        func loadData(_ index: Int) -> GCKMediaLoadRequestData {
            guard case .load(let data) = requests[index].command else { preconditionFailure("Not a load") }
            return data
        }
        func status(for index: Int, state: GCKMediaPlayerState = .paused, position: Int32 = 0) -> CastRemoteSnapshot {
            let metadata = loadData(index).queueData!.items![0].mediaInformation.metadata!
            return CastRemoteSnapshot(mediaID: metadata.string(forKey: "media_id"),
                loadID: metadata.string(forKey: CastMediaItemCodec.loadIDKey), mediaSessionID: 100 + index,
                positionMilliseconds: position, durationMilliseconds: 100_000, state: state,
                libraryID: metadata.string(forKey: CastMediaItemCodec.libraryIDKey))
        }
        func finishLoad(_ index: Int, state: GCKMediaPlayerState = .paused, position: Int32 = 0) {
            snapshot = status(for: index, state: state, position: position)
            onStatus?() // The SDK can notify status before completing its request.
            requests[index].callback(.completed)
        }
        func publish(_ status: CastRemoteSnapshot) { snapshot = status; onStatus?() }
    }
    @MainActor final class Gate {
        var waiting = false
        private var continuation: CheckedContinuation<Void, Never>?
        func hold() async { await withCheckedContinuation { waiting = true; continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
    func episode(_ id: Int64 = 1) -> LibraryEpisode {
        .init(id: id, details: ParsedEpisode(identifier: String(id), title: "Cast episode",
            media: ParsedMedia(url: "https://origin.example/episode.mp3", size: 1, durationMilliseconds: 100_000)))
    }
    func media(_ episode: LibraryEpisode, release: @escaping @MainActor () -> Void = {}) -> CastPlaybackMedia {
        CastPlaybackMedia(item: .init(contentURL: "https://relay.example/authorized-media", mediaID: String(episode.id),
            localPlaybackURL: "file:///media/episode.mp3", title: episode.details.title, subtitle: "Podcast"), release: release)
    }
    func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition()); if !condition() { throw URLError(.timedOut) }
    }

    func testReceiverBufferingSurvivesIntentCommandsUntilReceiverIsReady() async throws {
        for state in [GCKMediaPlayerState.buffering, .loading] {
            let client = Client()
            let engine = CastPlaybackEngine(client:client,automaticallyPoll:false,prepareMedia:{ [self] in media($0) })
            defer { engine.unload() }
            engine.load(episode:episode(),generation:UUID(),positionMilliseconds:0)
            try await wait { client.loads.count == 1 }
            let load = client.loads[0]
            client.finishLoad(load,state:state)
            XCTAssertTrue(try XCTUnwrap(engine.reading).buffering)
            var delivered: [PlaybackEngineReading] = []
            engine.onEvent = { if case .stateChanged(let reading) = $0 { delivered.append(reading) } }
            for intent in ["pause","play","seek","speed","pause"] {
                let command = UUID()
                switch intent {
                case "pause": engine.pause(commandID:command)
                case "play": engine.play(commandID:command)
                case "seek": engine.seek(to:25_000,commandID:command)
                default: try engine.setSpeed(1.5,commandID:command)
                }
                XCTAssertTrue(try XCTUnwrap(engine.reading).buffering, intent)
                XCTAssertEqual(delivered.last?.commandID,command)
                XCTAssertTrue(try XCTUnwrap(delivered.last).buffering, intent)
            }
            XCTAssertEqual(engine.reading?.sample.status,.paused)
            let pendingPause = client.requests.count - 1
            client.publish(client.status(for:load,state:.buffering,position:25_000))
            XCTAssertTrue(try XCTUnwrap(engine.reading).buffering)
            client.snapshot = client.status(for:load,state:.paused,position:25_000)
            client.requests[pendingPause].callback(.completed)
            XCTAssertFalse(try XCTUnwrap(engine.reading).buffering)
            XCTAssertEqual(engine.reading?.sample.status,.paused)
            XCTAssertEqual(engine.reading?.sample.positionMilliseconds,25_000)
        }
    }

    func testPreparationUsesLatestIntentAndAnAuthorizedReceiverURL() async throws {
        let client = Client(), gate = Gate()
        let engine = CastPlaybackEngine(client: client, automaticallyPoll: false) { [self] item in
            await gate.hold(); return media(item)
        }
        defer { engine.unload(); gate.release() }
        let generation = UUID(), command = UUID()
        engine.load(episode: episode(), generation: generation, positionMilliseconds: 1000)
        engine.play(commandID: command); engine.seek(to: 12_500, commandID: command)
        try engine.setSpeed(3, commandID: command); engine.pause(commandID: command)
        try await wait { gate.waiting }; gate.release(); try await wait { client.loads.count == 1 }
        let data = client.loadData(client.loads[0]), info = data.queueData!.items![0].mediaInformation
        XCTAssertEqual(data.autoplay, false); XCTAssertEqual(data.startTime, 12.5); XCTAssertEqual(data.playbackRate, 2)
        XCTAssertEqual(info.contentID, "https://relay.example/authorized-media")
        XCTAssertEqual(info.metadata?.string(forKey: "local_file_url"), "file:///media/episode.mp3")
        XCTAssertNotNil(info.metadata?.string(forKey: CastMediaItemCodec.loadIDKey))
        XCTAssertEqual(engine.reading?.generation, generation); XCTAssertEqual(engine.reading?.commandID, command)
        XCTAssertFalse(engine.reading!.isPrepared)
    }

    func testInFlightLoadKeepsNewSeekPlaySpeedAndCombinedVolumeUntilAcknowledged() async throws {
        let client = Client()
        let engine = CastPlaybackEngine(client: client, automaticallyPoll: false, prepareMedia: { [self] in media($0) })
        defer { engine.unload() }
        let command = UUID()
        engine.load(episode: episode(), generation: UUID(), positionMilliseconds: 0)
        try await wait { client.loads.count == 1 }
        engine.play(commandID: command); engine.seek(to: 30_000, commandID: command)
        try engine.setSpeed(1.75, commandID: command)
        try engine.setVolumeAdaptation(.heavyReduction); try engine.setSleepTimerVolume(0.4)
        client.finishLoad(client.loads[0])
        XCTAssertTrue(engine.reading!.isPrepared)
        XCTAssertEqual(engine.reading?.sample.status, .playing)
        XCTAssertEqual(engine.reading?.sample.positionMilliseconds, 30_000)
        XCTAssertEqual(engine.reading?.speed, 1.75)
        XCTAssertEqual(engine.reading?.commandID, command)
        var commands: [String] = []
        for request in client.requests.dropFirst() {
            switch request.command {
            case .seek(let value): XCTAssertEqual(value, 30_000); commands.append("seek")
            case .play: commands.append("play")
            case .speed(let value): XCTAssertEqual(value, 1.75); commands.append("speed")
            case .volume(let value): XCTAssertEqual(value, 0.08, accuracy: 0.00001); commands.append("volume")
            default: XCTFail("Unexpected control")
            }
        }
        XCTAssertEqual(commands, ["seek", "play", "speed", "volume"])
        client.onStatus?()
        XCTAssertEqual(engine.reading?.sample.positionMilliseconds, 30_000)
        var status = client.snapshot!; status.positionMilliseconds = 30_000; status.state = .playing; status.speed = 1.75
        client.snapshot = status
        for index in 1..<client.requests.count { client.requests[index].callback(.completed) }
        status.positionMilliseconds = 32_000; client.snapshot = status
        var progress: Int32?
        engine.onEvent = { if case .position(let value) = $0 { progress = value.sample.positionMilliseconds } }
        engine.receiveStatus(progress: true)
        XCTAssertEqual(progress, 32_000)
    }

    func testSupersededSeekCannotFailOrRestoreTheOldPosition() async throws {
        let client = Client()
        let selected = CastPlaybackEngine(client: client, automaticallyPoll: false, prepareMedia: { [self] in media($0) })
        defer { selected.unload() }
        selected.load(episode: episode(), generation: UUID(), positionMilliseconds: 0)
        try await wait { !client.loads.isEmpty }; client.finishLoad(client.loads[0], state: .playing)
        selected.seek(to: 15_000, commandID: UUID()); let old = client.requests.count - 1
        selected.seek(to: 22_000, commandID: UUID()); let current = client.requests.count - 1
        var failures = 0; selected.onEvent = { if case .failed = $0 { failures += 1 } }
        XCTAssertTrue(client.requests[old].token.cancelled)
        client.requests[old].callback(.failed("late failure"))
        client.snapshot?.positionMilliseconds = 22_000; client.requests[current].callback(.completed)
        XCTAssertEqual(failures, 0); XCTAssertEqual(selected.reading?.sample.positionMilliseconds, 22_000)
        client.snapshot?.state = .paused; client.onStatus?()
        XCTAssertEqual(selected.reading?.sample.status, .paused)
    }

    func testStopRetainsPositionAndExplicitPlayReloadsWhileNaturalEndIsDeliveredOnce() async throws {
        let client = Client()
        let selected = CastPlaybackEngine(client: client, automaticallyPoll: false, prepareMedia: { [self] in media($0) })
        defer { selected.unload() }
        var ends = 0
        selected.onEvent = { if case .ended = $0 { ends += 1 } }
        selected.load(episode: episode(), generation: UUID(), positionMilliseconds: 10_000)
        try await wait { !client.loads.isEmpty }; client.finishLoad(client.loads[0], state: .playing, position: 10_000)
        selected.seek(to: 12_000, commandID: UUID())
        let retiredSeek = client.requests.count - 1
        var stopped = client.snapshot!; stopped.state = .idle; stopped.idleReason = .cancelled; stopped.positionMilliseconds = 0
        client.publish(stopped)
        XCTAssertTrue(client.requests[retiredSeek].token.cancelled)
        XCTAssertEqual(ends, 0); XCTAssertEqual(selected.reading?.sample.positionMilliseconds, 12_000)
        XCTAssertEqual(selected.reading?.sample.status, .paused)
        selected.play(commandID: UUID()); XCTAssertEqual(client.loads.count, 2)
        let reloaded = client.loads[1]
        XCTAssertEqual(client.loadData(reloaded).startTime, 12)
        client.finishLoad(reloaded, state: .playing, position: 13_000)
        client.requests[retiredSeek].callback(.failed("retired before receiver reload"))
        XCTAssertEqual(selected.reading?.sample.positionMilliseconds, 13_000)
        var finished = client.snapshot!; finished.state = .idle; finished.idleReason = .finished
        finished.mediaID = nil; finished.loadID = nil
        client.publish(finished); selected.receiveStatus(progress: true)
        XCTAssertEqual(ends, 1); XCTAssertEqual(selected.reading?.sample.positionMilliseconds, 100_000)
    }

    func testRetiredCallbacksAndSameEpisodeStatusCannotCompleteReplacementLoad() async throws {
        let client = Client()
        var closes = 0
        let engine = CastPlaybackEngine(client: client, automaticallyPoll: false) { [self] item in media(item) { closes += 1 } }
        defer { engine.unload() }
        engine.load(episode: episode(), generation: UUID(), positionMilliseconds: 0)
        try await wait { client.loads.count == 1 }; client.finishLoad(client.loads[0], state: .playing)
        let oldStatus = client.onStatus, oldRequest = client.requests[client.loads[0]].callback, old = client.snapshot!
        let replacement = UUID(); engine.load(episode: episode(), generation: replacement, positionMilliseconds: 8000)
        try await wait { client.loads.count == 2 }
        var errors = 0, ends = 0
        engine.onEvent = { if case .failed = $0 { errors += 1 }; if case .ended = $0 { ends += 1 } }
        oldStatus?(); oldRequest(.failed("retired load"))
        client.snapshot = old; client.requests[client.loads[1]].callback(.completed)
        XCTAssertFalse(engine.reading!.isPrepared)
        XCTAssertEqual(closes, 1); XCTAssertEqual(errors, 0); XCTAssertEqual(ends, 0)
        client.publish(client.status(for: client.loads[1], state: .paused, position: 8000))
        XCTAssertTrue(engine.reading!.isPrepared); XCTAssertEqual(engine.reading?.generation, replacement)
    }

    func testCancelledMediaPreparationReleasesLateLeaseWithoutLoadingIt() async throws {
        let client = Client(), gate = Gate(); var closed = 0
        let engine = CastPlaybackEngine(client: client, automaticallyPoll: false) { [self] item in
            let lease = media(item) { closed += 1 }; await gate.hold(); return lease
        }
        defer { engine.unload(); gate.release() }
        engine.load(episode: episode(), generation: UUID(), positionMilliseconds: 0)
        try await wait { gate.waiting }; engine.unload(); gate.release()
        try await wait { closed == 1 }
        XCTAssertTrue(client.loads.isEmpty); XCTAssertNil(engine.reading)
    }

    func testRequestFailureIsReportedOnceWithoutRetryAndFastNaturalEndIsNotLost() async throws {
        let client = Client()
        let engine = CastPlaybackEngine(client: client, automaticallyPoll: false, prepareMedia: { [self] in media($0) })
        defer { engine.unload() }
        var errors: [String] = [], events: [String] = []
        engine.onEvent = { if case .failed(_, let message) = $0 { errors.append(message) } }
        engine.load(episode: episode(), generation: UUID(), positionMilliseconds: 0)
        try await wait { client.loads.count == 1 }
        let callback = client.requests[client.loads[0]].callback
        callback(.failed("Receiver rejected the media")); callback(.failed("duplicate"))
        XCTAssertEqual(errors, ["Receiver rejected the media"]); XCTAssertEqual(client.loads.count, 1)
        engine.load(episode: episode(), generation: UUID(), positionMilliseconds: 0)
        try await wait { client.loads.count == 2 }
        engine.onEvent = { if case .ready = $0 { events.append("ready") }; if case .ended = $0 { events.append("ended") } }
        let index = client.loads[1]
        var finished = client.status(for: index, state: .idle, position: 100_000); finished.idleReason = .finished
        client.snapshot = finished; client.requests[index].callback(.completed)
        XCTAssertEqual(events, ["ready", "ended"])
    }

    func testSDKRequestDelegateCompletesAndCancellationRetiresItsCallback() async throws {
        let completed = expectation(description: "Actual SDK request completion")
        let request = GCKRequest.application()
        let tracker = GoogleCastRequest(request) { outcome in
            if case .completed = outcome { completed.fulfill() } else { XCTFail("Wrong SDK result") }
        }
        request.complete()
        await fulfillment(of: [completed], timeout: 2)
        tracker.requestDidComplete(request) // A queued duplicate must be inert.
        var callbacks = 0
        let other = GCKRequest.application()
        let cancelled = GoogleCastRequest(other) { _ in callbacks += 1 }
        cancelled.cancel(); cancelled.requestDidComplete(other)
        XCTAssertEqual(callbacks, 0); XCTAssertNil(other.delegate)
    }

    func testIdleErrorAndCancellationBeforeFirstReadyDoNotLeavePreparationHanging() async throws {
        let client = Client()
        let engine = CastPlaybackEngine(client: client, automaticallyPoll: false, prepareMedia: { [self] in media($0) })
        defer { engine.unload() }
        var failures = 0, ready = 0, ends = 0
        engine.onEvent = {
            if case .failed = $0 { failures += 1 }
            if case .ready = $0 { ready += 1 }
            if case .ended = $0 { ends += 1 }
        }
        engine.load(episode: episode(), generation: UUID(), positionMilliseconds: 5000)
        try await wait { client.loads.count == 1 }
        var status = client.status(for: client.loads[0], state: .idle); status.idleReason = .error
        client.snapshot = status; client.requests[client.loads[0]].callback(.completed)
        XCTAssertEqual(failures, 1); XCTAssertEqual(ready, 0)
        engine.load(episode: episode(), generation: UUID(), positionMilliseconds: 5000)
        try await wait { client.loads.count == 2 }
        status = client.status(for: client.loads[1], state: .idle); status.idleReason = .cancelled
        client.snapshot = status; client.requests[client.loads[1]].callback(.completed)
        XCTAssertEqual(ready, 1); XCTAssertEqual(ends, 0)
        XCTAssertEqual(engine.reading?.sample.status, .paused)
        XCTAssertEqual(engine.reading?.sample.positionMilliseconds, 5000)
        engine.play(commandID: UUID()); XCTAssertEqual(client.loads.count, 3)
    }

    func testActualEnginePersistsReceiverProgressAndOnlyNaturalCompletionFinishesQueue() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("cast-engine-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        do {
            _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Cast", episodes: [episode().details]),
                source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
                validator: nil, permanentRedirectURL: nil))
            let client = Client()
            let engine = CastPlaybackEngine(client: client, automaticallyPoll: false, prepareMedia: { [self] in media($0) })
            let route = RoutedPlaybackEngine(local: ApplicationPlaybackEngine(muted: true))
            route.setRemote(engine)
            defer { route.unload() }
            let owner = PlaybackCoordinator(store: store, engine: route)
            try await owner.select(episodeID: 1)
            try await wait { client.loads.count == 1 }
            client.finishLoad(client.loads[0], state: .playing)
            try await owner.awaitPendingOperations()
            let session = try await store.playbackSession()
            var status = client.snapshot!; status.positionMilliseconds = 25_000
            client.snapshot = status; engine.receiveStatus(progress: true)
            try await owner.awaitPendingOperations()
            status.state = .paused; client.publish(status)
            try await owner.awaitPendingOperations()
            let saved = try await store.episode(id: 1), retained = try await store.playbackSession()
            let queue = try await store.queue().map(\.id)
            XCTAssertEqual(owner.phase, .paused); XCTAssertNotNil(session)
            XCTAssertEqual(session?.id, retained?.id)
            XCTAssertEqual(saved?.userState.positionMilliseconds, 25_000)
            XCTAssertEqual(saved?.userState.playedDurationMilliseconds, 25_000)
            XCTAssertNotEqual(saved?.userState.playState, .played); XCTAssertEqual(queue, [1])
            status.state = .idle; status.idleReason = .finished; status.positionMilliseconds = 100_000
            client.publish(status); engine.receiveStatus(progress: true)
            try await owner.awaitPendingOperations()
            let finished = try await store.episode(id: 1), finalSession = try await store.playbackSession()
            let finalQueue = try await store.queue()
            XCTAssertEqual(finished?.userState.playState, .played)
            XCTAssertEqual(finished?.userState.playedDurationMilliseconds, 100_000)
            XCTAssertNil(finalSession); XCTAssertTrue(finalQueue.isEmpty)
            route.unload()
        } catch { try? await store.close(); throw error }
        try await store.close()
    }

    func testBackgroundResumeKeepsGenerationLeaseAndReceiverProgressWithoutReload() async throws {
        let client = Client(); var closes = 0
        let engine = CastPlaybackEngine(client: client, automaticallyPoll: false) { [self] item in media(item) { closes += 1 } }
        defer { engine.unload() }
        let generation = UUID()
        engine.load(episode: episode(), generation: generation, positionMilliseconds: 1000)
        try await wait { client.loads.count == 1 }
        client.finishLoad(client.loads[0], state: .playing, position: 1000)
        client.requests.last!.callback(.completed)
        let late = client.onStatus
        engine.suspendConnection(); engine.suspendConnection()
        let resumed = Client()
        var status = client.snapshot!; status.positionMilliseconds = 35_000
        resumed.snapshot = status
        var ready = 0, progress: Int32?
        engine.onEvent = {
            if case .ready = $0 { ready += 1 }
            if case .position(let value) = $0 { progress = value.sample.positionMilliseconds }
        }
        engine.resumeConnection(client: resumed)
        late?() // A retired client's queued callback cannot validate cached status.
        XCTAssertNil(progress)
        XCTAssertEqual(engine.reading?.sample.positionMilliseconds, 1000)
        resumed.requests[0].callback(.completed)
        late?()
        XCTAssertEqual(closes, 0); XCTAssertEqual(ready, 0)
        XCTAssertEqual(progress, 35_000); XCTAssertEqual(engine.reading?.generation, generation)
        XCTAssertEqual(resumed.requests.count, 1); if case .status = resumed.requests[0].command {} else { XCTFail("Expected status refresh") }; XCTAssertEqual(client.loads.count, 1)
        XCTAssertNil(client.onStatus)
    }

    func testSuspendedCommandsWaitForFreshStatusAndResumeWithOnlyLatestValues() async throws {
        let client = Client()
        let engine = CastPlaybackEngine(client: client, automaticallyPoll: false, prepareMedia: { [self] in media($0) })
        defer { engine.unload() }
        engine.load(episode: episode(), generation: UUID(), positionMilliseconds: 0)
        try await wait { client.loads.count == 1 }; client.finishLoad(client.loads[0], state: .playing)
        client.requests.last!.callback(.completed)
        let requestCount = client.requests.count
        engine.suspendConnection()
        engine.seek(to: 40_000, commandID: UUID()); engine.seek(to: 45_000, commandID: UUID())
        engine.pause(commandID: UUID()); engine.play(commandID: UUID()); engine.pause(commandID: UUID())
        try engine.setSpeed(1.25, commandID: UUID()); try engine.setSpeed(1.75, commandID: UUID())
        try engine.setVolumeAdaptation(.heavyReduction); try engine.setSleepTimerVolume(0.4)
        XCTAssertEqual(client.requests.count, requestCount)
        let resumed = Client(); engine.resumeConnection(client: resumed)
        XCTAssertEqual(resumed.requests.count, 1)
        resumed.requests[0].callback(.completed)
        var status = client.snapshot!; status.positionMilliseconds = 30_000
        resumed.publish(status)
        let names = resumed.requests.dropFirst().map { request -> String in
            switch request.command {
            case .seek(let value): XCTAssertEqual(value, 45_000); return "seek"
            case .pause: return "pause"
            case .speed(let value): XCTAssertEqual(value, 1.75); return "speed"
            case .volume(let value): XCTAssertEqual(value, 0.08, accuracy: 0.00001); return "volume"
            default: XCTFail("Unexpected resume command"); return "unexpected"
            }
        }
        XCTAssertEqual(names, ["seek", "pause", "speed", "volume"])
        XCTAssertEqual(engine.reading?.sample.positionMilliseconds, 45_000)
        XCTAssertEqual(engine.reading?.sample.status, .paused); XCTAssertEqual(engine.reading?.speed, 1.75)
    }

    func testLoadAcceptedDuringSuspensionIsAdoptedAndPreSuspensionEditsSurvive() async throws {
        let client = Client()
        let engine = CastPlaybackEngine(client: client, automaticallyPoll: false, prepareMedia: { [self] in media($0) })
        defer { engine.unload() }
        engine.load(episode: episode(), generation: UUID(), positionMilliseconds: 0)
        try await wait { client.loads.count == 1 }
        let request = client.requests[0]
        engine.seek(to: 30_000, commandID: UUID()); try engine.setSpeed(1.5, commandID: UUID())
        engine.suspendConnection(); engine.pause(commandID: UUID())
        XCTAssertTrue(request.token.cancelled)
        request.callback(.failed("Disconnected sender"))
        let resumed = Client(); resumed.snapshot = client.status(for: 0, state: .playing, position: 12_000)
        engine.resumeConnection(client: resumed)
        resumed.requests[0].callback(.completed)
        XCTAssertTrue(engine.reading!.isPrepared)
        XCTAssertEqual(engine.reading?.sample.positionMilliseconds, 30_000)
        XCTAssertEqual(engine.reading?.sample.status, .paused); XCTAssertEqual(engine.reading?.speed, 1.5)
        XCTAssertTrue(resumed.loads.isEmpty); XCTAssertEqual(resumed.requests.count, 5)
    }

    func testNewSelectionWhileSuspendedWaitsAndLoadsOnlySelectedEpisodeOnResume() async throws {
        let client = Client()
        let prepared = expectation(description: "Media prepared while suspended")
        let gate = Gate()
        let selected = CastPlaybackEngine(client: client, automaticallyPoll: false) { [self] item in
            let lease = media(item); prepared.fulfill(); await gate.hold(); return lease
        }
        defer { selected.unload(); gate.release() }
        selected.suspendConnection()
        selected.load(episode: episode(3), generation: UUID(), positionMilliseconds: 7000)
        selected.play(commandID: UUID())
        await fulfillment(of: [prepared], timeout: 2)
        try await wait { gate.waiting }; gate.release()
        let resumed = Client()
        resumed.snapshot = .init(mediaID: nil, loadID: nil, mediaSessionID: 0,
            positionMilliseconds: 0, durationMilliseconds: 0, state: .idle)
        selected.resumeConnection(client: resumed)
        try await wait { resumed.loads.count == 1 }
        let data = resumed.loadData(resumed.loads[0])
        XCTAssertEqual(data.startTime, 7); XCTAssertEqual(data.autoplay, true)
        XCTAssertEqual(data.queueData?.items?.first?.mediaInformation.metadata?.string(forKey: "media_id"), "3")
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testResumeOfForeignItemRetiresOldControlsInsteadOfOverwritingReceiver() async throws {
        let client = Client()
        let engine = CastPlaybackEngine(client: client, automaticallyPoll: false, prepareMedia: { [self] in media($0) })
        engine.load(episode: episode(), generation: UUID(), positionMilliseconds: 0)
        try await wait { client.loads.count == 1 }; client.finishLoad(0, state: .playing)
        engine.suspendConnection(); engine.seek(to: 20_000, commandID: UUID())
        let resumed = Client()
        resumed.snapshot = .init(mediaID: "another-sender", loadID: nil, mediaSessionID: 99,
            positionMilliseconds: 60_000, durationMilliseconds: 120_000, state: .playing)
        var changed: String?
        engine.onReceiverItemChanged = { _, status in changed = status.mediaID }
        engine.resumeConnection(client: resumed)
        resumed.requests[0].callback(.completed)
        engine.play(commandID: UUID()); engine.unload()
        XCTAssertEqual(changed, "another-sender"); XCTAssertEqual(resumed.requests.count, 1)
    }

    func testNaturalEndDuringBackgroundIsDeliveredBeforeAnyDeferredControl() async throws {
        let client = Client()
        let engine = CastPlaybackEngine(client: client, automaticallyPoll: false, prepareMedia: { [self] in media($0) })
        defer { engine.unload() }
        engine.load(episode: episode(), generation: UUID(), positionMilliseconds: 0)
        try await wait { client.loads.count == 1 }; client.finishLoad(0, state: .playing)
        engine.suspendConnection(); try engine.setSleepTimerVolume(0.5)
        let resumed = Client()
        var status = client.snapshot!; status.state = .idle; status.idleReason = .finished
        status.mediaID = nil; status.loadID = nil; resumed.snapshot = status
        var ends = 0; engine.onEvent = { if case .ended = $0 { ends += 1 } }
        engine.resumeConnection(client: resumed); resumed.requests[0].callback(.completed); resumed.onStatus?()
        XCTAssertEqual(ends, 1); XCTAssertEqual(resumed.requests.count, 1)
    }
}
