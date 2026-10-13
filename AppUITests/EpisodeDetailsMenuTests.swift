import XCTest

/// Prerequisites: listening fixtures on 18765 and serve-new-episodes-fixture.py
/// on 18769. Libraries and staged refresh namespaces are isolated per test.
final class EpisodeDetailsMenuTests: XCTestCase {
    @MainActor private func subscribe(_ app: XCUIApplication, address: String) {
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let field = app.textFields["rssAddress"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeTextSettled(address)
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15)); app.buttons["subscribeFeed"].tap()
    }
    @MainActor private func menu(_ app: XCUIApplication, expecting id: String) {
        XCTAssertTrue(app.buttons["episodeMore"].waitForExistence(timeout: 5)); app.buttons["episodeMore"].tap()
        XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5))
    }
    @MainActor private func label(_ element: XCUIElement, _ expected: String) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate:
            NSPredicate(format: "label == %@", expected), object: element)], timeout: 20), .completed)
    }
    @MainActor private func inbox(_ app: XCUIApplication) {
        if app.buttons["NewEpisodesFragment"].exists { app.buttons["NewEpisodesFragment"].tap() }
        else { app.buttons["navigationMore"].tap(); app.navigation("Inbox").tap() }
    }

    @MainActor func testPausedDetailsShareCancelPositionHandoffAndSkipKeepsEpisodeInQueue() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch(); defer { app.terminate() }
        subscribe(app, address: "http://127.0.0.1:18765/feed.xml")
        for id in [1, 2] {
            let action = app.buttons["episode-action-\(id)"]
            XCTAssertTrue(action.waitForExistence(timeout: 5)); action.tap(); label(action, "Play")
        }
        // Thirty-second fixture audio otherwise lies entirely inside the default
        // thirty-second smart-completion boundary. Select the supported zero
        // setting so this journey isolates the default keep-on-skip behavior.
        app.buttons["navigationMore"].tap(); app.buttons["Settings"].tap(); app.buttons["prefScreenPlayback"].tap()
        let smart = app.buttons["prefSmartMarkAsPlayedSecs"]
        XCTAssertTrue(smart.waitForExistence(timeout: 5)); if !smart.isHittable { app.swipeUp() }; smart.tap()
        XCTAssertTrue(app.buttons["prefSmartMarkAsPlayedSecs-0"].waitForExistence(timeout: 5)); app.buttons["prefSmartMarkAsPlayedSecs-0"].tap()
        app.buttons["toolbarBack"].tap(); app.buttons["toolbarBack"].tap()
        app.buttons["QueueFragment"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5))
        XCTAssertLessThan(app.buttons["episode-1"].frame.minY, app.buttons["episode-2"].frame.minY)
        app.buttons["episode-action-1"].tap(); label(app.buttons["miniPlayerPlay"], "Pause")
        app.buttons["miniPlayerOpen"].tap()
        app.descendants(matching: .any)["playerSeek"].coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        app.buttons["playerPlay"].tap(); label(app.buttons["playerPlay"], "Play")
        let position = app.staticTexts["playerPosition"].label
        XCTAssertNotEqual(position, "00:00:00")
        app.buttons["playerCollapse"].tap(); app.buttons["episode-1"].tap()
        menu(app, expecting: "skip")
        XCTAssertEqual(app.buttons["skip"].label, "Skip episode")
        XCTAssertLessThan(app.buttons["skip"].frame.minY, app.buttons["markPlayed"].frame.minY)
        XCTAssertLessThan(app.buttons["removeFromQueue"].frame.minY, app.buttons["openPodcast"].frame.minY)
        XCTAssertLessThan(app.buttons["addFavorite"].frame.minY, app.buttons["share"].frame.minY)
        app.buttons["share"].tap()
        let checkbox = app.buttons["episodeSharePosition"], social = app.buttons["episodeShareSocial"]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5))
        if checkbox.value as? String == "Checked" { checkbox.tap() }
        XCTAssertFalse((social.value as? String ?? "").contains("Starting from:"))
        checkbox.tap(); XCTAssertEqual(checkbox.value as? String, "Checked")
        XCTAssertTrue((social.value as? String ?? "").contains("Starting from: \(position)"))
        let panel = app.otherElements["episodeShareSheet"]
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: panel.frame.midX - app.frame.minX,
            dy: panel.frame.minY - app.frame.minY - 12)).tap()
        XCTAssertTrue(checkbox.waitForNonExistence(timeout: 5))
        menu(app, expecting: "share"); app.buttons["share"].tap()
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5)); XCTAssertEqual(checkbox.value as? String, "Checked")
        social.tap()
        let copy = app.cells["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        menu(app, expecting: "skip")
        app.buttons["skip"].tap()
        label(app.buttons["miniPlayerPlay"], "Pause")
        label(app.buttons["miniPlayerOpen"], "First episode: a short introduction. Parity Listening Lab")
        app.buttons["miniPlayerOpen"].tap()
        app.buttons["playerPlay"].tap(); label(app.buttons["playerPlay"], "Play")
        app.buttons["playerCollapse"].tap()
        menu(app, expecting: "markPlayed")
        XCTAssertFalse(app.buttons["skip"].exists)
        XCTAssertTrue(app.buttons["removeFromQueue"].exists)
        XCTAssertFalse(app.buttons["markUnplayed"].exists)
        app.buttons["share"].tap()
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5))
        XCTAssertTrue((social.value as? String ?? "").contains("Starting from: \(position)"))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["QueueFragment"].waitForExistence(timeout: 10)); app.buttons["QueueFragment"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["episode-2"].exists)
        XCTAssertLessThan(app.buttons["episode-1"].frame.minY, app.buttons["episode-2"].frame.minY)
        app.buttons["episode-1"].tap(); menu(app, expecting: "share"); app.buttons["share"].tap()
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5)); XCTAssertEqual(checkbox.value as? String, "Checked")
        XCTAssertTrue((social.value as? String ?? "").contains("Starting from: \(position)"))
    }

    @MainActor func testRemoveFromInboxDisappearsFromMenuAndInboxAndSurvivesRelaunch() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), session = UUID().uuidString
        app.launchArguments = ["-test-library-id", session, "-test-muted-playback"]
        app.launch(); defer { app.terminate() }
        subscribe(app, address: "http://127.0.0.1:18769/feed.xml?session=\(session)")
        // Relaunch ends the source refresh cooldown before adding a new arrival.
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["SubscriptionFragment"].waitForExistence(timeout: 10)); app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 5)); app.buttons["subscriptionFeed-1"].tap()
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18769/advance?session=\(session)&stage=1")!)
        app.buttons["feedListMore"].tap(); app.buttons["refreshFeed"].tap()
        let fresh = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Action episode 1")).firstMatch
        XCTAssertTrue(fresh.waitForExistence(timeout: 15))
        inbox(app); XCTAssertTrue(fresh.waitForExistence(timeout: 5)); fresh.tap()
        menu(app, expecting: "removeFromInbox")
        XCTAssertEqual(app.buttons["removeFromInbox"].label, "Remove from inbox")
        XCTAssertFalse(app.buttons["skip"].exists)
        XCTAssertLessThan(app.buttons["removeFromInbox"].frame.minY, app.buttons["markPlayed"].frame.minY)
        app.buttons["removeFromInbox"].tap()
        menu(app, expecting: "markPlayed")
        XCTAssertFalse(app.buttons["removeFromInbox"].exists)
        XCTAssertFalse(app.buttons["Undo"].exists)
        let popup = app.scrollViews["episodeMenuPanel"]
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: popup.frame.minX - app.frame.minX - 12, dy: popup.frame.midY - app.frame.minY)).tap()
        XCTAssertTrue(popup.waitForNonExistence(timeout: 5))
        app.buttons["toolbarBack"].tap()
        XCTAssertTrue(fresh.waitForNonExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10)); inbox(app)
        XCTAssertFalse(fresh.exists)
        app.buttons["SubscriptionFragment"].tap(); app.buttons["subscriptionFeed-1"].tap()
        XCTAssertTrue(fresh.waitForExistence(timeout: 5)); fresh.tap(); menu(app, expecting: "markPlayed")
        XCTAssertFalse(app.buttons["removeFromInbox"].exists)
    }
}
