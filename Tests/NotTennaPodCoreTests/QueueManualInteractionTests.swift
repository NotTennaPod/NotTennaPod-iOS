import Foundation
import Testing
@testable import NotTennaPodCore

struct QueueManualInteractionTests {
    private enum StoredCell: Equatable {
        case integer(Int64), real(UInt64), text([UInt16]), blob(Data), null
        init(_ value: LibrarySQLValue) {
            switch value {
            case .integer(let value): self = .integer(value)
            case .real(let value): self = .real(value.bitPattern)
            case .text(let value): self = .text(Array(value.utf16))
            case .blob(let value): self = .blob(value)
            case .null: self = .null
            }
        }
    }
    private func storedRows(_ database: LibrarySQLite, table: String) throws -> [[StoredCell]] {
        try database.rows("SELECT * FROM \(table)").map { $0.map(StoredCell.init) }
    }

    private func fixture() -> FetchedFeed {
        let source = "https://queue.test/feed"
        return .init(feed: .init(format: .rss, title: "Queue", episodes: (1...4).map {
            .init(identifier: "item-\($0)", title: "Episode \($0)", media: .init(url: "https://queue.test/\($0).mp3", size: 123456, durationMilliseconds: 120_000))
        }), source: source, responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil)
    }
    private func withStore(_ body: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QueueManual-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite"), store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        do {
            _ = try await store.insert(fixture()); _ = try await store.enqueue([1,2,3,4])
            let sql = try LibrarySQLite(url: url); try sql.execute("DELETE FROM queue_work"); try sql.close()
            try await body(store, url); try await store.close()
        } catch { try? await store.close(); throw error }
    }
    @Test(arguments: [(Int64(1),3,[Int64(2),3,4,1]), (Int64(4),0,[Int64(4),1,2,3]), (Int64(2),2,[Int64(1),3,2,4])])
    func firstLastAndMiddleUseFinalIndex(_ input: (Int64, Int, [Int64])) async throws {
        try await withStore { store, url in
            _ = try await store.beginPlayback(episodeID: 2)
            try await store.updateEpisode(id: 2) { $0.userState.positionMilliseconds = 7311; $0.userState.isFavorite = true }
            let before = try await store.snapshot(), pending = try await store.pendingEffects()
            let selectionDB = try LibrarySQLite(url: url)
            let selection = try storedRows(selectionDB, table: "playback_selection"), playback = try storedRows(selectionDB, table: "playback_session")
            let result = try await store.performQueueMove(.item(input.0, finalIndex: input.1), expected: before.queue.map(QueueEpisodeIdentity.init))
            #expect(result.status == .moved); #expect(result.change.episodeIDs == input.2)
            #expect(result.change.events == [.moved(episodeID: input.0, index: input.1)])
            #expect(!result.change.requestsAutoDownload); #expect(try await store.queueAutoDownloadRequested() == false)
            #expect(try await store.snapshot().feeds == before.feeds); #expect(try await store.pendingEffects() == pending)
            #expect(try storedRows(selectionDB, table: "playback_selection") == selection)
            #expect(try storedRows(selectionDB, table: "playback_session") == playback); try selectionDB.close()
            let sql = try LibrarySQLite(url: url)
            #expect(try sql.rows("SELECT episode_id FROM queue ORDER BY position").compactMap { $0[0].integer } == input.2)
            try sql.close()
            let second = try FeedLibraryStore(url: url); #expect(try await second.queue().map(\.id) == input.2); try await second.close()
        }
    }
    @Test func acceptedIndexUndoPreservesManualMoveAndInvalidatesOlderCapture() async throws {
        try await withStore { store, url in
            _ = try await store.beginPlayback(episodeID: 2, positionMilliseconds: 7311)
            let db = try LibrarySQLite(url: url)
            let selection = try storedRows(db, table: "playback_selection")
            let playback = try storedRows(db, table: "playback_session")
            let before = try await store.snapshot().feeds
            let removal = try await store.removeFromQueueWithUndo(2)
            let receipt = try #require(removal.receipt)
            #expect(receipt.index == 1 && removal.change.episodeIDs == [1,3,4])
            let captured = try await store.queue().map(QueueEpisodeIdentity.init)
            let move = try await store.performQueueMove(.boundary([4], .top), expected: captured)
            #expect(move.status == .moved && move.change.episodeIDs == [4,1,3])
            #expect(!move.change.requestsAutoDownload)
            let beforeUndo = try await store.queue().map(QueueEpisodeIdentity.init)
            let undo = try await store.undoQueueRemoval(receipt)
            #expect(undo.status == .restored && undo.change?.episodeIDs == [4,2,1,3])
            #expect(undo.change?.events == [.added(episodeID: 2, index: 1)])
            let stale = try await store.performQueueMove(.boundary([3], .top), expected: beforeUndo)
            #expect(stale.status == .stale && stale.change.episodeIDs == [4,2,1,3])
            #expect(stale.change.events.isEmpty && !stale.change.requestsAutoDownload)
            #expect(try await store.snapshot().feeds == before)
            #expect(try storedRows(db, table: "playback_selection") == selection)
            #expect(try storedRows(db, table: "playback_session") == playback)
            #expect(try db.rows("SELECT episode_id FROM queue ORDER BY position").compactMap { $0[0].integer } == [4,2,1,3])
            try db.close()
        }
    }
    @Test func invalidSameAndReturnToStartNeverWrite() async throws {
        try await withStore { store, url in
            let episodes = try await store.queue(), captured = episodes.map(QueueEpisodeIdentity.init)
            let sql = try LibrarySQLite(url: url)
            try sql.execute("CREATE TRIGGER fail_move BEFORE DELETE ON queue BEGIN SELECT RAISE(ABORT,'no writes expected'); END")
            for move in [QueueManualMove.item(1, finalIndex: 0), .item(1, finalIndex: -1), .item(1, finalIndex: 4), .item(99, finalIndex: 0), .boundary([], .top), .boundary([2,99], .top)] {
                #expect(try await store.performQueueMove(move, expected: captured).status == .unchanged)
            }
            var drag = try #require(QueueDragSession(episodes: episodes, episodeID: 1, policy: .init()))
            drag.cross(3); #expect(drag.order == [2,3,1,4]); drag.cross(2)
            #expect(drag.order == [1,2,3,4]); #expect(drag.move == nil)
            try sql.close()
        }
    }
    @Test func onePointerSampleCanCrossMultipleRowsInEitherDirection() async throws {
        try await withStore { store, _ in
            let episodes = try await store.queue()
            var down = try #require(QueueDragSession(episodes: episodes, episodeID: 1, policy: .init()))
            down.cross(centerY: 360, rowCenters: [1:50,2:150,3:250,4:350])
            #expect(down.order == [2,3,4,1]); #expect(down.move == .item(1,finalIndex:3))
            down.cross(centerY: 40, rowCenters: [2:50,3:150,4:250,1:350])
            #expect(down.order == [1,2,3,4]); #expect(down.move == nil)
            var up = try #require(QueueDragSession(episodes: episodes, episodeID: 4, policy: .init()))
            up.cross(centerY: 40, rowCenters: [1:50,2:150,3:250,4:350]); #expect(up.order == [4,1,2,3])
        }
    }
    @Test func staleOrderAndRemovedIdentityCannotMoveAnotherEpisode() async throws {
        try await withStore { store, url in
            let captured = try await store.queue().map(QueueEpisodeIdentity.init)
            let second = try FeedLibraryStore(url: url)
            _ = try await second.removeFromQueue([1], performAutoDownload: false)
            let result = try await store.performQueueMove(.item(1, finalIndex: 2), expected: captured)
            #expect(result.status == .stale); #expect(try await store.queue().map(\.id) == [2,3,4])
            try await second.close()
        }
    }
    @Test func identityReplacementRejectedButProgressRenewalAllowed() async throws {
        try await withStore { store, _ in
            let captured = try await store.queue().map(QueueEpisodeIdentity.init)
            try await store.updateEpisode(id: 2) { $0.details.media?.url = "https://queue.test/replacement.mp3" }
            #expect(try await store.performQueueMove(.item(2, finalIndex: 0), expected: captured).status == .stale)
            let renewed = try await store.queue().map(QueueEpisodeIdentity.init)
            try await store.updateEpisode(id: 2) { $0.userState.positionMilliseconds = 1234; $0.userState.isFavorite = true }
            #expect(try await store.performQueueMove(.item(2, finalIndex: 0), expected: renewed).status == .moved)
            #expect(try await store.episode(id: 2)?.userState.positionMilliseconds == 1234)
        }
    }
    @Test func batchOrderUsesDisplayedOrderAndRollbackIsAtomic() async throws {
        try await withStore { store, url in
            let captured = try await store.queue().map(QueueEpisodeIdentity.init)
            let sql = try LibrarySQLite(url: url)
            try sql.execute("CREATE TRIGGER fail_move BEFORE INSERT ON queue WHEN NEW.position=2 BEGIN SELECT RAISE(ABORT,'move failure'); END")
            await #expect(throws: (any Error).self) { try await store.performQueueMove(.boundary([4,2], .top), expected: captured) }
            #expect(try await store.queue().map(\.id) == [1,2,3,4]); #expect(try await store.queueAutoDownloadRequested() == false)
            try sql.execute("DROP TRIGGER fail_move")
            #expect(try await store.performQueueMove(.boundary([4,2], .top), expected: captured).change.episodeIDs == [2,4,1,3])
            let latest = try await store.queue().map(QueueEpisodeIdentity.init)
            #expect(try await store.performQueueMove(.boundary([4,2], .bottom), expected: latest).change.episodeIDs == [1,3,2,4])
            try sql.close()
        }
    }
    @Test func cancelledTaskDoesNotCommit() async throws {
        try await withStore { store, _ in
            let captured = try await store.queue().map(QueueEpisodeIdentity.init)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await store.performQueueMove(.item(1, finalIndex: 3), expected: captured)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.queue().map(\.id) == [1,2,3,4])
        }
    }
    @Test func exactBulkBoundariesAndLockScope() {
        let order: [Int64] = [1,2,3,4], selecting = QueueInteractionPolicy(selecting: true)
        #expect(!selecting.canMove([1,2], in: order, to: .top, bulk: true))
        #expect(!selecting.canMove([3,4], in: order, to: .bottom, bulk: true))
        #expect(selecting.canMove([2,4], in: order, to: .top, bulk: true))
        #expect(selecting.canMove([2,4], in: order, to: .bottom, bulk: true))
        #expect(!selecting.canMove(order, in: order, to: .top, bulk: true))
        #expect(!QueueInteractionPolicy(locked: true, selecting: true).canMove([2,4], in: order, to: .top, bulk: true))
        #expect(QueueInteractionPolicy(locked: true).canMove([2], in: order, to: .top, bulk: false))
        #expect(!QueueInteractionPolicy(keepSorted: true).canMove([2], in: order, to: .top, bulk: false))
        #expect(!selecting.allowsDrag && selecting.showsHandle && !selecting.showsInformation)
    }
    @Test(arguments: [false,true]) func hitAreaLeadingHalfExcludesMidpointAndLockedHandleShifts(_ rtl: Bool) {
        let shown = EpisodeRowLayout(width: 400, titleHeight: 22, metadataHeight: 14, progressHeight: 14, draggable: true, rightToLeft: rtl)
        let hidden = EpisodeRowLayout(width: 400, titleHeight: 22, metadataHeight: 14, progressHeight: 14, draggable: false, rightToLeft: rtl)
        #expect(abs(abs(shown.cover.minX-hidden.cover.minX) - 12) <= 0.5)
        let policy = QueueInteractionPolicy(), y = shown.cover.midY
        #expect(policy.startsDrag(at: .init(x: shown.cover.midX + (rtl ? 1 : -1), y: y), handle: shown.dragHandle, cover: shown.cover, rightToLeft: rtl))
        #expect(!policy.startsDrag(at: .init(x: shown.cover.midX, y: y), handle: shown.dragHandle, cover: shown.cover, rightToLeft: rtl))
        #expect(!policy.startsDrag(at: .init(x: shown.cover.midX + (rtl ? -1 : 1), y: y), handle: shown.dragHandle, cover: shown.cover, rightToLeft: rtl))
        #expect(!QueueInteractionPolicy(locked: true).startsDrag(at: .init(x: shown.dragHandle.midX, y: y), handle: shown.dragHandle, cover: shown.cover, rightToLeft: rtl))
    }
}

