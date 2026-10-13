import XCTest

/// Journey on a library seeded from the oracle's Android fixture (`TestSupport/Data/episode-list-menus/lists.db`)
/// through the database import. Expected orders come from the independent oracle (`expected/lists.json`):
/// Inbox order → sort oldest first → Remove all (Cancel, then Confirm) → History order → Clear → Favorites follow the
/// Episodes sort → relaunch keeps the data and the sorts.
@MainActor final class EpisodeListsJourneyTests: XCTestCase {
    private var app = XCUIApplication()
    private var expected: [String: Any] = [:]

    override func setUpWithError() throws {
        continueAfterFailure = false
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestSupport/Data/episode-list-menus")
        expected = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("expected/lists.json"))) as? [String: Any])
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback",
                               "-test-seed-android-database", fixtures.appendingPathComponent("lists.db").path]
    }
    private func order(_ screen: String, _ code: Int) -> [Int] {
        let screens = expected["screens"] as? [String: Any], sort = ((screens?[screen] as? [String: Any])?["by_sort"] as? [String: Any])?[String(code)] as? [String: Any]
        return (sort?["first_page"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
    }
    /// The expected leading rows are the first ones in the list, in that order. Only those rows are queried:
    /// a snapshot of every row (157 in the Inbox) is too slow for XCUITest.
    private func expectLeading(_ ids: [Int], count: Int = 4, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let wanted = Array(ids.prefix(count)), content = app.scrollViews["libraryContent"]
        let matched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in MainActor.assumeIsolated {
            let rows = wanted.map { self.app.buttons["episode-\($0)"] }
            guard rows.allSatisfy({ $0.exists }), content.exists else { return false }
            let tops = rows.map(\.frame.minY)
            return zip(tops, tops.dropFirst()).allSatisfy { $0 < $1 } && abs(tops[0] - content.frame.minY) < 120
        } }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [matched], timeout: 15), .completed, "\(message): expected \(wanted) leading", file: file, line: line)
    }
    /// An outside tap closes the sheet; aim just above it (the status-bar strip does not reach the app).
    private func closeSortSheet() {
        let sheet = app.otherElements["episodeListSortSheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -60)).tap()
    }
    private func tap(_ id: String) {
        let button = app.buttons[id]; XCTAssertTrue(button.waitForExistence(timeout: 10), id + "\n" + app.debugDescription); button.tap()
    }
    private func open(_ destination: String, title: String) {
        if app.buttons[destination].exists { app.buttons[destination].tap(); return }
        tap("navigationMore")
        let item = app.otherElements["morePopup"].buttons[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription); item.tap()
    }

    func testListsSortRemoveAllClearHistoryAndRelaunch() throws {
        app.launch()
        XCTAssertTrue(app.buttons["NewEpisodesFragment"].waitForExistence(timeout: 30), app.debugDescription)
        open("NewEpisodesFragment", title: "Inbox")
        expectLeading(order("inbox", 2), "Inbox newest first")

        tap("inboxMore"); tap("inboxSort")
        let date = app.buttons["episodeListSort-date"]
        XCTAssertTrue(date.waitForExistence(timeout: 5)); XCTAssertEqual(date.label, "Date\u{a0}▼")
        date.tap(); XCTAssertEqual(date.label, "Date\u{a0}▲")
        closeSortSheet()
        XCTAssertTrue(date.waitForNonExistence(timeout: 5))
        expectLeading(order("inbox", 1), "Inbox oldest first")

        tap("inboxMore"); tap("inboxRemoveAll")
        tap("inboxRemoveAllCancel")
        expectLeading(order("inbox", 1), "Cancel keeps the Inbox")
        tap("inboxMore"); tap("inboxRemoveAll"); tap("inboxRemoveAllConfirm")
        XCTAssertTrue(app.staticTexts["inboxEmptyTitle"].waitForExistence(timeout: 10), app.debugDescription)

        open("PlaybackHistoryFragment", title: "Playback history")
        // History breaks equal completion times by media id (see EpisodeListsTests); check the unambiguous leaders.
        expectLeading(order("history", 106), count: 3, "History by completion")
        tap("historyClear"); tap("historyClearConfirm")
        XCTAssertTrue(app.staticTexts["historyEmptyTitle"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["historyClear"].exists)

        open("EpisodesFragment", title: "Episodes")
        tap("allEpisodesMore"); tap("allEpisodesSort")
        let duration = app.buttons["episodeListSort-duration"]
        XCTAssertTrue(duration.waitForExistence(timeout: 5)); duration.tap()
        closeSortSheet()
        XCTAssertTrue(duration.waitForNonExistence(timeout: 5))
        open("FavoritesFragment", title: "Favorites")
        expectLeading(order("favorites", 5), "Favorites follow the Episodes sort (shortest first)")

        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["NewEpisodesFragment"].waitForExistence(timeout: 30))
        open("FavoritesFragment", title: "Favorites")
        expectLeading(order("favorites", 5), "Sort kept after relaunch")
        open("NewEpisodesFragment", title: "Inbox")
        XCTAssertTrue(app.staticTexts["inboxEmptyTitle"].waitForExistence(timeout: 10), "Remove all kept after relaunch")
        open("PlaybackHistoryFragment", title: "Playback history")
        XCTAssertTrue(app.staticTexts["historyEmptyTitle"].waitForExistence(timeout: 10), "Clear history kept after relaunch")
    }
}
