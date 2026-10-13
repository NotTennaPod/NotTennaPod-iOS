import Foundation
import Testing
@testable import NotTennaPodCore

struct LibraryDownloadTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func withStore(_ operation: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadStore-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let episodes = (1...3).map { number in
            ParsedEpisode(identifier: "\(number)", title: "Episode \(number)", publicationDate: now,
                          media: ParsedMedia(url: "https://example.test/\(number).mp3", size: 120_017, durationMilliseconds: 30_000))
        }
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Download fixture", episodes: episodes),
                                              source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
                                              validator: nil, permanentRedirectURL: nil))
        do { try await operation(store, url); try await store.close() }
        catch { try? await store.close(); throw error }
    }

    private func start(_ store: FeedLibraryStore, episodeID: Int64, directory: URL,
                       enqueue: Bool = true) async throws -> LibraryDownloadJob {
        let requested = try #require(try await store.requestDownload(episodeID: episodeID, directory: directory, enqueue: enqueue, now: now))
        let job = try #require(try await store.beginDownloadAttempt(id: requested.id, now: now))
        try Data("partial".utf8).write(to: job.destination)
        #expect(try await store.attachDownloadFile(id: job.id, attempt: job.attempts))
        return job
    }

    @Test func requestQueuesImmediatelyAndPersistsUniqueJobAcrossReopen() async throws {
        try await withStore { store, url in
            try await store.updateEpisode(id: 1) { $0.userState.playState = .new }
            let first = try #require(try await store.requestDownload(episodeID: 1, directory: url.deletingLastPathComponent(), now: now))
            let duplicate = try await store.requestDownload(episodeID: 1, directory: url.deletingLastPathComponent(), now: now)
            #expect(duplicate == first)
            #expect(first.state == .waiting && first.enqueuedByDownload && first.attempts == 0)
            #expect(try await store.queue().map(\.id) == [1])
            #expect(try await store.episode(id: 1)?.userState.playState == .unplayed)
            #expect(try await store.episode(id: 1)?.userState.localFileURL == nil)
            #expect(try await store.queueAutoDownloadRequested())
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.downloadJobs() == [first])
            #expect(try await reopened.queue().map(\.id) == [1])
            try await reopened.close()
        }
    }

    @Test func frontPlacementKeepsDownloadRequestOrder() async throws {
        try await withStore { store, url in
            _ = try await store.enqueue([3])
            for id: Int64 in [1, 2] {
                _ = try await store.requestDownload(episodeID: id, directory: url.deletingLastPathComponent(), location: .front, now: now)
            }
            #expect(try await store.queue().map(\.id) == [1, 2, 3])
        }
    }

    @Test func cancellationPreservesExistingQueueUnlessDeletionPreferenceApplies() async throws {
        for prequeued in [false, true] {
            for fileExists in [false, true] {
                for deleteRemoves in [false, true] {
                    try await withStore { store, url in
                        if prequeued { _ = try await store.enqueue([1]) }
                        let job = try #require(try await store.requestDownload(episodeID: 1, directory: url.deletingLastPathComponent(), now: now))
                        if fileExists {
                            let attempt = try #require(try await store.beginDownloadAttempt(id: job.id, now: now))
                            try Data("partial".utf8).write(to: job.destination)
                            #expect(try await store.attachDownloadFile(id: job.id, attempt: attempt.attempts))
                        }
                        #expect(try await store.cancelDownload(id: job.id, deleteRemovesFromQueue: deleteRemoves, now: now))
                        let retained = prequeued && !(fileExists && deleteRemoves)
                        #expect(try await store.queue().map(\.id) == (retained ? [Int64(1)] : []))
                        #expect(try await store.episode(id: 1)?.userState.autoDownloadEnabled == false)
                        #expect(try await store.episode(id: 1)?.userState.localFileURL == nil)
                        #expect(try await store.downloadJobs().isEmpty)
                        #expect(try await store.downloadJobs(activeOnly: false).first?.state == .cancelled)
                        let cleanup = try await store.pendingEffects().filter {
                            if case .deleteDownloadFile = $0.effect.kind { true } else { false }
                        }
                        #expect(cleanup.count == (fileExists ? 1 : 0))
                        #expect(FileManager.default.fileExists(atPath: job.destination.path) == fileExists)
                        #expect(try await store.cancelDownload(id: job.id, now: now) == false)
                    }
                }
            }
        }
    }

    @Test func completionUsesCurrentEpisodeAndActualFileSizeAndSurvivesReopen() async throws {
        for state in EpisodePlayState.allCases {
            try await withStore { store, url in
                let job = try await start(store, episodeID: 1, directory: url.deletingLastPathComponent(), enqueue: false)
                try await store.updateEpisode(id: 1) {
                    $0.userState.playState = state
                    $0.userState.positionMilliseconds = 3_883
                    $0.userState.isFavorite = true
                    $0.userState.timeSpentMilliseconds = 9_000
                }
                try await store.selectSynchronizationAccount(UUID())
                #expect(try await store.completeDownload(id: job.id, attempt: job.attempts, measuredDuration: 30_040, now: now))
                #expect(try await store.completeDownload(id: job.id, attempt: job.attempts, now: now) == false)
                let reopened = try FeedLibraryStore(url: url)
                let episode = try #require(try await reopened.episode(id: 1))
                #expect(episode.userState.playState == (state == .new ? .unplayed : state))
                #expect(episode.userState.isDownloaded && !episode.userState.autoDownloadEnabled)
                #expect(episode.userState.positionMilliseconds == 3_883 && episode.userState.isFavorite)
                #expect(episode.userState.timeSpentMilliseconds == 9_000)
                #expect(episode.userState.downloadDate == now)
                #expect(episode.details.media?.size == 7 && episode.details.media?.durationMilliseconds == 30_040)
                #expect(try await reopened.queue().isEmpty)
                // The DOWNLOAD action reaches the connected account's outbox in the completion's commit.
                let outbox = try await reopened.synchronizationQueue()
                #expect(outbox.count == 1)
                guard case .episode(let action) = outbox.first?.value else { Issue.record("Expected download action"); return }
                #expect(action == .init(podcast: "https://example.test/feed", episode: try #require(episode.details.media?.url),
                                        guid: episode.details.identifier, action: .download, timestamp: now))
                #expect(try await reopened.downloadJobs().isEmpty)
                try await reopened.close()
            }
        }
    }

    @Test func interruptionRetainsFileAndStaleAttemptCannotCompleteOrInterruptReplacement() async throws {
        try await withStore { store, url in
            let job = try await start(store, episodeID: 1, directory: url.deletingLastPathComponent())
            #expect(try await store.interruptDownload(id: job.id, attempt: job.attempts, now: now))
            #expect(try await store.queue().map(\.id) == [1])
            #expect(try await store.episode(id: 1)?.userState.autoDownloadEnabled == true)
            #expect(try Data(contentsOf: job.destination) == Data("partial".utf8))
            let second = try #require(try await store.beginDownloadAttempt(id: job.id, now: now))
            #expect(second.attempts == 2)
            #expect(try await store.completeDownload(id: job.id, attempt: 1, now: now) == false)
            #expect(try await store.interruptDownload(id: job.id, attempt: 1, now: now) == false)
            #expect(try await store.attachDownloadFile(id: job.id, attempt: 1) == false)
            #expect(try await store.downloadJobs().first?.state == .transferring)
            #expect(try await store.completeDownload(id: job.id, attempt: 2, now: now))
        }
    }

    @Test func cancelledJobCannotPublishOrOverwriteNewDownload() async throws {
        try await withStore { store, url in
            let first = try await start(store, episodeID: 1, directory: url.deletingLastPathComponent())
            #expect(try await store.cancelDownload(id: first.id, now: now))
            let second = try await start(store, episodeID: 1, directory: url.deletingLastPathComponent())
            #expect(second.id != first.id && second.destination != first.destination)
            #expect(try await store.completeDownload(id: first.id, attempt: first.attempts, now: now) == false)
            #expect(try await store.attachDownloadFile(id: first.id, attempt: first.attempts) == false)
            #expect(try await store.episode(id: 1)?.userState.localFileURL == second.destination.path)
            #expect(try await store.completeDownload(id: second.id, attempt: second.attempts, now: now))
        }
    }

    @Test func completionFailureRollsBackEpisodeJobAndDeferredEffects() async throws {
        try await withStore { store, url in
            let job = try await start(store, episodeID: 1, directory: url.deletingLastPathComponent())
            let before = try await store.episode(id: 1)
            let effects = try await store.pendingEffects()
            let injector = try LibrarySQLite(url: url)
            // The completion's last write (the job becoming finished) fails: nothing of it may remain.
            try injector.execute("CREATE TRIGGER reject_completion BEFORE UPDATE ON download_jobs WHEN NEW.active = 0 BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            await #expect(throws: (any Error).self) {
                try await store.completeDownload(id: job.id, attempt: job.attempts, measuredDuration: 99, now: now)
            }
            #expect(try await store.episode(id: 1) == before)
            #expect(try await store.pendingEffects() == effects)
            #expect(try await store.downloadJobs().first?.state == .transferring)
            try injector.execute("DROP TRIGGER reject_completion")
            try injector.close()
            #expect(try await store.completeDownload(id: job.id, attempt: job.attempts, now: now))
        }
    }

    @Test func concurrentRequestsKeepOneJobAndOneQueueEntry() async throws {
        try await withStore { store, url in
            let second = try FeedLibraryStore(url: url)
            let ids = try await withThrowingTaskGroup(of: Int64?.self, returning: [Int64].self) { group in
                for index in 0..<40 {
                    let target = index.isMultiple(of: 2) ? store : second
                    group.addTask { try await target.requestDownload(episodeID: 1, directory: url.deletingLastPathComponent())?.id }
                }
                var ids: [Int64] = []
                for try await id in group { if let id { ids.append(id) } }
                return ids
            }
            #expect(ids.count == 40 && Set(ids).count == 1)
            #expect(try await store.downloadJobs().count == 1)
            #expect(try await store.queue().map(\.id) == [1])
            try await second.close()
        }
    }

    @Test func versionTwoMigrationRetainsLibraryQueueAndEffects() async throws {
        try await withStore { store, url in
            _ = try await store.enqueue([2, 1])
            let before = try await store.feeds()
            let effects = try await store.pendingEffects()
            try await store.close()
            let previous = try LibrarySQLite(url: url)
            try restoreRefreshSchemaEleven(previous)
            try previous.execute("DROP TABLE download_jobs")
            try previous.execute("DROP TABLE playback_selection")
            try previous.execute("DROP TABLE playback_session")
            try previous.execute("DROP TABLE local_folder_links")
            try previous.execute("DROP TABLE manual_feed_refresh")
            try previous.execute("DROP TABLE episode_notification_work"); try previous.execute("DROP TABLE episode_notification_attempt")
            try previous.execute("ALTER TABLE queue_work DROP COLUMN token"); try previous.execute("DROP TABLE synchronization_state"); try previous.execute("DROP TABLE synchronization_outbox"); try previous.execute("DROP TABLE feed_credentials"); try previous.execute("DROP TABLE feed_credential_cleanup"); try previous.execute("PRAGMA user_version = 2")
            try previous.close()
            let migrated = try FeedLibraryStore(url: url)
            #expect(try await migrated.feeds() == before)
            #expect(try await migrated.pendingEffects() == effects)
            #expect(try await migrated.queue().map(\.id) == [2, 1])
            #expect(try await migrated.downloadJobs().isEmpty)
            #expect(try await migrated.queueAutoDownloadRequested())
            try await migrated.close()
        }
    }

    @Test func requestFailureRollsBackQueueInboxAndAutoDownloadRequest() async throws {
        try await withStore { store, url in
            try await store.updateEpisode(id: 1) { $0.userState.playState = .new }
            let before = try await store.episode(id: 1)
            let injector = try LibrarySQLite(url: url)
            try injector.execute("CREATE TRIGGER reject_job BEFORE INSERT ON download_jobs BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            await #expect(throws: (any Error).self) {
                try await store.requestDownload(episodeID: 1, directory: url.deletingLastPathComponent(), now: now)
            }
            #expect(try await store.downloadJobs(activeOnly: false).isEmpty)
            #expect(try await store.queue().isEmpty)
            #expect(try await store.episode(id: 1) == before)
            #expect(try await store.queueAutoDownloadRequested() == false)
            try injector.close()
        }
    }

    @Test func cancellationFailureRollsBackQueueEpisodeAndCleanup() async throws {
        try await withStore { store, url in
            let job = try await start(store, episodeID: 1, directory: url.deletingLastPathComponent())
            let episode = try await store.episode(id: 1)
            let effects = try await store.pendingEffects()
            let injector = try LibrarySQLite(url: url)
            try injector.execute("CREATE TRIGGER reject_cancel BEFORE UPDATE ON download_jobs BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            await #expect(throws: (any Error).self) { try await store.cancelDownload(id: job.id, now: now) }
            #expect(try await store.episode(id: 1) == episode)
            #expect(try await store.pendingEffects() == effects)
            #expect(try await store.queue().map(\.id) == [1])
            #expect(try await store.downloadJobs().first?.state == .transferring)
            #expect(try Data(contentsOf: job.destination) == Data("partial".utf8))
            try injector.close()
        }
    }

    @Test func completionSyncFlagFollowsSubscriptionStateAndMissingDurationKeepsFeedValue() async throws {
        for state in FeedSubscriptionState.allCases {
            try await withStore { store, url in
                try await store.updatePreferences(feedID: 1) { $0.subscriptionState = state }
                try await store.selectSynchronizationAccount(UUID())
                let job = try await start(store, episodeID: 1, directory: url.deletingLastPathComponent())
                #expect(try await store.completeDownload(id: job.id, attempt: job.attempts, now: now))
                #expect(try await store.episode(id: 1)?.details.media?.durationMilliseconds == 30_000)
                let actions = try await store.synchronizationQueue().compactMap {
                    if case .episode(let action) = $0.value, action.action == .download { action } else { nil }
                }
                #expect(actions.count == (state != .notSubscribed ? 1 : 0))
            }
        }
    }

    @Test func completedMissingAndCorruptInputsDoNotCreateNewWork() async throws {
        try await withStore { store, url in
            try await store.updateEpisode(id: 1) { $0.userState.isDownloaded = true }
            try await store.updateEpisode(id: 2) { $0.details.media = nil }
            #expect(try await store.requestDownload(episodeID: 1, directory: url.deletingLastPathComponent()) == nil)
            #expect(try await store.requestDownload(episodeID: 2, directory: url.deletingLastPathComponent()) == nil)
            await #expect(throws: FeedLibraryError.missingEpisode(99)) {
                try await store.requestDownload(episodeID: 99, directory: url.deletingLastPathComponent())
            }
            #expect(try await store.downloadJobs().isEmpty)
            #expect(try await store.queue().isEmpty)
            let job = try #require(try await store.requestDownload(episodeID: 3, directory: url.deletingLastPathComponent()))
            let injector = try LibrarySQLite(url: url)
            try injector.execute("UPDATE download_jobs SET source = 'wrong' WHERE id = ?", [.integer(job.id)])
            await #expect(throws: FeedLibraryError.corruptRecord) { try await store.downloadJobs() }
            try injector.close()
        }
    }

    @Test func uniqueWorkKeepsOriginalConstraintAndNewGenerationCanChangeIt() async throws {
        try await withStore { store, url in
            let first = try #require(try await store.requestDownload(episodeID: 1, directory: url.deletingLastPathComponent(), networkConstraint: .unmetered))
            let duplicate = try await store.requestDownload(episodeID: 1, directory: url.deletingLastPathComponent(), networkConstraint: .connected)
            #expect(duplicate == first)
            #expect(try await store.cancelDownload(id: first.id))
            let second = try #require(try await store.requestDownload(episodeID: 1, directory: url.deletingLastPathComponent(), networkConstraint: .connected))
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.downloadJob(id: first.id)?.networkConstraint == .unmetered)
            #expect(try await reopened.downloadJob(id: second.id)?.networkConstraint == .connected)
            try await reopened.close()
        }
    }
}
