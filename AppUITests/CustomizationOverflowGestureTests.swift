import XCTest

final class CustomizationOverflowGestureTests: XCTestCase {
    @MainActor func testOrdinaryPaddingPanKeepsDraftAndFixedTitle() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback", "-test-customization-overflow"]
        app.launch()
        let toggle = app.buttons["fixtureResize"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10)); toggle.tap()
        XCTAssertEqual(toggle.label, "Shrink")
        let list = app.collectionViews["customizeList"]
        let title = app.staticTexts["customizeTitle"], titleFrame = title.frame
        let snapshot = app.buttons["fixtureSnapshot"], offset = app.staticTexts["fixtureOffset"]
        snapshot.tap()
        let initial = Double(offset.label.replacingOccurrences(of: "Offset: ", with: ""))!
        XCTAssertLessThan(initial, 0)
        let padding = -initial
        XCTAssertGreaterThan(padding, 8)
        // Start within the independently confirmed blank container padding.
        let start = list.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: list.frame.width * 0.8, dy: padding / 2))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -90)))
        snapshot.tap()
        let moved = Double(offset.label.replacingOccurrences(of: "Offset: ", with: ""))!
        XCTAssertGreaterThan(moved, initial + 20)
        XCTAssertEqual(title.frame.minY, titleFrame.minY, accuracy: 1) // The fixed title does not scroll away.
        // A held start in the blank band must not pick up an obscured row.
        XCTAssertGreaterThan(Int(offset.value as? String ?? "") ?? -1, 0)
        start.press(forDuration: 0.7, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.65)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
        let result = app.staticTexts["fixtureResult"]
        XCTAssertEqual(result.label, "Actions: 0")
        app.buttons["customizeOK"].tap()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Actions: 1; Home hidden: false; Default: false"), object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 3), .completed)
        XCTAssertEqual(result.value as? String, "HomeFragment,NewEpisodesFragment,QueueFragment,SubscriptionFragment,EpisodesFragment,DownloadsFragment,PlaybackHistoryFragment,FavoritesFragment,StatisticsFragment,AddFeedFragment||HomeFragment")
        app.terminate()
    }

    @MainActor func testEdgeDragToInitiallyOffscreenHiddenSectionAndActionSemantics() {
        continueAfterFailure = false
        // The gestures are the same whichever footer button ends the dialog, so one pass (OK) is enough.
        // Cancel discarding a drag and Reset restoring the default are covered by
        // LaunchTests.testNavigationCustomizationCancelConfirmResetAndDefaultPage.
        do {
            let action = "customizeOK"
            let app = XCUIApplication()
            app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback", "-test-customization-overflow"]
            app.launch()
            let list = app.collectionViews["customizeList"]
            XCTAssertTrue(list.waitForExistence(timeout: 10))
            let home = app.otherElements["customize-handle-HomeFragment"]
            let hidden = app.staticTexts["customize-row-hidden"], result = app.staticTexts["fixtureResult"]
            XCTAssertTrue(home.isHittable)
            XCTAssertFalse(hidden.exists && list.frame.intersects(hidden.frame))
            let snapshot = app.buttons["fixtureSnapshot"], offset = app.staticTexts["fixtureOffset"]
            snapshot.tap()
            let initialOffset = Double(offset.label.replacingOccurrences(of: "Offset: ", with: ""))!
            // The target is initially offscreen. Hold at the collection's real
            // viewport edge so UICollectionView must perform auto-scrolling.
            home.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.96)),
                       withVelocity: .slow, thenHoldForDuration: 4)
            snapshot.tap()
            let movedOffset = Double(offset.label.replacingOccurrences(of: "Offset: ", with: ""))!
            XCTAssertGreaterThan(movedOffset, initialOffset + 100) // Before any recovery swipe.
            XCTAssertEqual(result.label, "Actions: 0")
            let ok = app.buttons["customizeOK"]
            for _ in 0..<10 where !ok.exists || !list.frame.contains(ok.frame) { list.swipeUp(velocity: .slow) }
            XCTAssertTrue(ok.exists && list.frame.contains(ok.frame))
            snapshot.tap()
            let before = Double(offset.label.replacingOccurrences(of: "Offset: ", with: ""))!
            let start = ok.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            let travel = list.frame.maxY - (ok.frame.minY + ok.frame.height * 0.2) - 8
            XCTAssertGreaterThan(travel, 30)
            start.press(forDuration: 0.25, thenDragTo: start.withOffset(CGVector(dx: 0, dy: travel)))
            snapshot.tap()
            let after = Double(offset.label.replacingOccurrences(of: "Offset: ", with: ""))!
            // A successful drag may recycle the whole footer offscreen.
            XCTAssertLessThan(after, before - 5)
            XCTAssertEqual(result.label, "Actions: 0")
            app.buttons["fixtureResize"].tap()
            XCTAssertEqual(app.buttons["fixtureResize"].label, "Shrink")
            app.buttons["fixtureResize"].tap()
            XCTAssertEqual(app.buttons["fixtureResize"].label, "Grow")
            let target = app.buttons[action]
            for _ in 0..<15 {
                if target.exists && list.frame.contains(target.frame) { break }
                if !target.exists { list.swipeUp(velocity: .slow); continue }
                let delta = target.frame.midY - list.frame.midY
                let movement = max(-list.frame.height * 0.3, min(list.frame.height * 0.3, -delta))
                let origin = list.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
                origin.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: movement)), withVelocity: .slow, thenHoldForDuration: 0.1)
            }
            XCTAssertTrue(target.isHittable && list.frame.contains(target.frame))
            target.tap()
            let expected = "Actions: 1; Home hidden: \(action == "customizeOK"); Default: \(action == "customizeReset")"
            let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: result)
            XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 3), .completed)
            let seed = ["HomeFragment", "NewEpisodesFragment", "QueueFragment", "SubscriptionFragment", "EpisodesFragment",
                        "DownloadsFragment", "PlaybackHistoryFragment", "FavoritesFragment", "StatisticsFragment", "AddFeedFragment"]
            let expectedOrder = action == "customizeOK" ? Array(seed.dropFirst()) + [seed[0]] : action == "customizeReset" ? [] : seed
            let expectedValue = expectedOrder.joined(separator: ",") + "|" + (action == "customizeOK" ? "HomeFragment" : "")
                + "|" + (action == "customizeOK" ? "QueueFragment" : "HomeFragment")
            XCTAssertEqual(result.value as? String, expectedValue)
            app.terminate()
        }
    }
}
