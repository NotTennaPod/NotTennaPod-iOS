import XCTest

final class FeedAutoDeleteTests: XCTestCase {
    @MainActor func testSavedChoiceDeletesDownloadAfterPlaybackAndSurvivesRelaunch() throws {
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
        XCTAssertTrue(app.buttons["feedSettings"].waitForExistence(timeout: 5)); app.buttons["feedSettings"].tap()
        let row = app.buttons["feedSettingsAutoDelete"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        if !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.buttons["feedAutoDelete-0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["feedAutoDelete-0"].isSelected)
        app.buttons["feedAutoDelete-1"].tap()
        row.tap()
        XCTAssertTrue(app.buttons["feedAutoDelete-1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["feedAutoDelete-1"].isSelected)
        app.buttons["feedAutoDeleteCancel"].tap()
        app.buttons["toolbarBack"].tap()
        let action = app.buttons["episode-action-2"]
        XCTAssertTrue(action.waitForExistence(timeout: 5)); action.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: action)], timeout: 25), .completed)
        action.tap()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Download"), object: action)], timeout: 45), .completed)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["SubscriptionFragment"].waitForExistence(timeout: 10)); app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 5)); app.buttons["subscriptionFeed-1"].tap()
        XCTAssertEqual(app.buttons["episode-action-2"].label, "Download")
        app.buttons["feedSettings"].tap()
        if !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.buttons["feedAutoDelete-1"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["feedAutoDelete-1"].isSelected)
    }
}
