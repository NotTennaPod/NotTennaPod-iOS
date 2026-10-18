import XCTest

/// Actual journey on a UUID library seeded from the `mixed` Android database (DEBUG hook, through the
/// database import). Expectations come from the independent oracle: its runner may supply them in `SUBSCRIPTIONS_EXPECTED`
/// (with `SUBSCRIPTIONS_DATABASE`); otherwise the test uses the committed fixture database and the oracle output for it
/// recorded below. The runner can also check the saved preferences and the orders this test prints (`SUBSCRIPTIONS-OBSERVED …`).
/// Subscriptions (default order) → Sort alphabetically → Counter unplayed → 3 columns, titles on then off →
/// filter Kept updated + Counter greater than zero → Archive → relaunch keeps everything → drawer agrees.
@MainActor final class SubscriptionsJourneyTests: XCTestCase {
    // Fresh per run: the journey ends in drawer mode, so a fixed library would not start from the default.
    private let library = UUID().uuidString
    private var app = XCUIApplication()
    private var expected: [String: Any] = [:]

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let expectations = try environment["SUBSCRIPTIONS_EXPECTED"].map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
            ?? Data(Self.mixedDatabaseExpectations.utf8)
        expected = try XCTUnwrap(try JSONSerialization.jsonObject(with: expectations) as? [String: Any])
        let database = environment["SUBSCRIPTIONS_DATABASE"] ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestSupport/Data/subscriptions-screen/databases/mixed.db").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: database), "missing seed database \(database)")
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback", "-test-seed-android-database", database]
    }
    /// Oracle expectations for `TestSupport/Data/subscriptions-screen/databases/mixed.db`.
    nonisolated private static let mixedDatabaseExpectations = #"{"default":[4,20,10,9,1,2,3,13,14,11,6,5,12,8,7,18,19],"alphabetical":[11,1,2,3,6,12,8,7,20,18,10,19,4,9,5,13,14],"unplayed_counter_text":{"11":"1","1":"3","2":"3","3":"2","6":"4","8":"1","20":"4","10":"3","19":"1","4":"5","9":"3","5":"1","13":"2","14":"2"},"filtered":[11,1,2,8,20,19,4,9,5,13,14],"archive":[16,15],"drawer":["drawer-feed-11","drawer-feed-1","drawer-feed-8","drawer-feed-20","drawer-feed-4","drawer-feed-9","drawer-feed-5","drawer-feed-13","drawer-feed-14","drawer-folder-News","drawer-folder-Tech"],"entry_counter":"35"}"#
    private func ids(_ key: String) -> [Int64] { (expected[key] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.int64Value } }
    /// Displayed cells in reading order (rows, then left to right; the journey runs left-to-right).
    private func displayed(_ name: String) -> [Int64] {
        let cells = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'subscriptionFeed-'")).allElementsBoundByIndex
        let placed: [(frame: CGRect, id: Int64)] = cells.compactMap { cell in
            Int64(cell.identifier.dropFirst("subscriptionFeed-".count)).map { (cell.frame, $0) }
        }
        let result = placed.sorted { lhs, rhs in
            abs(lhs.frame.minY - rhs.frame.minY) > 1 ? lhs.frame.minY < rhs.frame.minY : lhs.frame.minX < rhs.frame.minX
        }.map(\.id)
        print("SUBSCRIPTIONS-OBSERVED \(name) \(result.map(String.init).joined(separator: ","))")
        return result
    }
    private func menu(_ item: String) {
        app.buttons["subscriptionsMore"].tap()
        XCTAssertTrue(app.buttons[item].waitForExistence(timeout: 5), item); app.buttons[item].tap()
    }
    private func choose(_ row: String) {
        XCTAssertTrue(app.buttons[row].waitForExistence(timeout: 5), row); app.buttons[row].tap()
        XCTAssertTrue(app.buttons[row].waitForNonExistence(timeout: 5))
    }

    func test01SortCounterColumnsFilterArchiveAndDrawer() {
        app.launch()
        XCTAssertTrue(app.navigation("Subscriptions").waitForExistence(timeout: 30), app.debugDescription)
        app.navigation("Subscriptions").tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-4"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(displayed("default"), ids("default"))

        menu("subscriptionsSort"); choose("subscriptionsSortDialog-1")
        XCTAssertEqual(displayed("alphabetical"), ids("alphabetical"))
        menu("subscriptionsCounter"); choose("subscriptionsCounterDialog-2")
        XCTAssertEqual(displayed("alphabetical_unplayed"), ids("alphabetical"))
        for (id, text) in expected["unplayed_counter_text"] as? [String: String] ?? [:] {
            XCTAssertEqual(app.buttons["subscriptionFeed-\(id)"].value as? String, text, "counter of \(id)")
        }

        menu("subscriptionsColumns"); choose("subscriptionsColumns-3")
        let square = app.buttons["subscriptionFeed-11"].frame
        XCTAssertEqual(square.width, square.height, accuracy: 1, "no titles by default")
        menu("subscriptionsShowTitles")
        XCTAssertGreaterThan(app.buttons["subscriptionFeed-11"].frame.height, square.height + 20)
        menu("subscriptionsShowTitles")
        XCTAssertEqual(app.buttons["subscriptionFeed-11"].frame.height, square.height, accuracy: 1)

        menu("subscriptionsFilter")
        for token in ["enabled_updates", "counter_greater_zero"] {
            XCTAssertTrue(app.buttons["subscriptionsFilter_" + token].waitForExistence(timeout: 5)); app.buttons["subscriptionsFilter_" + token].tap()
        }
        app.buttons["subscriptionsFilterConfirm"].tap()
        XCTAssertTrue(app.buttons["subscriptionsFilterConfirm"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["subscriptionsFiltered"].exists)
        XCTAssertEqual(displayed("filtered"), ids("filtered"))

        menu("subscriptionsArchive")
        XCTAssertTrue(app.staticTexts["screenTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["screenTitle"].label, "Archive")
        XCTAssertFalse(app.buttons["subscriptionsAdd"].exists)
        XCTAssertEqual(displayed("archive"), ids("archive"))
        app.buttons["toolbarBack"].tap()

        // Relaunch: order, counter, columns, titles and filter persist.
        app.terminate(); app.launch()
        XCTAssertTrue(app.navigation("Subscriptions").waitForExistence(timeout: 30))
        app.navigation("Subscriptions").tap()
        XCTAssertTrue(app.buttons["subscriptionsFiltered"].waitForExistence(timeout: 10))
        XCTAssertEqual(displayed("relaunch"), ids("filtered"))

        // Drawer (bottom navigation off): same order, counters and folders.
        app.buttons["navigationMore"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5)); app.buttons["Settings"].tap()
        app.buttons["prefScreenInterface"].tap()
        let bottom = app.buttons["prefBottomNavigation"]
        for _ in 0..<6 where !bottom.isHittable { app.swipeUp() }
        bottom.tap()
        if app.buttons["sourceMessageOK"].waitForExistence(timeout: 3) { app.buttons["sourceMessageOK"].tap() }
        app.buttons["Back"].tap(); app.buttons["Back"].tap()
        if app.buttons["openDrawer"].waitForExistence(timeout: 5) { app.buttons["openDrawer"].tap() }
        XCTAssertTrue(app.buttons["drawerFiltered"].waitForExistence(timeout: 5), app.debugDescription)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'drawer-feed-' OR identifier BEGINSWITH 'drawer-folder-'"))
            .allElementsBoundByIndex.sorted { $0.frame.minY < $1.frame.minY }.map(\.identifier)
        print("SUBSCRIPTIONS-OBSERVED drawer \(rows.joined(separator: ","))")
        XCTAssertEqual(rows, expected["drawer"] as? [String])
        XCTAssertEqual(app.buttons["drawer-SubscriptionFragment"].value as? String, expected["entry_counter"] as? String)
        app.terminate()
    }
}
