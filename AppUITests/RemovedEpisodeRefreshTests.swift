import XCTest

/// No server. The opt-in fixture supplies test-owned local documents and moves
/// the target after real Play→Pause; only visible Refresh performs removal.
final class RemovedEpisodeRefreshTests: XCTestCase {
    @MainActor private func label(_ element: XCUIElement, _ expected: String) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate:
            NSPredicate(format: "label == %@", expected), object: element)], timeout: 20), .completed)
    }
    @MainActor private func row(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'episode-' AND label BEGINSWITH %@", title)).firstMatch
    }
    @MainActor private func awaitProgressThenPause(_ app: XCUIApplication) {
        app.buttons["miniPlayerOpen"].tap()
        let position = app.staticTexts["playerPosition"]
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        let initial = position.label
        // The Pause label reflects requested playback, even while loading.
        // Advancing media time establishes that real playback actually began.
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate:
            NSPredicate(format: "label != %@", initial), object: position)], timeout: 20), .completed)
        app.buttons["playerPlay"].tap(); label(app.buttons["playerPlay"], "Play")
        app.buttons["playerCollapse"].tap()
    }

    @MainActor func testLocalRefreshRemovesPausedSelectionKeepsSurvivorAndPersistsAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback", "-test-removed-episode-refresh"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["QueueFragment"].waitForExistence(timeout: 10))
        app.buttons["QueueFragment"].tap()
        let removed = row("Removal target", in: app), survivor = row("Removal survivor", in: app)
        XCTAssertTrue(removed.waitForExistence(timeout: 20))
        XCTAssertTrue(survivor.waitForExistence(timeout: 5))
        XCTAssertLessThan(removed.frame.minY, survivor.frame.minY)
        removed.tap()
        XCTAssertTrue(app.buttons["episodePrimaryAction"].waitForExistence(timeout: 5))
        app.buttons["episodePrimaryAction"].tap()
        label(app.buttons["miniPlayerPlay"], "Pause")
        label(app.buttons["miniPlayerOpen"], "Removal target. Removal refresh folder")
        awaitProgressThenPause(app)
        label(app.buttons["miniPlayerPlay"], "Play")
        app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 5))
        app.buttons["subscriptionFeed-1"].tap()
        XCTAssertTrue(removed.waitForExistence(timeout: 5))
        app.buttons["feedListMore"].tap(); app.buttons["refreshFeed"].tap()
        XCTAssertTrue(removed.waitForNonExistence(timeout: 20))
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(survivor.exists)
        app.buttons["QueueFragment"].tap()
        XCTAssertTrue(survivor.waitForExistence(timeout: 5)); XCTAssertFalse(removed.exists)
        survivor.tap()
        XCTAssertTrue(app.buttons["episodePrimaryAction"].waitForExistence(timeout: 5))
        app.buttons["episodePrimaryAction"].tap()
        label(app.buttons["miniPlayerPlay"], "Pause")
        label(app.buttons["miniPlayerOpen"], "Removal survivor. Removal refresh folder")
        awaitProgressThenPause(app); label(app.buttons["miniPlayerPlay"], "Play")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["QueueFragment"].waitForExistence(timeout: 10)); app.buttons["QueueFragment"].tap()
        XCTAssertTrue(survivor.waitForExistence(timeout: 10)); XCTAssertFalse(removed.exists)
        label(app.buttons["miniPlayerOpen"], "Removal survivor. Removal refresh folder")
        label(app.buttons["miniPlayerPlay"], "Play")
        app.buttons["SubscriptionFragment"].tap(); app.buttons["subscriptionFeed-1"].tap()
        XCTAssertTrue(survivor.waitForExistence(timeout: 5)); XCTAssertFalse(removed.exists)
    }
}
