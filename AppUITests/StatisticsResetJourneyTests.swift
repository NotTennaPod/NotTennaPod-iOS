import XCTest

/// Actual journey on the statistics fixture: narrow the period, then More → Reset statistics
/// data → Cancel (nothing changes) → Reset → Confirm (choices back to All time, totals erased) →
/// relaunch keeps the reset. The runner independently checks the saved database and preferences.
@MainActor final class StatisticsResetJourneyTests: XCTestCase {
    /// Fresh per test: the fixture seeds a library once and the journey erases it, so a fixed library would start
    /// the next run already reset.
    private let library = UUID().uuidString
    private var app = XCUIApplication()
    override func setUp() { continueAfterFailure = false }

    private func launch() {
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback", "-test-statistics-journey"]
        app.launch()
        XCTAssertTrue(app.windows["statisticsFixtureReady"].waitForExistence(timeout: 30), app.debugDescription)
    }
    private func tap(_ id: String) {
        let button = app.buttons[id]; XCTAssertTrue(button.waitForExistence(timeout: 15), id)
        XCTAssertTrue(button.isHittable, id); button.tap()
    }
    private func expectTotal(_ text: String, _ step: String) {
        let total = app.staticTexts["statisticsTotal"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", text), object: total)], timeout: 10),
                       .completed, "\(step): expected \(text), got \(total.exists ? total.label : "no total")")
    }
    private func openReset() {
        tap("statisticsMore")
        let entry = app.descendants(matching: .any)["statisticsReset"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(entry.label, "Reset statistics data"); entry.tap()
        XCTAssertTrue(app.staticTexts["This will erase the history of duration played for all episodes. Are you sure you want to proceed?"].waitForExistence(timeout: 10))
    }

    func testResetCancelThenConfirmErasesPlayedTimeAndRestoresAllTime() {
        launch()
        tap("navigationMore"); tap("Statistics")
        expectTotal("3.5 hours", "All time before reset")
        tap("statisticsFilter"); tap("statisticsPastYear"); tap("statisticsFilterOK")
        expectTotal("3.0 hours", "Past year before reset")

        openReset(); tap("statisticsResetCancel")
        expectTotal("3.0 hours", "Cancel keeps choices and totals")

        openReset(); tap("statisticsResetConfirm")
        expectTotal("0.0 hours", "Reset erases played time")
        tap("statisticsFilter")
        XCTAssertEqual(app.buttons["statisticsIncludeMarked"].value as? String, "Off", "Include marked back to off")
        XCTAssertEqual(app.buttons["statisticsTo"].value as? String, "Today", "Period back to all time")
        tap("statisticsFilterOK")
        expectTotal("0.0 hours", "Unchanged OK after reset")

        app.terminate(); launch()
        tap("navigationMore"); tap("Statistics")
        expectTotal("0.0 hours", "Relaunch keeps the reset")
        app.terminate()
    }
}
