import XCTest

final class OnlineSearchTests: XCTestCase {
    @MainActor func testOnlineResultsPreviewSubscribeAndDirectURL() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback", "-test-online-search"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 3)); address.tap()
        address.typeTextSettled("http://127.0.0.1:18765/feed.xml"); app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 35)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["feedSearch"].waitForExistence(timeout: 10)); app.buttons["feedSearch"].tap()
        let local = app.textFields["librarySearchQuery"]
        XCTAssertTrue(local.waitForExistence(timeout: 3)); local.tap(); local.typeTextSettled("podcasts\n")
        app.buttons["searchFeedScope"].tap(); app.buttons["searchOnline"].tap()
        let online = app.textFields["onlineSearchQuery"]
        XCTAssertTrue(online.waitForExistence(timeout: 5)); XCTAssertEqual(online.value as? String, "podcasts")
        let first = app.buttons["onlineSearchResult-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 10)); XCTAssertEqual(first.label, "Online podcast 0, Fixture author")
        first.tap(); XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15))
        // The preview's toolbar close (X) is its back button.
        app.otherElements["feedPreviewCard"].buttons["toolbarBack"].firstMatch.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5)); XCTAssertEqual(online.value as? String, "podcasts")
        first.tap(); XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 10)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["feedInformation"].waitForExistence(timeout: 10))
        // Source OnlineFeedViewActivity.openFeed clears the back stack: the new subscription opens as a top-level page.
        XCTAssertFalse(app.buttons["toolbarBack"].exists, app.debugDescription)
        app.buttons["feedSearch"].tap(); XCTAssertTrue(local.waitForExistence(timeout: 3)); local.tap(); local.typeTextSettled("podcasts\n")
        app.buttons["searchFeedScope"].tap(); app.buttons["searchOnline"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        online.tap(); app.buttons["onlineSearchClear"].tap(); online.typeTextSettled("zz9c7fzz\n")
        let empty = app.staticTexts["onlineSearchMessage"]
        XCTAssertTrue(empty.waitForExistence(timeout: 10)); XCTAssertEqual(empty.label, "No results were found for \"zz9c7fzz\"")
        app.buttons["toolbarBack"].tap(); XCTAssertTrue(local.waitForExistence(timeout: 5))
        XCTAssertEqual(local.value as? String, "podcasts")
        local.tap(); app.buttons["searchClearQuery"].tap(); local.typeTextSettled("http://127.0.0.1:18765/online-feed.xml\n")
        app.buttons["searchOnline"].tap()
        XCTAssertTrue(app.buttons["feedInformation"].waitForExistence(timeout: 10))
        XCTAssertFalse(online.exists); XCTAssertFalse(app.buttons["subscribeFeed"].exists)
        app.buttons["toolbarBack"].tap(); XCTAssertTrue(local.waitForExistence(timeout: 5))
        // Persisted subscription survives relaunch; return through the normal subscriptions surface.
        app.terminate(); app.launch()
        app.buttons["SubscriptionFragment"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Online Listening Lab")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "subscriptionFeed-")).count, 2)
    }
    @MainActor func testAppleMissingLinkRecoversPreviewNoticeAndThenOpensSavedFeed() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback", "-test-online-search"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 3)); address.tap()
        address.typeTextSettled("https://podcasts.apple.com/us/podcast/fixture/id123"); app.buttons["Confirm"].tapWhenSettled()
        let notice = app.staticTexts["feedRecoveryNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        XCTAssertEqual(notice.label, "The suggested podcast did not have an RSS link, NotTennaPod found a podcast that could match")
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 3)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["feedSearch"].waitForExistence(timeout: 10)); app.buttons["feedSearch"].tap()
        let query = app.textFields["librarySearchQuery"]
        XCTAssertTrue(query.waitForExistence(timeout: 3)); query.tap()
        query.typeTextSettled("https://podcasts.apple.com/us/podcast/fixture/id123\n")
        app.buttons["searchFeedScope"].tap(); app.buttons["searchOnline"].tap()
        XCTAssertTrue(app.buttons["feedInformation"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["subscribeFeed"].exists); XCTAssertFalse(notice.exists)
        app.buttons["toolbarBack"].tap(); XCTAssertTrue(query.waitForExistence(timeout: 3))
        query.tap(); app.buttons["searchClearQuery"].tap()
        query.typeTextSettled("https://podcasts.apple.com/us/podcast/missing/id999\n")
        app.buttons["searchOnline"].tap()
        let ok = app.buttons["feedPreviewErrorConfirm"]
        XCTAssertTrue(ok.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.staticTexts["sourceMessageTitle"].label, "Error")
        XCTAssertEqual(app.staticTexts["sourceMessage"].label, "The link you tapped does not contain a valid podcast URL. Please verify the link and try again, or search for the podcast manually.")
        XCTAssertEqual(ok.label, "OK")
        ok.tap(); XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["subscribeFeed"].exists)
    }
}
