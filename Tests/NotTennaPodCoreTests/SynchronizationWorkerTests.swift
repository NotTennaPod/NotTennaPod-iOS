import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.timeLimit(.minutes(1)))
struct SynchronizationWorkerTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func fixture(_ body: (FeedLibraryStore, URL, LibraryFeed) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SyncWorker-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let feed = try await store.insert(fetched())
        do { try await body(store, root, feed); try await store.close() }
        catch { try? await store.close(); throw error }
    }
    private nonisolated func fetched(source: String = "https://example.test/feed") -> FetchedFeed {
        .init(feed: .init(format: .rss, title: "Podcast", episodes: (1...2).map {
            .init(identifier: "guid-\($0)", title: "Episode \($0)", publicationDate: Date(timeIntervalSince1970: Double($0)),
                  media: .init(url: source + "/\($0).mp3", size: 100, durationMilliseconds: 100_000))
        }), source: source, responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil)
    }
    private func request(_ store: FeedLibraryStore, connected: Bool = true) async throws -> SynchronizationRequest {
        if connected, try await store.synchronizationState().accountID == nil { try await store.selectSynchronizationAccount(UUID()) }
        return try #require(try await store.requestSynchronization(immediately: true, now: now))
    }
    private func online() -> DownloadNetworkMonitor {
        let network = DownloadNetworkMonitor(startMonitoring: false)
        network.update(.init(connected: true, metered: false, cellular: false))
        return network
    }
    private func subscriptions(_ store: FeedLibraryStore) -> SynchronizationSubscriptions {
        .init(store: store, deletion: FeedDeletionCoordinator(store: store, retirePlayback: { _ in }, retireDownloads: { _ in }), redirect: { _ in nil })
    }
    private func worker(_ store: FeedLibraryStore, provider: WorkerProvider, effects: WorkerEffects,
                        network: DownloadNetworkMonitor? = nil,
                        wait: @escaping @Sendable () async throws -> Void = {},
                        refresh: @escaping @Sendable () async throws -> Void = {}) -> SynchronizationWorker {
        .init(store: store, subscriptions: subscriptions(store), provider: { _ in provider },
              waitForRefresh: wait, requestRefresh: refresh, effects: effects, network: network ?? online(), clock: { now })
    }
    private func until(_ body: () async throws -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while try await !body(), ContinuousClock.now < end { await Task.yield() }
        try #require(try await body())
    }
    private func play(_ feed: LibraryFeed, position: Int32 = 90) -> SynchronizationEpisodeAction {
        let item = feed.episodes[0]
        return .init(podcast: feed.source, episode: item.details.media!.url!, guid: item.details.identifier,
                     action: .play, timestamp: now, started: 0, position: position, total: 100)
    }

    @Test func completeSequenceAppliesRemoteStateThenUploadsFirstPlayedHistoryAndClearsErrors() async throws {
        try await fixture { store, _, feed in
            _ = try await store.enqueue([feed.episodes[0].id])
            let request = try await request(store), trace = WorkerTrace()
            let provider = WorkerProvider(trace: trace, episodes: [play(feed)])
            let effects = WorkerEffects(trace: trace)
            let worker = worker(store, provider: provider, effects: effects, wait: { trace.append("wait") })
            #expect(try await worker.run(request) == .success)
            #expect(trace.entries == ["login", "status:subscriptions", "subscriptions", "subscriptionUpload", "status:waitingForRefresh", "wait",
                "status:downloadingEpisodes", "episodes", "episodesChanged", "status:uploadingEpisodes", "status:uploadingPlayed", "episodeUpload", "logout", "clear", "status:success"])
            let episode = try #require(try await store.episode(id: feed.episodes[0].id))
            var expected = feed.episodes[0]; expected.userState.playState = .played; expected.userState.positionMilliseconds = 0
            #expect(episode == expected)
            #expect(try await store.queue().isEmpty)
            let uploaded = try #require(provider.uploads.withLock { $0.first })
            #expect(uploaded.count == 1 && uploaded[0].started == 100 && uploaded[0].position == 100 && uploaded[0].total == 100)
            #expect(uploaded[0].timestamp == now)
            let state = try await store.synchronizationState()
            #expect(state.subscriptionTimestamp == 12 && state.episodeTimestamp == 22)
            #expect(state.lastAttempt == now && state.lastAttemptSuccessful && state.request == nil)
            #expect(try await store.synchronizationQueue().isEmpty)
        }
    }

    @Test func emptyEpisodeUploadUsesDownloadCursorAndSkipsUpload() async throws {
        try await fixture { store, _, _ in
            let request = try await request(store), provider = WorkerProvider(), effects = WorkerEffects()
            #expect(try await worker(store, provider: provider, effects: effects).run(request) == .success)
            #expect(provider.uploads.withLock { $0 }.isEmpty)
            #expect(try await store.synchronizationState().episodeTimestamp == 21)
            #expect(effects.events.withLock { $0 }.contains(.status(.uploadingPlayed)))
        }
    }

    @Test func noProviderDoesNotResolveCredentialsEmitStatusOrInventAttempt() async throws {
        try await fixture { store, _, _ in
            let request = try await request(store, connected: false), effects = WorkerEffects()
            let worker = SynchronizationWorker(store: store, subscriptions: subscriptions(store), provider: { _ in
                Issue.record("Disconnected worker must not resolve credentials"); throw SynchronizationError.notLoggedIn
            }, waitForRefresh: { Issue.record("Unexpected wait") }, requestRefresh: { Issue.record("Unexpected refresh") },
               effects: effects, network: online(), clock: { now })
            #expect(try await worker.run(request) == .noProvider)
            let state = try await store.synchronizationState()
            #expect(state.lastAttempt == nil && !state.lastAttemptSuccessful && state.request == nil)
            #expect(effects.events.withLock { $0 }.isEmpty)
        }
    }

    @Test func newlyDownloadedSubscriptionsDeferEpisodesUntilRefreshCompletes() async throws {
        try await fixture { store, _, _ in
            let request = try await request(store), provider = WorkerProvider(added: ["https://new.test/feed"]), effects = WorkerEffects()
            let refreshCount = Mutex(0)
            #expect(try await worker(store, provider: provider, effects: effects, refresh: {
                refreshCount.withLock { $0 += 1 }
            }).run(request) == .waitingForRefresh)
            #expect(refreshCount.withLock { $0 } == 1)
            #expect(!provider.steps.withLock { $0 }.contains("episodes"))
            #expect(!provider.steps.withLock { $0 }.contains("logout"))
            #expect(!effects.events.withLock { $0 }.contains(.status(.success)))
            let state = try await store.synchronizationState()
            #expect(state.episodeTimestamp == 0 && !state.lastAttemptSuccessful)
            // The subscription side effect submitted a newer request; finishing
            // this pass must not erase it while refresh is still outstanding.
            #expect(state.request?.id != request.id && state.request != nil)
            let newFeed = try #require(try await store.feeds().first { $0.source == "https://new.test/feed" })
            _ = try await store.applyRefresh(fetched(source: newFeed.source), feedID: newFeed.id)
            let next = try await self.request(store)
            #expect(try await worker(store, provider: WorkerProvider(), effects: WorkerEffects()).run(next) == .success)
        }
    }

    @Test func sourceRefreshDecisionIncludesArchivedAndSkipsKeepUpdatedDisabled() async throws {
        try await fixture { store, _, _ in
            let request = try await request(store), epoch = try await store.synchronizationState().epoch
            let unknown = try #require(try await store.addSynchronizationSubscription("https://unknown.test/feed", redirected: nil, epoch: epoch))
            try await store.updatePreferences(feedID: unknown.id) { $0.subscriptionState = .archived }
            #expect(try await store.needsSynchronizationFeedRefresh(epoch: epoch))
            try await store.updatePreferences(feedID: unknown.id) { $0.keepUpdated = false }
            #expect(try await store.needsSynchronizationFeedRefresh(epoch: epoch) == false)
            _ = request
        }
    }

    @Test func existingRefreshIsAwaitedAndCancellationOnlyCancelsTheWaiter() async throws {
        try await fixture { store, _, feed in
            let gate = SyncWorkerGate(), request = try await request(store), provider = WorkerProvider()
            let refresh = ManualFeedRefreshCoordinator(store: store) { refreshRequest in
                try await gate.wait()
                guard try await store.finishManualRefresh(id: refreshRequest.id) else { throw CancellationError() }
            }
            let manual = try await refresh.runOnce(feedID: feed.id).value
            defer { gate.open(); refresh.suspend() }
            let worker = SynchronizationWorker(store: store, subscriptions: subscriptions(store), refresh: refresh,
                provider: { _ in provider }, effects: WorkerEffects(), network: online(), clock: { now }, smartMarkAsPlayedSeconds: { 30 })
            let task = Task { try await worker.run(request) }
            defer { task.cancel() }
            try await until { provider.steps.withLock { $0 }.contains("subscriptionUpload") }
            #expect(!provider.steps.withLock { $0 }.contains("episodes"))
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(refresh.state == .active(manual))
            #expect(try await store.manualRefreshRequest() == manual)
            gate.open()
            try await refresh.waitUntilIdle()
            #expect(try await store.manualRefreshRequest() == nil)
            let next = try await self.request(store)
            #expect(try await worker.run(next) == .success)
        }
    }

    @Test func refreshWaitFollowsReplacementAndKeepsUICallback() async throws {
        try await fixture { store, _, feed in
            let first = SyncWorkerGate(), second = SyncWorkerGate(), observed = Mutex<[ManualFeedRefreshCoordinator.State]>([])
            let refresh = ManualFeedRefreshCoordinator(store: store) { request in
                try await (request.feedID == feed.id ? first : second).wait()
                guard try await store.finishManualRefresh(id: request.id) else { throw CancellationError() }
            }
            defer { first.open(); second.open(); refresh.suspend() }
            refresh.onChange = { state in observed.withLock { $0.append(state) } }
            _ = try await refresh.runOnce(feedID: feed.id).value
            let returned = Mutex(false)
            let wait = Task { try await refresh.waitUntilIdle(); returned.withLock { $0 = true } }
            defer { wait.cancel() }
            let replacement = try await refresh.runOnce(feedID: nil).value
            first.open()
            try await until { second.entries > 0 }
            #expect(!returned.withLock { $0 })
            #expect(refresh.state == .active(replacement))
            second.open()
            try await wait.value
            #expect(returned.withLock { $0 } && observed.withLock { $0 }.last == .idle)
        }
    }

    @Test(arguments: [SynchronizationCredentialError.missing, .keychain(-25308), .corrupt])
    func credentialResolutionFailureRetainsRetryableWork(error: SynchronizationCredentialError) async throws {
        try await fixture { store, _, _ in
            let request = try await request(store), effects = WorkerEffects()
            let work = SynchronizationWorker(store: store, subscriptions: subscriptions(store), provider: { _ in throw error },
                waitForRefresh: {}, requestRefresh: {}, effects: effects, network: online(), clock: { now })
            let retry = error != .corrupt
            #expect(try await work.run(request) == (retry ? .retry : .failed))
            let state = try await store.synchronizationState()
            #expect(state.request?.attempts == (retry ? 1 : nil))
            #expect(state.request?.id == (retry ? request.id : nil))
            #expect(!state.lastAttemptSuccessful)
        }
    }

    @Test func providerFailuresRetryAndOnlyEveryThirdAttemptReportsError() async throws {
        try await fixture { store, _, _ in
            var request = try await request(store)
            for attempt in 0..<4 {
                let effects = WorkerEffects(), provider = WorkerProvider(hook: { step in
                    if step == "login" { throw SynchronizationError.authentication }
                })
                #expect(try await worker(store, provider: provider, effects: effects).run(request) == .retry)
                let state = try await store.synchronizationState()
                #expect(!state.lastAttemptSuccessful && state.lastAttempt == now)
                let next = try #require(state.request)
                #expect(next.id == request.id && next.attempts == attempt + 1)
                #expect(next.notBefore == now.addingTimeInterval(600 * pow(2, Double(attempt))))
                #expect(effects.events.withLock { $0 }.filter { if case .reportError = $0 { true } else { false } }.count == (attempt == 2 ? 1 : 0))
                #expect(effects.events.withLock { $0 }.first == .status(.error))
                request = next
            }
        }
    }

    @Test func errorDeliveryKeepsExecutionLeaseAndPreservesItsNewerRequest() async throws {
        try await fixture { store, _, _ in
            let request = try await request(store)
            let effects = WorkerEffects(hook: { event in
                guard event == .status(.error) else { return }
                let next = try #require(try await store.requestSynchronization(now: now))
                #expect(next.notBefore == now.addingTimeInterval(120))
                await #expect(throws: CancellationError.self) { try await store.beginSynchronization(next, now: now) }
            })
            let provider = WorkerProvider(hook: { step in if step == "login" { throw SynchronizationError.authentication } })
            #expect(try await worker(store, provider: provider, effects: effects).run(request) == .retry)
            let next = try #require(try await store.synchronizationState().request)
            #expect(next.id != request.id && next.attempts == 0)
            #expect(try await worker(store, provider: WorkerProvider(), effects: WorkerEffects()).run(next) == .success)
        }
    }

    @Test func fatalFailureReportsImmediatelyAndLeavesUnsentOutbox() async throws {
        try await fixture { store, _, feed in
            let request = try await request(store)
            try await store.markEpisodePlayed(episodeID: feed.episodes[0].id, played: true, now: now)
            let current = try #require(try await store.synchronizationState().request), before = try await store.synchronizationQueue()
            let provider = WorkerProvider(hook: { step in if step == "login" { throw FeedLibraryError.invalidMutation } }), effects = WorkerEffects()
            #expect(try await worker(store, provider: provider, effects: effects).run(current) == .failed)
            #expect(try await store.synchronizationQueue() == before)
            #expect(try await store.synchronizationState().request == nil)
            #expect(effects.events.withLock { $0 }.count == 2)
            #expect(!provider.steps.withLock { $0 }.contains("logout"))
            _ = request
        }
    }

    @Test func interruptedUploadRetainsEpisodeCursorAndQueueForRetry() async throws {
        try await fixture { store, _, feed in
            _ = try await request(store)
            try await store.markEpisodePlayed(episodeID: feed.episodes[0].id, played: true, now: now)
            let request = try #require(try await store.synchronizationState().request), before = try await store.synchronizationQueue()
            let provider = WorkerProvider(hook: { step in if step == "episodeUpload" { throw URLError(.networkConnectionLost) } })
            #expect(try await worker(store, provider: provider, effects: WorkerEffects()).run(request) == .retry)
            #expect(try await store.synchronizationQueue() == before)
            #expect(try await store.synchronizationState().episodeTimestamp == 0)
            #expect(try await store.synchronizationState().subscriptionTimestamp == 12)
        }
    }

    @Test func newerChangesDuringEpisodeUploadSurviveAcknowledgementAndCompletion() async throws {
        try await fixture { store, _, feed in
            _ = try await request(store)
            try await store.markEpisodePlayed(episodeID: feed.episodes[0].id, played: true, now: now)
            let request = try #require(try await store.synchronizationState().request)
            let provider = WorkerProvider(hook: { step in
                if step == "episodeUpload" { try await store.markEpisodePlayed(episodeID: feed.episodes[1].id, played: true) }
            })
            #expect(try await worker(store, provider: provider, effects: WorkerEffects()).run(request) == .success)
            let queue = try await store.synchronizationQueue()
            #expect(queue.count == 1)
            guard case .episode(let action) = queue[0].value else { Issue.record("Expected episode change"); return }
            #expect(action.guid == feed.episodes[1].details.identifier)
            #expect(try await store.synchronizationState().request?.id != request.id)
        }
    }

    @Test func accountChangedDuringEpisodeFetchPreventsMutationReceiptAndSuccess() async throws {
        try await fixture { store, _, feed in
            let request = try await request(store), effects = WorkerEffects(), before = try await store.snapshot()
            let provider = WorkerProvider(episodes: [play(feed)], hook: { step in
                if step == "episodes" { try await store.selectSynchronizationAccount(UUID()) }
            })
            let work = worker(store, provider: provider, effects: effects)
            await #expect(throws: CancellationError.self) { try await work.run(request) }
            #expect(try await store.snapshot() == before)
            #expect(try await store.synchronizationState().episodeTimestamp == 0)
            #expect(!effects.events.withLock { $0 }.contains(.status(.success)))
            #expect(!effects.events.withLock { $0 }.contains(.status(.error)))
        }
    }

    @Test func cancellationReleasesExecutionRetainsRequestAndDoesNotReportFailure() async throws {
        try await fixture { store, _, _ in
            let request = try await request(store), gate = SyncWorkerGate(), effects = WorkerEffects()
            let provider = WorkerProvider(hook: { step in if step == "episodes" { try await gate.wait() } })
            let work = worker(store, provider: provider, effects: effects)
            let task = Task { try await work.run(request) }
            defer { task.cancel(); gate.open() }
            try await until { gate.entries > 0 }
            let duplicate = Task { try await work.run(request) }
            await #expect(throws: CancellationError.self) { try await duplicate.value }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.synchronizationState().request == request)
            #expect(!effects.events.withLock { $0 }.contains(.status(.error)))
            #expect(try await worker(store, provider: WorkerProvider(), effects: WorkerEffects()).run(request) == .success)
        }
    }

    @Test func realProviderNewSubscriptionRefreshAndEpisodeSyncCompleteAcrossTwoPasses() async throws {
        try await fixture { store, _, oldFeed in
            try await store.updatePreferences(feedID: oldFeed.id) { $0.keepUpdated = false }
            let address = Mutex("")
            let server = try await LoopbackHTTPServer.start { request in
                let source = address.withLock { $0 }
                if request.path == "/podcast" {
                    return .init(body: Data("""
                    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>Remote podcast</title><item><guid>remote-1</guid><title>Remote episode</title><pubDate>Tue, 14 Nov 2023 20:00:00 GMT</pubDate><enclosure url="https://media.test/remote.mp3" type="audio/mpeg" length="100"/><itunes:duration>100</itunes:duration></item></channel></rss>
                    """.utf8))
                }
                if request.method == "POST" { return .init(body: Data("{}".utf8)) }
                let body: [String: Any]
                if request.path.contains("/subscriptions") {
                    body = ["add": [source], "remove": [], "timestamp": 31]
                } else {
                    body = ["timestamp": 41, "actions": [["podcast": source, "episode": "https://media.test/remote.mp3", "guid": "remote-1", "action": "play",
                        "timestamp": "2023-11-14T22:13:20", "started": 0, "position": 90, "total": 100]]]
                }
                return .init(body: try! JSONSerialization.data(withJSONObject: body))
            }
            defer { server.stop() }
            address.withLock { $0 = server.url.deletingLastPathComponent().appendingPathComponent("podcast").absoluteString }
            let provider = try SynchronizationHTTPClient(backend: .nextcloud, host: server.url.deletingLastPathComponent().absoluteString,
                username: "fixture", password: "fixture", clock: { Date(timeIntervalSince1970: 50) })
            let network = online(), refreshEffects = RefreshHandoffEffects(store: store)
            let remote = FeedRefreshService(store: store, clock: { now })
            let refreshWorker = FeedRefreshWorker(store: store, network: network, effects: refreshEffects, shuffle: { $0 }) { feed, request in
                switch try await remote.refresh(feedID: feed.id, force: request.force, manualRequestID: request.id) {
                case .updated(let result): return .updated(result.feed)
                case .unchanged: return .unchanged
                case .failed: return .failed
                }
            }
            let refresh = ManualFeedRefreshCoordinator(store: store, worker: refreshWorker)
            defer { refresh.suspend() }
            let effects = WorkerEffects()
            let sync = SynchronizationWorker(store: store, subscriptions: subscriptions(store), refresh: refresh,
                provider: { _ in provider }, effects: effects, network: network, clock: { now }, smartMarkAsPlayedSeconds: { 30 })
            let first = try await request(store)
            #expect(try await sync.run(first) == .waitingForRefresh)
            try await refresh.waitUntilIdle()
            let refreshed = try #require(try await store.feeds().first { $0.source == address.withLock { $0 } })
            #expect(refreshed.title == "Remote podcast" && refreshed.episodes.count == 1)
            #expect(refreshed.lastRefreshAttempt == now)
            #expect(refreshed.episodes[0].userState.playState != .played)
            #expect(refreshEffects.events.withLock { $0 }.contains(.synchronize))
            let second = try #require(try await store.synchronizationState().request)
            #expect(second.id != first.id)
            #expect(try await sync.run(second) == .success)
            let complete = try #require(try await store.episode(id: refreshed.episodes[0].id))
            #expect(complete.userState.playState == .played && complete.userState.positionMilliseconds == 0)
            #expect(try await store.synchronizationState().episodeTimestamp == 50)
            #expect(try await store.synchronizationState().lastAttemptSuccessful)
            #expect(try await store.synchronizationQueue().isEmpty)
            let paths = server.requests.map(\.path)
            let feedFetch = try #require(paths.firstIndex(of: "/podcast")), episodeFetch = try #require(paths.firstIndex { $0.contains("/episode_action") })
            #expect(feedFetch < episodeFetch)
            #expect(server.requests.filter { $0.path == "/podcast" }.allSatisfy { $0.headers["authorization"] == nil })
        }
    }

    @Test(arguments: ["login", "subscriptions", "subscriptionUpload", "episodes", "episodeUpload", "logout"])
    func serviceFailureAtEachNetworkPhaseRetainsCorrectCommittedCursors(_ failedStep: String) async throws {
        try await fixture { store, _, feed in
            _ = try await request(store)
            try await store.markEpisodePlayed(episodeID: feed.episodes[0].id, played: true, now: now)
            let request = try #require(try await store.synchronizationState().request)
            let before = try await store.synchronizationQueue()
            let provider = WorkerProvider(hook: { step in if step == failedStep { throw SynchronizationError.httpStatus(503) } })
            #expect(try await worker(store, provider: provider, effects: WorkerEffects()).run(request) == .retry)
            let state = try await store.synchronizationState()
            let subscriptionsAccepted = ["episodes", "episodeUpload", "logout"].contains(failedStep)
            #expect(state.subscriptionTimestamp == (subscriptionsAccepted ? 12 : 0))
            #expect(state.episodeTimestamp == (failedStep == "logout" ? 22 : 0))
            #expect(try await store.synchronizationQueue() == (failedStep == "logout" ? [] : before))
            #expect(!state.lastAttemptSuccessful && state.request?.attempts == 1)
        }
    }

    @Test func networkConstraintWaitsBeforeAttemptAndLossCancelsInFlightWork() async throws {
        try await fixture { store, _, _ in
            let request = try await request(store), network = DownloadNetworkMonitor(startMonitoring: false)
            network.update(.init(connected: true, metered: true, cellular: true))
            let gate = SyncWorkerGate(), provider = WorkerProvider(hook: { step in if step == "login" { try await gate.wait() } }), effects = WorkerEffects()
            let work = worker(store, provider: provider, effects: effects, network: network)
            let task = Task { try await work.run(request) }
            defer { task.cancel(); gate.open() }
            try await until { network.pendingWaitCount > 0 }
            #expect(try await store.synchronizationState().lastAttempt == nil)
            #expect(provider.steps.withLock { $0 }.isEmpty)
            network.update(.init(connected: true, metered: false, cellular: false))
            try await until { gate.entries > 0 }
            network.update(.init(connected: false, metered: true, cellular: false))
            await #expect(throws: DownloadNetworkInterruption.self) { try await task.value }
            #expect(effects.events.withLock { $0 }.isEmpty)
            #expect(try await store.synchronizationState().request == request)
            #expect(try await store.synchronizationState().lastAttempt == now)
        }
    }
}

