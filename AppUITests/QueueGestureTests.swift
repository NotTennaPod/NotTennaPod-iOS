import XCTest
import SQLite3

final class QueueGestureTests: XCTestCase {
    /// The fixture's Queue: episodes 1–16 (`-test-queue-gestures`).
    private let fixtureQueue = Array(1...16)
    private var library = ""
    /// Each launch gets a fresh library: the fixture seeds it once and the journeys save new queue orders and the
    /// lock, so a fixed library would start the next run from the previous run's queue. A relaunch inside a test
    /// reuses `app.launchArguments`, so it keeps the same library.
    @MainActor private func launch(_ name: String, interrupt: String? = nil, rtl: Bool = false, large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        library = UUID().uuidString
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback", "-test-queue-gestures"]
        if ["scroll","resize","keyboard"].contains(name) { app.launchArguments += ["-test-m10-a7-diagnostics"] }
        if let interrupt { app.launchArguments += ["-test-queue-interrupt", interrupt] }
        if rtl { app.launchArguments += ["-test-queue-rtl"] }
        if large { app.launchArguments += ["-test-queue-large-text"] }
        app.launch()
        XCTAssertTrue(app.windows["queueFixtureReady"].waitForExistence(timeout: 35))
        if !app.buttons["queueMore"].exists { app.buttons["QueueFragment"].tap() }
        XCTAssertTrue(app.buttons["episode-3"].waitForExistence(timeout: 6))
        return app
    }
    @MainActor private func order(_ app: XCUIApplication) -> [Int] {
        // Each accessibility property crosses the automation boundary. Read it once;
        // sorting live elements repeatedly can exhaust the wait before evaluating order.
        let rows = app.buttons.matching(NSPredicate(format: "identifier MATCHES 'episode-[0-9]+'"))
            .allElementsBoundByIndex.map { (y: $0.frame.minY, identifier: $0.identifier) }
        return rows.sorted { $0.y < $1.y }.compactMap { Int($0.identifier.dropFirst(8)) }
    }
    /// Rows are built only near the screen (LazyContentList), so the rows that exist are one unbroken stretch of the
    /// Queue: they must be exactly that stretch of the expected order.
    @MainActor private func isStretch(_ shown: [Int], of expected: [Int]) -> Bool {
        guard let first = shown.first, let start = expected.firstIndex(of: first), start + shown.count <= expected.count else { return false }
        return Array(expected[start..<start + shown.count]) == shown
    }
    @MainActor private func expectOrder(_ expected: [Int], _ app: XCUIApplication) {
        // A complete first snapshot is already an exact result; AX collection time
        // does not measure how long the application needed to settle.
        if !isStretch(order(app), of: expected) {
            let predicate = NSPredicate { _, _ in MainActor.assumeIsolated { self.isStretch(self.order(app), of: expected) } }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: app)], timeout: 6), .completed,
                           "Queue order \(order(app)), expected a stretch of \(expected)")
        }
        // The rows on screen are only a stretch, so a complete order must also be the one the app saved (and a
        // relaunch reads): nothing off screen lost or misplaced. Mid-drag orders omit the lifted row and are not saved.
        guard Set(expected) == Set(fixtureQueue), expected.count == fixtureQueue.count else { return }
        if savedQueue() == expected { return }
        let saved = NSPredicate { _, _ in MainActor.assumeIsolated { self.savedQueue() == expected } }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: saved, object: app)], timeout: 6), .completed,
                       "Saved queue \(savedQueue() ?? []), expected \(expected)")
    }
    /// The Queue the app saved, read by the runner from the app's library (a sibling data container on the
    /// Simulator), as the swipe-settings journey reads it.
    @MainActor private func savedQueue() -> [Int]? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false),
              let containers = try? FileManager.default.contentsOfDirectory(
                  at: support.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(), includingPropertiesForKeys: nil),
              let path = containers.map({ $0.appendingPathComponent("Library/Application Support/UITests-\(library)/library.sqlite").path })
                  .first(where: { FileManager.default.fileExists(atPath: $0) }) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT episode_id FROM queue ORDER BY position", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var ids: [Int] = []
        while sqlite3_step(statement) == SQLITE_ROW { ids.append(Int(sqlite3_column_int64(statement, 0))) }
        return ids
    }
    @MainActor private func drag(_ id: Int, to target: Int, x: CGFloat = 18, app: XCUIApplication, rtl: Bool = false, hold: TimeInterval = 0) {
        let row = app.buttons["episode-\(id)"], destination = app.buttons["episode-\(target)"]
        XCTAssertTrue(row.isHittable && destination.isHittable)
        let start = row.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rtl ? row.frame.width - x : x, dy: row.frame.height/2))
        let delta = destination.frame.midY - row.frame.midY
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: delta + (delta > 0 ? 10 : -10))), withVelocity: .slow, thenHoldForDuration: hold)
    }
    /// Ordinary list scrolling is setup, not a keyboard-command assertion. Use the title
    /// area, away from either leading artwork/handle, and preserve the literal Queue order.
    @MainActor private func scrollRowsIntoView(_ ids: [Int], app: XCUIApplication, rtl: Bool = false) {
        // The complete saved order, not the rows that happen to be built: scrolling builds others.
        let content = app.scrollViews["libraryContent"], originalOrder = savedQueue() ?? order(app)
        for _ in 0..<8 {
            let viewport = content.frame
            let rows = ids.map { app.buttons["episode-\($0)"] }
            guard rows.allSatisfy({ $0.exists }), viewport.height > 0 else {
                XCTFail("Scroll setup requires the requested Queue rows and a nonempty viewport"); return
            }
            let frames = rows.map(\.frame)
            if frames.allSatisfy({ viewport.contains($0) }) && rows.allSatisfy({ $0.isHittable }) { return }
            let top = frames.map(\.minY).min()!, bottom = frames.map(\.maxY).max()!
            guard bottom - top <= viewport.height else {
                XCTFail("Requested drag endpoints do not fit in the actual Queue viewport"); return
            }
            // Center the row union so ordinary scrolling crosses UIKit pan recognition.
            // Tiny edge-only deltas can remain taps and open episode details.
            let displacement = viewport.midY - (top + bottom) / 2
            guard displacement != 0 else {
                XCTFail("Queue rows are inside the viewport but not hittable; scrolling cannot repair this setup"); return
            }
            let distance = min(abs(displacement), viewport.height * 0.4) * (displacement > 0 ? 1 : -1)
            let start = content.coordinate(withNormalizedOffset: .init(dx: rtl ? 0.35 : 0.65, dy: 0.5))
            start.press(forDuration: 0.01, thenDragTo: start.withOffset(.init(dx: 0, dy: distance)),
                        withVelocity: .slow, thenHoldForDuration: 0)
            expectOrder(originalOrder, app)
        }
        XCTFail("Ordinary Queue scrolling did not expose both drag endpoints; no keyboard fallback was used")
    }
    @MainActor private func lock(_ app: XCUIApplication) {
        app.buttons["queueMore"].tap(); app.buttons["queueLock"].tap()
    }
    @MainActor func test01ReorderLockContextBulkAndRelaunch() {
        let app = launch("journey"); defer { app.terminate() }
        drag(1,to:3,app:app); expectOrder([2,3,1] + Array(4...16),app)
        lock(app); XCTAssertTrue(app.buttons["queueLockCancel"].waitForExistence(timeout: 4))
        app.buttons["queueLockSuppress"].tap(); app.buttons["queueLockCancel"].tap()
        lock(app); XCTAssertTrue(app.buttons["queueLockConfirm"].waitForExistence(timeout: 4))
        app.buttons["queueLockSuppress"].tap(); app.buttons["queueLockConfirm"].tap()
        drag(1,to:2,x:25,app:app); expectOrder([2,3,1] + Array(4...16),app)
        app.buttons["episode-1"].press(forDuration:0.7); XCTAssertTrue(app.buttons["queue-top"].waitForExistence(timeout:4))
        app.buttons["queue-top"].tap(); expectOrder(Array(1...16),app)
        lock(app); scrollRowsIntoView([3,1],app:app); drag(3,to:1,x:36,app:app); expectOrder([3,1,2]+Array(4...16),app)
        app.buttons["episode-2"].press(forDuration:0.7); app.buttons["multiSelect"].tap(); app.buttons["episode-4"].tap()
        XCTAssertFalse(app.staticTexts["queueInformation"].exists)
        let bulk = app.buttons["queueBulk-top"]
        for _ in 0..<6 where !bulk.isHittable { app.otherElements["episodeSelectionActions"].swipeLeft() }
        XCTAssertTrue(bulk.isHittable); bulk.tap(); expectOrder([2,4,3,1]+Array(5...16),app)
        lock(app); app.buttons["SubscriptionFragment"].tap(); app.buttons["QueueFragment"].tap()
        expectOrder([2,4,3,1]+Array(5...16),app)
        app.terminate(); app.launch(); XCTAssertTrue(app.windows["queueFixtureReady"].waitForExistence(timeout:35))
        if !app.buttons["queueMore"].exists { app.buttons["QueueFragment"].tap() }
        expectOrder([2,4,3,1]+Array(5...16),app)
        drag(3,to:2,x:25,app:app); expectOrder([2,4,3,1]+Array(5...16),app)
    }
    /// Dragging from the leading handle area reorders; dragging from the middle or trailing
    /// part of a row does not (it scrolls instead).
    @MainActor func test02LeadingHandleDragsAndRowBodyDoesNot() {
        let app=launch("boundaries"); defer { app.terminate() }
        let width = app.buttons["episode-3"].frame.width
        drag(3,to:1,x:width/2,app:app); expectOrder(Array(1...16),app); scrollRowsIntoView([3,1],app:app)
        drag(3,to:1,x:width-18,app:app); expectOrder(Array(1...16),app); scrollRowsIntoView([3,1],app:app)
        drag(3,to:1,x:18,app:app); expectOrder([3,1,2]+Array(4...16),app)
    }
    @MainActor func test03EdgeAutoscroll() {
        let app=launch("scroll"); defer { app.terminate() }
        let row=app.buttons["episode-1"], start=row.coordinate(withNormalizedOffset:.zero).withOffset(.init(dx:18,dy:row.frame.height/2))
        let viewport = app.scrollViews["libraryContent"].frame
        let initialVisibleCount = app.buttons.matching(NSPredicate(format:"identifier MATCHES 'episode-[0-9]+'"))
            .allElementsBoundByIndex.filter { viewport.contains($0.frame) }.count
        let bottom=viewport.maxY-5
        start.press(forDuration:0.05,thenDragTo:start.withOffset(.init(dx:0,dy:bottom-row.frame.midY)),withVelocity:.slow,thenHoldForDuration:3)
        XCTAssertGreaterThan(order(app).firstIndex(of:1) ?? 0, initialVisibleCount)
    }
    @MainActor func test12KeyboardTopAndBottom() throws {
        // XCUITest key delivery does not reach the app on the Duo Simulator (Escape is undeliverable everywhere);
        // T/B were verified there with real host keys (BUILD) and run here on iPhone and iPad.
        try XCTSkipIf(XCUIDevice.isDuoSimulator, "XCUITest typeKey does not reach the app on the Duo Simulator")
        let app = launch("keyboard"); defer { app.terminate() }
        // Preserve both actual command observations even when the first endpoint fails.
        continueAfterFailure = true
        scrollToMiddleForKeyboard(app)
        expectOrder(Array(1...16),app)
        app.typeKey("t", modifierFlags: [])
        expectEndpointVisible(1,app:app)
        XCTAssertTrue(app.buttons["episode-2"].isHittable)
        app.typeKey("b", modifierFlags: [])
        expectEndpointVisible(16,app:app)
        XCTAssertTrue(app.buttons["episode-16"].isHittable)
        expectOrder(Array(1...16),app)
    }
    @MainActor private func scrollToMiddleForKeyboard(_ app: XCUIApplication) {
        let content = app.scrollViews["libraryContent"]
        for _ in 0..<8 {
            let viewport = content.frame
            let first = app.buttons["episode-1"], middle = app.buttons["episode-8"], last = app.buttons["episode-16"]
            // A row that is not built (rows exist only near the screen) is outside the viewport.
            let firstShown = first.exists && viewport.contains(first.frame), lastShown = last.exists && viewport.contains(last.frame)
            guard middle.exists, viewport.height > 0, !(firstShown && lastShown) else {
                XCTFail("Keyboard fixture must overflow the effective Queue viewport"); return
            }
            if !firstShown && !lastShown && middle.isHittable { return }
            let displacement = viewport.midY - middle.frame.midY
            guard displacement != 0 else {
                XCTFail("Ordinary scrolling could not establish an interior keyboard starting position"); return
            }
            let distance = min(abs(displacement), viewport.height * 0.4) * (displacement > 0 ? 1 : -1)
            let start = content.coordinate(withNormalizedOffset: .init(dx: 0.65, dy: 0.5))
            start.press(forDuration: 0.01, thenDragTo: start.withOffset(.init(dx: 0, dy: distance)),
                        withVelocity: .slow, thenHoldForDuration: 0)
            expectOrder(Array(1...16),app)
        }
        XCTFail("Ordinary scrolling did not leave both Queue endpoints outside the fully visible viewport")
    }
    /// The row is fully visible (within a point) inside the Queue viewport and can be tapped.
    @MainActor private func expectEndpointVisible(_ id: Int, app: XCUIApplication) {
        let predicate = NSPredicate { _, _ in MainActor.assumeIsolated {
            let row = app.buttons["episode-\(id)"]
            return row.isHittable && app.scrollViews["libraryContent"].frame.insetBy(dx: -1, dy: -1).contains(row.frame)
        } }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: app)], timeout: 6), .completed)
    }
    @MainActor func test04PersistenceFailureRestoresPreview() {
        let app=launch("failure",interrupt:"failure"); defer { app.terminate() }
        drag(3,to:1,app:app); XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout:4))
        app.alerts.buttons.firstMatch.tap(); expectOrder(Array(1...16),app)
    }
    @MainActor func test05MissingIdentityRejectsCapturedMove() {
        let app=launch("missing",interrupt:"missing"); defer { app.terminate() }
        drag(3,to:1,app:app,hold:1); expectOrder([1,2]+Array(4...16),app)
    }
    /// The fixture resizes the Queue while a drag is held; the drag must be cancelled and the
    /// saved order left unchanged.
    @MainActor func test06ResizeDuringDeliveredPointerCancels() {
        let app=launch("resize",interrupt:"resize"); defer { app.terminate() }
        drag(3,to:1,app:app,hold:1); expectOrder(Array(1...16),app)
    }
    @MainActor func test07RefreshDuringDeliveredPointerCancels() {
        let app=launch("refresh",interrupt:"refresh"); defer { app.terminate() }
        drag(3,to:1,app:app,hold:1); expectOrder(Array(1...16),app)
    }
    @MainActor func test08NavigationDuringDeliveredPointerCancels() {
        let app=launch("navigation",interrupt:"navigation"); defer { app.terminate() }
        drag(3,to:1,app:app,hold:1); app.buttons["QueueFragment"].tap(); expectOrder(Array(1...16),app)
    }
    @MainActor func test09RTLLeadingHalfAndRotation() {
        let app=launch("rtl",rtl:true); defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        drag(3,to:1,x:70,app:app,rtl:true); expectOrder(Array(1...16),app); scrollRowsIntoView([3,1],app:app,rtl:true)
        drag(3,to:1,x:36,app:app,rtl:true); expectOrder([3,1,2]+Array(4...16),app)
        if ProcessInfo.processInfo.environment["M10_QUEUE_SCENE_RESIZE_IN_MOUNTED_TESTS"] == "1" {
            // Duo's device-orientation request does not resize its scene. The paired
            // mounted OS-scene case supplies landscape geometry/hit/data/restoration.
            return
        }
        XCUIDevice.shared.orientation = .landscapeLeft; expectOrder([3,1,2]+Array(4...16),app)
        let landscape = NSPredicate { _, _ in MainActor.assumeIsolated {
            let window = app.windows.firstMatch.frame, content = app.scrollViews["libraryContent"].frame
            return window.width > window.height && content.width > content.height && window.contains(content)
        } }
        let rotated = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: app)], timeout: 6) == .completed
        if XCUIDevice.rotationResizesWindow { XCTAssertTrue(rotated) } // The Duo Simulator does not resize on rotation.
        XCUIDevice.shared.orientation = .portrait
    }
    @MainActor func test10MultitouchDoesNotMoveAndSingleTouchStillWorks() {
        let app=launch("multitouch"); defer { app.terminate() }
        app.buttons["episode-3"].pinch(withScale:0.7,velocity:-1)
        // UIKit may treat the pinch's lifted first finger as a tap on the row and open the episode;
        // what matters here is that multitouch never reorders the queue.
        if !app.buttons["episode-3"].waitForExistence(timeout: 2), app.buttons["toolbarBack"].exists { app.buttons["toolbarBack"].tap() }
        expectOrder(Array(1...16),app)
        drag(3,to:1,app:app); expectOrder([3,1,2]+Array(4...16),app)
    }
    @MainActor func test11LargeTextKeepsQueueControlsAndDragReachable() {
        let app=launch("large",large:true); defer { app.terminate() }
        XCTAssertGreaterThan(app.buttons["episode-1"].frame.height,82)
        drag(2,to:1,app:app); expectOrder([2,1]+Array(3...16),app)
        lock(app); XCTAssertTrue(app.buttons["queueLockCancel"].waitForExistence(timeout:4))
        app.buttons["queueLockCancel"].tap()
    }

}
