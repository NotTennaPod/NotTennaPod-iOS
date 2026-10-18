import Foundation
import Testing
@testable import NotTennaPodCore

@Suite
struct ManualFeedRefreshWorkerTests {
    private func withStore(_ body: (FeedLibraryStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RefreshWorker-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        do { try await body(store); try await store.close() }
        catch { try? await store.close(); throw error }
    }
    private func insert(_ store: FeedLibraryStore, index: Int = 1) async throws -> LibraryFeed {
        let source = "https://example.com/feed/\(index)"
        return try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Feed \(index)"),
            source: source, responseURL: URL(string: source)!, validator: "old", permanentRedirectURL: nil))
    }
    private func network(connected: Bool = true) -> DownloadNetworkMonitor {
        let result = DownloadNetworkMonitor(startMonitoring: false)
        result.update(.init(connected: connected, metered: true, cellular: true))
        return result
    }
    private func until(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await predicate()) && ContinuousClock.now < deadline { await Task.yield() }
        try #require(await predicate())
    }

    @Test func allFeedsShuffleEligibilityFourWorkerLimitFailuresAndCompletionOrder() async throws {
        try await withStore { store in
            var feeds: [LibraryFeed] = []
            for index in 1...10 { feeds.append(try await insert(store, index: index)) }
            try await store.updatePreferences(feedID: feeds[8].id) { $0.keepUpdated = false }
            try await store.updatePreferences(feedID: feeds[9].id) { $0.subscriptionState = .notSubscribed }
            let request = FeedRefreshRequest(feedID: nil, enqueuedAt: .distantPast)
            try await store.enqueueManualRefresh(request)
            let effects = WorkerEffects(), gate = WorkerGate()
            let worker = FeedRefreshWorker(store: store, network: network(), effects: effects,
                shuffle: { $0.reversed() }, refresh: { try await gate.refresh($0, $1) })
            let task = Task { try await worker.run(request) }; defer { task.cancel() }
            try await until { await gate.started.count == 4 }
            let first = await gate.started
            #expect(Set(first.map(\.0)) == Set(feeds[4...7].map(\.id)))
            #expect(first.allSatisfy { !$0.1.force && !$0.1.nextPage && $0.1.id == request.id })
            // Release a single lane at a time; exactly one next feed may start.
            for index in 0..<4 {
                await gate.finish(first[index].0, outcome: index == 0 ? .failed : .unchanged)
                try await until { await gate.started.count == 5 + index }
                #expect(await gate.peak == 4)
            }
            for feed in feeds.prefix(4) { await gate.finish(feed.id, outcome: .updated(feed)) }
            try await task.value
            let events = await effects.events
            #expect(events.first == .prepareNotifications)
            #expect(events[1] == .remaining(Array(feeds.prefix(8).reversed())))
            let remaining = events.compactMap { if case .remaining(let feeds) = $0 { feeds.count } else { nil } }
            #expect(remaining == Array((1...8).reversed()))
            #expect(events.filter { if case .refreshed = $0 { true } else { false } }.count == 4)
            // After all feeds: preview cleanup, auto-download, progress dismissal and sync all happen (order is internal).
            let tail = Array(events.suffix(4))
            for effect in [FeedRefreshWorker.Event.cleanUnsubscribedFeeds, .autoDownload, .dismissProgress, .synchronize] {
                #expect(tail.contains(effect))
            }
            #expect(try await store.manualRefreshRequest() == nil)
        }
    }

    @Test func missingSelectedFeedAndEmptyAllHaveDifferentPostRefreshEffects() async throws {
        try await withStore { store in
            for id: Int64? in [999, nil] {
                let request = FeedRefreshRequest(feedID: id, enqueuedAt: .distantPast)
                try await store.enqueueManualRefresh(request)
                let effects = WorkerEffects()
                let worker = FeedRefreshWorker(store: store, network: network(), effects: effects) { _, _ in
                    Issue.record("Empty library must not refresh"); return .unchanged
                }
                try await worker.run(request)
                let expected: [FeedRefreshWorker.Event] = id == nil
                    ? [.prepareNotifications, .remaining([]), .cleanUnsubscribedFeeds, .autoDownload, .dismissProgress, .synchronize]
                    : [.prepareNotifications]
                #expect(await effects.events == expected)
                #expect(try await store.manualRefreshRequest() == nil)
            }
        }
    }

    @Test func offlineAllWaitsCancellationRetainsJournalAndCellularPermitsResume() async throws {
        try await withStore { store in
            let request = FeedRefreshRequest(feedID: nil, isLocalFeed: true, enqueuedAt: .distantPast)
            try await store.enqueueManualRefresh(request)
            let monitor = network(connected: false), effects = WorkerEffects()
            let worker = FeedRefreshWorker(store: store, network: monitor, effects: effects) { _, _ in .unchanged }
            let task = Task { try await worker.run(request) }; defer { task.cancel() }
            try await until { monitor.pendingWaitCount == 1 }
            #expect(await effects.events.isEmpty)
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await store.manualRefreshRequest() == request)
            #expect(monitor.pendingWaitCount == 0)
            let resumed = Task { try await worker.run(request) }; defer { resumed.cancel() }
            try await until { monitor.pendingWaitCount == 1 }
            monitor.update(.init(connected: true, metered: true, cellular: true))
            try await resumed.value
            #expect(try await store.manualRefreshRequest() == nil)
        }
    }

    @Test func networkLossCancelsActiveServicesAndRetainsWorkWithoutCompletionEffects() async throws {
        try await withStore { store in
            let feed = try await insert(store)
            let request = FeedRefreshRequest(feedID: feed.id, enqueuedAt: .distantPast)
            try await store.enqueueManualRefresh(request)
            let monitor = network(), effects = WorkerEffects(), gate = WorkerGate()
            let worker = FeedRefreshWorker(store: store, network: monitor, effects: effects) { try await gate.refresh($0, $1) }
            let task = Task { try await worker.run(request) }; defer { task.cancel() }
            try await until { await gate.started.count == 1 }
            monitor.update(.init(connected: false, metered: true, cellular: true))
            await #expect(throws: DownloadNetworkInterruption.self) { try await task.value }
            #expect(await gate.cancelled == [feed.id])
            #expect(await effects.events == [.prepareNotifications, .remaining([feed])])
            #expect(try await store.manualRefreshRequest() == request)
        }
    }

    @Test func replacedRequestCannotPublishReturnedDataOrRemoveItsSuccessor() async throws {
        try await withStore { store in
            let feed = try await insert(store)
            let old = FeedRefreshRequest(feedID: feed.id, enqueuedAt: .distantPast)
            let new = FeedRefreshRequest(feedID: nil, enqueuedAt: .distantPast)
            try await store.enqueueManualRefresh(old)
            let effects = WorkerEffects()
            let worker = FeedRefreshWorker(store: store, network: network(), effects: effects) { _, _ in
                try await store.enqueueManualRefresh(new)
                return .updated(feed) // Deliberately ignores Task cancellation.
            }
            await #expect(throws: CancellationError.self) { try await worker.run(old) }
            #expect(await effects.events == [.prepareNotifications, .remaining([feed])])
            #expect(try await store.manualRefreshRequest() == new)
            await #expect(throws: CancellationError.self) { try await worker.run(old) }
            #expect(await effects.events.count == 2)
        }
    }

    @Test func effectReplacementOrFailureStopsLaterEffectsAndLeavesUnacknowledgedWork() async throws {
        try await withStore { store in
            for replace in [true, false] {
                let old = FeedRefreshRequest(feedID: nil, enqueuedAt: .distantPast)
                let new = FeedRefreshRequest(feedID: 999, enqueuedAt: .distantPast)
                try await store.enqueueManualRefresh(old)
                let effects = WorkerEffects { event in
                    if event == .autoDownload {
                        if replace { try await store.enqueueManualRefresh(new) }
                        else { throw FeedLibraryError.invalidMutation }
                    }
                }
                let worker = FeedRefreshWorker(store: store, network: network(), effects: effects) { _, _ in .unchanged }
                if replace { await #expect(throws: CancellationError.self) { try await worker.run(old) } }
                else { await #expect(throws: FeedLibraryError.self) { try await worker.run(old) } }
                #expect(await effects.events == [.prepareNotifications, .remaining([]), .cleanUnsubscribedFeeds, .autoDownload])
                #expect(try await store.manualRefreshRequest() == (replace ? new : old))
            }
        }
    }

    @Test func localAdapterRunsOfflineIgnoringDisabledUpdatesWithoutCredentialsOrHTTP() async throws {
        try await withStore { store in
            let folder = try await store.registerLocalFolder(title: "Folder", directoryIdentity: "fixture:folder", bookmark: Data([1]))
            try await store.updatePreferences(feedID: folder.feed.id) {
                $0.keepUpdated = false; $0.subscriptionState = .notSubscribed
            }
            let request = FeedRefreshRequest(feedID: folder.feed.id, nextPage: true, isLocalFeed: true, enqueuedAt: .distantPast)
            try await store.enqueueManualRefresh(request)
            let local = LocalFeedRefreshService(store: store, open: { _ in
                .init(files: [], bookmark: { Data([1]) }, readMetadata: { _ in
                    Issue.record("Empty folder has no metadata"); return LocalFileMetadata()
                })
            })
            let effects = WorkerEffects(), monitor = network(connected: false)
            let worker = FeedRefreshWorker(store: store, remote: FeedRefreshService(store: store), local: local,
                localDescription: "Local description", localAuthor: "Local author", network: monitor,
                credentials: { _ in Issue.record("Local feed cannot look up HTTP credentials"); return nil },
                options: { _ in FeedRefreshOptions() }, effects: effects)
            try await worker.run(request)
            let saved = try #require(try await store.feed(id: folder.feed.id))
            #expect(saved.metadata.description == "Local description" && saved.metadata.author == "Local author")
            #expect(!saved.keepUpdated && saved.subscriptionState == .notSubscribed && saved.pageNumber == 0)
            #expect(await effects.events.contains(.refreshed(saved)))
            #expect(monitor.pendingWaitCount == 0)
            #expect(try await store.manualRefreshRequest() == nil)
        }
    }

    @Test func remoteAdapterPreservesForcedPaginationCredentialsValidatorsAndFailureLogs() async throws {
        for selected in [false, true] {
            for status in [200, 304, 403] {
                try await withStore { store in
                    var parsed = ParsedFeed(format: .rss, title: "Original")
                    parsed.nextPageURL = "https://example.com/page2"
                    let feed = try await store.insert(FetchedFeed(feed: parsed, source: "https://example.com/feed",
                        responseURL: URL(string: "https://example.com/feed")!, validator: "old", permanentRedirectURL: nil))
                    if selected {
                        try await store.updatePreferences(feedID: feed.id) { $0.keepUpdated = false; $0.subscriptionState = .notSubscribed }
                    }
                    let request = FeedRefreshRequest(feedID: selected ? feed.id : nil, nextPage: true, enqueuedAt: .distantPast)
                    try await store.enqueueManualRefresh(request)
                    let http = WorkerHTTP(status: status), effects = WorkerEffects()
                    let worker = FeedRefreshWorker(store: store,
                        remote: FeedRefreshService(store: store, fetcher: FeedFetcher(transport: http)),
                        local: LocalFeedRefreshService(store: store), localDescription: "", localAuthor: "", network: network(),
                        credentials: { id in
                            #expect(id == feed.id); return FeedCredentials(username: "u", password: "p")
                        }, options: { id in #expect(id == feed.id); return FeedRefreshOptions() }, effects: effects)
                    try await worker.run(request)
                    let sent = try #require(await http.requests.first)
                    #expect(await http.requests.count == 2)
                    #expect(sent.url?.absoluteString == (selected ? "https://example.com/page2" : "https://example.com/feed"))
                    #expect(sent.value(forHTTPHeaderField: "If-None-Match") == (selected ? nil : "old"))
                    // Credentials are sent after the server's 401 challenge.
                    #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
                    let authenticated = try #require(await http.requests.last)
                    #expect(authenticated.value(forHTTPHeaderField: "Authorization") == "Basic dTpw")
                    #expect(authenticated.url == sent.url)
                    #expect(authenticated.value(forHTTPHeaderField: "If-None-Match") == (selected ? nil : "old"))
                    let saved = try #require(try await store.feed(id: feed.id))
                    #expect(saved.lastUpdateFailed == (status == 403))
                    // The request advances the page; the source merge retains
                    // the stored front-page number and title.
                    #expect(saved.pageNumber == 0)
                    #expect(saved.metadata.title == (!selected && status == 200 ? "Updated" : "Original"))
                    let logs = try await store.logs(feedID: feed.id)
                    #expect(logs.map(\.kind) == (status == 403 ? [.failure(.forbidden)] : []))
                    let updated = await effects.events.filter { if case .refreshed = $0 { true } else { false } }
                    #expect(updated.count == (status == 200 ? 1 : 0))
                    #expect(try await store.manualRefreshRequest() == nil)
                }
            }
        }
    }

    @Test func storageFailureCancelsOtherLanesAndDoesNotAcknowledge() async throws {
        try await withStore { store in
            var feeds: [LibraryFeed] = []
            for index in 1...5 { feeds.append(try await insert(store, index: index)) }
            let request = FeedRefreshRequest(feedID: nil, enqueuedAt: .distantPast)
            try await store.enqueueManualRefresh(request)
            let gate = WorkerGate(), effects = WorkerEffects()
            let worker = FeedRefreshWorker(store: store, network: network(), effects: effects,
                shuffle: { $0 }, refresh: { try await gate.refresh($0, $1) })
            let task = Task { try await worker.run(request) }; defer { task.cancel() }
            try await until { await gate.started.count == 4 }
            await gate.fail(feeds[0].id)
            await #expect(throws: FeedLibraryError.self) { try await task.value }
            #expect(Set(await gate.cancelled) == Set(feeds[1...3].map(\.id)))
            #expect(await gate.started.count == 4)
            #expect(await effects.events == [.prepareNotifications, .remaining(feeds)])
            #expect(try await store.manualRefreshRequest() == request)
        }
    }
}

private actor WorkerHTTP: FeedHTTPTransport {
    let status: Int
    var requests: [URLRequest] = []
    init(status: Int) { self.status = status }
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
        requests.append(request)
        if requests.count == 1 { return FeedHTTPResponse(url: request.url!, status: 401) }
        return FeedHTTPResponse(url: request.url!, status: status, body:
            Data("<rss version=\"2.0\"><channel><title>Updated</title></channel></rss>".utf8))
    }
}

private actor WorkerEffects: FeedRefreshEffects {
    var events: [FeedRefreshWorker.Event] = []
    let action: @Sendable (FeedRefreshWorker.Event) async throws -> Void
    init(action: @escaping @Sendable (FeedRefreshWorker.Event) async throws -> Void = { _ in }) { self.action = action }
    func handle(_ event: FeedRefreshWorker.Event, request: FeedRefreshRequest) async throws {
        events.append(event); try await action(event)
    }
}

private actor WorkerGate {
    var started: [(Int64, FeedRefreshRequest)] = []
    var cancelled: [Int64] = []
    var peak = 0
    var waiting: [Int64: CheckedContinuation<FeedRefreshWorker.Outcome, any Error>] = [:]
    func refresh(_ feed: LibraryFeed, _ request: FeedRefreshRequest) async throws -> FeedRefreshWorker.Outcome {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiting[feed.id] = continuation; started.append((feed.id, request)); peak = max(peak, waiting.count)
            }
        } onCancel: { Task { await self.cancel(feed.id) } }
    }
    func cancel(_ id: Int64) {
        if let continuation = waiting.removeValue(forKey: id) {
            cancelled.append(id); continuation.resume(throwing: CancellationError())
        }
    }
    func finish(_ id: Int64, outcome: FeedRefreshWorker.Outcome) {
        waiting.removeValue(forKey: id)?.resume(returning: outcome)
    }
    func fail(_ id: Int64) {
        waiting.removeValue(forKey: id)?.resume(throwing: FeedLibraryError.invalidMutation)
    }
}
