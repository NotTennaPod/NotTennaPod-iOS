import XCTest

/// OPML import through the real Files picker and Files app. The test pre-action seeds folder
/// `OPML-<library>` in "On My iPhone/iPad" (TestSupport/Media/files-provider); results are checked in the UI.
@MainActor final class OPMLImportJourneyTests: XCTestCase {
    private var app = XCUIApplication()
    override func setUp() { continueAfterFailure = false }
    private func tap(_ id: String) {
        let button = app.buttons[id]; XCTAssertTrue(button.waitForExistence(timeout: 15), id)
        // Menus animate in; wait until the control can actually be tapped.
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 5), .completed, id + "\n" + app.debugDescription); button.tap()
    }
    private func start(_ id: String, mode: String) {
        app.launchArguments = ["-test-library-id", id, "-test-muted-playback", "-test-opml-journey-mode", mode]
        app.launch(); XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 15))
    }
    private func picker() {
        tap("navigationMore")
        // Subscriptions has its own "Add podcast" button too; use the More menu's item.
        let item = app.otherElements["morePopup"].buttons["Add podcast"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription); item.tap()
        // Suggestions sit above the rows (AddFeedFragment order), so on a phone the last row,
        // "Import podcast list (OPML)", is below the fold of the scrolling screen, as on Android.
        let opml = app.buttons["addOPML"]
        XCTAssertTrue(opml.waitForExistence(timeout: 15))
        for _ in 0..<4 where !opml.isHittable { app.scrollViews["libraryContent"].swipeUp() }
        tap("addOPML")
    }
    @discardableResult private func choose(_ name: String, library: String, in owner: XCUIApplication, open: Bool = true) -> XCUIElement {
        let ownedRoot = owner.otherElements["DOC.browsingRoot Source: com.apple.FileProvider.LocalStorage, Title: OPML-" + library]
        let folder = owner.cells["OPML-" + library + ", Folder"]
        if !ownedRoot.exists {
            XCTAssertTrue(owner.revealInLocalFiles(folder), owner.debugDescription); folder.tap()
        }
        let file = owner.cells[(name as NSString).deletingPathExtension + ", opml"]
        XCTAssertTrue(file.waitForExistence(timeout: 15), owner.debugDescription)
        if open { file.tap() }
        return file
    }
    private func settingsPicker() {
        tap("navigationMore"); tap("Settings"); tap("Backup & restore")
        tap("opmlImportPreference")
    }
    private func verifySelectionAcrossResize() throws {
        let row = app.buttons["opmlRow-1"]
        XCTAssertFalse(row.isSelected); row.tap(); XCTAssertTrue(row.isSelected)
        if !XCUIDevice.rotationResizesWindow {
            // Duo device-orientation synthesis does not resize its window.
            // The supported OS-scene test independently verifies actual resize/restoration.
            let confirm = app.buttons["opmlConfirm"], cancel = app.buttons["opmlCancel"]
            XCTAssertTrue(row.isSelected && row.isHittable && confirm.isHittable && cancel.isHittable)
            XCTAssertLessThanOrEqual(cancel.frame.maxX, confirm.frame.minX)
            return
        }
        let oldFrame = app.windows.firstMatch.frame
        let oldOrientation: UIDeviceOrientation = oldFrame.width > oldFrame.height ? .landscapeLeft : .portrait
        defer { XCUIDevice.shared.orientation = oldOrientation }
        XCUIDevice.shared.orientation = oldFrame.width > oldFrame.height ? .portrait : .landscapeLeft
        let changed = NSPredicate { [self] _, _ in
            let frame = app.windows.firstMatch.frame
            return abs(frame.width - oldFrame.width) > 1 && abs(frame.height - oldFrame.height) > 1
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 15), .completed,
                       "Requested orientation must produce effective geometry")
        XCTAssertTrue(row.isSelected && row.isHittable)
        let confirm = app.buttons["opmlConfirm"], cancel = app.buttons["opmlCancel"]
        XCTAssertTrue(confirm.isHittable && cancel.isHittable)
        XCTAssertLessThanOrEqual(cancel.frame.maxX, confirm.frame.minX)
        XCUIDevice.shared.orientation = oldOrientation
        let restored = NSPredicate { [self] _, _ in abs(app.windows.firstMatch.frame.width - oldFrame.width) < 1 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: restored, object: nil)], timeout: 15), .completed)
        XCTAssertTrue(row.isSelected)
    }
    private func selectAll() {
        XCTAssertTrue(app.buttons["opmlRow-0"].waitForExistence(timeout: 15))
        tap("opmlOverflow")
        tap("opmlSelectAll")
    }
    /// The Subscriptions screen lists exactly these feeds, each once.
    private func expectSubscriptions(_ titles: [String], file: StaticString = #filePath, line: UInt = #line) {
        tap("SubscriptionFragment")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'subscriptionFeed-'"))
        func labels() -> [String] { rows.allElementsBoundByIndex.map(\.label) }
        func matches() -> Bool {
            let current = labels()
            return current.count == titles.count && titles.allSatisfy { title in current.contains { $0.contains(title) } }
        }
        let deadline = Date().addingTimeInterval(15)
        while !matches(), Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
        XCTAssertTrue(matches(), "Subscriptions: \(labels()), expected \(titles)", file: file, line: line)
    }
    private let selection = ["OPML First", "OPML Second", "OPML Last"]
    func testActualPickerCancelMalformedPrefixRetryAndRelaunch() throws {
        let id = "9A490CDF-7E51-457F-9576-188511EB247C"
        start(id, mode: "fail-second-once"); defer { app.terminate() }
        picker()
        choose("selection.opml", library: id, in: app, open: false)
        let pickerRoot = app.otherElements["DOC.browsingRoot Source: com.apple.FileProvider.LocalStorage, Title: OPML-" + id]
        let visibleCancel = app.buttons.matching(NSPredicate(format: "label == %@", "Cancel"))
            .allElementsBoundByIndex.first(where: { $0.isHittable })
        if let visibleCancel {
            visibleCancel.tap()
        } else {
            // Compact Files sheet's host AX Other(Cancel) is occluded by More.
            // Cancel through the actual modal-sheet dismissal gesture instead.
            let bar = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
            XCTAssertTrue(bar.exists && pickerRoot.exists)
            XCTAssertGreaterThan(bar.frame.width, 0)
            XCTAssertGreaterThan(bar.frame.height, 0)
            bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
                .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        }
        XCTAssertTrue(pickerRoot.waitForNonExistence(timeout: 15))
        XCTAssertTrue(app.buttons["addOPML"].isHittable)
        picker(); choose("malformed.opml", library: id, in: app)
        XCTAssertTrue(app.buttons["opmlReadErrorOK"].waitForExistence(timeout: 15)); tap("opmlReadErrorOK")
        picker(); choose("selection.opml", library: id, in: app)
        XCTAssertTrue(app.buttons["opmlRow-0"].waitForExistence(timeout: 15)); try verifySelectionAcrossResize(); tap("opmlCancel")
        expectSubscriptions([]) // Picker cancel, read error and dialog cancel import nothing.
        picker(); choose("selection.opml", library: id, in: app); selectAll(); tap("opmlConfirm")
        let confirm = app.buttons["opmlConfirm"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: confirm)], timeout: 15), .completed)
        // The second entry's write failed; the dialog stays open to retry the rest.
        tap("opmlConfirm"); XCTAssertTrue(confirm.waitForNonExistence(timeout: 15))
        app.terminate(); app.launch()
        expectSubscriptions(selection) // Every entry once: the retry neither lost nor duplicated one.
    }
    func testActualConfirmedCloseFinishesWithoutReopening() throws {
        let id = "F0483971-C6CE-430B-ACAA-EB6A521272AC"
        start(id, mode: "hold-until-close"); defer { app.terminate() }
        picker(); choose("selection.opml", library: id, in: app); selectAll(); tap("opmlConfirm")
        XCTAssertFalse(app.buttons["opmlConfirm"].isEnabled)
        // Closing the dialog while the import waits does not cancel it.
        tap("opmlCancel"); XCTAssertTrue(app.buttons["opmlCancel"].waitForNonExistence(timeout: 15))
        expectSubscriptions(selection)
        XCTAssertFalse(app.buttons["opmlConfirm"].exists)
        app.terminate(); app.launch()
        expectSubscriptions(selection); XCTAssertFalse(app.buttons["opmlConfirm"].exists)
    }
    func testFilesOpenColdAndShareWarmExternalDocumentDelivery() throws {
        try XCTSkipIf(XCUIDevice.isDuoSimulator, "The Duo Simulator has no Files app (FBSApplicationLibrary returns nil for com.apple.DocumentsApp); iPhone and iPad run this journey")
        let id = "C49DFF3B-C214-4EE7-A820-1FFAE7CB4EFF"
        // This launch records the DEBUG marker that routes the Files-driven cold launch to this library.
        start(id, mode: "ordinary")
        defer {
            app.terminate()
            app.launchArguments = ["-test-opml-journey-clear"]; app.launch(); app.terminate()
        }
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        for cold in [true, false] {
            if cold { app.terminate() }
            files.activate()
            let document = choose(cold ? "selection.opml" : "replacement.opml", library: id, in: files, open: false)
            document.press(forDuration: 1)
            if cold {
                let openWith = files.buttons["Open With"]; XCTAssertTrue(openWith.waitForExistence(timeout: 15), files.debugDescription); openWith.tap()
            } else {
                let share = files.buttons["Share"]; XCTAssertTrue(share.waitForExistence(timeout: 15)); share.tap()
            }
            let recipient = cold
                ? files.buttons.matching(NSPredicate(format: "label == %@", "NotTennaPod")).firstMatch
                : files.cells.matching(NSPredicate(format: "identifier == %@ AND label == %@", "shareCell", "NotTennaPod")).firstMatch
            XCTAssertTrue(recipient.waitForExistence(timeout: 15), files.debugDescription); recipient.tap()
            XCTAssertTrue(app.buttons["opmlRow-0"].waitForExistence(timeout: 15))
            let title = cold ? "OPML First" : "OPML Replacement"
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "opmlRow-0", title)).firstMatch.waitForExistence(timeout: 15))
            if !cold {
                // iPad Files may deliver Share to a new scene in the warm process.
                // Match the actual replacement window, never an offscreen scene's Cancel.
                let windows = app.windows.allElementsBoundByIndex.filter {
                    $0.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "opmlRow-0", title)).firstMatch.exists
                }
                XCTAssertEqual(windows.count, 1)
                let cancel = try XCTUnwrap(windows.first).buttons["opmlCancel"]
                XCTAssertTrue(cancel.isHittable); cancel.tap()
                XCTAssertTrue(cancel.waitForNonExistence(timeout: 15))
            }
        }
    }
    /// Re-importing feeds that are already in the library keeps what the user had: custom titles,
    /// the queued episode and the archived/preview states. Only the new entries are added.
    func testSettingsImportKeepsExistingSubscriptionsState() throws {
        let id = "5C4734B7-61CA-487F-B3AC-5ED0BFAE3208"
        start(id, mode: "refresh-lifecycle"); defer { app.terminate() }
        settingsPicker(); choose("refresh.opml", library: id, in: app)
        XCTAssertTrue(app.buttons["opmlRow-4"].waitForExistence(timeout: 15))
        selectAll(); tap("opmlConfirm")
        XCTAssertTrue(app.buttons["opmlConfirm"].waitForNonExistence(timeout: 15))
        app.terminate(); app.launch()
        // Existing feeds keep their custom title and state (archived stays archived, a preview stays
        // unsubscribed), so the list shows the existing subscription once plus the two new feeds.
        expectSubscriptions(["Custom global", "OPML New one", "OPML New two"])
        tap("QueueFragment")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'episode-' AND label CONTAINS 'Retained global'")).firstMatch.waitForExistence(timeout: 15),
                      "The queued episode survives the import: " + app.debugDescription)
    }
    func testRealProviderSnapshotSurvivesSourceRemovalAfterSelection() throws {
        let id = "39724F84-202F-4455-9037-1ED941C991C9"
        // In this mode the fixture deletes the picked file right after the app reads it.
        start(id, mode: "remove-source"); defer { app.terminate() }
        picker(); choose("selection.opml", library: id, in: app)
        XCTAssertTrue(app.buttons["opmlRow-0"].waitForExistence(timeout: 15))
        selectAll(); tap("opmlConfirm")
        XCTAssertTrue(app.buttons["opmlConfirm"].waitForNonExistence(timeout: 15))
        expectSubscriptions(selection)
    }
}
