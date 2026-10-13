import Foundation
import Testing
@testable import NotTennaPodCore

struct EpisodeQueueUndoTests {
    private func fixture(_ body: (FeedLibraryStore, LibrarySQLite, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("QueueUndo-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite"), store = try FeedLibraryStore(url: url)
        let db = try LibrarySQLite(url: url)
        do {
            _ = try await store.insert(.init(feed: .init(format: .rss, title: "Queue", episodes: (1...5).map {
                .init(identifier: "\($0)", title: "Episode \($0)", media: .init(url: "https://example.test/\($0).mp3", size: 42))
            }), source: "https://example.test/feed", responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil))
            _ = try await store.enqueue([1, 2, 3, 4])
            try db.execute("DELETE FROM queue_work")
            try await body(store, db, url)
            try db.close(); try await store.close()
        } catch { try? db.close(); try? await store.close(); throw error }
    }
    private func queue(_ db: LibrarySQLite) throws -> [Int64] {
        try db.rows("SELECT episode_id FROM queue ORDER BY position").map { try #require($0[0].integer) }
    }
    @Test func acceptedIndexRestoresIntoCurrentOrderWithoutRollingBackEdits() async throws {
        try await fixture { store, db, _ in
            let removal = try await store.removeFromQueueWithUndo(2), receipt = try #require(removal.receipt)
            #expect(receipt.index == 1); #expect(removal.change.episodeIDs == [1,3,4])
            #expect(removal.change.events == [.removed(episodeID: 2)] && removal.change.requestsAutoDownload)
            _ = try await store.moveQueueItem(from: 2, to: 0)
            _ = try await store.enqueue([5])
            try await store.updateEpisode(id: 2) { $0.userState.isFavorite = true; $0.userState.positionMilliseconds = 7_777; $0.userState.playState = .new }
            let undo = try await store.undoQueueRemoval(receipt)
            #expect(undo.status == .restored && undo.change?.events == [.added(episodeID: 2, index: 1)])
            #expect(try queue(db) == [4,2,1,3,5])
            let episode = try #require(try await store.episode(id: 2))
            #expect(episode.userState.playState == .unplayed && episode.userState.isFavorite && episode.userState.positionMilliseconds == 7_777)
            #expect(try await store.undoQueueRemoval(receipt).status == .unavailable)
            #expect(try db.scalar("SELECT count(*) FROM queue_work") == 1)
        }
    }
    @Test func missingRemovalAndDuplicateUndoStillRequestAutoDownloadWithoutMoving() async throws {
        try await fixture { store, db, _ in
            let absent = try await store.removeFromQueueWithUndo(5)
            #expect(absent.receipt == nil && absent.change.events.isEmpty && absent.change.requestsAutoDownload)
            let receipt = try #require(try await store.removeFromQueueWithUndo(2).receipt)
            _ = try await store.enqueue([2])
            try db.execute("DELETE FROM queue_work")
            let undo = try await store.undoQueueRemoval(receipt)
            #expect(undo.status == .alreadyQueued && undo.change?.events.isEmpty == true && undo.change?.requestsAutoDownload == true)
            #expect(try queue(db) == [1,3,4,2]); #expect(try db.scalar("SELECT count(*) FROM queue_work") == 1)
        }
    }
    @Test func missingEpisodeRequestsWorkButReplacementIdentityDoesNot() async throws {
        try await fixture { store, db, _ in
            let missing = try #require(try await store.removeFromQueueWithUndo(2).receipt)
            try db.execute("DELETE FROM episodes WHERE id = 2")
            try db.execute("DELETE FROM queue_work")
            #expect(try await store.undoQueueRemoval(missing).status == .missing)
            #expect(try db.scalar("SELECT count(*) FROM queue_work") == 1)
            let changed = try #require(try await store.removeFromQueueWithUndo(3).receipt)
            try await store.updateEpisode(id: 3) { $0.details.media?.url = "https://example.test/replacement.mp3" }
            try db.execute("DELETE FROM queue_work")
            #expect(try await store.undoQueueRemoval(changed).status == .unavailable)
            #expect(try queue(db) == [1,4]); #expect(try db.scalar("SELECT count(*) FROM queue_work") == 0)
        }
    }
    /// When the queue shrank below the old index before Undo, Android's `addQueueItemAt`
    /// throws on its DB thread and the Undo is silently lost. Not copied: the episode returns at the end.
    /// (Replaces the earlier expectation that such an Undo fails, which reproduced the lost Undo.)
    @Test func undoBeyondTheShrunkQueueRestoresAtTheEnd() async throws {
        try await fixture { store, db, _ in
            let receipt = try #require(try await store.removeFromQueueWithUndo(4).receipt)
            #expect(receipt.index == 3)
            _ = try await store.removeFromQueue([2,3]); try db.execute("DELETE FROM queue_work")
            let undo = try await store.undoQueueRemoval(receipt)
            #expect(undo.status == .restored && undo.change?.events == [.added(episodeID: 4, index: 1)])
            #expect(try queue(db) == [1,4]); #expect(try db.scalar("SELECT count(*) FROM queue_work") == 1)
            #expect(try await store.undoQueueRemoval(receipt).status == .unavailable)
        }
    }
    @Test(arguments: [false, true]) func writeFailureRollsBackRemovalOrUndo(undo: Bool) async throws {
        try await fixture { store, db, _ in
            let receipt = undo ? try #require(try await store.removeFromQueueWithUndo(2).receipt) : nil
            let before = try queue(db)
            try db.execute("DELETE FROM queue_work")
            try db.execute("CREATE TRIGGER fail_work BEFORE INSERT ON queue_work BEGIN SELECT RAISE(ABORT, 'failure'); END")
            do {
                if let receipt { _ = try await store.undoQueueRemoval(receipt) }
                else { _ = try await store.removeFromQueueWithUndo(2) }
                Issue.record("Expected queue/work transaction failure")
            } catch { }
            #expect(try queue(db) == before); #expect(try db.scalar("SELECT count(*) FROM queue_work") == 0)
            try db.execute("DROP TRIGGER fail_work")
            if let receipt { #expect(try await store.undoQueueRemoval(receipt).status == .restored) }
            else { #expect(try await store.removeFromQueueWithUndo(2).receipt?.index == 1) }
        }
    }
    @Test func releasedAndForeignStoreReceiptsCannotMutate() async throws {
        try await fixture { store, db, url in
            let first = try #require(try await store.removeFromQueueWithUndo(2).receipt)
            await store.releaseQueueRemoval(first)
            #expect(try await store.undoQueueRemoval(first).status == .unavailable)
            let second = try #require(try await store.removeFromQueueWithUndo(3).receipt)
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.undoQueueRemoval(second).status == .unavailable)
            try await reopened.close()
            #expect(try queue(db) == [1,4])
            #expect(try await store.undoQueueRemoval(second).status == .restored)
        }
    }
    @Test func independentRemovalsRestoreCapturedSlotsInCurrentOrder() async throws {
        try await fixture { store, db, _ in
            let first = try #require(try await store.removeFromQueueWithUndo(2).receipt)
            let second = try #require(try await store.removeFromQueueWithUndo(3).receipt)
            #expect(first.index == 1 && second.index == 1)
            #expect(try await store.undoQueueRemoval(second).status == .restored)
            #expect(try await store.undoQueueRemoval(first).status == .restored)
            #expect(try queue(db) == [1,2,3,4])
        }
    }
}
