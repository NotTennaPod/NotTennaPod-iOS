import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite(.timeLimit(.minutes(1)))
struct SynchronizationSubscriptionTests {
    private func fixture(_ body: (FeedLibraryStore, URL, UUID) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SyncSubscriptions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        try await store.selectSynchronizationAccount(UUID())
        let epoch = try await store.synchronizationState().epoch
        do { try await body(store, root, epoch); try await store.close() }
        catch { try? await store.close(); throw error }
    }
    private func feed(_ source: String, title: String = "Existing") -> FetchedFeed {
        .init(feed: .init(format: .rss, title: title, episodes: [
            .init(identifier: source + "#1", title: "Episode", media: .init(url: source + "/audio.mp3", size: 100, durationMilliseconds: 100_000))
        ]), source: source, responseURL: URL(string: source)!, validator: "saved-validator", permanentRedirectURL: nil)
    }
    private func deletion(_ store: FeedLibraryStore) async -> FeedDeletionCoordinator {
        await FeedDeletionCoordinator(store: store, retirePlayback: { _ in }, retireDownloads: { _ in })
    }
    private func settle(_ store: FeedLibraryStore, epoch: UUID, timestamp: Int64 = 10) async throws {
        let ids = try await store.synchronizationQueue().map(\.id)
        try await store.acknowledgeSynchronization(epoch: epoch, phase: .subscriptions, ids: ids, timestamp: timestamp)
    }

    @Test func firstSyncUploadsOriginalLocalSnapshotAndCreatesUnrefreshedRemoteFeed() async throws {
        try await fixture { store, _, epoch in
            let local = try await store.insert(feed("https://local.test/feed"))
            _ = try await store.insert(feed("https://archived.test/feed"), subscriptionState: .archived)
            _ = try await store.insert(feed("https://preview.test/feed"), subscriptionState: .notSubscribed)
            _ = try await store.registerLocalFolder(title: "Folder", directoryIdentity: "folder", bookmark: Data([1]))
            let provider = SubscriptionProvider(changes: .init(added: ["https://remote.test/feed"], removed: [], timestamp: 21))
            let service = SynchronizationSubscriptions(store: store, deletion: await deletion(store), redirect: { _ in nil })
            try await service.run(provider: provider, epoch: epoch)
            #expect(provider.uploads.withLock { $0 } == [.init(added: [local.source], removed: [])])
            let feeds = try await store.feeds()
            let remote = try #require(feeds.first { $0.source == "https://remote.test/feed" })
            #expect(remote.title == "Unknown podcast" && remote.episodes.isEmpty && remote.subscriptionState == .subscribed)
            #expect(remote.lastRefreshAttempt == Date(timeIntervalSince1970: 0) && remote.keepUpdated)
            #expect(try await store.feed(id: local.id) == local)
            #expect(try await store.synchronizationState().subscriptionTimestamp == 22)
            // Source first sync replaces the preexisting queued additions with
            // the subscribed snapshot; archived/local/preview feeds are excluded.
            #expect(try await store.synchronizationQueue().isEmpty)
        }
    }

    @Test func remoteOnlyChangeUsesDownloadedCursorAndDoesNotEchoUpload() async throws {
        try await fixture { store, _, epoch in
            try await settle(store, epoch: epoch)
            let provider = SubscriptionProvider(changes: .init(added: ["https://remote.test/new"], removed: [], timestamp: 99))
            try await SynchronizationSubscriptions(store: store, deletion: await deletion(store), redirect: { _ in nil }).run(provider: provider, epoch: epoch)
            #expect(provider.since.withLock { $0 } == [10])
            #expect(provider.uploads.withLock { $0 }.isEmpty)
            #expect(try await store.synchronizationQueue().isEmpty)
            #expect(try await store.synchronizationState().subscriptionTimestamp == 99)
        }
    }

