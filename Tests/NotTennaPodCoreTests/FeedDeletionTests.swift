import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.timeLimit(.minutes(1)))
struct FeedDeletionTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func fixture(_ suffix: String) -> FetchedFeed {
        .init(feed: .init(format: .rss, title: suffix, episodes: [
            ParsedEpisode(identifier: suffix, title: suffix, media: ParsedMedia(url: "https://example.org/\(suffix).mp3", size: 0))]),
            source: "https://example.org/\(suffix)", responseURL: URL(string: "https://example.org/\(suffix)")!, validator: nil, permanentRedirectURL: nil)
    }
    private func run(_ body: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FeedDeletion-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FeedLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        do { try await body(store, directory); try await store.close() }
        catch { try? await store.close(); throw error }
    }
    @Test func cleanupUsesStrictAgeBoundaryAndProtectsOwnedEpisodes() {
        for state in FeedSubscriptionState.allCases {
            for interacted in [false, true] {
                var episode = LibraryEpisode(id: 1, details: .init(media: .init(url: "https://example.org/media", size: 0)))
                episode.userState.positionMilliseconds = interacted ? 1 : 0
                var feed = LibraryFeed(id: 1, source: "https://example.org/feed", metadata: .init(format: .rss), episodes: [episode])
                feed.subscriptionState = state; feed.lastRefreshAttempt = now
                let retention: TimeInterval = (interacted ? 30 : 1) * 86_400
                for delta in [-1.0, 0, 0.001] {
                    #expect(NonSubscribedFeedCleanup.shouldDelete(feed, queuedIDs: [], now: now + retention + delta)
                        == (state == .notSubscribed && delta > 0))
                }
                for protection in 0..<3 {
                    var protected = feed
                    if protection == 0 { protected.episodes[0].userState.isFavorite = true }
                    if protection == 1 { protected.episodes[0].userState.isDownloaded = true }
                    #expect(!NonSubscribedFeedCleanup.shouldDelete(protected, queuedIDs: protection == 2 ? [1] : [], now: now + 100 * 86_400))
                }
            }
        }
    }
    @Test func deletionAtomicallyRemovesRelationsAndReplaysExternalWorkOnce() async throws {
        try await run { store, root in
            try await store.selectSynchronizationAccount(UUID())
            let first = try await store.insert(fixture("first")), second = try await store.insert(fixture("second"))
            let episode = try #require(first.episodes.first)
            let other = try #require(second.episodes.first)
            let file = root.appendingPathComponent("download.mp3")
            try Data([1, 2, 3]).write(to: file)
            try await store.updateEpisode(id: episode.id) { $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path }
            _ = try await store.enqueue([episode.id, other.id])
            #expect(try await store.requestFeedDeletion(feedID: first.id))
            #expect(try await store.feed(id: first.id) == nil)
            #expect(try await store.episode(id: episode.id) == nil)
            #expect(try await store.queue().map(\.id) == [other.id])
            #expect(FileManager.default.fileExists(atPath: file.path))
            let pending = try #require(try await store.pendingEffects().first { if case .deleteFeed = $0.effect.kind { true } else { false } })
            guard case .deleteFeed(let deletion) = pending.effect.kind else { return }
            #expect(deletion.files == [file] && deletion.episodeIDs == [episode.id] && deletion.synchronize)
            #expect(try await store.requestFeedDeletion(feedID: first.id) == false)
            let reopened = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
            let events = Mutex<[String]>([])
            let owner = await FeedDeletionCoordinator(store: reopened, retirePlayback: { _ in events.withLock { $0.append("playback") } },
                retireDownloads: { _ in events.withLock { $0.append("downloads") } }, removeFile: { url in
                    events.withLock { $0.append("file") }; try FeedDeletionCoordinator.unlinkDownload(url)
                })
            try await owner.resume().value; try await owner.resume().value
            #expect(events.withLock { $0 } == ["playback", "downloads", "file"])
            #expect(!FileManager.default.fileExists(atPath: file.path))
            // Once: the removal and the downloaded episode's DELETE reach the account's outbox; nothing is left to do.
            #expect(try await reopened.pendingEffects().isEmpty)
            let outbox = try await reopened.synchronizationQueue().map(\.value)
            #expect(outbox.filter { $0 == .removed(first.source) }.count == 1)
            #expect(!outbox.contains(.added(first.source)))
            #expect(outbox.filter { if case .episode(let action) = $0 { action.action == .delete } else { false } }.count == 1)
            try await reopened.close()
        }
    }
    @Test func expiredRequestRechecksQueueAndRejectsReplacedRefresh() async throws {
        try await run { store, _ in
            let feed = try await store.insert(fixture("preview"), options: .init(now: now), subscriptionState: .notSubscribed)
            let episodeID = try #require(feed.episodes.first?.id)
            let request = FeedRefreshRequest(feedID: nil, enqueuedAt: now)
            try await store.enqueueManualRefresh(request)
            _ = try await store.enqueue([episodeID])
            #expect(try await store.requestFeedDeletion(feedID: feed.id, expiredAt: now + 100 * 86_400, manualRequestID: request.id) == false)
            try await store.enqueueManualRefresh(.init(feedID: nil, enqueuedAt: now))
            await #expect(throws: CancellationError.self) {
                try await store.requestFeedDeletion(feedID: feed.id, expiredAt: now + 100 * 86_400, manualRequestID: request.id)
            }
            #expect(try await store.feed(id: feed.id) != nil)
        }
    }
    @Test func deletionCancelsSharedURLJobWithoutDeletingItsOtherFeed() async throws {
        try await run { store, root in
            let first = try await store.insert(fixture("shared"))
            var fetched = fixture("second")
            fetched.feed.episodes[0].media?.url = "https://example.org/shared.mp3"
            let second = try await store.insert(fetched)
            let other = try #require(second.episodes.first)
            let job = try #require(try await store.requestDownload(episodeID: other.id, directory: root, now: now))
            try Data([1]).write(to: job.destination)
            let cancelled = Mutex<Set<Int64>>([])
            let owner = await FeedDeletionCoordinator(store: store, retirePlayback: { _ in }, retireDownloads: { ids in
                cancelled.withLock { $0.formUnion(ids) }
            })
            try await owner.delete(feedID: first.id).value
            #expect(cancelled.withLock { $0 } == [job.id])
            #expect(try await store.feed(id: second.id) == second)
            #expect(try await store.downloadJobs(activeOnly: false).first?.state == .cancelled)
            #expect(!FileManager.default.fileExists(atPath: job.destination.path))
        }
    }
    @Test func failedUnlinkKeepsDurableWorkAndNeverRecursivelyDeletesDirectories() async throws {
        try await run { store, root in
            let feed = try await store.insert(fixture("failure"))
            let episodeID = try #require(feed.episodes.first?.id)
            let folder = root.appendingPathComponent("not-media")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let child = folder.appendingPathComponent("preserve.txt"); try Data([7]).write(to: child)
            try await store.updateEpisode(id: episodeID) { $0.userState.isDownloaded = true; $0.userState.localFileURL = folder.path }
            let owner = await FeedDeletionCoordinator(store: store, retirePlayback: { _ in }, retireDownloads: { _ in })
            await #expect(throws: (any Error).self) { try await owner.delete(feedID: feed.id).value }
            #expect(FileManager.default.fileExists(atPath: child.path))
            #expect(try await store.pendingEffects().contains { if case .deleteFeed = $0.effect.kind { true } else { false } })
            try FileManager.default.removeItem(at: child)
            try await owner.resume().value
            #expect(!FileManager.default.fileExists(atPath: folder.path))
        }
    }
    @Test func localFolderRemovalPreservesDocumentsAndOmitsSync() async throws {
        try await run { store, root in
            let folder = root.appendingPathComponent("local")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("preserve.mp3"); try Data([7]).write(to: file)
            let selection = try await LocalFolderSelection.prepare(directory: folder)
            let feed = try await store.registerLocalFolder(title: "Local", directoryIdentity: selection.identity, bookmark: selection.bookmark).feed
            var options = FeedRefreshOptions(); options.isLocalFeed = true
            _ = try await store.applyRefresh(FetchedFeed(feed: .init(format: .rss, episodes: [
                ParsedEpisode(identifier: "local-file", media: .init(url: file.absoluteString, size: 1))]),
                source: feed.source, responseURL: file, validator: nil, permanentRedirectURL: nil), feedID: feed.id, options: options)
            let episodeID = try #require(try await store.feed(id: feed.id)?.episodes.first?.id)
            try await store.updateEpisode(id: episodeID) { $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path }
            let owner = await FeedDeletionCoordinator(store: store, retirePlayback: { _ in }, retireDownloads: { _ in })
            try await owner.delete(feedID: feed.id).value
            #expect(try await store.feed(id: feed.id) == nil)
            #expect(try await store.localFolder(feedID: feed.id) == nil)
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(try await store.pendingEffects().isEmpty)
        }
    }
}
