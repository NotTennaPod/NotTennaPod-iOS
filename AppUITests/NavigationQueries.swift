import XCTest
import SQLite3

extension XCUIApplication {
    /// A navigation control by its label, excluding Home's section "more" buttons, which reuse the
    /// destination names ("Queue", "Inbox", …) as on Android. Same match as `buttons[label]` otherwise.
    func navigation(_ label: String) -> XCUIElement {
        buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier BEGINSWITH 'homeMore-')", label)).firstMatch
    }
}

extension XCUIElement {
    /// For a row of the shell's content list: hittable and wholly inside the visible list. A row just below the list,
    /// in the bottom strip's band (`ShellLayout.bottomStripMaximum`), or wholly below it, is clipped from view yet can
    /// still report `isHittable`; a tap at its centre lands on the strip.
    func isRevealed(in app: XCUIApplication) -> Bool {
        guard exists, isHittable else { return false }
        let content = app.scrollViews["libraryContent"]
        guard content.exists else { return true }
        return frame.minY >= content.frame.minY - 0.5 && frame.maxY <= content.frame.maxY + 0.5
    }

    /// Taps once the element's frame has stopped moving. Measured on iOS 27.1: after
    /// `typeText` into a system alert's text field, the accessibility tree reports the alert at its
    /// keyboard-hidden position for about 0.9 s while it is drawn above the keyboard, so an immediate tap
    /// lands on the dimmed backdrop and the alert action never runs.
    func tapWhenSettled(timeout: TimeInterval = 5) {
        // Require 1.2 s without change, longer than the observed 0.9 s stale window.
        var previous = frame, stableSince = Date()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            let current = frame
            if current != previous || current.isEmpty { previous = current; stableSince = Date() }
            else if Date().timeIntervalSince(stableSince) >= 1.2 { break }
        }
        tap()
    }
}

extension XCUIElement {
    /// Types, then waits until the keyboard's frame has been unchanged for 1.2 s. Measured on iOS 27.1:
    /// XCUITest's typing makes the software keyboard drop and return for about
    /// 0.9 s, so alerts and keyboard-avoiding dialogs move twice; a tap in that window uses a position
    /// that is about to change and misses its target.
    func typeTextSettled(_ text: String) {
        typeText(text)
        let keyboard = XCUIApplication().keyboards.firstMatch
        func current() -> CGRect { keyboard.exists ? keyboard.frame : .zero }
        var previous = current(), stableSince = Date()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            let frame = current()
            if frame != previous { previous = frame; stableSince = Date() }
            else if Date().timeIntervalSince(stableSince) >= 1.2 { break }
        }
    }
}

extension XCUIApplication {
    /// The system document picker (or the Files app) reopens wherever it was last used, which can be a
    /// subfolder or another location. Walks back, or through Browse/Locations, to "On My iPhone/iPad"
    /// until `target` exists there. Returns whether it did.
    ///
    /// "On My iPhone/iPad" holds only the seeded documents (`LocalFilesStorage`): tests that save exports
    /// there remove them again, so the seeded folders and files are on the first screen and no scrolling
    /// is needed to reach them.
    @discardableResult func revealInLocalFiles(_ target: XCUIElement, timeout: TimeInterval = 30) -> Bool {
        let local = cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "DOC.sidebar.item.On My ")).firstMatch
        let back = navigationBars.buttons.matching(identifier: "BackButton").firstMatch
        let titleMenu = navigationBars.buttons.matching(NSPredicate(format: "label ENDSWITH %@ AND NOT (label BEGINSWITH %@)", ", Actions Menu", "On My ")).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while !target.exists, Date() < deadline {
            if local.exists && local.isHittable { local.tap() }
            else if back.exists && back.isHittable { back.tap() }
            else if titleMenu.exists && titleMenu.isHittable {
                // The Duo's picker has no Back button; the folder title's menu lists the enclosing folders.
                titleMenu.tap()
                let parent = descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "On My ")).firstMatch
                if parent.waitForExistence(timeout: 2) { parent.tap() } else { typeKey(XCUIKeyboardKey.escape, modifierFlags: []) }
            }
            else if buttons["Browse"].firstMatch.exists { buttons["Browse"].firstMatch.tap() }
            else if cells["DOC.sidebar.header.Locations"].exists { cells["DOC.sidebar.header.Locations"].tap() }
            _ = target.waitForExistence(timeout: 2)
        }
        // On a phone the item can sit below the screen edge; scroll the list until it can be tapped.
        for _ in 0..<5 where target.exists && !target.isHittable && collectionViews.firstMatch.exists {
            collectionViews.firstMatch.swipeUp(velocity: .slow)
        }
        return target.exists
    }

    /// Brings the system Save picker to the local root ("On My iPhone/iPad").
    func openLocalFilesRoot(file: StaticString = #filePath, line: UInt = #line) {
        let bar = navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        let title = bar.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "On My ")).firstMatch
        XCTAssertTrue(revealInLocalFiles(title), debugDescription, file: file, line: line)
    }
}

