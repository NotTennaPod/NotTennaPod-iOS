import XCTest

final class FeedPullRefreshTests: XCTestCase {
    @MainActor func testShortPullThenRefreshUpdatesLibraryAndCooldownStopsRepeat() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), session = UUID().uuidString
        app.launchArguments = ["-test-library-id", session, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 3))
        address.tap(); address.typeTextSettled("http://127.0.0.1:18767/feed.xml?session=\(session)"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 20))
        app.buttons["subscribeFeed"].tap()
        // Subscribing refreshes the feed, which starts the 20 s same-feed manual-refresh cooldown.
        let subscribed = Date()
        let title = app.buttons["feedTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Pull episode 4")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let base = "http://127.0.0.1:18767"
        let (initial, _) = try await URLSession.shared.data(from: URL(string: "\(base)/arm?session=\(session)")!)
        @MainActor func pull(_ distance: CGFloat) {
            // Start in the episode list just below the podcast header (where a pull begins), so a long
            // pull stays on screen on a phone.
            let header = app.otherElements["feedAppBar"].frame
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: header.midX, dy: header.maxY + 24))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)))
        }
        pull(40)
        XCTAssertEqual(title.label, "Pull Refresh Lab")
        let (afterShort, _) = try await URLSession.shared.data(from: URL(string: "\(base)/count?session=\(session)")!)
        XCTAssertEqual(afterShort, initial)
        _ = try await URLSession.shared.data(from: URL(string: "\(base)/hold?session=\(session)")!)
        let cooldownLeft = 21 - Date().timeIntervalSince(subscribed)
        if cooldownLeft > 0 { try await Task.sleep(for: .seconds(cooldownLeft)) }
        pull(300) // Well past the 114 pt trigger, as a deliberate pull is.
        XCTAssertTrue(app.otherElements["feedRefreshProgress"].waitForExistence(timeout: 5), app.debugDescription)
        _ = try await URLSession.shared.data(from: URL(string: "\(base)/release?session=\(session)")!)
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pull delivered podcast"), object: title)], timeout: 15)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Pull delivered episode")).firstMatch.exists)
        let (afterRefresh, _) = try await URLSession.shared.data(from: URL(string: "\(base)/count?session=\(session)")!)
        pull(300) // Well past the 114 pt trigger, as a deliberate pull is.
        XCTAssertTrue(app.staticTexts["applicationNotice"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["applicationNotice"].label, "Please wait some time before refreshing podcasts again.")
        let (afterCooldown, _) = try await URLSession.shared.data(from: URL(string: "\(base)/count?session=\(session)")!)
        XCTAssertEqual(afterCooldown, afterRefresh)
    }
}
