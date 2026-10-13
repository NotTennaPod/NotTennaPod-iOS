import XCTest

final class PlaybackIntervalSettingsTests: XCTestCase {
    @MainActor func testSettingsAndLongPressChangeRealSeekAndPersistAcrossRelaunch() throws {
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
        let episode = app.buttons["episode-action-1"]
        XCTAssertTrue(episode.waitForExistence(timeout: 5)); episode.tap(); waitLabel(episode, "Play")
        episode.tap(); waitLabel(app.buttons["miniPlayerPlay"], "Pause")
        app.buttons["miniPlayerPlay"].tap()
        app.buttons["navigationMore"].tap(); app.buttons["Settings"].tap(); app.buttons["prefScreenPlayback"].tap()
        let forwardKey = "prefPlaybackFastForwardDeltaLauncher"
        let rewindKey = "prefPlaybackRewindDeltaLauncher"
        app.buttons[forwardKey].tap()
        XCTAssertTrue(app.buttons[forwardKey + "-30"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[forwardKey + "-30"].isSelected)
        for seconds in [5,10,15,20,30,45,60] {
            XCTAssertEqual(app.buttons[forwardKey + "-\(seconds)"].label, "\(seconds) seconds")
        }
        app.buttons[forwardKey + "Cancel"].tap()
        app.buttons[forwardKey].tap(); app.buttons[forwardKey + "-5"].tap()
        app.buttons[rewindKey].tap(); app.buttons[rewindKey + "-15"].tap()
        app.buttons["toolbarBack"].tap(); app.buttons["toolbarBack"].tap()
        app.buttons["miniPlayerOpen"].tap()
        XCTAssertTrue(app.buttons["playerForward"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["playerForwardValue"].label, "5")
        XCTAssertEqual(app.staticTexts["playerRewindValue"].label, "15")
        app.buttons["playerRewind"].tap(); waitPosition(app, seconds: 0)
        app.buttons["playerForward"].tap(); waitPosition(app, seconds: 5)
        app.buttons["playerForward"].press(forDuration: 1)
        XCTAssertTrue(app.buttons[forwardKey + "-5"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[forwardKey + "-5"].isSelected)
        app.buttons[forwardKey + "-10"].tap()
        waitPosition(app, seconds: 5) // Long press opens the chooser without also seeking.
        XCTAssertEqual(app.staticTexts["playerForwardValue"].label, "10")
        app.buttons["playerForward"].tap(); waitPosition(app, seconds: 15)
        app.buttons["playerRewind"].press(forDuration: 1)
        XCTAssertTrue(app.buttons[rewindKey + "-15"].waitForExistence(timeout: 5))
        app.buttons[rewindKey + "Cancel"].tap(); waitPosition(app, seconds: 15)
        app.buttons["playerRewind"].tap(); waitPosition(app, seconds: 0)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 10)); app.buttons["miniPlayerOpen"].tap()
        XCTAssertEqual(app.staticTexts["playerForwardValue"].label, "10")
        XCTAssertEqual(app.staticTexts["playerRewindValue"].label, "15")
        app.buttons["playerForward"].press(forDuration: 1)
        XCTAssertTrue(app.buttons[forwardKey + "-10"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[forwardKey + "-10"].isSelected)
        app.buttons[forwardKey + "Cancel"].tap()
    }
    @MainActor private func waitPosition(_ app: XCUIApplication, seconds: Int) {
        let label = String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        waitLabel(app.staticTexts["playerPosition"], label)
    }
    @MainActor private func waitLabel(_ element: XCUIElement, _ label: String) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label), object: element)], timeout: 20), .completed)
    }
}
