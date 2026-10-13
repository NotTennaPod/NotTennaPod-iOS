import XCTest

final class FeedNewEpisodesTests: XCTestCase {
    @MainActor func testQueueThenNothingApplyToRefreshAndPersistAcrossRelaunch() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), session = UUID().uuidString
        app.launchArguments = ["-test-library-id", session, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap(); address.typeTextSettled("http://127.0.0.1:18769/feed.xml?session=\(session)")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["feedSettings"].waitForExistence(timeout: 5))
        app.buttons["feedSettings"].tap()
        openChoice(app)
        XCTAssertTrue(app.buttons["feedNewEpisodes-0"].isSelected)
        app.buttons["feedNewEpisodes-3"].tap()
        openChoice(app)
        XCTAssertTrue(app.buttons["feedNewEpisodes-3"].isSelected)
        app.buttons["feedNewEpisodesCancel"].tap()
        app.buttons["toolbarBack"].tap()
        // Subscription starts a refresh and the source enforces a 20-second
        // process-local cooldown. Relaunch also verifies the saved policy.
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["SubscriptionFragment"].waitForExistence(timeout: 10)); app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 5)); app.buttons["subscriptionFeed-1"].tap()
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18769/advance?session=\(session)&stage=1")!)
        app.buttons["feedListMore"].tap(); app.buttons["refreshFeed"].tap()
        let added = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Action episode 1")).firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 15))
        app.buttons["QueueFragment"].tap()
        XCTAssertTrue(added.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Action episode ")).count, 1)

        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["SubscriptionFragment"].waitForExistence(timeout: 10)); app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 5)); app.buttons["subscriptionFeed-1"].tap()
        app.buttons["feedSettings"].tap(); openChoice(app)
        XCTAssertTrue(app.buttons["feedNewEpisodes-3"].isSelected)
        app.buttons["feedNewEpisodes-2"].tap()
        app.buttons["toolbarBack"].tap()
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18769/advance?session=\(session)&stage=2")!)
        app.buttons["feedListMore"].tap(); app.buttons["refreshFeed"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Action episode 2")).firstMatch.waitForExistence(timeout: 15))
        app.buttons["QueueFragment"].tap()
        XCTAssertTrue(added.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Action episode ")).count, 1)
    }

    @MainActor func testGlobalChoicesControlFreshArrivalsAndSurviveRelaunch() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), session = UUID().uuidString
        app.launchArguments = ["-test-library-id", session, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap()
        address.typeTextSettled("http://127.0.0.1:18769/feed.xml?session=\(session)")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15)); app.buttons["subscribeFeed"].tap()
        for (stage, raw) in [(1,3), (2,2), (3,1)] {
            app.buttons["navigationMore"].tap(); app.buttons["Settings"].tap(); app.buttons["prefScreenDownloads"].tap()
            app.buttons["prefNewEpisodesAction"].tap()
            XCTAssertTrue(app.buttons["prefNewEpisodesAction-1"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["prefNewEpisodesAction-0"].exists)
            if stage == 1 {
                XCTAssertTrue(app.buttons["prefNewEpisodesAction-1"].isSelected)
            }
            app.buttons["prefNewEpisodesAction-\(raw)"].tap()
            app.buttons["prefNewEpisodesAction"].tap()
            XCTAssertTrue(app.buttons["prefNewEpisodesAction-\(raw)"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["prefNewEpisodesAction-\(raw)"].isSelected)
            app.buttons["prefNewEpisodesActionCancel"].tap()
            app.terminate(); app.launch()
            XCTAssertTrue(app.buttons["SubscriptionFragment"].waitForExistence(timeout: 10)); app.buttons["SubscriptionFragment"].tap()
            XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 5)); app.buttons["subscriptionFeed-1"].tap()
            app.buttons["feedSettings"].tap(); openChoice(app)
            XCTAssertTrue(app.buttons["feedNewEpisodes-0"].isSelected)
            app.buttons["feedNewEpisodesCancel"].tap(); app.buttons["toolbarBack"].tap()
            _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18769/advance?session=\(session)&stage=\(stage)")!)
            app.buttons["feedListMore"].tap(); app.buttons["refreshFeed"].tap()
            let fresh = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Action episode \(stage)")).firstMatch
            XCTAssertTrue(fresh.waitForExistence(timeout: 15))
            app.buttons["QueueFragment"].tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Action episode 1")).firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Action episode ")).count, 1)
            if stage == 3 {
                if app.buttons["NewEpisodesFragment"].exists { app.buttons["NewEpisodesFragment"].tap() }
                else { app.buttons["navigationMore"].tap(); app.navigation("Inbox").tap() }
                XCTAssertTrue(fresh.waitForExistence(timeout: 5))
                XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Action episode ")).count, 1)
            }
        }
    }

    @MainActor private func openChoice(_ app: XCUIApplication) {
        let row = app.buttons["feedSettingsNewEpisodes"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        if !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.buttons["feedNewEpisodes-0"].waitForExistence(timeout: 5))
    }

}
