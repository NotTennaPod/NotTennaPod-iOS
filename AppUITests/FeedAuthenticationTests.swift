import XCTest

final class FeedAuthenticationTests: XCTestCase {
    @MainActor func testFailedSubscriptionRefreshRecoversThroughSettings() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), path = "/private.xml?recovery=\(UUID())"
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18770" + path)
        app.buttons["Confirm"].tapWhenSettled()
        let username = app.textFields["feedUsername"], password = app.secureTextFields["feedPassword"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap(); username.typeTextSettled("listener"); password.tap(); password.typeTextSettled("podcast")
        app.buttons["feedAuthenticationConfirm"].tapWhenSettled(); app.dismissSavePasswordPrompt()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 10)); app.subscribeAfterSystemSheet()
        XCTAssertTrue(app.buttons["feedSettings"].waitForExistence(timeout: 10), app.debugDescription)
        try await waitForAuthorized(2, path: path)
        app.buttons["feedSettings"].tap(); app.buttons["feedAuthentication"].tap()
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        app.buttons["feedPasswordVisibility"].tap()
        let visible = app.textFields["feedPassword"]
        visible.tap(); visible.typeTextSettled(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7) + "expired")
        app.buttons["feedAuthenticationConfirm"].tapWhenSettled(); app.dismissSavePasswordPrompt(); app.buttons["toolbarBack"].tap()
        let failure = app.buttons["feedRefreshFailure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        XCTAssertFalse(username.exists)
        failure.tap()
        XCTAssertTrue(app.staticTexts["feedLogStatus"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["feedLogStatus"].label, "Authentication error. Make sure that username and password are correct.")
        XCTAssertEqual(app.staticTexts["feedLogTechnical"].label, "401")
        XCTAssertEqual(app.staticTexts["feedLogURL"].label, "http://127.0.0.1:18770" + path)
        app.buttons["feedLogDetailsOK"].tap()
        app.terminate(); app.launch(); app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 10)); app.buttons["subscriptionFeed-1"].tap()
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        failure.tap(); XCTAssertTrue(app.staticTexts["feedLogTechnical"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["feedLogTechnical"].label, "401"); app.buttons["feedLogDetailsOK"].tap()
        app.buttons["feedSettings"].tap(); app.buttons["feedAuthentication"].tap()
        XCTAssertTrue(password.waitForExistence(timeout: 5)); app.buttons["feedPasswordVisibility"].tap()
        XCTAssertEqual(visible.value as? String, "expired")
        visible.tap(); visible.typeTextSettled(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7) + "podcast")
        app.buttons["feedAuthenticationConfirm"].tapWhenSettled(); app.dismissSavePasswordPrompt()
        try await waitForAuthorized(3, path: path)
        app.buttons["toolbarBack"].tap()
        let recovered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: failure)
        await fulfillment(of: [recovered], timeout: 10)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Private episode ")).count, 12)
    }

    @MainActor func testCredentialSettingsSaveRefreshCancelAndRelaunch() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), path = "/private.xml?edit=\(UUID())"
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18770" + path)
        app.buttons["Confirm"].tapWhenSettled()
        let username = app.textFields["feedUsername"], password = app.secureTextFields["feedPassword"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap(); username.typeTextSettled("listener"); password.tap(); password.typeTextSettled("podcast")
        app.buttons["feedAuthenticationConfirm"].tapWhenSettled(); app.dismissSavePasswordPrompt()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 10)); app.subscribeAfterSystemSheet()
        XCTAssertTrue(app.buttons["feedSettings"].waitForExistence(timeout: 10), app.debugDescription)
        try await waitForAuthorized(2, path: path)
        app.buttons["feedSettings"].tap()
        app.buttons["feedKeepUpdated"].tap()
        XCTAssertEqual(app.buttons["feedKeepUpdated"].value as? String, "Off")
        app.buttons["feedAuthentication"].tap()
        XCTAssertTrue(username.waitForExistence(timeout: 5), app.debugDescription); XCTAssertEqual(username.value as? String, "listener")
        XCTAssertFalse(app.staticTexts["feedAuthenticationFailure"].exists)
        app.buttons["feedPasswordVisibility"].tap()
        let visible = app.textFields["feedPassword"]
        XCTAssertEqual(visible.value as? String, "podcast")
        visible.tap(); visible.typeTextSettled(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7) + "discarded")
        app.buttons["feedAuthenticationCancel"].tap()
        app.buttons["feedAuthentication"].tap()
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        app.buttons["feedPasswordVisibility"].tap(); XCTAssertEqual(visible.value as? String, "podcast")
        // Saving a new accepted password forces refresh with keep-updated off.
        visible.tap(); visible.typeTextSettled(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7) + "updated-podcast")
        app.buttons["feedAuthenticationConfirm"].tapWhenSettled(); app.dismissSavePasswordPrompt()
        try await waitForAuthorized(3, path: path)
        XCTAssertEqual(app.buttons["feedKeepUpdated"].value as? String, "Off")
        app.terminate(); app.launch(); app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 10)); app.buttons["subscriptionFeed-1"].tap()
        app.buttons["feedSettings"].tap(); app.buttons["feedAuthentication"].tap()
        XCTAssertTrue(username.waitForExistence(timeout: 5)); XCTAssertEqual(username.value as? String, "listener")
        app.buttons["feedPasswordVisibility"].tap(); XCTAssertEqual(visible.value as? String, "updated-podcast")
        app.buttons["feedAuthenticationConfirm"].tapWhenSettled(); app.dismissSavePasswordPrompt()
        try await waitForAuthorized(4, path: path)
        XCTAssertEqual(app.buttons["feedKeepUpdated"].value as? String, "Off")
    }

    @MainActor func testPrivateEpisodeStreamsAgainAfterRelaunch() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), run = UUID().uuidString
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap()
        address.typeTextSettled("http://127.0.0.1:18770/private.xml?play=\(run)")
        app.buttons["Confirm"].tapWhenSettled()
        let username = app.textFields["feedUsername"], password = app.secureTextFields["feedPassword"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        username.tap(); username.typeTextSettled("listener"); password.tap(); password.typeTextSettled("podcast")
        app.buttons["feedAuthenticationConfirm"].tapWhenSettled(); app.dismissSavePasswordPrompt()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 10)); app.subscribeAfterSystemSheet()
        XCTAssertTrue(app.buttons["feedInformation"].waitForExistence(timeout: 10))
        let mediaPath = "/30sec.mp3?episode=12"
        let before = try await authorizedCount(mediaPath)
        func playAndPause(_ number: Int = 12) {
            app.buttons.matching(NSPredicate(format: "label == %@", String(format: "Private episode %02d", number))).firstMatch.tap()
            let action = app.buttons["episodePrimaryAction"]
            XCTAssertTrue(action.waitForExistence(timeout: 5))
            XCTAssertEqual(action.label, "Stream"); action.tap()
            let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pause"), object: action)
            wait(for: [playing], timeout: 15)
            action.tap()
            let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Stream"), object: action)
            wait(for: [paused], timeout: 5)
        }
        playAndPause(); try await waitForAuthorized(before + 1, path: mediaPath)
        app.terminate(); app.launch(); app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 10)); app.buttons["subscriptionFeed-1"].tap()
        XCTAssertTrue(app.buttons["feedInformation"].waitForExistence(timeout: 5))
        playAndPause()
        // The replayed episode may come from the media cache, so it proves nothing about credentials.
        // An episode never fetched before must be requested with the saved login after the relaunch.
        let uncachedPath = "/30sec.mp3?episode=11"
        let uncachedBefore = try await authorizedCount(uncachedPath)
        app.buttons["SubscriptionFragment"].tap(); app.buttons["subscriptionFeed-1"].tap()
        XCTAssertTrue(app.buttons["feedInformation"].waitForExistence(timeout: 5))
        playAndPause(11); try await waitForAuthorized(uncachedBefore + 1, path: uncachedPath)
        XCTAssertFalse(app.textFields["feedUsername"].exists)
    }

    @MainActor func testWrongLoginRetrySubscribeAndRelaunchRefresh() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), path = "/private.xml?run=\(UUID())"
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18770" + path)
        app.buttons["Confirm"].tapWhenSettled()
        let username = app.textFields["feedUsername"], password = app.secureTextFields["feedPassword"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["feedPreviewCard"].exists)
        username.tap(); username.typeTextSettled("listener"); password.tap(); password.typeTextSettled("wrong")
        app.buttons["feedAuthenticationConfirm"].tapWhenSettled()
        // The failure message is a 3.5 s toast (Android Toast.LENGTH_LONG). Look for it while declining iOS's
        // Save Password sheet when that appears (iPhone, iPad), not after waiting for a sheet that may never
        // come (the Duo shows none): by then the toast has correctly gone.
        let failure = app.staticTexts["feedAuthenticationFailure"], notNow = app.buttons["Not Now"]
        let deadline = Date().addingTimeInterval(15)
        while !failure.waitForExistence(timeout: 0.5), Date() < deadline { if notNow.exists { notNow.tap() } }
        XCTAssertTrue(failure.exists, app.debugDescription)
        app.dismissSavePasswordPrompt()
        XCTAssertEqual(username.value as? String, "listener")
        app.buttons["feedPasswordVisibility"].tap()
        let visible = app.textFields["feedPassword"]
        XCTAssertEqual(visible.value as? String, "wrong")
        visible.tap(); visible.typeTextSettled(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "podcast")
        app.buttons["feedPasswordVisibility"].tap()
        app.buttons["feedAuthenticationConfirm"].tapWhenSettled(); app.dismissSavePasswordPrompt()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Private episode ")).count, 12)
        app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["feedInformation"].waitForExistence(timeout: 10))
        try await waitForAuthorized(2, path: path)
        app.terminate(); app.launch(); app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons["subscriptionFeed-1"].waitForExistence(timeout: 10)); app.buttons["subscriptionFeed-1"].tap()
        app.buttons["feedListMore"].tap()
        app.buttons["refreshFeed"].tap()
        try await waitForAuthorized(3, path: path)
        XCTAssertFalse(app.textFields["feedUsername"].exists)
        XCTAssertTrue(app.buttons["feedInformation"].exists)
    }
    @MainActor func testCancelAuthenticationReturnsToAddPodcastWithoutSubscription() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18770/private.xml?cancel=\(UUID())")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["feedAuthenticationCancel"].waitForExistence(timeout: 10))
        app.buttons["feedAuthenticationCancel"].tap()
        XCTAssertTrue(app.buttons["addRSS"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["feedPreviewCard"].exists)
    }
    @MainActor private func waitForAuthorized(_ expected: Int, path: String) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        var count = 0
        repeat {
            count = try await authorizedCount(path)
            if count < expected { try await Task.sleep(for: .milliseconds(100)) }
        } while count < expected && ContinuousClock.now < deadline
        // Streaming may use several range requests; what matters is that authorized requests happened.
        XCTAssertGreaterThanOrEqual(count, expected)
    }
    @MainActor private func authorizedCount(_ path: String) async throws -> Int {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18770/counts")!)
        return try JSONDecoder().decode([String: [String: Int]].self, from: data)[path]?["authorized"] ?? 0
    }
}

extension XCUIApplication {
    /// Right after iOS's Save Password sheet closes, a tap can be lost while the sheet finishes dismissing.
    /// Tap Subscribe once it has settled, and again if the preview is still showing it.
    func subscribeAfterSystemSheet() {
        let subscribe = buttons["subscribeFeed"]
        subscribe.tapWhenSettled()
        if !subscribe.waitForNonExistence(timeout: 3), subscribe.exists { subscribe.tapWhenSettled() }
    }
}
