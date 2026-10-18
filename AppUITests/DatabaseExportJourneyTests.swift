import XCTest

/// Actual journey: Settings → Backup & restore (Database category above OPML) → Database export →
/// real system Save picker (`NotTennaPodBackup-yyyy-MM-dd.db`) → progress → `Export successful` → real
/// share sheet with the saved file. The saved file is read back from "On My iPhone/iPad" (not through
/// the Swift writer) and removed when the test ends; schema equality with a real Android 3.12.1 database
/// and Android's import of it are checked separately.
@MainActor final class DatabaseExportJourneyTests: XCTestCase {
    private let library = "15A0C0DE-DB00-4E15-8F15-0000000000F5"
    private var app = XCUIApplication()
    override func setUp() {
        continueAfterFailure = false
        keepLocalFilesSeeded(removing: [LocalFilesStorage.databaseExport])
    }

    private func tap(_ id: String) {
        let button = app.buttons[id]; XCTAssertTrue(button.waitForExistence(timeout: 15), id)
        XCTAssertTrue(button.isHittable, id); button.tap()
    }

    /// The saved backup as Android's Database import reads it: one file under the suggested name, an
    /// Android 3.12.1 database (user version 3110000) holding the fixture's two subscriptions.
    private func checkSavedBackup(suggested: String) throws {
        let name = suggested.hasSuffix(".db") ? suggested : suggested + ".db"
        let saved = LocalFilesStorage.items(prefix: LocalFilesStorage.databaseExport.prefix, suffix: LocalFilesStorage.databaseExport.suffix)
        XCTAssertEqual(saved.map(\.lastPathComponent), [name], "Saved once, under the suggested name")
        XCTAssertEqual(try LocalFilesStorage.backupSummary(try XCTUnwrap(saved.last)), .statisticsFixture)
    }

    func testDatabaseExportSavesAndSharesBackup() throws {
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback", "-test-statistics-journey"]
        app.launch()
        XCTAssertTrue(app.windows["statisticsFixtureReady"].waitForExistence(timeout: 30), app.debugDescription)
        tap("navigationMore"); tap("Settings"); tap("Backup & restore")
        let database = app.staticTexts["Database"], opml = app.staticTexts["OPML"]
        XCTAssertTrue(database.waitForExistence(timeout: 10) && opml.exists, app.debugDescription)
        XCTAssertLessThan(database.frame.minY, opml.frame.minY, "Source order: Database category before OPML")
        XCTAssertLessThan(app.buttons["databaseExport"].frame.minY, app.buttons["opmlExport"].frame.minY)
        tap("databaseExport")

        let confirm = app.buttons["DOCPicker.actionButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20), app.debugDescription)
        app.openLocalFilesRoot()
        let name = app.textFields["DOCPicker.filenameTextField"]
        // The Duo Simulator's Save picker can open with its "Save as" bar hidden; it appears once the file
        // list is pulled down, as a person would do. Elsewhere it shows at once.
        for _ in 0..<3 where !name.waitForExistence(timeout: 5) && app.collectionViews["File View"].exists {
            app.collectionViews["File View"].swipeDown(velocity: .slow)
        }
        XCTAssertTrue(name.waitForExistence(timeout: 5), app.debugDescription)
        let suggested = (name.value as? String) ?? ""
        XCTAssertNotNil(suggested.range(of: #"^NotTennaPodBackup-\d{4}-\d{2}-\d{2}(\.db)?$"#, options: .regularExpression), "Suggested name: \(suggested)")
        XCTAssertTrue(confirm.isEnabled); confirm.tap()

        let share = app.buttons["opmlExportShare"]
        XCTAssertTrue(share.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Export successful"].exists)
        try checkSavedBackup(suggested: suggested)
        share.tap()
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(sheet.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "NotTennaPodBackup-")).firstMatch.waitForExistence(timeout: 5))
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Cancel"])).firstMatch
        let region = app.otherElements["PopoverDismissRegion"]
        if close.exists && close.isHittable { close.tap() }
        else if region.exists { region.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.12)).tap() }
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["databaseExport"].waitForExistence(timeout: 10), "Share cancellation returns to Backup & restore")
        // Export only reads: after relaunch the library still shows the fixture's listening totals.
        app.terminate(); app.launch()
        XCTAssertTrue(app.windows["statisticsFixtureReady"].waitForExistence(timeout: 30), app.debugDescription)
        tap("navigationMore"); tap("Statistics")
        let total = app.staticTexts["statisticsTotal"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "3.5 hours"), object: total)], timeout: 10),
                       .completed, "Library unchanged after export: \(total.exists ? total.label : "no total")")
        for feed in ["Alpha statistics", "Bravo statistics"] {
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'statisticsFeed-' AND label CONTAINS %@", feed)).firstMatch.exists,
                          "\(feed) row after relaunch: " + app.debugDescription)
        }
        app.terminate()
    }
}
