import XCTest

final class FeedRefreshTests: XCTestCase {
    @MainActor func testEditURLRefreshAndRelaunchJourney() throws {
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
        XCTAssertTrue(app.buttons["feedInformation"].waitForExistence(timeout: 10))
        app.buttons["feedListMore"].tap()
        XCTAssertTrue(app.buttons["refreshFeed"].waitForExistence(timeout: 3))
        app.buttons["refreshFeed"].tap()
        app.buttons["feedInformation"].tap()
        app.buttons["feedInformationMore"].tap()
        XCTAssertTrue(app.buttons["editFeedURL"].waitForExistence(timeout: 3))
        app.buttons["editFeedURL"].tap()
        let input = app.textViews["editFeedURLInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.press(forDuration: 1.2)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 3) { selectAll.tap() }
        else {
            let alternate = app.buttons["Select All"]
            XCTAssertTrue(alternate.waitForExistence(timeout: 3)); alternate.tap()
        }
        input.typeTextSettled("http://127.0.0.1:18765/feed.xml?edited=1")
        app.buttons["editFeedURLNext"].tap()
        let confirm = app.buttons["editFeedURLConfirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertFalse(confirm.isEnabled)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: confirm)], timeout: 20), .completed)
        confirm.tap()
        XCTAssertTrue(app.buttons["toolbarBack"].waitForExistence(timeout: 5))
        app.buttons["toolbarBack"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Refreshed Listening Lab"), object: app.buttons["feedTitle"])], timeout: 20), .completed)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Refresh delivered episode")).firstMatch.exists)
        app.terminate(); app.launch()
        app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 10))
        app.buttons["subscriptionFeed-1"].tap(); app.buttons["feedInformation"].tap()
        app.buttons["feedInformationMore"].tap(); app.buttons["editFeedURL"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "http://127.0.0.1:18765/feed.xml?edited=1")
        app.buttons["editFeedURLCancel"].tap()
    }
}
