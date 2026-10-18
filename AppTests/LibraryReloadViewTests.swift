import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Deliberately ignores cancellation, as a completed database read can arrive
/// after its caller is superseded. The controller must reject that callback.
private actor SuspendedLibraryReads {
    private var reads: [Int: CheckedContinuation<FeedLibrarySnapshot, any Error>] = [:]
    private(set) var count = 0
    func load() async throws -> FeedLibrarySnapshot {
        let id = count; count += 1
        return try await withCheckedThrowingContinuation { reads[id] = $0 }
    }
    func finish(_ id: Int, _ snapshot: FeedLibrarySnapshot) { reads.removeValue(forKey: id)?.resume(returning: snapshot) }
    func fail(_ id: Int, message: String? = nil) {
        let pending = reads.removeValue(forKey: id)
        if let message { pending?.resume(throwing: ReloadFailure(message: message)) }
        else { pending?.resume(throwing: FeedLibraryError.invalidMutation) }
    }
}

private struct ReloadFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
@Suite(.serialized)
struct LibraryReloadViewTests {
    private func element<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if let value = view as? T, value.accessibilityIdentifier == id { return value }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: type) }.first
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await condition())
    }
    private func snapshot(filtered: Bool = false) -> FeedLibrarySnapshot {
        var feed = LibraryFeed(id: 1, source: "fixture://feed", metadata: ParsedFeed(format: .rss, title: "Feed"),
            episodes: (1...20).map { id in
                LibraryEpisode(id: Int64(id), details: ParsedEpisode(title: "Episode \(id)"))
            })
        feed.episodeFilterValues = filtered ? ["queued"] : []
        return FeedLibrarySnapshot(feeds: [feed], queue: feed.episodes.filter { $0.id.isMultiple(of: 2) })
    }
    private func controller(_ reads: SuspendedLibraryReads, root: URL) throws -> LibraryViewController {
        let preferences = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
        var value = preferences.value; value.defaultPage = "remember"; value.lastPage = "1"
        try preferences.update(value)
        let controller = LibraryViewController(library: nil, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: preferences, speedPreferences: nil,
            mobileNetworkPreferences: nil, usage: nil, loadSnapshot: { try await reads.load() })
        controller.loadViewIfNeeded(); controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        return controller
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryReload-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func requestsDuringAReadMergeIntoOneLaterReadAndTheOlderResultIsNotDrawn() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let reads = SuspendedLibraryReads(), controller = try controller(reads, root: root)
        try await wait { await reads.count == 1 }
        await reads.finish(0, snapshot())
        try await wait { element("episode-1", in: controller.view, as: UIButton.self) != nil }
        let earlier = controller.reloadLibrary()
        try await wait { await reads.count == 2 }
        // A play tap's several change events while one read runs cost one more read, not one each.
        let requests = (0..<3).map { _ in controller.reloadLibrary(preservingEpisodeDetails: true, keepsUnchangedScreen: true) }
        #expect(await reads.count == 2)
        await reads.finish(1, snapshot(filtered: true))
        try await wait { await reads.count == 3 }
        // The result read before the newer requests is not drawn.
        #expect(element("episode-1", in: controller.view, as: UIButton.self) != nil)
        await reads.finish(2, snapshot(filtered: true))
        await earlier?.value
        for request in requests { await request?.value }
        #expect(await reads.count == 3)
        #expect(element("episode-1", in: controller.view, as: UIButton.self) == nil)
        #expect(element("episode-2", in: controller.view, as: UIButton.self) != nil)
        #expect(controller.presentedViewController == nil)
    }

    @Test func anEventReloadThatChangesNothingKeepsTheListButAnActionReloadRedrawsIt() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let reads = SuspendedLibraryReads(), controller = try controller(reads, root: root)
        try await wait { await reads.count == 1 }
        await reads.finish(0, snapshot())
        try await wait { element("episode-1", in: controller.view, as: UIButton.self) != nil }
        let row = try #require(element("episode-1", in: controller.view, as: UIButton.self))
        let unchanged = controller.reloadLibrary(preservingEpisodeDetails: true, keepsUnchangedScreen: true)
        try await wait { await reads.count == 2 }
        await reads.finish(1, snapshot()); await unchanged?.value
        #expect(element("episode-1", in: controller.view, as: UIButton.self) === row)
        let changed = controller.reloadLibrary(preservingEpisodeDetails: true, keepsUnchangedScreen: true)
        try await wait { await reads.count == 3 }
        await reads.finish(2, snapshot(filtered: true)); await changed?.value
        #expect(element("episode-1", in: controller.view, as: UIButton.self) == nil)
        let action = controller.reloadLibrary()
        try await wait { await reads.count == 4 }
        let shown = try #require(element("episode-2", in: controller.view, as: UIButton.self))
        await reads.finish(3, snapshot(filtered: true)); await action?.value
        #expect(element("episode-2", in: controller.view, as: UIButton.self) !== shown)
    }

    @Test func changesInTheBackgroundAreReadOnceWhenTheAppBecomesActive() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let reads = SuspendedLibraryReads(), controller = try controller(reads, root: root)
        try await wait { await reads.count == 1 }
        await reads.finish(0, snapshot())
        try await wait { element("episode-1", in: controller.view, as: UIButton.self) != nil }
        var background = true
        controller.applicationInBackground = { background }
        for _ in 0..<5 { #expect(controller.reloadLibrary(preservingEpisodeDetails: true, keepsUnchangedScreen: true) == nil) }
        #expect(controller.reloadLibrary() == nil)
        #expect(await reads.count == 1)
        background = false
        controller.applicationDidBecomeActive()
        try await wait { await reads.count == 2 }
        await reads.finish(1, snapshot(filtered: true))
        try await wait { element("episode-1", in: controller.view, as: UIButton.self) == nil }
        #expect(element("episode-2", in: controller.view, as: UIButton.self) != nil)
        controller.applicationDidBecomeActive()
        #expect(await reads.count == 2)
    }

    @Test func reloadPreservesCurrentEpisodeNavigationAndItsExistingDetailsView() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let reads = SuspendedLibraryReads(), controller = try controller(reads, root: root)
        try await wait { await reads.count == 1 }
        await reads.finish(0, snapshot())
        try await wait { element("episode-1", in: controller.view, as: UIButton.self) != nil }
        let pending = controller.reloadLibrary(preservingEpisodeDetails: true)
        try await wait { await reads.count == 2 }
        try #require(element("episode-1", in: controller.view, as: UIButton.self)).sendActions(for: .touchUpInside)
        controller.view.layoutIfNeeded()
        let back = try #require(element("toolbarBack", in: controller.view, as: UIButton.self))
        await reads.finish(1, snapshot(filtered: true)); await pending?.value
        #expect(element("toolbarBack", in: controller.view, as: UIButton.self) === back)
        back.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
        #expect(element("episode-1", in: controller.view, as: UIButton.self) == nil)
        #expect(element("episode-2", in: controller.view, as: UIButton.self) != nil)
    }

    @Test func supersededErrorsStayHiddenButCurrentErrorsArePresented() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let reads = SuspendedLibraryReads(), controller = try controller(reads, root: root)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { closeTestWindow(window, restoringKey: previous) }
        try await wait { await reads.count == 1 }
        await reads.finish(0, snapshot())
        try await wait { element("episode-1", in: controller.view, as: UIButton.self) != nil }
        let earlier = controller.reloadLibrary()
        try await wait { await reads.count == 2 }
        let latest = controller.reloadLibrary()
        await reads.fail(1)
        try await wait { await reads.count == 3 }
        await reads.finish(2, snapshot(filtered: true)); await latest?.value; await earlier?.value
        #expect(controller.presentedViewController == nil)
        let failure = controller.reloadLibrary()
        try await wait { await reads.count == 4 }
        await reads.fail(3); await failure?.value
        let alert = try #require(controller.presentedViewController as? UIAlertController)
        #expect(alert.title == Appearance.text("error_label"))
        #expect(element("episode-1", in: controller.view, as: UIButton.self) == nil)
        #expect(element("episode-2", in: controller.view, as: UIButton.self) != nil)
        try await wait { !alert.isBeingPresented }
    }

    @Test(arguments: ["visible", "presenting", "dismissing"])
    func currentErrorSurvivesAnExistingModalAndItsTransitions(phase: String) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let reads = SuspendedLibraryReads(), controller = try controller(reads, root: root)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { closeTestWindow(window, restoringKey: previous) }
        try await wait { await reads.count == 1 }
        await reads.finish(0, snapshot())
        try await wait { element("episode-1", in: controller.view, as: UIButton.self) != nil }
        let pending = controller.reloadLibrary()
        try await wait { await reads.count == 2 }
        let modal = SourceMessageController(message: "Existing dialog")
        controller.present(modal, animated: phase == "presenting")
        if phase == "presenting" {
            try #require(modal.isBeingPresented && modal.transitionCoordinator != nil)
        } else {
            try await wait { modal.view.window != nil && !modal.isBeingPresented }
            if phase == "dismissing" {
                modal.dismiss(animated: true)
                try #require(modal.isBeingDismissed && modal.transitionCoordinator != nil)
            }
        }
        await reads.fail(1); await pending?.value
        func error() -> UIAlertController? {
            (phase == "dismissing" ? controller : modal).presentedViewController as? UIAlertController
        }
        try await wait { error().map { $0.viewIfLoaded?.window != nil && !$0.isBeingPresented } == true }
        let alert = try #require(error())
        #expect(alert.title == Appearance.text("error_label"))
        #expect(alert.message == FeedLibraryError.invalidMutation.localizedDescription)
        if phase != "dismissing" { #expect(controller.presentedViewController === modal) }
        alert.dismiss(animated: false)
        try await wait { (phase == "dismissing" ? controller : modal).presentedViewController == nil }
        #expect(element("episode-1", in: controller.view, as: UIButton.self) != nil)
    }

    @Test func errorsArrivingDuringAnotherErrorPresentationAreAllDelivered() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let reads = SuspendedLibraryReads(), controller = try controller(reads, root: root)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { closeTestWindow(window, restoringKey: previous) }
        try await wait { await reads.count == 1 }
        await reads.finish(0, snapshot())
        try await wait { element("episode-1", in: controller.view, as: UIButton.self) != nil }
        for id in 1...3 {
            let pending = controller.reloadLibrary()
            try await wait { await reads.count == id + 1 }
            await reads.fail(id, message: "Failure \(id)"); await pending?.value
        }
        func alerts() -> [UIAlertController] {
            var result: [UIAlertController] = [], owner: UIViewController = controller
            while let next = owner.presentedViewController {
                if let alert = next as? UIAlertController { result.append(alert) }
                owner = next
            }
            return result
        }
        try await wait { alerts().count == 3 && alerts().allSatisfy { !$0.isBeingPresented } }
        #expect(alerts().map(\.message) == ["Failure 1", "Failure 2", "Failure 3"])
        for alert in alerts().reversed() {
            let presenter = try #require(alert.presentingViewController)
            alert.dismiss(animated: false)
            try await wait { presenter.presentedViewController == nil }
        }
        #expect(controller.presentedViewController == nil)
    }

    @Test func errorBeforeWindowAttachmentAppearsWhenTheOwnerAppears() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let reads = SuspendedLibraryReads(), controller = try controller(reads, root: root)
        try await wait { await reads.count == 1 }
        await reads.finish(0, snapshot())
        try await wait { element("episode-1", in: controller.view, as: UIButton.self) != nil }
        let pending = controller.reloadLibrary()
        try await wait { await reads.count == 2 }
        await reads.fail(1); await pending?.value
        #expect(controller.presentedViewController == nil)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { closeTestWindow(window, restoringKey: previous) }
        try await wait { controller.presentedViewController is UIAlertController }
        let alert = try #require(controller.presentedViewController as? UIAlertController)
        #expect(alert.message == FeedLibraryError.invalidMutation.localizedDescription)
        try await wait { !alert.isBeingPresented }
    }

    @Test func startupErrorIsNotRepeatedWhenReturningFromAnotherScreen() async throws {
        let controller = LibraryViewController(library: nil, startupError: FeedLibraryError.invalidMutation,
            downloads: nil, playback: nil, timeDisplayPreferences: nil, navigationPreferences: nil,
            speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { closeTestWindow(window, restoringKey: previous) }
        try await wait { controller.presentedViewController is UIAlertController }
        let alert = try #require(controller.presentedViewController as? UIAlertController)
        try await wait { !alert.isBeingPresented }
        alert.dismiss(animated: false)
        try await wait { controller.presentedViewController == nil }
        let screen = UIViewController()
        screen.modalPresentationStyle = .fullScreen
        var presented = false, dismissed = false
        controller.present(screen, animated: false) { presented = true }
        try await wait { presented }
        screen.dismiss(animated: false) { dismissed = true }
        try await wait { dismissed }
        #expect(controller.presentedViewController == nil)
    }

}

