import Foundation
import Testing
@testable import NotTennaPodCore

/// Tables and files that grow with use stay bounded, and the Download log's duplicate-episode entries show
/// Android's explanation with both episodes (stored as that text, not as two whole parsed episodes).
@Suite struct LibraryStorageGrowthTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func withLibrary(_ operation: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StorageGrowth-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        do { try await operation(store, url); try await store.close() }
        catch { try? await store.close(); throw error }
    }

    private func episode(_ id: String?, title: String?, url: String?, notes: String = String(repeating: "Long show notes. ", count: 400)) -> ParsedEpisode {
        ParsedEpisode(identifier: id, title: title, description: notes, publicationDate: now,
                      media: url.map { ParsedMedia(url: $0, size: 1_000, mimeType: "audio/mpeg", durationMilliseconds: 60_000) })
    }

    private func fetched(_ episodes: [ParsedEpisode]) -> FetchedFeed {
        FetchedFeed(feed: ParsedFeed(format: .rss, title: "Feed", episodes: episodes), source: "https://example.test/feed",
                    responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil)
    }

    @Test func repeatedEpisodeLogShowsAndroidReasonWithBothEpisodes() async throws {
        try await withLibrary { store, url in
            let feed = try await store.insert(fetched([episode("a", title: "Same", url: "https://example.test/a.mp3")]),
                                              options: .init(now: now, timeZone: .gmt))
            // The host lists the episode again under another ID and the same media URL.
            _ = try await store.applyRefresh(fetched([episode("a", title: "Same", url: "https://example.test/a.mp3"),
                                                      episode("a2", title: "Same", url: "https://example.test/a.mp3")]),
                                             feedID: feed.id, options: .init(now: now, timeZone: .gmt))
            let log = try #require(try await store.logs(feedID: feed.id).first { if case .duplicate = $0.kind { true } else { false } })
            #expect(log.title == "Same")
            #expect(log.detail == """
                The podcast host appears to have added the same episode twice. NotTennaPod still refreshed the feed and attempted to repair it.

                Original episode:
                Title: Same
                ID: a2
                URL: https://example.test/a.mp3

                Second episode that is also in the feed:
                Title: Same
                ID: a
                URL: https://example.test/a.mp3
                """)
            let details = FeedLogDetails(log: log, feed: feed, text: { $0 })
            #expect(details.technical == log.detail && details.statusKey == "download_error_parser_exception")
            #expect(details.clipboard.contains("Second episode that is also in the feed:"))
            // Stored as the shown text, not two copies of the parsed episodes with their show notes.
            let db = try LibrarySQLite(url: url)
            #expect(try db.scalar("SELECT max(length(record)) FROM refresh_log") < 2_000)
            try db.close()
        }
    }

    @Test func changedIdentifierLogShowsAndroidReasonAndMissingValuesAsNull() throws {
        let previous = episode("old", title: "Episode", url: nil)
        let replacement = episode(nil, title: nil, url: "https://example.test/b.mp3")
        let duplicate = FeedRefreshResult.Duplicate.changedIdentifier(previous: previous, replacement: replacement, episodeID: 7)
        #expect(duplicate.detail == """
            The podcast host changed the ID of an existing episode instead of just updating the episode itself. NotTennaPod still refreshed the feed and attempted to repair it.

            Original episode:
            Title: Episode
            ID: old

            Now the feed contains:
            Title: null
            ID: null
            URL: https://example.test/b.mp3
            """)
        // A row saved before the text was stored still shows it.
        let legacy = FeedLibraryLog(feedID: 1, date: now, title: nil, kind: .duplicate(duplicate))
        #expect(FeedLogDetails(log: legacy, feed: nil, text: { $0 }).technical == duplicate.detail)
    }

    @Test func maintenanceRemovesOnlyOldFinishedJobsWithoutLogEntries() async throws {
        try await withLibrary { store, url in
            let episodes = (1...5).map { episode("\($0)", title: "Episode \($0)", url: "https://example.test/\($0).mp3", notes: "") }
            _ = try await store.insert(fetched(episodes), options: .init(now: now, timeZone: .gmt))
            let directory = url.deletingLastPathComponent()
            func job(_ episodeID: Int64, at date: Date) async throws -> LibraryDownloadJob {
                try #require(try await store.requestDownload(episodeID: episodeID, directory: directory, enqueue: false, now: date))
            }
            let old = now.addingTimeInterval(-30 * 86_400)
            let cancelledOld = try await job(1, at: old)
            _ = try await store.cancelDownload(id: cancelledOld.id, now: old)
            let keepsPartial = try await job(2, at: old)
            let attempt = try #require(try await store.beginDownloadAttempt(id: keepsPartial.id, now: old))
            try Data("partial".utf8).write(to: keepsPartial.destination)
            #expect(try await store.attachDownloadFile(id: keepsPartial.id, attempt: attempt.attempts))
            // A cancelled job whose partial file is still the episode's file (kept for resumption).
            try await store.updateEpisode(id: 2) { $0.userState.localFileURL = keepsPartial.destination.path }
            let db = try LibrarySQLite(url: url)
            try db.execute("UPDATE download_jobs SET active = 0, record = CAST(json_set(CAST(record AS TEXT), '$.state', 'cancelled') AS BLOB) WHERE id = ?",
                           [.integer(keepsPartial.id)])
            try db.close()
            let cancelledRecent = try await job(3, at: now)
            _ = try await store.cancelDownload(id: cancelledRecent.id, now: now)
            let active = try await job(4, at: old)

            _ = try await store.pruneDownloadLog(beforeMilliseconds: Int64(now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970 * 1_000))
            let remaining = try await store.downloadJobs(activeOnly: false).map(\.id)
            #expect(remaining == [keepsPartial.id, cancelledRecent.id, active.id])
        }
    }

    /// Apple's SQLite truncates the WAL after a checkpoint (`DEFAULT_JOURNAL_SIZE_LIMIT=32768`), so a large write
    /// does not leave a large -wal file behind; this guards that the library keeps that behaviour.
    @Test func downloadJobsAreIndexedByEpisodeAndTheWALIsTruncatedAfterALargeWrite() async throws {
        try await withLibrary { store, url in
            let check = try LibrarySQLite(url: url)
            #expect(try check.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 'download_jobs_by_episode'") == 1)
            try check.close()
            // About 16 MB in one transaction, then an ordinary write.
            let notes = String(repeating: "x", count: 16_000)
            let large = (0..<1_000).map { episode("e\($0)", title: "Episode \($0)", url: "https://example.test/\($0).mp3", notes: notes) }
            let feed = try await store.insert(fetched(large), options: .init(now: now, timeZone: .gmt))
            try await store.markEpisodePlayed(episodeID: feed.episodes[0].id, played: true)
            let wal = url.deletingLastPathComponent().appendingPathComponent("library.sqlite-wal")
            let size = try #require(try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? NSNumber).intValue
            #expect(size <= 1_048_576)
        }
    }
}
