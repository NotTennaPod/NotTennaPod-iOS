import XCTest

final class DefaultPageOverflowGestureTests: XCTestCase {
    @MainActor func testChoiceAndCancelOriginDragsDoNotActivateControls() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback", "-test-default-page-overflow"]
        app.launch()
        let viewport = app.scrollViews["defaultPageContent"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        let first = app.buttons["defaultPage-HomeFragment"]
        let title = app.staticTexts["defaultPageTitle"], cancel = app.buttons["defaultPageCancel"]
        let result = app.staticTexts["fixtureResult"], toggle = app.buttons["fixtureResize"]
        XCTAssertTrue(first.exists && viewport.frame.contains(first.frame))
        let before = title.frame.minY
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.25, thenDragTo: viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
        XCTAssertLessThan(title.frame.minY, before - 10)
        XCTAssertEqual(result.label, "Actions: 0")
        for _ in 0..<10 where !viewport.frame.contains(cancel.frame) { viewport.swipeUp(velocity: .slow) }
        XCTAssertTrue(viewport.frame.contains(cancel.frame) && cancel.isHittable)
        let cancelBefore = cancel.frame.minY
        let cancelStart = cancel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let travel = viewport.frame.maxY - (cancel.frame.minY + cancel.frame.height * 0.2) - 8
        XCTAssertGreaterThan(travel, 30)
        cancelStart.press(forDuration: 0.25, thenDragTo: cancelStart.withOffset(CGVector(dx: 0, dy: travel)))
        XCTAssertGreaterThan(cancel.frame.minY, cancelBefore + 5)
        XCTAssertEqual(result.label, "Actions: 0")
        for _ in 0..<10 where !viewport.frame.contains(title.frame) { viewport.swipeDown(velocity: .slow) }
        XCTAssertTrue(viewport.frame.contains(title.frame))
        toggle.tap()
        XCTAssertEqual(toggle.label, "Shrink")
        XCTAssertTrue(cancel.isHittable)
        let choices = app.scrollViews["defaultPageChoices"]
        XCTAssertTrue(choices.frame.contains(first.frame))
        let firstBefore = first.frame.minY, pinnedTitle = title.frame
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.25, thenDragTo: choices.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
        XCTAssertLessThan(first.frame.minY, firstBefore - 10)
        XCTAssertEqual(title.frame.minY, pinnedTitle.minY, accuracy: 1) // The title stays pinned.
        XCTAssertEqual(result.label, "Actions: 0")
        toggle.tap()
        XCTAssertEqual(toggle.label, "Grow")
        for _ in 0..<10 where !viewport.frame.contains(cancel.frame) { viewport.swipeUp(velocity: .slow) }
        XCTAssertTrue(viewport.frame.contains(cancel.frame) && cancel.isHittable)
        XCTAssertEqual(result.label, "Actions: 0")
        cancel.tap()
        XCTAssertTrue(result.label.hasPrefix("Actions: 1,"))
    }
}
