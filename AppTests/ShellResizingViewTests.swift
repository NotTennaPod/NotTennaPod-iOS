import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Direct UIKit checks on the real shell. Synthetic widths/insets exercise
/// independent edges; they are not claims about a particular Duo pose's metrics.
@MainActor
@Suite(.serialized)
struct ShellResizingViewTests {
    private func element<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let value = view as? T, value.accessibilityIdentifier == id { return value }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: T.self) }.first
    }

    /// The last subscription of the grid (feeds follow the source sort). Tiles are built as they come
    /// near the screen, so it is found once the grid is scrolled near its end, as a person would.
    private func lastSubscription(_ controller: LibraryViewController) -> UIControl? {
        guard let id = controller.subscriptionGrid?.ids.last else { return nil }
        return element("subscriptionFeed-\(id)", in: controller.view)
    }

    private func countElements(_ id: String, in view: UIView) -> Int {
        (view.accessibilityIdentifier == id ? 1 : 0) + view.subviews.reduce(0) { $0 + countElements(id, in: $1) }
    }

    private func run(bottomNavigation: Bool, rtl: Bool, library: FeedLibraryStore? = nil,
                     usage: StreamDownloadUsageStore? = nil, initialPage: String = "1", feeds: [LibraryFeed]? = nil,
                     body: @MainActor (LibraryViewController, UIView) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShellResize-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
        var value = preferences.value
        value.defaultPage = "remember"; value.lastPage = initialPage; value.bottomNavigation = bottomNavigation
        try preferences.update(value)
        let feed = LibraryFeed(id: 1, source: "fixture://feed", metadata: .init(format: .rss, title: "Resize feed"),
            episodes: (1...30).map { LibraryEpisode(id: Int64($0), details: .init(title: "Episode \($0)", description: "Retained notes")) })
        let snapshot: FeedLibrarySnapshot
        if let library { snapshot = try await library.snapshot() }
        else { snapshot = FeedLibrarySnapshot(feeds: feeds ?? [feed], queue: []) }
        let controller = LibraryViewController(library: library, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: preferences, speedPreferences: nil,
            mobileNetworkPreferences: nil, usage: usage, loadSnapshot: { snapshot })
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            await controller.reloadLibrary()?.value
            try await body(controller, host.view)
        }
    }

    private func resize(_ controller: LibraryViewController, width: CGFloat, height: CGFloat,
                        left: CGFloat, right: CGFloat) {
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: left, bottom: 0, right: right)
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
    }

    @Test func asymmetricHorizontalSafeAreasConstrainBothNavigationModesAndDirections() async throws {
        for bottom in [false, true] {
            for rtl in [false, true] {
                try await run(bottomNavigation: bottom, rtl: rtl) { controller, _ in
                    for (width, height) in [(402.0, 874.0), (874, 402), (800, 900), (320, 700)] {
                        for (left, right) in [(0.0, 0.0), (43, 7), (7, 43)] {
                            resize(controller, width: width, height: height, left: left, right: right)
                            let surface: UIView = try #require(element("shellSurface", in: controller.view))
                            let safe = controller.view.safeAreaLayoutGuide.layoutFrame
                            #expect(abs(surface.frame.minX - safe.minX) <= 1)
                            #expect(abs(surface.frame.maxX - safe.maxX) <= 1)
                            #expect(surface.frame.height == controller.view.bounds.height)
                            #expect(surface.clipsToBounds)
                            let toolbar: UIView = try #require(element("mainToolbar", in: controller.view))
                            let toolbarFrame = toolbar.convert(toolbar.bounds, to: controller.view)
                            #expect(toolbarFrame.minX >= safe.minX - 0.01)
                            #expect(toolbarFrame.maxX <= safe.maxX + 0.01)
                            let row: UIButton = try #require(element("episode-1", in: controller.view))
                            #expect(row.convert(row.bounds, to: controller.view).minX >= safe.minX - 0.01)
                            #expect(row.convert(row.bounds, to: controller.view).maxX <= safe.maxX + 0.01)
                            if bottom {
                                let queue: UIView = try #require(element(NavigationDestination.queue.rawValue, in: controller.view))
                                let region = try #require(queue.superview)
                                #expect(abs(region.convert(region.bounds, to: controller.view).maxX - safe.maxX) <= 1)
                            } else {
                                let drawer: NavigationDrawerView = try #require(element("navigationDrawer", in: controller.view))
                                #expect(drawer.superview === surface)
                                #expect(drawer.bounds.width == surface.bounds.width)
                            }
                        }
                    }
                    controller.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 59, bottom: 0, right: 1)
                    controller.view.layoutIfNeeded()
                    let surface: UIView = try #require(element("shellSurface", in: controller.view))
                    let safe = controller.view.safeAreaLayoutGuide.layoutFrame
                    #expect(abs(surface.frame.minX - safe.minX) <= 1)
                    #expect(abs(surface.frame.maxX - safe.maxX) <= 1)
                }
            }
        }
    }

    /// Android's bottom strip (main.xml `bottom_padding`): the bottom navigation ends above a strip in its own colour
    /// that runs to the screen edge, as tall as the bottom inset up to 24 pt, so the home indicator draws in the strip
    /// and never across the navigation labels. Additional insets below and above the cap, on top of the device's own.
    @Test(arguments: [false, true])
    func bottomNavigationEndsAboveAStripInItsOwnColour(rtl: Bool) async throws {
        try await run(bottomNavigation: true, rtl: rtl) { controller, _ in
            for additional in [0.0, 10, 40] {
                controller.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: additional, right: 0)
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                let expected = min(controller.view.safeAreaInsets.bottom, 24) // Android's 24 dp gesture strip
                let strip: UIView = try #require(element("shellBottomStrip", in: controller.view))
                let stripFrame = strip.convert(strip.bounds, to: controller.view)
                #expect(abs(stripFrame.maxY - controller.view.bounds.maxY) <= 0.5, "\(additional): \(stripFrame)")
                #expect(abs(stripFrame.height - expected) <= 0.5, "\(additional): \(stripFrame.height), expected \(expected)")
                #expect(!strip.isHidden && strip.alpha == 1)
                let colour = try #require(strip.backgroundColor).resolvedColor(with: controller.traitCollection)
                #expect(colour == Appearance.navigation.resolvedColor(with: controller.traitCollection))
                // Directly under the bar and as wide (the shell stops at horizontal safe areas, as on the Duo).
                let queue: UIView = try #require(element(NavigationDestination.queue.rawValue, in: controller.view))
                let navigation = try #require(queue.superview)
                let bar = navigation.convert(navigation.bounds, to: controller.view)
                #expect(abs(bar.maxY - stripFrame.minY) <= 0.5, "\(additional): bar \(bar), strip \(stripFrame)")
                #expect(abs(bar.minX - stripFrame.minX) <= 0.5 && abs(bar.width - stripFrame.width) <= 0.5, "\(bar) \(stripFrame)")
            }
        }
    }

    @Test func repeatedResizesRetainFeedScrollAndEpisodeNavigationAndWebView() async throws {
        try await run(bottomNavigation: true, rtl: false) { controller, _ in
            let row: UIButton = try #require(element("episode-1", in: controller.view))
            let scroll = try #require(row.superview?.superview as? UIScrollView)
            scroll.setContentOffset(CGPoint(x: 0, y: 320), animated: false)
            for width in [800.0, 320, 640, 402] {
                resize(controller, width: width, height: 700, left: 31, right: 9)
                #expect(scroll.contentOffset.y == 320)
            }
            let currentRow: UIButton = try #require(element("episode-1", in: controller.view))
            currentRow.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
            let notes: ShownotesWebView = try #require(element("episodeShownotes", in: controller.view))
            let cover: UIButton = try #require(element("episodeCover", in: controller.view))
            let header = try #require(cover.superview as? EpisodeHeaderView)
            for width in [320.0, 800, 402, 874] {
                resize(controller, width: width, height: 700, left: 9, right: 31)
                #expect(element("episodeShownotes", in: controller.view, as: ShownotesWebView.self) === notes)
                #expect(element("episodeCover", in: controller.view, as: UIButton.self) === cover)
                #expect(cover.superview === header)
                let headerFrame = header.convert(header.bounds, to: controller.view)
                let notesFrame = notes.convert(notes.bounds, to: controller.view)
                #expect(abs(headerFrame.maxY - notesFrame.minY) <= 1)
                #expect(abs(headerFrame.minX - notesFrame.minX) <= 1)
                #expect(element("toolbarBack", in: controller.view, as: UIButton.self) != nil)
            }
            let back: UIButton = try #require(element("toolbarBack", in: controller.view))
            back.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
            #expect(element("episode-1", in: controller.view, as: UIButton.self) != nil)
        }
    }

    @Test func shownotesNoticeRetainsIdentityAndReflowsAcrossInsetAndSizeChanges() async throws {
        for bottom in [false, true] {
            for rtl in [false, true] {
                try await run(bottomNavigation: bottom, rtl: rtl) { controller, _ in
                    let row: UIButton = try #require(element("episode-1", in: controller.view))
                    row.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
                    let notes: ShownotesWebView = try #require(element("episodeShownotes", in: controller.view))
                    notes.selectTimecode?(120_000)
                    let window = try #require(controller.view.window)
                    let notice: UILabel = try #require(element("applicationNotice", in: window))
                    let message = notice.text
                    #expect(message == Appearance.text("play_this_to_seek_position_message"))
                    for width in [402.0, 320, 874, 402] {
                        for (left, right) in [(0.0, 0.0), (47, 0), (0, 47), (11, 39)] {
                            resize(controller, width: width, height: 700, left: left, right: right)
                            #expect(element("applicationNotice", in: window, as: UILabel.self) === notice)
                            #expect(notice.text == message)
                            #expect(element("episodeShownotes", in: controller.view, as: ShownotesWebView.self) === notes)
                            let safe = controller.view.safeAreaLayoutGuide.layoutFrame
                            let frame = notice.convert(notice.bounds, to: controller.view)
                            #expect(abs(frame.minX - safe.minX - 24) <= 1)
                            #expect(abs(safe.maxX - frame.maxX - 24) <= 1)
                            #expect(frame.minY >= safe.minY && frame.maxY <= safe.maxY)
                            #expect(notice.bounds.height >= notice.sizeThatFits(CGSize(width: notice.bounds.width, height: .greatestFiniteMagnitude)).height)
                        }
                    }
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func openMoreMenuTracksVerticalInsetRedistributionWithoutLosingScroll(rtl: Bool) async throws {
        try await run(bottomNavigation: true, rtl: rtl) { controller, _ in
            controller.view.frame.size = CGSize(width: 402, height: 320)
            // Bottom insets stay within ShellLayout.bottomStripMaximum (24, Android's strip), so the 20 pt change moves the bar.
            controller.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 13, bottom: 24, right: 29)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            let more: UIControl = try #require(element("navigationMore", in: controller.view))
            more.sendActions(for: .touchUpInside)
            let overlay: UIControl = try #require(element("morePopup", in: controller.view))
            let panel = try #require(overlay.subviews.compactMap { $0 as? UIScrollView }.first)
            let maximumOffset = panel.contentSize.height - panel.bounds.height
            #expect(maximumOffset > 20)
            panel.setContentOffset(CGPoint(x: 0, y: 20), animated: false)
            let previousFrame = panel.convert(panel.bounds, to: controller.view)
            let navigationY = more.convert(more.bounds, to: controller.view).minY
            let size = panel.bounds.size
            controller.additionalSafeAreaInsets = UIEdgeInsets(top: 20, left: 13, bottom: 4, right: 29)
            // No resize or explicit invalidation: the inset callback must update layout.
            controller.view.layoutIfNeeded()
            #expect(element("morePopup", in: controller.view, as: UIControl.self) === overlay)
            #expect(panel.bounds.size == size)
            #expect(panel.contentOffset.y == 20)
            let frame = panel.convert(panel.bounds, to: controller.view)
            let shift = more.convert(more.bounds, to: controller.view).minY - navigationY
            #expect(abs(shift - 20) <= 1)
            #expect(abs(frame.minY - previousFrame.minY - shift) <= 1)
            #expect(abs(frame.maxY - more.convert(more.bounds, to: controller.view).minY) <= 1)
            overlay.sendActions(for: .touchUpInside)
            #expect(element("morePopup", in: controller.view, as: UIControl.self) == nil)
        }
    }

    private func waitForElement<T: UIView>(_ id: String, in view: UIView, as type: T.Type) async throws -> T {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let found: T = element(id, in: view) { return found }
            await Task.yield()
        }
        return try #require(element(id, in: view, as: type))
    }

    @Test(arguments: [false, true])
    func episodePopupAndSuggestionTrackLiveAnchorsDuringVerticalInsetChanges(rtl: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PopupAnchors-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let episode = ParsedEpisode(identifier: "one", title: "Episode", description: "Retained notes",
            media: ParsedMedia(url: "https://example.test/episode.mp3", size: 0, durationMilliseconds: 100_000))
        _ = try await library.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Feed", episodes: [episode]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
            validator: nil, permanentRedirectURL: nil))
        let usage = try StreamDownloadUsageStore(file: root.appendingPathComponent("usage.json"))
        for _ in 0..<10 { try usage.log(.stream) }
        do {
            try await run(bottomNavigation: true, rtl: rtl, library: library, usage: usage) { controller, _ in
                // This menu must overflow even when the host contributes no top inset. Bottom insets stay within
                // ShellLayout.bottomStripMaximum (24) so the redistribution keeps the screen height.
                controller.view.frame.size.height = 180
                controller.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 11, bottom: 24, right: 31)
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
                let row: UIButton = try #require(element("episode-1", in: controller.view))
                row.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
                let notes: ShownotesWebView = try #require(element("episodeShownotes", in: controller.view))
                let toolbar: UIView = try #require(element("mainToolbar", in: controller.view))
                let more: UIButton = try #require(element("episodeMore", in: controller.view))
                more.sendActions(for: .touchUpInside)
                let panel = try await waitForElement("episodeMenuPanel", in: controller.view, as: UIScrollView.self)
                #expect(panel.contentSize.height - panel.bounds.height > 20)
                panel.setContentOffset(CGPoint(x: 0, y: 20), animated: false)
                let oldY = panel.convert(panel.bounds, to: controller.view).minY
                let oldToolbarY = toolbar.convert(toolbar.bounds, to: controller.view).minY
                // The 20 points move from the bottom strip to the top, so the content keeps its size and the open
                // menu stays (a resized content area re-renders and closes popups, as a rotation does).
                controller.additionalSafeAreaInsets = UIEdgeInsets(top: 20, left: 11, bottom: 4, right: 31)
                controller.view.layoutIfNeeded()
                #expect(element("episodeMenuPanel", in: controller.view, as: UIScrollView.self) === panel)
                #expect(panel.contentOffset.y == 20)
                let shift = toolbar.convert(toolbar.bounds, to: controller.view).minY - oldToolbarY
                #expect(abs(shift - 20) <= 1)
                #expect(abs(panel.convert(panel.bounds, to: controller.view).minY - oldY - shift) <= 1)
                #expect(element("episodeShownotes", in: controller.view, as: ShownotesWebView.self) === notes)
                let overlay = try #require(panel.superview as? UIControl)
                overlay.sendActions(for: .touchUpInside)

                controller.view.frame.size.height = 874
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()

                // The real Stream action opens a suggestion from persisted usage history.
                let primary: UIControl = try #require(element("episodePrimaryAction", in: controller.view))
                primary.sendActions(for: .touchUpInside)
                let prompt = try await waitForElement("usageSuggestion", in: controller.view, as: UsageSuggestionView.self)
                prompt.layoutIfNeeded()
                // The suggestion's tracking of a top/bottom inset redistribution is not exercised here: the
                // bottom strip is capped at ShellLayout.bottomStripMaximum, and the test device's home-indicator
                // inset already exceeds it, so only the top would change.
                #expect(try #require(element("usageSuggestion-yes", in: prompt, as: UIButton.self)).isEnabled)
                #expect(prompt.accessibilityViewIsModal)
                #expect(prompt.accessibilityPerformEscape())
                #expect(element("usageSuggestion", in: controller.view, as: UsageSuggestionView.self) == nil)
                #expect(element("episodeShownotes", in: controller.view, as: ShownotesWebView.self) === notes)
            }
            try await library.close()
        } catch { try? await library.close(); throw error }
    }


    @Test(arguments: [false, true], [false, true])
    func subscriptionsRemainReachableWithFixedAddControl(bottomNavigation: Bool, rtl: Bool) async throws {
        let feeds = (1...30).map { LibraryFeed(id: Int64($0), source: "fixture://feed/\($0)",
            metadata: .init(format: .rss, title: "Subscription \($0)"), episodes: []) }
        try await run(bottomNavigation: bottomNavigation, rtl: rtl,
                      initialPage: NavigationDestination.subscriptions.rawValue, feeds: feeds) { controller, _ in
            // The source grid (default columns) and the list mode (columns = 1).
            for list in [false, true] {
            var priorOffset: CGFloat = 0
            if list {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("ShellResize-list-\(UUID()).json")
                defer { try? FileManager.default.removeItem(at: file) }
                let store = try SubscriptionDisplayPreferenceStore(file: file)
                var value = store.value; value.columns = 1; try store.update(value)
                controller.subscriptionPreferences = store
                resize(controller, width: 402, height: 700, left: 31, right: 7)
                await controller.reloadLibrary()?.value
                controller.view.layoutIfNeeded()
                controller.content.setContentOffset(.zero, animated: false)
            }
            for (width, height) in [(402.0, 700.0), (874, 320), (800, 900), (402, 700)] {
                resize(controller, width: width, height: height, left: 31, right: 7)
                let scroll = controller.content
                let add: UIButton = try #require(element("subscriptionsAdd", in: controller.view))
                let maximum = max(0, scroll.contentSize.height - scroll.bounds.height)
                try #require(maximum > 0, "All subscriptions must be reachable below this viewport")
                #expect(abs(scroll.contentOffset.y - min(priorOffset, maximum)) <= 1)
                var fixedFrame: CGRect?
                for offset in [0, maximum / 2, maximum] {
                    scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                    controller.view.layoutIfNeeded()
                    let frame = add.convert(add.bounds, to: controller.view)
                    let viewport = scroll.convert(scroll.bounds, to: controller.view)
                    // Fractional content heights give sub-picometre conversion noise; the control stays fixed.
                    if let fixedFrame {
                        #expect(abs(frame.minX - fixedFrame.minX) <= 1 && abs(frame.minY - fixedFrame.minY) <= 1 && frame.size == fixedFrame.size,
                                "Add \(frame) vs \(fixedFrame) at \(width)×\(height), offset \(offset) of \(maximum)")
                    } else { fixedFrame = frame }
                    #expect(abs(viewport.maxY - frame.maxY - 16) <= 1)
                    let trailingGap = rtl ? frame.minX - viewport.minX : viewport.maxX - frame.maxX
                    #expect(abs(trailingGap - 16) <= 1)
                    #expect(controller.view.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil) === add)
                }
                let last = try #require(lastSubscription(controller), "the last subscription is shown at the end")
                let lastFrame = last.convert(last.bounds, to: controller.view)
                let viewport = scroll.convert(scroll.bounds, to: controller.view)
                // A row that fits above the source's 88-point bottom padding is fully visible at the end. One
                // taller than that space (874×320: a 3-column cell exceeds the viewport; with bottom navigation
                // only 42 points remain above the padding, as on the source) shows its bottom edge clear of
                // Add at the end, and scrolling back by the hidden amount shows its top.
                if lastFrame.height <= viewport.height - 88 {
                    #expect(viewport.contains(lastFrame), "Viewport \(viewport), final row \(lastFrame), size \(width)×\(height), offset \(scroll.contentOffset)")
                } else {
                    #expect(lastFrame.maxY <= viewport.maxY + 0.01 && lastFrame.minY < viewport.minY, "\(viewport) \(lastFrame)")
                    let end = scroll.contentOffset
                    scroll.setContentOffset(CGPoint(x: 0, y: end.y - (viewport.minY - lastFrame.minY)), animated: false)
                    controller.view.layoutIfNeeded()
                    #expect(abs(last.convert(last.bounds, to: controller.view).minY - viewport.minY) <= 1, "top reachable")
                    scroll.setContentOffset(end, animated: false); controller.view.layoutIfNeeded()
                }
                #expect(lastFrame.maxY <= add.convert(add.bounds, to: controller.view).minY - 15)
                let offset = scroll.contentOffset
                await controller.reloadLibrary()?.value
                controller.view.layoutIfNeeded()
                #expect(scroll.contentOffset == offset)
                priorOffset = offset.y
            }
            }
            let last = try #require(lastSubscription(controller))
            last.sendActions(for: .touchUpInside)
            controller.view.layoutIfNeeded()
            #expect(element("subscriptionsAdd", in: controller.view, as: UIButton.self) == nil)
            #expect(element("toolbarBack", in: controller.view, as: UIControl.self) != nil)
        }
    }

    @Test(arguments: [0, 1])
    func shortSubscriptionListsKeepAddUsableWithoutSpuriousScrolling(count: Int) async throws {
        let feeds = (0..<count).map { LibraryFeed(id: Int64($0 + 1), source: "fixture://feed/\($0)",
            metadata: .init(format: .rss, title: "Subscription"), episodes: []) }
        try await run(bottomNavigation: false, rtl: false,
                      initialPage: NavigationDestination.subscriptions.rawValue, feeds: feeds) { controller, _ in
            for _ in 0..<3 {
                await controller.reloadLibrary()?.value
                controller.view.layoutIfNeeded()
                let add: UIButton = try #require(element("subscriptionsAdd", in: controller.view))
                var ancestor = add.superview
                while ancestor != nil && !(ancestor is UIScrollView) { ancestor = ancestor?.superview }
                let scroll = try #require(ancestor as? UIScrollView)
                #expect(scroll.contentSize.height <= scroll.bounds.height + 0.5)
                #expect(scroll.contentOffset == .zero)
                #expect(countElements("subscriptionsAdd", in: controller.view) == 1)
            }
            let add: UIButton = try #require(element("subscriptionsAdd", in: controller.view))
            add.sendActions(for: .touchUpInside)
            controller.view.layoutIfNeeded()
            let title: UILabel = try #require(element("screenTitle", in: controller.view))
            #expect(title.text == Appearance.title(for: .addPodcast))
        }
    }

}
