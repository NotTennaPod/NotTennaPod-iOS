import XCTest

final class FeedAutoSkipTests: XCTestCase {
    @MainActor func testAutoSkipSaveCancelRelaunchAndActualIntroEnding() throws {
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
        let row = app.buttons["feedSettingsAutoSkip"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        let intro = app.textFields["feedSkipIntro"], ending = app.textFields["feedSkipEnding"]
        XCTAssertTrue(intro.waitForExistence(timeout: 5)); XCTAssertEqual(intro.value as? String, "0")
        replace(intro, "5"); replace(ending, "10")
        app.buttons["feedSkipConfirm"].tapWhenSettled()
        // On iPad the number field's floating keypad is a popover: the first tap outside only closes it.
        if !app.buttons["feedSkipConfirm"].waitForNonExistence(timeout: 2) { app.buttons["feedSkipConfirm"].tapWhenSettled() }
        XCTAssertTrue(app.buttons["feedSkipConfirm"].waitForNonExistence(timeout: 5), app.debugDescription); row.tap()
        XCTAssertTrue(intro.waitForExistence(timeout: 5)); XCTAssertEqual(intro.value as? String, "5")
        XCTAssertEqual(ending.value as? String, "10")
        replace(intro, "99"); app.buttons["feedSkipCancel"].tapWhenSettled()
        if !app.buttons["feedSkipCancel"].waitForNonExistence(timeout: 2) { app.buttons["feedSkipCancel"].tapWhenSettled() }
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["SubscriptionFragment"].waitForExistence(timeout: 10)); app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 5)); app.buttons["subscriptionFeed-1"].tap()
        app.buttons["feedSettings"].tap(); row.tap()
        XCTAssertTrue(intro.waitForExistence(timeout: 5)); XCTAssertEqual(intro.value as? String, "5")
        XCTAssertEqual(ending.value as? String, "10")
        app.buttons["feedSkipCancel"].tap(); app.buttons["toolbarBack"].tap()
        let action = app.buttons["episode-action-2"]
        XCTAssertTrue(action.waitForExistence(timeout: 5)); action.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Play"), object: action)], timeout: 25), .completed)
        action.tap()
        let notice = app.descendants(matching: .any)["episodeActionSnackbar"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertEqual(notice.label, "Skipped first 5 seconds")
        app.buttons["miniPlayerOpen"].tap()
        let position = app.staticTexts["playerPosition"]
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        let seconds = Int(position.label.split(separator: ":").last ?? "") ?? -1
        XCTAssertGreaterThanOrEqual(seconds, 5); XCTAssertLessThan(seconds, 20)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label == %@", "Skipped last 10 seconds"), object: notice)], timeout: 25), .completed)
    }
    @MainActor private func replace(_ field: XCUIElement, _ value: String) {
        field.tap()
        // An open iPad keypad popover takes the first tap; tap again until the field has focus.
        if (field.value(forKey: "hasKeyboardFocus") as? Bool) != true { field.tapWhenSettled() }
        field.typeTextSettled(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String)?.count ?? 0) + value)
    }
}
