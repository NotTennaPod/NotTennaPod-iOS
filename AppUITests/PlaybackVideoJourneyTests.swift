import XCTest

/// Runs against the actual application route and a separately served, independently
/// validated numbered-frame/two-track fixture. No replacement engine or seeded player.
final class PlaybackVideoJourneyTests: XCTestCase {
    /// When this test last tapped the video to show its controls (taken before the touch is sent).
    private var revealedAt: ContinuousClock.Instant?
    /// The journey lengthens Android's 2.5 s control auto-hide (DEBUG `-test-video-controls-autohide-ms`): each
    /// XCUITest tap costs up to about 3 s on a loaded Simulator (Duo), so taps on controls shown for 2.5 s
    /// landed on the bare video. The controls still hide on their own here; PlaybackVideoSurfaceTests checks 2.5 s.
    private let controlsHideDelay: TimeInterval = 6
    @MainActor func testDownloadedVideoControlsAudioOnlyAndRelaunch() async throws { try await journey(download: true) }
    @MainActor func testProgressiveVideoControlsAndResize() async throws { try await journey(download: false) }

    @MainActor private func journey(download: Bool) async throws {
        continueAfterFailure = false
        let base = ProcessInfo.processInfo.environment["PLAYBACK_VIDEO_FIXTURE_URL"] ?? "http://127.0.0.1:59421"
        let app = XCUIApplication(), identity = UUID().uuidString
        app.launchArguments = ["-test-library-id", identity, "-test-muted-playback",
                               "-test-video-controls-autohide-ms", String(Int(controlsHideDelay * 1_000))]
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeTextSettled(base + "/feed.xml?run=" + identity)
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 10))
        if download {
            let action = app.buttons["episode-action-1"]
            XCTAssertEqual(action.label, "Download"); action.tap()
            try await label(action, "Play", timeout: 25); action.tap()
        } else {
            app.buttons["episode-1"].tap()
            let action = app.buttons["episodePrimaryAction"]
            XCTAssertTrue(action.waitForExistence(timeout: 5)); XCTAssertEqual(action.label, "Stream"); action.tap()
        }
        XCTAssertTrue(app.otherElements["videoPlayer"].waitForExistence(timeout: 15))
        if ProcessInfo.processInfo.environment["PLAYBACK_VIDEO_EXPECT_LANDSCAPE"] == "1" {
            let deadline = ContinuousClock.now + .seconds(5)
            while app.frame.width <= app.frame.height && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertGreaterThan(app.frame.width, app.frame.height)
        }
        showControls(app)
        try await visibleVideoLabel(app, "videoPlay", "Pause")
        tapControl(app, "videoPlay"); try await visibleVideoLabel(app, "videoPlay", "Play")
        let seek = app.descendants(matching: .any)["videoSeek"]
        whileControlsShow(app) {
            XCTAssertTrue(seek.isHittable)
            seek.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        try await visibleVideoLabel(app, "videoPosition", "00:00:48")
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == false"), object: app.buttons["videoMore"])], timeout: controlsHideDelay + 3)
        tapControl(app, "videoFavorite"); try await visibleVideoLabel(app, "videoFavorite", "Remove from favorites")
        menu(app, action: "audio")
        let english = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "videoAudioTrack-", "eng")).firstMatch
        let german = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "videoAudioTrack-", "deu")).firstMatch
        XCTAssertTrue(english.waitForExistence(timeout: 5)); XCTAssertTrue(german.exists)
        german.tap()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: german)], timeout: 10)
        app.buttons["videoAudioClose"].tap()
        menu(app, action: "speed")
        let silence = app.buttons["speedSkipSilence"]
        XCTAssertTrue(silence.waitForExistence(timeout: 5)); XCTAssertEqual(silence.value as? String, "Off"); silence.tap()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "On"), object: silence)], timeout: 5)
        app.buttons["speedPreset-2"].tap(); XCTAssertTrue(silence.waitForNonExistence(timeout: 5))
        whileControlsShow(app) { seek.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).tap() }
        try await visibleVideoLabel(app, "videoPosition", "00:00:00")
        tapControl(app, "videoPlay"); try await visibleVideoLabel(app, "videoPlay", "Pause")
        // Start at zero so resume rewind cannot masquerade as progress. Reach
        // six source seconds, crossing the independently authored2–4s silence.
        let progressDeadline = ContinuousClock.now + .seconds(15)
        var observedProgress = ""
        while ContinuousClock.now < progressDeadline {
            showControls(app) // Autohide deliberately removes these labels from AX.
            observedProgress = try snapshotLabel(app, identifier: "videoPosition") ?? ""
            if observedProgress >= "00:00:06" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThanOrEqual(observedProgress, "00:00:06")
        tapControl(app, "videoPlay"); try await visibleVideoLabel(app, "videoPlay", "Play")
        var paused = ""
        whileControlsShow(app) { paused = app.staticTexts["videoPosition"].label }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == false"), object: app.buttons["videoMore"])], timeout: controlsHideDelay + 3)
        XCUIDevice.shared.orientation = .landscapeLeft
        showControls(app); try await visibleVideoLabel(app, "videoPosition", paused)
        whileControlsShow(app) { XCTAssertTrue(app.buttons["videoMore"].isHittable && app.buttons["videoBack"].isHittable) }
        XCUIDevice.shared.orientation = .portrait
        menu(app, action: "audioOnly")
        XCTAssertTrue(app.otherElements["videoPlayer"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["miniPlayerOpen"].exists)
        try await label(app.buttons["miniPlayerPlay"], "Play")
        app.buttons["miniPlayerOpen"].tap()
        XCTAssertTrue(app.otherElements["videoPlayer"].waitForExistence(timeout: 5)); showControls(app)
        try await visibleVideoLabel(app, "videoPosition", paused)
        menu(app, action: "speed")
        XCTAssertTrue(silence.waitForExistence(timeout: 5)); XCTAssertEqual(silence.value as? String, "On")
        XCTAssertEqual(app.buttons["speedAddPreset"].value as? String, "1.50")
        app.buttons["speedPreset-2"].tap()
        XCTAssertTrue(silence.waitForNonExistence(timeout: 5))
        if download {
            whileControlsShow(app) { seek.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            try await visibleVideoLabel(app, "videoPosition", "00:00:48")
            // A paused seek alone has no source save boundary. Commit an actual
            // play→pause, then read the independently stored source timestamp.
            let saveBoundary = Int64(Date().timeIntervalSince1970 * 1_000)
            tapControl(app, "videoPlay"); try await visibleVideoLabel(app, "videoPlay", "Pause")
            tapControl(app, "videoPlay"); try await visibleVideoLabel(app, "videoPlay", "Play")
            let saved = try await storedCheckpoint(base: base, identity: identity, after: saveBoundary)
            try await visibleVideoLabel(app, "videoPosition", displayTime(saved.position))
            app.terminate(); app.launch()
            XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 10)); app.buttons["miniPlayerOpen"].tap()
            XCTAssertTrue(app.otherElements["videoPlayer"].waitForExistence(timeout: 15))
            showControls(app); try await visibleVideoLabel(app, "videoPlay", "Play")
            // This run must remain in the source's >0…60s pause interval;
            // expected display derives from exact committed milliseconds.
            let elapsed = Int64(Date().timeIntervalSince1970 * 1_000) - saved.lastPlayed
            XCTAssertGreaterThan(elapsed, 0); XCTAssertLessThanOrEqual(elapsed, 60_000)
            try await visibleVideoLabel(app, "videoPosition", displayTime(max(0, saved.position - 800)))
            try await visibleVideoLabel(app, "videoFavorite", "Remove from favorites")
        }
        if !download {
            try await videoMenus(app, base: base)
            if ProcessInfo.processInfo.environment["PLAYBACK_VIDEO_PIP_REQUIRED"] == "1" {
                try await pictureInPicture(app, base: base, identity: identity)
            }
        }
        XCTAssertFalse(app.staticTexts["videoError"].exists)
    }
    @MainActor private func videoMenus(_ app: XCUIApplication, base: String) async throws {
        tapControl(app, "videoShare")
        let share = app.otherElements["episodeShareSheet"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["episodeShareMediaAddress"].value as? String, base + "/journey.mp4")
        dismissPanel(share, app: app)
        tapControl(app, "videoMore")
        let order = ["audio", "speed", "openPodcast", "visitWebsite", "audioOnly", "chapters"]
        for id in order { XCTAssertTrue(app.buttons["videoMenu-" + id].waitForExistence(timeout: 5)) }
        for pair in zip(order, order.dropFirst()) {
            XCTAssertLessThan(app.buttons["videoMenu-" + pair.0].frame.midY, app.buttons["videoMenu-" + pair.1].frame.midY)
        }
        app.buttons["videoMenu-chapters"].tap()
        XCTAssertTrue(app.buttons["chapterPlay-1"].waitForExistence(timeout: 10))
        app.buttons["chapterPlay-1"].tap(); app.buttons["chaptersClose"].tap()
        try await visibleVideoLabel(app, "videoPlay", "Pause")
        tapControl(app, "videoSleepTimer")
        XCTAssertTrue(app.textFields["sleepTimerInput"].waitForExistence(timeout: 5))
        app.buttons["sleepTimerSet"].tap()
        XCTAssertTrue(app.staticTexts["sleepTimerRemaining"].waitForExistence(timeout: 5))
        app.buttons["sleepTimerDisable"].tap()
        XCTAssertTrue(app.textFields["sleepTimerInput"].waitForExistence(timeout: 5))
        dismissPanel(app.otherElements["sleepTimerSheet"], app: app)
        tapControl(app, "videoPlay")
        try await visibleVideoLabel(app, "videoPlay", "Play")
    }
    @MainActor private func dismissPanel(_ panel: XCUIElement, app: XCUIApplication) {
        let frame = panel.frame, bounds = app.frame
        let gaps = [(frame.minY - bounds.minY, CGPoint(x: frame.midX, y: (frame.minY + bounds.minY) / 2)),
                    (frame.minX - bounds.minX, CGPoint(x: (frame.minX + bounds.minX) / 2, y: frame.midY)),
                    (bounds.maxX - frame.maxX, CGPoint(x: (bounds.maxX + frame.maxX) / 2, y: frame.midY))]
        let outside = gaps.max { $0.0 < $1.0 }!
        XCTAssertGreaterThan(outside.0, 0)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: outside.1.x - bounds.minX, dy: outside.1.y - bounds.minY)).tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
    }
    @MainActor private func pictureInPicture(_ app: XCUIApplication, base: String, identity: String) async throws {
        tapControl(app, "videoPlay")
        try await visibleVideoLabel(app, "videoPlay", "Pause")
        XCUIDevice.shared.leaveApp()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let restore = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Restore full")).firstMatch
        let appeared = restore.waitForExistence(timeout: 10)
        XCTAssertTrue(appeared, "Supported iPad must show the actual system Picture in Picture window")
        let boundary = Int64(Date().timeIntervalSince1970 * 1_000)
        springboard.buttons["Pause"].tap()
        XCTAssertTrue(springboard.buttons["Play"].waitForExistence(timeout: 5))
        let saved = try await storedCheckpoint(base: base, identity: identity, after: boundary)
        restore.tap(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.otherElements["videoPlayer"].waitForExistence(timeout: 10))
        try await visibleVideoLabel(app, "videoPlay", "Play")
        try await visibleVideoLabel(app, "videoPosition", displayTime(saved.position))
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == false"), object: app.buttons["videoMore"])], timeout: controlsHideDelay + 3)
    }
    private struct StoredPosition { let position: Int64; let lastPlayed: Int64 }
    @MainActor private func storedCheckpoint(base: String, identity: String, after boundary: Int64) async throws -> StoredPosition {
        let url = try XCTUnwrap(URL(string: base + "/checkpoint?library=" + identity))
        let deadline = ContinuousClock.now + .seconds(10)
        repeat {
            let (data, response) = try await URLSession.shared.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let episode = try XCTUnwrap(root["episode"] as? [String: Any])
            let state = try XCTUnwrap(episode["userState"] as? [String: Any])
            let position = try XCTUnwrap(state["positionMilliseconds"] as? NSNumber).int64Value
            let lastPlayed = try XCTUnwrap(state["lastPlayedTimeMilliseconds"] as? NSNumber).int64Value
            if lastPlayed >= boundary {
                XCTAssertEqual(state["isFavorite"] as? Bool, true)
                return StoredPosition(position: position, lastPlayed: lastPlayed)
            }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        XCTFail("The actual play→pause did not commit a newer playback record")
        throw NSError(domain: "VideoJourney", code: 1)
    }
    private func displayTime(_ milliseconds: Int64) -> String {
        let seconds = milliseconds / 1_000
        return String(format: "%02lld:%02lld:%02lld", seconds / 3_600, seconds / 60 % 60, seconds % 60)
    }
    @MainActor private func snapshotLabel(_ app: XCUIApplication, identifier: String) throws -> String? {
        // One immutable AX observation: autohide may remove the live element
        // between independent exists/label queries, but cannot alter this tree.
        func find(_ node: any XCUIElementSnapshot) -> String? {
            if node.identifier == identifier { return node.label }
            for child in node.children { if let value = find(child) { return value } }
            return nil
        }
        return find(try app.snapshot())
    }
    @MainActor private func visibleVideoLabel(_ app: XCUIApplication, _ identifier: String, _ value: String, timeout: TimeInterval = 10) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        var observed: String?
        repeat {
            showControls(app)
            observed = try snapshotLabel(app, identifier: identifier)
            if observed == value { return }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        XCTAssertEqual(observed, value)
    }
    @MainActor private func controlsVisible(_ app: XCUIApplication) -> Bool {
        let more = app.buttons["videoMore"]
        return more.exists && more.isHittable
    }
    /// Makes the controls visible for reading (labels come from one snapshot, so a later autohide is harmless).
    @MainActor private func showControls(_ app: XCUIApplication) {
        if !controlsVisible(app) { revealControls(app) }
    }
    @MainActor private func revealControls(_ app: XCUIApplication) {
        revealedAt = .now
        app.otherElements["videoPlayer"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
        // Poll: XCTWaiter checks about once a second, which can use up most of the visible period.
        XCTAssertTrue(waitUntil(timeout: 5) { controlsVisible(app) }, "Tapping the video did not show its controls")
    }
    /// Runs `body` (taps or hit checks on controls) while the controls are sure to stay on screen. They hide
    /// `controlsHideDelay` after appearing (Android's 2.5 s, lengthened for the journey), so controls that were
    /// already showing can vanish between XCTest's lookup and its touch, which then lands on the video and
    /// toggles the controls instead (on the iPad, Sleep timer and More taps were lost this way). Unless this
    /// test revealed them recently enough to leave 3.5 s for the tap, let them hide, or confirm they stay (a menu
    /// or dialog stops the autohide, as on Android), and reveal them afresh.
    @MainActor private func whileControlsShow(_ app: XCUIApplication, _ body: () -> Void) {
        let fresh = revealedAt.map { ContinuousClock.now - $0 < .seconds(controlsHideDelay - 3.5) } ?? false
        if !(fresh && controlsVisible(app)) {
            let hidden = waitUntil(timeout: controlsHideDelay + 1) { !controlsVisible(app) }
            if hidden { revealControls(app) }
        }
        body()
    }
    @MainActor private func tapControl(_ app: XCUIApplication, _ identifier: String) {
        whileControlsShow(app) { app.buttons[identifier].tap() }
    }
    @MainActor private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return true
    }
    @MainActor private func menu(_ app: XCUIApplication, action: String) {
        tapControl(app, "videoMore")
        let item = app.buttons["videoMenu-" + action]
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
    }
    @MainActor private func label(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 10) async throws {
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", value), object: element)], timeout: timeout)
    }
}
