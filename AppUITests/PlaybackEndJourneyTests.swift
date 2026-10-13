import XCTest

/// Playback end and process-kill journeys. Fixture: `TestSupport/Servers/serve-playback-end-fixture.py` on
/// 127.0.0.1:18778 (Earlier episode 60 s; after `/advance`, Episode A 8 s, B 20 s, C 8 s, newest first).
/// Every expectation comes from Android 3.12.1, not from the Swift code; sources and reasoning:
/// - `Media3PlaybackService.startNextInQueue`/`updateDatabaseAfterPlayback`: a natural end marks the episode
///   played, removes it from the queue, adds it to the history and loads the queue item after it, playing only
///   when Continuous playback is on; with nothing after it the player closes.
/// - `PlayableUtils.saveCurrentPosition` writes the history date on every position save, which happens only
///   while playing, so a playing follower is listed above the finished episode and a paused one is not listed.
/// - `DBWriter.addQueueItem`: enqueueing (Download enqueues by default) moves an Inbox episode out of the Inbox;
///   `BottomNavigation` badges the Inbox item with the NEW count.
/// - `Media3PlaybackService.POSITION_SAVE_INTERVAL_MS` = 5000: while playing, the position is saved every 5 s.
@MainActor final class PlaybackEndJourneyTests: XCTestCase {
    private let app = XCUIApplication()
    private var run = ""
    private var mini: XCUIElement { app.buttons["miniPlayerOpen"] }
    private var miniPlay: XCUIElement { app.buttons["miniPlayerPlay"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        run = UUID().uuidString
        app.launchArguments = ["-test-library-id", run, "-test-muted-playback"]
    }

    override func tearDownWithError() throws { app.terminate() }

    /// Gap 2: A plays to its end (Continuous playback on) → B follows; relaunch; B plays to its end with
    /// Continuous playback off → C is loaded paused; relaunch; C plays to its end → nothing follows; relaunch.
    func testNaturalEndMarksPlayedLeavesQueueAndInboxAndFollowsQueueAcrossRelaunches() throws {
        app.launch()
        // The preview shows only the earlier episode; A, B and C are published before Subscribe, so the
        // refresh that follows delivers them as new episodes (Android ADD_TO_INBOX, the default).
        try subscribe(publishingNewEpisodes: true)
        tap("NewEpisodesFragment")
        tap("inboxMore"); tap("inboxRefresh")
        expectInboxBadge(3)
        expectOrder(["Episode A", "Episode B", "Episode C"], "Inbox, newest first")

        // Download enqueues; enqueueing takes an episode out of the Inbox at once.
        label(action("Episode A"), "Download"); action("Episode A").tapWhenSettled()
        expectInboxBadge(2); XCTAssertTrue(row("Episode A").waitForNonExistence(timeout: 10))
        label(action("Episode B"), "Download"); action("Episode B").tapWhenSettled()
        expectInboxBadge(1); XCTAssertTrue(row("Episode B").waitForNonExistence(timeout: 10))
        tap("QueueFragment")
        expectOrder(["Episode A", "Episode B"], "Queue in enqueue order")
        label(action("Episode A"), "Play", timeout: 30); label(action("Episode B"), "Play", timeout: 30)

        action("Episode A").tap()
        label(mini, "Episode A. Episode End Lab"); label(miniPlay, "Pause")
        // A reaches its natural end (8 s); Continuous playback is on by default, so B starts.
        label(mini, "Episode B. Episode End Lab", timeout: 40); label(miniPlay, "Pause")
        expectPositionAdvances()
        miniPlay.tap(); label(miniPlay, "Play")
        XCTAssertTrue(row("Episode A").waitForNonExistence(timeout: 10), "A finished: it leaves the queue")
        expectOrder(["Episode B"], "Queue after A's end")
        openHistory()
        expectOrder(["Episode B", "Episode A"], "History: B has played since A finished")
        expectPlayed("Episode A", true); expectPlayed("Episode B", false)
        tap("NewEpisodesFragment")
        expectOrder(["Episode C"], "Inbox after A's end"); expectInboxBadge(1)

        app.terminate(); app.launch()
        label(mini, "Episode B. Episode End Lab"); label(miniPlay, "Play")
        expectInboxBadge(1)
        tap("QueueFragment"); expectOrder(["Episode B"], "Queue after relaunch")
        XCTAssertFalse(row("Episode A").exists)
        openHistory(); expectOrder(["Episode B", "Episode A"], "History after relaunch")
        expectPlayed("Episode A", true)

        // C enters the queue behind B and the Inbox empties; Continuous playback off.
        tap("NewEpisodesFragment")
        expectOrder(["Episode C"], "Inbox before C is downloaded")
        label(action("Episode C"), "Download"); action("Episode C").tapWhenSettled()
        expectInboxBadge(0)
        XCTAssertTrue(app.staticTexts["inboxEmptyTitle"].waitForExistence(timeout: 10))
        setContinuousPlayback(false)
        tap("QueueFragment")
        expectOrder(["Episode B", "Episode C"], "Queue with C behind B")
        label(action("Episode C"), "Play", timeout: 30)
        miniPlay.tap(); label(miniPlay, "Pause")
        // B reaches its natural end; C is loaded but stays paused at its start.
        label(mini, "Episode C. Episode End Lab", timeout: 40); label(miniPlay, "Play")
        expectPausedAtStart()
        XCTAssertTrue(row("Episode B").waitForNonExistence(timeout: 10), "B finished: it leaves the queue")
        expectOrder(["Episode C"], "Queue after B's end")
        openHistory()
        expectOrder(["Episode B", "Episode A"], "History: C was loaded but never played")
        XCTAssertFalse(row("Episode C").exists, "A paused follower is not in the history")
        expectPlayed("Episode B", true)

        app.terminate(); app.launch()
        label(mini, "Episode C. Episode End Lab"); label(miniPlay, "Play")
        tap("QueueFragment"); expectOrder(["Episode C"], "Queue after second relaunch")
        openSettingsPlayback()
        let follow = app.buttons["prefFollowQueue"]
        XCTAssertTrue(follow.waitForExistence(timeout: 5)); XCTAssertEqual(follow.value as? String, "Off")
        leaveSettings()

        // C reaches its natural end with nothing after it: the player closes and the queue empties.
        miniPlay.tap(); label(miniPlay, "Pause")
        XCTAssertTrue(mini.waitForNonExistence(timeout: 40), "Nothing follows the last queue episode")
        tap("QueueFragment")
        XCTAssertTrue(app.staticTexts["No queued episodes"].waitForExistence(timeout: 10))
        XCTAssertFalse(row("Episode C").exists)
        openHistory()
        expectOrder(["Episode C", "Episode B", "Episode A"], "History after the queue ran out")
        for title in ["Episode A", "Episode B", "Episode C"] { expectPlayed(title, true) }

        app.terminate(); app.launch()
        openHistory()
        expectOrder(["Episode C", "Episode B", "Episode A"], "History after the last relaunch")
        for title in ["Episode A", "Episode B", "Episode C"] { expectPlayed(title, true) }
        XCTAssertFalse(mini.exists, "No episode is selected after the queue ran out")
        tap("QueueFragment")
        XCTAssertTrue(app.staticTexts["No queued episodes"].waitForExistence(timeout: 10))
        expectInboxBadge(0)
    }

    /// Gap 7: the app is terminated while an episode is playing (as when it is swiped away). On relaunch the
    /// episode is still selected, paused, at most about 5 s before what was heard, and Play continues from there.
    func testTerminatingWhilePlayingKeepsPositionWithinFiveSeconds() throws {
        app.launch()
        try subscribe()
        let episode = action("Earlier episode")
        label(episode, "Download"); episode.tap()
        label(episode, "Play", timeout: 30); episode.tap()
        label(mini, "Earlier episode. Episode End Lab"); label(miniPlay, "Pause")
        mini.tap()
        let position = app.staticTexts["playerPosition"]
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        // Past two 5-second saves, then terminate the playing process as an app-switcher swipe does.
        wait(for: position, seconds: { $0 >= 13 }, timeout: 30)
        let heard = try XCTUnwrap(seconds(position.label))
        app.terminate()

        app.launch()
        label(mini, "Earlier episode. Episode End Lab"); label(miniPlay, "Play")
        mini.tap()
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        let restored = try XCTUnwrap(seconds(position.label))
        // Android saves every 5 s from a 1-second observer, so up to about 6 s of what was heard is replayed;
        // the saved position is never ahead of what was heard (one display second of slack).
        XCTAssertTrue((heard - 6)...(heard + 1) ~= restored, "Heard \(heard) s before termination, restored \(restored) s")
        XCTAssertEqual(app.buttons["playerPlay"].label, "Play")
        app.buttons["playerPlay"].tap(); label(app.buttons["playerPlay"], "Pause")
        // Playback continues from the restored position, not from the start.
        wait(for: position, seconds: { $0 > restored }, timeout: 15)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(seconds(position.label)), restored)
        app.buttons["playerPlay"].tap(); label(app.buttons["playerPlay"], "Play")
    }

