import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.timeLimit(.minutes(1))) @MainActor
struct RemovedEpisodeEffectsTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private enum Failure: Error { case injected }

    private func fetched(_ names: [String], source: String = "https://example.test/feed") -> FetchedFeed {
        .init(feed: .init(format: .rss, title: "Removal", episodes: names.map {
            .init(identifier: $0, title: $0, publicationDate: now,
                  media: .init(url: "https://example.test/\($0).mp3", size: 3, durationMilliseconds: 30_000))
        }), source: source, responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil)
    }

    private func fixture(_ body: @MainActor (FeedLibraryStore, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RemovedEpisodes-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        do { try await body(store, root); try await store.close() }
        catch { try? await store.close(); throw error }
    }

    private func remove(_ names: [String] = [], from feed: LibraryFeed, store: FeedLibraryStore) async throws -> FeedRefreshResult {
        var options = FeedRefreshOptions(now: now); options.removeUnlistedItems = true
        return try await store.applyRefresh(fetched(names, source: feed.source), feedID: feed.id, options: options)
    }

    private func pending(_ store: FeedLibraryStore) async throws -> [PendingFeedLibraryEffect] {
        try await store.pendingEffects().filter { if case .removeEpisodes = $0.effect.kind { true } else { false } }
    }

    private func owner(_ store: FeedLibraryStore) -> FeedDeletionCoordinator {
        .init(store: store, retirePlayback: { _ in }, retireDownloads: { _ in })
    }

    private func download(_ id: Int64, store: FeedLibraryStore, root: URL) async throws -> LibraryDownloadJob {
        let queued = try #require(try await store.requestDownload(episodeID: id, directory: root, now: now))
        let active = try #require(try await store.beginDownloadAttempt(id: queued.id, now: now))
        try Data([1, 2, 3]).write(to: active.destination)
        #expect(try await store.attachDownloadFile(id: active.id, attempt: active.attempts))
        #expect(try await store.completeDownload(id: active.id, attempt: active.attempts, now: now))
        return active
    }

    private func makeLegacy(_ effect: PendingFeedLibraryEffect, root: URL) throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(effect.effect)) as? [String: Any])
        object.removeValue(forKey: "removedEpisodeCleanup")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(FeedLibraryEffect.self, from: data)
        #expect(decoded.removedEpisodeCleanup == nil && decoded.kind == effect.effect.kind)
        let db = try LibrarySQLite(url: root.appendingPathComponent("library.sqlite"))
        defer { try? db.close() }
        try db.execute("UPDATE pending_effects SET record = ? WHERE id = ?", [.blob(data), .integer(effect.id)])
    }

    @Test func removalSurvivesRestartAndRetiresQueuePlaybackLogsMediaTranscriptAndSyncOnce() async throws {
        try await fixture { store, root in
            let feed = try await store.insert(fetched(["a", "b", "c"]))
            let a = feed.episodes[0], b = feed.episodes[1], c = feed.episodes[2]
            let job = try await download(a.id, store: store, root: root)
            let transcript = URL(fileURLWithPath: job.destination.path + ".transcript")
            try Data([7]).write(to: transcript)
            _ = try await store.enqueue([c.id, b.id])
            _ = try await store.beginPlayback(episodeID: a.id)
            try await store.selectSynchronizationAccount(UUID())
            let result = try await remove(["b", "c"], from: feed, store: store)
            #expect(result.removedEpisodes.map(\.id) == [a.id])
            #expect(try await store.playbackSelectionEpisodeID() == nil)
            #expect(try await store.playbackSession() == nil)
            #expect(try await store.queue().map(\.id) == [c.id, b.id])
            #expect(try await store.downloadJobs(activeOnly: false).isEmpty)
            #expect(try await store.downloadLog().allSatisfy { $0.episodeID != a.id })
            #expect(try await store.synchronizationQueue().isEmpty)
            let effect = try #require(try await pending(store).first)
            #expect(effect.effect.kind == .removeEpisodes(result.removedEpisodes))
            #expect(effect.effect.removedEpisodeCleanup?.downloadJobIDs == [job.id])
            #expect(FileManager.default.fileExists(atPath: job.destination.path))
            try await store.close()
            let reopened = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
            let events = Mutex<[String]>([])
            let recipient = FeedDeletionCoordinator(store: reopened, retirePlayback: { ids in
                #expect(ids == [a.id]); events.withLock { $0.append("playback") }
            }, retireDownloads: { ids in
                #expect(ids == [job.id]); events.withLock { $0.append("downloads") }
            }, removeFile: { file in
                events.withLock { $0.append("file") }; try FeedDeletionCoordinator.unlinkDownload(file)
            })
            try await recipient.resume().value; try await recipient.resume().value
            #expect(events.withLock { $0 } == ["playback", "downloads", "file"])
            #expect(!FileManager.default.fileExists(atPath: job.destination.path))
            #expect(!FileManager.default.fileExists(atPath: transcript.path))
            #expect(try await pending(reopened).isEmpty)
            let changes = try await reopened.synchronizationQueue()
            #expect(changes.count == 1)
            if case .episode(let action) = changes.first?.value {
                #expect(action.action == .delete && action.guid == a.details.identifier && action.podcast == feed.source)
            } else { Issue.record("Expected one DELETE action") }
            let db = try LibrarySQLite(url: root.appendingPathComponent("library.sqlite"))
            #expect(try db.rows("SELECT position FROM queue ORDER BY position").compactMap { $0[0].integer } == [0, 1])
            try db.close(); try await reopened.close()
        }
    }

    @Test func partialPendingQueueIntentKeepsSurvivorsAndCannotResurrectRemovedEpisode() async throws {
        try await fixture { store, _ in
            let feed = try await store.insert(fetched(["a"]))
            try await store.updatePreferences(feedID: feed.id) { $0.newEpisodesAction = .queue }
            _ = try await store.applyRefresh(fetched(["a", "b", "c"]), feedID: feed.id)
            _ = try await remove(["a", "c"], from: feed, store: store)
            _ = try await store.consumeFeedRefreshQueueEffects()
            #expect(try await store.queue().map(\.details.identifier) == ["c"])
            try await owner(store).resume().value
            #expect(try await pending(store).isEmpty)
        }
    }

    @Test func localScanStopsPlaybackAndPreservesProviderDocumentsWithNoDeleteSync() async throws {
        try await fixture { store, root in
            let file = root.appendingPathComponent("provider.mp3"); try Data([4]).write(to: file)
            let context = try await store.registerLocalFolder(title: "Folder", directoryIdentity: "provider", bookmark: Data([1]))
            let snapshot = ParsedFeed(format: .rss, episodes: [.init(identifier: "local", title: "provider.mp3", link: "provider.mp3",
                publicationDate: now, media: .init(url: file.absoluteString, size: 1))])
            let feed = try await store.applyLocalFolderScan(snapshot, context: context).feed
            let id = try #require(feed.episodes.first?.id)
            try await store.updateEpisode(id: id) { $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path }
            let engine = Engine(), playback = PlaybackCoordinator(store: store, engine: engine)
            try await playback.select(episodeID: id)
            try await store.selectSynchronizationAccount(UUID())
            let scan = try await store.beginLocalFolderScan(feedID: feed.id)
            _ = try await store.applyLocalFolderScan(.init(format: .rss), context: scan)
            let removal = try #require(try await pending(store).first?.effect.removedEpisodeCleanup)
            #expect(removal.files.isEmpty && removal.downloadedEpisodes.isEmpty && !removal.synchronize)
            let recipient = FeedDeletionCoordinator(store: store, retirePlayback: { try await playback.retireDeletedEpisodes($0) },
                retireDownloads: { #expect($0.isEmpty) }, removeFile: { _ in Issue.record("Provider document must never be unlinked") })
            try await recipient.resume().value
            #expect(playback.episode == nil && playback.phase == .idle && engine.loadedID == nil)
            #expect(try await store.playbackSelectionEpisodeID() == nil)
            #expect(try await store.synchronizationQueue().isEmpty)
            #expect(try Data(contentsOf: file) == Data([4]))
            #expect(try await pending(store).isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func remotePlaybackRetiresOnlyTheRemovedCurrentIdentity(replaced: Bool) async throws {
        try await fixture { store, _ in
            let feed = try await store.insert(fetched(["a", "b"]))
            let engine = Engine(), playback = PlaybackCoordinator(store: store, engine: engine)
            let first = feed.episodes[0], other = feed.episodes[1]
            try await playback.select(episodeID: first.id)
            _ = try await remove(["b"], from: feed, store: store)
            if replaced { try await playback.select(episodeID: other.id) }
            let unloads = engine.unloads
            let recipient = FeedDeletionCoordinator(store: store,
                retirePlayback: { try await playback.retireDeletedEpisodes($0) }, retireDownloads: { _ in })
            try await recipient.resume().value
            #expect(playback.episode?.id == (replaced ? other.id : nil))
            #expect(engine.loadedID == (replaced ? other.id : nil))
            #expect(engine.unloads == unloads + (replaced ? 0 : 1))
            #expect(try await store.playbackSelectionEpisodeID() == (replaced ? other.id : nil))
        }
    }

    @Test func failedSwitchStillReportsStorageFailureWhenOldEpisodeExists() async throws {
        try await fixture { store, root in
            let feed = try await store.insert(fetched(["a", "b"]))
            let playback = PlaybackCoordinator(store: store, engine: Engine())
            try await playback.select(episodeID: feed.episodes[0].id)
            let session = try await store.playbackSession()
            let db = try LibrarySQLite(url: root.appendingPathComponent("library.sqlite"))
            try db.execute("CREATE TRIGGER fail_switch BEFORE DELETE ON playback_session BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            await #expect(throws: FeedLibraryError.self) { try await playback.select(episodeID: feed.episodes[1].id) }
            #expect(playback.episode?.id == feed.episodes[0].id && playback.phase == .failed)
            #expect(try await store.playbackSession() == session)
            #expect(try await store.episode(id: feed.episodes[0].id) != nil)
            try db.execute("DROP TRIGGER fail_switch"); try db.close()
        }
    }

    @Test func cancelledSwitchDoesNotTreatMissingOldEpisodeAsSuccessfulReplacement() async throws {
        try await fixture { store, _ in
            let feed = try await store.insert(fetched(["a", "b"]))
            let cancel = Mutex(false), first = feed.episodes[0], other = feed.episodes[1]
            let playback = PlaybackCoordinator(store: store, engine: Engine(), preferences: { episode in
                if episode.id == first.id && cancel.withLock({ $0 }) { withUnsafeCurrentTask { $0?.cancel() } }
                return .init()
            })
            try await playback.select(episodeID: first.id)
            _ = try await remove(["b"], from: feed, store: store)
            cancel.withLock { $0 = true }
            await #expect(throws: CancellationError.self) { try await playback.select(episodeID: other.id) }
            #expect(playback.episode?.id == first.id)
            #expect(try await store.playbackSelectionEpisodeID() == nil)
            #expect(try await pending(store).count == 1)
        }
    }

    @Test func sharedURLCancelsCapturedJobButReplacementGetsAnotherFileAndSurvives() async throws {
        try await fixture { store, root in
            let removed = try await store.insert(fetched(["a"]))
            let other = try await store.insert(fetched(["a"], source: "https://example.test/other"))
            let id = other.episodes[0].id
            let job = try #require(try await store.requestDownload(episodeID: id, directory: root))
            let active = try #require(try await store.beginDownloadAttempt(id: job.id))
            try Data([1]).write(to: job.destination)
            #expect(try await store.attachDownloadFile(id: job.id, attempt: active.attempts))
            _ = try await remove(from: removed, store: store)
            #expect(try await store.downloadJob(id: job.id)?.state == .cancelled)
            #expect(try await store.completeDownload(id: job.id, attempt: active.attempts) == false)
            let replacement = try #require(try await store.requestDownload(episodeID: id, directory: root))
            #expect(replacement.id != job.id && replacement.destination != job.destination)
            try Data([9]).write(to: replacement.destination)
            let recipient = FeedDeletionCoordinator(store: store, retirePlayback: { _ in }, retireDownloads: { ids in
                #expect(ids == [job.id] && !ids.contains(replacement.id))
            })
            try await recipient.resume().value
            #expect(!FileManager.default.fileExists(atPath: job.destination.path))
            #expect(try Data(contentsOf: replacement.destination) == Data([9]))
            #expect(try await store.downloadJob(id: replacement.id)?.state == .waiting)
            #expect(try await store.episode(id: id) != nil)
        }
    }

    @Test func staleCleanupDoesNotUnlinkAFileNowOwnedByAnotherDownloadedEpisode() async throws {
        try await fixture { store, root in
            let feed = try await store.insert(fetched(["a", "b"]))
            let file = try await download(feed.episodes[0].id, store: store, root: root).destination
            _ = try await remove(["b"], from: feed, store: store)
            try await store.updateEpisode(id: feed.episodes[1].id) { $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path }
            try await owner(store).resume().value
            #expect(try Data(contentsOf: file) == Data([1, 2, 3]))
            #expect(try await pending(store).isEmpty)
        }
    }

    @Test(arguments: ["playback", "downloads", "file"])
    func failureRetainsWorkAndRestartRetriesWithoutDuplicatingSync(stage: String) async throws {
        try await fixture { store, root in
            let feed = try await store.insert(fetched(["a"]))
            let file = try await download(feed.episodes[0].id, store: store, root: root).destination
            try await store.selectSynchronizationAccount(UUID())
            _ = try await remove(from: feed, store: store)
            let recipient = FeedDeletionCoordinator(store: store, retirePlayback: { _ in if stage == "playback" { throw Failure.injected } },
                retireDownloads: { _ in if stage == "downloads" { throw Failure.injected } },
                removeFile: { _ in throw Failure.injected })
            await #expect(throws: RemovedEpisodeEffectsError.self) { try await recipient.resume().value }
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(try await pending(store).count == 1)
            #expect(try await store.synchronizationQueue().isEmpty)
            try await store.close()
            let reopened = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
            try await owner(reopened).resume().value; try await owner(reopened).resume().value
            #expect(try await reopened.synchronizationQueue().count == 1)
            #expect(try await pending(reopened).isEmpty)
            try await reopened.close()
        }
    }

    @Test(arguments: ["replacement", "logout", "connectedLater", "archived", "notSubscribed"])
    func synchronizationUsesCommittedAccountAndSubscriptionContext(scenario: String) async throws {
        try await fixture { store, root in
            let feed = try await store.insert(fetched(["a"]))
            _ = try await download(feed.episodes[0].id, store: store, root: root)
            if scenario != "connectedLater" { try await store.selectSynchronizationAccount(UUID()) }
            if scenario == "archived" { try await store.updatePreferences(feedID: feed.id) { $0.subscriptionState = .archived } }
            if scenario == "notSubscribed" { try await store.updatePreferences(feedID: feed.id) { $0.subscriptionState = .notSubscribed } }
            _ = try await remove(from: feed, store: store)
            if scenario == "replacement" || scenario == "connectedLater" { try await store.selectSynchronizationAccount(UUID()) }
            if scenario == "logout" { try await store.selectSynchronizationAccount(nil) }
            try await owner(store).resume().value
            #expect(try await store.synchronizationQueue().count == (scenario == "archived" ? 1 : 0))
            #expect(try await pending(store).isEmpty)
        }
    }

    @Test func sidecarWriteFailureRollsBackRemovalJobsQueueAndPlayback() async throws {
        try await fixture { store, root in
            let feed = try await store.insert(fetched(["a", "b"]))
            let job = try #require(try await store.requestDownload(episodeID: feed.episodes[0].id, directory: root))
            _ = try await store.beginPlayback(episodeID: feed.episodes[0].id)
            let before = try await store.snapshot(), effects = try await store.pendingEffects(), session = try await store.playbackSession()
            let db = try LibrarySQLite(url: root.appendingPathComponent("library.sqlite"))
            try db.execute("CREATE TRIGGER fail_removal BEFORE INSERT ON pending_effects BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            await #expect(throws: FeedLibraryError.self) { _ = try await remove(["b"], from: feed, store: store) }
            #expect(try await store.snapshot() == before)
            #expect(try await store.pendingEffects() == effects)
            #expect(try await store.playbackSession() == session)
            #expect(try await store.downloadJob(id: job.id) == job)
            try db.execute("DROP TRIGGER fail_removal"); try db.close()
        }
    }

    @Test func syncCommitFailureRetainsEffectAfterUnlinkAndRetryCommitsExactlyOnce() async throws {
        try await fixture { store, root in
            let feed = try await store.insert(fetched(["a"]))
            let file = try await download(feed.episodes[0].id, store: store, root: root).destination
            try await store.selectSynchronizationAccount(UUID())
            _ = try await remove(from: feed, store: store)
            let db = try LibrarySQLite(url: root.appendingPathComponent("library.sqlite"))
            try db.execute("CREATE TRIGGER fail_sync BEFORE INSERT ON synchronization_outbox BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            await #expect(throws: RemovedEpisodeEffectsError.self) { try await owner(store).resume().value }
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(try await pending(store).count == 1)
            #expect(try await store.synchronizationQueue().isEmpty)
            try db.execute("DROP TRIGGER fail_sync"); try db.close()
            try await owner(store).resume().value; try await owner(store).resume().value
            #expect(try await store.synchronizationQueue().count == 1)
            #expect(try await pending(store).isEmpty)
        }
    }

    @Test func legacyMissingSidecarDoesNotAssignOldDeleteToCurrentAccount() async throws {
        try await fixture { store, root in
            let feed = try await store.insert(fetched(["a"]))
            let file = try await download(feed.episodes[0].id, store: store, root: root).destination
            _ = try await remove(from: feed, store: store)
            try makeLegacy(try #require(try await pending(store).first), root: root)
            try await store.selectSynchronizationAccount(UUID())
            try await owner(store).resume().value
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(try await pending(store).isEmpty)
            #expect(try await store.synchronizationQueue().isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func legacyOrphanUsesRecordedFeedContextOrRemainsDiagnosableWithoutBlockingOtherEffects(hasContext: Bool) async throws {
        try await fixture { store, root in
            let feed = try await store.insert(fetched(["a"]))
            let file = try await download(feed.episodes[0].id, store: store, root: root).destination
            _ = try await remove(from: feed, store: store)
            let orphan = try #require(try await pending(store).first)
            try makeLegacy(orphan, root: root)
            _ = try await store.requestFeedDeletion(feedID: feed.id)
            if !hasContext {
                for effect in try await store.pendingEffects() {
                    if case .deleteFeed = effect.effect.kind { try await store.acknowledgeEffect(id: effect.id) }
                }
            }
            let other = try await store.insert(fetched(["b"], source: "https://example.test/other"))
            let otherFile = try await download(other.episodes[0].id, store: store, root: root).destination
            _ = try await remove(from: other, store: store)
            if hasContext { try await owner(store).resume().value }
            else {
                await #expect(throws: RemovedEpisodeEffectsError.incomplete([.init(effectID: orphan.id, reason: .missingLegacyContext)])) {
                    try await owner(store).resume().value
                }
            }
            #expect(FileManager.default.fileExists(atPath: file.path) == !hasContext)
            #expect(!FileManager.default.fileExists(atPath: otherFile.path))
            #expect(try await pending(store).map(\.id) == (hasContext ? [] : [orphan.id]))
        }
    }

    @Test func cancellationBeforeUnlinkKeepsAcceptedEffectForNextResume() async throws {
        try await fixture { store, root in
            let feed = try await store.insert(fetched(["a"]))
            let file = try await download(feed.episodes[0].id, store: store, root: root).destination
            _ = try await remove(from: feed, store: store)
            let cancelOnce = Mutex(true)
            let recipient = FeedDeletionCoordinator(store: store, retirePlayback: { _ in
                if cancelOnce.withLock({ let cancel = $0; $0 = false; return cancel }) {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }, retireDownloads: { _ in })
            await #expect(throws: CancellationError.self) { try await recipient.resume().value }
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(try await pending(store).count == 1)
            try await recipient.resume().value
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(try await pending(store).isEmpty)
        }
    }

    @Test func recipientWaitsForActualDownloadWriterToRetireBeforeUnlink() async throws {
        try await fixture { store, root in
            let feed = try await store.insert(fetched(["a"]))
            let job = try #require(try await store.requestDownload(episodeID: feed.episodes[0].id, directory: root))
            let network = DownloadNetworkMonitor(startMonitoring: false)
            network.update(.init(connected: true, metered: false, cellular: false))
            let transfer = HeldTransfer()
            let worker = MediaDownloadWorker(store: store, transfer: transfer, network: network)
            let download = Task { try await worker.run(id: job.id) }
            defer { transfer.release(); download.cancel() }
            for await _ in transfer.started { break }
            _ = try await remove(from: feed, store: store)
            let unlinked = Mutex(false)
            let recipient = FeedDeletionCoordinator(store: store, retirePlayback: { _ in },
                retireDownloads: { try await worker.retireDeletedJobs($0) }, removeFile: { file in
                    unlinked.withLock { $0 = true }; try FeedDeletionCoordinator.unlinkDownload(file)
                })
            let removal = recipient.resume()
            for await _ in transfer.cancelled { break }
            #expect(!unlinked.withLock { $0 })
            #expect(FileManager.default.fileExists(atPath: job.destination.path))
            #expect(try await pending(store).count == 1)
            transfer.release()
            try await removal.value
            #expect(try await download.value == .interrupted)
            #expect(unlinked.withLock { $0 })
            #expect(!FileManager.default.fileExists(atPath: job.destination.path))
            #expect(try await store.downloadJob(id: job.id) == nil)
            #expect(try await pending(store).isEmpty)
        }
    }

    private final class HeldTransfer: MediaTransferring {
        private let continuation = Mutex<CheckedContinuation<MediaDownloadResult, any Error>?>(nil)
        private let start = AsyncStream<Void>.makeStream()
        private let cancellation = AsyncStream<Void>.makeStream()
        var started: AsyncStream<Void> { start.stream }
        var cancelled: AsyncStream<Void> { cancellation.stream }
        func download(_ input: MediaDownloadRequest,
                      progress: @escaping @Sendable (MediaDownloadProgress) -> Void) async throws -> MediaDownloadResult {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { pending in
                    continuation.withLock { $0 = pending }
                    start.continuation.yield(())
                }
            } onCancel: { cancellation.continuation.yield(()) }
        }
        func release() {
            let pending = continuation.withLock { let pending = $0; $0 = nil; return pending }
            pending?.resume(throwing: CancellationError())
        }
    }

    private final class Engine: PlaybackEngine {
        var reading: PlaybackEngineReading?
        var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
        var loadedID: Int64?
        var unloads = 0
        func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) { loadedID = episode.id }
        func play(commandID: UUID) {}
        func pause(commandID: UUID) {}
        func seek(to positionMilliseconds: Int64, commandID: UUID) {}
        func setSpeed(_ speed: Float, commandID: UUID) throws {}
        func unload() { loadedID = nil; reading = nil; unloads += 1 }
    }
}
