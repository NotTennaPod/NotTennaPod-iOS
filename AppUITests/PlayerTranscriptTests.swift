import XCTest

final class PlayerTranscriptTests: XCTestCase {
    @MainActor func testOverflowTranscriptSelectionSeekRefreshCommentsAndPodcast() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18765/transcript-feed.xml")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15)); app.buttons["subscribeFeed"].tap()
        let episode = app.buttons["episode-action-1"]
        XCTAssertTrue(episode.waitForExistence(timeout: 5)); episode.tap(); label(episode, "Play")
        episode.tap(); label(app.buttons["miniPlayerPlay"], "Pause"); app.buttons["miniPlayerPlay"].tap()
        app.buttons["miniPlayerOpen"].tap(); label(app.buttons["playerPlay"], "Play")
        let more = app.buttons["playerMore"]
        XCTAssertTrue(more.isHittable); more.tap()
        let podcast = app.buttons["playerOverflow-openPodcast"], website = app.buttons["playerOverflow-visitWebsite"]
        let transcript = app.buttons["playerOverflow-transcript"], comments = app.buttons["playerOverflow-comments"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        XCTAssertLessThan(podcast.frame.minY, website.frame.minY)
        XCTAssertLessThan(website.frame.minY, transcript.frame.minY)
        XCTAssertLessThan(transcript.frame.minY, comments.frame.minY)
        transcript.tap()
        let first = app.buttons["transcriptSegment-0"], follow = app.buttons["transcriptFollow"]
        XCTAssertTrue(first.waitForExistence(timeout: 10)); XCTAssertEqual(follow.value as? String, "On")
        XCTAssertFalse(first.isSelected)
        first.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["transcriptCopy"].waitForExistence(timeout: 5)); XCTAssertEqual(follow.value as? String, "Off")
        app.buttons["transcriptMore"].tap()
        XCTAssertTrue(app.buttons["transcriptSelectAll"].waitForExistence(timeout: 5)); app.buttons["transcriptSelectAll"].tap()
        XCTAssertTrue(app.buttons["transcriptCopy"].waitForExistence(timeout: 5))
        app.buttons["transcriptCopy"].tap(); XCTAssertEqual(follow.value as? String, "On")
        XCTAssertTrue(app.buttons["transcriptRefresh"].isHittable)
        app.buttons["transcriptSegment-2"].tap()
        app.buttons["transcriptClose"].tap(); label(app.staticTexts["playerPosition"], "00:00:10")
        label(app.buttons["playerPlay"], "Play")
        more.tap(); transcript.tap(); XCTAssertTrue(first.waitForExistence(timeout: 5))
        app.buttons["transcriptRefresh"].tap(); XCTAssertTrue(first.waitForExistence(timeout: 5))
        app.buttons["transcriptClose"].tap(); more.tap(); comments.tap()
        let cancel = app.buttons["playerCommentsCancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["You are leaving NotTennaPod"].exists)
        cancel.tap(); XCTAssertTrue(more.waitForExistence(timeout: 5) && more.isHittable)
        more.tap(); podcast.tap()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 5))
        XCTAssertFalse(more.isHittable)
        XCTAssertTrue(app.buttons["episode-action-1"].isHittable)
    }
    @MainActor func testLongTranscriptDragSelectionAndFollowReturn() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18765/transcript-long-feed.xml")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15)); app.buttons["subscribeFeed"].tap()
        let episode = app.buttons["episode-action-1"]
        XCTAssertTrue(episode.waitForExistence(timeout: 5)); episode.tap(); label(episode, "Play")
        episode.tap(); label(app.buttons["miniPlayerPlay"], "Pause"); app.buttons["miniPlayerPlay"].tap()
        app.buttons["miniPlayerOpen"].tap(); label(app.buttons["playerPlay"], "Play")
        app.buttons["playerMore"].tap(); app.buttons["playerOverflow-transcript"].tap()
        let first = app.buttons["transcriptSegment-0"], last = app.buttons["transcriptSegment-5"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let list = app.tables["transcriptList"], follow = app.buttons["transcriptFollow"]
        XCTAssertTrue(list.isHittable && app.buttons["transcriptClose"].isHittable)
        // Use the visible text rectangle: the full row can exceed the viewport.
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["transcriptCopy"].waitForExistence(timeout: 5)); XCTAssertEqual(follow.value as? String, "Off")
        for _ in 0..<18 {
            if last.exists && last.isHittable { break }
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).press(forDuration: 0.01,
                thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        }
        XCTAssertTrue(last.isHittable)
        XCTAssertEqual(follow.value as? String, "Off")
        app.buttons["transcriptCancelSelection"].tap(); XCTAssertEqual(follow.value as? String, "On")
        // A user drag turns Follow off without entering selection.
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).press(forDuration: 0.01,
            thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertEqual(follow.value as? String, "Off")
        app.buttons["transcriptClose"].tap()
        label(app.buttons["playerPlay"], "Play")
        let seek = app.descendants(matching: .any)["playerSeek"]
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["playerMore"].tap(); app.buttons["playerOverflow-transcript"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(follow.value as? String, "On")
        app.buttons["transcriptClose"].tap(); label(app.staticTexts["playerPosition"], "00:00:15")
    }

    @MainActor func testHundredLineBoundaryKeepsFollowingSegmentReachable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18765/transcript-lines-feed.xml")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15)); app.buttons["subscribeFeed"].tap()
        let episode = app.buttons["episode-action-1"]
        XCTAssertTrue(episode.waitForExistence(timeout: 5)); episode.tap(); label(episode, "Play")
        episode.tap(); label(app.buttons["miniPlayerPlay"], "Pause"); app.buttons["miniPlayerPlay"].tap()
        app.buttons["miniPlayerOpen"].tap(); label(app.buttons["playerPlay"], "Play")
        app.buttons["playerMore"].tap(); app.buttons["playerOverflow-transcript"].tap()
        let first = app.buttons["transcriptSegment-0"], next = app.buttons["transcriptSegment-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let list = app.tables["transcriptList"]
        XCTAssertTrue(first.label.contains("Line 101")) // Full accessibility text survives the visual cap.
        for _ in 0..<16 {
            if next.exists && next.isHittable { break }
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).press(forDuration: 0.01,
                thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        }
        XCTAssertTrue(next.isHittable && app.buttons["transcriptClose"].isHittable)
        XCTAssertEqual(app.buttons["transcriptFollow"].value as? String, "Off")
        next.tap(); app.buttons["transcriptClose"].tap()
        label(app.staticTexts["playerPosition"], "00:00:05"); label(app.buttons["playerPlay"], "Play")
    }

    @MainActor private func label(_ element: XCUIElement, _ expected: String) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: element)], timeout: 20), .completed)
    }
}
