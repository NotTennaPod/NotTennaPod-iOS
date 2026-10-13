import Foundation
import Testing
@testable import NotTennaPodCore

/// Source `DBWriter.resetStatistics` sets every media's played duration to 0 in one transaction
/// and changes nothing else. Native playback stores an absolute session baseline, so the reset must
/// also rebase an active session; otherwise the next sample would restore the erased total.
@Suite(.serialized) struct StatisticsResetTests {
    private func withStore(_ body: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StatisticsReset-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        try await body(store, url)
        try await store.close()
    }
    private func seeded(_ store: FeedLibraryStore) async throws -> LibraryFeed {
        try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Reset fixture", episodes: [
            .init(identifier: "a", title: "A", media: .init(url: "fixture://a", size: 1, durationMilliseconds: 3_600_000)),
            .init(identifier: "b", title: "B", media: .init(url: "fixture://b", size: 1, durationMilliseconds: 1_800_000)),
            .init(identifier: "c", title: "C", media: .init(url: "fixture://c", size: 1, durationMilliseconds: 600_000))]),
            source: "https://example.test/reset", responseURL: URL(string: "https://example.test/reset")!, validator: nil))
    }
    private func id(_ feed: LibraryFeed, _ guid: String) throws -> Int64 {
        try #require(feed.episodes.first { $0.details.identifier == guid }).id
    }

    @Test func zeroesOnlyPlayedDurationForEveryEpisodeAndPersists() async throws {
        try await withStore { store, url in
            let feed = try await seeded(store)
            try await store.updateEpisode(id: id(feed, "a")) {
                $0.userState.playState = .played; $0.userState.playedDurationMilliseconds = 3_000_000
                $0.userState.lastPlayedTimeMilliseconds = 1_700_000_000_000; $0.userState.lastPlayedHistoryMilliseconds = 1_700_000_000_000
            }
            try await store.updateEpisode(id: id(feed, "b")) {
                $0.userState.positionMilliseconds = 90_000; $0.userState.playedDurationMilliseconds = 90_000
                $0.userState.lastPlayedTimeMilliseconds = 1_710_000_000_000
            }
            try await store.updatePreferences(feedID: feed.id) { $0.customTitle = "Renamed" }
            _ = try await store.enqueue([id(feed, "b"), id(feed, "c")])
            let before = try #require(try await store.feed(id: feed.id))
            let queueBefore = try await store.queue().map(\.id)

            try await store.resetPlayedDurationStatistics()

            let after = try #require(try await store.feed(id: feed.id))
            #expect(after.episodes.allSatisfy { $0.userState.playedDurationMilliseconds == 0 })
            var expected = before
            for index in expected.episodes.indices { expected.episodes[index].userState.playedDurationMilliseconds = 0 }
            #expect(after == expected, "Only played duration changes")
            #expect(try await store.queue().map(\.id) == queueBefore)
            // Repeating the reset is harmless.
            try await store.resetPlayedDurationStatistics()
            #expect(try await store.feed(id: feed.id) == expected)
            try await store.close()
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.feed(id: feed.id) == expected)
            try await reopened.close()
        }
    }

    @Test func activeAndLateSamplesCannotRestoreErasedTotals() async throws {
        try await withStore { store, _ in
            let feed = try await seeded(store)
            let episode = try id(feed, "a")
            try await store.updateEpisode(id: episode) { $0.userState.playedDurationMilliseconds = 600_000 }
            let session = try await store.beginPlayback(episodeID: episode, positionMilliseconds: 60_000)
            _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 120_000, durationMilliseconds: 3_600_000, status: .playing))
            #expect(try await store.feed(id: feed.id)?.episodes.first { $0.id == episode }?.userState.playedDurationMilliseconds == 660_000)

            try await store.resetPlayedDurationStatistics()
            #expect(try await store.feed(id: feed.id)?.episodes.first { $0.id == episode }?.userState.playedDurationMilliseconds == 0)

            // A late sample from before the reset (older position) adds nothing.
            _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 100_000, durationMilliseconds: 3_600_000, status: .playing))
            #expect(try await store.feed(id: feed.id)?.episodes.first { $0.id == episode }?.userState.playedDurationMilliseconds == 0)
            // Continued listening counts only from the reset point (120 s → 180 s).
            _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 180_000, durationMilliseconds: 3_600_000, status: .playing))
            #expect(try await store.feed(id: feed.id)?.episodes.first { $0.id == episode }?.userState.playedDurationMilliseconds == 60_000)
        }
    }

    @Test func failedWriteRollsBackEveryEpisode() async throws {
        try await withStore { store, url in
            let feed = try await seeded(store)
            for (guid, played) in [("a", Int64(1_000)), ("b", 2_000), ("c", 3_000)] {
                try await store.updateEpisode(id: id(feed, guid)) { $0.userState.playedDurationMilliseconds = played }
            }
            let before = try await store.feed(id: feed.id)
            let db = try LibrarySQLite(url: url)
            let last = try id(feed, "c")
            try db.execute("CREATE TRIGGER reject_reset BEFORE UPDATE ON episodes WHEN NEW.id = \(last) BEGIN SELECT RAISE(ABORT, 'fixture failure'); END")
            await #expect(throws: (any Error).self) { try await store.resetPlayedDurationStatistics() }
            #expect(try await store.feed(id: feed.id) == before, "All-or-nothing: no partial reset")
            try db.execute("DROP TRIGGER reject_reset")
            try db.close()
            try await store.resetPlayedDurationStatistics()
            #expect(try await store.feed(id: feed.id)?.episodes.allSatisfy { $0.userState.playedDurationMilliseconds == 0 } == true)
        }
    }
}
