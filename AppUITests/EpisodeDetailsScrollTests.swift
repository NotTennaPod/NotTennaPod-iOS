import XCTest

final class EpisodeDetailsScrollTests: XCTestCase {
    @MainActor
    func testHeaderAndNotesDragIndependentlyInShortWindow() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 3))
        address.tap(); address.typeTextSettled("http://127.0.0.1:18765/episode-constrained.xml"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 35)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5)); app.buttons["episode-1"].tap()
        let notes = app.webViews["episodeShownotes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeLeft
        let header = app.scrollViews["episodeHeaderScroll"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let title = app.staticTexts["episodeTitle"], secondary = app.buttons["episodeSecondaryAction"]
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { app.frame.width > app.frame.height } }, object: nil)
        let rotated = XCTWaiter.wait(for: [landscape], timeout: 10) == .completed
        if XCUIDevice.rotationResizesWindow { XCTAssertTrue(rotated) }
        // A tablet (or a window that did not rotate) is tall enough in landscape for the whole header: nothing needs scrolling, and all of it is visible.
        if secondary.waitForExistence(timeout: 5), secondary.frame.maxY <= header.frame.maxY + 1 {
            XCTAssertTrue(secondary.isHittable && title.isHittable, "app=\(app.frame), header=\(header.frame), secondary=\(secondary.frame)")
            XCTAssertGreaterThanOrEqual(notes.frame.minY, header.frame.maxY - 1)
            XCUIDevice.shared.orientation = .portrait
            return
        }
        XCTAssertGreaterThan(header.frame.height, 44)
        XCTAssertGreaterThan(notes.frame.height, 18)
        XCTAssertGreaterThanOrEqual(notes.frame.minY, header.frame.maxY - 1) // Notes start below the header, no overlap.
        let originalTitleY = title.frame.minY
        let originalNotes = notes.frame
        header.swipeUp(velocity: .slow)
        XCTAssertLessThan(title.frame.minY, originalTitleY - 10)
        XCTAssertEqual(notes.frame.minY, originalNotes.minY, accuracy: 1) // Scrolling the header leaves the notes in place.
        for _ in 0..<5 where !secondary.isHittable { header.swipeUp(velocity: .slow) }
        XCTAssertTrue(secondary.isHittable)
        secondary.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Delete"), object: secondary)], timeout: 25), .completed)
        let headerTitleY = title.frame.minY
        let end = notes.links["Final link"]
        for _ in 0..<8 where !end.isHittable { notes.swipeUp(velocity: .fast) }
        XCTAssertTrue(end.isHittable)
        XCTAssertEqual(title.frame.minY, headerTitleY, accuracy: 2)
        var previousEnd = end.frame, stableSince = Date(), stableSamples = 0
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                let current = end.frame
                if abs(current.minY - previousEnd.minY) > 0.5 {
                    previousEnd = current; stableSince = Date(); stableSamples = 0
                } else { stableSamples += 1 }
                return stableSamples >= 3 && Date().timeIntervalSince(stableSince) >= 0.3
            }
        }, object: nil)], timeout: 5), .completed)
        let endY = end.frame.minY
        let cover = app.buttons["episodeCover"]
        for _ in 0..<8 where !cover.isHittable { header.swipeDown(velocity: .fast) }
        XCTAssertTrue(cover.isHittable)
        XCTAssertEqual(end.frame.minY, endY, accuracy: 2)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { app.frame.height > app.frame.width }
        }, object: nil)], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["toolbarBack"].isHittable)
        app.buttons["toolbarBack"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5))
    }
}
