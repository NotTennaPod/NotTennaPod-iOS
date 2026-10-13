import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor
struct LocalFolderCoordinatorTests {
    private func fixture(_ body: (FeedLibraryStore, URL, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalImport-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: database)
        do { try await body(store, database, root); try await store.close() }
        catch { try? await store.close(); throw error }
    }

    private func wait(_ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(try await condition())
    }

    @Test func realSelectionReturnsRegisteredFeedBeforeScanAndPersistsDefaultOrder() async throws {
        try await fixture { store, database, root in
            let folder = root.appendingPathComponent("Episodes ü #100%")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let gate = LocalImportGate()
            let coordinator = LocalFolderCoordinator(store: store, refresh: { id in
                await gate.hold(id)
                return try await LocalFeedRefreshService(store: store).refresh(feedID: id, description: "Local", author: "AntennaPod")
            })
            let selection = try await LocalFolderSelection.prepare(directory: folder)
            #expect(selection.title == "Episodes ü #100%")
            let registered = try await coordinator.add(selection, fallbackTitle: "Local folder")
            #expect(registered.title == selection.title && registered.episodes.isEmpty)
            #expect(registered.episodeSortOrderCode == 3 && registered.autoDownload == .disabled)
            #expect(coordinator.refreshingFeedID == registered.id)
            try await wait { await gate.started == [registered.id] }
            #expect(try await store.feed(id: registered.id)?.lastRefreshAttempt == nil)
            await gate.release(registered.id)
            try await wait { coordinator.refreshingFeedID == nil }
            #expect(try await store.logs(feedID: registered.id).map(\.kind) == [.success])
            let reopened = try FeedLibraryStore(url: database)
            #expect(try await reopened.feed(id: registered.id)?.episodeSortOrderCode == 3)
            #expect(try await reopened.localFolder(feedID: registered.id)?.bookmark == selection.bookmark)
            try await reopened.close()
        }
    }

