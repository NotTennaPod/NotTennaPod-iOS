import XCTest

final class FeedRemovalTests: XCTestCase {
    @MainActor
    func testUnsubscribeRequiresConfirmationAndClearsTheLibrary() throws {
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
        app.buttons["feedListMore"].tap(); app.buttons["removeArchiveFeed"].tap()
        XCTAssertTrue(app.buttons["removeFeedNext"].waitForExistence(timeout: 5))
        app.buttons["removeFeedNext"].tap()
        XCTAssertTrue(app.buttons["removeFeedConfirm"].waitForExistence(timeout: 5))
        app.buttons["removeFeedCancel"].tap()
        XCTAssertTrue(app.buttons["feedInformation"].waitForExistence(timeout: 5))
        app.buttons["feedListMore"].tap(); app.buttons["removeArchiveFeed"].tap()
        app.buttons["removeFeedNext"].tap(); app.buttons["removeFeedConfirm"].tap()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionsAdd"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["subscriptionFeed-1"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionsAdd"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["subscriptionFeed-1"].exists)
    }
}
