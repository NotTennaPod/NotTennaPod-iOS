import XCTest

final class FeedPaginationTests: XCTestCase {
    @MainActor func testPageLoadingResetAndRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 3))
        address.tap(); address.typeTextSettled("http://127.0.0.1:18766/paged.xml"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 25))
        app.buttons["subscribeFeed"].tap()
        let next = app.buttons["feedNextPage"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()
        let content = app.scrollViews["libraryContent"]
        content.swipeUp()
        let older = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Pagination episode 05")).firstMatch
        XCTAssertTrue(older.waitForExistence(timeout: 10))
        XCTAssertTrue(next.waitForExistence(timeout: 3))
        next.tap()
        content.swipeUp()
        let last = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Pagination episode 01")).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 10))
        XCTAssertTrue(next.waitForNonExistence(timeout: 10))
        app.buttons["feedListMore"].tap()
        let complete = app.buttons["refreshCompleteFeed"]
        XCTAssertTrue(complete.waitForExistence(timeout: 3))
        XCTAssertEqual(complete.label, "Refresh complete podcast")
        complete.tap()
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        // Original resets to the root, preserving the older episodes. The first
        // next-page press after reset reads the root again before advancing.
        next.tap()
        XCTAssertTrue(last.exists)
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        app.terminate(); app.launch()
        app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 10))
        app.buttons["subscriptionFeed-1"].tap()
        content.swipeUp(); content.swipeUp()
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        XCTAssertTrue(next.waitForExistence(timeout: 5))
    }
}
