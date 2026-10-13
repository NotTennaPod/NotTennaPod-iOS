import XCTest

/// New-episode notifications (Android `NewEpisodesNotification`): one notification per podcast plus the
/// "Your subscriptions have new episodes." summary, all in one group; tapping a podcast's notification opens
/// that podcast as a top-level screen, tapping the summary opens the Inbox.
///
/// The app's own work is checked here through a recording notification center (the fixture's panel shows
/// exactly what the app posted, and a row tap takes the notification tap's route). The system permission
/// prompt and Notification Center presentation are Apple's and can't be reached on a default iOS 27.0 iPhone
/// Simulator (the prompt never appears there); they are checked on a real device.
final class EpisodeNotificationTests: XCTestCase {
    @MainActor func testNotificationGroupContentAndTapRoutes() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback", "-test-notification-delivery"]
        app.launch()
        XCTAssertTrue(app.buttons["publishFixtureNotifications"].waitForExistence(timeout: 10))
        app.buttons["publishFixtureNotifications"].tap()
        XCTAssertTrue(app.buttons["SubscriptionFragment"].waitForExistence(timeout: 15), app.debugDescription)

        // Grouping and content: three notifications in the one EPISODES group, with Android's wording.
        let group = app.descendants(matching: .any)["fixtureNotificationGroup.de.danoeh.antennapod.EPISODES"]
        XCTAssertTrue(group.waitForExistence(timeout: 5), app.debugDescription)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fixtureNotification.'"))
        XCTAssertEqual(rows.count, 3, app.debugDescription)
        XCTAssertEqual(group.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fixtureNotification.'")).count, 3)
        func feedRow(_ title: String) -> XCUIElement {
            group.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fixtureNotification.new-episodes.feed.' AND label CONTAINS %@",
                "\(title) has a new episode")).firstMatch
        }
        let alpha = feedRow("Notification Alpha"), beta = feedRow("Notification Beta")
        XCTAssertTrue(alpha.exists && beta.exists, app.debugDescription)
        XCTAssertTrue(alpha.label.contains("New episode"))
        XCTAssertEqual(alpha.value as? String, "artwork", "The podcast cover is attached")
        XCTAssertEqual(beta.value as? String, "artwork")
        let summary = group.buttons["fixtureNotification.new-episodes.summary"]
        XCTAssertTrue(summary.exists)
        XCTAssertTrue(summary.label.contains("Your subscriptions have new episodes."), summary.label)

        // A podcast's notification opens that podcast as a top-level screen (no Back).
        alpha.tap()
        XCTAssertTrue(app.buttons["feedInformation"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.descendants(matching: .any)["feedTitle"].label, "Notification Alpha")
        XCTAssertFalse(app.buttons["toolbarBack"].exists)

        // The summary opens the Inbox, replacing the podcast screen.
        summary.tap()
        XCTAssertTrue(app.staticTexts["screenTitle"].waitForExistence(timeout: 10))
        let inbox = NSPredicate(format: "label == 'Inbox'")
        expectation(for: inbox, evaluatedWith: app.staticTexts["screenTitle"])
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["feedInformation"].exists)
        XCTAssertFalse(app.buttons["toolbarBack"].exists)
    }
}
