import XCTest

final class ShownotesRaceTests: XCTestCase {
    @MainActor func testMediaReplacementUsesCurrentNotesAndRetiresPreviousSelection() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        addTeardownBlock { @MainActor in app.terminate() }
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap()
        address.typeTextSettled("http://127.0.0.1:18765/shownotes-race.xml")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 20))
        app.buttons["subscribeFeed"].tap()

        func label(_ element: XCUIElement, _ value: String) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@", value), object: element)], timeout: 25), .completed)
        }
        // Download both first so network timing cannot stand in for media ownership.
        for id in [1, 2] {
            let action = app.buttons["episode-action-\(id)"]
            XCTAssertTrue(action.waitForExistence(timeout: 5)); action.tap(); label(action, "Play")
        }
        var topPositions: [String: CGFloat] = [:]
        for id in [1, 2, 1] {
            let marker = id == 1 ? "Alphaword" : "Betaword"
            let obsolete = id == 1 ? "Betaword" : "Alphaword"
            let action = app.buttons["episode-action-\(id)"]
            XCTAssertTrue(action.waitForExistence(timeout: 5)); action.tap()
            label(app.buttons["miniPlayerPlay"], "Pause")
            app.buttons["miniPlayerPlay"].tap(); label(app.buttons["miniPlayerPlay"], "Play")
            app.buttons["miniPlayerOpen"].tap(); app.buttons["playerShownotes"].tap()
            let notes = app.webViews["playerShownotesContent"], top = notes.staticTexts[marker]
            XCTAssertTrue(top.waitForExistence(timeout: 10))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hittable == true"), object: top)], timeout: 5), .completed)
            XCTAssertFalse(notes.staticTexts[obsolete].exists)
            XCTAssertFalse(app.buttons["shownotesSelection-copy"].exists)
            if let previous = topPositions[marker] { XCTAssertEqual(top.frame.minY, previous, accuracy: 1) }
            topPositions[marker] = top.frame.minY
            label(app.buttons["playerPlay"], "Play")
            notes.swipeUp(velocity: .slow)
            // WebKit's accessibility positions follow the scroll a moment later than the screen does.
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hittable == false"), object: top)], timeout: 5), .completed, "top scrolled away")
            let paragraphs = notes.staticTexts.allElementsBoundByIndex.filter {
                $0.label.hasPrefix(marker + " paragraph ") && $0.isHittable && notes.frame.insetBy(dx: 0, dy: 40).contains($0.frame)
            }
            XCTAssertFalse(paragraphs.isEmpty)
            paragraphs[paragraphs.count / 2].press(forDuration: 1)
            XCTAssertTrue(app.buttons["shownotesSelection-copy"].waitForExistence(timeout: 5))
            app.buttons["playerCollapse"].tap()
            XCTAssertTrue(app.buttons["shownotesSelection-copy"].waitForNonExistence(timeout: 5))
        }
    }

}