    @Test(arguments: [NewEpisodesAction.inbox, .queue, .nothing])
    func realLocalScanUsesCurrentGlobalNewEpisodePreference(action: NewEpisodesAction) async throws {
        try await fixture { store, _, root in
            let folder = root.appendingPathComponent("Episodes")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let sample = try #require(Bundle.module.url(forResource: "playback-30sec", withExtension: "mp3", subdirectory: "Fixtures"))
            let existing = folder.appendingPathComponent("Existing.mp3")
            try FileManager.default.copyItem(at: sample, to: existing)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 978307200)], ofItemAtPath: existing.path)
            let preferences = try DownloadPreferenceStore(file: root.appendingPathComponent("downloads.json"))
            let coordinator = LocalFolderCoordinator(store: store, description: "Local", author: "Folder", options: {
                await MainActor.run {
                    var options = FeedRefreshOptions(); options.globalNewEpisodesAction = preferences.value.newEpisodesAction ?? .inbox
                    return options
                }
            })
            let feed = try await coordinator.add(try await LocalFolderSelection.prepare(directory: folder), fallbackTitle: "Folder")
            try await wait { coordinator.refreshingFeedID == nil }
            var value = preferences.value; value.newEpisodesAction = action; try preferences.update(value)
            let arrival = folder.appendingPathComponent("New episode.mp3")
            try FileManager.default.copyItem(at: sample, to: arrival)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 978393600)], ofItemAtPath: arrival.path)
            coordinator.startRefresh(feedID: feed.id)
            try await wait { coordinator.refreshingFeedID == nil }
            let saved = try #require(try await store.feed(id: feed.id))
            #expect(saved.newEpisodesAction == .global && saved.episodes.count == 2)
            let episode = try #require(saved.episodes.first { $0.details.link == "New episode.mp3" })
            #expect(episode.userState.playState == (action == .inbox ? .new : .unplayed))
            _ = try await store.consumeFeedRefreshQueueEffects()
            #expect(try await store.queue().map(\.id) == (action == .queue ? [episode.id] : []))
            #expect(try await store.consumeFeedRefreshQueueEffects().isEmpty)
        }
    }

    @Test func failedFirstScanRetainsSubscriptionAndAllowsRecovery() async throws {
        try await fixture { store, _, root in
            let folder = root.appendingPathComponent("Missing")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let selection = try await LocalFolderSelection.prepare(directory: folder)
            try FileManager.default.removeItem(at: folder)
            let coordinator = LocalFolderCoordinator(store: store, description: "Local", author: "AntennaPod")
            var events: [LocalFolderCoordinator.Event] = []
            coordinator.onEvent = { events.append($0) }
            let feed = try await coordinator.add(selection, fallbackTitle: "Local folder")
            try await wait { coordinator.refreshingFeedID == nil }
            #expect(try await store.feed(id: feed.id)?.lastUpdateFailed == true)
            #expect(try await store.feeds().count == 1)
            #expect(try await store.logs(feedID: feed.id).count == 1)
            // The failed scan updates the library; a folder read failure is not reported as a storage error.
            #expect(events.contains(.libraryChanged))
            #expect(!events.contains { if case .storageFailed = $0 { true } else { false } })
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let repaired = try await LocalFolderSelection.prepare(directory: folder)
            try await coordinator.reconnect(repaired, feedID: feed.id)
            #expect(coordinator.refreshingFeedID == nil)
            #expect(try await store.feed(id: feed.id)?.lastUpdateFailed == true)
            coordinator.startRefresh(feedID: feed.id)
            try await wait { coordinator.refreshingFeedID == nil }
            #expect(try await store.feed(id: feed.id)?.lastUpdateFailed == false)
            let logs = try await store.logs(feedID: feed.id)
            #expect(logs.count == 2 && logs.first?.kind == .success)
        }
    }

    @Test func newerManualRequestReplacesWorkWithoutLateStateOrError() async throws {
        try await fixture { store, _, _ in
            let gate = LocalImportGate()
            let coordinator = LocalFolderCoordinator(store: store, refresh: { id in
                await gate.hold(id)
                if id == 1 { throw LocalFolderScanFailure(message: "Obsolete error") }
                return .superseded
            })
            var events: [LocalFolderCoordinator.Event] = []
            coordinator.onEvent = { events.append($0) }
            coordinator.startRefresh(feedID: 1)
            try await wait { await gate.started == [1] }
            coordinator.startRefresh(feedID: 2)
            try await wait { await gate.started == [1, 2] }
            await gate.release(1)
            try await wait { await gate.finished.contains(1) }
            #expect(coordinator.refreshingFeedID == 2)
            await gate.release(2)
            try await wait { coordinator.refreshingFeedID == nil }
            // The superseded request's late error is never surfaced.
            #expect(!events.contains { if case .storageFailed = $0 { true } else { false } })
        }
    }

    @Test func reconnectDoesNotRefreshOrRenameOrDiscardHistory() async throws {
        try await fixture { store, _, _ in
            let context = try await store.registerLocalFolder(title: "Original", directoryIdentity: "old", bookmark: Data([1]))
            _ = try await store.applyLocalFolderScan(ParsedFeed(format: .rss, episodes: [
                ParsedEpisode(identifier: "episode", link: "one.mp3", media: ParsedMedia(url: "document:one", size: 1))
            ]), context: context)
            try await store.updateEpisode(id: 1) { $0.userState.positionMilliseconds = 1234 }
            let before = try await store.feed(id: 1)
            let coordinator = LocalFolderCoordinator(store: store, refresh: { _ in
                Issue.record("Reconnection must not start a scan"); return .superseded
            })
            try await coordinator.reconnect(.init(title: "Other", identity: "new", bookmark: Data([2])), feedID: 1)
            #expect(coordinator.refreshingFeedID == nil)
            let after = try await store.feed(id: 1)
            #expect(after?.title == "Original" && after?.episodes == before?.episodes)
            #expect(after?.source == "antennapod_local:new")
            #expect(after?.episodeSortOrderCode == 3)
        }
    }

    @Test func canceledAndInvalidSelectionDoNotRegisterOrScheduleWork() async throws {
        try await fixture { store, _, root in
            let coordinator = LocalFolderCoordinator(store: store, refresh: { _ in
                Issue.record("Invalid selection scheduled a scan"); return .superseded
            })
            let file = root.appendingPathComponent("not-a-folder"); try Data([1]).write(to: file)
            await #expect(throws: LocalFolderDocuments.Failure.notDirectory) { try await LocalFolderSelection.prepare(directory: file) }
            await #expect(throws: FeedLibraryError.invalidMutation) {
                try await coordinator.add(.init(title: nil, identity: "folder", bookmark: Data()), fallbackTitle: "Local folder")
            }
            let canceled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await coordinator.add(.init(title: nil, identity: "folder", bookmark: Data([1])), fallbackTitle: "Local folder")
            }
            await #expect(throws: CancellationError.self) { try await canceled.value }
            #expect(try await store.feeds().isEmpty && coordinator.refreshingFeedID == nil)
        }
    }

    @Test func sourceSQLTitleAndLegacyDefaultOrderingPreserveStoredEpisodes() throws {
        // FeedItemSortQuery.generateFrom(EPISODE_TITLE_A_Z) returns
        // "FeedItems.title ASC"; PodDBAdapter declares title TEXT without collation.
        let database = FileManager.default.temporaryDirectory.appendingPathComponent("LocalSort-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: database) }
        let db = try LibrarySQLite(url: database); defer { try? db.close() }
        try db.execute("CREATE TABLE FeedItems (id INTEGER PRIMARY KEY, title TEXT, pubDate INTEGER)")
        let names: [String?] = ["z", "A", "a2", "a10", "é", "e\u{301}", "\u{e000}", "😀", nil, "", "a", "A", "a\0b"]
        var episodes: [LibraryEpisode] = []
        for (index, title) in names.enumerated() {
            let id = Int64(index + 1)
            let date: Int64? = index.isMultiple(of: 4) ? nil : Int64((index * 7) % 5) * 1000
            try db.execute("INSERT INTO FeedItems VALUES (?, ?, ?)", [
                .integer(id), title.map(LibrarySQLValue.text) ?? .null, date.map(LibrarySQLValue.integer) ?? .null
            ])
            episodes.insert(.init(id: id, details: .init(title: title,
                publicationDate: date.map { Date(timeIntervalSince1970: Double($0) / 1000) })), at: 0)
        }
        let expected = try db.rows("SELECT id FROM FeedItems ORDER BY FeedItems.title ASC").compactMap { $0[0].integer }
        var feed = LibraryFeed(id: 1, source: "antennapod_local:folder", metadata: .init(format: .rss), episodes: episodes)
        feed.episodeSortOrderCode = 3
        #expect(feed.displayEpisodes.map(\.id) == expected)
        #expect(feed.episodes == episodes)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(feed)) as! [String: Any]
        legacy.removeValue(forKey: "episodeSortOrderCode")
        let old = try JSONDecoder().decode(LibraryFeed.self, from: JSONSerialization.data(withJSONObject: legacy))
        // A missing per-feed choice follows the global default (DATE_NEW_OLD),
        // not the persisted array order. Derive the expectation through SQLite,
        // just as the source query does, including NULL dates and ties.
        let defaultIDs = try db.rows("SELECT id FROM FeedItems ORDER BY FeedItems.pubDate DESC").compactMap { $0[0].integer }
        #expect(old.episodeSortOrderCode == nil)
        #expect(old.displayEpisodes.map(\.id) == defaultIDs)
        #expect(old.episodes == episodes)
    }
}

private actor LocalImportGate {
    var started: [Int64] = []
    var finished: [Int64] = []
    private var continuations: [Int64: CheckedContinuation<Void, Never>] = [:]
    func hold(_ id: Int64) async {
        started.append(id)
        await withCheckedContinuation { continuations[id] = $0 }
        finished.append(id)
    }
    func release(_ id: Int64) { continuations.removeValue(forKey: id)?.resume() }
}
