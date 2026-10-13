import XCTest

/// Runs against serve-nextcloud-fixture.py on loopback18813. Authorization is
/// performed in Safari with a real HTTP Grant access submission. App activation
/// is the user's ordinary return, never an injected callback or credential.
final class NextcloudAuthenticationTests: XCTestCase {
    @MainActor private func start() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        addTeardownBlock { @MainActor in app.terminate() }
        return app
    }
    /// Opens Settings → Synchronization. A relaunch may already be there: iOS reopens the place it saved when the app
    /// last left the foreground (for the browser), and a kill in the foreground saves nothing newer.
    @MainActor private func settings(_ app: XCUIApplication) {
        let more = app.buttons["navigationMore"], sync = app.buttons["pref_synchronization_sync"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            more.exists || sync.exists
        }, object: nil)], timeout: 10), .completed)
        if sync.exists { return }
        more.tap(); app.buttons["Settings"].tap()
        let row = app.buttons["prefScreenSynchronization"]
        for _ in 0..<5 where !row.isHittable { app.scrollViews["libraryContent"].swipeUp() }
        XCTAssertTrue(row.isHittable); row.tap()
        XCTAssertTrue(app.buttons["pref_synchronization_sync"].waitForExistence(timeout: 5))
    }
    @MainActor private func tap(_ id: String, _ app: XCUIApplication) {
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        for _ in 0..<5 where !button.isHittable {
            let body = app.scrollViews["sourceMessageBody"]
            (body.exists ? body : app.scrollViews["libraryContent"]).swipeUp()
        }
        XCTAssertTrue(button.isHittable); button.tap()
    }
    @MainActor private func begin(_ identifier: String, _ app: XCUIApplication) {
        tap("preference_synchronization_description", app)
        tap("syncProvider-nextcloud", app)
        let field = app.textFields["nextcloudHost"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeTextSettled("http://127.0.0.1:18813/cloud/" + identifier)
        tap("nextcloudProceed", app)
    }
    @MainActor private func browser() -> XCUIApplication {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20))
        XCTAssertTrue(safari.buttons["Grant access"].waitForExistence(timeout: 20))
        return safari
    }
    @MainActor private func grant(_ safari: XCUIApplication, app: XCUIApplication) {
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 10))
        let grant = safari.buttons["Grant access"]
        XCTAssertTrue(grant.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: grant)], timeout: 10), .completed)
        grant.tap()
        XCTAssertTrue(safari.staticTexts["Access granted"].waitForExistence(timeout: 10))
        app.activate()
    }
    @MainActor private func status(_ prefix: String, _ app: XCUIApplication) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", prefix), object: app.staticTexts["synchronizationStatus"])], timeout: 40), .completed)
    }
    @MainActor private func inspect(_ identifier: String) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18813/inspect/" + identifier)!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    @MainActor private func control(_ identifier: String, _ changes: [String: Int]) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18813/control/" + identifier)!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: changes)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
    @MainActor func testBrowserGrantSubfolderFullSyncRemotePositionRelaunchAndLogout() async throws {
        let app = start(), identifier = UUID().uuidString.lowercased()
        settings(app); begin(identifier, app)
        grant(browser(), app: app)
        status("Successful (", app)
        XCTAssertTrue((app.buttons["pref_synchronization_logout"].value as? String)?.contains(identifier) == true)
        XCTAssertFalse(app.buttons["pref_gpodnet_setlogin_information"].exists)
        let first = try await inspect(identifier)
        XCTAssertEqual(first["auth_start"] as? Int, 1)
        XCTAssertEqual(first["grant"] as? Int, 1)
        XCTAssertGreaterThan(first["poll"] as? Int ?? 0, 0)
        let cursors = try XCTUnwrap(first["sync_since"] as? [[String: Any]])
        XCTAssertTrue(cursors.contains { ($0["value"] as? Int) == 0 })
        app.buttons["toolbarBack"].tap(); app.buttons["toolbarBack"].tap(); app.navigation("Subscriptions").tap()
        let feed = app.buttons.matching(NSPredicate(format: "label == %@", "Nextcloud sync fixture")).firstMatch
        XCTAssertTrue(feed.waitForExistence(timeout: 20)); feed.tap()
        let episode = app.buttons.matching(NSPredicate(format: "label == %@", "Synced fixture episode")).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 10))
        XCTAssertTrue((episode.value as? String)?.contains("00:00:12") == true)
        episode.press(forDuration: 0.7); tap("markPlayed", app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "Played"), object: episode)], timeout: 10), .completed)
        app.terminate(); app.launch(); settings(app)
        XCTAssertTrue((app.buttons["pref_synchronization_logout"].value as? String)?.contains(identifier) == true)
        status("Successful (", app)
        tap("pref_synchronization_sync", app)
        let deadline = Date().addingTimeInterval(40)
        var state = try await inspect(identifier)
        while (state["episode_uploads"] as? [[String: Any]] ?? []).isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100)); state = try await inspect(identifier)
        }
        status("Successful (", app)
        let uploads = try XCTUnwrap(state["episode_uploads"] as? [[String: Any]])
        let actions = uploads.flatMap { $0["actions"] as? [[String: Any]] ?? [] }
        XCTAssertTrue(actions.contains { ($0["action"] as? String) == "play" && ($0["position"] as? Int) == 60 && ($0["guid"] as? String) == "sync-episode" })
        tap("pref_synchronization_logout", app)
        XCTAssertTrue(app.buttons["preference_synchronization_description"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["pref_synchronization_sync"].isEnabled)
        app.terminate(); app.launch(); settings(app)
        XCTAssertFalse(app.buttons["pref_synchronization_sync"].isEnabled)
    }

    @MainActor func testStartErrorRetryCancelAndLateBrowserGrantCannotSelectAccount() async throws {
        let app = start(), identifier = UUID().uuidString.lowercased()
        try await control(identifier, ["startFailures": 1])
        settings(app); begin(identifier, app)
        XCTAssertTrue(app.staticTexts["sourceMessage"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["sourceMessage"].label.contains("Return code 503"))
        tap("sourceMessageOK", app)
        XCTAssertTrue(app.textFields["nextcloudHost"].isEnabled)
        tap("nextcloudProceed", app)
        let safari = browser()
        app.activate()
        XCTAssertTrue(app.buttons["nextcloudCancel"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["nextcloudHost"].isEnabled)
        tap("nextcloudCancel", app)
        XCTAssertFalse(app.buttons["pref_synchronization_sync"].isEnabled)
        safari.activate(); grant(safari, app: app)
        XCTAssertFalse(app.buttons["pref_synchronization_sync"].isEnabled)
        let canceled = try await inspect(identifier)
        XCTAssertTrue((canceled["sync_routes"] as? [String: Int])?.isEmpty == true)
        begin(identifier, app); grant(browser(), app: app)
        status("Successful (", app)
        let completed = try await inspect(identifier)
        XCTAssertEqual(completed["auth_start"] as? Int, 3)
        XCTAssertEqual(completed["grant"] as? Int, 2)
        tap("pref_synchronization_logout", app)
    }

    @MainActor func testPendingAuthorizationRelaunchResumesWithoutReopeningBrowserAndDenialCanCancel() async throws {
        let app = start(), identifier = UUID().uuidString.lowercased()
        settings(app); begin(identifier, app)
        let safari = browser()
        safari.buttons["Deny access"].tap()
        XCTAssertTrue(safari.staticTexts["Access denied"].waitForExistence(timeout: 10))
        app.activate()
        XCTAssertTrue(app.buttons["nextcloudCancel"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["nextcloudHost"].isEnabled)
        let before = try await inspect(identifier)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["nextcloudCancel"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.textFields["nextcloudHost"].isEnabled)
        let deadline = Date().addingTimeInterval(10)
        var restored = try await inspect(identifier)
        while (restored["poll"] as? Int ?? 0) <= (before["poll"] as? Int ?? 0), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100)); restored = try await inspect(identifier)
        }
        XCTAssertGreaterThan(restored["poll"] as? Int ?? 0, before["poll"] as? Int ?? 0)
        XCTAssertEqual(restored["auth_start"] as? Int, 1)
        XCTAssertEqual(restored["browser"] as? Int, 1)
        XCTAssertEqual(restored["deny"] as? Int, 1)
        tap("nextcloudCancel", app)
        XCTAssertFalse(app.buttons["pref_synchronization_sync"].isEnabled)
        begin(identifier, app); grant(browser(), app: app)
        status("Successful (", app)
        tap("pref_synchronization_logout", app)
    }
}
