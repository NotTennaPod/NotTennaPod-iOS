import XCTest

final class ArchivedFeedTests: XCTestCase {
    @MainActor func testArchiveInformationRestoreAndRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 3))
        address.tap(); address.typeTextSettled("http://127.0.0.1:18768/selection.xml"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 20)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["feedListMore"].waitForExistence(timeout: 10))
        app.buttons["feedListMore"].tap(); app.buttons["removeArchiveFeed"].tap()
        XCTAssertTrue(app.buttons["archiveFeed"].waitForExistence(timeout: 5)); app.buttons["archiveFeed"].tap()
        XCTAssertTrue(app.buttons["restoreFeed"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["restoreFeed"].label, "Restore")
        XCTAssertTrue(app.staticTexts["feedUpdatesDisabled"].exists)
        XCTAssertTrue(app.buttons["feedSearch"].exists)
        XCTAssertFalse(app.buttons["feedFilter"].exists); XCTAssertFalse(app.buttons["feedSettings"].exists)
        XCTAssertFalse(app.buttons["episode-action-1"].exists)
        let episode = app.buttons.matching(NSPredicate(format: "label == %@", "Selection episode 08")).firstMatch
        XCTAssertTrue(episode.exists)
        app.buttons["feedInformation"].tap()
        XCTAssertTrue(app.textViews["feedInfoDescription"].waitForExistence(timeout: 5) || app.otherElements["feedInformationScreen"].exists)
        app.buttons["toolbarBack"].tap()
        XCTAssertTrue(app.buttons["restoreFeed"].waitForExistence(timeout: 5)); app.buttons["restoreFeed"].tap()
        XCTAssertTrue(app.buttons["feedFilter"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["feedSettings"].exists); XCTAssertTrue(app.buttons["episode-action-1"].exists)
        XCTAssertFalse(app.buttons["restoreFeed"].exists); XCTAssertFalse(app.staticTexts["feedUpdatesDisabled"].exists)
        app.terminate(); app.launch(); app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 10)); app.buttons["subscriptionFeed-1"].tap()
        XCTAssertTrue(app.buttons["feedFilter"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["episode-action-1"].exists)
        XCTAssertFalse(app.buttons["restoreFeed"].exists)
    }
}
