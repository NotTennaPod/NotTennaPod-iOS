import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct OPMLImportTests {
    enum Failure: Error { case write, read, refresh }
    private func withStore(_ body: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OPML-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("library.sqlite"), store = try FeedLibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        do { try await body(store, url); try await store.close() }
        catch { try? await store.close(); throw error }
    }
    private func fetched(_ source: String, identifier: String? = nil) -> FetchedFeed {
        .init(feed: .init(format: .atom, identifier: identifier, title: "Before", episodes: [
            .init(identifier: "episode", title: "Episode", media: .init(url: "https://e.test/media", size: 32768, mimeType: "audio/mpeg"))]),
            source: source, responseURL: URL(string: "https://e.test")!, validator: "validator")
    }
    @Test func sourceIdentityDuplicateOrderAndRetainedState() async throws {
        try await withStore { store, url in
            let original = try await store.insert(fetched("raw"))
            let file = url.deletingLastPathComponent().appendingPathComponent("retained.mp3")
            let bytes = Data([1, 3, 5, 7]); try bytes.write(to: file)
            let vault = ImportCredentialVault()
            let retainedAuth = FeedAuthentication(store: store, vault: vault)
            let credentials = FeedCredentials(username: "import-fixture", password: "retained-secret")
            try await retainedAuth.save(credentials, feedID: original.id)
            try await store.updatePreferences(feedID: original.id) { $0.customTitle = "Custom"; $0.skip = .init(introSeconds: 12, endingSeconds: 7) }
            let preferences = try await store.feed(id: original.id)
            try await store.updateEpisode(id: original.episodes[0].id) {
                $0.userState.isFavorite = true; $0.userState.positionMilliseconds = 12000
                $0.userState.localFileURL = file.absoluteString; $0.userState.isDownloaded = true
            }
            _ = try await store.beginPlayback(episodeID: original.episodes[0].id)
            let episode = try await store.episode(id: original.episodes[0].id), queue = try await store.queue()
            let playback = try await store.playbackSession(), effects = try await store.pendingEffects()
            #expect(try await store.feed(id: original.id)?.sourceFeedType == "atom")
            let first = try await store.importOPMLEntry(.init(title: "First", xmlURL: "raw"))
            let last = try await store.importOPMLEntry(.init(title: "Last", xmlURL: "raw"))
            #expect(first.id == original.id && last.id == original.id)
            #expect(last.metadata.title == "Last" && last.validator == nil && last.sourceFeedType == nil)
            #expect(try await store.episode(id: original.episodes[0].id) == episode)
            #expect(try await store.queue() == queue)
            #expect(try await store.playbackSession() == playback)
            #expect(try await store.pendingEffects() == effects)
            #expect(try await store.feed(id: original.id)?.customTitle == preferences?.customTitle)
            #expect(try await store.feed(id: original.id)?.skipPreferences == preferences?.skipPreferences)
            #expect(try await retainedAuth.credentials(feedID: original.id) == credentials)
            #expect(try Data(contentsOf: file) == bytes)
            let atom = try await store.insert(fetched("atom", identifier: "urn:source"))
            let duplicate = try await store.importOPMLEntry(.init(title: "Imported", xmlURL: "atom"))
            #expect(atom.id != duplicate.id)
            #expect(try await store.importOPMLEntry(.init(title: "Again", xmlURL: "atom")).id == duplicate.id)
        }
    }
    @Test(arguments: [FeedSubscriptionState.archived, .notSubscribed])
    func preservesArchivedAndPreview(_ state: FeedSubscriptionState) async throws {
        try await withStore { store, _ in
            let f = try await store.insert(fetched("url"), subscriptionState: state)
            let effects = try await store.pendingEffects()
            let imported = try await store.importOPMLEntry(.init(title: "Imported", xmlURL: "url"))
            #expect(imported.id == f.id && imported.subscriptionState == state)
            #expect(imported.sourceFeedType == nil)
            #expect(try await store.pendingEffects() == effects)
        }
    }
    @Test func exactUTF16SourceIdentityAndLegacyProjection() async throws {
        try await withStore { store, _ in
            let a = try await store.importOPMLEntry(.init(title: "a", xmlURL: "Cafe\u{301}"))
            let b = try await store.importOPMLEntry(.init(title: "b", xmlURL: "Caf\u{e9}"))
            #expect(a.id != b.id)
            let legacy = LibraryFeed(id: 99, source: "remote", metadata: .init(format: .rss), episodes: [])
            let bytes = try JSONEncoder().encode(legacy)
            #expect(!String(decoding: bytes, as: UTF8.self).contains("sourceTypeAbsent"))
            #expect(try JSONDecoder().decode(LibraryFeed.self, from: bytes).sourceFeedType == "rss")
            let local = LibraryFeed(id: 100, source: "antennapod_local:folder", metadata: .init(format: .rss), episodes: [])
            #expect(local.sourceFeedType == nil)
        }
    }
    @Test func prefixFailureRollbackRetryAndGlobalRefresh() async throws {
        try await withStore { store, url in
            try await store.selectSynchronizationAccount(UUID())
            let db = try LibrarySQLite(url: url)
            try db.execute("CREATE TRIGGER reject_second BEFORE INSERT ON feeds WHEN NEW.title='Second' BEGIN SELECT RAISE(ABORT,'fixture failure'); END")
            var refreshes = 0
            let session = OPMLImportSession(store: store, read: { _ in Data("<opml><outline title='First' xmlUrl='a'/><outline title='Second' xmlUrl='b'/></opml>".utf8) }, refresh: { refreshes += 1 })
            await session.load(URL(fileURLWithPath: "/fixture"))?.value; session.selectAll(true)
            await session.confirm()?.value
            guard case .commitFailed = session.state else { Issue.record("Expected committed prefix failure"); return }
            #expect(try await store.feeds().map(\.source) == ["a"])
            // Each committed row sends its subscription (the failed row sends nothing).
            let prefixEffects = try await store.synchronizationQueue().map(\.value)
            #expect(prefixEffects == [.added("a")] && refreshes == 0)
            #expect(session.committedFeedIDs == [1])
            try db.execute("DROP TRIGGER reject_second")
            await session.confirm()?.value
            #expect(session.state == .completed && session.committedFeedIDs == [1, 2])
            #expect(refreshes == 1)
            #expect(try await store.synchronizationQueue().map(\.value) == [.added("a"), .added("b")])
            #expect(try await store.pendingEffects().isEmpty)
            let reopened = try FeedLibraryStore(url: url)
            #expect(try await reopened.feeds().allSatisfy { $0.sourceFeedType == nil })
            try await reopened.close(); try db.close()
        }
    }
    @Test func failedAndNotModifiedRefreshDoNotInventSourceType() async throws {
        try await withStore { store, _ in
            let f = try await store.importOPMLEntry(.init(title: "Placeholder", xmlURL: "https://e.test/feed"))
            try await store.recordFailure(.connection, feedID: f.id, date: Date())
            #expect(try await store.feed(id: f.id)?.sourceFeedType == nil)
            let service = FeedRefreshService(store: store, fetcher: FeedFetcher(transport: NotModifiedTransport()))
            #expect(try await service.refresh(feedID: f.id) == .unchanged)
            #expect(try await store.feed(id: f.id)?.sourceFeedType == nil)
            _ = try await store.applyRefresh(fetched("url"), feedID: f.id)
            #expect(try await store.feed(id: f.id)?.sourceFeedType == "atom")
        }
    }
    @Test func placeholderHeaderFailureRollsBackMatchedTitleAndType() async throws {
        try await withStore { store, url in
            let original = try await store.insert(fetched("raw"))
            let saved = try await store.feed(id: original.id), effects = try await store.pendingEffects()
            let db = try LibrarySQLite(url: url)
            try db.execute("CREATE TRIGGER reject_provenance BEFORE UPDATE ON feeds WHEN CAST(NEW.record AS TEXT) LIKE '%sourceTypeAbsent%' BEGIN SELECT RAISE(ABORT,'header failure'); END")
            await #expect(throws: (any Error).self) { try await store.importOPMLEntry(.init(title: "Changed", xmlURL: "raw")) }
            #expect(try await store.feed(id: original.id) == saved)
            #expect(try await store.pendingEffects() == effects)
            try db.close()
        }
    }
    actor ReadGate {
        var pending: [String: CheckedContinuation<Data, any Error>] = [:]
        func read(_ url: URL) async throws -> Data { try await withCheckedThrowingContinuation { pending[url.path] = $0 } }
        func finish(_ path: String, xml: String) { pending.removeValue(forKey: path)?.resume(returning: Data(xml.utf8)) }
    }
    @Test func replacedAndClosedReadsCannotPublishLateDocuments() async throws {
        let gate = ReadGate()
        let session = OPMLImportSession(read: { try await gate.read($0) }, commit: { _ in 0 }, refresh: {})
        let old = session.load(URL(fileURLWithPath: "/old"))
        while await gate.pending["/old"] == nil { await Task.yield() }
        let fresh = session.load(URL(fileURLWithPath: "/fresh"))
        while await gate.pending["/fresh"] == nil { await Task.yield() }
        await gate.finish("/fresh", xml: "<opml><outline xmlUrl='fresh'/></opml>"); await fresh?.value
        await gate.finish("/old", xml: "<opml><outline xmlUrl='stale'/></opml>"); await old?.value
        #expect(session.document.entries.map(\.xmlURL) == ["fresh"])
        let closing = session.load(URL(fileURLWithPath: "/close"))
        while await gate.pending["/close"] == nil { await Task.yield() }
        session.close()
        await gate.finish("/close", xml: "<opml><outline xmlUrl='late'/></opml>"); await closing?.value
        #expect(session.state == .closed && session.document.entries.isEmpty)
    }
    actor CommitGate {
        var values: [OPMLDocument.Entry] = []
        var continuation: CheckedContinuation<Void, Never>?
        func commit(_ entry: OPMLDocument.Entry) async -> Int64 {
            values.append(entry)
            await withCheckedContinuation { continuation = $0 }
            return 42
        }
        func release() { continuation?.resume(); continuation = nil }
    }
    @Test func oneImmutableConfirmationFinishesAfterCloseWithoutUIDelivery() async throws {
        let gate = CommitGate(); var refreshes = 0; var deliveries = 0
        let session = OPMLImportSession(read: { _ in Data("<opml><outline xmlUrl='a'/><outline xmlUrl='b'/></opml>".utf8) },
            commit: { await gate.commit($0) }, refresh: { refreshes += 1 })
        await session.load(URL(fileURLWithPath: "/fixture"))?.value; session.toggle(1)
        session.onChange = { deliveries += 1 }
        let job = try #require(session.confirm()); #expect(session.confirm() == nil)
        session.toggle(0); #expect(session.selected == [1])
        while await gate.values.isEmpty { await Task.yield() }
        session.close(); let atClose = deliveries
        await gate.release(); await job.value
        #expect(await gate.values.map(\.xmlURL) == ["b"])
        #expect(session.state == .completed && refreshes == 1 && deliveries == atClose)
    }
    @Test func cancelBeforeConfirmAndEmptyConfirmation() async {
        var refreshes = 0
        let session = OPMLImportSession(read: { _ in Data("<opml/>".utf8) }, commit: { _ in Issue.record("No selected rows"); return 0 }, refresh: { refreshes += 1 })
        await session.load(URL(fileURLWithPath: "/fixture"))?.value; session.close()
        #expect(session.confirm() == nil && refreshes == 0)
        let empty = OPMLImportSession(read: { _ in Data("<opml/>".utf8) }, commit: { _ in 0 }, refresh: { refreshes += 1 })
        await empty.load(URL(fileURLWithPath: "/fixture"))?.value; await empty.confirm()?.value
        #expect(empty.state == .completed && refreshes == 1)
    }
    @Test func refreshFailureRetriesOnlyEnqueueAndReadFailureNeverCommits() async {
        let calls = Mutex(0); var refreshes = 0
        let session = OPMLImportSession(read: { _ in Data("<opml><outline xmlUrl='a'/></opml>".utf8) }, commit: { _ in calls.withLock { $0 += 1 }; return 8 }, refresh: { refreshes += 1; if refreshes == 1 { throw Failure.refresh } })
        await session.load(URL(fileURLWithPath: "/fixture"))?.value; session.selectAll(true)
        await session.confirm()?.value; await session.confirm()?.value
        #expect(session.state == .completed && refreshes == 2 && calls.withLock { $0 } == 1)
        let failed = OPMLImportSession(read: { _ in throw Failure.read }, commit: { _ in Issue.record("read failed"); return 0 }, refresh: {})
        await failed.load(URL(fileURLWithPath: "/gone"))?.value
        guard case .readFailed = failed.state else { Issue.record("Expected read failure"); return }
        #expect(failed.confirm() == nil)
    }
    @Test func coordinatedLocalSnapshotSurvivesDeletionAndMissingFileFailsBeforeCommit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("M11-provider-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("source.opml")
        try Data("<opml><outline title='Retained bytes' xmlUrl='raw'/></opml>".utf8).write(to: url)
        let entries = Mutex<[OPMLDocument.Entry]>([])
        let session = OPMLImportSession(read: { try await OPMLDocumentReader().read($0) },
            commit: { entry in entries.withLock { $0.append(entry) }; return 1 }, refresh: {})
        await session.load(url)?.value
        #expect(session.state == .selecting)
        try FileManager.default.removeItem(at: url)
        session.selectAll(true); await session.confirm()?.value
        #expect(entries.withLock { $0 } == [.init(title: "Retained bytes", xmlURL: "raw")])
        let missing = OPMLImportSession(read: { try await OPMLDocumentReader().read($0) },
            commit: { _ in Issue.record("Missing file must not commit"); return 0 }, refresh: {})
        await missing.load(url)?.value
        guard case .readFailed = missing.state else { Issue.record("Expected coordinated missing-file failure"); return }
        #expect(missing.confirm() == nil)
        // Real local NSFileCoordinator behavior; this is not an external-provider revocation claim.
    }
    @Test func cancelledProviderReadBalancesAcquiredScope() async throws {
        let began = Mutex(false), events = Mutex<[String]>([]), release = DispatchSemaphore(value: 0)
        let reader = OPMLDocumentReader(begin: { _ in events.withLock { $0.append("begin") }; return true }, end: { _ in events.withLock { $0.append("end") } }, snapshot: { _ in
            began.withLock { $0 = true }; release.wait(); return Data("discarded".utf8)
        })
        let task = Task { try await reader.read(URL(fileURLWithPath: "/provider")) }
        while !began.withLock({ $0 }) { await Task.yield() }
        task.cancel(); release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(events.withLock { $0 } == ["begin", "end"])
        let local = OPMLDocumentReader(begin: { _ in false }, end: { _ in Issue.record("No scope acquired") }, snapshot: { _ in Data("local".utf8) })
        #expect(try await local.read(URL(fileURLWithPath: "/local")) == Data("local".utf8))
    }
    @Test(arguments: [true, false]) func providerScopeClosesOnSuccessAndReadError(fails: Bool) async throws {
        let events = Mutex<[String]>([])
        let reader = OPMLDocumentReader(begin: { _ in events.withLock { $0.append("begin") }; return true }, end: { _ in events.withLock { $0.append("end") } }, snapshot: { _ in events.withLock { $0.append("snapshot") }; if fails { throw Failure.read }; return Data("bytes".utf8) })
        if fails { await #expect(throws: Failure.self) { try await reader.read(URL(fileURLWithPath: "/provided")) } }
        else { #expect(try await reader.read(URL(fileURLWithPath: "/provided")) == Data("bytes".utf8)) }
        #expect(events.withLock { $0 } == ["begin", "snapshot", "end"])
    }
}

private struct NotModifiedTransport: FeedHTTPTransport {
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse { .init(url: request.url!, status: 304) }
}

private final class ImportCredentialVault: SynchronizationCredentialStore, Sendable {
    private let values = Mutex<[UUID: String]>([:])
    func insert(_ password: String, id: UUID) throws { values.withLock { $0[id] = password } }
    func password(id: UUID) throws -> String {
        try values.withLock { guard let value = $0[id] else { throw SynchronizationCredentialError.missing }; return value }
    }
    func remove(id: UUID) throws { values.withLock { $0[id] = nil } }
}
