import Foundation
import Synchronization
import Testing
@testable import NotTennaPodCore

/// The app's one grant of background time: participants share it, its expiration or refusal parks every one of
/// them and gives it back exactly once, time that ran out is never renewed by later work, and a manual refresh joins it
///: expired, it keeps its saved request and marks nothing as failed.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct BackgroundWorkGrantTests {
    /// UIKit's background task, as the grant sees it.
    @MainActor final class FakeTime: BackgroundTimeProviding {
        var isInBackground = false
        var refuses = false
        var begun = 0
        var ended: [(grant: Int, expired: Bool)] = []
        var expiration: (@MainActor () -> Void)?
        func begin(expired: @escaping @MainActor () -> Void) -> Int? {
            guard !refuses else { return nil }
            begun += 1
            expiration = expired
            return begun
        }
        func end(_ grant: Int, expired: Bool) { ended.append((grant, expired)) }
    }

    /// A participant whose work the test turns on and off; parking does not stop it at once (it winds down later).
    @MainActor final class Work {
        var running = false
        var parks = 0
        var changes: [Bool] = []
        var participant: BackgroundWorkGrant.Participant {
            .init(hasWork: { [unowned self] in running }, park: { [unowned self] in parks += 1 },
                  changed: { [unowned self] in changes.append($0) })
        }
    }

    private func makeGrant(_ time: FakeTime, _ works: [Work]) -> BackgroundWorkGrant {
        BackgroundWorkGrant(time: time, participants: works.map(\.participant), pollInterval: .seconds(30))
    }

    @Test func syncDownloadRefreshAndImportShareOneGrantGivenBackWhenAllAreDone() {
        let time = FakeTime(), sync = Work(), download = Work(), refresh = Work(), imported = Work()
        let grant = makeGrant(time, [sync, download, refresh])
        sync.running = true
        time.isInBackground = true
        grant.enterBackground()
        #expect(time.begun == 1 && grant.isHeld)
        #expect(sync.changes == [true] && download.changes == [true] && refresh.changes == [true])
        download.running = true; grant.workStarted()
        refresh.running = true; grant.workStarted()
        imported.running = true
        let membership = grant.join(imported.participant)
        #expect(time.begun == 1, "Later participants join the held grant; nothing asks again")
        sync.running = false; grant.workChanged()
        download.running = false; grant.workChanged()
        refresh.running = false; grant.workChanged()
        #expect(grant.isHeld && time.ended.isEmpty, "Held while the import still works")
        imported.running = false
        membership.leave()
        #expect(!grant.isHeld && time.ended.count == 1 && time.ended[0].grant == 1 && !time.ended[0].expired)
        #expect(sync.parks == 0 && download.parks == 0 && refresh.parks == 0 && imported.parks == 0)
    }

    @Test func expirationParksEveryParticipantAndGivesTheGrantBackOnceWhileTheWorkWindsDown() throws {
        let time = FakeTime(), sync = Work(), download = Work(), refresh = Work(), imported = Work()
        let grant = makeGrant(time, [sync, download, refresh])
        time.isInBackground = true
        sync.running = true; refresh.running = true
        grant.enterBackground()
        let membership = grant.join(imported.participant)
        imported.running = true
        let expire = try #require(time.expiration)
        expire()
        // The work has not stopped yet (it winds down asynchronously); the grant is given back anyway.
        #expect(time.ended.count == 1 && time.ended[0].expired && !grant.isHeld)
        #expect(sync.parks == 1 && download.parks == 1 && refresh.parks == 1 && imported.parks == 1)
        expire()
        grant.workChanged()
        sync.running = false; refresh.running = false; imported.running = false
        membership.leave()
        #expect(time.ended.count == 1, "Exactly once, whatever arrives late")
        #expect(sync.parks == 1 && imported.parks == 1)
    }

    @Test func workStartingAfterTheTimeRanOutParksWithoutAskingAgainUntilNewTime() throws {
        let time = FakeTime(), sync = Work(), refresh = Work()
        let grant = makeGrant(time, [sync, refresh])
        time.isInBackground = true
        sync.running = true
        grant.enterBackground()
        let expire1 = try #require(time.expiration); expire1()
        #expect(grant.isExhausted)
        // A refresh started later in the same background period (an OPML import's, a shortcut's).
        refresh.running = true
        grant.workStarted()
        let imported = Work(); imported.running = true
        _ = grant.join(imported.participant)
        grant.enterBackground() // another scene left the foreground, a parked download was resumed
        #expect(time.begun == 1, "Time that ran out is never renewed by later work")
        #expect(refresh.parks >= 2 && imported.parks >= 1, "It parks at once instead")
        // The system woke the app for background events: new time.
        grant.enterBackground(freshTime: true)
        #expect(time.begun == 2 && grant.isHeld && !grant.isExhausted)
        // A scene became active: the grant is given back; the next background period may ask again.
        grant.enterForeground()
        #expect(!grant.isHeld && time.ended.last?.expired == false)
        let expire2 = try #require(time.expiration); expire2()
        #expect(time.ended.count == 2, "A late expiration of a grant already given back does nothing")
        time.isInBackground = true
        grant.enterBackground()
        #expect(time.begun == 3)
    }

    @Test func refusedTimeParksTheWorkAndForegroundWorkNeedsNoTime() {
        let time = FakeTime(), refresh = Work()
        let grant = makeGrant(time, [refresh])
        refresh.running = true
        grant.workStarted()
        #expect(time.begun == 0 && refresh.parks == 0, "In the foreground the work needs no grant")
        time.isInBackground = true
        time.refuses = true
        grant.workStarted()
        #expect(!grant.isHeld && refresh.parks == 1 && grant.isExhausted, "Refused: the work parks as at expiration")
        time.refuses = false
        grant.workStarted()
        #expect(time.begun == 0, "A refusal is not asked again in the same period")
        let idle = Work()
        let second = makeGrant(time, [idle])
        second.enterBackground()
        #expect(time.begun == 0 && idle.parks == 0, "No work: no grant and nothing parks")
    }

    @Test func aStaleExpirationFromAnEarlierGrantNeverEndsANewerOne() throws {
        let time = FakeTime(), work = Work()
        let grant = makeGrant(time, [work])
        work.running = true
        time.isInBackground = true
        grant.enterBackground()
        let first = try #require(time.expiration)
        grant.enterForeground()
        grant.enterBackground()
        #expect(time.begun == 2 && grant.isHeld)
        first() // the first grant's expiration, delivered late
        #expect(grant.isHeld && time.ended.count == 1 && !time.ended[0].expired && work.parks == 0)
        let second = try #require(time.expiration)
        second()
        #expect(!grant.isHeld && time.ended.last?.expired == true && work.parks == 1)
    }

    /// A server exchange running in its own server-sync background task: an expired UIKit period earlier, then
    /// that task's wake, then the unlock event or another participant meeting a refusal never cancels it.
    @Test func anExchangeInItsOwnBackgroundTaskIsNeverParkedByTheGrant() async throws {
        let engine = ServerSyncSchedulerTests.Engine(), network = ServerSyncSchedulerTests.Network()
        let scheduler = ServerSyncScheduler(engine: engine, hints: nil, outbox: nil, network: network, timing: ServerSyncSchedulerTests.fast)
        scheduler.start()
        try await until { scheduler.history.count == 1 && !scheduler.hasPendingWork }
        scheduler.setForeground(false)
        var windows = 0
        let time = FakeTime(), download = Work()
        let grant = BackgroundWorkGrant(time: time, participants: [
            .serverSync({ scheduler }, inWindow: { windows > 0 }), download.participant], pollInterval: .seconds(30))
        // A UIKit grant runs out in this background period.
        download.running = true
        time.isInBackground = true
        grant.enterBackground()
        let expire = try #require(time.expiration)
        expire()
        #expect(grant.isExhausted && download.parks == 1)
        // Without a window of its own the idle exchange parked too (its cancellation is delivered asynchronously).
        try await until { engine.cancelled == 1 }
        let cancelsBefore = engine.cancelled
        // Later iOS wakes the app for a server-sync background task.
        windows = 1
        engine.hold()
        let run = Task { await scheduler.runInBackground(.refresh) }
        try await until { scheduler.isExchanging }
        // The unlock retry calls enterBackground, and the exhausted period parks process-bound work.
        grant.enterBackground()
        #expect(download.parks == 2, "Work without time of its own parks")
        // A participant meets a refusal while the window still runs.
        time.refuses = true
        let imported = Work(); imported.running = true
        let membership = grant.join(imported.participant)
        #expect(imported.parks >= 1 && time.begun == 1, "Exhausted UIKit time is never renewed")
        for _ in 0..<20 { await Task.yield() } // a cancellation would be delivered by now
        // The scheduler's park is what cancels an exchange; it was never asked (a scene, a timer or the engine itself may
        // end this exchange earlier, which is not what this checks).
        #expect(engine.cancelled == cancelsBefore, "The exchange in its own window is never cancelled")
        engine.release()
        #expect(await run.value)
        windows = 0
        membership.leave()
        await scheduler.stop()
    }

    // MARK: - Manual refresh

    @Test func expiredManualRefreshKeepsItsRequestMarksNothingFailedAndRunsAgainWhenActive() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("K5a-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try FeedLibraryStore(url: folder.appendingPathComponent("library.sqlite"))
        let source = "https://k5a.example/feed"
        let feed = try await store.insert(.init(feed: ParsedFeed(format: .rss, title: "Held podcast",
            episodes: [ParsedEpisode(identifier: "one", title: "One")]), source: source,
            responseURL: URL(string: source)!, validator: nil, permanentRedirectURL: nil))
        let transport = HeldFeedTransport()
        let network = DownloadNetworkMonitor(startMonitoring: false)
        network.update(.init(connected: true, metered: false, cellular: false))
        let worker = FeedRefreshWorker(store: store, remote: FeedRefreshService(store: store, fetcher: FeedFetcher(transport: transport)),
            local: LocalFeedRefreshService(store: store), localDescription: "Local", localAuthor: "Local", network: network,
            credentials: { _ in nil }, options: { _ in .init() }, effects: NoRefreshEffects())
        let refresh = ManualFeedRefreshCoordinator(store: store, worker: worker)
        let time = FakeTime()
        let grant = BackgroundWorkGrant(time: time, participants: [.manualRefresh { refresh }], pollInterval: .seconds(30))
        // As the app does: a refresh that starts in the background joins the grant.
        refresh.onChange = { state in if case .active = state { grant.workStarted() } }
        time.isInBackground = true
        grant.enterBackground()
        #expect(time.begun == 0, "Nothing to do yet")
        let request = try await refresh.runOnce(feedID: feed.id).value
        #expect(time.begun == 1 && grant.isHeld)
        try await until { await transport.inFlight == 1 }

        let expire3 = try #require(time.expiration); expire3()
        #expect(time.ended.count == 1 && time.ended[0].expired, "Given back at once")
        #expect(refresh.state == .suspended(request))
        try await until { await transport.cancelled == 1 }
        #expect(try await store.manualRefreshRequest() == request, "The saved request is kept for later")
        let interrupted = try #require(try await store.feed(id: feed.id))
        #expect(!interrupted.lastUpdateFailed, "No \"refresh failed\" mark")
        #expect(try await store.logs(feedID: feed.id).isEmpty, "No failure in the log")

        // Requests made before the app is active again wait with it.
        _ = try await refresh.runOnce(feedID: feed.id).value
        #expect(time.begun == 1)
        if case .suspended = refresh.state {} else { Issue.record("Still parked: \(refresh.state)") }

        // The app is active again: the saved refresh runs and completes.
        time.isInBackground = false
        grant.enterForeground()
        await transport.answer()
        try await refresh.resume().value
        try await refresh.waitUntilIdle()
        #expect(refresh.state == .idle)
        #expect(try await store.manualRefreshRequest() == nil)
        let refreshed = try #require(try await store.feed(id: feed.id))
        #expect(!refreshed.lastUpdateFailed && refreshed.title == "Refreshed podcast")
        #expect(try await store.logs(feedID: feed.id).allSatisfy { $0.kind == .success })
        try await store.close()
    }

    private func until(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await predicate()) && ContinuousClock.now < deadline { await Task.yield() }
        try #require(await predicate())
    }
}

