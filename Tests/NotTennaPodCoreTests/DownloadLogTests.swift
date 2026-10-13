import Foundation
import Testing
@testable import NotTennaPodCore

struct DownloadLogTests {
    private func fixture(_ body: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadLog-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let feed = ParsedFeed(format: .rss, title: "Podcast", episodes: [
            ParsedEpisode(identifier: "one", title: "Episode", media: .init(url: "https://example.test/media", size: 100))])
        _ = try await store.insert(.init(feed: feed, source: "https://example.test/feed",
            responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
        do { try await body(store, directory); try await store.close() }
        catch { try? await store.close(); throw error }
    }
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    @Test func unifiedHistoryOrdersByCompletionRetainsRetriesAndSuppressesOnlyMatchingSuccess() async throws {
        try await fixture { store, directory in
            try await store.recordFailure(.httpStatus(500), feedID: 1, date: date(1))
            let job = try #require(try await store.requestDownload(episodeID: 1, directory: directory, now: date(2)))
            _ = try await store.beginDownloadAttempt(id: job.id, now: date(2))
            _ = try await store.recordDownloadFailure(id: job.id, attempt: 1, failure: .connection, now: date(3))
            _ = try await store.beginDownloadAttempt(id: job.id, now: date(34))
            try Data("media".utf8).write(to: job.destination)
            _ = try await store.attachDownloadFile(id: job.id, attempt: 2)
            _ = try await store.completeDownload(id: job.id, attempt: 2, now: date(35))
            let entries = try await store.downloadLog()
            #expect(entries.map(\.date) == [date(35), date(3), date(1)])
            #expect(entries.map(\.title) == ["Episode", "Episode", "Podcast"])
            #expect(entries.map { $0.canRetry(in: entries) } == [false, false, true])
            #expect(entries.map(\.statusKey) == ["download_successful", "download_error_connection_error", "download_error_http_data_error"])
            let reopened = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
            #expect(try await reopened.downloadLog() == entries)
            try await reopened.close()
        }
    }

    @Test func clearingHistoryPreservesRetryQueueAndFeedFailureAndNewCompletionReappears() async throws {
        try await fixture { store, directory in
            try await store.recordFailure(.unauthorized, feedID: 1, date: date(1))
            let job = try #require(try await store.requestDownload(episodeID: 1, directory: directory, now: date(2)))
            _ = try await store.beginDownloadAttempt(id: job.id, now: date(2))
            let failed = try #require(try await store.recordDownloadFailure(id: job.id, attempt: 1, failure: .connection, now: date(3)))
            let queue = try await store.queue()
            try await store.clearDownloadLog()
            #expect(try await store.downloadLog().isEmpty)
            #expect(try await store.logs(feedID: 1).isEmpty)
            #expect(try await store.feed(id: 1)?.lastUpdateFailed == true)
            var retained = failed; retained.logs = []
            #expect(try await store.downloadJob(id: job.id) == retained)
            #expect(try await store.queue() == queue)
            _ = try await store.beginDownloadAttempt(id: job.id, now: date(34))
            _ = try await store.recordDownloadFailure(id: job.id, attempt: 2, failure: .http(404), now: date(35))
            let result = try await store.downloadLog()
            #expect(result.count == 1 && result[0].id == .media(job: job.id, attempt: 2))
            #expect(result.first?.canRetry(in: result) == true)
        }
    }

    @Test func historyCapKeepsNewestTwoHundredAndClearReachesHiddenRows() async throws {
        try await fixture { store, _ in
            for i in 0..<205 { try await store.recordFailure(.connection, feedID: 1, date: date(Double(i))) }
            let history = try await store.downloadLog()
            #expect(history.count == 200 && history.first?.date == date(204) && history.last?.date == date(5))
            try await store.clearDownloadLog()
            #expect(try await store.logs(feedID: 1).isEmpty)
        }
    }

    @Test func mediaDetailsResolveCurrentOwnerAndMissingOwnerCannotOpenPodcast() async throws {
        try await fixture { store, directory in
            let job = try #require(try await store.requestDownload(episodeID: 1, directory: directory))
            _ = try await store.beginDownloadAttempt(id: job.id)
            _ = try await store.recordDownloadFailure(id: job.id, attempt: 1, failure: .http(404))
            let entry = try #require(try await store.downloadLog().first)
            let details = FeedLogDetails(entry: entry, feed: try await store.feed(id: 1), episode: try await store.episode(id: 1), text: { $0 })
            #expect(details.podcast == "Podcast" && details.episode == "Episode" && details.feedID == 1)
            #expect(details.fileURL == "https://example.test/media" && details.technical == "404")
            let absent = FeedLogDetails(entry: entry, feed: try await store.feed(id: 1), episode: nil, text: { $0 })
            #expect(absent.podcast == nil && absent.feedID == nil && absent.episode == "Episode" && absent.fileURL == "unknown")
        }
    }

    @Test func cancellationAndRangeRestartDoNotCreateSpuriousFailureRows() async throws {
        try await fixture { store, directory in
            let job = try #require(try await store.requestDownload(episodeID: 1, directory: directory))
            _ = try await store.beginDownloadAttempt(id: job.id)
            _ = try await store.recordDownloadFailure(id: job.id, attempt: 1, failure: .http(416))
            #expect(try await store.downloadLog().isEmpty)
            _ = try await store.cancelDownload(id: job.id)
            #expect(try await store.downloadLog().isEmpty)
        }
    }
}
