import XCTest

/// Deliberately malformed media is separate from the valid format/processing fixture.
final class PlaybackVideoFailureJourneyTests: XCTestCase {
    @MainActor func testVideoStreamErrorThenRetryRetainsSelectedEpisode() async throws {
        continueAfterFailure = false
        let base = ProcessInfo.processInfo.environment["PLAYBACK_VIDEO_FIXTURE_URL"] ?? "http://127.0.0.1:59421"
        let app = XCUIApplication(), identity = UUID().uuidString
        app.launchArguments = ["-test-library-id", identity, "-test-muted-playback"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap()
        address.typeTextSettled(base + "/feed.xml?run=" + identity + "&failure=1"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 10)); app.buttons["episode-1"].tap()
        let action = app.buttons["episodePrimaryAction"]
        XCTAssertTrue(action.waitForExistence(timeout: 5)); XCTAssertEqual(action.label, "Stream"); action.tap()
        XCTAssertTrue(app.buttons["sourceMessageOK"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["sourceMessageTitle"].label, "Error")
        XCTAssertTrue(app.staticTexts["sourceMessage"].label.hasPrefix("The media file could not be played."))
        app.buttons["sourceMessageOK"].tap()
        // Preparation failed before a display layer existed; the selected
        // episode remains in the original details/mini-player surface.
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 5))
        var repair = URLRequest(url: try XCTUnwrap(URL(string: base + "/repair/" + identity)))
        repair.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: repair)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
        app.buttons["miniPlayerOpen"].tap()
        XCTAssertTrue(app.otherElements["videoPlayer"].waitForExistence(timeout: 15))
        // Opening the retained selection preserves its paused intent. Explicit
        // Play then proves recovery through the existing shared owner.
        showControls(app)
        XCTAssertEqual(try snapshotLabel(app, identifier: "videoPlay"), "Play")
        app.buttons["videoPlay"].tap()
        let deadline = ContinuousClock.now + .seconds(15)
        var observedPlay: String?
        repeat {
            showControls(app)
            observedPlay = try snapshotLabel(app, identifier: "videoPlay")
            if !app.staticTexts["videoError"].exists && observedPlay == "Pause" { break }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        XCTAssertFalse(app.staticTexts["videoError"].exists)
        XCTAssertEqual(observedPlay, "Pause")
        showControls(app); app.buttons["videoPlay"].tap()
        showControls(app); XCTAssertNotNil(try snapshotLabel(app, identifier: "videoFavorite"))
        // The actual picture is independently inspected after controls hide.
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == false"), object: app.buttons["videoMore"])], timeout: 5)
    }
    @MainActor private func snapshotLabel(_ app: XCUIApplication, identifier: String) throws -> String? {
        // One immutable AX observation: autohide may remove the live element
        // between independent exists/label queries, but cannot alter this tree.
        func find(_ node: any XCUIElementSnapshot) -> String? {
            if node.identifier == identifier { return node.label }
            for child in node.children { if let value = find(child) { return value } }
            return nil
        }
        return find(try app.snapshot())
    }
    @MainActor private func showControls(_ app: XCUIApplication) {
        let more = app.buttons["videoMore"]
        let visible = more.exists && more.isHittable
        if visible { return }
        app.otherElements["videoPlayer"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: more)
        let outcome = XCTWaiter.wait(for: [ready], timeout: 5)
        XCTAssertEqual(outcome, .completed)
    }
}
