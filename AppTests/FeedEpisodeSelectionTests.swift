import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct FeedEpisodeSelectionTests {
    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let result = view as? T { return result }
        for child in view.subviews { if let result: T = find(id, in: child) { return result } }
        return nil
    }
    private func wait(_ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try await !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(try await predicate())
    }
    @Test func filteredSelectionBeyondSourcePageSurvivesReloadAndMutatesOnlySelectedEpisodes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FeedSelection-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        var parsed = ParsedFeed(format: .rss, title: "Selection")
        parsed.episodes = (1...153).map { ParsedEpisode(identifier: "\($0)", title: "Episode \($0)", publicationDate: Date(timeIntervalSince1970: Double($0)), media: .init(url: "https://example.org/\($0).mp3", size: 100)) }
        let feed = try await store.insert(.init(feed: parsed, source: "https://example.org/feed", responseURL: URL(string: "https://example.org/feed")!, validator: nil, permanentRedirectURL: nil))
        let mapping = Dictionary(uniqueKeysWithValues: feed.episodes.map { ($0.details.identifier!, $0.id) })
        for key in ["152", "153"] { try await store.updateEpisode(id: mapping[key]!) { $0.userState.playState = .played } }
        try await store.setEpisodeFilter(feedID: feed.id, filter: .init(values: ["unplayed"]))
        let network = DownloadNetworkMonitor(startMonitoring: false)
        network.update(.init(connected: false, metered: false, cellular: false))
        let downloads = DownloadCoordinator(store: store, directory: root.appendingPathComponent("media"), network: network)
        let playback = PlaybackCoordinator(store: store, engine: AVPlayerPlaybackEngine(muted: true))
        let controller = LibraryViewController(library: store, startupError: nil, downloads: downloads, playback: playback,
            timeDisplayPreferences: nil, navigationPreferences: nil, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
        do { try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            await controller.openNotification(.feed(feed.id)); controller.view.layoutIfNeeded()
            controller.startFeedSelection(mapping["75"]!)
            controller.changeFeedSelection("select_all_above")
            #expect(controller.feedSelection.ids == Set((75...151).map { mapping[String($0)]! }))
            controller.changeFeedSelection("select_all_below")
            let expected = Set((1...151).map { mapping[String($0)]! })
            #expect(controller.feedSelection.ids == expected)
            await controller.reloadLibrary()?.value
            controller.view.frame.size = CGSize(width: 720, height: 420)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            #expect(controller.feedSelection.ids == expected)
            let count: UILabel = try #require(find("episodeSelectionCount", in: controller.view))
            #expect(count.text == "151/151 selected")
            let content: UIScrollView = try #require(find("libraryContent", in: controller.view))
            let bar: UIView = try #require(find("episodeSelectionActions", in: controller.view))
            #expect(abs(bar.frame.maxY - content.frame.maxY) < 0.5)
            #expect(content.contentSize.height > 153 * 48)
            for insets in [UIEdgeInsets(top: 0, left: 19, bottom: 0, right: 47), .init(top: 0, left: 47, bottom: 0, right: 19)] {
                controller.additionalSafeAreaInsets = insets
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                #expect(controller.feedSelection.ids == expected)
                #expect(abs(bar.frame.minX - content.frame.minX) < 0.5)
                #expect(abs(bar.frame.width - content.frame.width) < 0.5)
                // The list shows Android's page of 150 and adds the rest as its end comes into view:
                // scroll until the very end, as a person keeps scrolling.
                var scrolledHeight: CGFloat = -1
                while scrolledHeight != content.contentSize.height {
                    scrolledHeight = content.contentSize.height
                    content.contentOffset.y = max(0, content.contentSize.height - content.bounds.height)
                    controller.view.layoutIfNeeded()
                }
                let last: UIButton = try #require(find("episode-\(mapping["1"]!)", in: controller.view))
                #expect(last.convert(last.bounds, to: bar.superview).maxY <= bar.frame.minY + 0.5)
            }
            // Back to the newest episode at the top (rows are built as they come near the screen).
            content.contentOffset.y = 0; controller.view.layoutIfNeeded()
            let secondary: UIButton = try #require(find("episode-action-\(mapping["151"]!)", in: controller.view))
            secondary.sendActions(for: .touchUpInside)
            #expect(controller.feedSelection.ids.count == 150)
            let row: UIButton = try #require(find("episode-\(mapping["151"]!)", in: controller.view))
            row.sendActions(for: .touchUpInside)
            #expect(controller.feedSelection.ids == expected)
            controller.changeFeedSelection("select_toggle")
            #expect(controller.feedSelection.active && controller.feedSelection.ids.isEmpty)
            let noItems: UIButton = try #require(find("episodeBulk-addFavorite", in: controller.view))
            noItems.sendActions(for: .touchUpInside)
            #expect(controller.feedSelection.active)
            controller.changeFeedSelection("select_toggle")
            let favorite: UIButton = try #require(find("episodeBulk-addFavorite", in: controller.view))
            favorite.sendActions(for: .touchUpInside)
            try await wait { try await store.feed(id: feed.id)?.episodes.filter(\.userState.isFavorite).count == 151 }
            await controller.reloadLibrary()?.value
            #expect(!controller.feedSelection.active)
            let updated = try #require(try await store.feed(id: feed.id))
            #expect(Set(updated.episodes.filter(\.userState.isFavorite).map(\.id)) == expected)
            controller.startFeedSelection(mapping["75"]!)
            #expect(controller.accessibilityPerformEscape())
            #expect(!controller.feedSelection.active)
            #expect(find("feedInformation", in: controller.view) as UIButton? != nil)
        }
        } catch {
            await downloads.stop(); try? await playback.stop(); try? await store.close()
            throw error
        }
        await downloads.stop(); try await playback.stop(); try await store.close()
    }

    @Test(arguments: [FeedSubscriptionState.subscribed, .archived, .notSubscribed])
    func contextAvailabilityAndLeavingFeedClearSelection(state: FeedSubscriptionState) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FeedContext-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        var parsed = ParsedFeed(format: .rss, title: "Context")
        parsed.episodes = [.init(identifier: "episode", title: "Context episode", media: .init(url: "https://example.org/media", size: 100))]
        let feed = try await store.insert(.init(feed: parsed, source: "https://example.org/feed", responseURL: URL(string: "https://example.org/feed")!, validator: nil, permanentRedirectURL: nil), subscriptionState: state)
        let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: nil, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            await controller.openNotification(.feed(feed.id)); controller.view.layoutIfNeeded()
            let content: UIScrollView = try #require(find("libraryContent", in: controller.view))
            let row = try #require(content.subviews.compactMap { $0 as? EpisodeRowView }.first)
            row.contextMenu?(row, CGPoint(x: 0.4, y: 0.5))
            try await wait { controller.presentedViewController != nil && controller.presentedViewController?.isBeingPresented == false }
            let menu = try #require(controller.presentedViewController)
            let select: UIButton? = find("multiSelect", in: menu.view)
            #expect((select != nil) == (state != .notSubscribed))
            controller.dismiss(animated: false)
            if state != .notSubscribed {
                controller.startFeedSelection(feed.episodes[0].id)
                #expect(controller.feedSelection.active)
                await controller.openNotification(.inbox); controller.view.layoutIfNeeded()
                #expect(!controller.feedSelection.active)
                #expect((find("episodeSelectionActions", in: controller.view) as UIView?)?.isHidden == true)
            }
        }
        try await store.close()
    }
}
