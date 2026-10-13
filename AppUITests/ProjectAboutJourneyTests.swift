import XCTest

/// Journey: More → Settings (no rating or other prompt on launch) → About says NotTennaPod is not AntennaPod, with
/// its version and licences, and Back returns; a one-time statement says the same on the first launch. The Settings
/// root's composition (Android's order, Project with only About, the static notice last, right-to-left) is checked
/// by SettingsRootViewTests.
@MainActor final class ProjectAboutJourneyTests: XCTestCase {
    private let library = UUID().uuidString
    private var app = XCUIApplication()
    static let rows = ["prefScreenInterface", "prefScreenPlayback", "prefScreenDownloads", "prefScreenSynchronization",
                       "prefScreenImportExport", "notifications"]
    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback"]
    }

    private func openSettings() {
        let more = app.buttons["navigationMore"]
        XCTAssertTrue(more.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertEqual(app.alerts.count, 0, "no rating or other prompt on launch")
        more.tap()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5)); settings.tap()
        XCTAssertTrue(app.buttons[Self.rows[0]].waitForExistence(timeout: 5), app.debugDescription)
    }

    /// Scrolls until the notice, the last row, is fully in the visible list (About is then above it).
    private func scrollToNotice() -> XCUIElement {
        let notice = app.staticTexts["settingsSpinOffNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<6 where !notice.isRevealed(in: app) { app.swipeUp() }
        XCTAssertTrue(notice.isRevealed(in: app), "notice fully visible: \(notice.frame)")
        return notice
    }

    func test03AboutSaysNotTennaPodIsNotAntennaPod() {
        app.launch()
        openSettings()
        _ = scrollToNotice()
        app.buttons["prefAbout"].tapWhenSettled()
        let title = app.staticTexts["aboutStatementTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(title.label, "NotTennaPod is not AntennaPod")
        let statement = app.staticTexts["aboutStatement"]
        XCTAssertTrue(statement.label.contains("no native AntennaPod for iOS") && statement.label.contains("has nothing to do with NotTennaPod"))
        let window = app.windows.firstMatch.frame
        let licenses = app.buttons["about_licenses"]
        for _ in 0..<4 where !(licenses.isHittable && window.contains(licenses.frame)) { app.swipeUp() }
        XCTAssertTrue(app.buttons["about_version"].exists && app.buttons["about_version"].label == "NotTennaPod version")
        licenses.tapWhenSettled()
        XCTAssertTrue(app.staticTexts["license-0"].waitForExistence(timeout: 5) || app.otherElements["license-0"].waitForExistence(timeout: 1),
                      app.debugDescription)
        app.buttons["toolbarBack"].tapWhenSettled()
        XCTAssertTrue(app.buttons["about_licenses"].waitForExistence(timeout: 5))
    }

    /// The first launch shows the statement once: it is gone after OK and on the next launch.
    func test04FirstLaunchStatementShowsOnce() {
        app.launchArguments += ["-test-first-launch-notice"]
        app.launch()
        let heading = app.staticTexts["sourceMessageTitle"]
        XCTAssertTrue(heading.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertEqual(heading.label, "NotTennaPod is not AntennaPod")
        XCTAssertTrue(app.staticTexts["sourceMessage"].label.contains("Please don't report NotTennaPod problems to the AntennaPod team"))
        app.buttons["sourceMessageOK"].tapWhenSettled()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 5))
        XCTAssertFalse(heading.exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.staticTexts["sourceMessageTitle"].waitForExistence(timeout: 3), "shown only once")
    }
}
