import XCTest

/// Now Playing buttons journey: Settings → User interface → "Set notification buttons". The dialog offers
/// Skip episode and Playback speed, both ticked by default; Cancel keeps the saved
/// choice, Confirm saves it, and the choice survives a relaunch. The saved file is read directly from the
/// app's container, independently of the app. What the system Now Playing surfaces draw is a hardware
/// check: the Simulator's Control Center exposes no media controls to tests.
final class NowPlayingJourneyTests: XCTestCase {
    private let row = "prefFullNotificationButtons"

    private func savedButtons(_ library: String) -> [Int]? {
        let applications = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        for container in (try? FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil)) ?? [] {
            let file = container.appendingPathComponent("Library/Application Support/UITests-\(library)/notification-buttons.json")
            if let data = try? Data(contentsOf: file) {
                return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["buttons"] as? [Int]
            }
        }
        return nil
    }

    @MainActor private func openDialog(_ app: XCUIApplication) {
        let settingsRow = app.buttons[row]
        if !settingsRow.exists {
            XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
            app.buttons["navigationMore"].tap(); app.buttons["Settings"].tapWhenSettled()
            XCTAssertTrue(app.buttons["prefScreenInterface"].waitForExistence(timeout: 5)); app.buttons["prefScreenInterface"].tap()
        }
        XCTAssertTrue(settingsRow.waitForExistence(timeout: 5))
        for _ in 0..<5 where !settingsRow.isRevealed(in: app) { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertEqual(settingsRow.label, "Set notification buttons")
        settingsRow.tapWhenSettled()
        XCTAssertTrue(app.buttons[row + "Confirm"].waitForExistence(timeout: 5))
    }

    @MainActor private func checked(_ app: XCUIApplication) -> [Bool] {
        [app.buttons[row + "-2"].isSelected, app.buttons[row + "-4"].isSelected]
    }

    @MainActor func testNotificationButtonsChoiceIsSavedAndSurvivesRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication(), library = UUID().uuidString
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback"]
        app.launch()
        defer { app.terminate() }

        openDialog(app)
        XCTAssertEqual(app.staticTexts[row + "Title"].label, "Set notification buttons")
        XCTAssertEqual(app.buttons[row + "-2"].label, "Skip episode")
        XCTAssertEqual(app.buttons[row + "-4"].label, "Playback speed")
        XCTAssertLessThan(app.buttons[row + "-2"].frame.minY, app.buttons[row + "-4"].frame.minY)
        XCTAssertFalse(app.buttons["Next chapter"].exists); XCTAssertFalse(app.buttons["Sleep timer"].exists)
        XCTAssertEqual(app.buttons[row + "Confirm"].label, "Confirm"); XCTAssertEqual(app.buttons[row + "Cancel"].label, "Cancel")
        XCTAssertEqual(checked(app), [true, true], "Android default: Skip episode and Playback speed")

        // Cancel keeps the saved choice.
        app.buttons[row + "-4"].tapWhenSettled()
        XCTAssertEqual(checked(app), [true, false])
        app.buttons[row + "Cancel"].tapWhenSettled()
        XCTAssertTrue(app.buttons[row + "Confirm"].waitForNonExistence(timeout: 5))
        XCTAssertNil(savedButtons(library), "nothing saved on Cancel")
        openDialog(app)
        XCTAssertEqual(checked(app), [true, true])

        // Confirm saves: Playback speed off.
        app.buttons[row + "-4"].tapWhenSettled()
        app.buttons[row + "Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons[row + "Confirm"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(savedButtons(library), [2])

        app.terminate(); app.launch()
        openDialog(app)
        XCTAssertEqual(checked(app), [true, false])
        // Swap: Skip episode off, Playback speed on.
        app.buttons[row + "-2"].tapWhenSettled(); app.buttons[row + "-4"].tapWhenSettled()
        app.buttons[row + "Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons[row + "Confirm"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(savedButtons(library), [4])
        app.terminate(); app.launch()
        openDialog(app)
        XCTAssertEqual(checked(app), [false, true])
        app.buttons[row + "Cancel"].tapWhenSettled()
    }
}
