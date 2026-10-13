import CryptoKit
import Synchronization
import XCTest

/// Background work journeys: a download that keeps going after the app leaves and is closed, a
/// pending synchronization that reaches the server after the app goes to the background, and the
/// Download log keeping 7 days of entries on a 3-day maintenance cadence.
final class BackgroundWorkJourneyTests: XCTestCase {
    static let media = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ ($0 >> 11)) })
    static let tag = "\"m29-journey-v1\""

    @MainActor private func launch(_ app: XCUIApplication, library: String, _ extra: [String] = []) {
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback"] + extra
        app.launch()
    }

    @MainActor private func openLog(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.otherElements["morePopup"].buttons["Downloads"].tap()
        XCTAssertTrue(app.buttons["openDownloadLog"].waitForExistence(timeout: 5)); app.buttons["openDownloadLog"].tap()
        XCTAssertTrue(app.buttons["downloadLogClear"].waitForExistence(timeout: 5))
    }

    @MainActor private func logTitles(_ app: XCUIApplication, expecting count: Int) -> [String] {
        let rows = app.cells.matching(identifier: "downloadLogRow")
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", count), object: rows)], timeout: 10)
        return app.staticTexts.matching(identifier: "downloadLogTitle").allElementsBoundByIndex.map(\.label)
    }

    /// Android `DatabaseMaintenanceWorker`: every 3 days, delete Download log entries older than 7 days.
    /// The clock offset moves only the app's maintenance clock; the seeded entries keep their dates.
    @MainActor func testDownloadLogKeepsSevenDaysOnThreeDayMaintenanceCadence() {
        continueAfterFailure = false
        let app = XCUIApplication(), library = UUID().uuidString
        launch(app, library: library, ["-test-m29-download-log"])
        openLog(app)
        // First launch: never run, so due. 7 d + 1 min and 8 d are gone; 6 d 23 h and 1 h stay.
        XCTAssertEqual(logTitles(app, expecting: 2), ["Recent episode", "Kept podcast"])
        // One day later the kept entry is 7 d 23 h old, but maintenance ran less than 3 days ago.
        app.terminate()
        launch(app, library: library, ["-test-maintenance-clock-offset-hours", "24"])
        openLog(app)
        XCTAssertEqual(logTitles(app, expecting: 2), ["Recent episode", "Kept podcast"])
        // Three days after the first run it is due again: the 9 d 23 h entry goes, the 3 d one stays.
        app.terminate()
        launch(app, library: library, ["-test-maintenance-clock-offset-hours", "72"])
        openLog(app)
        XCTAssertEqual(logTitles(app, expecting: 1), ["Recent episode"])
    }

    /// Serves one feed and its episode with a strong validator and byte ranges. The first episode
    /// request sends 40 % of the file and stays open, so the transfer is in progress when the app leaves.
    private final class EpisodeServer: Sendable {
        let server: LoopbackHTTPServer
        let port: Int
        private init(server: LoopbackHTTPServer, port: Int) { self.server = server; self.port = port }
        static func start() async throws -> EpisodeServer {
            let port = Mutex(0), first = Mutex(true)
            let server = try await LoopbackHTTPServer.start { request in
                if request.path.hasPrefix("/feed.xml") {
                    let feed = """
                    <rss version="2.0"><channel><title>Background podcast</title><link>https://example.test</link>
                    <item><guid>m29-background</guid><title>Background episode</title><pubDate>Mon, 28 Sep 2026 08:00:00 GMT</pubDate>
                    <enclosure url="http://127.0.0.1:\(port.withLock { $0 })/episode.mp3" type="audio/mpeg" length="\(BackgroundWorkJourneyTests.media.count)"/></item>
                    </channel></rss>
                    """
                    return .init(status: 200, headers: ["Content-Type": "application/rss+xml"], body: Data(feed.utf8))
                }
                guard request.path == "/episode.mp3" else { return .init(status: 404, headers: [:], body: Data()) }
                let media = BackgroundWorkJourneyTests.media, tag = BackgroundWorkJourneyTests.tag
                if first.withLock({ let was = $0; $0 = false; return was }) {
                    return .init(status: 200, headers: ["Content-Type": "audio/mpeg", "ETag": tag, "Accept-Ranges": "bytes",
                                                        "Content-Length": String(media.count)],
                                 body: media.prefix(1_200_000), keepConnectionOpen: true, includeAutomaticContentLength: false)
                }
                var response = LoopbackHTTPServer.Response(status: 200, headers: ["Content-Type": "audio/mpeg", "ETag": tag,
                                                                                  "Accept-Ranges": "bytes"], body: media)
                if let range = request.headers["range"], request.headers["if-range"].map({ $0 == tag }) ?? true,
                   let start = Int(range.dropFirst("bytes=".count).split(separator: "-").first ?? ""), start < media.count {
                    response.status = 206
                    response.headers["Content-Range"] = "bytes \(start)-\(media.count - 1)/\(media.count)"
                    response.body = media.suffix(from: start)
                }
                return response
            }
            port.withLock { $0 = server.url.port! }
            return EpisodeServer(server: server, port: server.url.port!)
        }
    }

    /// The saved episode file in the app's test library, read directly (not through the app).
    private func savedEpisode(library: String) -> Data? {
        let applications = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        for container in (try? FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil)) ?? [] {
            let media = container.appendingPathComponent("Library/Application Support/UITests-\(library)/media")
            let files = (try? FileManager.default.contentsOfDirectory(at: media, includingPropertiesForKeys: nil)) ?? []
            if let file = files.first(where: { $0.pathExtension == "media" }) { return try? Data(contentsOf: file) }
        }
        return nil
    }

    /// Android: the download is a WorkManager job that keeps running after the app is left or its
    /// process ends, and resumes with Range after a stop. iOS: the background download session.
    @MainActor func testDownloadContinuesAfterLeavingAndClosingTheAppAndSavesExactFile() async throws {
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
        let row = app.buttons.matching(NSPredicate(format: "label == %@", "Background episode")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let action = app.buttons["episode-action-\(row.identifier.dropFirst("episode-".count))"]
        XCTAssertEqual(action.label, "Download"); action.tap()
        // The transfer is running: the server has sent part of the file and holds the rest.
        let requested = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            episodes.server.requests.contains { $0.path == "/episode.mp3" } }, object: nil)
        await fulfillment(of: [requested], timeout: 300)
        XCTAssertEqual(action.label, "Cancel download", "the download is running")
        // Leave the app, then close it while the transfer is still open.
        XCUIDevice.shared.leaveApp()
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.state == .runningBackgroundSuspended)
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        // The server finishes the file while the app is not running.
        let finishedWithoutApp: Bool
        do {
            try await episodes.server.appendResponseBody(Self.media.suffix(from: 1_200_000), toLatestRequestFor: "/episode.mp3", isFinal: true)
            finishedWithoutApp = true
        } catch { finishedWithoutApp = false }
        // When the transfer finishes, the system launches the app in the background to hand it over.
        // That launch has no test arguments (so it opens the default library, not this test's); end it
        // before opening the app as the person does. The finished file waits beside the download.
        var relaunchedBySystem = false
        if finishedWithoutApp {
            relaunchedBySystem = app.wait(for: .runningBackground, timeout: 15) || app.state == .runningBackgroundSuspended
            if app.state != .notRunning { app.terminate(); XCTAssertTrue(app.wait(for: .notRunning, timeout: 10)) }
        }
        launch(app, library: library)
        app.navigation("Subscriptions").tap()
        let feed = app.buttons.matching(NSPredicate(format: "label == %@", "Background podcast")).firstMatch
        XCTAssertTrue(feed.waitForExistence(timeout: 10)); feed.tap()
        let reopened = app.buttons.matching(NSPredicate(format: "label == %@", "Background episode")).firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 10))
        let play = app.buttons["episode-action-\(reopened.identifier.dropFirst("episode-".count))"]
        // The system schedules the hand-over; a busy Simulator (its own asset downloads) can delay it.
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: play)], timeout: 300)
        // Independent check of the saved data: the exact source file.
        let saved = try XCTUnwrap(savedEpisode(library: library), "saved episode file")
        XCTAssertEqual(SHA256.hash(data: saved), SHA256.hash(data: Self.media))
        // Records how the Simulator's terminate behaves for background transfers.
        let ranges = episodes.server.requests.filter { $0.path == "/episode.mp3" }.map { $0.headers["range"] ?? "none" }
        print("M29-P5 finishedWithoutApp=\(finishedWithoutApp) relaunchedBySystem=\(relaunchedBySystem) episodeRequests=\(ranges)")
        // One successful entry in the Download log.
        openLog(app)
        XCTAssertEqual(logTitles(app, expecting: 1), ["Background episode"])
    }

    /// Android: an import or restart ends the process and its connections, and a restarted
    /// download worker whose episode no longer exists fails without a request. iOS keeps background
    /// transfers across launches: nine downloads of an earlier library are left running against a server
    /// that never answers (eight hold the host's connections), then the app opens another library, as
    /// after a restore. A new download there must still start and finish.
    @MainActor func testNewDownloadStartsAfterAnEarlierLibraryLeftTransfersRunning() async throws {
        continueAfterFailure = false
        let port = Mutex(0)
        let server = try await LoopbackHTTPServer.start { request in
            let base = "http://127.0.0.1:\(port.withLock { $0 })"
            switch request.path {
            case "/earlier.xml":
                let items = (1...9).map { index in
                    """
                    <item><guid>m29-earlier-\(index)</guid><title>Earlier episode \(index)</title>
                    <pubDate>Mon, \(10 + index) Sep 2026 08:00:00 GMT</pubDate>
                    <enclosure url="\(base)/old-\(index).mp3" type="audio/mpeg" length="3000000"/></item>
                    """
                }.joined()
                let feed = "<rss version=\"2.0\"><channel><title>Earlier podcast</title><link>https://example.test</link>\(items)</channel></rss>"
                return .init(status: 200, headers: ["Content-Type": "application/rss+xml"], body: Data(feed.utf8))
            case "/new.xml":
                let feed = """
                <rss version="2.0"><channel><title>Restored podcast</title><link>https://example.test</link>
                <item><guid>m29-new</guid><title>New episode</title><pubDate>Mon, 28 Sep 2026 08:00:00 GMT</pubDate>
                <enclosure url="\(base)/new.mp3" type="audio/mpeg" length="\(BackgroundWorkJourneyTests.media.count)"/></item>
                </channel></rss>
                """
                return .init(status: 200, headers: ["Content-Type": "application/rss+xml"], body: Data(feed.utf8))
            case "/new.mp3":
                return .init(status: 200, headers: ["Content-Type": "audio/mpeg", "ETag": BackgroundWorkJourneyTests.tag],
                             body: BackgroundWorkJourneyTests.media)
            default:
                // The earlier library's episodes: accepted, never answered.
                return request.path.hasPrefix("/old-") ? nil : .init(status: 404, headers: [:], body: Data())
            }
        }
        port.withLock { $0 = server.url.port! }
        defer { server.stop() }
        func subscribe(_ app: XCUIApplication, _ path: String) {
            XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
            app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
            let address = app.textFields["rssAddress"]
            XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap()
            address.typeTextSettled("http://127.0.0.1:\(server.url.port!)\(path)")
            app.buttons["Confirm"].tapWhenSettled()
            XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 10)); app.buttons["subscribeFeed"].tap()
        }
        let app = XCUIApplication()
        // The earlier library: every episode is downloaded at once (multi-select, Download).
        launch(app, library: UUID().uuidString)
        subscribe(app, "/earlier.xml")
        let first = app.buttons.matching(NSPredicate(format: "label == %@", "Earlier episode 9")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10)); first.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["multiSelect"].waitForExistence(timeout: 5)); app.buttons["multiSelect"].tap()
        app.buttons["episodeSelectionMore"].tap(); app.buttons["select_toggle"].tap()
        XCTAssertEqual(app.staticTexts["episodeSelectionCount"].label, "9/9 selected")
        let download = app.buttons["episodeBulk-download"]
        if !download.isHittable { app.otherElements["episodeSelectionActions"].swipeLeft() }
        XCTAssertTrue(download.isHittable); download.tap()
        // Eight transfers reach the server and stay open (system scheduling can delay the first).
        let held = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            server.requests.filter { $0.path.hasPrefix("/old-") }.count >= 8 }, object: nil)
        await fulfillment(of: [held], timeout: 300)
        // The app ends with the transfers still running; the next library has none of these downloads.
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        launch(app, library: UUID().uuidString)
        subscribe(app, "/new.xml")
        let row = app.buttons.matching(NSPredicate(format: "label == %@", "New episode")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let action = app.buttons["episode-action-\(row.identifier.dropFirst("episode-".count))"]
        XCTAssertEqual(action.label, "Download"); action.tap()
        // Without reconciliation the request never left the device: the eight connections stayed taken.
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: action)], timeout: 120)
        XCTAssertEqual(server.requests.filter { $0.path == "/new.mp3" }.count, 1)
    }

    /// Android: a queued change is sent about 20 s later by WorkManager even if the app was left.
    /// iOS: leaving the app starts the pending pass at once within the granted background time.
    @MainActor func testMarkPlayedReachesServerAfterAppGoesToBackground() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), username = "m29_" + UUID().uuidString.lowercased()
        addUIInterruptionMonitor(withDescription: "System password save prompt") { alert in
            let later = alert.buttons["Not Now"]
            guard later.exists else { return false }
            later.tap(); return true
        }
        launch(app, library: UUID().uuidString)
        func tap(_ id: String) {
            if app.buttons["Not Now"].exists { app.buttons["Not Now"].tap() }
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            for _ in 0..<5 where !button.isHittable {
                if app.buttons["Not Now"].exists { app.buttons["Not Now"].tap() }
                let body = app.scrollViews["sourceMessageBody"]
                (body.exists ? body : app.scrollViews["libraryContent"]).swipeUp()
            }
            button.tap()
        }
        func fill(_ id: String, _ text: String, secure: Bool = false) {
            let field = secure ? app.secureTextFields[id] : app.textFields[id]
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            field.typeTextSettled(text)
        }
        func openSynchronization() {
            XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
            app.buttons["navigationMore"].tap(); app.buttons["Settings"].tap()
            let row = app.buttons["prefScreenSynchronization"]
            for _ in 0..<5 where !row.isHittable { app.scrollViews["libraryContent"].swipeUp() }
            row.tap()
            XCTAssertTrue(app.buttons["pref_synchronization_sync"].waitForExistence(timeout: 5))
        }
        func status(_ prefix: String) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", prefix),
                object: app.staticTexts["synchronizationStatus"])], timeout: 40), .completed)
        }
        func playActions() async throws -> [[String: Any]] {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18812/inspect/" + username)!)
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return (report["episode_uploads"] as? [[String: Any]] ?? []).flatMap { $0["actions"] as? [[String: Any]] ?? [] }
                .filter { ($0["action"] as? String) == "play" && ($0["guid"] as? String) == "sync-episode" }
        }
        openSynchronization()
        tap("preference_synchronization_description"); tap("syncProvider-gpodder")
        fill("gpodderHost", "http://127.0.0.1:18812"); tap("gpodderProceed")
        fill("gpodderUsername", username); fill("gpodderPassword", "fixture-password", secure: true)
        tap("gpodderLogin"); tap("gpodderDevice-fixture-device")
        XCTAssertTrue(app.buttons["gpodderSyncNow"].waitForExistence(timeout: 10)); tap("gpodderSyncNow")
        status("Successful (")
        app.buttons["toolbarBack"].tap(); app.buttons["toolbarBack"].tap()
        app.navigation("Subscriptions").tap()
        let feed = app.buttons.matching(NSPredicate(format: "label == %@", "Synced fixture podcast")).firstMatch
        XCTAssertTrue(feed.waitForExistence(timeout: 20)); feed.tap()
        let episode = app.buttons.matching(NSPredicate(format: "label == %@", "Synced fixture episode")).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 10))
        let before = try await playActions(); XCTAssertTrue(before.isEmpty)
        episode.press(forDuration: 0.7)
        tap("markPlayed")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Played"),
                                                                      object: episode)], timeout: 10), .completed)
        // Leave the app right away, well before the 20 s delay.
        XCUIDevice.shared.leaveApp()
        let deadline = Date().addingTimeInterval(45)
        var actions = try await playActions()
        while actions.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(250)); actions = try await playActions() }
        XCTAssertFalse(actions.isEmpty, "the change reached the server while the app was in the background")
        XCTAssertNotEqual(app.state, .runningForeground)
        // Back in the app, the Synchronization screen reports the pass.
        app.activate()
        while app.buttons["toolbarBack"].exists { app.buttons["toolbarBack"].tap() }
        openSynchronization()
        status("Successful (")
    }
}
