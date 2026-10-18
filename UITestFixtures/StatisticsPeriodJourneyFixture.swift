#if DEBUG
import UIKit
import NotTennaPodCore

/// Explicit UUID test libraries only (`-test-library-id` + `-test-statistics-journey`). Seeds two
/// feeds whose listening history sits at known offsets from the seeding month, so the runner can
/// compute expected totals independently from the saved database:
/// Alpha: 2 h last played mid-month three months ago, 1 h played yesterday; Bravo: 30 min fourteen
/// months ago, plus a 1 h episode only marked as played (no listening time or date).
@MainActor enum StatisticsPeriodJourneyFixture {
    /// Written once the library is seeded; a library without it is emptied before it opens (`SeededLibraryFixtures`).
    nonisolated static let readyMarker = "statistics-fixture-ready"

    static func prepare(directory: URL, store: FeedLibraryStore) async throws {
        let marker = directory.appendingPathComponent(readyMarker)
        if !FileManager.default.fileExists(atPath: marker.path) {
            guard try await store.snapshot().feeds.isEmpty else { throw CocoaError(.fileWriteFileExists) }
            let calendar = Calendar.current, now = Date()
            let thisMonth = try require(calendar.dateInterval(of: .month, for: now)?.start)
            func midMonth(_ monthsAgo: Int) throws -> Int64 {
                let start = try require(calendar.date(byAdding: .month, value: -monthsAgo, to: thisMonth))
                return Int64(try require(calendar.date(byAdding: .hour, value: 14 * 24 + 12, to: start)).timeIntervalSince1970 * 1000)
            }
            let yesterday = Int64(now.addingTimeInterval(-24 * 3600).timeIntervalSince1970 * 1000)
            func rss(_ title: String, _ items: [(String, Int)]) -> String {
                "<rss version=\"2.0\" xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"><channel><title>\(title)</title>"
                    + items.map { "<item><guid isPermaLink=\"false\">\($0.0)</guid><title>\($0.0)</title><enclosure url=\"https://statistics.invalid/\($0.0).mp3\" length=\"1\" type=\"audio/mpeg\"/><itunes:duration>\($0.1)</itunes:duration></item>" }.joined()
                    + "</channel></rss>"
            }
            func insert(_ source: String, _ xml: String) async throws -> LibraryFeed {
                let result = try await FeedFetcher(transport: Transport(url: URL(string: source)!, body: Data(xml.utf8)))
                    .fetch(.init(source: source, generateMissingArtwork: false))
                guard case .updated(let fetched) = result else { throw CocoaError(.fileReadCorruptFile) }
                return try await store.insert(fetched)
            }
            let alpha = try await insert("https://alpha.statistics.invalid/feed", rss("Alpha statistics", [("a1", 7200), ("a2", 3600)]))
            let bravo = try await insert("https://bravo.statistics.invalid/feed", rss("Bravo statistics", [("b1", 1800), ("b2", 3600)]))
            func episode(_ feed: LibraryFeed, _ guid: String) throws -> Int64 {
                try require(feed.episodes.first { $0.details.identifier == guid }).id
            }
            func listened(_ id: Int64, milliseconds: Int64, at time: Int64) async throws {
                try await store.updateEpisode(id: id) {
                    $0.userState.playState = .played; $0.userState.playedDurationMilliseconds = milliseconds
                    $0.userState.lastPlayedTimeMilliseconds = time; $0.userState.lastPlayedHistoryMilliseconds = time
                }
            }
            try await listened(episode(alpha, "a1"), milliseconds: 7_200_000, at: midMonth(3))
            try await listened(episode(alpha, "a2"), milliseconds: 3_600_000, at: yesterday)
            try await listened(episode(bravo, "b1"), milliseconds: 1_800_000, at: midMonth(14))
            try await store.updateEpisode(id: episode(bravo, "b2")) { $0.userState.playState = .played }
            try Data("seeded; runner snapshots SQL/preferences before input\n".utf8).write(to: marker, options: .atomic)
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                if let controller = window.rootViewController as? LibraryViewController { await controller.reloadLibrary()?.value }
                window.accessibilityIdentifier = "statisticsFixtureReady"
            }
        }
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw CocoaError(.featureUnsupported) }
        return value
    }

    private struct Transport: FeedHTTPTransport {
        let url: URL
        let body: Data
        func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
            guard request.url == url else { throw URLError(.badURL) }
            return .init(url: url, status: 200, headers: ["Content-Type": "application/xml", "Content-Length": String(body.count)], body: body)
        }
    }
}
#endif
