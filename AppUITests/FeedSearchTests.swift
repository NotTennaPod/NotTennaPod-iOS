import XCTest

final class FeedSearchTests: XCTestCase {
    @MainActor func testFeedSearchResultBackScopeAndEmptyJourney() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 3))
        address.tap(); address.typeTextSettled("http://127.0.0.1:18765/feed.xml"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 35)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["feedSearch"].waitForExistence(timeout: 10)); app.buttons["feedSearch"].tap()
        let query = app.textFields["librarySearchQuery"]
        XCTAssertTrue(query.waitForExistence(timeout: 5)); query.tap(); query.typeTextSettled("queue\n")
        let match = app.buttons.matching(NSPredicate(format: "label == %@", "Second episode: queue and resume")).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@", "First episode: a short introduction")).firstMatch.exists)
        match.tap(); XCTAssertTrue(app.webViews["episodeShownotes"].waitForExistence(timeout: 5))
        app.buttons["toolbarBack"].tap(); XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertEqual(query.value as? String, "queue")
        app.buttons["searchFeedScope"].tap()
        XCTAssertTrue(match.waitForExistence(timeout: 5))
        query.tap(); app.buttons["searchClearQuery"].tap(); XCTAssertTrue(match.exists); query.typeTextSettled("unfindable\n")
        let empty = app.staticTexts["searchEmptyTitle"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "unfindable"), object: empty)], timeout: 8), .completed)
        query.tap(); app.buttons["searchClearQuery"].tap()
        XCTAssertEqual(empty.label, "Type a query to search")
        app.buttons["toolbarBack"].tap()
        XCTAssertTrue(app.buttons["feedInformation"].waitForExistence(timeout: 5))
    }
}
