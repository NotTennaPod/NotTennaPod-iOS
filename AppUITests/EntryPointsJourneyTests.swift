import XCTest

/// Entry point journeys: podcast links (cold and warm), the Share Extension, Home Screen quick actions and
/// App Intents. Expectations from Android 3.12.1; feeds from the preview fixture (18774).
@MainActor final class EntryPointsJourneyTests: XCTestCase {
    private var app = XCUIApplication()
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let run = UUID().uuidString

    override func setUp() {
        continueAfterFailure = false
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
    }

    private func launch() {
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 15))
    }

    private func path(_ tag: String) -> String { "/preview.xml?m34=\(run)-\(tag)" }

    /// Opens a link as another app would: through the system, which may first ask "Open in “NotTennaPod”?".
    private func openFromSystem(_ link: String) {
        XCUIDevice.shared.system.open(URL(string: link)!)
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 5) { open.tap() }
    }

    private func waitForPreview(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 20), app.debugDescription, file: file, line: line)
        XCTAssertTrue(app.otherElements["feedPreviewCard"].exists, file: file, line: line)
        XCTAssertTrue(app.staticTexts["Preview Navigation Lab"].exists
                      || app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Preview Navigation Lab")).count > 0,
                      app.debugDescription, file: file, line: line)
    }

    private func closePreview() {
        app.otherElements["feedPreviewCard"].buttons["toolbarBack"].firstMatch.tapWhenSettled()
        XCTAssertTrue(app.otherElements["feedPreviewCard"].waitForNonExistence(timeout: 5))
    }

    private func requestCount(_ path: String) async throws -> Int {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18774/counts")!)
        return try JSONDecoder().decode([String: Int].self, from: data)[path] ?? 0
    }

    private func screenTitle(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let title = app.staticTexts["screenTitle"]
        let predicate = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [predicate], timeout: 10), .completed, app.debugDescription, file: file, line: line)
    }

    /// Long-presses AntennaPod's Home Screen icon (paging through the Home Screen as a person would)
    /// and returns the quick-action menu's buttons.
    private func quickActionMenu(file: StaticString = #filePath, line: UInt = #line) -> XCUIElementQuery {
        if XCUIDevice.isDuoSimulator {
            // The Duo Simulator ignores Home (NavigationQueries.leaveApp); switching to Settings and closing it
            // leaves the Home Screen with AntennaPod in the background, as Home would.
            let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
            settings.activate(); settings.terminate()
        } else { XCUIDevice.shared.press(.home) }
        let icon = springboard.icons["NotTennaPod"]
        XCTAssertTrue(icon.waitForExistence(timeout: 10), springboard.debugDescription, file: file, line: line)
        var pages = 0
        while !icon.isHittable && pages < 6 { springboard.swipeLeft(); pages += 1 }
        XCTAssertTrue(icon.isHittable, springboard.debugDescription, file: file, line: line)
        icon.press(forDuration: 1.5)
        return springboard.buttons
    }

    private func openInSafari(_ link: String) -> XCUIApplication {
        XCUIDevice.shared.system.open(URL(string: link)!)
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15))
        return safari
    }

    /// Safari hands an RSS response to the app that opens feed: links (the counterpart of
    /// Android's http + RSS MIME filter), and Safari's Share → AntennaPod hands the page's address to the
    /// app: a website with one feed link opens that feed's preview.
    func testSafariFeedLinkAndShareExtensionOpenThePreview() {
        launch()
        let safari = openInSafari("http://127.0.0.1:18774" + path("safari"))
        let open = safari.buttons["Open"]
        if open.waitForExistence(timeout: 10) {
            XCTAssertTrue(safari.textViews["Open this page in “NotTennaPod”?"].exists, safari.debugDescription)
            open.tap()
        }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        waitForPreview()
        closePreview()

        _ = openInSafari("http://127.0.0.1:18820/pages/website-one-link.html?m34=" + run)
        let menu = safari.buttons["MoreMenuButton"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15), safari.debugDescription); menu.tapWhenSettled()
        let share = safari.buttons["ShareButton"]
        XCTAssertTrue(share.waitForExistence(timeout: 5), safari.debugDescription); share.tapWhenSettled()
        let target = safari.cells.matching(identifier: "shareCell").matching(NSPredicate(format: "label == %@", "NotTennaPod")).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10), safari.debugDescription); target.tapWhenSettled()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 20), app.debugDescription)
        let onlyFeed = NSPredicate(format: "label CONTAINS %@", "Only Feed")
        XCTAssertTrue(app.buttons.matching(onlyFeed).count > 0 || app.staticTexts.matching(onlyFeed).count > 0, app.debugDescription)
        closePreview()
    }

    /// Opens shared text the way the Share Extension hands it to the app (`nottennapod-share://subscribe?text=`).
    private func openSharedText(_ text: String) {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        XCUIDevice.shared.leaveApp()
        openFromSystem("nottennapod-share://subscribe?text=" + text.addingPercentEncoding(withAllowedCharacters: allowed)!)
    }

    /// Shared text opens the preview of its first link —
    /// with words around it, with a second link after it, and AntennaPod's own "Share podcast" text for a
    /// title with ':' (Android crashes there) — and text without a link shows the no-podcast error.
    func testSharedTextOpensThePreviewOfItsFirstLink() async throws {
        launch()
        app.buttons["Queue"].firstMatch.tapWhenSettled()
        screenTitle("Queue")
        let first = path("text-first"), second = path("text-second")
        openSharedText("Listen to this: http://127.0.0.1:18774\(first), and http://127.0.0.1:18774\(second) too!")
        waitForPreview()
        closePreview()
        screenTitle("Queue")
        let firstCount = try await requestCount(first), secondCount = try await requestCount(second)
        XCTAssertGreaterThanOrEqual(firstCount, 1, "the first link is fetched")
        XCTAssertEqual(secondCount, 0, "the second link is not")

        // ShareUtils.shareFeedLink text: "<title>\n\nhttps://antennapod.org/deeplink/subscribe/?url=<URLEncoder
        // (feed) with htt → %68%74%74>&title=<URLEncoder(title)>".
        let shared = path("text-antennapod")
        let encodedFeed = ("http://127.0.0.1:18774" + shared).addingPercentEncoding(withAllowedCharacters:
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._*"))!
            .replacingOccurrences(of: "htt", with: "%68%74%74")
        openSharedText("Planet Money: The Indicator\n\nhttps://antennapod.org/deeplink/subscribe/?url=" + encodedFeed
                       + "&title=Planet+Money%3A+The+Indicator")
        waitForPreview()
        closePreview()
        let sharedCount = try await requestCount(shared)
        XCTAssertGreaterThanOrEqual(sharedCount, 1)

        openSharedText("Listen to this podcast, it is great")
        let ok = app.buttons["feedPreviewErrorConfirm"]
        XCTAssertTrue(ok.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.staticTexts["sourceMessageTitle"].label, "Error")
        XCTAssertTrue(app.staticTexts["sourceMessage"].label.hasPrefix("The link you tapped does not contain a valid podcast URL."),
                      app.staticTexts["sourceMessage"].label)
        ok.tapWhenSettled()
        XCTAssertTrue(app.otherElements["feedPreviewCard"].waitForNonExistence(timeout: 5))
        screenTitle("Queue")
    }

    /// Opens the Shortcuts app on AntennaPod's App Shortcuts (Library → Apps → AntennaPod).
    private func appShortcuts() -> XCUIApplication {
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        shortcuts.activate()
        // A fresh device first shows "What's New in Shortcuts" and the All Shortcuts list.
        let proceed = shortcuts.buttons["Continue"]
        if proceed.waitForExistence(timeout: 10) { proceed.tap() }
        let entry = shortcuts.buttons["NotTennaPod"]
        if !entry.waitForExistence(timeout: 5) {
            let library = shortcuts.buttons["BackButton"]
            if library.waitForExistence(timeout: 5) { library.tap() }
        }
        XCTAssertTrue(entry.waitForExistence(timeout: 10), shortcuts.debugDescription); entry.tap()
        return shortcuts
    }

    /// Android's App Actions as App Shortcuts: the five pages of the entity set, in its order and with
    /// its labels, and Search; running "Playback history" from the Shortcuts app opens that page.
    func testAppShortcutsRunFromTheShortcutsApp() throws {
        // Like the Files app, the Shortcuts app is not installed on the Duo Simulator (FBSApplicationLibrary
        // returns nil for com.apple.shortcuts). The iPhone and iPad run this journey; EntryPointsViewTests
        // covers the intents' routes and the pages they open on every device.
        try XCTSkipIf(XCUIDevice.isDuoSimulator, "The Duo Simulator has no Shortcuts app")
        launch()
        app.buttons["navigationMore"].tapWhenSettled()
        let settings = app.otherElements["morePopup"].buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5)); settings.tapWhenSettled()
        screenTitle("Settings")
        let shortcuts = appShortcuts()
        let pages = ["Queue", "Episodes", "Downloads", "Subscriptions", "Playback history"]
        let tiles = pages.map { shortcuts.staticTexts[$0] }
        XCTAssertTrue(tiles[0].waitForExistence(timeout: 10), shortcuts.debugDescription)
        XCTAssertTrue(shortcuts.staticTexts["Search"].exists, shortcuts.debugDescription)
        for (earlier, later) in zip(tiles, tiles.dropFirst()) {
            XCTAssertTrue(later.exists, shortcuts.debugDescription)
            // Reading order: left to right, then the next row.
            XCTAssertTrue(earlier.frame.minY < later.frame.minY - 20 || (abs(earlier.frame.minY - later.frame.minY) < 20 && earlier.frame.minX < later.frame.minX))
        }
        // The tile is the icon button above its label.
        let tile = shortcuts.buttons.matching(identifier: "list.bullet").element(boundBy: 4)
        XCTAssertTrue(tile.exists && abs(tile.frame.midX - tiles[4].frame.midX) < 20, shortcuts.debugDescription)
        tile.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), shortcuts.debugDescription)
        screenTitle("Playback history") // Settings closed; the page replaced it
        XCTAssertFalse(app.buttons["toolbarBack"].exists)
    }

    /// The four quick actions in Android's order; Queue opens its page and closes Settings;
    /// Refresh opens the startup page (Home) and refreshes the subscribed podcast; a quick action also
    /// starts the app (cold).
    func testQuickActionsRouteAndRefreshRefreshes() async throws {
        launch()
        // A subscribed podcast to refresh, subscribed through a link.
        let feed = path("refresh")
        XCUIDevice.shared.leaveApp()
        openFromSystem("itpc://127.0.0.1:18774" + feed)
        waitForPreview()
        app.buttons["subscribeFeed"].tapWhenSettled()
        XCTAssertTrue(app.buttons["feedInformation"].waitForExistence(timeout: 15), app.debugDescription)
        // Subscribing downloads the feed once for the preview and once for its refresh.
        var before = try await requestCount(feed)
        let settle = ContinuousClock.now + .seconds(10)
        while before < 2 && ContinuousClock.now < settle { before = try await requestCount(feed) }
        XCTAssertEqual(before, 2)

        // Settings is open when the quick action arrives; Queue closes it and opens as a top-level page.
        // (Each Home Screen long press costs Springboard's 60 s idle wait, so the journey uses three;
        // Episodes/Subscriptions routing is covered by EntryPointsViewTests.)
        app.buttons["navigationMore"].tapWhenSettled()
        let settings = app.otherElements["morePopup"].buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5)); settings.tapWhenSettled()
        screenTitle("Settings")
        let menu = quickActionMenu()
        XCTAssertTrue(menu["Queue"].waitForExistence(timeout: 5), springboard.debugDescription)
        let items = ["Queue", "Episodes", "Subscriptions", "Refresh"].map { menu[$0] }
        for (upper, lower) in zip(items, items.dropFirst()) { XCTAssertLessThan(upper.frame.minY, lower.frame.minY) }
        menu["Queue"].tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        screenTitle("Queue")
        XCTAssertFalse(app.buttons["toolbarBack"].exists, "Queue opens as a top-level page")

        let refresh = quickActionMenu()["Refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5)); refresh.tap()
        screenTitle("Home")
        var after = before
        let deadline = ContinuousClock.now + .seconds(15)
        while after <= before && ContinuousClock.now < deadline { after = try await requestCount(feed) }
        XCTAssertEqual(after, before + 1, "Refresh downloads the subscribed podcast once")

        // Cold: the quick action starts the app.
        app.terminate()
        let episodes = quickActionMenu()["Episodes"]
        XCTAssertTrue(episodes.waitForExistence(timeout: 5)); episodes.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        screenTitle("Episodes")
    }

    /// Each podcast protocol opens the preview over the current page (warm), which stays; a link also
    /// starts the app (cold).
    func testEveryProtocolOpensThePreviewWarmAndCold() {
        launch()
        app.buttons["Queue"].firstMatch.tapWhenSettled()
        screenTitle("Queue")
        for scheme in ["itpc", "pcast", "feed", "antennapod-subscribe"] {
            XCUIDevice.shared.leaveApp()
            openFromSystem("\(scheme)://127.0.0.1:18774" + path(scheme))
            waitForPreview()
            closePreview()
            screenTitle("Queue") // the page under the preview is untouched
        }
        // Cold: the app is not running when the link arrives.
        app.terminate()
        app.open(URL(string: "itpc://127.0.0.1:18774" + path("cold"))!)
        waitForPreview()
        closePreview()
    }
}
