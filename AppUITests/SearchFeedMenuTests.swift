import XCTest

final class SearchFeedMenuTests: XCTestCase {
    @MainActor func testLongPressTagsCancelShareAndRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 3)); address.tap()
        address.typeTextSettled("http://127.0.0.1:18765/feed.xml"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 35)); app.buttons["subscribeFeed"].tap()
        openSearch(app)
        let card = app.buttons["searchFeed-1"]
        XCTAssertTrue(card.waitForExistence(timeout: 8)); card.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["searchFeedAction-editTags"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["searchFeedAction-removeInbox"].exists)
        XCTAssertTrue(app.buttons["searchFeedAction-removeArchive"].exists)
        app.buttons["searchFeedAction-editTags"].tap()
        let field = app.textFields["feedTagInput"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeTextSettled("Science")
        app.buttons["feedTagAdd"].tap()
        XCTAssertTrue(app.buttons["feedTagRemove-0"].exists)
        field.tap(); field.typeTextSettled("Listening")
        app.buttons["feedTagsSave"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5)); card.press(forDuration: 0.7)
        app.buttons["searchFeedAction-editTags"].tap()
        XCTAssertTrue(app.buttons["feedTagRemove-1"].waitForExistence(timeout: 5))
        app.buttons["feedTagRemove-0"].tap(); app.buttons["feedTagsCancel"].tap()
        card.press(forDuration: 0.7); app.buttons["searchFeedAction-share"].tap()
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout: 10)); app.cells["Copy"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.press(forDuration: 0.7); app.buttons["searchFeedAction-removeInbox"].tap()
        XCTAssertTrue(app.buttons["removeFeedInboxConfirm"].waitForExistence(timeout: 5))
        app.buttons["removeFeedInboxConfirm"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["librarySearchQuery"].value as? String, "listening")
        app.terminate(); app.launch(); app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 10)); app.buttons["subscriptionFeed-1"].tap()
        openSearch(app); XCTAssertTrue(card.waitForExistence(timeout: 8)); card.press(forDuration: 0.7)
        app.buttons["searchFeedAction-editTags"].tap()
        XCTAssertTrue(app.buttons["feedTagRemove-1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Science"].exists); XCTAssertTrue(app.staticTexts["Listening"].exists)
        app.buttons["feedTagsCancel"].tap()
    }
    @MainActor private func openSearch(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["feedSearch"].waitForExistence(timeout: 10)); app.buttons["feedSearch"].tap()
        let query = app.textFields["librarySearchQuery"]
        XCTAssertTrue(query.waitForExistence(timeout: 3)); query.tap(); query.typeTextSettled("listening\n")
        app.buttons["searchFeedScope"].tap()
    }
}
