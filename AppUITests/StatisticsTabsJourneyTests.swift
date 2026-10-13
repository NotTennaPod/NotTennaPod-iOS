import XCTest
import SQLite3

/// Actual journey on a UUID library seeded from the oracle's Android database (DEBUG hooks, through
/// the database import, with its downloaded media re-marked as iOS downloads):
/// More → Statistics (Subscriptions) → Years tab (oracle years, Reset-only menu) → swipe to Downloads
/// (oracle rows and header, no menu) → row → feed statistics dialog → OK (still Downloads) → rotate
/// (still Downloads) → Years → Reset (Years empty, no year-0 row; Downloads unchanged) → Downloads row →
/// Open podcast → Statistics again opens on Subscriptions → Default page = Statistics → relaunch opens
/// Statistics on Subscriptions. The runner independently recomputes Years and Downloads from the app's
/// saved library (UTC months; subscribed/archived feeds by stored size) before and after Reset.
@MainActor final class StatisticsTabsJourneyTests: XCTestCase {
    /// A fresh library per run: the seed is installed once per library and Reset changes it.
    private let library = UUID().uuidString
    private var app = XCUIApplication()
    private var expected: [String: Any] = [:]
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestSupport/Data/statistics-tabs")
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        let data = try Data(contentsOf: fixtures.appendingPathComponent("expected/statistics-tabs.json"))
        expected = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["databases"] as? [String: Any])
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback",
                               "-test-seed-android-database", fixtures.appendingPathComponent("statistics.db").path,
                               "-test-seed-android-downloads"]
    }
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private var main: [String: Any] { expected["main"] as! [String: Any] }
    private var oracleYears: [String] {
        ((main["years"] as! [String: Any])["year_rows"] as! [[String: Any]]).map { "\(($0["year"] as! NSNumber).intValue), \($0["hours_text"] as! String)" }
    }
    private var oracleDownloads: [String] {
        ((main["downloads"] as! [String: Any])["rows"] as! [[String: Any]]).map { "\($0["title"] as! String), \($0["value_text"] as! String)" }
    }

    private func tap(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[id]; XCTAssertTrue(button.waitForExistence(timeout: 15), id, file: file, line: line)
        XCTAssertTrue(button.isHittable, id, file: file, line: line); button.tap()
    }
    private func waitFor(_ element: XCUIElement, exists: Bool = true, timeout: TimeInterval = 10, _ message: String) {
        let predicate = NSPredicate(format: "exists == %@", NSNumber(value: exists))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout), .completed, message)
    }
    private func waitLabel(_ element: XCUIElement, _ text: String, _ message: String) {
        let predicate = NSPredicate(format: "label == %@", text)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 10), .completed,
                       "\(message): \(element.exists ? element.label : "missing")")
    }
    private func selected(_ tab: String) -> Bool { app.buttons["statisticsTab-" + tab].isSelected }
    private func expectTab(_ tab: String, filter: Bool, more: Bool, _ step: String) {
        let predicate = NSPredicate(format: "isSelected == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: app.buttons["statisticsTab-" + tab])], timeout: 10),
                       .completed, "\(step): \(tab) selected")
        waitFor(app.buttons["statisticsFilter"], exists: filter, "\(step): Filter \(filter ? "shown" : "hidden")")
        waitFor(app.buttons["statisticsMore"], exists: more, "\(step): overflow \(more ? "shown" : "hidden")")
    }
    private func labels(_ prefix: String, type: XCUIElement.ElementType) -> [String] {
        app.descendants(matching: type).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).allElementsBoundByIndex
            .sorted { $0.frame.minY < $1.frame.minY }.map(\.label)
    }
    private func openStatistics() {
        tap("navigationMore"); tap("Statistics")
        waitLabel(app.staticTexts["screenTitle"], "Statistics", "Statistics title")
    }

    // MARK: Independent read of the saved library

    private struct Saved { var feeds: [Int64: (title: String, state: Int)] = [:]; var episodes: [(feed: Int64, record: [String: Any])] = [] }

    private func savedLibrary() throws -> Saved {
        // The app's data container is a sibling of this runner's container on the Simulator.
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let applications = support.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = try FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil).map {
            $0.appendingPathComponent("Library/Application Support/UITests-\(library)/library.sqlite")
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
        let url = try XCTUnwrap(candidates.first, "saved library")
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_close(db) }
        func rows(_ sql: String, _ body: (OpaquePointer?) throws -> Void) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW { try body(statement) }
        }
        func json(_ statement: OpaquePointer?, _ column: Int32) throws -> [String: Any] {
            let data = Data(bytes: sqlite3_column_blob(statement, column), count: Int(sqlite3_column_bytes(statement, column)))
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        var saved = Saved()
        try rows("SELECT id, record FROM feeds") { statement in
            let record = try json(statement, 1)
            let custom = record["customTitle"] as? String ?? ""
            let title = custom.isEmpty ? ((record["metadata"] as? [String: Any])?["title"] as? String ?? "") : custom
            saved.feeds[sqlite3_column_int64(statement, 0)] = (title, (record["subscriptionState"] as? NSNumber)?.intValue ?? 0)
        }
        try rows("SELECT feed_id, record FROM episodes ORDER BY id") { statement in
            saved.episodes.append((sqlite3_column_int64(statement, 0), try json(statement, 1)))
        }
        return saved
    }

    /// Years rows ("2025, 15.3 hours") by UTC month of the last play, newest first.
    private func recomputedYears(_ saved: Saved) -> [String] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        var years: [Int: Int64] = [:]
        for (_, record) in saved.episodes where record["details"].flatMap({ ($0 as? [String: Any])?["media"] }) != nil {
            let state = record["userState"] as? [String: Any] ?? [:]
            let played = (state["playedDurationMilliseconds"] as? NSNumber)?.int64Value ?? 0
            let last = (state["lastPlayedTimeMilliseconds"] as? NSNumber)?.int64Value ?? 0
            guard played > 0, last > 0, last / 1000 <= 253_402_300_799 else { continue }
            years[calendar.component(.year, from: Date(timeIntervalSince1970: Double(last / 1000))), default: 0] += played
        }
        return years.keys.sorted(by: >).map { year in
            let hours = Double(years[year]!) / 1000 / 3600
            return "\(year), \(String(format: "%.1f", (hours * 10).rounded(.toNearestOrAwayFromZero) / 10)) hours"
        }
    }

    /// Downloads rows as (feed id, bytes, count): subscribed/archived feeds with episodes, stored size of
    /// downloaded episodes, descending size, ties by id.
    private func recomputedDownloads(_ saved: Saved) -> [(Int64, Int64, Int)] {
        var result: [Int64: (Int64, Int)] = [:]
        for (feed, record) in saved.episodes where saved.feeds[feed]?.state != 1 {
            var value = result[feed] ?? (0, 0)
            let state = record["userState"] as? [String: Any] ?? [:]
            if state["downloadDate"] != nil, let media = (record["details"] as? [String: Any])?["media"] as? [String: Any] {
                value.0 += (media["size"] as? NSNumber)?.int64Value ?? 0; value.1 += 1
            }
            result[feed] = value
        }
        return result.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
    }

    func testTabsYearsDownloadsDialogRotationResetAndNewScreens() throws {
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 30), app.debugDescription)
        let saved = try savedLibrary()
        XCTAssertEqual(recomputedYears(saved), oracleYears, "saved library → Years (independent)")
        let downloads = recomputedDownloads(saved)
        let oracleRows = (main["downloads"] as! [String: Any])["rows"] as! [[String: Any]]
        XCTAssertEqual(downloads.map(\.0), oracleRows.map { ($0["feed_id"] as! NSNumber).int64Value }, "saved library → Downloads order (independent)")
        XCTAssertEqual(downloads.map(\.1), oracleRows.map { ($0["total_download_size"] as! NSNumber).int64Value })

        // Statistics opens on Subscriptions with Filter and Reset.
        openStatistics()
        for (tab, title) in [("subscriptions", "Subscriptions"), ("years", "Years"), ("downloads", "Downloads")] {
            XCTAssertEqual(app.buttons["statisticsTab-" + tab].label, title)
        }
        let tabs = ["subscriptions", "years", "downloads"].map { app.buttons["statisticsTab-" + $0].frame }
        XCTAssertTrue(tabs[0].minX < tabs[1].minX && tabs[1].minX < tabs[2].minX, "source tab order")
        expectTab("subscriptions", filter: true, more: true, "open")
        XCTAssertTrue(app.staticTexts["statisticsTotal"].waitForExistence(timeout: 10))

        // Years by tapping the tab.
        tap("statisticsTab-years")
        expectTab("years", filter: false, more: true, "Years")
        waitFor(app.otherElements["yearStatistics-2026"], "year rows")
        XCTAssertEqual(labels("yearStatistics-", type: .other), oracleYears)
        XCTAssertEqual(app.staticTexts["yearsStatisticsCaption"].label, "Time played per month")

        // Downloads by swiping the pages.
        app.scrollViews["statisticsPages"].swipeLeft()
        expectTab("downloads", filter: false, more: false, "Downloads")
        waitLabel(app.staticTexts["downloadStatisticsTotal"], "1.3 GB", "Downloads header")
        XCTAssertEqual(app.staticTexts["downloadStatisticsCaption"].label, "Total size of 9 episodes on the device")
        XCTAssertEqual(labels("downloadStatisticsFeed-", type: .button), oracleDownloads)

        // Row → feed statistics dialog → OK keeps Downloads.
        tap("downloadStatisticsFeed-2")
        XCTAssertTrue(app.staticTexts["My Beta"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["statisticsOpenPodcast"].exists)
        tap("statisticsOK")
        waitFor(app.buttons["statisticsOK"], exists: false, "dialog closed")
        expectTab("downloads", filter: false, more: false, "after dialog")

        // Rotation keeps the tab and its menu.
        XCUIDevice.shared.orientation = .landscapeLeft
        expectTab("downloads", filter: false, more: false, "landscape")
        XCTAssertTrue(app.buttons["statisticsTab-downloads"].isHittable && app.buttons["statisticsTab-subscriptions"].isHittable,
                      "tab bar visible in landscape")
        XCUIDevice.shared.orientation = .portrait
        expectTab("downloads", filter: false, more: false, "portrait again")

        // Reset from Years: Years empties (no year-0 row), Downloads is unchanged; saved data checked.
        app.scrollViews["statisticsPages"].swipeRight()
        expectTab("years", filter: false, more: true, "back to Years")
        tap("statisticsMore")
        let reset = app.descendants(matching: .any)["statisticsReset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 10)); XCTAssertEqual(reset.label, "Reset statistics data"); reset.tap()
        tap("statisticsResetConfirm")
        waitFor(app.otherElements["yearStatistics-2026"], exists: false, "Years emptied")
        XCTAssertEqual(labels("yearStatistics-", type: .other), [], "no year rows after Reset")
        XCTAssertTrue(app.staticTexts["yearsStatisticsCaption"].exists)
        expectTab("years", filter: false, more: true, "Reset keeps the tab")
        let afterReset = try savedLibrary()
        XCTAssertEqual(recomputedYears(afterReset), [], "saved library has no listening")
        XCTAssertEqual(recomputedDownloads(afterReset).map(\.1), downloads.map(\.1), "saved downloads unchanged")
        tap("statisticsTab-downloads")
        expectTab("downloads", filter: false, more: false, "Downloads after Reset")
        waitLabel(app.staticTexts["downloadStatisticsTotal"], "1.3 GB", "Downloads unchanged by Reset")
        XCTAssertEqual(labels("downloadStatisticsFeed-", type: .button), oracleDownloads)

        // Open podcast replaces Statistics; coming back is a new screen on Subscriptions.
        tap("downloadStatisticsFeed-2")
        tap("statisticsOpenPodcast")
        waitFor(app.buttons["statisticsTab-downloads"], exists: false, "Statistics left")
        waitLabel(app.descendants(matching: .any)["feedTitle"], "My Beta", "podcast shown")
        openStatistics()
        expectTab("subscriptions", filter: true, more: true, "new Statistics screen")

        // Default page = Statistics: a relaunch opens Statistics on Subscriptions.
        tap("statisticsTab-years")
        expectTab("years", filter: false, more: true, "Years before relaunch")
        tap("navigationMore"); tap("Settings"); tap("prefScreenInterface")
        let preference = app.buttons["prefDefaultPage"]
        for _ in 0..<6 where !preference.isHittable { app.swipeUp() }
        preference.tap()
        tap("defaultPage-StatisticsFragment")
        app.terminate(); app.launch()
        waitLabel(app.staticTexts["screenTitle"], "Statistics", "relaunch opens Statistics")
        expectTab("subscriptions", filter: true, more: true, "relaunch")
        app.terminate()
    }
}
