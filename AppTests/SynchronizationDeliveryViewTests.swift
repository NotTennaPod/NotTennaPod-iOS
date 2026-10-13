import UIKit
import UserNotifications
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct SynchronizationDeliveryViewTests {
    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        (view as? T) ?? view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }
    private func controller() -> LibraryViewController {
        LibraryViewController(library: nil, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: nil, speedPreferences: nil,
            mobileNetworkPreferences: nil, usage: nil)
    }
    @Test func sourceTextAndNativeNotificationEnvelopeRetainFullErrorAndApplicationDestination() {
        let body = Appearance.text("gpodnetsync_error_descr") + "Wrong username or password"
        #expect(body == "An error occurred during syncing: Wrong username or password")
        let request = NativeSynchronizationNotifications.request(title: Appearance.text("gpodnetsync_error_title"), body: body)
        #expect(request.identifier == NativeSynchronizationNotifications.errorIdentifier)
        #expect(request.content.title == "gpodder.net sync error" && request.content.body == body)
        #expect(request.content.interruptionLevel == .active && request.content.sound != nil && request.trigger == nil)
        #expect(request.content.userInfo.isEmpty)
        #expect(NativeSynchronizationNotifications.opensApplication(identifier: request.identifier, category: request.content.categoryIdentifier))
        #expect(!NativeSynchronizationNotifications.opensApplication(identifier: "unrelated", category: request.content.categoryIdentifier))
    }
    /// Records what the publisher asks of the notification center, with the system's replace-by-identifier rule.
    private final class RecordingCenter: SynchronizationNotificationCenter {
        var status: UNAuthorizationStatus = .authorized
        var shown: [String: UNNotificationRequest] = [:]
        func authorizationStatus() async -> UNAuthorizationStatus { status }
        func post(_ request: UNNotificationRequest) async throws { shown[request.identifier] = request }
        func removePendingNotificationRequests(withIdentifiers identifiers: [String]) { identifiers.forEach { shown[$0] = nil } }
        func removeDeliveredNotifications(withIdentifiers identifiers: [String]) { identifiers.forEach { shown[$0] = nil } }
    }
    /// Replaces the earlier test that used the real notification center: it needed notification permission,
    /// which a default Simulator does not have and tests may not grant. What is ours is checked here: one
    /// error notification (a newer error replaces it), permission is read from the center, and clearing
    /// removes both error kinds and nothing else.
    @Test func publicationReplacesOneErrorAndClearsBothErrorKindsOnly() async throws {
        let center = RecordingCenter(), publisher = NativeSynchronizationNotifications(center: center)
        #expect(await publisher.isAuthorized())
        center.status = .denied
        #expect(!(await publisher.isAuthorized()))
        let content = UNMutableNotificationContent(); content.title = "Fixture retained notification"
        let otherID = "fixture-unrelated"
        try await center.post(UNNotificationRequest(identifier: otherID, content: content, trigger: nil))
        try await center.post(UNNotificationRequest(identifier: NativeSynchronizationNotifications.authenticationIdentifier, content: content, trigger: nil))
        try await publisher.publishError(title: "Fixture sync error", body: "first")
        try await publisher.publishError(title: "Fixture sync error", body: "second")
        let error = try #require(center.shown[NativeSynchronizationNotifications.errorIdentifier])
        #expect(error.content.title == "Fixture sync error" && error.content.body == "second")
        #expect(center.shown.count == 3)
        await publisher.clearErrors()
        #expect(Set(center.shown.keys) == [otherID])
    }
    @Test func messageMetricsTruncationAndWideWidthFollowSource() throws {
        let snackbar = Snackbar(message: "An error occurred during syncing: Wrong username or password")
        snackbar.place(in: CGRect(x: 31, y: 0, width: 350, height: 600), wide: false)
        snackbar.layoutIfNeeded()
        // 8-pt margins inside the content region, as on Android (within a point).
        #expect(abs(snackbar.frame.minX - 39) <= 1 && abs(snackbar.frame.maxX - 373) <= 1 && abs(snackbar.frame.maxY - 592) <= 1)
        #expect(abs(snackbar.label.frame.minX - 16) <= 1 && snackbar.label.numberOfLines == 2)
        #expect(snackbar.layer.cornerRadius == 4 && snackbar.label.lineBreakMode == .byTruncatingTail)
        #expect(snackbar.bounds.height >= 48)
        snackbar.place(in: CGRect(x: 250, y: 0, width: 800, height: 700), wide: true)
        #expect(snackbar.bounds.width <= 576 && snackbar.bounds.width >= 320 && abs(snackbar.center.x - 650) <= 1)
        #expect(snackbar.label.numberOfLines == 1 && snackbar.accessibilityLabel == snackbar.message)
    }
    @Test func shellInsetsResizeAndReplacementKeepMessageInContentRegion() async throws {
        try await withViewTestWindow { host, _ in
            let controller = controller()
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            controller.view.frame = CGRect(x: 0, y: 0, width: 430, height: 800)
            controller.additionalSafeAreaInsets = .init(top: 0, left: 31, bottom: 0, right: 7)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            #expect(controller.showSnackbar("first", animated: false))
            let first = try #require(find(Snackbar.self, in: controller.view))
            first.pauseTimeout()
            controller.additionalSafeAreaInsets = .init(top: 0, left: 7, bottom: 0, right: 31)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            let inRoot = first.convert(first.bounds, to: controller.view)
            #expect(inRoot.minX >= controller.view.safeAreaLayoutGuide.layoutFrame.minX + 8)
            #expect(inRoot.maxX <= controller.view.safeAreaLayoutGuide.layoutFrame.maxX - 8)
            controller.view.frame.size = CGSize(width: 820, height: 700)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            #expect(find(Snackbar.self, in: controller.view) === first)
            #expect(first.label.numberOfLines == 1 && first.frame.width <= 576)
            #expect(controller.showSnackbar("replacement", animated: false))
            let second = try #require(find(Snackbar.self, in: controller.view))
            second.pauseTimeout()
            #expect(second !== first && first.superview == nil && second.message == "replacement")
            first.dismiss(animated: false)
            #expect(second.superview != nil)
            second.dismiss(animated: false)
            #expect(find(Snackbar.self, in: controller.view) == nil)
        }
    }
    @Test(arguments: [false, true])
    func snackbarTracksCollapsedAndExpandedPlayerAnchors(bottomNavigation: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SyncSnackbar-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try FeedLibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        let source = URL(string: "https://fixture.invalid/feed")!
        let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Fixture", episodes: [
            .init(identifier: "episode", title: "Episode", media: .init(url: "https://fixture.invalid/media", size: 0, durationMilliseconds: 60_000))
        ]), source: source.absoluteString, responseURL: source, validator: nil, permanentRedirectURL: nil))
        _ = try await store.beginPlayback(episodeID: feed.episodes[0].id)
        let playback = PlaybackCoordinator(store: store, engine: AVPlayerPlaybackEngine(muted: true))
        try await playback.restore()
        let preferences = try NavigationPreferenceStore(file: folder.appendingPathComponent("navigation.json"))
        let time = try TimeDisplayPreferenceStore(file: folder.appendingPathComponent("time.json"))
        var value = preferences.value; value.bottomNavigation = bottomNavigation; try preferences.update(value)
        do {
            try await withViewTestWindow { host, _ in
                let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: playback,
                    timeDisplayPreferences: time, navigationPreferences: preferences, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
                host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
                defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
                controller.view.frame = host.view.bounds
                await controller.reloadLibrary()?.value
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                let player = try #require(find(PlayerView.self, in: controller.view))
                #expect(controller.showSnackbar("Fixture sync error", animated: false))
                let snackbar = try #require(find(Snackbar.self, in: controller.view)); snackbar.pauseTimeout()
                #expect(abs(snackbar.frame.maxY - (player.frame.minY - 8)) < 0.1 && snackbar.swipeEnabled)
                player.setExpanded(true, animated: false); controller.view.layoutIfNeeded()
                #expect(abs(snackbar.frame.maxY - (player.frame.maxY - 8)) < 0.1 && !snackbar.swipeEnabled)
                player.setExpanded(false, animated: false); controller.view.layoutIfNeeded()
                #expect(abs(snackbar.frame.maxY - (player.frame.minY - 8)) < 0.1 && snackbar.swipeEnabled)
                snackbar.dismiss(animated: false)
            }
            try await store.close()
        } catch { try? await store.close(); throw error }
    }

    @Test func detachedScreenDeclinesForegroundDelivery() {
        let controller = controller()
        controller.loadViewIfNeeded()
        #expect(!controller.showSnackbar("not visible", animated: false))
    }
}
