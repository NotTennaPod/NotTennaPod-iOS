import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Mounted Subscriptions/Archive screen and drawer: grid/list geometry for
/// every column setting, title toggle, counter pill, RTL, first-visit column default, overflow menus,
/// Sort/Counter dialogs, the immediate-apply filter sheet, the Archive screen and the drawer order.
@MainActor @Suite(.serialized)
struct SubscriptionsScreenViewTests {
    private func find<T: UIView>(_ id: String, in view: UIView, as type: T.Type = T.self) -> T? {
        if let match = view as? T, view.accessibilityIdentifier == id { return match }
        return view.subviews.lazy.compactMap { find(id, in: $0, as: type) }.first
    }
    private func all(_ prefix: String, in view: UIView) -> [UIView] {
        ((view.accessibilityIdentifier ?? "").hasPrefix(prefix) ? [view] : []) + view.subviews.flatMap { all(prefix, in: $0) }
    }
    /// Displayed feed ids in reading order (rows top to bottom, then along the reading direction).
    private func displayed(in view: UIView, rtl: Bool = false) -> [Int64] {
        all("subscriptionFeed-", in: view).sorted {
            abs($0.frame.minY - $1.frame.minY) > 0.5 ? $0.frame.minY < $1.frame.minY : (rtl ? $0.frame.minX > $1.frame.minX : $0.frame.minX < $1.frame.minX)
        }.compactMap { Int64(($0.accessibilityIdentifier ?? "").dropFirst("subscriptionFeed-".count)) }
    }
    private func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }
    private func tap(_ id: String, in view: UIView) throws {
        let control: UIControl = try #require(find(id, in: view), "\(id)")
        control.sendActions(for: .touchUpInside)
    }

    /// Feeds with NEW/unplayed/played episodes: counters NEW = [1: 0, 2: 3, 3: 1, 4: 0], titles out of id order.
    private func library() -> [LibraryFeed] {
        func episodes(_ feed: Int64, new: Int, unplayed: Int, played: Int) -> [LibraryEpisode] {
            var result: [LibraryEpisode] = []
            for (state, count) in [(EpisodePlayState.new, new), (.unplayed, unplayed), (.played, played)] {
                for _ in 0..<count {
                    var details = ParsedEpisode(); details.title = "E"
                    details.publicationDate = Date(timeIntervalSince1970: 1_700_000_000 + Double(feed * 1000 + Int64(result.count)))
                    var user = EpisodeUserState(); user.playState = state
                    result.append(LibraryEpisode(id: feed * 100 + Int64(result.count), details: details, userState: user))
                }
            }
            return result
        }
        let rows: [(Int64, String, Int, Int, Int)] = [(1, "Delta", 0, 2, 1), (2, "bravo", 3, 0, 0), (3, "Charlie", 1, 0, 3), (4, "alpha", 0, 0, 0)]
        var feeds = rows.map { id, title, new, unplayed, played in
            LibraryFeed(id: id, source: "fixture://subscriptions/\(id)", metadata: .init(format: .rss, title: title),
                        episodes: episodes(id, new: new, unplayed: unplayed, played: played))
        }
        feeds[2].lastUpdateFailed = true
        // A server library's podcast whose server refresh fails while this device's works: the same icon and words.
        feeds[3].serverRefresh = ServerRefreshStatus(lastAttempt: Date(timeIntervalSince1970: 1_700_000_000), label: "parser_exception")
        feeds[3].tags = ["Tech"]
        feeds[0].keepUpdated = false
        var archived = LibraryFeed(id: 9, source: "fixture://subscriptions/9", metadata: .init(format: .rss, title: "Archived one"),
                                   episodes: episodes(9, new: 2, unplayed: 0, played: 0))
        archived.subscriptionState = .archived
        return feeds + [archived]
    }

    private func run(size: CGSize = CGSize(width: 402, height: 874), rtl: Bool = false, bottomNavigation: Bool = true,
                     feeds: [LibraryFeed]? = nil, preferences: SubscriptionDisplayPreferences? = nil,
                     body: @MainActor (LibraryViewController, SubscriptionDisplayPreferenceStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SubscriptionsScreen-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let navigation = try NavigationPreferenceStore(file: root.appendingPathComponent("navigation.json"))
        var value = navigation.value
        value.defaultPage = "remember"; value.lastPage = NavigationDestination.subscriptions.rawValue; value.bottomNavigation = bottomNavigation
        try navigation.update(value)
        let store = try SubscriptionDisplayPreferenceStore(file: root.appendingPathComponent("subscriptions.json"))
        if let preferences { try store.update(preferences) }
        let snapshot = FeedLibrarySnapshot(feeds: feeds ?? library(), queue: [])
        let controller = LibraryViewController(library: nil, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil,
            mobileNetworkPreferences: nil, usage: nil, loadSnapshot: { snapshot })
        controller.subscriptionPreferences = store
        try await withViewTestWindow { host, _ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            defer {
                controller.presentedViewController?.dismiss(animated: false)
                controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent()
            }
            controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            controller.view.frame = CGRect(origin: .zero, size: size)
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            await controller.reloadLibrary()?.value
            controller.view.layoutIfNeeded()
            try await body(controller, store)
        }
    }
    /// Dialog rows dismiss their dialog themselves (animated); await that before the next presentation.
    private func dismissPresented(_ controller: LibraryViewController) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while controller.presentedViewController != nil || controller.presentedViewController?.isBeingDismissed == true,
              ContinuousClock.now < deadline {
            if let presented = controller.presentedViewController, !presented.isBeingDismissed { presented.dismiss(animated: false) }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.presentedViewController == nil)
    }

    @Test func firstVisitPersistsTheDeviceClassColumnDefault() async throws {
        try await run { controller, store in
            #expect(store.value.columns == 3, "402-point window: default 3 columns written on first visit")
            let grid = all("subscriptionFeed-", in: controller.view)
            #expect(Set(grid.map { round($0.frame.minY) }).count == 2, "4 feeds in 3 columns make two rows")
        }
        try await run(size: CGSize(width: 1032, height: 1376)) { _, store in
            #expect(store.value.columns == 5, "sw ≥ 600: default 5 columns")
        }
    }

    /// Default order COUNTER/SHOW_NEW: bravo(3), Charlie(1), then alpha and Delta by title; pill only when > 0.
    @Test(arguments: [false, true]) func gridCellsFollowSourceGeometry(rightToLeft: Bool) async throws {
        for columns in 2...5 {
            var preferences = SubscriptionDisplayPreferences(); preferences.columns = columns
            try await run(rtl: rightToLeft, preferences: preferences) { controller, _ in
                #expect(displayed(in: controller.view, rtl: rightToLeft) == [2, 3, 4, 1], "columns \(columns)")
                let cells = all("subscriptionFeed-", in: controller.view)
                let content = try #require(cells.first?.superview)
                let slot = content.bounds.width / CGFloat(columns)
                for cell in cells { #expect(near(cell.frame.width, slot - 2), "1-point divider on each side") }
                let first: UIControl = try #require(find("subscriptionFeed-2", in: controller.view))
                #expect(near(rightToLeft ? content.bounds.width - first.frame.maxX : first.frame.minX, 1))
                let pill: UILabel = try #require(find("subscriptionCounter-2", in: first))
                #expect(pill.text == "3" && !pill.isHidden)
                // Top-end of the cover, 8-point margin.
                let pillFrame = pill.convert(pill.bounds, to: first)
                #expect(rightToLeft ? pillFrame.minX < first.bounds.midX : pillFrame.maxX > first.bounds.midX)
                #expect(pillFrame.minY < first.bounds.height * 0.3)
                let quiet: UILabel = try #require(find("subscriptionCounter-4", in: controller.view))
                #expect(quiet.isHidden, "no pill at 0")
                // Titles off by default: grid cell is square (plus padding/divider).
                #expect(near(first.frame.height, first.frame.width), "columns \(columns)")
                #expect(first.accessibilityLabel == "bravo" && first.accessibilityValue == "3" && first.accessibilityTraits.contains(.button))
                let failed: UIControl = try #require(find("subscriptionFeed-3", in: controller.view))
                #expect(failed.accessibilityLabel == "Charlie, Last refresh failed. Tap to view details.")
                let serverFailed: UIControl = try #require(find("subscriptionFeed-4", in: controller.view))
                #expect(serverFailed.accessibilityLabel == "alpha, Last refresh failed. Tap to view details.")
                for (id, failing) in [(1, false), (2, false), (3, true), (4, true)] {
                    let cell: UIControl = try #require(find("subscriptionFeed-\(id)", in: controller.view))
                    let icon: UIImageView = try #require(find("subscriptionFailure-\(id)", in: cell))
                    #expect(icon.isHidden == !failing, "\(id)")
                    if failing {
                        // Bottom-end of the cover, inside the cell.
                        let frame = icon.convert(icon.bounds, to: cell)
                        #expect(cell.bounds.contains(frame) && frame.minY > cell.bounds.height / 2, "\(id)")
                        #expect(rightToLeft ? frame.midX < cell.bounds.midX : frame.midX > cell.bounds.midX, "\(id)")
                    }
                }
            }
        }
    }

    @Test func titleToggleAddsTwoLinesAndIsHiddenInListMode() async throws {
        try await run { controller, store in
            let before = try #require(find("subscriptionFeed-2", in: controller.view, as: UIControl.self)).frame.height
            try tap("subscriptionsMore", in: controller.view)
            let entries = all("subscriptions", in: controller.view).compactMap(\.accessibilityIdentifier)
            #expect(entries.contains("subscriptionsShowTitles"))
            let titles: UIControl = try #require(find("subscriptionsShowTitles", in: controller.view))
            #expect(titles.subviews.contains { ($0 as? PopupMenuAccessory)?.kind == .checkbox(false) })
            #expect(try #require(find("subscriptionsColumns", in: controller.view, as: UIControl.self)).subviews.contains { ($0 as? PopupMenuAccessory)?.kind == .submenu })
            try tap("subscriptionsShowTitles", in: controller.view); controller.view.layoutIfNeeded()
            #expect(store.value.showTitle)
            let after = try #require(find("subscriptionFeed-2", in: controller.view, as: UIControl.self)).frame.height
            #expect(near(after - before, SubscriptionGridCell.titleHeight(columns: 3)))
            // List mode through the columns submenu; Show titles disappears.
            try tap("subscriptionsMore", in: controller.view); try tap("subscriptionsColumns", in: controller.view)
            let checked: UIControl = try #require(find("subscriptionsColumns-3", in: controller.view))
            #expect(checked.accessibilityTraits.contains(.selected))
            #expect(find("subscriptionsColumnsMenuHeader", in: controller.view, as: UILabel.self)?.text == "Number of columns")
            #expect(checked.subviews.contains { ($0 as? PopupMenuAccessory)?.kind == .radio(true) })
            try tap("subscriptionsColumns-1", in: controller.view); controller.view.layoutIfNeeded()
            #expect(store.value.columns == 1)
            let row = try #require(find("subscriptionFeed-2", in: controller.view, as: SubscriptionListRow.self))
            #expect(near(row.frame.height, 72) && near(row.frame.minX, 0))
            try tap("subscriptionsMore", in: controller.view)
            #expect(find("subscriptionsShowTitles", in: controller.view, as: UIControl.self) == nil)
        }
    }

    @Test(arguments: [false, true]) func listRowsAndTabletTwoSpanList(rightToLeft: Bool) async throws {
        var preferences = SubscriptionDisplayPreferences(); preferences.columns = 1
        try await run(rtl: rightToLeft, preferences: preferences) { controller, _ in
            let row = try #require(find("subscriptionFeed-2", in: controller.view, as: SubscriptionListRow.self))
            let content = try #require(row.superview)
            #expect(near(row.frame.width, content.bounds.width))
            let counter: UILabel = try #require(find("subscriptionCounter-2", in: row))
            #expect(counter.text == "3")
            let cover = try #require(row.subviews.first)
            #expect(near(cover.frame.width, 56) && near(rightToLeft ? row.bounds.width - cover.frame.maxX : cover.frame.minX, 16))
            #expect(rightToLeft ? counter.frame.maxX < row.bounds.midX : counter.frame.minX > row.bounds.midX)
            // The server's failure shows the same icon at the row's end, clear of the title and counter.
            let serverFailed = try #require(find("subscriptionFeed-4", in: controller.view, as: SubscriptionListRow.self))
            let icon: UIImageView = try #require(find("subscriptionFailure-4", in: serverFailed))
            #expect(!icon.isHidden && serverFailed.bounds.contains(icon.frame))
            #expect(rightToLeft ? icon.frame.maxX < serverFailed.bounds.midX : icon.frame.minX > serverFailed.bounds.midX)
            #expect(serverFailed.accessibilityLabel == "alpha, Last refresh failed. Tap to view details.")
        }
        try await run(size: CGSize(width: 1032, height: 1376), rtl: rightToLeft, preferences: preferences) { controller, _ in
            let rows = all("subscriptionFeed-", in: controller.view)
            let content = try #require(rows.first?.superview)
            for row in rows { #expect(near(row.frame.width, content.bounds.width / 2), "2-span list at sw ≥ 600") }
            #expect(displayed(in: controller.view, rtl: rightToLeft) == [2, 3, 4, 1])
        }
    }

    /// A subscription whose metadata has not arrived yet (no title) says which podcast it is by its address, as
    /// Android's `getHumanReadableIdentifier` does, in the grid (title and cover fallback), the list and to VoiceOver.
    @Test(arguments: [3, 1]) func anUnnamedSubscriptionShowsItsAddress(columns: Int) async throws {
        var feeds = library()
        feeds[1] = LibraryFeed(id: 2, source: "fixture://subscriptions/2", metadata: .init(format: .rss, title: nil), episodes: feeds[1].episodes)
        var preferences = SubscriptionDisplayPreferences(); preferences.columns = columns; preferences.showTitle = true
        try await run(feeds: feeds, preferences: preferences) { controller, _ in
            let cell = try #require(find("subscriptionFeed-2", in: controller.view, as: UIControl.self))
            #expect(cell.accessibilityLabel == "fixture://subscriptions/2")
            let labels = all("", in: cell).compactMap { ($0 as? UILabel)?.text }
            #expect(labels.contains("fixture://subscriptions/2"), "\(labels)")
        }
    }

    @Test func overflowSortCounterAndPersistence() async throws {
        try await run { controller, store in
            try tap("subscriptionsMore", in: controller.view)
            let menu: UIView = try #require(find("subscriptionsMenu", in: controller.view))
            let order = all("subscriptions", in: menu).filter { $0 is UIControl && $0 !== menu }
                .sorted { $0.frame.minY < $1.frame.minY }.compactMap(\.accessibilityIdentifier)
            // Android 3.12.1 runtime order: Refresh (menuCategory="container") is last.
            #expect(order == ["subscriptionsFilter", "subscriptionsSort", "subscriptionsCounter",
                              "subscriptionsColumns", "subscriptionsShowTitles", "subscriptionsArchive", "subscriptionsRefresh"])
            try tap("subscriptionsSort", in: controller.view)
            let sort = try #require(controller.presentedViewController)
            let checked: UIControl = try #require(find("subscriptionsSortDialog-0", in: sort.view))
            #expect(checked.accessibilityTraits.contains(.selected))
            try tap("subscriptionsSortDialog-1", in: sort.view)
            try await dismissPresented(controller); controller.view.layoutIfNeeded()
            #expect(store.value.feedOrder == "1")
            #expect(displayed(in: controller.view) == [4, 2, 3, 1], "alphabetical, case-insensitive")
            try tap("subscriptionsMore", in: controller.view); try tap("subscriptionsCounter", in: controller.view)
            let counter = try #require(controller.presentedViewController)
            try tap("subscriptionsCounterDialog-2", in: counter.view)
            try await dismissPresented(controller); controller.view.layoutIfNeeded()
            #expect(store.value.feedCounter == "2")
            let pill: UILabel = try #require(find("subscriptionCounter-1", in: controller.view))
            #expect(pill.text == "2" && !pill.isHidden, "unplayed counter")
            try tap("subscriptionsMore", in: controller.view); try tap("subscriptionsSort", in: controller.view)
            try tap("subscriptionsSortDialog-3", in: try #require(controller.presentedViewController).view)
            try await dismissPresented(controller); controller.view.layoutIfNeeded()
            #expect(displayed(in: controller.view) == [3, 1, 4, 2], "most played, ties by title")
        }
    }

    @Test func filterSheetAppliesImmediatelyResetsAndConfirms() async throws {
        try await run(bottomNavigation: true) { controller, store in
            try tap("subscriptionsMore", in: controller.view); try tap("subscriptionsFilter", in: controller.view)
            let sheet = try #require(controller.presentedViewController as? FeedFilterController)
            sheet.view.layoutIfNeeded()
            let counter: UIControl = try #require(find("subscriptionsFilter_counter_greater_zero", in: sheet.view))
            let kept: UIControl = try #require(find("subscriptionsFilter_enabled_updates", in: sheet.view))
            let notKept: UIControl = try #require(find("subscriptionsFilter_disabled_updates", in: sheet.view))
            #expect(near(counter.frame.width, kept.frame.width + notKept.frame.width - 1), "single button fills its row")
            counter.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
            #expect(store.value.subscriptionsFilter == "counter_greater_zero")
            #expect(displayed(in: controller.view) == [2, 3], "applied behind the sheet")
            #expect(find("subscriptionsFiltered", in: controller.view, as: UIButton.self) != nil)
            kept.sendActions(for: .touchUpInside); notKept.sendActions(for: .touchUpInside); controller.view.layoutIfNeeded()
            #expect(kept.isSelected == false && notKept.isSelected, "single selection per row")
            #expect(store.value.subscriptionsFilter == SubscriptionsFilter.serialized(["counter_greater_zero", "disabled_updates"]))
            #expect(displayed(in: controller.view).isEmpty)
            #expect(find("subscriptionsEmptyTitle", in: controller.view, as: UILabel.self)?.text == "No subscriptions")
            try tap("subscriptionsFilterReset", in: sheet.view); controller.view.layoutIfNeeded()
            #expect(store.value.subscriptionsFilter == "" && controller.presentedViewController === sheet, "Reset keeps the sheet")
            #expect(find("subscriptionsFiltered", in: controller.view, as: UIButton.self) == nil)
            kept.sendActions(for: .touchUpInside)
            try tap("subscriptionsFilterConfirm", in: sheet.view)
            try await dismissPresented(controller); controller.view.layoutIfNeeded()
            #expect(store.value.subscriptionsFilter == "enabled_updates")
            #expect(displayed(in: controller.view) == [2, 3, 4])
            // The Filtered bar opens the sheet with the saved selection.
            try tap("subscriptionsFiltered", in: controller.view)
            let reopened = try #require(controller.presentedViewController as? FeedFilterController)
            reopened.view.layoutIfNeeded()
            #expect(try #require(find("subscriptionsFilter_enabled_updates", in: reopened.view, as: UIControl.self)).isSelected)
        }
    }

    @Test func archiveScreenShowsArchivedFeedsWithReducedMenuAndNoCounters() async throws {
        try await run { controller, _ in
            try tap("subscriptionsMore", in: controller.view); try tap("subscriptionsArchive", in: controller.view)
            controller.view.layoutIfNeeded()
            #expect(find("screenTitle", in: controller.view, as: UILabel.self)?.text == "Archive")
            #expect(displayed(in: controller.view) == [9])
            #expect(try #require(find("subscriptionCounter-9", in: controller.view, as: UILabel.self)).isHidden)
            #expect(find("subscriptionsAdd", in: controller.view, as: UIButton.self) == nil)
            #expect(find("toolbarBack", in: controller.view, as: UIControl.self) != nil)
            try tap("subscriptionsMore", in: controller.view)
            let menu: UIView = try #require(find("subscriptionsMenu", in: controller.view))
            let order = all("subscriptions", in: menu).filter { $0 is UIControl && $0 !== menu }
                .sorted { $0.frame.minY < $1.frame.minY }.compactMap(\.accessibilityIdentifier)
            #expect(order == ["subscriptionsSort", "subscriptionsColumns", "subscriptionsShowTitles"])
        }
        let empty = library().filter { $0.subscriptionState != .archived }
        try await run(feeds: empty) { controller, _ in
            try tap("subscriptionsMore", in: controller.view); try tap("subscriptionsArchive", in: controller.view)
            controller.view.layoutIfNeeded()
            #expect(find("subscriptionsEmptyTitle", in: controller.view, as: UILabel.self)?.text == "Nothing archived")
        }
    }

    /// The drawer uses the same order/counter/filter: root feeds, then tag folders with summed counters.
    @Test func drawerMatchesSubscriptionsOrderCountersAndFolders() async throws {
        var preferences = SubscriptionDisplayPreferences(); preferences.subscriptionsFilter = "enabled_updates"
        try await run(bottomNavigation: false, preferences: preferences) { controller, store in
            let drawer: UIView = try #require(find("navigationDrawer", in: controller.view))
            let rows = all("drawer-", in: drawer).filter { $0.accessibilityIdentifier?.hasPrefix("drawer-feed-") == true || $0.accessibilityIdentifier?.hasPrefix("drawer-folder-") == true }
                .sorted { $0.frame.minY < $1.frame.minY }.compactMap(\.accessibilityIdentifier)
            #expect(rows == ["drawer-feed-2", "drawer-feed-3", "drawer-folder-Tech"], "Delta is filtered out; alpha only in Tech")
            let filtered: UIControl = try #require(find("drawerFiltered", in: drawer))
            let info = try #require(filtered.subviews.first { $0 is UIImageView })
            #expect(near(info.frame.minX, 16) && info.frame.maxX < filtered.bounds.width, "info icon at the start")
            #expect(find("drawer-SubscriptionFragment", in: drawer, as: UIControl.self)?.accessibilityValue == "4", "entry counter: all subscribed NEW")
            try tap("drawer-folder-Tech", in: drawer)
            #expect(store.value.openFolders == ["Tech"])
            let refreshed: UIView = try #require(find("navigationDrawer", in: controller.view))
            #expect(find("drawer-folder-feed-4", in: refreshed, as: UIControl.self) != nil)
        }
    }
}
