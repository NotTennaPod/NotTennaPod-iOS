import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite
struct FeedPaginationViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let result = view as? T { return result }
        for child in view.subviews { if let result: T = find(id, in: child) { return result } }
        return nil
    }
    private func wait(_ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while try await !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        #expect(try await predicate())
    }
    @Test func footerVisibilityLoadingNavigationAndResetAreConnected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PagedViews-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        var parsed = ParsedFeed(format: .rss, title: "Paged view")
        parsed.isPaged = true; parsed.nextPageURL = "https://example.org/page1"
        parsed.episodes = (1...24).map { ParsedEpisode(identifier: "\($0)", title: "Episode \($0)") }
        let feed = try await store.insert(.init(feed: parsed, source: "https://example.org/root", responseURL: URL(string: "https://example.org/root")!, validator: nil, permanentRedirectURL: nil))
        let refresh = ManualFeedRefreshCoordinator(store: store, execute: { _ in try await Task.sleep(for: .seconds(50)) })
        defer { refresh.suspend() }
        let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: nil, speedPreferences: nil,
            mobileNetworkPreferences: nil, usage: nil, manualRefresh: refresh,
            refreshNetwork: { throw CancellationError() }) // Page controls bypass admission/network probing.
        refresh.onChange = { [weak controller] in controller?.refreshStateChanged($0) }
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            await controller.openNotification(.feed(feed.id)); controller.view.layoutIfNeeded()
            let footer: FeedPageFooter = try #require(find("feedNextPage", in: controller.view))
            let content: UIScrollView = try #require(find("libraryContent", in: controller.view))
            #expect(footer.isHidden)
            content.contentOffset.y = content.contentSize.height - content.bounds.height
            #expect(!footer.isHidden)
            #expect(abs(footer.frame.maxY - content.frame.maxY) < 0.5)
            // Every scroll callback asks for the footer's size; its text is measured again only when something changed.
            let measured = footer.measurements
            for _ in 0..<50 { content.contentOffset.y -= 1 }
            #expect(footer.measurements - measured <= 1, "\(footer.measurements - measured) measurements in 50 scroll callbacks")
            content.contentOffset.y = content.contentSize.height - content.bounds.height
            footer.sendActions(for: .touchUpInside)
            try await wait { try await store.manualRefreshRequest()?.nextPage == true }
            #expect(footer.isLoading && !footer.isEnabled)
            let first = try #require(try await store.manualRefreshRequest())
            footer.sendActions(for: .touchUpInside)
            #expect(try await store.manualRefreshRequest()?.id == first.id)
            for size in [CGSize(width: 720, height: 420), CGSize(width: 320, height: 260)] {
                controller.view.frame.size = size
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                content.contentOffset.y = content.contentSize.height - content.bounds.height
                #expect(!footer.isHidden)
                #expect(footer.frame.width == content.frame.width)
                #expect(abs(footer.frame.maxY - content.frame.maxY) < 0.5)
            }
            let more: UIButton = try #require(find("feedListMore", in: controller.view))
            more.sendActions(for: .touchUpInside)
            let complete: UIButton = try #require(find("refreshCompleteFeed", in: controller.view))
            #expect(complete.title(for: .normal) == "Refresh complete podcast")
            complete.sendActions(for: .touchUpInside)
            try await wait { try await store.manualRefreshRequest()?.id != first.id }
            #expect(try await store.manualRefreshRequest()?.nextPage == false)
            #expect(try await store.feed(id: feed.id)?.metadata.nextPageURL == feed.source)
            let information: UIButton = try #require(find("feedInformation", in: controller.view))
            information.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
            #expect(footer.isHidden)
        }
        refresh.suspend()
        try await store.close()
    }

    @Test(arguments: [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge])
    func footerFitsTextAndKeepsCenteredSourceOrder(category: UIContentSizeCategory) async throws {
        try await withViewTestWindow { host, _ in
            let footer = FeedPageFooter()
            host.view.addSubview(footer)
            footer.traitOverrides.preferredContentSizeCategory = category
            footer.frame = CGRect(origin: .zero, size: footer.sizeThatFits(CGSize(width: 300, height: 300)))
            footer.setLoading(false); footer.layoutIfNeeded()
            let label = try #require(footer.subviews.compactMap { $0 as? UILabel }.first)
            let image = try #require(footer.subviews.compactMap { $0 as? UIImageView }.first)
            // Icon then text, side by side and centred as a group; the text is never clipped.
            let gap = label.frame.minX - image.frame.maxX
            #expect(gap >= 0 && gap <= 16)
            #expect(image.frame.width > 0 && image.frame.height > 0 && image.image != nil)
            #expect(label.frame.minY >= 0 && label.frame.maxY <= footer.bounds.maxY, "label \(label.frame), footer \(footer.bounds), font \(label.font.pointSize)")
            #expect(label.frame.height >= ceil(label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height) - 0.5)
            #expect(abs((image.frame.minX + label.frame.maxX) / 2 - footer.bounds.midX) < 8)
            #expect(label.text == "Load next page")
        }
    }

    /// The footer's text is measured once per width, text size and text: again after a text-size change, and the
    /// result (size and layout, right to left too) is a fresh footer's.
    @Test(arguments: [UISemanticContentAttribute.forceLeftToRight, .forceRightToLeft])
    func footerMeasuresItsTextOncePerChange(direction: UISemanticContentAttribute) async throws {
        try await withViewTestWindow { host, _ in
            func make(_ category: UIContentSizeCategory?) -> FeedPageFooter {
                let footer = FeedPageFooter()
                footer.semanticContentAttribute = direction
                host.view.addSubview(footer)
                if let category { footer.traitOverrides.preferredContentSizeCategory = category }
                return footer
            }
            let footer = make(nil)
            let bounds = CGSize(width: 300, height: 800)
            for _ in 0..<50 { _ = footer.sizeThatFits(bounds) }
            #expect(footer.measurements == 1)
            footer.frame = CGRect(origin: .zero, size: footer.sizeThatFits(bounds)); footer.layoutIfNeeded()
            #expect(footer.measurements == 1, "a layout at the measured width reuses it")
            footer.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            let larger = footer.sizeThatFits(bounds)
            #expect(footer.measurements == 2, "a text-size change measures again")
            _ = footer.sizeThatFits(CGSize(width: 260, height: 800))
            #expect(footer.measurements == 3, "so does a width change")
            let fresh = make(.accessibilityExtraExtraExtraLarge)
            #expect(fresh.sizeThatFits(bounds) == larger)
            footer.frame = CGRect(origin: .zero, size: larger); fresh.frame = footer.frame
            footer.setNeedsLayout(); footer.layoutIfNeeded(); fresh.layoutIfNeeded()
            let frames = { (view: FeedPageFooter) in view.subviews.map(\.frame) }
            #expect(frames(footer) == frames(fresh), "the same layout as a fresh footer")
            footer.removeFromSuperview(); fresh.removeFromSuperview()
        }
    }
}
