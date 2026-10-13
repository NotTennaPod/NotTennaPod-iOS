import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testUsageSuggestionInterceptsActionsAndPreservesChoices() throws {
        continueAfterFailure = false
        for history in ["stream", "download"] {
            let app = XCUIApplication()
            app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback", "-test-usage-history", history]
            app.launch()
            XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
            app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
            let address = app.textFields["rssAddress"]
            XCTAssertTrue(address.waitForExistence(timeout: 3))
            address.tap(); address.typeTextSettled("http://127.0.0.1:18765/episode-header.xml"); app.buttons["Confirm"].tapWhenSettled()
            XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 35)); app.buttons["subscribeFeed"].tap()
            XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5)); app.buttons["episode-1"].tap()
            let primary = app.buttons["episodePrimaryAction"], secondary = app.buttons["episodeSecondaryAction"]
            let notes = app.webViews["episodeShownotes"]
            XCTAssertTrue(notes.links["0:15"].waitForExistence(timeout: 10))
            let notesY = notes.frame.minY
            func label(_ element: XCUIElement, _ expected: String, timeout: TimeInterval = 10) {
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: element)], timeout: timeout), .completed)
            }
            let message = app.staticTexts["usageSuggestionMessage"]
            if history == "stream" {
                primary.tap(); label(primary, "Pause")
                XCTAssertFalse(message.exists)
                primary.tap(); label(primary, "Stream")
            } else {
                secondary.tap(); label(secondary, "Delete", timeout: 25)
                XCTAssertFalse(message.exists)
                secondary.tap(); label(secondary, "Download")
            }
            let action = history == "stream" ? primary : secondary
            let anchorBottom = primary.frame.maxY
            action.tap()
            XCTAssertTrue(message.waitForExistence(timeout: 5))
            XCTAssertEqual(message.label, history == "stream"
                ? "Looks like you stream a lot. Do you want episode lists to show stream buttons?"
                : "Looks like you download a lot. Do you want episode lists to show download buttons?")
            let yes = app.buttons["usageSuggestion-yes"], no = app.buttons["usageSuggestion-no"]
            XCTAssertTrue(yes.isHittable && no.isHittable)
            XCTAssertLessThan(no.frame.maxX, yes.frame.maxX)
            XCTAssertGreaterThanOrEqual(message.frame.minY, anchorBottom - 1) // Shown below the action buttons.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: message)], timeout: 5), .completed)
            XCTAssertEqual(primary.label, "Stream"); XCTAssertEqual(secondary.label, "Download")
            action.tap(); XCTAssertTrue(message.waitForExistence(timeout: 5))
            // Escape can't be delivered by iOS 27.1 XCUITest; UsageSuggestionViewTests covers the
            // Escape command; a real keyboard needs a check on a device. Dismiss outside instead.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: message)], timeout: 5), .completed)
            XCTAssertTrue(primary.exists && notes.links["0:15"].exists)
            action.tap(); XCTAssertTrue(message.waitForExistence(timeout: 5))
            if history == "stream" {
                yes.tap()
                XCTAssertTrue(app.staticTexts["Setting updated successfully."].waitForExistence(timeout: 5))
                XCTAssertEqual(primary.label, "Stream") // The intercepted tap did not resume playback.
                XCTAssertEqual(notes.frame.minY, notesY, accuracy: 2)
                app.buttons["toolbarBack"].tap()
                let row = app.buttons["episode-action-1"]
                XCTAssertTrue(row.waitForExistence(timeout: 5)); label(row, "Stream")
            } else {
                no.tap()
                XCTAssertEqual(secondary.label, "Download") // No must not enqueue the intercepted action.
                XCTAssertEqual(notes.frame.minY, notesY, accuracy: 2)
                secondary.tap(); label(secondary, "Delete", timeout: 25)
                XCTAssertFalse(message.exists)
            }
            app.terminate()
        }
    }

    @MainActor
    func testEpisodeHeaderActionsAndTextOnlySlots() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 3))
        address.tap(); address.typeTextSettled("http://127.0.0.1:18765/episode-header.xml"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 35)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5)); app.buttons["episode-1"].tap()
        let primary = app.buttons["episodePrimaryAction"], secondary = app.buttons["episodeSecondaryAction"]
        let title = app.staticTexts["episodeTitle"], cover = app.buttons["episodeCover"]
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        XCTAssertEqual(primary.label, "Stream"); XCTAssertEqual(secondary.label, "Download")
        // Artwork leads the title; Stream and Download share one row as equal halves.
        XCTAssertLessThanOrEqual(cover.frame.maxX, title.frame.minX)
        XCTAssertLessThanOrEqual(primary.frame.maxX, secondary.frame.minX + 1)
        XCTAssertEqual(primary.frame.width, secondary.frame.width, accuracy: 2)
        XCTAssertEqual(primary.frame.midY, secondary.frame.midY, accuracy: 2)
        XCTAssertEqual(app.staticTexts["episodeDuration"].label, "0\u{00a0}minutes")
        let notes = app.webViews["episodeShownotes"]
        XCTAssertTrue(notes.links["0:15"].waitForExistence(timeout: 10))
        let originalNotesTop = notes.frame.minY
        secondary.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Delete"), object: secondary)], timeout: 25), .completed)
        XCTAssertEqual(primary.label, "Play")
        XCTAssertEqual(notes.frame.minY, originalNotesTop, accuracy: 2)
        primary.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pause"), object: primary)], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 5))
        primary.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: primary)], timeout: 5), .completed)
        notes.links["0:15"].tap()
        app.buttons["miniPlayerOpen"].tap()
        XCTAssertEqual(app.staticTexts["playerPosition"].label, "00:00:15")
        XCTAssertEqual(app.buttons["playerPlay"].label, "Play")
        app.buttons["playerCollapse"].tap()
        secondary.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Download"), object: secondary)], timeout: 10), .completed)
        XCTAssertEqual(primary.label, "Stream"); XCTAssertFalse(app.buttons["miniPlayerOpen"].exists)
        XCTAssertEqual(notes.frame.minY, originalNotesTop, accuracy: 2)
        XCTAssertTrue(notes.links["0:15"].exists)
        cover.tap()
        XCTAssertTrue(app.buttons["episode-2"].waitForExistence(timeout: 5))
        app.buttons["toolbarBack"].tap(); XCTAssertTrue(primary.waitForExistence(timeout: 5))
        app.buttons["toolbarBack"].tap(); app.buttons["episode-2"].tap()
        XCTAssertTrue(app.staticTexts["episodeNoMedia"].waitForExistence(timeout: 5))
        XCTAssertEqual(primary.label, "Mark as read")
        XCTAssertFalse(secondary.exists)
        let readNotesTop = notes.frame.minY
        primary.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: primary)], timeout: 5), .completed)
        XCTAssertEqual(notes.frame.minY, readNotesTop, accuracy: 2)
    }

    @MainActor
    func testShownotesFormattingLinksAndSeeking() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 3))
        address.tap(); address.typeTextSettled("http://127.0.0.1:18765/shownotes.xml"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 35)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["episode-2"].waitForExistence(timeout: 5)); app.buttons["episode-2"].tap()
        let notes = app.webViews["episodeShownotes"]
        let welcome = notes.staticTexts["Welcome to the shownotes lab."]
        XCTAssertTrue(welcome.waitForExistence(timeout: 10))
        // A desktop viewport regresses 16px text to ~6px on this phone. These
        // bounds detect that regression; the screenshot checks actual typography.
        XCTAssertGreaterThanOrEqual(welcome.frame.height, 16)
        XCTAssertLessThanOrEqual(welcome.frame.height, 24)
        XCTAssertGreaterThanOrEqual(welcome.frame.minX, notes.frame.minX + 24)
        XCTAssertFalse(notes.staticTexts["SCRIPT EXECUTED"].exists)
        XCTAssertTrue(notes.links["0:05"].exists); XCTAssertTrue(notes.links["0:15"].exists)
        XCTAssertFalse(notes.links["0:30"].exists)
        XCTAssertTrue(notes.links["www.example.org"].exists)
        notes.links["0:05"].tap()
        XCTAssertTrue(app.staticTexts["To jump to positions, you need to play the episode"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["miniPlayerOpen"].exists)
        notes.links["Explicit website"].tap()
        let browser = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "state == %d", XCUIApplication.State.runningForeground.rawValue), object: browser)], timeout: 15), .completed)
        app.activate()
        XCTAssertTrue(notes.links["0:05"].waitForExistence(timeout: 5))
        app.buttons["toolbarBack"].tap()
        let action = app.buttons["episode-action-2"]
        XCTAssertTrue(action.waitForExistence(timeout: 5)); action.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: action)], timeout: 25), .completed)
        action.tap()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 10)); app.buttons["miniPlayerOpen"].tap()
        let position = app.staticTexts["playerPosition"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "00:00:00"), object: position)], timeout: 10), .completed)
        app.buttons["playerPlay"].tap(); app.buttons["playerShownotes"].tap()
        let playerNotes = app.webViews["playerShownotesContent"]
        XCTAssertTrue(playerNotes.links["0:15"].waitForExistence(timeout: 5)); playerNotes.links["0:15"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "00:00:15"), object: position)], timeout: 5), .completed)
        XCTAssertEqual(app.buttons["playerPlay"].label, "Play")
        app.buttons["playerCollapse"].tap(); app.buttons["episode-2"].tap()
        XCTAssertTrue(notes.links["0:05"].waitForExistence(timeout: 5)); notes.links["0:05"].tap()
        app.buttons["miniPlayerOpen"].tap()
        XCTAssertEqual(position.label, "00:00:05"); XCTAssertEqual(app.buttons["playerPlay"].label, "Play")
        app.buttons["playerCollapse"].tap(); app.buttons["toolbarBack"].tap(); app.buttons["episode-1"].tap()
        let empty = app.webViews["episodeShownotes"].staticTexts["This episode has no shownotes."]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        let emptyNotes = app.webViews["episodeShownotes"]
        XCTAssertEqual(empty.frame.midX, emptyNotes.frame.midX, accuracy: 4) // Centered in the notes area.
        XCTAssertTrue(emptyNotes.frame.contains(empty.frame))
    }

    @MainActor
    func testEpisodeMenuStateNavigationBrowserAndReset() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 3))
        address.tap(); address.typeTextSettled("http://127.0.0.1:18765/feed.xml"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 35)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5)); app.buttons["episode-1"].tap()

        func openMenu(_ item: String) {
            XCTAssertTrue(app.buttons["episodeMore"].waitForExistence(timeout: 5))
            app.buttons["episodeMore"].tap()
            XCTAssertTrue(app.buttons[item].waitForExistence(timeout: 5))
        }
        let website = app.buttons["episodeWebsite"]
        XCTAssertTrue(website.waitForExistence(timeout: 5))
        // Website sits directly before the overflow button.
        XCTAssertLessThanOrEqual(website.frame.maxX, app.buttons["episodeMore"].frame.minX + 1)
        XCTAssertLessThan(app.buttons["episodeMore"].frame.minX - website.frame.maxX, 8)
        website.tap()
        let browser = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate:
            NSPredicate(format: "state == %d", XCUIApplication.State.runningForeground.rawValue), object: browser)], timeout: 15), .completed)
        app.activate()
        openMenu("markPlayed")
        let panel = app.scrollViews["episodeMenuPanel"]
        // The popup and toolbar share the scene's safe shell surface. Window
        // edges can extend beyond it on a device with asymmetric safe areas.
        let toolbar = app.otherElements["mainToolbar"]
        XCTAssertTrue(toolbar.exists)
        XCTAssertEqual(panel.frame.maxX, toolbar.frame.maxX, accuracy: 12) // Opens at the toolbar's end.
        XCTAssertGreaterThanOrEqual(app.buttons["markPlayed"].frame.height, 44) // Comfortable touch target.
        XCTAssertLessThan(app.buttons["markPlayed"].frame.minY, app.buttons["addToQueue"].frame.minY)
        XCTAssertLessThan(app.buttons["openPodcast"].frame.minY, app.buttons["addFavorite"].frame.minY)
        app.buttons["markPlayed"].tap()
        openMenu("markUnplayed"); XCTAssertFalse(app.buttons["markPlayed"].exists); app.buttons["markUnplayed"].tap()
        openMenu("addFavorite"); app.buttons["addFavorite"].tap()
        app.buttons["navigationMore"].tap(); app.buttons["Favorites"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["episode-2"].exists)
        app.buttons["episode-1"].tap()
        openMenu("openPodcast"); app.buttons["openPodcast"].tap()
        XCTAssertTrue(app.buttons["episode-2"].waitForExistence(timeout: 5))
        app.buttons["toolbarBack"].tap()
        XCTAssertTrue(app.buttons["episodeMore"].waitForExistence(timeout: 5)) // Back returns to the episode.
        app.buttons["toolbarBack"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["episode-2"].exists)
        app.navigation("Subscriptions").tap(); app.listeningLabSubscription.tap()
        let action = app.buttons["episode-action-1"]
        XCTAssertTrue(action.waitForExistence(timeout: 5)); action.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: action)], timeout: 25), .completed)
        action.tap()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 10)); app.buttons["miniPlayerOpen"].tap()
        let position = app.staticTexts["playerPosition"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "00:00:00"), object: position)], timeout: 10), .completed)
        app.buttons["playerPlay"].tap(); app.buttons["playerCollapse"].tap()
        app.buttons["episode-1"].tap()
        openMenu("resetPosition"); XCTAssertTrue(app.buttons["removeFavorite"].exists)
        app.buttons["resetPosition"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["miniPlayerPlay"])], timeout: 5), .completed)
        openMenu("markPlayed")
        XCTAssertFalse(app.buttons["resetPosition"].exists); XCTAssertTrue(app.buttons["removeFromQueue"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
        XCTAssertFalse(panel.exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.navigation("Queue").waitForExistence(timeout: 10)); app.navigation("Queue").tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5)); app.buttons["episode-1"].tap()
        openMenu("markPlayed")
        XCTAssertFalse(app.buttons["resetPosition"].exists); XCTAssertTrue(app.buttons["removeFavorite"].exists)
        XCTAssertFalse(app.buttons["miniPlayerPlay"].exists)
    }

    @MainActor
    func testToolbarGeometryAndDrawerDuringPlayback() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        let toolbar = app.otherElements["mainToolbar"]
        XCTAssertTrue(toolbar.exists)
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]; XCTAssertTrue(address.waitForExistence(timeout: 3))
        address.tap(); address.typeTextSettled("http://127.0.0.1:18765/feed.xml"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 35)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 5)); app.buttons["episode-1"].tap()
        let back = app.buttons["toolbarBack"], more = app.buttons["episodeMore"]
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        // Back at the leading end and overflow at the trailing end, both inside the toolbar.
        XCTAssertTrue(back.isHittable && more.isHittable)
        XCTAssertTrue(toolbar.frame.contains(CGPoint(x: back.frame.midX, y: back.frame.midY)))
        XCTAssertTrue(toolbar.frame.contains(CGPoint(x: more.frame.midX, y: more.frame.midY)))
        XCTAssertLessThan(back.frame.midX, toolbar.frame.midX)
        XCTAssertGreaterThan(more.frame.midX, toolbar.frame.midX)
        XCTAssertLessThanOrEqual(more.frame.maxX, toolbar.frame.maxX + 1)
        back.tap()
        let action = app.buttons["episode-action-1"]
        XCTAssertTrue(action.waitForExistence(timeout: 3)); action.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: action)], timeout: 20), .completed)
        action.tap()
        let mini = app.buttons["miniPlayerPlay"]
        XCTAssertTrue(mini.waitForExistence(timeout: 10))
        XCTAssertEqual(mini.label, "Pause"); mini.tap()
        app.buttons["navigationMore"].tap(); app.buttons["Settings"].tap(); app.buttons["prefScreenInterface"].tap()
        let bottom = app.buttons["prefBottomNavigation"]
        for _ in 0..<6 where !bottom.isHittable { app.swipeUp() }
        bottom.tap(); XCTAssertTrue(app.buttons["sourceMessageOK"].waitForExistence(timeout: 3)); app.buttons["sourceMessageOK"].tap()
        app.terminate(); app.launch()
        let persistent = hasPersistentDrawer(app)
        XCTAssertTrue(app.buttons[persistent ? "drawer-HomeFragment" : "openDrawer"].waitForExistence(timeout: 10))
        XCTAssertTrue(mini.waitForExistence(timeout: 10)); mini.tap()
        app.buttons["miniPlayerOpen"].tap()
        let position = app.staticTexts["playerPosition"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "00:00:00"), object: position)], timeout: 10), .completed)
        XCTAssertEqual(app.buttons["playerPlay"].label, "Pause")
        app.buttons["playerCollapse"].tap()
        XCTAssertEqual(mini.label, "Pause")
        let home = app.buttons["drawer-HomeFragment"]
        if persistent {
            XCTAssertTrue(home.isHittable && mini.isHittable) // The permanent drawer and the player coexist.
        } else {
            app.buttons["openDrawer"].tap()
            XCTAssertTrue(home.waitForExistence(timeout: 3))
            waitForOpenDrawer(app)
            app.closeDrawerByScrim()
        }
        XCTAssertEqual(mini.label, "Pause") // Opening the drawer preserves playback intent.
        mini.tap()
    }

    @MainActor
    func testPreferredStreamingCancelOnceAlwaysAndRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback", "-test-restricted-streaming"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]; XCTAssertTrue(address.waitForExistence(timeout: 3))
        address.tap(); address.typeTextSettled("http://127.0.0.1:18765/feed.xml"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 35)); app.buttons["subscribeFeed"].tap()
        let action = app.buttons["episode-action-2"]
        XCTAssertTrue(action.waitForExistence(timeout: 5)); XCTAssertEqual(action.label, "Download")
        app.buttons["navigationMore"].tap(); app.buttons["Settings"].tap(); app.buttons["prefScreenInterface"].tap()
        let preference = app.buttons["prefStreamOverDownload"]
        for _ in 0..<10 where !preference.isHittable { app.swipeUp() }
        XCTAssertTrue(preference.isHittable); XCTAssertEqual(preference.value as? String, "Off")
        preference.tap(); XCTAssertEqual(preference.value as? String, "On")
        app.buttons["Back"].tap(); app.buttons["Back"].tap()
        XCTAssertEqual(action.label, "Stream")
        action.tap()
        let message = app.staticTexts["sourceMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertEqual(message.label, "Streaming over mobile data connection is disabled in the settings. Tap to stream anyway.")
        XCTAssertEqual(app.staticTexts["sourceMessageTitle"].label, "Stream")
        let cancel = app.buttons["streamingCancel"], always = app.buttons["streamingAlways"], once = app.buttons["streamingOnce"]
        XCTAssertEqual(cancel.label, "Cancel"); XCTAssertEqual(always.label, "Always"); XCTAssertEqual(once.label, "Once")
        XCTAssertLessThan(cancel.frame.maxX, always.frame.minX)
        XCTAssertLessThan(always.frame.maxX, once.frame.minX)
        XCTAssertEqual(cancel.frame.midY, once.frame.midY, accuracy: 4)
        cancel.tap(); XCTAssertTrue(message.waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.buttons["miniPlayerPlay"].exists)
        app.navigation("Queue").tap()
        XCTAssertTrue(app.staticTexts["No queued episodes"].waitForExistence(timeout: 3))
        app.navigation("Subscriptions").tap(); app.listeningLabSubscription.tap()
        XCTAssertEqual(action.label, "Stream"); action.tap()
        XCTAssertTrue(once.waitForExistence(timeout: 5)); once.tap()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 10))
        app.buttons["miniPlayerOpen"].tap()
        let position = app.staticTexts["playerPosition"]
        XCTAssertTrue(position.waitForExistence(timeout: 3))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "00:00:00"), object: position)], timeout: 10), .completed)
        XCTAssertEqual(app.buttons["playerPlay"].label, "Pause"); app.buttons["playerPlay"].tap()
        let savedPosition = position.label
        XCTAssertNotEqual(savedPosition, "00:00:00")
        app.buttons["playerCollapse"].tap()
        XCTAssertEqual(action.label, "Stream") // Still remote; Once did not download it.
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["miniPlayerPlay"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["miniPlayerPlay"].label, "Play")
        app.buttons["miniPlayerOpen"].tap(); XCTAssertEqual(position.label, savedPosition)
        app.buttons["playerCollapse"].tap(); app.buttons["miniPlayerPlay"].tap()
        XCTAssertTrue(message.waitForExistence(timeout: 5)) // Once did not persist mobile permission.
        cancel.tap(); XCTAssertTrue(message.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.buttons["miniPlayerPlay"].label, "Play")
        app.buttons["miniPlayerPlay"].tap(); XCTAssertTrue(message.waitForExistence(timeout: 5))
        // Outside dismissal also retains the pending request and saved mini player.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        XCTAssertTrue(message.waitForNonExistence(timeout: 3))
        app.buttons["miniPlayerPlay"].tap(); XCTAssertTrue(always.waitForExistence(timeout: 5)); always.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pause"), object: app.buttons["miniPlayerPlay"])], timeout: 10), .completed)
        app.buttons["miniPlayerPlay"].tap()
        app.navigation("Queue").tap()
        XCTAssertTrue(app.buttons["episode-2"].waitForExistence(timeout: 3)); XCTAssertFalse(app.buttons["episode-1"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["miniPlayerPlay"].waitForExistence(timeout: 10))
        app.buttons["miniPlayerPlay"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pause"), object: app.buttons["miniPlayerPlay"])], timeout: 10), .completed)
        XCTAssertFalse(message.exists)
        app.buttons["miniPlayerOpen"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "00:00:00"), object: position)], timeout: 10), .completed)
        app.buttons["playerPlay"].tap(); app.buttons["playerCollapse"].tap()
    }

    @MainActor
    func testPlaybackErrorShowsGuidanceAndOnlyOKCollapsesPlayer() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]; XCTAssertTrue(address.waitForExistence(timeout: 3))
        address.tap(); address.typeTextSettled("http://127.0.0.1:18765/feed.xml"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 35)); app.buttons["subscribeFeed"].tap()
        let action = app.buttons["episode-action-1"]
        XCTAssertTrue(action.waitForExistence(timeout: 5)); action.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: action)], timeout: 25), .completed)
        action.tap()
        let pause = app.buttons["miniPlayerPlay"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pause"), object: pause)], timeout: 10), .completed)
        pause.tap()
        app.terminate()
        app.launchArguments.append("-test-missing-local-media")
        app.launch()
        XCTAssertTrue(app.buttons["miniPlayerPlay"].waitForExistence(timeout: 10))
        app.buttons["miniPlayerPlay"].tap()
        let message = app.staticTexts["sourceMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        let guidance = "The media file could not be played.\n\n- Try deleting and re-downloading the episode.\n- Check your network connection, and make sure no VPN or login page is blocking access.\n- Try long-pressing and sharing the \"Media address\" to your web browser to see if it can be played there. If not, contact the podcast creators."
        XCTAssertTrue(message.label.hasPrefix(guidance + "\n\n"))
        XCTAssertGreaterThan(message.label.count, guidance.count + 2)
        XCTAssertEqual(app.staticTexts["sourceMessageTitle"].label, "Error")
        app.buttons["sourceMessageOK"].tap()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 3))
        app.buttons["miniPlayerOpen"].tap()
        XCTAssertTrue(app.buttons["playerPlay"].waitForExistence(timeout: 3))
        app.buttons["playerPlay"].tap()
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        XCTAssertTrue(message.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["playerPlay"].isHittable)
        app.buttons["playerPlay"].tap()
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        app.buttons["sourceMessageOK"].tap()
        XCTAssertTrue(message.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["miniPlayerOpen"].isHittable)
        XCTAssertFalse(app.buttons["playerPlay"].isHittable)
        XCTAssertEqual(app.buttons["miniPlayerPlay"].label, "Play")
        // The real downloaded file remains valid; clearing only the test source override
        // allows the retained episode to prepare again without another subscription/download.
        app.terminate(); app.launchArguments.removeAll { $0 == "-test-missing-local-media" }; app.launch()
        XCTAssertTrue(app.buttons["miniPlayerPlay"].waitForExistence(timeout: 10))
        XCTAssertFalse(message.exists)
        app.buttons["miniPlayerPlay"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pause"), object: app.buttons["miniPlayerPlay"])], timeout: 10), .completed)
        app.buttons["miniPlayerPlay"].tap()
    }

    @MainActor
    func testCleanLaunchAndRSSNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        for label in ["Home", "Queue", "Inbox", "Subscriptions", "More"] {
            XCTAssertTrue(app.buttons[label].exists)
        }
        app.buttons["navigationMore"].tap()
        XCTAssertTrue(app.buttons["Customize navigation"].waitForExistence(timeout: 3))
        app.buttons["Add podcast"].tap()
        app.buttons["addRSS"].tap()
        XCTAssertTrue(app.textFields["rssAddress"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["addRSS"].exists)
    }

    @MainActor
    func testPlaybackSpeedPresetEditingSelectionAndRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]; XCTAssertTrue(address.waitForExistence(timeout: 3))
        address.tap(); address.typeTextSettled("http://127.0.0.1:18765/feed.xml"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 35)); app.buttons["subscribeFeed"].tap()
        let action = app.buttons["episode-action-1"]
        XCTAssertTrue(action.waitForExistence(timeout: 5)); action.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: action)], timeout: 25), .completed)
        action.tap()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 10))
        let pause = app.buttons["miniPlayerPlay"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pause"), object: pause)], timeout: 10), .completed)
        pause.tap(); app.buttons["miniPlayerOpen"].tap()
        XCTAssertTrue(app.buttons["playerSpeed"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["playerSpeedValue"].label, "1.00")
        app.buttons["playerSpeed"].tap()
        let add = app.buttons["speedAddPreset"]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        XCTAssertEqual(add.value as? String, "1.00")
        XCTAssertTrue(app.buttons["speedSkipSilence"].exists)
        let checkboxY = app.buttons["speedSkipSilence"].frame.minY
        app.buttons["speedIncrease"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1.05"), object: add)], timeout: 3), .completed)
        add.tap()
        XCTAssertTrue(app.buttons["speedPreset-3"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["speedPreset-1"].label, "1.05")
        XCTAssertEqual(app.buttons["speedSkipSilence"].frame.minY, checkboxY, accuracy: 1)
        add.tap()
        XCTAssertTrue(app.staticTexts["speedPresetDuplicate"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["speedPresetDuplicate"].label, "1.05x is already saved as a preset.")
        XCTAssertFalse(app.buttons["speedPreset-4"].exists)
        app.buttons["speedPreset-1"].press(forDuration: 0.7)
        XCTAssertFalse(app.buttons["speedPreset-3"].exists)
        XCTAssertEqual(add.value as? String, "1.05")
        XCTAssertEqual(app.buttons["speedPreset-1"].label, "1.25")
        app.buttons["speedPreset-2"].tap()
        XCTAssertTrue(add.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["playerSpeedValue"].label, "1.50")
        XCTAssertEqual(app.buttons["playerPlay"].label, "Play")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 10)); app.buttons["miniPlayerOpen"].tap()
        XCTAssertEqual(app.staticTexts["playerSpeedValue"].label, "1.50")
        XCTAssertEqual(app.buttons["playerPlay"].label, "Play")
        app.buttons["playerSpeed"].tap(); XCTAssertTrue(add.waitForExistence(timeout: 3))
        XCTAssertEqual(add.value as? String, "1.50")
        XCTAssertEqual(app.buttons["speedPreset-0"].label, "1.00")
        XCTAssertEqual(app.buttons["speedPreset-1"].label, "1.25")
        XCTAssertEqual(app.buttons["speedPreset-2"].label, "1.50")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        XCTAssertTrue(add.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testQueueInformationCountsDurationsAndSurvivesRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.navigation("Queue").tap()
        let information = app.staticTexts["queueInformation"]
        XCTAssertTrue(information.waitForExistence(timeout: 3))
        XCTAssertEqual(information.label, "0 episodes • 0\u{00a0}minutes left")
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]; XCTAssertTrue(address.waitForExistence(timeout: 3))
        address.tap(); address.typeTextSettled("http://127.0.0.1:18765/feed.xml"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 35)); app.buttons["subscribeFeed"].tap()
        for id in 1...2 {
            if id > 1 { app.navigation("Subscriptions").tap(); app.listeningLabSubscription.tap() }
            XCTAssertTrue(app.buttons["episode-\(id)"].waitForExistence(timeout: 3))
            app.buttons["episode-\(id)"].tap()
            XCTAssertFalse(information.exists)
            app.buttons["episodeMore"].tap(); app.buttons["addToQueue"].tap(); app.navigation("Queue").tap()
            XCTAssertTrue(information.waitForExistence(timeout: 3))
            XCTAssertEqual(information.label, id == 1 ? "1 episode • 0\u{00a0}minutes left" : "2 episodes • 1\u{00a0}minute left")
        }
        // The information line sits under the screen title and above the first episode.
        XCTAssertGreaterThan(information.frame.midY, app.staticTexts["screenTitle"].frame.midY)
        XCTAssertGreaterThanOrEqual(app.buttons["episode-1"].frame.minY, information.frame.maxY - 1)
        app.terminate(); app.launch(); app.navigation("Queue").tap()
        XCTAssertTrue(information.waitForExistence(timeout: 3))
        XCTAssertEqual(information.label, "2 episodes • 1\u{00a0}minute left")
        for id in 1...2 {
            app.buttons["episode-\(id)"].tap(); app.buttons["episodeMore"].tap()
            app.buttons["removeFromQueue"].tap(); app.navigation("Queue").tap()
            XCTAssertTrue(information.waitForExistence(timeout: 3))
            XCTAssertEqual(information.label, id == 1 ? "1 episode • 0\u{00a0}minutes left" : "0 episodes • 0\u{00a0}minutes left")
        }
    }

    @MainActor
    func testRSSSubscriptionAndQueueSurviveRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap()
        app.buttons["Add podcast"].tap()
        app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 3))
        address.tap()
        address.typeTextSettled("http://127.0.0.1:18765/feed.xml")
        app.buttons["Confirm"].tapWhenSettled()
        let subscribe = app.buttons["subscribeFeed"]
        XCTAssertTrue(subscribe.waitForExistence(timeout: 35))
        XCTAssertTrue(app.descendants(matching: .any)["Parity Listening Lab"].firstMatch.exists)
        subscribe.tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["episode-2"].exists)
        let rowValue = app.buttons["episode-1"].value as? String ?? ""
        XCTAssertTrue(rowValue.contains("120 kB"))
        XCTAssertTrue(rowValue.contains("00:00:30"))
        app.buttons["episode-1"].tap()
        app.buttons["episodeMore"].tap()
        app.buttons["addToQueue"].tap()
        app.navigation("Queue").tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["episode-2"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigation("Queue").waitForExistence(timeout: 10))
        app.navigation("Queue").tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 3))
        app.buttons["episode-1"].tap()
        app.buttons["episodeMore"].tap()
        app.buttons["removeFromQueue"].tap()
        app.navigation("Queue").tap()
        XCTAssertTrue(app.staticTexts["No queued episodes"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigation("Subscriptions").waitForExistence(timeout: 10))
        app.navigation("Subscriptions").tap()
        app.listeningLabSubscription.tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 3))
        app.buttons["episode-1"].tap()
        XCTAssertTrue(app.staticTexts["Second episode: queue and resume"].exists)
        app.buttons["Back"].tap()
        let action = app.buttons["episode-action-1"]
        XCTAssertTrue(action.waitForExistence(timeout: 3))
        XCTAssertEqual(action.label, "Download")
        action.tap()
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: action)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 20), .completed)
        app.navigation("Queue").tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["episode-2"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigation("Queue").waitForExistence(timeout: 10))
        app.navigation("Queue").tap()
        XCTAssertTrue(app.buttons["episode-action-1"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["episode-action-1"].label, "Play")
        app.buttons["navigationMore"].tap()
        app.navigation("Downloads").tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["episode-2"].exists)
        // Source CompletedDownloadsFragment: by default a downloaded row's action is Delete; play from the Queue.
        XCTAssertEqual(app.buttons["episode-action-1"].label, "Delete")
        app.navigation("Queue").tap()
        XCTAssertTrue(app.buttons["episode-action-1"].waitForExistence(timeout: 3))
        app.buttons["episode-action-1"].tap()
        let miniPlay = app.buttons["miniPlayerPlay"]
        XCTAssertTrue(miniPlay.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists, app.alerts.debugDescription)
        XCTAssertEqual(miniPlay.label, "Pause")
        XCTAssertEqual(app.buttons["episode-action-1"].label, "Pause")
        app.buttons["miniPlayerOpen"].tap()
        let playerPosition = app.staticTexts["playerPosition"]
        XCTAssertTrue(playerPosition.waitForExistence(timeout: 3))
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "00:00:00"), object: playerPosition)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 10), .completed)
        app.buttons["playerPlay"].tap()
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: app.buttons["playerPlay"])
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 5), .completed)
        // Force quit restores the saved pause, not subsequent paused seeks.
        // Observed on Android 3.12.1.
        let savedPosition = playerPosition.label
        let seek = app.descendants(matching: .any)["playerSeek"]
        XCTAssertTrue(seek.isHittable)
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let midpoint = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "00:00:15"), object: playerPosition)
        XCTAssertEqual(XCTWaiter.wait(for: [midpoint], timeout: 5), .completed)
        XCTAssertEqual(app.buttons["playerPlay"].label, "Play")
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: seek.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)))
        let beginning = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "00:00:00"), object: playerPosition)
        XCTAssertEqual(XCTWaiter.wait(for: [beginning], timeout: 5), .completed)
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let midpointAgain = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "00:00:15"), object: playerPosition)
        XCTAssertEqual(XCTWaiter.wait(for: [midpointAgain], timeout: 5), .completed)
        let playerDuration = app.buttons["playerDuration"]
        XCTAssertEqual(playerDuration.label, "Duration: 0\u{00a0}minutes")
        playerDuration.tap()
        XCTAssertEqual(playerDuration.label, "Remaining time: 0\u{00a0}minutes")
        XCTAssertEqual(playerPosition.label, "00:00:15")
        XCTAssertEqual(app.buttons["playerPlay"].label, "Play")
        playerDuration.tap()
        XCTAssertEqual(playerDuration.label, "Duration: 0\u{00a0}minutes")
        playerDuration.tap()
        XCTAssertEqual(playerDuration.label, "Remaining time: 0\u{00a0}minutes")
        XCTAssertTrue(app.navigation("Queue").isHittable)
        XCTAssertFalse(app.buttons["miniPlayerPlay"].exists)
        app.buttons["playerShownotes"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.webViews.firstMatch.isHittable)
        app.buttons["playerCollapse"].tap()
        XCTAssertTrue(miniPlay.waitForExistence(timeout: 3))
        XCTAssertEqual(miniPlay.label, "Play")
        app.buttons["miniPlayerOpen"].swipeUp()
        XCTAssertTrue(app.buttons["playerCollapse"].waitForExistence(timeout: 3))
        let collapse = app.buttons["playerCollapse"]
        // Start inside the control: swipeDown() used y=9 on Duo, at the system's top edge.
        collapse.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0,
            thenDragTo: collapse.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.3)),
            withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(miniPlay.waitForExistence(timeout: 3))
        // The cover page drags the player too, not only the toolbar (ViewPagerBottomSheetBehavior); an upward
        // drag there still turns to the show notes.
        let window = app.windows.firstMatch
        app.buttons["miniPlayerOpen"].swipeUp()
        XCTAssertTrue(app.buttons["playerCollapse"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.webViews.firstMatch.isHittable)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0,
            thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)),
            withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 3))
        let notesShown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: app.webViews.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [notesShown], timeout: 3), .completed, "an upward drag on the cover shows the notes")
        app.buttons["playerCollapse"].tapWhenSettled()
        XCTAssertTrue(miniPlay.waitForExistence(timeout: 3))
        app.buttons["miniPlayerOpen"].swipeUp()
        XCTAssertTrue(app.buttons["playerCollapse"].waitForExistence(timeout: 3))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 0,
            thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)),
            withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(miniPlay.waitForExistence(timeout: 3))
        app.terminate()
        app.launch()
        XCTAssertTrue(miniPlay.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(miniPlay.label, "Play")
        app.buttons["miniPlayerOpen"].tap()
        XCTAssertTrue(app.buttons["playerPlay"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["playerPlay"].label, "Play")
        XCTAssertEqual(playerPosition.label, savedPosition)
        XCTAssertEqual(playerDuration.label, "Remaining time: 0\u{00a0}minutes")
        app.buttons["playerCollapse"].tap()
        app.navigation("Queue").tap()
        let restoredRow = app.buttons["episode-1"]
        XCTAssertTrue(restoredRow.waitForExistence(timeout: 3))
        XCTAssertTrue((restoredRow.value as? String)?.contains("-00:00:") == true)
        app.navigation("Subscriptions").tap()
        app.listeningLabSubscription.tap()
        let unstartedRow = app.buttons["episode-2"]
        XCTAssertTrue(unstartedRow.waitForExistence(timeout: 3))
        XCTAssertTrue((unstartedRow.value as? String)?.contains("00:00:30") == true)
        XCTAssertFalse((unstartedRow.value as? String)?.contains("-00:00:") == true)
        XCTAssertTrue(app.buttons["episode-1"].exists)
        XCTAssertTrue((app.buttons["episode-1"].value as? String)?.contains("-00:00:") == true)

        // The same paused player remains owned across Settings and navigation modes.
        let bottomPlayerY = app.buttons["miniPlayerOpen"].frame.minY
        app.buttons["navigationMore"].tap()
        app.buttons["Settings"].tap()
        XCTAssertFalse(app.buttons["miniPlayerOpen"].exists)
        app.buttons["prefScreenInterface"].tap()
        let bottomNavigation = app.buttons["prefBottomNavigation"]
        for _ in 0..<6 where !bottomNavigation.isHittable { app.swipeUp() }
        XCTAssertEqual(bottomNavigation.value as? String, "On")
        bottomNavigation.tap()
        XCTAssertTrue(app.buttons["sourceMessageOK"].waitForExistence(timeout: 3))
        app.buttons["sourceMessageOK"].tap()
        app.buttons["Back"].tap(); app.buttons["Back"].tap()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["miniPlayerPlay"].label, "Play")
        // Without bottom navigation the mini player moves down to Android's bottom strip (the home-indicator inset,
        // at most 24 pt: 24 on an iPhone, 20 on an iPad), not to the screen edge.
        XCTAssertGreaterThan(app.buttons["miniPlayerOpen"].frame.minY, bottomPlayerY + 16)
        XCTAssertGreaterThanOrEqual(app.frame.maxY - app.buttons["miniPlayerOpen"].frame.maxY, 19)
        XCTAssertTrue(app.buttons["episode-1"].exists)
        app.buttons["miniPlayerOpen"].tap()
        XCTAssertEqual(playerPosition.label, savedPosition)
        XCTAssertEqual(playerDuration.label, "Remaining time: 0\u{00a0}minutes")
        app.buttons["playerCollapse"].tap()
        app.terminate(); app.launch()
        // Bottom navigation stays off after relaunch: phones open the drawer from the toolbar, tablets keep
        // Android's permanent drawer beside the content (no toolbar drawer button there).
        let persistent = hasPersistentDrawer(app)
        XCTAssertTrue(app.buttons[persistent ? "drawer-HomeFragment" : "openDrawer"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["navigationMore"].exists)
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["miniPlayerPlay"].label, "Play")
        if persistent { XCTAssertFalse(app.buttons["openDrawer"].exists) } else { app.buttons["openDrawer"].tap() }
        XCTAssertEqual(app.buttons["drawer-QueueFragment"].value as? String, "1")
        XCTAssertTrue(app.buttons["drawer-feed-1"].exists)
        waitForOpenDrawer(app)
        app.buttons["drawer-QueueFragment"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["miniPlayerPlay"].label, "Play")
    }
    /// Tablets (shortest side at least 720 pt) keep Android's permanent drawer beside the content;
    /// phones open a modal drawer from the toolbar menu or the edge.
    @MainActor private func hasPersistentDrawer(_ app: XCUIApplication) -> Bool {
        let frame = app.windows.firstMatch.frame
        return min(frame.width, frame.height) >= 720
    }

    @MainActor
    func testDrawerModeNavigationGesturesAndPersistence() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["prefScreenInterface"].waitForExistence(timeout: 3))
        app.buttons["prefScreenInterface"].tap()
        XCTAssertFalse(app.buttons["prefExpandNotify"].exists)
        XCTAssertFalse(app.buttons["prefPersistNotify"].exists)
        let bottom = app.buttons["prefBottomNavigation"]
        for _ in 0..<6 where !bottom.isHittable { app.swipeUp() }
        XCTAssertTrue(bottom.isHittable)
        XCTAssertEqual(bottom.value as? String, "On")
        let settingY = bottom.frame.minY
        bottom.tap()
        XCTAssertTrue(app.buttons["sourceMessageOK"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["sourceMessage"].label.contains("\n\n"))
        app.buttons["sourceMessageOK"].tap()
        XCTAssertEqual(bottom.value as? String, "Off")
        XCTAssertEqual(bottom.frame.minY, settingY, accuracy: 1)
        let backOpens = app.buttons["prefBackButtonOpensDrawer"]
        for _ in 0..<3 where !backOpens.isHittable { app.swipeUp() }
        XCTAssertTrue(backOpens.isEnabled)
        app.buttons["Back"].tap()
        app.buttons["Back"].tap()
        if hasPersistentDrawer(app) {
            let home = app.buttons["drawer-HomeFragment"], queue = app.buttons["drawer-QueueFragment"]
            XCTAssertTrue(home.waitForExistence(timeout: 3) && home.isSelected && queue.isHittable)
            XCTAssertFalse(app.buttons["openDrawer"].exists); XCTAssertFalse(app.buttons["navigationMore"].exists)
            XCTAssertGreaterThanOrEqual(queue.frame.minY, home.frame.maxY - 1) // Queue listed below Home.
            queue.tap()
            XCTAssertTrue(app.staticTexts["No queued episodes"].waitForExistence(timeout: 3)); XCTAssertTrue(queue.isSelected)
            app.terminate(); app.launch()
            XCTAssertTrue(queue.waitForExistence(timeout: 10)); XCTAssertFalse(app.buttons["navigationMore"].exists)
            app.buttons["drawerSettings"].tap(); app.buttons["prefScreenInterface"].tap()
            for _ in 0..<6 where !bottom.isHittable { app.swipeUp() }
            XCTAssertEqual(bottom.value as? String, "Off")
            bottom.tap(); XCTAssertEqual(bottom.value as? String, "On")
            app.buttons["Back"].tap(); app.buttons["Back"].tap()
            XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 3))
            XCTAssertFalse(queue.exists)
            return
        }
        let menu = app.buttons["openDrawer"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["navigationMore"].exists)
        menu.tap()
        let queue = app.buttons["drawer-QueueFragment"]
        XCTAssertTrue(queue.waitForExistence(timeout: 3))
        let home = app.buttons["drawer-HomeFragment"]
        XCTAssertTrue(home.isSelected)
        XCTAssertGreaterThanOrEqual(queue.frame.minY, home.frame.maxY - 1) // Queue listed below Home.
        XCTAssertGreaterThan(app.buttons["drawerSettings"].frame.minY, app.buttons["drawer-AddFeedFragment"].frame.maxY)
        waitForOpenDrawer(app)
        // Android default-page/13-original-home-retained: Settings is a separate
        // activity above the still-open drawer, including nested preference pages.
        app.buttons["drawerSettings"].tap()
        XCTAssertTrue(app.buttons["prefScreenInterface"].waitForExistence(timeout: 3))
        XCTAssertFalse(home.exists)
        app.buttons["prefScreenInterface"].tap()
        app.buttons["Back"].tap(); app.buttons["Back"].tap()
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        XCTAssertTrue(home.isSelected)
        XCTAssertTrue(home.isHittable)
        XCTAssertTrue(app.buttons["drawerSettings"].isHittable)
        queue.tap()
        XCTAssertTrue(app.staticTexts["No queued episodes"].waitForExistence(timeout: 3))
        menu.tap()
        XCTAssertTrue(queue.waitForExistence(timeout: 3))
        XCTAssertTrue(queue.isSelected)
        app.closeDrawerByScrim()
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
        let rotated = XCTWaiter.wait(for: [landscape], timeout: 5) == .completed
        if XCUIDevice.rotationResizesWindow { XCTAssertTrue(rotated) }
        XCTAssertTrue(app.staticTexts["No queued episodes"].exists)
        menu.tap()
        XCTAssertTrue(queue.waitForExistence(timeout: 3))
        // The landscape drawer does not cover the whole screen; content stays visible beside it.
        XCTAssertLessThan(queue.frame.maxX, app.frame.maxX - 56)
        XCTAssertTrue(queue.isSelected)
        app.closeDrawerByScrim()
        XCUIDevice.shared.orientation = .portrait
        let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.height > app.frame.width }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["No queued episodes"].waitForExistence(timeout: 3), app.debugDescription)
        // Start inside the source edge region; travel past half before release.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        XCTAssertTrue(queue.waitForExistence(timeout: 3))
        app.buttons["drawer-HomeFragment"].tap()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 3))
        app.terminate(); app.launch()
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["navigationMore"].exists)
        menu.tap()
        app.buttons["drawerSettings"].tap()
        app.buttons["prefScreenInterface"].tap()
        for _ in 0..<6 where !bottom.isHittable { app.swipeUp() }
        XCTAssertEqual(bottom.value as? String, "Off")
        bottom.tap()
        XCTAssertEqual(bottom.value as? String, "On")
        app.buttons["Back"].tap(); app.buttons["Back"].tap()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 3))
        XCTAssertFalse(menu.exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        XCTAssertFalse(menu.exists)
    }

    @MainActor
    func testNavigationCustomizationCancelConfirmResetAndDefaultPage() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        func openEditor() {
            app.buttons["navigationMore"].tap()
            app.buttons["Customize navigation"].tap()
            XCTAssertTrue(app.staticTexts["customizeTitle"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.staticTexts["customizeTitle"].label, "Drawer preferences")
        }
        func handle(_ tag: String) -> XCUIElement { app.descendants(matching: .any)["customize-handle-" + tag] }
        openEditor()
        XCTAssertTrue(app.staticTexts["customize-row-shown"].exists)
        XCTAssertTrue(app.staticTexts["customize-row-hidden"].exists)
        XCTAssertFalse(app.staticTexts["customize-row-SubscriptionList"].exists)
        handle("QueueFragment").press(forDuration: 0.1, thenDragTo: handle("HomeFragment"))
        XCTAssertLessThan(app.staticTexts["customize-row-QueueFragment"].frame.minY, app.staticTexts["customize-row-HomeFragment"].frame.minY)
        app.buttons["customizeCancel"].tap()
        XCTAssertLessThan(app.buttons["Home"].frame.minX, app.navigation("Queue").frame.minX)
        openEditor()
        XCTAssertLessThan(app.staticTexts["customize-row-HomeFragment"].frame.minY, app.staticTexts["customize-row-QueueFragment"].frame.minY)
        let list = app.collectionViews["customizeList"]
        let hiddenHeader = app.staticTexts["customize-row-hidden"]
        // Resolve an initially clipped destination before touching the handle;
        // XCUI's implicit target scroll otherwise interrupts the active drag.
        let reveal = max(0, hiddenHeader.frame.maxY - list.frame.maxY + 8)
        if reveal > 0 {
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.8))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -reveal)))
        }
        XCTAssertTrue(handle("HomeFragment").isHittable)
        XCTAssertTrue(list.frame.contains(hiddenHeader.frame))
        handle("HomeFragment").press(forDuration: 0.1, thenDragTo: hiddenHeader)
        XCTAssertGreaterThan(app.staticTexts["customize-row-HomeFragment"].frame.minY, app.staticTexts["customize-row-hidden"].frame.minY)
        app.buttons["customizeOK"].tap()
        XCTAssertFalse(app.buttons["Home"].exists)
        XCTAssertTrue(app.navigation("Queue").exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["No queued episodes"].waitForExistence(timeout: 10))
        openEditor()
        XCTAssertGreaterThan(app.staticTexts["customize-row-HomeFragment"].frame.minY, app.staticTexts["customize-row-hidden"].frame.minY)
        app.buttons["customizeReset"].tap()
        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 3))
        XCTAssertLessThan(app.buttons["Home"].frame.minX, app.navigation("Queue").frame.minX)
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["No queued episodes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Home"].exists)
    }

    @MainActor
    func testNavigationActionsScrollIndependentlyAtLargeText() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap()
        app.buttons["Customize navigation"].tap()
        XCTAssertTrue(app.staticTexts["customizeTitle"].waitForExistence(timeout: 3))
        let actions = app.scrollViews["customizeActions"]
        let ok = app.buttons["customizeOK"], reset = app.buttons["customizeReset"]
        XCTAssertTrue(actions.exists)
        XCTAssertGreaterThan(ok.frame.height, 48) // Require the requested text size.
        // Like Android's dialog button bar, the actions stack only when they don't fit side by side (phones).
        if !(reset.frame.minY > ok.frame.maxY) {
            XCTAssertFalse(reset.frame.intersects(ok.frame))
            XCTAssertTrue(ok.isHittable && reset.isHittable)
            reset.tap()
            XCTAssertTrue(app.staticTexts["customizeTitle"].waitForNonExistence(timeout: 3))
            return
        }
        // On a phone the stacked actions overflow and must scroll on their own; a tablet has room for them.
        if reset.frame.maxY <= actions.frame.maxY {
            XCTAssertTrue(actions.frame.contains(ok.frame) && actions.frame.contains(reset.frame) && reset.isHittable)
            reset.tap()
            XCTAssertTrue(app.staticTexts["customizeTitle"].waitForNonExistence(timeout: 3))
            return
        }
        let home = app.staticTexts["customize-row-HomeFragment"], before = home.frame
        let resetYBeforeSwipe = reset.frame.minY
        XCTAssertTrue(actions.frame.contains(ok.frame))
        let start = ok.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let travel = ok.frame.minY + ok.frame.height * 0.8 - actions.frame.minY - 5
        XCTAssertGreaterThan(travel, 30)
        start.press(forDuration: 0.25, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -travel)))
        XCTAssertLessThan(reset.frame.minY, resetYBeforeSwipe)
        XCTAssertLessThan(reset.frame.minY, actions.frame.maxY)
        XCTAssertTrue(app.staticTexts["customizeTitle"].exists) // The swipe did not activate an action.
        XCTAssertEqual(home.frame.minY, before.minY, accuracy: 1) // The list behind did not move.
        if !actions.frame.contains(reset.frame) { actions.swipeUp(velocity: .slow) }
        XCTAssertTrue(actions.frame.contains(reset.frame))
        XCTAssertTrue(reset.isHittable)
        reset.tap()
        XCTAssertTrue(app.staticTexts["customizeTitle"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["welcomeTitle"].exists)
    }

    @MainActor
    func testDefaultPageSelectionAndRememberedRootRoutes() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        func openInterface() {
            app.buttons["navigationMore"].tap(); app.buttons["Settings"].tap()
            app.buttons["prefScreenInterface"].tap()
        }
        func openChooser() {
            let preference = app.buttons["prefDefaultPage"]
            for _ in 0..<6 where !preference.isHittable { app.swipeUp() }
            XCTAssertTrue(preference.isHittable); preference.tap()
            XCTAssertTrue(app.staticTexts["defaultPageTitle"].waitForExistence(timeout: 3))
        }
        openInterface(); openChooser()
        let tags = ["HomeFragment", "QueueFragment", "NewEpisodesFragment", "EpisodesFragment", "SubscriptionFragment", "StatisticsFragment", "remember"]
        for tag in tags { XCTAssertTrue(app.buttons["defaultPage-" + tag].exists) }
        XCTAssertTrue(app.buttons["defaultPage-HomeFragment"].isSelected)
        app.buttons["defaultPageCancel"].tap()
        openChooser()
        XCTAssertTrue(app.buttons["defaultPage-HomeFragment"].isSelected)
        app.buttons["defaultPage-QueueFragment"].tap()
        XCTAssertFalse(app.staticTexts["defaultPageTitle"].exists)
        openChooser()
        XCTAssertTrue(app.buttons["defaultPage-QueueFragment"].isSelected)
        app.buttons["defaultPageCancel"].tap()
        app.buttons["Back"].tap(); app.buttons["Back"].tap()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].exists) // Picking default doesn't replace current page.
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["No queued episodes"].waitForExistence(timeout: 10))
        openInterface(); openChooser()
        app.buttons["defaultPage-remember"].tap()
        app.buttons["Back"].tap(); app.buttons["Back"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["No queued episodes"].waitForExistence(timeout: 10)) // Cold Queue launch recorded root.
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]; XCTAssertTrue(address.waitForExistence(timeout: 3))
        address.tap(); address.typeTextSettled("http://127.0.0.1:18765/feed.xml"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 35)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 10))
        app.navigation("Subscriptions").tap(); app.listeningLabSubscription.tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 3))
        app.terminate(); app.launch()
        XCTAssertTrue(app.listeningLabSubscription.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["episode-1"].exists) // Child feed didn't replace Subscriptions root.
        openInterface()
        let bottom = app.buttons["prefBottomNavigation"]
        for _ in 0..<6 where !bottom.isHittable { app.swipeUp() }
        bottom.tap(); XCTAssertTrue(app.buttons["sourceMessageOK"].waitForExistence(timeout: 3)); app.buttons["sourceMessageOK"].tap()
        app.buttons["Back"].tap(); app.buttons["Back"].tap()
        app.listeningLabSubscription.tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 3))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        XCTAssertTrue(app.buttons["drawer-SubscriptionFragment"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["drawer-SubscriptionFragment"].isSelected)
        XCTAssertFalse(app.buttons["drawer-feed-1"].isSelected)
        app.buttons["drawer-feed-1"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Back"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout: 10), app.debugDescription) // Drawer feed is a remembered root.
        XCTAssertTrue(app.buttons[hasPersistentDrawer(app) ? "drawer-feed-1" : "openDrawer"].exists)
        XCTAssertFalse(app.buttons["Back"].exists)
    }

    /// The drawer has finished sliding in: its first row is on screen and tappable.
    @MainActor private func waitForOpenDrawer(_ app: XCUIApplication) {
        let home = app.buttons["drawer-HomeFragment"]
        let open = NSPredicate { _, _ in home.isHittable && home.frame.minX >= 0 && home.frame.minX < 24 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: open, object: nil)], timeout: 3), .completed)
    }
}

extension XCUIApplication {
    /// The Parity Listening Lab tile on Subscriptions (a tablet's permanent drawer lists the feed too).
    var listeningLabSubscription: XCUIElement {
        buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'subscriptionFeed-' AND label CONTAINS 'Parity Listening Lab'")).firstMatch
    }
}

extension XCUIApplication {
    /// Taps the drawer's scrim beside the drawer. Relative to the scrim, so it stays right after rotation,
    /// where app-relative coordinates can land inside the drawer.
    func closeDrawerByScrim() {
        let scrim = otherElements["drawerScrim"]
        XCTAssertTrue(scrim.waitForExistence(timeout: 3), debugDescription)
        scrim.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        XCTAssertTrue(scrim.waitForNonExistence(timeout: 3), "The drawer closes")
    }
}
