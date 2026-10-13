import XCTest

final class PlayerChaptersJourneyTests: XCTestCase {
    @MainActor func testCoverChapterSeeksDialogPlayRefreshAndRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout:10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout:5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18807/feed.xml")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout:15)); app.buttons["subscribeFeed"].tap()
        let episode = app.buttons["episode-action-1"]
        XCTAssertTrue(episode.waitForExistence(timeout:5)); episode.tap(); label(episode,"Play")
        episode.tap(); label(app.buttons["miniPlayerPlay"],"Pause"); app.buttons["miniPlayerPlay"].tap()
        app.buttons["miniPlayerOpen"].tap(); label(app.buttons["playerPlay"],"Play")
        let chapters = app.buttons["playerChapters"], next = app.buttons["playerNextChapter"], previous = app.buttons["playerPreviousChapter"]
        XCTAssertTrue(chapters.waitForExistence(timeout:15) && chapters.isHittable)
        XCTAssertEqual(chapters.label, "Chapters")
        XCTAssertEqual(previous.label, "Previous chapter")
        XCTAssertEqual(next.label, "Next chapter")
        XCTAssertEqual(chapters.frame.midY, app.buttons["playerShownotes"].frame.midY, accuracy:1)
        next.tap(); label(app.staticTexts["playerPosition"],"00:00:10")
        label(app.buttons["playerPlay"],"Play")
        let nextSlot = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx:next.frame.midX-app.frame.minX,dy:next.frame.midY-app.frame.minY))
        next.tap(); label(app.staticTexts["playerPosition"],"00:00:20")
        XCTAssertFalse(next.isHittable)
        nextSlot.tap()
        XCTAssertTrue(app.buttons["chaptersClose"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["Chapters"].exists)
        app.buttons["chaptersClose"].tap()
        previous.tap(); label(app.staticTexts["playerPosition"],"00:00:10")
        chapters.tap()
        XCTAssertTrue(app.buttons["chapterPlay-2"].waitForExistence(timeout:10))
        XCTAssertEqual(app.buttons["chapterPlay-2"].label, "Play chapter")
        XCTAssertTrue(app.staticTexts["Middle"].exists)
        app.buttons["chaptersRefresh"].tap()
        XCTAssertTrue(app.buttons["chapterPlay-2"].waitForExistence(timeout:10))
        app.buttons["chapterPlay-2"].tap()
        XCTAssertTrue(app.buttons["chaptersClose"].exists)
        app.buttons["chaptersClose"].tap(); label(app.buttons["playerPlay"],"Pause")
        app.buttons["playerPlay"].tap(); label(app.buttons["playerPlay"],"Play")
        let paused = app.staticTexts["playerPosition"].label
        XCTAssertTrue(paused.hasPrefix("00:00:2"))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout:10)); app.buttons["miniPlayerOpen"].tap()
        label(app.buttons["playerPlay"],"Play")
        XCTAssertTrue(chapters.waitForExistence(timeout:15) && chapters.isHittable)
        XCTAssertEqual(app.staticTexts["playerPosition"].label,paused)
        chapters.tap(); XCTAssertTrue(app.buttons["chapterPlay-2"].waitForExistence(timeout:10))
        app.buttons["chaptersClose"].tap()
    }
    @MainActor func testArtworkLinksAndForegroundRestoration() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout:10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout:5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18807/rich-feed.xml")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout:15)); app.buttons["subscribeFeed"].tap()
        let episode = app.buttons["episode-action-1"]
        XCTAssertTrue(episode.waitForExistence(timeout:5)); episode.tap(); label(episode,"Play")
        episode.tap(); label(app.buttons["miniPlayerPlay"],"Pause"); app.buttons["miniPlayerPlay"].tap()
        app.buttons["miniPlayerOpen"].tap(); label(app.buttons["playerPlay"],"Play")
        let chapters = app.buttons["playerChapters"]
        XCTAssertTrue(chapters.waitForExistence(timeout:15) && chapters.isHittable)
        chapters.tap()
        XCTAssertTrue(app.buttons["chapterPlay-3"].waitForExistence(timeout:10))
        let row = app.cells["chapterRow-0"]
        func point(_ rowIndex: Int, _ dx: CGFloat = 44, _ dy: CGFloat = 0) -> CGPoint {
            CGPoint(x:app.cells["chapterRow-\(rowIndex)"].frame.minX+dx,
                    y:app.buttons["chapterPlay-\(rowIndex)"].frame.midY+dy)
        }
        // Each chapter shows its own artwork (red, blue), a chapter without artwork shows the
        // podcast artwork (green) and unavailable artwork shows the grey placeholder.
        shows(.red,at:point(0),in:app)
        shows(.blue,at:point(1),in:app)
        shows(.green,at:point(2),in:app)
        shows(.gray,at:point(3),in:app)
        XCTAssertTrue(row.exists)
        let table = app.tables["chaptersList"]
        table.swipeUp()
        let last = app.cells["chapterRow-3"]
        XCTAssertLessThanOrEqual(last.frame.maxY,table.frame.maxY+1)
        XCTAssertTrue(app.buttons["chapterPlay-3"].isHittable)
        shows(.gray,at:point(3),in:app)
        table.swipeDown()
        XCTAssertTrue(app.buttons["chapterLink-0"].isHittable)
        app.buttons["chapterLink-0"].tap()
        let browser = XCUIApplication(bundleIdentifier:"com.apple.mobilesafari")
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"state == %d",XCUIApplication.State.runningForeground.rawValue),object:browser)],timeout:15),.completed)
        XCTAssertTrue(browser.staticTexts["Chapter destination"].waitForExistence(timeout:10))
        app.activate()
        XCTAssertTrue(app.buttons["chaptersClose"].waitForExistence(timeout:10))
        shows(.red,at:point(0),in:app)
        app.buttons["chaptersClose"].tap(); label(app.buttons["playerPlay"],"Play")
        app.buttons["playerNextChapter"].tap(); label(app.staticTexts["playerPosition"],"00:00:10")
        label(app.buttons["playerPlay"],"Play")
    }
    @MainActor func testUnavailableChapterLinkShowsNoticeAndRetainsDialog() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id", UUID().uuidString, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout:10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout:5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18807/failed-link-feed.xml")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout:15)); app.buttons["subscribeFeed"].tap()
        let episode = app.buttons["episode-action-1"]
        XCTAssertTrue(episode.waitForExistence(timeout:5)); episode.tap(); label(episode,"Play")
        episode.tap(); label(app.buttons["miniPlayerPlay"],"Pause"); app.buttons["miniPlayerPlay"].tap()
        app.buttons["miniPlayerOpen"].tap(); label(app.buttons["playerPlay"],"Play")
        let paused = app.staticTexts["playerPosition"].label
        XCTAssertTrue(app.buttons["playerChapters"].waitForExistence(timeout:15))
        app.buttons["playerChapters"].tap()
        XCTAssertTrue(app.buttons["chapterLink-0"].waitForExistence(timeout:10))
        app.buttons["chapterLink-0"].tap()
        let notice = app.staticTexts["applicationNotice"]
        let appeared = notice.waitForExistence(timeout:2)
        XCTAssertTrue(appeared)
        XCTAssertEqual(notice.label,"No web browser found.")
        XCTAssertTrue(notice.isHittable)
        XCTAssertTrue(app.buttons["chaptersClose"].isHittable)
        XCTAssertEqual(app.state,.runningForeground)
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:notice)],timeout:6),.completed)
        app.buttons["chapterLink-0"].tap()
        XCTAssertTrue(notice.waitForExistence(timeout:2))
        app.buttons["chaptersClose"].tap()
        XCTAssertTrue(notice.exists && notice.isHittable)
        label(app.buttons["playerPlay"],"Play")
        XCTAssertEqual(app.staticTexts["playerPosition"].label,paused)
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:notice)],timeout:6),.completed)
    }
    @MainActor func testChapterRotationRetainsScrolledDialogPlaybackAndRefresh() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), run = UUID().uuidString
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        func control(_ path: String) async throws -> [String:Any] {
            let separator = path.contains("?") ? "&" : "?"
            let (data,response) = try await URLSession.shared.data(from:URL(string:"http://127.0.0.1:18809/\(path)\(separator)run=\(run)")!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
            return try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        }
        func gate(_ key: String) async throws {
            let deadline = ContinuousClock.now + .seconds(8)
            while ContinuousClock.now < deadline {
                if try await control("state")[key] as? Bool == true { return }
                try await Task.sleep(for:.milliseconds(20))
            }
            XCTFail("Fixture did not reach \(key)")
        }
        func rotate(_ orientation: UIDeviceOrientation, landscape: Bool) {
            XCUIDevice.shared.orientation = orientation
            // The Duo Simulator does not resize the window on rotation (NavigationQueries.rotationResizesWindow),
            // so waiting there only let the 30 s episode run out during the playing pass.
            guard XCUIDevice.rotationResizesWindow else { return }
            let expectation = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in landscape ? app.frame.width > app.frame.height : app.frame.height > app.frame.width },object:nil)
            XCTAssertEqual(XCTWaiter.wait(for:[expectation],timeout:8),.completed,"Requested rotation did not produce the expected app viewport: \(app.frame)")
        }
        let table = app.tables["chaptersList"]
        func firstVisibleChapter() -> String? {
            // One accessibility snapshot: querying 20 cells one by one took about 8 s on the Duo.
            guard let snapshot = try? table.snapshot() else { return nil }
            let bounds = snapshot.frame
            func cells(_ node: any XCUIElementSnapshot) -> [any XCUIElementSnapshot] {
                node.elementType == .cell ? [node] : node.children.flatMap(cells)
            }
            return cells(snapshot).first { $0.frame.intersection(bounds).height > 1 && $0.frame.intersects(bounds) }?.identifier
        }
        app.launchArguments = ["-test-library-id",run,"-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout:10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout:5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18809/feed.xml?count=20&run=\(run)")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout:15)); app.buttons["subscribeFeed"].tap()
        let episode = app.buttons["episode-action-1"]
        XCTAssertTrue(episode.waitForExistence(timeout:5)); episode.tap(); label(episode,"Play")
        episode.tap(); label(app.buttons["miniPlayerPlay"],"Pause"); app.buttons["miniPlayerPlay"].tap()
        app.buttons["miniPlayerOpen"].tap(); label(app.buttons["playerPlay"],"Play")
        for playing in [false,true] {
            let paused = app.staticTexts["playerPosition"].label
            if playing { app.buttons["playerPlay"].tap(); label(app.buttons["playerPlay"],"Pause") }
            app.buttons["playerChapters"].tap()
            XCTAssertTrue(app.buttons["chapterPlay-0"].waitForExistence(timeout:10))
            table.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.7)).press(forDuration:0.1,thenDragTo:table.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.4)))
            let anchor = try XCTUnwrap(firstVisibleChapter())
            XCTAssertNotEqual(anchor,"chapterRow-0")
            rotate(.landscapeLeft,landscape:true)
            XCTAssertTrue(app.buttons["chaptersClose"].isHittable && app.buttons["chaptersRefresh"].isHittable)
            XCTAssertTrue(app.scrollViews["chaptersPanel"].frame.contains(app.buttons["chaptersClose"].frame))
            XCTAssertTrue(app.scrollViews["chaptersPanel"].frame.contains(app.buttons["chaptersRefresh"].frame))
            XCTAssertEqual(firstVisibleChapter(),anchor)
            _ = try await control("arm?result=chapters")
            app.buttons["chaptersRefresh"].tap(); try await gate("held")
            XCTAssertTrue(app.activityIndicators["chaptersLoading"].exists)
            rotate(.portrait,landscape:false)
            XCTAssertTrue(app.activityIndicators["chaptersLoading"].exists)
            XCTAssertTrue(app.buttons["chaptersClose"].isHittable)
            _ = try await control("release"); try await gate("completed")
            XCTAssertTrue(app.activityIndicators["chaptersLoading"].waitForNonExistence(timeout:8))
            app.buttons["chaptersClose"].tap(); label(app.buttons["playerPlay"],playing ? "Pause" : "Play")
            if playing { app.buttons["playerPlay"].tap(); label(app.buttons["playerPlay"],"Play") }
            else { XCTAssertEqual(app.staticTexts["playerPosition"].label,paused) }
        }
        app.buttons["playerChapters"].tap()
        XCTAssertTrue(app.buttons["chapterPlay-0"].waitForExistence(timeout:10))
        let panel = app.scrollViews["chaptersPanel"]
        rotate(.landscapeLeft,landscape:true)
        app.buttons["chaptersClose"].tap(); app.buttons["playerChapters"].tap()
        XCTAssertTrue(app.buttons["chaptersClose"].waitForExistence(timeout:5))
        // A dialog opened in landscape, then rotated, stays on screen with its controls reachable.
        XCTAssertTrue(app.frame.contains(panel.frame) && app.buttons["chaptersClose"].isHittable)
        rotate(.portrait,landscape:false)
        XCTAssertTrue(app.frame.contains(panel.frame) && app.buttons["chaptersClose"].isHittable)
        app.buttons["chaptersClose"].tap(); label(app.buttons["playerPlay"],"Play")
    }
    @MainActor func testHeldRefreshDismissalKeepsNewDialogAndPlayback() async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), run = UUID().uuidString
        func control(_ path: String) async throws -> [String:Any] {
            let (data,response) = try await URLSession.shared.data(from:URL(string:"http://127.0.0.1:18809/\(path)?run=\(run)")!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
            return try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        }
        func gate(_ key: String) async throws {
            let deadline = ContinuousClock.now + .seconds(8)
            while ContinuousClock.now < deadline {
                if try await control("state")[key] as? Bool == true { return }
                try await Task.sleep(for:.milliseconds(20))
            }
            XCTFail("Fixture did not reach \(key)")
        }
        app.launchArguments = ["-test-library-id",run,"-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout:10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout:5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18809/feed.xml?run=\(run)")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout:15)); app.buttons["subscribeFeed"].tap()
        let episode = app.buttons["episode-action-1"]
        XCTAssertTrue(episode.waitForExistence(timeout:5)); episode.tap(); label(episode,"Play")
        episode.tap(); label(app.buttons["miniPlayerPlay"],"Pause"); app.buttons["miniPlayerPlay"].tap()
        app.buttons["miniPlayerOpen"].tap(); label(app.buttons["playerPlay"],"Play")
        let paused = app.staticTexts["playerPosition"].label
        for outside in [false,true] {
            app.buttons["playerChapters"].tap()
            XCTAssertTrue(app.buttons["chapterPlay-0"].waitForExistence(timeout:10))
            XCTAssertEqual(app.buttons["chapterPlay-0"].label,"Play chapter")
            XCTAssertEqual(app.buttons["chapterLink-0"].label,"https://example.invalid/chapter/0")
            XCTAssertTrue(app.buttons["chapterPlay-0"].isHittable && app.buttons["chapterLink-0"].isHittable)
            _ = try await control("arm"); app.buttons["chaptersRefresh"].tap(); try await gate("held")
            XCTAssertTrue(app.activityIndicators["chaptersLoading"].exists)
            if outside {
                let panel = app.scrollViews["chaptersPanel"]
                XCTAssertGreaterThan(panel.frame.minY,app.frame.minY+10)
                app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:panel.frame.midX-app.frame.minX,dy:panel.frame.minY-app.frame.minY-8)).tap()
            } else { app.buttons["chaptersClose"].tap() }
            XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:app.buttons["chaptersClose"])],timeout:5),.completed)
            app.buttons["playerChapters"].tap()
            XCTAssertTrue(app.buttons["chapterPlay-2"].waitForExistence(timeout:10))
            _ = try await control("release"); try await gate("completed")
            XCTAssertTrue(app.buttons["chaptersClose"].isHittable && app.staticTexts["Opening"].exists)
            app.buttons["chaptersClose"].tap(); label(app.buttons["playerPlay"],"Play")
            XCTAssertEqual(app.staticTexts["playerPosition"].label,paused)
        }
    }
    /// Leaving the app and returning (by switching to Settings, which backgrounds the app as Home does and also works
    /// on the Duo) reloads the dialog on the current chapter and keeps the paused or playing intent.
    @MainActor func testChapterForegroundReloadThroughAppSwitch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id",UUID().uuidString,"-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout:10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout:5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18807/text-feed.xml")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout:15)); app.buttons["subscribeFeed"].tap()
        let episode = app.buttons["episode-action-1"]
        XCTAssertTrue(episode.waitForExistence(timeout:5)); episode.tap(); label(episode,"Play")
        episode.tap(); label(app.buttons["miniPlayerPlay"],"Pause"); app.buttons["miniPlayerPlay"].tap()
        app.buttons["miniPlayerOpen"].tap(); label(app.buttons["playerPlay"],"Play")
        let paused = app.staticTexts["playerPosition"].label
        let current = Int(paused.split(separator:":").last!)!
        app.buttons["playerChapters"].tap()
        let table = app.tables["chaptersList"], selected = app.buttons["chapterPlay-\(current)"]
        XCTAssertTrue(selected.waitForExistence(timeout:15))
        for _ in 0..<15 {
            if app.buttons["chapterPlay-19"].isHittable { break }
            table.swipeUp()
        }
        XCTAssertTrue(app.buttons["chapterPlay-19"].isHittable)
        XCTAssertFalse(selected.isHittable)
        XCUIApplication(bundleIdentifier:"com.apple.Preferences").activate()
        XCTAssertTrue(app.wait(for:.runningBackground,timeout:5),"App state after background request: \(app.state.rawValue)")
        app.activate()
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"hittable == true"),object:selected)],timeout:8),.completed)
        XCTAssertTrue(app.buttons["chaptersClose"].exists)
        XCTAssertEqual(selected.label,"Play chapter")
        XCTAssertEqual(app.buttons["chaptersRefresh"].label,"Refresh")
        app.buttons["chaptersClose"].tap(); label(app.buttons["playerPlay"],"Play")
        XCTAssertEqual(app.staticTexts["playerPosition"].label,paused)
        app.buttons["playerPlay"].tap(); label(app.buttons["playerPlay"],"Pause")
        app.buttons["playerChapters"].tap(); XCTAssertTrue(app.buttons["chaptersClose"].waitForExistence(timeout:5))
        XCUIApplication(bundleIdentifier:"com.apple.Preferences").activate()
        XCTAssertTrue(app.wait(for:.runningBackground,timeout:5),"App state after background request: \(app.state.rawValue)"); app.activate()
        XCTAssertTrue(app.buttons["chaptersClose"].waitForExistence(timeout:5))
        app.buttons["chaptersClose"].tap(); label(app.buttons["playerPlay"],"Pause")
        app.buttons["playerPlay"].tap(); label(app.buttons["playerPlay"],"Play")
        let stopped = app.staticTexts["playerPosition"].label
        app.buttons["playerChapters"].tap(); XCTAssertTrue(app.buttons["chaptersClose"].waitForExistence(timeout:5))
        app.buttons["chaptersClose"].tap(); label(app.buttons["playerPlay"],"Play")
        XCTAssertEqual(app.staticTexts["playerPosition"].label,stopped)
    }
    /// Accessibility text size (set for this launch only): the wrapped rows, their links and the final row stay inside
    /// the list and reachable. Default-size wrapping and the last row are covered by the view test
    /// `wrappedChapterRenderingAndLastRowSurviveTextAndViewportChanges` and by the foreground journey above.
    @MainActor func testEnlargedChapterTextAndFinalRow() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-test-library-id",UUID().uuidString,"-test-muted-playback",
            "-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityM"]
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout:10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout:5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18807/text-feed.xml")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout:15)); app.buttons["subscribeFeed"].tap()
        let episode = app.buttons["episode-action-1"]
        XCTAssertTrue(episode.waitForExistence(timeout:5)); episode.tap(); label(episode,"Play")
        episode.tap(); label(app.buttons["miniPlayerPlay"],"Pause"); app.buttons["miniPlayerPlay"].tap()
        app.buttons["miniPlayerOpen"].tap(); label(app.buttons["playerPlay"],"Play")
        let paused = app.staticTexts["playerPosition"].label
        app.buttons["playerChapters"].tap()
        let table = app.tables["chaptersList"], final = app.cells["chapterRow-19"]
        XCTAssertTrue(app.buttons["chapterLink-0"].waitForExistence(timeout:15))
        let first = app.cells["chapterRow-0"], link = app.buttons["chapterLink-0"]
        // A row counts as fully visible when it lies inside the list, within a point.
        func visible(_ row: XCUIElement) -> Bool { row.exists && table.frame.insetBy(dx:-1,dy:-1).contains(row.frame) }
        // Opening centers the selected chapter; navigate to the top for the source comparison.
        for _ in 0..<10 {
            if visible(first) { break }
            table.swipeDown()
        }
        XCTAssertTrue(visible(first))
        XCTAssertTrue(first.frame.contains(link.frame) && table.frame.contains(link.frame))
        for _ in 0..<20 {
            if visible(final) { break }
            table.swipeUp()
        }
        XCTAssertTrue(visible(final))
        XCTAssertTrue(table.frame.contains(app.buttons["chapterLink-19"].frame))
        let duration = final.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@","Duration:")).firstMatch
        XCTAssertTrue(duration.exists && table.frame.contains(duration.frame))
        XCTAssertTrue(app.buttons["chapterLink-19"].isHittable)
        XCTAssertTrue(app.buttons["chapterPlay-19"].isHittable)
        XCTAssertTrue(app.buttons["chaptersClose"].isHittable)
        app.buttons["chaptersClose"].tap(); label(app.buttons["playerPlay"],"Play")
        XCTAssertEqual(app.staticTexts["playerPosition"].label,paused)
    }
    @MainActor func testGatedStreamLoadingAndChapterSeekRecovery() async throws {
        try await gatedLoadingJourney(kind:"mp3")
    }
    @MainActor func testGatedHLSLoadingAndChapterSeekRecovery() async throws {
        try await gatedLoadingJourney(kind:"hls")
    }
    @MainActor private func gatedLoadingJourney(kind: String) async throws {
        continueAfterFailure = false
        let app = XCUIApplication(), run = UUID().uuidString
        func release(_ fraction: Double) async throws {
            let (_, response) = try await URLSession.shared.data(from:URL(string:"http://127.0.0.1:18808/release?run=\(run)&fraction=\(fraction)")!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
        }
        app.launchArguments = ["-test-library-id", run, "-test-muted-playback"]
        app.launch()
        XCTAssertTrue(app.buttons["navigationMore"].waitForExistence(timeout:10))
        app.buttons["navigationMore"].tap(); app.buttons["Add podcast"].tap(); app.buttons["addRSS"].tap()
        let address = app.textFields["rssAddress"]
        XCTAssertTrue(address.waitForExistence(timeout:5)); address.tap(); address.typeTextSettled("http://127.0.0.1:18808/feed.xml?run=\(run)&kind=\(kind)")
        app.buttons["Confirm"].tapWhenSettled()
        XCTAssertTrue(app.buttons["subscribeFeed"].waitForExistence(timeout:15)); app.buttons["subscribeFeed"].tap()
        XCTAssertTrue(app.buttons["episode-1"].waitForExistence(timeout:5)); app.buttons["episode-1"].tap()
        XCTAssertTrue(app.buttons["episodePrimaryAction"].waitForExistence(timeout:5))
        XCTAssertEqual(app.buttons["episodePrimaryAction"].label,"Stream"); app.buttons["episodePrimaryAction"].tap()
        XCTAssertTrue(app.buttons["miniPlayerOpen"].waitForExistence(timeout:10)); app.buttons["miniPlayerOpen"].tap()
        let loading = app.otherElements["playerLoading"]
        XCTAssertTrue(loading.waitForExistence(timeout:10))
        try await release(0.5)
        XCTAssertTrue(loading.waitForNonExistence(timeout:20))
        let position = app.staticTexts["playerPosition"]
        let initial = position.label
        await fulfillment(of:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"label != %@",initial),object:position)],timeout:10)
        XCTAssertTrue(app.buttons["playerNextChapter"].isHittable)
        app.buttons["playerNextChapter"].tap(); app.buttons["playerNextChapter"].tap()
        label(position,"00:00:25")
        XCTAssertTrue(loading.waitForExistence(timeout:10))
        app.buttons["playerPlay"].tap(); label(app.buttons["playerPlay"],"Play")
        XCTAssertTrue(loading.exists)
        try await release(1)
        XCTAssertTrue(loading.waitForNonExistence(timeout:20))
        label(app.buttons["playerPlay"],"Play")
        XCTAssertTrue(position.label.hasPrefix("00:00:25"))
        app.buttons["playerPlay"].tap(); label(app.buttons["playerPlay"],"Pause")
        let paused = position.label
        await fulfillment(of:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"label != %@",paused),object:position)],timeout:10)
        app.buttons["playerPlay"].tap(); label(app.buttons["playerPlay"],"Play")
    }
    private enum Tint { case red, green, blue, gray }
    /// Loosely classifies the colour shown at `point`: enough to tell which artwork is displayed,
    /// without depending on exact colour rendering.
    @MainActor private func shows(_ tint: Tint, at point: CGPoint, in app: XCUIApplication) {
        let expectation = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
            let shot = app.screenshot().image
            guard let image = shot.cgImage else { return false }
            let sx = CGFloat(image.width)/app.frame.width, sy = CGFloat(image.height)/app.frame.height
            guard let cropped = image.cropping(to:CGRect(x:(point.x-app.frame.minX)*sx,y:(point.y-app.frame.minY)*sy,width:1,height:1)) else { return false }
            var bytes = [UInt8](repeating:0,count:4)
            bytes.withUnsafeMutableBytes { memory in
                let context = CGContext(data:memory.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,
                    space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(cropped,in:CGRect(x:0,y:0,width:1,height:1))
            }
            let r = Int(bytes[0]), g = Int(bytes[1]), b = Int(bytes[2])
            switch tint {
            case .red: return r > g + 80 && r > b + 80
            case .green: return g > r + 60 && g > b + 60
            case .blue: return b > r + 80 && b > g + 80
            case .gray: return max(r,g,b) - min(r,g,b) < 24 && (100...235).contains(r)
            }
        },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[expectation],timeout:12),.completed,"Expected \(tint) artwork at \(point)")
    }
    @MainActor private func label(_ element: XCUIElement,_ expected: String) {
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"label == %@",expected),object:element)],timeout:20),.completed)
    }
}
