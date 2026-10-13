import XCTest

/// Actual OPML export journey: Settings → Backup & restore → OPML export → real system Save
/// picker → progress → `Export successful` → actual Share sheet. The saved document is read back
/// from "On My iPhone/iPad" (not through the Swift writer) and removed when the test ends.
@MainActor final class OPMLExportJourneyTests: XCTestCase {
    private let library = "5A0D2F8E-7C41-4F0B-9D7A-12A0C0DE0012"
    private var app = XCUIApplication()
    override func setUp() {
        continueAfterFailure = false
        keepLocalFilesSeeded(removing: [LocalFilesStorage.opmlExport])
    }

    private func launch(failOnce: Bool = false) {
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback", "-test-m12-opml-export"]
        if failOnce { app.launchArguments.append("-test-m12-export-fail-once") }
        app.launch()
        XCTAssertTrue(app.windows["m12ExportFixtureReady"].waitForExistence(timeout: 30), app.debugDescription)
    }
    private func tap(_ id: String) {
        let button = app.buttons[id]; XCTAssertTrue(button.waitForExistence(timeout: 15), id)
        XCTAssertTrue(button.isHittable, id); button.tap()
    }
    private func openBackupRestore() {
        tap("navigationMore"); tap("Settings"); tap("Backup & restore")
        XCTAssertTrue(app.buttons["opmlExport"].waitForExistence(timeout: 10))
        XCTAssertLessThan(app.buttons["opmlExport"].frame.minY, app.buttons["opmlImportPreference"].frame.minY,
                          "Source order: OPML export precedes OPML import")
    }

    /// Saves into the device's local root through the real system Save picker. It may already
    /// open there; otherwise navigate to the local location first. Returns the suggested name.
    @discardableResult private func saveInLocalRoot() -> String {
        let confirm = app.buttons["DOCPicker.actionButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20), app.debugDescription)
        app.openLocalFilesRoot()
        let name = app.textFields["DOCPicker.filenameTextField"]
        // The Duo Simulator's Save picker can open with its "Save as" bar hidden; it appears once the file
        // list is pulled down, as a person would do (as in the database export journey). Elsewhere it shows at once.
        for _ in 0..<3 where !name.waitForExistence(timeout: 5) && app.collectionViews["File View"].exists {
            app.collectionViews["File View"].swipeDown(velocity: .slow)
        }
        XCTAssertTrue(name.waitForExistence(timeout: 5), app.debugDescription)
        let suggested = (name.value as? String) ?? ""
        XCTAssertNotNil(suggested.range(of: #"^nottennapod-feeds-\d{4}-\d{2}-\d{2}(\.opml)?$"#, options: .regularExpression),
                        "Suggested dated filename: \(suggested)")
        XCTAssertTrue(confirm.isEnabled); confirm.tap()
        resolveNameConflictIfPresented()
        return suggested
    }

    /// The saved document as another podcast app receives it: one file under the suggested name in
    /// "On My iPhone/iPad", an OPML list of the fixture's subscribed feeds (title and address, escaping
    /// undone); the archived and preview feeds are not subscriptions. Exact bytes and order: host tests.
    private func checkSavedDocument(suggested: String) throws {
        let name = suggested.hasSuffix(".opml") ? suggested : suggested + ".opml"
        let saved = LocalFilesStorage.items(prefix: LocalFilesStorage.opmlExport.prefix, suffix: LocalFilesStorage.opmlExport.suffix)
        XCTAssertEqual(saved.map(\.lastPathComponent), [name], "Saved once, under the suggested name")
        let outlines = OutlineReader()
        let parser = XMLParser(data: try Data(contentsOf: try XCTUnwrap(saved.last)))
        parser.delegate = outlines
        XCTAssertTrue(parser.parse(), "Well-formed OPML: \(parser.parserError.map { String(describing: $0) } ?? "")")
        XCTAssertTrue(outlines.isOPML, "OPML document")
        XCTAssertEqual(Set(outlines.feeds), [
            OutlineReader.Feed(title: "Zulu Display", address: "https://bravo.example/feed"),
            OutlineReader.Feed(title: "alpha feed", address: "https://alpha.example/feed"),
            OutlineReader.Feed(title: "\u{c9}clair & <Friends> \"Quoted\"\t\u{1F3A7}", address: "https://example.test/feed?token=fixture&x=1"),
            OutlineReader.Feed(title: "Imported Placeholder", address: "https://imported.example/feed"),
        ])
        XCTAssertEqual(outlines.feeds.count, 4, "Each subscription once")
    }
    private final class OutlineReader: NSObject, XMLParserDelegate {
        struct Feed: Hashable { let title: String, address: String }
        private(set) var feeds: [Feed] = []
        private(set) var isOPML = false
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if name == "opml" { isOPML = true }
            if name == "outline", let address = attributes["xmlUrl"] { feeds.append(Feed(title: attributes["title"] ?? "", address: address)) }
        }
    }

    /// The failed first attempt's destination file remains (source offers no rollback), so the
    /// retry meets the system "Replace Existing Item" prompt. Choose Replace, a provider decision.
    private func resolveNameConflictIfPresented() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let candidates = [app.buttons["Replace"], app.alerts.buttons["Replace"], springboard.buttons["Replace"],
                          app.sheets.buttons["Replace"]]
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if app.buttons["opmlExportShare"].exists || app.staticTexts["Export error"].exists || app.otherElements["opmlExportProgress"].exists { return }
            if let replace = candidates.first(where: { $0.exists }) {
                replace.tap(); return
            }
            if !app.buttons["DOCPicker.actionButton"].exists && !app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].exists { return }
            usleep(200_000)
        }
    }

    func test02InjectedErrorThenRetrySaveAndShare() throws {
        launch(failOnce: true)
        openBackupRestore()
        tap("opmlExport")
        saveInLocalRoot()
        let error = app.staticTexts["Export error"]
        XCTAssertTrue(error.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["M12 controlled export failure"].exists)
        tap("sourceMessageOK")
        XCTAssertTrue(error.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.buttons["opmlExportShare"].exists, "A failed write never offers success")

        // Retry is a fresh export through the actual picker.
        tap("opmlExport")
        let suggested = saveInLocalRoot()
        let share = app.buttons["opmlExportShare"]
        XCTAssertTrue(share.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Export successful"].exists)
        try checkSavedDocument(suggested: suggested)
        XCTAssertEqual(share.label, "Share")
        share.tap()
        // The system sheet must present the saved document itself (source ShareCompat stream).
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Share sheet: " + app.debugDescription)
        let sharedFile = sheet.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "nottennapod-feeds-")).firstMatch
        XCTAssertTrue(sharedFile.waitForExistence(timeout: 5), "Shared item is the saved OPML: " + app.debugDescription)
        XCTAssertTrue(sheet.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "OPML document")).firstMatch.exists)
        // Cancel without choosing a recipient: Close where offered, otherwise dismiss outside the sheet.
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Cancel"])).firstMatch
        let dismissRegion = app.otherElements["PopoverDismissRegion"]
        if close.exists && close.isHittable { close.tap() }
        else if dismissRegion.exists { dismissRegion.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.12)).tap() }
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Share sheet dismissed")
        XCTAssertTrue(app.buttons["opmlExport"].waitForExistence(timeout: 10), "Share cancellation returns to Backup & restore")
        app.terminate()
    }
}
