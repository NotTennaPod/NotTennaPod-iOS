import XCTest

final class PCPlaybackIntegrationUITests: XCTestCase {
    @MainActor func testHardwareChoicesCancelAndPersistAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let libraryID = UUID().uuidString
        app.launchArguments = ["-test-library-id", libraryID, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        openPlaybackSettings(app)
        let disconnect = app.buttons["prefPauseOnHeadsetDisconnect"]
        XCTAssertEqual(disconnect.value as? String, "On"); disconnect.tap()
        XCTAssertEqual(disconnect.value as? String, "Off")
        XCTAssertFalse(app.buttons["prefUnpauseOnHeadsetReconnect"].exists)
        XCTAssertFalse(app.buttons["prefUnpauseOnBluetoothReconnect"].exists)
        let forward = "prefHardwareForwardButton", previous = "prefHardwarePreviousButton"
        openRow(forward, app)
        XCTAssertTrue(app.buttons[forward + "-90"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[forward + "-90"].isSelected)
        let choices = [("90", "Fast-forward"), ("89", "Rewind"), ("87", "Skip episode"), ("88", "Restart episode")]
        for (id, label) in choices { XCTAssertEqual(app.buttons[forward + "-" + id].label, label) }
        app.buttons[forward + "Cancel"].tap()
        openRow(forward, app); XCTAssertTrue(app.buttons[forward + "-90"].isSelected)
        app.buttons[forward + "-87"].tap()
        openRow(previous, app); XCTAssertTrue(app.buttons[previous + "-89"].isSelected)
        app.buttons[previous + "-88"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        openPlaybackSettings(app)
        XCTAssertEqual(app.buttons["prefPauseOnHeadsetDisconnect"].value as? String, "Off")
        openRow(forward, app); XCTAssertTrue(app.buttons[forward + "-87"].isSelected)
        app.buttons[forward + "Cancel"].tap()
        openRow(previous, app); XCTAssertTrue(app.buttons[previous + "-88"].isSelected)
        app.buttons[previous + "Cancel"].tap()
    }
    @MainActor private func openPlaybackSettings(_ app: XCUIApplication) {
        app.buttons["navigationMore"].tap(); app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["prefScreenPlayback"].waitForExistence(timeout: 5)); app.buttons["prefScreenPlayback"].tap()
    }
    @MainActor private func openRow(_ key: String, _ app: XCUIApplication) {
        let row = app.buttons[key]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        for _ in 0..<5 where !row.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(row.isHittable); row.tap()
    }
}
