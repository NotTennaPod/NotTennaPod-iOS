import Foundation
import Testing
@testable import NotTennaPodCore

@Suite
struct LibraryPlaybackTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func withStore(_ operation: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Playback-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let episodes = (1...3).map {
            ParsedEpisode(identifier: "\($0)", title: "Episode \($0)",
                          media: ParsedMedia(url: "https://example.test/\($0).mp3", size: 0, durationMilliseconds: 100_000))
        }
        _ = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Playback", episodes: episodes),
                                              source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
                                              validator: nil, permanentRedirectURL: nil))
        do { try await operation(store, url); try await store.close() }
        catch { try? await store.close(); throw error }
    }

    private func sample(_ position: Int32, duration: Int32 = 100_000,
                        status: LibraryPlaybackSession.Status = .playing) -> PlaybackSample {
        .init(positionMilliseconds: position, durationMilliseconds: duration, status: status)
    }

    @Test func selectingMediaEnqueuesButDoesNotFabricateListeningHistory() async throws {
        try await withStore { store, _ in
            try await store.updateEpisode(id: 1) { $0.userState.playState = .new; $0.userState.positionMilliseconds = 40_000 }
            let session = try await store.beginPlayback(episodeID: 1, positionMilliseconds: 37_000)
            #expect(session.startPositionMilliseconds == 37_000)
            #expect(session.status == .paused)
            #expect(try await store.queue().map(\.id) == [1])
            let episode = try #require(try await store.episode(id: 1))
            #expect(episode.userState.playState == .unplayed)
            #expect(episode.userState.positionMilliseconds == 40_000)
            #expect(episode.userState.lastPlayedTimeMilliseconds == 0)
            #expect(episode.userState.lastPlayedHistoryMilliseconds == nil)
            #expect(episode.userState.autoDownloadEnabled)
        }
    }

    @Test func alreadyQueuedSelectionDoesNotRequestAnotherAutomaticDownloadEvaluation() async throws {
        try await withStore { store, url in
            _ = try await store.enqueue([2, 1])
            let connection = try LibrarySQLite(url: url)
            try connection.execute("DELETE FROM queue_work")
            try connection.close()
            _ = try await store.beginPlayback(episodeID: 1, enqueueLocation: .front)
            #expect(try await store.queue().map(\.id) == [2, 1])
            #expect(try await store.queueAutoDownloadRequested() == false)
        }
    }

    @Test func samplesUseSessionStartRatherThanAccumulatingTicksOrClampingRewinds() async throws {
        try await withStore { store, _ in
            try await store.updateEpisode(id: 1) {
                $0.userState.positionMilliseconds = 10_000
                $0.userState.playedDurationMilliseconds = 7_000
                $0.userState.timeSpentMilliseconds = 99_000
                $0.userState.isFavorite = true
            }
            let session = try await store.beginPlayback(episodeID: 1)
            for (position, played): (Int32, Int32) in [(15_000, 12_000), (20_000, 17_000), (12_000, 9_000), (8_000, 9_000), (0, 9_000)] {
                let saved = try #require(try await store.recordPlayback(sessionID: session.id, sample: sample(position), now: now))
                #expect(saved.userState.playedDurationMilliseconds == played)
                #expect(saved.userState.positionMilliseconds == position)
                #expect(saved.userState.timeSpentMilliseconds == 99_000)
                #expect(saved.userState.isFavorite)
                #expect(saved.userState.lastPlayedTimeMilliseconds == 1_700_000_000_000)
                #expect(saved.userState.lastPlayedHistoryMilliseconds == 1_700_000_000_000)
            }
        }
    }

    @Test func samplingPreservesOtherChangesAndOnlyUpdatesPositiveSeekableDuration() async throws {
        try await withStore { store, _ in
            let session = try await store.beginPlayback(episodeID: 1)
            try await store.updateEpisode(id: 1) { $0.userState.isFavorite = true; $0.userState.playState = .new }
            var update = sample(0, duration: 30_040, status: .paused)
            update.seekable = false
            let first = try #require(try await store.recordPlayback(sessionID: session.id, sample: update, now: now))
            #expect(first.details.media?.durationMilliseconds == 100_000)
            #expect(first.userState.playState == .new && first.userState.isFavorite)
            update.seekable = true
            let second = try #require(try await store.recordPlayback(sessionID: session.id, sample: update, now: now))
            #expect(second.details.media?.durationMilliseconds == 30_040)
            update.durationMilliseconds = -1
            #expect(try await store.recordPlayback(sessionID: session.id, sample: update, now: now)?.details.media?.durationMilliseconds == 30_040)
            #expect(try await store.playbackSession()?.status == .paused)
        }
    }

    @Test func selectionAndSampleSurviveReopenAndNewSessionRejectsOldCallbacks() async throws {
        try await withStore { store, url in
            let first = try await store.beginPlayback(episodeID: 1)
            _ = try await store.recordPlayback(sessionID: first.id, sample: sample(3_883, duration: 30_040, status: .paused), now: now)
            let reader = try FeedLibraryStore(url: url)
            #expect(try await reader.playbackSession()?.id == first.id)
            #expect(try await reader.episode(id: 1)?.userState.positionMilliseconds == 3_883)
            let second = try await reader.beginPlayback(episodeID: 2)
            #expect(try await store.recordPlayback(sessionID: first.id, sample: sample(90_000), now: now) == nil)
            #expect(try await store.endPlayback(sessionID: first.id, reason: .ended, now: now) == nil)
            #expect(try await store.playbackSession()?.id == second.id)
            #expect(try await store.episode(id: 1)?.userState.positionMilliseconds == 3_883)
            #expect(try await store.queue().map(\.id) == [1, 2])
            try await reader.close()
        }
    }

    @Test(arguments: [Int32(69_999), 70_000, 100_000])
    func switchingUsesInclusiveSmartCompletionThreshold(position: Int32) async throws {
        try await withStore { store, _ in
            let session = try await store.beginPlayback(episodeID: 1)
            _ = try await store.recordPlayback(sessionID: session.id, sample: sample(position), now: now)
            let result = try #require(try await store.endPlayback(sessionID: session.id, reason: .switched, now: now.addingTimeInterval(1)))
            #expect(result.markedPlayed == (position >= 70_000))
            #expect(result.episode.userState.positionMilliseconds == (position >= 70_000 ? 0 : position))
            #expect(try await store.queue().map(\.id) == (position >= 70_000 ? [] : [1]))
            #expect(result.episode.userState.lastPlayedHistoryMilliseconds == 1_700_000_001_000)
            #expect(result.episode.userState.lastPlayedTimeMilliseconds == 1_700_000_000_000)
        }
    }

    @Test func shortEpisodeCanBeAlmostFinishedAtZeroUnderDefaultThirtySecondSetting() async throws {
        try await withStore { store, _ in
            try await store.updateEpisode(id: 1) { $0.details.media?.durationMilliseconds = 30_000 }
            let session = try await store.beginPlayback(episodeID: 1)
            #expect(try await store.endPlayback(sessionID: session.id, reason: .switched, now: now)?.markedPlayed == true)
        }
    }

    @Test func completionSelectsNextBeforeRemovingCurrentAndPreservesPreResetSyncSnapshot() async throws {
        try await withStore { store, _ in
            _ = try await store.enqueue([3, 1, 2])
            try await store.selectSynchronizationAccount(UUID())
            let session = try await store.beginPlayback(episodeID: 1, positionMilliseconds: 5_000)
            _ = try await store.recordPlayback(sessionID: session.id, sample: sample(100_000), now: now)
            var preferences = PlaybackEndPreferences()
            preferences.synchronize = true
            let result = try #require(try await store.endPlayback(sessionID: session.id, reason: .ended, preferences: preferences, now: now))
            #expect(result.nextEpisodeID == 2 && result.markedPlayed && result.removedFromQueue)
            #expect(result.episode.userState.positionMilliseconds == 0)
            #expect(result.episode.userState.playedDurationMilliseconds == 95_000)
            #expect(try await store.queue().map(\.id) == [3, 2])
            #expect(try await store.playbackSession() == nil)
            // The completed PLAY action (from the pre-reset snapshot) is in the account's outbox.
            let outbox = try await store.synchronizationQueue()
            guard case .episode(let action) = outbox.last?.value else { Issue.record("Missing playback synchronization action"); return }
            #expect(action == .init(podcast: "https://example.test/feed", episode: "https://example.test/1.mp3", guid: "1",
                                    action: .play, timestamp: now, started: 5, position: 100, total: 100))
            #expect(try await store.endPlayback(sessionID: session.id, reason: .ended, now: now) == nil)
            #expect(try await store.synchronizationQueue() == outbox)
        }
    }

    @Test(arguments: [true, false])
    func explicitSkipHonorsKeepPreferenceWithoutMarkingPlayed(keep: Bool) async throws {
        try await withStore { store, _ in
            _ = try await store.enqueue([1, 2])
            let session = try await store.beginPlayback(episodeID: 1)
            _ = try await store.recordPlayback(sessionID: session.id, sample: sample(1_000), now: now)
            var preferences = PlaybackEndPreferences()
            preferences.skipKeepsEpisode = keep
            let result = try #require(try await store.endPlayback(sessionID: session.id, reason: .skipped, preferences: preferences, now: now))
            #expect(result.nextEpisodeID == 2)
            #expect(!result.markedPlayed)
            #expect(result.episode.userState.positionMilliseconds == 1_000)
            #expect(try await store.queue().map(\.id) == (keep ? [1, 2] : [2]))
        }
    }

    @Test func nextQueueItemWithNoMediaDoesNotSkipAheadAndMissingCurrentHasNoSuccessor() async throws {
        try await withStore { store, _ in
            _ = try await store.enqueue([1, 2, 3])
            try await store.updateEpisode(id: 2) { $0.details.media = nil }
            let first = try await store.beginPlayback(episodeID: 1)
            #expect(try await store.endPlayback(sessionID: first.id, reason: .ended, now: now)?.nextEpisodeID == nil)
            let second = try await store.beginPlayback(episodeID: 3)
            _ = try await store.removeFromQueue([3])
            #expect(try await store.endPlayback(sessionID: second.id, reason: .ended, now: now)?.nextEpisodeID == nil)
        }
    }

    @Test(arguments: [true, false])
    func automaticDeletionHonorsFavoriteProtectionAndRetainsDurableFileWork(keepFavorite: Bool) async throws {
        try await withStore { store, url in
            let file = url.deletingLastPathComponent().appendingPathComponent("download.media")
            try Data("audio".utf8).write(to: file)
            try await store.updateEpisode(id: 1) {
                $0.userState.isFavorite = true
                $0.userState.isDownloaded = true
                $0.userState.localFileURL = file.path
                $0.userState.downloadDate = now
            }
            let session = try await store.beginPlayback(episodeID: 1)
            var preferences = PlaybackEndPreferences()
            preferences.autoDelete = true
            preferences.favoriteKeepsEpisode = keepFavorite
            let result = try #require(try await store.endPlayback(sessionID: session.id, reason: .ended, preferences: preferences, now: now))
            #expect(result.episode.userState.isDownloaded == keepFavorite)
            #expect(FileManager.default.fileExists(atPath: file.path))
            let deletes = try await store.pendingEffects().filter { if case .deleteDownloadFile = $0.effect.kind { true } else { false } }
            #expect(deletes.count == (keepFavorite ? 0 : 1))
            try await MediaDownloadWorker(store: store).cleanCancelledFiles()
            #expect(FileManager.default.fileExists(atPath: file.path) == keepFavorite)
        }
    }

    @Test func autoDeleteWithoutDownloadedFileStillRecordsSourceDeleteAction() async throws {
        try await withStore { store, _ in
            try await store.selectSynchronizationAccount(UUID())
            let session = try await store.beginPlayback(episodeID: 1)
            var preferences = PlaybackEndPreferences(); preferences.autoDelete = true
            _ = try await store.endPlayback(sessionID: session.id, reason: .ended, preferences: preferences, now: now)
            let actions = try await store.synchronizationQueue().compactMap { if case .episode(let action) = $0.value { action } else { nil } }
            #expect(actions == [.init(podcast: "https://example.test/feed", episode: "https://example.test/1.mp3", guid: "1",
                                      action: .delete, timestamp: now)])
            #expect(try await store.pendingEffects().isEmpty)
        }
    }

    @Test func failedSelectionRollsBackQueueAndEpisodeState() async throws {
        try await withStore { store, url in
            try await store.updateEpisode(id: 1) { $0.userState.playState = .new }
            let connection = try LibrarySQLite(url: url)
            try connection.execute("CREATE TRIGGER reject_selection BEFORE INSERT ON playback_session BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            await #expect(throws: (any Error).self) { try await store.beginPlayback(episodeID: 1) }
            #expect(try await store.queue().isEmpty)
            #expect(try await store.playbackSession() == nil)
            #expect(try await store.episode(id: 1)?.userState.playState == .new)
            #expect(try await store.queueAutoDownloadRequested() == false)
            try connection.close()
        }
    }

    @Test func failedSampleRollsBackPositionHistoryAndStatus() async throws {
        try await withStore { store, url in
            let session = try await store.beginPlayback(episodeID: 1)
            let before = try await store.episode(id: 1)
            let connection = try LibrarySQLite(url: url)
            try connection.execute("CREATE TRIGGER reject_status BEFORE UPDATE ON playback_session BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            await #expect(throws: (any Error).self) { try await store.recordPlayback(sessionID: session.id, sample: sample(5_000), now: now) }
            #expect(try await store.episode(id: 1) == before)
            #expect(try await store.playbackSession() == session)
            try connection.close()
        }
    }

    @Test func failedCompletionRollsBackQueueHistoryEffectsAndSession() async throws {
        try await withStore { store, url in
            let session = try await store.beginPlayback(episodeID: 1)
            let before = try await store.episode(id: 1)
            let effects = try await store.pendingEffects()
            let connection = try LibrarySQLite(url: url)
            try connection.execute("CREATE TRIGGER reject_end BEFORE DELETE ON playback_session BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            var preferences = PlaybackEndPreferences()
            preferences.synchronize = true
            await #expect(throws: (any Error).self) { try await store.endPlayback(sessionID: session.id, reason: .ended, preferences: preferences, now: now) }
            #expect(try await store.episode(id: 1) == before)
            #expect(try await store.queue().map(\.id) == [1])
            #expect(try await store.playbackSession() == session)
            #expect(try await store.pendingEffects() == effects)
            try connection.close()
        }
    }

    @Test func emptyVersionFourMigrationDoesNotInventSelectionAndDeletionCascades() async throws {
        try await withStore { store, url in
            let old = try LibrarySQLite(url: url)
            try restoreRefreshSchemaEleven(old)
            try old.execute("DROP TABLE playback_selection")
            try old.execute("DROP TABLE local_folder_links")
            try old.execute("DROP TABLE manual_feed_refresh")
            try old.execute("DROP TABLE episode_notification_work"); try old.execute("DROP TABLE episode_notification_attempt")
            try old.execute("ALTER TABLE queue_work DROP COLUMN token"); try old.execute("DROP TABLE synchronization_state"); try old.execute("DROP TABLE synchronization_outbox"); try old.execute("DROP TABLE feed_credentials"); try old.execute("DROP TABLE feed_credential_cleanup"); try old.execute("PRAGMA user_version = 4")
            try old.close()
            try await store.close()
            let migrated = try FeedLibraryStore(url: url)
            #expect(try await migrated.playbackSelectionEpisodeID() == nil)
            let session = try await migrated.beginPlayback(episodeID: 1)
            _ = try await migrated.endPlayback(sessionID: session.id, reason: .switched)
            let connection = try LibrarySQLite(url: url)
            try connection.execute("DELETE FROM episodes WHERE id = 1")
            #expect(try await migrated.playbackSelectionEpisodeID() == nil)
            #expect(try connection.rows("PRAGMA foreign_key_check").isEmpty)
            try connection.close()
            try await migrated.close()
        }
    }

    @Test func versionFourMigrationPreservesActiveSelectionAndStatistics() async throws {
        try await withStore { store, url in
            let session = try await store.beginPlayback(episodeID: 1)
            _ = try await store.recordPlayback(sessionID: session.id, sample: sample(3130, status: .paused), now: now)
            let stored = try await store.playbackSession()
            let feeds = try await store.feeds()
            let old = try LibrarySQLite(url: url)
            try restoreRefreshSchemaEleven(old)
            try old.execute("DROP TABLE playback_selection")
            try old.execute("DROP TABLE local_folder_links")
            try old.execute("DROP TABLE manual_feed_refresh")
            try old.execute("DROP TABLE episode_notification_work"); try old.execute("DROP TABLE episode_notification_attempt")
            try old.execute("ALTER TABLE queue_work DROP COLUMN token"); try old.execute("DROP TABLE synchronization_state"); try old.execute("DROP TABLE synchronization_outbox"); try old.execute("DROP TABLE feed_credentials"); try old.execute("DROP TABLE feed_credential_cleanup"); try old.execute("PRAGMA user_version = 4")
            try old.close()
            try await store.close()
            let migrated = try FeedLibraryStore(url: url)
            #expect(try await migrated.playbackSelectionEpisodeID() == 1)
            #expect(try await migrated.playbackSession() == stored)
            #expect(try await migrated.feeds() == feeds)
            #expect(try await migrated.queue().map(\.id) == [1])
            try await migrated.close()
        }
    }

    @Test func switchedStatisticsEndRetainsSelectionAndFinalCompletionClearsIt() async throws {
        try await withStore { store, _ in
            let first = try await store.beginPlayback(episodeID: 1)
            _ = try await store.endPlayback(sessionID: first.id, reason: .switched, now: now)
            #expect(try await store.playbackSession() == nil)
            #expect(try await store.playbackSelectionEpisodeID() == 1)
            let second = try await store.beginPlayback(episodeID: 2)
            #expect(try await store.playbackSelectionEpisodeID() == 2)
            _ = try await store.endPlayback(sessionID: second.id, reason: .ended, now: now)
            #expect(try await store.playbackSession() == nil)
            #expect(try await store.playbackSelectionEpisodeID() == nil)
        }
    }

    @Test func afterCurrentEnqueueUsesRetainedSelectionAfterStatisticsEnd() async throws {
        try await withStore { store, _ in
            _ = try await store.enqueue([1, 3])
            let first = try await store.beginPlayback(episodeID: 1)
            _ = try await store.endPlayback(sessionID: first.id, reason: .switched, now: now)
            #expect(try await store.playbackSession() == nil)
            _ = try await store.beginPlayback(episodeID: 2, enqueueLocation: .afterCurrentlyPlaying)
            #expect(try await store.queue().map(\.id) == [1, 2, 3])
            #expect(try await store.playbackSelectionEpisodeID() == 2)
        }
    }

    @Test func selectionWriteFailureRollsBackNewSessionAndQueue() async throws {
        try await withStore { store, url in
            let first = try await store.beginPlayback(episodeID: 1)
            let connection = try LibrarySQLite(url: url)
            try connection.execute("CREATE TRIGGER reject_selection BEFORE INSERT ON playback_selection BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            await #expect(throws: (any Error).self) { try await store.beginPlayback(episodeID: 2) }
            #expect(try await store.playbackSession() == first)
            #expect(try await store.playbackSelectionEpisodeID() == 1)
            #expect(try await store.queue().map(\.id) == [1])
            try connection.close()
        }
    }

    @Test func selectionClearFailureRollsBackCompletedStateAndStatistics() async throws {
        try await withStore { store, url in
            let first = try await store.beginPlayback(episodeID: 1)
            let before = try await store.episode(id: 1)
            let connection = try LibrarySQLite(url: url)
            try connection.execute("CREATE TRIGGER reject_selection_delete BEFORE DELETE ON playback_selection BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            await #expect(throws: (any Error).self) { try await store.endPlayback(sessionID: first.id, reason: .ended, now: now) }
            #expect(try await store.playbackSession() == first)
            #expect(try await store.playbackSelectionEpisodeID() == 1)
            #expect(try await store.episode(id: 1) == before)
            #expect(try await store.queue().map(\.id) == [1])
            try connection.close()
        }
    }

    @Test func versionThreeMigrationPreservesQueueDownloadJobsAndOldEpisodeRecords() async throws {
        try await withStore { store, url in
            _ = try await store.requestDownload(episodeID: 1, directory: url.deletingLastPathComponent(), now: now)
            let feeds = try await store.feeds()
            let jobs = try await store.downloadJobs()
            try await store.close()
            let old = try LibrarySQLite(url: url)
            try restoreRefreshSchemaEleven(old)
            try old.execute("DROP TABLE playback_selection")
            try old.execute("DROP TABLE playback_session")
            try old.execute("DROP TABLE local_folder_links")
            try old.execute("DROP TABLE manual_feed_refresh")
            try old.execute("DROP TABLE episode_notification_work"); try old.execute("DROP TABLE episode_notification_attempt")
            try old.execute("ALTER TABLE queue_work DROP COLUMN token"); try old.execute("DROP TABLE synchronization_state"); try old.execute("DROP TABLE synchronization_outbox"); try old.execute("DROP TABLE feed_credentials"); try old.execute("DROP TABLE feed_credential_cleanup"); try old.execute("PRAGMA user_version = 3")
            try old.close()
            let migrated = try FeedLibraryStore(url: url)
            #expect(try await migrated.feeds() == feeds)
            #expect(try await migrated.downloadJobs() == jobs)
            #expect(try await migrated.queue().map(\.id) == [1])
            #expect(try await migrated.playbackSession() == nil)
            #expect(try await migrated.episode(id: 1)?.userState.lastPlayedHistoryMilliseconds == nil)
            try await migrated.close()
        }
    }

    @Test(arguments: [Int32(0), 1])
    func sourceMarksPersistedNewStateOnlyBeforePositivePositionClearsInMemoryFlag(position: Int32) async throws {
        try await withStore { store, _ in
            _ = try await store.enqueue([1])
            try await store.updateEpisode(id: 1) { $0.userState.playState = .new }
            let session = try await store.beginPlayback(episodeID: 1)
            let saved = try #require(try await store.recordPlayback(sessionID: session.id, sample: sample(position), now: now))
            #expect(saved.userState.playState == (position == 0 ? .unplayed : .new))
            #expect(try await store.playbackSession()?.itemPlayState == .unplayed)
        }
    }

    @Test func playedDurationCrossesJavaIntegerLimitWithoutCorruptingHistory() async throws {
        try await withStore { store, _ in
            try await store.updateEpisode(id: 1) { $0.userState.playedDurationMilliseconds = 2_147_483_647 }
            let session = try await store.beginPlayback(episodeID: 1)
            let saved = try #require(try await store.recordPlayback(sessionID: session.id, sample: sample(1), now: now))
            #expect(Int64(saved.userState.playedDurationMilliseconds) == 2_147_483_648)
            let ended = try #require(try await store.endPlayback(sessionID: session.id, reason: .switched, now: now.addingTimeInterval(-10)))
            #expect(ended.episode.userState.lastPlayedHistoryMilliseconds == 1_699_999_990_000)
            #expect(ended.episode.userState.lastPlayedTimeMilliseconds == 1_700_000_000_000)
        }
    }

    @Test func syncRequiresExplicitPermissionSubscriptionAndForwardProgress() async throws {
        try await withStore { store, _ in
            try await store.selectSynchronizationAccount(UUID())
            let session = try await store.beginPlayback(episodeID: 1, positionMilliseconds: 5_000)
            let before = try await store.synchronizationQueue()
            _ = try await store.recordPlayback(sessionID: session.id, sample: sample(5_000), now: now, synchronize: true)
            _ = try await store.recordPlayback(sessionID: session.id, sample: sample(6_000), now: now)
            #expect(try await store.synchronizationQueue() == before)
            _ = try await store.recordPlayback(sessionID: session.id, sample: sample(6_000), now: now, synchronize: true)
            #expect(try await store.synchronizationQueue().count == before.count + 1)
            try await store.updatePreferences(feedID: 1) { $0.subscriptionState = .notSubscribed }
            var preferences = PlaybackEndPreferences()
            preferences.synchronize = true
            _ = try await store.endPlayback(sessionID: session.id, reason: .ended, preferences: preferences, now: now)
            #expect(try await store.synchronizationQueue().count == before.count + 1)
            #expect(try await store.pendingEffects().isEmpty)
        }
    }

    @Test func samplesPreserveSourceTimingWithoutItsConfirmedIntegerOverflow() async throws {
        struct Row: Decodable {
            var start: Int32
            var initialPlayed: Int32
            var initialState: Int
            var position: Int32
            var played: Int32
            var memoryState: Int
            var storedState: Int
        }
        let fixture = try #require(Bundle.module.url(forResource: "playback-java", withExtension: "json", subdirectory: "Fixtures"))
        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: fixture))
        #expect(rows.count == 252)
        #expect(rows.filter { $0.played < 0 }.count == 45) // Retained original defect evidence.
        try await withStore { store, _ in
            _ = try await store.enqueue([1])
            var session: LibraryPlaybackSession?
            for (index, row) in rows.enumerated() {
                if index.isMultiple(of: 7) {
                    let state = try #require(EpisodePlayState(rawValue: row.initialState))
                    try await store.updateEpisode(id: 1) {
                        $0.userState.positionMilliseconds = row.start
                        $0.userState.playedDurationMilliseconds = Int64(row.initialPlayed)
                        $0.userState.playState = state
                    }
                    session = try await store.beginPlayback(episodeID: 1)
                }
                let id = try #require(session?.id)
                let saved = try #require(try await store.recordPlayback(sessionID: id, sample: sample(row.position), now: now))
                #expect(saved.userState.positionMilliseconds == row.position, "Java sample \(index)")
                // These fixtures start nonnegative and can wrap at most once. Recover
                // the unsigned magnitude for the45 confirmed overflow rows only;
                // the207 ordinary rows retain their exact original expectations.
                let intendedPlayed = row.played < 0 ? Int64(UInt32(bitPattern: row.played)) : Int64(row.played)
                #expect(saved.userState.playedDurationMilliseconds == intendedPlayed, "Java sample \(index)")
                #expect(saved.userState.playState.rawValue == row.storedState, "Java sample \(index)")
                #expect(try await store.playbackSession()?.itemPlayState.rawValue == row.memoryState, "Java sample \(index)")
            }
        }
    }

    @Test func fileCleanupDoesNotRecursivelyDeleteDirectoryContents() async throws {
        try await withStore { store, url in
            let directory = url.deletingLastPathComponent().appendingPathComponent("not-a-media-file")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let child = directory.appendingPathComponent("keep.txt")
            try Data("keep".utf8).write(to: child)
            try await store.updateEpisode(id: 1) { $0.userState.localFileURL = directory.path; $0.userState.isDownloaded = true }
            let session = try await store.beginPlayback(episodeID: 1)
            var preferences = PlaybackEndPreferences()
            preferences.autoDelete = true
            _ = try await store.endPlayback(sessionID: session.id, reason: .ended, preferences: preferences, now: now)
            let pending = try await store.pendingEffects()
            await #expect(throws: (any Error).self) { try await MediaDownloadWorker(store: store).cleanCancelledFiles() }
            #expect(try Data(contentsOf: child) == Data("keep".utf8))
            #expect(try await store.pendingEffects() == pending)
        }
    }

    @Test func wideListeningTotalsSurviveReopenRepeatedSessionsAndRewinds() async throws {
        try await withStore { store, url in
            try await store.updateEpisode(id: 1) { $0.userState.playedDurationMilliseconds = 2_147_483_647 }
            let first = try await store.beginPlayback(episodeID: 1, positionMilliseconds: 0)
            _ = try await store.recordPlayback(sessionID: first.id, sample: sample(1), now: now)
            _ = try await store.endPlayback(sessionID: first.id, reason: .switched, now: now)
            try await store.close()
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.episode(id: 1)?.userState.playedDurationMilliseconds == 2_147_483_648)
            let second = try await reopened.beginPlayback(episodeID: 1, positionMilliseconds: 0)
            #expect(second.playedDurationWhenStarted == 2_147_483_648)
            for (position, expected): (Int32, Int64) in [(10_000, 2_147_493_648), (2_000, 2_147_485_648), (0, 2_147_485_648)] {
                let saved = try #require(try await reopened.recordPlayback(sessionID: second.id, sample: sample(position), now: now))
                #expect(saved.userState.playedDurationMilliseconds == expected)
            }
            let statistics = try await reopened.statistics(includeMarkedAsPlayed: false, now: now)
            #expect(statistics.feeds.first?.playedSeconds == 2_147_485)
            #expect(statistics.feeds.first?.episodesStarted == 1)
            let persisted = try FeedLibraryStore(url: url)
            #expect(try await persisted.playbackSession()?.playedDurationWhenStarted == 2_147_483_648)
            #expect(try await persisted.episode(id: 1)?.userState.playedDurationMilliseconds == 2_147_485_648)
            try await persisted.close()
            try await reopened.close()
        }
    }

    @Test func unrepresentableListeningTotalRollsBackInsteadOfWrappingOrTrapping() async throws {
        try await withStore { store, _ in
            try await store.updateEpisode(id: 1) { $0.userState.playedDurationMilliseconds = Int64.max }
            let session = try await store.beginPlayback(episodeID: 1, positionMilliseconds: 0)
            let before = try await store.episode(id: 1)
            let effects = try await store.pendingEffects()
            await #expect(throws: FeedLibraryError.invalidMutation) {
                try await store.recordPlayback(sessionID: session.id, sample: sample(1), now: now, synchronize: true)
            }
            #expect(try await store.episode(id: 1) == before)
            #expect(try await store.playbackSession() == session)
            #expect(try await store.pendingEffects() == effects)
        }
    }

}
