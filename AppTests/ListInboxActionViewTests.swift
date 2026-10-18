import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor private final class ListInboxEngine: PlaybackEngine {
    var reading: PlaybackEngineReading?
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    private var generation: UUID?
    private var command: UUID?
    private var position: Int64 = 0
    private var playing = false
    func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
        self.generation = generation; command = generation; position = positionMilliseconds
    }
    func play(commandID: UUID) { command = commandID; playing = true; update() }
    func pause(commandID: UUID) { command = commandID; playing = false; update() }
    func seek(to positionMilliseconds: Int64, commandID: UUID) { command = commandID; position = positionMilliseconds; update() }
    func setSpeed(_ speed: Float, commandID: UUID) throws { command = commandID; update() }
    func unload() { reading = nil; generation = nil; command = nil; playing = false }
    private func update() {
        guard reading != nil, let generation, let command else { return }
        reading = .init(generation: generation, commandID: command,
            sample: .init(positionMilliseconds: Int32(position), durationMilliseconds: 120_000, status: playing ? .playing : .paused))
    }
    func position(_ value: Int32) {
        position = Int64(value); update()
        if let reading { onEvent?(.position(reading)) }
    }
    func ready() {
        guard let generation, let command else { return }
        reading = .init(generation: generation, commandID: command,
            sample: .init(positionMilliseconds: Int32(position), durationMilliseconds: 120_000, status: playing ? .playing : .paused))
        onEvent?(.ready(reading!))
    }
}

