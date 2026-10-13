import Foundation
import Testing
@testable import NotTennaPodCore

struct ManualFeedRefreshTests {
    @Test func admissionMatchesOriginalJavaAndSourceCooldownPrecedesNetwork() throws {
        struct Row: Decodable {
            let age: Int64, feedID: Int64?, lastFeedID: Int64?
            let local, connected, allowed, restricted, vpn: Bool
            let expected: String
        }
        struct Fixture: Decodable { let cases: [Row] }
        let file = try #require(Bundle.module.url(forResource: "manual-refresh-admission", withExtension: "json", subdirectory: "Fixtures"))
        let rows = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file)).cases
        #expect(rows.count == 2592)
        for row in rows {
            let result = ManualFeedRefreshAdmission(feedID: row.feedID, isLocalFeed: row.local,
                nowMilliseconds: 1_000_000, lastManualMilliseconds: 1_000_000 - row.age, lastManualFeedID: row.lastFeedID,
                connected: row.connected, refreshAllowed: row.allowed, restricted: row.restricted, vpnOverWiFi: row.vpn)
            let expected: ManualFeedRefreshAdmission = switch row.expected {
            case "run": .run
            case "cooldown": .cooldown
            case "offline": .offline
            case "ask": .askMobile(vpnOverWiFi: false)
            case "askVPN": .askMobile(vpnOverWiFi: true)
            default: preconditionFailure("Unknown original result")
            }
            #expect(result == expected, "age=\(row.age), target=\(String(describing: row.feedID))")
        }
    }
    @Test func individualAndAllRequestFlagsAndEligibilityUseSourceWorkerRules() {
        var feeds: [LibraryFeed] = []
        for state in FeedSubscriptionState.allCases {
            for updated in [false, true] {
                for local in [false, true] {
                    var feed = LibraryFeed(id: Int64(feeds.count + 1), source: local ? "antennapod_local:folder" : "https://example.com",
                        metadata: ParsedFeed(format: .rss), episodes: [])
                    feed.subscriptionState = state; feed.keepUpdated = updated; feeds.append(feed)
                }
            }
        }
        let all = FeedRefreshRequest(feedID: nil, nextPage: true, isLocalFeed: true, enqueuedAt: .distantPast)
        #expect(!all.force && !all.nextPage && all.requiresNetwork)
        #expect(all.eligibleFeeds(from: feeds).map(\.id) == feeds.filter { $0.keepUpdated && $0.subscriptionState == .subscribed }.map(\.id))
        for feed in feeds {
            let request = FeedRefreshRequest(feedID: feed.id, nextPage: true, isLocalFeed: feed.source.hasPrefix("antennapod_local:"), enqueuedAt: .distantPast)
            #expect(request.force && request.nextPage)
            #expect(request.requiresNetwork == !feed.source.hasPrefix("antennapod_local:"))
            #expect(request.eligibleFeeds(from: feeds) == [feed])
        }
        #expect(FeedRefreshRequest(feedID: 999, enqueuedAt: .distantPast).eligibleFeeds(from: feeds).isEmpty)
    }
    private func withStore(_ operation: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ManualRefresh-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library.sqlite"), store = try FeedLibraryStore(url: file)
        do { try await operation(store, file); try await store.close() }
        catch { try? await store.close(); throw error }
    }
    private func feed(_ store: FeedLibraryStore) async throws -> LibraryFeed {
        try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Original"), source: "https://example.com/feed",
            responseURL: URL(string: "https://example.com/feed")!, validator: "old", permanentRedirectURL: nil))
    }
    @Test func replacementSurvivesReopenAndOldAcknowledgmentsCannotEraseNewWork() async throws {
        try await withStore { store, file in
            let first = FeedRefreshRequest(feedID: 1, enqueuedAt: Date(timeIntervalSince1970: 123))
            let second = FeedRefreshRequest(feedID: nil, enqueuedAt: Date(timeIntervalSince1970: 456))
            #expect(try await store.manualRefreshRequest() == nil)
            try await store.enqueueManualRefresh(first)
            let other = try FeedLibraryStore(url: file)
            #expect(try await other.manualRefreshRequest() == first)
            try await other.enqueueManualRefresh(second)
            #expect(try await store.finishManualRefresh(id: first.id) == false)
            #expect(try await store.manualRefreshRequest() == second)
            try await other.close()
            let reopened = try FeedLibraryStore(url: file)
            #expect(try await reopened.manualRefreshRequest() == second)
            #expect(try await reopened.finishManualRefresh(id: second.id))
            #expect(try await store.manualRefreshRequest() == nil)
            #expect(try await store.finishManualRefresh(id: second.id) == false)
            try await reopened.close()
        }
    }
    @Test func migrationPreservesExistingLibraryAndFailedOrCancelledReplacementPreservesJob() async throws {
        try await withStore { store, file in
            let original = try await feed(store)
            let db = try LibrarySQLite(url: file)
            try restoreRefreshSchemaEleven(db)
            try db.execute("DROP TABLE manual_feed_refresh")
            try db.execute("DROP TABLE episode_notification_work"); try db.execute("DROP TABLE episode_notification_attempt")
            try db.execute("ALTER TABLE queue_work DROP COLUMN token"); try db.execute("DROP TABLE synchronization_state"); try db.execute("DROP TABLE synchronization_outbox"); try db.execute("DROP TABLE feed_credentials"); try db.execute("DROP TABLE feed_credential_cleanup"); try db.execute("PRAGMA user_version = 6")
            let migrated = try FeedLibraryStore(url: file)
            #expect(try await migrated.feed(id: original.id) == original)
            #expect(try await migrated.manualRefreshRequest() == nil)
            let first = FeedRefreshRequest(feedID: original.id, enqueuedAt: .distantPast)
            let second = FeedRefreshRequest(feedID: nil, enqueuedAt: .distantPast)
            try await migrated.enqueueManualRefresh(first)
            try db.execute("CREATE TRIGGER reject_manual BEFORE UPDATE ON feed_refresh_request BEGIN SELECT RAISE(ABORT, 'replacement failed'); END")
            await #expect(throws: FeedLibraryError.self) { try await store.enqueueManualRefresh(second) }
            #expect(try await migrated.manualRefreshRequest() == first)
            try db.execute("DROP TRIGGER reject_manual")
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await store.enqueueManualRefresh(second)
            }
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            #expect(try await store.manualRefreshRequest() == first)
            try await migrated.close(); try db.close()
        }
    }
    @Test func replacedRemoteSuccessAndFailureCannotChangeFeedLogsOrPendingEffects() async throws {
        try await withStore { store, _ in
            let original = try await feed(store)
            let effects = try await store.pendingEffects()
            for status in [200, 403] {
                let old = FeedRefreshRequest(feedID: original.id, enqueuedAt: .distantPast)
                let replacement = FeedRefreshRequest(feedID: 999, enqueuedAt: .distantPast)
                try await store.enqueueManualRefresh(old)
                let transport = ManualRefreshTransport { request in
                    try await store.enqueueManualRefresh(replacement)
                    return FeedHTTPResponse(url: request.url!, status: status, headers: [:], body: Data("<rss version=\"2.0\"><channel><title>Obsolete</title></channel></rss>".utf8))
                }
                let service = FeedRefreshService(store: store, fetcher: FeedFetcher(transport: transport))
                await #expect(throws: CancellationError.self) {
                    try await service.refresh(feedID: original.id, force: true, manualRequestID: old.id)
                }
                #expect(try await store.feed(id: original.id) == original)
                #expect(try await store.logs(feedID: original.id).isEmpty)
                #expect(try await store.pendingEffects() == effects)
                #expect(try await store.manualRefreshRequest() == replacement)
            }
        }
    }
    @Test func replacedLocalSuccessAndFailureCannotMutateFolderRegistrationOrLibrary() async throws {
        try await withStore { store, _ in
            let registration = try await store.registerLocalFolder(title: "Folder", directoryIdentity: "file:///fixture/", bookmark: Data([1]))
            let old = FeedRefreshRequest(feedID: registration.feed.id, isLocalFeed: true, enqueuedAt: .distantPast)
            try await store.enqueueManualRefresh(old)
            let context = try await store.beginLocalFolderScan(feedID: registration.feed.id, manualRequestID: old.id)
            let before = try await store.feed(id: registration.feed.id)
            let replacement = FeedRefreshRequest(feedID: nil, enqueuedAt: .distantPast)
            try await store.enqueueManualRefresh(replacement)
            await #expect(throws: CancellationError.self) {
                try await store.applyLocalFolderScan(ParsedFeed(format: .rss, title: "Obsolete"), context: context, manualRequestID: old.id)
            }
            await #expect(throws: CancellationError.self) {
                try await store.recordLocalFolderFailure(.init(code: 1, message: "Obsolete error"), context: context, date: .distantPast, manualRequestID: old.id)
            }
            await #expect(throws: CancellationError.self) {
                try await store.beginLocalFolderScan(feedID: registration.feed.id, manualRequestID: old.id)
            }
            #expect(try await store.feed(id: registration.feed.id) == before)
            #expect(try await store.isCurrentLocalFolderScan(context))
            #expect(try await store.logs(feedID: registration.feed.id).isEmpty)
        }
    }
}
private struct ManualRefreshTransport: FeedHTTPTransport {
    var operation: @Sendable (URLRequest) async throws -> FeedHTTPResponse
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse { try await operation(request) }
}
