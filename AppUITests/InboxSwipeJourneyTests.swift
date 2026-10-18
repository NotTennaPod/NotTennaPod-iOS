import XCTest

/// Authored selected-app journeys; execution needs a separately reserved device.
final class InboxSwipeJourneyTests: XCTestCase {
    @MainActor private func episodes(_ app: XCUIApplication) {
        if app.buttons["EpisodesFragment"].exists { app.buttons["EpisodesFragment"].tap() }
        else { app.buttons["navigationMore"].tap(); app.otherElements["morePopup"].buttons["Episodes"].tap() }
    }
    @MainActor private func row(_ title: String, _ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Swipe journey " + title)).firstMatch
    }
    @MainActor private func swipeLeftAcrossRow(_ row: XCUIElement) {
        XCTAssertTrue(row.exists && row.isHittable)
        XCTAssertGreaterThan(row.frame.width, 0); XCTAssertGreaterThan(row.frame.height, 0)
        // XCTest swipeLeft emitted only200pt on the834pt iPad row. A full
        // row-relative gesture must cross the unchanged first-use threshold.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)))
    }
    /// Set by the right-to-left variant; the app then launches with an Arabic RTL layout.
    private var requestsRTL = false

    @MainActor private func configuredApplication() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback", "-test-inbox-swipe-journey"]
        // On the verified runtime, AppleTextDirection alone leaves this English
        // bundle LTR. Both pseudolanguage defaults deliver native UIKit RTL;
        // the independent composition test must still verify the actual order.
        if requestsRTL { app.launchArguments += ["-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA",
            "-AppleTextDirection", "YES", "-NSForceRightToLeftWritingDirection", "YES"] }
        return app
    }

    @MainActor private func openEpisodes(_ app: XCUIApplication) {
        XCTAssertTrue(row("target", app).waitForExistence(timeout: 15)); episodes(app)
        XCTAssertTrue(row("target", app).waitForExistence(timeout: 5))
        XCTAssertTrue(row("survivor", app).exists)
    }

    @MainActor private func assertToolbarComposition(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists)
        let viewport = window.frame
        XCTAssertGreaterThan(viewport.width, 0); XCTAssertGreaterThan(viewport.height, 0)
        let search = app.buttons["allEpisodesSearch"], filter = app.buttons["allEpisodesFilter"]
        let more = app.buttons["allEpisodesMore"]
        for control in [search, filter, more, row("target", app), row("survivor", app)] {
            XCTAssertTrue(control.exists); XCTAssertTrue(control.isHittable)
            XCTAssertGreaterThan(control.frame.width, 0); XCTAssertGreaterThan(control.frame.height, 0)
            XCTAssertTrue(viewport.contains(control.frame), "Control must remain visible in the actual app window")
        }
        // Source episodes.xml orders Search, Filter, then overflow at the end.
        // Keep this independent RTL gate even when the gesture journey passes.
        if requestsRTL {
            XCTAssertGreaterThan(search.frame.midX, filter.frame.midX)
            XCTAssertGreaterThan(filter.frame.midX, more.frame.midX)
        } else {
            XCTAssertLessThan(search.frame.midX, filter.frame.midX)
            XCTAssertLessThan(filter.frame.midX, more.frame.midX)
        }
        XCTAssertFalse(search.frame.intersects(filter.frame)); XCTAssertFalse(filter.frame.intersects(more.frame))
        XCTAssertLessThanOrEqual(max(search.frame.maxY, filter.frame.maxY, more.frame.maxY), row("target", app).frame.minY)
    }

    @MainActor func testAllEpisodesToolbarCompositionAcrossRotation() { toolbarCompositionAcrossRotation() }
    @MainActor func testAllEpisodesToolbarCompositionAcrossRotationRightToLeft() {
        requestsRTL = true
        toolbarCompositionAcrossRotation()
    }
    @MainActor private func toolbarCompositionAcrossRotation() {
        continueAfterFailure = false
        let app = configuredApplication(), initialOrientation = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .portrait
        app.launch(); defer { app.terminate(); XCUIDevice.shared.orientation = initialOrientation }
        openEpisodes(app)
        assertToolbarComposition(app)
        let window = app.windows.firstMatch, beforeSize = window.frame.size
        XCUIDevice.shared.orientation = .landscapeLeft
        // A rotation request alone is not a resize. Check the actual scene;
        // a resized window need not have the physical display's aspect ratio.
        let resized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            window.exists && window.frame.width > 0 && window.frame.height > 0 && window.frame.size != beforeSize
        }, object: nil)
        if XCUIDevice.rotationResizesWindow { XCTAssertEqual(XCTWaiter.wait(for: [resized], timeout: 5), .completed) }
        assertToolbarComposition(app)
        app.buttons["allEpisodesFilter"].tap()
        XCTAssertTrue(app.buttons["feedFilterConfirm"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["feedFilterConfirm"].isHittable)
        app.buttons["feedFilterConfirm"].tap()
        XCTAssertTrue(app.buttons["feedFilterConfirm"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(row("target", app).exists && row("survivor", app).exists)
        let resizedSize = window.frame.size
        XCUIDevice.shared.orientation = .portrait
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            window.exists && window.frame.width > 0 && window.frame.height > 0 && window.frame.size != resizedSize
        }, object: nil)
        if XCUIDevice.rotationResizesWindow { XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed) }
        assertToolbarComposition(app)
    }

    @MainActor func testActualSwipeFirstUseCancelConfiguredRemoveUndoAndRelaunch() {
        continueAfterFailure = false
        let app = configuredApplication()
        app.launch(); defer { app.terminate() }
        openEpisodes(app)
        let target = row("target", app), survivor = row("survivor", app)
        // Toolbar RTL/resize diagnostics live in their own test. This outcome
        // proves physical-left behavior; it is RTL coverage only with that gate.
        swipeLeftAcrossRow(target)
        XCTAssertTrue(app.buttons["inboxSwipeCancel"].waitForExistence(timeout: 5))
        app.buttons["inboxSwipeCancel"].tap()
        XCTAssertTrue(app.buttons["inboxSwipeCancel"].waitForNonExistence(timeout: 5)); XCTAssertTrue(target.exists)
        swipeLeftAcrossRow(target)
        XCTAssertTrue(app.buttons["inboxSwipeChange-left"].waitForExistence(timeout: 5)); app.buttons["inboxSwipeChange-left"].tap()
        XCTAssertTrue(app.buttons["inboxSwipeChoice-REMOVE_FROM_INBOX"].waitForExistence(timeout: 5))
        app.buttons["inboxSwipeChoice-REMOVE_FROM_INBOX"].tap()
        XCTAssertTrue(app.buttons["inboxSwipeConfirm"].waitForExistence(timeout: 5))
        app.buttons["inboxSwipeConfirm"].tap()
        XCTAssertTrue(app.buttons["inboxSwipeConfirm"].waitForNonExistence(timeout: 5)); XCTAssertTrue(target.exists)
        swipeLeftAcrossRow(target)
        // Undo is offered for Android's LENGTH_LONG (2.75 s). On a slow Simulator every extra query costs
        // seconds, so tap it as soon as it appears; the row's removal while Undo shows is checked after the
        // relaunch below, and the survivor's presence right after.
        let undo = app.buttons["inboxSwipeUndo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 2)); undo.tap()
        XCTAssertTrue(target.waitForExistence(timeout: 5)); XCTAssertTrue(survivor.exists)
        app.terminate(); app.launch(); XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10)); episodes(app)
        XCTAssertTrue(target.waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["allEpisodesFiltered"].exists)
        swipeLeftAcrossRow(target)
        XCTAssertTrue(undo.waitForExistence(timeout: 2)); XCTAssertFalse(target.exists)
        XCTAssertFalse(app.buttons["inboxSwipeConfirm"].exists)
        XCTAssertTrue(undo.waitForNonExistence(timeout: 5))
        app.terminate(); app.launch(); XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10)); episodes(app)
        XCTAssertTrue(survivor.waitForExistence(timeout: 5)); XCTAssertFalse(target.exists)
        app.buttons["allEpisodesFilter"].tap()
        XCTAssertTrue(app.buttons["feedFilterReset"].waitForExistence(timeout: 5)); app.buttons["feedFilterReset"].tap()
        app.buttons["feedFilterConfirm"].tap()
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["allEpisodesFiltered"].exists)
    }
    @MainActor func testActualVoiceOverUndoFromControlledLiveOffer() throws {
        // VoiceOver is the scenario here: the test turns it on itself and restores it in teardown.
        continueAfterFailure = false
        let app = configuredApplication(), voiceOver = XCUIDevice.shared.voiceOverService
        app.launchArguments.append("-test-inbox-swipe-voiceover")
        let libraryID = app.launchArguments[1], initiallyEnabled = voiceOver.isEnabled
        print("VOICEOVER_UNDO_SESSION \(libraryID) baselineVoiceOver=\(initiallyEnabled)")
        // XCTest teardown also runs when a fatal assertion bypasses Swift defer.
        addTeardownBlock { @MainActor in
            if voiceOver.isEnabled != initiallyEnabled {
                if initiallyEnabled { try voiceOver.enable() } else { try voiceOver.disable() }
            }
            XCTAssertEqual(voiceOver.isEnabled, initiallyEnabled)
            print("VOICEOVER_UNDO_RESTORED \(libraryID) voiceOver=\(voiceOver.isEnabled)")
            app.terminate()
        }
        if initiallyEnabled { try voiceOver.disable() }
        app.launch(); openEpisodes(app)
        let target = row("target", app), survivor = row("survivor", app)
        // Only configuration is ordinary input. Offer creation below is labelled
        // controlled setup; the swipe journey above proves the physical-left gesture.
        swipeLeftAcrossRow(target)
        XCTAssertTrue(app.buttons["inboxSwipeChange-left"].waitForExistence(timeout: 5))
        app.buttons["inboxSwipeChange-left"].tap()
        app.buttons["inboxSwipeChoice-REMOVE_FROM_INBOX"].tap()
        app.buttons["inboxSwipeConfirm"].tap()
        XCTAssertTrue(app.buttons["inboxSwipeConfirm"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(target.exists && survivor.exists)
        try voiceOver.enable(); XCTAssertTrue(voiceOver.isEnabled)
        let initialSpeech = try voiceOver.currentSpeech().utterance
        XCTAssertFalse(initialSpeech.isEmpty)
        // The fixture now removes the target from the inbox through the real recipient, once.
        print("VOICEOVER_UNDO_READY \(libraryID)")
        let undo = app.buttons["inboxSwipeUndo"], message = app.staticTexts["Removed from inbox"]
        guard message.waitForExistence(timeout: 5) else {
            throw NSError(domain: "InboxSwipeAccessibilitySetup", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "No live message after VoiceOver-active controlled recipient admission"])
        }
        // Give a person time to reach an unvisited offer, beyond the unchanged
        // ordinary 2.75 s deadline: the unvisited offer must still be live.
        print("VOICEOVER_UNVISITED_START \(libraryID)")
        let prematureDismissal = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !undo.exists }, object: nil)
        prematureDismissal.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [prematureDismissal], timeout: 4), .completed)
        XCTAssertTrue(voiceOver.isEnabled && undo.exists)
        print("VOICEOVER_UNVISITED_END \(libraryID)")
        // With VoiceOver enabled, the documented single tap explores/selects.
        // No focus callback, announcement focus request or direct action is used.
        message.tap()
        let messageSpeech = try voiceOver.currentSpeech().utterance
        XCTAssertTrue(messageSpeech.contains("Removed from inbox"))
        let undoSpeech = try voiceOver.moveForward().utterance
        XCTAssertTrue(undoSpeech.contains("Undo"), "Actual message→Undo traversal must be delivered")
        XCTAssertTrue(voiceOver.isEnabled && undo.exists)
        XCTAssertFalse(target.exists); XCTAssertTrue(survivor.exists)
        print("VOICEOVER_UNDO_FOCUSED \(libraryID)")
        let vanished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !undo.exists }, object: nil)
        vanished.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [vanished], timeout: 4), .completed)
        let retainedSpeech = try voiceOver.currentSpeech().utterance
        XCTAssertTrue(retainedSpeech.contains("Undo"))
        XCTAssertTrue(voiceOver.isEnabled && undo.exists)
        // VoiceOver double-tap activates its selected control. The independent
        // probe must also show the same real offer/focus and exact saved result.
        undo.doubleTap()
        XCTAssertTrue(target.waitForExistence(timeout: 5)); XCTAssertTrue(survivor.exists)
        XCTAssertTrue(undo.waitForNonExistence(timeout: 5))
        print("VOICEOVER_UNDO_ACTIVATED \(libraryID)")
        try voiceOver.disable(); XCTAssertFalse(voiceOver.isEnabled)
        app.terminate(); app.launch(); openEpisodes(app)
        XCTAssertTrue(target.exists && survivor.exists)
        XCTAssertFalse(app.buttons["inboxSwipeUndo"].exists)
        XCTAssertTrue(app.buttons["allEpisodesFiltered"].exists)
        print("VOICEOVER_UNDO_RELAUNCHED \(libraryID)")
    }

}