    @Test func additionsRespectSourceSchemeEquivalentURLRedirectAndPendingLocalRemoval() async throws {
        try await fixture { store, _, epoch in
            let existing = try await store.insert(feed("https://existing.test/Feed"))
            let removed = try await store.insert(feed("https://removed.test/feed"))
            try await settle(store, epoch: epoch)
            _ = try await store.requestFeedDeletion(feedID: removed.id)
            let calls = Mutex<[String]>([])
            let provider = SubscriptionProvider(changes: .init(added: ["ftp://other.test/feed", "HTTP://upper.test/feed", "antennapod_local:folder",
                "http://EXISTING.test/feed/", removed.source, "https://redirect.test/feed", "https://new.test/feed"], removed: [], timestamp: 12))
            let service = SynchronizationSubscriptions(store: store, deletion: await deletion(store), redirect: { source in
                calls.withLock { $0.append(source) }
                return source.contains("redirect") ? existing.source : nil
            })
            try await service.run(provider: provider, epoch: epoch)
            #expect(calls.withLock { $0 } == ["https://redirect.test/feed", "https://new.test/feed"])
            #expect(try await store.feeds().map(\.source).sorted() == [existing.source, "https://new.test/feed"].sorted())
            #expect(try await store.feed(id: existing.id) == existing)
            // Pending deletion is still owned by the deletion coordinator.
            #expect(try await store.pendingEffects().contains { if case .deleteFeed = $0.effect.kind { true } else { false } })
        }
    }

    @Test func realDeletionRetiresPlaybackDownloadsAndFilesBeforeAcknowledgingRemoteRemoval() async throws {
        try await fixture { store, root, epoch in
            let first = try await store.insert(feed("https://remove.test/feed"))
            let episode = first.episodes[0], file = root.appendingPathComponent("download.mp3")
            try Data([1, 2, 3]).write(to: file)
            try await store.updateEpisode(id: episode.id) { $0.userState.isDownloaded = true; $0.userState.localFileURL = file.path }
            let session = try await store.beginPlayback(episodeID: episode.id)
            _ = session
            try await settle(store, epoch: epoch)
            let steps = Mutex<[String]>([])
            let owner = await FeedDeletionCoordinator(store: store, retirePlayback: { ids in
                let currentSession = try await store.playbackSession()
                #expect(ids == [episode.id]); #expect(currentSession == nil)
                steps.withLock { $0.append("playback") }
            }, retireDownloads: { _ in steps.withLock { $0.append("downloads") } }, removeFile: { url in
                #expect(FileManager.default.fileExists(atPath: url.path)); steps.withLock { $0.append("file") }
                try FeedDeletionCoordinator.unlinkDownload(url)
            })
            let provider = SubscriptionProvider(changes: .init(added: [], removed: [first.source], timestamp: 40))
            try await SynchronizationSubscriptions(store: store, deletion: owner, redirect: { _ in nil }).run(provider: provider, epoch: epoch)
            #expect(steps.withLock { $0 } == ["playback", "downloads", "file"])
            #expect(try await store.feed(id: first.id) == nil && !FileManager.default.fileExists(atPath: file.path))
            #expect(try await store.queue().isEmpty)
            #expect(try await store.playbackSelectionEpisodeID() == nil)
            let queued = try await store.synchronizationQueue()
            #expect(queued.count == 1)
            guard case .episode(let action) = queued.first?.value else { Issue.record("Expected completed file DELETE"); return }
            #expect(action.action == .delete && action.podcast == first.source)
            #expect(provider.uploads.withLock { $0 }.isEmpty)
            #expect(try await store.synchronizationState().subscriptionTimestamp == 40)
        }
    }

    @Test func remoteRemovalIsExactAndRecentLocalResubscriptionWins() async throws {
        try await fixture { store, _, epoch in
            let exact = try await store.insert(feed("https://same.test/Feed"))
            let archived = try await store.insert(feed("https://archived.test/feed"), subscriptionState: .archived)
            try await settle(store, epoch: epoch)
            let provider = SubscriptionProvider(changes: .init(added: [], removed: ["http://same.test/feed", archived.source, "https://new.test/feed"], timestamp: 42), onFetch: {
                _ = try await store.insert(feed("https://new.test/feed"))
            })
            try await SynchronizationSubscriptions(store: store, deletion: await deletion(store), redirect: { _ in nil }).run(provider: provider, epoch: epoch)
            #expect(try await store.feed(id: exact.id) == exact)
            #expect(try await store.feed(id: archived.id) == nil)
            #expect(try await store.feeds().contains { $0.source == "https://new.test/feed" })
            #expect(provider.uploads.withLock { $0 } == [.init(added: ["https://new.test/feed"], removed: [])])
        }
    }

    @Test func firstSyncRetainsSourcePreRemovalUploadSnapshot() async throws {
        try await fixture { store, _, epoch in
            let local = try await store.insert(feed("https://local.test/feed"))
            try await settle(store, epoch: epoch, timestamp: 0)
            let provider = SubscriptionProvider(changes: .init(added: [], removed: [local.source], timestamp: 12))
            try await SynchronizationSubscriptions(store: store, deletion: await deletion(store), redirect: { _ in nil }).run(provider: provider, epoch: epoch)
            #expect(try await store.feed(id: local.id) == nil)
            #expect(provider.uploads.withLock { $0 } == [.init(added: [local.source], removed: [])])
        }
    }

