import XCTest

final class ShownotesLinkActionsTests: XCTestCase {
    @MainActor func testEpisodeAndPlayerLongPressActions() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap()
        address.typeTextSettled("http://127.0.0.1:18765/shownotes-actions.xml"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 20)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5)); app.buttons["episode-1"].tap()
        let notes = app.webViews["episodeShownotes"]
        XCTAssertTrue(notes.links["Website action"].waitForExistence(timeout: 10))
        notes.links["Website action"].press(forDuration: 1)
        let copy = app.buttons["shownotesLink-copy_url_label"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["shownotesLink-open_in_browser_label"].exists)
        XCTAssertTrue(app.buttons["shownotesLink-share_url_label"].exists)
        XCTAssertEqual(copy.label, "Copy URL")
        XCTAssertEqual(app.buttons["shownotesLink-open_in_browser_label"].label, "Open in browser")
        XCTAssertEqual(app.buttons["shownotesLink-share_url_label"].label, "Share URL")
        let panel = app.otherElements["shownotesLinkMenu"]
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: panel.frame.midX - app.frame.minX, dy: panel.frame.minY - app.frame.minY - 12)).tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        notes.links["Website action"].press(forDuration: 1)
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        // Original menu rows include their horizontal text padding in the hit target.
        copy.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        verifyPaste("https://example.invalid/path?q=one%20two&x=3", app)
        app.buttons["episode-1"].tap()
        XCTAssertTrue(notes.links["Position action"].waitForExistence(timeout: 10))
        notes.links["Position action"].press(forDuration: 1)
        let seek = app.buttons["shownotesLink-go_to_position_label"]
        XCTAssertTrue(seek.waitForExistence(timeout: 5)); XCTAssertFalse(copy.exists)
        XCTAssertEqual(app.staticTexts["shownotesLinkTitle"].label, "00:00:15")
        seek.tap()
        XCTAssertTrue(app.staticTexts["To jump to positions, you need to play the episode"].waitForExistence(timeout: 5))
        notes.links["Email action"].press(forDuration: 1)
        XCTAssertFalse(copy.exists)
        verifyPaste("hello@example.invalid", app)
        let download = app.buttons["episode-action-1"]
        XCTAssertTrue(download.waitForExistence(timeout: 5)); download.tap(); label(download, "Play")
        download.tap(); label(app.buttons["miniPlayerPlay"], "Pause"); app.buttons["miniPlayerPlay"].tap()
        app.buttons["miniPlayerOpen"].tap(); app.buttons["playerShownotes"].tap()
        let playerNotes = app.webViews["playerShownotesContent"]
        XCTAssertTrue(playerNotes.links["Position action"].waitForExistence(timeout: 5))
        playerNotes.links["Position action"].press(forDuration: 1)
        XCTAssertTrue(seek.waitForExistence(timeout: 5)); seek.tap()
        label(app.staticTexts["playerPosition"], "00:00:15"); label(app.buttons["playerPlay"], "Play")
        playerNotes.links["Website action"].press(forDuration: 1)
        let share = app.buttons["shownotesLink-share_url_label"]
        XCTAssertTrue(share.waitForExistence(timeout: 5)); share.tap()
        let systemCopy = app.cells["Copy"]
        XCTAssertTrue(systemCopy.waitForExistence(timeout: 10)); systemCopy.tap()
        XCTAssertTrue(systemCopy.waitForNonExistence(timeout: 5))
        label(app.buttons["playerPlay"], "Play")
        playerNotes.links["Website action"].press(forDuration: 1)
        let browserAction = app.buttons["shownotesLink-open_in_browser_label"]
        XCTAssertTrue(browserAction.waitForExistence(timeout: 5)); browserAction.tap()
        let browser = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(browser.wait(for: .runningForeground, timeout: 15)); app.activate()
        label(app.buttons["playerPlay"], "Play")
        XCTAssertTrue(playerNotes.links["Position action"].waitForExistence(timeout: 5))
        let scrubber = app.descendants(matching: .any)["playerSeek"]
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        XCTAssertNotEqual(app.staticTexts["playerPosition"].label, "00:00:15")
        app.buttons["playerCollapse"].tap(); app.buttons["episode-1"].tap()
        XCTAssertTrue(notes.links["Position action"].waitForExistence(timeout: 10))
        notes.links["Position action"].press(forDuration: 1)
        XCTAssertTrue(seek.waitForExistence(timeout: 5)); seek.tap()
        app.buttons["miniPlayerOpen"].tap()
        label(app.staticTexts["playerPosition"], "00:00:15"); label(app.buttons["playerPlay"], "Play")
        app.buttons["playerCollapse"].tap()
        verifyPaste("https://example.invalid/path?q=one%20two&x=3", app)
    }
    @MainActor private func verifyPaste(_ expected: String, _ app: XCUIApplication) {
        // The UI runner is backgrounded and cannot read the app's pasteboard.
        // Verify the user-visible result by pasting into the actual address field.
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let field = app.textFields["rssAddress"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        field.press(forDuration: 1)
        let paste = app.menuItems["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        // A menu-item tap makes XCTest misclassify its owning alert as an
        // interruption. Tap the actual observed menu bounds without that handler.
        let point = paste.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: point.midX - app.frame.minX, dy: point.midY - app.frame.minY)).tap()
        XCTAssertTrue(paste.waitForNonExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, expected)
        app.buttons["Cancel"].tap(); app.navigation("Subscriptions").tap(); app.buttons["Shownotes actions"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5))
    }
    @MainActor private func label(_ element: XCUIElement, _ expected: String) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: element)], timeout: 25), .completed)
    }
}
