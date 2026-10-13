import XCTest

final class ShownotesHitTypesTests: XCTestCase {
    @MainActor func testSourceSelectionToolbarActions() {
        continueAfterFailure = false
        let app = openFixture()
        let notes = app.webViews["episodeShownotes"]
        XCTAssertTrue(notes.staticTexts["Selectableword"].waitForExistence(timeout: 10))
        notes.staticTexts["Selectableword"].press(forDuration: 1)
        XCTAssertTrue(app.buttons["shownotesSelection-copy"].waitForExistence(timeout: 5))
        let firstPage = app.otherElements["shownotesSelectionToolbar"].buttons.allElementsBoundByIndex.filter { $0.identifier != "shownotesSelection-more" }.map(\.label)
        XCTAssertEqual(firstPage, ["Copy", "Share", "Select all", "Web search"])
        XCTAssertTrue(app.menuItems.allElementsBoundByIndex.isEmpty)
        selectionShareAndSearch(notes, app, "Episode")
        verifySelectionPaste(app, expected: "Mixed link text Selectableword Text link")
        openPausedPlayer(app)
        selectionShareAndSearch(app.webViews["playerShownotesContent"], app, "Player")
        XCTAssertEqual(app.buttons["playerPlay"].label, "Play")
        app.buttons["playerCollapse"].tap()
        verifySelectionPaste(app, expected: "Mixed link text Selectableword Text link")
    }
    @MainActor private func selectionShareAndSearch(_ notes: XCUIElement, _ app: XCUIApplication, _ surface: String) {
        if !app.buttons["shownotesSelection-copy"].exists {
            // The player's notes load when the player first opens; wait for the text before holding it.
            XCTAssertTrue(notes.staticTexts["Selectableword"].waitForExistence(timeout: 10))
            notes.staticTexts["Selectableword"].press(forDuration: 1)
            XCTAssertTrue(app.buttons["shownotesSelection-copy"].waitForExistence(timeout: 5))
        }
        let search = app.buttons["shownotesSelection-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap()
        let browser = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(browser.wait(for: .runningForeground, timeout: 15))
        let exactQuery = browser.textFields.matching(NSPredicate(format: "value == %@", "Selectableword")).firstMatch.waitForExistence(timeout: 15)
        XCTAssertTrue(exactQuery)
        app.activate()
        XCTAssertTrue(notes.staticTexts["Selectableword"].waitForExistence(timeout: 5))
        // Test the word search before expanding the range. A tap within a
        // retained range toggles its menu instead of creating a new selection.
        notes.staticTexts["Selectableword"].press(forDuration: 1)
        let all = app.buttons["shownotesSelection-all"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 5)); all.tap()
        let share = app.buttons["shownotesSelection-share"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 5)); share.tap()
        let systemCopy = app.cells["Copy"]
        XCTAssertTrue(systemCopy.waitForExistence(timeout: 10))
        systemCopy.tap(); XCTAssertTrue(systemCopy.waitForNonExistence(timeout: 5))
    }

    @MainActor func testImageHoldsTextSelectionAndOrdinaryLinkOnBothSurfaces() {
        continueAfterFailure = false
        let app = openFixture()
        exercise(app.webViews["episodeShownotes"], app, "Episode")
        verifySelectionPaste(app)
        openPausedPlayer(app)
        exercise(app.webViews["playerShownotesContent"], app, "Player")
        XCTAssertEqual(app.buttons["playerPlay"].label, "Play")
        app.buttons["playerCollapse"].tap()
        verifySelectionPaste(app)
    }
    @MainActor func testSelectAllRetainsImageAnchorText() {
        continueAfterFailure = false
        let app = openFixture()
        selectAllAndCopy(app.webViews["episodeShownotes"], app, "Episode")
        verifySelectionPaste(app, expected: "Linked imageMixed link text Plain image Selectableword Text link")
        openPausedPlayer(app)
        selectAllAndCopy(app.webViews["playerShownotesContent"], app, "Player")
        XCTAssertEqual(app.buttons["playerPlay"].label, "Play")
        app.buttons["playerCollapse"].tap()
        verifySelectionPaste(app, expected: "Linked imageMixed link text Plain image Selectableword Text link")
    }
    @MainActor private func selectAllAndCopy(_ notes: XCUIElement, _ app: XCUIApplication, _ surface: String) {
        XCTAssertTrue(notes.staticTexts["Selectableword"].waitForExistence(timeout: 10))
        notes.staticTexts["Selectableword"].press(forDuration: 1)
        let copy = app.buttons["shownotesSelection-copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        let all = app.buttons["shownotesSelection-all"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 5)); all.tap()
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        let rect = copy.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rect.midX - app.frame.minX, dy: rect.midY - app.frame.minY)).tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
    }
    @MainActor private func openPausedPlayer(_ app: XCUIApplication) {
        let download = app.buttons["episode-action-1"]
        XCTAssertTrue(download.waitForExistence(timeout: 5)); download.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Play'"), object: download)], timeout: 25), .completed)
        download.tap()
        let mini = app.buttons["miniPlayerPlay"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Pause'"), object: mini)], timeout: 10), .completed)
        mini.tap(); app.buttons["miniPlayerOpen"].tap(); app.buttons["playerShownotes"].tap()
    }
    @MainActor private func openFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let field = app.textFields["rssAddress"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        field.typeTextSettled("http://127.0.0.1:18765/shownotes-hit-types.xml"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 20)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5)); app.buttons["episode-1"].tap()
        return app
    }
    @MainActor private func exercise(_ notes: XCUIElement, _ app: XCUIApplication, _ surface: String) {
        XCTAssertTrue(notes.links["Text link"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["SCRIPT RAN"].exists)
        for name in ["Linked image", "Plain image"] {
            let image = notes.images[name].firstMatch
            XCTAssertTrue(image.waitForExistence(timeout: 5))
            image.press(forDuration: 1)
            XCTAssertFalse(app.otherElements["shownotesLinkMenu"].exists)
            XCTAssertFalse(app.buttons["shownotesSelection-copy"].exists)
            XCTAssertFalse(app.menuItems["Copy"].exists)
            XCTAssertFalse(app.buttons["Save Image"].exists)
            XCTAssertTrue(notes.links["Text link"].isHittable)
        }
        // Android classifies the entire anchor as an image link, including
        // its text child. Hold the actual text node, not the image-containing box.
        let mixed = notes.staticTexts["Mixed link text"].firstMatch
        XCTAssertTrue(mixed.waitForExistence(timeout: 5)); mixed.press(forDuration: 1)
        XCTAssertFalse(app.otherElements["shownotesLinkMenu"].exists)
        XCTAssertFalse(app.buttons["shownotesSelection-copy"].exists)
        XCTAssertFalse(app.menuItems["Copy"].exists)
        notes.links["Text link"].press(forDuration: 1)
        let copy = app.buttons["shownotesLink-copy_url_label"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["shownotesLinkTitle"].label, "https://example.invalid/text")
        copy.tap(); XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        let text = notes.staticTexts["Selectableword"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5)); text.press(forDuration: 1)
        let selectionCopy = app.buttons["shownotesSelection-copy"].firstMatch
        XCTAssertTrue(selectionCopy.waitForExistence(timeout: 5))
        let rect = selectionCopy.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rect.midX - app.frame.minX, dy: rect.midY - app.frame.minY)).tap()
        XCTAssertTrue(selectionCopy.waitForNonExistence(timeout: 5))
        notes.images["Linked image"].firstMatch.tap()
        let browser = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(browser.wait(for: .runningForeground, timeout: 15))
        app.activate()
        XCTAssertTrue(notes.links["Text link"].waitForExistence(timeout: 5))
    }
    @MainActor private func verifySelectionPaste(_ app: XCUIApplication, expected: String = "Selectableword") {
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let field = app.textFields["rssAddress"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.press(forDuration: 1)
        let paste = app.menuItems["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        let rect = paste.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rect.midX - app.frame.minX, dy: rect.midY - app.frame.minY)).tap()
        XCTAssertTrue(paste.waitForNonExistence(timeout: 5)); XCTAssertEqual((field.value as? String)?.split(whereSeparator: \.isWhitespace).joined(separator: " "), expected)
        app.buttons["Cancel"].tap(); app.navigation("Subscriptions").tap(); app.buttons["Shownotes hit types"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5))
    }
}