/// An engine of the test's own: the player's position is whatever the test says it reached.
@MainActor private final class LivePositionEngine: PlaybackEngine {
    var reading: PlaybackEngineReading?
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    private var generation: UUID?, commandID: UUID?
    private var position: Int32 = 0, playing = false
    func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
        self.generation = generation; commandID = generation; position = Int32(positionMilliseconds); reading = nil
    }
    func play(commandID: UUID) { self.commandID = commandID; playing = true; reading?.commandID = commandID; reading?.sample.status = .playing }
    func pause(commandID: UUID) { self.commandID = commandID; playing = false; reading?.commandID = commandID; reading?.sample.status = .paused }
    func seek(to positionMilliseconds: Int64, commandID: UUID) { self.commandID = commandID; position = Int32(positionMilliseconds) }
    func setSpeed(_ speed: Float, commandID: UUID) throws { self.commandID = commandID }
    func unload() { reading = nil; generation = nil; commandID = nil }

    private func value(_ position: Int32) -> PlaybackEngineReading? {
        guard let generation, let commandID else { return nil }
        return PlaybackEngineReading(generation: generation, commandID: commandID,
            sample: .init(positionMilliseconds: position, durationMilliseconds: 600_000, status: playing ? .playing : .paused),
            speed: 1, skipSilence: false)
    }
    func ready() { guard let value = value(position) else { return }; reading = value; onEvent?(.ready(value)) }
    /// Playback moved on to `position`: the coordinator hears it, the store does not yet (its save is every five seconds).
    func moved(to position: Int32) {
        self.position = position
        guard let value = value(position) else { return }
        reading = value; onEvent?(.position(value))
    }
}