@MainActor @Suite(.serialized)
struct ListInboxActionViewTests {
    enum Route: String, CaseIterable { case inbox, all, queue, feed, downloads, search }
    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let result = view as? T { return result }
        return view.subviews.lazy.compactMap { find(id, in: $0) as T? }.first
    }
    private func wait(_ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while try await !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await predicate())
    }
    private func tap(_ id: String, in view: UIView) throws {
        let button: UIControl = try #require(find(id, in: view))
        button.sendActions(for: .touchUpInside)
    }
    private func menu(_ controller: LibraryViewController, id: Int64) async throws -> UIView {
        controller.view.layoutIfNeeded()
        let button: UIButton = try #require(find("episode-\(id)", in: controller.view))
        var ancestor: UIView? = button
        while ancestor != nil && !(ancestor is EpisodeRowView) { ancestor = ancestor?.superview }
        let row = try #require(ancestor as? EpisodeRowView)
        try #require(row.contextMenu != nil)
        row.contextMenu?(row, CGPoint(x: 0.4, y: 0.5))
        try await wait { controller.presentedViewController != nil && controller.presentedViewController?.isBeingPresented == false }
        return try #require(controller.presentedViewController?.view)
    }
    private func row(_ id: Int64, in controller: LibraryViewController) throws -> EpisodeRowView {
        let button: UIButton = try #require(find("episode-\(id)", in: controller.view))
        var parent: UIView? = button
        while parent != nil && !(parent is EpisodeRowView) { parent = parent?.superview }
        return try #require(parent as? EpisodeRowView)
    }
    private actor ActionGate {
        var entered = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    private func silentWave() -> Data {
        // A complete 120-second, 8 kHz mono PCM file without artwork chunks.
        // Artwork inspection must see normal media, not malformed placeholder bytes.
        let sampleRate: UInt32 = 8_000
        let byteCount = sampleRate * 120 * 2
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(Data("RIFF".utf8)); word(UInt32(36) + byteCount)
        data.append(Data("WAVEfmt ".utf8)); word(UInt32(16))
        word(UInt16(1)); word(UInt16(1)); word(sampleRate); word(sampleRate * 2)
        word(UInt16(2)); word(UInt16(16))
        data.append(Data("data".utf8)); word(byteCount)
        data.append(Data(count: Int(byteCount)))
        return data
    }

    private func fixture(route: Route = .feed, local: Bool = false, autoDelete: Bool = false,
                         position: Int32 = 90_000, duration: Int32 = 120_000,
                         loadSnapshot: (@Sendable (FeedLibraryStore) async throws -> FeedLibrarySnapshot)? = nil,
                         onDownloads: ((DownloadCoordinator) -> Void)? = nil,
                         playbackConsumer: Bool = false,
                         _ body: @MainActor (LibraryViewController, FeedLibraryStore, LibraryFeed, PlaybackCoordinator, ListInboxEngine, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ListInbox-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let network = DownloadNetworkMonitor(startMonitoring: false)
        network.update(.init(connected: false, metered: false, cellular: false))
        var preferences = DownloadPreferences(); preferences.autoDelete = autoDelete
        let capturedPreferences = preferences
        let downloads = DownloadCoordinator(store: store, directory: root.appendingPathComponent("media"), network: network, preferences: { capturedPreferences })
        onDownloads?(downloads)
        let engine = ListInboxEngine()
        let selectedPlayback = PlaybackCoordinator(store: store, engine: engine)
        do {
            let bytes = silentWave(), source = URL(string: "https://example.invalid/list-inbox")!
            let inserted = try await store.insert(.init(feed: .init(format: .rss, title: "Inbox actions", episodes: (1...4).map {
                .init(identifier: String($0), title: "Inbox episode \($0)", media: .init(url: "https://example.invalid/\($0).wav", size: Int64(bytes.count), mimeType: "audio/wav", durationMilliseconds: duration))
            }), source: local ? "antennapod_local:inbox" : source.absoluteString, responseURL: source, validator: nil, permanentRedirectURL: nil))
            try await store.updatePreferences(feedID: inserted.id) { $0.autoDelete = .never }
            // Queue insertion itself clears NEW; establish the independent
            // mixed-state fixture only after seeding queue membership.
            _ = try await store.enqueue(inserted.episodes.map(\.id))
            for (index, episode) in inserted.episodes.enumerated() {
                let file = root.appendingPathComponent("episode-\(episode.id).wav")
                try bytes.write(to: file)
                try await store.updateEpisode(id: episode.id) {
                    $0.userState.playState = index < 2 ? .new : (index == 2 ? .played : .unplayed)
                    $0.userState.positionMilliseconds = position; $0.userState.isFavorite = true
                    $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path
                    $0.details.media?.hasEmbeddedPicture = false
                }
            }
            let feed = try #require(try await store.feed(id: inserted.id))
            try await store.selectSynchronizationAccount(UUID())
            let navigation = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
            var value = navigation.value
            switch route {
            case .inbox: value.defaultPage = NavigationDestination.inbox.rawValue
            case .all: value.defaultPage = NavigationDestination.episodes.rawValue
            case .queue: value.defaultPage = NavigationDestination.queue.rawValue
            case .downloads: value.defaultPage = NavigationDestination.downloads.rawValue
            case .feed, .search: value.defaultPage = "remember"; value.lastPage = "\(feed.id)"
            }
            try navigation.update(value)
            let snapshotReader: (@Sendable () async throws -> FeedLibrarySnapshot)?
            if let loadSnapshot {
                snapshotReader = { @Sendable in try await loadSnapshot(store) }
            } else { snapshotReader = nil }
            let controller = LibraryViewController(library: store, startupError: nil, downloads: downloads, playback: selectedPlayback,
                timeDisplayPreferences: playbackConsumer ? try TimeDisplayPreferenceStore(file: root.appendingPathComponent("time-display.json")) : nil, navigationPreferences: navigation, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil,
                loadSnapshot: snapshotReader)
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                controller.view.frame = host.view.bounds
                defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
                if route == .search {
                    try tap("feedSearch", in: controller.view); controller.view.layoutIfNeeded()
                    let field: UITextField = try #require(find("librarySearchQuery", in: controller.view))
                    field.text = "Inbox"; field.sendActions(for: .editingChanged); _ = field.delegate?.textFieldShouldReturn?(field)
                    try await wait { (find("episode-\(feed.episodes[0].id)", in: controller.view) as UIButton?) != nil }
                }
                try await body(controller, store, feed, selectedPlayback, engine, root)
            }
            try await selectedPlayback.stop(); await downloads.stop(); try await store.close()
        } catch { try? await selectedPlayback.stop(); await downloads.stop(); try? await store.close(); throw error }
    }

    @Test(arguments: Route.allCases)
    func contextRoutesPersistWithoutFeedbackResetOrSync(route: Route) async throws {
        try await fixture(route: route) { controller, store, feed, _, _, root in
            let id = feed.episodes[0].id, before = try #require(try await store.episode(id: feed.episodes[0].id))
            let effects = try await store.pendingEffects(), queue = try await store.queue().map(\.id)
            let panel = try await menu(controller, id: id)
            let remove: UIButton = try #require(find("removeInbox", in: panel))
            #expect(remove.currentTitle == "Remove from inbox")
            remove.sendActions(for: .touchUpInside)
            try await wait { try await store.episode(id: id)?.userState.playState == .unplayed }
            var expected = before; expected.userState.playState = .unplayed
            #expect(try await store.episode(id: id) == expected)
            #expect(try await store.pendingEffects() == effects)
            #expect(try await store.synchronizationQueue().isEmpty)
            #expect(try await store.queue().map(\.id) == queue)
            #expect((find("episodeActionSnackbar", in: controller.view) as UIView?) == nil)
            #expect(controller.presentedViewController == nil)
            let reopened = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
            #expect(try await reopened.episode(id: id) == expected); try await reopened.close()
            try await Task.sleep(for: .milliseconds(2200))
            #expect(try await store.episode(id: id) == expected)
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("episode-\(id).wav").path))
        }
    }

    @Test(arguments: ["eligible", "early", "zeroDuration", "localDisabled", "mutationFailure", "deletionFailure", "otherSelected", "removedID"])
    func contextCleanupUsesExistingPolicyAndPreservesErrorsAndOtherSelection(scenario: String) async throws {
        var capturedDownloads: DownloadCoordinator?
        try await fixture(local: scenario == "localDisabled", autoDelete: true,
            position: scenario == "early" ? 89_999 : 90_000, duration: scenario == "zeroDuration" ? 0 : 120_000, onDownloads: { capturedDownloads = $0 }) { controller, store, feed, playback, engine, root in
            let id = feed.episodes[0].id, other = feed.episodes[3].id
            let before = try #require(try await store.episode(id: id)), file = root.appendingPathComponent("episode-\(id).wav")
            let connection = try LibrarySQLite(url: root.appendingPathComponent("library.sqlite"))
            defer { try? connection.execute("DROP TRIGGER IF EXISTS fail_inbox"); try? connection.execute("DROP TRIGGER IF EXISTS fail_cleanup") }
            if scenario == "mutationFailure" {
                try connection.execute("CREATE TRIGGER fail_inbox BEFORE UPDATE ON episodes BEGIN SELECT RAISE(ABORT, 'inbox write failure'); END")
            }
            try tap("removeInbox", in: try await menu(controller, id: id))
            if scenario == "mutationFailure" {
                try await wait { controller.presentedViewController is UIAlertController }
                #expect(try await store.episode(id: id) == before)
                try await Task.sleep(for: .milliseconds(2200))
                #expect(FileManager.default.fileExists(atPath: file.path)); return
            }
            try await wait { try await store.episode(id: id)?.userState.playState == .unplayed }
            #expect(FileManager.default.fileExists(atPath: file.path))
            if scenario == "deletionFailure" {
                try connection.execute("CREATE TRIGGER fail_cleanup BEFORE UPDATE ON episodes BEGIN SELECT RAISE(ABORT, 'cleanup write failure'); END")
            }
            if scenario == "otherSelected" || scenario == "removedID" {
                try await playback.select(episodeID: other); engine.ready()
                try await wait { playback.episode?.id == other && playback.phase == .playing }
                // Leaving the list must not cancel its application-owned cleanup.
                await controller.openNotification(.inbox)
            }
            if scenario == "removedID" {
                // An absent captured identity is stale, not an I/O error. Await
                // the actual callback and drain its events to a known marker.
                let operation = try #require(controller.lastEpisodeActionDeletion)
                let downloads = try #require(capturedDownloads)
                var events = downloads.events().makeAsyncIterator()
                guard case .stateChanged? = await events.next() else { Issue.record("Missing initial state event"); return }
                let otherBefore = try await store.episode(id: other)
                let queueBefore = try await store.queue()
                try connection.execute("DELETE FROM episodes WHERE id = ?", [.integer(id)])
                await operation.value
                try await downloads.start() // Emits state after the completed callback.
                guard case .stateChanged? = await events.next() else { Issue.record("Stale cleanup emitted success/error"); return }
                #expect(!(controller.presentedViewController is UIAlertController))
                #expect(try await store.episode(id: other) == otherBefore)
                #expect(try await store.queue() == queueBefore.filter { $0.id != id })
                #expect(try await store.episode(id: id) == nil)
                #expect(playback.episode?.id == other && playback.phase == .playing)
                #expect(FileManager.default.fileExists(atPath: file.path))
                #expect(try await store.episode(id: other)?.userState.isDownloaded == true)
                return
            }
            if scenario == "eligible" || scenario == "otherSelected" {
                try await wait { !FileManager.default.fileExists(atPath: file.path) }
                let result = try #require(try await store.episode(id: id))
                #expect(result.userState.playState == .unplayed && result.userState.positionMilliseconds == 90_000)
                #expect(!result.userState.isDownloaded && result.userState.localFileURL == nil && result.userState.isFavorite)
                if scenario == "otherSelected" { #expect(playback.episode?.id == other && playback.phase == .playing) }
            } else {
                try await Task.sleep(for: .milliseconds(2300))
                var expected = before; expected.userState.playState = .unplayed
                #expect(try await store.episode(id: id) == expected)
                #expect(FileManager.default.fileExists(atPath: file.path))
                if scenario == "deletionFailure" { try await wait { controller.presentedViewController is UIAlertController } }
            }
        }
    }

    @Test(arguments: [Route.inbox, .all, .feed, .downloads])
    func bulkOnlyChangesNewMembersAndNeverSchedulesCleanup(route: Route) async throws {
        try await fixture(route: route, autoDelete: true) { controller, store, feed, _, _, root in
            let before = try #require(try await store.feed(id: feed.id)), effects = try await store.pendingEffects()
            let ids = before.episodes.map(\.id)
            try tap("multiSelect", in: try await menu(controller, id: ids[0]))
            try await wait { controller.feedSelection.active }
            controller.changeFeedSelection("select_toggle"); controller.view.layoutIfNeeded()
            let bar: UIView = try #require(find("episodeSelectionActions", in: controller.view))
            #expect(!bar.isHidden)
            try tap("episodeBulk-removeInbox", in: bar)
            try await wait { try await store.feed(id: feed.id)?.episodes.contains { $0.userState.playState == .new } == false }
            var expected = before
            for index in expected.episodes.indices where expected.episodes[index].userState.playState == .new { expected.episodes[index].userState.playState = .unplayed }
            #expect(try await store.feed(id: feed.id) == expected)
            #expect(try await store.pendingEffects() == effects)
            #expect(try await store.synchronizationQueue().isEmpty)
            try await wait { (find("episodeActionSnackbar", in: controller.view) as UIView?) != nil }
            let snackbar: UIView = try #require(find("episodeActionSnackbar", in: controller.view))
            #expect(snackbar.accessibilityLabel == "2 episodes removed from inbox.")
            #expect(controller.lastEpisodeActionDeletion == nil)
            #expect(!controller.feedSelection.active)
            try await Task.sleep(for: .milliseconds(2300))
            #expect(try await store.feed(id: feed.id) == expected)
            for id in ids { #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("episode-\(id).wav").path)) }
            let reopened = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
            #expect(try await reopened.feed(id: feed.id) == expected); try await reopened.close()
        }
    }

    @Test func selectedListPreservesActionsAndDataAcrossDeliveredSceneResize() async throws {
        try await fixture(route: .all) { controller, store, feed, _, _, root in
            let before = try #require(try await store.feed(id: feed.id))
            let queue = try await store.queue().map(\.id), effects = try await store.pendingEffects()
            let files = try Dictionary(uniqueKeysWithValues: before.episodes.map {
                ($0.id, try Data(contentsOf: root.appendingPathComponent("episode-\($0.id).wav")))
            })
            let ids = Set(before.episodes.map(\.id))
            try tap("multiSelect", in: try await menu(controller, id: before.episodes[0].id))
            try await wait { controller.feedSelection.active }
            controller.changeFeedSelection("select_toggle")
            let window = try #require(controller.view.window), scene = try #require(window.windowScene)
            let scroll: UIScrollView = try #require(find("libraryContent", in: controller.view))
            // This child follows its real test window; no manual viewport size is supplied.
            let oldMask = controller.view.autoresizingMask
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            defer { controller.view.autoresizingMask = oldMask }
            window.layoutIfNeeded(); controller.view.layoutIfNeeded()
            let originalScene = scene.effectiveGeometry.coordinateSpace.bounds.size
            let originalContent = scroll.bounds.size
            let originalOrientation = scene.effectiveGeometry.interfaceOrientation
            let restore: UIInterfaceOrientationMask
            switch originalOrientation {
            case .portrait: restore = .portrait
            case .portraitUpsideDown: restore = .portraitUpsideDown
            case .landscapeLeft: restore = .landscapeLeft
            case .landscapeRight: restore = .landscapeRight
            default: throw NSError(domain: "InboxResizeSetup", code: 1)
            }
            let target: UIInterfaceOrientationMask = originalOrientation.isPortrait ? .landscapeLeft : .portrait
            var requestError: String?
            var failure: (any Error)?
            do {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { requestError = String(describing: $0) }
                let deadline = ContinuousClock.now + .seconds(6)
                while requestError == nil && scroll.bounds.size == originalContent && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                window.layoutIfNeeded(); controller.view.layoutIfNeeded()
                print("Inbox scene resize: sceneBefore=\(originalScene); sceneAfter=\(scene.effectiveGeometry.coordinateSpace.bounds.size); contentBefore=\(originalContent); contentAfter=\(scroll.bounds.size); window=\(window.bounds); safeArea=\(controller.view.safeAreaInsets); error=\(requestError ?? "none")")
                if !windowingRefusesRotation(requestError) {
                    try #require(requestError == nil, "A valid OS scene resize is required")
                    try #require(scene.effectiveGeometry.coordinateSpace.bounds.size != originalScene)
                    try #require(scroll.bounds.size != originalContent)
                }
                #expect(controller.feedSelection.ids == ids)
                let count: UILabel = try #require(find("episodeSelectionCount", in: controller.view))
                #expect(count.text == "4/4 selected")
                let remove: UIButton = try #require(find("episodeBulk-removeInbox", in: controller.view))
                let actions = try #require(remove.superview as? UIScrollView)
                actions.scrollRectToVisible(remove.frame, animated: false)
                window.layoutIfNeeded()
                func reachable() -> Bool {
                    let center = remove.convert(CGPoint(x: remove.bounds.midX, y: remove.bounds.midY), to: window)
                    let hit = window.hitTest(center, with: nil)
                    return window.bounds.contains(center) && (hit === remove || hit?.isDescendant(of: remove) == true)
                }
                let reachabilityDeadline = ContinuousClock.now + .seconds(6)
                while !reachable(), ContinuousClock.now < reachabilityDeadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                let center = remove.convert(CGPoint(x: remove.bounds.midX, y: remove.bounds.midY), to: window)
                let hit = window.hitTest(center, with: nil)
                print("Inbox resized action: frame=\(remove.convert(remove.bounds, to: window)); scroll=\(actions.convert(actions.bounds, to: window)); hit=\(String(describing: hit)); presented=\(String(describing: controller.presentedViewController)); transition=\(String(describing: controller.transitionCoordinator))")
                #expect(remove.isEnabled && !remove.isHidden)
                #expect(reachable())
                #expect(try await store.feed(id: feed.id) == before)
                #expect(try await store.queue().map(\.id) == queue)
                #expect(try await store.pendingEffects() == effects)
                #expect(try await store.synchronizationQueue().isEmpty)
                for (id, bytes) in files {
                    #expect(try Data(contentsOf: root.appendingPathComponent("episode-\(id).wav")) == bytes)
                }
            } catch { failure = error }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: restore)) { print("Inbox scene restore error: \($0)") }
            try await wait { scene.effectiveGeometry.coordinateSpace.bounds.size == originalScene }
            window.layoutIfNeeded(); controller.view.layoutIfNeeded()
            print("Inbox scene restored: scene=\(scene.effectiveGeometry.coordinateSpace.bounds.size); content=\(scroll.bounds.size)")
            #expect(scroll.bounds.size == originalContent)
            #expect(controller.feedSelection.ids == ids)
            #expect(try await store.feed(id: feed.id) == before)
            if let failure { throw failure }
        }
    }

    @Test(arguments: [0, 1])
    func bulkCountsCurrentNewItemsAndSuppressesOnlyOne(count: Int) async throws {
        try await fixture { controller, store, feed, _, _, _ in
            let ids = feed.episodes.map(\.id)
            controller.startFeedSelection(ids[0]); controller.changeFeedSelection("select_toggle")
            let remove: UIButton = try #require(find("episodeBulk-removeInbox", in: controller.view))
            // Stored state may change after selection rendering. Dispatch rereads it.
            for id in ids.prefix(2 - count) { try await store.removeEpisodeFromInbox(episodeID: id) }
            remove.sendActions(for: .touchUpInside)
            try await wait { !controller.feedSelection.active }
            try await wait { try await store.feed(id: feed.id)?.episodes.filter { $0.userState.playState == .new }.isEmpty == true }
            if count == 0 { try await wait { (find("episodeActionSnackbar", in: controller.view) as UIView?) != nil } }
            else { await controller.reloadLibrary()?.value }
            let snackbar: UIView? = find("episodeActionSnackbar", in: controller.view)
            if count == 0 { #expect(snackbar?.accessibilityLabel == "0 episodes removed from inbox.") }
            else { #expect(snackbar == nil) }
            #expect(try await store.feed(id: feed.id)?.episodes.filter { $0.userState.playState == .new }.isEmpty == true)
        }
    }

    @Test(arguments: [Route.queue, .search])
    func excludedBulkRoutesRetainSingleContextRemoval(route: Route) async throws {
        try await fixture(route: route) { controller, _, feed, _, _, _ in
            let panel = try await menu(controller, id: feed.episodes[0].id)
            #expect((find("removeInbox", in: panel) as UIButton?) != nil)
            try tap("multiSelect", in: panel)
            try await wait { (find("episodeSelectionCount", in: controller.view) as UILabel?) != nil }
            #expect((find("episodeBulk-removeInbox", in: controller.view) as UIButton?) == nil)
        }
    }

    @Test func enabledLocalCleanupUsesRegisteredDocumentAndRefreshesTheList() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ListInboxLocal-\(UUID())")
        let folder = root.appendingPathComponent("Episodes"), file = folder.appendingPathComponent("Episode.wav")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try silentWave().write(to: file)
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let local = LocalFolderCoordinator(store: store, description: "Local", author: "Folder")
        let preferences = try DownloadPreferenceStore(file: root.appendingPathComponent("downloads.json"))
        var value = preferences.value; value.autoDelete = true; value.autoDeleteLocal = true
        try preferences.update(value)
        let network = DownloadNetworkMonitor(startMonitoring: false)
        let downloads = DownloadCoordinator(store: store, directory: root.appendingPathComponent("media"), network: network, preferences: { preferences.value })
        let playback = PlaybackCoordinator(store: store, engine: ListInboxEngine())
        do {
            let feed = try await local.add(try await LocalFolderSelection.prepare(directory: folder), fallbackTitle: "Episodes")
            try await wait { local.refreshingFeedID == nil }
            let episode = try #require(try await store.feed(id: feed.id)?.episodes.first)
            #expect(episode.details.media?.durationMilliseconds == 120_000)
            try await store.updateEpisode(id: episode.id) {
                $0.userState.playState = .new; $0.userState.positionMilliseconds = 90_000
                $0.details.media?.hasEmbeddedPicture = false
            }
            let controller = LibraryViewController(library: store, startupError: nil, downloads: downloads, playback: playback,
                timeDisplayPreferences: nil, navigationPreferences: nil, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil,
                downloadPreferences: preferences)
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                controller.view.frame = host.view.bounds
                defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                await controller.openNotification(.feed(feed.id)); controller.view.layoutIfNeeded()
                try tap("removeInbox", in: try await menu(controller, id: episode.id))
                try await wait { try await store.episode(id: episode.id)?.userState.playState == .unplayed }
                #expect(FileManager.default.fileExists(atPath: file.path))
                try await wait { !FileManager.default.fileExists(atPath: file.path) }
                try await wait { try await store.feed(id: feed.id)?.episodes.isEmpty == true }
                #expect(controller.presentedViewController == nil)
            }
            try await playback.stop(); await downloads.stop(); try await store.close()
        } catch { try? await playback.stop(); await downloads.stop(); try? await store.close(); throw error }
    }
    @Test(arguments: [0, 1, 2, 3, 4, 5])
    func capturedContextUsesRealPositionEventsAndRefreshLifetime(_ scenario: Int) async throws {
        let initial: [Int32] = [90_000, 89_999, 0, 90_000, 90_000, 0]
        let final: [Int32] = [90_000, 89_999, 90_000, 0, 0, 90_000]
        let deletes = [true, false, true, false, true, false]
        try await fixture(route: .all, autoDelete: true, position: initial[scenario], playbackConsumer: true) { controller, store, feed, playback, engine, root in
            let id = feed.episodes[0].id, gate = ActionGate()
            defer { Task { await gate.release() } }
            controller.episodeActionDeletionWait = { await gate.wait() }
            try await playback.select(episodeID: id); engine.ready(); try await playback.awaitPendingOperations()
            // Queue completion does not drain the controller's buffered events.
            // Fence its consumer before the final setup snapshot and capture.
            engine.position(initial[scenario]); try await playback.awaitPendingOperations()
            let setupRevision = playback.positionRevision
            try await wait { setupRevision > 0 && controller.episodeActionPositionRevision == setupRevision }
            // Selection clears NEW. Restore this labelled test precondition before capture.
            try await store.updateEpisode(id: id) { $0.userState.playState = .new; $0.userState.positionMilliseconds = initial[scenario] }
            await controller.reloadLibrary()?.value
            try await wait { try row(id, in: controller).actionModel?.snapshot().episode.userState.playState == .new }
            let captured = try #require(try row(id, in: controller).actionModel)
            let visibleMenu = try await menu(controller, id: id)
            try tap("removeInbox", in: visibleMenu)
            try await wait { await gate.entered }
            #expect(try row(id, in: controller).actionModel === captured)
            #expect(captured.snapshot().episode.userState.playState == .unplayed)
            if scenario >= 4 {
                try await store.updateEpisode(id: id) { $0.userState.positionMilliseconds = final[scenario] }
                await controller.reloadLibrary()?.value
                let replacement = try #require(try row(id, in: controller).actionModel)
                #expect(replacement !== captured)
                #expect(replacement.snapshot().episode.userState.positionMilliseconds == final[scenario])
            } else if scenario >= 2 {
                engine.position(final[scenario]); try await playback.awaitPendingOperations()
                try await wait { captured.snapshot().episode.userState.positionMilliseconds == final[scenario] }
            }
            let operation = try #require(controller.lastEpisodeActionDeletion)
            await gate.release(); await operation.value
            let persisted = try #require(try await store.episode(id: id))
            let file = root.appendingPathComponent("episode-\(id).wav")
            #expect(persisted.userState.isDownloaded == !deletes[scenario])
            #expect(FileManager.default.fileExists(atPath: file.path) == !deletes[scenario])
            #expect(persisted.userState.playState == .unplayed)
            #expect(try await store.queue().contains { $0.id == id })
            #expect(captured.snapshot().episode.userState.positionMilliseconds == (scenario >= 4 ? initial[scenario] : final[scenario]))
        }
    }

    @Test(arguments: Route.allCases)
    func ownCommitUpdatesVisibleRouteAndPreservesOtherEpisodeData(route: Route) async throws {
        try await fixture(route: route) { controller, store, feed, _, _, _ in
            let id = feed.episodes[0].id, gate = ActionGate()
            defer { Task { await gate.release() } }
            controller.episodeActionDeletionWait = { await gate.wait() }
            let before = try #require(try await store.episode(id: id))
            let other = try await store.episode(id: feed.episodes[1].id)
            try tap("removeInbox", in: try await menu(controller, id: id))
            try await wait { await gate.entered }
            #expect(try await store.episode(id: id)?.userState.playState == .unplayed)
            if route == .inbox { #expect((find("episode-\(id)", in: controller.view) as UIButton?) == nil) }
            else {
                let visible = try #require(try row(id, in: controller).actionModel?.snapshot().episode)
                var expected = before; expected.userState.playState = .unplayed
                #expect(visible == expected)
                let button: UIButton = try #require(find("episode-\(id)", in: controller.view))
                #expect(button.accessibilityLabel == before.details.title)
                #expect(try row(id, in: controller).contextMenu != nil)
            }
            #expect(try await store.episode(id: feed.episodes[1].id) == other)
            let operation = try #require(controller.lastEpisodeActionDeletion)
            await gate.release(); await operation.value
        }
    }

    @Test(arguments: [false, true])
    func pendingCommitPreservesRefreshedDataAndFailureCannotSchedule(fails: Bool) async throws {
        try await fixture(route: .all) { controller, store, feed, _, _, root in
            let id = feed.episodes[0].id, commit = ActionGate(), timer = ActionGate()
            defer { Task { await commit.release(); await timer.release() } }
            controller.beforeEpisodeActionCommit = { await commit.wait() }
            controller.episodeActionDeletionWait = { await timer.wait() }
            let old = try #require(try row(id, in: controller).actionModel)
            try tap("removeInbox", in: try await menu(controller, id: id))
            try await wait { await commit.entered }
            try await store.updateEpisode(id: id) { $0.details.title = "Refreshed identity"; $0.userState.positionMilliseconds = 1234 }
            await controller.reloadLibrary()?.value
            #expect(try row(id, in: controller).actionModel?.snapshot().episode.details.title == "Refreshed identity")
            let connection = try LibrarySQLite(url: root.appendingPathComponent("library.sqlite"))
            defer { try? connection.execute("DROP TRIGGER IF EXISTS fail_pending_inbox") }
            if fails { try connection.execute("CREATE TRIGGER fail_pending_inbox BEFORE UPDATE ON episodes BEGIN SELECT RAISE(ABORT, 'pending inbox failure'); END") }
            await commit.release()
            if fails {
                try await wait { controller.presentedViewController is UIAlertController }
                #expect(controller.lastEpisodeActionDeletion == nil)
                #expect(old.snapshot().episode.userState.playState == .new)
                #expect(try await store.episode(id: id)?.userState.playState == .new)
            } else {
                try await wait { await timer.entered }
                #expect(old.snapshot().episode.userState.playState == .unplayed)
                let operation = try #require(controller.lastEpisodeActionDeletion)
                await timer.release(); await operation.value
            }
            let expectedState: EpisodePlayState = fails ? .new : .unplayed
            try await wait { (try? row(id, in: controller).actionModel?.snapshot().episode.userState.playState) == expectedState }
            let persisted = try #require(try await store.episode(id: id))
            #expect(persisted.userState.playState == expectedState)
            #expect(persisted.details.title == "Refreshed identity")
            #expect(persisted.userState.positionMilliseconds == 1234)
            let button: UIButton = try #require(find("episode-\(id)", in: controller.view))
            #expect(button.accessibilityLabel == "Refreshed identity")
            let visible = try #require(try row(id, in: controller).actionModel)
            #expect(visible.snapshot().episode.details.title == "Refreshed identity")
            #expect(visible.snapshot().episode.userState.positionMilliseconds == 1234)
        }
    }

    @Test func searchRedrawAndRefreshKeepResultsActionableWithoutOverwritingNewerData() async throws {
        try await fixture(route: .search) { controller, store, feed, _, _, root in
            let id = feed.episodes[0].id, commit = ActionGate(), timer = ActionGate()
            defer { Task { await commit.release(); await timer.release() } }
            let search: LibrarySearchView = try #require(controller.view.subviews.flatMap { descendants($0) }.compactMap { $0 as? LibrarySearchView }.first)
            let before = try #require(try await store.feed(id: feed.id))
            let queue = try await store.queue(), effects = try await store.pendingEffects()
            @MainActor func expectResults() throws {
                #expect(search.session.result.episodes.map { $0.episode.id } == before.episodes.map(\.id).sorted())
                for episode in before.episodes {
                    let button: UIButton = try #require(find("episode-\(episode.id)", in: controller.view))
                    #expect(button.accessibilityLabel == episode.details.title)
                    #expect(try row(episode.id, in: controller).contextMenu != nil)
                }
            }
            search.rebuildRows(); try expectResults()
            search.session.change(""); try expectResults()
            let revision = search.session.resultRevision
            search.session.change("Inbox ")
            try await wait { search.session.resultRevision > revision }
            try expectResults()
            #expect(try await store.feed(id: feed.id) == before)

            // Hold an actual action across an accepted newer search result.
            // Its completion must update play state without restoring old metadata.
            controller.beforeEpisodeActionCommit = { await commit.wait() }
            controller.episodeActionDeletionWait = { await timer.wait() }
            try tap("removeInbox", in: try await menu(controller, id: id))
            try await wait { await commit.entered }
            try await store.updateEpisode(id: id) {
                $0.details.title = "Inbox refreshed episode"; $0.userState.positionMilliseconds = 1234
            }
            let refreshRevision = search.session.resultRevision
            // The stored change reaches the screen as the app delivers it: the search patches the changed result in place,
            // without searching again.
            await controller.reloadLibrary()?.value
            try await wait { search.session.result.episodes.first { $0.episode.id == id }?.episode.details.title == "Inbox refreshed episode" }
            #expect(search.session.resultRevision == refreshRevision, "no new search")
            let refreshed: UIButton = try #require(find("episode-\(id)", in: controller.view))
            #expect(refreshed.accessibilityLabel == "Inbox refreshed episode")
            await commit.release()
            try await wait { await timer.entered }
            try await wait { search.session.result.episodes.first { $0.episode.id == id }?.episode.userState.playState == .unplayed }
            var expected = before.episodes[0]
            expected.details.title = "Inbox refreshed episode"
            expected.userState.positionMilliseconds = 1234; expected.userState.playState = .unplayed
            #expect(try row(id, in: controller).actionModel?.snapshot().episode == expected)
            let current: UIButton = try #require(find("episode-\(id)", in: controller.view))
            #expect(current.accessibilityLabel == expected.details.title)
            let operation = try #require(controller.lastEpisodeActionDeletion)
            await timer.release(); await operation.value
            #expect(try await store.episode(id: id) == expected)
            for other in before.episodes.dropFirst() {
                #expect(try await store.episode(id: other.id) == other)
            }
            #expect(try await store.queue().map(\.id) == queue.map(\.id))
            #expect(try await store.pendingEffects() == effects)
            #expect(try await store.synchronizationQueue().isEmpty)
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("episode-\(id).wav").path))
            #expect(controller.presentedViewController == nil)
        }
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { descendants($0) } }

    @Test func stalePlaybackGenerationCannotChangeVisibleProgressOrTriggerCleanup() async throws {
        try await fixture(route: .all, autoDelete: true, playbackConsumer: true) { controller, store, feed, playback, engine, root in
            let id = feed.episodes[0].id, other = feed.episodes[3].id, timer = ActionGate()
            defer { Task { await timer.release() } }
            try await playback.select(episodeID: id); engine.ready(); try await playback.awaitPendingOperations()
            engine.position(90_000); try await playback.awaitPendingOperations()
            let stale = try #require(engine.reading) // Eligible position from the old A selection.
            try await playback.select(episodeID: other); engine.ready(); try await playback.awaitPendingOperations()
            try await playback.select(episodeID: id); engine.ready(); try await playback.awaitPendingOperations()
            engine.position(12_345); try await playback.awaitPendingOperations()
            let setupRevision = playback.positionRevision
            try await wait { setupRevision > 0 && controller.episodeActionPositionRevision == setupRevision }
            #expect(stale.generation != engine.reading?.generation)
            // Selection clears NEW; restore this controlled action precondition.
            try await store.updateEpisode(id: id) {
                $0.userState.playState = .new; $0.userState.positionMilliseconds = 12_345
            }
            await controller.reloadLibrary()?.value
            let before = try #require(try await store.episode(id: id))
            let otherBefore = try await store.episode(id: other), queue = try await store.queue().map(\.id)
            let file = root.appendingPathComponent("episode-\(id).wav")
            let bytes = try Data(contentsOf: file)
            controller.episodeActionDeletionWait = { await timer.wait() }
            try tap("removeInbox", in: try await menu(controller, id: id))
            try await wait { await timer.entered }
            let revision = playback.positionRevision
            engine.onEvent?(.position(stale)); try await playback.awaitPendingOperations()
            #expect(playback.positionRevision == revision)
            #expect(try row(id, in: controller).actionModel?.snapshot().episode.userState.positionMilliseconds == 12_345)
            let button: UIButton = try #require(find("episode-\(id)", in: controller.view))
            #expect(button.accessibilityValue?.contains(EpisodeRowPresentation.time(12_345)) == true)
            let operation = try #require(controller.lastEpisodeActionDeletion)
            await timer.release(); await operation.value
            var expected = before; expected.userState.playState = .unplayed
            #expect(try await store.episode(id: id) == expected)
            #expect(try Data(contentsOf: file) == bytes)
            #expect(try await store.episode(id: other) == otherBefore)
            #expect(try await store.queue().map(\.id) == queue)
            #expect(playback.episode?.id == id)
            #expect(controller.presentedViewController == nil)
        }
    }

    private actor SnapshotFailure {
        var fails = false
        func enable() { fails = true }
        func read(_ store: FeedLibraryStore) async throws -> FeedLibrarySnapshot {
            if fails { throw FeedLibraryError.invalidMutation }
            return try await store.snapshot()
        }
    }
    @Test func failedDataReadKeepsVisibleDataAndContextActionAvailable() async throws {
        let failure = SnapshotFailure()
        try await fixture(route: .all, loadSnapshot: { try await failure.read($0) }) { controller, _, feed, _, _, _ in
            let id = feed.episodes[0].id
            let before = try #require(try row(id, in: controller).actionModel?.snapshot().episode)
            await failure.enable(); await controller.reloadLibrary()?.value
            try await wait { controller.presentedViewController is UIAlertController }
            #expect(try row(id, in: controller).actionModel?.snapshot().episode == before)
            let button: UIButton = try #require(find("episode-\(id)", in: controller.view))
            #expect(button.accessibilityLabel == before.details.title)
            controller.dismiss(animated: false)
            try await wait { controller.presentedViewController == nil }
            let panel = try await menu(controller, id: id)
            #expect((find("removeInbox", in: panel) as UIButton?) != nil)
        }
    }

    private actor HeldSnapshot {
        private var armed = false
        let gate = ActionGate()
        func arm() { armed = true }
        func read(_ store: FeedLibraryStore) async throws -> FeedLibrarySnapshot {
            let snapshot = try await store.snapshot()
            if armed { armed = false; await gate.wait() }
            return snapshot
        }
    }

    @Test(arguments: [false, true])
    func concurrentReadOrFailedMutationCannotDiscardCommittedReconciliation(failedSecondWrite: Bool) async throws {
        let held = HeldSnapshot()
        try await fixture(route: .all, loadSnapshot: { try await held.read($0) }) { controller, store, feed, _, _, root in
            let id = feed.episodes[0].id, commit = ActionGate(), timer = ActionGate()
            defer { Task { await commit.release(); await timer.release(); await held.gate.release() } }
            controller.beforeEpisodeActionCommit = { await commit.wait() }
            controller.episodeActionDeletionWait = { await timer.wait() }
            let old = try #require(try row(id, in: controller).actionModel)
            try tap("removeInbox", in: try await menu(controller, id: id))
            try await wait { await commit.entered }
            await controller.reloadLibrary()?.value
            #expect(try row(id, in: controller).actionModel?.snapshot().episode.userState.playState == .new)
            await held.arm(); await commit.release()
            try await wait { await held.gate.entered }
            let reconciliation = try #require(controller.lastEpisodeActionReconciliation)
            if failedSecondWrite {
                let connection = try LibrarySQLite(url: root.appendingPathComponent("library.sqlite"))
                defer { try? connection.execute("DROP TRIGGER IF EXISTS fail_second_inbox"); try? connection.close() }
                try connection.execute("CREATE TRIGGER fail_second_inbox BEFORE UPDATE ON episodes BEGIN SELECT RAISE(ABORT, 'second inbox failure'); END")
                controller.beforeEpisodeActionCommit = nil
                try await wait { controller.presentedViewController == nil }
                // The episode already left the Inbox, so a second Remove from inbox writes nothing; Mark as played still writes.
                try tap("markPlayed", in: try await menu(controller, id: id))
                try await wait { controller.presentedViewController is UIAlertController }
                await held.gate.release(); await reconciliation.value
                let current = try #require(try row(id, in: controller).actionModel)
                #expect(current.snapshot().episode.userState.playState == .unplayed)
                #expect(try await store.episode(id: id)?.userState.playState == .unplayed)
                await timer.release(); await controller.lastEpisodeActionDeletion?.value
                return
            }
            try await store.updateEpisode(id: id) {
                $0.userState.playState = .played; $0.userState.positionMilliseconds = 4321
                $0.details.title = "Newer committed data"
            }
            // A reload requested while the reconciliation's read is still running follows it and shows the newer data.
            let newer = controller.reloadLibrary()
            await held.gate.release(); await reconciliation.value; await newer?.value
            let current = try #require(try row(id, in: controller).actionModel)
            let button: UIButton = try #require(find("episode-\(id)", in: controller.view))
            #expect(button.accessibilityLabel == "Newer committed data")
            #expect(try await store.episode(id: id) == current.snapshot().episode)
            #expect(current.snapshot().episode.userState.playState == .played)
            #expect(current.snapshot().episode.userState.positionMilliseconds == 4321)
            #expect(current.snapshot().episode.details.title == "Newer committed data")
            #expect(old.snapshot().episode.userState.playState == .unplayed)
            await timer.release(); await controller.lastEpisodeActionDeletion?.value
        }
    }

}
