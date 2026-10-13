import XCTest

/// Add-podcast journeys against the discovery fixture server (127.0.0.1:18820, started by the scheme pre-action).
/// Expected values come from the Android oracle (TestSupport/Data/add-podcast-discovery/expected/discovery.json).
@MainActor final class AddPodcastJourneyTests: XCTestCase {
    private var app = XCUIApplication()
    private let library = UUID().uuidString
    override func setUp() {
        continueAfterFailure = false
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback", "-test-discovery"]
    }
    private func launch() {
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 15))
    }
    private func openAddPodcast() {
        app.buttons["navigationMore"].tapWhenSettled()
        let item = app.otherElements["morePopup"].buttons["Add podcast"]
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tapWhenSettled()
        XCTAssertTrue(app.buttons["addRSS"].waitForExistence(timeout: 10))
    }
    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 15) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "\(element) label is not \(label)\n\(app.debugDescription)")
    }
    private func discoverMenu(_ item: String) {
        app.buttons["discoverOverflow"].tapWhenSettled()
        let button = app.buttons[item]
        XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tapWhenSettled()
    }
    private func focused(_ field: XCUIElement) {
        let focus = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [focus], timeout: 5), .completed, app.debugDescription)
    }
    private func addByAddress(_ address: String) {
        app.buttons["addRSS"].tapWhenSettled()
        let field = app.textFields["rssAddress"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tapWhenSettled(); field.typeTextSettled(address)
        app.buttons["Confirm"].tapWhenSettled()
    }

    /// Suggestions → Discover more → Select country → Hide → relaunch: both preferences persist and
    /// the suggestions follow them; Discover's back arrow goes to the default page.
    func testSuggestionsDiscoverCountryHideAndRelaunch() {
        launch(); openAddPodcast()
        // The first 12 top-list entries, in feed order (nothing subscribed yet).
        waitForLabel(app.buttons["quickDiscoveryItem-0"], "Top Show 01")
        XCTAssertEqual(app.buttons["quickDiscoveryItem-2"].label, "Daily Brief")
        XCTAssertTrue(app.buttons["quickDiscoveryItem-11"].exists)
        XCTAssertFalse(app.buttons["quickDiscoveryItem-12"].exists)
        XCTAssertEqual(app.staticTexts["quickDiscoveryAttribution"].label, "Suggestions by Apple Podcasts")
        app.buttons["discoverMore"].tapWhenSettled()
        XCTAssertTrue(app.otherElements["discoverScreen"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["screenTitle"].label, "Discover")
        waitForLabel(app.buttons["discoverResult-0"], "Top Show 01, Artist 01")
        XCTAssertTrue(app.buttons["discoverResult-24"].exists)
        XCTAssertEqual(app.staticTexts["discoverAttribution"].label, "Suggestions by Apple Podcasts")

        discoverMenu("discoverSelectCountry")
        let field = app.textFields["selectCountryField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "United States") // the current (device) country
        field.tapWhenSettled()
        // Focusing clears the field, so typing filters from scratch.
        field.typeTextSettled("Germ")
        let germany = app.buttons["Germany"]
        XCTAssertTrue(germany.waitForExistence(timeout: 5)); germany.tapWhenSettled()
        app.buttons["selectCountryOK"].tapWhenSettled()
        waitForLabel(app.buttons["discoverResult-0"], "Deutsch Show 01, Artist 01")

        discoverMenu("discoverHide")
        waitForLabel(app.staticTexts["discoverMessage"], "You selected to hide suggestions.")
        XCTAssertFalse(app.buttons["discoverResult-0"].exists)
        XCTAssertFalse(app.buttons["discoverRetry"].exists)

        app.terminate(); launch()
        // Relaunch opens the default page (Home), not Discover.
        XCTAssertFalse(app.otherElements["discoverScreen"].exists)
        openAddPodcast()
        waitForLabel(app.staticTexts["quickDiscoveryMessage"], "You selected to hide suggestions.")
        XCTAssertFalse(app.buttons["quickDiscoveryItem-0"].exists)
        XCTAssertFalse(app.staticTexts["quickDiscoveryAttribution"].exists)
        app.buttons["discoverMore"].tapWhenSettled()
        waitForLabel(app.staticTexts["discoverMessage"], "You selected to hide suggestions.")
        app.buttons["discoverOverflow"].tapWhenSettled()
        let hide = app.buttons["discoverHide"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5)); XCTAssertTrue(hide.isSelected)
        hide.tapWhenSettled()
        waitForLabel(app.buttons["discoverResult-0"], "Deutsch Show 01, Artist 01")
        app.buttons["toolbarBack"].tapWhenSettled()
        XCTAssertTrue(app.otherElements["discoverScreen"].waitForNonExistence(timeout: 5))
        waitForLabel(app.staticTexts["screenTitle"], "Home")
    }

    /// A suggestion opens its preview; once subscribed, it is no longer suggested.
    func testSubscribedSuggestionLeavesTheSuggestions() {
        launch(); openAddPodcast()
        let first = app.buttons["quickDiscoveryItem-0"]
        waitForLabel(first, "Top Show 01")
        first.tapWhenSettled()
        let subscribe = app.buttons["subscribeFeed"]
        XCTAssertTrue(subscribe.waitForExistence(timeout: 15), app.debugDescription); subscribe.tapWhenSettled()
        XCTAssertTrue(app.buttons["feedInformation"].waitForExistence(timeout: 10))
        openAddPodcast()
        waitForLabel(app.buttons["quickDiscoveryItem-0"], "Top Show 02")
        XCTAssertEqual(app.buttons["quickDiscoveryItem-1"].label, "Daily Brief")
    }

    /// The Add-box query goes to the combined Apple + Podcast Index search; fyyd has its own screen.
    func testSearchBoxCombinedOrderAndFyydScreen() {
        launch(); openAddPodcast()
        let box = app.textFields["addPodcastSearchField"]
        box.tapWhenSettled(); box.typeTextSettled("shared\n")
        let first = app.buttons["onlineSearchResult-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 15), app.debugDescription)
        // Oracle small_both: score order, ties in the source's HashMap order.
        let titles = ["Alpha (PI)", "PI Result 01", "Shared One (PI)", "Shared Two (PI)", "PI Result 04",
                      "Apple Result 04", "PI Result 06", "Apple Result 06"]
        for (index, title) in titles.enumerated() {
            XCTAssertTrue(app.buttons["onlineSearchResult-\(index)"].label.hasPrefix(title + ", "), "\(index): \(title)")
        }
        XCTAssertFalse(app.buttons["onlineSearchResult-8"].exists)
        XCTAssertEqual(app.staticTexts["onlineSearchProvider"].label, "Results by Apple, Podcast Index")
        XCTAssertEqual(app.textFields["onlineSearchQuery"].value as? String, "shared")
        app.buttons["toolbarBack"].tapWhenSettled()
        XCTAssertTrue(app.buttons["addSearchFyyd"].waitForExistence(timeout: 5))
        // performSearch cleared the box.
        XCTAssertNotEqual(box.value as? String, "shared")

        app.buttons["addSearchFyyd"].tapWhenSettled()
        let query = app.textFields["onlineSearchQuery"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertNotEqual(query.value as? String, "shared") // the Add-box text is not carried over
        query.typeTextSettled("fyyd\n")
        waitForLabel(app.buttons["onlineSearchResult-0"], "fyyd One, F1")
        XCTAssertEqual(app.buttons["onlineSearchResult-1"].label, "Unknown, F2 (no title)")
        XCTAssertTrue(app.buttons["onlineSearchResult-3"].label.hasPrefix("fyyd Four"))
        XCTAssertEqual(app.staticTexts["onlineSearchProvider"].label, "Results by fyyd")
        app.buttons["onlineSearchResult-0"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15), app.debugDescription)
    }

    /// Add by RSS address: validation, a website with several feeds (chooser in Android order), and a
    /// website without feeds (error with Edit feed URL, whose Confirm is the retry).
    func testWebsiteChooserErrorAndEditFeedURL() {
        launch(); openAddPodcast()
        addByAddress("localhost")
        waitForLabel(app.staticTexts["rssAddressError"], "The RSS address you entered is not valid.")
        let field = app.textFields["rssAddress"]
        XCTAssertTrue(field.exists)
        focused(field)
        field.typeTextSettled(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 9) + "http://127.0.0.1:18820/pages/website-many-links.html")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.otherElements["feedChooser"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.staticTexts["feedChooserTitle"].label, "Subscriptions")
        let labels = ["MP3 Feed (renamed)", "Comments", "AAC Feed", "http://127.0.0.1:18820/feeds/atom.xml"]
        for (index, label) in labels.enumerated() { XCTAssertEqual(app.buttons["feedChooserRow-\(index)"].label, label) }
        XCTAssertFalse(app.buttons["feedChooserRow-4"].exists)
        app.buttons["feedChooserRow-2"].tapWhenSettled()
        let subscribe = app.buttons["subscribeFeed"]
        XCTAssertTrue(subscribe.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["AAC Feed"].exists || app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "AAC Feed")).count > 0)
        app.otherElements["feedPreviewCard"].buttons["toolbarBack"].firstMatch.tapWhenSettled()
        XCTAssertTrue(app.otherElements["feedPreviewCard"].waitForNonExistence(timeout: 5))

        addByAddress("http://127.0.0.1:18820/pages/website-no-links.html")
        let ok = app.buttons["feedPreviewErrorConfirm"]
        XCTAssertTrue(ok.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(app.staticTexts["sourceMessageTitle"].label, "Error")
        let message = app.staticTexts["sourceMessage"].label
        XCTAssertTrue(message.hasPrefix("The address you entered is a website address, not a podcast RSS address."), message)
        XCTAssertTrue(message.contains("Technical reason: \nWebsite title: \"Example\n Podcast   Site\""), message)
        XCTAssertTrue(message.hasSuffix("File URL:\nhttp://127.0.0.1:18820/pages/website-no-links.html"), message)
        XCTAssertFalse(app.buttons["Retry"].exists)
        app.buttons["feedErrorEditURL"].tapWhenSettled()
        let edit = app.textFields["editFeedURLField"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertEqual(edit.value as? String, "http://127.0.0.1:18820/pages/website-no-links.html")
        // The field is focused with the caret after the address (a tap would move the caret).
        focused(edit)
        edit.typeTextSettled(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "no-links.html".count) + "one-link.html")
        app.buttons["feedErrorEditConfirm"].tapWhenSettled()
        // One feed link opens that feed directly.
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.otherElements["feedChooser"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Only Feed")).count > 0
                      || app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Only Feed")).count > 0, app.debugDescription)
    }
}