/// A feed server that holds every request until the test answers it; a cancelled request ends as URLSession's would.
private actor HeldFeedTransport: FeedHTTPTransport {
    private(set) var inFlight = 0
    private(set) var cancelled = 0
    private var answers = false
    private var waiting: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func answer() {
        answers = true
        for continuation in waiting.values { continuation.resume(returning: true) }
        waiting = [:]
    }

    func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
        let url = try #require(request.url)
        if !answers {
            inFlight += 1
            let id = UUID()
            let answered = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled { continuation.resume(returning: false) } else { waiting[id] = continuation }
                }
            } onCancel: { Task { await self.cancel(id) } }
            inFlight -= 1
            guard answered else { cancelled += 1; throw URLError(.cancelled) }
        }
        return FeedHTTPResponse(url: url, status: 200, headers: ["Content-Type": "application/rss+xml"],
            body: Data("<rss><channel><title>Refreshed podcast</title><item><guid>one</guid><title>One</title></item></channel></rss>".utf8))
    }

    private func cancel(_ id: UUID) { waiting.removeValue(forKey: id)?.resume(returning: false) }
}

private struct NoRefreshEffects: FeedRefreshEffects {
    func handle(_ event: FeedRefreshWorker.Event, request: FeedRefreshRequest) async throws {}
}
