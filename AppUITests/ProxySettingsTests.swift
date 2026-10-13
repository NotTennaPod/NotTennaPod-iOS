import XCTest

final class ProxySettingsTests: XCTestCase {
    @MainActor func testAuthenticatedProxyTestSaveRelaunchSubscriptionAndDownload() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), identifier = UUID().uuidString
        app.launchArguments = ["-test-library-id", identifier, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Settings"].tap(); app.buttons["prefScreenDownloads"].tap()
        let row = app.buttons["prefProxy"]
        for _ in 0..<5 where !row.isHittable { app.scrollViews["libraryContent"].swipeUp() }
        XCTAssertTrue(row.isHittable); row.tap()
        app.buttons["proxyType"].tap(); app.buttons["proxyType-HTTP"].tap()
        for (id, text) in [("proxyHost", "localhost"), ("proxyPort", "18790"), ("proxyUsername", "fixture-user")] {
            let field = app.textFields[id]
            for _ in 0..<4 where !field.isHittable { app.scrollViews["sourceMessageBody"].swipeUp() }
            field.tap(); field.typeTextSettled(text)
        }
        let password = app.secureTextFields["proxyPassword"]
        for _ in 0..<4 where !password.isHittable { app.scrollViews["sourceMessageBody"].swipeUp() }
        password.tap(); password.typeTextSettled("fixture-secret\n")
        let confirm = app.buttons["proxyConfirm"]
        XCTAssertTrue(confirm.isHittable); confirm.tap()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "OK"), object: confirm)], timeout: 40)
        XCTAssertEqual(app.staticTexts["proxyStatus"].label, "Test successful")
        confirm.tap(); app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeTextSettled("http://proxy-feed.invalid/feed.xml?session=\(identifier)")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15)); app.buttons["subscribeFeed"].tap()
        let episode = app.buttons.matching(NSPredicate(format: "label == %@", "Proxy downloaded episode")).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 10))
        let id = String(episode.identifier.dropFirst("episode-".count))
        let action = app.buttons["episode-action-" + id]
        if !action.isHittable { app.scrollViews["libraryContent"].swipeUp() }
        action.tap()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: action)], timeout: 20)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.otherElements["morePopup"].buttons["Downloads"].tap()
        XCTAssertTrue(app.buttons["episode-" + id].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["episode-action-" + id].label, "Delete")
    }
    // The proxy is saved, the app is relaunched, and the subscription and stream then go through the saved proxy
    // (the fixture feed and media hosts do not resolve directly). One stream per media kind.
    @MainActor func testSavedProxyStreamsAfterRelaunch() async throws { try await savedProxyStream(mode: "progressive") }
    @MainActor func testSavedProxyHLSStreamsAfterRelaunch() async throws { try await savedProxyStream(mode: "playlist") }
    @MainActor func testSavedProxyEncryptedHLSStreamsAfterRelaunch() async throws { try await savedProxyStream(mode: "encrypted") }
    @MainActor func testSavedProxyOpenEndedStreamsAfterRelaunch() async throws { try await savedProxyStream(mode: "open-ended") }
    @MainActor func testSavedProxyUnknownDurationRecoversWithoutEndingEpisode() async throws { try await savedProxyStream(mode: "live-recovery") }
    @MainActor private func savedProxyStream(mode: String) async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), identifier = UUID().uuidString
        app.launchArguments = ["-test-library-id", identifier, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Settings"].tap(); app.buttons["prefScreenDownloads"].tap()
        let row = app.buttons["prefProxy"]
        for _ in 0..<5 where !row.isHittable { app.scrollViews["libraryContent"].swipeUp() }
        XCTAssertTrue(row.isHittable); row.tap()
        app.buttons["proxyType"].tap(); app.buttons["proxyType-HTTP"].tap()
        for (id, text) in [("proxyHost", "localhost"), ("proxyPort", "18790"), ("proxyUsername", "fixture-user")] {
            let field = app.textFields[id]
            for _ in 0..<4 where !field.isHittable { app.scrollViews["sourceMessageBody"].swipeUp() }
            field.tap(); field.typeTextSettled(text)
        }
        let password = app.secureTextFields["proxyPassword"]
        for _ in 0..<4 where !password.isHittable { app.scrollViews["sourceMessageBody"].swipeUp() }
        password.tap(); password.typeTextSettled("fixture-secret\n")
        let confirm = app.buttons["proxyConfirm"]
        XCTAssertTrue(confirm.isHittable); confirm.tap()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "OK"), object: confirm)], timeout: 40)
        XCTAssertEqual(app.staticTexts["proxyStatus"].label, "Test successful")
        confirm.tap(); app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeTextSettled("http://proxy-feed.invalid/feed.xml?session=\(identifier)&mode=\(mode)")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15)); app.buttons["subscribeFeed"].tap()
        let episode = app.buttons.matching(NSPredicate(format: "label == %@", "Proxy downloaded episode")).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 10))
        let id = String(episode.identifier.dropFirst("episode-".count))
        let action = app.buttons["episode-action-" + id]
        if !action.isHittable { app.scrollViews["libraryContent"].swipeUp() }
        app.buttons["navigationMore"].tap(); app.buttons["Settings"].tap(); app.buttons["prefScreenInterface"].tap()
        let streamSetting = app.buttons["prefStreamOverDownload"]
        for _ in 0..<5 where !streamSetting.isHittable { app.scrollViews["libraryContent"].swipeUp() }
        streamSetting.tap(); app.buttons["toolbarBack"].tap(); app.buttons["toolbarBack"].tap()
        do {
            XCTAssertTrue(action.waitForExistence(timeout: 10)); XCTAssertEqual(action.label, "Stream"); action.tap()
            XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 15)); app.buttons["miniPlayerOpen"].tap()
            let position = app.staticTexts["playerPosition"]
            XCTAssertTrue(position.waitForExistence(timeout: 5))
            let initial = position.label
            if mode == "open-ended" || mode == "live-recovery" {
                // Media3PlaybackService.setupPositionObserver only posts duration > 0;
                // AudioPlayerFragment also ignores INVALID_TIME. Unknown-length audio
                // advancement is verified by native tests and persisted pause position.
                await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pause"), object: app.buttons["playerPlay"])], timeout: 15)
                if mode == "live-recovery" {
                    let deadline = ContinuousClock.now + .seconds(25)
                    var resumed = false
                    var request = URLRequest(url: URL(string: "http://127.0.0.1:18790/recovery-status?session=\(identifier)")!)
                    request.setValue("Basic " + Data("fixture-user:fixture-secret".utf8).base64EncodedString(), forHTTPHeaderField: "Proxy-Authorization")
                    while !resumed, ContinuousClock.now < deadline {
                        let (data, _) = try await URLSession.shared.data(for: request)
                        let status = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                        resumed = status["reconnected"] as? Bool == true && (status["secondsSinceReconnect"] as? Double ?? 0) >= 3
                        if !resumed { try await Task.sleep(for: .milliseconds(100)) }
                    }
                    XCTAssertTrue(resumed, "The selected application must reconnect after consuming its live buffer")
                    XCTAssertEqual(app.buttons["playerPlay"].label, "Pause")
                    XCTAssertFalse(app.alerts.firstMatch.exists)
                }
                // Android leaves the text frozen here; a ticking position is not a user-visible defect.
                XCTAssertNotNil(position.label.range(of: #"^\d{2}:\d{2}:\d{2}$"#, options: .regularExpression), position.label)
            } else {
                await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", initial), object: position)], timeout: 15)
            }
            XCTAssertEqual(app.buttons["playerPlay"].label, "Pause"); app.buttons["playerPlay"].tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"),
                                                                          object: app.buttons["playerPlay"])], timeout: 10), .completed)
        }
    }
    @MainActor func testSettingsNavigationDraftCancelDirectSaveResetAndRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        func open() {
            XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
            app.buttons["navigationMore"].tap(); app.buttons["Settings"].tap(); app.buttons["prefScreenDownloads"].tap()
            let row = app.buttons["prefProxy"]
            for _ in 0..<5 where !row.isHittable { app.scrollViews["libraryContent"].swipeUp() }
            XCTAssertTrue(row.isHittable); row.tap()
            XCTAssertTrue(app.buttons["proxyType"].waitForExistence(timeout: 5))
        }
        open()
        XCTAssertFalse(app.textFields["proxyHost"].isEnabled)
        XCTAssertEqual(app.buttons["proxyConfirm"].label, "OK")
        app.buttons["proxyType"].tap()
        XCTAssertTrue(app.buttons["proxyType-HTTP"].waitForExistence(timeout: 5))
        app.buttons["proxyType-HTTP"].tap()
        let host = app.textFields["proxyHost"]
        XCTAssertTrue(host.isEnabled); host.tap(); host.typeTextSettled("localhost")
        app.textFields["proxyPort"].tap(); app.textFields["proxyPort"].typeTextSettled("8080")
        // Type selection dismisses the keyboard without losing entered fields.
        app.buttons["proxyType"].tapWhenSettled()
        // On iPad the port field's floating number pad is a popover: the first tap outside only closes it.
        if !app.buttons["proxyType-DIRECT"].waitForExistence(timeout: 2) { app.buttons["proxyType"].tapWhenSettled() }
        XCTAssertTrue(app.buttons["proxyType-DIRECT"].waitForExistence(timeout: 5), app.debugDescription); app.buttons["proxyType-DIRECT"].tap()
        XCTAssertEqual(app.buttons["proxyConfirm"].label, "OK")
        XCTAssertFalse(app.buttons["proxyReset"].exists)
        app.buttons["proxyConfirm"].tap()
        app.terminate(); app.launch(); open()
        XCTAssertEqual(host.value as? String, "localhost")
        XCTAssertEqual(app.textFields["proxyPort"].value as? String, "8080")
        app.buttons["proxyType"].tap(); app.buttons["proxyType-HTTP"].tap()
        app.buttons["proxyReset"].tap()
        XCTAssertEqual(host.value as? String, "Host")
        app.buttons["proxyConfirm"].tap()
        XCTAssertTrue(app.buttons["proxyHostError"].waitForExistence(timeout: 5))
        app.buttons["proxyHostError"].tap()
        app.buttons["proxyCancel"].tap()
        app.terminate(); app.launch(); open()
        XCTAssertTrue(host.isEnabled)
        XCTAssertEqual(app.buttons["proxyType"].value as? String, "HTTP")
        XCTAssertEqual(host.value as? String, "Host")
        XCTAssertEqual(app.buttons["proxyConfirm"].label, "Test")
        app.buttons["proxyType"].tapWhenSettled()
        // On iPad the port field's floating number pad is a popover: the first tap outside only closes it.
        if !app.buttons["proxyType-DIRECT"].waitForExistence(timeout: 2) { app.buttons["proxyType"].tapWhenSettled() }
        XCTAssertTrue(app.buttons["proxyType-DIRECT"].waitForExistence(timeout: 5), app.debugDescription); app.buttons["proxyType-DIRECT"].tap(); app.buttons["proxyConfirm"].tap()
    }
}
