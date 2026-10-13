import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct PeriodicFeedRefreshTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func fixture(_ body: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Periodic-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("library.sqlite"), store = try FeedLibraryStore(url: file)
        do { try await body(store, file); try await store.close() }
        catch { try? await store.close(); throw error }
    }
    private func fetched(_ ids: [String] = ["old"], source: String = "https://example.com/feed") -> FetchedFeed {
        .init(feed: .init(format: .rss, title: "Periodic", episodes: ids.map { .init(identifier: $0, title: $0) }),
            source: source, responseURL: URL(string: source)!, validator: "etag", permanentRedirectURL: nil)
    }
    private func until(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try await !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(try await condition())
    }
    @Test(arguments: PeriodicFeedRefreshSchedule.intervals.filter { $0 > 0 })
    func intervalBoundaryAndSubscriptionEligibility(minutes: Int) async throws {
        try await fixture { store, _ in
            var feed = try await store.insert(fetched())
            let request = FeedRefreshRequest(periodic: .init(intervalMinutes: minutes, allowMobile: false, now: now), enqueuedAt: now)
            let boundary = now.addingTimeInterval(-Double(minutes) * 60 - 900)
            feed.lastRefreshAttempt = boundary
            #expect(request.eligibleFeeds(from: [feed], now: now).count == 1)
            feed.lastRefreshAttempt = boundary.addingTimeInterval(0.001)
            #expect(request.eligibleFeeds(from: [feed], now: now).isEmpty)
            feed.lastRefreshAttempt = nil
            #expect(request.eligibleFeeds(from: [feed], now: now).count == 1)
            feed.keepUpdated = false
            #expect(request.eligibleFeeds(from: [feed], now: now).isEmpty)
            feed.keepUpdated = true; feed.subscriptionState = .notSubscribed
            #expect(request.eligibleFeeds(from: [feed], now: now).isEmpty)
            let manual = FeedRefreshRequest(feedID: feed.id, enqueuedAt: now)
            #expect(manual.eligibleFeeds(from: [feed], now: now).count == 1 && manual.force)
            #expect(!request.force && !request.nextPage && request.requiresNetwork)
        }
    }
    @Test func keepReplaceNeverAndCompletionAreIsolatedFromManualAndNotifications() async throws {
        try await fixture { store, _ in
            let feed = try await store.insert(fetched())
            try await store.updatePreferences(feedID: feed.id) { $0.showEpisodeNotification = true }
            let manual = FeedRefreshRequest(feedID: nil, enqueuedAt: now)
            try await store.enqueueManualRefresh(manual)
            let first = try #require(try await store.configurePeriodicRefresh(intervalMinutes: 720, allowMobile: false, replace: false, now: now))
            #expect(try await store.configurePeriodicRefresh(intervalMinutes: 60, allowMobile: true, replace: false, now: now) == first)
            let periodic = try #require(try await store.beginPeriodicRefresh(now: now))
            #expect(try await store.beginPeriodicRefresh(now: now) == periodic)
            for request in [manual, periodic] {
                _ = try await store.beginEpisodeNotificationAttempt(requestID: request.id)
                _ = try await store.applyRefresh(fetched(["old", request.id.uuidString]), feedID: feed.id, manualRequestID: request.id)
            }
            let manualWork = try await store.pendingEpisodeNotifications(requestID: manual.id)
            #expect(manualWork.count == 1)
            #expect(try await store.pendingEpisodeNotifications(requestID: periodic.id).count == 1)
            #expect(try await store.finishManualRefresh(id: periodic.id) == false)
            _ = try await store.configurePeriodicRefresh(intervalMinutes: 60, allowMobile: true, replace: true, now: now)
            #expect(try await store.refreshRequest(id: periodic.id) == nil)
            #expect(try await store.pendingEpisodeNotifications(requestID: manual.id) == manualWork)
            await #expect(throws: CancellationError.self) { try await store.applyRefresh(fetched(["stale"]), feedID: feed.id, manualRequestID: periodic.id) }
            let second = try #require(try await store.beginPeriodicRefresh(now: now))
            #expect(second.networkConstraint == .connected)
            #expect(try await store.finishRefresh(id: second.id, now: now))
            #expect(try await store.periodicRefreshSchedule()?.nextCheck == now.addingTimeInterval(3600))
            #expect(try await store.beginPeriodicRefresh(now: now.addingTimeInterval(3599)) == nil)
            #expect(try await store.beginPeriodicRefresh(now: now.addingTimeInterval(3600)) != nil)
            _ = try await store.configurePeriodicRefresh(intervalMinutes: 0, allowMobile: false, replace: false, now: now)
            #expect(try await store.periodicRefreshSchedule() == nil)
            #expect(try await store.beginPeriodicRefresh(now: now) == nil)
            #expect(try await store.manualRefreshRequest() == manual)
            #expect(try await store.pendingEpisodeNotifications(requestID: manual.id) == manualWork)
        }
    }
    @Test func schemaElevenMigrationRetainsCommittedNotificationAndManualRecord() async throws {
        try await fixture { store, file in
            let feed = try await store.insert(fetched())
            try await store.updatePreferences(feedID: feed.id) { $0.showEpisodeNotification = true }
            let manual = FeedRefreshRequest(feedID: nil, enqueuedAt: now)
            try await store.enqueueManualRefresh(manual)
            _ = try await store.beginEpisodeNotificationAttempt(requestID: manual.id)
            _ = try await store.applyRefresh(fetched(["old", "new"]), feedID: feed.id, manualRequestID: manual.id)
            let pending = try #require(try await store.pendingEpisodeNotifications(requestID: manual.id).first)
            #expect(try await store.markEpisodeNotificationChildPublished(pending))
            let snapshot = try await store.snapshot(), work = try await store.pendingEpisodeNotifications(requestID: manual.id)
            try await store.close()
            let old = try LibrarySQLite(url: file)
            try restoreRefreshSchemaEleven(old); try old.close()
            let reopened = try FeedLibraryStore(url: file)
            #expect(try await reopened.snapshot() == snapshot)
            #expect(try await reopened.manualRefreshRequest() == manual)
            #expect(try await reopened.pendingEpisodeNotifications(requestID: manual.id) == work)
            #expect(try await reopened.periodicRefreshSchedule() == nil)
            _ = try await reopened.configurePeriodicRefresh(intervalMinutes: 720, allowMobile: false, replace: false, now: now)
            let periodic = try #require(try await reopened.beginPeriodicRefresh(now: now))
            #expect(periodic.id != manual.id)
            let check = try LibrarySQLite(url: file)
            #expect(try check.scalar("PRAGMA user_version") == 20)
            #expect(try check.rows("PRAGMA foreign_key_check").isEmpty)
            try check.close(); try await reopened.close()
        }
    }
    @Test func executionClockAndUnmeteredConstraintApplyBeforeEvenLocalEmptyWork() async throws {
        try await fixture { store, _ in
            let feed = try await store.insert(fetched())
            // Store an actual attempt at the test clock, then enqueue before it is due.
            var options = FeedRefreshOptions(); options.refreshAttempt = now
            _ = try await store.applyRefresh(fetched(), feedID: feed.id, options: options)
            _ = try await store.configurePeriodicRefresh(intervalMinutes: 60, allowMobile: false, replace: false, now: now)
            let request = try #require(try await store.beginPeriodicRefresh(now: now))
            let clock = Mutex(now), network = DownloadNetworkMonitor(startMonitoring: false), events = Events()
            network.update(.init(connected: true, metered: true, cellular: true))
            let worker = FeedRefreshWorker(store: store, network: network, effects: events, clock: { clock.withLock { $0 } }) { feed, request in
                #expect(!request.force); await events.seen(feed.id); return .unchanged
            }
            let task = Task { try await worker.run(request) }; defer { task.cancel() }
            try await until { network.pendingWaitCount > 0 }
            #expect(await events.ids.isEmpty)
            #expect(await events.values.isEmpty)
            clock.withLock { $0 = now.addingTimeInterval(4500) }
            network.update(.init(connected: true, metered: false, cellular: false))
            try await task.value
            #expect(await events.ids == [feed.id])
            // Refresh follow-up work all happens; its internal ordering is not asserted.
            let followUps = await events.values
            for effect: FeedRefreshWorker.Event in [.cleanUnsubscribedFeeds, .autoDownload, .dismissProgress, .synchronize] {
                #expect(followUps.contains(effect))
            }
            #expect(try await store.periodicRefreshSchedule()?.nextCheck == now.addingTimeInterval(8100))
        }
    }
    @MainActor @Test func joinedExecutionExpirationRecoveryAndManualCooldownAreIndependent() async throws {
        try await fixture { store, _ in
            let network = DownloadNetworkMonitor(startMonitoring: false), events = Events()
            network.update(.init(connected: false, metered: true, cellular: false))
            let worker = FeedRefreshWorker(store: store, network: network, effects: events) { _, _ in .unchanged }
            let owner = PeriodicFeedRefreshCoordinator(store: store, worker: worker)
            let manual = ManualFeedRefreshCoordinator(store: store, clock: { 100_000 }, execute: { _ in })
            _ = try await owner.configure(intervalMinutes: 720, allowMobile: false, replace: false).value
            let a = owner.runDue(), b = owner.runDue()
            try await until { network.pendingWaitCount > 0 }
            let saved = try #require(try await store.beginPeriodicRefresh())
            #expect(network.pendingWaitCount == 1)
            #expect(manual.admission(feedID: nil, isLocalFeed: false, network: .init(connected: true, metered: false, cellular: false), refreshAllowed: true) == .run)
            owner.suspend()
            await #expect(throws: CancellationError.self) { try await a.value }
            await #expect(throws: CancellationError.self) { try await b.value }
            #expect(try await store.refreshRequest(id: saved.id) == saved)
            network.update(.init(connected: true, metered: false, cellular: false))
            try await owner.runDue().value
            #expect(try await store.refreshRequest(id: saved.id) == nil)
            #expect(await events.values.filter { $0 == .synchronize }.count == 1)
        }
    }
    @Test func realHTTPUsesValidatorCurrentOptionsAndDoesNotRecheckRecentlyRefreshedFeed() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .init(body: Data("<rss><channel><title>Updated</title><item><guid>old</guid><title>Old</title></item><item><guid>new</guid><title>New</title><enclosure url=\"https://example.com/new.mp3\" type=\"audio/mpeg\" length=\"100\"/></item></channel></rss>".utf8)) }
        defer { server.stop() }
        try await fixture { store, _ in
            var initial = FeedRefreshOptions(); initial.refreshAttempt = Date(timeIntervalSince1970: 0)
            let feed = try await store.insert(fetched(source: server.url.absoluteString), options: initial)
            let network = DownloadNetworkMonitor(startMonitoring: false), events = Events()
            network.update(.init(connected: true, metered: false, cellular: false))
            let worker = FeedRefreshWorker(store: store, remote: .init(store: store, fetcher: FeedFetcher()),
                local: .init(store: store), localDescription: "", localAuthor: "", network: network, credentials: { _ in nil },
                options: { _ in var value = FeedRefreshOptions(); value.globalNewEpisodesAction = .queue; return value }, effects: events)
            _ = try await store.configurePeriodicRefresh(intervalMinutes: 720, allowMobile: false, replace: false)
            try await worker.run(try #require(try await store.beginPeriodicRefresh()))
            try #require(server.requests.count == 1)
            #expect(server.requests[0].headers["if-none-match"] == "etag")
            _ = try await store.consumeFeedRefreshQueueEffects()
            #expect(try await store.queue().map(\.details.identifier) == ["new"])
            #expect(try await store.feed(id: feed.id)?.metadata.title == "Updated")
            _ = try await store.configurePeriodicRefresh(intervalMinutes: 720, allowMobile: false, replace: true)
            try await worker.run(try #require(try await store.beginPeriodicRefresh()))
            #expect(server.requests.count == 1)
            #expect(await events.values.filter { $0 == .synchronize }.count == 2)
        }
    }
    @Test func interleavedManualAndPeriodicNotificationRecipientsRetainTheirOwnBaselines() async throws {
        try await fixture { store, _ in
            let feed = try await store.insert(fetched())
            try await store.updatePreferences(feedID: feed.id) { $0.showEpisodeNotification = true }
            try await store.updateEpisode(id: feed.episodes[0].id) { $0.userState.playState = .played }
            let manual = FeedRefreshRequest(feedID: nil, enqueuedAt: now)
            try await store.enqueueManualRefresh(manual)
            _ = try await store.configurePeriodicRefresh(intervalMinutes: 720, allowMobile: false, replace: false, now: now)
            let periodic = try #require(try await store.beginPeriodicRefresh(now: now))
            let publisher = EpisodeNotificationDeliveryTests.Publisher()
            let delivery = EpisodeNotificationDelivery(store: store, publisher: publisher,
                text: .init(title: { "New \($0)" }, message: { "\($1): \($0)" }, summary: "Inbox"), artwork: { _ in nil })
            try await delivery.prepare(requestID: manual.id)
            try await delivery.prepare(requestID: periodic.id)
            let first = try await store.applyRefresh(fetched(["old", "one"]), feedID: feed.id, manualRequestID: manual.id)
            try await delivery.refreshed(first.feed, requestID: manual.id)
            let second = try await store.applyRefresh(fetched(["old", "one", "two"]), feedID: feed.id, manualRequestID: periodic.id)
            try await delivery.refreshed(second.feed, requestID: periodic.id)
            #expect(publisher.posts.map(\.destination) == [.feed(feed.id), .inbox, .feed(feed.id), .inbox])
            #expect(publisher.posts.map(\.alerts) == [false, true, false, false])
            #expect(try await store.pendingEpisodeNotifications(requestID: manual.id).isEmpty)
            #expect(try await store.pendingEpisodeNotifications(requestID: periodic.id).isEmpty)
        }
    }
    @Test func unmeteredCellularStillBlocksRemoteButNotLocalOnlyWorker() async throws {
        try await fixture { store, _ in
            var options = FeedRefreshOptions(); options.refreshAttempt = Date(timeIntervalSince1970: 0)
            let feed = try await store.insert(fetched(), options: options)
            _ = try await store.configurePeriodicRefresh(intervalMinutes: 60, allowMobile: false, replace: false, now: now)
            let request = try #require(try await store.beginPeriodicRefresh(now: now))
            let network = DownloadNetworkMonitor(startMonitoring: false), events = Events()
            network.update(.init(connected: true, metered: false, cellular: true))
            let worker = FeedRefreshWorker(store: store, network: network, effects: events) { feed, _ in
                await events.seen(feed.id); return .unchanged
            }
            await #expect(throws: PeriodicFeedRefreshNetworkBlocked.self) { try await worker.run(request) }
            #expect(await events.ids.isEmpty)
            #expect(try await store.refreshRequest(id: request.id) == request)
            try await store.updatePreferences(feedID: feed.id) { $0.keepUpdated = false }
            let local = try await store.registerLocalFolder(title: "Local", directoryIdentity: "fixture:periodic", bookmark: Data([1]))
            try await worker.run(request)
            #expect(await events.ids == [local.feed.id])
            #expect(try await store.refreshRequest(id: request.id) == nil)
        }
    }
    private actor Events: FeedRefreshEffects {
        var values: [FeedRefreshWorker.Event] = []
        var ids: [Int64] = []
        func seen(_ id: Int64) { ids.append(id) }
        func handle(_ event: FeedRefreshWorker.Event, request: FeedRefreshRequest) { values.append(event) }
    }
}
