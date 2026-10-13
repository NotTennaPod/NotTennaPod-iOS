import Foundation
import Testing
@testable import NotTennaPodCore

struct LibraryQueueTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func fetched(_ count: Int = 6) -> FetchedFeed {
        let items = (1...count).map { number in
            ParsedEpisode(identifier: "\(number)", title: "Episode \(number)", publicationDate: now.addingTimeInterval(Double(number)),
                          media: number == 5 ? nil : ParsedMedia(url: "https://example.test/\(number).mp3", size: 32_768, durationMilliseconds: 30_000))
        }
        return FetchedFeed(feed: ParsedFeed(format: .rss, title: "Queue fixture", episodes: items),
                           source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
                           validator: nil, permanentRedirectURL: nil)
    }

    private func withStore(_ operation: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AntennaPodQueue-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        do { try await operation(store, url); try await store.close() }
        catch { try? await store.close(); throw error }
    }

    @Test func batchOrderDuplicateSuppressionAndInboxTransitionSurviveReopen() async throws {
        try await withStore { store, url in
            _ = try await store.insert(fetched())
            try await store.updateEpisode(id: 1) { $0.userState.playState = .new; $0.userState.isFavorite = true }
            try await store.updateEpisode(id: 2) { $0.userState.playState = .played; $0.userState.positionMilliseconds = 3_883 }
            let change = try await store.enqueue([2, 1, 2, 5, 99, 3])
            #expect(change.episodeIDs == [2, 1, 3])
            #expect(change.events == [.added(episodeID: 2, index: 0), .added(episodeID: 1, index: 1), .added(episodeID: 3, index: 2)])
            #expect(change.requestsAutoDownload)
            #expect(try await store.episode(id: 1)?.userState.playState == .unplayed)
            #expect(try await store.episode(id: 1)?.userState.isFavorite == true)
            #expect(try await store.episode(id: 2)?.userState.playState == .played)
            #expect(try await store.episode(id: 2)?.userState.positionMilliseconds == 3_883)
            try await store.close()
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.queue().map(\.id) == [2, 1, 3])
            #expect(try await reopened.queueAutoDownloadRequested())
            #expect(try await reopened.enqueue([1, 2]).events.isEmpty)
            #expect(try await reopened.queue().map(\.id) == [2, 1, 3])
            try await reopened.close()
        }
    }

    @Test func frontAndAfterCurrentCalculateOncePerBatchAndSkipDownloadingPrefix() async throws {
        for location in [EnqueueLocation.front, .afterCurrentlyPlaying] {
            try await withStore { store, _ in
                _ = try await store.insert(fetched())
                _ = try await store.enqueue([1, 2, 3])
                let playing: PlayingItem? = location == .front ? nil : .episode(1)
                let change = try await store.enqueue([4, 6], location: location, playing: playing,
                                                     downloadingURLs: ["https://example.test/1.mp3", "https://example.test/2.mp3"])
                #expect(change.episodeIDs == [1, 2, 4, 6, 3])
                #expect(change.events == [.added(episodeID: 4, index: 2), .added(episodeID: 6, index: 3)])
            }
        }
    }

    @Test func refreshQueueRecoveryUsesPersistedCurrentEpisodeAndDownloadingPrefix() async throws {
        try await withStore { store, url in
            let feed = try await store.insert(fetched(3))
            _ = try await store.enqueue([1, 2, 3])
            _ = try await store.beginPlayback(episodeID: 1)
            _ = try await store.requestDownload(episodeID: 2, directory: url.deletingLastPathComponent(), enqueue: false)
            try await store.updatePreferences(feedID: feed.id) { $0.newEpisodesAction = .queue }
            _ = try await store.applyRefresh(fetched(6), feedID: feed.id)
            #expect(try await store.queue().map(\.id) == [1, 2, 3])
            let reopened = try FeedLibraryStore(url: url)
            let changes = try await reopened.consumeFeedRefreshQueueEffects(location: .afterCurrentlyPlaying)
            #expect(changes.count == 1)
            #expect(try await reopened.queue().map(\.id) == [1, 2, 4, 6, 3])
            #expect(try await store.consumeFeedRefreshQueueEffects().isEmpty)
            #expect(try await store.queue().map(\.id) == [1, 2, 4, 6, 3])
            try await reopened.close()
        }
    }

    @Test func randomPlacementUsesOneInclusiveSlotForWholeBatch() async throws {
        for slot in 0...2 {
            try await withStore { store, _ in
                _ = try await store.insert(fetched())
                _ = try await store.enqueue([1, 2])
                let change = try await store.enqueue([3, 4], location: .random, randomIndex: { range in
                    #expect(range == 0...2)
                    return slot
                })
                let expected: [[Int64]] = [[3, 4, 1, 2], [1, 3, 4, 2], [1, 2, 3, 4]]
                #expect(change.episodeIDs == expected[slot])
            }
        }
    }

    @Test func explicitInsertionAllowsMediaLessEpisodeAndChecksIndexOnlyWhenInserting() async throws {
        try await withStore { store, _ in
            _ = try await store.insert(fetched())
            #expect(try await store.enqueueAt(5, index: 0).episodeIDs == [5])
            #expect(try await store.enqueueAt(5, index: -1).events.isEmpty)
            #expect(try await store.enqueueAt(99, index: 99).events.isEmpty)
            await #expect(throws: FeedLibraryError.invalidMutation) { try await store.enqueueAt(1, index: -1) }
            await #expect(throws: FeedLibraryError.invalidMutation) { try await store.enqueueAt(1, index: 2) }
            #expect(try await store.enqueueAt(1, index: 1).episodeIDs == [5, 1])
        }
    }

    @Test func moveRemoveAndClearPreserveListeningStateAndSourceEventOrder() async throws {
        try await withStore { store, _ in
            _ = try await store.insert(fetched())
            _ = try await store.enqueue([1, 2, 3, 4])
            try await store.updateEpisode(id: 1) { $0.userState.positionMilliseconds = 400; $0.userState.playState = .played }
            #expect(try await store.moveQueueItem(from: 0, to: 3).episodeIDs == [2, 3, 4, 1])
            #expect(try await store.moveQueueItem(from: -1, to: 0).events.isEmpty)
            #expect(try await store.moveQueueItem(from: 0, to: 4).events.isEmpty)
            #expect(try await store.moveQueueItem(from: 1, to: 1).events == [.moved(episodeID: 3, index: 1)])
            let removed = try await store.removeFromQueue([4, 2, 4, 99], performAutoDownload: false)
            #expect(removed.episodeIDs == [3, 1])
            #expect(removed.events == [.removed(episodeID: 4), .removed(episodeID: 2)])
            #expect(!removed.requestsAutoDownload)
            #expect(try await store.clearQueue().events == [.cleared])
            #expect(try await store.clearQueue().events == [.cleared])
            #expect(try await store.queue().isEmpty)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 400)
            #expect(try await store.episode(id: 1)?.userState.playState == .played)
        }
    }

    @Test func emptyInputsDoNotRequestAutoDownloadButNonemptyNoOpsDo() async throws {
        try await withStore { store, _ in
            let initial = try await store.queue()
            #expect(initial.isEmpty)
            #expect(try await store.enqueue([]).requestsAutoDownload == false)
            #expect(try await store.removeFromQueue([]).requestsAutoDownload == false)
            #expect(try await store.queueAutoDownloadRequested() == false)
            #expect(try await store.enqueue([99]).requestsAutoDownload)
            #expect(try await store.queueAutoDownloadRequested())
        }
    }

    @Test func versionOneMigrationRetainsLibraryAndDeferredWork() async throws {
        try await withStore { store, url in
            let feed = try await store.insert(fetched())
            let pending = try await store.pendingEffects()
            try await store.close()
            let db = try LibrarySQLite(url: url)
            try restoreRefreshSchemaEleven(db)
            try db.execute("DROP TABLE download_jobs")
            try db.execute("DROP TABLE playback_selection")
            try db.execute("DROP TABLE playback_session")
            try db.execute("DROP TABLE queue")
            try db.execute("DROP TABLE queue_work")
            try db.execute("DROP TABLE local_folder_links")
            try db.execute("DROP TABLE manual_feed_refresh")
            try db.execute("DROP TABLE episode_notification_work"); try db.execute("DROP TABLE episode_notification_attempt")
            try db.execute("DROP TABLE synchronization_state"); try db.execute("DROP TABLE synchronization_outbox"); try db.execute("DROP TABLE feed_credentials"); try db.execute("DROP TABLE feed_credential_cleanup"); try db.execute("PRAGMA user_version = 1")
            try db.close()
            let migrated = try FeedLibraryStore(url: url)
            #expect(try await migrated.feed(id: feed.id) == feed)
            #expect(try await migrated.pendingEffects() == pending)
            #expect(try await migrated.queue().isEmpty)
            #expect(try await migrated.enqueue([3, 1]).episodeIDs == [3, 1])
            try await migrated.close()
        }
    }

    @Test func queueWriteFailureRollsBackInboxChangesAndAutoDownloadRequest() async throws {
        try await withStore { store, url in
            _ = try await store.insert(fetched())
            try await store.updateEpisode(id: 1) { $0.userState.playState = .new }
            let db = try LibrarySQLite(url: url)
            try db.execute("CREATE TRIGGER fail_queue BEFORE INSERT ON queue WHEN NEW.position = 1 BEGIN SELECT RAISE(ABORT, 'queue failure'); END")
            await #expect(throws: (any Error).self) { try await store.enqueue([1, 2]) }
            #expect(try await store.queue().isEmpty)
            #expect(try await store.episode(id: 1)?.userState.playState == .new)
            #expect(try await store.queueAutoDownloadRequested() == false)
            try db.execute("DROP TRIGGER fail_queue")
            #expect(try await store.enqueue([1, 2]).episodeIDs == [1, 2])
            try db.close()
        }
    }

    @Test func refreshQueueEffectsAreAtomicAndRepeatedConsumptionDoesNotRequeueRemovedItems() async throws {
        try await withStore { store, url in
            let feed = try await store.insert(fetched(1))
            var options = FeedRefreshOptions(now: now.addingTimeInterval(10), timeZone: .gmt)
            options.globalNewEpisodesAction = .queue
            _ = try await store.applyRefresh(fetched(3), feedID: feed.id, options: options)
            let pending = try await store.pendingEffects()
            let db = try LibrarySQLite(url: url)
            try db.execute("CREATE TRIGGER fail_ack BEFORE DELETE ON pending_effects BEGIN SELECT RAISE(ABORT, 'ack failure'); END")
            await #expect(throws: (any Error).self) { try await store.consumeQueueEffects() }
            #expect(try await store.queue().isEmpty)
            #expect(try await store.pendingEffects() == pending)
            #expect(try await store.queueAutoDownloadRequested() == false)
            try db.execute("DROP TRIGGER fail_ack")
            let changes = try await store.consumeQueueEffects()
            #expect(changes.count == 1)
            #expect(try await store.queue().map(\.details.identifier) == ["3", "2"])
            // Consumed; the subscription's add action is not kept (no sync account).
            #expect(try await store.pendingEffects().isEmpty)
            _ = try await store.clearQueue()
            #expect(try await store.consumeQueueEffects().isEmpty)
            #expect(try await store.queue().isEmpty)
            try db.close()
        }
    }

    @Test func episodeRemovalCascadesQueueMembershipButRetainsRemainingOrder() async throws {
        try await withStore { store, _ in
            let feed = try await store.insert(fetched(3))
            _ = try await store.enqueue([2, 1, 3])
            var remaining = fetched(3)
            remaining.feed.episodes.removeAll { $0.identifier == "1" }
            var options = FeedRefreshOptions(now: now, timeZone: .gmt)
            options.removeUnlistedItems = true
            _ = try await store.applyRefresh(remaining, feedID: feed.id, options: options)
            #expect(try await store.queue().map(\.id) == [2, 3])
            #expect(try await store.moveQueueItem(from: 1, to: 0).episodeIDs == [3, 2])
        }
    }

    @Test func concurrentConnectionsDoNotLoseQueueAddsOrCreateDuplicates() async throws {
        try await withStore { store, url in
            _ = try await store.insert(fetched())
            let second = try FeedLibraryStore(url: url)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<40 {
                    let target = index.isMultiple(of: 2) ? store : second
                    group.addTask { _ = try await target.enqueue([Int64(index % 4 + 1)]) }
                }
                try await group.waitForAll()
            }
            let ids = try await store.queue().map(\.id)
            #expect(ids.count == 4 && Set(ids) == [1, 2, 3, 4])
            #expect(try await second.queue().map(\.id) == ids)
            try await second.close()
        }
    }
}
