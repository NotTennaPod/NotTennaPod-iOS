import XCTest

/// Requires the existing listening fixture on 127.0.0.1:18765. All media,
/// settings and playback changes are made through the application's controls.
final class KeepSkippedEpisodesTests: XCTestCase {
    @MainActor func testDefaultOnRetainsEarlySkippedEpisodeAcrossRelaunch() {
        journey(keep: true)
    }

    // Also proves the Off choice is saved: it is read back after the relaunch.
    @MainActor func testImmediateOffRemovesEarlySkippedEpisodeAcrossRelaunch() {
        journey(keep: false)
    }

    @MainActor private func journey(keep: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication(), library = UUID().uuidString
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap()
        address.typeTextSettled("http://127.0.0.1:18765/feed.xml")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15)); app.buttons["subscribeFeed"].tap()
        for id in [1, 2] {
            let action = app.buttons["episode-action-\(id)"]
            XCTAssertTrue(action.waitForExistence(timeout: 5)); action.tap(); label(action, "Play")
        }
        openSettings(app)
        // The fixture lasts thirty seconds, so disable the separate smart
        // completion rule before selecting it to exercise an early skip.
        let smart = app.buttons["prefSmartMarkAsPlayedSecs"]
        reveal(smart, in: app); smart.tap()
        XCTAssertTrue(app.buttons["prefSmartMarkAsPlayedSecs-0"].waitForExistence(timeout: 5))
        app.buttons["prefSmartMarkAsPlayedSecs-0"].tap()
        let setting = app.buttons["prefSkipKeepsEpisode"]
        reveal(setting, in: app)
        XCTAssertEqual(setting.label, "Keep skipped episodes")
        XCTAssertEqual(setting.value as? String, "On")
        XCTAssertGreaterThan(setting.frame.minY, smart.frame.minY)
        leaveSettings(app)
        app.buttons["QueueFragment"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["episode-2"].exists)
        XCTAssertLessThan(app.buttons["episode-1"].frame.minY, app.buttons["episode-2"].frame.minY)
        app.buttons["episode-action-1"].tap(); label(app.buttons["miniPlayerPlay"], "Pause")
        app.buttons["miniPlayerPlay"].tap(); label(app.buttons["miniPlayerPlay"], "Play")
        app.buttons["miniPlayerOpen"].tap()
        let seek = app.descendants(matching: .any)["playerSeek"]
        XCTAssertTrue(seek.waitForExistence(timeout: 5))
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate:
            NSPredicate(format: "label MATCHES %@", "00:00:1[0-4]"), object: app.staticTexts["playerPosition"])], timeout: 10), .completed)
        let position = app.staticTexts["playerPosition"].label
        app.buttons["playerCollapse"].tap()
        if !keep {
            // Change after selection: the coordinator must read the live value
            // when Skip executes rather than a launch/selection-time snapshot.
            openSettings(app); reveal(setting, in: app)
            XCTAssertEqual(setting.value as? String, "On")
            setting.tap(); XCTAssertEqual(setting.value as? String, "Off")
            leaveSettings(app)
        }
        app.buttons["miniPlayerOpen"].tap()
        XCTAssertTrue(app.buttons["playerSkip"].waitForExistence(timeout: 5)); app.buttons["playerSkip"].tap()
        label(app.buttons["playerPlay"], "Pause")
        app.buttons["playerPlay"].tap(); label(app.buttons["playerPlay"], "Play")
        app.buttons["playerCollapse"].tap()
        label(app.buttons["miniPlayerOpen"], "First episode: a short introduction. Parity Listening Lab")
        app.buttons["QueueFragment"].tap()
        assertQueue(app, keep: keep)
        assertSkippedEpisode(app, keep: keep, position: position)

        app.terminate(); app.launch()
        openSettings(app); reveal(setting, in: app)
        XCTAssertEqual(setting.value as? String, keep ? "On" : "Off")
        leaveSettings(app); app.buttons["QueueFragment"].tap()
        assertQueue(app, keep: keep)
        assertSkippedEpisode(app, keep: keep, position: position)
    }

    @MainActor private func assertQueue(_ app: XCUIApplication, keep: Bool) {
        XCTAssertTrue(app.buttons["episode-2"].waitForExistence(timeout: 5))
        if keep {
            XCTAssertTrue(app.buttons["episode-1"].exists)
            XCTAssertLessThan(app.buttons["episode-1"].frame.minY, app.buttons["episode-2"].frame.minY)
        } else {
            XCTAssertTrue(app.buttons["episode-1"].waitForNonExistence(timeout: 5))
        }
    }

    @MainActor private func assertSkippedEpisode(_ app: XCUIApplication, keep: Bool, position: String) {
        app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 5)); app.buttons["subscriptionFeed-1"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5)); app.buttons["episode-1"].tap()
        XCTAssertTrue(app.buttons["episodePrimaryAction"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["episodePrimaryAction"].label, "Play") // Download retained.
        app.buttons["episodeMore"].tap()
        XCTAssertTrue(app.buttons["markPlayed"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["markUnplayed"].exists) // Skip is not completion.
        XCTAssertEqual(app.buttons["removeFromQueue"].exists, keep)
        XCTAssertEqual(app.buttons["addToQueue"].exists, !keep)
        XCTAssertFalse(app.buttons["skip"].exists) // Immediate successor owns playback.
        app.buttons["share"].tap()
        let includePosition = app.buttons["episodeSharePosition"]
        XCTAssertTrue(includePosition.waitForExistence(timeout: 5))
        if includePosition.value as? String != "Checked" { includePosition.tap() }
        XCTAssertTrue((app.buttons["episodeShareSocial"].value as? String ?? "").contains("Starting from: \(position)"))
    }

    @MainActor private func openSettings(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["prefScreenPlayback"].waitForExistence(timeout: 5)); app.buttons["prefScreenPlayback"].tap()
    }
    @MainActor private func leaveSettings(_ app: XCUIApplication) {
        app.buttons["toolbarBack"].tap(); app.buttons["toolbarBack"].tap()
    }
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        for _ in 0..<4 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    @MainActor private func label(_ element: XCUIElement, _ expected: String) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate:
            NSPredicate(format: "label == %@", expected), object: element)], timeout: 20), .completed)
    }
}
