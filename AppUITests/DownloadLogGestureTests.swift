import XCTest

final class DownloadLogGestureTests: XCTestCase {
    @MainActor func testToolbarCollapseRetainsListPositionWhenReexpanded() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback", "-test-download-log-gestures"]
        app.launch()
        let open = app.buttons["fixtureOpenHistory"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: open)], timeout: 10)
        open.tap()
        let sheet = app.otherElements["downloadLogSheet"], list = app.tables["downloadLogList"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let collapsedTop = sheet.frame.minY
        dragHeading(app, by: -80); await top(sheet, equals: 0)
        drag(list, in: app, by: -100)
        let second = app.staticTexts.matching(identifier: "downloadLogTitle").matching(NSPredicate(format: "label == %@", "History episode 1")).firstMatch
        XCTAssertTrue(second.exists); let savedY = second.frame.minY
        dragHeading(app, by: 80); await top(sheet, equals: collapsedTop)
        dragHeading(app, by: -80); await top(sheet, equals: 0)
        XCTAssertTrue(second.exists); XCTAssertEqual(second.frame.minY, savedY, accuracy: 2)
    }
    @MainActor func testListExpansionScrollingCollapseEmptyAndDismissal() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback", "-test-download-log-gestures"]
        app.launch()
        let open = app.buttons["fixtureOpenHistory"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: open)], timeout: 10)
        open.tap()
        let sheet = app.otherElements["downloadLogSheet"], list = app.tables["downloadLogList"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let collapsedTop = sheet.frame.minY
        XCTAssertGreaterThan(collapsedTop, 40)
        drag(list, in: app, by: -80)
        await top(sheet, equals: 0)
        let first = app.staticTexts.matching(identifier: "downloadLogTitle").matching(NSPredicate(format: "label == %@", "History episode 0")).firstMatch
        XCTAssertTrue(first.exists)
        let firstY = first.frame.minY
        drag(list, in: app, by: -150)
        await top(sheet, equals: 0)
        XCTAssertTrue(!first.exists || first.frame.minY < firstY - 50)
        XCUIDevice.shared.orientation = .landscapeLeft
        await top(sheet, equals: 0)
        XCTAssertTrue(!first.exists || first.frame.minY < firstY - 50)
        XCUIDevice.shared.orientation = .portrait
        await top(sheet, equals: 0)
        drag(list, in: app, by: 45)
        await top(sheet, equals: 0)
        // Remaining downward travel reaches the top and hands over to the sheet.
        drag(list, in: app, by: 240)
        await top(sheet, equals: collapsedTop)
        // A short pull on an already collapsed sheet snaps back, not dismisses.
        drag(list, in: app, by: 35)
        await top(sheet, equals: collapsedTop)
        app.buttons["downloadLogClear"].tap()
        XCTAssertTrue(app.staticTexts["No download log"].waitForExistence(timeout: 5))
        let emptyTop = sheet.frame.minY
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: sheet.frame.midX, dy: emptyTop + 90))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 190)), withVelocity: 350, thenHoldForDuration: 0.1)
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: list)], timeout: 5)
        XCTAssertTrue(open.isHittable)
    }
    @MainActor private func drag(_ list: XCUIElement, in app: XCUIApplication, by distance: CGFloat) {
        let visible = list.frame.intersection(app.frame)
        let y = distance > 0 ? visible.minY + 60 : visible.maxY - 60
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: visible.midX, dy: y))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)), withVelocity: 300, thenHoldForDuration: 0.1)
    }
    @MainActor private func dragHeading(_ app: XCUIApplication, by distance: CGFloat) {
        let heading = app.staticTexts["Download log"]
        let start = heading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)), withVelocity: 300, thenHoldForDuration: 0.1)
    }
    @MainActor private func top(_ sheet: XCUIElement, equals y: CGFloat) async {
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { abs(sheet.frame.minY - y) < 2 }
        }, object: nil)], timeout: 5)
    }
}
