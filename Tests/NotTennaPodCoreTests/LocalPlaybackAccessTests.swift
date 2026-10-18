import Darwin
import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.serialized)
struct LocalPlaybackAccessTests {
    private struct Fixture {
        let root: URL, folder: URL, file: URL, database: URL
        let store: FeedLibraryStore
        let episode: LibraryEpisode
    }
    private func fixture(name: String = "episode.wav", _ body: (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalPlayback-\(UUID())", isDirectory: true)
        let folder = root.appendingPathComponent("provider", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = folder.appendingPathComponent(name, isDirectory: false)
        try Data(0..<8).write(to: file)
        let database = root.appendingPathComponent("library.sqlite")
        let store = try FeedLibraryStore(url: database)
        do {
            let context = try await store.registerLocalFolder(title: "Local", directoryIdentity: folder.absoluteString,
                bookmark: LocalFolderDocuments.makeBookmark(directory: folder))
            let snapshot = ParsedFeed(format: .rss, title: "Local", episodes: [
                .init(identifier: "one", title: "Episode", link: name,
                    media: .init(url: file.absoluteString, size: 8, mimeType: "audio/wav"))
            ])
            _ = try await store.applyLocalFolderScan(snapshot, context: context)
            _ = try await store.enqueue([1])
            let episode = try #require(try await store.episode(id: 1))
            try await body(Fixture(root: root, folder: folder, file: file, database: database, store: store, episode: episode))
            try await store.close()
        } catch { try? await store.close(); throw error }
    }
    private final class Events: Sendable {
        let values = Mutex<[String]>([])
        func record(_ value: String) { values.withLock { $0.append(value) } }
        func count(_ value: String) -> Int { values.withLock { $0.filter { $0 == value }.count } }
    }
    private func environment(started: Bool = true) -> (LocalPlaybackAccess.Environment, Events) {
        let events = Events()
        var environment = LocalPlaybackAccess.Environment()
        let resolve = environment.resolve
        environment.resolve = { data in events.record("resolve"); return try resolve(data) }
        // These counters model scope ownership only; the files are app-owned.
        environment.start = { _ in events.record("start"); return started }
        environment.stop = { _ in events.record("stop") }
        return (environment, events)
    }
    private final class Gate: Sendable {
        private let enteredState = Mutex(false)
        private let releaseSignal = DispatchSemaphore(value: 0)
        var entered: Bool { enteredState.withLock { $0 } }
        func hold() { enteredState.withLock { $0 = true }; releaseSignal.wait() }
        func release() { releaseSignal.signal() }
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(predicate())
    }

    @Test(arguments: ["episode.wav", "你好 # %.wav", "%2E%2E e\u{301}.wav"])
    func realBookmarksReadLiteralRangesAndPreserveStoredIdentity(name: String) async throws {
        try await fixture(name: name) { f in
            let before = try await f.store.feed(id: 1), queue = try await f.store.queue()
            let owner = try #require(try await LocalPlaybackAccess(store: f.store).open(episode: f.episode))
            defer { owner.close() }
            #expect(owner.length == 8 && owner.context.reference.filename == name && owner.context.mimeType == "audio/wav")
            #expect(try await owner.read(at: 0, maximumCount: 65_536) == Data(0..<8))
            #expect(try await owner.read(at: 2, maximumCount: 3) == Data([2, 3, 4]))
            #expect(try await owner.read(at: 8, maximumCount: 1).isEmpty)
            #expect(try await owner.read(at: Int64.max, maximumCount: 1).isEmpty)
            for (offset, count) in [(-1, 1), (0, 0), (0, 65_537)] {
                await #expect(throws: LocalPlaybackAccess.Failure.invalidRange) { try await owner.read(at: Int64(offset), maximumCount: count) }
            }
            #expect(try await f.store.feed(id: 1) == before)
            #expect(try await f.store.queue() == queue)
            #expect(try await f.store.downloadJobs(activeOnly: false).isEmpty)
        }
    }

    @Test func movedFolderRenewsPersistedGrantWithoutChangingMediaIdentity() async throws {
        try await fixture { f in
            let initial = try #require(try await f.store.localFolder(feedID: 1))
            let moved = f.root.appendingPathComponent("moved # %.folder", isDirectory: true)
            try FileManager.default.moveItem(at: f.folder, to: moved)
            let owner = try #require(try await LocalPlaybackAccess(store: f.store).open(episode: f.episode))
            defer { owner.close() }
            #expect(try await owner.read(at: 1, maximumCount: 3) == Data([1, 2, 3]))
            let renewed = try #require(try await f.store.localFolder(feedID: 1))
            #expect(renewed.bookmark != initial.bookmark && renewed.generation == initial.generation)
            #expect(try await f.store.episode(id: 1) == f.episode)
            let reopened = try FeedLibraryStore(url: f.database)
            do {
                #expect(try await reopened.localFolder(feedID: 1) == renewed)
                let again = try #require(try await LocalPlaybackAccess(store: reopened).open(episode: f.episode))
                #expect(try await again.read(at: 4, maximumCount: 4) == Data([4, 5, 6, 7])); again.close()
                try await reopened.close()
            } catch { try? await reopened.close(); throw error }
        }
    }

    @Test(arguments: [false, true])
    func onlySuccessfulScopeStartsAreBalancedAndChildCancellationIsIndependent(started: Bool) async throws {
        try await fixture { f in
            let (environment, events) = environment(started: started)
            let owner = try #require(try await LocalPlaybackAccess(store: f.store, environment: environment).open(episode: f.episode))
            let retired = owner.makeReader(), current = owner.makeReader()
            retired.cancel()
            await #expect(throws: CancellationError.self) { try await retired.read(at: 0, maximumCount: 2) }
            #expect(try await current.read(at: 0, maximumCount: 2) == Data([0, 1]))
            #expect(events.count("start") == 1 && events.count("stop") == 0)
            owner.close(); owner.close()
            await #expect(throws: CancellationError.self) { try await current.read(at: 0, maximumCount: 2) }
            try await wait { events.count("stop") == (started ? 1 : 0) }
        }
    }

    @Test func nativeSynchronousConsumerUsesDedicatedQueueAndFinalOwnerReleasesScope() async throws {
        try await fixture { f in
            var (environment, events) = environment()
            let read = environment.read
            environment.read = { handle, offset, count in #expect(!Thread.isMainThread); return try read(handle, offset, count) }
            var owner = try await LocalPlaybackAccess(store: f.store, environment: environment).open(episode: f.episode)
            var reader: LocalPlaybackDocument.Reader? = try #require(owner).makeReader()
            owner = nil
            #expect(events.count("stop") == 0)
            let bytes: Data = try await withCheckedThrowingContinuation { continuation in
                let current = reader!
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result { try current.readSynchronously(at: 2, maximumCount: 2) })
                }
            }
            #expect(bytes == Data([2, 3]))
            reader = nil
            try await wait { events.count("stop") == 1 }
        }
    }

    @Test func remoteReturnsNilButMissingLocalRegistrationCannotFallBackToMetadataURL() async throws {
        try await fixture { f in
            let remote = try await f.store.insert(.init(feed: .init(format: .rss, title: "Remote", episodes: [
                .init(identifier: "remote", media: .init(url: "https://example.invalid/audio", size: 8))
            ]), source: "https://example.invalid/feed", responseURL: URL(string: "https://example.invalid/feed")!,
                validator: nil, permanentRedirectURL: nil))
            let (environment, events) = environment()
            let access = LocalPlaybackAccess(store: f.store, environment: environment)
            #expect(try await access.open(episode: remote.episodes[0]) == nil)
            let db = try LibrarySQLite(url: f.database); defer { try? db.close() }
            try db.execute("DELETE FROM local_folder_links WHERE feed_id = 1")
            await #expect(throws: LocalPlaybackAccess.Failure.missingRegistration) { try await access.open(episode: f.episode) }
            #expect(events.count("resolve") == 0 && events.count("start") == 0)
            #expect(try Data(contentsOf: f.file) == Data(0..<8))
        }
    }

    @Test(arguments: ["", ".", "..", "../escape", "/tmp/escape", "folder/file", "nul\0name"])
    func invalidLiteralChildIsRejectedBeforeResolvingGrant(name: String) async throws {
        try await fixture { f in
            try await f.store.updateEpisode(id: 1) { $0.details.link = name }
            let episode = try #require(try await f.store.episode(id: 1))
            let (environment, events) = environment()
            await #expect(throws: LocalFolderDocuments.Failure.invalidName) {
                try await LocalPlaybackAccess(store: f.store, environment: environment).open(episode: episode)
            }
            #expect(events.count("start") == 0 && events.count("resolve") == 0)
        }
    }

