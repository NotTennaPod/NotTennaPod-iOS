import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct FeedSortViewTests {
    private func element<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if let result = view as? T, result.accessibilityIdentifier == id
            || (result.accessibilityIdentifier == nil && (result as? UIButton)?.title(for: .normal) == id) { return result }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: type) }.first
    }
    private func wait(_ condition: () async throws -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(6)
        while try await !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await condition())
    }
    private func tap(_ id: String, _ controller: UIViewController) throws {
        let button: UIControl = try #require(element(id, in: controller.view))
        button.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
    }

    @Test(arguments: [false, true])
    func sheetPreservesChoicesAndSelectionAcrossAsymmetricInsetsAndShortWindow(local: Bool) async throws {
        let editor = FeedSortEditor(selection: .global, local: local, save: { _ in })
        let controller = FeedSortController(editor: editor)
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            controller.view.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
            controller.additionalSafeAreaInsets = .init(top: 12, left: 27, bottom: 19, right: 61)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            let sheet: UIView = try #require(element("feedSortSheet", in: controller.view))
            #expect(abs(sheet.bounds.width - 640) < 1, "Sheet is capped at the source 640 pt width")
            let safe = controller.view.safeAreaInsets
            #expect(abs(sheet.frame.midX - (safe.left + (1000 - safe.left - safe.right) / 2)) < 0.5)
            #expect((element("feedSort-filename", in: controller.view, as: UIButton.self) != nil) == local)
            let global: UIButton = try #require(element("feedSort-global", in: controller.view))
            #expect(!global.isEnabled && global.accessibilityTraits.contains(.notEnabled))
            try tap("feedSort-title", controller)
            let title: UIButton = try #require(element("feedSort-title", in: controller.view))
            #expect(title.title(for: .normal) == "Episode title\u{a0}▲")
            try tap("feedSort-title", controller)
            #expect(editor.selection == .titleDescending)
            controller.additionalSafeAreaInsets = .init(top: 12, left: 63, bottom: 19, right: 5)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            let changedSafe = controller.view.safeAreaInsets
            #expect(abs(sheet.frame.midX - (changedSafe.left + (1000 - changedSafe.left - changedSafe.right) / 2)) < 0.5)
            controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            controller.view.frame.size = CGSize(width: 360, height: 230)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            #expect(editor.selection == .titleDescending)
            #expect(sheet.frame.minY >= controller.view.safeAreaInsets.top)
            let duration: UIButton = try #require(element("feedSort-duration", in: controller.view))
            #expect(abs(title.frame.midY - duration.frame.midY) < 0.5)
            #expect(title.bounds.height > duration.bounds.height)
            let last: UIButton = try #require(element("feedSort-global", in: controller.view))
            let scroller = try #require(last.superview as? UIScrollView)
            scroller.scrollRectToVisible(last.frame, animated: false)
            #expect(scroller.bounds.contains(CGPoint(x: last.frame.midX, y: last.frame.midY)))
            controller.view.semanticContentAttribute = .forceRightToLeft
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            #expect(title.frame.minX > duration.frame.minX)
            #expect(title.title(for: .normal) == "Episode title\u{a0}▼")
        }
    }

    @Test func menuSortAndInboxConfirmationUpdateRealListAndPreserveQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FeedSortUI-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let preferencesFile = root.appendingPathComponent("navigation.json")
        let preferences = try NavigationPreferenceStore(file: preferencesFile)
        let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Menu podcast", link: "https://example.org/site",
            episodes: ["Zulu", "Alpha", "Beta"].enumerated().map { index, title in
                .init(identifier: title, title: title, publicationDate: Date(timeIntervalSince1970: Double(index + 1)))
            }), source: "https://example.org/feed", responseURL: URL(string: "https://example.org/feed")!, validator: nil, permanentRedirectURL: nil))
        let newID = feed.episodes[0].id
        try await store.updateEpisode(id: newID) { $0.userState.playState = .new }
        _ = try await store.enqueue([feed.episodes[1].id])
        let queued = try await store.queue()
        let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: preferences, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil,
            feedDeletion: .init(store: store, retirePlayback: { _ in }, retireDownloads: { _ in }),
            manualRefresh: .init(store: store, execute: { _ in }))
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 800)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            await controller.openNotification(.feed(feed.id)); controller.view.layoutIfNeeded()
            try tap("feedListMore", controller)
            let ids = ["sortFeed", "refreshFeed", "feedListWebsite", "feedListShare", "removeFeedInbox", "removeArchiveFeed"]
            let positions = try ids.map { id -> CGFloat in
                let button: UIButton = try #require(element(id, in: controller.view)); return button.frame.minY
            }
            #expect(positions == positions.sorted())
            try tap("sortFeed", controller)
            try await wait { controller.presentedViewController is FeedSortController && controller.presentedViewController?.isBeingPresented == false }
            let sheet = try #require(controller.presentedViewController as? FeedSortController)
            try tap("feedSort-title", sheet)
            try await wait { try await store.feed(id: feed.id)?.episodeSortOrderCode == 3 }
            try await wait {
                let alpha = self.element("episode-\(feed.episodes.first { $0.details.title == "Alpha" }!.id)", in: controller.view, as: UIView.self)
                let zulu = self.element("episode-\(feed.episodes.first { $0.details.title == "Zulu" }!.id)", in: controller.view, as: UIView.self)
                return alpha != nil && zulu != nil && alpha!.convert(alpha!.bounds, to: controller.view).minY < zulu!.convert(zulu!.bounds, to: controller.view).minY
            }
            #expect(controller.presentedViewController === sheet)
            _ = sheet.accessibilityPerformEscape()
            try await wait { controller.presentedViewController == nil }
            try tap("feedListMore", controller); try tap("removeFeedInbox", controller)
            try await wait { controller.presentedViewController is SourceMessageController && controller.presentedViewController?.isBeingPresented == false }
            try tap("removeFeedInboxCancel", try #require(controller.presentedViewController))
            try await wait { controller.presentedViewController == nil }
            #expect(try await store.episode(id: newID)?.userState.playState == .new)
            try tap("feedListMore", controller); try tap("removeFeedInbox", controller)
            try await wait { controller.presentedViewController is SourceMessageController && controller.presentedViewController?.isBeingPresented == false }
            try tap("removeFeedInboxConfirm", try #require(controller.presentedViewController))
            try await wait { try await store.episode(id: newID)?.userState.playState == .unplayed }
            #expect(try await store.queue() == queued)
            try await wait { controller.presentedViewController == nil }
            try tap("feedListMore", controller); try tap("sortFeed", controller)
            try await wait { controller.presentedViewController is FeedSortController && controller.presentedViewController?.isBeingPresented == false }
            let feedSheet = try #require(controller.presentedViewController as? FeedSortController)
            try tap("feedSort-global", feedSheet)
            try await wait { try await store.feed(id: feed.id)?.episodeSortOrderCode == 11 }
            _ = feedSheet.accessibilityPerformEscape()
            try await wait { controller.presentedViewController == nil }
            try tap("navigationMore", controller); try tap("Settings", controller)
            try tap("prefScreenInterface", controller); try tap("prefGlobalDefaultSortedOrder", controller)
            try await wait { controller.presentedViewController is FeedSortController && controller.presentedViewController?.isBeingPresented == false }
            let globalSheet = try #require(controller.presentedViewController as? FeedSortController)
            #expect(element("feedSort-global", in: globalSheet.view, as: UIButton.self) == nil)
            #expect(element("feedSort-filename", in: globalSheet.view, as: UIButton.self) == nil)
            try tap("feedSort-title", globalSheet); try tap("feedSort-title", globalSheet)
            try await wait { preferences.value.defaultFeedSortOrder == .titleDescending }
            #expect(try NavigationPreferenceStore(file: preferencesFile).value.defaultFeedSortOrder == .titleDescending)
            _ = globalSheet.accessibilityPerformEscape()
            try await wait { controller.presentedViewController == nil }
            try tap("toolbarBack", controller); try tap("toolbarBack", controller)
            try await wait {
                let alpha = self.element("episode-\(feed.episodes.first { $0.details.title == "Alpha" }!.id)", in: controller.view, as: UIView.self)
                let zulu = self.element("episode-\(feed.episodes.first { $0.details.title == "Zulu" }!.id)", in: controller.view, as: UIView.self)
                return alpha != nil && zulu != nil && zulu!.convert(zulu!.bounds, to: controller.view).minY < alpha!.convert(alpha!.bounds, to: controller.view).minY
            }

        }
        try await store.close()
    }
}
