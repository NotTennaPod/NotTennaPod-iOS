import XCTest

final class FeedInformationTests: XCTestCase {
    @MainActor
    func testInformationStatisticsSettingsAndFilterJourney() throws {
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
        app.buttons["feedInformation"].tap()
        XCTAssertTrue(app.buttons["statisticsButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["descriptionHeadingLabel"].exists)
        app.buttons["feedShare"].tap()
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout: 10))
        app.cells["Copy"].tap()
        XCTAssertTrue(app.buttons["statisticsButton"].waitForExistence(timeout: 5))
        app.buttons["statisticsButton"].tap()
        XCTAssertTrue(app.buttons["statisticsFeed-1"].waitForExistence(timeout: 5))
        app.buttons["statisticsFeed-1"].tap()
        XCTAssertTrue(app.buttons["statisticsOK"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(identifier: "statisticsValue").matching(NSPredicate(format: "label == %@", "2 episodes")).firstMatch.exists)
        app.buttons["statisticsOK"].tap()
        app.buttons["toolbarBack"].tap()
        XCTAssertTrue(app.buttons["statisticsButton"].waitForExistence(timeout: 5))
        app.buttons["toolbarBack"].tap()
        app.buttons["feedSettings"].tap()
        XCTAssertTrue(app.buttons["feedKeepUpdated"].waitForExistence(timeout: 5))
        app.buttons["feedKeepUpdated"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Off"), object: app.buttons["feedKeepUpdated"])], timeout: 5), .completed)
        app.buttons["toolbarBack"].tap()
        XCTAssertTrue(app.staticTexts["feedUpdatesDisabled"].exists || app.buttons["feedUpdatesDisabled"].exists)
        app.buttons["feedFilter"].tap()
        XCTAssertTrue(app.buttons["feedFilter_queued"].waitForExistence(timeout: 5))
        app.buttons["feedFilter_queued"].tap(); app.buttons["feedFilterConfirm"].tap()
        XCTAssertTrue(app.buttons["feedFiltered"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["episode-1"].exists)
        app.buttons["feedFiltered"].tap(); app.buttons["feedFilterReset"].tap(); app.buttons["feedFilterConfirm"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5))
        let scroll = app.scrollViews["libraryContent"]
        scroll.swipeUp()
        let collapsedTitle = app.staticTexts["screenTitle"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Parity Listening Lab"), object: collapsedTitle)], timeout: 5), .completed)
        scroll.swipeDown()
        XCTAssertTrue(app.buttons["feedInformation"].isHittable)
        app.buttons["feedInformation"].tap()
        XCTAssertTrue(app.buttons["statisticsButton"].waitForExistence(timeout: 5))
    }
}
