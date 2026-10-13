import XCTest
import SQLite3

/// Swipe journeys on a UUID library seeded from the oracle's Android database
/// (`TestSupport/Data/swipe-settings/swipe-journey.db`, built from `swipe-cases.json`), through the database import:
/// Queue 21–25, History 36, 31, 32, 33, 34 (oracle `history_initial_order`), Inbox 42, 41.
/// Expected texts, orders and outcomes come from the oracle (`expected/swipe-settings.json`), and the
/// runner reads the app's saved library itself (queue table and episode records), not through the app.
@MainActor final class SwipeSettingsJourneyTests: XCTestCase {
    private let library = UUID().uuidString
    private var app = XCUIApplication()
    private var expected: [String: Any] = [:]
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestSupport/Data/swipe-settings")
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        expected = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("expected/swipe-settings.json"))) as? [String: Any])
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback",
                               "-test-seed-android-database", fixtures.appendingPathComponent("swipe-journey.db").path]
    }

    // MARK: Helpers

    private func tap(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 15), id + "\n" + app.debugDescription, file: file, line: line)
        button.tap()
    }
    private func open(_ destination: String, title: String) {
        leaveSettings()
        if app.buttons[destination].exists { app.buttons[destination].tap(); return }
        tap("navigationMore")
        let item = app.otherElements["morePopup"].buttons[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription); item.tap()
    }
    private func leaveSettings() {
        for _ in 0..<4 where app.buttons["toolbarBack"].exists { app.buttons["toolbarBack"].tap() }
    }
    private func ints(_ value: Any?) -> [Int] { (value as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue } }
    /// The list shows exactly `ids`, top to bottom.
    private func expectRows(_ ids: [Int], _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let matched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in MainActor.assumeIsolated {
            let rows = self.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'episode-' AND NOT (identifier BEGINSWITH 'episode-action')"))
                .allElementsBoundByIndex.filter { $0.exists && $0.frame.height > 0 }
            return rows.sorted { $0.frame.minY < $1.frame.minY }.compactMap { Int($0.identifier.dropFirst("episode-".count)) } == ids
        } }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [matched], timeout: 15), .completed, "\(message): expected \(ids)\n\(app.debugDescription)", file: file, line: line)
    }
    /// A physical swipe across most of the row, starting away from the Queue's drag handle.
    private func swipe(_ id: Int, left: Bool) {
        let row = app.buttons["episode-\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10) && row.isHittable, "row \(id)")
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.9 : 0.35, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.1 : 0.98, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
    private func openSwipeSettings() {
        leaveSettings()
        tap("navigationMore"); tap("Settings"); tap("prefScreenInterface")
        let swipe = app.buttons["prefSwipe"], scroll = app.scrollViews["libraryContent"]
        XCTAssertTrue(swipe.waitForExistence(timeout: 10))
        for _ in 0..<8 where !swipe.isHittable || !scroll.frame.contains(swipe.frame) { scroll.swipeUp() }
        XCTAssertEqual(swipe.label.hasPrefix("Swipe actions"), true, swipe.label)
        swipe.tap()
        XCTAssertTrue(app.buttons["prefSwipeQueue"].waitForExistence(timeout: 10))
    }
    private func dialogTitle(_ text: String) -> XCUIElement { app.staticTexts[text] }

    // MARK: Saved data, read by the runner

    private func savedLibrary() throws -> URL {
        // The app's data container is a sibling of this runner's container on the Simulator.
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let applications = support.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = try FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil).map {
            $0.appendingPathComponent("Library/Application Support/UITests-\(library)/library.sqlite")
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
        return try XCTUnwrap(candidates.first, "saved library")
    }
    private func query<T>(_ sql: String, _ row: (OpaquePointer?) throws -> T) throws -> [T] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(try savedLibrary().path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { result.append(try row(statement)) }
        return result
    }
    private func savedQueue() throws -> [Int] { try query("SELECT episode_id FROM queue ORDER BY position") { Int(sqlite3_column_int64($0, 0)) } }
    private func savedState(_ id: Int) throws -> [String: Any] {
        let records = try query("SELECT record FROM episodes WHERE id = \(id)") { statement in
            Data(bytes: sqlite3_column_blob(statement, 0), count: Int(sqlite3_column_bytes(statement, 0)))
        }
        let record = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(records.first)) as? [String: Any])
        return try XCTUnwrap(record["userState"] as? [String: Any])
    }
    private func savedSyncActions() throws -> Int { try query("SELECT count(*) FROM synchronization_outbox") { Int(sqlite3_column_int64($0, 0)) }.first ?? 0 }

    // MARK: Journeys

    /// Settings → Swipe actions (seven rows) → Queue → configure → Queue: swipe Remove → "1 episode removed from queue." →
    /// Undo → the configured other side (Add to favorites) → lock the queue → swipe Remove again (the lock does not
    /// block swipes) → the offer times out → relaunch keeps the removal and the configuration.
    func testQueueConfiguredFromSettingsRemovesWithUndoLockedOrNotAndSurvivesRelaunch() throws {
        app.launch()
        XCTAssertTrue(app.buttons["QueueFragment"].waitForExistence(timeout: 30), app.debugDescription)
        openSwipeSettings()
        // Seven title-only rows in source order (`preferences_swipe.xml`).
        let rows = try XCTUnwrap((expected["settings"] as? [String: Any])?["rows"] as? [[String: Any]])
        let shown = rows.map { app.buttons[$0["key"] as! String] }
        for (row, oracle) in zip(shown, rows) {
            XCTAssertTrue(row.waitForExistence(timeout: 5), oracle["key"] as! String)
            XCTAssertEqual(row.label, oracle["title"] as? String)
        }
        XCTAssertEqual(shown.map(\.frame.minY), shown.map(\.frame.minY).sorted(), "rows in source order")

        tap("prefSwipeQueue")
        XCTAssertTrue(dialogTitle("Swipe actions - Queue").waitForExistence(timeout: 5), app.debugDescription)
        // Dialog defaults (never stored until Confirm): Remove from queue on both sides.
        XCTAssertEqual(app.buttons["inboxSwipePreview-left"].value as? String, "Remove from queue")
        XCTAssertEqual(app.buttons["inboxSwipePreview-right"].value as? String, "Remove from queue")
        tap("inboxSwipeChange-right")
        // The Queue picker, in source order.
        for id in ["REMOVE_FROM_QUEUE", "START_DOWNLOAD", "DELETE", "MARK_FAV", "MARK_PLAYED"] {
            XCTAssertTrue(app.buttons["inboxSwipeChoice-" + id].waitForExistence(timeout: 5), id)
        }
        XCTAssertFalse(app.buttons["inboxSwipeChoice-ADD_TO_QUEUE"].exists)
        tap("inboxSwipeChoice-MARK_FAV")
        XCTAssertTrue(app.buttons["inboxSwipeChoice-MARK_FAV"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["inboxSwipePreview-right"].value as? String, "Add to favorites")
        tap("inboxSwipeConfirm")
        XCTAssertTrue(app.buttons["inboxSwipeConfirm"].waitForNonExistence(timeout: 5))

        open("QueueFragment", title: "Queue")
        XCTAssertTrue(app.buttons["queueMore"].waitForExistence(timeout: 10))
        expectRows([21, 22, 23, 24, 25], "Seeded queue")
        swipe(23, left: true)
        let message = app.staticTexts["1 episode removed from queue."]
        XCTAssertTrue(app.buttons["inboxSwipeUndo"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(message.exists)
        app.buttons["inboxSwipeUndo"].tap()
        expectRows([21, 22, 23, 24, 25], "Undo restores the old place")
        XCTAssertEqual(try savedQueue(), [21, 22, 23, 24, 25])

        // Swipe right: the configured Add to favorites. The row springs back and nothing is offered.
        XCTAssertEqual(try savedState(24)["isFavorite"] as? Bool, false)
        swipe(24, left: false)
        let favorite = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in MainActor.assumeIsolated {
            (try? self.savedState(24)["isFavorite"] as? Bool) == true } }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [favorite], timeout: 10), .completed, "Add to favorites saved")
        XCTAssertFalse(app.buttons["inboxSwipeUndo"].exists)
        expectRows([21, 22, 23, 24, 25], "Add to favorites keeps the row")

        // Lock the queue: swipes still work (the lock blocks only drag and bulk moves).
        tap("queueMore"); tap("queueLock")
        XCTAssertTrue(app.buttons["queueLockConfirm"].waitForExistence(timeout: 5)); app.buttons["queueLockConfirm"].tap()
        XCTAssertTrue(app.buttons["queueLockConfirm"].waitForNonExistence(timeout: 5))
        swipe(23, left: true)
        XCTAssertTrue(app.buttons["inboxSwipeUndo"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(message.exists)
        app.buttons["inboxSwipeUndo"].tap()
        expectRows([21, 22, 23, 24, 25], "Locked queue: Undo")
        swipe(23, left: true)
        XCTAssertTrue(app.buttons["inboxSwipeUndo"].waitForExistence(timeout: 3))
        expectRows([21, 22, 24, 25], "Locked queue: removed")
        // The offer ends by itself; the removal was committed at once.
        XCTAssertTrue(app.buttons["inboxSwipeUndo"].waitForNonExistence(timeout: 15))
        expectRows([21, 22, 24, 25], "No Undo")
        XCTAssertEqual(try savedQueue(), [21, 22, 24, 25])
        XCTAssertEqual(try savedSyncActions(), 0, "no synchronization action")

        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["QueueFragment"].waitForExistence(timeout: 30))
        open("QueueFragment", title: "Queue")
        expectRows([21, 22, 24, 25], "After relaunch")
        XCTAssertEqual(try savedQueue(), [21, 22, 24, 25])
        XCTAssertEqual(try savedState(24)["isFavorite"] as? Bool, true)
        // The configuration survived: a left swipe removes at once, with no first-use dialog.
        swipe(21, left: true)
        XCTAssertTrue(app.buttons["inboxSwipeUndo"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["inboxSwipeConfirm"].exists)
        app.buttons["inboxSwipeUndo"].tap()
        expectRows([21, 22, 24, 25], "Relaunched Undo")
    }

    /// History: the first swipe opens "Swipe actions - Playback history" (Cancel, then Confirm the defaults) →
    /// Remove from history → "Removed from history" → Undo returns the row to its place → remove another one and let
    /// the offer time out → relaunch keeps it removed; only its history date changed. Then the Inbox configured from
    /// Settings removes with its own Undo.
    func testHistoryFirstUseRemoveUndoTimeoutRelaunchAndInboxFromSettings() throws {
        let initial = ints(expected["history_initial_order"])
        let sequence = try XCTUnwrap((expected["history_sequences"] as? [[String: Any]])?.first { $0["name"] as? String == "remove_tied_first_undo" })
        let second = try XCTUnwrap((expected["history_sequences"] as? [[String: Any]])?.first { $0["name"] as? String == "remove_tied_second_no_undo" })
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 30), app.debugDescription)
        open("PlaybackHistoryFragment", title: "Playback history")
        XCTAssertTrue(app.buttons["historyClear"].waitForExistence(timeout: 10), app.debugDescription)
        expectRows(initial, "History order")

        // First use: the swipe opens the dialog and does nothing to the episode.
        swipe(32, left: true)
        XCTAssertTrue(dialogTitle("Swipe actions - Playback history").waitForExistence(timeout: 5), app.debugDescription)
        tap("inboxSwipeCancel")
        XCTAssertTrue(app.buttons["inboxSwipeCancel"].waitForNonExistence(timeout: 5))
        expectRows(initial, "First use changes nothing")
        swipe(32, left: true)
        XCTAssertTrue(dialogTitle("Swipe actions - Playback history").waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["inboxSwipePreview-left"].value as? String, "Remove from history")
        XCTAssertEqual(app.buttons["inboxSwipePreview-right"].value as? String, "Remove from history")
        tap("inboxSwipeConfirm")
        XCTAssertTrue(app.buttons["inboxSwipeConfirm"].waitForNonExistence(timeout: 5))
        expectRows(initial, "Confirm acts on nothing")

        let before = try savedState(32)
        swipe(32, left: true)
        XCTAssertTrue(app.buttons["inboxSwipeUndo"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Removed from history"].exists)
        app.buttons["inboxSwipeUndo"].tap()
        expectRows(ints(sequence["after_undo"]), "Undo restores the old place")
        let restored = try savedState(32)
        XCTAssertEqual((restored["lastPlayedHistoryMilliseconds"] as? NSNumber)?.int64Value, (before["lastPlayedHistoryMilliseconds"] as? NSNumber)?.int64Value)

        // Undo is tapped at once above: the offer lasts Android's LENGTH_LONG (2.75 s).
        swipe(33, left: false)
        XCTAssertTrue(app.buttons["inboxSwipeUndo"].waitForExistence(timeout: 3))
        expectRows(ints(second["after_remove"]), "Removed")
        XCTAssertTrue(app.buttons["inboxSwipeUndo"].waitForNonExistence(timeout: 15))
        expectRows(ints(second["final"]), "No Undo")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 30))
        open("PlaybackHistoryFragment", title: "Playback history")
        expectRows(ints(second["final"]), "After relaunch")
        // Only the history date changed: played state, position and played duration are kept.
        let removed = try savedState(33)
        XCTAssertNil(removed["lastPlayedHistoryMilliseconds"])
        XCTAssertEqual((removed["playedDurationMilliseconds"] as? NSNumber)?.intValue, 900_000)
        let played = try savedState(31)["playState"] as? NSObject
        XCTAssertNotNil(played); XCTAssertEqual(removed["playState"] as? NSObject, played)
        XCTAssertEqual(try savedSyncActions(), 0, "no synchronization action")

        // Inbox configured from Settings: the defaults (left Remove from inbox, right Add to queue).
        openSwipeSettings()
        tap("prefSwipeInbox")
        XCTAssertTrue(dialogTitle("Swipe actions - Inbox").waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.buttons["inboxSwipePreview-left"].value as? String, "Remove from inbox")
        XCTAssertEqual(app.buttons["inboxSwipePreview-right"].value as? String, "Add to queue")
        tap("inboxSwipeConfirm")
        XCTAssertTrue(app.buttons["inboxSwipeConfirm"].waitForNonExistence(timeout: 5))
        open("NewEpisodesFragment", title: "Inbox")
        expectRows([42, 41], "Inbox")
        swipe(41, left: true)
        XCTAssertTrue(app.buttons["inboxSwipeUndo"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Removed from inbox"].exists)
        app.buttons["inboxSwipeUndo"].tap()
        expectRows([42, 41], "Inbox Undo")
    }
}