    // MARK: - Steps

    private func subscribe(publishingNewEpisodes: Bool = false) throws {
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 15))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap()
        address.typeTextSettled("http://127.0.0.1:18778/feed.xml?run=\(run)")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15))
        XCTAssertTrue(row("Earlier episode").waitForExistence(timeout: 15))
        if publishingNewEpisodes {
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:18778/advance?run=\(run)&stage=1"))
            XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), "1")
        }
        app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(row("Earlier episode").waitForExistence(timeout: 15))
    }

    private func setContinuousPlayback(_ on: Bool) {
        openSettingsPlayback()
        let follow = app.buttons["prefFollowQueue"]
        XCTAssertTrue(follow.waitForExistence(timeout: 5))
        for _ in 0..<4 where !follow.isHittable { app.swipeUp() }
        XCTAssertEqual(follow.label, "Continuous playback")
        XCTAssertEqual(follow.value as? String, on ? "Off" : "On")
        follow.tap()
        label(follow, on ? "On" : "Off", attribute: "value")
        leaveSettings()
    }

    private func openSettingsPlayback() {
        tap("navigationMore"); app.buttons["Settings"].tap()
        tap("prefScreenPlayback")
    }

    private func leaveSettings() { tap("toolbarBack"); tap("toolbarBack") }

    private func openHistory() {
        if app.buttons["PlaybackHistoryFragment"].exists { app.buttons["PlaybackHistoryFragment"].tap(); return }
        tap("navigationMore")
        let item = app.otherElements["morePopup"].buttons["Playback history"]
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
    }

    /// The expanded player shows the position moving forward, then collapses again.
    private func expectPositionAdvances() {
        mini.tap()
        let position = app.staticTexts["playerPosition"]
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        let start = position.label
        label(position, start, attribute: "label", equals: false, timeout: 10)
        tap("playerCollapse")
    }

    /// A paused follower: Play is offered, the position stays at the start and does not move.
    private func expectPausedAtStart() {
        mini.tap()
        let position = app.staticTexts["playerPosition"]
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["playerPlay"].label, "Play")
        XCTAssertEqual(position.label, "00:00:00")
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "00:00:00"), object: position)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 3), .timedOut, "The follower must not start playing")
        tap("playerCollapse")
    }

    // MARK: - Queries

    private func row(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'episode-' AND label == %@", title)).firstMatch
    }

    private func action(_ title: String) -> XCUIElement {
        let row = row(title)
        XCTAssertTrue(row.waitForExistence(timeout: 15), "\(title) row\n\(app.debugDescription)")
        return app.buttons["episode-action-" + row.identifier.dropFirst("episode-".count)]
    }

    private func expectPlayed(_ title: String, _ played: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let row = row(title)
        XCTAssertTrue(row.waitForExistence(timeout: 10), title, file: file, line: line)
        let value = row.value as? String ?? ""
        XCTAssertEqual(value.hasPrefix("Played"), played, "\(title): \(value)", file: file, line: line)
    }

    /// Rows are listed in this order, top to bottom, and no other episode row of this feed is listed.
    private func expectOrder(_ titles: [String], _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let all = ["Episode A", "Episode B", "Episode C", "Earlier episode"]
        let matched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in MainActor.assumeIsolated {
            let rows = titles.map(self.row)
            guard rows.allSatisfy(\.exists), !all.filter({ !titles.contains($0) }).contains(where: { self.row($0).exists }) else { return false }
            let tops = rows.map(\.frame.minY)
            return zip(tops, tops.dropFirst()).allSatisfy { $0 < $1 }
        } }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [matched], timeout: 15), .completed, "\(message): expected \(titles)",
                       file: file, line: line)
    }

    /// The Inbox item of the bottom navigation reads its badge as Material does ("3 new notifications").
    private func expectInboxBadge(_ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let inbox = app.buttons["NewEpisodesFragment"]
        let expected = count == 0 ? "" : count == 1 ? "1 new notification" : "\(count) new notifications"
        let matched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in MainActor.assumeIsolated {
            inbox.exists && (inbox.value as? String ?? "") == expected
        } }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [matched], timeout: 20), .completed,
                       "Inbox badge \(inbox.value as? String ?? "none"), expected \(expected)", file: file, line: line)
    }

    private func tap(_ id: String) {
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 10), id); button.tap()
    }

    private func label(_ element: XCUIElement, _ expected: String, attribute: String = "label", equals: Bool = true,
                       timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "\(attribute) \(equals ? "==" : "!=") %@", expected)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout),
                       .completed, "\(element) \(attribute) \(equals ? "==" : "!=") \(expected)", file: file, line: line)
    }

    private func seconds(_ label: String) -> Int? {
        let fields = label.split(separator: ":").compactMap { Int($0) }
        return fields.count == 3 ? fields.reduce(0) { $0 * 60 + $1 } : nil
    }

    private func wait(for position: XCUIElement, seconds condition: @escaping (Int) -> Bool, timeout: TimeInterval,
                      file: StaticString = #filePath, line: UInt = #line) {
        let reached = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in MainActor.assumeIsolated {
            self.seconds(position.label).map(condition) == true
        } }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reached], timeout: timeout), .completed, "Position \(position.label)",
                       file: file, line: line)
    }
}
