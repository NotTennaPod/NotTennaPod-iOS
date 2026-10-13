import Foundation
import Testing
@testable import NotTennaPodCore

@MainActor @Suite(.timeLimit(.minutes(1)))
struct ManualFeedRefreshCoordinatorTests {
    private func withStore(_ body: (FeedLibraryStore, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RefreshOwner-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("library.sqlite"), store = try FeedLibraryStore(url: file)
        do { try await body(store, file); try await store.close() }
        catch { try? await store.close(); throw error }
    }
    private func until(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await predicate()) && ContinuousClock.now < deadline { await Task.yield() }
        try #require(await predicate())
    }
    private func owner(_ store: FeedLibraryStore, _ gate: CoordinatorGate,
                       clock: @escaping () -> Int64 = { 1_000_000 }) -> ManualFeedRefreshCoordinator {
        ManualFeedRefreshCoordinator(store: store, clock: clock) { request in
            try await gate.run(request)
            guard try await store.finishManualRefresh(id: request.id) else { throw CancellationError() }
        }
    }
    private let online = DownloadNetworkState(connected: true, metered: false, cellular: false)
    private let offline = DownloadNetworkState(connected: false, metered: true, cellular: false)

    @Test func rapidSuspendedRequestsPersistInInvocationOrderAndResumeOnlyLatest() async throws {
        try await withStore { store, _ in
            let gate = CoordinatorGate()
            let observed = self.owner(store, gate)
            observed.suspend()
            let tasks = (1...30).map { observed.runOnce(feedID: Int64($0), isLocalFeed: $0.isMultiple(of: 2)) }
            var requests: [FeedRefreshRequest] = []
            for task in tasks { requests.append(try await task.value) }
            let last = try #require(requests.last)
            #expect(try await store.manualRefreshRequest() == last)
            #expect(observed.state == .suspended(last))
            #expect(await gate.started.isEmpty)
            try await observed.resume().value
            try await until { await gate.started.count == 1 }
            #expect(await gate.started == [last])
            await gate.finish(last.id)
            try await until { observed.state == .idle }
            #expect(try await store.manualRefreshRequest() == nil)
        }
    }

    @Test func globalReplacementCancelsDifferentFeedAndLateResultCannotClearSuccessor() async throws {
        try await withStore { store, _ in
            let gate = CoordinatorGate(ignoreCancellation: true), owner = owner(store, gate)
            let first = try await owner.runOnce(feedID: 1, isLocalFeed: true).value
            try await until { await gate.started.count == 1 }
            let second = try await owner.runOnce(feedID: nil).value
            try await until {
                let started = await gate.started.count, cancelled = await gate.cancelled.count
                return started == 2 && cancelled == 1
            }
            #expect(await gate.cancelled == [first.id])
            #expect(owner.state == .active(second))
            #expect(try await store.manualRefreshRequest() == second)
            await gate.finish(first.id)
            try await until { await gate.completed.contains(first.id) }
            #expect(owner.state == .active(second))
            #expect(try await store.manualRefreshRequest() == second)
            #expect(try await owner.cancel(requestID: first.id).value == false)
            #expect(owner.state == .active(second))
            await gate.finish(second.id)
            try await until { owner.state == .idle }
        }
    }

    @Test func recoveryDoesNotRestoreCooldownAndRepeatedResumeDoesNotDuplicateExecution() async throws {
        try await withStore { store, _ in
            let saved = FeedRefreshRequest(feedID: 1, enqueuedAt: Date(timeIntervalSince1970: 1000))
            try await store.enqueueManualRefresh(saved)
            let gate = CoordinatorGate(), owner = owner(store, gate)
            let resumes = (0..<20).map { _ in owner.resume() }
            for task in resumes { try await task.value }
            try await until { await gate.started.count == 1 }
            #expect(await gate.started == [saved])
            #expect(owner.admission(feedID: 1, isLocalFeed: false, network: online, refreshAllowed: true) == .run)
            #expect(owner.state == .active(saved))
            await gate.finish(saved.id)
            try await until { owner.state == .idle }
            try await owner.resume().value
            #expect(owner.state == .idle)
            #expect(await gate.started.count == 1)
        }
    }

