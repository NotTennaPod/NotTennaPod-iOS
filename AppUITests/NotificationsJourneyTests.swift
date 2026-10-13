import Synchronization
import XCTest

/// Notifications journey: a download that fails while the app is in the background produces
/// "Episode download failed" / "Tap to view details."; tapping it opens the Download log with that entry,
/// warm and cold; with "Download failed" off there is no notification but the entry is still logged; a
/// failure while the app is in front shows "Download of "…" failed." with Details, which opens the log.
///
/// Notification permission is a system setting the tests may neither depend on nor change, so the app runs
/// with `-test-notification-recorder`: what it hands to the notification center is written to its test
/// library, and a tap on that notification is simulated by writing its identifier there before the app is
/// launched (cold) or brought back (warm). Delivery itself is checked on real hardware.
final class NotificationsJourneyTests: XCTestCase {
    /// Feed with one episode. The first two episode requests are held until the test answers them (so they
    /// fail while the app is in the background); later ones fail at once with 404.
    private final class EpisodeServer: Sendable {
        let server: LoopbackHTTPServer
        let port: Int
        private init(server: LoopbackHTTPServer, port: Int) { self.server = server; self.port = port }
        static func start() async throws -> EpisodeServer {
            let port = Mutex(0), count = Mutex(0)
            let server = try await LoopbackHTTPServer.start { request in
                if request.path.hasPrefix("/feed.xml") {
                    let feed = """
                    <rss version="2.0"><channel><title>Failing podcast</title><link>https://example.test</link>
                    <item><guid>m30-failing</guid><title>Failing episode</title><pubDate>Mon, 28 Sep 2026 08:00:00 GMT</pubDate>
                    <enclosure url="http://127.0.0.1:\(port.withLock { $0 })/episode.mp3" type="audio/mpeg" length="1000000"/></item>
                    </channel></rss>
                    """
                    return .init(status: 200, headers: ["Content-Type": "application/rss+xml"], body: Data(feed.utf8))
                }
                guard request.path == "/episode.mp3", count.withLock({ $0 += 1; return $0 }) > 2 else {
                    return request.path == "/episode.mp3" ? nil : .init(status: 404, headers: [:], body: Data())
                }
                return .init(status: 404, headers: ["Content-Type": "text/plain"], body: Data("gone".utf8))
            }
            port.withLock { $0 = server.url.port! }
            return EpisodeServer(server: server, port: server.url.port!)
        }
        var episodeRequests: Int { server.requests.filter { $0.path == "/episode.mp3" }.count }
    }