    @Test func additionsDuringFirstFetchAndDuringUploadSurviveTheirUnrelatedReceipt() async throws {
        try await fixture { store, _, epoch in
            let original = try await store.insert(feed("https://before.test/feed"))
            let provider = SubscriptionProvider(changes: .init(added: [], removed: [], timestamp: 1), onFetch: {
                _ = try await store.insert(feed("https://during-fetch.test/feed"))
            }, onUpload: {
                _ = try await store.insert(feed("https://during-upload.test/feed"))
            })
            let service = SynchronizationSubscriptions(store: store, deletion: await deletion(store), redirect: { _ in nil })
            try await service.run(provider: provider, epoch: epoch)
            #expect(provider.uploads.withLock { $0 } == [.init(added: [original.source], removed: [])])
            #expect(try await store.synchronizationQueue().map(\.value) == [.added("https://during-fetch.test/feed"), .added("https://during-upload.test/feed")])
            let next = SubscriptionProvider(changes: .init(added: [], removed: [], timestamp: 23))
            try await service.run(provider: next, epoch: epoch)
            #expect(next.uploads.withLock { $0 } == [.init(added: ["https://during-fetch.test/feed", "https://during-upload.test/feed"], removed: [])])
            #expect(try await store.synchronizationQueue().isEmpty)
        }
    }

    @Test func accountChangeDuringHEADRejectsOldAdditionAndDuringUploadRejectsReceipt() async throws {
        try await fixture { store, _, epoch in
            let provider = SubscriptionProvider(changes: .init(added: ["https://remote.test/feed"], removed: [], timestamp: 12))
            let service = SynchronizationSubscriptions(store: store, deletion: await deletion(store), redirect: { _ in
                try await store.selectSynchronizationAccount(UUID()); return nil
            })
            await #expect(throws: CancellationError.self) { try await service.run(provider: provider, epoch: epoch) }
            #expect(try await store.feeds().isEmpty)
            let nextEpoch = try await store.synchronizationState().epoch
            _ = try await store.insert(feed("https://local.test/feed"))
            let upload = SubscriptionProvider(changes: .init(added: [], removed: [], timestamp: 12), onUpload: {
                try await store.selectSynchronizationAccount(UUID())
                _ = try await store.insert(feed("https://new-account.test/feed"))
            })
            let next = SynchronizationSubscriptions(store: store, deletion: await deletion(store), redirect: { _ in nil })
            await #expect(throws: CancellationError.self) { try await next.run(provider: upload, epoch: nextEpoch) }
            #expect(try await store.synchronizationState().subscriptionTimestamp == 0)
            #expect(try await store.synchronizationQueue().map(\.value) == [.added("https://new-account.test/feed")])
        }
    }

    @Test func deletionFinishedInDifferentAccountDoesNotEmitChangesToThatAccount() async throws {
        try await fixture { store, _, epoch in
            let local = try await store.insert(feed("https://local.test/feed"))
            try await settle(store, epoch: epoch)
            _ = try await store.requestFeedDeletion(feedID: local.id)
            try await store.selectSynchronizationAccount(UUID())
            let newEpoch = try await store.synchronizationState().epoch
            let provider = SubscriptionProvider(changes: .init(added: [local.source], removed: [], timestamp: 50))
            try await SynchronizationSubscriptions(store: store, deletion: await deletion(store), redirect: { _ in nil }).run(provider: provider, epoch: newEpoch)
            let replacement = try #require(try await store.feeds().first)
            #expect(replacement.source == local.source && replacement.id != local.id)
            try await deletion(store).resume().value
            #expect(try await store.synchronizationQueue().isEmpty)
            #expect(try await store.feed(id: replacement.id) == replacement)
            // The deletion finished; its removal is not sent to the new account (nor kept).
            #expect(try await store.pendingEffects().isEmpty)
        }
    }