/// The live row time: the playing episode's row shows the player's position, not the last save, whenever the row is
/// built again (a reload, a new or a reused action model), in elapsed and in remaining-time mode.
@MainActor @Suite(.serialized)
struct LiveRowTimeViewTests {
    private func element<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if let value = view as? T, value.accessibilityIdentifier == id { return value }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: type) }.first
    }
    private func wait(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await condition(), sourceLocation: sourceLocation)
    }

    @Test(arguments: [false, true], [false, true]) func thePlayingRowShowsTheLiveTimeAfterAReload(remaining: Bool, rightToLeft: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveRowTime-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        do {
            let source = "https://example.invalid/live.xml"
            let feed = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Live", episodes: (1...3).map {
                ParsedEpisode(identifier: "live-\($0)", title: "Live episode \($0)",
                              media: ParsedMedia(url: "https://example.invalid/live-\($0).mp3", size: 0, mimeType: "audio/mpeg", durationMilliseconds: 600_000))
            }), source: source, responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil))
            let episode = try #require(feed.episodes.first).id
            let navigation = try NavigationPreferenceStore(file: directory.appendingPathComponent("navigation.json"))
            var value = navigation.value; value.defaultPage = "remember"; value.lastPage = "\(feed.id)"; try navigation.update(value)
            let time = try TimeDisplayPreferenceStore(file: directory.appendingPathComponent("time.json"))
            try time.update(.init(showRemainingTime: remaining))
            let engine = LivePositionEngine()
            let playback = PlaybackCoordinator(store: store, engine: engine)
            let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: playback,
                timeDisplayPreferences: time, navigationPreferences: navigation, speedPreferences: nil,
                mobileNetworkPreferences: nil, usage: nil)
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                controller.view.frame = host.view.bounds
                if rightToLeft { controller.traitOverrides.layoutDirection = .rightToLeft }
                defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                await controller.reloadLibrary()?.value
                // Playing from 95 s: the store holds 95 s; the player then reaches 100 s before its next save.
                try await store.updateEpisodePositionForTesting(episode, 95_000)
                try await playback.select(episodeID: episode, play: true)
                engine.ready()
                try await wait { playback.phase == .playing }
                engine.moved(to: 100_000)
                try await wait { playback.sample?.positionMilliseconds == 100_000 }
                #expect(try await store.episode(id: episode)?.userState.positionMilliseconds == 95_000, "not saved yet")
                // The screen is read again (a library change): its rows are built from new models of the stored episodes.
                await controller.reloadLibrary()?.value
                controller.view.layoutIfNeeded()
                let row = try #require(element("episode-\(episode)", in: controller.view, as: UIButton.self))
                if rightToLeft { #expect(row.effectiveUserInterfaceLayoutDirection == .rightToLeft) }
                // The row stays inside the screen, whichever way it reads.
                let frame = row.convert(row.bounds, to: controller.view)
                #expect(frame.minX >= -0.5 && frame.maxX <= controller.view.bounds.maxX + 0.5, "\(frame)")
                let shown = row.accessibilityValue ?? ""
                let live = remaining ? PlayerTimePresentation(position: 100_000, duration: 600_000, showRemainingTime: true)?.length ?? ""
                                     : EpisodeRowPresentation.time(100_000)
                #expect(shown.contains(EpisodeRowPresentation.time(100_000)) && shown.contains(live), "live time: \(shown)")
                #expect(!shown.contains(EpisodeRowPresentation.time(95_000)), "never the stored time: \(shown)")
                // A reused model (an event reload that keeps the presentation) shows it too.
                await controller.reloadLibrary(preservingEpisodeDetails: true, keepsUnchangedScreen: true)?.value
                let again = try #require(element("episode-\(episode)", in: controller.view, as: UIButton.self)).accessibilityValue ?? ""
                #expect(again.contains(EpisodeRowPresentation.time(100_000)), "\(again)")
                try await playback.pause()
            }
            try await store.close()
        } catch { try? await store.close(); throw error }
    }

    /// A position stored while the episode is selected, after the player's samples (a person's action, an applied remote
    /// change), shows in its row: the live time never hides it. The player's next sample is newer again: the row follows
    /// it, and so does a row built again from storage.
    @Test func aPositionStoredAfterThePlayersSamplesShowsUntilItsNextSample() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveRowStored-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        do {
            let source = "https://example.invalid/stored.xml"
            let feed = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Stored", episodes: (1...2).map {
                ParsedEpisode(identifier: "stored-\($0)", title: "Stored episode \($0)",
                              media: ParsedMedia(url: "https://example.invalid/stored-\($0).mp3", size: 0, mimeType: "audio/mpeg", durationMilliseconds: 600_000))
            }), source: source, responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil))
            let episode = try #require(feed.episodes.first).id
            let navigation = try NavigationPreferenceStore(file: directory.appendingPathComponent("navigation.json"))
            var value = navigation.value; value.defaultPage = "remember"; value.lastPage = "\(feed.id)"; try navigation.update(value)
            // As the app's screen: with its player, which follows the player's position events.
            let time = try TimeDisplayPreferenceStore(file: directory.appendingPathComponent("time.json"))
            let engine = LivePositionEngine()
            let playback = PlaybackCoordinator(store: store, engine: engine)
            let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: playback,
                timeDisplayPreferences: time, navigationPreferences: navigation, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                controller.view.frame = host.view.bounds
                defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                @MainActor func shown() throws -> String {
                    controller.view.layoutIfNeeded()
                    return try #require(element("episode-\(episode)", in: controller.view, as: UIButton.self)).accessibilityValue ?? ""
                }
                await controller.reloadLibrary()?.value
                try await store.updateEpisodePositionForTesting(episode, 95_000)
                try await playback.select(episodeID: episode, play: true)
                engine.ready()
                try await wait { playback.phase == .playing }
                engine.moved(to: 100_000)
                try await wait { playback.sample?.positionMilliseconds == 100_000 }
                // The screen has the player's position event (its rows follow the player through these, not reloads).
                try await wait { controller.episodeActionPositionRevision == playback.positionRevision }
                await controller.reloadLibrary()?.value
                let live = try shown()
                #expect(live.contains(EpisodeRowPresentation.time(100_000)), "the live time first: \(live)")
                // Stored after the player's last sample: the patched row shows it, not the player's older 100 s.
                try await store.updateEpisode(id: episode) { $0.userState.positionMilliseconds = 30_000 }
                await controller.reloadLibrary()?.value
                let stored = try shown()
                #expect(stored.contains(EpisodeRowPresentation.time(30_000)) && !stored.contains(EpisodeRowPresentation.time(100_000)),
                        "the newer stored position: \(stored)")
                // The player's next sample is newer: the row shows it as it arrives.
                engine.moved(to: 101_000)
                try await wait { playback.sample?.positionMilliseconds == 101_000 }
                try await wait { controller.episodeActionPositionRevision == playback.positionRevision }
                let followed = try shown()
                #expect(followed.contains(EpisodeRowPresentation.time(101_000)), "the player's newer sample: \(followed)")
                // A row built again from storage (the screen opened again, new models of the stored 30 s) follows the
                // player too.
                await controller.reloadLibrary(reopen: true)?.value
                let resumed = try shown()
                #expect(resumed.contains(EpisodeRowPresentation.time(101_000)) && !resumed.contains(EpisodeRowPresentation.time(30_000)),
                        "the rebuilt row: \(resumed)")
                try await playback.pause()
            }
            try await store.close()
        } catch { try? await store.close(); throw error }
    }

    /// The carried-forward row-time cases: the playing episode's search row shows the live time; after the pause the
    /// saved time (now the live one) shows in the list; after a relaunch (a new store, coordinator and screen on the same
    /// library) the row shows that saved time.
    @Test(arguments: [false, true]) func theSearchRowThePausedRowAndARelaunchShowTheRightTime(rightToLeft: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveRowSearch-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        func tap(_ id: String, _ root: UIView) throws {
            let control = try #require(element(id, in: root, as: UIControl.self), "missing \(id)"); control.sendActions(for: .touchUpInside)
            root.layoutIfNeeded()
        }
        func screen(_ store: FeedLibraryStore, _ playback: PlaybackCoordinator, feed: Int64) throws -> LibraryViewController {
            let navigation = try NavigationPreferenceStore(file: directory.appendingPathComponent("navigation.json"))
            var value = navigation.value; value.defaultPage = "remember"; value.lastPage = "\(feed)"; try navigation.update(value)
            let time = try TimeDisplayPreferenceStore(file: directory.appendingPathComponent("time.json"))
            return LibraryViewController(library: store, startupError: nil, downloads: nil, playback: playback,
                timeDisplayPreferences: time, navigationPreferences: navigation, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
        }
        func host(_ controller: LibraryViewController, _ body: () async throws -> Void) async throws {
            try await withViewTestWindow { host, _ in
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                controller.view.frame = host.view.bounds
                if rightToLeft { controller.traitOverrides.layoutDirection = .rightToLeft }
                defer { controller.view.endEditing(true); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                try await body()
            }
        }
        func shown(_ id: Int64, in controller: LibraryViewController) throws -> String {
            controller.view.layoutIfNeeded()
            let row = try #require(element("episode-\(id)", in: controller.view, as: UIButton.self))
            let frame = row.convert(row.bounds, to: controller.view)
            #expect(frame.minX >= -0.5 && frame.maxX <= controller.view.bounds.maxX + 0.5, "inside the screen: \(frame)")
            return row.accessibilityValue ?? ""
        }
        var store = try FeedLibraryStore(url: url)
        let source = "https://example.invalid/search-live.xml"
        let feed = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Live", episodes: (1...3).map {
            ParsedEpisode(identifier: "search-live-\($0)", title: "Searchable live episode \($0)",
                          media: ParsedMedia(url: "https://example.invalid/search-live-\($0).mp3", size: 0, mimeType: "audio/mpeg", durationMilliseconds: 600_000))
        }), source: source, responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil))
        let episode = try #require(feed.episodes.first).id
        do {
            let engine = LivePositionEngine()
            let playback = PlaybackCoordinator(store: store, engine: engine)
            let controller = try screen(store, playback, feed: feed.id)
            try await host(controller) {
                await controller.reloadLibrary()?.value
                try await store.updateEpisodePositionForTesting(episode, 95_000)
                try await playback.select(episodeID: episode, play: true)
                engine.ready()
                try await wait { playback.phase == .playing }
                engine.moved(to: 100_000)
                try await wait { playback.sample?.positionMilliseconds == 100_000 }
                // The search page's row: the live time, never the stored one.
                await controller.openNotification(.feed(feed.id)); controller.view.layoutIfNeeded()
                try tap("feedSearch", controller.view)
                let field = try #require(element("librarySearchQuery", in: controller.view, as: UITextField.self))
                field.text = "Searchable"; field.sendActions(for: .editingChanged)
                field.resignFirstResponder()
                try await wait { self.element("episode-\(episode)", in: controller.view, as: UIButton.self) != nil }
                let searched = try shown(episode, in: controller)
                #expect(searched.contains(EpisodeRowPresentation.time(100_000)) && !searched.contains(EpisodeRowPresentation.time(95_000)),
                        "search row: \(searched)")
                try tap("toolbarBack", controller.view)
                // Paused: the save holds the live time, and the list shows it.
                try await playback.pause()
                try await wait { (try? await store.episode(id: episode)?.userState.positionMilliseconds) == 100_000 }
                await controller.reloadLibrary()?.value
                let paused = try shown(episode, in: controller)
                #expect(paused.contains(EpisodeRowPresentation.time(100_000)), "paused row: \(paused)")
            }
            try await store.close()
            // Relaunch: a new store, coordinator (restored) and screen on the same library.
            store = try FeedLibraryStore(url: url)
            let restored = PlaybackCoordinator(store: store, engine: LivePositionEngine())
            try await restored.restore()
            #expect(restored.episode?.id == episode, "the relaunch restores the paused episode")
            let again = try screen(store, restored, feed: feed.id)
            try await host(again) {
                await again.reloadLibrary()?.value
                let relaunched = try shown(episode, in: again)
                #expect(relaunched.contains(EpisodeRowPresentation.time(100_000)) && !relaunched.contains(EpisodeRowPresentation.time(95_000)),
                        "after a relaunch: \(relaunched)")
            }
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
}

extension FeedLibraryStore {
    /// The stored position of an episode, as a save would leave it.
    func updateEpisodePositionForTesting(_ id: Int64, _ position: Int32) throws {
        guard var episode = try loadEpisode(id) else { return }
        episode.userState.positionMilliseconds = position
        try write(.local) { try saveEpisode(episode, feedID: try feedID(forEpisode: id)) }
    }
}
