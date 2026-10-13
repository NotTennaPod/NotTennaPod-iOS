import XCTest

/// Actual journey on a UUID test library that is playing a downloaded episode (muted):
/// Settings → Backup & restore → Database import → No (nothing) → Confirm → real Files picker →
/// a real Android 3.12.1 backup → "Import successful" (not dismissible) → OK recreates the app with
/// the restored library, playback stopped; relaunch keeps it. Then a newer-version file shows
/// "Import error" and changes nothing. The runner checks the saved library independently.
@MainActor final class DatabaseImportJourneyTests: XCTestCase {
    // Fresh per test (XCTest makes one instance per test method): test01 replaces its library with the
    // imported backup, so a shared or fixed ID would not start clean.
    private let library = UUID().uuidString
    private var app = XCUIApplication()
    override func setUp() {
        continueAfterFailure = false
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback", "-test-list-inbox-cleanup"]
    }

    private func tap(_ id: String, timeout: TimeInterval = 15) {
        let button = app.buttons[id]; XCTAssertTrue(button.waitForExistence(timeout: timeout), id + "\n" + app.debugDescription)
        XCTAssertTrue(button.isHittable, id); button.tap()
    }
    private func destination(_ id: String, title: String) {
        if app.buttons[id].exists { app.buttons[id].tap() } else { tap("navigationMore"); tap(title) }
    }
    private func waitLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 20) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, "\(label): \(element.exists ? element.label : "missing")")
    }
    /// Labels over 128 characters cannot be subscripted; match them by predicate.
    private func label(_ text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
    }
    private func openBackupRestore() {
        tap("navigationMore"); tap("Settings"); tap("Backup & restore")
        XCTAssertTrue(app.buttons["databaseImport"].waitForExistence(timeout: 10))
    }
    /// Real system picker in open mode: choose a file from the device's local root, which holds only the
    /// seeded documents (export tests remove theirs). On a small screen a file in the last row can still
    /// lie under the picker's floating bottom bar, where a tap selects nothing (Duo). Scroll the
    /// file grid until the file sits in its upper half, or the grid stops moving (the last row then
    /// clears the bar).
    private func pick(_ prefix: String) {
        let file = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
        app.openLocalFilesRoot()
        let grid = app.collectionViews.matching(identifier: "File View").firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 10), app.debugDescription)
        var previous = CGRect.null
        for _ in 0..<8 {
            if file.exists {
                let frame = file.frame
                if frame.midY <= grid.frame.midY || frame == previous { break }
                previous = frame
            }
            grid.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(file.exists && file.isHittable, app.debugDescription)
        file.tap()
        // Choosing a file closes the picker. If it stays open, the tap selected nothing; that is not an app result
        // (the cell lay under the picker's top bar).
        let picker = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "DOC.browsingRoot")).firstMatch
        XCTAssertTrue(picker.waitForNonExistence(timeout: 15), "The picker closes with the chosen file\n" + app.debugDescription)
    }
    /// Queue rows in order (`episode-<id>`), the library state a failed import must leave unchanged.
    private func queueEpisodes() -> [String] {
        destination("QueueFragment", title: "Queue")
        let rows = app.buttons.matching(NSPredicate(format: "identifier MATCHES %@", "episode-[0-9]+"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        return rows.allElementsBoundByIndex.map(\.identifier)
    }

    func test01ImportWhilePlayingReplacesLibraryAndRecreatesApp() {
        app.launch()
        destination("QueueFragment", title: "Queue")
        let action = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "episode-action-")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 20), app.debugDescription)
        waitLabel(action, "Play"); action.tap()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 15))
        waitLabel(app.buttons["miniPlayerPlay"], "Pause")

        openBackupRestore()
        let export = app.buttons["databaseExport"], restore = app.buttons["databaseImport"], opml = app.buttons["opmlExport"]
        XCTAssertLessThan(export.frame.maxY, restore.frame.maxY); XCTAssertLessThan(restore.frame.maxY, opml.frame.maxY)
        XCTAssertEqual(restore.label, "Database import")

        restore.tap()
        XCTAssertTrue(app.staticTexts["Database import"].waitForExistence(timeout: 10))
        XCTAssertTrue(label("Importing a database will replace all of your current subscriptions and playing history. You should export your current database as a backup. Do you want to replace?").exists)
        tap("databaseImportNo")
        XCTAssertTrue(app.buttons["databaseImportNo"].waitForNonExistence(timeout: 10))
        // No changes nothing: back out of Settings (which shows no player) and the episode is still playing.
        tap("toolbarBack"); tap("toolbarBack")
        XCTAssertTrue(app.buttons["miniPlayerPlay"].waitForExistence(timeout: 10), app.debugDescription)
        waitLabel(app.buttons["miniPlayerPlay"], "Pause")

        openBackupRestore()
        restore.tap(); tap("databaseImportConfirm")
        pick("emulator-parity-library")
        XCTAssertTrue(app.staticTexts["Import successful"].waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Please press OK to restart NotTennaPod"].exists)
        tap("databaseImportRestart")

        // Fresh application state: the restored library, nothing playing.
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 3), "Playback of the replaced library ended")
        destination("QueueFragment", title: "Queue")
        XCTAssertTrue(app.buttons["episode-20"].waitForExistence(timeout: 15), app.debugDescription)
        destination("SubscriptionFragment", title: "Subscriptions")
        XCTAssertTrue(app.buttons["subscriptionFeed-19"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.buttons["subscriptionFeed-10"].exists)
        XCTAssertFalse(app.buttons["subscriptionFeed-8"].exists, "Preview feeds are not subscriptions")

        app.terminate(); app.launch()
        destination("QueueFragment", title: "Queue")
        XCTAssertTrue(app.buttons["episode-20"].waitForExistence(timeout: 15), "Relaunch keeps the restored library")
        app.terminate()
    }

    /// Independent of test01: compares the library before and after the failed imports.
    func test02NewerVersionShowsImportErrorAndChangesNothing() {
        app.launch()
        let before = queueEpisodes()
        openBackupRestore()
        tap("databaseImport"); tap("databaseImportConfirm")
        pick("newer-version-backup")
        XCTAssertTrue(app.staticTexts["Import error"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(label("This database was exported with a newer version of NotTennaPod. Your current installation does not yet know how to handle this file.").exists)
        tap("sourceMessageOK")
        XCTAssertTrue(app.buttons["databaseImport"].waitForExistence(timeout: 10))
        tap("databaseImport"); tap("databaseImportConfirm")
        pick("not-a-database")
        XCTAssertTrue(app.staticTexts["Import error"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts["file is not a database"].exists)
        tap("sourceMessageOK")
        app.terminate(); app.launch()
        XCTAssertEqual(queueEpisodes(), before, "Failed imports left the library unchanged")
        app.terminate()
    }
}