    @Test func fullSyncRetainsSameAccountDeletionAndDisconnectedAcceptanceStaysDisconnected() async throws {
        try await fixture { store, _, epoch in
            let local = try await store.insert(feed("https://local.test/feed"))
            try await settle(store, epoch: epoch)
            _ = try await store.requestFeedDeletion(feedID: local.id)
            _ = try await store.requestSynchronization(full: true)
            try await deletion(store).resume().value
            #expect(try await store.synchronizationQueue().map(\.value) == [.removed(local.source)])
            try await store.selectSynchronizationAccount(nil)
            let disconnected = try await store.insert(feed("https://disconnected.test/feed"))
            _ = try await store.requestFeedDeletion(feedID: disconnected.id)
            try await store.selectSynchronizationAccount(UUID())
            try await deletion(store).resume().value
            #expect(try await store.synchronizationQueue().isEmpty)
        }
    }

    @Test func uploadFailureRetainsCursorAndQueueAndCancelledWorkDoesNotPrune() async throws {
        try await fixture { store, _, epoch in
            try await settle(store, epoch: epoch)
            _ = try await store.insert(feed("https://local.test/feed"))
            let before = try await store.synchronizationQueue(), state = try await store.synchronizationState()
            for failure in [SynchronizationError.httpStatus(503), .authentication] {
                let provider = SubscriptionProvider(changes: .init(added: [], removed: [], timestamp: 11), onUpload: { throw failure })
                let service = SynchronizationSubscriptions(store: store, deletion: await deletion(store), redirect: { _ in nil })
                await #expect(throws: failure) { try await service.run(provider: provider, epoch: epoch) }
                #expect(try await store.synchronizationQueue() == before)
                #expect(try await store.synchronizationState() == state)
            }
            let cancelled = SubscriptionProvider(changes: .init(added: [], removed: [], timestamp: 11), onUpload: { throw CancellationError() })
            let service = SynchronizationSubscriptions(store: store, deletion: await deletion(store), redirect: { _ in nil })
            await #expect(throws: CancellationError.self) { try await service.run(provider: cancelled, epoch: epoch) }
            #expect(try await store.synchronizationQueue() == before)
        }
    }

