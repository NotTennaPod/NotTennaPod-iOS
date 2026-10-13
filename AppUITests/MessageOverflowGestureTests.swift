import XCTest

final class MessageOverflowGestureTests: XCTestCase {
    @MainActor
    func testBodyAndButtonDragsReachBothEndsWithoutInvokingActions() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback", "-test-message-overflow"]
        app.launch()
        let viewport = app.scrollViews["sourceMessageContent"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        let title = app.staticTexts["sourceMessageTitle"], body = app.staticTexts["sourceMessage"]
        let result = app.staticTexts["fixtureResult"], resize = app.buttons["fixtureResize"]
        let neutral = app.buttons["neutral"], positive = app.buttons["positive"]
        XCTAssertLessThan(viewport.frame.height, 150)
        XCTAssertGreaterThan(viewport.frame.height, positive.frame.height)
        let originalTitleY = title.frame.minY
        let visibleBody = body.frame.intersection(viewport.frame)
        XCTAssertGreaterThan(visibleBody.height, 20)
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: visibleBody.midX, dy: visibleBody.midY))
        let end = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertLessThan(title.frame.minY, originalTitleY - 10)
        for _ in 0..<10 where !viewport.frame.contains(neutral.frame) { viewport.swipeUp(velocity: .slow) }
        XCTAssertTrue(viewport.frame.contains(neutral.frame) && neutral.isHittable)
        XCTAssertEqual(result.label, "Actions: 0")
        // Begin on a real enabled button; a drag must scroll, never fire it.
        let beforeButtonDrag = title.frame.minY
        neutral.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertGreaterThan(title.frame.minY, beforeButtonDrag + 5)
        XCTAssertEqual(result.label, "Actions: 0")
        for _ in 0..<10 where !viewport.frame.contains(title.frame) { viewport.swipeDown(velocity: .slow) }
        XCTAssertTrue(viewport.frame.contains(title.frame))
        XCTAssertEqual(result.label, "Actions: 0")
        resize.tap()
        XCTAssertEqual(resize.label, "Shrink")
        XCTAssertTrue(positive.isHittable && neutral.isHittable)
        resize.tap()
        XCTAssertEqual(resize.label, "Grow")
        for _ in 0..<15 where !viewport.frame.contains(positive.frame) {
            // Approach an intermediate control from its current side. A full
            // swipe can overshoot it; repeated upward swipes cannot recover.
            let delta = positive.frame.midY - viewport.frame.midY
            let movement = max(-viewport.frame.height * 0.3, min(viewport.frame.height * 0.3, -delta))
            let origin = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            origin.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: movement)),
                         withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(positive.isHittable && viewport.frame.contains(positive.frame),
                      "positive=\(positive.frame), viewport=\(viewport.frame)")
        positive.tap()
        XCTAssertEqual(result.label, "Actions: 1, positive")
    }
}
