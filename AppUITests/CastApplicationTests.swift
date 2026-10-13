import XCTest

final class CastApplicationTests: XCTestCase {
    @MainActor func testPlayerChooserEmptyRetryAndRelaunchPreserveLocalPlayback() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback", "-test-cast-enabled", "-test-cast-empty-discovery"]
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
        let cast = app.buttons["playerCast"]
        label(cast, "Cast. Disconnected")
        XCTAssertTrue(cast.isHittable)
        let position = app.staticTexts["playerPosition"].label
        cast.tap()
        XCTAssertTrue(app.staticTexts["castChooserTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["castChooserTitle"].label, "Cast to")
        label(app.staticTexts["castChooserTitle"], "No devices available", timeout: 25)
        XCTAssertTrue(app.links["castChooserHelp"].isHittable)
        app.buttons["castChooserOK"].tap()
        XCTAssertTrue(app.staticTexts["castChooserTitle"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["playerPosition"].label, position)
        XCTAssertEqual(app.buttons["playerPlay"].label, "Play")
        cast.tap()
        XCTAssertTrue(app.staticTexts["castChooserTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["castChooserTitle"].label, "Cast to")
        // Closing the process during discovery must not change the selected episode.
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 10)); app.buttons["miniPlayerOpen"].tap()
        label(cast, "Cast. Disconnected")
        XCTAssertEqual(app.buttons["playerPlay"].label, "Play")
        XCTAssertFalse(app.staticTexts["castChooserTitle"].exists)
        app.buttons["playerPlay"].tap(); label(app.buttons["playerPlay"], "Pause")
        app.buttons["playerPlay"].tap(); label(app.buttons["playerPlay"], "Play")
    }
    @MainActor private func openConnectedGroup() -> (app: XCUIApplication, cast: XCUIElement, position: String, expand: XCUIElement) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback", "-test-cast-enabled", "-test-cast-group"]
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
        let cast = app.buttons["playerCast"]
        label(cast, "Cast. Connected")
        let position = app.staticTexts["playerPosition"].label
        cast.tap()
        let expand = app.buttons["castGroupExpand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5)); label(expand, "Expand")
        return (app, cast, position, expand)
    }
    // Escape: iOS 27.1 XCUITest's typeKey(.escape) never reaches the app (the dialog is first responder and
    // letter keys arrive). CastApplicationRuntimeTests covers the Escape command closing the dialog
    // without ending the session; a real keyboard needs a check on a device.
    @MainActor func testConnectedGroupTouchVolumesScrollCloseAndStop() {
        let (app, cast, position, expand) = openConnectedGroup()
        XCTAssertFalse(app.buttons["castDisconnect"].exists)
        let master = app.descendants(matching: .any)["castReceiverVolume"]
        master.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
        XCTAssertGreaterThanOrEqual(percent(master), 65)
        let retainedMaster = master.value as? String
        // Holding on the slider shows touch feedback but must not change the volume.
        master.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).press(forDuration: 2)
        XCTAssertEqual(master.value as? String, retainedMaster)
        expand.tap(); label(expand, "Collapse")
        let fixed = app.descendants(matching: .any)["castMemberVolume-office"]
        let kitchen = app.descendants(matching: .any)["castMemberVolume-kitchen"]
        XCTAssertTrue(kitchen.waitForExistence(timeout: 5)); XCTAssertTrue(kitchen.isHittable)
        XCTAssertFalse(fixed.isEnabled); XCTAssertEqual(fixed.value as? String, "100%")
        drag(kitchen, from: 0.3, to: 0.75)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.percent(kitchen) >= 65
        }, object: nil)], timeout: 5), .completed)
        let retainedKitchen = kitchen.value as? String
        let list = app.scrollViews["castGroupMembers"]
        // Start over the actual slider area: vertical gestures must scroll,
        // while the horizontal drag above changes only that member's volume.
        let third = app.descendants(matching: .any)["castMemberVolume-speaker-2"]
        XCTAssertTrue(third.isHittable)
        let retainedThird = third.value as? String
        third.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)))
        XCTAssertEqual(third.value as? String, retainedThird)
        let last = app.descendants(matching: .any)["castMemberVolume-speaker-5"]
        XCTAssertTrue(last.isHittable)
        drag(last, from: 0.5, to: 0.2)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.percent(last) <= 30
        }, object: nil)], timeout: 5), .completed)
        let retainedLast = last.value as? String
        expand.tap(); label(expand, "Expand"); expand.tap(); label(expand, "Collapse")
        XCTAssertTrue(last.isHittable); XCTAssertEqual(last.value as? String, retainedLast)
        app.buttons["castConnectedClose"].tap()
        XCTAssertTrue(expand.waitForNonExistence(timeout: 5)); label(cast, "Cast. Connected")
        cast.tap(); XCTAssertTrue(expand.waitForExistence(timeout: 5)); label(expand, "Expand")
        XCTAssertEqual(master.value as? String, retainedMaster)
        expand.tap(); XCTAssertTrue(kitchen.isHittable); XCTAssertEqual(kitchen.value as? String, retainedKitchen)
        app.buttons["castStop"].tap(); label(cast, "Cast. Disconnected")
        XCTAssertEqual(app.staticTexts["playerPosition"].label, position)
        label(app.buttons["playerPlay"], "Play")
    }
    @MainActor private func drag(_ element: XCUIElement, from: CGFloat, to: CGFloat) {
        element.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: element.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.5)))
    }
    @MainActor private func percent(_ element: XCUIElement) -> Int {
        Int((element.value as? String ?? "").replacingOccurrences(of: "%", with: "")) ?? -1
    }
    @MainActor private func label(_ element: XCUIElement, _ expected: String, timeout: TimeInterval = 20) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", expected), object: element)], timeout: timeout), .completed)
    }
}