    @Test(arguments: [false, true])
    func missingOrDirectoryDocumentFailsAndReleasesScope(directory: Bool) async throws {
        try await fixture { f in
            try FileManager.default.removeItem(at: f.file)
            if directory { try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false) }
            let (environment, events) = environment()
            await #expect(throws: (any Error).self) { try await LocalPlaybackAccess(store: f.store, environment: environment).open(episode: f.episode) }
            try await wait { events.count("start") == 1 && events.count("stop") == 1 }
            #expect(try await f.store.episode(id: 1) == f.episode)
        }
    }

    @Test func specialFileCannotBlockAcquisitionOrReplaceAnOpenDocument() async throws {
        try await fixture { f in
            let (environment, events) = environment()
            let access = LocalPlaybackAccess(store: f.store, environment: environment)
            let owner = try #require(try await access.open(episode: f.episode))
            defer { owner.close() }
            try FileManager.default.removeItem(at: f.file)
            try #require(mkfifo(f.file.path, S_IRUSR | S_IWUSR) == 0)
            await #expect(throws: LocalPlaybackAccess.Failure.notRegularFile) { try await access.open(episode: f.episode) }
            await #expect(throws: LocalPlaybackAccess.Failure.notRegularFile) { try await owner.read(at: 0, maximumCount: 2) }
            try await wait { events.count("start") == 2 && events.count("stop") == 1 }
        }
    }

    @Test(arguments: [false, true])
    func resolverAndRenewalErrorsDoNotDeliverOwnerOrMutateLibrary(afterStart: Bool) async throws {
        try await fixture { f in
            let before = try await f.store.feed(id: 1), link = try await f.store.localFolder(feedID: 1)
            var (environment, events) = environment()
            let resolve = environment.resolve
            environment.resolve = { data in
                if !afterStart { throw CocoaError(.fileReadNoPermission) }
                let value = try resolve(data)
                return .init(directory: value.directory, stale: true)
            }
            environment.renew = { _ in throw CocoaError(.fileWriteNoPermission) }
            await #expect(throws: CocoaError(afterStart ? .fileWriteNoPermission : .fileReadNoPermission)) {
                try await LocalPlaybackAccess(store: f.store, environment: environment).open(episode: f.episode)
            }
            try await wait { events.count("stop") == (afterStart ? 1 : 0) }
            #expect(events.count("start") == (afterStart ? 1 : 0))
            #expect(try await f.store.feed(id: 1) == before)
            #expect(try await f.store.localFolder(feedID: 1) == link)
        }
    }

    @Test func staleEpisodeSnapshotIsRejectedBeforeResolvingGrant() async throws {
        try await fixture { f in
            try await f.store.updateEpisode(id: 1) { $0.details.media?.url = "file:///different-document" }
            let (environment, events) = environment()
            await #expect(throws: CancellationError.self) {
                try await LocalPlaybackAccess(store: f.store, environment: environment).open(episode: f.episode)
            }
            #expect(events.count("resolve") == 0 && events.count("start") == 0)
        }
    }

    enum Change: CaseIterable { case replace, overwrite, truncate }
    @Test(arguments: Change.allCases)
    func coordinatedWriterIsNotHeldForPlaybackAndChangedBytesAreRejected(change: Change) async throws {
        try await fixture { f in
            let owner = try #require(try await LocalPlaybackAccess(store: f.store).open(episode: f.episode))
            defer { owner.close() }
            #expect(try await owner.read(at: 0, maximumCount: 2) == Data([0, 1]))
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                DispatchQueue.global(qos: .utility).async {
                    var result: Result<Void, any Error>?, error: NSError?
                    NSFileCoordinator().coordinate(writingItemAt: f.file, options: [], error: &error) { url in
                        result = Result {
                            switch change {
                            case .replace: try Data(repeating: 9, count: 8).write(to: url, options: .atomic)
                            case .overwrite:
                                let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
                                try file.write(contentsOf: Data(repeating: 9, count: 8))
                            case .truncate:
                                let file = try FileHandle(forWritingTo: url); defer { try? file.close() }; try file.truncate(atOffset: 3)
                            }
                        }
                    }
                    continuation.resume(with: error.map { .failure($0) } ?? result ?? .failure(CocoaError(.fileReadUnknown)))
                }
            }
            await #expect(throws: LocalPlaybackAccess.Failure.changedDocument) { try await owner.read(at: 2, maximumCount: 2) }
        }
    }

    @Test func symlinkReadsOriginalTargetAndRejectsReplacementTarget() async throws {
        try await fixture { f in
            let target = f.folder.appendingPathComponent("target")
            try FileManager.default.moveItem(at: f.file, to: target)
            try FileManager.default.createSymbolicLink(at: f.file, withDestinationURL: target)
            let owner = try #require(try await LocalPlaybackAccess(store: f.store).open(episode: f.episode))
            defer { owner.close() }
            #expect(try await owner.read(at: 2, maximumCount: 2) == Data([2, 3]))
            let other = f.folder.appendingPathComponent("other"); try Data(repeating: 9, count: 8).write(to: other)
            try FileManager.default.removeItem(at: f.file)
            try FileManager.default.createSymbolicLink(at: f.file, withDestinationURL: other)
            await #expect(throws: LocalPlaybackAccess.Failure.changedDocument) { try await owner.read(at: 0, maximumCount: 2) }
            #expect(try Data(contentsOf: target) == Data(0..<8))
        }
    }

    @Test(arguments: [false, true])
    func cancellationDuringAcquisitionCannotDeliverOrLeakGrant(afterStart: Bool) async throws {
        try await fixture { f in
            let gate = Gate(); defer { gate.release() }
            var (environment, events) = environment()
            let resolve = environment.resolve
            environment.resolve = { data in
                if !afterStart { gate.hold() }
                let value = try resolve(data)
                return .init(directory: value.directory, stale: afterStart)
            }
            environment.renew = { _ in gate.hold(); return Data([2]) }
            let access = LocalPlaybackAccess(store: f.store, environment: environment)
            let task = Task { try await access.open(episode: f.episode) }
            defer { task.cancel() }
            try await wait { gate.entered }; task.cancel(); gate.release()
            await #expect(throws: CancellationError.self) { try await task.value }
            try await wait { events.count("stop") == (afterStart ? 1 : 0) }
            #expect(events.count("start") == (afterStart ? 1 : 0))
        }
    }

    @Test func cancelledReadDiscardsBytesButOtherReaderRemainsUsable() async throws {
        try await fixture { f in
            let gate = Gate(); defer { gate.release() }
            var (environment, events) = environment()
            let read = environment.read, first = Mutex(true)
            environment.read = { handle, offset, count in
                let bytes = try read(handle, offset, count)
                if first.withLock({ let old = $0; $0 = false; return old }) { gate.hold() }
                return bytes
            }
            let owner = try #require(try await LocalPlaybackAccess(store: f.store, environment: environment).open(episode: f.episode))
            defer { owner.close() }
            let reader = owner.makeReader(), other = owner.makeReader()
            let task = Task { try await reader.read(at: 0, maximumCount: 2) }; defer { task.cancel() }
            try await wait { gate.entered }; reader.cancel(); gate.release()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await other.read(at: 2, maximumCount: 2) == Data([2, 3]))
            #expect(events.count("stop") == 0)
        }
    }

    @Test func closeDuringReadWaitsForCallbackAndDoesNotRevokeReplacementOwner() async throws {
        try await fixture { f in
            let gate = Gate(); defer { gate.release() }
            var (environment, events) = environment()
            let read = environment.read
            environment.read = { file, offset, count in gate.hold(); return try read(file, offset, count) }
            let owner = try #require(try await LocalPlaybackAccess(store: f.store, environment: environment).open(episode: f.episode))
            let task = Task { try await owner.read(at: 0, maximumCount: 2) }; defer { task.cancel() }
            try await wait { gate.entered }; owner.close()
            #expect(events.count("stop") == 0)
            let (nextEnvironment, nextEvents) = self.environment()
            let next = try #require(try await LocalPlaybackAccess(store: f.store, environment: nextEnvironment).open(episode: f.episode))
            defer { next.close() }
            #expect(try await next.read(at: 0, maximumCount: 2) == Data([0, 1]))
            gate.release()
            await #expect(throws: CancellationError.self) { try await task.value }
            try await wait { events.count("stop") == 1 }
            #expect(nextEvents.count("stop") == 0)
            #expect(try await next.read(at: 4, maximumCount: 2) == Data([4, 5]))
        }
    }

    private final class HeldPresenter: NSObject, NSFilePresenter, Sendable {
        typealias Reader = @Sendable ((@Sendable () -> Void)?) -> Void
        let presentedItemURL: URL?
        let presentedItemOperationQueue = OperationQueue()
        private let waitingReader = Mutex<Reader?>(nil)
        var waiting: Bool { waitingReader.withLock { $0 != nil } }
        init(url: URL) { presentedItemURL = url; super.init(); presentedItemOperationQueue.maxConcurrentOperationCount = 1 }
        func relinquishPresentedItem(toReader reader: @escaping Reader) { waitingReader.withLock { $0 = reader } }
        func release() { let reader = waitingReader.withLock { let old = $0; $0 = nil; return old }; reader?(nil) }
    }
    @Test(arguments: [false, true])
    func cancellationInterruptsRealBlockedCoordination(duringRead: Bool) async throws {
        try await fixture { f in
            let (environment, events) = environment()
            let access = LocalPlaybackAccess(store: f.store, environment: environment)
            let owner = duringRead ? try await access.open(episode: f.episode) : nil
            defer { owner?.close() }
            let presenter = HeldPresenter(url: f.file)
            NSFileCoordinator.addFilePresenter(presenter)
            defer { presenter.release(); NSFileCoordinator.removeFilePresenter(presenter) }
            let task = Task {
                if let owner { _ = try await owner.read(at: 0, maximumCount: 2) }
                else { let opened = try await access.open(episode: f.episode); opened?.close() }
            }
            defer { task.cancel() }
            try await wait { presenter.waiting }; task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            presenter.release(); owner?.close()
            try await wait { events.count("stop") == 1 }
        }
    }

    enum StoreRace: CaseIterable { case reconnect, scan, episode, removal }
    @Test(arguments: StoreRace.allCases)
    func storeChangesDuringAcquisitionRejectOldOwnerAndPreserveNewRegistration(race: StoreRace) async throws {
        try await fixture { f in
            let gate = Gate(); defer { gate.release() }
            var (environment, events) = environment()
            let resolve = environment.resolve
            environment.resolve = { data in let value = try resolve(data); return .init(directory: value.directory, stale: true) }
            environment.renew = { _ in gate.hold(); return Data([9]) }
            let access = LocalPlaybackAccess(store: f.store, environment: environment)
            let task = Task { try await access.open(episode: f.episode) }; defer { task.cancel() }
            try await wait { gate.entered }
            switch race {
            case .reconnect: _ = try await f.store.reconnectLocalFolder(feedID: 1, directoryIdentity: f.folder.absoluteString, bookmark: Data([7]))
            case .scan: _ = try await f.store.beginLocalFolderScan(feedID: 1)
            case .episode: try await f.store.updateEpisode(id: 1) { $0.details.media?.url = "file:///new-document" }
            case .removal:
                let scan = try await f.store.beginLocalFolderScan(feedID: 1)
                _ = try await f.store.applyLocalFolderScan(.init(format: .rss, title: "Local"), context: scan)
            }
            let current = try await f.store.localFolder(feedID: 1)
            gate.release()
            await #expect(throws: CancellationError.self) { try await task.value }
            try await wait { events.count("stop") == 1 }
            #expect(try await f.store.localFolder(feedID: 1) == current)
            #expect(try Data(contentsOf: f.file) == Data(0..<8))
        }
    }

    @Test func renewalPreservesNewerBytesAndDatabaseFailureDoesNotDeliverOwner() async throws {
        try await fixture { f in
            let first = try #require(try await f.store.localPlaybackContext(for: f.episode))
            #expect(try await f.store.confirmLocalPlaybackAccess(first, refreshedBookmark: Data([2])))
            #expect(try await f.store.confirmLocalPlaybackAccess(first, refreshedBookmark: Data([3])))
            #expect(try await f.store.localFolder(feedID: 1)?.bookmark == Data([2]))
            let second = try #require(try await f.store.localPlaybackContext(for: f.episode))
            #expect(try await f.store.confirmLocalPlaybackAccess(second, refreshedBookmark: first.reference.folder.bookmark))
            let before = try await f.store.localFolder(feedID: 1)
            let db = try LibrarySQLite(url: f.database); defer { try? db.close() }
            try db.execute("CREATE TRIGGER reject_playback_renewal BEFORE UPDATE ON local_folder_links BEGIN SELECT RAISE(ABORT, 'renewal failure'); END")
            var (environment, events) = environment()
            let resolve = environment.resolve
            environment.resolve = { data in let value = try resolve(data); return .init(directory: value.directory, stale: true) }
            environment.renew = { _ in Data([4]) }
            await #expect(throws: FeedLibraryError.self) {
                try await LocalPlaybackAccess(store: f.store, environment: environment).open(episode: f.episode)
            }
            try await wait { events.count("stop") == 1 }
            #expect(try await f.store.localFolder(feedID: 1) == before)
            #expect(try await f.store.episode(id: 1) == f.episode)
            try db.execute("DROP TRIGGER reject_playback_renewal")
            await #expect(throws: FeedLibraryError.invalidMutation) { try await f.store.confirmLocalPlaybackAccess(first, refreshedBookmark: Data()) }
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await f.store.confirmLocalPlaybackAccess(first, refreshedBookmark: Data([5]))
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await f.store.localFolder(feedID: 1) == before)
        }
    }

    @Test(arguments: [1, 3])
    func successfulShortReadsAdvanceByActualCountWithoutReplacingIdentity(limit: Int) async throws {
        try await fixture { f in
            var (environment, _) = environment()
            let read = environment.read
            environment.read = { file, offset, count in try read(file, offset, min(count, limit)) }
            let owner = try #require(try await LocalPlaybackAccess(store: f.store, environment: environment).open(episode: f.episode))
            defer { owner.close() }
            var bytes = Data()
            while bytes.count < 8 {
                let part = try await owner.read(at: Int64(bytes.count), maximumCount: 8)
                #expect(!part.isEmpty && part.count <= limit)
                bytes.append(part)
            }
            #expect(bytes == Data(0..<8))
            #expect(try await owner.read(at: 8, maximumCount: 8).isEmpty)
        }
    }

    @Test func zeroProgressBeforeKnownEOFIsReadFailureNotReplacement() async throws {
        try await fixture { f in
            var (environment, _) = environment()
            environment.read = { _, _, _ in Data() }
            let owner = try #require(try await LocalPlaybackAccess(store: f.store, environment: environment).open(episode: f.episode))
            defer { owner.close() }
            await #expect(throws: MediaDownloadError.wrongSize(expected: 8, received: 0)) {
                try await owner.read(at: 0, maximumCount: 8)
            }
            #expect(try await owner.read(at: 8, maximumCount: 8).isEmpty)
        }
    }

    @Test func readErrorDoesNotEscapeScopeAndSubsequentReadCanRetry() async throws {
        try await fixture { f in
            var (environment, events) = environment()
            let read = environment.read, first = Mutex(true)
            environment.read = { file, offset, count in
                if first.withLock({ let old = $0; $0 = false; return old }) { throw POSIXError(.EACCES) }
                return try read(file, offset, count)
            }
            let owner = try #require(try await LocalPlaybackAccess(store: f.store, environment: environment).open(episode: f.episode))
            await #expect(throws: POSIXError(.EACCES)) { try await owner.read(at: 0, maximumCount: 2) }
            #expect(events.count("stop") == 0)
            #expect(try await owner.read(at: 0, maximumCount: 2) == Data([0, 1]))
            owner.close(); try await wait { events.count("stop") == 1 }
        }
    }

    @Test func editDuringReadCannotDeliverMixedBytes() async throws {
        try await fixture { f in
            var (environment, _) = environment()
            let read = environment.read
            environment.read = { file, offset, count in
                let bytes = try read(file, offset, count)
                // An uncoordinated external writer is outside Foundation's lock.
                // The post-read descriptor check must still discard the result.
                let writer = try FileHandle(forWritingTo: f.file); defer { try? writer.close() }
                try writer.truncate(atOffset: 1)
                return bytes
            }
            let owner = try #require(try await LocalPlaybackAccess(store: f.store, environment: environment).open(episode: f.episode))
            defer { owner.close() }
            await #expect(throws: LocalPlaybackAccess.Failure.changedDocument) { try await owner.read(at: 0, maximumCount: 2) }
        }
    }
}
