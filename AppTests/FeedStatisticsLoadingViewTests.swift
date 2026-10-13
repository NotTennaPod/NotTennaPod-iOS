import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor
struct FeedStatisticsLoadingViewTests {
    private func element<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if view.accessibilityIdentifier == id { return view as? T }
        for child in view.subviews { if let found = element(id, in: child, as: type) { return found } }
        return nil
    }
    private func value(_ card: String, in view: UIView) -> String? {
        guard let card = element("statistics.\(card)", in: view, as: UIView.self) else { return nil }
        return element("statisticsValue", in: card, as: UILabel.self)?.text
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    @Test func actualStoreLoadsAndNewDialogReadsFreshTotalsBeforeOpeningPodcast() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StatisticsLoading-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let now = Date(timeIntervalSince1970: 1_735_819_200)
        let feed = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Fresh statistics", episodes: [
            ParsedEpisode(identifier: "one", title: "One", publicationDate: now.addingTimeInterval(-86_400),
                media: ParsedMedia(url: "fixture://one", size: 1000, durationMilliseconds: 3_600_000)),
            ParsedEpisode(identifier: "two", title: "Two", publicationDate: now,
                media: ParsedMedia(url: "fixture://two", size: 1000, durationMilliseconds: 3_600_000))]),
            source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        try await store.updateEpisode(id: feed.episodes[0].id) { $0.userState.playState = .played }
        let formatter = StatisticsTextFormatter(locale: Locale(identifier: "en-US"), timeZone: TimeZone(secondsFromGMT: 0)!, now: now)
        let content = FeedStatisticsContentView(feedID: feed.id, detailed: false, store: store)
        var sizeChanges = 0
        content.onSizeChange = { sizeChanges += 1 }
        #expect(value("episodesStarted", in: content) == "…")
        await content.load(formatter: formatter).value
        #expect(value("episodesStarted", in: content) == "1 episode" && sizeChanges >= 1, "Loaded totals resize the container")
        #expect(element("statistics.episodesTotal", in: content, as: UIView.self) == nil)
        try await store.updateEpisode(id: feed.episodes[1].id) { $0.userState.playState = .played }
        // Source opening a detailed dialog starts a new read; it must not reuse
        // the existing information-view snapshot or mutate that view's totals.
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { host.dismiss(animated: false); window.isHidden = true; previous?.makeKey() }
        var opened = false
        let dialog = FeedStatisticsDialog.make(feedID: feed.id, title: feed.title, store: store, formatter: formatter) {
            #expect(host.presentedViewController == nil)
            opened = true
        }
        host.present(dialog, animated: false)
        try await waitUntil { value("episodesStarted", in: dialog.view) == "2 episodes" }
        dialog.view.layoutIfNeeded()
        #expect(value("durationTotal", in: dialog.view) == "2.0 hours")
        #expect(value("episodesStarted", in: content) == "1 episode")
        let body = try #require(element("statisticsDialogBody", in: dialog.view, as: UIView.self))
        let loaded = try #require(element("feedStatisticsContent", in: body, as: FeedStatisticsContentView.self))
        #expect(loaded.bounds.height >= loaded.sizeThatFits(loaded.bounds.size).height - 0.5, "Loaded cards are not clipped")
        #expect(body.bounds.height >= loaded.bounds.height, "Dialog body grows to fit loaded totals")
        try #require(element("statisticsOpenPodcast", in: dialog.view, as: UIButton.self)).sendActions(for: .touchUpInside)
        try await waitUntil { opened && host.presentedViewController == nil }
        try await store.close()
    }

    @Test func absentAndFailedReadsRetainSourcePlaceholdersWithoutErrorControls() async throws {
        enum Failure: Error { case denied }
        for fails in [false, true] {
            let content = FeedStatisticsContentView(feedID: 1, detailed: true) { _, _, _ in
                if fails { throw Failure.denied }; return nil
            }
            var errors: [String] = []
            content.onFailure = { errors.append($0) }
            await content.load().value
            #expect(errors == (fails ? ["denied"] : []))
            for id in FeedStatisticsCardsView.Card.allCases { #expect(value(id.rawValue, in: content) == "…") }
            #expect(content.subviews.count == 1)
        }
    }

}
