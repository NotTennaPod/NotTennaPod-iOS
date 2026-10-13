import Foundation
import Testing
@testable import NotTennaPodCore

struct NewEpisodeNotificationTests {
    private struct Fixture: Decodable {
        struct Decision: Decodable {
            let keepUpdated, enabled: Bool
            let before: Int?, after: Int, notificationCount: Int?, countReads: Int
        }
        struct Feed: Decodable { let id: Int64, state: Int, episodeStates: [Int], media: Bool }
        struct Query: Decodable { let feedIDs: [Int64], counts: [String: Int] }
        let cases: [Decision], feeds: [Feed], queries: [Query]
    }
    private func fixture() throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "new-episode-notification", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    private func withStore(_ body: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NewNotifications-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("library.sqlite"), store = try FeedLibraryStore(url: file)
        do { try await body(store, file); try await store.close() }
        catch { try? await store.close(); throw error }
    }
    private func insert(_ store: FeedLibraryStore, state: FeedSubscriptionState = .subscribed) async throws -> LibraryFeed {
        let parsed = ParsedFeed(format: .rss, title: "Original", imageURL: "https://example.com/cover.png",
            episodes: [ParsedEpisode(identifier: "one", title: "One"), ParsedEpisode(identifier: "two", title: "Two")])
        return try await store.insert(FetchedFeed(feed: parsed, source: "https://example.com/feed",
            responseURL: URL(string: "https://example.com/feed")!, validator: nil, permanentRedirectURL: nil), subscriptionState: state)
    }

    @Test func notificationDecisionsMatchUnchangedJavaAndPreserveTotalTitleAndArtwork() throws {
        let rows = try fixture().cases
        #expect(rows.count == 224)
        for row in rows {
            var feed = LibraryFeed(id: 1, source: "https://example.com/feed", metadata:
                ParsedFeed(format: .rss, title: "Original", imageURL: "https://example.com/cover.png"), episodes: [])
            feed.keepUpdated = row.keepUpdated; feed.showEpisodeNotification = row.enabled
            feed.customTitle = "Custom 🎧 العربية"
            let baseline = NewEpisodeNotificationBaseline(requestID: UUID(), counts: row.before.map { [1: $0] } ?? [:])
            let result = baseline.notification(for: feed, newCount: row.after)
            #expect(result?.count == row.notificationCount)
            if let result {
                #expect(result.feedID == 1 && result.title == feed.customTitle && result.imageURL == feed.metadata.imageURL)
                #expect(result.count == row.after) // Source displays total, not delta.
            }
            #expect(row.countReads == (row.keepUpdated && row.enabled ? 1 : 0))
        }
    }

