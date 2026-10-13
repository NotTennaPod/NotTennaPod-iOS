import XCTest

/// Actual journey: More → Statistics → Filter (marked, Past year, one month via the real
/// From/To choice lists) → changed totals → feed detail (all time) → relaunch keeps the choice.
/// Expected totals are hand values from the fixture (see StatisticsPeriodJourneyFixture); the runner
/// independently recomputes them from the saved database and preferences.
@MainActor final class StatisticsPeriodJourneyTests: XCTestCase {
    /// Fresh per test: the fixture seeds a library once and the journey saves a filter in it, so a fixed library
    /// would start the next run from the saved filter.
    private let library = UUID().uuidString
    private var app = XCUIApplication()
    override func setUp() { continueAfterFailure = false }

    private func launch() {
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback", "-test-m13-statistics-journey"]
        app.launch()
        XCTAssertTrue(app.windows["m13StatisticsFixtureReady"].waitForExistence(timeout: 30), app.debugDescription)
    }
    private func tap(_ id: String) {
        let button = app.buttons[id]; XCTAssertTrue(button.waitForExistence(timeout: 15), id)
        XCTAssertTrue(button.isHittable, id); button.tap()
    }
    private func openStatistics() {
        tap("navigationMore"); tap("Statistics")
    }
    private func expectTotal(_ text: String, _ step: String) {
        let total = app.staticTexts["statisticsTotal"]
        let matches = NSPredicate(format: "label == %@", text)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: matches, object: total)], timeout: 10), .completed,
                       "\(step): expected \(text), got \(total.exists ? total.label : "no total")")
    }
    private func openFilter() {
        tap("statisticsFilter")
        XCTAssertTrue(app.buttons["statisticsFilterOK"].waitForExistence(timeout: 10))
    }
    private func choose(_ side: String, month label: String) {
        tap(side)
        let list = app.descendants(matching: .any)["statisticsMonthChoices"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), app.debugDescription)
        let cell = list.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'statisticsMonth-'"))
            .containing(NSPredicate(format: "label == %@", label)).firstMatch
        if !cell.exists { list.swipeUp() }
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "\(side) choice \(label): " + app.debugDescription)
        cell.tap()
        XCTAssertEqual(app.buttons[side].value as? String, label)
    }

    func testFilterNarrowsTotalsDetailStaysAllTimeAndChoicePersists() {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM yyyy")
        let thisMonth = Calendar.current.dateInterval(of: .month, for: Date())!.start
        let threeMonthsAgo = formatter.string(from: Calendar.current.date(byAdding: .month, value: -3, to: thisMonth)!)

        launch()
        openStatistics()
        expectTotal("3.5 hours", "Default all time excludes marked-only")

        openFilter(); tap("statisticsIncludeMarked")
        XCTAssertFalse(app.buttons["statisticsPastYear"].isEnabled, "Marked disables the date choices")
        tap("statisticsFilterOK")
        expectTotal("4.5 hours", "Marked adds its full duration")

        openFilter(); tap("statisticsIncludeMarked"); tap("statisticsPastYear"); tap("statisticsFilterOK")
        expectTotal("3.0 hours", "Past year drops fourteen-month-old listening")

        openFilter()
        choose("statisticsFrom", month: threeMonthsAgo)
        choose("statisticsTo", month: threeMonthsAgo)
        tap("statisticsFilterOK")
        expectTotal("2.0 hours", "Single month counts only its listening")

        let alpha = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'statisticsFeed-' AND label CONTAINS %@", "Alpha statistics")).firstMatch
        XCTAssertTrue(alpha.waitForExistence(timeout: 10), app.debugDescription)
        alpha.tap()
        let played = app.otherElements["statistics.playbackTime"].staticTexts["statisticsValue"]
        XCTAssertTrue(played.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(played.label, "3.0 hours", "Feed detail stays all time")
        tap("statisticsOK")
        expectTotal("2.0 hours", "Back on the filtered list")

        app.terminate()
        launch()
        openStatistics()
        expectTotal("2.0 hours", "Relaunch keeps the saved month")
        app.terminate()
    }
}
