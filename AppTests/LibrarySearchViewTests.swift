import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized) struct LibrarySearchViewTests {
    private func find<T: UIView>(_ id: String, _ root: UIView, as: T.Type = T.self) -> T? {
        if let value = root as? T, value.accessibilityIdentifier == id { return value }
        return root.subviews.lazy.compactMap { find(id, $0, as: T.self) }.first
    }
    private func tap(_ id: String, _ root: UIView) throws {
        let button: UIControl = try #require(find(id, root)); button.sendActions(for: .touchUpInside)
        root.layoutIfNeeded()
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(predicate())
    }
    @Test func feedSearchQueriesRealStoreOpensEpisodeReturnsAndClearsScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SearchUI-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        func insert(_ title: String) async throws -> LibraryFeed {
            try await store.insert(.init(feed: .init(format: .rss, title: title, description: "matching library", episodes: (0..<30).map { index in
                .init(identifier: "\(title)-\(index)", title: "matching \(title) episode \(index) with a long title to verify reflow of retained reading position", description: "notes") }), source: "https://example.org/\(title)",
                responseURL: URL(string: "https://example.org/feed")!, validator: nil, permanentRedirectURL: nil))
        }
        let first = try await insert("first"), second = try await insert("second")
        let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: nil, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer { controller.view.endEditing(true); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 700)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            await controller.openNotification(.feed(first.id)); controller.view.layoutIfNeeded()
            try tap("feedSearch", controller.view)
            let field: UITextField = try #require(find("librarySearchQuery", controller.view))
            field.text = "matching"; field.sendActions(for: .editingChanged)
            _ = field.delegate?.textFieldShouldReturn?(field)
            try await wait { self.find("episode-\(first.episodes[0].id)", controller.view, as: UIButton.self) != nil }
            #expect(find("episode-\(second.episodes[0].id)", controller.view, as: UIButton.self) == nil)
            try tap("episode-\(first.episodes[0].id)", controller.view)
            #expect(find("episodeShownotes", controller.view, as: UIView.self) != nil)
            try tap("toolbarBack", controller.view)
            let restored: UITextField = try #require(find("librarySearchQuery", controller.view))
            #expect(restored === field); #expect(restored.text == "matching")
            let results: UIScrollView = try #require(find("searchEpisodeResults", controller.view))
            // Rows are built as they come near the screen: scroll down to the sixteenth.
            while find("episode-\(first.episodes[15].id)", controller.view, as: UIButton.self) == nil,
                  results.contentOffset.y < results.contentSize.height { results.contentOffset.y += 100 }
            let row = try #require(find("episode-\(first.episodes[15].id)", controller.view, as: UIButton.self)?.superview)
            results.contentOffset.y = row.frame.minY + 10
            field.becomeFirstResponder()
            field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.position(from: field.beginningOfDocument, offset: 3)!)
            controller.additionalSafeAreaInsets = .init(top: 0, left: 19, bottom: 0, right: 47)
            controller.view.frame.size = CGSize(width: 700, height: 450)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            #expect(field.text == "matching"); #expect(field.isFirstResponder)
            let retainedRow = try #require(find("episode-\(first.episodes[15].id)", controller.view, as: UIButton.self)?.superview)
            #expect(abs(retainedRow.frame.minY - results.contentOffset.y + 10) < 1)
            #expect(field.selectedTextRange.map { field.offset(from: field.beginningOfDocument, to: $0.end) } == 3)
            field.resignFirstResponder()
            try tap("searchFeedScope", controller.view)
            let search = try #require(controller.view.searchDescendants.compactMap { $0 as? LibrarySearchView }.first)
            try await wait { search.displayedIDs.contains(second.episodes[0].id) }
            // Only the rows near the screen are built (60 results).
            #expect(search.displayedIDs.count == 60)
            #expect(results.searchDescendants.filter { $0 is EpisodeRowView }.count < 40)
            results.contentOffset.y = 0
            while find("episode-\(second.episodes[0].id)", controller.view, as: UIButton.self) == nil,
                  results.contentOffset.y < results.contentSize.height { results.contentOffset.y += 100 }
            #expect(find("episode-\(second.episodes[0].id)", controller.view, as: UIButton.self) != nil)
            #expect(find("searchFeed-\(second.id)", controller.view, as: UIButton.self) != nil)
            field.text = "unfindable"; field.sendActions(for: .editingChanged); _ = field.delegate?.textFieldShouldReturn?(field)
            try await wait { self.find("searchEmptyTitle", controller.view, as: UILabel.self)?.text?.contains("unfindable") == true }
            field.text = ""; field.sendActions(for: .editingChanged)
            #expect(find("searchEmptyTitle", controller.view, as: UILabel.self)?.text == "Type a query to search")
            try tap("toolbarBack", controller.view)
            #expect(find("feedInformation", controller.view, as: UIButton.self) != nil)
        }
        try await store.close()
    }
    @Test func rtlFeedStripRetainsLogicalLeadingOffsetThroughViewportChanges() async throws {
        var result = LibrarySearchResult()
        result.feeds = (1...8).map { LibraryFeed(id: Int64($0), source: "fixture", metadata: .init(format: .rss, title: "Feed \($0)"), episodes: []) }
        let supplied = result
        let session = LibrarySearchSession(feedID: nil, feedTitle: "", read: { _, _ in supplied })
        let search = LibrarySearchView(session: session)
        search.semanticContentAttribute = .forceRightToLeft
        search.frame = CGRect(x: 0, y: 0, width: 360, height: 400)
        session.change("feed ")
        try await wait { self.find("searchFeed-1", search, as: UIButton.self) != nil }
        search.layoutIfNeeded()
        let strip: UIScrollView = try #require(find("searchFeedResults", search))
        #expect(abs(strip.contentOffset.x - (strip.contentSize.width - 360)) < 1, "RTL strip starts at its logical leading (right) end")
        strip.contentOffset.x -= 100
        search.frame.size.width = 260; search.setNeedsLayout(); search.layoutIfNeeded()
        #expect(abs(strip.contentSize.width - 260 - strip.contentOffset.x - 100) < 1)
        search.frame.size.width = 500; search.setNeedsLayout(); search.layoutIfNeeded()
        #expect(abs(strip.contentSize.width - 500 - strip.contentOffset.x - 100) < 1)
    }

}

private extension UIView {
    var searchDescendants: [UIView] { subviews + subviews.flatMap(\.searchDescendants) }
}
