import XCTest

/// Journey on a library seeded from the oracle's Android fixture (`TestSupport/Data/queue-sort-clear/queue.db`,
/// queue 101, 104, 108, 111, 113) through the database import. Expected orders come from the independent oracle
/// (`expected/queue-sort.json`, case `ks_duration_tie_back`):
/// Sort by Duration with Keep sorted → add 102 from its podcast → re-sorted → Clear queue (Cancel, then Confirm) →
/// Enqueue location Front and Keep sorted off → add 103 then 115 → relaunch keeps the queue and the settings.
@MainActor final class QueueSortJourneyTests: XCTestCase {
    private var app = XCUIApplication()
    private var expected: [String: Any] = [:]

    override func setUpWithError() throws {
        continueAfterFailure = false
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestSupport/Data/queue-sort-clear")
        let oracle = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("expected/queue-sort.json"))) as? [String: Any])
        expected = try XCTUnwrap((oracle["enqueue"] as? [[String: Any]])?.first { $0["name"] as? String == "ks_duration_tie_back" })
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback",
                               "-test-seed-android-database", fixtures.appendingPathComponent("queue.db").path]
    }
    private func ints(_ key: String) -> [Int] { (expected[key] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue } }
    /// The Queue shows exactly `ids`, top to bottom.
    private func expectQueue(_ ids: [Int], _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let matched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in MainActor.assumeIsolated {
            let rows = self.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'episode-' AND NOT (identifier BEGINSWITH 'episode-action')"))
                .allElementsBoundByIndex.filter { $0.exists && $0.frame.height > 0 }
            let shown = rows.sorted { $0.frame.minY < $1.frame.minY }.compactMap { Int($0.identifier.dropFirst("episode-".count)) }
            return shown == ids
        } }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [matched], timeout: 15), .completed, "\(message): expected \(ids)\n\(app.debugDescription)", file: file, line: line)
    }
    private func tap(_ id: String) {
        let button = app.buttons[id]; XCTAssertTrue(button.waitForExistence(timeout: 10), id + "\n" + app.debugDescription); button.tap()
    }
    private func openQueue() {
        if !app.buttons["QueueFragment"].exists { tap("toolbarBack") }
        tap("QueueFragment")
        XCTAssertTrue(app.buttons["queueMore"].waitForExistence(timeout: 10))
    }
    /// An outside tap closes the sheet; aim just above it.
    private func closeSortSheet() {
        let sheet = app.otherElements["queueSortSheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -60)).tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }
    private func addToQueue(_ episode: Int, feed: Int) {
        tap("SubscriptionFragment")
        let tile = app.buttons["subscriptionFeed-\(feed)"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        for _ in 0..<5 where !tile.isHittable { app.swipeUp() }
        tile.tap()
        let row = app.buttons["episode-\(episode)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        for _ in 0..<5 where !row.isHittable { app.swipeUp() }
        row.tap()
        tap("episodeMore"); tap("addToQueue")
        XCTAssertTrue(app.buttons["addToQueue"].waitForNonExistence(timeout: 5))
    }
    private func attachScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func openPlaybackSettings() {
        tap("navigationMore"); tap("Settings"); tap("prefScreenPlayback")
    }

    func testSortKeepSortedAddClearEnqueueFrontAndRelaunch() throws {
        app.launch()
        XCTAssertTrue(app.buttons["QueueFragment"].waitForExistence(timeout: 30), app.debugDescription)
        openQueue()
        expectQueue([101, 104, 108, 111, 113], "Seeded queue")

        // Sort by Duration (shortest first) and keep it sorted.
        tap("queueMore")
        XCTAssertTrue(app.buttons["queueLock"].exists, "Lock is offered while the queue is not kept sorted")
        attachScreen("m23-queue-menu")
        tap("queueSort")
        let keep = app.buttons["queueKeepSorted"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        XCTAssertFalse(keep.isEnabled, "Disabled until an order is chosen")
        tap("queueSort-duration")
        XCTAssertEqual(app.buttons["queueSort-duration"].label, "Duration\u{a0}▲")
        XCTAssertTrue(keep.isEnabled); keep.tap()
        XCTAssertEqual(keep.value as? String, "On")
        attachScreen("m23-sort-sheet-keep-sorted")
        closeSortSheet()
        expectQueue(ints("queue"), "Sorted by duration")
        tap("queueMore")
        XCTAssertTrue(app.buttons["queueSort"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["queueLock"].exists, "Lock is hidden while Keep sorted is on")
        attachScreen("m23-queue-menu-keep-sorted")
        app.otherElements["queueMenu"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()

        // An added episode is sorted in; its tie keeps Enqueue location's (Back) place.
        addToQueue(102, feed: 3)
        openQueue()
        expectQueue(ints("result"), "Keep sorted after an addition")

        // Clear queue: Cancel keeps everything, Confirm removes every episode.
        tap("queueMore"); tap("queueClear")
        XCTAssertTrue(app.staticTexts["Please confirm that you want to remove ALL episodes from the queue."].waitForExistence(timeout: 5))
        attachScreen("m23-clear-queue-confirmation")
        tap("queueClearCancel")
        expectQueue(ints("result"), "Cancel keeps the queue")
        tap("queueMore"); tap("queueClear"); tap("queueClearConfirm")
        XCTAssertTrue(app.staticTexts["No queued episodes"].waitForExistence(timeout: 10), app.debugDescription)
        expectQueue([], "Cleared")

        // Keep sorted off, Enqueue location Front, then two additions: the later one goes first.
        tap("queueMore"); tap("queueSort")
        XCTAssertTrue(keep.waitForExistence(timeout: 5)); XCTAssertEqual(keep.value as? String, "On")
        keep.tap(); XCTAssertEqual(keep.value as? String, "Off")
        closeSortSheet()
        openPlaybackSettings()
        let location = app.buttons["prefEnqueueLocation"]
        XCTAssertTrue(location.waitForExistence(timeout: 5))
        for _ in 0..<4 where !location.isHittable { app.swipeUp() }
        attachScreen("m23-playback-settings-queue-rows")
        location.tap(); tap("prefEnqueueLocation-FRONT")
        XCTAssertTrue(app.buttons["prefEnqueueLocation-FRONT"].waitForNonExistence(timeout: 5))
        tap("toolbarBack"); tap("toolbarBack")
        addToQueue(103, feed: 3)
        tap("toolbarBack")
        addToQueue(115, feed: 3)
        openQueue()
        expectQueue([115, 103], "Front")

        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["QueueFragment"].waitForExistence(timeout: 30))
        openQueue()
        expectQueue([115, 103], "Queue kept after relaunch")
        tap("queueMore"); tap("queueSort")
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        XCTAssertEqual(keep.value as? String, "Off"); XCTAssertFalse(keep.isEnabled)
        XCTAssertEqual(app.buttons["queueSort-duration"].label, "Duration", "No active row while Keep sorted is off")
        closeSortSheet()
        openPlaybackSettings()
        XCTAssertTrue(location.waitForExistence(timeout: 5))
        for _ in 0..<4 where !location.isHittable { app.swipeUp() }
        location.tap()
        XCTAssertTrue(app.buttons["prefEnqueueLocation-FRONT"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["prefEnqueueLocation-FRONT"].isSelected, "Enqueue location Front kept after relaunch")
        XCTAssertFalse(app.buttons["prefEnqueueLocation-BACK"].isSelected)
        tap("prefEnqueueLocationCancel")
    }
}
