import XCTest

final class PlayerFavoriteTests: XCTestCase {
    @MainActor func testPlayerFavoriteUpdatesLibraryExternalEditsAndRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
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
        let favorite = app.buttons["playerFavorite"]
        label(favorite, "Add to favorites")
        XCTAssertTrue(favorite.isHittable)
        XCTAssertGreaterThan(favorite.frame.minX, app.buttons["playerCollapse"].frame.maxX)
        let position = app.staticTexts["playerPosition"].label
        favorite.tap(); label(favorite, "Remove from favorites")
        XCTAssertTrue(favorite.isSelected)
        XCTAssertEqual(app.staticTexts["playerPosition"].label, position)
        XCTAssertEqual(app.buttons["playerPlay"].label, "Play")
        app.buttons["playerCollapse"].tap()
        app.buttons["navigationMore"].tap(); app.buttons["Favorites"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["episode-2"].exists)
        app.buttons["episode-1"].tap(); app.buttons["episodeMore"].tap()
        XCTAssertTrue(app.buttons["removeFavorite"].waitForExistence(timeout: 5)); app.buttons["removeFavorite"].tap()
        app.buttons["miniPlayerOpen"].tap(); label(favorite, "Add to favorites")
        favorite.tap(); label(favorite, "Remove from favorites")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 10)); app.buttons["miniPlayerOpen"].tap()
        label(favorite, "Remove from favorites")
        XCTAssertTrue(favorite.isSelected && favorite.isHittable)
        XCTAssertEqual(app.buttons["playerPlay"].label, "Play")
        favorite.tap(); label(favorite, "Add to favorites")
        app.buttons["playerCollapse"].tap()
        app.buttons["navigationMore"].tap(); app.buttons["Favorites"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForNonExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 10)); app.buttons["miniPlayerOpen"].tap()
        label(favorite, "Add to favorites")
    }
    @MainActor private func label(_ element: XCUIElement, _ expected: String) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@ AND enabled == true", expected), object: element)], timeout: 20), .completed)
    }
}
