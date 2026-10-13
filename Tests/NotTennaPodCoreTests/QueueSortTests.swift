import Foundation
import SQLite3
import Testing
@testable import NotTennaPodCore

/// Queue sort, Keep sorted, Clear queue and Enqueue location against the independent oracle
/// (a Python port cross-checked by running the unchanged Java files).
/// The library is the oracle's fixture as an Android 3.12.1 database (`TestSupport/Data/queue-sort-clear/queue.db`)
/// through the database import, so episode and feed ids (Smart shuffle's HashMap order depends on them) are
/// the oracle's. Queue order is read back from the SQLite `queue` table directly, not through the store.
@Suite(.serialized) struct QueueSortTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized
    static let fixtures = root.appendingPathComponent("TestSupport/Data/queue-sort-clear")
    nonisolated(unsafe) static let expected: [String: Any] = {
        let data = try! Data(contentsOf: fixtures.appendingPathComponent("expected/queue-sort.json"))
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()
    static let english: [String: String] = ["episode_title": "Episode title", "feed_title": "Podcast title", "duration": "Duration",
                                            "date": "Date", "random": "Random", "smart_shuffle": "Smart shuffle"]

    private func withLibrary(_ body: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M23-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let restored = try AndroidDatabaseRestore.read(Self.fixtures.appendingPathComponent("queue.db"), staging: directory.appendingPathComponent("s"))
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        do {
            try await store.installRestoredLibrary(restored, carrying: try await store.restoreCarryOver())
            try await body(store, url)
        } catch { try? await store.close(); throw error }
        try await store.close()
    }

    /// Independent read of the saved queue order.
    private func queueTable(_ url: URL) throws -> [Int64] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw FeedLibraryError.corruptRecord }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT episode_id FROM queue ORDER BY position", -1, &statement, nil) == SQLITE_OK else { throw FeedLibraryError.corruptRecord }
        defer { sqlite3_finalize(statement) }
        var ids: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW { ids.append(sqlite3_column_int64(statement, 0)) }
        return ids
    }

    /// Puts the queue into an exact order without sorting (the Undo path accepts media-less rows, as imports do).
    private func setQueue(_ ids: [Int64], _ store: FeedLibraryStore) async throws {
        _ = try await store.clearQueue()
        for (index, id) in ids.enumerated() { _ = try await store.enqueueAt(id, index: index) }
    }
    private func ints(_ value: Any?) -> [Int64] { (value as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.int64Value } }
    private func media(_ id: Int64) -> String { "https://example.test/audio/\(id).mp3" }

    @Test func everyQueueSortMatchesTheOracleIncludingTiesLocalesAndSmartShuffle() async throws {
        try await withLibrary { store, url in
            let sorts = Self.expected["sorts"] as! [[String: Any]]
            #expect(sorts.count == 24)
            for scenario in sorts {
                let order = try #require(QueueSortOrder(rawValue: scenario["order"] as! String))
                #expect(order.code == (scenario["code"] as! Int))
                let input = ints(scenario["input"]), locale = Locale(identifier: scenario["locale"] as! String)
                try await setQueue(input, store)
                #expect(try queueTable(url) == input)
                let change = try await store.reorderQueue(order, locale: locale)
                let saved = try queueTable(url)
                #expect(change.events == [.sorted] && change.episodeIDs == saved)
                let label = "\(order.rawValue) \(scenario["queue"]!) \(locale.identifier)"
                if order == .random {
                    #expect(saved.sorted() == ints(scenario["is_permutation_of"]), "\(label)")
                } else {
                    #expect(saved == ints(scenario["result"]), "\(label)")
                }
            }
        }
    }

    @Test func randomUsesTheShuffleAndTappingItAgainShufflesAgain() async throws {
        try await withLibrary { store, url in
            try await setQueue([101, 104, 108, 111, 113], store)
            _ = try await store.reorderQueue(.random, shuffle: { $0.reverse() })
            #expect(try queueTable(url) == [113, 111, 108, 104, 101])
            _ = try await store.reorderQueue(.random, shuffle: { $0.swapAt(0, 1) })
            #expect(try queueTable(url) == [111, 113, 108, 104, 101])
        }
    }

    @Test func everyEnqueueCaseMatchesTheOracleIncludingKeepSortedInsertion() async throws {
        try await withLibrary { store, url in
            let cases = Self.expected["enqueue"] as! [[String: Any]]
            #expect(cases.count == 42)
            for item in cases {
                let name = item["name"] as! String
                let location = try #require(EnqueueLocation(rawValue: item["location"] as! String))
                let keepSorted = item["keep_sorted"] as! Bool
                store.setQueueInsertionSettings(.init(location: location,
                    keepSortedOrder: keepSorted ? QueueSortOrder(rawValue: item["keep_sorted_order"] as! String) : nil,
                    locale: Locale(identifier: "en-US")))
                let current = (item["current"] as? NSNumber)?.int64Value
                let downloading = Set(ints(item["downloading"]).map(media))
                let outcomes: [(slot: Int, result: [Int64])] = location == .random
                    ? (item["outcomes"] as! [[String: Any]]).map { ($0["slot"] as! Int, ints($0["result"])) }
                    : [(-1, ints(item["result"]))]
                let base = ints(item["queue"]), add = ints(item["add"])
                for outcome in outcomes {
                    try await setQueue(base, store)
                    let slot = outcome.slot, size = base.count
                    let change = try await store.enqueue(add, location: location, playing: current.map(PlayingItem.episode),
                                                         downloadingURLs: downloading, randomIndex: { range in
                        #expect(range == 0...size, "\(name)")
                        return slot
                    })
                    #expect(try queueTable(url) == outcome.result, "\(name) slot \(outcome.slot)")
                    let added = ints(item["added"])
                    if item["keep_sorted_applied"] as! Bool {
                        #expect(change.events == [.sorted], "\(name)")
                    } else {
                        #expect(change.events.compactMap { if case .added(let id, _) = $0 { id } else { nil } } == added, "\(name)")
                    }
                    if location != .random, let slot = item["insert_position"] as? Int, !added.isEmpty, !keepSorted {
                        #expect(change.events.first == .added(episodeID: added[0], index: slot), "\(name)")
                    }
                }
            }
            store.setQueueInsertionSettings(.init())
        }
    }

    @Test func sortSheetLabelsTapsAndKeepSortedCheckboxFollowTheSource() {
        let dialog = Self.expected["dialog"] as! [String: Any]
        #expect((dialog["rows_in_grid_order"] as! [String]) == QueueSortRow.allCases.map { Self.english[$0.titleKey]! })
        for (active, rows) in dialog["labels_by_active_order"] as! [String: [[String: Any]]] {
            let order = QueueSortOrder(rawValue: active)
            #expect(active == "None" || order != nil)
            for (row, expected) in zip(QueueSortRow.allCases, rows) {
                let arrow = row.arrowAscending(order).map { $0 ? "\u{a0}▲" : "\u{a0}▼" } ?? ""
                #expect(Self.english[row.titleKey]! + arrow == expected["label"] as! String, "\(active) \(row)")
                #expect(row.isActive(order) == expected["active"] as! Bool)
                #expect(row.tapped(from: order).rawValue == expected["tap_selects"] as! String, "\(active) \(row)")
            }
        }
        // Keep sorted off: no active row, checkbox unchecked and disabled until a row is tapped.
        var sheet = QueueSortSheetState(keepSorted: false, storedOrder: .durationShortLong)
        #expect(sheet.order == nil && !sheet.keepSorted && !sheet.keepSortedEnabled)
        sheet.setKeepSorted(true)
        #expect(!sheet.keepSorted)
        sheet.tap(.duration)
        #expect(sheet.order == .durationShortLong && !sheet.keepSorted && sheet.keepSortedEnabled)
        sheet.setKeepSorted(true)
        #expect(sheet.keepSorted)
        // Random turns Keep sorted off and disables it; another order re-checks it in the same sheet.
        sheet.tap(.random)
        #expect(sheet.order == .random && !sheet.keepSorted && !sheet.keepSortedEnabled)
        sheet.tap(.random)
        #expect(sheet.order == .random && !sheet.keepSorted)
        sheet.tap(.date)
        #expect(sheet.order == .dateOldNew && sheet.keepSorted && sheet.keepSortedEnabled)
        // Random with the box already off does not re-check it later.
        sheet.setKeepSorted(false); sheet.tap(.random); sheet.tap(.smartShuffle)
        #expect(sheet.order == .smartShuffleOldNew && !sheet.keepSorted && sheet.keepSortedEnabled)
        // Keep sorted on: the stored order is active and the checkbox checked and enabled.
        let open = QueueSortSheetState(keepSorted: true, storedOrder: .feedTitleZA)
        #expect(open.order == .feedTitleZA && open.keepSorted && open.keepSortedEnabled)
        #expect(QueueSortOrder(storedValue: nil) == .dateNewOld && QueueSortOrder(storedValue: "EPISODE_FILENAME_A_Z") == .dateNewOld)
        #expect(EnqueueLocation(storedValue: "bogus") == .back)
    }

    @Test func keepSortedAppliesToDownloadRequestsPlaybackStartAndUserAddsButNotToUndoOrRandom() async throws {
        try await withLibrary { store, url in
            let directory = url.deletingLastPathComponent().appendingPathComponent("downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store.setQueueInsertionSettings(.init(location: .back, keepSortedOrder: .durationShortLong, locale: Locale(identifier: "en-US")))
            // Base queue is unsorted: 101, 104, 108, 111, 113 (30, 60, 60, 30, 20 min).
            // Enqueue downloaded at request time: 102 (30 min, ties 101/111) is queued and the whole queue re-sorted.
            let job = try #require(try await store.requestDownload(episodeID: 102, directory: directory))
            #expect(job.enqueuedByDownload)
            #expect(try queueTable(url) == [113, 101, 111, 102, 104, 108])
            // Cancelling that download removes it from the queue again.
            #expect(try await store.cancelDownload(id: job.id))
            #expect(try queueTable(url) == [113, 101, 111, 104, 108])
            // Enqueue downloaded off: the queue is untouched.
            _ = try await store.requestDownload(episodeID: 103, directory: directory, enqueue: false)
            #expect(try queueTable(url) == [113, 101, 111, 104, 108])
            // Undo of a removal restores the index without sorting.
            let removal = try await store.removeFromQueueWithUndo(113)
            _ = try await store.undoQueueRemoval(try #require(removal.receipt))
            #expect(try queueTable(url) == [113, 101, 111, 104, 108])
            try await setQueue([108, 113, 104], store)
            // A drifted queue is re-sorted in full at the next addition (playback start of an unqueued episode) ...
            _ = try await store.beginPlayback(episodeID: 115)
            #expect(try queueTable(url) == [113, 115, 108, 104])
            // ... but not when every item is skipped.
            try await setQueue([108, 113], store)
            #expect(try await store.enqueueUsingSettings([113, 110]).events.isEmpty)
            #expect(try queueTable(url) == [108, 113])
            #expect(try await store.enqueueUsingSettings([103]).events == [.sorted])
            #expect(try queueTable(url) == [113, 103, 108])
            // Keep sorted with the Random order: additions stay where Enqueue location puts them.
            store.setQueueInsertionSettings(.init(location: .front, keepSortedOrder: .random, locale: Locale(identifier: "en-US")))
            _ = try await store.enqueueUsingSettings([102])
            #expect(try queueTable(url) == [102, 113, 103, 108])
            store.setQueueInsertionSettings(.init())
        }
    }

    @Test func keepSortedAppliesToRefreshAddToQueueButNotToDownloadCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M23Refresh-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        do {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            func fetched(_ durations: [Int32]) -> FetchedFeed {
                let items = durations.enumerated().map { index, minutes in
                    ParsedEpisode(identifier: "\(index + 1)", title: "Episode \(index + 1)", publicationDate: now.addingTimeInterval(Double(index)),
                                  media: ParsedMedia(url: "https://example.test/\(index + 1).mp3", size: 1, durationMilliseconds: minutes * 60_000))
                }
                return FetchedFeed(feed: ParsedFeed(format: .rss, title: "Refresh", episodes: items), source: "https://example.test/feed",
                                   responseURL: URL(string: "https://example.test/feed")!, validator: nil, permanentRedirectURL: nil)
            }
            let feed = try await store.insert(fetched([30, 10]))
            func ids() async throws -> [String] { try await store.queue().map { $0.details.identifier ?? "" } }
            func id(_ identifier: String) async throws -> Int64 {
                try #require(try await store.feed(id: feed.id)?.episodes.first { $0.details.identifier == identifier }?.id)
            }
            _ = try await store.enqueue([try await id("1"), try await id("2")])
            store.setQueueInsertionSettings(.init(location: .back, keepSortedOrder: .durationShortLong))
            var options = FeedRefreshOptions(now: now.addingTimeInterval(10), timeZone: .gmt)
            options.globalNewEpisodesAction = .queue
            _ = try await store.applyRefresh(fetched([30, 10, 20, 5]), feedID: feed.id, options: options)
            #expect(try await ids() == ["1", "2"], "Refresh queues through its effect")
            _ = try await store.consumeQueueEffects()
            #expect(try await ids() == ["4", "2", "3", "1"], "Refresh's Add to queue re-sorts")

            // Download completion saves the measured duration but does not re-sort.
            let four = try await id("4")
            let job = try #require(try await store.requestDownload(episodeID: four, directory: directory))
            let attempt = try #require(try await store.beginDownloadAttempt(id: job.id))
            try Data([1, 2, 3]).write(to: attempt.destination)
            #expect(try await store.attachDownloadFile(id: job.id, attempt: attempt.attempts))
            #expect(try await store.completeDownload(id: job.id, attempt: attempt.attempts, measuredDuration: 60 * 60_000))
            #expect(try await store.episode(id: four)?.details.media?.durationMilliseconds == 60 * 60_000)
            #expect(try await ids() == ["4", "2", "3", "1"])
        } catch { try? await store.close(); throw error }
        try await store.close()
    }

    @Test func enqueueLocationUsesTheSelectedEpisodeAndActiveDownloads() async throws {
        try await withLibrary { store, url in
            let directory = url.deletingLastPathComponent().appendingPathComponent("downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // After current episode: the paused current episode 108 is the anchor for a user add and a download request.
            _ = try await store.beginPlayback(episodeID: 108)
            store.setQueueInsertionSettings(.init(location: .afterCurrentlyPlaying))
            _ = try await store.enqueueUsingSettings([103])
            #expect(try queueTable(url) == [101, 104, 108, 103, 111, 113])
            _ = try await store.requestDownload(episodeID: 102, directory: directory, location: .afterCurrentlyPlaying)
            // 103 is not downloading, so 102 goes directly after the current episode.
            #expect(try queueTable(url) == [101, 104, 108, 102, 103, 111, 113])
            // Front keeps back-to-back download requests in request order: each skips the downloading prefix.
            try await setQueue([101, 104], store)
            store.setQueueInsertionSettings(.init(location: .front))
            for id: Int64 in [115, 109, 112] {
                _ = try await store.requestDownload(episodeID: id, directory: directory, location: .front)
            }
            #expect(try queueTable(url) == [115, 109, 112, 101, 104])
            store.setQueueInsertionSettings(.init())
        }
    }

    @Test func clearQueueRemovesOnlyQueueRowsWithoutSyncOrAutoDownloadAndPlaybackStopsAtTheEnd() async throws {
        try await withLibrary { store, url in
            try await store.updateEpisode(id: 104) { $0.userState.isFavorite = true; $0.userState.positionMilliseconds = 60_000 }
            let session = try await store.beginPlayback(episodeID: 101)
            if let token = try await store.automaticDownloadRequest() { try await store.finishAutomaticDownloadRequest(token) }
            let feedsBefore = try await store.feeds(), effects = try await store.pendingEffects()
            let sync = try await store.synchronizationQueue()
            let change = try await store.clearQueue()
            #expect(change.events == [.cleared] && change.episodeIDs.isEmpty)
            #expect(try queueTable(url).isEmpty)
            #expect(try await store.feeds() == feedsBefore, "Episode state, favorites and positions are untouched")
            #expect(try await store.pendingEffects() == effects)
            #expect(try await store.synchronizationQueue() == sync, "No synchronization action")
            #expect(try await store.queueAutoDownloadRequested() == false, "No automatic download evaluation")
            #expect(try await store.playbackSession()?.id == session.id, "The playing episode keeps playing")
            // Clearing an empty queue is a no-op.
            #expect(try await store.clearQueue().episodeIDs.isEmpty)
            // The playing episode is no longer queued, so its end has no next episode.
            let end = try await store.endPlayback(sessionID: session.id, reason: .ended)
            #expect(end?.nextEpisodeID == nil)
            // Its export matches: an Android backup carries an empty Queue table.
            let backup = try await AndroidDatabaseBackup.data(library: store, speeds: .init()) { _ in nil }
            #expect(try androidQueue(backup).isEmpty)
        }
    }

    @Test func sortedQueueIsWhatAnAndroidBackupCarries() async throws {
        try await withLibrary { store, _ in
            _ = try await store.reorderQueue(.durationShortLong)
            let backup = try await AndroidDatabaseBackup.data(library: store, speeds: .init()) { _ in nil }
            #expect(try androidQueue(backup) == [113, 101, 111, 104, 108])
        }
    }

    private func androidQueue(_ data: Data) throws -> [Int64] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("M23-backup-\(UUID()).db")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw FeedLibraryError.corruptRecord }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT feeditem FROM Queue ORDER BY id", -1, &statement, nil) == SQLITE_OK else { throw FeedLibraryError.corruptRecord }
        defer { sqlite3_finalize(statement) }
        var ids: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW { ids.append(sqlite3_column_int64(statement, 0)) }
        return ids
    }
}
