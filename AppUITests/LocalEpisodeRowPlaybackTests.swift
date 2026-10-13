import XCTest

/// The existing opt-in local fixture registers/scans real sandbox WAV files.
/// Its target moves on pause; use the survivor for stable playback/relaunch.
/// This is not an external provider-grant or physical-audio acceptance test.
final class LocalEpisodeRowPlaybackTests: XCTestCase {
    @MainActor private func label(_ element: XCUIElement, _ expected: String) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate:
            NSPredicate(format: "label == %@", expected), object: element)], timeout: 20), .completed)
    }
    @MainActor private func action(in app: XCUIApplication) -> XCUIElement {
        let row = app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'episode-' AND label == %@", "Removal survivor")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        let id = String(row.identifier.dropFirst("episode-".count))
        let action = app.buttons["episode-action-" + id]
        XCTAssertTrue(action.exists && action.isEnabled)
        return action
    }
    @MainActor private func awaitAdvancingPlayback(_ app: XCUIApplication) {
        app.buttons["miniPlayerOpen"].tap()
        let position = app.staticTexts["playerPosition"]
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        let initial = position.label
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate:
            NSPredicate(format: "label != %@", initial), object: position)], timeout: 20), .completed)
        app.buttons["playerCollapse"].tap()
    }

    @MainActor func testGenericLocalRowPlaysPausesAndRestoresSelectionAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString,
            "-test-muted-playback", "-test-removed-episode-refresh"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["QueueFragment"].waitForExistence(timeout: 10))
        app.buttons["QueueFragment"].tap()
        let play = action(in: app)
        label(play, "Play")
        play.tap()
        label(app.buttons["miniPlayerOpen"], "Removal survivor. Removal refresh folder")
        label(play, "Pause")
        awaitAdvancingPlayback(app)
        play.tap(); label(play, "Play"); label(app.buttons["miniPlayerPlay"], "Play")

        app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 5))
        app.buttons["subscriptionFeed-1"].tap()
        let feedAction = action(in: app)
        label(feedAction, "Play"); feedAction.tap(); label(feedAction, "Pause")
        awaitAdvancingPlayback(app)
        feedAction.tap(); label(feedAction, "Play")

        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["QueueFragment"].waitForExistence(timeout: 10))
        app.buttons["QueueFragment"].tap()
        let restored = action(in: app)
        label(restored, "Play")
        label(app.buttons["miniPlayerOpen"], "Removal survivor. Removal refresh folder")
        label(app.buttons["miniPlayerPlay"], "Play")
        restored.tap(); label(restored, "Pause")
        awaitAdvancingPlayback(app)
        restored.tap(); label(restored, "Play")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH 'episode-' AND label == %@", "Removal target")).firstMatch.exists)
    }
}
