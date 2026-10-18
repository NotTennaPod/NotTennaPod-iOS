import Foundation
import SQLite3
import Testing
@testable import NotTennaPodCore

struct EpisodeMarkUndoTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func fixture(_ body: (FeedLibraryStore, URL, Int64) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwipeUndo-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        let feed = try await store.insert(.init(feed: .init(format: .rss, title: "Undo", episodes: [
            .init(identifier: "one", title: "Original", publicationDate: now,
                media: .init(url: "https://example.test/one.mp3", size: 123, durationMilliseconds: 120_000)),
            .init(identifier: "two", title: "Other", publicationDate: now,
                media: .init(url: "https://example.test/two.mp3", size: 456, durationMilliseconds: 120_000))
        ]), source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!,
            validator: nil, permanentRedirectURL: nil), options: .init(now: now))
        let id = try #require(feed.episodes.first { $0.details.identifier == "one" }?.id)
        try await store.updateEpisode(id: id) {
            $0.userState.playState = .new
            $0.userState.positionMilliseconds = 12_000
            $0.userState.lastPlayedHistoryMilliseconds = 77
        }
        do { try await body(store, url, id); try await store.close() }
        catch { try? await store.close(); throw error }
    }

    /// Independent SQLite connection; never calls the production read/migration helpers.
    private func sql(_ url: URL, _ query: String) throws -> [[String?]] {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw FeedLibraryError.corruptRecord }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        guard sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil) == SQLITE_OK else { throw FeedLibraryError.corruptRecord }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, query, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw FeedLibraryError.sqlite(code: prepared, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        var result: [[String?]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw FeedLibraryError.sqlite(code: status, message: String(cString: sqlite3_errmsg(db))) }
            result.append((0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) }
            })
        }
    }

    private func diskEpisode(_ url: URL, _ id: Int64) throws -> LibraryEpisode {
        let text = try #require(sql(url, "SELECT record FROM episodes WHERE id = \(id)").first?.first ?? nil)
        return try JSONDecoder().decode(LibraryEpisode.self, from: Data(text.utf8))
    }

    private func sideEffects(_ url: URL) throws -> [[[String?]]] {
        try ["SELECT position,episode_id FROM queue ORDER BY position",
             "SELECT id,hex(record) FROM pending_effects ORDER BY id",
             "SELECT id,phase,hex(record) FROM synchronization_outbox ORDER BY id",
             "SELECT id,hex(record) FROM download_jobs ORDER BY id"].map { try sql(url, $0) }
    }

    @Test(arguments: [false, true]) func acceptedPriorStateAndUndoPreservePositionHistoryAndOutbox(connected: Bool) async throws {
        try await fixture { store, url, id in
            if connected { try await store.selectSynchronizationAccount(UUID()) }
            let before = try diskEpisode(url, id), effects = try sideEffects(url)
            let receipt = try #require(try await store.applySwipeMark(episodeID: id, action: .removeInbox))
            #expect(receipt.previousState == .new)
            #expect(receipt.appliedState == .unplayed)
            var expected = before; expected.userState.playState = .unplayed
            #expect(try diskEpisode(url, id) == expected)
            #expect(try sideEffects(url) == effects)
            #expect(try await store.undoSwipeMark(receipt) == .restored)
            #expect(try diskEpisode(url, id) == before)
            #expect(try sideEffects(url) == effects)
            #expect(try sql(url, "SELECT count(*) FROM episode_swipe_undo") == [["0"]])
            #expect(try await store.undoSwipeMark(receipt) == .superseded)
        }
    }

    @Test(arguments: EpisodePlayState.allCases) func toggleRestoresEachAcceptedState(previous: EpisodePlayState) async throws {
        try await fixture { store, url, id in
            try await store.updateEpisode(id: id) { $0.userState.playState = previous }
            let before = try diskEpisode(url, id), effects = try sideEffects(url)
            let receipt = try #require(try await store.applySwipeMark(episodeID: id, action: .togglePlayed))
            #expect(receipt.previousState == previous)
            #expect(receipt.appliedState == (previous == .unplayed ? .played : .unplayed))
            #expect(try diskEpisode(url, id).userState.positionMilliseconds == 12_000)
            #expect(try await store.undoSwipeMark(receipt) == .restored)
            #expect(try diskEpisode(url, id) == before)
            #expect(try sideEffects(url) == effects)
        }
    }

    @Test func transactionReadsAcceptedStateNotTheOlderVisibleSnapshot() async throws {
        try await fixture { store, url, id in
            let visible = try diskEpisode(url, id)
            #expect(visible.userState.playState == .new)
            try await store.markEpisodePlayed(episodeID: id, played: true, resetPosition: false)
            #expect(try await store.applySwipeMark(episodeID: id, action: .removeInbox) == nil)
            #expect(try sql(url, "SELECT count(*) FROM episode_swipe_undo") == [["0"]])
            let toggle = try #require(try await store.applySwipeMark(episodeID: id, action: .togglePlayed))
            #expect(toggle.previousState == .played)
            #expect(try await store.undoSwipeMark(toggle) == .restored)
            #expect(try diskEpisode(url, id).userState.playState == .played)
        }
    }

    @Test func mediaLessNewItemIsEligibleAndUnrelatedUpdatesSurviveUndo() async throws {
        try await fixture { store, url, id in
            try await store.updateEpisode(id: id) { $0.details.media = nil }
            let receipt = try #require(try await store.applySwipeMark(episodeID: id, action: .removeInbox))
            try await store.setFavorite(episodeID: id, favorite: true)
            try await store.updateEpisode(id: id) {
                $0.details.title = "New metadata"; $0.userState.positionMilliseconds = 24_000
                $0.userState.playedDurationMilliseconds = 50; $0.userState.lastPlayedHistoryMilliseconds = 999
            }
            var latest = try diskEpisode(url, id); latest.userState.playState = .new
            #expect(try await store.undoSwipeMark(receipt) == .restored)
            #expect(try diskEpisode(url, id) == latest)
        }
    }

    @Test(arguments: ["context", "mark", "reset", "aba", "remote"]) func laterExplicitIntentRejectsOldUndo(kind: String) async throws {
        try await fixture { store, url, id in
            let receipt = try #require(try await store.applySwipeMark(episodeID: id, action: .removeInbox))
            switch kind {
            case "context": try await store.removeEpisodeFromInbox(episodeID: id)
            case "mark": try await store.markEpisodePlayed(episodeID: id, played: false)
            case "reset": try await store.resetPlaybackPosition(episodeID: id)
            case "aba":
                try await store.markEpisodePlayed(episodeID: id, played: true, resetPosition: false)
                try await store.markEpisodePlayed(episodeID: id, played: false)
            default:
                try await store.selectSynchronizationAccount(UUID())
                let epoch = try await store.synchronizationState().epoch
                let action = SynchronizationEpisodeAction(podcast: "https://example.test/feed", episode: "https://example.test/one.mp3",
                    guid: "one", action: .play, timestamp: now, started: 0, position: 12, total: 120)
                #expect(try await store.applySynchronizationEpisodes([action], epoch: epoch) == [id])
            }
            let latest = try diskEpisode(url, id)
            #expect(try await store.undoSwipeMark(receipt) == .superseded)
            #expect(try diskEpisode(url, id) == latest)
        }
    }

    @Test func releaseAndRepeatedActionsConsumeOnlyTheirOwnReceipt() async throws {
        try await fixture { store, url, id in
            let first = try #require(try await store.applySwipeMark(episodeID: id, action: .removeInbox))
            let second = try #require(try await store.applySwipeMark(episodeID: id, action: .togglePlayed))
            try await store.releaseSwipeUndo(first)
            #expect(try await store.undoSwipeMark(first) == .superseded)
            #expect(try await store.undoSwipeMark(second) == .restored)
            #expect(try diskEpisode(url, id).userState.playState == .unplayed)
            let third = try #require(try await store.applySwipeMark(episodeID: id, action: .togglePlayed))
            try await store.releaseSwipeUndo(third)
            #expect(try await store.undoSwipeMark(third) == .superseded)
            #expect(try diskEpisode(url, id).userState.playState == .played)
        }
    }

    @Test(arguments: ["episode", "guard", "commit"]) func failedInitialWriteReturnsNoReceiptAndRollsBack(kind: String) async throws {
        try await fixture { store, url, id in
            _ = try await store.enqueue([id])
            try await store.updateEpisode(id: id) { $0.userState.playState = .new }
            _ = try await store.beginPlayback(episodeID: id, positionMilliseconds: 0)
            let before = try diskEpisode(url, id), session = try sql(url, "SELECT hex(record) FROM playback_session")
            if kind == "commit" {
                _ = try sql(url, "CREATE TABLE deferred_rejection (feed_id INTEGER REFERENCES feeds(id) DEFERRABLE INITIALLY DEFERRED)")
                _ = try sql(url, "CREATE TRIGGER fail_mark AFTER INSERT ON episode_swipe_undo BEGIN INSERT INTO deferred_rejection VALUES (-123); END")
            } else {
                let target = kind == "episode" ? "UPDATE ON episodes" : "INSERT ON episode_swipe_undo"
                _ = try sql(url, "CREATE TRIGGER fail_mark BEFORE \(target) BEGIN SELECT RAISE(ABORT, 'initial failure'); END")
            }
            await #expect(throws: (any Error).self) { try await store.applySwipeMark(episodeID: id, action: .removeInbox) }
            #expect(try diskEpisode(url, id) == before)
            #expect(try sql(url, "SELECT hex(record) FROM playback_session") == session)
            #expect(try sql(url, "SELECT count(*) FROM episode_swipe_undo") == [["0"]])
            if kind == "commit" { #expect(try sql(url, "SELECT count(*) FROM deferred_rejection") == [["0"]]) }
        }
    }

    @Test(arguments: ["episode", "guard", "session", "commit"]) func failedUndoRetainsCommittedStateAndGuard(kind: String) async throws {
        try await fixture { store, url, id in
            _ = try await store.enqueue([id])
            try await store.updateEpisode(id: id) { $0.userState.playState = .new }
            _ = try await store.beginPlayback(episodeID: id, positionMilliseconds: 0)
            let receipt = try #require(try await store.applySwipeMark(episodeID: id, action: .removeInbox))
            let before = try diskEpisode(url, id), guardRows = try sql(url, "SELECT * FROM episode_swipe_undo")
            let session = try sql(url, "SELECT hex(record) FROM playback_session")
            if kind == "commit" {
                _ = try sql(url, "CREATE TABLE deferred_rejection (feed_id INTEGER REFERENCES feeds(id) DEFERRABLE INITIALLY DEFERRED)")
                _ = try sql(url, "CREATE TRIGGER fail_undo AFTER DELETE ON episode_swipe_undo BEGIN INSERT INTO deferred_rejection VALUES (-123); END")
            } else {
                let target = kind == "episode" ? "UPDATE ON episodes" : kind == "guard" ? "DELETE ON episode_swipe_undo" : "UPDATE ON playback_session"
                _ = try sql(url, "CREATE TRIGGER fail_undo BEFORE \(target) BEGIN SELECT RAISE(ABORT, 'undo failure'); END")
            }
            await #expect(throws: (any Error).self) { try await store.undoSwipeMark(receipt) }
            #expect(try diskEpisode(url, id) == before)
            #expect(try sql(url, "SELECT * FROM episode_swipe_undo") == guardRows)
            #expect(try sql(url, "SELECT hex(record) FROM playback_session") == session)
            _ = try sql(url, "DROP TRIGGER fail_undo")
            // Store-level proof of rollback only; a UI must not auto-retry Undo.
            #expect(try await store.undoSwipeMark(receipt) == .restored)
        }
    }

    @Test func failedLaterIntentDoesNotInvalidateAnEarlierCommittedUndo() async throws {
        try await fixture { store, url, id in
            try await store.selectSynchronizationAccount(UUID())
            let receipt = try #require(try await store.applySwipeMark(episodeID: id, action: .removeInbox))
            let effects = try sideEffects(url)
            _ = try sql(url, "CREATE TRIGGER reject_later BEFORE UPDATE ON episodes BEGIN SELECT RAISE(ABORT, 'later failure'); END")
            // A later intent that changes the episode (an unchanged record is not rewritten, so would not reach the trigger).
            await #expect(throws: (any Error).self) { try await store.markEpisodePlayed(episodeID: id, played: true) }
            #expect(try sideEffects(url) == effects)
            _ = try sql(url, "DROP TRIGGER reject_later")
            #expect(try await store.undoSwipeMark(receipt) == .restored)
            #expect(try diskEpisode(url, id).userState.playState == .new)
        }
    }

    @Test(arguments: ["url", "media", "nilURL", "unicode"]) func logicalMediaReplacementInvalidatesEvenAfterABA(kind: String) async throws {
        try await fixture { store, url, id in
            if kind == "nilURL" { try await store.updateEpisode(id: id) { $0.details.media?.url = nil } }
            if kind == "unicode" { try await store.updateEpisode(id: id) { $0.details.media?.url = "https://example.test/é.mp3" } }
            let old = try diskEpisode(url, id)
            let receipt = try #require(try await store.applySwipeMark(episodeID: id, action: .removeInbox))
            try await store.updateEpisode(id: id) {
                if kind == "media" { $0.details.media = nil }
                else { $0.details.media?.url = kind == "unicode" ? "https://example.test/e\u{301}.mp3" : "https://example.test/replacement.mp3" }
            }
            try await store.updateEpisode(id: id) { $0.details.media = old.details.media }
            #expect(try await store.undoSwipeMark(receipt) == .superseded)
            #expect(try diskEpisode(url, id).userState.playState == .unplayed)
        }
    }

    @Test func progressDurationFavoriteAndOwnDownloadClearingAreNotLogicalReplacement() async throws {
        try await fixture { store, url, id in
            try await store.updateEpisode(id: id) { $0.userState.localFileURL = "/owned/old.media"; $0.userState.isDownloaded = true }
            let receipt = try #require(try await store.applySwipeMark(episodeID: id, action: .removeInbox))
            try await store.updateEpisode(id: id) {
                $0.userState.positionMilliseconds = 99_000; $0.details.media?.durationMilliseconds = 130_000
                $0.details.media?.size = 987; $0.userState.isFavorite = true
                $0.userState.localFileURL = nil; $0.userState.isDownloaded = false
            }
            var latest = try diskEpisode(url, id); latest.userState.playState = .new
            #expect(try await store.undoSwipeMark(receipt) == .restored)
            #expect(try diskEpisode(url, id) == latest)
        }
    }

    @Test func deletionRecreationAndOtherStoreEpochCannotReuseReceipt() async throws {
        try await fixture { store, url, id in
            let receipt = try #require(try await store.applySwipeMark(episodeID: id, action: .removeInbox))
            let other = try FeedLibraryStore(url: url)
            #expect(try await other.undoSwipeMark(receipt) == .unavailable)
            try await other.releaseSwipeUndo(receipt)
            try await other.close()
            let row = try #require(sql(url, "SELECT feed_id,pubdate,hex(record) FROM episodes WHERE id = \(id)").first)
            _ = try sql(url, "DELETE FROM episodes WHERE id = \(id)")
            #expect(try sql(url, "SELECT count(*) FROM episode_swipe_undo") == [["0"]])
            #expect(try await store.undoSwipeMark(receipt) == .unavailable)
            _ = try sql(url, "INSERT INTO episodes VALUES (\(id),\(row[0]!),\(row[1]!),X'\(row[2]!)')")
            #expect(try await store.undoSwipeMark(receipt) == .superseded)
            let next = try #require(try await store.applySwipeMark(episodeID: id, action: .togglePlayed))
            try await store.close()
            await #expect(throws: FeedLibraryError.closed) { try await store.undoSwipeMark(next) }
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.undoSwipeMark(next) == .unavailable)
            #expect(try diskEpisode(url, id).userState.playState == .played)
            try await reopened.close()
        }
    }

    @Test func matchingSessionReceivesOnlyStateAndContinuesWithLatestProgress() async throws {
        try await fixture { store, url, id in
            _ = try await store.enqueue([id])
            try await store.updateEpisode(id: id) { $0.userState.playState = .new }
            let initial = try await store.beginPlayback(episodeID: id, positionMilliseconds: 0)
            let receipt = try #require(try await store.applySwipeMark(episodeID: id, action: .removeInbox))
            #expect(try await store.playbackSession()?.itemPlayState == .unplayed)
            _ = try await store.recordPlayback(sessionID: initial.id,
                sample: .init(positionMilliseconds: 25_000, durationMilliseconds: 120_000, status: .playing), now: now)
            var latest = try #require(try await store.playbackSession()); latest.itemPlayState = .new
            #expect(try await store.undoSwipeMark(receipt) == .restored)
            #expect(try await store.playbackSession() == latest)
            #expect(try diskEpisode(url, id).userState.positionMilliseconds == 25_000)
            _ = try await store.recordPlayback(sessionID: initial.id,
                sample: .init(positionMilliseconds: 26_000, durationMilliseconds: 120_000, status: .playing), now: now)
            #expect(try diskEpisode(url, id).userState.positionMilliseconds == 26_000)
            #expect(try diskEpisode(url, id).userState.playState == .new)
        }
    }

    @Test func differentSelectedSessionIsUntouchedByMarkAndUndo() async throws {
        try await fixture { store, url, id in
            let other = try #require(try await store.feeds().first?.episodes.first { $0.id != id }?.id)
            _ = try await store.beginPlayback(episodeID: other)
            let session = try sql(url, "SELECT hex(record) FROM playback_session"), selection = try sql(url, "SELECT * FROM playback_selection")
            let receipt = try #require(try await store.applySwipeMark(episodeID: id, action: .removeInbox))
            #expect(try await store.undoSwipeMark(receipt) == .restored)
            #expect(try sql(url, "SELECT hex(record) FROM playback_session") == session)
            #expect(try sql(url, "SELECT * FROM playback_selection") == selection)
        }
    }

    @Test(arguments: ["renewal", "scan", "reconnect", "registration", "name", "size"]) func localDocumentAndRegistrationRules(kind: String) async throws {
        try await fixture { store, url, _ in
            let context = try await store.registerLocalFolder(title: "Local", directoryIdentity: "folder", bookmark: Data([1]))
            let parsed = ParsedFeed(format: .rss, episodes: [.init(identifier: "local", title: "Local", link: "one.mp3",
                publicationDate: now, media: .init(url: "file:///folder/one.mp3", size: 42))])
            let scanned = try await store.applyLocalFolderScan(parsed, context: context)
            let id = try #require(scanned.feed.episodes.first?.id)
            try await store.updateEpisode(id: id) { $0.userState.playState = .new }
            let episode = try diskEpisode(url, id)
            let access = try #require(try await store.localPlaybackContext(for: episode))
            let receipt = try #require(try await store.applySwipeMark(episodeID: id, action: .removeInbox))
            switch kind {
            case "renewal": #expect(try await store.confirmLocalPlaybackAccess(access, refreshedBookmark: Data([2])))
            case "scan":
                let next = try await store.beginLocalFolderScan(feedID: context.feed.id)
                _ = try await store.applyLocalFolderScan(parsed, context: next, refreshedBookmark: Data([2]))
            case "reconnect": _ = try await store.reconnectLocalFolder(feedID: context.feed.id, directoryIdentity: "folder", bookmark: Data([2]))
            case "registration": _ = try await store.registerLocalFolder(title: "Local again", directoryIdentity: "folder", bookmark: Data([2]))
            default: try await store.updateEpisode(id: id) {
                if kind == "name" { $0.details.link = "replacement.mp3" } else { $0.details.media?.size = 43 }
            }
            }
            #expect(try await store.undoSwipeMark(receipt) == (["renewal", "scan"].contains(kind) ? .restored : .superseded))
        }
    }

    @Test func schemaTwelveUpgradePreservesEveryExistingTableAndDoesNotReplayGuards() async throws {
        try await fixture { store, url, id in
            try await store.selectSynchronizationAccount(UUID())
            _ = try await store.enqueue([id])
            try await store.close()
            _ = try sql(url, "DROP TABLE episode_swipe_undo")
            _ = try sql(url, "DROP TABLE imported_download_log"); _ = try sql(url, "DROP TABLE restore_journal")
            _ = try sql(url, "PRAGMA user_version = 12")
            let tables = try sql(url, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").compactMap { $0[0] }
            let before = try tables.map { try sql(url, "SELECT * FROM \($0)") }
            let upgraded = try FeedLibraryStore(url: url)
            #expect(try sql(url, "PRAGMA user_version") == [["22"]])
            #expect(try tables.map { try sql(url, "SELECT * FROM \($0)") } == before)
            #expect(try sql(url, "SELECT count(*) FROM episode_swipe_undo") == [["0"]])
            try await upgraded.close()
        }
    }

    @Test func failedMigrationPreservesVersionAndLibrary() async throws {
        try await fixture { store, url, id in
            try await store.close()
            _ = try sql(url, "DROP TABLE episode_swipe_undo")
            _ = try sql(url, "DROP TABLE imported_download_log"); _ = try sql(url, "DROP TABLE restore_journal")
            _ = try sql(url, "PRAGMA user_version = 12")
            _ = try sql(url, "CREATE VIEW episode_swipe_undo AS SELECT 1")
            let before = try diskEpisode(url, id)
            #expect(throws: (any Error).self) { try FeedLibraryStore(url: url) }
            #expect(try sql(url, "PRAGMA user_version") == [["12"]])
            #expect(try diskEpisode(url, id) == before)
            _ = try sql(url, "DROP VIEW episode_swipe_undo")
            let recovered = try FeedLibraryStore(url: url)
            #expect(try sql(url, "PRAGMA user_version") == [["22"]])
            try await recovered.close()
        }
    }
}
