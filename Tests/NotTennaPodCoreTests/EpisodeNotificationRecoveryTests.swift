import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite
struct EpisodeNotificationRecoveryTests {
    private let text = EpisodeNotificationDelivery.Text(title: { "New \($0)" }, message: { "\($1): \($0)" }, summary: "Inbox")
    private func fetched(_ identifiers: [String]) -> FetchedFeed {
        .init(feed: .init(format: .rss, title: "Show", episodes: identifiers.map { .init(identifier: $0, title: $0) }),
            source: "https://example.org/feed", responseURL: URL(string: "https://example.org/feed")!, validator: nil, permanentRedirectURL: nil)
    }
    private func run(_ body: (FeedLibraryStore, URL, LibraryFeed, FeedRefreshRequest) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NotificationRecovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("library.sqlite"), store = try FeedLibraryStore(url: file)
        let feed = try await store.insert(fetched(["one"]))
        try await store.updatePreferences(feedID: feed.id) { $0.showEpisodeNotification = true }
        try await store.updateEpisode(id: feed.episodes[0].id) { $0.userState.playState = .played }
        let request = FeedRefreshRequest(feedID: feed.id, enqueuedAt: .distantPast)
        try await store.enqueueManualRefresh(request)
        do { try await body(store, file, feed, request); try await store.close() }
        catch { try? await store.close(); throw error }
    }
    @Test func committedRefreshSurvivesReopenWithoutACompletionCallback() async throws {
        try await run { store, file, feed, request in
            let publisher = EpisodeNotificationDeliveryTests.Publisher()
            let first = EpisodeNotificationDelivery(store: store, publisher: publisher, text: text, artwork: { _ in nil })
            try await first.prepare(requestID: request.id)
            let refreshed = try await store.applyRefresh(fetched(["one", "two"]), feedID: feed.id, manualRequestID: request.id)
            #expect(publisher.posts.isEmpty)
            try await store.close() // No refreshed callback: process exited after commit.
            let reopened = try FeedLibraryStore(url: file)
            let recovered = EpisodeNotificationDelivery(store: reopened, publisher: publisher, text: text, artwork: { _ in nil })
            try await recovered.prepare(requestID: request.id)
            #expect(publisher.posts.map(\.destination) == [.feed(feed.id), .inbox])
            #expect(publisher.posts[0].body == "Show: 1")
            #expect(try await reopened.pendingEpisodeNotifications(requestID: request.id).isEmpty)
            try await recovered.refreshed(refreshed.feed, requestID: request.id)
            #expect(publisher.posts.count == 2) // Fresh retry baseline prevents duplicate delivery.
            try await reopened.close()
        }
    }
    @Test func journalFailureRollsBackFeedEpisodesLogsAndEffects() async throws {
        try await run { store, file, feed, request in
            _ = try await store.beginEpisodeNotificationAttempt(requestID: request.id)
            let before = try await store.feed(id: feed.id), effects = try await store.pendingEffects(), logs = try await store.logs(feedID: feed.id)
            let db = try LibrarySQLite(url: file)
            try db.execute("CREATE TRIGGER reject_notice BEFORE INSERT ON episode_notification_work BEGIN SELECT RAISE(ABORT, 'journal unavailable'); END")
            await #expect(throws: FeedLibraryError.self) {
                try await store.applyRefresh(fetched(["one", "two"]), feedID: feed.id, manualRequestID: request.id)
            }
            #expect(try await store.feed(id: feed.id) == before)
            #expect(try await store.pendingEffects() == effects)
            #expect(try await store.logs(feedID: feed.id) == logs)
            #expect(try await store.pendingEpisodeNotifications(requestID: request.id).isEmpty)
            try db.close()
        }
    }
    @Test func localFolderCommitStagesNotificationWithItsRegistration() async throws {
        try await run { store, _, _, _ in
            let initial = try await store.registerLocalFolder(title: "Folder", directoryIdentity: "fixture:folder", bookmark: Data([1]))
            try await store.updatePreferences(feedID: initial.feed.id) { $0.showEpisodeNotification = true }
            let request = FeedRefreshRequest(feedID: initial.feed.id, isLocalFeed: true, enqueuedAt: .distantPast)
            try await store.enqueueManualRefresh(request)
            _ = try await store.beginEpisodeNotificationAttempt(requestID: request.id)
            let scan = try await store.beginLocalFolderScan(feedID: initial.feed.id, manualRequestID: request.id)
            _ = try await store.applyLocalFolderScan(.init(format: .rss, title: "Folder", episodes: [
                .init(identifier: "one", title: "one.mp3", link: "one.mp3", media: .init(url: "document:one", size: 100, mimeType: "audio/mpeg"))
            ]), context: scan, manualRequestID: request.id)
            let pending = try #require(try await store.pendingEpisodeNotifications(requestID: request.id).first)
            #expect(pending.feedID == initial.feed.id && pending.beforeCount == 0)
            #expect(try await store.episodeNotificationCandidate(pending)?.count == 1)
        }
    }
    @Test func replacementFailurePreservesWorkAndSuccessOrCancellationRetiresIt() async throws {
        try await run { store, file, feed, request in
            _ = try await store.beginEpisodeNotificationAttempt(requestID: request.id)
            _ = try await store.applyRefresh(fetched(["one", "two"]), feedID: feed.id, manualRequestID: request.id)
            let pending = try #require(try await store.pendingEpisodeNotifications(requestID: request.id).first)
            let replacement = FeedRefreshRequest(feedID: nil, enqueuedAt: .distantPast)
            let db = try LibrarySQLite(url: file)
            try db.execute("CREATE TRIGGER reject_manual BEFORE UPDATE ON feed_refresh_request BEGIN SELECT RAISE(ABORT, 'replacement failed'); END")
            await #expect(throws: FeedLibraryError.self) { try await store.enqueueManualRefresh(replacement) }
            #expect(try await store.pendingEpisodeNotifications(requestID: request.id) == [pending])
            try db.execute("DROP TRIGGER reject_manual")
            try await store.enqueueManualRefresh(replacement)
            #expect(try await store.pendingEpisodeNotifications(requestID: replacement.id).isEmpty)
            await #expect(throws: CancellationError.self) { try await store.acknowledgeEpisodeNotification(pending) }
            _ = try await store.beginEpisodeNotificationAttempt(requestID: replacement.id)
            _ = try await store.applyRefresh(fetched(["one", "two", "three"]), feedID: feed.id, manualRequestID: replacement.id)
            #expect(try await store.pendingEpisodeNotifications(requestID: replacement.id).count == 1)
            #expect(try await store.finishManualRefresh(id: replacement.id))
            #expect(try db.scalar("SELECT count(*) FROM episode_notification_work") == 0)
            #expect(try db.scalar("SELECT count(*) FROM episode_notification_attempt") == 0)
            try db.close()
        }
    }
    @Test(arguments: [false, true]) func databaseFailureAfterOSAcceptanceRecoversWithoutAnotherAlert(summaryAccepted: Bool) async throws {
        try await run { store, file, feed, request in
            let publisher = EpisodeNotificationDeliveryTests.Publisher()
            let original = EpisodeNotificationDelivery(store: store, publisher: publisher, text: text, artwork: { _ in nil })
            try await original.prepare(requestID: request.id)
            let refreshed = try await store.applyRefresh(fetched(["one", "two"]), feedID: feed.id, manualRequestID: request.id)
            let db = try LibrarySQLite(url: file)
            let operation = summaryAccepted ? "DELETE" : "UPDATE"
            try db.execute("CREATE TRIGGER reject_receipt BEFORE \(operation) ON episode_notification_work BEGIN SELECT RAISE(ABORT, 'receipt unavailable'); END")
            await #expect(throws: FeedLibraryError.self) { try await original.refreshed(refreshed.feed, requestID: request.id) }
            #expect(publisher.posts.count == (summaryAccepted ? 2 : 1))
            try db.execute("DROP TRIGGER reject_receipt")
            let recovered = EpisodeNotificationDelivery(store: store, publisher: publisher, text: text, artwork: { _ in nil })
            try await recovered.prepare(requestID: request.id)
            #expect(publisher.posts.count == 3)
            #expect(publisher.posts.filter(\.alerts).count == 1)
            #expect(publisher.posts.last?.destination == .inbox)
            #expect(publisher.posts.last?.alerts == !summaryAccepted)
            #expect(try await store.pendingEpisodeNotifications(requestID: request.id).isEmpty)
            try db.close()
        }
    }
    @Test func retryRechecksUnreadCountAndDeletedWorkCannotAcknowledgeANewerRecord() async throws {
        try await run { store, _, feed, request in
            let baseline = try await store.beginEpisodeNotificationAttempt(requestID: request.id)
            let refreshed = try await store.applyRefresh(fetched(["one", "two"]), feedID: feed.id, manualRequestID: request.id)
            let pending = try #require(try await store.pendingEpisodeNotifications(requestID: request.id).first)
            for episode in refreshed.feed.episodes {
                try await store.updateEpisode(id: episode.id) { $0.userState.playState = .played }
            }
            let publisher = EpisodeNotificationDeliveryTests.Publisher()
            let recovered = EpisodeNotificationDelivery(store: store, publisher: publisher, text: text, artwork: { _ in
                Issue.record("No increased count means no artwork request"); return nil
            })
            try await recovered.prepare(requestID: request.id)
            #expect(publisher.posts.isEmpty)
            #expect(try await store.pendingEpisodeNotifications(requestID: request.id).isEmpty)
            let newer = try #require(try await store.stageEpisodeNotification(refreshed.feed, baseline: baseline))
            #expect(newer.id != pending.id)
            try await store.acknowledgeEpisodeNotification(pending)
            #expect(try await store.pendingEpisodeNotifications(requestID: request.id) == [newer])
        }
    }

    @Test func realWorkerRetryDeliversCommittedNoticeEvenWhenServerReturnsNotModified() async throws {
        try await run { store, _, feed, request in
            let publisher = EpisodeNotificationDeliveryTests.Publisher()
            publisher.fail = [EpisodeNotificationPublication.feedID(feed.id)]
            let delivery = EpisodeNotificationDelivery(store: store, publisher: publisher, text: text, artwork: { _ in nil })
            let effects = RecoveryWorkerEffects(delivery: delivery)
            let transport = RecoveryHTTP()
            let monitor = DownloadNetworkMonitor(startMonitoring: false)
            monitor.update(.init(connected: true, metered: false, cellular: false))
            let worker = FeedRefreshWorker(store: store,
                remote: FeedRefreshService(store: store, fetcher: FeedFetcher(transport: transport)),
                local: LocalFeedRefreshService(store: store), localDescription: "", localAuthor: "",
                network: monitor, credentials: { _ in nil }, options: { _ in FeedRefreshOptions() }, effects: effects)
            await #expect(throws: (any Error).self) { try await worker.run(request) }
            #expect(try await store.feed(id: feed.id)?.episodes.count == 2)
            #expect(try await store.manualRefreshRequest() == request)
            publisher.fail = []
            try await worker.run(request)
            #expect(await transport.calls == 2)
            #expect(publisher.posts.map(\.destination) == [.feed(feed.id), .inbox])
            #expect(publisher.posts.first?.body == "Show: 1")
            #expect(try await store.manualRefreshRequest() == nil)
        }
    }

    @Test func migrationFromSevenRetainsPendingRequestAndLibrary() async throws {
        try await run { store, file, feed, request in
            let before = try await store.feed(id: feed.id), effects = try await store.pendingEffects()
            try await store.close()
            let db = try LibrarySQLite(url: file)
            try restoreRefreshSchemaEleven(db)
            try db.execute("DROP TABLE episode_notification_work")
            try db.execute("DROP TABLE episode_notification_attempt")
            try db.execute("ALTER TABLE queue_work DROP COLUMN token"); try db.execute("DROP TABLE synchronization_state"); try db.execute("DROP TABLE synchronization_outbox"); try db.execute("DROP TABLE feed_credentials"); try db.execute("DROP TABLE feed_credential_cleanup"); try db.execute("PRAGMA user_version = 7")
            try db.close()
            let migrated = try FeedLibraryStore(url: file)
            #expect(try await migrated.feed(id: feed.id) == before)
            #expect(try await migrated.pendingEffects() == effects)
            #expect(try await migrated.manualRefreshRequest() == request)
            #expect(try await migrated.pendingEpisodeNotifications(requestID: request.id).isEmpty)
            let check = try LibrarySQLite(url: file)
            #expect(try check.scalar("PRAGMA user_version") == 22)
            try check.close(); try await migrated.close()
        }
    }
}

@MainActor private final class RecoveryWorkerEffects: FeedRefreshEffects {
    let delivery: EpisodeNotificationDelivery
    init(delivery: EpisodeNotificationDelivery) { self.delivery = delivery }
    func handle(_ event: FeedRefreshWorker.Event, request: FeedRefreshRequest) async throws {
        switch event {
        case .prepareNotifications: try await delivery.prepare(requestID: request.id)
        case .refreshed(let feed): try await delivery.refreshed(feed, requestID: request.id)
        default: break // Test scope: real notification recipient, other effects separately verified.
        }
    }
}
private actor RecoveryHTTP: FeedHTTPTransport {
    var calls = 0
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
        calls += 1
        if calls > 1 { return .init(url: request.url!, status: 304) }
        return .init(url: request.url!, status: 200, body: Data("""
            <rss version="2.0"><channel><title>Show</title>
            <item><guid>one</guid><title>one</title></item>
            <item><guid>two</guid><title>two</title></item>
            </channel></rss>
            """.utf8))
    }
}
