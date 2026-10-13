import XCTest

final class DownloadLogTests: XCTestCase {
    @MainActor func testHistoryMediaRetryOpenClearAndFeedFailureFallback() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), session = UUID().uuidString
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18776/feed.xml?session=\(session)")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 10)); app.buttons["subscribeFeed"].tap()
        let download = app.buttons["episode-action-1"]
        XCTAssertTrue(download.waitForExistence(timeout: 10)); XCTAssertEqual(download.label, "Download"); download.tap()
        // Android reports the failed download with its message ("Download of "…" failed." with Details),
        // not an error dialog (EpisodeDownloadWorker.sendErrorNotification while the app is in front).
        let failed = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "Download of \"", "\" failed.")).firstMatch
        XCTAssertTrue(failed.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        openLog(app)
        XCTAssertTrue(app.buttons["downloadLogRetry-media-1"].waitForExistence(timeout: 5))
        app.cells["downloadLogRow"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["feedLogEpisode"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["feedLogTechnical"].label, "404")
        app.buttons["downloadLogOpenPodcast"].tap()
        XCTAssertTrue(app.buttons["feedSettings"].waitForExistence(timeout: 5))
        openLog(app)
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18776/recover-media?session=\(session)")!)
        app.buttons["downloadLogRetry-media-1"].tap()
        let two = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: app.cells.matching(identifier: "downloadLogRow"))
        await fulfillment(of: [two], timeout: 20)
        XCTAssertFalse(app.buttons["downloadLogRetry-media-1"].exists)
        closeLog(app)
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18776/fail-feed?session=\(session)")!)
        app.terminate(); app.launch()
        app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 5)); app.buttons["subscriptionFeed-1"].tap()
        app.buttons["feedListMore"].tap(); app.buttons["refreshFeed"].tap()
        XCTAssertTrue(app.buttons["feedRefreshFailure"].waitForExistence(timeout: 15)); app.buttons["feedRefreshFailure"].tap()
        XCTAssertTrue(app.staticTexts["feedLogTechnical"].waitForExistence(timeout: 5)); XCTAssertEqual(app.staticTexts["feedLogTechnical"].label, "503")
        app.buttons["feedLogDetailsOK"].tap()
        openLog(app)
        let retryFeed = app.buttons["downloadLogRetry-feed-1"]
        XCTAssertTrue(retryFeed.waitForExistence(timeout: 5)); retryFeed.tap()
        // This retry follows Refresh immediately and bypasses its 20-second admission cooldown.
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 4"), object: app.cells.matching(identifier: "downloadLogRow"))], timeout: 15)
        app.buttons["downloadLogClear"].tap()
        XCTAssertTrue(app.staticTexts["No download log"].waitForExistence(timeout: 5))
        closeLog(app)
        app.buttons["SubscriptionFragment"].tap(); app.buttons["subscriptionFeed-1"].tap()
        app.buttons["feedRefreshFailure"].tap()
        XCTAssertTrue(app.buttons["downloadLogClear"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No download log"].exists)
        app.terminate(); app.launch(); openLog(app)
        XCTAssertTrue(app.staticTexts["No download log"].waitForExistence(timeout: 5))
    }
    @MainActor private func openLog(_ app: XCUIApplication) {
        app.buttons["navigationMore"].tap(); app.otherElements["morePopup"].buttons["Downloads"].tap()
        XCTAssertTrue(app.buttons["openDownloadLog"].waitForExistence(timeout: 5)); app.buttons["openDownloadLog"].tap()
        XCTAssertTrue(app.buttons["downloadLogClear"].waitForExistence(timeout: 5))
    }
    @MainActor private func closeLog(_ app: XCUIApplication) {
        let sheet = app.otherElements["downloadLogSheet"]
        let top = sheet.frame.minY
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: sheet.frame.midX, dy: max(1, top - 20))).tap()
        XCTAssertTrue(app.buttons["openDownloadLog"].waitForExistence(timeout: 5))
    }
}
