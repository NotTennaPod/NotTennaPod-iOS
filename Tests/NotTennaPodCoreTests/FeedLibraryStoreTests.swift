import Foundation
import SQLite3
import Testing
@testable import NotTennaPodCore

struct FeedLibraryStoreTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func options() -> FeedRefreshOptions { FeedRefreshOptions(now: now, timeZone: .gmt) }

    private func fetched(_ identifiers: [String] = ["a"], source: String = "https://example.test/feed",
                         title: String = "Feed", identifier: String? = nil) -> FetchedFeed {
        let episodes = identifiers.enumerated().map { offset, id in
            ParsedEpisode(identifier: id, title: "Episode \(id)", publicationDate: now.addingTimeInterval(Double(offset)),
                          media: ParsedMedia(url: "https://example.test/\(id).mp3", size: 32_768, mimeType: "audio/mpeg",
                                             durationMilliseconds: 60_000))
        }
        return FetchedFeed(feed: ParsedFeed(format: .rss, identifier: identifier, title: title, episodes: episodes),
                           source: source, responseURL: URL(string: source)!, validator: "etag", permanentRedirectURL: nil)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AntennaPodLibrary-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func withLibrary(_ operation: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        do {
            try await operation(store, url)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    private func rawExecute(_ url: URL, _ sql: String) throws {
        var database: OpaquePointer?
        let opened = sqlite3_open(url.path, &database)
        defer { if let database { sqlite3_close(database) } }
        guard opened == SQLITE_OK else { throw FeedLibraryError.sqlite(code: opened, message: "Test open failed") }
        let status = sqlite3_exec(database, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw FeedLibraryError.sqlite(code: status, message: String(cString: sqlite3_errmsg(database))) }
    }

    @Test func mediaDeletionRollbackKeepsFileMetadataSelectionQueueAndEffects() async throws {
        try await withLibrary { store, url in
            _ = try await store.insert(fetched())
            let file = url.deletingLastPathComponent().appendingPathComponent("existing.media")
            try Data("protected by transaction".utf8).write(to: file)
            try await store.updateEpisode(id: 1) {
                $0.userState.localFileURL = file.path; $0.userState.isDownloaded = true
                $0.userState.positionMilliseconds = 12000; $0.userState.isFavorite = true
            }
            _ = try await store.beginPlayback(episodeID: 1)
            let episode = try await store.episode(id: 1), session = try await store.playbackSession()
            let queue = try await store.queue(), effects = try await store.pendingEffects()
            try rawExecute(url, "CREATE TRIGGER reject_deletion BEFORE INSERT ON pending_effects BEGIN SELECT RAISE(ABORT, 'deletion failure'); END")
            await #expect(throws: (any Error).self) { try await store.requestMediaDeletion(episodeID: 1, deleteRemovesFromQueue: true) }
            #expect(try await store.episode(id: 1) == episode)
            #expect(try await store.playbackSession() == session)
            #expect(try await store.playbackSelectionEpisodeID() == 1)
            #expect(try await store.queue() == queue)
            #expect(try await store.pendingEffects() == effects)
            #expect(try Data(contentsOf: file) == Data("protected by transaction".utf8))
        }
    }

    @Test func mediaDeletionRejectsAnActiveDownloadWithoutChangingItsState() async throws {
        try await withLibrary { store, url in
            _ = try await store.insert(fetched())
            let job = try #require(await store.requestDownload(episodeID: 1, directory: url.deletingLastPathComponent()))
            let episode = try await store.episode(id: 1), effects = try await store.pendingEffects()
            await #expect(throws: FeedLibraryError.invalidMutation) { try await store.requestMediaDeletion(episodeID: 1) }
            #expect(try await store.downloadJobs() == [job])
            #expect(try await store.episode(id: 1) == episode)
            #expect(try await store.pendingEffects() == effects)
        }
    }

    @Test(arguments: ["present", "missing", "nil"])
    func missingDownloadedMediaRepairsOnlyDownloadFields(pathState: String) async throws {
        try await withLibrary { store, url in
            _ = try await store.insert(fetched())
            let file = url.deletingLastPathComponent().appendingPathComponent("download.media")
            if pathState == "present" { try Data("download".utf8).write(to: file) }
            try await store.updateEpisode(id: 1) {
                $0.userState.isDownloaded = true
                $0.userState.localFileURL = pathState == "nil" ? nil : file.path
                $0.userState.downloadDate = Date(timeIntervalSince1970: 1000)
                $0.userState.isFavorite = true; $0.userState.positionMilliseconds = 12000
            }
            _ = try await store.beginPlayback(episodeID: 1)
            var expected = try #require(await store.episode(id: 1))
            let session = try await store.playbackSession(), effects = try await store.pendingEffects()
            if pathState != "present" {
                expected.userState.isDownloaded = false; expected.userState.localFileURL = nil; expected.userState.downloadDate = nil
            }
            #expect(try await store.repairMissingDownloadedMedia(episodeID: 1) == (pathState != "present"))
            #expect(try await store.episode(id: 1) == expected)
            #expect(try await store.queue().map(\.id) == [1])
            #expect(try await store.playbackSession() == session)
            #expect(try await store.pendingEffects() == effects)
            #expect(try await store.repairMissingDownloadedMedia(episodeID: 1) == false)
        }
    }

    @Test func storesParsedFeedAndReopensWithStableIDsAndDefaultDateOrder() async throws {
        try await withLibrary { store, url in
            try await store.selectSynchronizationAccount(UUID())
            let saved = try await store.insert(fetched(["a", "b", "c"]), options: options())
            #expect(saved.episodes.map(\.details.identifier) == ["c", "b", "a"])
            #expect(saved.episodes.map(\.id) == [3, 2, 1])
            #expect(saved.metadata.episodes.isEmpty)
            #expect(saved.episodes.allSatisfy { $0.userState.playState == .unplayed })
            #expect(try await store.logs(feedID: saved.id).isEmpty)
            // The subscription is sent to the connected account; nothing else is left to do.
            #expect(try await store.pendingEffects().isEmpty)
            #expect(try await store.synchronizationQueue().map(\.value) == [.added(saved.source)])
            try await store.close()
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.feed(id: saved.id) == saved)
            #expect(try await reopened.pendingEffects().isEmpty)
            #expect(try await reopened.synchronizationQueue().map(\.value) == [.added(saved.source)])
            try await reopened.close()
        }
    }

    @Test func playbackStateMeasuredDurationAndPreferencesSurviveRefreshAndReopen() async throws {
        try await withLibrary { store, url in
            let saved = try await store.insert(fetched(), options: options())
            let id = try #require(saved.episodes.first?.id)
            let date = now
            try await store.updateEpisode(id: id) {
                $0.userState.positionMilliseconds = 12_345
                $0.userState.playedDurationMilliseconds = 33_000
                $0.userState.timeSpentMilliseconds = 44_000
                $0.userState.lastPlayedTimeMilliseconds = 1_700_000_000_000
                $0.userState.playbackCompletionDate = date
                $0.userState.playState = .played
                $0.userState.localFileURL = "file:///downloaded episode.mp3"
                $0.userState.isDownloaded = true
                $0.userState.downloadDate = date
                $0.userState.isFavorite = true
                $0.userState.autoDownloadEnabled = false
                $0.details.media?.durationMilliseconds = 65_000
            }
            try await store.updatePreferences(feedID: saved.id) {
                $0.customTitle = "My podcast"
                $0.newEpisodesAction = .nothing
                $0.autoDownload = .disabled
                $0.skip = .init(introSeconds: 12, endingSeconds: 7)
                $0.volumeAdaptation = .mediumBoost
            }
            let expected = try #require(try await store.episode(id: id))
            var changed = fetched(["a", "b"], title: "Publisher changed title")
            changed.feed.episodes[0].description = "Updated shownotes"
            _ = try await store.applyRefresh(changed, feedID: saved.id, options: options())
            try await store.close()
            let reopened = try FeedLibraryStore(url: url)
            let actual = try #require(try await reopened.episode(id: id))
            #expect(actual.userState == expected.userState)
            #expect(actual.details.media?.durationMilliseconds == 65_000)
            #expect(actual.details.description == "Updated shownotes")
            let feed = try #require(try await reopened.feed(id: saved.id))
            #expect(feed.title == "My podcast" && feed.metadata.title == "Publisher changed title")
            #expect(feed.newEpisodesAction == .nothing && feed.autoDownload == .disabled)
            #expect(feed.skipPreferences == .init(introSeconds: 12, endingSeconds: 7))
            #expect(feed.volumeAdaptation == .mediumBoost)
            #expect(feed.episodes.count == 2)
            try await reopened.close()
        }
    }

    @Test func duplicateSubscriptionIdentityUsesGUIDOrExactSourceAndPreservesUserChoices() async throws {
        try await withLibrary { store, _ in
            try await store.selectSynchronizationAccount(UUID())
            let first = try await store.insert(fetched(source: "https://example.test/one", identifier: "publisher"), options: options())
            try await store.updatePreferences(feedID: first.id) { $0.customTitle = "Custom" }
            let same = try await store.insert(fetched(["a", "b"], source: "https://example.test/two", identifier: "publisher"), options: options())
            #expect(same.id == first.id && same.source == first.source && same.title == "Custom")
            #expect(same.episodes.count == 2)
            let different = try await store.insert(fetched(source: "https://example.test/three"), options: options())
            #expect(different.id != first.id)
            #expect(try await store.feeds().count == 2)
            // Two subscriptions, two subscription actions (the merged duplicate adds none).
            #expect(try await store.synchronizationQueue().map(\.value) == [.added("https://example.test/one"), .added("https://example.test/three")])
        }
    }

    @Test func feedIdentityKeepsComposedAndDecomposedUnicodeDistinct() async throws {
        try await withLibrary { store, _ in
            let first = try await store.insert(fetched(identifier: "é"), options: options())
            let second = try await store.insert(fetched(identifier: "e\u{301}"), options: options())
            #expect(first.id != second.id)
            #expect(try await store.feeds().count == 2)
        }
    }

    @Test func boundUnicodeNULAndSQLSyntaxRoundTripWithoutChangingSchema() async throws {
        try await withLibrary { store, url in
            var input = fetched(title: "Episode'); DROP TABLE feeds; -- 😀\0end")
            input.feed.episodes[0].description = "Line one\nLine two\0é e\u{301}"
            let saved = try await store.insert(input, options: options())
            #expect(try await store.feed(id: saved.id) == saved)
            let db = try LibrarySQLite(url: url)
            #expect(try db.scalar("SELECT count(*) FROM feeds") == 1)
            try db.close()
            #expect(saved.metadata.title?.utf16.elementsEqual(input.feed.title!.utf16) == true)
            #expect(saved.episodes[0].details.description == input.feed.episodes[0].description)
        }
    }

    @Test func transactionFailureRollsBackMetadataEpisodesIDsLogsAndEffects() async throws {
        try await withLibrary { store, url in
            let original = try await store.insert(fetched(["a", "remove"]), options: options())
            try await store.updatePreferences(feedID: original.id) { $0.newEpisodesAction = .queue }
            try await store.recordFailure(.forbidden, feedID: original.id, date: now)
            let before = try await store.feed(id: original.id)
            let oldEffects = try await store.pendingEffects()
            let oldLog = try await store.logs(feedID: original.id)
            let db = try LibrarySQLite(url: url)
            let priorSequence = try db.scalar("SELECT value FROM library_ids WHERE kind = 'episode'")
            try db.execute("CREATE TRIGGER reject_effect BEFORE INSERT ON pending_effects BEGIN SELECT RAISE(ABORT, 'Injected effect failure'); END")
            var settings = options()
            settings.removeUnlistedItems = true
            settings.now = now.addingTimeInterval(2)
            settings.refreshAttempt = settings.now
            let input = fetched(["a", "new"], title: "Changed")
            await #expect(throws: FeedLibraryError.self) {
                try await store.applyRefresh(input, feedID: original.id, options: settings)
            }
            #expect(try await store.feed(id: original.id) == before)
            #expect(try await store.pendingEffects() == oldEffects)
            #expect(try await store.logs(feedID: original.id) == oldLog)
            #expect(try db.scalar("SELECT value FROM library_ids WHERE kind = 'episode'") == priorSequence)
            try db.execute("DROP TRIGGER reject_effect")
            let result = try await store.applyRefresh(input, feedID: original.id, options: settings)
            #expect(result.removedEpisodes.count == 1)
            #expect(try await store.feed(id: original.id)?.episodes.map(\.details.identifier) == ["new", "a"])
            #expect(try await store.logs(feedID: original.id).first?.kind == .success)
            try db.close()
        }
    }

    @Test func initialInsertFailureLeavesNoFeedOrEffectAndRollsBackIDAllocation() async throws {
        try await withLibrary { store, url in
            let db = try LibrarySQLite(url: url)
            try db.execute("CREATE TRIGGER reject_episode BEFORE INSERT ON episodes WHEN NEW.id = 2 BEGIN SELECT RAISE(ABORT, 'Injected second episode failure'); END")
            await #expect(throws: FeedLibraryError.self) { try await store.insert(fetched(["a", "b"]), options: options()) }
            #expect(try await store.feeds().isEmpty)
            #expect(try await store.pendingEffects().isEmpty)
            #expect(try db.scalar("SELECT count(*) FROM episodes") == 0)
            #expect(try db.scalar("SELECT value FROM library_ids WHERE kind = 'feed'") == 0)
            #expect(try db.scalar("SELECT value FROM library_ids WHERE kind = 'episode'") == 0)
            try db.execute("DROP TRIGGER reject_episode")
            let feed = try await store.insert(fetched(), options: options())
            #expect(feed.id == 1 && feed.episodes[0].id == 1)
            try db.close()
        }
    }

    @Test func pendingEffectsSurviveReopenAndOnlyAcknowledgedWorkDisappears() async throws {
        try await withLibrary { store, url in
            let feed = try await store.insert(fetched(), options: options())
            try await store.updatePreferences(feedID: feed.id) { $0.newEpisodesAction = .queue }
            _ = try await store.applyRefresh(fetched(["a", "b"]), feedID: feed.id, options: options())
            _ = try await store.applyRefresh(fetched(["a", "b", "c"]), feedID: feed.id, options: options())
            let pending = try await store.pendingEffects()
            #expect(pending.map(\.effect.kind) == [.queueEpisodes([2]), .queueEpisodes([3])])
            try await store.close()
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.pendingEffects() == pending)
            try await reopened.acknowledgeEffect(id: pending[0].id)
            try await reopened.acknowledgeEffect(id: pending[0].id)
            #expect(try await reopened.pendingEffects() == Array(pending.dropFirst()))
            try await reopened.close()
        }
    }

    @Test func removalPersistsCleanupDetailsAndNeverReusesDeletedEpisodeIDs() async throws {
        try await withLibrary { store, _ in
            let feed = try await store.insert(fetched(), options: options())
            let id = feed.episodes[0].id
            try await store.updateEpisode(id: id) {
                $0.userState.isDownloaded = true
                $0.userState.localFileURL = "file:///download.mp3"
            }
            var settings = options()
            settings.removeUnlistedItems = true
            let result = try await store.applyRefresh(fetched([]), feedID: feed.id, options: settings)
            #expect(try await store.episode(id: id) == nil)
            #expect(result.removedEpisodes.first?.userState.localFileURL == "file:///download.mp3")
            #expect(try await store.pendingEffects().last?.effect.kind == .removeEpisodes(result.removedEpisodes))
            let added = try await store.applyRefresh(fetched(["new"]), feedID: feed.id, options: options())
            #expect(added.feed.episodes[0].id > id)
        }
    }

    @Test func repairedPlayedEpisodePersistsSyncProposalAndDuplicateRecoveryLogs() async throws {
        try await withLibrary { store, _ in
            let input = fetched()
            let saved = try await store.insert(input, options: options())
            try await store.updateEpisode(id: saved.episodes[0].id) { $0.userState.playState = .played }
            try await store.selectSynchronizationAccount(UUID())
            var changed = input
            changed.feed.episodes[0].identifier = "changed"
            let result = try await store.applyRefresh(changed, feedID: saved.id, options: options())
            #expect(result.feed.episodes[0].id == saved.episodes[0].id)
            let logs = try await store.logs(feedID: saved.id)
            #expect(logs.count == 2 && logs[1].kind == .success)
            guard case .duplicate = logs[0].kind else { Issue.record("Expected duplicate diagnostic"); return }
            #expect(logs[0].title == "Episode a")
            // The repaired played episode is sent as played under its new GUID.
            let sync = try #require(result.completedEpisodeSync.first)
            #expect(sync.identifier == "changed")
            #expect(try await store.synchronizationQueue().map(\.value) == [.episode(.init(podcast: saved.source,
                episode: try #require(sync.mediaURL), guid: "changed", action: .play, timestamp: options().now,
                started: sync.totalSeconds, position: sync.totalSeconds, total: sync.totalSeconds))])
            #expect(try await store.pendingEffects().isEmpty)
        }
    }

    @Test func successfulRefreshOnlyAddsSuccessLogFollowingFailure() async throws {
        try await withLibrary { store, _ in
            let input = fetched()
            let feed = try await store.insert(input, options: options())
            _ = try await store.applyRefresh(input, feedID: feed.id, options: options())
            #expect(try await store.logs(feedID: feed.id).isEmpty)
            try await store.recordFailure(.notFound(status: 404), feedID: feed.id, date: now.addingTimeInterval(1))
            let failed = try #require(try await store.feed(id: feed.id))
            #expect(failed.lastUpdateFailed && failed.lastRefreshAttempt == now.addingTimeInterval(1))
            var settings = options()
            settings.now = now.addingTimeInterval(2)
            settings.refreshAttempt = settings.now
            _ = try await store.applyRefresh(input, feedID: feed.id, options: settings)
            _ = try await store.applyRefresh(input, feedID: feed.id, options: settings)
            #expect(try await store.logs(feedID: feed.id).map(\.kind) == [.success, .failure(.notFound(status: 404))])
            #expect(try await store.feed(id: feed.id)?.lastUpdateFailed == false)
        }
    }

    @Test func redirectsAreSkippedOnInitialInsertAndCommittedForAllExactMatchingSourcesOnRefresh() async throws {
        try await withLibrary { store, _ in
            var input = fetched(identifier: "one")
            input.permanentRedirectURL = "https://example.test/permanent"
            input.feed.redirectURL = "https://example.test/itunes"
            let first = try await store.insert(input, options: options())
            #expect(first.source == input.source)
            var sameSource = fetched(identifier: "two")
            sameSource.feed.episodes = []
            let second = try await store.insert(sameSource, options: options())
            let untouched = try await store.insert(fetched(source: "https://example.test/feed/", identifier: "three"), options: options())
            _ = try await store.applyRefresh(input, feedID: first.id, options: options())
            #expect(try await store.feed(id: first.id)?.source == input.permanentRedirectURL)
            #expect(try await store.feed(id: second.id)?.source == input.permanentRedirectURL)
            #expect(try await store.feed(id: untouched.id)?.source == untouched.source)
        }
    }

    @Test func twoConnectionsSerializeUpdatesWithoutLosingStateOrAllocatingDuplicateIDs() async throws {
        try await withLibrary { store, url in
            let second = try FeedLibraryStore(url: url)
            let saved = try await store.insert(fetched(), options: options())
            let id = saved.episodes[0].id
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<100 {
                    let writer = index.isMultiple(of: 2) ? store : second
                    group.addTask {
                        try await writer.updateEpisode(id: id) { $0.userState.positionMilliseconds += 1 }
                    }
                }
                try await group.waitForAll()
            }
            #expect(try await store.episode(id: id)?.userState.positionMilliseconds == 100)
            try await withThrowingTaskGroup(of: Int64.self) { group in
                for index in 0..<20 {
                    let writer = index.isMultiple(of: 2) ? store : second
                    let incoming = fetched(["\(index)"], source: "https://example.test/\(index)")
                    let settings = options()
                    group.addTask { try await writer.insert(incoming, options: settings).id }
                }
                var ids: Set<Int64> = []
                for try await id in group { ids.insert(id) }
                #expect(ids.count == 20)
            }
            #expect(try await store.feeds().count == 21)
            try await second.close()
        }
    }

    @Test func invalidEpisodeMutationRollsBackAndMissingRecordsStayMissing() async throws {
        try await withLibrary { store, _ in
            let feed = try await store.insert(fetched(), options: options())
            let original = feed.episodes[0]
            await #expect(throws: FeedLibraryError.invalidMutation) {
                try await store.updateEpisode(id: original.id) { $0.id = 999; $0.userState.isFavorite = true }
            }
            await #expect(throws: FeedLibraryError.invalidMutation) {
                try await store.updateEpisode(id: original.id) { $0.details.publicationDate = nil }
            }
            #expect(try await store.episode(id: original.id) == original)
            await #expect(throws: FeedLibraryError.missingEpisode(999)) {
                try await store.updateEpisode(id: 999) { $0.userState.isFavorite = true }
            }
            await #expect(throws: FeedLibraryError.missingFeed(999)) {
                try await store.applyRefresh(fetched(), feedID: 999, options: options())
            }
            #expect(try await store.feed(id: 999) == nil)
            #expect(try await store.episode(id: 999) == nil)
        }
    }

    @Test func schemaVersionAndForeignDatabaseProtectionDoNotDiscardData() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let foreign = directory.appendingPathComponent("foreign.sqlite")
        try rawExecute(foreign, "CREATE TABLE original(value TEXT); INSERT INTO original VALUES ('preserved')")
        #expect(throws: FeedLibraryError.foreignDatabase) { try FeedLibraryStore(url: foreign) }
        try rawExecute(foreign, "INSERT INTO original VALUES ('still usable')")
        let future = directory.appendingPathComponent("future.sqlite")
        let db = try LibrarySQLite(url: future)
        try db.execute("PRAGMA user_version = 99")
        try db.close()
        #expect(throws: FeedLibraryError.unsupportedSchema(99)) { try FeedLibraryStore(url: future) }
        try rawExecute(future, "UPDATE library_ids SET value = 500 WHERE kind = 'feed'")
        let bad = directory.appendingPathComponent("broken.sqlite")
        let bytes = Data("This is not SQLite".utf8)
        try bytes.write(to: bad)
        #expect(throws: FeedLibraryError.self) { try FeedLibraryStore(url: bad) }
        #expect(try Data(contentsOf: bad) == bytes)
    }

    @Test func corruptedRecordIsReportedInsteadOfRecreatingAnEmptyLibrary() async throws {
        try await withLibrary { store, url in
            let feed = try await store.insert(fetched(), options: options())
            let db = try LibrarySQLite(url: url)
            try db.execute("UPDATE episodes SET record = ? WHERE id = ?", [.blob(Data("{broken".utf8)), .integer(feed.episodes[0].id)])
            await #expect(throws: DecodingError.self) { try await store.feed(id: feed.id) }
            #expect(try db.scalar("SELECT count(*) FROM episodes") == 1)
            #expect(try db.scalar("SELECT count(*) FROM feeds") == 1)
            try db.close()
        }
    }

    @Test func refreshLogUsesCompletionDateRatherThanInsertionOrderWhenClockMovesBack() async throws {
        try await withLibrary { store, _ in
            let input = fetched()
            let feed = try await store.insert(input, options: options())
            try await store.recordFailure(.connection, feedID: feed.id, date: now.addingTimeInterval(100))
            try await store.recordFailure(.forbidden, feedID: feed.id, date: now.addingTimeInterval(10))
            #expect(try await store.logs(feedID: feed.id).map(\.kind) == [.failure(.connection), .failure(.forbidden)])
            _ = try await store.applyRefresh(input, feedID: feed.id, options: options())
            #expect(try await store.logs(feedID: feed.id).map(\.kind) == [.failure(.connection), .failure(.forbidden), .success])
        }
    }

    @Test func previewAndLocalFeedInsertDoNotScheduleRemoteSubscriptionSync() async throws {
        try await withLibrary { store, _ in
            _ = try await store.insert(fetched(source: "https://example.test/preview"), options: options(), subscriptionState: .notSubscribed)
            var local = options()
            local.isLocalFeed = true
            _ = try await store.insert(fetched(source: "https://example.test/local"), options: local)
            #expect(try await store.pendingEffects().isEmpty)
        }
    }
}