    @Test func databaseCountersMatchOriginalSQLAcrossSubscriptionPlayAndMediaStates() async throws {
        let source = try fixture()
        #expect(source.feeds.count == 24 && source.queries.count == 28)
        try await withStore { store, _ in
            #expect(try await store.newEpisodeCounts().isEmpty)
            for row in source.feeds {
                let episodes = row.episodeStates.enumerated().map { index, _ in
                    ParsedEpisode(identifier: "\(index)", title: "Episode \(index)", media: row.media
                        ? ParsedMedia(url: "https://example.com/\(row.id)/\(index).mp3", size: 100) : nil)
                }
                let url = "https://example.com/feed/\(row.id)"
                let feed = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Feed \(row.id)", episodes: episodes),
                    source: url, responseURL: URL(string: url)!, validator: nil, permanentRedirectURL: nil),
                    subscriptionState: try #require(FeedSubscriptionState(rawValue: row.state)))
                #expect(feed.id == row.id)
                for episode in feed.episodes {
                    let identifier = try #require(episode.details.identifier)
                    let index = try #require(Int(identifier))
                    let play = try #require(EpisodePlayState(rawValue: row.episodeStates[index]))
                    try await store.updateEpisode(id: episode.id) { $0.userState.playState = play }
                }
            }
            for query in source.queries {
                let expected = Dictionary(uniqueKeysWithValues: query.counts.map { (Int64($0.key)!, $0.value) })
                #expect(try await store.newEpisodeCounts(feedIDs: query.feedIDs) == expected)
            }
        }
    }

    @Test func preferenceDefaultsLegacyDecodePersistenceRefreshAndRollback() async throws {
        try await withStore { store, file in
            var feed = try await insert(store)
            #expect(!feed.showEpisodeNotification)
            feed.showEpisodeNotification = true
            var oldJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(feed)) as? [String: Any])
            oldJSON.removeValue(forKey: "showEpisodeNotificationValue")
            let legacy = try JSONDecoder().decode(LibraryFeed.self, from: JSONSerialization.data(withJSONObject: oldJSON))
            #expect(!legacy.showEpisodeNotification && legacy.episodes == feed.episodes)
            try await store.updatePreferences(feedID: feed.id) { $0.showEpisodeNotification = true }
            let reopened = try FeedLibraryStore(url: file)
            #expect(try await reopened.feed(id: feed.id)?.showEpisodeNotification == true)
            try await reopened.close()
            let fetched = FetchedFeed(feed: ParsedFeed(format: .rss, title: "Refreshed"), source: feed.source,
                responseURL: URL(string: feed.source)!, validator: "new", permanentRedirectURL: nil)
            #expect(try await store.applyRefresh(fetched, feedID: feed.id).feed.showEpisodeNotification)
            let saved = try await store.feed(id: feed.id)
            await #expect(throws: FeedLibraryError.self) {
                try await store.updatePreferences(feedID: feed.id) {
                    $0.showEpisodeNotification = false; throw FeedLibraryError.invalidMutation
                }
            }
            #expect(try await store.feed(id: feed.id) == saved)
            let feedID = feed.id
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await store.updatePreferences(feedID: feedID) { $0.showEpisodeNotification = false }
            }
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            #expect(try await store.feed(id: feed.id) == saved)
            try await store.updatePreferences(feedID: feed.id) { $0.customTitle = "Custom" }
            #expect(try await store.feed(id: feed.id)?.showEpisodeNotification == true)
            try await store.updatePreferences(feedID: feed.id) { $0.showEpisodeNotification = false }
            #expect(try await store.feed(id: feed.id)?.showEpisodeNotification == false)
        }
    }

    @Test func baselineIsSubscribedOnlyButSelectedCountIncludesArchivedAndUnsubscribed() async throws {
        for state in FeedSubscriptionState.allCases {
            try await withStore { store, _ in
                let feed = try await insert(store, state: state)
                try await store.updatePreferences(feedID: feed.id) { $0.showEpisodeNotification = true }
                for episode in feed.episodes { try await store.updateEpisode(id: episode.id) { $0.userState.playState = .new } }
                let request = FeedRefreshRequest(feedID: feed.id, enqueuedAt: .distantPast)
                try await store.enqueueManualRefresh(request)
                let baseline = try await store.newEpisodeNotificationBaseline(manualRequestID: request.id)
                #expect(baseline.counts == (state == .subscribed ? [feed.id: 2] : [:]))
                let saved = try #require(try await store.feed(id: feed.id))
                let notice = try await store.newEpisodeNotification(for: saved, baseline: baseline)
                #expect(notice?.count == (state == .subscribed ? nil : 2))
                #expect(try await store.newEpisodeCounts(feedIDs: [feed.id]) == [feed.id: 2])
            }
        }
    }

    @Test func baselineRemainsFixedFreshCountsReflectUserActionsAndOwnershipRejectsReplacement() async throws {
        try await withStore { store, _ in
            let feed = try await insert(store)
            try await store.updatePreferences(feedID: feed.id) { $0.showEpisodeNotification = true; $0.customTitle = "Custom" }
            for episode in feed.episodes { try await store.updateEpisode(id: episode.id) { $0.userState.playState = .unplayed } }
            let request = FeedRefreshRequest(feedID: feed.id, enqueuedAt: .distantPast)
            try await store.enqueueManualRefresh(request)
            let baseline = try await store.newEpisodeNotificationBaseline(manualRequestID: request.id)
            #expect(baseline.counts.isEmpty)
            let saved = try #require(try await store.feed(id: feed.id))
            #expect(try await store.newEpisodeNotification(for: saved, baseline: baseline) == nil)
            try await store.updateEpisode(id: feed.episodes[0].id) { $0.userState.playState = .new }
            #expect(try await store.newEpisodeNotification(for: saved, baseline: baseline)?.count == 1)
            try await store.updateEpisode(id: feed.episodes[1].id) { $0.userState.playState = .new }
            #expect(try await store.newEpisodeNotification(for: saved, baseline: baseline)?.count == 2)
            try await store.updatePreferences(feedID: feed.id) { $0.showEpisodeNotification = false; $0.customTitle = "Changed after refresh" }
            // Original uses the returned refresh snapshot's preference/title,
            // but queries the current count independently.
            #expect(try await store.newEpisodeNotification(for: saved, baseline: baseline)?.title == "Custom")
            let disabled = try #require(try await store.feed(id: feed.id))
            #expect(try await store.newEpisodeNotification(for: disabled, baseline: baseline) == nil)
            try await store.updateEpisode(id: feed.episodes[0].id) { $0.userState.playState = .played }
            try await store.updateEpisode(id: feed.episodes[1].id) { $0.userState.playState = .unplayed }
            #expect(try await store.newEpisodeNotification(for: saved, baseline: baseline) == nil)
            let next = FeedRefreshRequest(feedID: nil, enqueuedAt: .distantPast)
            try await store.enqueueManualRefresh(next)
            await #expect(throws: CancellationError.self) { try await store.newEpisodeNotification(for: saved, baseline: baseline) }
            await #expect(throws: CancellationError.self) { try await store.newEpisodeNotificationBaseline(manualRequestID: request.id) }
            #expect(try await store.manualRefreshRequest() == next)
        }
    }

    @Test func realRefreshWorkerCapturesBaselineThenUsesCommittedNewEpisodeTotal() async throws {
        try await withStore { store, _ in
            let feed = try await insert(store)
            try await store.updatePreferences(feedID: feed.id) { $0.showEpisodeNotification = true }
            try await store.updateEpisode(id: feed.episodes[0].id) { $0.userState.playState = .new }
            try await store.updateEpisode(id: feed.episodes[1].id) { $0.userState.playState = .played }
            let request = FeedRefreshRequest(feedID: feed.id, enqueuedAt: .distantPast)
            try await store.enqueueManualRefresh(request)
            let monitor = DownloadNetworkMonitor(startMonitoring: false)
            monitor.update(.init(connected: true, metered: false, cellular: false))
            let effects = NotificationWorkerEffects(store: store)
            let remote = FeedRefreshService(store: store, fetcher: FeedFetcher(transport: NotificationHTTP()))
            let worker = FeedRefreshWorker(store: store, remote: remote, local: LocalFeedRefreshService(store: store),
                localDescription: "", localAuthor: "", network: monitor, credentials: { _ in nil },
                options: { _ in FeedRefreshOptions() }, effects: effects)
            try await worker.run(request)
            #expect(await effects.baseline?.counts == [feed.id: 1])
            let notices = await effects.notices
            #expect(notices.count == 1 && notices.first?.count == 2)
            #expect(try await store.newEpisodeCounts(feedIDs: [feed.id]) == [feed.id: 2])
            #expect(try await store.feed(id: feed.id)?.episodes.count == 3)
            #expect(try await store.manualRefreshRequest() == nil)
        }
    }
}

private actor NotificationWorkerEffects: FeedRefreshEffects {
    let store: FeedLibraryStore
    var baseline: NewEpisodeNotificationBaseline?
    var notices: [NewEpisodeNotification] = []
    init(store: FeedLibraryStore) { self.store = store }
    func handle(_ event: FeedRefreshWorker.Event, request: FeedRefreshRequest) async throws {
        switch event {
        case .prepareNotifications: baseline = try await store.newEpisodeNotificationBaseline(manualRequestID: request.id)
        case .refreshed(let feed):
            guard let baseline, baseline.requestID == request.id else { throw FeedLibraryError.invalidMutation }
            if let notice = try await store.newEpisodeNotification(for: feed, baseline: baseline) { notices.append(notice) }
        default: break // Test recipient: no OS notifications or other completion effects.
        }
    }
}

private struct NotificationHTTP: FeedHTTPTransport {
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
        FeedHTTPResponse(url: request.url!, status: 200, body: Data("""
            <rss version="2.0"><channel><title>Original</title>
            <item><guid>one</guid><title>One</title></item>
            <item><guid>two</guid><title>Two</title></item>
            <item><guid>three</guid><title>Three</title></item>
            </channel></rss>
            """.utf8))
    }
}
