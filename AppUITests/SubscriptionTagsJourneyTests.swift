import XCTest

/// Journey on a UUID library seeded from the oracle's Android fixture
/// `TestSupport/Data/subscription-tags-bulk/tags-library.db` (DEBUG hook, through the database import): Tech chip
/// → tag two feeds with the multi-select Tags dialog → their chip → bottom navigation off (inside the test) →
/// drawer folder → rename it → multi-select three → bulk Playback speed and Include in auto downloads off →
/// archive one → relaunch keeps everything → bottom navigation restored. Expected feed ids come from the oracle
/// (`expected/subscription-tags.json`, alphabetical order).
@MainActor final class SubscriptionTagsJourneyTests: XCTestCase {
    private let library = UUID().uuidString
    private var app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        let database = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestSupport/Data/subscription-tags-bulk/tags-library.db").path
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback", "-test-seed-android-database", database]
    }

    /// Displayed cells in reading order.
    private func displayed() -> [Int] {
        let cells = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'subscriptionFeed-'")).allElementsBoundByIndex
        return cells.compactMap { cell -> (CGRect, Int)? in Int(cell.identifier.dropFirst("subscriptionFeed-".count)).map { (cell.frame, $0) } }
            .sorted { abs($0.0.minY - $1.0.minY) > 1 ? $0.0.minY < $1.0.minY : $0.0.minX < $1.0.minX }.map(\.1)
    }
    private func wait(_ element: XCUIElement, _ timeout: TimeInterval = 5, _ file: StaticString = #filePath, _ line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element)\n\(app.debugDescription)", file: file, line: line)
    }
    private func gone(_ element: XCUIElement, _ file: StaticString = #filePath, _ line: UInt = #line) {
        XCTAssertTrue(element.waitForNonExistence(timeout: 5), "\(element)", file: file, line: line)
    }
    private func selectionTitle(_ text: String) {
        wait(app.staticTexts["subscriptionSelectionCount"])
        XCTAssertEqual(app.staticTexts["subscriptionSelectionCount"].label, text)
    }
    /// A floating action, scrolling the strip until it can be tapped.
    private func bulk(_ action: String) {
        let button = app.buttons["feedBulk-" + action], strip = app.otherElements["subscriptionSelectionActions"]
        wait(button)
        for _ in 0..<4 where !button.isHittable { strip.swipeLeft() }
        button.tap()
    }
    private func snackbar(_ text: String) {
        let bar = app.otherElements["subscriptionsUpdatedSnackbar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(bar.label, text)
        // It covers the bottom of the list for 2.75 s, as on Android; wait before the next action.
        XCTAssertTrue(bar.waitForNonExistence(timeout: 10))
    }
    /// Evidence screenshots, kept in the result bundle.
    private func attachScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    /// Settings → Interface → "Bottom navigation" (the drawer exists only with it off).
    private func toggleBottomNavigation(fromDrawer: Bool) {
        if fromDrawer {
            if app.buttons["openDrawer"].waitForExistence(timeout: 3) { app.buttons["openDrawer"].tap() }
            wait(app.buttons["drawerSettings"]); app.buttons["drawerSettings"].tap()
        } else {
            app.buttons["navigationMore"].tap(); wait(app.buttons["Settings"]); app.buttons["Settings"].tap()
        }
        wait(app.buttons["prefScreenInterface"]); app.buttons["prefScreenInterface"].tap()
        let bottom = app.buttons["prefBottomNavigation"]
        wait(bottom)
        for _ in 0..<6 where !bottom.isHittable { app.swipeUp() }
        bottom.tap()
        if app.buttons["sourceMessageOK"].waitForExistence(timeout: 3) { app.buttons["sourceMessageOK"].tap() }
        app.buttons["Back"].tap(); app.buttons["Back"].tap()
    }

    func test01TagChipsFoldersBulkEditsArchiveAndRelaunch() {
        app.launch()
        XCTAssertTrue(app.navigation("Subscriptions").waitForExistence(timeout: 30), app.debugDescription)
        app.navigation("Subscriptions").tap()
        wait(app.buttons["subscriptionFeed-1"], 10)
        // Alphabetical order, as in the oracle's views.
        app.buttons["subscriptionsMore"].tap(); wait(app.buttons["subscriptionsSort"]); app.buttons["subscriptionsSort"].tap()
        wait(app.buttons["subscriptionsSortDialog-1"]); app.buttons["subscriptionsSortDialog-1"].tap()
        gone(app.buttons["subscriptionsSortDialog-1"])
        XCTAssertEqual(displayed(), [1, 2, 4, 5, 3, 9, 10, 11, 12, 6])

        // Chips: All, the tags, Untagged. Tech shows its members.
        wait(app.buttons["subscriptionTag-Tech"])
        XCTAssertTrue(app.buttons["subscriptionTag-#root"].isSelected)
        XCTAssertTrue(app.buttons["subscriptionTag-#untagged"].exists)
        app.buttons["subscriptionTag-Tech"].tap()
        XCTAssertEqual(displayed(), [4, 5, 3, 6])
        attachScreen("m24-chip-tech")
        app.buttons["subscriptionTag-#root"].tap()

        // Tag two feeds: long press starts multi-select; the Tags dialog shows only common tags (none here).
        app.buttons["subscriptionFeed-1"].press(forDuration: 1.2)
        selectionTitle("1/10 selected")
        XCTAssertFalse(app.buttons["subscriptionsAdd"].exists, "FAB hidden while selecting")
        app.buttons["subscriptionFeed-2"].tap()
        selectionTitle("2/10 selected")
        bulk("editTags")
        wait(app.staticTexts["feedTagsCommonInfo"])
        XCTAssertFalse(app.buttons["feedTagRemove-0"].exists, "Alpha and Beta share no tag")
        let field = app.textFields["feedTagInput"]
        field.tap(); field.typeTextSettled("Morning")
        app.buttons["feedTagsSave"].tapWhenSettled()
        gone(app.buttons["feedTagsSave"])
        selectionTitle("2/10 selected")
        app.buttons["endSubscriptionSelection"].tap()
        gone(app.staticTexts["subscriptionSelectionCount"])
        wait(app.buttons["subscriptionTag-Morning"])
        app.buttons["subscriptionTag-Morning"].tap()
        XCTAssertEqual(displayed(), [1, 2])
        app.buttons["subscriptionTag-#root"].tap()

        // Drawer (bottom navigation off, turned off here and restored at the end): the folder, then rename.
        toggleBottomNavigation(fromDrawer: false)
        if app.buttons["openDrawer"].waitForExistence(timeout: 5) { app.buttons["openDrawer"].tap() }
        let folder = app.buttons["drawer-folder-Morning"]
        wait(folder)
        attachScreen("m24-drawer-folders")
        folder.press(forDuration: 1.2)
        wait(app.buttons["renameTag"]); XCTAssertTrue(app.buttons["deleteTag"].exists)
        app.buttons["renameTag"].tap()
        let input = app.textViews["tagRenameInput"]
        wait(input); input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() // caret after the title
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10))
        input.typeTextSettled("Evening")
        app.buttons["tagRenameConfirm"].tapWhenSettled()
        wait(app.buttons["drawer-folder-Evening"])
        XCTAssertFalse(app.buttons["drawer-folder-Morning"].exists)
        app.buttons["drawer-SubscriptionFragment"].tap()
        wait(app.buttons["subscriptionTag-Evening"])
        XCTAssertFalse(app.buttons["subscriptionTag-Morning"].exists)

        // Multi-select three: bulk Playback speed (1.35×) and Include in auto downloads → Disabled.
        wait(app.buttons["subscriptionFeed-3"])
        app.buttons["subscriptionFeed-3"].press(forDuration: 1.2)
        app.buttons["subscriptionFeed-4"].tap(); app.buttons["subscriptionFeed-5"].tap()
        selectionTitle("3/10 selected")
        attachScreen("m24-selection-three")
        bulk("playbackSpeed")
        wait(app.buttons["feedSpeedIncrease"])
        for _ in 0..<7 { app.buttons["feedSpeedIncrease"].tap() }
        XCTAssertEqual(app.staticTexts["feedSpeedValue"].label, "1.35x")
        app.buttons["bulkSpeedSave"].tap()
        snackbar("3 subscriptions updated.")
        selectionTitle("3/10 selected")
        bulk("autoDownload")
        wait(app.buttons["bulkAutoDownload-2"]); app.buttons["bulkAutoDownload-2"].tap()
        app.buttons["bulkAutoDownloadConfirm"].tap()
        snackbar("3 subscriptions updated.")

        // Archive one: with a single feed selected, selection ends as the sheet opens.
        app.buttons["subscriptionFeed-4"].tap(); app.buttons["subscriptionFeed-5"].tap()
        selectionTitle("1/10 selected")
        bulk("removeArchive")
        wait(app.buttons["archiveFeed"]); app.buttons["archiveFeed"].tap()
        gone(app.buttons["subscriptionFeed-3"])
        XCTAssertFalse(app.staticTexts["subscriptionSelectionCount"].exists)
        XCTAssertEqual(displayed(), [1, 2, 4, 5, 9, 10, 11, 12, 6])

        // Relaunch: tags, archive state and the bulk values persist.
        app.terminate(); app.launch()
        if app.buttons["openDrawer"].waitForExistence(timeout: 20) { app.buttons["openDrawer"].tap() }
        wait(app.buttons["drawer-folder-Evening"])
        app.buttons["drawer-SubscriptionFragment"].tap()
        wait(app.buttons["subscriptionFeed-4"], 10)
        XCTAssertEqual(displayed(), [1, 2, 4, 5, 9, 10, 11, 12, 6])
        app.buttons["subscriptionTag-Evening"].tap()
        XCTAssertEqual(displayed(), [1, 2])
        app.buttons["subscriptionTag-#root"].tap()
        app.buttons["subscriptionsMore"].tap(); wait(app.buttons["subscriptionsArchive"]); app.buttons["subscriptionsArchive"].tap()
        wait(app.buttons["subscriptionFeed-3"])
        XCTAssertEqual(displayed(), [7, 3], "Eta Archive, Gamma Talk")
        app.buttons["toolbarBack"].tap()
        for id in [4, 5] {
            wait(app.buttons["subscriptionFeed-\(id)"]); app.buttons["subscriptionFeed-\(id)"].tap()
            wait(app.buttons["feedSettings"]); app.buttons["feedSettings"].tap()
            let speedRow = app.buttons["feedSettingsPlaybackSpeed"]; wait(speedRow); speedRow.tap()
            wait(app.buttons["feedSpeedCancel"])
            XCTAssertEqual(app.descendants(matching: .any)["feedSpeedSlider"].value as? String, "1.35", "feed \(id)")
            XCTAssertEqual(app.buttons["feedSpeedSkipSilence"].value as? String, "Off", "saved unchecked")
            app.buttons["feedSpeedCancel"].tap()
            let autoDownload = app.buttons["feedSettingsAutoDownload"]
            for _ in 0..<3 where !autoDownload.isHittable { app.swipeUp() }
            autoDownload.tap()
            wait(app.buttons["feedAutoDownload-0"])
            XCTAssertTrue(app.buttons["feedAutoDownload-0"].isSelected, "feed \(id): Disabled (stored 0)")
            app.buttons["feedAutoDownload-0"].tap()
            app.buttons["toolbarBack"].tap(); app.buttons["toolbarBack"].tap()
        }

        // Restore bottom navigation.
        toggleBottomNavigation(fromDrawer: true)
        XCTAssertTrue(app.navigation("Subscriptions").waitForExistence(timeout: 10))
        app.terminate()
    }
}
