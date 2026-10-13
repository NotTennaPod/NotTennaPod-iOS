import Foundation
import Testing
@testable import NotTennaPodCore

/// Subscriptions/Archive/drawer order, counters and filter against the independent oracle (written from the
/// pinned source without reading this code). Libraries come from Android-schema databases through the
/// database import; expectations are in `TestSupport/Data/subscriptions-screen/expected`.
@Suite(.serialized) struct SubscriptionDisplayTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized
    static let evidence = root.appendingPathComponent("TestSupport/Data/subscriptions-screen")
    static let real = root.appendingPathComponent("TestSupport/Data/database-restore/android-3.12.1")
    static let orders = ["COUNTER": FeedOrder.counter, "ALPHABETICAL": .alphabetical, "MOST_RECENT_EPISODE": .mostRecentEpisode, "MOST_PLAYED": .mostPlayed]
    static let counters = ["SHOW_NEW": FeedCounter.showNew, "SHOW_UNPLAYED": .showUnplayed, "SHOW_DOWNLOADED": .showDownloaded,
                           "SHOW_DOWNLOADED_UNPLAYED": .showDownloadedUnplayed, "SHOW_NONE": .showNone]

    private func load(_ database: URL) async throws -> [LibraryFeed] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M21-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let restored = try AndroidDatabaseRestore.read(database, staging: directory.appendingPathComponent("s"))
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try await store.installRestoredLibrary(restored, carrying: try await store.restoreCarryOver())
        // The import brings Android downloads in as not downloaded; the fixture's downloaded media are
        // re-marked as downloaded on iOS so the downloaded counters have data.
        let android = try BackupSQLite(url: database, create: false); defer { try? android.close() }
        for row in try android.named("SELECT feeditem, downloaded FROM FeedMedia WHERE downloaded > 0") {
            try? await store.updateEpisode(id: row.long("feeditem")) {
                $0.userState.isDownloaded = true; $0.userState.localFileURL = "/fixture/\(row.long("feeditem")).mp3"
                $0.userState.downloadDate = Date(timeIntervalSince1970: Double(row.long("downloaded")) / 1000)
            }
        }
        let feeds = try await store.snapshot().feeds
        try await store.close()
        return feeds
    }
    private func json(_ name: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: Self.evidence.appendingPathComponent("expected/\(name).json"))) as! [String: Any]
    }
    private func ids(_ value: Any?) -> [Int64] { (value as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.int64Value } }
    private func preferences(_ expected: [String: Any]) -> (SubscriptionDisplayPreferences, Bool) {
        let prefs = expected["preferences"] as! [String: Any]
        func raw(_ key: String) -> Any? { (prefs[key] as? [String: Any])?["raw"] ?? prefs[key] }
        var value = SubscriptionDisplayPreferences()
        value.feedOrder = raw("prefDrawerFeedOrder") as? String ?? "0"
        value.feedCounter = raw("prefDrawerFeedIndicator") as? String ?? "1"
        value.subscriptionsFilter = raw("prefSubscriptionsFilter") as? String ?? ""
        return (value, (raw("prefEnableAutoDl") as? Bool) ?? false)
    }

    /// Checks the subscribed screen, archive and drawer of one oracle run; `matrix` adds all 4×5 orders.
    private func check(_ name: String, feeds: [LibraryFeed], matrix: Bool) throws {
        let expected = try json(name)
        let (prefs, globalAutoDownload) = preferences(expected)
        // SQL pre-order (raw title COLLATE NOCASE, ties by rowid).
        #expect(SubscriptionListQueries.preOrder(feeds).map(\.id) == ids(expected["sql_preorder_feed_ids"]), "\(name) pre-order")
        // Counters for every setting, subscribed feeds only.
        for (key, counter) in Self.counters {
            let oracle = (expected["counters_by_setting"] as? [String: Any])?[key] as? [String: Any] ?? [:]
            let values = Dictionary(uniqueKeysWithValues: oracle.map { (Int64($0.key)!, ($0.value as! NSNumber).intValue) }).filter { $0.value > 0 }
            #expect(SubscriptionListQueries.counters(feeds, counter) == values, "\(name) \(key) counters")
        }
        let subscribed = SubscriptionListQueries.load(feeds, preferences: prefs, state: .subscribed, globalAutoDownload: globalAutoDownload)
        let screen = expected["subscriptions"] as! [String: Any]
        if screen["load_error"] == nil {
            #expect(subscribed.feeds.map(\.id) == ids(screen["feed_ids"]), "\(name) subscriptions")
            for feed in screen["feeds"] as? [[String: Any]] ?? [] {
                let id = (feed["id"] as! NSNumber).int64Value
                #expect(subscribed.counters[id, default: 0] == (feed["counter"] as! NSNumber).intValue, "\(name) counter \(id)")
            }
            #expect(prefs.filter.isEnabled == (screen["filtered_message_visible"] as? Bool), "\(name) filtered bar")
            let drawer = expected["drawer"] as! [String: Any]
            #expect(subscribed.rootFeeds.map(\.id) == ids(drawer["root_feed_ids"]), "\(name) drawer root")
            let folders = (drawer["folders"] as? [[String: Any]] ?? []).map { [$0["title"] as! String] + ids($0["feed_ids"]).map(String.init) }
            #expect(subscribed.folders.filter { !FeedTags.equal($0.title, FeedTags.root) && !FeedTags.equal($0.title, FeedTags.untagged) }
                .map { [$0.title] + $0.feeds.map { String($0.id) } } == folders, "\(name) drawer folders")
            #expect(subscribed.counterSum == (drawer["subscriptions_entry_counter"] as! NSNumber).intValue, "\(name) entry counter")
        }
        let archive = SubscriptionListQueries.load(feeds, preferences: prefs, state: .archived, globalAutoDownload: globalAutoDownload)
        let archiveJSON = expected["archive"] as! [String: Any]
        #expect(archive.feeds.map(\.id) == ids(archiveJSON["feed_ids"]), "\(name) archive")
        #expect(archive.feeds.allSatisfy { archive.counters[$0.id] == nil }, "\(name) archive has no counters")
        guard matrix else { return }
        for (key, value) in expected["matrix_subscribed_feed_ids"] as? [String: Any] ?? [:] {
            let parts = key.split(separator: "/").map(String.init)
            var combination = prefs
            combination.feedOrder = Self.orders[parts[0]]!.stored; combination.feedCounter = Self.counters[parts[1]]!.stored
            let actual = SubscriptionListQueries.load(feeds, preferences: combination, state: .subscribed, globalAutoDownload: globalAutoDownload).feeds.map(\.id)
            if value is [Any] { #expect(actual == ids(value), "\(name) \(key)") }
        }
    }

    @Test func syntheticFixturesMatchTheOracle() async throws {
        let mixed = try await load(Self.evidence.appendingPathComponent("databases/mixed.db"))
        // The failure icon follows the imported `last_update_failed` (only feed 7 in the fixture).
        #expect(mixed.filter(\.lastUpdateFailed).map(\.id) == [7])
        try check("mixed", feeds: mixed, matrix: true)
        for name in ["f-counter", "f-counter-none", "f-ad-on", "f-ad-on-global", "f-ad-off", "f-up-on", "f-up-off",
                     "f-nt-on", "f-nt-off", "f-combo", "f-unknown", "open-folders"] {
            try check("mixed-" + name, feeds: mixed, matrix: false)
        }
        for name in ["archiveonly", "empty"] {
            try check(name, feeds: try await load(Self.evidence.appendingPathComponent("databases/\(name).db")), matrix: true)
        }
    }

    @Test func realAndroidLibrariesMatchTheOracle() async throws {
        for name in ["emulator-parity-library", "archived-credentials-library", "authentication-preview-library", "first-journey-downloaded"] {
            try check(name, feeds: try await load(Self.real.appendingPathComponent("\(name).db")), matrix: true)
        }
    }

    /// The source throws on a null display title in a counter tie (perpetual progress bar);
    /// here the orders that do not throw match the oracle and the throwing ones place null titles last.
    @Test func nullTitleDoesNotBreakTheList() async throws {
        let feeds = try await load(Self.evidence.appendingPathComponent("databases/nulltitle.db"))
        let expected = try json("nulltitle")
        #expect((expected["subscriptions"] as! [String: Any])["load_error"] != nil, "the oracle reproduces the source exception")
        for (key, value) in expected["matrix_subscribed_feed_ids"] as? [String: Any] ?? [:] {
            let parts = key.split(separator: "/").map(String.init)
            var prefs = SubscriptionDisplayPreferences()
            prefs.feedOrder = Self.orders[parts[0]]!.stored; prefs.feedCounter = Self.counters[parts[1]]!.stored
            let actual = SubscriptionListQueries.load(feeds, preferences: prefs, state: .subscribed, globalAutoDownload: false).feeds
            #expect(actual.count == feeds.filter { $0.subscriptionState == .subscribed }.count, "\(key) lists every feed")
            if value is [Any] {
                #expect(actual.map(\.id) == ids(value), "\(key)")
            } else {
                // Within each counter value, titled feeds come first in case-insensitive order.
                let values = parts[0] == "COUNTER" ? SubscriptionListQueries.counters(feeds, prefs.counter)
                    : SubscriptionListQueries.count(feeds) { $0.userState.playState == .played }
                for (a, b) in zip(actual, actual.dropFirst()) where values[a.id, default: 0] == values[b.id, default: 0] {
                    #expect(!(a.title == nil && b.title != nil), "\(key): null title \(a.id) before \(b.id)")
                }
            }
        }
    }

    @Test func javaStringSemantics() {
        let compare = SubscriptionListQueries.compareToIgnoreCase
        #expect(compare("alpha", "ALPHA") == 0)
        #expect(compare("İstanbul", "istanbul") == 0)
        #expect(compare("Äpfel", "Zebra") > 0)
        #expect(compare("ßRadio", "Zebra") > 0)
        #expect(compare("ssradio", "ßRadio") < 0)
        #expect(compare("\u{1FB3}", "\u{1FBC}") == 0)
        #expect(compare("😀", "\u{FF21}") < 0, "char-based: a surrogate unit sorts before U+FF21")
        #expect(compare("ab", "abc") == -1)
        // Stored values and fallbacks (FeedOrder/FeedCounter.fromOrdinal; non-numeric → default).
        #expect(FeedOrder(stored: "9") == .mostRecentEpisode && FeedOrder(stored: "x") == .counter && FeedOrder(stored: "3") == .mostPlayed)
        #expect(FeedCounter(stored: "0") == .showNone && FeedCounter(stored: "") == .showNew && FeedCounter(stored: "5") == .showDownloadedUnplayed)
        #expect(SubscriptionsFilter(stored: "").isEnabled == false && SubscriptionsFilter(stored: "show_non_subscribed").isEnabled)
        #expect(SubscriptionDisplayPreferences.defaultColumns(smallestWidth: 599) == 3 && SubscriptionDisplayPreferences.defaultColumns(smallestWidth: 600) == 5)
    }

    /// Every filter selection is saved and read back exactly (the Java HashSet token order of the
    /// saved string is not compared: it is only read by this app and has no visible effect).
    @Test func filterSelectionRoundTrips() {
        var selections: [[String]] = [[]]
        for row in SubscriptionsFilter.rows {
            selections = selections.flatMap { base in [base] + row.map { base + [$0.token] } }
        }
        #expect(selections.count == 54)
        for selection in selections {
            let restored = SubscriptionsFilter(stored: SubscriptionsFilter.serialized(Set(selection)))
            #expect(restored.tokens.count == selection.count && Set(restored.tokens) == Set(selection), "\(selection)")
            #expect(restored.isEnabled == !selection.isEmpty)
        }
    }
}
