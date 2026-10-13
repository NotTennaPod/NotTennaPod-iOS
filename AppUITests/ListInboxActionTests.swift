import XCTest

/// Uses the session-isolated staged feed on 18777. Downloaded NEW state is a
/// separate fixture precondition; ordinary downloading deliberately clears NEW.
final class ListInboxActionTests: XCTestCase {
    @MainActor private func destination(_ destination: String, title: String, app: XCUIApplication) {
        if app.buttons[destination].exists { app.buttons[destination].tap() }
        else { app.buttons["navigationMore"].tap(); app.otherElements["morePopup"].buttons[title].tap() }
    }
    @MainActor private func episode(_ number: Int, _ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Inbox episode \(number)")).firstMatch
    }
    @MainActor private func seedArrivals(_ app: XCUIApplication, session: String) async throws {
        app.launchArguments = ["-test-library-id", session, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let field = app.textFields["rssAddress"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        field.typeTextSettled("http://127.0.0.1:18777/feed.xml?session=\(session)")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 20)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(episode(0, app).waitForExistence(timeout: 10))
        // End the manual refresh cooldown before introducing two fresh rows.
        app.terminate(); app.launch()
        destination("SubscriptionFragment", title: "Subscriptions", app: app)
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 10)); app.buttons["subscriptionFeed-1"].tap()
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18777/advance?session=\(session)&stage=1")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        app.buttons["feedListMore"].tap(); app.buttons["refreshFeed"].tap()
        XCTAssertTrue(episode(2, app).waitForExistence(timeout: 20)); XCTAssertTrue(episode(1, app).exists)
    }

    @MainActor func testInboxContextRemovesOnlyTargetSilentlyAndPersistsAfterRelaunch() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), session = UUID().uuidString
        defer { app.terminate() }
        try await seedArrivals(app, session: session)
        destination("NewEpisodesFragment", title: "Inbox", app: app)
        let first = episode(1, app), second = episode(2, app)
        XCTAssertTrue(first.waitForExistence(timeout: 5)); XCTAssertTrue(second.exists)
        first.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["removeInbox"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["removeInbox"].label, "Remove from inbox")
        XCTAssertLessThan(app.buttons["removeInbox"].frame.minY, app.buttons["markPlayed"].frame.minY)
        app.buttons["removeInbox"].tap()
        XCTAssertTrue(first.waitForNonExistence(timeout: 5)); XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Undo"].exists)
        XCTAssertFalse(app.otherElements["episodeActionSnackbar"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        destination("NewEpisodesFragment", title: "Inbox", app: app)
        XCTAssertFalse(first.exists); XCTAssertTrue(second.waitForExistence(timeout: 5))
        destination("EpisodesFragment", title: "Episodes", app: app)
        XCTAssertTrue(first.waitForExistence(timeout: 5)); first.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["markPlayed"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["removeInbox"].exists)
    }

    @MainActor func testControlledPersistedNewDownloadDeletesOnlyTargetAndSurvivesRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback", "-test-list-inbox-cleanup"]
        app.launch(); defer { app.terminate() }
        let target = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND identifier BEGINSWITH 'episode-'", "Inbox cleanup target")).firstMatch
        let survivor = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND identifier BEGINSWITH 'episode-'", "Inbox cleanup survivor")).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 15)); XCTAssertTrue(survivor.exists)
        let targetID = String(target.identifier.dropFirst("episode-".count))
        destination("NewEpisodesFragment", title: "Inbox", app: app)
        XCTAssertTrue(target.waitForExistence(timeout: 5)); target.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["removeInbox"].waitForExistence(timeout: 5))
        app.buttons["removeInbox"].tap()
        XCTAssertTrue(target.waitForNonExistence(timeout: 5)); XCTAssertTrue(survivor.exists)
        XCTAssertFalse(app.buttons["Undo"].exists)
        XCTAssertFalse(app.otherElements["episodeActionSnackbar"].exists)
        destination("DownloadsFragment", title: "Downloads", app: app)
        XCTAssertTrue(target.waitForNonExistence(timeout: 10)); XCTAssertTrue(survivor.waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        destination("DownloadsFragment", title: "Downloads", app: app)
        XCTAssertFalse(target.exists); XCTAssertTrue(survivor.waitForExistence(timeout: 5))
        destination("QueueFragment", title: "Queue", app: app)
        XCTAssertTrue(target.waitForExistence(timeout: 5)); XCTAssertTrue(survivor.exists)
        XCTAssertEqual(app.buttons["episode-action-" + targetID].label, "Download")
        target.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["markPlayed"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["removeInbox"].exists); XCTAssertTrue(app.buttons["removeFavorite"].exists)
    }

    @MainActor func testAllEpisodesBulkCountsOnlyNewRowsAndPersistsEmptyInbox() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), session = UUID().uuidString
        defer { app.terminate() }
        try await seedArrivals(app, session: session)
        destination("EpisodesFragment", title: "Episodes", app: app)
        XCTAssertTrue(episode(2, app).waitForExistence(timeout: 5)); episode(2, app).press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["multiSelect"].waitForExistence(timeout: 5)); app.buttons["multiSelect"].tap()
        XCTAssertTrue(app.staticTexts["episodeSelectionCount"].waitForExistence(timeout: 5))
        app.buttons["episodeSelectionMore"].tap(); app.buttons["select_toggle"].tap()
        XCTAssertEqual(app.staticTexts["episodeSelectionCount"].label, "3/3 selected")
        let remove = app.buttons["episodeBulk-removeInbox"]
        let actions = app.otherElements["episodeSelectionActions"]
        for _ in 0..<4 where !remove.isHittable { actions.swipeLeft() }
        XCTAssertTrue(remove.isHittable); remove.tap()
        let snackbar = app.otherElements["episodeActionSnackbar"]
        XCTAssertTrue(snackbar.waitForExistence(timeout: 5)); XCTAssertEqual(snackbar.label, "2 episodes removed from inbox.")
        XCTAssertFalse(app.buttons["Undo"].exists)
        XCTAssertTrue(episode(0, app).exists); XCTAssertTrue(episode(1, app).exists); XCTAssertTrue(episode(2, app).exists)
        destination("NewEpisodesFragment", title: "Inbox", app: app)
        XCTAssertTrue(episode(1, app).waitForNonExistence(timeout: 5)); XCTAssertFalse(episode(2, app).exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        destination("NewEpisodesFragment", title: "Inbox", app: app)
        XCTAssertFalse(episode(1, app).exists); XCTAssertFalse(episode(2, app).exists)
        destination("EpisodesFragment", title: "Episodes", app: app)
        XCTAssertTrue(episode(0, app).waitForExistence(timeout: 5)); XCTAssertTrue(episode(1, app).exists); XCTAssertTrue(episode(2, app).exists)
    }
}