/// The Simulator's "On My iPhone/iPad" storage (`group.com.apple.FileProvider.LocalStorage`). The scheme's test
/// pre-action seeds it from `TestSupport/Media/files-provider` (`Tools/test-fixtures.sh` seed_files). On the
/// Simulator the runner reaches the device's shared containers directly, as other journeys read the app's library.
enum LocalFilesStorage {
    /// Its "File Provider Storage" folder, the root the picker shows as "On My iPhone/iPad".
    static let root: URL? = {
        // The runner's home is <device>/data/Containers/Data/Application/<runner>.
        let groups = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Shared/AppGroup", isDirectory: true)
        for group in (try? FileManager.default.contentsOfDirectory(at: groups, includingPropertiesForKeys: nil)) ?? [] {
            let metadata = group.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            guard let data = try? Data(contentsOf: metadata),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  plist["MCMMetadataIdentifier"] as? String == "group.com.apple.FileProvider.LocalStorage" else { continue }
            return group.appendingPathComponent("File Provider Storage", isDirectory: true)
        }
        return nil
    }()

    /// The items in `folder` (the root by default) named `<prefix>…<suffix>`, the way the app names its exports
    /// (`nottennapod-feeds-2026-10-01.opml`; the system may add " 2" before the extension), oldest first.
    static func items(prefix: String, suffix: String, in folder: String? = nil) -> [URL] {
        guard var directory = root else { return [] }
        if let folder { directory.appendPathComponent(folder, isDirectory: true) }
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let all = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast }
        return all.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.hasSuffix(suffix) }
            .sorted { modified($0) < modified($1) }
    }

    /// One kind of export a test saves into the storage.
    struct Export: CustomStringConvertible, Sendable {
        let prefix: String, suffix: String
        var description: String { prefix + "*" + suffix }
    }
    static let opmlExport = Export(prefix: "nottennapod-feeds-", suffix: ".opml")
    static let databaseExport = Export(prefix: "NotTennaPodBackup-", suffix: ".db")
    static let htmlExport = Export(prefix: "nottennapod-feeds-", suffix: ".html")
    static let favoritesExport = Export(prefix: "nottennapod-favorites-", suffix: ".html")

    /// Removes these exports from the root and, if given, leaves `emptyFolder` as seeded: present and empty.
    static func restoreSeeded(removing exports: [Export], emptyFolder: String?) {
        for export in exports {
            for item in items(prefix: export.prefix, suffix: export.suffix) { try? FileManager.default.removeItem(at: item) }
        }
        if let emptyFolder, let root {
            let folder = root.appendingPathComponent(emptyFolder, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue {
                for item in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                    try? FileManager.default.removeItem(at: item)
                }
            } else {
                try? FileManager.default.removeItem(at: folder)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            }
        }
    }

    /// What Android's Database import reads from a saved backup: its schema version, integrity and subscriptions.
    struct BackupSummary: Equatable {
        let userVersion: [String], integrity: [String], feeds: [String]
        /// The statistics fixture library (database export journeys) as an Android 3.12.1 database.
        static let statisticsFixture = Self(userVersion: ["3110000"], integrity: ["ok"], feeds: ["Alpha statistics", "Bravo statistics"])
    }
    /// Reads a private copy, so SQLite never touches the storage.
    static func backupSummary(_ item: URL) throws -> BackupSummary {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + item.lastPathComponent)
        try FileManager.default.copyItem(at: item, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
        func rows(_ sql: String) -> [String] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return ["error: " + String(cString: sqlite3_errmsg(db))] }
            defer { sqlite3_finalize(statement) }
            var result: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW { result.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "") }
            return result
        }
        return BackupSummary(userVersion: rows("PRAGMA user_version"), integrity: rows("PRAGMA integrity_check"),
                             feeds: rows("SELECT title FROM Feeds ORDER BY title"))
    }
}

