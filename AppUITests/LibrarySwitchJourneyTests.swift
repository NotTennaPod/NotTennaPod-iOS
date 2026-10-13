import XCTest

/// Library switching (PROTOCOL §15.4) through the app on a UUID test library: a server library is kept on the device
/// (DEBUG fixture, seeded from the `mixed` Android database), and a switch to it is requested while an episode of
/// the standalone library plays. Audio is never interrupted: the switch waits until the person pauses, then the app
/// shows the server library. A relaunch keeps it; a switch recorded before a start (as a logout leaves it) is
/// applied at launch, before the library opens.
@MainActor final class LibrarySwitchJourneyTests: XCTestCase {
    private let library = UUID().uuidString
    private let app = XCUIApplication()
    private let database = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestSupport/Data/subscriptions-screen/databases/mixed.db").path

    override func setUp() { continueAfterFailure = false }

    private func tap(_ id: String, timeout: TimeInterval = 15) {
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: timeout), id + "\n" + app.debugDescription)
        button.tapWhenSettled()
    }
    private func destination(_ id: String, title: String) {
        if app.buttons[id].exists { app.buttons[id].tapWhenSettled() } else { tap("navigationMore"); tap(title) }
    }
    private func waitLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 20) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, "\(label): \(element.exists ? element.label : "missing")")
    }
    /// The standalone library holds only the fixture's feed (1); the server library holds the `mixed` database's
    /// subscriptions, among them feed 4.
    private func showsServerLibrary(_ expected: Bool) {
        destination("SubscriptionFragment", title: "Subscriptions")
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 20), app.debugDescription)
        if expected { XCTAssertTrue(app.buttons["subscriptionFeed-4"].waitForExistence(timeout: 20), app.debugDescription) }
        else { XCTAssertFalse(app.buttons["subscriptionFeed-4"].exists, app.debugDescription) }
    }

    func test01SwitchWaitsForThePauseAndIsKeptAndAppliedAtLaunch() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: database), database)
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback", "-test-list-inbox-cleanup",
                               "-test-server-library", database, "-test-switch-library-when-playing"]
        app.launch()
        showsServerLibrary(false)

        destination("QueueFragment", title: "Queue")
        let action = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "episode-action-")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 20), app.debugDescription)
        waitLabel(action, "Play"); action.tapWhenSettled()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 15))
        waitLabel(app.buttons["miniPlayerPlay"], "Pause")
        // Requested while playing: it waits, and playback goes on.
        let requested = app.windows.matching(NSPredicate(format: "label == %@", "librarySwitch: requested")).firstMatch
        XCTAssertTrue(requested.waitForExistence(timeout: 20), app.debugDescription)
        waitLabel(app.buttons["miniPlayerPlay"], "Pause")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "episode-action-")).firstMatch.exists,
                      "the standalone library's queue is still shown")

        // The person pauses: the switch runs and the app shows the server library, nothing playing.
        app.buttons["miniPlayerPlay"].tapWhenSettled()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 30))
        showsServerLibrary(true)
        XCTAssertFalse(app.buttons["miniPlayerPlay"].exists && app.buttons["miniPlayerPlay"].label == "Pause")

        // Relaunch: the server library stays the active one.
        app.terminate()
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback"]
        app.launch()
        showsServerLibrary(true)

        // A switch recorded before the start (logout) is applied before the library opens.
        app.terminate()
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback", "-test-record-library-switch", "standalone"]
        app.launch()
        showsServerLibrary(false)
        destination("QueueFragment", title: "Queue")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "episode-action-")).firstMatch
            .waitForExistence(timeout: 20), "the standalone library's queue and data are unchanged")
    }
}
