import XCTest
import ObjectiveC
import GoogleCast
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor final class CastSessionRouteTests: XCTestCase {
    typealias Client = CastPlaybackEngineTests.Client
    typealias Local = RoutedPlaybackEngineTests.Engine
    let identity = CastSessionIdentity(deviceID: "device", sessionID: "session")
    func snapshot(_ client: Client, identity: CastSessionIdentity? = nil) -> CastSessionSnapshot {
        .init(identity: identity ?? self.identity, client: client, media: nil, status: client.snapshot)
    }
    func media(_ episode: LibraryEpisode) -> CastPlaybackMedia {
        .init(item: .init(contentURL: "https://relay.example/authorized-media", mediaID: String(episode.id)))
    }
    func episode() -> LibraryEpisode {
        .init(id: 1, details: .init(identifier: "1", title: "Session", media: .init(url: "https://origin.example/media", size: 1)))
    }
    func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        guard condition() else { XCTFail("Expected session transition"); throw URLError(.timedOut) }
    }

    func testSDKDelegateSelectorsMatchCastSpecificCallbacks() {
        for selector in ["sessionManager:didStartCastSession:", "sessionManager:didResumeCastSession:",
            "sessionManager:willEndCastSession:", "sessionManager:didEndCastSession:withError:",
            "sessionManager:didSuspendCastSession:withReason:", "sessionManager:didFailToStartCastSession:withError:"] {
            XCTAssertNotNil(class_getInstanceMethod(CastSessionEventSource.self, NSSelectorFromString(selector)), selector)
        }
        XCTAssertNil(class_getInstanceMethod(CastSessionEventSource.self, NSSelectorFromString("sessionManager:didStartSession:")))
    }

    func testWarmSessionBackgroundResumeAndEndingPreserveLatestPosition() async throws {
        let local = Local(); local.automaticReady = true
        let routes = RoutedPlaybackEngine(local: local), client = Client()
        defer { routes.unload() }
        let binding = CastSessionRouteBinding(routes: routes, automaticallyPoll: false, prepareMedia: media,
            onRestoredSession: { _ in XCTFail("Owned session should resume") }, onProblem: { XCTFail($0) })
        let generation = UUID()
        routes.load(episode: episode(), generation: generation, positionMilliseconds: 2000)
        routes.play(commandID: UUID()); local.advance(to: 8000)
        binding.receive(.connected(snapshot(client), resumed: false))
        try await wait { client.loads.count == 1 }
        XCTAssertEqual(client.loadData(0).startTime, 8)
        client.finishLoad(0, state: .playing, position: 8000); client.requests.last!.callback(.completed)
        binding.receive(.suspended(snapshot(client), reason: .appBackgrounded))
        XCTAssertTrue(routes.isRemote); XCTAssertEqual(local.loaded.count, 1)
        let resumed = Client(); var status = client.snapshot!; status.positionMilliseconds = 32_000
        resumed.snapshot = status
        binding.receive(.connected(snapshot(resumed), resumed: true))
        resumed.requests[0].callback(.completed)
        binding.receive(.connected(snapshot(resumed), resumed: true))
        XCTAssertEqual(resumed.requests.count, 1); XCTAssertTrue(resumed.loads.isEmpty)
        XCTAssertEqual(routes.reading?.generation, generation)
        status.positionMilliseconds = 36_000; resumed.snapshot = status
        binding.receive(.ending(snapshot(resumed)))
        resumed.snapshot = nil // SDK queue clearing happens after willEnd.
        binding.receive(.ended(identity, message: nil))
        XCTAssertFalse(routes.isRemote); XCTAssertEqual(local.loaded.count, 2)
        XCTAssertEqual(local.loaded.last?.2, 36_000); XCTAssertTrue(local.wantsPlayback)
    }

    func testNetworkLossHandsBackAndResumeTransfersLatestLocalProgress() async throws {
        let local = Local(); local.automaticReady = true
        let routes = RoutedPlaybackEngine(local: local), client = Client()
        defer { routes.unload() }
        let binding = CastSessionRouteBinding(routes: routes, automaticallyPoll: false, prepareMedia: media,
            onRestoredSession: { _ in XCTFail("Known local transfer") }, onProblem: { XCTFail($0) })
        routes.load(episode: episode(), generation: UUID(), positionMilliseconds: 0); routes.play(commandID: UUID())
        binding.receive(.connected(snapshot(client), resumed: false))
        try await wait { client.loads.count == 1 }; client.finishLoad(0, state: .playing, position: 10_000)
        let count = client.requests.count
        binding.receive(.suspended(snapshot(client), reason: .networkNotReachable))
        XCTAssertFalse(routes.isRemote); XCTAssertEqual(local.loaded.last?.2, 10_000)
        XCTAssertEqual(client.requests.count, count) // Cannot send STOP on the lost connection.
        local.advance(to: 25_000)
        let resumed = Client(); binding.receive(.connected(snapshot(resumed), resumed: true))
        try await wait { resumed.loads.count == 1 }
        XCTAssertEqual(resumed.loadData(0).startTime, 25)
        XCTAssertTrue(routes.isRemote)
    }

    func testUnownedResumeRequiresLibraryAdoptionWithoutOverwritingReceiver() {
        let local = Local(); local.automaticReady = true
        let routes = RoutedPlaybackEngine(local: local), client = Client()
        defer { routes.unload() }
        var restored: CastSessionSnapshot?
        let binding = CastSessionRouteBinding(routes: routes, automaticallyPoll: false, prepareMedia: media,
            onRestoredSession: { restored = $0 }, onProblem: { XCTFail($0) })
        routes.load(episode: episode(), generation: UUID(), positionMilliseconds: 5000)
        client.snapshot = .init(mediaID: "existing", loadID: nil, mediaSessionID: 99,
            positionMilliseconds: 60_000, durationMilliseconds: 120_000, state: .playing)
        binding.receive(.connected(snapshot(client), resumed: true))
        XCTAssertEqual(restored?.status?.positionMilliseconds, 60_000)
        XCTAssertEqual(restored?.identity, identity); XCTAssertTrue(client.requests.isEmpty)
        XCTAssertFalse(routes.isRemote); XCTAssertEqual(local.loaded.count, 1)
    }

    func testRetiredSessionEndingCannotHandBackReplacementSession() async throws {
        let local = Local(); local.automaticReady = true
        let routes = RoutedPlaybackEngine(local: local), first = Client(), second = Client()
        defer { routes.unload() }
        let binding = CastSessionRouteBinding(routes: routes, automaticallyPoll: false, prepareMedia: media,
            onRestoredSession: { _ in XCTFail("Unexpected restore") }, onProblem: { XCTFail($0) })
        routes.load(episode: episode(), generation: UUID(), positionMilliseconds: 0)
        binding.receive(.connected(snapshot(first), resumed: false))
        try await wait { first.loads.count == 1 }; first.finishLoad(0, position: 4000)
        let secondID = CastSessionIdentity(deviceID: "second", sessionID: "new")
        binding.receive(.connected(snapshot(second, identity: secondID), resumed: false))
        try await wait { second.loads.count == 1 }; second.finishLoad(0, position: 8000)
        binding.receive(.ending(snapshot(first)))
        binding.receive(.ended(identity, message: nil))
        XCTAssertTrue(routes.isRemote); XCTAssertEqual(local.loaded.count, 1)
        XCTAssertEqual(routes.reading?.sample.positionMilliseconds, 8000)
    }
}