    @Test func placeholderTransactionFailureLeavesCompleteLibraryAndOutboxUnchanged() async throws {
        try await fixture { store, root, epoch in
            let before = try await store.snapshot(), state = try await store.synchronizationState()
            let db = try LibrarySQLite(url: root.appendingPathComponent("library.sqlite"))
            defer { try? db.close() }
            try db.execute("CREATE TRIGGER reject_sync BEFORE INSERT ON synchronization_outbox BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            let provider = SubscriptionProvider(changes: .init(added: ["https://remote.test/feed"], removed: [], timestamp: 20))
            let service = SynchronizationSubscriptions(store: store, deletion: await deletion(store), redirect: { _ in nil })
            await #expect(throws: FeedLibraryError.self) { try await service.run(provider: provider, epoch: epoch) }
            #expect(try await store.snapshot() == before)
            #expect(try await store.synchronizationQueue().isEmpty)
            #expect(try await store.pendingEffects().isEmpty)
            #expect(try await store.synchronizationState() == state)
        }
    }

    @Test func resubscriptionBeforeFileCleanupKeepsNewerAddAndNewFeed() async throws {
        try await fixture { store, _, epoch in
            let original = try await store.insert(feed("https://same.test/feed"))
            try await settle(store, epoch: epoch)
            _ = try await store.requestFeedDeletion(feedID: original.id)
            let replacement = try await store.insert(feed(original.source, title: "Subscribed again"))
            let before = try await store.synchronizationQueue()
            try await deletion(store).resume().value
            #expect(try await store.feed(id: replacement.id) == replacement)
            #expect(try await store.synchronizationQueue() == before)
            #expect(before.map(\.value) == [.added(original.source)])
        }
    }

    @Test func sourceLegacyConflictCleanupOnlyTouchesFailedSnapshot() async throws {
        try await fixture { store, root, epoch in
            let local = try await store.insert(feed("https://local.test/feed"))
            try await settle(store, epoch: epoch)
            let db = try LibrarySQLite(url: root.appendingPathComponent("library.sqlite"))
            defer { try? db.close() }
            for value: SynchronizationQueuedChange.Value in [.removed(local.source), .added("https://gone.test/feed"), .removed("https://gone.test/feed")] {
                try db.execute("INSERT INTO synchronization_outbox(phase, record) VALUES ('subscriptions', ?)",
                               [.blob(try JSONEncoder().encode(value))])
            }
            let ids = try await store.synchronizationQueue().map(\.id)
            _ = try await store.insert(feed("https://newer.test/feed"))
            try await store.removeLegacySynchronizationConflicts(epoch: epoch, ids: ids, local: [local.source])
            #expect(try await store.synchronizationQueue().map(\.value) == [.removed("https://gone.test/feed"), .added("https://newer.test/feed")])
            #expect(try await store.synchronizationState().subscriptionTimestamp == 10)
        }
    }

    @Test func selectedHTTPClientFetchesAndUploadsThroughRealLocalServer() async throws {
        try await fixture { store, _, epoch in
            let local = try await store.insert(feed("https://local.test/feed"))
            let server = try await LoopbackHTTPServer.start { request in
                if request.method == "GET" {
                    return .init(body: Data(#"{"add":["https://remote.test/feed"],"remove":[],"timestamp":31}"#.utf8))
                }
                return .init(body: Data(#"{"timestamp":32}"#.utf8))
            }
            defer { server.stop() }
            let provider = try SynchronizationHTTPClient(backend: .nextcloud,
                host: server.url.deletingLastPathComponent().absoluteString, username: "fixture", password: "fixture", clock: { Date(timeIntervalSince1970: 40) })
            let service = SynchronizationSubscriptions(store: store, deletion: await deletion(store), redirect: { _ in nil })
            try await provider.login()
            try await service.run(provider: provider, epoch: epoch)
            try await provider.logout()
            #expect(server.requests.map(\.method) == ["GET", "POST"])
            let upload = try #require(server.requests.last)
            let json = try #require(JSONSerialization.jsonObject(with: upload.body) as? [String: Any])
            #expect(json["add"] as? [String] == [local.source])
            #expect(json["remove"] as? [String] == [])
            #expect(try await store.feeds().count == 2)
            // Nextcloud upload cursors use its clock, not the response body.
            #expect(try await store.synchronizationState().subscriptionTimestamp == 40)
            #expect(try await store.synchronizationQueue().isEmpty)
        }
    }

    @Test func failedRemoteTeardownKeepsDurableRemovalAndCursorForRecovery() async throws {
        try await fixture { store, _, epoch in
            let local = try await store.insert(feed("https://local.test/feed"))
            try await settle(store, epoch: epoch)
            let owner = await FeedDeletionCoordinator(store: store, retirePlayback: { _ in throw FeedLibraryError.invalidMutation }, retireDownloads: { _ in })
            let provider = SubscriptionProvider(changes: .init(added: [], removed: [local.source], timestamp: 12))
            let service = SynchronizationSubscriptions(store: store, deletion: owner, redirect: { _ in nil })
            await #expect(throws: FeedLibraryError.invalidMutation) { try await service.run(provider: provider, epoch: epoch) }
            #expect(try await store.feed(id: local.id) == nil)
            #expect(try await store.pendingEffects().contains { if case .deleteFeed = $0.effect.kind { true } else { false } })
            #expect(try await store.synchronizationState().subscriptionTimestamp == 10)
            #expect(provider.uploads.withLock { $0 }.isEmpty)
            let retry = SynchronizationSubscriptions(store: store, deletion: await deletion(store), redirect: { _ in nil })
            try await retry.run(provider: provider, epoch: epoch)
            #expect(try await store.synchronizationState().subscriptionTimestamp == 12)
            #expect(try await store.synchronizationQueue().isEmpty)
            #expect(try await store.pendingEffects().allSatisfy { if case .deleteFeed = $0.effect.kind { false } else { true } })
        }
    }

    @Test func redirectUpgradeFailureAndLoopPoliciesPreserveOriginalSubscription() async throws {
        let upgrade = HeadScript([.response(302, "https://example.test/feed"), .response(200, nil)])
        #expect(try await SynchronizationRedirectChecker(transport: upgrade).destination(for: "http://example.test/feed") == "https://example.test/feed")
        let failure = HeadScript([.response(301, "https://other.test/feed"), .failure(.cannotConnectToHost)])
        #expect(try await SynchronizationRedirectChecker(transport: failure).destination(for: "https://example.test/feed") == nil)
        let loop = HeadScript(Array(repeating: .response(301, "/feed"), count: 21))
        #expect(try await SynchronizationRedirectChecker(transport: loop).destination(for: "https://example.test/feed") == nil)
        #expect(await loop.requests.count == 21)
        try await fixture { store, _, epoch in
            let failedHEAD = HeadScript([.failure(.cannotFindHost)])
            let provider = SubscriptionProvider(changes: .init(added: ["https://unreachable.test/feed"], removed: [], timestamp: 4))
            let service = SynchronizationSubscriptions(store: store, deletion: await deletion(store), redirects: .init(transport: failedHEAD))
            try await service.run(provider: provider, epoch: epoch)
            #expect(try await store.feeds().map(\.source) == ["https://unreachable.test/feed"])
            #expect(try await store.synchronizationState().subscriptionTimestamp == 4)
        }
    }

    @Test func localRemovalWhileHEADIsSuspendedPreventsResurrection() async throws {
        try await fixture { store, _, epoch in
            let source = "https://remote.test/feed"
            let provider = SubscriptionProvider(changes: .init(added: [source], removed: [], timestamp: 7))
            let service = SynchronizationSubscriptions(store: store, deletion: await deletion(store), redirect: { _ in
                let local = try await store.insert(feed(source))
                _ = try await store.requestFeedDeletion(feedID: local.id)
                return nil
            })
            try await service.run(provider: provider, epoch: epoch)
            #expect(try await store.feeds().isEmpty)
            #expect(try await store.pendingEffects().contains { if case .deleteFeed = $0.effect.kind { true } else { false } })
        }
    }

    @Test func realRedirectHEADUsesFirstHopAndCancellationStopsHeldRequest() async throws {
        for status in [301, 302, 303, 307, 308] {
            let server = try await LoopbackHTTPServer.start { request in
                if request.path == "/feed" { return .init(status: status, headers: ["Location": "/first"]) }
                if request.path == "/first" { return .init(status: 301, headers: ["Location": "/last"]) }
                return .init(status: 404)
            }
            defer { server.stop() }
            let value = try await SynchronizationRedirectChecker(userAgent: "AntennaPod/9.9.9").destination(for: server.url.absoluteString)
            #expect(value == ([301, 308].contains(status) ? server.url.deletingLastPathComponent().appendingPathComponent("first").absoluteString : nil))
            #expect(server.requests.map(\.method) == ["HEAD", "HEAD", "HEAD"])
            #expect(server.requests.allSatisfy { $0.headers["authorization"] == nil })
            // Source's AntennapodHttpClient sends the app's User-Agent on every hop.
            #expect(server.requests.allSatisfy { $0.headers["user-agent"] == "AntennaPod/9.9.9" })
        }
        let cancelled = try await LoopbackHTTPServer.start { _ in nil }
        defer { cancelled.stop() }
        let task = Task { try await SynchronizationRedirectChecker().destination(for: cancelled.url.absoluteString) }
        while cancelled.requests.isEmpty { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private final class SubscriptionProvider: SynchronizationProvider {
    struct Upload: Equatable { let added, removed: [String] }
    let since = Mutex<[Int64]>([]), uploads = Mutex<[Upload]>([])
    let changes: SynchronizationSubscriptionChanges
    let onFetch: @Sendable () async throws -> Void
    let onUpload: @Sendable () async throws -> Void
    init(changes: SynchronizationSubscriptionChanges,
         onFetch: @escaping @Sendable () async throws -> Void = {},
         onUpload: @escaping @Sendable () async throws -> Void = {}) {
        self.changes = changes; self.onFetch = onFetch; self.onUpload = onUpload
    }
    func login() async throws { Issue.record("Subscription phase must not own login") }
    func logout() async throws { Issue.record("Subscription phase must not own logout") }
    func subscriptionChanges(since: Int64) async throws -> SynchronizationSubscriptionChanges {
        self.since.withLock { $0.append(since) }; try await onFetch(); return changes
    }
    func uploadSubscriptions(added: [String], removed: [String]) async throws -> SynchronizationUploadResult {
        uploads.withLock { $0.append(.init(added: added, removed: removed)) }; try await onUpload(); return .init(timestamp: 22)
    }
    func episodeChanges(since: Int64) async throws -> SynchronizationEpisodeChanges { throw SynchronizationError.unsupportedOperation }
    func uploadEpisodeActions(_ actions: [SynchronizationEpisodeAction]) async throws -> SynchronizationUploadResult? { throw SynchronizationError.unsupportedOperation }
}

private actor HeadScript: FeedHTTPTransport {
    enum Step: Sendable { case response(Int, String?), failure(URLError.Code) }
    var steps: [Step]
    var requests: [URLRequest] = []
    init(_ steps: [Step]) { self.steps = steps }
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }
        switch steps.removeFirst() {
        case .failure(let code): throw URLError(code)
        case .response(let status, let location):
            return .init(url: request.url!, status: status, headers: location.map { ["Location": $0] } ?? [:])
        }
    }
}
