import Foundation
import Testing
@testable import NotTennaPodCore

struct LibraryLocalFolderTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func snapshot(_ names: [String]) -> ParsedFeed {
        ParsedFeed(format: .rss, title: "Folder", episodes: names.map { name in
            ParsedEpisode(identifier: "id-" + name, title: name, link: name, publicationDate: now,
                media: ParsedMedia(url: "document:" + name, size: 100, mimeType: "audio/mpeg", durationMilliseconds: 30_000))
        })
    }
    private func fixture(_ body: (FeedLibraryStore, URL, URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryLocal-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        do { try await body(store, url, folder); try await store.close() }
        catch { try? await store.close(); throw error }
    }
    private func register(_ store: FeedLibraryStore) async throws -> LocalFolderScanContext {
        try await store.registerLocalFolder(title: "Folder", directoryIdentity: "fixture:folder", bookmark: Data([1, 2, 3]))
    }

    @Test func registrationAndRealBookmarkSurviveRelaunchWithoutDuplicateFeedOrLostState() async throws {
        try await fixture { store, url, parent in
            let directory = parent.appendingPathComponent("media", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data([1]).write(to: directory.appendingPathComponent("a.mp3"))
            let bookmark = try LocalFolderDocuments.makeBookmark(directory: directory)
            let initial = try await store.registerLocalFolder(title: "Folder", directoryIdentity: directory.absoluteString, bookmark: bookmark)
            let applied = try await store.applyLocalFolderScan(snapshot(["a.mp3"]), context: initial)
            let id = try #require(applied.feed.episodes.first?.id)
            try await store.updatePreferences(feedID: initial.feed.id) { $0.customTitle = "My folder" }
            try await store.updateEpisode(id: id) { $0.userState.isFavorite = true; $0.userState.positionMilliseconds = 1234 }
            try await store.close()
            let reopened = try FeedLibraryStore(url: url)
            let link = try #require(try await reopened.localFolder(feedID: initial.feed.id))
            #expect(try await LocalFolderDocuments(bookmark: link.bookmark).entries().map(\.name) == ["a.mp3"])
            let repeated = try await reopened.registerLocalFolder(title: "Changed picker title", directoryIdentity: directory.absoluteString, bookmark: bookmark)
            #expect(repeated.feed.id == initial.feed.id && repeated.feed.title == "My folder")
            #expect(repeated.feed.episodes.first?.id == id && repeated.feed.episodes.first?.userState.isFavorite == true)
            #expect(repeated.feed.episodes.first?.userState.positionMilliseconds == 1234)
            #expect(try await reopened.feeds().count == 1)
            let reference = try #require(try await reopened.localDocument(episodeID: id))
            #expect(reference.filename == "a.mp3" && reference.identity == "document:a.mp3")
            #expect(reference.folder.bookmark == bookmark)
            #expect(repeated.feed.autoDownload == .disabled && repeated.feed.episodes.first?.userState.autoDownloadEnabled == false)
            #expect(try await reopened.pendingEffects().isEmpty)
            try await reopened.close()
        }
    }

    @Test func reconnectKeepsFeedHistoryButRejectsOldFolderScan() async throws {
        try await fixture { store, _, _ in
            let initial = try await register(store)
            _ = try await store.applyLocalFolderScan(snapshot(["a.mp3"]), context: initial)
            try await store.updateEpisode(id: 1) { $0.userState.positionMilliseconds = 3456; $0.userState.isFavorite = true }
            let old = try await store.beginLocalFolderScan(feedID: 1)
            let next = try await store.reconnectLocalFolder(feedID: 1, directoryIdentity: "fixture:replacement", bookmark: Data([4, 5]))
            await #expect(throws: FeedLibraryError.invalidMutation) { try await store.applyLocalFolderScan(snapshot([]), context: old) }
            #expect(next.feed.source == "antennapod_local:fixture:replacement")
            let updated = try await store.applyLocalFolderScan(snapshot(["a.mp3"]), context: next)
            #expect(updated.feed.episodes.first?.id == 1 && updated.feed.episodes.first?.userState.positionMilliseconds == 3456)
            #expect(updated.feed.episodes.first?.userState.isFavorite == true)
            #expect(try await store.localFolder(feedID: 1)?.bookmark == Data([4, 5]))
        }
    }

    @Test func latestStartedScanWinsAndCannotBeAppliedTwice() async throws {
        try await fixture { store, _, _ in
            _ = try await register(store)
            let old = try await store.beginLocalFolderScan(feedID: 1)
            let latest = try await store.beginLocalFolderScan(feedID: 1)
            await #expect(throws: FeedLibraryError.invalidMutation) { try await store.applyLocalFolderScan(snapshot(["old.mp3"]), context: old) }
            _ = try await store.applyLocalFolderScan(snapshot(["current.mp3"]), context: latest)
            await #expect(throws: FeedLibraryError.invalidMutation) { try await store.applyLocalFolderScan(snapshot([]), context: latest) }
            #expect(try await store.feed(id: 1)?.episodes.map(\.details.link) == ["current.mp3"])
        }
    }

    @Test func bookmarkWriteFailureRollsBackScanQueuePlaybackEffectsAndAllocatedIDs() async throws {
        try await fixture { store, url, _ in
            let initial = try await register(store)
            _ = try await store.applyLocalFolderScan(snapshot(["a.mp3"]), context: initial)
            _ = try await store.enqueue([1]); _ = try await store.beginPlayback(episodeID: 1)
            let context = try await store.beginLocalFolderScan(feedID: 1)
            let feeds = try await store.feeds(), effects = try await store.pendingEffects()
            let session = try await store.playbackSession()
            let db = try LibrarySQLite(url: url)
            try db.execute("CREATE TRIGGER fail_bookmark BEFORE UPDATE ON local_folder_links BEGIN SELECT RAISE(ABORT, 'bookmark failure'); END")
            await #expect(throws: FeedLibraryError.self) {
                try await store.applyLocalFolderScan(snapshot(["b.mp3"]), context: context, refreshedBookmark: Data([9]))
            }
            #expect(try await store.feeds() == feeds)
            #expect(try await store.pendingEffects() == effects)
            #expect(try await store.queue().map(\.id) == [1])
            #expect(try await store.playbackSession() == session)
            #expect(try await store.playbackSelectionEpisodeID() == 1)
            #expect(try await store.localFolder(feedID: 1) == context.link)
            try db.execute("DROP TRIGGER fail_bookmark"); try db.close()
            let result = try await store.applyLocalFolderScan(snapshot(["b.mp3"]), context: context, refreshedBookmark: Data([9]))
            #expect(result.feed.episodes.map(\.details.link) == ["b.mp3"])
            #expect(try await store.playbackSession() == nil)
            #expect(try await store.playbackSelectionEpisodeID() == nil)
            #expect(try await store.localFolder(feedID: 1)?.bookmark == Data([9]))
        }
    }

    @Test func registrationAndReconnectionFailuresLeaveNoHalfLinkedFeed() async throws {
        try await fixture { store, url, _ in
            let db = try LibrarySQLite(url: url)
            try db.execute("CREATE TRIGGER fail_link BEFORE INSERT ON local_folder_links BEGIN SELECT RAISE(ABORT, 'link failure'); END")
            await #expect(throws: FeedLibraryError.self) { try await register(store) }
            #expect(try await store.feeds().isEmpty)
            try db.execute("DROP TRIGGER fail_link")
            let context = try await register(store)
            try db.execute("CREATE TRIGGER fail_link BEFORE UPDATE ON local_folder_links BEGIN SELECT RAISE(ABORT, 'link failure'); END")
            await #expect(throws: FeedLibraryError.self) {
                try await store.reconnectLocalFolder(feedID: 1, directoryIdentity: "other", bookmark: Data([9]))
            }
            #expect(try await store.feed(id: 1) == context.feed)
            #expect(try await store.localFolder(feedID: 1) == context.link)
            try db.close()
        }
    }

    @Test func removedLocalEpisodesCleanQueueSelectionButNeverDeleteProviderFiles() async throws {
        try await fixture { store, url, folder in
            let providerFile = folder.appendingPathComponent("a.mp3"); try Data([8, 9]).write(to: providerFile)
            let initial = try await register(store)
            _ = try await store.applyLocalFolderScan(snapshot(["a.mp3", "b.mp3", "c.mp3"]), context: initial)
            _ = try await store.enqueue([3, 1, 2]); _ = try await store.beginPlayback(episodeID: 1)
            let context = try await store.beginLocalFolderScan(feedID: 1)
            try await store.updateEpisode(id: 2) { $0.userState.positionMilliseconds = 4321; $0.userState.isFavorite = true }
            let result = try await store.applyLocalFolderScan(snapshot(["b.mp3", "c.mp3"]), context: context)
            #expect(result.removedEpisodes.map(\.id) == [1])
            #expect(try await store.queue().map(\.id) == [3, 2])
            #expect(try await store.playbackSelectionEpisodeID() == nil)
            #expect(result.feed.episodes.first { $0.id == 2 }?.userState.positionMilliseconds == 4321)
            #expect(result.feed.episodes.first { $0.id == 2 }?.userState.isFavorite == true)
            #expect(try Data(contentsOf: providerFile) == Data([8, 9]))
            for pending in try await store.pendingEffects() {
                if case .removeEpisodes = pending.effect.kind { } else { Issue.record("Unexpected local cleanup/sync effect") }
            }
            let db = try LibrarySQLite(url: url)
            #expect(try db.rows("SELECT position FROM queue ORDER BY position").compactMap { $0[0].integer } == [0, 1])
            try db.close()
        }
    }

    @Test func newLocalQueueIntentSurvivesRelaunchAndExecutesOnce() async throws {
        try await fixture { store, url, _ in
            let initial = try await register(store)
            try await store.updatePreferences(feedID: 1) { $0.newEpisodesAction = .queue; $0.autoDownload = .enabled }
            let result = try await store.applyLocalFolderScan(snapshot(["a.mp3"]), context: initial,
                options: FeedRefreshOptions(now: now, timeZone: .gmt))
            #expect(result.queueEpisodeIDs == [1] && result.feed.autoDownload == .disabled)
            #expect(result.feed.episodes.first?.userState.autoDownloadEnabled == false)
            try await store.close()
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.consumeQueueEffects().count == 1)
            #expect(try await reopened.consumeQueueEffects().isEmpty)
            #expect(try await reopened.queue().map(\.id) == [1])
            try await reopened.close()
        }
    }


    @Test func olderInitialFilesDoNotTriggerNewEpisodeQueueAction() async throws {
        try await fixture { store, _, _ in
            let initial = try await register(store)
            try await store.updatePreferences(feedID: 1) { $0.newEpisodesAction = .queue }
            let result = try await store.applyLocalFolderScan(snapshot(["archive.mp3"]), context: initial,
                options: FeedRefreshOptions(now: now.addingTimeInterval(1), timeZone: .gmt))
            #expect(result.feed.episodes.count == 1)
            #expect(result.queueEpisodeIDs.isEmpty)
            #expect(try await store.pendingEffects().isEmpty)
            #expect(try await store.queue().isEmpty)
        }
    }

    @Test func cancelledAndInvalidScansDoNotConsumeCurrentGrantOrChangeLibrary() async throws {
        try await fixture { store, _, _ in
            let context = try await register(store)
            let snapshot = snapshot(["a.mp3"])
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await store.applyLocalFolderScan(snapshot, context: context)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            await #expect(throws: FeedLibraryError.invalidMutation) {
                try await store.applyLocalFolderScan(snapshot, context: context, refreshedBookmark: Data())
            }
            #expect(try await store.localFolder(feedID: 1) == context.link)
            #expect(try await store.feed(id: 1) == context.feed)
            #expect(try await store.pendingEffects().isEmpty)
            let applied = try await store.applyLocalFolderScan(snapshot, context: context)
            #expect(applied.feed.episodes.first?.id == 1)
        }
    }

    @Test func ordinaryFeedCannotBeReconnectedAndDeletedFeedLosesItsGrant() async throws {
        try await fixture { store, url, _ in
            let local = try await register(store)
            let remote = try await store.insert(FetchedFeed(feed: snapshot(["remote.mp3"]),
                source: "https://example.test/rss", responseURL: URL(string: "https://example.test/rss")!,
                validator: nil, permanentRedirectURL: nil))
            await #expect(throws: FeedLibraryError.invalidMutation) {
                try await store.reconnectLocalFolder(feedID: remote.id, directoryIdentity: "other", bookmark: Data([1]))
            }
            #expect(try await store.localFolder(feedID: remote.id) == nil)
            #expect(try await store.localDocument(episodeID: remote.episodes[0].id) == nil)
            let db = try LibrarySQLite(url: url)
            try db.execute("DELETE FROM feeds WHERE id = ?", [.integer(local.feed.id)])
            #expect(try await store.localFolder(feedID: local.feed.id) == nil)
            #expect(try db.rows("PRAGMA foreign_key_check").isEmpty)
            try db.close()
        }
    }

    @Test func schemaFiveMigrationPreservesLibraryQueuePlaybackAndDoesNotInventGrants() async throws {
        try await fixture { store, url, _ in
            let initial = try await register(store)
            _ = try await store.applyLocalFolderScan(snapshot(["a.mp3"]), context: initial)
            _ = try await store.enqueue([1]); _ = try await store.beginPlayback(episodeID: 1)
            let feeds = try await store.feeds(), session = try await store.playbackSession()
            try await store.close()
            let old = try LibrarySQLite(url: url)
            try restoreRefreshSchemaEleven(old)
            try old.execute("DROP TABLE feed_credentials"); try old.execute("DROP TABLE feed_credential_cleanup")
            try old.execute("DROP TABLE episode_notification_work"); try old.execute("DROP TABLE episode_notification_attempt")
            try old.execute("DROP TABLE local_folder_links"); try old.execute("DROP TABLE manual_feed_refresh"); try old.execute("ALTER TABLE queue_work DROP COLUMN token"); try old.execute("DROP TABLE synchronization_state"); try old.execute("DROP TABLE synchronization_outbox"); try old.execute("PRAGMA user_version = 5"); try old.close()
            let migrated = try FeedLibraryStore(url: url)
            #expect(try await migrated.feeds() == feeds)
            #expect(try await migrated.playbackSession() == session)
            #expect(try await migrated.queue().map(\.id) == [1])
            #expect(try await migrated.localFolder(feedID: 1) == nil)
            await #expect(throws: FeedLibraryError.invalidMutation) { try await migrated.beginLocalFolderScan(feedID: 1) }
            try await migrated.close()
            let db = try LibrarySQLite(url: url)
            #expect(try db.rows("PRAGMA foreign_key_check").isEmpty)
            try db.close()
        }
    }
}
