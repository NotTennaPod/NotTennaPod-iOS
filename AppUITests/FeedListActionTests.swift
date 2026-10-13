import XCTest

final class FeedListActionTests: XCTestCase {
    @MainActor func testSortShareInboxAndPersistedSelectionJourney() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 3))
        address.tap(); address.typeTextSettled("http://127.0.0.1:18765/feed.xml"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 35))
        app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["feedListMore"].waitForExistence(timeout: 10))
        app.buttons["feedListMore"].tap()
        XCTAssertTrue(app.buttons["sortFeed"].waitForExistence(timeout: 3))
        app.buttons["sortFeed"].tap()
        let title = app.buttons["feedSort-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["feedSort-filename"].exists)
        XCTAssertFalse(app.buttons["feedSort-global"].isEnabled)
        title.tap(); XCTAssertEqual(title.label, "Episode title\u{a0}▲")
        // Dismiss outside the sheet, measured from the actual sheet bounds.
        let sheet = app.otherElements["feedSortSheet"]
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: sheet.frame.midX, dy: sheet.frame.minY - 20)).tap()
        let first = app.buttons.matching(NSPredicate(format: "label == %@", "First episode: a short introduction")).firstMatch
        let second = app.buttons.matching(NSPredicate(format: "label == %@", "Second episode: queue and resume")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5)); XCTAssertLessThan(first.frame.minY, second.frame.minY)
        app.buttons["feedListMore"].tap(); app.buttons["feedListShare"].tap()
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout: 10)); app.cells["Copy"].tap()
        XCTAssertTrue(app.buttons["feedListMore"].waitForExistence(timeout: 5))
        app.buttons["feedListMore"].tap(); app.buttons["removeFeedInbox"].tap()
        XCTAssertTrue(app.buttons["removeFeedInboxCancel"].waitForExistence(timeout: 5))
        app.buttons["removeFeedInboxCancel"].tap()
        app.buttons["feedListMore"].tap(); app.buttons["removeFeedInbox"].tap()
        app.buttons["removeFeedInboxConfirm"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5)); XCTAssertTrue(second.exists)
        app.terminate(); app.launch()
        app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 10))
        app.buttons["subscriptionFeed-1"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5)); XCTAssertLessThan(first.frame.minY, second.frame.minY)
        app.buttons["feedListMore"].tap(); app.buttons["sortFeed"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5)); XCTAssertEqual(title.label, "Episode title\u{a0}▲")
        title.tap(); XCTAssertEqual(title.label, "Episode title\u{a0}▼")
    }
}
