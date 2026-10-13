import UIKit
import XCTest
import GoogleCast
import ObjectiveC
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor final class CastApplicationRuntimeTests: XCTestCase {
    typealias Client = CastPlaybackEngineTests.Client
    typealias Local = RoutedPlaybackEngineTests.Engine
    final class Session: CastApplicationSession {
        let identity = CastSessionIdentity(deviceID: "living", sessionID: "one")
        var state = CastConnectionState()
        var onEvent: ((CastSessionEvent) -> Void)?
        var onChange: (() -> Void)?
        var starts = 0
        let discovery = ChooserTestDiscovery(), client = Client()
        var endings: [Bool] = [], volumes: [Float] = []
        var allowsEnding = true
        var receiverHasMedia = false
        func start() { starts += 1 }
        func makeDiscovery() -> any CastDeviceDiscovery { discovery }
        func snapshot() -> CastSessionSnapshot {
            .init(identity: identity, client: client, media: nil, status: client.snapshot,
                receiverAddress: .init(address: "127.0.0.1", port: 8009))
        }
        func connect() {
            state = .init(phase: .connected, identity: identity, name: "Living room", volume: 0.4, canDisconnect: true)
            onEvent?(.connected(snapshot(), resumed: false)); onChange?()
        }
        func end(stopReceiver: Bool) -> Bool {
            endings.append(stopReceiver)
            guard allowsEnding else { return false }
            onEvent?(.ending(snapshot())); state = .init(); onEvent?(.ended(identity, message: nil)); onChange?()
            return true
        }
        var memberVolumes: [(String, Float)] = []
        var memberCompletions: [@MainActor (CastRequestOutcome) -> Void] = []
        var memberTokens: [CastPlaybackEngineTests.Token] = []
        func setMemberVolume(_ value: Float, memberID: String, completion: @escaping @MainActor (CastRequestOutcome) -> Void) -> any CastRequestCancellation {
            memberVolumes.append((memberID, value)); memberCompletions.append(completion)
            let token = CastPlaybackEngineTests.Token(); memberTokens.append(token); return token
        }
        func setVolume(_ value: Float, completion: @escaping @MainActor (CastRequestOutcome) -> Void) -> any CastRequestCancellation {
            volumes.append(value); state.volume = value; completion(.completed); onChange?()
            return CastPlaybackEngineTests.Token()
        }
    }
    func wait(_ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        // Let the main run loop commit/render Core Animation transactions;
        // repeatedly yielding the actor can keep it busy until this deadline.
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate()); if !predicate() { throw URLError(.timedOut) }
    }
    func fixture(library: LibraryReference = .standalone,
                 _ body: (CastApplicationRuntime, Session, PlaybackCoordinator, Local, CastMediaAccessOwner, LibraryEpisode) async throws -> Void) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("cast-app-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let proxy = try await LoopbackHTTPServer.start { _ in .init(body: Data("authorized receiver bytes".utf8)) }
        defer { proxy.stop() }
        do {
            let feed = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Cast feed", episodes: [
                .init(identifier: "1", title: "Cast episode", media: .init(url: "http://publisher.invalid/media.mp3", size: 25, durationMilliseconds: 100_000))]),
                source: "https://publisher.invalid/feed", responseURL: URL(string: "https://publisher.invalid/feed")!, validator: nil, permanentRedirectURL: nil))
            let local = Local(); local.automaticReady = true
            let routes = RoutedPlaybackEngine(local: local)
            let player = PlaybackCoordinator(store: store, engine: routes)
            let media = CastMediaAccessOwner(store: store, authentication: FeedAuthentication(store: store),
                network: ProxyNetworkEnvironment(configuration: .init(kind: .http, host: "127.0.0.1", port: proxy.url.port!)), userAgent: "AntennaPod/test",
                library: library)
            let session = Session()
            let subject = CastApplicationRuntime(session: session, player: player, routes: routes, media: media)
            subject.start(); subject.start(); try await wait { session.starts == 1 }
            try await body(subject, session, player, local, media, feed.episodes[0])
            try await player.stop(); media.receiverStopped(deviceID: session.identity.deviceID)
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
    func loaded(_ runtime: CastApplicationRuntime, _ session: Session, _ player: PlaybackCoordinator, _ episode: LibraryEpisode) async throws -> URL {
        try await player.select(episodeID: episode.id, play: true)
        session.connect(); try await wait { !session.client.loads.isEmpty }
        let index = session.client.loads[0]
        let info = session.client.loadData(index).queueData!.items![0].mediaInformation
        let url = try XCTUnwrap(info.contentURL ?? info.contentID.flatMap(URL.init(string:)))
        session.client.finishLoad(index, state: .playing, position: 32_000)
        return url
    }
    /// PROTOCOL §15.4: a library switch waits while a session is connecting, or connected with media on the receiver
    /// (which a new library graph would adopt by its local ID); an idle connected receiver does not hold it.
    func testLibrarySwitchWaitsForAConnectingSessionOrReceiverMedia() async throws {
        try await fixture { runtime, session, _, _, _, _ in
            XCTAssertFalse(runtime.blocksLibrarySwitch)
            session.state = .init(phase: .connecting, identity: session.identity); session.onChange?()
            XCTAssertTrue(runtime.blocksLibrarySwitch)
            session.connect()
            XCTAssertEqual(runtime.state.phase, .connected); XCTAssertFalse(runtime.blocksLibrarySwitch)
            session.receiverHasMedia = true
            XCTAssertTrue(runtime.blocksLibrarySwitch)
            runtime.end(stopReceiver: false)
            XCTAssertFalse(runtime.blocksLibrarySwitch)
        }
    }
    /// A server library's loads name it beside `media_id`; the standalone library's carry no new key.
    func testLoadsNameTheirServerLibraryOnly() async throws {
        let server = "0b5a3c1e-7c43-4a5e-9d1f-2b9a0e7f6c11"
        for library in [LibraryReference.standalone, .server(server)] {
            try await fixture(library: library) { runtime, session, player, _, _, episode in
                _ = try await loaded(runtime, session, player, episode)
                let metadata = try XCTUnwrap(session.client.loadData(session.client.loads[0]).queueData?.items?.first?.mediaInformation.metadata)
                XCTAssertEqual(metadata.string(forKey: "media_id"), String(episode.id))
                if library == .standalone {
                    XCTAssertFalse(metadata.containsKey(CastMediaItemCodec.libraryIDKey))
                } else {
                    XCTAssertEqual(metadata.string(forKey: CastMediaItemCodec.libraryIDKey), server)
                }
                // The receiver reports the loaded item back with its tag: the library's own load plays.
                try await wait { player.phase == .playing }
                XCTAssertEqual(player.episode?.id, episode.id, "\(library)")
            }
        }
    }
    func testDisconnectPreservesReceiverBytesAndLocalProgressWithoutMediaStop() async throws {
        try await fixture { runtime, session, player, local, media, episode in
            let url = try await loaded(runtime, session, player, episode)
            let before = session.client.requests.count
            runtime.end(stopReceiver: false)
            XCTAssertEqual(session.endings, [false]); XCTAssertEqual(runtime.state.phase, .disconnected)
            XCTAssertEqual(local.loaded.last?.2, 32_000); XCTAssertTrue(local.wantsPlayback)
            XCTAssertFalse(session.client.requests.dropFirst(before).contains { if case .stop = $0.command { true } else { false } })
            let (bytes, _) = try await URLSession.shared.data(from: url)
            XCTAssertEqual(bytes, Data("authorized receiver bytes".utf8))
            try await player.stop()
            let (afterLocalStop, _) = try await URLSession.shared.data(from: url)
            XCTAssertEqual(afterLocalStop, bytes)
            media.setReceiver(.init(address: "127.0.0.1", port: 8009))
            let retained = try await media.authorizedMedia(episodeID: episode.id, contentURL: url.absoluteString)
            XCTAssertNotNil(retained); retained?.close()
            let closed = try await media.authorizedMedia(episodeID: episode.id, contentURL: url.absoluteString)
            XCTAssertNil(closed)
        }
    }
    func testStopCastingClosesLeaseAndRequestsReceiverTermination() async throws {
        try await fixture { runtime, session, player, local, media, episode in
            let url = try await loaded(runtime, session, player, episode)
            runtime.end(stopReceiver: true)
            XCTAssertEqual(session.endings, [true]); XCTAssertEqual(local.loaded.last?.2, 32_000)
            media.setReceiver(.init(address: "127.0.0.1", port: 8009))
            let retained = try await media.authorizedMedia(episodeID: episode.id, contentURL: url.absoluteString)
            XCTAssertNil(retained)
        }
    }
    func testRejectedEndingKeepsPlayingLeaseAndAllowsDisconnectRetry() async throws {
        try await fixture { runtime, session, player, _, _, episode in
            let url = try await loaded(runtime, session, player, episode)
            var problems: [String] = []
            let token = runtime.observe({ _ in }, problem: { problems.append($0) }); defer { token.cancel() }
            session.allowsEnding = false; runtime.end(stopReceiver: true)
            XCTAssertEqual(problems.count, 1); XCTAssertEqual(runtime.state.phase, .connected)
            session.allowsEnding = true; runtime.end(stopReceiver: false)
            let (bytes, _) = try await URLSession.shared.data(from: url)
            XCTAssertEqual(bytes, Data("authorized receiver bytes".utf8))
        }
    }
    func testChooserAndMultipleObserversFollowActualSessionEvents() async throws {
        try await fixture { runtime, session, _, _, _, _ in
            var first: [CastConnectionState.Phase] = [], second: [CastConnectionState.Phase] = []
            let a = runtime.observe({ first.append($0.phase) }, problem: { _ in })
            let b = runtime.observe({ second.append($0.phase) }, problem: { _ in })
            let chooser = runtime.makeChooser(); chooser.start()
            var selected = 0; chooser.onSelected = { selected += 1 }
            session.connect(); XCTAssertEqual(selected, 1); XCTAssertFalse(chooser.isActive)
            a.cancel(); runtime.setVolume(0.7)
            XCTAssertEqual(session.volumes, [0.7]); XCTAssertEqual(first, [.disconnected, .connected])
            XCTAssertEqual(second.last, .connected); runtime.end(stopReceiver: false)
            XCTAssertEqual(second.last, .disconnected); b.cancel()
        }
    }
    func element<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) throws -> T {
        func find(_ view: UIView) -> T? {
            if view.accessibilityIdentifier == id { return view as? T }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        return try XCTUnwrap(find(view), id)
    }
    func testGroupMembersPreserveSurvivorsAndPrependAdditionsWithoutNameSorting() {
        let a = CastGroupMember(id: "a", name: "Zulu", volume: 0.3)
        let b = CastGroupMember(id: "b", name: "Alpha", volume: 0.8)
        var members = CastGroupMembers(); members.replace([a, b, a])
        XCTAssertEqual(members.values.map(\.id), ["a", "b"])
        var changed = b; changed.name = "Renamed"; changed.volume = 0.4
        members.replace([changed, a]); XCTAssertEqual(members.values.map(\.id), ["a", "b"])
        XCTAssertEqual(members.values.last, changed)
        let c = CastGroupMember(id: "c", name: "New", volume: 0.2)
        members.update(c); XCTAssertEqual(members.values.map(\.id), ["c", "a", "b"])
        members.update(changed); XCTAssertEqual(members.values.map(\.id), ["c", "a", "b"])
        members.remove("a"); XCTAssertEqual(members.values.map(\.id), ["c", "b"])
        members.replace([]); XCTAssertTrue(members.values.isEmpty)
    }
    func testMemberRequestsAreIndependentAndRetireOnRemovalCapabilityOrSessionChange() async throws {
        try await fixture { runtime, session, _, _, _, _ in
            session.connect()
            session.state.members = [.init(id: "a", name: "A", volume: 0.3), .init(id: "b", name: "B", volume: 0.4)]
            session.onChange?()
            var errors: [String] = []
            let observation = runtime.observe({ _ in }, problem: { errors.append($0) }); defer { observation.cancel() }
            runtime.setMemberVolume(.nan, memberID: "a"); runtime.setMemberVolume(0.4, memberID: "missing")
            XCTAssertTrue(session.memberVolumes.isEmpty)
            runtime.setMemberVolume(2, memberID: "a"); runtime.setMemberVolume(-1, memberID: "b")
            XCTAssertEqual(session.memberVolumes.map { $0.1 }, [1, 0])
            runtime.setMemberVolume(0.6, memberID: "a")
            XCTAssertTrue(session.memberTokens[0].cancelled); XCTAssertFalse(session.memberTokens[1].cancelled)
            session.memberCompletions[0](.failed("stale")); XCTAssertTrue(errors.isEmpty)
            session.memberCompletions[1](.failed("current")); XCTAssertEqual(errors, ["current"])
            session.state.members[0].hasVariableVolume = false; session.onChange?()
            XCTAssertTrue(session.memberTokens[2].cancelled)
            runtime.setMemberVolume(0.5, memberID: "a"); XCTAssertEqual(session.memberVolumes.count, 3)
            session.memberCompletions[2](.failed("fixed")); XCTAssertEqual(errors.count, 1)
            runtime.setMemberVolume(0.8, memberID: "b"); session.state.members.removeAll { $0.id == "b" }; session.onChange?()
            XCTAssertTrue(session.memberTokens[3].cancelled)
            session.state.members = [.init(id: "a", name: "A", volume: 0.3)]; session.onChange?()
            runtime.setMemberVolume(0.8, memberID: "a")
            session.state.identity = .init(deviceID: "living", sessionID: "replacement"); session.onChange?()
            XCTAssertTrue(session.memberTokens[4].cancelled)
            session.memberCompletions[4](.failed("old session")); XCTAssertEqual(errors, ["current"])
            runtime.setMemberVolume(0.5, memberID: "a"); session.state.phase = .disconnected; session.onChange?()
            XCTAssertTrue(session.memberTokens[5].cancelled)
        }
    }
    func testGroupControlsExpandFixedRowsResizeAndMembershipUpdates() async throws {
        try await fixture { runtime, session, _, _, _, _ in
            session.connect(); session.state.canDisconnect = false; session.state.name = "Whole home"
            session.state.members = [.init(id: "kitchen", name: "Kitchen", volume: 0.3)]; session.onChange?()
            try await withViewTestWindow { host, _ in
                let animations = UIView.areAnimationsEnabled; UIView.setAnimationsEnabled(false)
                defer { UIView.setAnimationsEnabled(animations) }
                let dialog = CastConnectedController(runtime: runtime, identity: session.identity)
                host.addChild(dialog); host.view.addSubview(dialog.view); dialog.didMove(toParent: host)
                defer { dialog.willMove(toParent: nil); dialog.view.removeFromSuperview(); dialog.removeFromParent() }
                dialog.view.frame = host.view.bounds; dialog.view.traitOverrides.preferredContentSizeCategory = .large
                dialog.view.layoutIfNeeded()
                let expand: UIButton = try element("castGroupExpand", in: dialog.view)
                let list: UIScrollView = try element("castGroupMembers", in: dialog.view)
                let mainVolume = try element("castReceiverVolume", in: dialog.view)
                let before = mainVolume.frame
                XCTAssertTrue(expand.isHidden, "A single member is not a group"); XCTAssertEqual(list.frame.height, 0)
                session.state.members.insert(.init(id: "office", name: "Office 1", volume: 0.2, hasVariableVolume: false), at: 0); session.onChange?()
                dialog.view.layoutIfNeeded(); XCTAssertFalse(expand.isHidden)
                XCTAssertLessThan(mainVolume.frame.width, before.width, "The master slider makes room for the chevron")
                XCTAssertFalse(mainVolume.frame.intersects(expand.frame)); XCTAssertEqual(list.frame.height, 0)
                expand.sendActions(for: .touchUpInside); dialog.view.layoutIfNeeded()
                XCTAssertGreaterThan(list.frame.height, 0, "Expanding shows the member list")
                XCTAssertEqual(expand.accessibilityLabel, "Collapse")
                let fixed = try element("castMemberVolume-office", in: dialog.view)
                let variable = try element("castMemberVolume-kitchen", in: dialog.view)
                XCTAssertEqual(fixed.accessibilityValue, "100%"); XCTAssertFalse((fixed as! UIControl).isEnabled)
                XCTAssertTrue(fixed.accessibilityTraits.contains(.notEnabled))
                fixed.accessibilityIncrement(); XCTAssertTrue(session.memberVolumes.isEmpty)
                variable.accessibilityIncrement(); XCTAssertEqual(session.memberVolumes.first?.0, "kitchen")
                XCTAssertEqual(try XCTUnwrap(session.memberVolumes.first?.1), 0.35, accuracy: 0.001)
                for i in 0..<4 { session.state.members.append(.init(id: "extra-\(i)", name: "Speaker \(i)", volume: 0.4)) }
                session.onChange?(); dialog.view.layoutIfNeeded()
                XCTAssertGreaterThan(list.contentSize.height, list.frame.height, "Many members scroll inside the list")
                list.contentOffset.y = list.contentSize.height - list.bounds.height
                let last = try element("castMember-extra-3", in: dialog.view)
                let lastSlider = try element("castMemberVolume-extra-3", in: dialog.view)
                XCTAssertTrue(list.bounds.insetBy(dx: -1, dy: -1).contains(last.convert(lastSlider.frame, to: list)), "Last member is reachable")
                let offset = list.contentOffset.y
                session.state.members[0].name = "Renamed kitchen"; session.onChange?(); dialog.view.layoutIfNeeded()
                XCTAssertEqual(list.contentOffset.y, offset, accuracy: 1, "A rename does not jump the list")
                for rtl in [false, true] {
                    dialog.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                    dialog.view.frame.size = CGSize(width: 834, height: 600)
                    dialog.additionalSafeAreaInsets = .init(top: 11, left: rtl ? 84 : 0, bottom: 21, right: rtl ? 0 : 84)
                    dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                    XCTAssertGreaterThan(list.frame.height, 0)
                    let row = try element("castMember-office", in: dialog.view)
                    let slider = try element("castMemberVolume-office", in: row)
                    XCTAssertTrue(row.bounds.insetBy(dx: -1, dy: -1).contains(slider.frame), "Member slider stays inside its row")
                    let panel = try element("castConnectedPanel", in: dialog.view)
                    XCTAssertTrue(dialog.view.bounds.inset(by: dialog.view.safeAreaInsets).contains(panel.frame))
                    XCTAssertEqual(expand.accessibilityLabel, "Collapse")
                }
                let rowHeight = (try element("castMember-office", in: dialog.view)).frame.height
                let memberLabel = try XCTUnwrap((try element("castMember-office", in: dialog.view)).subviews.compactMap { $0 as? UILabel }.first)
                memberLabel.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
                dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                XCTAssertGreaterThan((try element("castMember-office", in: dialog.view)).frame.height, rowHeight, "Larger text grows the member row")
                let oldCount = session.memberVolumes.count
                session.state.members.removeAll { $0.id == "kitchen" }; session.onChange?()
                variable.accessibilityIncrement(); XCTAssertEqual(session.memberVolumes.count, oldCount)
                dialog.view.frame = host.view.bounds; dialog.additionalSafeAreaInsets = .zero
                dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                expand.sendActions(for: .touchUpInside); dialog.view.layoutIfNeeded()
                XCTAssertEqual(list.frame.height, 0); XCTAssertEqual(expand.accessibilityLabel, "Expand")
            }
        }
    }
    func testGroupAnimationRetogglesAndAccessibilityReceivesUpdatesImmediately() async throws {
        try await fixture { runtime, session, _, _, _, _ in
            session.connect(); session.state.members = [.init(id: "a", name: "A", volume: 0.3), .init(id: "b", name: "B", volume: 0.4)]; session.onChange?()
            let clock = ChooserTestClock()
            try await withViewTestWindow { host, _ in
                let dialog = CastConnectedController(runtime: runtime, identity: session.identity, clock: clock)
                host.addChild(dialog); host.view.addSubview(dialog.view); dialog.didMove(toParent: host)
                defer { dialog.willMove(toParent: nil); dialog.view.removeFromSuperview(); dialog.removeFromParent() }
                dialog.view.frame = host.view.bounds; dialog.view.layoutIfNeeded()
                let expand: UIButton = try element("castGroupExpand", in: dialog.view)
                let list: UIScrollView = try element("castGroupMembers", in: dialog.view)
                expand.sendActions(for: .touchUpInside)
                expand.sendActions(for: .touchUpInside)
                expand.sendActions(for: .touchUpInside)
                try await wait { list.layer.animationKeys()?.isEmpty != false }
                expand.sendActions(for: .touchUpInside)
                try await wait { list.layer.animationKeys()?.isEmpty != false }
                XCTAssertEqual(list.frame.height, 0)
                expand.sendActions(for: .touchUpInside)
                let slider = try element("castMemberVolume-a", in: dialog.view)
                slider.accessibilityIncrement(); XCTAssertEqual(slider.accessibilityValue, "35%")
                session.state.members[0].volume = 0.8; session.state.members[1].name = "Changed B"; session.onChange?()
                XCTAssertEqual(slider.accessibilityValue, "80%")
                XCTAssertTrue(clock.jobs.isEmpty)
                slider.accessibilityIncrement(); session.state.members[0].hasVariableVolume = false; session.onChange?()
                XCTAssertEqual(slider.accessibilityValue, "100%")
                clock.advance(1); XCTAssertEqual(slider.accessibilityValue, "100%")
                // Even when less than one slider fits beside the fixed controls,
                // preserve a usable inner viewport and outer-scroll reachability.
                dialog.view.frame.size = CGSize(width: 320, height: 270)
                dialog.additionalSafeAreaInsets = .zero; dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                XCTAssertGreaterThanOrEqual(list.frame.height, 40)
                let outer: UIScrollView = try element("castConnectedContent", in: dialog.view)
                XCTAssertGreaterThan(outer.contentSize.height, outer.bounds.height)
            }
        }
    }
    private final class VolumeTouch: UITouch {
        var point: CGPoint = .zero
        override func location(in view: UIView?) -> CGPoint { point }
    }
    func testVolumePressHighlightEndsOnCancellationAndDisableWithoutChangingVolume() async throws {
        try await fixture { runtime, session, _, _, _, _ in
            session.connect()
            try await withViewTestWindow { host, _ in
                let dialog = CastConnectedController(runtime: runtime, identity: session.identity)
                host.addChild(dialog); host.view.addSubview(dialog.view); dialog.didMove(toParent: host)
                defer { dialog.willMove(toParent: nil); dialog.view.removeFromSuperview(); dialog.removeFromParent() }
                dialog.view.frame = host.view.bounds; dialog.view.layoutIfNeeded()
                let control: UIControl = try element("castReceiverVolume", in: dialog.view)
                let touch = VolumeTouch()
                @MainActor func x() -> CGFloat { 16 + (control.bounds.width - 32) * 0.4 }
                touch.point = CGPoint(x: x(), y: control.bounds.midY)
                XCTAssertTrue(control.beginTracking(touch, with: nil)); XCTAssertTrue(control.isHighlighted)
                control.bounds.size.width -= 100; control.setNeedsLayout(); control.layoutIfNeeded()
                XCTAssertTrue(control.isHighlighted); XCTAssertEqual(control.accessibilityValue, "40%")
                control.cancelTracking(with: nil); XCTAssertFalse(control.isHighlighted)
                touch.point.x = x(); XCTAssertTrue(control.beginTracking(touch, with: nil)); XCTAssertTrue(control.isHighlighted)
                control.isEnabled = false; XCTAssertFalse(control.isHighlighted)
                XCTAssertEqual(control.accessibilityValue, "40%")
                XCTAssertTrue(session.volumes.allSatisfy { abs($0 - 0.4) < 0.001 })
            }
        }
    }
    /// The Cast SDK starts at the first Cast button tap, or at launch only when a Cast
    /// session was active last time; the button, chooser and casting behave the same.
    func testCastStartsOnFirstUseOrToResumeTheLastSession() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("cast-lazy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let local = Local(); local.automaticReady = true
        let routes = RoutedPlaybackEngine(local: local)
        let player = PlaybackCoordinator(store: store, engine: routes)
        let media = CastMediaAccessOwner(store: store, authentication: FeedAuthentication(store: store),
            network: ProxyNetworkEnvironment(configuration: .init()), userAgent: "AntennaPod/test")
        let session = Session(), memory = CastSessionMemory(wasActive: false)
        let lazy = CastApplicationRuntime(session: session, player: player, routes: routes, media: media, memory: memory)
        var seen: [CastConnectionState] = []
        let observation = lazy.observe({ seen.append($0) }, problem: { _ in })
        lazy.start()
        try await wait { lazy.sessionReady }
        XCTAssertEqual(session.starts, 0, "Nothing starts the SDK at launch without an earlier session")
        XCTAssertEqual(seen.last?.phase, .disconnected, "The Cast button is shown before the SDK starts")
        _ = lazy.makeChooser()
        try await wait { session.starts == 1 }
        session.connect()
        try await wait { lazy.state.phase == .connected }
        XCTAssertTrue(memory.wasActive)
        observation.cancel()
        // The next launch resumes the session the person was casting to.
        let next = Session()
        let resumed = CastApplicationRuntime(session: next, player: player, routes: routes, media: media, memory: memory)
        resumed.start()
        try await wait { next.starts == 1 }
        _ = session.end(stopReceiver: false)
        try await player.stop(); media.receiverStopped(deviceID: session.identity.deviceID); try await store.close()
    }

    /// Quick volume steps (key repeat, VoiceOver) share one short animation; none keeps running after the
    /// dialog closes (each step used to start a frame clock and orphan the previous one for ever).
    func testQuickVolumeStepsLeaveNoAnimationRunningAfterClose() async throws {
        try await fixture { runtime, session, _, _, _, _ in
            session.connect()
            weak var released: UIControl?
            try await withViewTestWindow { host, _ in
                let dialog = CastConnectedController(runtime: runtime, identity: session.identity)
                host.addChild(dialog); host.view.addSubview(dialog.view); dialog.didMove(toParent: host)
                dialog.view.frame = host.view.bounds; dialog.view.layoutIfNeeded()
                let control: UIControl = try element("castReceiverVolume", in: dialog.view)
                let before = control.accessibilityValue
                for _ in 0..<3 { control.accessibilityIncrement() }
                XCTAssertNotEqual(control.accessibilityValue, before)
                released = control
                dialog.willMove(toParent: nil); dialog.view.removeFromSuperview(); dialog.removeFromParent()
            }
            try await wait { released == nil }
        }
    }
    func testMasterVolumeBeginsOnDownButScrollableMembersWaitForIntent() async throws {
        try await fixture { runtime, session, _, _, _, _ in
            session.connect(); session.state.members = [.init(id: "a", name: "A", volume: 0.3), .init(id: "b", name: "B", volume: 0.4)]; session.onChange?()
            try await withViewTestWindow { host, _ in
                let dialog = CastConnectedController(runtime: runtime, identity: session.identity)
                host.addChild(dialog); host.view.addSubview(dialog.view); dialog.didMove(toParent: host)
                defer { dialog.willMove(toParent: nil); dialog.view.removeFromSuperview(); dialog.removeFromParent() }
                dialog.view.frame = host.view.bounds; dialog.view.layoutIfNeeded()
                let master: UIControl = try element("castReceiverVolume", in: dialog.view)
                let member: UIControl = try element("castMemberVolume-a", in: dialog.view)
                let touch = VolumeTouch(); touch.point = CGPoint(x: 16 + (master.bounds.width - 32) * 0.75, y: master.bounds.midY)
                XCTAssertTrue(master.beginTracking(touch, with: nil))
                XCTAssertTrue(master.isHighlighted); XCTAssertEqual(session.volumes.last ?? -1, 0.75, accuracy: 0.01)
                master.cancelTracking(with: nil); XCTAssertFalse(master.isHighlighted)
                XCTAssertFalse(member.beginTracking(touch, with: nil)); XCTAssertTrue(session.memberVolumes.isEmpty)
                let outer: UIScrollView = try element("castConnectedContent", in: dialog.view)
                outer.isScrollEnabled = true
                let count = session.volumes.count
                XCTAssertFalse(master.beginTracking(touch, with: nil)); XCTAssertEqual(session.volumes.count, count)
                outer.isScrollEnabled = false
                XCTAssertTrue(master.beginTracking(touch, with: nil)); master.isEnabled = false
                XCTAssertFalse(master.isHighlighted); XCTAssertFalse(master.continueTracking(touch, with: nil))
            }
        }
    }
    func testNewGroupMemberAppearsAtTopAndRemovedMemberDisappears() async throws {
        try await fixture { runtime, session, _, _, _, _ in
            session.connect(); session.state.members = [.init(id: "a", name: "A", volume: 0.3), .init(id: "b", name: "B", volume: 0.4)]; session.onChange?()
            try await withViewTestWindow { host, _ in
                let dialog = CastConnectedController(runtime: runtime, identity: session.identity)
                host.addChild(dialog); host.view.addSubview(dialog.view); dialog.didMove(toParent: host)
                defer { dialog.willMove(toParent: nil); dialog.view.removeFromSuperview(); dialog.removeFromParent() }
                dialog.view.frame = host.view.bounds; dialog.view.layoutIfNeeded()
                let expand: UIButton = try element("castGroupExpand", in: dialog.view)
                let list: UIScrollView = try element("castGroupMembers", in: dialog.view)
                expand.sendActions(for: .touchUpInside)
                try await wait { list.layer.animationKeys()?.isEmpty != false }
                session.state.members.insert(.init(id: "c", name: "C", volume: 0.5), at: 0); session.onChange?()
                dialog.view.layoutIfNeeded()
                let row = try element("castMember-c", in: dialog.view)
                let existing = try element("castMember-a", in: dialog.view)
                try await wait { row.alpha == 1 }
                XCTAssertLessThan(row.frame.minY, existing.frame.minY, "A new member is prepended")
                XCTAssertEqual(row.frame.width, list.contentSize.width, accuracy: 1)
                session.state.members.insert(.init(id: "d", name: "D", volume: 0.2), at: 0); session.onChange?()
                let removed = try element("castMember-d", in: dialog.view)
                session.state.members.removeFirst(); session.onChange?()
                try await wait { removed.superview == nil }
            }
        }
    }
    func testSourceProviderStopOnlyReflowsAndRejectsUnavailableDisconnect() async throws {
        XCTAssertFalse(CastConnectionState().canDisconnect)
        try await fixture { runtime, session, _, _, _, _ in
            session.connect()
            session.state.canDisconnect = false; session.onChange?()
            runtime.end(stopReceiver: false); XCTAssertTrue(session.endings.isEmpty)
            try await withViewTestWindow { host, _ in
                let dialog = CastConnectedController(runtime: runtime, identity: session.identity)
                host.addChild(dialog); host.view.addSubview(dialog.view); dialog.didMove(toParent: host)
                defer { dialog.willMove(toParent: nil); dialog.view.removeFromSuperview(); dialog.removeFromParent() }
                let panel = try element("castConnectedPanel", in: dialog.view)
                let scroll: UIScrollView = try element("castConnectedContent", in: dialog.view)
                let disconnect: UIButton = try element("castDisconnect", in: dialog.view)
                let stop: UIButton = try element("castStop", in: dialog.view)
                stop.titleLabel?.traitOverrides.preferredContentSizeCategory = .large
                disconnect.titleLabel?.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
                dialog.view.traitOverrides.preferredContentSizeCategory = .large
                var stopOnlyHeight: CGFloat = 0
                for rtl in [false, true] {
                    dialog.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                    for size in [CGSize(width: 412, height: 800), CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
                        dialog.view.frame.size = size
                        dialog.additionalSafeAreaInsets = .init(top: 11, left: rtl ? 84 : 0, bottom: 21, right: rtl ? 0 : 84)
                        dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                        XCTAssertTrue(disconnect.isHidden); XCTAssertFalse(disconnect.isEnabled)
                        XCTAssertFalse(stop.isHidden); XCTAssertGreaterThanOrEqual(stop.frame.height, 44)
                        XCTAssertTrue(CGRect(origin: .zero, size: scroll.contentSize).insetBy(dx: -1, dy: -1).contains(stop.frame))
                        // Stop sits at the trailing edge of the action row.
                        let stopCenter = stop.frame.midX, contentCenter = scroll.contentSize.width / 2
                        XCTAssertTrue(rtl ? stopCenter < contentCenter : stopCenter > contentCenter)
                        XCTAssertTrue(dialog.view.bounds.inset(by: dialog.view.safeAreaInsets).contains(panel.frame))
                        stopOnlyHeight = scroll.contentSize.height
                    }
                }
                disconnect.sendActions(for: .touchUpInside)
                XCTAssertTrue(session.endings.isEmpty)
                // An unavailable action must not dismiss/unsubscribe the dialog.
                session.state.canDisconnect = true; session.onChange?()
                dialog.view.frame.size = CGSize(width: 230, height: 220)
                dialog.additionalSafeAreaInsets = .zero
                dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                XCTAssertFalse(disconnect.isHidden); XCTAssertTrue(disconnect.isEnabled)
                XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
                scroll.contentOffset.y = scroll.contentSize.height - scroll.bounds.height
                session.state.canDisconnect = false; session.onChange?(); dialog.view.layoutIfNeeded()
                XCTAssertEqual(scroll.contentSize.height, stopOnlyHeight, accuracy: 1, "Removing Disconnect reflows back to the stop-only layout")
                XCTAssertLessThanOrEqual(scroll.contentOffset.y, max(0, scroll.contentSize.height - scroll.bounds.height) + 0.5)
                let stopHeight = stop.frame.height
                stop.titleLabel?.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
                dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                XCTAssertGreaterThan(stop.frame.height, stopHeight, "Larger text grows the Stop button")
                XCTAssertTrue(CGRect(origin: .zero, size: scroll.contentSize).insetBy(dx: -1, dy: -1).contains(stop.frame), "Stop stays inside the scrollable content")
                runtime.end(stopReceiver: true); XCTAssertEqual(session.endings, [true])
            }
        }
    }
    func testSharedDiscoverySurvivesOtherSceneClosingAndRestartsAfterLastOwner() {
        var starts = 0, stops = 0
        let activity = CastDiscoveryActivity(begin: { starts += 1 }, end: { stops += 1 })
        let first = activity.acquire(), second = activity.acquire()
        XCTAssertEqual(starts, 1)
        first.cancel(); first.cancel(); XCTAssertEqual(stops, 0)
        second.cancel(); XCTAssertEqual(stops, 1)
        var third: CastChooserCancellation? = activity.acquire()
        XCTAssertNotNil(third); XCTAssertEqual(starts, 2)
        third = nil; XCTAssertEqual(stops, 2)
    }
    func testConnectedCompositionResizeSafeAreasAndRTLOverflow() async throws {
        try await fixture { runtime, session, _, _, _, _ in
            session.connect()
            try await withViewTestWindow { host, _ in
                let dialog = CastConnectedController(runtime: runtime, identity: session.identity)
                host.addChild(dialog); host.view.addSubview(dialog.view); dialog.didMove(toParent: host)
                defer { dialog.willMove(toParent: nil); dialog.view.removeFromSuperview(); dialog.removeFromParent() }
                dialog.view.traitOverrides.preferredContentSizeCategory = .large
                let panel = try element("castConnectedPanel", in: dialog.view)
                let name: UILabel = try element("castConnectedName", in: dialog.view)
                let close: UIButton = try element("castConnectedClose", in: dialog.view)
                let stop: UIButton = try element("castStop", in: dialog.view)
                let disconnect: UIButton = try element("castDisconnect", in: dialog.view)
                let scroll: UIScrollView = try element("castConnectedContent", in: dialog.view)
                for rtl in [false, true] {
                    dialog.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                    // Source dialog widths: phone minor-axis, tablet major/minor-axis fractions.
                    for (w, h, desired): (CGFloat, CGFloat, CGFloat) in [(412,800,320),(834,1194,583.8),(1194,834,597),(600,900,540),(900,600,540)] {
                        dialog.view.frame.size = CGSize(width: w, height: h)
                        for insets in [UIEdgeInsets(top: 11, left: 84, bottom: 21, right: 0), .init(top: 17, left: 0, bottom: 3, right: 84)] {
                            dialog.additionalSafeAreaInsets = insets
                            dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                            let safe = dialog.view.bounds.inset(by: dialog.view.safeAreaInsets)
                            XCTAssertTrue(safe.contains(panel.frame)); XCTAssertEqual(panel.frame.midX, safe.midX, accuracy: 1)
                            XCTAssertEqual(panel.frame.width, min(desired, safe.width - 48), accuracy: 2)
                            // Title leads, close trails; Stop trails the action row beside Disconnect, below the title.
                            XCTAssertTrue(rtl ? name.frame.midX > close.frame.midX : name.frame.midX < close.frame.midX)
                            XCTAssertFalse(name.frame.intersects(close.frame))
                            XCTAssertGreaterThanOrEqual(close.frame.width, 44); XCTAssertGreaterThanOrEqual(close.frame.height, 44)
                            XCTAssertTrue(rtl ? stop.frame.midX < disconnect.frame.midX : stop.frame.midX > disconnect.frame.midX)
                            XCTAssertEqual(disconnect.frame.minY, stop.frame.minY, accuracy: 1)
                            XCTAssertFalse(stop.frame.intersects(disconnect.frame))
                            XCTAssertGreaterThanOrEqual(stop.frame.minY, name.frame.maxY)
                            XCTAssertEqual(name.text, "Living room"); XCTAssertEqual(runtime.state.phase, .connected)
                        }
                    }
                }
                dialog.additionalSafeAreaInsets = .zero
                // Retain logical leading when an already-overflowing RTL viewport narrows.
                for width: CGFloat in [188, 148] {
                    dialog.view.frame.size = CGSize(width: width, height: 300)
                    dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                    XCTAssertGreaterThan(scroll.contentSize.width, scroll.bounds.width)
                    XCTAssertEqual(scroll.contentOffset.x, scroll.contentSize.width - scroll.bounds.width, accuracy: 1)
                }
                dialog.view.semanticContentAttribute = .forceLeftToRight
                dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                XCTAssertEqual(scroll.contentOffset.x, 0, accuracy: 1)
                dialog.view.frame.size = CGSize(width: 340, height: 300)
                dialog.view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
                dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                XCTAssertGreaterThan(name.font.pointSize, 20)
                XCTAssertLessThan(stop.frame.minY, disconnect.frame.minY)
                XCTAssertTrue(scroll.isScrollEnabled && scroll.clipsToBounds)
                scroll.scrollRectToVisible(disconnect.frame, animated: false)
                XCTAssertTrue(scroll.bounds.contains(disconnect.frame))
                dialog.view.frame.size = CGSize(width: 40, height: 40); dialog.view.layoutIfNeeded()
                XCTAssertTrue(panel.isHidden)
                dialog.view.frame.size = CGSize(width: 412, height: 800); dialog.view.layoutIfNeeded()
                XCTAssertFalse(panel.isHidden); XCTAssertTrue(session.endings.isEmpty)
            }
        }
    }
    func testConnectedAccessibilityVolumeReceivesRemoteUpdatesWithoutTouchDelay() async throws {
        try await fixture { runtime, session, _, _, _, _ in
            session.connect()
            let clock = ChooserTestClock()
            let dialog = CastConnectedController(runtime: runtime, identity: session.identity, clock: clock)
            dialog.loadViewIfNeeded()
            let volume: UIControl = try element("castReceiverVolume", in: dialog.view)
            XCTAssertEqual(volume.accessibilityValue, "40%")
            volume.accessibilityIncrement()
            XCTAssertEqual(session.volumes.last ?? 0, 0.45, accuracy: 0.001)
            session.state.volume = 0.8; session.onChange?()
            XCTAssertEqual(volume.accessibilityValue, "80%")
            XCTAssertTrue(clock.jobs.isEmpty)
            session.state.muted = true; session.onChange?(); XCTAssertEqual(volume.accessibilityValue, "0%")
            XCTAssertTrue(dialog.accessibilityPerformEscape()); XCTAssertTrue(session.endings.isEmpty)
        }
    }
    func testTouchDefersDialogChangesButOtherVolumeCallbacksStayLiveAndMasterIsNotReplayed() async throws {
        try await fixture { runtime, session, _, _, _, _ in
            session.connect(); session.state.name = "Whole home"
            session.state.members = [.init(id: "a", name: "Kitchen", volume: 0.3), .init(id: "b", name: "Office", volume: 0.4)]
            session.onChange?()
            let clock = ChooserTestClock()
            try await withViewTestWindow { host, _ in
                let dialog = CastConnectedController(runtime: runtime, identity: session.identity, clock: clock)
                host.addChild(dialog); host.view.addSubview(dialog.view); dialog.didMove(toParent: host)
                defer { dialog.willMove(toParent: nil); dialog.view.removeFromSuperview(); dialog.removeFromParent() }
                dialog.view.frame = host.view.bounds; dialog.view.layoutIfNeeded()
                let volume: UIControl = try element("castReceiverVolume", in: dialog.view)
                let title: UILabel = try element("castConnectedName", in: dialog.view)
                let kitchen: UIControl = try element("castMemberVolume-a", in: dialog.view)
                let touch = VolumeTouch(); touch.point = CGPoint(x: 16 + (volume.bounds.width - 32) * 0.6, y: volume.bounds.midY)
                XCTAssertTrue(volume.beginTracking(touch, with: nil)); XCTAssertEqual(volume.accessibilityValue, "60%")
                session.state.name = "Updated home"; session.state.volume = 0.8
                session.state.members[0].name = "Updated kitchen"; session.state.members[0].volume = 0.7
                session.state.members.append(.init(id: "c", name: "New office", volume: 0.5)); session.onChange?()
                XCTAssertEqual(title.text, "Whole home"); XCTAssertEqual(volume.accessibilityValue, "60%")
                XCTAssertEqual(kitchen.accessibilityValue, "70%")
                XCTAssertEqual(kitchen.accessibilityLabel, "Kitchen, Volume slider")
                let list = try element("castGroupMembers", in: dialog.view)
                XCTAssertEqual(list.subviews.filter { $0.accessibilityIdentifier?.hasPrefix("castMember-") == true }.count, 2)
                volume.endTracking(touch, with: nil)
                clock.advance(0.499); XCTAssertEqual(title.text, "Whole home")
                clock.advance(0.001); dialog.view.layoutIfNeeded()
                XCTAssertEqual(title.text, "Updated home"); XCTAssertEqual(volume.accessibilityValue, "60%")
                XCTAssertEqual(kitchen.accessibilityLabel, "Updated kitchen, Volume slider")
                XCTAssertEqual(list.subviews.filter { $0.accessibilityIdentifier?.hasPrefix("castMember-") == true }.count, 3)
                // Unrelated later metadata must not replay the discarded80% callback.
                session.state.name = "Renamed again"; session.onChange?(); XCTAssertEqual(volume.accessibilityValue, "60%")
                session.state.volume = 0.9; session.onChange?(); XCTAssertEqual(volume.accessibilityValue, "90%")
                volume.accessibilityDecrement(); XCTAssertTrue(clock.jobs.isEmpty)
                session.state.volume = 0.4; session.onChange?(); XCTAssertEqual(volume.accessibilityValue, "40%")
            }
        }
    }
    func testStartingAnotherVolumeTouchReplacesSettlingAndDefersMemberRemoval() async throws {
        try await fixture { runtime, session, _, _, _, _ in
            session.connect(); session.state.members = [.init(id: "a", name: "A", volume: 0.3), .init(id: "b", name: "B", volume: 0.4)]; session.onChange?()
            let clock = ChooserTestClock()
            let dialog = CastConnectedController(runtime: runtime, identity: session.identity, clock: clock); dialog.loadViewIfNeeded()
            let member: UIControl = try element("castMemberVolume-a", in: dialog.view)
            let master: UIControl = try element("castReceiverVolume", in: dialog.view)
            let title: UILabel = try element("castConnectedName", in: dialog.view)
            // Drive the control-event boundary; real touch admission is exercised
            // by the mounted master test and the group application gesture journey.
            member.sendActions(for: .editingDidBegin); member.accessibilityIncrement(); member.sendActions(for: .editingDidEnd)
            XCTAssertEqual(member.accessibilityValue, "35%")
            session.state.members[0].volume = 0.8; session.state.name = "Pending name"; session.onChange?()
            XCTAssertEqual(member.accessibilityValue, "35%")
            clock.advance(0.25); master.sendActions(for: .editingDidBegin)
            XCTAssertTrue(clock.jobs.isEmpty)
            session.state.members[0].volume = 0.75; session.onChange?(); XCTAssertEqual(member.accessibilityValue, "75%")
            session.state.members.removeAll { $0.id == "a" }; session.onChange?()
            clock.advance(1); XCTAssertTrue(member.isDescendant(of: dialog.view)); XCTAssertEqual(title.text, "Living room")
            let requests = session.memberVolumes.count; member.accessibilityIncrement(); XCTAssertEqual(session.memberVolumes.count, requests)
            master.sendActions(for: .editingDidEnd); clock.advance(0.499); XCTAssertTrue(member.isDescendant(of: dialog.view))
            clock.advance(0.001); XCTAssertFalse(member.isDescendant(of: dialog.view)); XCTAssertEqual(title.text, "Pending name")
            master.sendActions(for: .editingDidBegin); master.sendActions(for: .editingDidEnd)
            XCTAssertFalse(clock.jobs.isEmpty); XCTAssertTrue(dialog.accessibilityPerformEscape()); XCTAssertTrue(clock.jobs.isEmpty)
        }
    }
    func testPresentedConnectedActionsCloseDisconnectAndStop() async throws {
        for action in ["castConnectedClose", "castDisconnect", "castStop"] {
            try await fixture { runtime, session, _, _, _, _ in
                session.connect()
                try await withViewTestWindow { host, window in
                    let dialog = CastConnectedController(runtime: runtime, identity: session.identity)
                    host.present(dialog, animated: false)
                    try await wait { dialog.viewIfLoaded?.window === window && !dialog.isBeingPresented }
                    dialog.view.layoutIfNeeded()
                    let button: UIButton = try element(action, in: dialog.view)
                    let frame = button.convert(button.bounds, to: window)
                    XCTAssertTrue(window.bounds.contains(frame))
                    XCTAssertTrue(window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil) === button)
                    if action == "castConnectedClose" {
                        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                        }
                        let attachment = XCTAttachment(image: image)
                        attachment.name = "Connected Cast controls"; attachment.lifetime = .keepAlways; add(attachment)
                    }
                    button.sendActions(for: .touchUpInside)
                    try await wait { host.presentedViewController == nil }
                    XCTAssertEqual(session.endings, action == "castConnectedClose" ? [] : [action == "castStop"])
                    XCTAssertEqual(runtime.state.phase, action == "castConnectedClose" ? .connected : .disconnected)
                }
            }
        }
    }
    func testFixedVolumeDefersLayoutDuringTouchButRejectsRequestsImmediately() async throws {
        try await fixture { runtime, session, _, _, _, _ in
            session.connect()
            let clock = ChooserTestClock()
            try await withViewTestWindow { host, _ in
                let dialog = CastConnectedController(runtime: runtime, identity: session.identity, clock: clock)
                host.addChild(dialog); host.view.addSubview(dialog.view); dialog.didMove(toParent: host)
                defer { dialog.willMove(toParent: nil); dialog.view.removeFromSuperview(); dialog.removeFromParent() }
                dialog.view.frame = host.view.bounds; dialog.view.layoutIfNeeded()
                let panel = try element("castConnectedPanel", in: dialog.view)
                let volume: UIControl = try element("castReceiverVolume", in: dialog.view)
                let stop: UIButton = try element("castStop", in: dialog.view)
                let variableHeight = panel.frame.height, variableActionY = stop.frame.minY
                volume.sendActions(for: .editingDidBegin)
                volume.sendActions(for: .valueChanged) // Control-event boundary; no release yet.
                session.state.hasVariableVolume = false; session.state.volume = 0.8; session.onChange?()
                dialog.view.layoutIfNeeded()
                XCTAssertEqual(panel.frame.height, variableHeight, accuracy: 1, "No reflow under the finger")
                XCTAssertFalse(volume.superview!.isHidden)
                let requestsBeforeRelease = session.volumes.count
                runtime.setVolume(0.9); volume.sendActions(for: .valueChanged)
                XCTAssertEqual(session.volumes.count, requestsBeforeRelease)
                volume.sendActions(for: .editingDidEnd); clock.advance(0.5); dialog.view.layoutIfNeeded()
                XCTAssertLessThan(panel.frame.height, variableHeight, "Fixed volume removes the slider row after release")
                XCTAssertLessThan(stop.frame.minY, variableActionY)
                XCTAssertTrue(volume.superview!.isHidden); XCTAssertFalse(volume.isEnabled)
                let count = session.volumes.count
                runtime.setVolume(0.7); volume.sendActions(for: .valueChanged); volume.sendActions(for: .editingDidEnd)
                XCTAssertEqual(session.volumes.count, count); XCTAssertTrue(clock.jobs.isEmpty)
                session.state.hasVariableVolume = true; session.onChange?(); dialog.view.layoutIfNeeded()
                XCTAssertEqual(volume.accessibilityValue, "80%")
                XCTAssertEqual(panel.frame.height, variableHeight, accuracy: 1); XCTAssertEqual(stop.frame.minY, variableActionY, accuracy: 1)
                volume.accessibilityDecrement(); XCTAssertTrue(clock.jobs.isEmpty)
                session.state.hasVariableVolume = false; session.onChange?()
                XCTAssertTrue(clock.jobs.isEmpty)
            }
        }
    }
    func testCastButtonAnimatesWhileConnectingAndSettlesOnConnectedIcon() async throws {
        try await withViewTestWindow { host, _ in
            let button = UIButton(type: .custom)
            button.frame = CGRect(x: 20, y: 100, width: 48, height: 48)
            host.view.addSubview(button)
            let indicator = CastButtonIndicator(button: button)
            indicator.update(.disconnected); button.layoutIfNeeded()
            let mask = try XCTUnwrap(indicator.layer.mask)
            XCTAssertEqual(indicator.frame.midX, button.bounds.midX, accuracy: 0.5); XCTAssertEqual(indicator.frame.midY, button.bounds.midY, accuracy: 0.5)
            XCTAssertEqual(indicator.frame.width, 24, accuracy: 1)
            XCTAssertTrue(mask.animationKeys()?.isEmpty ?? true, "Disconnected icon is static")
            XCTAssertNotNil(mask.contents, "Disconnected icon is shown")
            // The animations are checked as handed to Core Animation. Waiting for the render server to report
            // them depended on other work in the idle test app (a launch web view, the Cast SDK) producing frames.
            indicator.update(.connecting)
            let connecting = try XCTUnwrap(mask.animation(forKey: "castFrames"))
            XCTAssertEqual(connecting.repeatCount, .infinity, "Connecting animates until the state changes")
            indicator.update(.connecting)
            XCTAssertEqual(mask.animation(forKey: "castFrames")?.beginTime, connecting.beginTime, "Repeated updates do not restart the animation")
            indicator.update(.connected)
            let transition = try XCTUnwrap(mask.animation(forKey: "castFrames"))
            XCTAssertEqual(transition.repeatCount, 1)
            button.isHighlighted = true; button.layoutIfNeeded()
            indicator.traitOverrides.userInterfaceStyle = .dark
            indicator.setNeedsLayout(); indicator.layoutIfNeeded()
            XCTAssertEqual(mask.animation(forKey: "castFrames")?.beginTime, transition.beginTime, "Press/appearance updates do not restart the transition")
            button.isHighlighted = false
            XCTAssertEqual(transition.duration, 31 * 0.042, accuracy: 0.001)
            XCTAssertTrue(transition.isRemovedOnCompletion, "The transition ends on the model's icon")
            XCTAssertNotNil(mask.contents, "Connected icon remains visible after the transition")
            indicator.update(.connected)
            XCTAssertEqual(mask.animation(forKey: "castFrames")?.beginTime, transition.beginTime, "Connected again does not restart")
            indicator.update(.connecting); XCTAssertNotNil(mask.animation(forKey: "castFrames"))
            indicator.update(.disconnected); XCTAssertNil(mask.animation(forKey: "castFrames"))
            let restoredButton = UIButton(type: .custom)
            let existing = CastButtonIndicator(button: restoredButton); existing.update(.connected)
            XCTAssertNil(existing.layer.mask?.animation(forKey: "castFrames"))
            XCTAssertNotNil(existing.layer.mask?.contents)
        }
    }
    func testFocusedVolumeKeyboardDirectionAndImmediateCallbacks() async throws {
        try await fixture { runtime, session, _, _, _, _ in
            session.connect(); session.state.name = "Whole home"
            session.state.members = [.init(id: "a", name: "Kitchen", volume: 0.3), .init(id: "b", name: "Office 1", volume: 0.4, hasVariableVolume: false)]; session.onChange?()
            let clock = ChooserTestClock()
            try await withViewTestWindow { host, _ in
                let dialog = CastConnectedController(runtime: runtime, identity: session.identity, clock: clock)
                host.addChild(dialog); host.view.addSubview(dialog.view); dialog.didMove(toParent: host)
                defer { dialog.willMove(toParent: nil); dialog.view.removeFromSuperview(); dialog.removeFromParent() }
                dialog.view.frame = host.view.bounds; dialog.view.layoutIfNeeded()
                let control: UIControl = try element("castReceiverVolume", in: dialog.view)
                let fixed: UIControl = try element("castMemberVolume-b", in: dialog.view)
                XCTAssertTrue(control.canBecomeFocused); XCTAssertFalse(fixed.canBecomeFocused)
                XCTAssertFalse(fixed.becomeFirstResponder())
                let thumb = try XCTUnwrap(control.layer.sublayers?.last)
                XCTAssertTrue(control.becomeFirstResponder()); XCTAssertTrue(control.isFirstResponder)
                @MainActor func key(_ input: String) throws {
                    let command = try XCTUnwrap(control.keyCommands?.first { $0.input == input })
                    XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
                    XCTAssertTrue(UIApplication.shared.sendAction(try XCTUnwrap(command.action), to: nil, from: command, for: nil))
                }
                try key(UIKeyCommand.inputRightArrow); XCTAssertEqual(control.accessibilityValue, "45%")
                XCTAssertEqual(session.volumes.last ?? 0, 0.45, accuracy: 0.001); XCTAssertTrue(clock.jobs.isEmpty)
                try await wait { abs(thumb.position.x - (16 + (control.bounds.width - 32) * 0.45)) < 1 }
                try key(UIKeyCommand.inputLeftArrow); XCTAssertEqual(control.accessibilityValue, "40%")
                control.semanticContentAttribute = .forceRightToLeft
                try key(UIKeyCommand.inputLeftArrow); XCTAssertEqual(control.accessibilityValue, "45%")
                try key("-"); XCTAssertEqual(control.accessibilityValue, "50%")
                session.state.volume = 1; session.onChange?()
                let count = session.volumes.count; control.accessibilityIncrement(); XCTAssertEqual(session.volumes.count, count)
                session.state.volume = 0.8; session.onChange?(); XCTAssertEqual(control.accessibilityValue, "80%")
                XCTAssertTrue(clock.jobs.isEmpty)
                control.isEnabled = false; XCTAssertFalse(control.isFirstResponder); XCTAssertNil(control.keyCommands)
            }
        }
    }
    func testKeyboardEscapeFromVolumeClosesDialogWithoutEndingSession() async throws {
        try await fixture { runtime, session, _, _, _, _ in
            session.connect()
            let clock = ChooserTestClock()
            try await withViewTestWindow { host, _ in
                let dialog = CastConnectedController(runtime: runtime, identity: session.identity, clock: clock)
                host.present(dialog, animated: false)
                try await wait { dialog.view.window != nil && dialog.isFirstResponder }
                let control: UIControl = try element("castReceiverVolume", in: dialog.view)
                XCTAssertTrue(control.becomeFirstResponder())
                control.sendActions(for: .editingDidBegin); control.sendActions(for: .editingDidEnd)
                XCTAssertFalse(clock.jobs.isEmpty)
                let command = try XCTUnwrap(dialog.keyCommands?.first { $0.input == UIKeyCommand.inputEscape })
                XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
                XCTAssertTrue(dialog.canPerformAction(try XCTUnwrap(command.action), withSender: command))
                XCTAssertTrue(UIApplication.shared.sendAction(try XCTUnwrap(command.action), to: nil, from: command, for: nil))
                try await wait { host.presentedViewController == nil }
                XCTAssertTrue(clock.jobs.isEmpty); XCTAssertTrue(session.endings.isEmpty)
                XCTAssertEqual(runtime.state.phase, .connected)
                XCTAssertFalse(control.isFirstResponder); XCTAssertFalse(dialog.canBecomeFirstResponder)
                XCTAssertNil(dialog.keyCommands)
            }
        }
    }
    func testRouteLossDefersDismissalThroughActiveVolumeAndSettlingWithoutTargetingReplacement() async throws {
        for member in [false, true] {
            for replacement in [false, true] {
                for settling in [false, true] {
                    try await fixture { runtime, session, _, _, _, _ in
                        session.connect(); session.state.members = [.init(id: "a", name: "Kitchen", volume: 0.3), .init(id: "b", name: "Office", volume: 0.4)]; session.onChange?()
                        let clock = ChooserTestClock()
                        try await withViewTestWindow { host, window in
                            let dialog = CastConnectedController(runtime: runtime, identity: session.identity, clock: clock)
                            host.present(dialog, animated: false)
                            try await wait { dialog.view.window === window && !dialog.isBeingPresented }
                            let master: UIControl = try element("castReceiverVolume", in: dialog.view)
                            let child: UIControl = try element("castMemberVolume-a", in: dialog.view)
                            let held = member ? child : master
                            // Control-event boundary, matching the source SeekBar listener;
                            // real gesture admission has separate application coverage.
                            held.sendActions(for: .editingDidBegin)
                            if settling { held.sendActions(for: .editingDidEnd) }
                            if replacement {
                                session.state.identity = .init(deviceID: "other", sessionID: "replacement")
                                session.state.name = "Other room"; session.state.volume = 0.8
                                session.state.members[0].volume = 0.9
                            } else { session.state = .init() }
                            session.onChange?()
                            XCTAssertTrue(host.presentedViewController === dialog)
                            XCTAssertFalse(dialog.isBeingDismissed, "member=\(member), replacement=\(replacement), settling=\(settling)")
                            let title: UILabel = try element("castConnectedName", in: dialog.view)
                            XCTAssertEqual(title.text, "Living room")
                            XCTAssertEqual(master.accessibilityValue, "40%")
                            XCTAssertEqual(child.accessibilityValue, "30%")
                            let masterRequests = session.volumes.count, memberRequests = session.memberVolumes.count
                            master.accessibilityIncrement(); child.accessibilityIncrement()
                            XCTAssertEqual(session.volumes.count, masterRequests)
                            XCTAssertEqual(session.memberVolumes.count, memberRequests)
                            if !settling {
                                clock.advance(1); XCTAssertFalse(dialog.isBeingDismissed)
                                held.sendActions(for: .editingDidEnd)
                            }
                            clock.advance(0.499); XCTAssertFalse(dialog.isBeingDismissed)
                            clock.advance(0.001)
                            try await wait { host.presentedViewController == nil }
                            XCTAssertTrue(clock.jobs.isEmpty); XCTAssertTrue(session.endings.isEmpty)
                            XCTAssertEqual(runtime.state.phase, replacement ? .connected : .disconnected)
                            if replacement {
                                XCTAssertEqual(runtime.state.identity?.sessionID, "replacement")
                                XCTAssertEqual(session.state.volume, 0.8)
                                XCTAssertEqual(session.state.members[0].volume, 0.9)
                            }
                        }
                    }
                }
            }
        }
    }
    func testStopFromDeferredOldDialogPreservesReplacementAndCancelsSettling() async throws {
        for member in [false, true] {
            try await fixture { runtime, session, _, _, _, _ in
                session.connect(); session.state.members = [.init(id: "a", name: "Kitchen", volume: 0.3), .init(id: "b", name: "Office", volume: 0.4)]; session.onChange?()
                let clock = ChooserTestClock()
                try await withViewTestWindow { host, window in
                    let dialog = CastConnectedController(runtime: runtime, identity: session.identity, clock: clock)
                    host.present(dialog, animated: false)
                    try await wait { dialog.view.window === window && !dialog.isBeingPresented }
                    let held: UIControl = try element(member ? "castMemberVolume-a" : "castReceiverVolume", in: dialog.view)
                    held.sendActions(for: .editingDidBegin); held.sendActions(for: .editingDidEnd)
                    session.state.identity = .init(deviceID: "other", sessionID: "replacement"); session.onChange?()
                    XCTAssertFalse(dialog.isBeingDismissed); XCTAssertFalse(clock.jobs.isEmpty)
                    let stop: UIButton = try element("castStop", in: dialog.view)
                    stop.sendActions(for: .touchUpInside)
                    try await wait { host.presentedViewController == nil }
                    XCTAssertTrue(session.endings.isEmpty); XCTAssertTrue(clock.jobs.isEmpty)
                    XCTAssertEqual(runtime.state.phase, .connected)
                    XCTAssertEqual(runtime.state.identity?.sessionID, "replacement")
                }
            }
        }
    }
    func testSDKOptionsAndSessionSelectors() {
        let options = GoogleCastApplicationSession.options()
        XCTAssertTrue(options.disableDiscoveryAutostart); XCTAssertFalse(options.startDiscoveryAfterFirstTapOnCastButton)
        XCTAssertTrue(options.suspendSessionsWhenBackgrounded)
        for name in ["castSession:didReceiveMultizoneStatus:", "castSession:didAddMultizoneDevice:", "castSession:didUpdateMultizoneDevice:", "castSession:didRemoveMultizoneDeviceWithID:", "sessionManager:willStartCastSession:", "sessionManager:castSession:didReceiveDeviceVolume:muted:", "sessionManager:session:didUpdateDevice:"] {
            XCTAssertNotNil(class_getInstanceMethod(GoogleCastApplicationSession.self, NSSelectorFromString(name)), name)
        }
    }
}
