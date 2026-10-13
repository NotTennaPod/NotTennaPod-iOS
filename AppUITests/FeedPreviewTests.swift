import XCTest

final class FeedPreviewTests: XCTestCase {
    @MainActor func testPreviewStreamingAndPauseRetainTheSharedSessionAfterClosing() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap()
        let source = "http://127.0.0.1:18774/preview.xml?run=playback-\(UUID())"
        func open() {
            app.buttons["addRSS"].tap()
            let address = app.textFields["rssAddress"]
            XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeTextSettled(source)
            app.buttons["Confirm"].tapWhenSettled()
            XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15))
            app.buttons.matching(NSPredicate(format: "label == %@", "Preview episode 12")).firstMatch.tap()
            XCTAssertTrue(app.webViews["episodeShownotes"].waitForExistence(timeout: 5))
        }
        func label(_ expected: String, on button: XCUIElement) {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: button)
            wait(for: [expectation], timeout: 10)
        }
        open()
        let action = app.buttons["episodePrimaryAction"]
        label("Stream", on: action); action.tap(); label("Pause", on: action)
        XCTAssertTrue(app.otherElements["feedPreviewCard"].exists)
        action.tap(); label("Stream", on: action)
        app.buttons["toolbarBack"].tap(); app.buttons["toolbarBack"].tap()
        XCTAssertFalse(app.otherElements["feedPreviewCard"].exists)
        XCTAssertTrue(app.buttons["miniPlayerPlay"].waitForExistence(timeout: 5))
        open(); label("Stream", on: action); action.tap(); label("Pause", on: action)
        action.tap(); label("Stream", on: action)
    }

    @MainActor func testPreviewPersistsEpisodeActionsNavigatesInformationAndSubscribesWithRefresh() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), key = UUID().uuidString
        let path = "/preview.xml?run=\(key)", source = "http://127.0.0.1:18774" + path
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap()
        func open() {
            app.buttons["addRSS"].tap()
            let address = app.textFields["rssAddress"]
            XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeTextSettled(source)
            app.buttons["Confirm"].tapWhenSettled(); XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15))
        }
        open()
        XCTAssertTrue(app.otherElements["feedPreviewCard"].exists)
        XCTAssertEqual(app.buttons["subscribeFeed"].label, "Subscribe")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Preview episode ")).count, 12)
        XCTAssertFalse(app.buttons["episode-action-1"].exists)
        let first = app.buttons.matching(NSPredicate(format: "label == %@", "Preview episode 12")).firstMatch
        XCTAssertTrue(first.exists)
        first.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["addFavorite"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["multiSelect"].exists); app.buttons["addFavorite"].tap()
        XCTAssertTrue(app.staticTexts["episodeSubscriptionNotice"].waitForExistence(timeout: 5))
        app.buttons["toolbarBack"].tap(); XCTAssertTrue(app.buttons["addRSS"].waitForExistence(timeout: 5))
        open()
        XCTAssertTrue(app.staticTexts["episodeSubscriptionNotice"].exists)
        first.tap(); XCTAssertTrue(app.webViews["episodeShownotes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["feedPreviewCard"].exists)
        app.buttons["toolbarBack"].tap(); XCTAssertTrue(app.buttons["previewDescription"].waitForExistence(timeout: 5))
        app.buttons["previewDescription"].tap()
        XCTAssertTrue(app.otherElements["feedInformationScreen"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["statisticsButton"].exists)
        XCTAssertTrue(app.buttons["subscribeFeed"].exists)
        let previewRequests = try await requestCount(path)
        XCTAssertEqual(previewRequests, 1)
        app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["feedInformation"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["feedPreviewCard"].exists)
        XCTAssertTrue(app.buttons["episode-action-1"].exists)
        let deadline = ContinuousClock.now + .seconds(8)
        var count = try await requestCount(path)
        while count < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100)); count = try await requestCount(path)
        }
        XCTAssertEqual(count, 2)
        first.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["removeFavorite"].waitForExistence(timeout: 5)); app.buttons["removeFavorite"].tap()
        app.terminate(); app.launch(); app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 10)); app.buttons["subscriptionFeed-1"].tap()
        XCTAssertTrue(app.buttons["feedInformation"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["subscribeFeed"].exists)
    }
    @MainActor private func requestCount(_ path: String) async throws -> Int {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18774/counts")!)
        return try JSONDecoder().decode([String: Int].self, from: data)[path] ?? 0
    }
}
