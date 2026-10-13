import XCTest

final class FeedVolumeTests: XCTestCase {
    @MainActor func testVolumeChoiceCancelAndRelaunch() throws {
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
        let row = app.buttons["feedSettingsVolume"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        let off = app.buttons["feedVolume-0"]
        XCTAssertTrue(off.waitForExistence(timeout: 5)); XCTAssertTrue(off.isSelected)
        app.buttons["feedVolume-5"].tap()
        XCTAssertFalse(app.buttons["feedVolumeCancel"].exists)
        row.tap()
        XCTAssertTrue(app.buttons["feedVolume-5"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["feedVolume-5"].isSelected)
        app.buttons["feedVolumeCancel"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["SubscriptionFragment"].waitForExistence(timeout: 10)); app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 5)); app.buttons["subscriptionFeed-1"].tap()
        app.buttons["feedSettings"].tap(); row.tap()
        XCTAssertTrue(app.buttons["feedVolume-5"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["feedVolume-5"].isSelected)
        app.buttons["feedVolume-1"].tap(); row.tap()
        XCTAssertTrue(app.buttons["feedVolume-1"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["feedVolume-1"].isSelected)
        app.buttons["feedVolumeCancel"].tap(); app.buttons["toolbarBack"].tap()
        let play = app.buttons["episode-action-2"]
        XCTAssertTrue(play.waitForExistence(timeout: 5)); play.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: play)], timeout: 25), .completed)
        play.tap()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 5))
        app.buttons["feedSettings"].tap(); row.tap(); app.buttons["feedVolume-0"].tap()
        row.tap(); XCTAssertTrue(off.waitForExistence(timeout: 5)); XCTAssertTrue(off.isSelected)
    }
}
