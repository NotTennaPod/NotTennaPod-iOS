import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

private actor OnlineUIRequests {
    var queries: [String] = []
    func search(_ query: String) throws -> [PodcastSearchResult] {
        queries.append(query)
        if query == "failure", queries.filter({ $0 == "failure" }).count == 1 { throw PodcastSearchError.http(503) }
        return (0..<40).map { index in
            .init(title: index == 12 ? "A long result title that must wrap across two lines in the first column" : "Result \(index)",
                  feedURL: index == 13 ? "https://itunes.apple.com/lookup?id=13" : "https://example.org/\(index)",
                  author: index == 12 ? "A long author name that also takes two lines in this column" : (index == 13 ? nil : "Author \(index)"))
        }
    }
}
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct OnlineSearchViewTests {
    private func find<T: UIView>(_ id: String, _ root: UIView, as: T.Type = T.self) -> T? {
        if let value = root as? T, value.accessibilityIdentifier == id { return value }
        return root.subviews.lazy.compactMap { find(id, $0, as: T.self) }.first
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await predicate())
    }
    @Test func draftResizeResultAnchorAndSelectionDoNotResubmit() async throws {
        let requests = OnlineUIRequests()
        let session = OnlineSearchSession { query, _ in try await requests.search(query) }
        let search = OnlineSearchView(session: session, query: "initial")
        try await withViewTestWindow { host, _ in
            host.view.addSubview(search); host.view.addSubview(search.field)
            defer { search.field.resignFirstResponder(); search.field.removeFromSuperview(); search.removeFromSuperview() }
            search.frame = CGRect(x: 19, y: 60, width: 390, height: 420)
            search.field.frame = CGRect(x: 72, y: 0, width: 300, height: 48); search.toolbarAttached()
            try await wait { if case .results = session.state { true } else { false } }
            search.layoutIfNeeded()
            #expect(!search.field.isFirstResponder)
            let scroll: UIScrollView = try #require(find("onlineSearchResults", search))
            let row: UIButton = try #require(find("onlineSearchResult-12", search)); scroll.contentOffset.y = row.frame.minY + 10
            search.field.text = "unsubmitted draft"; search.field.sendActions(for: .editingChanged)
            search.field.becomeFirstResponder()
            search.field.selectedTextRange = search.field.textRange(from: search.field.beginningOfDocument, to: search.field.position(from: search.field.beginningOfDocument, offset: 4)!)
            search.frame.size = CGSize(width: 830, height: 300); search.setNeedsLayout(); search.layoutIfNeeded(); search.toolbarAttached()
            #expect(abs(row.frame.minY - scroll.contentOffset.y + 10) < 1)
            #expect(search.field.text == "unsubmitted draft"); #expect(search.field.isFirstResponder)
            #expect(search.field.selectedTextRange.map { search.field.offset(from: search.field.beginningOfDocument, to: $0.end) } == 4)
            #expect(await requests.queries == ["initial"])
            let next: UIButton = try #require(find("onlineSearchResult-13", search))
            #expect(next.frame.height < row.frame.height)
            #expect(abs(next.frame.minY - row.frame.minY) <= 1); #expect(next.frame.minX > row.frame.minX)
            search.semanticContentAttribute = .forceRightToLeft; search.setNeedsLayout(); search.layoutIfNeeded()
            #expect(next.frame.minX < row.frame.minX)
            search.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            search.frame.size.width = 260; search.setNeedsLayout(); search.layoutIfNeeded()
            let footer: UILabel = try #require(find("onlineSearchProvider", search))
            #expect(footer.numberOfLines == 0); #expect(footer.frame.height > footer.font.lineHeight)
            #expect(footer.frame.maxX <= search.bounds.width)
            #expect(search.field.text == "unsubmitted draft")
            var selected: String?
            search.openFeed = { selected = $0 }; row.sendActions(for: .touchUpInside)
            #expect(selected == "https://example.org/12"); #expect(!search.field.isFirstResponder)
        }
    }
    @Test func retryUsesSubmittedQueryAndRemainsReachableInShortWindow() async throws {
        let requests = OnlineUIRequests()
        let session = OnlineSearchSession(provider: .apple) { query, _ in try await requests.search(query) }
        let search = OnlineSearchView(session: session, query: "failure")
        try await wait { session.state == .failure("HTTP 503") }
        search.frame = CGRect(x: 0, y: 0, width: 260, height: 90); search.layoutIfNeeded()
        search.field.text = "other draft"; search.field.sendActions(for: .editingChanged)
        let retry: UIButton = try #require(find("onlineSearchRetry", search))
        let scroll: UIScrollView = try #require(find("onlineSearchResults", search))
        #expect(!retry.isHidden); #expect(scroll.contentSize.height >= retry.frame.maxY)
        #expect(retry.frame.minX >= 0 && retry.frame.maxX <= scroll.bounds.width)
        retry.sendActions(for: .touchUpInside)
        try await wait { if case .results = session.state { true } else { false } }
        #expect(await requests.queries == ["failure", "failure"])
        #expect(search.field.text == "other draft")
    }
    @Test func librarySearchConnectsOnlineAndBackRetainsBothQueries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OnlineSearchUI-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let feed = try await library.insert(.init(feed: .init(format: .rss, title: "Library", episodes: []), source: "https://example.org/feed", responseURL: URL(string: "https://example.org/feed")!, validator: nil, permanentRedirectURL: nil))
        let client = PodcastSearchClient(send: { request in
            let json = request.url!.host == "itunes.apple.com" ? #"{"results":[{"collectionName":"Found podcast","feedUrl":"https://example.org/remote"}]}"# : #"{"feeds":[]}"#
            return (Data(json.utf8), 200)
        })
        let controller = LibraryViewController(library: library, startupError: nil, downloads: nil, playback: nil, timeDisplayPreferences: nil, navigationPreferences: nil, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil, podcastSearch: client)
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer { controller.view.endEditing(true); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            controller.view.frame = CGRect(x: 0, y: 0, width: 466, height: 650)
            await controller.openNotification(.feed(feed.id)); controller.view.layoutIfNeeded()
            @MainActor func tap(_ id: String) throws {
                let button: UIButton = try #require(find(id, controller.view)); button.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
            }
            try tap("feedSearch")
            let local: UITextField = try #require(find("librarySearchQuery", controller.view))
            local.text = "podcasts"; local.sendActions(for: .editingChanged); _ = local.delegate?.textFieldShouldReturn?(local)
            let scoped: UIButton = try #require(find("searchOnline", controller.view)); #expect(scoped.isHidden)
            try tap("searchFeedScope"); try tap("searchOnline")
            try await wait { self.find("onlineSearchResult-0", controller.view, as: UIButton.self) != nil }
            let online: UITextField = try #require(find("onlineSearchQuery", controller.view)); #expect(online.text == "podcasts")
            online.text = "draft"; online.sendActions(for: .editingChanged)
            controller.additionalSafeAreaInsets = .init(top: 0, left: 19, bottom: 0, right: 47)
            controller.view.frame.size = CGSize(width: 830, height: 450); controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            #expect(online.text == "draft")
            #expect(online.convert(online.bounds, to: controller.view).maxX <= 830 - 47)
            try tap("toolbarBack")
            #expect(find("librarySearchQuery", controller.view, as: UITextField.self) === local)
            #expect(local.text == "podcasts")
        }
        try await library.close()
    }
}
