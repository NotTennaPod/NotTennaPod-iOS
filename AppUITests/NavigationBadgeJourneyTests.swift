import XCTest

/// Journey with real touches: the bottom-navigation Inbox badge of an
/// Android 3.12.1 library (`TestSupport/Data/database-restore/gap-data/counter-states.db`, through the
/// database import) counts only NEW episodes of subscribed feeds, as VoiceOver reads it ("Inbox, 5 new
/// notifications" in Android's TalkBack wording), drops at once after Mark as played and Remove from inbox
/// from a row's long-press menu, and keeps its count after relaunch. Numbers: `counter-expected.json`
/// (Android's own SQL through `navigation_counters.py`); the mounted test covers every other action.
@MainActor final class NavigationBadgeJourneyTests: XCTestCase {
    private let app = XCUIApplication()
    private var inbox: [Int] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestSupport/Data/database-restore/gap-data")
        let oracle = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("counter-expected.json"))) as? [String: Any])
        inbox = try XCTUnwrap(oracle["states"] as? [[String: Any]]).compactMap { ($0["inbox"] as? NSNumber)?.intValue }
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback",
                               "-test-seed-android-database", fixtures.appendingPathComponent("counter-states.db").path]
    }
    override func tearDown() { app.terminate() }

    private func spoken(_ count: Int) -> String { "\(count) new notification" + (count == 1 ? "" : "s") }
    /// The Inbox item of the bottom bar as accessibility reads it.
    private func expectBadge(_ count: Int, _ stage: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons["NewEpisodesFragment"]
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in MainActor.assumeIsolated {
            button.exists && button.label == "Inbox" && (button.value as? String ?? "") == self.spoken(count)
        } }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 10), .completed,
                       "\(stage): Inbox badge \(count), read \(String(describing: button.value))", file: file, line: line)
    }
    private func menuAction(_ episode: Int, _ action: String) {
        let row = app.buttons["episode-\(episode)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        row.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons[action].tapWhenSettled()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "episode \(episode) left the Inbox")
    }

    func testInboxBadgeCountsSubscribedNewAndDropsAtOnceAfterRowActions() throws {
        app.launch()
        XCTAssertTrue(app.buttons["NewEpisodesFragment"].waitForExistence(timeout: 30), app.debugDescription)
        // NEW episodes of the archived feed and of the preview feed do not count.
        expectBadge(inbox[0], "restored library")
        app.buttons["NewEpisodesFragment"].tapWhenSettled()
        menuAction(28, "markPlayed")
        expectBadge(inbox[1], "after Mark as played")
        menuAction(29, "removeInbox")
        expectBadge(inbox[2], "after Remove from inbox")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["NewEpisodesFragment"].waitForExistence(timeout: 30), app.debugDescription)
        expectBadge(inbox[2], "after relaunch")
    }
}
