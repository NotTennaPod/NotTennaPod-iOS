import XCTest

final class DownloadsControlsTests: XCTestCase {
    @MainActor func testDownloadSortSearchRefreshDeleteCancelConfirmAndRelaunch() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), session = UUID().uuidString
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18771/feed.xml?session=\(session)")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 10)); app.buttons["subscribeFeed"].tap()
        var ids: [String: String] = [:]
        for title in ["Unplayed", "Zulu", "Alpha"] {
            let row = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 8))
            if !row.isHittable { app.scrollViews["libraryContent"].swipeUp() }
            let id = String(row.identifier.dropFirst("episode-".count)); ids[title] = id
            let button = app.buttons["episode-action-\(id)"]
            XCTAssertTrue(button.isHittable); button.tap()
            await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: button)], timeout: 20)
        }
        let alpha = app.buttons["episode-\(ids["Alpha"]!)"]
        alpha.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["markPlayed"].waitForExistence(timeout: 5)); app.buttons["markPlayed"].tap()
        openDownloads(app)
        XCTAssertEqual(app.buttons["episode-action-\(ids["Alpha"]!)"].label, "Delete")
        app.buttons["downloadsMore"].tap(); app.buttons["downloadsSort"].tap()
        XCTAssertTrue(app.buttons["feedSort-size"].waitForExistence(timeout: 5)); app.buttons["feedSort-size"].tap()
        app.buttons["feedSort-title"].tap()
        dismissSort(app)
        XCTAssertLessThan(app.buttons["episode-\(ids["Alpha"]!)"].frame.minY, app.buttons["episode-\(ids["Unplayed"]!)"].frame.minY)
        app.buttons["downloadsSearch"].tap()
        let query = app.textFields["librarySearchQuery"]
        XCTAssertTrue(query.waitForExistence(timeout: 5)); query.tap(); query.typeTextSettled("Zulu\n")
        XCTAssertTrue(app.buttons["episode-\(ids["Zulu"]!)"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["searchFeedScope"].exists)
        app.buttons["toolbarBack"].tap()
        let before = try await count(session)
        app.buttons["downloadsMore"].tap(); app.buttons["downloadsRefresh"].tap()
        let deadline = Date().addingTimeInterval(15)
        var after = before
        while after <= before && Date() < deadline { try await Task.sleep(for: .milliseconds(100)); after = try await count(session) }
        XCTAssertGreaterThan(after, before)
        app.buttons["downloadsMore"].tap(); app.buttons["downloadsDeletePlayed"].tap()
        XCTAssertTrue(app.buttons["downloadsDeletePlayedCancel"].waitForExistence(timeout: 5))
        app.buttons["downloadsDeletePlayedCancel"].tap()
        XCTAssertTrue(app.buttons["episode-\(ids["Alpha"]!)"].exists)
        app.buttons["downloadsMore"].tap(); app.buttons["downloadsDeletePlayed"].tap()
        app.buttons["downloadsDeletePlayedConfirm"].tap()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["episode-\(ids["Alpha"]!)"])], timeout: 10)
        XCTAssertTrue(app.buttons["episode-\(ids["Zulu"]!)"].exists && app.buttons["episode-\(ids["Unplayed"]!)"].exists)
        app.buttons["episode-action-\(ids["Zulu"]!)"].tap()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["episode-\(ids["Zulu"]!)"])], timeout: 10)
        app.terminate(); app.launch(); openDownloads(app)
        XCTAssertTrue(app.buttons["episode-\(ids["Unplayed"]!)"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["episode-\(ids["Alpha"]!)"].exists)
        app.buttons["downloadsMore"].tap(); app.buttons["downloadsSort"].tap()
        XCTAssertEqual(app.buttons["feedSort-title"].label, "Episode title ▲")
        dismissSort(app)
        app.buttons["episode-action-\(ids["Unplayed"]!)"].tap()
        XCTAssertTrue(app.staticTexts["No downloaded episodes"].waitForExistence(timeout: 10))
        let beforePull = try await count(session)
        let content = app.scrollViews["libraryContent"]
        let start = content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: min(230, content.frame.height * 0.6))), withVelocity: 400, thenHoldForDuration: 0.1)
        let pullDeadline = Date().addingTimeInterval(15)
        var afterPull = beforePull
        while afterPull <= beforePull && Date() < pullDeadline { try await Task.sleep(for: .milliseconds(100)); afterPull = try await count(session) }
        XCTAssertGreaterThan(afterPull, beforePull)
        XCTAssertTrue(app.staticTexts["No downloaded episodes"].exists)
    }
    @MainActor func testContextSelectionFavoritesQueueShareAndBulkDeletePersist() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), session = UUID().uuidString
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18771/feed.xml?session=\(session)")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 10)); app.buttons["subscribeFeed"].tap()
        var ids: [String: String] = [:]
        for title in ["Unplayed", "Zulu", "Alpha"] {
            let row = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 8))
            if !row.isHittable { app.scrollViews["libraryContent"].swipeUp() }
            let id = String(row.identifier.dropFirst("episode-".count)); ids[title] = id
            let action = app.buttons["episode-action-\(id)"]; action.tap()
            await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: action)], timeout: 20)
        }
        openDownloads(app)
        let alpha = app.buttons["episode-\(ids["Alpha"]!)"], zulu = app.buttons["episode-\(ids["Zulu"]!)"]
        alpha.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["multiSelect"].waitForExistence(timeout: 5))
        app.buttons["multiSelect"].tap()
        XCTAssertTrue(app.buttons["endEpisodeSelection"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["episode-action-\(ids["Zulu"]!)"].label, "Play")
        app.buttons["episode-action-\(ids["Zulu"]!)"].tap()
        XCTAssertEqual(app.staticTexts["episodeSelectionCount"].label, "2/3 selected")
        let favorite = app.buttons["episodeBulk-addFavorite"]
        if !favorite.isHittable { app.otherElements["episodeSelectionActions"].swipeLeft() }
        XCTAssertTrue(favorite.isHittable); favorite.tap()
        XCTAssertTrue(app.buttons["downloadsMore"].waitForExistence(timeout: 5))
        app.terminate(); app.launch(); openDownloads(app)
        alpha.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["removeFavorite"].waitForExistence(timeout: 5))
        app.buttons["share"].tap()
        XCTAssertTrue(app.buttons["episodeShareSocial"].waitForExistence(timeout: 5)); app.buttons["episodeShareSocial"].tap()
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout: 10)); app.cells["Copy"].tap()
        zulu.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["removeFavorite"].waitForExistence(timeout: 5)); app.buttons["multiSelect"].tap()
        app.buttons["episodeSelectionMore"].tap(); app.buttons["select_toggle"].tap()
        XCTAssertEqual(app.staticTexts["episodeSelectionCount"].label, "3/3 selected")
        let removeQueue = app.buttons["episodeBulk-removeQueue"]
        if !removeQueue.isHittable { app.otherElements["episodeSelectionActions"].swipeLeft() }
        XCTAssertTrue(removeQueue.isHittable); removeQueue.tap()
        XCTAssertTrue(app.buttons["downloadsMore"].waitForExistence(timeout: 5))
        alpha.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["addQueue"].waitForExistence(timeout: 5)); app.buttons["multiSelect"].tap()
        zulu.tap()
        XCTAssertEqual(app.staticTexts["episodeSelectionCount"].label, "2/3 selected")
        app.buttons["episodeBulk-delete"].tap()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: alpha),
                              XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: zulu)], timeout: 10)
        app.terminate(); app.launch(); openDownloads(app)
        let remaining = app.buttons["episode-\(ids["Unplayed"]!)"]
        XCTAssertTrue(remaining.waitForExistence(timeout: 5)); XCTAssertFalse(alpha.exists || zulu.exists)
        remaining.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["addFavorite"].waitForExistence(timeout: 5)); XCTAssertTrue(app.buttons["addQueue"].exists)
        app.buttons["multiSelect"].tap(); app.buttons["endEpisodeSelection"].tap()
        XCTAssertEqual(app.buttons["episode-action-\(ids["Unplayed"]!)"].label, "Delete")
    }
    @MainActor func testFirstSwipeConfigurationCancelToggleDisableAndSavedDelete() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), session = UUID().uuidString
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18771/feed.xml?session=\(session)")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 10)); app.buttons["subscribeFeed"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label == %@", "Unplayed")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        let id = String(row.identifier.dropFirst("episode-".count)), action = app.buttons["episode-action-" + String(row.identifier.dropFirst("episode-".count))]
        action.tap()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: action)], timeout: 20)
        openDownloads(app)
        let downloaded = app.buttons["episode-" + id]
        let start = downloaded.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: -40, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0)
        XCTAssertTrue(downloaded.exists)
        XCTAssertFalse(app.buttons["downloadsSwipeChange-left"].exists)
        swipeEpisode(downloaded, left: true)
        XCTAssertTrue(app.buttons["downloadsSwipeChange-left"].waitForExistence(timeout: 5))
        app.buttons["downloadsSwipeChange-left"].tap()
        XCTAssertTrue(app.buttons["downloadsSwipeChoice-MARK_FAV"].waitForExistence(timeout: 5))
        app.buttons["downloadsSwipeChoice-MARK_FAV"].tap(); app.buttons["downloadsSwipeCancel"].tap()
        swipeEpisode(downloaded, left: true)
        XCTAssertTrue(app.buttons["downloadsSwipeChange-left"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["downloadsSwipePreview-left"].value as? String, "Delete")
        app.buttons["downloadsSwipeChange-left"].tap(); app.buttons["downloadsSwipeChoice-MARK_FAV"].tap()
        app.buttons["downloadsSwipeChange-right"].tap(); app.buttons["downloadsSwipeChoice-ADD_TO_QUEUE"].tap()
        app.buttons["downloadsSwipeConfirm"].tap()
        swipeEpisode(downloaded, left: true); downloaded.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["removeFavorite"].waitForExistence(timeout: 5)); dismissContext(app)
        swipeEpisode(downloaded, left: true); downloaded.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["addFavorite"].waitForExistence(timeout: 5)); dismissContext(app)
        swipeEpisode(downloaded, left: false); downloaded.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["addQueue"].waitForExistence(timeout: 5)); dismissContext(app)
        swipeEpisode(downloaded, left: false); downloaded.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["removeQueue"].waitForExistence(timeout: 5)); dismissContext(app)
        app.terminate(); app.launch(); openDownloads(app)
        swipeEpisode(downloaded, left: true); downloaded.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["removeFavorite"].waitForExistence(timeout: 5)); dismissContext(app)
        openSwipeSettings(app)
        app.buttons["downloadsSwipeEnabled"].tap()
        app.buttons["downloadsSwipeConfirm"].tap(); closeSettings(app)
        swipeEpisode(downloaded, left: true); downloaded.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["removeFavorite"].waitForExistence(timeout: 5)); dismissContext(app)
        openSwipeSettings(app)
        XCTAssertEqual(app.buttons["downloadsSwipeEnabled"].value as? String, "Off")
        app.buttons["downloadsSwipeEnabled"].tap()
        app.buttons["downloadsSwipeChange-left"].tap(); app.buttons["downloadsSwipeChoice-MARK_PLAYED"].tap()
        app.buttons["downloadsSwipeConfirm"].tap(); closeSettings(app)
        swipeEpisode(downloaded, left: true); downloaded.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["markUnplayed"].waitForExistence(timeout: 5)); dismissContext(app)
        openSwipeSettings(app)
        app.buttons["downloadsSwipeChange-left"].tap(); app.buttons["downloadsSwipeChoice-DELETE"].tap()
        app.buttons["downloadsSwipeConfirm"].tap(); closeSettings(app)
        swipeEpisode(downloaded, left: true)
        XCTAssertTrue(app.staticTexts["No downloaded episodes"].waitForExistence(timeout: 10))
    }
    @MainActor func testGlobalDownloadSettingsPersistAndMarkedEpisodeIsDeletedByPolicy() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), session = UUID().uuidString
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18771/feed.xml?session=\(session)")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 10)); app.buttons["subscribeFeed"].tap()
        let episode = app.buttons.matching(NSPredicate(format: "label == %@", "Unplayed")).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 8))
        let id = String(episode.identifier.dropFirst("episode-".count)), action = app.buttons["episode-action-" + String(episode.identifier.dropFirst("episode-".count))]
        action.tap()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Play"), object: action)], timeout: 20)
        openDownloads(app)
        XCTAssertEqual(action.label, "Delete")
        app.buttons["navigationMore"].tap(); app.buttons["Settings"].tap(); app.buttons["prefScreenInterface"].tap()
        tapSetting("prefDownloadsButtonAction", app)
        XCTAssertEqual(app.buttons["prefDownloadsButtonAction"].value as? String, "On")
        app.buttons["toolbarBack"].tap(); app.buttons["toolbarBack"].tap()
        XCTAssertEqual(action.label, "Play")
        app.buttons["navigationMore"].tap(); app.buttons["Settings"].tap(); app.buttons["prefScreenDownloads"].tap()
        tapSetting("prefDeleteRemovesFromQueue", app); tapSetting("prefAutoDownloadSettings", app)
        tapSetting("prefEpisodeCacheSize", app)
        XCTAssertTrue(app.buttons["prefEpisodeCacheSize-25"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["prefEpisodeCacheSize-25"].isSelected)
        app.buttons["prefEpisodeCacheSizeCancel"].tap()
        for key in ["prefEnableAutoDl", "prefEnableAutoDlQueue", "prefEnableAutoDownloadOnBattery"] { tapSetting(key, app) }
        tapSetting("prefEpisodeCacheSize", app); app.buttons["prefEpisodeCacheSize-5"].tap()
        app.buttons["toolbarBack"].tap(); tapSetting("prefAutoDeleteScreen", app)
        XCTAssertFalse(app.buttons["prefAutoDeleteLocal"].isEnabled)
        tapSetting("prefAutoDelete", app); tapSetting("prefAutoDeleteLocal", app)
        XCTAssertTrue(app.buttons["cancelAutoDeleteLocal"].waitForExistence(timeout: 5))
        app.buttons["cancelAutoDeleteLocal"].tap()
        XCTAssertEqual(app.buttons["prefAutoDeleteLocal"].value as? String, "Off")
        tapSetting("prefAutoDeleteLocal", app); app.buttons["confirmAutoDeleteLocal"].tap()
        tapSetting("prefFavoriteKeepsEpisode", app)
        tapSetting("prefEpisodeCleanup", app)
        XCTAssertTrue(app.buttons["prefEpisodeCleanup-12"].waitForExistence(timeout: 5))
        app.buttons["prefEpisodeCleanup-12"].tap()
        app.buttons["toolbarBack"].tap(); app.buttons["toolbarBack"].tap(); app.buttons["prefScreenPlayback"].tap()
        tapSetting("prefSmartMarkAsPlayedSecs", app)
        XCTAssertTrue(app.buttons["prefSmartMarkAsPlayedSecs-120"].waitForExistence(timeout: 5)); app.buttons["prefSmartMarkAsPlayedSecs-120"].tap()
        app.terminate(); app.launch(); openDownloads(app)
        XCTAssertEqual(action.label, "Play")
        app.buttons["navigationMore"].tap(); app.buttons["Settings"].tap(); app.buttons["prefScreenDownloads"].tap()
        XCTAssertEqual(app.buttons["prefDeleteRemovesFromQueue"].value as? String, "On")
        tapSetting("prefAutoDownloadSettings", app)
        XCTAssertEqual(app.buttons["prefEnableAutoDl"].value as? String, "On")
        XCTAssertEqual(app.buttons["prefEnableAutoDlQueue"].value as? String, "On")
        XCTAssertEqual(app.buttons["prefEnableAutoDownloadOnBattery"].value as? String, "Off")
        tapSetting("prefEpisodeCacheSize", app); XCTAssertTrue(app.buttons["prefEpisodeCacheSize-5"].isSelected); app.buttons["prefEpisodeCacheSizeCancel"].tap()
        app.buttons["toolbarBack"].tap(); tapSetting("prefAutoDeleteScreen", app)
        XCTAssertEqual(app.buttons["prefAutoDelete"].value as? String, "On")
        XCTAssertEqual(app.buttons["prefAutoDeleteLocal"].value as? String, "On")
        XCTAssertEqual(app.buttons["prefFavoriteKeepsEpisode"].value as? String, "Off")
        for _ in 0..<3 { app.buttons["toolbarBack"].tap() }
        let downloaded = app.buttons["episode-" + id]
        swipeEpisode(downloaded, left: true)
        XCTAssertTrue(app.buttons["downloadsSwipeChange-left"].waitForExistence(timeout: 5))
        app.buttons["downloadsSwipeChange-left"].tap(); app.buttons["downloadsSwipeChoice-MARK_PLAYED"].tap(); app.buttons["downloadsSwipeConfirm"].tap()
        swipeEpisode(downloaded, left: true)
        XCTAssertTrue(app.staticTexts["No downloaded episodes"].waitForExistence(timeout: 10))
    }
    @MainActor func testPeriodicRefreshIntervalCancelNeverMobileRestartAndRelaunch() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        func openSettings() {
            app.buttons["navigationMore"].tap(); app.buttons["Settings"].tap(); app.buttons["prefScreenDownloads"].tap()
        }
        openSettings(); tapSetting("prefAutoUpdateIntervall", app)
        XCTAssertTrue(app.buttons["prefAutoUpdateIntervall-720"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["prefAutoUpdateIntervall-720"].isSelected)
        app.buttons["prefAutoUpdateIntervallCancel"].tap()
        tapSetting("prefAutoUpdateIntervall", app); app.buttons["prefAutoUpdateIntervall-0"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        openSettings(); tapSetting("prefAutoUpdateIntervall", app)
        XCTAssertTrue(app.buttons["prefAutoUpdateIntervall-0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["prefAutoUpdateIntervall-0"].isSelected)
        app.buttons["prefAutoUpdateIntervall-60"].tap()
        tapSetting("prefMobileUpdateTypes", app)
        XCTAssertTrue(app.buttons["prefMobileUpdateTypes-feed_refresh"].waitForExistence(timeout: 5))
        app.buttons["prefMobileUpdateTypes-feed_refresh"].tap(); app.buttons["prefMobileUpdateTypesConfirm"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10))
        openSettings(); tapSetting("prefAutoUpdateIntervall", app)
        XCTAssertTrue(app.buttons["prefAutoUpdateIntervall-60"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["prefAutoUpdateIntervall-60"].isSelected)
        app.buttons["prefAutoUpdateIntervallCancel"].tap()
    }

    @MainActor func testMobileUpdatesDraftConfirmationAndRestrictedStreaming() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), session = UUID().uuidString
        app.launchArguments = ["-test-library-id", session, "-test-muted-playback", "-test-restricted-streaming"]
        app.launch()
        XCTAssertTrue(app.staticTexts["welcomeTitle"].waitForExistence(timeout: 10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18771/feed.xml?session=\(session)")
        app.buttons["Confirm"].tapWhenSettled(); XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout: 15)); app.buttons["subscribeFeed"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label == %@", "Unplayed")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let action = app.buttons["episode-action-" + String(row.identifier.dropFirst("episode-".count))]
        app.buttons["navigationMore"].tap(); app.buttons["Settings"].tap(); app.buttons["prefScreenInterface"].tap()
        tapSetting("prefStreamOverDownload", app)
        app.buttons["toolbarBack"].tap(); app.buttons["toolbarBack"].tap()
        XCTAssertEqual(action.label, "Stream"); action.tap()
        XCTAssertTrue(app.buttons["streamingCancel"].waitForExistence(timeout: 5)); app.buttons["streamingCancel"].tap()
        app.buttons["navigationMore"].tap(); app.buttons["Settings"].tap(); app.buttons["prefScreenDownloads"].tap()
        tapSetting("prefMobileUpdateTypes", app)
        let uses = ["feed_refresh", "episode_download", "auto_download", "streaming", "images", "sync"]
        XCTAssertTrue(app.buttons["prefMobileUpdateTypes-images"].waitForExistence(timeout: 5))
        for key in uses { XCTAssertEqual(app.buttons["prefMobileUpdateTypes-" + key].isSelected, ["images", "sync"].contains(key)) }
        app.buttons["prefMobileUpdateTypes-streaming"].tap(); app.buttons["prefMobileUpdateTypesCancel"].tap()
        tapSetting("prefMobileUpdateTypes", app)
        XCTAssertTrue(app.buttons["prefMobileUpdateTypes-streaming"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["prefMobileUpdateTypes-streaming"].isSelected)
        for key in uses { app.buttons["prefMobileUpdateTypes-" + key].tap() }
        app.buttons["prefMobileUpdateTypesConfirm"].tap()
        app.buttons["toolbarBack"].tap(); app.buttons["toolbarBack"].tap()
        action.tap()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["streamingCancel"].exists)
        app.buttons["miniPlayerOpen"].tap()
        let position = app.staticTexts["playerPosition"]
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "00:00:00"), object: position)], timeout: 15)
        XCTAssertEqual(app.buttons["playerPlay"].label, "Pause"); app.buttons["playerPlay"].tap(); app.buttons["playerCollapse"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout: 10)); app.buttons["navigationMore"].tap(); app.buttons["Settings"].tap(); app.buttons["prefScreenDownloads"].tap()
        tapSetting("prefMobileUpdateTypes", app)
        XCTAssertTrue(app.buttons["prefMobileUpdateTypes-images"].waitForExistence(timeout: 5))
        for key in uses { XCTAssertEqual(app.buttons["prefMobileUpdateTypes-" + key].isSelected, !["images", "sync"].contains(key)) }
        app.buttons["prefMobileUpdateTypesCancel"].tap()
    }

    @MainActor private func tapSetting(_ id: String, _ app: XCUIApplication) {
        let row = app.buttons[id], scroll = app.scrollViews["libraryContent"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        for _ in 0..<12 where !row.isHittable || !scroll.frame.contains(row.frame) {
            if row.frame.midY < scroll.frame.minY { scroll.swipeDown() } else { scroll.swipeUp() }
        }
        XCTAssertTrue(row.isHittable && scroll.frame.contains(row.frame)); row.tap()
    }
    @MainActor private func swipeEpisode(_ row: XCUIElement, left: Bool) {
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.9 : 0.1, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.1 : 0.9, dy: 0.5))
        start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }
    @MainActor private func dismissContext(_ app: XCUIApplication) {
        let point = app.buttons["downloadsSearch"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)); point.tap()
    }
    @MainActor private func openSwipeSettings(_ app: XCUIApplication) {
        app.buttons["navigationMore"].tap(); app.buttons["Settings"].tap(); app.buttons["prefScreenInterface"].tap()
        let swipe = app.buttons["prefSwipe"], scroll = app.scrollViews["libraryContent"]
        for _ in 0..<8 where !swipe.isHittable || !scroll.frame.contains(swipe.frame) { scroll.swipeUp() }
        XCTAssertTrue(swipe.isHittable && scroll.frame.contains(swipe.frame)); swipe.tap()
        XCTAssertTrue(app.buttons["prefSwipeDownloads"].waitForExistence(timeout: 5)); app.buttons["prefSwipeDownloads"].tap()
        XCTAssertTrue(app.buttons["downloadsSwipeChange-left"].waitForExistence(timeout: 5))
    }
    @MainActor private func closeSettings(_ app: XCUIApplication) {
        for _ in 0..<3 { app.buttons["toolbarBack"].tap() }
        XCTAssertTrue(app.buttons["downloadsMore"].waitForExistence(timeout: 5))
    }
    @MainActor private func openDownloads(_ app: XCUIApplication) {
        app.buttons["navigationMore"].tap(); app.otherElements["morePopup"].buttons["Downloads"].tap()
        XCTAssertTrue(app.buttons["downloadsMore"].waitForExistence(timeout: 5))
    }
    @MainActor private func dismissSort(_ app: XCUIApplication) {
        let sheet = app.otherElements["feedSortSheet"]
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: sheet.frame.midX, dy: sheet.frame.minY - 20)).tap()
    }
    @MainActor private func count(_ session: String) async throws -> Int {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18771/count?session=\(session)")!)
        return (try JSONSerialization.jsonObject(with: data) as! [String: Int])["count"]!
    }
}
