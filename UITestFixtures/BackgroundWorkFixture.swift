#if DEBUG
import Foundation
import NotTennaPodCore

/// Background work journey input: a Download log with entries on both sides of the 7-day retention, created
/// through the ordinary refresh-log and download-attempt records with dates relative to launch.
enum BackgroundWorkFixture {
    static func seedDownloadLog(store: FeedLibraryStore, directory: URL) async throws {
        guard try await store.downloadLog().isEmpty else { return } // Seeded once per test library.
        let now = Date()
        func feed(_ title: String, _ key: String, episode: String) async throws -> Int64 {
            // Real parser metadata from an in-memory document; no network.
            let source = "http://127.0.0.1:9/\(key).xml"
            let xml = "<rss version=\"2.0\"><channel><title>\(title)</title><item><guid>\(key)</guid><title>\(episode)</title>"
                + "<enclosure url=\"http://127.0.0.1:9/\(key).mp3\" type=\"audio/mpeg\" length=\"100\"/></item></channel></rss>"
            let result = try await FeedFetcher(transport: Transport(url: URL(string: source)!, body: Data(xml.utf8)))
                .fetch(.init(source: source, generateMissingArtwork: false))
            guard case .updated(let fetched) = result else { throw CocoaError(.fileReadCorruptFile) }
            let id = try await store.insert(fetched).id
            // Not refreshed by the app (its address does not exist), so no new log entries appear.
            try await store.updatePreferences(feedID: id) { $0.keepUpdated = false }
            return id
        }
        let kept = try await feed("Kept podcast", "kept", episode: "Recent episode")
        let pruned = try await feed("Pruned podcast", "pruned", episode: "Old episode")
        // Feed refresh failures: 6 d 23 h (kept) and 7 d + 1 min (deleted by the first maintenance).
        try await store.recordFailure(.httpStatus(503), feedID: kept, date: now.addingTimeInterval(-(6 * 86_400 + 23 * 3_600)))
        try await store.recordFailure(.httpStatus(503), feedID: pruned, date: now.addingTimeInterval(-(7 * 86_400 + 60)))
        // Media attempts: 1 h (kept) and 8 days (deleted).
        let media = directory.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for (feedID, age) in [(kept, 3_600.0), (pruned, 8 * 86_400.0)] {
            guard let episode = try await store.feed(id: feedID)?.episodes.first?.id,
                  let job = try await store.requestDownload(episodeID: episode, directory: media, now: now.addingTimeInterval(-age)),
                  try await store.beginDownloadAttempt(id: job.id, now: now.addingTimeInterval(-age)) != nil,
                  try await store.recordDownloadFailure(id: job.id, attempt: 1, failure: .http(404), now: now.addingTimeInterval(-age)) != nil
            else { throw FeedLibraryError.invalidMutation }
        }
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
