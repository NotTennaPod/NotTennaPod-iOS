import XCTest

final class ShownotesLifetimeTests: XCTestCase {
    @MainActor func testForegroundRetainsScrollAndCollapseResetsNotesAndMenu() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap()
        address.typeTextSettled("http://127.0.0.1:18765/shownotes-lifetime.xml"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 20)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5)); app.buttons["episode-1"].tap()
        app.buttons["episodeSecondaryAction"].tap()
        let play = app.buttons["episodePrimaryAction"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Play'"), object: play)], timeout: 25), .completed)
        play.tap()
        let mini = app.buttons["miniPlayerPlay"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Pause'"), object: mini)], timeout: 10), .completed)
        mini.tap(); app.buttons["miniPlayerOpen"].tap(); app.buttons["playerShownotes"].tap()
        let notes = app.webViews["playerShownotesContent"], top = notes.staticTexts["Selectableword"]
        XCTAssertTrue(top.waitForExistence(timeout: 10)); XCTAssertTrue(top.isHittable)
        let initialY = top.frame.minY
        notes.swipeUp(velocity: .slow)
        let visible = notes.staticTexts.allElementsBoundByIndex.filter { $0.label.hasPrefix("Paragraph ") && $0.isHittable && notes.frame.insetBy(dx: 0, dy: 40).contains($0.frame) }
        XCTAssertFalse(visible.isEmpty)
        let anchor = visible[visible.count / 2], label = anchor.label, beforeY = anchor.frame.minY
        XCTAssertFalse(top.isHittable)
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch(); XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 5))
        app.activate(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        let restored = notes.staticTexts[label]
        XCTAssertTrue(restored.waitForExistence(timeout: 5)); XCTAssertTrue(restored.isHittable)
        XCTAssertEqual(restored.frame.minY, beforeY, accuracy: 1)
        XCTAssertEqual(app.buttons["playerPlay"].label, "Play")
        app.buttons["playerCollapse"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["miniPlayerOpen"])], timeout: 5), .completed)
        app.buttons["miniPlayerOpen"].tap(); app.buttons["playerShownotes"].tap()
        // The pager animation can still be moving after XCTest's idle check (both reopenings).
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            top.isHittable && abs(top.frame.minY - initialY) <= 1
        }, object: top)], timeout: 5), .completed)
        XCTAssertTrue(top.isHittable); XCTAssertEqual(top.frame.minY, initialY, accuracy: 1)
        top.press(forDuration: 1)
        XCTAssertTrue(app.buttons["shownotesSelection-copy"].waitForExistence(timeout: 5))
        app.buttons["playerCollapse"].tap()
        XCTAssertTrue(app.buttons["shownotesSelection-copy"].waitForNonExistence(timeout: 5))
        app.buttons["miniPlayerOpen"].tap(); app.buttons["playerShownotes"].tap()
        // The pager animation can still be moving after XCTest's idle check.
        // Await its observable destination instead of asserting mid-transition.
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            top.isHittable && abs(top.frame.minY - initialY) <= 1
        }, object: top)], timeout: 5), .completed)
        XCTAssertTrue(top.isHittable)
        XCTAssertEqual(top.frame.minY, initialY, accuracy: 1)
        XCTAssertFalse(app.buttons["shownotesSelection-copy"].exists)
        XCTAssertEqual(app.buttons["playerPlay"].label, "Play")
    }
    @MainActor func testNestedEpisodeNavigationRetainsReadingPositionAndReopenStartsFresh() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap()
        address.typeTextSettled("http://127.0.0.1:18765/shownotes-lifetime.xml"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 20)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5)); app.buttons["episode-1"].tap()
        let notes = app.webViews["episodeShownotes"], top = notes.staticTexts["Selectableword"]
        XCTAssertTrue(top.waitForExistence(timeout: 10)); XCTAssertTrue(top.isHittable)
        let initialY = top.frame.minY
        notes.swipeUp(velocity: .slow)
        let visible = notes.staticTexts.allElementsBoundByIndex.filter {
            $0.label.hasPrefix("Paragraph ") && $0.isHittable && notes.frame.insetBy(dx: 0, dy: 30).contains($0.frame)
        }
        XCTAssertFalse(visible.isEmpty)
        let anchor = visible[visible.count / 2], label = anchor.label, beforeY = anchor.frame.minY
        XCTAssertFalse(top.isHittable)
        app.buttons["episodePodcast"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5)); app.buttons["episode-1"].tap()
        XCTAssertTrue(top.waitForExistence(timeout: 5)); XCTAssertTrue(top.isHittable)
        XCTAssertEqual(top.frame.minY, initialY, accuracy: 1)
        notes.swipeUp(velocity: .slow); notes.swipeUp(velocity: .slow)
        XCTAssertFalse(top.isHittable)
        app.buttons["toolbarBack"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5)); app.buttons["toolbarBack"].tap()
        let restored = notes.staticTexts[label]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            restored.isHittable && abs(restored.frame.minY - beforeY) <= 1
        }, object: restored)], timeout: 5), .completed)
        XCTAssertEqual(restored.frame.minY, beforeY, accuracy: 1)
        app.buttons["toolbarBack"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5)); app.buttons["episode-1"].tap()
        XCTAssertTrue(top.waitForExistence(timeout: 5)); XCTAssertTrue(top.isHittable)
        XCTAssertEqual(top.frame.minY, initialY, accuracy: 1)
        XCTAssertFalse(app.buttons["shownotesSelection-copy"].exists)
    }

    // System text services (Speak Selection) are not used here: turning them on
    // needs a Settings change that a fresh Simulator cannot reliably make or undo.
    // Their overflow integration is a view test; real Speak is a hardware check.
    @MainActor func testSharingRetainsScrolledPausedPlayer() {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        addTeardownBlock { @MainActor in app.terminate() }
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap()
        address.typeTextSettled("http://127.0.0.1:18765/shownotes-modal.xml"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 20)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5)); app.buttons["episode-1"].tap()
        app.buttons["episodeSecondaryAction"].tap()
        let play = app.buttons["episodePrimaryAction"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Play'"), object: play)], timeout: 25), .completed)
        play.tap()
        let mini = app.buttons["miniPlayerPlay"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Pause'"), object: mini)], timeout: 10), .completed)
        mini.tap(); app.buttons["miniPlayerOpen"].tap(); app.buttons["playerShownotes"].tap()
        let notes = app.webViews["playerShownotesContent"]
        XCTAssertTrue(notes.staticTexts["Selectableword"].waitForExistence(timeout: 10))
        @MainActor func visible(_ links: Bool) -> XCUIElement {
            let viewport = notes.frame.insetBy(dx: 0, dy: 50)
            let candidates = (links ? notes.links : notes.staticTexts)
                .matching(NSPredicate(format: "label BEGINSWITH %@", links ? "Link " : "Paragraph "))
                .allElementsBoundByIndex.filter { viewport.contains($0.frame) && $0.isHittable }
            XCTAssertFalse(candidates.isEmpty)
            return candidates[candidates.count / 2]
        }
        for action in ["URL Share", "Text Share"] {
            notes.swipeUp(velocity: .slow)
            let anchor = visible(false), anchorLabel = anchor.label, beforeY = anchor.frame.minY
            if action == "URL Share" {
                visible(true).press(forDuration: 1)
                let share = app.buttons["shownotesLink-share_url_label"]
                XCTAssertTrue(share.waitForExistence(timeout: 5)); share.tap()
            } else {
                anchor.press(forDuration: 1)
                XCTAssertTrue(app.buttons["shownotesSelection-copy"].waitForExistence(timeout: 5))
                app.buttons["shownotesSelection-share"].tap()
            }
            let copy = app.cells["Copy"]
            XCTAssertTrue(copy.waitForExistence(timeout: 10)); copy.tap()
            XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
            let returned = notes.staticTexts[anchorLabel]
            XCTAssertTrue(returned.isHittable)
            XCTAssertEqual(returned.frame.minY, beforeY, accuracy: 1)
            XCTAssertEqual(app.buttons["playerPlay"].label, "Play")
        }
    }

}