private final class WorkerProvider: SynchronizationProvider {
    let trace: WorkerTrace
    let steps = Mutex<[String]>([]), uploads = Mutex<[[SynchronizationEpisodeAction]]>([])
    let added: [String], episodes: [SynchronizationEpisodeAction]
    let hook: @Sendable (String) async throws -> Void
    init(trace: WorkerTrace = WorkerTrace(), added: [String] = [], episodes: [SynchronizationEpisodeAction] = [],
         hook: @escaping @Sendable (String) async throws -> Void = { _ in }) {
        self.trace = trace; self.added = added; self.episodes = episodes; self.hook = hook
    }
    private func step(_ name: String) async throws {
        trace.append(name); steps.withLock { $0.append(name) }; try await hook(name)
    }
    func login() async throws { try await step("login") }
    func logout() async throws { try await step("logout") }
    func subscriptionChanges(since: Int64) async throws -> SynchronizationSubscriptionChanges {
        try await step("subscriptions"); return .init(added: added, removed: [], timestamp: 11)
    }
    func uploadSubscriptions(added: [String], removed: [String]) async throws -> SynchronizationUploadResult {
        try await step("subscriptionUpload"); return .init(timestamp: 12)
    }
    func episodeChanges(since: Int64) async throws -> SynchronizationEpisodeChanges {
        try await step("episodes"); return .init(actions: episodes, timestamp: 21)
    }
    func uploadEpisodeActions(_ actions: [SynchronizationEpisodeAction]) async throws -> SynchronizationUploadResult? {
        uploads.withLock { $0.append(actions) }; try await step("episodeUpload"); return .init(timestamp: 22)
    }
}