    @Test func cooldownTracksOnlyLastInvocationDirectRequestsBypassAndBoundaryIsExact() async throws {
        try await withStore { store, _ in
            var now: Int64 = 1_000_000
            let owner = owner(store, CoordinatorGate(), clock: { now })
            owner.suspend()
            _ = try await owner.runOnce(feedID: 1, isLocalFeed: true).value
            #expect(owner.admission(feedID: 1, isLocalFeed: true, network: offline, refreshAllowed: true) == .cooldown)
            #expect(owner.admission(feedID: 2, isLocalFeed: true, network: offline, refreshAllowed: false) == .run)
            now += 19_999
            #expect(owner.admission(feedID: 1, isLocalFeed: false, network: online, refreshAllowed: true) == .cooldown)
            now += 1
            #expect(owner.admission(feedID: 1, isLocalFeed: false, network: offline, refreshAllowed: false) == .offline)
            _ = try await owner.runOnce(feedID: 1).value
            let direct = try await owner.runOnce(feedID: 1, nextPage: true).value
            #expect(direct.nextPage)
            #expect(try await store.manualRefreshRequest() == direct)
            _ = try await owner.runOnce(feedID: nil).value
            #expect(owner.admission(feedID: 1, isLocalFeed: false, network: online, refreshAllowed: true) == .run)
            #expect(owner.admission(feedID: nil, isLocalFeed: false, network: offline, refreshAllowed: false) == .cooldown)
            now -= 1
            #expect(owner.admission(feedID: nil, isLocalFeed: false, network: online, refreshAllowed: true) == .cooldown)
        }
    }

    @Test func suspendedEnqueueAndResumeThenImmediateSuspendCannotStartWork() async throws {
        try await withStore { store, _ in
            let gate = CoordinatorGate(), owner = owner(store, gate)
            let pending = owner.runOnce(feedID: 1)
            owner.suspend()
            let request = try await pending.value
            #expect(owner.state == .suspended(request))
            #expect(await gate.started.isEmpty)
            let resume = owner.resume()
            owner.suspend()
            try await resume.value
            #expect(owner.state == .suspended(request))
            #expect(await gate.started.isEmpty)
            #expect(try await store.manualRefreshRequest() == request)
            try await owner.resume().value
            try await until { await gate.started.count == 1 }
            owner.suspend()
            try await until { await gate.cancelled.count == 1 }
            #expect(try await store.manualRefreshRequest() == request)
            try await owner.resume().value
            try await until { await gate.started.count == 2 }
            await gate.finish(request.id)
            try await until { owner.state == .idle }
        }
    }

    @Test func targetedCancellationClearsOnlyAcceptedUUIDAndStopsExecution() async throws {
        try await withStore { store, _ in
            let gate = CoordinatorGate(), owner = owner(store, gate)
            let request = try await owner.runOnce(feedID: 1).value
            try await until { await gate.started.count == 1 }
            #expect(try await owner.cancel(requestID: UUID()).value == false)
            #expect(owner.state == .active(request))
            #expect(try await owner.cancel(requestID: request.id).value)
            try await until { await gate.cancelled == [request.id] }
            #expect(owner.state == .idle)
            #expect(try await store.manualRefreshRequest() == nil)
            #expect(try await owner.cancel(requestID: request.id).value == false)
        }
    }

    @Test func failedReplacementPreservesOldExecutionAndLaterCommandStillRuns() async throws {
        try await withStore { store, file in
            let gate = CoordinatorGate(), owner = owner(store, gate)
            let first = try await owner.runOnce(feedID: 1).value
            try await until { await gate.started.count == 1 }
            let db = try LibrarySQLite(url: file)
            try db.execute("CREATE TRIGGER reject_manual BEFORE UPDATE ON feed_refresh_request BEGIN SELECT RAISE(ABORT, 'replacement failed'); END")
            await #expect(throws: FeedLibraryError.self) { try await owner.runOnce(feedID: 2).value }
            #expect(owner.state == .active(first))
            #expect(try await store.manualRefreshRequest() == first)
            #expect(await gate.cancelled.isEmpty)
            try db.execute("DROP TRIGGER reject_manual")
            let second = try await owner.runOnce(feedID: 3).value
            try await until { await gate.started.count == 2 }
            #expect(owner.state == .active(second))
            await gate.finish(second.id)
            try await until { owner.state == .idle }
            try db.close()
        }
    }

