import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct PeriodicFeedRefreshRuntimeTests {
    private func fixture(_ body: (FeedLibraryStore, DownloadNetworkMonitor, PeriodicFeedRefreshRuntime, Scheduler, Effects) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PeriodicRuntime-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let network = DownloadNetworkMonitor(startMonitoring: false), effects = Effects(), scheduler = Scheduler()
        network.update(.init(connected: false, metered: true, cellular: false))
        let worker = FeedRefreshWorker(store: store, network: network, effects: effects) { _, _ in .unchanged }
        let owner = PeriodicFeedRefreshCoordinator(store: store, worker: worker)
        let runtime = PeriodicFeedRefreshRuntime(owner: owner, scheduler: scheduler)
        await runtime.configure(intervalMinutes: 720, allowMobile: false, replace: false).value
        await runtime.waitForScheduling()
        do { try await body(store, network, runtime, scheduler, effects); runtime.setForeground(false); owner.suspend(); try await store.close() }
        catch { runtime.setForeground(false); owner.suspend(); try? await store.close(); throw error }
    }
    private func until(_ condition: () async throws -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while try await !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        try #require(try await condition())
    }
    @Test func backgroundExpirationRetainsWorkAndNeverCancelsOnlyPeriodicSlot() async throws {
        try await fixture { store, network, runtime, scheduler, effects in
            let manual = FeedRefreshRequest(feedID: nil, enqueuedAt: Date())
            try await store.enqueueManualRefresh(manual)
            let lease = Lease(); runtime.launch(lease)
            try await until { network.pendingWaitCount == 1 }
            let request = try #require(try await store.beginPeriodicRefresh())
            lease.expiration?()
            try await until { network.pendingWaitCount == 0 }
            #expect(lease.completed == [false])
            #expect(try await store.refreshRequest(id: request.id) == request)
            #expect(effects.events.isEmpty)
            await runtime.configure(intervalMinutes: 0, allowMobile: false, replace: true).value
            await runtime.waitForScheduling()
            #expect(scheduler.next == nil)
            #expect(try await store.refreshRequest(id: request.id) == nil)
            #expect(try await store.manualRefreshRequest() == manual)
            #expect(lease.completed == [false])
        }
    }
    @Test func foregroundJoinsBackgroundAndSurvivesItsExpirationWithoutDuplicateEffects() async throws {
        try await fixture { store, network, runtime, scheduler, effects in
            let lease = Lease(); runtime.launch(lease)
            try await until { network.pendingWaitCount == 1 }
            runtime.setForeground(true)
            lease.expiration?()
            #expect(lease.completed == [false])
            network.update(.init(connected: true, metered: false, cellular: false))
            try await until { try await store.periodicRefreshSchedule()!.nextCheck > Date() }
            #expect(effects.events.filter { $0 == .synchronize }.count == 1)
            #expect(network.pendingWaitCount == 0)
            #expect(scheduler.next != nil)
            runtime.setForeground(false)
        }
    }
    @Test func backgroundSuccessCompletesOnceAndReschedulesHourly() async throws {
        try await fixture { store, network, runtime, scheduler, effects in
            network.update(.init(connected: true, metered: false, cellular: false))
            let lease = Lease(); runtime.launch(lease)
            try await until { !lease.completed.isEmpty }
            #expect(lease.completed == [true] && lease.expiration == nil)
            // Every post-refresh effect happens exactly once (their internal order is not user-visible).
            let expected: [FeedRefreshWorker.Event] = [.prepareNotifications, .remaining([]), .cleanUnsubscribedFeeds, .autoDownload, .dismissProgress, .synchronize]
            #expect(effects.events.count == expected.count)
            for event in expected { #expect(effects.events.filter { $0 == event }.count == 1, "\(event)") }
            let next = try #require(try await store.periodicRefreshSchedule()?.nextCheck)
            #expect(next.timeIntervalSinceNow > 3590 && next.timeIntervalSinceNow <= 3600)
            try await until { scheduler.next == next }
            #expect(try await store.beginPeriodicRefresh() == nil)
        }
    }
    @Test func startupReconcilesInterruptedPreferenceCallbackButKeepsUnchangedSchedule() async throws {
        try await fixture { store, _, runtime, scheduler, _ in
            let original = try #require(try await store.periodicRefreshSchedule())
            await runtime.configure(intervalMinutes: 720, allowMobile: false, replace: false).value
            #expect(try await store.periodicRefreshSchedule() == original)
            await runtime.configure(intervalMinutes: 60, allowMobile: true, replace: false).value
            let updated = try #require(try await store.periodicRefreshSchedule())
            #expect(updated.id != original.id && updated.intervalMinutes == 60 && updated.allowMobile)
            #expect(scheduler.next != nil)
        }
    }
    @Test func delayedSystemSubmissionCannotBlockForegroundOrResurrectNever() async throws {
        try await fixture { store, network, runtime, scheduler, effects in
            scheduler.delayNext = true
            await runtime.configure(intervalMinutes: 60, allowMobile: true, replace: true).value
            try await until { scheduler.pending != nil }
            network.update(.init(connected: true, metered: false, cellular: false))
            runtime.setForeground(true)
            try await until { effects.events.contains(.synchronize) }
            await runtime.configure(intervalMinutes: 0, allowMobile: false, replace: true).value
            #expect(scheduler.next == nil)
            #expect(try await store.periodicRefreshSchedule() == nil)
            scheduler.release()
            await runtime.waitForScheduling()
            #expect(scheduler.next == nil)
            #expect(try await store.beginPeriodicRefresh() == nil)
            runtime.setForeground(false)
        }
    }
    private final class Scheduler: PeriodicRefreshScheduling {
        var next: Date?
        var delayNext = false
        var pending: CheckedContinuation<Void, Never>?
        func submit(earliest: Date) async {
            if delayNext {
                delayNext = false
                await withCheckedContinuation { pending = $0 }
            }
            next = earliest
        }
        func release() { let continuation = pending; pending = nil; continuation?.resume() }
        func cancel() { next = nil }
    }
    private final class Lease: PeriodicRefreshBackgroundLease {
        var expiration: (@MainActor () -> Void)?
        var completed: [Bool] = []
        func complete(success: Bool) { completed.append(success); expiration = nil }
    }
    @MainActor private final class Effects: FeedRefreshEffects {
        var events: [FeedRefreshWorker.Event] = []
        func handle(_ event: FeedRefreshWorker.Event, request: FeedRefreshRequest) { events.append(event) }
    }
}
