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
@Suite(.serialized, .timeLimit(.minutes(1)))
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