private final class WorkerEffects: SynchronizationWorkerEffects {
    let trace: WorkerTrace
    let events = Mutex<[SynchronizationWorker.Event]>([])
    let hook: @Sendable (SynchronizationWorker.Event) async throws -> Void
    init(trace: WorkerTrace = WorkerTrace(), hook: @escaping @Sendable (SynchronizationWorker.Event) async throws -> Void = { _ in }) {
        self.trace = trace; self.hook = hook
    }
    func handle(_ event: SynchronizationWorker.Event, epoch: UUID) async throws {
        events.withLock { $0.append(event) }
        let name: String
        switch event {
        case .status(let value): name = "status:\(value)"
        case .episodesChanged: name = "episodesChanged"
        case .clearErrorNotifications: name = "clear"
        case .reportError: name = "report"
        }
        trace.append(name)
        try await hook(event)
    }
}

private final class SyncWorkerGate: Sendable {
    private struct State {
        var opened = false
        var entries = 0
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    }
    private let state = Mutex(State())
    var entries: Int { state.withLock { $0.entries } }
    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = state.withLock { state in
                    state.entries += 1
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if state.opened { return .success(()) }
                    state.waiters[id] = continuation
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            self.state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }
    func open() {
        let waiting = state.withLock { state in
            state.opened = true
            let waiting = Array(state.waiters.values); state.waiters.removeAll(); return waiting
        }
        for waiter in waiting { waiter.resume() }
    }
}

private final class WorkerTrace: Sendable {
    private let storage = Mutex<[String]>([])
    var entries: [String] { storage.withLock { $0 } }
    func append(_ entry: String) { storage.withLock { $0.append(entry) } }
}

private final class RefreshHandoffEffects: FeedRefreshEffects {
    let store: FeedLibraryStore
    let events = Mutex<[FeedRefreshWorker.Event]>([])
    init(store: FeedLibraryStore) { self.store = store }
    func handle(_ event: FeedRefreshWorker.Event, request: FeedRefreshRequest) async throws {
        events.withLock { $0.append(event) }
        if event == .synchronize { _ = try await store.requestSynchronization() }
    }
}
