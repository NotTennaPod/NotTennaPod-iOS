import XCTest

final class FeedNavigationTests: XCTestCase {
    @MainActor
    func testBackReturnsToTheFeedReadingPosition() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 3))
        address.tap(); address.typeTextSettled("http://127.0.0.1:18765/navigation.xml"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 35))
        app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 10))
        let list = app.scrollViews["libraryContent"]
        for _ in 0..<3 { list.swipeUp() }
        let viewport = list.frame
        let rows = app.buttons.matching(NSPredicate(format: "identifier MATCHES %@", "episode-[0-9]+"))
            .allElementsBoundByIndex.filter {
                $0.isHittable && $0.frame.minY >= viewport.minY + 20 && $0.frame.maxY <= viewport.maxY - 20
            }.sorted { $0.frame.minY < $1.frame.minY }
        let row = try XCTUnwrap(rows.first)
        XCTAssertNotEqual(row.identifier, "episode-1")
        let identifier = row.identifier, original = row.frame
        for _ in 0..<2 {
            app.buttons[identifier].tap()
            XCTAssertTrue(app.webViews["episodeShownotes"].waitForExistence(timeout: 10))
            app.buttons["toolbarBack"].tap()
            let restored = app.buttons[identifier]
            let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                restored.exists && restored.isHittable && abs(restored.frame.minY - original.minY) < 4
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
        }
        app.navigation("Subscriptions").tap()
        app.buttons["subscriptionFeed-1"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["episode-1"].isHittable)
    }

    /// IOS ends the app while it is in the background (as when it reclaims memory; the app is not swiped away):
    /// opening it again shows the episode the person was on, over its podcast, with the player expanded and paused,
    /// as Android restores MainActivity's screen and bottom sheet.
    @MainActor
    func testReopensWhereItWasAfterIOSEndsTheApp() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tapWhenSettled(); app.buttons["Add podcast"].tapWhenSettled(); app.buttons["addRSS"].tapWhenSettled()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 3))
        address.tapWhenSettled(); address.typeTextSettled("http://127.0.0.1:18765/episode-header.xml"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 35)); app.buttons["subscribeFeed"].tapWhenSettled()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 10)); app.buttons["episode-1"].tapWhenSettled()
        let primary = app.buttons["episodePrimaryAction"]
        func label(_ element: XCUIElement, _ expected: String) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected),
                                                                          object: element)], timeout: 10), .completed, app.debugDescription)
        }
        XCTAssertTrue(primary.waitForExistence(timeout: 10))
        primary.tapWhenSettled(); label(primary, "Pause")
        primary.tapWhenSettled(); label(primary, "Stream")
        app.buttons["miniPlayerOpen"].tapWhenSettled()
        let collapse = app.buttons["playerCollapse"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 5) && collapse.isHittable)

        XCUIDevice.shared.leaveApp()
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.state == .runningBackgroundSuspended)
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()

        // The player, expanded and paused on the episode.
        XCTAssertTrue(collapse.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: collapse)],
                                      timeout: 10), .completed, app.debugDescription)
        XCTAssertFalse(app.staticTexts["welcomeTitle"].exists)
        collapse.tapWhenSettled()
        // Under it, the episode, then its podcast.
        XCTAssertTrue(primary.waitForExistence(timeout: 10), app.debugDescription)
        label(primary, "Stream")
        app.buttons["toolbarBack"].tapWhenSettled()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["feedInformation"].exists, "the podcast's page")
        app.terminate()
    }
}
