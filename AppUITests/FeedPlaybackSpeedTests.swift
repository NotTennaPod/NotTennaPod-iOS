import XCTest

final class FeedPlaybackSpeedTests: XCTestCase {
    @MainActor func testFeedSpeedAppliesToNextEpisodeAndSurvivesRelaunch() throws {
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
        let first = app.buttons["episode-action-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5)); first.tap(); waitLabel(first, "Play")
        first.tap(); waitLabel(app.buttons["miniPlayerPlay"], "Pause")
        app.buttons["miniPlayerPlay"].tap(); app.buttons["miniPlayerOpen"].tap()
        XCTAssertTrue(app.staticTexts["playerSpeedValue"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["playerSpeedValue"].label, "1.00")
        app.buttons["playerCollapse"].tap(); app.buttons["feedSettings"].tap()
        let row = app.buttons["feedSettingsPlaybackSpeed"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        let global = app.buttons["feedSpeedUseGlobal"]
        XCTAssertTrue(global.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["feedSpeedIncrease"].isEnabled)
        global.tap()
        for _ in 0..<10 { app.buttons["feedSpeedIncrease"].tap() }
        XCTAssertEqual(app.staticTexts["feedSpeedValue"].label, "1.50x")
        app.buttons["feedSpeedSave"].tap()
        app.buttons["toolbarBack"].tap(); app.buttons["miniPlayerOpen"].tap()
        XCTAssertEqual(app.staticTexts["playerSpeedValue"].label, "1.00")
        app.buttons["playerCollapse"].tap()
        let second = app.buttons["episode-action-2"]
        XCTAssertTrue(second.waitForExistence(timeout: 5)); second.tap(); waitLabel(second, "Play")
        second.tap(); waitLabel(app.buttons["miniPlayerPlay"], "Pause")
        app.buttons["miniPlayerPlay"].tap(); app.buttons["miniPlayerOpen"].tap()
        XCTAssertEqual(app.staticTexts["playerSpeedValue"].label, "1.50")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 10)); app.buttons["miniPlayerOpen"].tap()
        XCTAssertEqual(app.staticTexts["playerSpeedValue"].label, "1.50")
        app.buttons["playerCollapse"].tap(); app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 5)); app.buttons["subscriptionFeed-1"].tap()
        app.buttons["feedSettings"].tap(); row.tap()
        XCTAssertTrue(global.waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any)["feedSpeedSlider"].value as? String, "1.50")
        global.tap(); app.buttons["feedSpeedCancel"].tap(); row.tap()
        XCTAssertTrue(app.buttons["feedSpeedIncrease"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["feedSpeedIncrease"].isEnabled)
        XCTAssertEqual(app.descendants(matching: .any)["feedSpeedSlider"].value as? String, "1.50")
        app.buttons["feedSpeedCancel"].tap()
    }
    @MainActor private func waitLabel(_ element: XCUIElement, _ label: String) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label), object: element)], timeout: 20), .completed)
    }
}
