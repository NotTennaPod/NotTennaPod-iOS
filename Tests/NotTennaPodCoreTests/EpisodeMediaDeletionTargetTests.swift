import Foundation
import Testing
import Synchronization
@testable import NotTennaPodCore

@MainActor @Suite struct EpisodeMediaDeletionTargetTests {
    private final class Engine: PlaybackEngine {
        var reading: PlaybackEngineReading?
        var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
        var unloads = 0
        func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {}
        func play(commandID: UUID) {}
        func pause(commandID: UUID) {}
        func seek(to positionMilliseconds: Int64, commandID: UUID) {}
        func setSpeed(_ speed: Float, commandID: UUID) throws {}
        func unload() { unloads += 1 }
    }
    private func remote(_ body: (FeedLibraryStore, LibraryFeed, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DeletionTarget-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let feed = try await store.insert(.init(feed: .init(format: .rss, episodes: (1...2).map {
            .init(identifier: "\($0)", title: "Episode \($0)", media: .init(url: "https://example.org/\($0)", size: 3, durationMilliseconds: 120000))
        }), source: "https://example.org/feed", responseURL: URL(string: "https://example.org/feed")!, validator: nil, permanentRedirectURL: nil))
        for episode in feed.episodes {
            let file = root.appendingPathComponent("\(episode.id).media")
            try Data([1, 2, 3]).write(to: file)
            try await store.updateEpisode(id: episode.id) { $0.userState.localFileURL = file.path; $0.userState.isDownloaded = true }
        }
        _ = try await store.enqueue(feed.episodes.map(\.id))
        try await body(store, feed, root)
        try await store.close()
    }

    @Test(arguments: [0, 1, 2, 3, 4]) func staleRemoteIdentityHasNoSideEffects(_ change: Int) async throws {
        try await remote { store, feed, root in
            let id = feed.episodes[0].id
            let target = try #require(try await store.snapshot().deletionTargets[id])
            let playback = PlaybackCoordinator(store: store, engine: Engine())
            try await playback.select(episodeID: id, play: false)
            switch change {
            case 0: _ = try await store.updateFeedDownloadURL(original: feed.source, updated: "https://replacement.example/feed")
            case 1: try await store.updateEpisode(id: id) { $0.details.media?.url = "https://replacement.example/media" }
            case 2: try await store.updateEpisode(id: id) { $0.userState.localFileURL = root.appendingPathComponent("replacement.media").path }
            case 3: try await store.updateEpisode(id: id) { $0.details.media = nil }
            default: try await store.updateEpisode(id: id) { $0.userState.localFileURL = nil }
            }
            let before = try await store.snapshot(), effects = try await store.pendingEffects()
            let selection = try await store.playbackSelectionEpisodeID()
            #expect(try await playback.deleteDownloadedMedia(target: target, deleteRemovesFromQueue: true) == .stale)
            #expect(try await store.snapshot() == before)
            #expect(try await store.pendingEffects() == effects)
            #expect(try await store.playbackSelectionEpisodeID() == selection)
            #expect(playback.episode?.id == id)
            #expect(try Data(contentsOf: root.appendingPathComponent("\(id).media")) == Data([1, 2, 3]))
        }
    }

    @Test func remoteAdmissionUsesRawUnicodeAndNilIdentity() async throws {
        try await remote { store, feed, _ in
            let id = feed.episodes[0].id
            try await store.updateEpisode(id: id) { $0.details.media?.url = "https://example.org/caf\u{e9}" }
            let target = try #require(try await store.snapshot().deletionTargets[id])
            try await store.updateEpisode(id: id) { $0.details.media?.url = "https://example.org/cafe\u{301}" }
            #expect(try await store.requestMediaDeletion(target: target) == .stale)
            let wrongFeed = EpisodeMediaDeletionTarget(episodeID: id, feedID: feed.id + 99, source: feed.source, media: target.media)
            #expect(try await store.requestMediaDeletion(target: wrongFeed) == .stale)
            let removed = EpisodeMediaDeletionTarget(episodeID: 9999999, feedID: feed.id, source: feed.source, media: target.media)
            #expect(try await store.requestMediaDeletion(target: removed) == .stale)
        }
    }

    @Test func successfulRemoteDeletesCapturedFileAndPreservesSelectedB() async throws {
        try await remote { store, feed, root in
            let id = feed.episodes[0].id, other = feed.episodes[1].id
            let target = try #require(try await store.snapshot().deletionTargets[id])
            let playback = PlaybackCoordinator(store: store, engine: Engine())
            try await playback.select(episodeID: other, play: false)
            let selected = try await store.playbackSelectionEpisodeID()
            let downloads = DownloadCoordinator(store: store, directory: root.appendingPathComponent("downloads"), network: .init(startMonitoring: false), preferences: { var p = DownloadPreferences(); p.deleteRemovesFromQueue = true; return p })
            #expect(try await downloads.deleteDownloadedMedia(target: target, playback: playback) == .deleted)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("\(id).media").path))
            #expect(try Data(contentsOf: root.appendingPathComponent("\(other).media")) == Data([1, 2, 3]))
            #expect(try await store.queue().map(\.id) == [other])
            #expect(try await store.playbackSelectionEpisodeID() == selected && playback.episode?.id == other)
            #expect(try await store.episode(id: id)?.userState.isDownloaded == false)
            #expect(try await store.requestMediaDeletion(target: target) == .stale)
            await downloads.stop()
        }
    }

    @Test func failedRemoteTransactionKeepsFileQueueSelectionAndEffects() async throws {
        try await remote { store, feed, root in
            let id = feed.episodes[0].id, playback = PlaybackCoordinator(store: store, engine: Engine())
            try await playback.select(episodeID: id, play: false)
            let target = try #require(try await store.snapshot().deletionTargets[id])
            let before = try await store.snapshot(), effects = try await store.pendingEffects(), selection = try await store.playbackSelectionEpisodeID()
            let db = try LibrarySQLite(url: root.appendingPathComponent("library.sqlite"))
            try db.execute("CREATE TRIGGER reject_deletion BEFORE UPDATE ON episodes BEGIN SELECT RAISE(ABORT, 'deletion failure'); END")
            await #expect(throws: (any Error).self) { try await playback.deleteDownloadedMedia(target: target, deleteRemovesFromQueue: true) }
            #expect(try await store.snapshot() == before)
            #expect(try await store.pendingEffects() == effects)
            #expect(try await store.playbackSelectionEpisodeID() == selection && playback.episode?.id == id)
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(id).media").path))
            try db.close()
        }
    }

    private func local(_ body: (FeedLibraryStore, LocalFolderScanContext, EpisodeMediaDeletionTarget, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalDeletionTarget-\(UUID())")
        let directory = root.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = directory.appendingPathComponent("episode.mp3")
        try Data([1, 2, 3]).write(to: file)
        let documents = LocalFolderDocuments(bookmark: try LocalFolderDocuments.makeBookmark(directory: directory))
        let entries = try await documents.entries()
        let receipts = entries.compactMap { entry in entry.resourceIdentity.map { LocalDocumentResourceReceipt(filename: entry.name, identity: $0) } }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let context = try await store.registerLocalFolder(title: "Local", directoryIdentity: directory.absoluteString, bookmark: documents.bookmark)
        let updated = try await store.applyLocalFolderScan(.init(format: .rss, episodes: [.init(identifier: "one", title: "One", link: "episode.mp3", media: .init(url: file.absoluteString, size: 3))]), context: context, documentResources: receipts)
        let id = updated.feed.episodes[0].id
        _ = try await store.enqueue([id])
        let target = try #require(try await store.snapshot().deletionTargets[id])
        try await body(store, context, target, file)
        try await store.close()
    }

    @Test func scanAndBookmarkRenewalRetainDeletionRegistrationButReconnectDoesNot() async throws {
        try await local { store, context, target, _ in
            #expect(try await store.admitsMediaDeletion(target))
            let scan = try await store.beginLocalFolderScan(feedID: context.feed.id)
            #expect(try await store.admitsMediaDeletion(target))
            #expect(scan.link.generation != context.link.generation)
            _ = try await store.recordLocalFolderFailure(.init(message: "controlled failure"), context: scan, date: .now)
            #expect(try await store.admitsMediaDeletion(target))
            _ = try await store.reconnectLocalFolder(feedID: context.feed.id, directoryIdentity: context.link.directoryIdentity, bookmark: context.link.bookmark)
            #expect(try await !store.admitsMediaDeletion(target))
            #expect(try await store.recordLocalMediaDeletion(target: target, removeFromQueue: true) == .stale)
            #expect(try await store.queue().map(\.id) == [target.episodeID])
        }
    }

    @Test func sameNameSameSizeProviderReplacementIsNotDeleted() async throws {
        try await local { store, _, target, file in
            guard case .local(let reference) = target.media else { Issue.record("expected local target"); return }
            let replacement = file.deletingLastPathComponent().appendingPathComponent("replacement")
            try Data([7, 8, 9]).write(to: replacement)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: replacement, to: file)
            #expect(try await store.admitsMediaDeletion(target)) // Database still describes the old scan.
            let before = try await store.snapshot()
            let playback = PlaybackCoordinator(store: store, engine: Engine())
            let coordinator = LocalFolderCoordinator(store: store, refresh: { _ in Issue.record("stale target must not refresh"); return .superseded })
            #expect(try await coordinator.deleteMedia(target: target, playback: playback, removeFromQueue: true) == .stale)
            #expect(try Data(contentsOf: file) == Data([7, 8, 9]))
            #expect(try await store.snapshot() == before)
            #expect(reference.resourceIdentity != nil)
        }
    }

    @Test func capturedLocalDeletionRemovesOnlyOriginalChild() async throws {
        try await local { store, _, target, file in
            let keep = file.deletingLastPathComponent().appendingPathComponent("keep.mp3")
            try Data([4, 5]).write(to: keep)
            let playback = PlaybackCoordinator(store: store, engine: Engine())
            let coordinator = LocalFolderCoordinator(store: store, refresh: { _ in .superseded })
            #expect(try await coordinator.deleteMedia(target: target, playback: playback, removeFromQueue: true) == .deleted)
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(try Data(contentsOf: keep) == Data([4, 5]))
            #expect(try await store.queue().isEmpty == true)
        }
    }

    @Test func legacyRegistrationDecodesWithoutPretendingToHaveResourceIdentity() throws {
        let generation = UUID()
        let json = "{\"feedID\":1,\"directoryIdentity\":\"file:///old\",\"bookmark\":\"AQ==\",\"generation\":\"\(generation)\"}"
        let link = try JSONDecoder().decode(LocalFolderLink.self, from: Data(json.utf8))
        #expect(link.registrationID == nil && link.deletionRegistrationID == generation)
        #expect(link.documentResources == nil)
        let reference = LocalDocumentReference(folder: link, filename: "one.mp3", identity: "file:///old/one.mp3", size: 3)
        #expect(!reference.isSameDeletionDocument(as: reference))
    }
    @Test(arguments: [false, true]) func unavailableReceiptAndFailedProviderLeaveStateUntouched(invalidProvider: Bool) async throws {
        try await local { store, _, target, file in
            guard case .local(let old) = target.media else { Issue.record("expected local"); return }
            let folder = LocalFolderLink(feedID: old.folder.feedID, directoryIdentity: old.folder.directoryIdentity,
                bookmark: invalidProvider ? Data([0, 1, 2]) : old.folder.bookmark, generation: old.folder.generation,
                registrationID: old.folder.deletionRegistrationID, documentResources: old.folder.documentResources)
            let reference = LocalDocumentReference(folder: folder, filename: old.filename, identity: old.identity, size: old.size,
                resourceIdentity: invalidProvider ? old.resourceIdentity : nil)
            let captured = EpisodeMediaDeletionTarget(episodeID: target.episodeID, feedID: target.feedID, source: target.source, media: .local(reference))
            let playback = PlaybackCoordinator(store: store, engine: Engine())
            try await playback.select(episodeID: target.episodeID, play: false)
            let before = try await store.snapshot(), selection = try await store.playbackSelectionEpisodeID()
            let coordinator = LocalFolderCoordinator(store: store, refresh: { _ in Issue.record("unsuccessful deletion must not refresh"); return .superseded })
            if invalidProvider {
                await #expect(throws: (any Error).self) { try await coordinator.deleteMedia(target: captured, playback: playback, removeFromQueue: true) }
            } else {
                await #expect(throws: LocalFolderDocuments.Failure.resourceIdentityUnavailable) {
                    try await coordinator.deleteMedia(target: captured, playback: playback, removeFromQueue: true)
                }
            }
            #expect(try await store.snapshot() == before)
            #expect(try await store.playbackSelectionEpisodeID() == selection)
            #expect(playback.episode?.id == target.episodeID)
            #expect(try Data(contentsOf: file) == Data([1, 2, 3]))
        }
    }

