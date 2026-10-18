import XCTest

/// Actual journey: Settings → Backup & restore → HTML category (after OPML) → HTML export and
/// Favorites export, each through the real system Save picker (`nottennapod-feeds/favorites-yyyy-MM-dd.html`),
/// progress, "Export successful" and the real share sheet. Both saved documents are read back from
/// "On My iPhone/iPad" (not through the Swift writer) and removed when the test ends; byte equality
/// with the source writer rules is checked separately.
@MainActor final class HTMLExportJourneyTests: XCTestCase {
    private let library = "17A0C0DE-DB00-4E17-8F17-0000000000F7"
    private var app = XCUIApplication()
    override func setUp() {
        continueAfterFailure = false
        keepLocalFilesSeeded(removing: [LocalFilesStorage.htmlExport, LocalFilesStorage.favoritesExport])
    }

    private func tap(_ id: String) {
        let button = app.buttons[id]; XCTAssertTrue(button.waitForExistence(timeout: 15), id)
        if !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.isHittable, id); button.tap()
    }
    /// The saved page a friend opens: one file under the suggested name that shows the expected texts
    /// (the list-inbox fixture's feed, or its two favorite episodes).
    private func checkSavedPage(suggested: String, prefix: String, shows texts: [String]) throws {
        let name = suggested.hasSuffix(".html") ? suggested : suggested + ".html"
        let saved = LocalFilesStorage.items(prefix: prefix + "-", suffix: ".html")
        XCTAssertEqual(saved.map(\.lastPathComponent), [name], "Saved once, under the suggested name")
        let page = String(decoding: try Data(contentsOf: try XCTUnwrap(saved.last)), as: UTF8.self)
        XCTAssertTrue(page.contains("<html") && page.contains("</html>"), "A complete HTML page")
        for text in texts { XCTAssertTrue(page.contains(text), "\(name) shows \(text)") }
    }
    private func save(_ row: String, prefix: String, shows texts: [String]) throws {
        tap(row)
        let confirm = app.buttons["DOCPicker.actionButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20), app.debugDescription)
        app.openLocalFilesRoot()
        let name = app.textFields["DOCPicker.filenameTextField"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), app.debugDescription)
        let suggested = (name.value as? String) ?? ""
        XCTAssertNotNil(suggested.range(of: "^" + prefix + #"-\d{4}-\d{2}-\d{2}(\.html)?$"#, options: .regularExpression), "Suggested: \(suggested)")
        confirm.tap()
        let share = app.buttons["opmlExportShare"]
        // iOS QuickLook renders a web preview of the staged .html and then of the saved copy; each render
        // holds a coordinated read, so the picker's move and then the app's coordinated write wait for it.
        // On a loaded Simulator each render took 18-49 s (Save to "Export successful" 21-72 s);
        // the app's own work takes about 2 s, as for OPML. Device latency is a hardware-checklist item.
        XCTAssertTrue(share.waitForExistence(timeout: 150), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Export successful"].exists)
        try checkSavedPage(suggested: suggested, prefix: prefix, shows: texts)
        share.tap()
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(sheet.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch.waitForExistence(timeout: 5))
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Cancel"])).firstMatch
        let region = app.otherElements["PopoverDismissRegion"]
        if close.exists && close.isHittable { close.tap() } else if region.exists { region.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.12)).tap() }
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
    }

    func testHTMLAndFavoritesExportsSaveAndShare() throws {
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback", "-test-list-inbox-cleanup"]
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 20))
        tap("navigationMore"); tap("Settings"); tap("Backup & restore")
        let opml = app.staticTexts["OPML"], html = app.staticTexts["HTML"]
        XCTAssertTrue(html.waitForExistence(timeout: 10) && opml.exists, app.debugDescription)
        XCTAssertLessThan(opml.frame.minY, html.frame.minY, "Source order: HTML category after OPML")
        XCTAssertEqual(app.buttons["htmlExport"].label, "HTML export")
        XCTAssertEqual(app.buttons["favoritesExport"].label, "Favorites export")
        XCTAssertLessThan(app.buttons["htmlExport"].frame.minY, app.buttons["favoritesExport"].frame.minY)
        try save("htmlExport", prefix: "nottennapod-feeds",
                 shows: ["<title>NotTennaPod Subscriptions</title>", "Controlled inbox cleanup", "https://example.invalid/controlled-list-inbox"])
        try save("favoritesExport", prefix: "nottennapod-favorites",
                 shows: ["<title>NotTennaPod Favorites</title>", "Inbox cleanup target", "Inbox cleanup survivor"])
        app.terminate()
    }
}
