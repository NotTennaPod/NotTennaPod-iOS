import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor
struct FeedFilterViewTests {
    private func fixture(filter: [String] = []) async throws -> (URL, FeedLibraryStore, FeedFilterEditor) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FilterView-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let feed = try await store.insert(FetchedFeed(feed: .init(format: .rss, title: "Feed"),
            source: "https://example.invalid/feed", responseURL: URL(string: "https://example.invalid/feed")!,
            validator: nil, permanentRedirectURL: nil))
        try await store.setEpisodeFilter(feedID: feed.id, filter: .init(values: filter))
        return (directory, store, FeedFilterEditor(feed: try #require(await store.feed(id: feed.id)), store: store))
    }
    private func element<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if let item = view as? T, item.accessibilityIdentifier == id { return item }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: type) }.first
    }
    private func layout(_ controller: UIViewController, width: CGFloat = 402, height: CGFloat = 874) {
        controller.loadViewIfNeeded(); controller.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
    }

    @Test func allTwelveOptionsUseSourceLabelsGroupsOrderingAndImmediateWrites() async throws {
        let (directory, store, editor) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var saved: [LibraryFeed] = []
        let controller = FeedFilterController(editor: editor, onSaved: { saved.append($0) })
        layout(controller)
        let labels = [["Played","Not played"],["Paused","Not paused"],["Is favorite","Not favorite"],
                      ["Has media","No media"],["Queued","Not queued"],["Downloaded","Not downloaded"]]
        var y: CGFloat = 0
        for group in FeedFilterGroup.allCases {
            let buttons = try group.values.map { try #require(element("feedFilter_" + $0, in: controller.view, as: UIControl.self)) }
            // Each pair is one segmented row, below the previous one, positive option first.
            #expect(abs(buttons[0].frame.minY - buttons[1].frame.minY) < 0.5 && buttons[0].frame.minY >= y - 0.5)
            #expect(buttons[0].frame.minX > 0 && buttons[0].frame.minX < buttons[1].frame.minX)
            #expect(abs(buttons[0].frame.maxX - buttons[1].frame.minX) <= 2, "Pair halves touch like a segmented button")
            for index in 0...1 {
                #expect(buttons[index].accessibilityLabel == labels[group.rawValue][index])
                buttons[index].sendActions(for: .touchUpInside)
                #expect(buttons[index].isSelected && !buttons[1 - index].isSelected)
                #expect(buttons[index].accessibilityTraits.contains(.selected))
            }
            y = buttons[0].frame.maxY
        }
        let reset = try #require(element("feedFilterReset", in: controller.view, as: UIButton.self))
        let confirm = try #require(element("feedFilterConfirm", in: controller.view, as: UIButton.self))
        #expect(reset.frame.minY >= y - 0.5 && abs(reset.frame.minY - confirm.frame.minY) < 0.5 && reset.frame.maxX <= confirm.frame.minX + 0.5,
                "Reset then Confirm on one row below the options")
        #expect(reset.title(for: .normal) == "Reset" && confirm.title(for: .normal) == "Confirm")
        await editor.waitForPendingChanges()
        #expect(saved.count == 12 && saved.last?.episodeFilter.values == ["unplayed","not_paused","not_favorite","no_media","not_queued","not_downloaded"])
        reset.sendActions(for: .touchUpInside)
        #expect(!editor.selection.filter.isActive)
        await editor.waitForPendingChanges()
        #expect(saved.count == 13 && saved.last?.episodeFilter.isActive == false)
        confirm.sendActions(for: .touchUpInside)
        await editor.waitForPendingChanges()
        #expect(saved.count == 13)
        try await store.close()
    }

    @Test func widthRTLAndShortViewportPreservePairAnchorsAndScrollableFooter() async throws {
        let (directory, store, editor) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = FeedFilterController(editor: editor)
        for width in [320, 402, 834] as [CGFloat] {
            for rtl in [false, true] {
                controller.loadViewIfNeeded(); controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                layout(controller, width: width, height: 250)
                let sheet = try #require(element("feedFilterSheet", in: controller.view, as: UIScrollView.self))
                let first = try #require(element("feedFilter_played", in: sheet, as: UIControl.self))
                let second = try #require(element("feedFilter_unplayed", in: sheet, as: UIControl.self))
                #expect(abs(sheet.bounds.width - min(640, width)) < 1 && abs(sheet.frame.maxY - 250) < 1, "Bottom sheet, capped at 640 pt wide")
                #expect(sheet.contentSize.height > sheet.bounds.height)
                #expect(first.frame.minY > 0 && abs(first.frame.height - second.frame.height) < 0.5)
                // The positive option leads in either direction, with equal side margins.
                #expect(rtl ? first.frame.minX > second.frame.minX : first.frame.minX < second.frame.minX)
                let leftMargin = min(first.frame.minX, second.frame.minX), rightMargin = sheet.bounds.width - max(first.frame.maxX, second.frame.maxX)
                #expect(leftMargin > 0 && abs(leftMargin - rightMargin) < 1)
                let confirm = try #require(element("feedFilterConfirm", in: sheet, as: UIButton.self))
                #expect(confirm.frame.maxY <= sheet.contentSize.height - 8)
            }
        }
        try await store.close()
    }

    @Test func confirmClosesPresentedSheetWithoutCancelingAcceptedChange() async throws {
        let (directory, store, editor) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { host.dismiss(animated: false); window.isHidden = true; previous?.makeKey() }
        var saved: LibraryFeed?
        let controller = FeedFilterController(editor: editor, onSaved: { saved = $0 })
        host.present(controller, animated: false); controller.view.layoutIfNeeded()
        let played = try #require(element("feedFilter_played", in: controller.view, as: UIControl.self))
        played.sendActions(for: .touchUpInside)
        let confirm = try #require(element("feedFilterConfirm", in: controller.view, as: UIControl.self))
        confirm.sendActions(for: .touchUpInside)
        await editor.waitForPendingChanges()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while host.presentedViewController != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(host.presentedViewController == nil && saved?.episodeFilter.values == ["played"])
        try await store.close()
    }

    @Test func openingSheetPersistsItsRestoredLegacySelectionWithoutConfirm() async throws {
        let (directory, store, editor) = try await fixture(filter: ["played", "unplayed", "unknown"])
        defer { try? FileManager.default.removeItem(at: directory) }
        var saved: LibraryFeed?
        let controller = FeedFilterController(editor: editor, onSaved: { saved = $0 })
        layout(controller)
        let played = try #require(element("feedFilter_played", in: controller.view, as: UIControl.self))
        let unplayed = try #require(element("feedFilter_unplayed", in: controller.view, as: UIControl.self))
        #expect(!played.isSelected && unplayed.isSelected)
        await editor.waitForPendingChanges()
        #expect(saved?.episodeFilter.values == ["unplayed"])
        try await store.close()
    }
}
