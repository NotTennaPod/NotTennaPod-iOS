import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Mounted screens: Inbox, Episodes, Favorites and History order, toolbars, sort sheet, Remove all and
/// Clear history.
@MainActor @Suite(.serialized)
struct EpisodeListMenusViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if view.accessibilityIdentifier == id, let result = view as? T { return result }
        return view.subviews.lazy.compactMap { find(id, in: $0, as: type) }.first
    }
    private func wait(_ condition: @MainActor () async throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while try await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await condition(), sourceLocation: sourceLocation)
    }

    struct Fixture {
        let root: URL, store: FeedLibraryStore, lists: EpisodeListPreferenceStore
        let ids: [String: Int64]
    }
    /// Two feeds. Titles encode the facts: A1 (new, 3 min, newest), A2 (new, 1 min), B1 (new, 2 min, oldest),
    /// A3 (favorite, 5 min), B2 (favorite, 4 min, newer), A4 (history, finished last), B3 (history, earlier).
    private func withFixture(_ body: @MainActor (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EpisodeListMenusView-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        func episode(_ title: String, hours: Double, minutes: Int32) -> ParsedEpisode {
            ParsedEpisode(identifier: title, title: title, publicationDate: base.addingTimeInterval(hours * 3600),
                media: .init(url: "https://example.test/\(title).mp3", size: 1, durationMilliseconds: minutes * 60_000))
        }
        var ids: [String: Int64] = [:]
        for (name, episodes) in [("A", [episode("A1", hours: 10, minutes: 3), episode("A2", hours: 5, minutes: 1),
                                         episode("A3", hours: 1, minutes: 5), episode("A4", hours: 0.5, minutes: 6)]),
                                 ("B", [episode("B1", hours: 2, minutes: 2), episode("B2", hours: 3, minutes: 4), episode("B3", hours: 0.2, minutes: 7)])] {
            let source = "https://example.test/\(name)"
            let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Feed \(name)", episodes: episodes), source: source,
                responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil))
            for item in feed.episodes { ids[item.details.title!] = item.id }
        }
        for (title, change) in [("A1", "new"), ("A2", "new"), ("B1", "new"), ("A3", "favorite"), ("B2", "favorite"),
                                ("A4", "history2"), ("B3", "history1")] {
            try await store.updateEpisode(id: ids[title]!) {
                switch change {
                case "new": $0.userState.playState = .new
                case "favorite": $0.userState.playState = .played; $0.userState.isFavorite = true
                case "history2": $0.userState.playState = .played; $0.userState.lastPlayedHistoryMilliseconds = 1_790_000_200_000
                default: $0.userState.playState = .played; $0.userState.lastPlayedHistoryMilliseconds = 1_790_000_100_000
                }
            }
        }
        let lists = try EpisodeListPreferenceStore(file: root.appendingPathComponent("lists.json"))
        do { try await body(Fixture(root: root, store: store, lists: lists, ids: ids)) }
        catch { try? await store.close(); throw error }
        try await store.close()
    }
    /// Mounts the library on one screen and runs `body` with a tap helper and the visible row order.
    private func withScreen(_ destination: NavigationDestination, _ fixture: Fixture, lists: EpisodeListPreferenceStore? = nil,
                            _ body: @MainActor (LibraryViewController, @MainActor (String, UIView?) throws -> Void, @MainActor () -> [String]) async throws -> Void) async throws {
        let navigation = try NavigationPreferenceStore(file: fixture.root.appendingPathComponent("navigation-\(UUID()).json"))
        var value = navigation.value; value.defaultPage = destination.rawValue; try navigation.update(value)
        let controller = LibraryViewController(library: fixture.store, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil, mobileNetworkPreferences: nil, usage: nil)
        controller.episodeListPreferences = lists ?? fixture.lists
        let titles = Dictionary(uniqueKeysWithValues: fixture.ids.map { ($0.value, $0.key) })
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer { controller.dismiss(animated: false); controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            controller.view.frame = host.view.bounds
            await controller.reloadLibrary()?.value; controller.view.layoutIfNeeded()
            let tap: @MainActor (String, UIView?) throws -> Void = { id, view in
                controller.view.layoutIfNeeded()
                let control: UIControl = try #require(self.find(id, in: view ?? controller.view), "Missing \(id)")
                control.sendActions(for: .touchUpInside)
                controller.view.layoutIfNeeded()
            }
            let order: @MainActor () -> [String] = {
                controller.view.layoutIfNeeded()
                return fixture.ids.values.compactMap { id -> (CGFloat, String)? in
                    guard let row = self.find("episode-\(id)", in: controller.view, as: UIButton.self) else { return nil }
                    return (row.convert(row.bounds, to: controller.view).minY, titles[id]!)
                }.sorted { $0.0 < $1.0 }.map(\.1)
            }
            try await body(controller, tap, order)
        }
    }
    private func menuOrder(_ ids: [String], in view: UIView) -> [String] {
        ids.compactMap { id in find(id, in: view, as: UIButton.self).map { (id, $0.convert($0.bounds, to: view).minY) } }
            .sorted { $0.1 < $1.1 }.map(\.0)
    }

    @Test func inboxSortsRemovesAllWithPromptAndRemembersBoth() async throws {
        try await withFixture { fixture in
            try await withScreen(.inbox, fixture) { controller, tap, order in
                #expect(order() == ["A1", "A2", "B1"], "Newest first by default")
                #expect(find("inboxSearch", in: controller.view, as: UIButton.self) != nil)
                try tap("inboxMore", nil)
                #expect(menuOrder(["inboxSort", "inboxRefresh", "inboxRemoveAll"], in: controller.view) == ["inboxSort", "inboxRefresh", "inboxRemoveAll"])
                try tap("inboxSort", nil)
                try await wait { controller.presentedViewController is EpisodeListSortController && controller.presentedViewController?.isBeingPresented == false }
                let sheet = try #require(controller.presentedViewController)
                let date = try #require(find("episodeListSort-date", in: sheet.view, as: UIButton.self))
                let duration = try #require(find("episodeListSort-duration", in: sheet.view, as: UIButton.self))
                #expect(duration.title(for: .normal) == "Duration" && date.title(for: .normal) == "Date\u{a0}▼")
                #expect(duration.frame.minY == date.frame.minY && (duration.frame.minX < date.frame.minX) == (sheet.view.effectiveUserInterfaceLayoutDirection == .leftToRight))
                try tap("episodeListSort-date", sheet.view)
                #expect(date.title(for: .normal) == "Date\u{a0}▲" && fixture.lists.value.inbox == .dateOldest)
                sheet.dismiss(animated: false); try await wait { controller.presentedViewController == nil }
                #expect(order() == ["B1", "A2", "A1"], "Oldest first after the sort")
                try tap("inboxMore", nil); try tap("inboxSort", nil)
                try await wait { controller.presentedViewController is EpisodeListSortController && controller.presentedViewController?.isBeingPresented == false }
                try tap("episodeListSort-duration", controller.presentedViewController!.view)
                controller.presentedViewController?.dismiss(animated: false); try await wait { controller.presentedViewController == nil }
                #expect(order() == ["A2", "B1", "A1"] && fixture.lists.value.inbox == .durationShortest, "Shortest first")

                // Remove all: Cancel changes nothing; Confirm with "Do not show again" clears the Inbox and remembers.
                try tap("inboxMore", nil); try tap("inboxRemoveAll", nil)
                try await wait { controller.presentedViewController is SourceMessageController && controller.presentedViewController?.isBeingPresented == false }
                let prompt = try #require(controller.presentedViewController)
                #expect(find("sourceMessageTitle", in: prompt.view, as: UILabel.self)?.text == "Remove all from inbox")
                try tap("inboxRemoveAllCancel", prompt.view)
                try await wait { controller.presentedViewController == nil }
                #expect(order().count == 3)
                try tap("inboxMore", nil); try tap("inboxRemoveAll", nil)
                try await wait { controller.presentedViewController is SourceMessageController && controller.presentedViewController?.isBeingPresented == false }
                let again = try #require(controller.presentedViewController)
                try tap("inboxRemoveAllDoNotShow", again.view); try tap("inboxRemoveAllConfirm", again.view)
                try await wait { controller.presentedViewController == nil && order().isEmpty }
                #expect(fixture.lists.value.doNotPromptRemoveAllFromInbox)
                #expect(find("inboxEmptyTitle", in: controller.view, as: UILabel.self)?.text == "No episodes in the inbox")
                try await wait { self.find("applicationNotice", in: controller.view.window!, as: UILabel.self)?.text == "Removed all from inbox" }
                let a1 = try #require(try await fixture.store.episode(id: fixture.ids["A1"]!))
                #expect(a1.userState.playState == .unplayed)
            }
            // Sort and "Do not show again" survive a new screen (and its stored file).
            let reopened = try EpisodeListPreferenceStore(file: fixture.root.appendingPathComponent("lists.json"))
            #expect(reopened.value.inbox == .durationShortest && reopened.value.doNotPromptRemoveAllFromInbox)
        }
    }

    @Test func favoritesFollowTheEpisodesSortAndOfferOnlyRefresh() async throws {
        try await withFixture { fixture in
            try await withScreen(.favorites, fixture) { controller, tap, order in
                #expect(order() == ["B2", "A3"], "Newest first")
                #expect(find("favoritesSearch", in: controller.view, as: UIButton.self) != nil)
                try tap("favoritesMore", nil)
                #expect(find("favoritesRefresh", in: controller.view, as: UIButton.self) != nil)
                #expect(find("favoritesSort", in: controller.view, as: UIButton.self) == nil)
            }
            try fixture.lists.update { $0.episodesSort = EpisodeListSort.durationLongest.rawValue }
            try await withScreen(.favorites, fixture) { _, _, order in
                #expect(order() == ["A3", "B2"], "Favorites follow the Episodes sort")
            }
            try await withScreen(.episodes, fixture) { controller, tap, order in
                #expect(Array(order().prefix(2)) == ["B3", "A4"], "Episodes longest first")
                try tap("allEpisodesMore", nil)
                #expect(menuOrder(["allEpisodesSort", "allEpisodesRefresh"], in: controller.view) == ["allEpisodesSort", "allEpisodesRefresh"])
            }
        }
    }

    @Test func historyOrdersByCompletionAndClearsOnlyAfterConfirmation() async throws {
        try await withFixture { fixture in
            try await withScreen(.history, fixture) { controller, tap, order in
                #expect(order() == ["A4", "B3"], "Most recently finished first")
                try tap("historyClear", nil)
                try await wait { controller.presentedViewController is SourceMessageController && controller.presentedViewController?.isBeingPresented == false }
                try tap("historyClearCancel", controller.presentedViewController!.view)
                try await wait { controller.presentedViewController == nil }
                #expect(order().count == 2)
                try tap("historyClear", nil)
                try await wait { controller.presentedViewController is SourceMessageController && controller.presentedViewController?.isBeingPresented == false }
                let prompt = try #require(controller.presentedViewController)
                #expect(find("sourceMessage", in: prompt.view, as: UILabel.self)?.text == "This will clear the entire playback history. Are you sure you want to proceed?")
                try tap("historyClearConfirm", prompt.view)
                try await wait { controller.presentedViewController == nil && order().isEmpty }
                #expect(find("historyClear", in: controller.view, as: UIButton.self) == nil, "Clear history hidden when empty")
                #expect(find("historyEmptyTitle", in: controller.view, as: UILabel.self)?.text == "No history")
                let a4 = try #require(try await fixture.store.episode(id: fixture.ids["A4"]!))
                #expect(a4.userState.lastPlayedHistoryMilliseconds == nil && a4.userState.playState == .played)
            }
        }
    }

    @Test(arguments: [NavigationDestination.favorites, .history])
    func favoritesAndHistoryRowsHaveContextMenuAndMultiSelect(_ destination: NavigationDestination) async throws {
        try await withFixture { fixture in
            try await withScreen(destination, fixture) { controller, tap, order in
                let first = try #require(order().first)
                let button = try #require(find("episode-\(fixture.ids[first]!)", in: controller.view, as: UIButton.self))
                let row = try #require(button.superview as? EpisodeRowView)
                row.contextMenu?(row, CGPoint(x: 0.4, y: 0.5))
                try await wait { controller.presentedViewController != nil && controller.presentedViewController?.isBeingPresented == false }
                let menu = try #require(controller.presentedViewController)
                #expect(find("skipEpisode", in: menu.view, as: UIButton.self) == nil, "No Skip in list menus")
                try tap("multiSelect", menu.view)
                try await wait { controller.feedSelection.active && controller.presentedViewController == nil }
                #expect(controller.feedSelection.ids == [fixture.ids[first]!])
            }
        }
    }
}
