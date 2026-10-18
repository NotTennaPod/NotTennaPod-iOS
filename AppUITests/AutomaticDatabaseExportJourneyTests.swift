import XCTest

/// Actual journey (one ordered test; the test pre-action seeds the empty "DatabaseExport" folder, step 4 has the app remove
/// it, and the test leaves it present and empty again when it ends): Backup & restore → Automatic database export
/// switch → real folder picker (Cancel keeps Off; choosing "DatabaseExport" turns it On and backs up now) → a due run (backup
/// clock shifted by a DEBUG launch argument; no system setting changes) backs up again → a not-due launch writes
/// nothing → a removed folder reports the source error → switching Off stops backups. The backups are read from the
/// folder (not through the Swift writer); retention and schema equality are checked by the host tests.
@MainActor final class AutomaticDatabaseExportJourneyTests: XCTestCase {
    // Fresh per run, so the journey always starts with the switch Off and no backup history.
    private let library = UUID().uuidString
    private var app = XCUIApplication()
    override func setUp() {
        continueAfterFailure = false
        keepLocalFilesSeeded(removing: [], emptyFolder: "DatabaseExport")
    }
    /// The backups in the chosen folder, as a person sees them in Files; each is a valid Android backup of the library.
    private func checkBackups(count: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let backups = LocalFilesStorage.items(prefix: LocalFilesStorage.databaseExport.prefix, suffix: LocalFilesStorage.databaseExport.suffix, in: "DatabaseExport")
        XCTAssertEqual(backups.count, count, "Backups in DatabaseExport: \(backups.map(\.lastPathComponent))", file: file, line: line)
        for backup in backups {
            XCTAssertEqual(try LocalFilesStorage.backupSummary(backup), .statisticsFixture, backup.lastPathComponent, file: file, line: line)
        }
    }

    private func launch(offsetDays: Int? = nil) {
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback", "-test-statistics-journey"]
            + (offsetDays.map { ["-test-auto-backup-now-offset-days", String($0)] } ?? [])
        app.launch()
        XCTAssertTrue(app.windows["statisticsFixtureReady"].waitForExistence(timeout: 30), app.debugDescription)
    }
    private func tap(_ id: String) {
        let button = app.buttons[id]; XCTAssertTrue(button.waitForExistence(timeout: 15), id)
        if !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.isHittable, id); button.tap()
    }
    private var toggle: XCUIElement { app.buttons["automaticDatabaseExport"] }
    private func openBackupRestore() {
        tap("navigationMore"); tap("Settings"); tap("Backup & restore")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
    }
    private func outcome(_ prefix: String, timeout: TimeInterval = 60) -> String {
        let marker = app.windows.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "automaticBackup: ", prefix)).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: timeout), "automaticBackup: \(prefix)\n" + app.debugDescription)
        return marker.label
    }

    /// Every step builds on the previous step's saved state (chosen folder, last backup time), so the steps are one
    /// test: separate tests would depend on each other's leftovers and on run order. Retention (keeping the five
    /// newest backups) is covered by the host `AutomaticDatabaseExportTests`.
    func testEnableDueNotDueRemovedFolderAndSwitchOff() throws {
        try enableChoosesFolderAndBacksUpImmediately()
        try dueRunBacksUpAgain()
        try notDueWritesNothing()
        removedFolderReportsSourceError()
        switchingOffStopsBackups()
    }

    private func enableChoosesFolderAndBacksUpImmediately() throws {
        launch()
        openBackupRestore()
        XCTAssertEqual(toggle.label, "Automatic database export")
        XCTAssertEqual(toggle.value as? String, "Off")
        XCTAssertLessThan(app.buttons["databaseExport"].frame.minY, toggle.frame.minY)
        XCTAssertLessThan(toggle.frame.minY, app.buttons["databaseImport"].frame.minY)
        toggle.tap()
        // The system folder picker is a sheet with Open and no Cancel button; cancel by swiping it away.
        let picker = app.buttons["Open"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20), app.debugDescription)
        // iPad shows a full-screen picker with Close; iPhone/Duo a sheet dismissed by swiping down.
        let close = app.buttons.matching(NSPredicate(format: "label IN %@ OR identifier IN %@", ["Close", "Cancel"], ["Close", "Cancel"])).firstMatch
        if close.exists && close.isHittable { close.tap() }
        else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).press(forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        }
        XCTAssertTrue(picker.waitForNonExistence(timeout: 10), "Picker dismissed")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10)); XCTAssertEqual(toggle.value as? String, "Off", "Cancel keeps it off")

        toggle.tap()
        let folder = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "DatabaseExport")).firstMatch
        app.revealInLocalFiles(folder)
        XCTAssertTrue(folder.exists, app.debugDescription); folder.tap()
        let open = app.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10), app.debugDescription)
        open.tap()
        let done = outcome("done")
        XCTAssertTrue(done.contains("done NotTennaPodBackup-"), done)
        XCTAssertEqual(toggle.value as? String, "On")
        try checkBackups(count: 1)
        app.terminate()
    }

    private func dueRunBacksUpAgain() throws {
        launch(offsetDays: 4)
        XCTAssertTrue(outcome("done").contains("NotTennaPodBackup-"))
        try checkBackups(count: 2) // Named by the (shifted) run date, so a new file.
        app.terminate()
    }

    private func notDueWritesNothing() throws {
        launch()
        let result = outcome("scheduled")
        XCTAssertFalse(result.contains("done"), "A launch before the next due time writes no backup: \(result)")
        openBackupRestore()
        XCTAssertEqual(toggle.value as? String, "On")
        try checkBackups(count: 2)
        app.terminate()
    }

    private func removedFolderReportsSourceError() {
        // The notice is transient (snackbar length): observe it first, then the run's recorded outcome.
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback", "-test-statistics-journey",
                               "-test-auto-backup-now-offset-days", "8", "-test-auto-backup-remove-folder"]
        app.launch()
        let notice = app.staticTexts["applicationNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertEqual(notice.label, "Error during automatic database backup Unable to open export folder")
        XCTAssertTrue(outcome("failed").contains("failed Unable to open export folder"))
        openBackupRestore()
        XCTAssertEqual(toggle.value as? String, "On", "The switch stays on after a failure")
        app.terminate()
    }

    private func switchingOffStopsBackups() {
        launch()
        openBackupRestore()
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "Off")
        app.terminate()
        launch(offsetDays: 20)
        openBackupRestore()
        XCTAssertEqual(toggle.value as? String, "Off")
        XCTAssertFalse(app.windows.matching(NSPredicate(format: "label BEGINSWITH %@", "automaticBackup:")).firstMatch.exists)
        app.terminate()
    }
}
