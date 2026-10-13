import XCTest

final class PlayerShareTests: XCTestCase {
    @MainActor func testPlayerSharePositionCancelCopyAndRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18765/feed.xml")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15)); app.buttons["subscribeFeed"].tap()
        let episode = app.buttons["episode-action-1"]
        XCTAssertTrue(episode.waitForExistence(timeout: 5)); episode.tap(); label(episode, "Play")
        episode.tap(); label(app.buttons["miniPlayerPlay"], "Pause"); app.buttons["miniPlayerPlay"].tap()
        app.buttons["miniPlayerOpen"].tap()
        let share = app.buttons["playerShare"]
        XCTAssertTrue(share.waitForExistence(timeout: 5) && share.isHittable)
        label(app.buttons["playerPlay"], "Play")
        let savedPausePosition = app.staticTexts["playerPosition"].label
        XCTAssertGreaterThan(share.frame.minX, app.buttons["playerFavorite"].frame.maxX)
        let seek = app.descendants(matching: .any)["playerSeek"]
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        label(app.staticTexts["playerPosition"], "00:00:15")
        share.tap()
        let position = app.buttons["episodeSharePosition"]
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        if position.value as? String == "Checked" { position.tap() }
        XCTAssertEqual(position.value as? String, "Not checked")
        let social = app.buttons["episodeShareSocial"]
        XCTAssertFalse((social.value as? String ?? "").contains("Starting from"))
        position.tap()
        XCTAssertEqual(position.value as? String, "Checked")
        XCTAssertTrue((social.value as? String ?? "").contains("Starting from: 00:00:15"))
        XCTAssertTrue((social.value as? String ?? "").contains("#t=15"))
        XCTAssertTrue(app.buttons["episodeShareFile"].exists)
        XCTAssertTrue(app.buttons["episodeShareMediaAddress"].exists)
        let panel = app.otherElements["episodeShareSheet"]
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: panel.frame.midX - app.frame.minX, dy: panel.frame.minY - app.frame.minY - 12)).tap()
        XCTAssertTrue(position.waitForNonExistence(timeout: 5))
        XCTAssertTrue(share.isHittable)
        label(app.buttons["playerPlay"], "Play"); label(app.staticTexts["playerPosition"], "00:00:15")
        share.tap(); XCTAssertTrue(position.waitForExistence(timeout: 5))
        XCTAssertEqual(position.value as? String, "Checked")
        social.tap()
        let copy = app.cells["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10)); copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5)); XCTAssertTrue(share.isHittable)
        label(app.staticTexts["playerPosition"], "00:00:15")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 10)); app.buttons["miniPlayerOpen"].tap()
        // Force termination restores the saved pause, not the unsaved paused seek (as on Android).
        label(app.staticTexts["playerPosition"], savedPausePosition)
        share.tap(); XCTAssertTrue(position.waitForExistence(timeout: 5))
        XCTAssertEqual(position.value as? String, "Checked")
        XCTAssertTrue((social.value as? String ?? "").contains("Starting from: \(savedPausePosition)"))
    }
    @MainActor private func label(_ element: XCUIElement, _ expected: String) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: element)], timeout: 20), .completed)
    }
}
