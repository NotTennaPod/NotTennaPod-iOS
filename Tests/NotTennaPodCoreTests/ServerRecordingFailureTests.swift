import Foundation
import Testing
@testable import NotTennaPodCore

/// Failure injection (PROTOCOL §15.2): a failure after every individual recorder write leaves
/// nothing of the recorder's savepoint; an ordinary mutation rolls back whole, with its files and the player
/// untouched; a playback write still commits.
@MainActor @Suite struct ServerRecordingFailureTests {
    private final class Engine: PlaybackEngine {
        var reading: PlaybackEngineReading?
        var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
        var loads = 0, unloads = 0
        func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) { loads += 1 }
        func play(commandID: UUID) {}
        func pause(commandID: UUID) {}
        func seek(to positionMilliseconds: Int64, commandID: UUID) {}
        func setSpeed(_ speed: Float, commandID: UUID) throws {}
        func unload() { unloads += 1 }
    }

    /// One mutation under test: `setup` prepares the library, `act` makes the write.
    struct Scenario: Sendable, CustomStringConvertible {
        let name: String
        let setup: @Sendable (ServerLibraryFixture) async throws -> [Int64]
        let act: @Sendable (ServerLibraryFixture, [Int64]) async throws -> Void
        var description: String { name }
    }

    nonisolated private static func registered(_ fixture: ServerLibraryFixture) async throws -> [Int64] {
        let feed = try await fixture.subscribeRegistered().feed
        return [feed.id] + feed.episodes.map(\.id).sorted()
    }

    nonisolated private static func pending(_ fixture: ServerLibraryFixture) async throws -> [Int64] {
        let feed = try await fixture.store.insert(ServerLibraryFixture.fetched("https://example.test/pending.xml", title: "Pending"))
        return [feed.id] + feed.episodes.map(\.id).sorted()
    }

    /// A refresh finding two new releases (PROTOCOL §9.5).
    nonisolated private static func refresh(_ fixture: ServerLibraryFixture, _ feedID: Int64, source: String = "https://example.test/feed.xml") async throws {
        _ = try await fixture.store.applyRefresh(ServerLibraryFixture.fetched(source, title: source.contains("pending") ? "Pending" : "Show", count: 6),
                                                 feedID: feedID, options: .init(now: ServerLibraryFixture.now.addingTimeInterval(86_400 * 7)))
    }

    /// A registered podcast whose first canonical metadata arrived, so its next refresh observes its backfill (PROTOCOL §9.4).
    nonisolated private static func large(_ fixture: ServerLibraryFixture) async throws -> [Int64] {
        let (feed, podcast, _) = try await fixture.subscribeRegistered(ServerDiscoveryTests.fetched(ServerDiscoveryTests.base))
        try await fixture.store.executeForTesting("INSERT INTO ntp_records(entity, id, field_group, value, provenance) VALUES ('podcast', ?, 'metadata', ?, '[]')",
                                                  [.text(podcast), .blob(try (["title": "Show"] as ContractJSON).canonicalData())])
        return [feed.id] + feed.episodes.map(\.id).sorted()
    }

    /// A refresh with 453 records to observe besides its release: more than one bounded transaction's worth (PROTOCOL §6.8).
    nonisolated private static func refreshLarge(_ fixture: ServerLibraryFixture, _ feedID: Int64) async throws {
        _ = try await fixture.store.applyRefresh(ServerDiscoveryTests.fetched(ServerDiscoveryTests.large), feedID: feedID,
                                                 options: .init(now: ServerDiscoveryTests.date(10)))
    }

    nonisolated static let scenarios: [Scenario] = [
        .init(name: "subscribe", setup: { _ in [] }, act: { f, _ in _ = try await f.store.insert(ServerLibraryFixture.fetched()) }),
        .init(name: "register preview", setup: { f in
            let preview = try await f.store.preparePreview(ServerLibraryFixture.fetched(), now: ServerLibraryFixture.now)
            return preview.episodes.map(\.id)
        }, act: { f, ids in try await f.store.setFavorite(episodeID: ids[0], favorite: true) }),
        .init(name: "mark registered", setup: registered, act: { f, ids in try await f.store.markEpisodesPlayed(episodeIDs: [ids[1], ids[2]], played: true) }),
        .init(name: "mark pending draft", setup: pending, act: { f, ids in try await f.store.markEpisodePlayed(episodeID: ids[1], played: true) }),
        .init(name: "dismiss", setup: { f in
            let ids = try await registered(f)
            for id in ids.dropFirst() { try await f.store.projectForTesting(id) { $0.userState.playState = .new } }
            return ids
        }, act: { f, ids in try await f.store.removeAllFromInbox() }),
        .init(name: "policy", setup: registered, act: { f, ids in try await f.store.updatePreferences(feedID: ids[0]) { $0.keepUpdated = false; $0.newEpisodesAction = .nothing } }),
        .init(name: "archive", setup: registered, act: { f, ids in try await f.store.updatePreferences(feedID: ids[0]) { $0.subscriptionState = .archived } }),
        .init(name: "change URL", setup: registered, act: { f, _ in _ = try await f.store.updateFeedDownloadURL(original: "https://example.test/feed.xml", updated: "https://example.test/moved.xml") }),
        .init(name: "credentials", setup: registered, act: { f, ids in
            try await FeedAuthentication(store: f.store, vault: f.vault).save(.init(username: "a", password: "b"), feedID: ids[0])
        }),
        .init(name: "queue add keep sorted", setup: { f in
            let ids = try await registered(f)
            _ = try await f.store.enqueue([ids[3], ids[1]])
            f.store.setQueueInsertionSettings(.init(keepSortedOrder: .episodeTitleAZ))
            return ids
        }, act: { f, ids in _ = try await f.store.enqueue([ids[2]]) }),
        .init(name: "queue remove", setup: { f in let ids = try await registered(f); _ = try await f.store.enqueue(Array(ids.dropFirst())); return ids },
              act: { f, ids in _ = try await f.store.removeFromQueueWithUndo(ids[2]) }),
        .init(name: "queue move", setup: { f in let ids = try await registered(f); _ = try await f.store.enqueue(Array(ids.dropFirst())); return ids },
              act: { f, ids in _ = try await f.store.performQueueMove(.item(ids[1], finalIndex: 3), expected: try await f.store.queue().map(QueueEpisodeIdentity.init)) }),
        .init(name: "queue sort", setup: { f in let ids = try await registered(f); _ = try await f.store.enqueue(Array(ids.dropFirst()).reversed()); return ids },
              act: { f, _ in _ = try await f.store.reorderQueue(.dateOldNew) }),
        .init(name: "queue clear", setup: { f in let ids = try await registered(f); _ = try await f.store.enqueue(Array(ids.dropFirst())); return ids },
              act: { f, _ in _ = try await f.store.clearQueue() }),
        .init(name: "history remove", setup: { f in
            let ids = try await registered(f)
            try await f.store.projectForTesting(ids[1]) { $0.userState.lastPlayedHistoryMilliseconds = 9_000 }
            return ids
        }, act: { f, ids in _ = try await f.store.removeFromPlaybackHistoryWithUndo(ids[1]) }),
        .init(name: "history clear with drafts", setup: { f in
            let ids = try await registered(f)
            let pending = try await pending(f)
            try await f.store.setFavorite(episodeID: pending[1], favorite: true)
            try await f.store.projectForTesting(ids[1]) { $0.userState.lastPlayedHistoryMilliseconds = 9_000 }
            return ids
        }, act: { f, _ in _ = try await f.store.clearPlaybackHistory() }),
        .init(name: "statistics reset", setup: { f in
            let ids = try await registered(f)
            try await f.store.projectForTesting(ids[1]) { $0.userState.playedDurationMilliseconds = 9_000 }
            return ids
        }, act: { f, _ in try await f.store.resetPlayedDurationStatistics() }),
        .init(name: "account policy", setup: { _ in [] }, act: { f, _ in try await f.store.setServerAccountPolicy(.sorting(keepSorted: true, order: .dateOldNew)) }),
        .init(name: "unsubscribe", setup: registered, act: { f, ids in _ = try await f.store.requestFeedDeletion(feedID: ids[0]) }),
        .init(name: "subscribe with URL credentials", setup: { _ in [] },
              act: { f, _ in _ = try await f.store.insert(ServerLibraryFixture.fetched("https://alice:pw@example.test/private.xml")) }),
        .init(name: "keep-sorted add across podcasts", setup: { f in
            let ids = try await registered(f)
            let two = try await f.subscribeRegistered(ServerLibraryFixture.fetched("https://example.test/two.xml", title: "Two")).feed.episodes.map(\.id).sorted()
            _ = try await f.store.enqueue([ids[3], two[1], ids[1]])
            f.store.setQueueInsertionSettings(.init(keepSortedOrder: .episodeTitleAZ))
            return ids + two
        }, act: { f, ids in _ = try await f.store.enqueue([ids[2]]) }),
        .init(name: "owed play-load add replayed", setup: { f in
            let ids = try await registered(f)
            await f.store.injectRecorderFailure(after: 1)
            _ = try await f.store.beginPlayback(episodeID: ids[1])
            await f.store.injectRecorderFailure(after: nil)
            return ids
        }, act: { f, ids in _ = try await f.store.enqueue([ids[2]]) }),
        .init(name: "refresh observes and proposes", setup: { f in
            let ids = try await registered(f)
            try await f.store.updatePreferences(feedID: ids[0]) { $0.showEpisodeNotification = true }
            return ids
        }, act: { f, ids in try await refresh(f, ids[0]) }),
        .init(name: "refresh drafts of a pending registration", setup: pending, act: { f, ids in try await refresh(f, ids[0], source: "https://example.test/pending.xml") }),
        .init(name: "queue filing proposes with its bundle", setup: { f in
            let ids = try await registered(f)
            try await f.store.updatePreferences(feedID: ids[0]) { $0.newEpisodesAction = .queue }
            _ = try await f.store.enqueue([ids[1]])
            try await refresh(f, ids[0])
            return ids
        }, act: { f, _ in _ = try await f.store.consumeFeedRefreshQueueEffects(location: .front) }),
        .init(name: "refresh lists a large batch's observations", setup: large, act: { f, ids in try await refreshLarge(f, ids[0]) }),
        .init(name: "deferred observations", setup: { f in
            let ids = try await large(f)
            try await refreshLarge(f, ids[0])
            return ids
        }, act: { f, _ in _ = try await f.store.recordDeferredObservations(feedID: nil) }),
        .init(name: "materialize discovery drafts", setup: { f in
            let ids = try await pending(f)
            try await refresh(f, ids[0], source: "https://example.test/pending.xml")
            return ids
        }, act: { f, ids in
            let op = try f.registrationOp(feedID: ids[0])
            let created = try f.created(op)
            try await f.store.resolveRegistration(opID: op, .init(podcastID: created.podcast, generationID: created.generation, mode: "created", decisionID: nil))
        }),
        .init(name: "materialize", setup: { f in
            let ids = try await pending(f)
            try await f.store.markEpisodePlayed(episodeID: ids[1], played: true)
            try await f.store.setFavorite(episodeID: ids[2], favorite: true)
            return ids
        }, act: { f, ids in
            let op = try f.registrationOp(feedID: ids[0])
            let created = try f.created(op)
            try await f.store.resolveRegistration(opID: op, .init(podcastID: created.podcast, generationID: created.generation, mode: "created", decisionID: nil))
        }),
    ]

    /// How many writes the recorder makes for the scenario.
    private func writes(_ scenario: Scenario) async throws -> Int {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let ids = try await scenario.setup(fixture)
        let before = try fixture.serverTables()
        try await scenario.act(fixture, ids)
        #expect(try fixture.serverTables() != before, "\(scenario.name) records something")
        return await fixture.store.lastRecorderWrites()
    }

    @Test(arguments: scenarios) func aFailureAfterAnyRecorderWriteLeavesNothing(_ scenario: Scenario) async throws {
        let total = try await writes(scenario)
        #expect(total > 0)
        for failAfter in 1...total {
            let fixture = try await ServerLibraryFixture()
            let ids = try await scenario.setup(fixture)
            let rows = try fixture.libraryRows(), tables = try fixture.serverTables()
            let files = try contents(fixture.directory)
            await fixture.store.injectRecorderFailure(after: failAfter)
            do {
                try await scenario.act(fixture, ids)
                Issue.record("\(scenario.name) failing after write \(failAfter) committed")
            } catch let error as ServerRecordingError {
                #expect(error == .injectedFailure, "\(scenario.name) after write \(failAfter): \(error)")
                #expect(try fixture.libraryRows() == rows, "\(scenario.name) after write \(failAfter): rows changed")
                #expect(try fixture.serverTables() == tables, "\(scenario.name) after write \(failAfter): recorder state survived")
                #expect(try contents(fixture.directory) == files, "\(scenario.name) after write \(failAfter): files changed")
            }
            await fixture.close()
        }
    }

    private func contents(_ directory: URL) throws -> [String: Int] {
        var result: [String: Int] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where !name.hasPrefix("library.sqlite") {
            result[name] = (try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.size] as? NSNumber)?.intValue ?? -1
        }
        return result
    }

    // MARK: Playback writes never fail because of sync

    @Test func aPlaybackLoadAndEndCommitWhenTheirRecordingFails() async throws {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let store = fixture.store
        let ids = try await Self.registered(fixture)
        // The play load's queue add: the load commits without its fact, which is owed durably.
        await store.injectRecorderFailure(after: 1)
        let session = try await store.beginPlayback(episodeID: ids[1])
        #expect(try await store.queue().map(\.id) == [ids[1]])
        #expect(try await store.playbackSelectionEpisodeID() == ids[1])
        #expect(try fixture.rows("SELECT intent, subject FROM ntp_owed") == [["queue.add", "episode:\(ids[1])"]])
        #expect(try fixture.rows("SELECT export_owed FROM ntp_library") == [["0"]])
        #expect(try fixture.outbox().map(\.type) == ["podcast.subscribe"])
        // A save and the end (its queue removal changes the recorder's keys) commit as well.
        _ = try await store.recordPlayback(sessionID: session.id, sample: .init(positionMilliseconds: 599_000, durationMilliseconds: 600_000, status: .paused), synchronize: true)
        let ended = try #require(try await store.endPlayback(sessionID: session.id, reason: .ended))
        #expect(ended.markedPlayed)
        #expect(try await store.episode(id: ids[1])?.userState.playState == .played)
        #expect(try await store.queue().isEmpty)
        await store.injectRecorderFailure(after: nil)
        #expect(try fixture.rows("SELECT export_owed FROM ntp_library") == [["1"]], "the end's leave is owed")
        // The next write drops what is owed for an episode no longer queued, repairs the queue keys and records the
        // owed leave before its own fact.
        _ = try await store.enqueue([ids[2]])
        #expect(try fixture.queueOrderMatchesKeys())
        #expect(try fixture.rows("SELECT count(*) FROM ntp_owed") == [["0"]])
        #expect(try fixture.rows("SELECT export_owed FROM ntp_library") == [["0"]])
        #expect(try fixture.outbox().map(\.type) == ["podcast.subscribe", "episode.leave", "queue.add"])
    }

    // MARK: Files and the player (side effects)

    private func downloaded(_ fixture: ServerLibraryFixture, _ ids: [Int64]) async throws -> [URL] {
        var files: [URL] = []
        for id in ids.dropFirst() {
            let file = fixture.directory.appendingPathComponent("episode-\(id).media")
            try Data([1, 2, 3]).write(to: file)
            try Data([4]).write(to: URL(fileURLWithPath: file.path + ".transcript"))
            try await fixture.store.attachDownloadForTesting(id, file: file)
            files.append(file)
        }
        return files
    }

    @Test func aFailedDeletionLeavesTheFileAndThePlayer() async throws {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let store = fixture.store
        let ids = try await Self.registered(fixture)
        let files = try await downloaded(fixture, ids)
        _ = try await store.enqueue([ids[1], ids[2]])
        let engine = Engine()
        let playback = PlaybackCoordinator(store: store, engine: engine)
        try await playback.select(episodeID: ids[1], play: false)
        let rows = try fixture.libraryRows(), tables = try fixture.serverTables()
        await store.injectRecorderFailure(after: 1)
        await #expect(throws: ServerRecordingError.injectedFailure) {
            try await playback.deleteDownloadedMedia(episodeID: ids[1], deleteRemovesFromQueue: true)
        }
        #expect(playback.episode?.id == ids[1])
        #expect(engine.unloads == 1)  // the load's own unload of the previous (empty) player
        #expect(try fixture.libraryRows() == rows)
        #expect(try fixture.serverTables() == tables)
        #expect(FileManager.default.fileExists(atPath: files[0].path))
        #expect(FileManager.default.fileExists(atPath: files[0].path + ".transcript"))
        // Without the failure the deletion commits, then the player retires and the post-commit work deletes.
        await store.injectRecorderFailure(after: nil)
        try await playback.deleteDownloadedMedia(episodeID: ids[1], deleteRemovesFromQueue: true)
        #expect(playback.episode == nil)
        #expect(engine.unloads == 2)
        #expect(try fixture.outbox().last?.type == "queue.remove")
        let worker = MediaDownloadWorker(store: store)
        try await worker.cleanCancelledFiles()
        #expect(!FileManager.default.fileExists(atPath: files[0].path))
        #expect(!FileManager.default.fileExists(atPath: files[0].path + ".transcript"))
        #expect(try await store.pendingEffects(kinds: ["deleteDownloadFile"]).isEmpty)
    }

    @Test func aFailedPositionResetLeavesThePlayer() async throws {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let store = fixture.store
        let ids = try await Self.registered(fixture)
        let engine = Engine()
        let playback = PlaybackCoordinator(store: store, engine: engine)
        try await playback.select(episodeID: ids[1], play: false)
        let rows = try fixture.libraryRows()
        await store.injectRecorderFailure(after: 1)
        await #expect(throws: ServerRecordingError.injectedFailure) { try await playback.resetPlaybackPosition(episodeID: ids[1]) }
        #expect(playback.episode?.id == ids[1])
        #expect(engine.unloads == 1)
        #expect(try fixture.libraryRows() == rows)
        await store.injectRecorderFailure(after: nil)
        try await playback.resetPlaybackPosition(episodeID: ids[1])
        #expect(playback.episode == nil)
        #expect(try fixture.outbox().last?.type == "episode.reset_position")
    }

    @Test func postCommitDeletionKeepsAFileAnotherEpisodeStillReferences() async throws {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let store = fixture.store
        let ids = try await Self.registered(fixture)
        let files = try await downloaded(fixture, ids)
        try await store.requestMediaDeletion(episodeID: ids[1])
        // Before the work runs, another episode comes to name the same file (as a merge moves a download, PROTOCOL §9.7).
        try await store.attachDownloadForTesting(ids[2], file: files[0])
        let worker = MediaDownloadWorker(store: store)
        try await worker.cleanCancelledFiles()
        #expect(FileManager.default.fileExists(atPath: files[0].path))
        #expect(try await store.pendingEffects(kinds: ["deleteDownloadFile"]).isEmpty)
    }

    @Test func aFailedUnsubscribeLeavesFilesAndPlaybackAndTheWorkReplaysAfterACommit() async throws {
        let fixture = try await ServerLibraryFixture()
        defer { Task { await fixture.close() } }
        let store = fixture.store
        let ids = try await Self.registered(fixture)
        let files = try await downloaded(fixture, ids)
        let engine = Engine()
        let playback = PlaybackCoordinator(store: store, engine: engine)
        try await playback.select(episodeID: ids[2], play: false)
        let deletion = FeedDeletionCoordinator(store: store, retirePlayback: { try await playback.retireDeletedEpisodes($0) },
                                               retireDownloads: { _ in })
        let rows = try fixture.libraryRows()
        await store.injectRecorderFailure(after: 1)
        await #expect(throws: ServerRecordingError.injectedFailure) { try await deletion.delete(feedID: ids[0]).value }
        #expect(try fixture.libraryRows() == rows)
        #expect(playback.episode?.id == ids[2])
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        // Committed: the work runs after COMMIT (the player retires, the files go); a later resume finds nothing left.
        await store.injectRecorderFailure(after: nil)
        try await deletion.delete(feedID: ids[0]).value
        #expect(playback.episode == nil)
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(try fixture.outbox().last?.type == "podcast.unsubscribe")
        try await deletion.resume().value
    }

    @Test func postCommitWorkInterruptedByAProcessDeathRunsAtTheNextLaunch() async throws {
        let fixture = try await ServerLibraryFixture()
        let ids = try await Self.registered(fixture)
        let files = try await downloaded(fixture, ids)
        try await fixture.store.requestMediaDeletion(episodeID: ids[1])
        _ = try await fixture.store.requestFeedDeletion(feedID: ids[0])
        // The process dies before the work runs: the next launch drains it.
        try await fixture.store.close()
        let reopened = try FeedLibraryStore(url: fixture.url)
        #expect(await reopened.isServerLibrary)
        let worker = MediaDownloadWorker(store: reopened)
        try await worker.cleanCancelledFiles()
        try await FeedDeletionCoordinator(store: reopened, retirePlayback: { _ in }, retireDownloads: { _ in }).resume().value
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(try await reopened.pendingEffects().isEmpty)
        try await reopened.close()
        try? FileManager.default.removeItem(at: fixture.directory)
    }
}

extension FeedLibraryStore {
    /// Marks an episode downloaded at `file` (download bookkeeping: device-only, `.local`).
    func attachDownloadForTesting(_ id: Int64, file: URL) throws {
        try write(.local) {
            guard var episode = try loadEpisode(id) else { return }
            episode.userState.localFileURL = file.path; episode.userState.isDownloaded = true
            try saveEpisode(episode, feedID: feedID(forEpisode: id))
        }
    }
}