extension XCTestCase {
    /// Exports saved into "On My iPhone/iPad" used to pile up there during a run and push the seeded folders and
    /// files that later picker tests need out of view. A test that saves exports calls this in `setUp`:
    /// it removes that kind of export now (leftovers of an interrupted test) and again when the test ends, pass or
    /// fail, so the storage stays as seeded for every picker test. The seed step removes the same kinds.
    ///
    /// For an independent check of a saved export, which reads the newest
    /// export from the storage, run that one journey with `TEST_RUNNER_KEEP_LOCAL_EXPORTS=1 xcodebuild test …`: the
    /// exports then stay after the test, and the next run's seed step removes them.
    func keepLocalFilesSeeded(removing exports: [LocalFilesStorage.Export], emptyFolder: String? = nil) {
        XCTAssertNotNil(LocalFilesStorage.root, "The Simulator's local Files storage (seeded by the test pre-action)")
        LocalFilesStorage.restoreSeeded(removing: exports, emptyFolder: emptyFolder)
        guard ProcessInfo.processInfo.environment["KEEP_LOCAL_EXPORTS"] != "1" else { return }
        addTeardownBlock {
            LocalFilesStorage.restoreSeeded(removing: exports, emptyFolder: emptyFolder)
            for export in exports {
                XCTAssertEqual(LocalFilesStorage.items(prefix: export.prefix, suffix: export.suffix).map(\.lastPathComponent), [],
                               "Removed after the test: \(export)")
            }
            if let emptyFolder, let root = LocalFilesStorage.root {
                let left = try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(emptyFolder).path)
                XCTAssertEqual(left, [], "\(emptyFolder) is present and empty after the test")
            }
        }
    }
}

extension XCUIApplication {
    /// After credentials are confirmed, iOS may offer to save the (synthetic) password in a sheet that
    /// takes the next tap. The iPhone Simulator shows it; the iPad does not. Decline it when it appears.
    func dismissSavePasswordPrompt(timeout: TimeInterval = 8) { // The sheet can take about 5 s to appear.
        let notNow = buttons["Not Now"]
        if notNow.waitForExistence(timeout: timeout) { notNow.tap(); _ = notNow.waitForNonExistence(timeout: 3) }
    }
}

extension XCUIDevice {
    /// The Duo Simulator (model iPhone19,4, device type iPhone-Duo) does not resize the app window when
    /// XCUITest changes the orientation. Only there do rotation checks fall back to the
    /// current size; everywhere else a missing rotation stays a failure.
    static var rotationResizesWindow: Bool { !isDuoSimulator }
    static var isDuoSimulator: Bool { ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == "iPhone19,4" }
}

extension XCUIDevice {
    /// Sends the app under test to the background as a person would. The Duo Simulator ignores the Home button,
    /// so there the test switches to Settings instead, which backgrounds the app in the same way.
    @MainActor func leaveApp() {
        if Self.isDuoSimulator { XCUIApplication(bundleIdentifier: "com.apple.Preferences").activate() }
        else { press(.home) }
    }
}
