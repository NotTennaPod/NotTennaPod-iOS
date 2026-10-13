import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct EpisodeSelectionTests {
    private func find<T: UIView>(_ id: String, _ root: UIView, as: T.Type = T.self) -> T? {
        if let value = root as? T, value.accessibilityIdentifier == id { return value }
        return root.subviews.lazy.compactMap { find(id, $0, as: T.self) }.first
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate())
    }
    @Test func selectionSurvivesReloadResizeAndBackBeforeSearchNavigation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Selection", episodes: (1...20).map {
            .init(identifier: String($0), title: "Matching episode \($0)", media: .init(url: "https://example.org/\($0).mp3", size: 10))
        }), source: "https://example.org/feed", responseURL: URL(string: "https://example.org/feed")!, validator: nil, permanentRedirectURL: nil))
        let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: nil, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer { controller.view.endEditing(true); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 700); controller.view.layoutIfNeeded()
            await controller.openNotification(.feed(feed.id)); controller.view.layoutIfNeeded()
            let open: UIButton = try #require(find("feedSearch", controller.view)); open.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
            let query: UITextField = try #require(find("librarySearchQuery", controller.view))
            query.text = "matching"; query.sendActions(for: .editingChanged); _ = query.delegate?.textFieldShouldReturn?(query)
            // All 20 results arrived; rows are built as they come near the screen.
            try await wait { controller.view.allDescendants.compactMap { $0 as? LibrarySearchView }.first?.displayedIDs.count == 20 }
            let search = try #require(controller.view.allDescendants.compactMap { $0 as? LibrarySearchView }.first)
            try await wait { self.find("episode-\(search.displayedIDs[0])", controller.view, as: UIButton.self) != nil }
            let ids = search.displayedIDs; search.startSelection(ids[0]); controller.view.layoutIfNeeded()
            #expect(query.isHidden && !query.isFirstResponder)
            let row: UIButton = try #require(find("episode-\(ids[1])", controller.view)); row.sendActions(for: .touchUpInside)
            #expect(search.selection.ids == Set(ids.prefix(2)))
            let secondary: UIButton = try #require(find("episode-action-\(ids[2])", controller.view)); secondary.sendActions(for: .touchUpInside)
            #expect(search.selection.ids == Set(ids.prefix(3)))
            #expect(find("episodeShownotes", controller.view, as: UIView.self) == nil)
            let count: UILabel = try #require(find("episodeSelectionCount", controller.view)); #expect(count.text == "3/20 selected")
            let result: UIScrollView = try #require(find("searchEpisodeResults", controller.view))
            let end: UIButton = try #require(find("endEpisodeSelection", controller.view))
            for insets in [UIEdgeInsets(top: 0, left: 19, bottom: 0, right: 47), .init(top: 0, left: 47, bottom: 0, right: 19)] {
                controller.additionalSafeAreaInsets = insets; controller.view.frame.size = CGSize(width: 700, height: 450)
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                try await wait { ids.contains { self.find("episode-\($0)", controller.view, as: UIButton.self) != nil } }
                #expect(search.selection.ids == Set(ids.prefix(3))); #expect(query.text == "matching")
                let bar: UIView = try #require(find("episodeSelectionActions", search))
                #expect(bar.frame.maxY <= search.bounds.maxY + 0.5)
                result.contentOffset.y = max(0, result.contentSize.height - result.bounds.height)
                let last: UIButton = try #require(find("episode-\(ids.last!)", search))
                #expect(last.convert(last.bounds, to: search).maxY <= bar.frame.minY + 0.5)
            }
            search.changeSelection("select_toggle"); #expect(search.selection.ids.count == 20)
            search.changeSelection("select_toggle"); #expect(search.selection.active && search.selection.ids.isEmpty)
            #expect(find("episodeBulk-download", search, as: UIButton.self) != nil)
            end.sendActions(for: .touchUpInside)
            #expect(!search.selection.active && !query.isHidden)
            search.startSelection(ids[0]); let back: UIButton = try #require(find("toolbarBack", controller.view))
            back.sendActions(for: .touchUpInside)
            #expect(!search.selection.active); #expect(query.superview != nil)
            back.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
            #expect(find("feedInformation", controller.view, as: UIButton.self) != nil)
        }
        try await store.close()
    }
    @Test func shortSelectionRetainsAnEpisodeViewportAndScrollableActionLabels() async throws {
        var result = LibrarySearchResult()
        let episode = LibraryEpisode(id: 1, details: .init(title: "Episode", media: .init(url: "https://example.org/audio", size: 10)))
        let feed = LibraryFeed(id: 1, source: "https://example.org/feed", metadata: .init(format: .rss, title: "Podcast"), episodes: [episode])
        result.feeds = [feed]; result.episodes = [.init(feedID: 1, episode: episode)]
        let supplied = result, session = LibrarySearchSession(feedID: nil, feedTitle: "", read: { _, _ in supplied })
        let search = LibrarySearchView(session: session)
        search.makeRow = { _, episode in EpisodeRowView(feed: feed, episode: episode, queued: false, queueScreen: false, showRemainingTime: false, activelyPlaying: false, downloadAction: {}, open: {}) }
        search.selectedItems = { _ in [.init(episode: episode, local: false)] }
        try await withViewTestWindow { host, _ in
            host.view.addSubview(search); defer { search.removeFromSuperview() }
            search.frame = CGRect(x: 20, y: 20, width: 320, height: 180)
            session.change("episode"); session.submit()
            try await wait { self.find("episode-1", search, as: UIButton.self) != nil }
            search.startSelection(1); search.layoutIfNeeded()
            for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
                search.traitOverrides.preferredContentSizeCategory = category
                search.setNeedsLayout(); search.layoutIfNeeded()
                let bar: UIView = try #require(find("episodeSelectionActions", search))
                bar.layoutIfNeeded()
                let results: UIScrollView = try #require(find("searchEpisodeResults", search))
                #expect(bar.frame.minY - results.frame.minY >= 48)
                let actions = try #require(bar.allDescendants.compactMap { $0 as? UIScrollView }.first)
                actions.layoutIfNeeded()
                #expect(actions.contentSize.height >= actions.bounds.height)
                actions.contentOffset.y = max(0, actions.contentSize.height - actions.bounds.height)
                let button: UIButton = try #require(find("episodeBulk-download", search))
                let label = try #require(button.subviews.compactMap { $0 as? UILabel }.first)
                #expect(label.convert(label.bounds, to: actions).maxY <= actions.bounds.maxY + 0.5)
                #expect(button.bounds.height >= 48)
                #expect(search.selection.ids == [1])
            }
        }
    }

    @Test func shareChoicesPersistPositionAndExposeCheckboxInReadingOrder() async throws {
        let name = "EpisodeShare-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let episode = LibraryEpisode(id: 1, details: .init(title: "Episode", link: "https://example.org/episode", media: .init(url: "https://example.org/media", size: 10)))
        let feed = LibraryFeed(id: 1, source: "https://example.org/feed", metadata: .init(format: .rss, title: "Podcast"), episodes: [episode])
        try await withViewTestWindow { host, _ in
            let share = EpisodeShareController(feed: feed, episode: episode, defaults: defaults) { _ in }
            host.present(share, animated: false); try await wait { share.view.window != nil }; share.view.layoutIfNeeded()
            let checkbox: UIButton = try #require(find("episodeSharePosition", share.view)); checkbox.sendActions(for: .touchUpInside)
            #expect(defaults.bool(forKey: "shareEpisodeStartAt"))
            #expect(find("episodeShareMediaAddress", share.view, as: UIButton.self) != nil)
            #expect(find("episodeShareFile", share.view, as: UIButton.self) == nil)
            share.additionalSafeAreaInsets = .init(top: 0, left: 25, bottom: 0, right: 50)
            share.view.setNeedsLayout(); share.view.layoutIfNeeded()
            let panel: UIView = try #require(find("episodeShareSheet", share.view))
            #expect(panel.frame.minX >= share.view.safeAreaLayoutGuide.layoutFrame.minX)
            #expect(panel.frame.maxX <= share.view.safeAreaLayoutGuide.layoutFrame.maxX)
            let firstCard: UIButton = try #require(find("episodeShareSocial", share.view))
            #expect(firstCard.accessibilityValue?.contains("Starting from: 00:00:00") == true)
            let parent = try #require(firstCard.superview)
            let order = parent.accessibilityElements?.compactMap { ($0 as? UIView)?.accessibilityIdentifier }
            #expect(order == ["episodeShareSocial", "episodeSharePosition", "episodeShareMediaAddress"])
            share.dismiss(animated: false)
        }
    }
}
private extension UIView {
    var allDescendants: [UIView] { subviews + subviews.flatMap(\.allDescendants) }
}