    @Test func workerFailureRetainsRequestAndExplicitRecoveryRetriesIt() async throws {
        try await withStore { store, _ in
            let gate = CoordinatorGate(), owner = owner(store, gate)
            let request = try await owner.runOnce(feedID: 1).value
            try await until { await gate.started.count == 1 }
            await gate.finish(request.id, failure: true)
            try await until { if case .failed = owner.state { true } else { false } }
            #expect(try await store.manualRefreshRequest() == request)
            #expect(await gate.started.count == 1)
            try await owner.resume().value
            try await until { await gate.started.count == 2 }
            #expect(await gate.started == [request, request])
            await gate.finish(request.id)
            try await until { owner.state == .idle }
        }
    }

    @Test func realWorkerRetriesNetworkInterruptionWaitsOfflineAndCompletesOnReconnection() async throws {
        try await withStore { store, _ in
            let feed = try await store.insert(FetchedFeed(feed: ParsedFeed(format: .rss, title: "Feed"),
                source: "https://example.com/feed", responseURL: URL(string: "https://example.com/feed")!,
                validator: nil, permanentRedirectURL: nil))
            let monitor = DownloadNetworkMonitor(startMonitoring: false)
            monitor.update(online)
            let gate = CoordinatorGate()
            let worker = FeedRefreshWorker(store: store, network: monitor, effects: CoordinatorEffects()) { _, request in
                try await gate.run(request); return .unchanged
            }
            let owner = ManualFeedRefreshCoordinator(store: store, worker: worker)
            let request = try await owner.runOnce(feedID: feed.id).value
            try await until { await gate.started.count == 1 }
            monitor.update(offline)
            try await until { await gate.cancelled.count == 1 && monitor.pendingWaitCount == 1 }
            #expect(await gate.started.count == 1)
            #expect(owner.state == .active(request))
            #expect(try await store.manualRefreshRequest() == request)
            monitor.update(online)
            try await until { await gate.started.count == 2 }
            await gate.finish(request.id)
            try await until { owner.state == .idle }
            #expect(try await store.manualRefreshRequest() == nil)
            #expect(monitor.pendingWaitCount == 0)
        }
    }

    @Test func precancelledEnqueueDoesNotReplaceSavedWorkOrPoisonLaterCommands() async throws {
        try await withStore { store, _ in
            let owner = owner(store, CoordinatorGate())
            owner.suspend()
            let first = try await owner.runOnce(feedID: 1).value
            let cancelled = owner.runOnce(feedID: 2)
            cancelled.cancel()
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            #expect(try await store.manualRefreshRequest() == first)
            #expect(owner.state == .suspended(first))
            let next = try await owner.runOnce(feedID: 3).value
            #expect(try await store.manualRefreshRequest() == next)
            #expect(owner.state == .suspended(next))
        }
    }
}

private struct CoordinatorEffects: FeedRefreshEffects {
    func handle(_ event: FeedRefreshWorker.Event, request: FeedRefreshRequest) async throws {}
}

private actor CoordinatorGate {
    let ignoreCancellation: Bool
    var started: [FeedRefreshRequest] = []
    var cancelled: [UUID] = []
    var completed: [UUID] = []
    var waiting: [UUID: CheckedContinuation<Void, any Error>] = [:]
    init(ignoreCancellation: Bool = false) { self.ignoreCancellation = ignoreCancellation }
    func run(_ request: FeedRefreshRequest) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiting[request.id] = continuation; started.append(request)
            }
        } onCancel: { Task { await self.cancel(request.id) } }
        completed.append(request.id)
    }
    func cancel(_ id: UUID) {
        cancelled.append(id)
        if !ignoreCancellation { waiting.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    }
    func finish(_ id: UUID, failure: Bool = false) {
        if failure { waiting.removeValue(forKey: id)?.resume(throwing: FeedLibraryError.invalidMutation) }
        else { waiting.removeValue(forKey: id)?.resume() }
    }
}
