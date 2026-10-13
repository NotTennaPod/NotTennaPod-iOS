import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Mounted: the Statistics tab bar (Subscriptions, Years, Downloads), the toolbar menu per tab,
/// the Years and Downloads pages against the independent oracle (`TestSupport/Data/statistics-tabs`),
/// tab retention across the feed dialog and resizing, a new screen on Subscriptions, RTL, and Reset
/// from Years. The library is the oracle's Android database through the database import, with its
/// `download_inputs` re-marked as iOS downloads (the import brings them in as not downloaded).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct StatisticsTabsViewTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../TestSupport/Data/statistics-tabs").standardized
    static let expected: [String: Any] = {
        let data = try! Data(contentsOf: fixtures.appendingPathComponent("expected/statistics-tabs.json"))
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()
    static var main: [String: Any] { (expected["databases"] as! [String: Any])["main"] as! [String: Any] }
    static var years: [String: Any] { main["years"] as! [String: Any] }
    static var downloads: [String: Any] { main["downloads"] as! [String: Any] }

    private func element<T: UIView>(_ id: String, in view: UIView, as: T.Type = T.self) -> T? {
        if let match = view as? T, view.accessibilityIdentifier == id { return match }
        return view.subviews.lazy.compactMap { element(id, in: $0, as: T.self) }.first
    }
    private func elements(prefix: String, in view: UIView) -> [UIView] {
        var result: [UIView] = []
        if view.accessibilityIdentifier?.hasPrefix(prefix) == true { result.append(view) }
        for sub in view.subviews { result += elements(prefix: prefix, in: sub) }
        return result
    }
    private func wait(_ stage: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate(), Comment(rawValue: stage))
    }

    struct Fixture {
        let folder: URL
        let store: FeedLibraryStore
        let controller: LibraryViewController
    }

    private func fixture(database: String = "statistics.db") async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("M28Tabs-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let restored = try AndroidDatabaseRestore.read(Self.fixtures.appendingPathComponent(database), staging: folder.appendingPathComponent("s"))
        let store = try FeedLibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        try await store.installRestoredLibrary(restored, carrying: try await store.restoreCarryOver())
        for input in Self.downloads["download_inputs"] as! [[String: Any]] where database == "statistics.db" {
            let id = (input["item_id"] as! NSNumber).int64Value, size = (input["filesize"] as! NSNumber).int64Value
            try await store.updateEpisode(id: id) {
                $0.userState.isDownloaded = true; $0.userState.localFileURL = "/fixture/\(id).mp3"
                $0.userState.downloadDate = Date(timeIntervalSince1970: 1_788_000_000); $0.details.media?.size = size
            }
        }
        let navigation = try NavigationPreferenceStore(file: folder.appendingPathComponent("navigation.json"))
        var value = navigation.value; value.defaultPage = NavigationDestination.statistics.rawValue; try navigation.update(value)
        let prefs = try StatisticsPreferenceStore(file: folder.appendingPathComponent("statistics.json"))
        let controller = LibraryViewController(library: store, startupError: nil, downloads: nil, playback: nil,
            timeDisplayPreferences: nil, navigationPreferences: navigation, speedPreferences: nil,
            mobileNetworkPreferences: nil, usage: nil, statisticsPreferences: prefs)
        return Fixture(folder: folder, store: store, controller: controller)
    }

    private func mounted(_ fixture: Fixture, rtl: Bool = false, _ body: @MainActor (ViewTestWindowHost, LibraryViewController) async throws -> Void) async throws {
        let controller = fixture.controller
        try await withViewTestWindow { host, _ in
            if rtl {
                host.traitOverrides.layoutDirection = .rightToLeft
                controller.view.semanticContentAttribute = .forceRightToLeft
            }
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent: host)
            controller.view.frame = host.view.bounds; controller.view.layoutIfNeeded()
            defer {
                controller.presentedViewController?.dismiss(animated: false)
                controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent()
                host.traitOverrides.remove(UITraitLayoutDirection.self)
            }
            try await body(host, controller)
        }
        try await fixture.store.close()
        try? FileManager.default.removeItem(at: fixture.folder)
    }

    private func pager(_ controller: LibraryViewController) throws -> StatisticsPagerView {
        try #require(element("statisticsPager", in: controller.view, as: StatisticsPagerView.self))
    }
    private func tab(_ name: String, _ controller: LibraryViewController) throws -> UIButton {
        try #require(element("statisticsTab-" + name, in: controller.view, as: UIButton.self))
    }
    private func menu(_ controller: LibraryViewController) -> [String] {
        ["statisticsFilter", "statisticsMore"].filter { element($0, in: controller.view, as: UIButton.self) != nil }
    }
    private func open(_ name: String, index: Int, _ controller: LibraryViewController) async throws {
        try tab(name, controller).sendActions(for: .touchUpInside)
        try await wait("\(name) settled") {
            (try? pager(controller))?.selected == index && controller.statisticsTab.rawValue == index
                && (try? pager(controller))?.pages.isDecelerating == false
        }
        controller.view.layoutIfNeeded()
    }
    private func rows(_ prefix: String, _ controller: LibraryViewController) -> [UIView] {
        elements(prefix: prefix, in: controller.view).sorted { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }
    }
    /// Visible to a person: inside the window and not covered by the tab strip.
    private func visible(_ view: UIView, in controller: LibraryViewController) throws -> Bool {
        let frame = view.convert(view.bounds, to: controller.view)
        let pages = try pager(controller).pages
        let area = pages.convert(pages.bounds, to: controller.view)
        return area.insetBy(dx: -0.5, dy: -0.5).contains(frame)
    }

    @Test func tabsMenusAndPagesMatchSourceAndOracle() async throws {
        try await mounted(try await fixture()) { _, controller in
            try await wait("subscriptions loaded") { element("statisticsTotal", in: controller.view, as: UILabel.self)?.text != nil }
            let pager = try pager(controller)
            // Tab bar under the toolbar: three equal tabs in source order and wording.
            let tabs = try ["subscriptions", "years", "downloads"].map { try tab($0, controller) }
            #expect(tabs.map { $0.configuration?.title } == ["Subscriptions", "Years", "Downloads"])
            #expect(tabs[0].frame.minX < tabs[1].frame.minX && tabs[1].frame.minX < tabs[2].frame.minX)
            #expect(Set(tabs.map { Int($0.frame.width.rounded()) }).count == 1)
            for button in tabs {
                let label = try #require(button.titleLabel)
                #expect(label.intrinsicContentSize.width <= button.bounds.width, "\(button.configuration?.title ?? "") not clipped")
            }
            let toolbar = try #require(element("screenTitle", in: controller.view, as: UILabel.self))
            #expect(toolbar.text == "Statistics")
            let strip = pager.strip.convert(pager.strip.bounds, to: controller.view)
            #expect(strip.minY >= toolbar.convert(toolbar.bounds, to: controller.view).maxY - 1, "tab bar below the toolbar")
            #expect(tabs[0].accessibilityTraits.contains(.selected) && !tabs[1].accessibilityTraits.contains(.selected))
            #expect(menu(controller) == ["statisticsFilter", "statisticsMore"], "Subscriptions: Filter and Reset")

            // Years: oracle values, newest first, not actionable; the chart fits and is proportional.
            try await open("years", index: 1, controller)
            #expect(menu(controller) == ["statisticsMore"], "Years: Reset only")
            #expect(tabs[1].accessibilityTraits.contains(.selected))
            try await wait("years loaded") { element("yearsStatistics", in: controller.view, as: YearsStatisticsView.self) != nil }
            let expectedRows = (Self.years["year_rows"] as! [[String: Any]]).map {
                "\(($0["year"] as! NSNumber).intValue), \($0["hours_text"] as! String)"
            }
            let yearRows = rows("yearStatistics-", controller)
            #expect(yearRows.map { $0.accessibilityLabel ?? "" } == expectedRows)
            #expect(expectedRows == ["2026, 1.3 hours", "2025, 15.3 hours", "2024, 4.0 hours", "2022, 3.3 hours"])
            for row in yearRows { #expect(!(row is UIControl) && !row.accessibilityTraits.contains(.button), "year rows are not actionable") }
            #expect(try visible(try #require(yearRows.first), in: controller), "newest year visible below the chart")
            #expect(element("yearsStatisticsCaption", in: controller.view, as: UILabel.self)?.text == "Time played per month")
            let chart = try #require(element("yearsStatisticsChart", in: controller.view, as: YearsBarChartView.self))
            #expect(try visible(chart, in: controller))
            // The chart spans the Years page (not the window: on the Duo the navigation rail shares it).
            let page = try #require(element("yearsStatistics", in: controller.view, as: YearsStatisticsView.self))
            #expect(abs(chart.bounds.height - 200) <= 1 && chart.bounds.width >= page.bounds.width - 40,
                    "chart \(chart.bounds.size) page \(page.bounds.size)")
            let bars = chart.layout.bars, oracleBars = (Self.years["chart"] as! [String: Any])["bars"] as! [[String: Any]]
            #expect(bars.count == oracleBars.count)
            for (bar, oracle) in zip(bars, oracleBars) {
                #expect(abs(Double(bar.heightFraction) - (oracle["height_fraction"] as! NSNumber).doubleValue) < 0.001)
                #expect(bar.purple == (oracle["color"] as? String == "purple"))
                // Drawn height is the fraction of the bar area: visibly proportional.
                #expect(abs(Double(chart.layout.barAreaHeight - bar.top) - Double(bar.heightFraction) * Double(chart.layout.barAreaHeight)) < 0.5)
            }
            #expect(chart.layout.yearLabels.map(\.text) == ["2023", "2024", "2025", "2026"])
            #expect(chart.layout.gridLines.map(\.label) == ["10", "5"])

            // Downloads: oracle rows, order, texts, chips and header; no toolbar action at all.
            try await open("downloads", index: 2, controller)
            #expect(menu(controller).isEmpty, "Downloads: no menu")
            try await wait("downloads loaded") { element("downloadStatisticsTotal", in: controller.view, as: UILabel.self) != nil }
            #expect(element("downloadStatisticsTotal", in: controller.view, as: UILabel.self)?.text == Self.downloads["header_value_text"] as? String)
            #expect(element("downloadStatisticsCaption", in: controller.view, as: UILabel.self)?.text == Self.downloads["header_caption"] as? String)
            let oracleRows = Self.downloads["rows"] as! [[String: Any]]
            let downloadRows = rows("downloadStatisticsFeed-", controller)
            #expect(downloadRows.map { $0.accessibilityIdentifier ?? "" } == oracleRows.map { "downloadStatisticsFeed-\(($0["feed_id"] as! NSNumber).int64Value)" })
            #expect(downloadRows.map { $0.accessibilityLabel ?? "" } == oracleRows.map { "\($0["title"] as! String), \($0["value_text"] as! String)" })
            for oracle in oracleRows {
                let id = (oracle["feed_id"] as! NSNumber).int64Value
                let chip = try #require(element("downloadStatisticsChip-\(id)", in: controller.view, as: UILabel.self))
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                chip.textColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                let hex = String(format: "#FF%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
                #expect(hex == oracle["chip_color"] as? String, "chip \(id)")
            }

            // Row → feed statistics dialog → OK returns to Downloads.
            let row = try #require(downloadRows.first as? UIControl)
            row.sendActions(for: .touchUpInside)
            try await wait("feed dialog") { (controller.presentedViewController as? SourceMessageController)?.isBeingPresented == false }
            let dialog = try #require(controller.presentedViewController as? SourceMessageController)
            #expect(element("sourceMessageTitle", in: dialog.view, as: UILabel.self)?.text == "My Beta")
            #expect(element("statisticsOpenPodcast", in: dialog.view, as: UIButton.self)?.title(for: .normal) == "Open podcast")
            try #require(element("statisticsOK", in: dialog.view, as: UIButton.self)).sendActions(for: .touchUpInside)
            try await wait("dialog dismissed") { controller.presentedViewController == nil }
            #expect(try self.pager(controller).selected == 2 && menu(controller).isEmpty, "still Downloads after the dialog")

            // Swiping (settled page offset) back to Years selects it and its menu.
            let pages = pager.pages
            pages.setContentOffset(CGPoint(x: pages.bounds.width, y: 0), animated: true)
            try await wait("swipe settled on Years") { controller.statisticsTab == .years }
            #expect(menu(controller) == ["statisticsMore"])
        }
    }

    @Test func tabAndMenuSurviveResizeAndANewScreenOpensOnSubscriptions() async throws {
        try await mounted(try await fixture()) { host, controller in
            try await wait("subscriptions loaded") { element("statisticsTotal", in: controller.view, as: UILabel.self)?.text != nil }
            try await open("years", index: 1, controller)
            let original = host.view.bounds
            // Phone portrait/landscape, iPad and Duo-like widths: the tab and its menu stay; nothing is clipped.
            for size in [CGSize(width: 874, height: 402), CGSize(width: 1210, height: 834), CGSize(width: 540, height: 720), original.size] {
                controller.view.frame = CGRect(origin: .zero, size: size)
                controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                let pager = try pager(controller)
                #expect(pager.selected == 1 && controller.statisticsTab == .years, "\(size)")
                #expect(abs(pager.pages.contentOffset.x - pager.pages.bounds.width) < 1, "Years page shown at \(size)")
                #expect(menu(controller) == ["statisticsMore"], "menu matches the tab at \(size)")
                for name in ["subscriptions", "years", "downloads"] {
                    let button = try tab(name, controller)
                    #expect(button.titleLabel!.intrinsicContentSize.width <= button.bounds.width, "\(name) at \(size)")
                    #expect(controller.view.bounds.contains(button.convert(button.bounds, to: controller.view)))
                }
                // A short landscape page scrolls, as Android's list does: the chart is full width and reachable.
                let chart = try #require(element("yearsStatisticsChart", in: controller.view, as: YearsBarChartView.self))
                let page = try #require(element("statisticsPage-years", in: controller.view, as: UIScrollView.self))
                let inPage = chart.convert(chart.bounds, to: page)
                #expect(inPage.minX >= 0 && inPage.maxX <= page.bounds.width && inPage.width >= page.bounds.width - 40, "chart width at \(size)")
                #expect(inPage.minY >= 0 && inPage.maxY <= page.contentSize.height, "chart reachable at \(size)")
                page.scrollRectToVisible(inPage, animated: false)
                let shown = page.bounds.intersection(inPage).height
                #expect(shown >= min(inPage.height, page.bounds.height) - 1, "chart scrolls into view at \(size)")
                page.contentOffset = .zero
            }
            // Open podcast leaves Statistics; coming back is a new screen on Subscriptions.
            try await open("downloads", index: 2, controller)
            try await wait("downloads loaded") { element("downloadStatisticsFeed-2", in: controller.view, as: UIControl.self) != nil }
            try #require(element("downloadStatisticsFeed-2", in: controller.view, as: UIControl.self)).sendActions(for: .touchUpInside)
            try await wait("feed dialog") { (controller.presentedViewController as? SourceMessageController)?.isBeingPresented == false }
            let dialog = try #require(controller.presentedViewController as? SourceMessageController)
            try #require(element("statisticsOpenPodcast", in: dialog.view, as: UIButton.self)).sendActions(for: .touchUpInside)
            try await wait("podcast opened") {
                guard controller.presentedViewController == nil, case .feed(let id) = controller.path.last else { return false }
                return id == 2 && controller.path.count == 1
            }
            #expect(element("statisticsPager", in: controller.view, as: StatisticsPagerView.self) == nil)
            controller.drawerAction(.destination(.statistics))
            try await wait("statistics again") { element("statisticsTotal", in: controller.view, as: UILabel.self)?.text != nil }
            #expect(try pager(controller).selected == 0 && controller.statisticsTab == .subscriptions)
            #expect(menu(controller) == ["statisticsFilter", "statisticsMore"])
        }
    }

    @Test func rightToLeftMirrorsTabsAndSwipeButNotCharts() async throws {
        try await mounted(try await fixture(), rtl: true) { _, controller in
            try await wait("subscriptions loaded") { element("statisticsTotal", in: controller.view, as: UILabel.self)?.text != nil }
            let pager = try pager(controller)
            #expect(pager.effectiveUserInterfaceLayoutDirection == .rightToLeft)
            let tabs = try ["subscriptions", "years", "downloads"].map { try tab($0, controller) }
            #expect(tabs[0].frame.minX > tabs[1].frame.minX && tabs[1].frame.minX > tabs[2].frame.minX, "Subscriptions is right-most")
            let width = pager.pages.bounds.width
            #expect(abs(pager.pages.contentOffset.x - 2 * width) < 1, "first page on the right")
            // Swiping toward the left edge reveals the next tab (Years), as ViewPager2 does in RTL.
            pager.pages.setContentOffset(CGPoint(x: width, y: 0), animated: true)
            try await wait("swipe settled on Years") { controller.statisticsTab == .years }
            #expect(menu(controller) == ["statisticsMore"])
            try await wait("years loaded") { element("yearsStatisticsChart", in: controller.view, as: YearsBarChartView.self) != nil }
            let chart = try #require(element("yearsStatisticsChart", in: controller.view, as: YearsBarChartView.self))
            let lefts = chart.layout.bars.map(\.left)
            #expect(lefts == lefts.sorted() && chart.transform.isIdentity, "oldest month on the left in RTL too")
            let year = try #require(rows("yearStatistics-", controller).first)
            let label = try #require(year.subviews.compactMap { $0 as? UILabel }.first)
            #expect(label.effectiveUserInterfaceLayoutDirection == .rightToLeft)
            try await open("downloads", index: 2, controller)
            #expect(menu(controller).isEmpty)
        }
    }

    @Test func resetFromYearsEmptiesYearsWithoutAZeroRowAndLeavesDownloads() async throws {
        let fixture = try await fixture()
        try await mounted(fixture) { _, controller in
            try await wait("subscriptions loaded") { element("statisticsTotal", in: controller.view, as: UILabel.self)?.text != nil }
            try await open("years", index: 1, controller)
            try await wait("years loaded") { !rows("yearStatistics-", controller).isEmpty }
            try #require(element("statisticsMore", in: controller.view, as: UIButton.self)).sendActions(for: .touchUpInside)
            try await wait("overflow") { element("statisticsReset", in: controller.view, as: UIControl.self) != nil }
            try #require(element("statisticsReset", in: controller.view, as: UIControl.self)).sendActions(for: .touchUpInside)
            try await wait("confirmation") { (controller.presentedViewController as? SourceMessageController)?.isBeingPresented == false }
            let dialog = try #require(controller.presentedViewController as? SourceMessageController)
            try #require(element("statisticsResetConfirm", in: dialog.view, as: UIButton.self)).sendActions(for: .touchUpInside)
            try await wait("years emptied") { controller.presentedViewController == nil && rows("yearStatistics-", controller).isEmpty
                && element("yearsStatisticsChart", in: controller.view, as: YearsBarChartView.self)?.months.isEmpty == true }
            #expect(controller.statisticsTab == .years, "Reset keeps the tab")
            #expect(element("yearsStatisticsCaption", in: controller.view, as: UILabel.self)?.text == "Time played per month")
            // Saved data: every played duration is 0; downloads are untouched.
            let feeds = try await fixture.store.feeds()
            #expect(feeds.flatMap(\.episodes).allSatisfy { $0.userState.playedDurationMilliseconds == 0 })
            #expect(feeds.flatMap(\.episodes).filter { $0.userState.downloadDate != nil }.count == 10)
            try await open("downloads", index: 2, controller)
            try await wait("downloads") { element("downloadStatisticsTotal", in: controller.view, as: UILabel.self)?.text == "1.3 GB" }
            #expect(element("downloadStatisticsCaption", in: controller.view, as: UILabel.self)?.text == "Total size of 9 episodes on the device")
        }
    }

    @Test func emptyLibraryShowsHeadersWithoutRows() async throws {
        try await mounted(try await fixture(database: "statistics-empty.db")) { _, controller in
            try await open("years", index: 1, controller)
            try await wait("years") { element("yearsStatisticsChart", in: controller.view, as: YearsBarChartView.self) != nil }
            #expect(rows("yearStatistics-", controller).isEmpty, "no year-0 row")
            try await open("downloads", index: 2, controller)
            try await wait("downloads") { element("downloadStatisticsTotal", in: controller.view, as: UILabel.self)?.text == "0 B" }
            #expect(element("downloadStatisticsCaption", in: controller.view, as: UILabel.self)?.text == "Total size of 0 episodes on the device")
            #expect(rows("downloadStatisticsFeed-", controller).isEmpty)
        }
    }
}
