import XCTest

final class FeedAutoDownloadTests: XCTestCase {
    @MainActor func testSavedFilterControlsActualAutomaticDownloadsAfterRefresh() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), session = UUID().uuidString
        app.launchArguments = ["-test-library-id", session, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap()
        address.typeTextSettled("http://127.0.0.1:18775/feed.xml?session=\(session)"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["feedSettings"].waitForExistence(timeout: 5)); app.buttons["feedSettings"].tap()
        tapRow("feedSettingsAutoDownload", app)
        XCTAssertTrue(app.buttons["feedAutoDownload-1"].waitForExistence(timeout: 5))
        app.buttons["feedAutoDownload-2"].tap()
        tapRow("feedSettingsDownloadFilter", app)
        XCTAssertTrue(app.buttons["downloadFilterInclude"].waitForExistence(timeout: 5))
        let term = app.textFields["downloadFilterTerm"]
        term.tap(); term.typeTextSettled("Skip"); app.buttons["downloadFilterAdd"].tap()
        app.buttons["downloadFilterExclude"].tap()
        app.buttons["downloadFilterDuration"].tap()
        let minutes = app.textFields["downloadFilterMinutes"]
        minutes.tap(); minutes.typeTextSettled("0")
        // The dialog moves above the keyboard, so its buttons stay reachable while typing.
        XCTAssertTrue(app.buttons["downloadFilterConfirm"].isHittable, "Confirm must not be covered by the keyboard")
        app.buttons["downloadFilterExclude"].tap()
        app.buttons["downloadFilterConfirm"].tap()
        tapRow("feedSettingsDownloadFilter", app)
        XCTAssertTrue(app.buttons["downloadFilterExclude"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["downloadFilterExclude"].isSelected)
        XCTAssertEqual(minutes.value as? String, "0")
        app.buttons["downloadFilterCancel"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["SubscriptionFragment"].waitForExistence(timeout: 10)); app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 5)); app.buttons["subscriptionFeed-1"].tap()
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18775/arm?session=\(session)")!)
        app.buttons["feedListMore"].tap(); app.buttons["refreshFeed"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Keep episode")).firstMatch.waitForExistence(timeout: 15))
        // IDs follow the response order: existing1, Keep2, Skip3.
        let keep = app.buttons["episode-action-2"], skip = app.buttons["episode-action-3"]
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: keep)], timeout: 25)
        XCTAssertEqual(skip.label, "Download")
        app.buttons["QueueFragment"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Keep episode")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Skip episode")).firstMatch.exists)
    }
    @MainActor private func tapRow(_ id: String, _ app: XCUIApplication) {
        let row = app.buttons[id]; XCTAssertTrue(row.waitForExistence(timeout: 5))
        for _ in 0..<3 where !row.isHittable { app.swipeUp() }
        row.tap()
    }
}
