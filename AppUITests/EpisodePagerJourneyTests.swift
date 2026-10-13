import XCTest

/// Episode pager journey on the oracle's Android fixture (`TestSupport/Data/episode-pager/pager.db`) through the
/// database import. Expectations come from the independent
/// oracle `expected/pager.json`: Inbox row 3 → next → previous → next → Mark as played on page 4 → Back → the Inbox
/// without that episode → relaunch keeps it played at position 0 and does not reopen the pager.
@MainActor final class EpisodePagerJourneyTests: XCTestCase {
    private var app = XCUIApplication()
    private var journey: [String: Any] = [:]
    private var menus: [String: [String: [String]]] = [:]

    override func setUpWithError() throws {
        continueAfterFailure = false
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestSupport/Data/episode-pager")
        let oracle = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("expected/pager.json"))) as? [String: Any])
        journey = try XCTUnwrap(oracle["journey"] as? [String: Any])
        menus = try XCTUnwrap(oracle["menus"] as? [String: [String: [String]]])
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback",
                               "-test-seed-android-database", fixtures.appendingPathComponent("pager.db").path]
    }
    override func tearDown() { app.terminate() }

    private func ids(_ value: Any?) -> [Int] { (value as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue } }
    private func open(_ destination: String, title: String) {
        if app.buttons[destination].exists { app.buttons[destination].tapWhenSettled(); return }
        app.buttons["navigationMore"].tapWhenSettled()
        let item = app.otherElements["morePopup"].buttons[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription); item.tap()
    }
    /// The list shows exactly these episode rows, top to bottom.
    private func expectRows(_ wanted: [Int], absent: [Int] = [], _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let matched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in MainActor.assumeIsolated {
            let rows = wanted.map { self.app.buttons["episode-\($0)"] }
            guard rows.allSatisfy(\.exists), absent.allSatisfy({ !self.app.buttons["episode-\($0)"].exists }) else { return false }
            let tops = rows.map(\.frame.minY)
            return zip(tops, tops.dropFirst()).allSatisfy { $0 < $1 }
        } }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [matched], timeout: 15), .completed, "\(message): expected \(wanted)", file: file, line: line)
    }
    private func expectTitle(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let label = app.staticTexts["episodeTitle"]
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", title), object: label)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 10), .completed, "shown episode \(title)\n\(app.debugDescription)", file: file, line: line)
    }
    /// The toolbar icon and the overflow as a person reads them (top to bottom), then closed with an outside tap.
    private func expectMenu(_ id: Int, overflow expected: [String]? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let menu = menus[String(id)] ?? [:]
        XCTAssertEqual(app.buttons["episodeWebsite"].waitForExistence(timeout: menu["toolbar_icons"]?.isEmpty == false ? 5 : 1),
                       menu["toolbar_icons"]?.isEmpty == false, "toolbar icon of \(id)", file: file, line: line)
        app.buttons["episodeMore"].tapWhenSettled()
        let panel = app.scrollViews["episodeMenuPanel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5), file: file, line: line)
        let titles = panel.buttons.allElementsBoundByIndex.sorted { $0.frame.minY < $1.frame.minY }.map(\.label)
        XCTAssertEqual(titles, expected ?? menu["overflow"], "overflow of \(id)", file: file, line: line)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.9)).tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), file: file, line: line)
    }
    private func swipe(next: Bool) {
        let pager = app.scrollViews["episodePagerScroll"]
        XCTAssertTrue(pager.waitForExistence(timeout: 5), app.debugDescription)
        if next { pager.swipeLeft() } else { pager.swipeRight() }
    }

    func testInboxRowThreeSwipeMarkPlayedOnPageFourBackAndRelaunch() throws {
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 30), app.debugDescription)
        open("NewEpisodesFragment", title: "Inbox")
        let inbox = ids(journey["inbox_before"])
        expectRows(inbox, "Inbox of the fixture")

        // 1. Open row 3: the pager opens on it, with no animation through earlier pages.
        let row = try XCTUnwrap(journey["open_row"] as? Int)
        app.buttons["episode-\(inbox[row - 1])"].tapWhenSettled()
        expectTitle("No website here")
        expectMenu(303)

        // 2-3. Next, previous, next by swiping the page.
        for step in journey["steps"] as? [[String: Any]] ?? [] {
            swipe(next: step["gesture"] as? String == "next")
            expectTitle(step["visible_id"] as? Int == 304 ? "Page four" : "No website here")
        }
        expectMenu(304)

        // 4. Mark as played on page 4: the menu acts on the shown episode and the pager stays on it.
        app.buttons["episodeMore"].tapWhenSettled()
        XCTAssertTrue(app.buttons["markPlayed"].waitForExistence(timeout: 5)); app.buttons["markPlayed"].tap()
        let after = (journey["pager_after_action"] as? [String: Any])?["menu_after"] as? [String: [String]]
        // The write finishes asynchronously; the menu reads the saved state each time it opens.
        var played = false
        for _ in 0..<5 where !played {
            app.buttons["episodeMore"].tapWhenSettled()
            played = app.buttons["markUnplayed"].waitForExistence(timeout: 2)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.9)).tap()
            XCTAssertTrue(app.scrollViews["episodeMenuPanel"].waitForNonExistence(timeout: 5))
        }
        XCTAssertTrue(played, "the shown episode became played")
        expectTitle("Page four")
        expectMenu(304, overflow: after?["overflow"])
        XCTAssertFalse(app.otherElements["episodeActionSnackbar"].exists, "no snackbar for one episode")
        // The previous page's episode is untouched: still new, so its menu still offers Remove from inbox.
        swipe(next: false)
        expectTitle("No website here")
        expectMenu(303)

        // 5. Back: straight to the Inbox, which no longer lists the played episode.
        app.buttons["toolbarBack"].tapWhenSettled()
        let back = ids((journey["after_back"] as? [String: Any])?["list"])
        expectRows(back, absent: [304], "Inbox after Back")
        XCTAssertFalse(app.buttons["episodeMore"].exists)

        // 6. Relaunch: same Inbox, the episode stays played at position 0, no pager reopened.
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["episodeMore"].exists, "the pager is not restored")
        open("NewEpisodesFragment", title: "Inbox")
        expectRows(ids((journey["after_relaunch"] as? [String: Any])?["inbox"]), absent: [304], "Inbox after relaunch")
        open("EpisodesFragment", title: "Episodes")
        XCTAssertTrue(app.buttons["episode-304"].waitForExistence(timeout: 10))
        app.buttons["episode-304"].tapWhenSettled()
        expectTitle("Page four")
        expectMenu(304, overflow: after?["overflow"])
    }
}
