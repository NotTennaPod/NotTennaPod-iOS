import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.timeLimit(.minutes(1)))
struct FeedPullRefreshViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let result = view as? T { return result }
        for child in view.subviews { if let result: T = find(id, in: child) { return result } }
        return nil
    }
    private func wait(_ predicate: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        #expect(predicate(), sourceLocation: sourceLocation)
    }
    /// Android's Inbox, Episodes, Favorites, Playback history (EpisodesListFragment:174-176) and Queue
    /// (QueueFragment) refresh every podcast on pull-to-refresh, with the spinner shown while the update runs.
    @Test(arguments: [NavigationDestination.inbox, .episodes, .favorites, .history, .queue])
    func listScreensPullToRefreshEveryPodcastWithSpinner(destination: NavigationDestination) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PullLists-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        _ = try await store.insert(.init(feed: .init(format: .rss, title: "Pull fixture"), source: "https://example.org/feed", responseURL: URL(string: "https://example.org/feed")!, validator: nil, permanentRedirectURL: nil))
        let refresh = ManualFeedRefreshCoordinator(store: store, execute: { _ in try await Task.sleep(for: .seconds(50)) })
        var accepted: [FeedRefreshRequest] = []
        let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: nil, speedPreferences: nil, mobileNetworkPreferences: nil,
            usage: nil, manualRefresh: refresh, refreshNetwork: { .init(connected: true, metered: false, cellular: false) })
        refresh.onChange = { [weak controller] state in
            if case .active(let request) = state { accepted.append(request) }
            controller?.refreshStateChanged(state)
        }
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer {
                controller.dismiss(animated: false); refresh.suspend()
                controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent()
            }
            controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
            await controller.reloadLibrary()?.value
            controller.select(destination); controller.view.layoutIfNeeded()
            let content: UIScrollView = try #require(find("libraryContent", in: controller.view))
            let indicator: UIView = try #require(find("feedRefreshProgress", in: controller.view))
            let startY = content.frame.minY + 40
            for (state, distance) in [(UIGestureRecognizer.State.began, CGFloat(0)), (.changed, 210), (.ended, 210)] {
                controller.handleFeedPull(state: state, translation: CGPoint(x: 0, y: distance), location: CGPoint(x: content.frame.midX, y: startY + distance))
            }
            try await wait { accepted.count == 1 }
            #expect(accepted.first?.feedID == nil, "refreshes every podcast")
            #expect(!indicator.isHidden, "spinner shows while the update runs")
            _ = try await refresh.cancel(requestID: try #require(accepted.first).id).value
            try await wait { indicator.isHidden }
        }
    }

    @Test(arguments: ["short", "reverse", "cancel", "offline", "mobileNo", "mobileEscape", "once", "run", "afterScroll", "header", "resize", "navigate", "running"])
    func pullRoutesThroughAdmissionAndClearsTransientState(scenario: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PullViews-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Pull fixture"), source: "https://example.org/feed", responseURL: URL(string: "https://example.org/feed")!, validator: nil, permanentRedirectURL: nil))
        let refresh = ManualFeedRefreshCoordinator(store: store, execute: { request in
            if scenario == "running" { try await Task.sleep(for: .seconds(50)) }
            _ = try await store.finishManualRefresh(id: request.id)
        })
        var accepted: [FeedRefreshRequest] = []
        let mobile = scenario.hasPrefix("mobile") || scenario == "once"
        let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: nil, speedPreferences: nil, mobileNetworkPreferences: nil,
            usage: nil, manualRefresh: refresh, refreshNetwork: { .init(connected: scenario != "offline", metered: mobile, cellular: mobile) })
        refresh.onChange = { [weak controller] state in
            if case .active(let request) = state { accepted.append(request) }
            controller?.refreshStateChanged(state)
        }
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer {
                controller.dismiss(animated: false); refresh.suspend()
                controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent()
            }
            controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            await controller.openNotification(.feed(feed.id)); controller.view.layoutIfNeeded()
            let content: UIScrollView = try #require(find("libraryContent", in: controller.view))
            let header: UIView = try #require(find("subscribedFeedHeader", in: controller.view))
            let indicator: UIView = try #require(find("feedRefreshProgress", in: controller.view))
            let startY = scenario == "header" ? content.frame.minY + 20 : header.convert(header.bounds, to: content.superview).maxY + 20
            if scenario == "afterScroll" { content.contentOffset.y = 80 }
            @MainActor func gesture(_ state: UIGestureRecognizer.State, _ distance: CGFloat) {
                controller.handleFeedPull(state: state, translation: CGPoint(x: 0, y: distance), location: CGPoint(x: content.frame.midX, y: startY + distance))
            }
            if scenario == "running" { _ = try await refresh.runOnce(feedID: feed.id).value }
            gesture(.began, 0)
            gesture(.changed, scenario == "short" ? 30 : 210)
            if scenario == "resize" {
                controller.view.frame.size = CGSize(width: 720, height: 480)
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                #expect(abs(indicator.center.x - content.frame.midX) < 0.5)
            }
            if scenario == "reverse" { gesture(.changed, 30) }
            gesture(scenario == "cancel" ? .cancelled : .ended, ["short", "reverse"].contains(scenario) ? 30 : 210)
            if scenario == "navigate" {
                let information: UIButton = try #require(find("feedInformation", in: controller.view))
                information.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
            }
            if scenario == "running" {
                #expect(accepted.count == 1 && !indicator.isHidden)
                _ = try await refresh.cancel(requestID: accepted[0].id).value
                try await wait { indicator.isHidden }
                return
            }
            if mobile {
                try await wait { controller.presentedViewController is SourceMessageController && controller.presentedViewController?.isBeingPresented == false }
                let dialog = try #require(controller.presentedViewController)
                #expect(!indicator.isHidden)
                if scenario == "mobileEscape" { #expect(dialog.accessibilityPerformEscape()) }
                else {
                    let button: UIButton = try #require(find(scenario == "once" ? "refreshOnce" : "refreshNo", in: dialog.view))
                    button.sendActions(for: .touchUpInside)
                }
            }
            if ["run", "once", "afterScroll", "resize"].contains(scenario) {
                try await wait { accepted.count == 1 }
                #expect(accepted[0].feedID == feed.id && !accepted[0].nextPage)
            } else if scenario == "offline" {
                try await wait { (self.find("applicationNotice", in: controller.view.window ?? controller.view) as UILabel?)?.text == "No network connection" }
            }
            try await wait { indicator.isHidden }
            if !["run", "once", "afterScroll", "resize"].contains(scenario) { #expect(accepted.isEmpty) }
        }
        try await store.close()
    }
}
