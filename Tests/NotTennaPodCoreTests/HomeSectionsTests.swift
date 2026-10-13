import Foundation
import Testing
@testable import NotTennaPodCore

/// Home section contents against the independent oracle, written from the pinned source without
/// reading this code. Libraries come from Android-schema databases through the database import;
/// expectations use a fixed clock and Surprise seed. Items the
/// source orders without a tiebreaker (reported by the oracle) may appear in any order, and any member
/// of a tie that crosses the limit may be shown.
@Suite(.serialized) struct HomeSectionsTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized
    static let evidence = root.appendingPathComponent("TestSupport/Data/home-sections")
    static let now: Int64 = 1_790_000_000_000

    struct Expected {
        let json: [String: Any]
        var welcome: Bool { ((json["welcome"] as? [String: Any])?["welcome_visible"] as? Bool) ?? false }
        var tags: [String] { json["visible_section_tags"] as? [String] ?? [] }
        func section(_ tag: String) -> [String: Any]? { (json["sections"] as? [[String: Any]])?.first { $0["tag"] as? String == tag } }
    }

    private func load(_ database: URL) async throws -> (feeds: [LibraryFeed], queue: [LibraryEpisode]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M20-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let restored = try AndroidDatabaseRestore.read(database, staging: directory.appendingPathComponent("s"))
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try await store.installRestoredLibrary(restored, carrying: try await store.restoreCarryOver())
        // The import brings Android downloads in as not downloaded (their files are Android paths); the
        // fixture's downloaded episodes are re-marked as if downloaded on iOS, so Manage downloads has data.
        let android = try BackupSQLite(url: database, create: false); defer { try? android.close() }
        for row in try android.named("SELECT feeditem, downloaded FROM FeedMedia WHERE downloaded > 0") {
            let when = Date(timeIntervalSince1970: Double(row.long("downloaded")) / 1000)
            try? await store.updateEpisode(id: row.long("feeditem")) {
                $0.userState.isDownloaded = true; $0.userState.localFileURL = "/fixture/\(row.long("feeditem")).mp3"; $0.userState.downloadDate = when
            }
        }
        let snapshot = try await store.snapshot()
        try await store.close()
        return (snapshot.feeds, snapshot.queue)
    }

    /// Order must match except inside source tie groups; a tie crossing the limit may pick any member.
    private func expectIDs(_ actual: [Int64], _ section: [String: Any], key: String, _ label: String) {
        let expected = (section[key] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.int64Value }
        let ties = (section["ties"] as? [[String: Any]] ?? []).map { tie in
            Set(((tie["ids"] ?? tie["feed_ids"]) as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.int64Value })
        }
        #expect(actual.count == expected.count, "\(label): \(actual) vs \(expected)")
        for (index, (a, e)) in zip(actual, expected).enumerated() where a != e {
            let group = ties.first { $0.contains(e) }
            #expect(group?.contains(a) == true, "\(label)[\(index)]: \(a) vs \(e) (\(actual) vs \(expected))")
        }
    }

    private func check(_ name: String, database: URL, seed: Int32, preferences: HomeSectionPreferences = .init(),
                       includeMarked: Bool = false) async throws {
        let expected = Expected(json: try JSONSerialization.jsonObject(with: Data(contentsOf: Self.evidence.appendingPathComponent("expected/\(name).json"))) as! [String: Any])
        let (feeds, queue) = try await load(database)
        #expect(HomeSectionQueries.showsWelcome(feeds) == expected.welcome, "\(name) welcome")
        #expect(preferences.sections.map(\.rawValue) == expected.tags, "\(name) section order")
        let date = Date(timeIntervalSince1970: Double(Self.now) / 1000)
        for section in preferences.sections {
            let json = try #require(expected.section(section.rawValue), "\(name) \(section)")
            switch section {
            case .queue:
                expectIDs(HomeSectionQueries.continueListening(queue: queue, now: Self.now).map(\.id), json, key: "item_ids", "\(name) queue")
            case .inbox:
                let inbox = HomeSectionQueries.inbox(feeds)
                expectIDs(inbox.items.map(\.1.id), json, key: "item_ids", "\(name) inbox")
                if let badge = json["badge"] as? [String: Any], badge["visible"] as? Bool == true {
                    #expect(HomeSectionQueries.badge(inbox.total) == badge["text"] as? String, "\(name) badge")
                }
            case .surprise:
                expectIDs(HomeSectionQueries.surprise(feeds, seed: seed, now: Self.now).map(\.1.id), json, key: "item_ids", "\(name) surprise")
            case .classics:
                expectIDs(try HomeSectionQueries.classics(feeds, includeMarkedAsPlayed: includeMarked, now: date).map(\.id), json, key: "feed_ids", "\(name) classics")
            case .downloads:
                let downloaded = DownloadsList.episodes(feeds.flatMap(\.episodes), jobs: [], order: nil)
                expectIDs(Array(downloaded.prefix(2)).map(\.id), json, key: "item_ids", "\(name) downloads")
            }
        }
    }

    @Test(arguments: ["empty", "states", "rich", "ties"])
    func syntheticLibrariesMatchTheOracle(_ name: String) async throws {
        try await check(name, database: Self.evidence.appendingPathComponent("databases/\(name).db"), seed: 12345)
    }

    @Test(arguments: ["archived-credentials-library", "authentication-preview-library", "emulator-parity-library", "first-journey-downloaded"])
    func realAndroidLibrariesMatchTheOracle(_ name: String) async throws {
        try await check(name, database: Self.root.appendingPathComponent("TestSupport/Data/database-restore/android-3.12.1/\(name).db"), seed: 12345)
    }

    @Test func hiddenReorderedNegativeSeedAndMarkedPlayedVariant() async throws {
        try await check("rich-variant", database: Self.evidence.appendingPathComponent("databases/rich.db"), seed: -987_654_321,
                        preferences: .init(hidden: "InboxSection", order: "DownloadsSection,QueueSection"), includeMarked: true)
    }

    @Test func preferencesFollowHomePreferences() {
        #expect(HomeSectionPreferences().sections == HomeSection.allCases)
        let unknown = HomeSectionPreferences(hidden: "Nope,SubscriptionsSection", order: "Mystery,InboxSection")
        #expect(unknown.sections == [.inbox, .queue, .surprise, .downloads], "Listed first, others in default order, hidden removed")
        #expect(unknown.dialogHidden == [.classics])
        let confirmed = HomeSectionPreferences.confirmed(shown: [.downloads, .queue], hidden: [.inbox, .surprise, .classics])
        #expect(confirmed == .init(hidden: "InboxSection,EpisodesSurpriseSection,SubscriptionsSection",
                                   order: "DownloadsSection,QueueSection,InboxSection,EpisodesSurpriseSection,SubscriptionsSection"))
        #expect(HomeSectionPreferences.confirmed(shown: HomeSection.allCases, hidden: []).sections == HomeSection.allCases)
        #expect(HomeSectionQueries.badge(99) == "99" && HomeSectionQueries.badge(100) == "99+")
    }
}
