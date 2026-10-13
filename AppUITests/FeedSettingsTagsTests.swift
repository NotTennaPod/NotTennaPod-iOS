import XCTest

final class FeedSettingsTagsTests: XCTestCase {
    @MainActor func testSettingsTagsSaveCancelSearchAndRelaunchShareTheSameState() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18765/feed.xml")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["feedSettings"].waitForExistence(timeout: 10)); app.buttons["feedSettings"].tap()
        let row = app.buttons["feedSettingsTags"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        let field = app.textFields["feedTagInput"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["feedTagsRoot"].exists)
        field.tap(); field.typeTextSettled("Science"); app.buttons["feedTagAdd"].tap()
        field.tap(); field.typeTextSettled("Listening"); app.buttons["feedTagsSave"].tap()
        row.tap(); XCTAssertTrue(app.buttons["feedTagRemove-1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Science"].exists && app.staticTexts["Listening"].exists)
        XCTAssertLessThan(app.staticTexts["Listening"].frame.minX, app.staticTexts["Science"].frame.minX)
        app.buttons["feedTagRemove-0"].tap(); app.buttons["feedTagsCancel"].tap()
        app.buttons["toolbarBack"].tap(); app.buttons["feedSearch"].tap()
        let query = app.textFields["librarySearchQuery"]
        XCTAssertTrue(query.waitForExistence(timeout: 5)); query.tap(); query.typeTextSettled("listening\n")
        app.buttons["searchFeedScope"].tap()
        let card = app.buttons["searchFeed-1"]
        XCTAssertTrue(card.waitForExistence(timeout: 5)); card.press(forDuration: 0.7)
        app.buttons["searchFeedAction-editTags"].tap()
        XCTAssertTrue(app.staticTexts["Science"].waitForExistence(timeout: 5)); XCTAssertTrue(app.staticTexts["Listening"].exists)
        field.tap(); field.typeTextSettled("Shared"); app.buttons["feedTagsSave"].tap()
        app.terminate(); app.launch(); app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 10)); app.buttons["subscriptionFeed-1"].tap()
        app.buttons["feedSettings"].tap(); row.tap()
        XCTAssertTrue(app.buttons["feedTagRemove-2"].waitForExistence(timeout: 5))
        for name in ["Science", "Listening", "Shared"] { XCTAssertTrue(app.staticTexts[name].exists) }
        app.buttons["feedTagsCancel"].tap()
    }
}
