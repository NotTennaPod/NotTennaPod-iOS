import XCTest

/// Settings search journey:
/// More → Settings → the search card → typing "black" lists Full black first with "User interface > Theming"; it opens
/// User interface with the Full black row on screen; Back returns to the same results, Back again to Settings.
/// Typing "speed" lists the global and the podcast Playback speed with their breadcrumbs; the podcast one explains
/// itself in a "Podcast settings" dialog; the global one opens Playback at its row. Expected texts are Android's.
@MainActor final class SettingsSearchJourneyTests: XCTestCase {
    private let library = UUID().uuidString
    private var app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback"]
    }

    private func openSearch() -> XCUIElement {
        let more = app.buttons["navigationMore"]
        XCTAssertTrue(more.waitForExistence(timeout: 30), app.debugDescription)
        more.tap()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5)); settings.tap()
        let card = app.buttons["searchPreference"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(card.label, "Search…")
        card.tap()
        let field = app.textFields["settingsSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard opens on the field")
        XCTAssertEqual(app.staticTexts["screenTitle"].label, "Settings")
        return field
    }

    private func result(_ index: Int) -> XCUIElement { app.buttons["settingsSearchResult-\(index)"] }

    /// Evidence screenshots, kept in the result bundle.
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The element is fully inside the app window and not under the keyboard.
    private func visible(_ element: XCUIElement) -> Bool {
        let window = app.windows.firstMatch.frame
        let keyboard = app.keyboards.firstMatch
        let bottom = keyboard.exists ? min(window.maxY, keyboard.frame.minY) : window.maxY
        return element.isHittable && window.contains(element.frame) && element.frame.maxY <= bottom + 1
    }

    func test01BlackOpensFullBlackAndBackKeepsTheResults() {
        app.launch()
        let field = openSearch()
        field.typeTextSettled("black")
        let first = result(0)
        XCTAssertTrue(first.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(first.label, "Full black")
        XCTAssertEqual(first.value as? String, "User interface > Theming")
        XCTAssertTrue(visible(first))
        XCTAssertTrue(result(9).exists && !result(10).exists, "ten results at most")
        capture("m33-black-results")
        first.tapWhenSettled()
        let row = app.buttons["prefThemeBlack"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.staticTexts["screenTitle"].label, "User interface")
        XCTAssertTrue(visible(row), "navigation lands on Full black: \(row.frame)")
        capture("m33-black-user-interface")
        app.buttons["toolbarBack"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "black", "Back returns to the search page with its query")
        XCTAssertEqual(result(0).label, "Full black")
        app.buttons["toolbarBack"].tap()
        XCTAssertTrue(app.buttons["prefScreenInterface"].waitForExistence(timeout: 5), "then to Settings")
        XCTAssertFalse(field.exists)
    }

    func test02SpeedShowsGlobalAndPodcastResultsWithBreadcrumbs() {
        app.launch()
        let field = openSearch()
        field.typeTextSettled("speed")
        let global = result(0), podcast = result(1)
        XCTAssertTrue(podcast.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(global.label, "Playback speed")
        XCTAssertEqual(global.value as? String, "Playback > Playback control")
        XCTAssertEqual(podcast.label, "Playback speed")
        XCTAssertEqual(podcast.value as? String, "Podcast settings > Playback")
        XCTAssertLessThanOrEqual(global.frame.maxY, podcast.frame.minY + 1)
        capture("m33-speed-results")
        podcast.tapWhenSettled()
        let message = app.staticTexts["This setting is unique to each podcast. You can change it by opening the podcast page."]
        XCTAssertTrue(message.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Podcast settings"].exists)
        capture("m33-speed-podcast-dialog")
        app.buttons["sourceMessageOK"].tapWhenSettled()
        XCTAssertTrue(message.waitForNonExistence(timeout: 5))
        XCTAssertTrue(global.exists, "the dialog leaves the results in place")
        global.tapWhenSettled()
        let row = app.buttons["prefPlaybackSpeedLauncher"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.staticTexts["screenTitle"].label, "Playback")
        XCTAssertTrue(visible(row), "navigation lands on Playback speed: \(row.frame)")
    }
}
