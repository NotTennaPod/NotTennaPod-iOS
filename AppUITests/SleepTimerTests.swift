import XCTest

final class SleepTimerTests: XCTestCase {
    @MainActor func testTimerStartExtendDisableEpisodeExpiryAndSavedOptions() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18765/feed.xml")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15)); app.buttons["subscribeFeed"].tap()
        let episode = app.buttons["episode-action-1"]
        XCTAssertTrue(episode.waitForExistence(timeout: 5)); episode.tap(); label(episode, "Play")
        episode.tap(); label(app.buttons["miniPlayerPlay"], "Pause"); app.buttons["miniPlayerPlay"].tap()
        app.buttons["miniPlayerOpen"].tap(); label(app.buttons["playerPlay"], "Play")
        let timer = app.buttons["playerSleepTimer"]
        label(timer, "Set sleep timer"); XCTAssertTrue(timer.isHittable); timer.tap()
        let input = app.textFields["sleepTimerInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); XCTAssertEqual(input.value as? String, "15")
        app.buttons["sleepTimerSet"].tap()
        XCTAssertTrue(app.staticTexts["sleepTimerMessage"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["sleepTimerMessage"].label.contains("No media playing"))
        app.buttons["sleepTimerVibrate"].tap(); XCTAssertEqual(app.buttons["sleepTimerVibrate"].value as? String, "On")
        app.buttons["sleepTimerHours"].tap()
        let dial = app.otherElements["sleepTimerTimeRangeDial"]
        XCTAssertTrue(dial.waitForExistence(timeout: 5))
        let start = dial.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5 - 0.4 * sqrt(3) / 2))
        let finish = dial.coordinate(withNormalizedOffset: CGVector(dx: 0.5 + 0.4 * sin(21.2 / 24 * 2 * .pi), dy: 0.5 - 0.4 * cos(21.2 / 24 * 2 * .pi)))
        start.press(forDuration: 0.1, thenDragTo: finish)
        app.buttons["sleepTimerTimeRangeOK"].tap()
        XCTAssertTrue(app.buttons["sleepTimerAutomatic"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["sleepTimerAutomatic"].value as? String, "On")
        XCTAssertTrue(app.buttons["sleepTimerAutomatic"].label.contains("09:00 PM"))
        app.buttons["sleepTimerAutomatic"].tap()
        dismissSheet(app); app.buttons["playerPlay"].tap(); label(app.buttons["playerPlay"], "Pause")
        timer.tap(); XCTAssertTrue(input.waitForExistence(timeout: 5)); app.buttons["sleepTimerSet"].tap()
        let remaining = app.staticTexts["sleepTimerRemaining"]
        XCTAssertTrue(remaining.waitForExistence(timeout: 5))
        app.buttons["sleepTimerExtend0"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH '00:19:' OR label == '00:20:00'"), object: remaining)], timeout: 5), .completed)
        dismissSheet(app); label(timer, "Sleep timer"); timer.tap()
        XCTAssertTrue(app.buttons["sleepTimerDisable"].waitForExistence(timeout: 5)); app.buttons["sleepTimerDisable"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        app.buttons["sleepTimerMode"].tap(); app.buttons["sleepTimerModeEpisodes"].tap()
        XCTAssertEqual(input.value as? String, "1"); XCTAssertFalse(app.buttons["sleepTimerShake"].exists)
        app.buttons["sleepTimerSet"].tap(); label(remaining, "1 episode")
        dismissSheet(app)
        let seek = app.descendants(matching: .any)["playerSeek"]
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForNonExistence(timeout: 15))
        XCTAssertTrue(episode.waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(episode.waitForExistence(timeout: 10)); episode.tap()
        label(app.buttons["miniPlayerPlay"], "Pause"); app.buttons["miniPlayerPlay"].tap(); app.buttons["miniPlayerOpen"].tap()
        label(timer, "Set sleep timer"); timer.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5)); XCTAssertEqual(input.value as? String, "1")
        XCTAssertEqual(app.buttons["sleepTimerVibrate"].value as? String, "On")
        XCTAssertTrue(app.buttons["sleepTimerMode"].label.contains("episodes"))
    }
    @MainActor func testKeyboardRotationSheetDragAndBlockedSettingsReturn() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback", "-test-timer-geometry"]
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18765/feed.xml")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15)); app.buttons["subscribeFeed"].tap()
        let episode = app.buttons["episode-action-1"]
        XCTAssertTrue(episode.waitForExistence(timeout: 5)); episode.tap(); label(episode, "Play")
        episode.tap(); label(app.buttons["miniPlayerPlay"], "Pause"); app.buttons["miniPlayerPlay"].tap()
        app.buttons["miniPlayerOpen"].tap(); label(app.buttons["playerPlay"], "Play")
        let position = app.staticTexts["playerPosition"].label
        let timer = app.buttons["playerSleepTimer"]; timer.tap()
        let input = app.textFields["sleepTimerInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeTextSettled("1234")
        XCTAssertEqual(input.value as? String, "123")
        XCTAssertTrue(input.isHittable)
        XCUIDevice.shared.orientation = .landscapeLeft
        let panel = app.otherElements["sleepTimerSheet"]
        let landscape = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate:
            NSPredicate(format: "value == 'orientation:3' OR value == 'orientation:4'"), object: panel)], timeout: 5)
        if XCUIDevice.rotationResizesWindow { XCTAssertEqual(landscape, .completed) } // The Duo Simulator does not resize on rotation.
        XCTAssertTrue(input.waitForExistence(timeout: 5)); XCTAssertEqual(input.value as? String, "123")
        XCTAssertTrue(input.isHittable)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate:
            NSPredicate(format: "value == 'orientation:1'"), object: panel)], timeout: 5), .completed)
        app.buttons["sleepTimerMode"].tap(); app.buttons["sleepTimerModeEpisodes"].tap()
        XCTAssertEqual(input.value as? String, "1")
        app.buttons["sleepTimerHours"].tap()
        let dial = app.otherElements["sleepTimerTimeRangeDial"]
        XCTAssertTrue(dial.waitForExistence(timeout: 5))
        let start = dial.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let end = dial.coordinate(withNormalizedOffset: CGVector(dx: 0.5 + 0.4 * sin(22.2 / 24 * 2 * .pi), dy: 0.5 - 0.4 * cos(22.2 / 24 * 2 * .pi)))
        start.press(forDuration: 0.1, thenDragTo: end)
        app.buttons["sleepTimerTimeRangeOK"].tap()
        XCTAssertTrue(app.buttons["sleepTimerDisableContinuous"].waitForExistence(timeout: 5))
        app.buttons["sleepTimerDisableContinuous"].tap()
        let settings = app.buttons["sleepTimerPlaybackSettings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["sleepTimerSet"].isEnabled)
        settings.tap()
        let continuous = app.buttons["prefFollowQueue"]
        XCTAssertTrue(app.buttons["toolbarBack"].waitForExistence(timeout: 5))
        for _ in 0..<5 where !continuous.exists || !continuous.isHittable { app.swipeUp() }
        XCTAssertTrue(continuous.exists)
        XCTAssertTrue(continuous.isHittable)
        XCTAssertFalse(timer.exists)
        continuous.tap(); app.buttons["toolbarBack"].tap()
        XCTAssertTrue(timer.waitForExistence(timeout: 5) && timer.isHittable)
        label(app.staticTexts["playerPosition"], position); label(app.buttons["playerPlay"], "Play")
        timer.tap(); XCTAssertTrue(input.waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["sleepTimerSet"].isEnabled)
        app.buttons["sleepTimerMode"].tap(); app.buttons["sleepTimerModeMinutes"].tap()
        XCTAssertEqual(input.value as? String, "123")
        panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03))
            .press(forDuration: 0.05, thenDragTo: panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)))
        XCTAssertTrue(input.waitForNonExistence(timeout: 5)); XCTAssertTrue(timer.isHittable)
        label(app.staticTexts["playerPosition"], position)
        timer.tap(); XCTAssertTrue(input.waitForExistence(timeout: 5)); XCTAssertEqual(input.value as? String, "123")
    }

    @MainActor private func dismissSheet(_ app: XCUIApplication) {
        let panel = app.otherElements["sleepTimerSheet"]
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: panel.frame.midX - app.frame.minX, dy: panel.frame.minY - app.frame.minY - 12)).tap()
        XCTAssertTrue(app.buttons["sleepTimerMode"].waitForNonExistence(timeout: 5))
    }
    @MainActor private func label(_ element: XCUIElement, _ expected: String) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: element)], timeout: 20), .completed)
    }
}
