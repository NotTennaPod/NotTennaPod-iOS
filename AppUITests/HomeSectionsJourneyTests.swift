import XCTest

/// Actual journey on a UUID library seeded from an Android database (DEBUG hook, through the database
/// import) with a pinned Surprise seed and Home clock. The expectation is the independent oracle's output
/// for the same database, seed and time (`rich.db`, seed 12345, now 1790000000000 ms);
/// `M20_EXPECTED`/`M20_DATABASE` may override both.
/// Home (default page) → sections, order, items, badge and "more" targets match the oracle →
/// Shuffle draws a different valid selection → Configure: hide Continue listening by dragging it below
/// "Hidden", OK → hidden and kept after relaunch → Reset restores the default.
@MainActor final class HomeSectionsJourneyTests: XCTestCase {
    /// Fresh per test: the seed is installed once per library and test02 changes the saved Home sections.
    private let library = UUID().uuidString
    private var app = XCUIApplication()
    private var expected: [String: Any] = [:]

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestSupport/Data/home-sections")
        let path = environment["M20_EXPECTED"] ?? fixtures.appendingPathComponent("expected/journey-rich.json").path
        expected = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let now = try XCTUnwrap(expected["now_ms"] as? NSNumber).int64Value
        app.launchArguments = ["-test-library-id", library, "-test-muted-playback", "-test-home-surprise-seed", "12345",
                               "-test-home-now-ms", String(now),
                               "-test-seed-android-database", environment["M20_DATABASE"] ?? fixtures.appendingPathComponent("databases/rich.db").path]
    }
    private func section(_ tag: String) -> [String: Any]? {
        (expected["sections"] as? [[String: Any]])?.first { $0["tag"] as? String == tag }
    }
    private func ids(_ value: Any?) -> [Int64] { (value as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.int64Value } }
    /// Identifiers and frames of matching elements, read from one accessibility snapshot. Reading the frame and the
    /// identifier of index-bound elements one query at a time can pair one element's frame with another's identifier
    /// when the tree is re-read between queries (once the screen showed Continue listening above See
    /// what's new while the per-element reads reported the reverse).
    private func elements(_ root: XCUIElement, type: XCUIElement.ElementType? = nil,
                          _ matches: (String) -> Bool) -> [(id: String, frame: CGRect)] {
        guard let snapshot = try? root.snapshot() else { return [] }
        var found: [(id: String, frame: CGRect)] = []
        func walk(_ node: any XCUIElementSnapshot) {
            if (type == nil || node.elementType == type), matches(node.identifier) { found.append((node.identifier, node.frame)) }
            node.children.forEach(walk)
        }
        walk(snapshot)
        return found
    }
    private func stripIDs(_ strip: String, prefix: String) -> [Int64] {
        elements(app.scrollViews[strip]) { $0.hasPrefix(prefix) }.sorted { $0.frame.minX < $1.frame.minX }
            .compactMap { Int64($0.id.dropFirst(prefix.count)) }
    }
    private func titles() -> [String] {
        elements(app, type: .staticText) { $0.hasPrefix("homeSectionTitle-") }.sorted { $0.frame.minY < $1.frame.minY }
            .map { String($0.id.dropFirst("homeSectionTitle-".count)) }
    }
    private func rowIDs(below header: String, above next: String?) -> [Int64] {
        let titles = Dictionary(elements(app, type: .staticText) { $0.hasPrefix("homeSectionTitle-") }.map { ($0.id, $0.frame) },
                                uniquingKeysWith: { first, _ in first })
        let top = titles["homeSectionTitle-" + header]?.maxY ?? .greatestFiniteMagnitude
        let bottom = next.flatMap { titles["homeSectionTitle-" + $0]?.minY } ?? .greatestFiniteMagnitude
        return elements(app, type: .button) { $0.range(of: "^episode-[0-9]+$", options: .regularExpression) != nil }
            .filter { $0.frame.midY > top && $0.frame.midY < bottom }.sorted { $0.frame.minY < $1.frame.minY }
            .compactMap { Int64($0.id.dropFirst("episode-".count)) }
    }

    func test01SectionsMatchTheOracleAndShuffle() {
        app.launch()
        XCTAssertTrue(app.staticTexts["homeSectionTitle-QueueSection"].waitForExistence(timeout: 30), app.debugDescription)
        // Home may still be rendering its last sections when the first title appears.
        let visible = expected["visible_section_tags"] as? [String]
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in MainActor.assumeIsolated { self.titles() == visible } }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed, "sections \(titles())")
        XCTAssertEqual(stripIDs("homeQueueStrip", prefix: "homeEpisode-"), ids(section("QueueSection")?["item_ids"]))
        XCTAssertEqual(stripIDs("homeSurpriseStrip", prefix: "homeEpisode-"), ids(section("EpisodesSurpriseSection")?["item_ids"]))
        XCTAssertEqual(stripIDs("homeClassicsStrip", prefix: "homeFeed-"), ids(section("SubscriptionsSection")?["feed_ids"]))
        let inbox = section("InboxSection")
        XCTAssertEqual(rowIDs(below: "InboxSection", above: "EpisodesSurpriseSection").count, ids(inbox?["item_ids"]).count)
        XCTAssertEqual(Set(rowIDs(below: "InboxSection", above: "EpisodesSurpriseSection")), Set(ids(inbox?["item_ids"])))
        if let badge = inbox?["badge"] as? [String: Any] { XCTAssertEqual(app.staticTexts["homeInboxBadge"].label, badge["text"] as? String) }
        XCTAssertEqual(app.buttons["homeMore-QueueSection"].label, "Queue")
        XCTAssertEqual(app.buttons["homeMore-SubscriptionsSection"].label, "Subscriptions")

        // Shuffle: a new source seed; the selection stays one-per-feed from the candidates.
        let before = stripIDs("homeSurpriseStrip", prefix: "homeEpisode-")
        let candidates = Set((section("EpisodesSurpriseSection")?["candidate_episode_ids_by_feed"] as? [String: Any] ?? [:]).values.flatMap { ids($0) })
        app.buttons["homeShuffle"].tap()
        let after = stripIDs("homeSurpriseStrip", prefix: "homeEpisode-")
        XCTAssertEqual(after.count, before.count)
        XCTAssertTrue(Set(after).isSubset(of: candidates), "\(after)")

        // "more" opens the source destination.
        app.buttons["homeMore-SubscriptionsSection"].tap()
        XCTAssertTrue(app.staticTexts["screenTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["screenTitle"].label, "Subscriptions")
        app.terminate()
    }

    func test02ConfigureHidesPersistsAndResets() {
        app.launch()
        XCTAssertTrue(app.staticTexts["homeSectionTitle-QueueSection"].waitForExistence(timeout: 30), app.debugDescription)
        app.buttons["homeMore"].tap()
        XCTAssertTrue(app.buttons["homeConfigure"].waitForExistence(timeout: 5)); app.buttons["homeConfigure"].tap()
        let queue = app.otherElements["homeConfigure-QueueSection"], hidden = app.staticTexts["homeConfigureHidden"]
        XCTAssertTrue(queue.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(queue.value as? String, "Shown")
        queue.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).press(forDuration: 0.3,
            thenDragTo: hidden.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.6)))
        XCTAssertEqual(queue.value as? String, "Hidden", app.debugDescription)
        app.buttons["homeConfigureOK"].tap()
        XCTAssertTrue(app.staticTexts["homeSectionTitle-InboxSection"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["homeSectionTitle-QueueSection"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["homeSectionTitle-InboxSection"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["homeSectionTitle-QueueSection"].exists, "Hidden section stays hidden after relaunch")
        app.buttons["homeMore"].tap(); app.buttons["homeConfigure"].tap()
        XCTAssertTrue(app.buttons["homeConfigureReset"].waitForExistence(timeout: 10)); app.buttons["homeConfigureReset"].tap()
        XCTAssertTrue(app.staticTexts["homeSectionTitle-QueueSection"].waitForExistence(timeout: 10), "Reset restores the default")
        XCTAssertEqual(titles(), ["QueueSection", "InboxSection", "EpisodesSurpriseSection", "SubscriptionsSection", "DownloadsSection"])
        app.terminate()
    }
}
