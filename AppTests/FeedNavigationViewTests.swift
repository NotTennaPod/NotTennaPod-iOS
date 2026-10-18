import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

private actor NavigationSnapshot {
    var value: FeedLibrarySnapshot
    init(_ value: FeedLibrarySnapshot) { self.value = value }
    func replace(_ value: FeedLibrarySnapshot) { self.value = value }
}

@MainActor
@Suite(.serialized)
struct FeedNavigationViewTests {
    private func element<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let match = view as? T, match.accessibilityIdentifier == id { return match }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: T.self) }.first
    }
    private func fixture(count: Int = 40) -> FeedLibrarySnapshot {
        let feeds = (1...20).map { id in
            LibraryFeed(id: Int64(id), source: "fixture://feed/\(id)",
                metadata: .init(format: .rss, title: "Podcast \(id)"),
                episodes: (1...count).map { index in
                    LibraryEpisode(id: Int64(id * 100 + index), details: .init(
                        title: "Episode \(index) with a title that wraps in a narrow window",
                        description: "Episode notes"))
                })
        }
        return .init(feeds: feeds, queue: [])
    }
    private func run(rootPage: String = "1",
                     _ body: @MainActor (LibraryViewController, NavigationSnapshot, UIScrollView) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FeedNavigation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = try NavigationPreferenceStore(file: directory.appendingPathComponent("navigation.json"))
        var value = preferences.value
        value.defaultPage = "remember"; value.lastPage = rootPage
        try preferences.update(value)
        let snapshot = NavigationSnapshot(fixture())
        let controller = LibraryViewController(library: nil, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: preferences, speedPreferences: nil,
            mobileNetworkPreferences: nil, usage: nil, loadSnapshot: { await snapshot.value })
        // The first app-hosted suite can start before the launch scene activates.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer {
                controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent()
            }
            resize(controller, width: 402)
            await controller.reloadLibrary()?.value
            controller.view.layoutIfNeeded()
            let scroll: UIScrollView = try #require(element("libraryContent", in: controller.view))
            try await body(controller, snapshot, scroll)
        }
    }
    private func resize(_ controller: UIViewController, width: CGFloat) {
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 600)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
    }
    private func tap(_ id: String, _ controller: UIViewController) throws {
        let button: UIControl = try #require(element(id, in: controller.view))
        button.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
    }
    /// Where the list's rows are, top to bottom (rows are built as they come near the screen; on screen they
    /// are there).
    private func rows(_ scroll: UIScrollView) -> [UIView] {
        guard let controller = sequence(first: scroll as UIResponder, next: \.next).compactMap({ $0 as? LibraryViewController }).first,
              let list = controller.episodeList else { return [] }
        for (index, frame) in list.frames.enumerated() where frame.intersects(scroll.bounds) {
            let shown = list.views[list.ids[index]]?.frame
            #expect(shown.map { abs($0.minY - frame.minY) < 0.5 && abs($0.height - frame.height) < 0.5 } == true,
                    "row \(index) on screen is shown where it belongs: \(String(describing: shown)) vs \(frame)")
        }
        return list.frames.map { UIView(frame: $0) }
    }
    private func position(_ scroll: UIScrollView, index: Int, clipped: CGFloat = 13) {
        scroll.setContentOffset(CGPoint(x: 0, y: rows(scroll)[index].frame.minY + clipped), animated: false)
    }
    private func expectPosition(_ scroll: UIScrollView, index: Int, clipped: CGFloat = 13,
                                sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(rows(scroll)[index].frame.minY - scroll.contentOffset.y + clipped) < 0.5,
                sourceLocation: sourceLocation)
    }

    @Test func episodeBackRestoresFeedPositionAndReopeningStartsAtTop() async throws {
        try await run { controller, _, scroll in
            position(scroll, index: 8)
            try tap("episode-109", controller)
            #expect(rows(scroll).isEmpty)
            #expect(scroll.contentOffset.y == 0)
            try tap("toolbarBack", controller)
            expectPosition(scroll, index: 8)
            try tap("episode-110", controller)
            #expect(scroll.contentOffset.y == 0)
            try tap("toolbarBack", controller)
            expectPosition(scroll, index: 8)
        }
    }

    @Test func eachBackStackEntryOwnsItsReadingPosition() async throws {
        try await run(rootPage: NavigationDestination.subscriptions.rawValue) { controller, _, scroll in
            scroll.setContentOffset(CGPoint(x: 0, y: 321), animated: false)
            try tap("subscriptionFeed-8", controller)
            #expect(scroll.contentOffset.y == 0)
            position(scroll, index: 12, clipped: 21)
            try tap("episode-813", controller)
            try tap("toolbarBack", controller)
            expectPosition(scroll, index: 12, clipped: 21)
            try tap("toolbarBack", controller)
            #expect(scroll.contentOffset.y == 321)
            try tap("subscriptionFeed-9", controller)
            #expect(scroll.contentOffset.y == 0)
        }
    }

    @Test func resizeRetainsRowAndTopOffsetWithAsymmetricSafeAreas() async throws {
        try await run { controller, _, scroll in
            position(scroll, index: 8)
            let originalHeight = rows(scroll)[0].frame.height
            for width in [800.0, 320, 600, 402] {
                controller.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 17, bottom: 0, right: 43)
                resize(controller, width: width)
                expectPosition(scroll, index: 8)
                if width == 800 { #expect(rows(scroll)[0].frame.height < originalHeight) }
            }
        }
    }

    @Test func reloadWhileInDetailsRestoresIndexInUpdatedFeedOnBack() async throws {
        try await run { controller, snapshot, scroll in
            position(scroll, index: 8)
            try tap("episode-109", controller)
            var next = fixture()
            var feed = next.feeds[0]
            feed.episodeFilterValues = ["queued"]
            next = .init(feeds: [feed], queue: feed.episodes.filter { $0.id.isMultiple(of: 2) })
            await snapshot.replace(next)
            await controller.reloadLibrary(preservingEpisodeDetails: true)?.value
            resize(controller, width: 800)
            try tap("toolbarBack", controller)
            #expect(rows(scroll).count == 20)
            expectPosition(scroll, index: 8)
            #expect(element("episode-109", in: controller.view, as: UIButton.self) == nil)
        }
    }

    @Test func visibleReloadPreservesIndexAndEmptyOrShortResultsClampSafely() async throws {
        try await run { controller, snapshot, scroll in
            position(scroll, index: 8)
            var feed = fixture().feeds[0]
            feed.episodeFilterValues = ["queued"]
            await snapshot.replace(.init(feeds: [feed], queue: feed.episodes.filter { $0.id.isMultiple(of: 2) }))
            await controller.reloadLibrary()?.value
            expectPosition(scroll, index: 8)
            position(scroll, index: 17)
            await snapshot.replace(fixture(count: 12))
            await controller.reloadLibrary()?.value
            expectPosition(scroll, index: 0, clipped: 0)
            await snapshot.replace(fixture(count: 2))
            await controller.reloadLibrary()?.value
            // AppBar retains its collapsed state independently of the short
            // RecyclerView, whose first adapter row now sits at the top.
            expectPosition(scroll, index: 0, clipped: 0)
            #expect(scroll.contentOffset.y == 156)
            await snapshot.replace(.init(feeds: [], queue: []))
            await controller.reloadLibrary()?.value
            #expect(scroll.contentOffset.y == 0)
            #expect(rows(scroll).isEmpty)
        }
    }

    @Test func selectingRootDiscardsChildHistory() async throws {
        try await run { controller, _, scroll in
            position(scroll, index: 8)
            try tap("episode-109", controller)
            try tap(NavigationDestination.subscriptions.rawValue, controller)
            #expect(element("toolbarBack", in: controller.view, as: UIButton.self) == nil)
            #expect(scroll.contentOffset.y == 0)
            try tap("subscriptionFeed-1", controller)
            #expect(scroll.contentOffset.y == 0)
            try tap("toolbarBack", controller)
            #expect(scroll.contentOffset.y == 0)
            #expect(element("toolbarBack", in: controller.view, as: UIButton.self) == nil)
        }
    }
}
