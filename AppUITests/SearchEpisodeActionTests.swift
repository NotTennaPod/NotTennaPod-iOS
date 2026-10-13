import XCTest

final class SearchEpisodeActionTests: XCTestCase {
    @MainActor func testContextSelectionQueueFavoriteShareAndRelaunch() throws {
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
        let first = app.buttons["episode-1"], second = app.buttons["episode-2"]
        XCTAssertTrue(first.waitForExistence(timeout: 8)); first.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["multiSelect"].waitForExistence(timeout: 5))
        app.buttons["multiSelect"].tap()
        XCTAssertTrue(app.staticTexts["episodeSelectionCount"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["episodeSelectionCount"].label, "1/2 selected")
        second.tap(); XCTAssertEqual(app.staticTexts["episodeSelectionCount"].label, "2/2 selected")
        XCTAssertFalse(app.buttons["episodeBulk-share"].exists)
        app.buttons["episodeSelectionMore"].tap(); XCTAssertTrue(app.buttons["select_toggle"].waitForExistence(timeout: 5))
        app.buttons["select_toggle"].tap()
        XCTAssertEqual(app.staticTexts["episodeSelectionCount"].label, "0/2 selected")
        app.buttons["episodeBulk-download"].tap()
        XCTAssertTrue(app.otherElements["episodeActionSnackbar"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.otherElements["episodeActionSnackbar"].label, "No items selected")
        XCTAssertEqual(app.staticTexts["episodeSelectionCount"].label, "0/2 selected")
        app.buttons["episodeSelectionMore"].tap(); app.buttons["select_toggle"].tap()
        let queue = app.buttons["episodeBulk-addQueue"]
        if !queue.isHittable { app.otherElements["episodeSelectionActions"].swipeLeft() }
        XCTAssertTrue(queue.isHittable); queue.tap()
        XCTAssertTrue(app.textFields["librarySearchQuery"].waitForExistence(timeout: 5), app.debugDescription)
        first.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["removeQueue"].waitForExistence(timeout: 5))
        app.buttons["multiSelect"].tap(); second.tap()
        let favorite = app.buttons["episodeBulk-addFavorite"]
        if !favorite.isHittable { app.otherElements["episodeSelectionActions"].swipeLeft() }
        XCTAssertTrue(favorite.isHittable); favorite.tap()
        XCTAssertTrue(app.textFields["librarySearchQuery"].waitForExistence(timeout: 5), app.debugDescription)
        first.press(forDuration: 0.7); XCTAssertTrue(app.buttons["removeFavorite"].waitForExistence(timeout: 5))
        app.buttons["share"].tap(); XCTAssertTrue(app.buttons["episodeShareSocial"].waitForExistence(timeout: 5))
        app.buttons["episodeSharePosition"].tap(); app.buttons["episodeShareSocial"].tap()
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout: 10)); app.cells["Copy"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        app.terminate(); app.launch(); app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 10)); app.buttons["subscriptionFeed-1"].tap()
        openSearch(app); XCTAssertTrue(first.waitForExistence(timeout: 8)); first.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["removeFavorite"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["removeQueue"].exists)
        app.buttons["multiSelect"].tap(); app.buttons["endEpisodeSelection"].tap()
        XCTAssertEqual(app.textFields["librarySearchQuery"].value as? String, "episode")
    }
    @MainActor private func openSearch(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["feedSearch"].waitForExistence(timeout: 10)); app.buttons["feedSearch"].tap()
        let query = app.textFields["librarySearchQuery"]
        XCTAssertTrue(query.waitForExistence(timeout: 3)); query.tap(); query.typeTextSettled("episode\n")
    }
}