    /// The app's test library, found directly in the Simulator's app containers (not through the app).
    private func libraryFolder(_ library: String) -> URL? {
        let applications = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        for container in (try? FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil)) ?? [] {
            let folder = container.appendingPathComponent("Library/Application Support/UITests-\(library)")
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("library.sqlite").path) { return folder }
        }
        return nil
    }
    private func entries(_ name: String, library: String) -> [[String: Any]] {
        guard let file = libraryFolder(library)?.appendingPathComponent(name), let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }
    private func simulateTap(library: String) throws {
        let folder = try XCTUnwrap(libraryFolder(library), "test library")
        try Data("download-error".utf8).write(to: folder.appendingPathComponent("notification-response"))
    }
    @MainActor private func waitForOutcomes(_ count: Int, library: String, timeout: TimeInterval = 120) async throws -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(timeout)
        while entries("download-error-outcomes.json", library: library).count < count && Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        let outcomes = entries("download-error-outcomes.json", library: library)
        XCTAssertGreaterThanOrEqual(outcomes.count, count, "delivery decisions")
        return outcomes
    }

    /// Evidence screenshots, kept in the result bundle.
    @MainActor private func attachScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func launch(_ app: XCUIApplication, library: String) {
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback", "-test-notification-recorder"]
        app.launch()
    }
    @MainActor private func logTitles(_ app: XCUIApplication, expecting count: Int) -> [String] {
        XCTAssertTrue(app.otherElements["downloadLogSheet"].waitForExistence(timeout: 15), "Download log open")
        let rows = app.cells.matching(identifier: "downloadLogRow")
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", count), object: rows)], timeout: 10)
        return app.staticTexts.matching(identifier: "downloadLogTitle").allElementsBoundByIndex.map(\.label)
    }
    @MainActor private func closeLog(_ app: XCUIApplication) {
        let sheet = app.otherElements["downloadLogSheet"]
        let top = sheet.frame.minY
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: sheet.frame.midX, dy: max(1, top - 20))).tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }
    @MainActor private func episodeAction(_ app: XCUIApplication) -> XCUIElement {
        let row = app.buttons.matching(NSPredicate(format: "label == %@", "Failing episode")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        return app.buttons["episode-action-\(row.identifier.dropFirst("episode-".count))"]
    }
    /// Starts the download and leaves the app while the server holds the request, then fails it.
    @MainActor private func failInBackground(_ app: XCUIApplication, _ episodes: EpisodeServer, request: Int) async throws {
        let action = episodeAction(app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Download"),
                                                                      object: action)], timeout: 10), .completed)
        action.tap()
        let requested = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in episodes.episodeRequests >= request }, object: nil)
        await fulfillment(of: [requested], timeout: 60)
        XCUIDevice.shared.leaveApp()
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.state == .runningBackgroundSuspended)
        try episodes.server.respond(toPath: "/episode.mp3", with: .init(status: 404, headers: ["Content-Type": "text/plain"],
                                                                         body: Data("gone".utf8)))
    }

    @MainActor func testDownloadFailureNotificationSwitchAndMessage() async throws {
        continueAfterFailure = false
        let episodes = try await EpisodeServer.start()
        defer { episodes.server.stop() }
        let app = XCUIApplication(), library = UUID().uuidString
        launch(app, library: library)
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap()
        address.typeTextSettled("http://127.0.0.1:\(episodes.port)/feed.xml")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 10)); app.buttons["subscribeFeed"].tap()

        // 1. The download fails while the app is in the background: the notification is handed over.
        try await failInBackground(app, episodes, request: 1)
        var outcomes = try await waitForOutcomes(1, library: library)
        XCTAssertEqual(outcomes.last?["outcome"] as? String, "notification")
        XCTAssertEqual(outcomes.last?["retrying"] as? Bool, false, "404 ends the download at once")
        let requests = entries("notification-requests.json", library: library)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?["title"] as? String, "Episode download failed")
        XCTAssertEqual(requests.first?["body"] as? String, "Tap to view details.")
        XCTAssertEqual(requests.first?["identifier"] as? String, "download-error")

        // 2. Tap it (warm): the app comes back on the same page with the Download log showing the entry.
        try simulateTap(library: library)
        app.activate()
        XCTAssertEqual(logTitles(app, expecting: 1), ["Failing episode"])
        attachScreen("M30 warm tap: Download log over the podcast page")
        closeLog(app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "Failing episode")).firstMatch.exists,
                      "the podcast page under the log is kept")

        // 3. Tap it cold (iOS ended the app after step 1 left it): the app reopens where it was with the log over it, once.
        app.terminate()
        try simulateTap(library: library)
        launch(app, library: library)
        XCTAssertEqual(logTitles(app, expecting: 1), ["Failing episode"])
        attachScreen("M30 cold tap: Download log over the reopened page")
        XCTAssertEqual(app.otherElements.matching(identifier: "downloadLogSheet").count, 1)
        closeLog(app)

        // 4. Settings → Notifications → "Download failed" off, then fail again in the background.
        app.buttons["navigationMore"].tap(); app.buttons["Settings"].tap()
        let row = app.buttons["notifications"]
        for _ in 0..<5 where !row.isHittable { app.scrollViews["libraryContent"].swipeUp() }
        row.tap()
        let downloadSwitch = app.buttons["prefShowDownloadReport"]
        XCTAssertTrue(downloadSwitch.waitForExistence(timeout: 5))
        XCTAssertEqual(downloadSwitch.value as? String, "On")
        attachScreen("M30 Settings → Notifications")
        let syncSwitch = app.buttons["pref_gpodnet_notifications"]
        XCTAssertFalse(syncSwitch.isEnabled, "Synchronization failed is disabled without an account")
        downloadSwitch.tapWhenSettled()
        XCTAssertEqual(downloadSwitch.value as? String, "Off")
        // Saved data, read directly from the test library.
        let saved = try XCTUnwrap(libraryFolder(library)?.appendingPathComponent("notification-preferences.json"))
        let settings = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: saved)) as? [String: Any])
        XCTAssertEqual(settings["prefShowDownloadReport"] as? Bool, false)
        app.buttons["toolbarBack"].tap(); app.buttons["toolbarBack"].tap()
        app.navigation("Subscriptions").tap()
        let feed = app.buttons.matching(NSPredicate(format: "label == %@", "Failing podcast")).firstMatch
        XCTAssertTrue(feed.waitForExistence(timeout: 10)); feed.tap()
        try await failInBackground(app, episodes, request: 2)
        outcomes = try await waitForOutcomes(2, library: library)
        XCTAssertEqual(outcomes.last?["outcome"] as? String, "nothing", "no notification with Download failed off")
        XCTAssertEqual(entries("notification-requests.json", library: library).count, 1)
        app.activate()
        // Right after activation the button can report no hit point yet (iPhone); tap once it has settled.
        app.buttons["navigationMore"].tapWhenSettled(); app.otherElements["morePopup"].buttons["Downloads"].tap()
        XCTAssertTrue(app.buttons["openDownloadLog"].waitForExistence(timeout: 5)); app.buttons["openDownloadLog"].tap()
        XCTAssertEqual(logTitles(app, expecting: 2), ["Failing episode", "Failing episode"], "the failure is still logged")
        closeLog(app)

        // 5. A failure with the app in front: the message, whose Details opens the log.
        app.navigation("Subscriptions").tap()
        XCTAssertTrue(feed.waitForExistence(timeout: 10)); feed.tap()
        let action = episodeAction(app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Download"),
                                                                      object: action)], timeout: 10), .completed)
        action.tap()
        let message = app.staticTexts["Download of \"Failing episode\" failed."]
        XCTAssertTrue(message.waitForExistence(timeout: 20))
        attachScreen("M30 foreground failure message")
        // The message stays for Android's long duration; Details is tapped while it is shown.
        app.buttons["downloadErrorDetails"].tap()
        XCTAssertEqual(logTitles(app, expecting: 3), ["Failing episode", "Failing episode", "Failing episode"])
        outcomes = try await waitForOutcomes(3, library: library)
        XCTAssertEqual(outcomes.last?["outcome"] as? String, "message")
        XCTAssertEqual(outcomes.last?["message"] as? String, "Download of \"Failing episode\" failed.", "shown once, without a retry promise")
        XCTAssertEqual(outcomes.count, 3)
        XCTAssertEqual(entries("notification-requests.json", library: library).count, 1)
    }
}
