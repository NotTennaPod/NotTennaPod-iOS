import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

struct LocalFeedRefreshServiceTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let failure = LocalFolderScanFailure(code: 257, message: "Cannot read local directory. Re-connect the folder.")

    private func withStore(_ body: (FeedLibraryStore, URL, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalRefresh-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: url)
        _ = try await store.registerLocalFolder(title: "Folder", directoryIdentity: "fixture:folder", bookmark: Data([1]))
        do { try await body(store, url, root); try await store.close() }
        catch { try? await store.close(); throw error }
    }

    private func input(_ names: [String], bookmark: Data = Data([1])) -> LocalFolderScanInput {
        LocalFolderScanInput(files: names.map {
            LocalFeedFile(name: $0, identity: "document:" + $0, providerMIMEType: "audio/mpeg",
                mediaMIMEType: "audio/mpeg", size: 10, modified: now)
        }, bookmark: { bookmark }, readMetadata: { _ in LocalFileMetadata(title: "Metadata title", durationMilliseconds: 30_000) })
    }

    private func service(_ store: FeedLibraryStore, names: [String]) -> LocalFeedRefreshService {
        let input = input(names), date = now
        return LocalFeedRefreshService(store: store, open: { _ in input }, clock: { date })
    }

    private func run(_ service: LocalFeedRefreshService) async throws -> LocalFeedRefreshService.Outcome {
        try await service.refresh(feedID: 1, description: "Local description", author: "Local folder")
    }

    @Test func initialSuccessIsLoggedOnceAndRecoveryIsLoggedWithoutLosingHistory() async throws {
        try await withStore { store, url, _ in
            let success = service(store, names: ["a.mp3"])
            guard case .updated(let first) = try await run(success) else { Issue.record("Expected scan"); return }
            #expect(first.feed.metadata.description == "Local description" && first.feed.metadata.author == "Local folder")
            try await store.updateEpisode(id: 1) { $0.userState.isFavorite = true; $0.userState.positionMilliseconds = 1000 }
            _ = try await store.enqueue([1]); _ = try await store.beginPlayback(episodeID: 1)
            _ = try await run(success)
            #expect(try await store.logs(feedID: 1).map(\.kind) == [.success])
            let before = try #require(try await store.feed(id: 1))
            let session = try await store.playbackSession()
            let fail = LocalFeedRefreshService(store: store, open: { _ in throw failure }, clock: { now.addingTimeInterval(1) })
            #expect(try await run(fail) == .failed(failure))
            let failed = try #require(try await store.feed(id: 1))
            #expect(failed.episodes == before.episodes && failed.lastUpdateFailed)
            #expect(try await store.queue().map(\.id) == [1])
            #expect(try await store.playbackSession() == session)
            let recoveryInput = input(["a.mp3"])
            let recovery = LocalFeedRefreshService(store: store, open: { _ in recoveryInput }, clock: { now.addingTimeInterval(2) })
            _ = try await run(recovery); _ = try await run(recovery)
            #expect(try await store.feed(id: 1)?.lastUpdateFailed == false)
            #expect(try await store.logs(feedID: 1).map(\.kind) == [.success, .failure(.io(code: 257)), .success])
            try await store.close()
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.logs(feedID: 1)[1].detail == failure.message)
            #expect(try await reopened.feed(id: 1)?.episodes == before.episodes)
            try await reopened.close()
        }
    }

    @Test(arguments: [false, true])
    func reconnectedSuccessCannotBeOverwrittenByLateSuccessOrFailure(fails: Bool) async throws {
        try await withStore { store, _, _ in
            let gate = OpenGate()
            let slow = LocalFeedRefreshService(store: store, open: { _ in try await gate.open() }, clock: { now })
            let task = Task { try await run(slow) }
            await gate.waitUntilOpened()
            _ = try await store.reconnectLocalFolder(feedID: 1, directoryIdentity: "fixture:replacement", bookmark: Data([9]))
            let nextInput = input(["replacement.mp3"], bookmark: Data([9]))
            let next = LocalFeedRefreshService(store: store, open: { _ in nextInput }, clock: { now })
            _ = try await run(next)
            let feed = try await store.feed(id: 1), logs = try await store.logs(feedID: 1)
            await gate.finish(fails ? .failure(failure) : .success(input(["obsolete.mp3"])))
            #expect(try await task.value == .superseded)
            #expect(try await store.feed(id: 1) == feed)
            #expect(try await store.logs(feedID: 1) == logs)
            #expect(try await store.localFolder(feedID: 1)?.bookmark == Data([9]))
        }
    }

    @Test func cancellationAfterProviderReturnsCannotLogFailureOrApplySnapshot() async throws {
        try await withStore { store, _, _ in
            _ = try await run(service(store, names: ["a.mp3"]))
            let before = try await store.feed(id: 1), logs = try await store.logs(feedID: 1)
            let gate = OpenGate()
            let slow = LocalFeedRefreshService(store: store, open: { _ in try await gate.open() })
            let task = Task { try await run(slow) }
            await gate.waitUntilOpened(); task.cancel()
            await gate.finish(.success(input([])))
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.feed(id: 1) == before)
            #expect(try await store.logs(feedID: 1) == logs)
            _ = try await run(service(store, names: ["a.mp3"]))
        }
    }

    @Test func logWriteFailureRollsBackBothSuccessfulScanAndErrorState() async throws {
        try await withStore { store, url, _ in
            let db = try LibrarySQLite(url: url)
            try db.execute("CREATE TRIGGER fail_log BEFORE INSERT ON refresh_log BEGIN SELECT RAISE(ABORT, 'log failure'); END")
            let before = try await store.feed(id: 1)
            await #expect(throws: FeedLibraryError.self) { try await run(service(store, names: ["a.mp3"])) }
            #expect(try await store.feed(id: 1) == before)
            #expect(try await store.logs(feedID: 1).isEmpty)
            let fail = LocalFeedRefreshService(store: store, open: { _ in throw failure })
            await #expect(throws: FeedLibraryError.self) { try await run(fail) }
            #expect(try await store.feed(id: 1) == before)
            #expect(try await store.logs(feedID: 1).isEmpty)
            try db.execute("DROP TRIGGER fail_log"); try db.close()
            _ = try await run(service(store, names: ["a.mp3"]))
            #expect(try await store.feed(id: 1)?.episodes.first?.id == 1)
        }
    }

    @Test func individualMetadataFailureKeepsEpisodeAndSuccessfulFolderStatus() async throws {
        try await withStore { store, _, _ in
            let files = input(["a.mp3"]).files
            let source = LocalFolderScanInput(files: files, bookmark: { Data([1]) }, readMetadata: { _ in throw CocoaError(.fileReadCorruptFile) })
            let service = LocalFeedRefreshService(store: store, open: { _ in source }, clock: { now })
            guard case .updated(let result) = try await run(service) else { Issue.record("Expected complete scan"); return }
            #expect(result.feed.episodes.first?.details.title == "a")
            #expect(result.feed.episodes.first?.details.description == CocoaError(.fileReadCorruptFile).localizedDescription)
            #expect(!result.feed.lastUpdateFailed)
            #expect(try await store.logs(feedID: 1).map(\.kind) == [.success])
        }
    }

    @Test func realFolderEnumerationFailurePreservesPreviouslyScannedEpisode() async throws {
        try await withStore { store, _, root in
            let folder = root.appendingPathComponent("media", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data([1, 2]).write(to: folder.appendingPathComponent("a.mp3"))
            let bookmark = try LocalFolderDocuments.makeBookmark(directory: folder)
            _ = try await store.reconnectLocalFolder(feedID: 1, directoryIdentity: folder.absoluteString, bookmark: bookmark)
            let service = LocalFeedRefreshService(store: store, open: { link in
                let documents = LocalFolderDocuments(bookmark: link.bookmark)
                let files = try await documents.entries().filter { !$0.isDirectory }.map {
                    LocalFeedFile(name: $0.name, identity: folder.appendingPathComponent($0.name).absoluteString,
                        providerMIMEType: "audio/mpeg", mediaMIMEType: "audio/mpeg", size: $0.size, modified: $0.modified ?? now)
                }
                // Real directory I/O; metadata/MIME are deterministic fixture inputs here.
                return LocalFolderScanInput(files: files, bookmark: { documents.bookmark }, readMetadata: { _ in LocalFileMetadata() })
            }, clock: { now })
            _ = try await run(service)
            let episodes = try await store.feed(id: 1)?.episodes
            try FileManager.default.removeItem(at: folder)
            guard case .failed = try await run(service) else { Issue.record("Missing folder must fail"); return }
            #expect(try await store.feed(id: 1)?.episodes == episodes)
            #expect(try await store.feed(id: 1)?.lastUpdateFailed == true)
        }
    }

    @Test func evictedFilesKeepTheirEpisodesAndOnlyAGenuineDeletionRemovesOne() async throws {
        try await withStore { store, _, root in
            let folder = root.appendingPathComponent("media", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            for name in ["a.mp3", "b.mp3", "c.mp3"] { try Data(count: 64).write(to: folder.appendingPathComponent(name)) }
            let bookmark = try LocalFolderDocuments.makeBookmark(directory: folder)
            _ = try await store.reconnectLocalFolder(feedID: 1, directoryIdentity: folder.absoluteString, bookmark: bookmark)
            let provider = LocalAvailabilityFixture()
            let reads = Mutex<[String]>([])
            let service = LocalFeedRefreshService(store: store, open: { link in
                // Real directory I/O; the provider's availability answers are the fixture's.
                try await LocalFolderDocuments(bookmark: link.bookmark, availability: provider.source).scanInput { url, _ in
                    reads.withLock { $0.append(url.lastPathComponent) }
                    return LocalFileMetadata(title: "Tagged " + url.lastPathComponent, durationMilliseconds: 30_000)
                }
            }, clock: { now })
            guard case .updated = try await run(service) else { Issue.record("Expected scan"); return }
            let a = try #require(try await store.feed(id: 1)?.episodes.first { $0.details.link == "a.mp3" })
            try await store.updateEpisode(id: a.id) {
                $0.userState.isFavorite = true; $0.userState.positionMilliseconds = 1_000; $0.userState.playState = .played
            }
            _ = try await store.enqueue([a.id])
            let before = try #require(try await store.feed(id: 1))
            reads.withLock { $0 = [] }

            // "Remove Download": a.mp3 leaves a legacy stub; b.mp3 stays listed but has no data here.
            try FileManager.default.removeItem(at: folder.appendingPathComponent("a.mp3"))
            try LocalAvailabilityFixture.writePlaceholder(in: folder, for: "a.mp3", size: 64)
            provider.set(".a.mp3.icloud", .notDownloaded); provider.set("b.mp3", .notDownloaded)
            guard case .updated(let evicted) = try await run(service) else { Issue.record("Expected scan"); return }
            #expect(evicted.removedEpisodes.isEmpty && reads.withLock { $0 }.isEmpty)
            #expect(try await store.feed(id: 1)?.episodes == before.episodes)
            #expect(try await store.queue().map(\.id) == [a.id])

            // A failed listing is no evidence that anything has gone.
            provider.fail("c.mp3")
            guard case .failed = try await run(service) else { Issue.record("Expected a failed listing"); return }
            #expect(try await store.feed(id: 1)?.episodes == before.episodes)
            provider.fail(nil)

            // A file really deleted loses its episode, as on Android. A local file
            // that is only named like a stub is no evidence that c.mp3 is in the cloud.
            try FileManager.default.removeItem(at: folder.appendingPathComponent("c.mp3"))
            try Data([1]).write(to: folder.appendingPathComponent(".c.mp3.icloud"))
            guard case .updated(let deleted) = try await run(service) else { Issue.record("Expected scan"); return }
            #expect(deleted.removedEpisodes.map(\.details.link) == ["c.mp3"])
            #expect(try await store.feed(id: 1)?.episodes == before.episodes.filter { $0.details.link != "c.mp3" })

            // Downloaded again: the same episode, with its state, and nothing to read.
            try FileManager.default.removeItem(at: folder.appendingPathComponent(".a.mp3.icloud"))
            try Data(count: 64).write(to: folder.appendingPathComponent("a.mp3"))
            provider.set(".a.mp3.icloud", nil); provider.set("a.mp3", .current)
            _ = try await run(service)
            #expect(try await store.feed(id: 1)?.episodes.first { $0.id == a.id } == before.episodes.first { $0.id == a.id })
            #expect(reads.withLock { $0 }.isEmpty)
            #expect(try await store.queue().map(\.id) == [a.id])
        }
    }

    @Test func aStubTheProviderCannotAnswerForFailsTheRefreshAndKeepsEverything() async throws {
        try await withStore { store, _, root in
            let folder = root.appendingPathComponent("media", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data(count: 64).write(to: folder.appendingPathComponent("a.mp3"))
            _ = try await store.reconnectLocalFolder(feedID: 1, directoryIdentity: folder.absoluteString,
                bookmark: LocalFolderDocuments.makeBookmark(directory: folder))
            let provider = LocalAvailabilityFixture()
            let service = LocalFeedRefreshService(store: store, open: { link in
                try await LocalFolderDocuments(bookmark: link.bookmark, availability: provider.source).scanInput { _, _ in
                    LocalFileMetadata(title: "Tagged", durationMilliseconds: 30_000)
                }
            }, clock: { now })
            _ = try await run(service)
            let id = try #require(try await store.feed(id: 1)?.episodes.first?.id)
            try await store.updateEpisode(id: id) { $0.userState.isFavorite = true; $0.userState.positionMilliseconds = 7_000 }
            _ = try await store.enqueue([id]); _ = try await store.beginPlayback(episodeID: id)
            let episodes = try await store.feed(id: 1)?.episodes, queue = try await store.queue()
            let session = try await store.playbackSession(), selection = try await store.playbackSelectionEpisodeID()

            // Evicted to a stub that says nothing, and the question about a.mp3 itself fails for now.
            try FileManager.default.removeItem(at: folder.appendingPathComponent("a.mp3"))
            try LocalAvailabilityFixture.writePlaceholder(in: folder, for: "a.mp3", size: 64)
            provider.fail("a.mp3")
            guard case .failed = try await run(service) else { Issue.record("An unanswered question must fail the refresh"); return }
            #expect(try await store.feed(id: 1)?.episodes == episodes)
            #expect(try await store.queue() == queue)
            #expect(try await store.playbackSession() == session)
            #expect(try await store.playbackSelectionEpisodeID() == selection)

            // The provider answers again: the episode is kept, with everything that belongs to it.
            provider.fail(nil); provider.set("a.mp3", .notDownloaded)
            guard case .updated(let recovered) = try await run(service) else { Issue.record("Expected scan"); return }
            #expect(recovered.removedEpisodes.isEmpty && !recovered.feed.lastUpdateFailed)
            #expect(try await store.feed(id: 1)?.episodes == episodes)
            #expect(try await store.queue() == queue)
            #expect(try await store.playbackSession() == session)
            #expect(try await store.playbackSelectionEpisodeID() == selection)
        }
    }

    @Test func pendingMetadataSurvivesAFailedReadAndAReopenedLibrary() async throws {
        try await withStore { store, url, _ in
            let file = LocalFeedFile(name: "tagged.mp3", identity: "document:tagged.mp3", providerMIMEType: "audio/mpeg",
                mediaMIMEType: "audio/mpeg", size: 10, modified: now, availability: .notDownloaded)
            func service(_ store: FeedLibraryStore, _ availability: LocalDocumentAvailability,
                         read: @escaping @Sendable (LocalFeedFile) async throws -> LocalFileMetadata) -> LocalFeedRefreshService {
                var listed = file; listed.availability = availability
                let input = LocalFolderScanInput(files: [listed], bookmark: { Data([1]) }, readMetadata: read)
                return LocalFeedRefreshService(store: store, open: { _ in input }, clock: { now })
            }
            _ = try await run(service(store, .notDownloaded) { _ in Issue.record("Cloud-only"); return LocalFileMetadata() })
            let pending = try #require(try await store.feed(id: 1)?.episodes.first)
            #expect(pending.details.title == "tagged" && pending.details.media?.metadataPending == true)
            _ = try await run(service(store, .current) { _ in throw CocoaError(.fileReadNoPermission) })
            #expect(try await store.feed(id: 1)?.episodes == [pending])

            try await store.close()
            let reopened = try FeedLibraryStore(url: url)
            let calls = Mutex(0)
            _ = try await run(service(reopened, .current) { _ in
                calls.withLock { $0 += 1 }; return LocalFileMetadata(title: "Tagged title", durationMilliseconds: 61_000)
            })
            let filled = try #require(try await reopened.feed(id: 1)?.episodes.first)
            #expect(calls.withLock { $0 } == 1 && filled.id == pending.id && filled.userState == pending.userState)
            #expect(filled.details.title == "Tagged title" && filled.details.media?.durationMilliseconds == 61_000)
            #expect(filled.details.media?.metadataPending == nil)
            try await reopened.close()
        }
    }

    @Test func equalCompletionTimesStillLogRecoveryAndFailureContextIsConsumedOnce() async throws {
        try await withStore { store, _, _ in
            let success = service(store, names: ["a.mp3"])
            _ = try await run(success)
            let context = try await store.beginLocalFolderScan(feedID: 1)
            #expect(try await store.recordLocalFolderFailure(failure, context: context, date: now))
            #expect(try await store.recordLocalFolderFailure(failure, context: context, date: now) == false)
            _ = try await run(success); _ = try await run(success)
            let logs = try await store.logs(feedID: 1)
            #expect(logs.map(\.kind) == [.success, .failure(.io(code: 257)), .success])
            #expect(logs.allSatisfy { $0.date == now })
        }
    }

    @Test func bookmarkRenewedDuringMetadataReadIsCommittedWithCompletedSnapshot() async throws {
        try await withStore { store, _, _ in
            let bookmark = Mutex(Data([1]))
            let source = LocalFolderScanInput(files: input(["a.mp3"]).files,
                bookmark: { bookmark.withLock { $0 } }, readMetadata: { _ in
                    bookmark.withLock { $0 = Data([8, 9]) }
                    return LocalFileMetadata(title: "Updated")
                })
            _ = try await run(LocalFeedRefreshService(store: store, open: { _ in source }, clock: { now }))
            #expect(try await store.localFolder(feedID: 1)?.bookmark == Data([8, 9]))
            #expect(try await store.feed(id: 1)?.episodes.first?.details.title == "Updated")
        }
    }

    @Test func successfulEmptyEnumerationRemovesEpisodesQueueAndStoredSelection() async throws {
        try await withStore { store, _, _ in
            _ = try await run(service(store, names: ["a.mp3"]))
            _ = try await store.enqueue([1]); _ = try await store.beginPlayback(episodeID: 1)
            guard case .updated(let result) = try await run(service(store, names: [])) else {
                Issue.record("A genuinely empty directory is a successful scan"); return
            }
            #expect(result.removedEpisodes.map(\.id) == [1])
            #expect(try await store.feed(id: 1)?.episodes.isEmpty == true)
            #expect(try await store.queue().isEmpty)
            #expect(try await store.playbackSession() == nil)
            #expect(try await store.playbackSelectionEpisodeID() == nil)
        }
    }

    @Test func feedDeletedDuringEnumerationDoesNotReturnAnErrorOrRecreateIt() async throws {
        try await withStore { store, url, _ in
            let gate = OpenGate()
            let slow = LocalFeedRefreshService(store: store, open: { _ in try await gate.open() })
            let task = Task { try await run(slow) }
            await gate.waitUntilOpened()
            let db = try LibrarySQLite(url: url)
            try db.execute("DELETE FROM feeds WHERE id = 1"); try db.close()
            await gate.finish(.success(input(["a.mp3"])))
            #expect(try await task.value == .superseded)
            #expect(try await store.feeds().isEmpty)
            #expect(try await store.logs(feedID: 1).isEmpty)
        }
    }

    @Test func oldLogRecordsDecodeWithoutDetailedMessage() throws {
        let old = Data(#"{"feedID":1,"date":0,"title":"Folder","kind":{"success":{}}}"#.utf8)
        let log = try JSONDecoder().decode(FeedLibraryLog.self, from: old)
        #expect(log.kind == .success && log.detail == nil)
    }
}

private actor OpenGate {
    private var continuation: CheckedContinuation<LocalFolderScanInput, any Error>?
    private var waiter: CheckedContinuation<Void, Never>?
    func open() async throws -> LocalFolderScanInput {
        try await withCheckedThrowingContinuation {
            continuation = $0; waiter?.resume(); waiter = nil
        }
    }
    func waitUntilOpened() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish(_ result: Result<LocalFolderScanInput, any Error>) {
        continuation?.resume(with: result); continuation = nil
    }
}