    @Test func missingOriginalLocalFileCompletesWithoutRetargeting() async throws {
        try await local { store, _, target, file in
            try FileManager.default.removeItem(at: file)
            let playback = PlaybackCoordinator(store: store, engine: Engine())
            let coordinator = LocalFolderCoordinator(store: store, refresh: { _ in .superseded })
            #expect(try await coordinator.deleteMedia(target: target, playback: playback, removeFromQueue: true) == .deleted)
            #expect(try await store.queue().isEmpty == true)
        }
    }

    @Test func legacyReceiptFailureRecoversThroughNormalScanAndNewEligibleAction() async throws {
        try await local { store, context, target, file in
            let root = file.deletingLastPathComponent().deletingLastPathComponent()
            let db = try LibrarySQLite(url: root.appendingPathComponent("library.sqlite"))
            defer { try? db.close() }
            let row = try #require(db.rows("SELECT record FROM local_folder_links WHERE feed_id = ?", [.integer(context.feed.id)]).first)
            guard case .blob(let bytes) = row[0] else { Issue.record("Expected persisted link"); return }
            var legacy = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            legacy.removeValue(forKey: "documentResources")
            legacy.removeValue(forKey: "registrationID")
            try db.execute("UPDATE local_folder_links SET record = ? WHERE feed_id = ?",
                [.blob(try JSONSerialization.data(withJSONObject: legacy)), .integer(context.feed.id)])
            // Match the authoritative document identity a normal older scan
            // would have saved. Bookmark resolution may canonicalize /var to
            // /private/var; constructing a URL here would change raw identity.
            let entries = try await LocalFolderDocuments(bookmark: context.link.bookmark).entries()
            let observed = try #require(entries.first { $0.name == "episode.mp3" })
            try await store.updateEpisode(id: target.episodeID) {
                $0.details.media?.url = observed.identity
                $0.details.media?.durationMilliseconds = 120_000
                $0.userState.positionMilliseconds = 90_000
            }
            let oldCapture = try #require(try await store.snapshot().deletionTargets[target.episodeID])
            let playback = PlaybackCoordinator(store: store, engine: Engine())
            let refresh = LocalFeedRefreshService(store: store, open: { link in
                // Real coordinated enumeration/receipt capture; the tiny controlled
                // file uses an injected metadata reader, not an audio decoder.
                try await LocalFolderDocuments(bookmark: link.bookmark).scanInput(readMetadata: { _, checkCancellation in
                    try checkCancellation()
                    return .init(title: "One", durationMilliseconds: 120_000)
                })
            })
            let coordinator = LocalFolderCoordinator(store: store, refresh: { id in
                try await refresh.refresh(feedID: id, description: "Local", author: "Local")
            })
            let before = try await store.snapshot(), effects = try await store.pendingEffects()
            let selection = try await store.playbackSelectionEpisodeID()
            await #expect(throws: LocalFolderDocuments.Failure.resourceIdentityUnavailable) {
                try await coordinator.deleteMedia(target: oldCapture, playback: playback, removeFromQueue: true)
            }
            #expect(try await store.snapshot() == before)
            #expect(try await store.pendingEffects() == effects)
            #expect(try await store.playbackSelectionEpisodeID() == selection)
            #expect(try Data(contentsOf: file) == Data([1, 2, 3]))
            guard case .updated = try await refresh.refresh(feedID: context.feed.id, description: "Local", author: "Local") else {
                Issue.record("Normal scan must restore authoritative receipts"); return
            }
            guard case .local(let prior) = oldCapture.media else { Issue.record("Expected local legacy target"); return }
            let current = try #require(try await store.localDocument(episodeID: target.episodeID))
            #expect(current.isSameDeletionLocation(as: prior))
            #expect(prior.resourceIdentity == nil && current.resourceIdentity != nil)
            // An old timer never upgrades its captured receipt after recovery.
            await #expect(throws: LocalFolderDocuments.Failure.resourceIdentityUnavailable) {
                try await coordinator.deleteMedia(target: oldCapture, playback: playback, removeFromQueue: true)
            }
            let recovered = try await store.snapshot()
            let newCapture = try #require(recovered.deletionTargets[target.episodeID])
            guard case .local(let reference) = newCapture.media else { Issue.record("Expected local target"); return }
            #expect(reference.resourceIdentity != nil)
            let episode = try #require(try await store.episode(id: target.episodeID))
            let model = EpisodeActionModel(item: .init(episode: episode, local: true, queued: true))
            let downloads = DownloadCoordinator(store: store, directory: root.appendingPathComponent("downloads"),
                network: .init(startMonitoring: false), preferences: {
                    var p = DownloadPreferences(); p.autoDelete = true; p.autoDeleteLocal = true; return p
                })
            var outcomes: [EpisodeMediaDeletionOutcome] = []
            let timer = downloads.deleteAfterMark(model: model, target: newCapture, wait: {}) { captured in
                let outcome = try await coordinator.deleteMedia(target: captured, playback: playback, removeFromQueue: true)
                outcomes.append(outcome); return outcome
            }
            await timer.value
            #expect(outcomes == [.deleted])
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(try await store.queue().isEmpty == true)
            #expect(try await store.playbackSelectionEpisodeID() == selection)
            await downloads.stop()
        }
    }

    private final class HeldWriter: NSObject, NSFilePresenter, Sendable {
        typealias Writer = @Sendable ((@Sendable () -> Void)?) -> Void
        let presentedItemURL: URL?
        let presentedItemOperationQueue = OperationQueue()
        private let writer = Mutex<Writer?>(nil)
        var waiting: Bool { writer.withLock { $0 != nil } }
        init(_ url: URL) { presentedItemURL = url; super.init(); presentedItemOperationQueue.maxConcurrentOperationCount = 1 }
        func relinquishPresentedItem(toWriter pending: @escaping Writer) { writer.withLock { $0 = pending } }
        func release() { writer.withLock { let value = $0; $0 = nil; return value }?(nil) }
    }

    @Test func reconnectWhileProviderIsWaitingCannotEraseReplacementOrItsSelection() async throws {
        try await local { store, context, target, file in
            let presenter = HeldWriter(file)
            NSFileCoordinator.addFilePresenter(presenter)
            defer { presenter.release(); NSFileCoordinator.removeFilePresenter(presenter) }
            let playback = PlaybackCoordinator(store: store, engine: Engine())
            let coordinator = LocalFolderCoordinator(store: store, refresh: { _ in Issue.record("stale commit must not refresh"); return .superseded })
            let deletion = Task { try await coordinator.deleteMedia(target: target, playback: playback, removeFromQueue: true) }
            defer { deletion.cancel() }
            let deadline = ContinuousClock.now + .seconds(5)
            while !presenter.waiting, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(presenter.waiting)
            let replacementFolder = file.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("reconnected")
            try FileManager.default.createDirectory(at: replacementFolder, withIntermediateDirectories: true)
            let replacement = replacementFolder.appendingPathComponent(file.lastPathComponent)
            try Data([7, 8, 9]).write(to: replacement)
            _ = try await store.reconnectLocalFolder(feedID: context.feed.id, directoryIdentity: replacementFolder.absoluteString,
                bookmark: LocalFolderDocuments.makeBookmark(directory: replacementFolder))
            try await store.updateEpisode(id: target.episodeID) { $0.details.media?.url = replacement.absoluteString; $0.userState.isFavorite = true }
            let before = try await store.snapshot(), effects = try await store.pendingEffects()
            presenter.release()
            #expect(try await deletion.value == .stale)
            #expect(try await store.snapshot() == before)
            #expect(try await store.pendingEffects() == effects)
            #expect(try Data(contentsOf: replacement) == Data([7, 8, 9]))
            // I/O already admitted against the captured grant may remove only
            // that old resource; the current database/queue remains untouched.
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func localCommitFailureReportsFailureAndPreservesDatabaseState() async throws {
        try await local { store, _, target, file in
            let playback = PlaybackCoordinator(store: store, engine: Engine())
            let before = try await store.snapshot()
            let root = file.deletingLastPathComponent().deletingLastPathComponent()
            let db = try LibrarySQLite(url: root.appendingPathComponent("library.sqlite"))
            // The local episode record itself is unchanged by the commit (and so not rewritten); fail its queue removal.
            try db.execute("CREATE TRIGGER reject_local_delete BEFORE DELETE ON queue BEGIN SELECT RAISE(ABORT, 'local commit failure'); END")
            let coordinator = LocalFolderCoordinator(store: store, refresh: { _ in Issue.record("failed commit must not refresh"); return .superseded })
            await #expect(throws: (any Error).self) { try await coordinator.deleteMedia(target: target, playback: playback, removeFromQueue: true) }
            #expect(try await store.snapshot() == before)
            // Provider I/O and SQLite are not one distributed transaction. The
            // committed unlink is preserved and the metadata failure is surfaced.
            #expect(!FileManager.default.fileExists(atPath: file.path))
            try db.close()
        }
    }

}
