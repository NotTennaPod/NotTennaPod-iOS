import XCTest

final class FeedEpisodeSelectionTests: XCTestCase {
    @MainActor func testFeedContextSelectionQueueFavoritesShareAndRelaunch() {
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
        let first = app.buttons.matching(NSPredicate(format: "label == %@", "Selection episode 08")).firstMatch
        let second = app.buttons.matching(NSPredicate(format: "label == %@", "Selection episode 07")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["multiSelect"].waitForExistence(timeout: 5))
        app.buttons["multiSelect"].tap(); second.tap()
        XCTAssertEqual(app.staticTexts["episodeSelectionCount"].label, "2/8 selected")
        app.buttons["episodeSelectionMore"].tap(); app.buttons["select_all_below"].tap()
        XCTAssertEqual(app.staticTexts["episodeSelectionCount"].label, "8/8 selected")
        let queue = app.buttons["episodeBulk-addQueue"]
        if !queue.isHittable { app.otherElements["episodeSelectionActions"].swipeLeft() }
        XCTAssertTrue(queue.isHittable); queue.tap()
        XCTAssertTrue(app.buttons["feedSearch"].waitForExistence(timeout: 5))
        first.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["removeQueue"].waitForExistence(timeout: 5))
        app.buttons["multiSelect"].tap()
        app.buttons["episodeSelectionMore"].tap(); app.buttons["select_toggle"].tap()
        let favorite = app.buttons["episodeBulk-addFavorite"]
        if !favorite.isHittable { app.otherElements["episodeSelectionActions"].swipeLeft() }
        XCTAssertTrue(favorite.isHittable); favorite.tap()
        XCTAssertTrue(app.buttons["feedSearch"].waitForExistence(timeout: 5))
        first.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["removeFavorite"].waitForExistence(timeout: 5)); app.buttons["share"].tap()
        XCTAssertTrue(app.buttons["episodeShareSocial"].waitForExistence(timeout: 5))
        app.buttons["episodeShareSocial"].tap()
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout: 10)); app.cells["Copy"].tap()
        app.terminate(); app.launch()
        app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 10)); app.buttons["subscriptionFeed-1"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5)); first.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["removeFavorite"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["removeQueue"].exists)
        app.buttons["multiSelect"].tap(); app.buttons["endEpisodeSelection"].tap()
        XCTAssertTrue(app.buttons["feedInformation"].waitForExistence(timeout: 5))
        app.buttons["QueueFragment"].tap()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Selection episode ")).count, 8)
    }
}