@MainActor struct QueueInteractionPreferenceTests {
    @Test func defaultsConfirmSuppressionUnlockAndReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QueuePrefs-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("queue.json"), store = try QueueInteractionPreferenceStore(file: directory.appendingPathComponent("queue.json"))
        #expect(store.value == .init())
        try store.confirmLock(doNotShowAgain: false); #expect(store.value == .init(locked: true, showLockWarning: true))
        try store.toggleWithoutWarning(); try store.confirmLock(doNotShowAgain: true)
        try store.toggleWithoutWarning(); #expect(store.value == .init(locked: false, showLockWarning: false))
        #expect(try QueueInteractionPreferenceStore(file: file).value == store.value)
        try store.toggleWithoutWarning(); #expect(store.value == .init(locked: true, showLockWarning: false))
    }
    @Test func malformedReadAndFailedWritePreserveMemoryAndDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("QueuePrefsFailure-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("queue.json")
        try Data("{}".utf8).write(to: file)
        let store = try QueueInteractionPreferenceStore(file: file); #expect(store.value == .init())
        try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try store.confirmLock(doNotShowAgain: true) }
        #expect(store.value == .init()); #expect(try FileManager.default.contentsOfDirectory(atPath: file.path).isEmpty)
        try FileManager.default.removeItem(at: file); try Data("malformed".utf8).write(to: file)
        #expect(throws: (any Error).self) { try QueueInteractionPreferenceStore(file: file) }
    }
}
