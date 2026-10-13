import XCTest

final class SynchronizationSettingsTests: XCTestCase {
    @MainActor private func start() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        addUIInterruptionMonitor(withDescription: "System password save prompt") { alert in
            let later = alert.buttons["Not Now"]
            guard later.exists else { return false }
            later.tap(); return true
        }
        app.launch()
        addTeardownBlock { @MainActor in app.terminate() }
        return app
    }
    @MainActor private func settings(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Settings"].tap()
        let row = app.buttons["prefScreenSynchronization"]
        for _ in 0..<5 where !row.isHittable { app.scrollViews["libraryContent"].swipeUp() }
        XCTAssertTrue(row.isHittable); row.tap()
        XCTAssertTrue(app.buttons["pref_synchronization_sync"].waitForExistence(timeout: 5))
    }
    @MainActor private func tap(_ id: String, _ app: XCUIApplication) {
        dismissPasswordPrompt(app)
        let button = app.buttons[id]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        for _ in 0..<5 where !button.isHittable {
            dismissPasswordPrompt(app)
            if !button.isHittable {
                let body = app.scrollViews["sourceMessageBody"]
                (body.exists ? body : app.scrollViews["libraryContent"]).swipeUp()
            }
        }
        XCTAssertTrue(button.isHittable); button.tap()
    }
    @MainActor private func fill(_ id: String, _ text: String, _ app: XCUIApplication, secure: Bool = false, replacing old: String = "") {
        dismissPasswordPrompt(app)
        let field = secure ? app.secureTextFields[id] : app.textFields[id]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        for _ in 0..<5 where !field.isHittable {
            dismissPasswordPrompt(app)
            if !field.isHittable { app.scrollViews["sourceMessageBody"].swipeUp() }
        }
        dismissPasswordPrompt(app)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeTextSettled(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + text)
    }
    @MainActor private func dismissPasswordPrompt(_ app: XCUIApplication) {
        // Native credential autofill can present its own sheet after login.
        // Dismiss the system offer without changing application account state.
        let later = app.buttons["Not Now"]
        if later.exists { later.tap() }
    }
    @MainActor private func beginLogin(_ app: XCUIApplication, username: String, password: String) {
        tap("preference_synchronization_description", app)
        tap("syncProvider-gpodder", app)
        fill("gpodderHost", "http://127.0.0.1:18812", app)
        tap("gpodderProceed", app)
        fill("gpodderUsername", username, app)
        fill("gpodderPassword", password, app, secure: true)
        tap("gpodderLogin", app)
    }
    @MainActor private func status(_ prefix: String, _ app: XCUIApplication) {
        let value = app.staticTexts["synchronizationStatus"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", prefix), object: value)], timeout: 40), .completed)
    }
    @MainActor private func inspect(_ username: String) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18812/inspect/" + username)!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    @MainActor private func episodeRequests(_ report: [String: Any], zero: Bool = false) -> Int {
        (report["routes"] as? [[String: Any]] ?? []).filter {
            ($0["method"] as? String) == "GET" && ($0["path"] as? String)?.contains("/episodes/") == true
                && (!zero || ($0["since"] as? Int) == 0)
        }.count
    }
    @MainActor private func waitForEpisodeExchange(_ username: String, after count: Int, zero: Bool = false) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(40)
        var report = try await inspect(username)
        while episodeRequests(report, zero: zero) <= count && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100)); report = try await inspect(username)
        }
        XCTAssertGreaterThan(episodeRequests(report, zero: zero), count)
        return report
    }

    @MainActor func testExistingDeviceSyncPersistencePasswordRetryAndLogout() async throws {
        let app = start(), username = "existing_" + UUID().uuidString.lowercased()
        settings(app)
        XCTAssertFalse(app.buttons["pref_synchronization_sync"].isEnabled)
        beginLogin(app, username: username, password: "wrong")
        let error = app.staticTexts["gpodderAuthenticationError"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertEqual(error.label, "Wrong username or password")
        fill("gpodderPassword", "fixture-password", app, secure: true, replacing: "wrong")
        tap("gpodderLogin", app)
        tap("gpodderDevice-fixture-device", app)
        XCTAssertTrue(app.buttons["gpodderSyncNow"].waitForExistence(timeout: 10))
        let beforeSync = try await inspect(username)
        XCTAssertTrue((beforeSync["since"] as? [[String: Any]])?.isEmpty == true)
        tap("gpodderSyncNow", app)
        status("Successful (", app)
        XCTAssertTrue(app.buttons["pref_gpodnet_setlogin_information"].exists)
        let account = app.buttons["pref_synchronization_logout"]
        XCTAssertTrue((account.value as? String)?.contains(username) == true)

        app.buttons["toolbarBack"].tap(); app.buttons["toolbarBack"].tap()
        app.navigation("Subscriptions").tap()
        let feed = app.buttons.matching(NSPredicate(format: "label == %@", "Synced fixture podcast")).firstMatch
        XCTAssertTrue(feed.waitForExistence(timeout: 20)); feed.tap()
        let episode = app.buttons.matching(NSPredicate(format: "label == %@", "Synced fixture episode")).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 10))
        // Observable imported position before any local playback can change it.
        XCTAssertTrue((episode.value as? String)?.contains("00:00:12") == true)
        episode.press(forDuration: 0.7)
        tap("markPlayed", app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "Played"), object: episode)], timeout: 10), .completed)
        app.terminate(); app.launch()
        settings(app)
        status("Successful (", app)
        XCTAssertTrue((app.buttons["pref_synchronization_logout"].value as? String)?.contains(username) == true)

        tap("pref_gpodnet_setlogin_information", app)
        XCTAssertFalse(app.textFields["feedUsername"].isEnabled)
        fill("feedPassword", "wrong", app, secure: true)
        tap("syncPasswordConfirm", app)
        tap("pref_synchronization_sync", app)
        status("Failed (", app)
        tap("pref_gpodnet_setlogin_information", app)
        fill("feedPassword", "fixture-password", app, secure: true)
        tap("syncPasswordConfirm", app)
        let beforeRetry = try await inspect(username)
        tap("pref_synchronization_sync", app)
        _ = try await waitForEpisodeExchange(username, after: episodeRequests(beforeRetry))
        status("Successful (", app)
        let acknowledged = try await inspect(username)
        let uploads = try XCTUnwrap(acknowledged["episode_uploads"] as? [[String: Any]])
        let actions = uploads.flatMap { $0["actions"] as? [[String: Any]] ?? [] }
        XCTAssertTrue(actions.contains { ($0["action"] as? String) == "play" && ($0["position"] as? Int) == 60 && ($0["guid"] as? String) == "sync-episode" })
        // A second incremental pass must not resend acknowledged outbox actions.
        tap("pref_synchronization_sync", app)
        _ = try await waitForEpisodeExchange(username, after: episodeRequests(acknowledged))
        status("Successful (", app)
        let incremental = try await inspect(username)
        XCTAssertEqual((incremental["episode_uploads"] as? [[String: Any]])?.count, uploads.count)
        tap("pref_synchronization_force_full_sync", app)
        _ = try await waitForEpisodeExchange(username, after: episodeRequests(incremental, zero: true), zero: true)
        status("Successful (", app)
        let report = try await inspect(username)
        let routes = try XCTUnwrap(report["routes"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(routes.filter { ($0["method"] as? String) == "GET" && ($0["path"] as? String)?.contains("/subscriptions/") == true && ($0["since"] as? Int) == 0 }.count, 2)
        tap("pref_synchronization_logout", app)
        XCTAssertTrue(app.buttons["preference_synchronization_description"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["pref_synchronization_sync"].isEnabled)
        XCTAssertFalse(app.buttons["pref_gpodnet_setlogin_information"].exists)
        app.terminate(); app.launch(); settings(app)
        XCTAssertFalse(app.buttons["pref_synchronization_sync"].isEnabled)
    }

    @MainActor func testRegistrationFailureRetryAndCancelAfterSelectionRetainsAccountWithoutSync() async throws {
        let app = start(), username = "register_" + UUID().uuidString.lowercased()
        settings(app)
        beginLogin(app, username: username, password: "fixture-password")
        let name = app.textFields["gpodderDeviceName"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        let original = try XCTUnwrap(name.value as? String)
        fill("gpodderDeviceName", "Rejected device", app, replacing: original)
        tap("gpodderCreateDevice", app)
        let error = app.staticTexts["gpodderAuthenticationError"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertEqual(error.label, "127.0.0.1 is currently unavailable (code 500)")
        fill("gpodderDeviceName", "Registered fixture device", app, replacing: "Rejected device")
        tap("gpodderCreateDevice", app)
        XCTAssertTrue(app.buttons["gpodderSyncNow"].waitForExistence(timeout: 10))
        tap("gpodderCancel", app)
        XCTAssertTrue(app.buttons["pref_synchronization_sync"].isEnabled)
        XCTAssertTrue((app.buttons["pref_synchronization_logout"].value as? String)?.contains(username) == true)
        XCTAssertEqual(app.buttons["pref_synchronization_logout"].value as? String,
            "Logged in as \(username) on http://127.0.0.1:18812. You can choose your synchronization provider again once you have logged out.")
        let report = try await inspect(username)
        XCTAssertTrue((report["since"] as? [[String: Any]])?.isEmpty == true)
        XCTAssertTrue((report["episode_uploads"] as? [[String: Any]])?.isEmpty == true)
        XCTAssertTrue((report["subscription_uploads"] as? [[String: Any]])?.isEmpty == true)
        XCTAssertEqual((report["device"] as? [String: Any])?["caption"] as? String, "Registered fixture device")
        tap("pref_synchronization_logout", app)
    }

}
