import Foundation
import Testing
@testable import NotTennaPodCore

/// When a server library exchanges (PROTOCOL §6.4), with an engine of the test's own: launch, local
/// actions after the debounce, retries, pauses, change hints and polling, the network, playback pauses, the page's
/// "Synchronize now" and "Force full synchronization", background work, and screens told at most once a second.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5))) struct ServerSyncSchedulerTests {
    /// An engine whose reports the test chooses; an exchange can be held open until the test releases it.
    final class Engine: ServerExchangeDriving, @unchecked Sendable {
        private let lock = NSLock()
        private var queued: [ServerExchangeReport] = []
        private var calls: [String] = []
        private var holding = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var resumes = 0, releases = 0, cancels = 0
        private var fullOwed = false
        /// The persisted Force full request (as the library's `ntp_requests`).
        var requestedFull: Bool {
            get { lock.withLock { fullOwed } }
            set { lock.withLock { fullOwed = newValue } }
        }
        private var currentHead = ServerHead(logID: "00000000-0000-4000-8000-000000000001", epoch: 1, seq: 1)
        let (stream, continuation) = AsyncStream<ServerExchangeEvent>.makeStream()

        var head: ServerHead {
            get { lock.withLock { currentHead } }
            set { lock.withLock { currentHead = newValue } }
        }
        var log: [String] { lock.withLock { calls } }
        var resumed: Int { lock.withLock { resumes } }
        var releasedPins: Int { lock.withLock { releases } }
        var cancelled: Int { lock.withLock { cancels } }

        func queue(_ report: ServerExchangeReport) { lock.withLock { queued.append(report) } }
        func hold() { lock.withLock { holding = true } }
        func release() {
            let waiting = lock.withLock { holding = false; let list = waiters; waiters = []; return list }
            for waiter in waiting { waiter.resume() }
        }

        private func run(_ kind: String) async -> ServerExchangeReport {
            let number = lock.withLock { calls.append(kind); return calls.count }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let waits: Bool = lock.withLock {
                    guard holding else { return false }
                    waiters.append(continuation)
                    return true
                }
                if !waits { continuation.resume() }
            }
            return lock.withLock {
                var report = queued.isEmpty ? ServerExchangeReport() : queued.removeFirst()
                if report.head == nil { report.head = currentHead }
                if kind == "full", report.pause == nil, report.retryAfter == nil, report.error == nil, !report.waitingForPause, !report.waitingForBackground {
                    report.reprojected = true
                    fullOwed = false
                }
                report.acknowledged = number
                return report
            }
        }

        func exchange() async -> ServerExchangeReport { await run("exchange") }
        func forceFullSynchronization() async -> ServerExchangeReport { await run("full") }
        func storedState() async -> ServerExchangeReport { var report = ServerExchangeReport(); report.stateOnly = true; return report }
        func requestFullSynchronization() async { requestedFull = true }
        func fullSynchronizationRequested() async -> Bool { requestedFull }
        func resume() async throws { lock.withLock { resumes += 1 } }
        func liveHead() async -> ServerHead? { head }
        func releasePins() async { lock.withLock { releases += 1 } }
        func events() async -> AsyncStream<ServerExchangeEvent> { stream }
        func cancelExchange() async { lock.withLock { cancels += 1 }; release() }
        func note(_ kind: String, _ detail: String) async {}
        func close() async {}
    }

    final class Network: ServerSyncNetworkGate, @unchecked Sendable {
        private let lock = NSLock()
        private var allowed = true
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        var permittedNow: Bool {
            get { lock.withLock { allowed } }
            set { lock.withLock { allowed = newValue }; continuation.yield(()) }
        }
        /// The preference changes while the path stays as it was (no path event).
        func setWithoutPathChange(_ value: Bool) { lock.withLock { allowed = value } }
        func permitted() async -> Bool { permittedNow }
        func changes() -> AsyncStream<Void> { stream }
    }

    /// Change hints the test sends; each connection is a new stream.
    final class Hints: ServerChangeHintSource, @unchecked Sendable {
        private let lock = NSLock()
        private var current: AsyncThrowingStream<ServerHead, any Error>.Continuation?
        private var opened = 0
        private var failing: (any Error)?
        var connections: Int { lock.withLock { opened } }
        var failure: (any Error)? {
            get { lock.withLock { failing } }
            set { lock.withLock { failing = newValue } }
        }

        func hints() -> AsyncThrowingStream<ServerHead, any Error> {
            let (stream, continuation) = AsyncThrowingStream<ServerHead, any Error>.makeStream()
            lock.withLock {
                opened += 1
                if let failing { continuation.finish(throwing: failing) } else { current = continuation }
            }
            return stream
        }
        func send(_ head: ServerHead) { _ = lock.withLock { current?.yield(head) } }
        func drop() { lock.withLock { current?.finish(); current = nil } }
    }

    static var fast: ServerSyncScheduler.Timing {
        var timing = ServerSyncScheduler.Timing()
        timing.debounce = .milliseconds(50); timing.polling = .milliseconds(100); timing.reconnect = .milliseconds(50)
        timing.reloadInterval = .milliseconds(200)
        return timing
    }

    let engine = Engine()
    let network = Network()
    let outbox = AsyncStream<Void>.makeStream()

    func scheduler(hints: (any ServerChangeHintSource)? = nil, timing: ServerSyncScheduler.Timing = fast) -> ServerSyncScheduler {
        ServerSyncScheduler(engine: engine, hints: hints, outbox: { [stream = outbox.stream] in stream }, network: network, timing: timing)
    }

    func waitUntil(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition(), sourceLocation: sourceLocation)
    }

    /// Idle: no exchange running and no push waiting; nothing more can start without a new trigger.
    /// (Also: every exchange counted in `history` has been handled.)
    func settled(_ scheduler: ServerSyncScheduler, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await waitUntil({ !scheduler.hasPendingWork }, sourceLocation: sourceLocation)
    }

    @Test func launchExchangesAndLocalActionsArePushedTogetherAfterTheDebounce() async throws {
        let scheduler = scheduler()
        scheduler.start()
        try await waitUntil { scheduler.history.count == 1 }
        #expect(scheduler.history.element(0) == [.launch])
        try await settled(scheduler)
        // Three actions in a row (one recorded by the store): one push, after the debounce.
        outbox.continuation.yield(())
        try await waitUntil { scheduler.debouncing }
        scheduler.localChange()
        scheduler.localChange()
        try await waitUntil { scheduler.history.count == 2 }
        try await settled(scheduler)
        #expect(scheduler.history.count == 2 && scheduler.history.element(1) == [.localChange], "\(scheduler.history)")
        await scheduler.stop()
    }

    @Test func inTheBackgroundAWaitingPushStartsAtOnce() async throws {
        var timing = Self.fast
        timing.debounce = .seconds(3_600)
        let scheduler = scheduler(timing: timing)
        scheduler.start()
        try await waitUntil { scheduler.history.count == 1 }
        try await settled(scheduler)
        scheduler.localChange()
        #expect(scheduler.hasPendingWork, "the push waits for the debounce")
        scheduler.setExpedited(true)
        try await waitUntil { scheduler.history.count == 2 }
        scheduler.localChange()
        try await waitUntil { scheduler.history.count == 3 }
        await scheduler.stop()
    }

    @Test func triggersDuringAnExchangeRunExactlyOneMoreAfterIt() async throws {
        var timing = Self.fast
        timing.polling = .seconds(3_600)
        let scheduler = scheduler(timing: timing)
        engine.hold()
        scheduler.start()
        try await waitUntil { scheduler.isExchanging }
        scheduler.setForeground(true)
        scheduler.localChange()
        // The debounce elapses while the exchange runs.
        try await waitUntil { scheduler.history.count == 1 && scheduler.pendingTriggers == [.activation, .localChange] }
        engine.release()
        try await waitUntil { scheduler.history.count == 2 }
        try await settled(scheduler)
        #expect(scheduler.history.count == 2, "\(scheduler.history)")
        #expect(scheduler.history.last?.isSuperset(of: [.activation, .localChange]) == true)
        await scheduler.stop()
    }

    @Test func aTransientFailureIsRetriedAfterItsDelay() async throws {
        var failed = ServerExchangeReport()
        failed.retryAfter = 0.05
        failed.unreachable = true
        engine.queue(failed)
        let scheduler = scheduler()
        scheduler.start()
        try await waitUntil { scheduler.history.count == 2 }
        #expect(scheduler.history.element(1) == [.retry])
        await scheduler.stop()
    }

    /// During a backoff (here the server's `retry_after` of an hour) local actions, hints and polls
    /// wait for the deadline; what the person asks for does not.
    @Test func automaticTriggersWaitForTheRetryDeadline() async throws {
        var throttled = ServerExchangeReport()
        throttled.retryAfter = 3_600
        engine.queue(throttled)
        let hints = Hints()
        let scheduler = scheduler(hints: hints)
        scheduler.start()
        try await waitUntil { scheduler.lastReport?.retryAfter == 3_600 }
        try await settled(scheduler)
        scheduler.setForeground(true)
        scheduler.localChange()
        try await waitUntil { hints.connections == 1 }
        hints.send(ServerHead(logID: engine.head.logID, epoch: 1, seq: 9))
        try await Task.sleep(for: .milliseconds(300)) // debounce and polling intervals pass
        #expect(engine.log.count == 1, "nothing automatic before the deadline: \(scheduler.history)")
        #expect(await scheduler.synchronizeNow() != nil, "Synchronize now runs at once")
        #expect(engine.log.count == 2)
        await scheduler.stop()
    }

    @Test func triggersParkedDuringABackoffRunOnceAtTheDeadline() async throws {
        var failed = ServerExchangeReport()
        failed.retryAfter = 0.4
        failed.unreachable = true
        engine.queue(failed)
        var timing = Self.fast
        timing.polling = .seconds(3_600)
        let scheduler = scheduler(timing: timing)
        scheduler.start()
        try await waitUntil { scheduler.lastReport?.retryAfter == 0.4 }
        scheduler.localChange()
        scheduler.localChange()
        try await waitUntil { engine.log.count == 2 }
        try await settled(scheduler)
        #expect(engine.log.count == 2, "one exchange at the deadline: \(scheduler.history)")
        #expect(scheduler.history.last?.isSuperset(of: [.retry, .localChange]) == true)
        await scheduler.stop()
    }

    @Test func aPauseStopsEveryTriggerUntilResumed() async throws {
        var paused = ServerExchangeReport()
        paused.pause = .signIn
        engine.queue(paused)
        let hints = Hints()
        let scheduler = scheduler(hints: hints)
        scheduler.start()
        try await waitUntil { scheduler.history.count == 1 }
        try await settled(scheduler)
        #expect(scheduler.pause == .signIn)
        scheduler.setForeground(true)
        scheduler.localChange()
        hints.send(ServerHead(logID: engine.head.logID, epoch: 1, seq: 9))
        try await Task.sleep(for: .milliseconds(300)) // several polling and debounce intervals: nothing may start
        try await settled(scheduler)
        #expect(scheduler.history.count == 1, "paused: \(scheduler.history)")
        // What the person asks for still runs and tells why nothing happened.
        engine.queue(paused)
        let report = await scheduler.synchronizeNow()
        #expect(report?.pause == .signIn && scheduler.history.count == 2)
        // Signed in again: sync continues.
        await scheduler.resume()
        #expect(engine.resumed == 1)
        try await waitUntil { scheduler.history.count == 3 }
        #expect(scheduler.pause == nil)
        scheduler.localChange()
        try await waitUntil { scheduler.history.count >= 4 }
        await scheduler.stop()
    }

    @Test func aPauseThatLetsPullsContinueKeepsExchangingAndSynchronizeNowTriesAgain() async throws {
        var paused = ServerExchangeReport()
        paused.pause = .versionUnsupported
        engine.queue(paused)
        let scheduler = scheduler()
        scheduler.start()
        try await waitUntil { scheduler.history.count == 1 }
        try await settled(scheduler)
        #expect(scheduler.pause == nil)
        engine.queue(paused)
        scheduler.localChange()
        try await waitUntil { scheduler.history.count == 2 }
        try await settled(scheduler)
        await scheduler.synchronizeNow()
        #expect(engine.resumed == 1, "a server that needed updating is tried again")
        await scheduler.synchronizeNow()
        #expect(engine.resumed == 1, "only when the last report said so")
        await scheduler.stop()
    }

    @Test func aChangeHintPullsOnlyForAnotherHead() async throws {
        let hints = Hints()
        var timing = Self.fast
        timing.polling = .seconds(3_600)
        let scheduler = scheduler(hints: hints, timing: timing)
        scheduler.start()
        try await waitUntil { scheduler.history.count == 1 }
        try await settled(scheduler)
        scheduler.setForeground(true)
        try await waitUntil { scheduler.history.count == 2 && hints.connections == 1 }
        try await settled(scheduler)
        hints.send(engine.head)
        try await waitUntil { scheduler.hintsConnected }
        try await settled(scheduler)
        #expect(scheduler.history.count == 2, "the stream's first event names this library's own head")
        let next = ServerHead(logID: engine.head.logID, epoch: 1, seq: 2)
        engine.head = next
        hints.send(next)
        try await waitUntil { scheduler.history.count == 3 }
        #expect(scheduler.history.element(2) == [.hint])
        // In the background the stream closes.
        scheduler.setForeground(false)
        #expect(!scheduler.hintsConnected)
        await scheduler.stop()
    }

    @Test func withoutChangeHintsItPollsEveryInterval() async throws {
        let hints = Hints()
        hints.failure = ServerChangeHintError.unsupported
        let scheduler = scheduler(hints: hints)
        scheduler.start()
        scheduler.setForeground(true)
        try await waitUntil { scheduler.history.filter { $0.contains(.poll) }.count >= 2 }
        #expect(hints.connections == 1, "an older server is not asked again while the scene stays active")
        scheduler.setForeground(false)
        try await settled(scheduler)
        let count = scheduler.history.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(scheduler.history.count == count, "no polling in the background")
        await scheduler.stop()
    }

    @Test func aDroppedStreamIsPolledUntilItReconnects() async throws {
        let hints = Hints()
        var timing = Self.fast
        timing.reconnect = .seconds(2)
        let scheduler = scheduler(hints: hints, timing: timing)
        scheduler.start()
        scheduler.setForeground(true)
        try await waitUntil { hints.connections == 1 }
        hints.send(engine.head)
        try await waitUntil { scheduler.hintsConnected }
        hints.drop()
        try await waitUntil { scheduler.history.contains { $0.contains(.poll) } }
        try await waitUntil { hints.connections == 2 }
        hints.send(engine.head)
        try await waitUntil { scheduler.hintsConnected }
        try await settled(scheduler)
        let count = scheduler.history.count
        try await Task.sleep(for: .milliseconds(300))
        try await settled(scheduler)
        #expect(scheduler.history.count == count, "connected again: no more polling")
        await scheduler.stop()
    }

    @Test func withoutAPermittedNetworkItWaitsForTheNetwork() async throws {
        network.permittedNow = false
        let scheduler = scheduler()
        scheduler.start()
        scheduler.localChange()
        try await Task.sleep(for: .milliseconds(150))
        try await settled(scheduler)
        #expect(scheduler.history.isEmpty, "mobile data not allowed: nothing is sent")
        network.permittedNow = true
        try await waitUntil { scheduler.history.count == 1 }
        #expect(scheduler.history.first?.contains(.network) == true)
        await scheduler.stop()
    }

    /// On a network sync may not use (mobile data, preference off) no hint stream connects and
    /// nothing is sent; a permitted network starts both.
    @Test func aProhibitedNetworkOpensNoHintStream() async throws {
        network.permittedNow = false
        let hints = Hints()
        let scheduler = scheduler(hints: hints)
        scheduler.start()
        scheduler.setForeground(true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(hints.connections == 0 && engine.log.isEmpty, "nothing over a prohibited network")
        network.permittedNow = true
        try await waitUntil { hints.connections == 1 && engine.log.count == 1 }
        await scheduler.stop()
    }

    /// Mobile data becomes prohibited during an exchange (Wi-Fi lost, or the preference turned off): the exchange and
    /// the hints stop at once; a permitted network runs it again.
    @Test func aNetworkBecomingProhibitedStopsTheRunningWork() async throws {
        let hints = Hints()
        var timing = Self.fast
        timing.polling = .seconds(3_600)
        let scheduler = scheduler(hints: hints, timing: timing)
        scheduler.start()
        scheduler.setForeground(true)
        try await waitUntil { hints.connections == 1 }
        try await settled(scheduler)
        engine.hold()
        _ = Task { await scheduler.synchronizeNow() }
        try await waitUntil { scheduler.isExchanging }
        network.setWithoutPathChange(false)
        scheduler.networkPolicyChanged()
        try await waitUntil { engine.cancelled == 1 && !scheduler.hasPendingWork }
        #expect(!scheduler.hintsConnected)
        let count = engine.log.count
        network.permittedNow = true
        try await waitUntil { engine.log.count == count + 1 && hints.connections == 2 }
        #expect(scheduler.history.last?.contains(.network) == true, "\(scheduler.history)")
        await scheduler.stop()
    }

    @Test func whatWaitedForAPauseRunsWhenPlaybackPauses() async throws {
        var waiting = ServerExchangeReport()
        waiting.waitingForPause = true
        engine.queue(waiting)
        let scheduler = scheduler()
        scheduler.playbackChanged(playing: true)
        scheduler.start()
        try await waitUntil { scheduler.history.count == 1 }
        try await settled(scheduler)
        #expect(scheduler.needsProcessingTime)
        scheduler.playbackChanged(playing: false)
        try await waitUntil { scheduler.history.count == 2 }
        try await settled(scheduler)
        #expect(scheduler.history.element(1) == [.playbackPaused])
        #expect(!scheduler.needsProcessingTime)
        await scheduler.stop()
    }

    /// A publication over the budget waits while the app is in the foreground and runs when the
    /// app leaves it; a processing task is asked for meanwhile.
    @Test func whatWaitedForTheBackgroundRunsWhenTheAppLeavesTheForeground() async throws {
        let scheduler = scheduler()
        scheduler.start()
        try await waitUntil { scheduler.history.count == 1 }
        try await settled(scheduler)
        var waiting = ServerExchangeReport()
        waiting.waitingForBackground = true
        engine.queue(waiting)
        scheduler.setForeground(true)
        try await waitUntil { scheduler.history.count == 2 }
        try await settled(scheduler)
        #expect(scheduler.needsProcessingTime, "a processing task is asked for")
        scheduler.setForeground(false)
        try await waitUntil { scheduler.history.count == 3 }
        try await settled(scheduler)
        #expect(scheduler.history.element(2) == [.backgrounded], "\(scheduler.history)")
        #expect(!scheduler.needsProcessingTime)
        await scheduler.stop()
    }

    /// While audio plays, what waited for the app to leave the foreground runs when it leaves, still playing (the engine
    /// publishes it whole within the background budget), also when the app left during the exchange that found it waiting.
    @Test func whileAudioPlaysWhatWaitedForTheBackgroundRunsWhenTheAppLeavesTheForeground() async throws {
        let scheduler = scheduler()
        scheduler.start()
        try await waitUntil { scheduler.history.count == 1 }
        try await settled(scheduler)
        scheduler.playbackChanged(playing: true)
        var waiting = ServerExchangeReport()
        waiting.waitingForBackground = true
        engine.queue(waiting)
        scheduler.setForeground(true)
        try await waitUntil { scheduler.history.count == 2 }
        try await settled(scheduler)
        scheduler.setForeground(false)
        try await waitUntil { scheduler.history.count == 3 }
        try await settled(scheduler)
        #expect(scheduler.history.element(2) == [.backgrounded], "\(scheduler.history)")
        // The app left while the exchange that found it waiting ran.
        engine.queue(waiting)
        engine.hold()
        scheduler.setForeground(true)
        try await waitUntil { engine.log.count == 4 }
        scheduler.setForeground(false)
        engine.release()
        try await waitUntil { scheduler.history.count == 5 }
        try await settled(scheduler)
        #expect(scheduler.history.element(4) == [.backgrounded], "\(scheduler.history)")
        await scheduler.stop()
    }

    /// A repair waiting for the app to leave the foreground is not built again at every pause of playback: it runs
    /// when the app leaves the foreground.
    @Test func aRepairWaitingForTheBackgroundRunsWhenTheAppLeavesTheForeground() async throws {
        let scheduler = scheduler()
        scheduler.start()
        try await waitUntil { scheduler.history.count == 1 }
        try await settled(scheduler)
        scheduler.setForeground(true)
        try await waitUntil { scheduler.history.count == 2 }
        try await settled(scheduler)
        var waiting = ServerExchangeReport()
        waiting.waitingForBackground = true
        engine.queue(waiting)
        let first = await scheduler.forceFullSynchronization()
        #expect(first?.reprojected == false && scheduler.needsProcessingTime)
        scheduler.playbackChanged(playing: true)
        scheduler.playbackChanged(playing: false)
        scheduler.localChange()
        try await waitUntil { engine.log.count == 4 }
        try await settled(scheduler)
        #expect(engine.log == ["exchange", "exchange", "full", "exchange"], "no repair at the pause: \(engine.log)")
        scheduler.setForeground(false)
        try await waitUntil { engine.log.last == "full" && !scheduler.needsProcessingTime }
        #expect(!engine.requestedFull)
        await scheduler.stop()
    }

    /// Every foreground and playback transition moves the publication eligibility on, so a large
    /// publication allowed before it is refused at the store.
    @Test func transitionsMoveThePublicationEligibilityOn() async throws {
        let eligibility = ServerPublicationEligibility()
        let scheduler = ServerSyncScheduler(engine: engine, hints: nil, outbox: nil, network: network, timing: Self.fast, eligibility: eligibility)
        scheduler.start()
        var last = eligibility.current
        for step in ["foreground", "playing", "paused", "background"] {
            switch step {
            case "foreground": scheduler.setForeground(true)
            case "playing": scheduler.playbackChanged(playing: true)
            case "paused": scheduler.playbackChanged(playing: false)
            default: scheduler.setForeground(false)
            }
            #expect(eligibility.current != last, "\(step)")
            last = eligibility.current
        }
        await scheduler.stop()
    }

    /// A background task before the retry deadline sends nothing; its work runs with the
    /// retry, and the next task is asked for no earlier than the deadline. Synchronize now still runs at once.
    @Test func aBackgroundTaskHonoursTheRetryDeadline() async throws {
        var throttled = ServerExchangeReport()
        throttled.retryAfter = 3_600
        engine.queue(throttled)
        let scheduler = scheduler()
        scheduler.start()
        try await waitUntil { scheduler.lastReport?.retryAfter == 3_600 && !scheduler.hasPendingWork }
        #expect(await scheduler.runInBackground(.refresh) == false)
        #expect(await scheduler.runInBackground(.processing) == false)
        #expect(engine.log.count == 1, "nothing sent before the deadline: \(engine.log)")
        #expect(scheduler.pendingTriggers.contains(.background), "its work waits for the retry")
        let deadline = try #require(scheduler.retryNotBeforeDate)
        #expect(deadline > Date().addingTimeInterval(3_500))
        _ = await scheduler.synchronizeNow()
        #expect(engine.log.count == 2, "Synchronize now keeps its own policy")
        await scheduler.stop()
    }

    /// When the deadline passes, the waiting background work runs with the retry, once.
    @Test func backgroundWorkThatWaitedRunsWithTheRetry() async throws {
        var throttled = ServerExchangeReport()
        throttled.retryAfter = 1.5
        engine.queue(throttled)
        let scheduler = scheduler()
        scheduler.start()
        try await waitUntil { scheduler.lastReport?.retryAfter == 1.5 }
        #expect(await scheduler.runInBackground(.refresh) == false)
        try await waitUntil { scheduler.history.count == 2 }
        try await settled(scheduler)
        #expect(scheduler.history.element(1) == [.retry, .background], "\(scheduler.history)")
        await scheduler.stop()
    }

    @Test func synchronizeNowReturnsTheReportOfAnExchangeThatStartedAfterTheTap() async throws {
        let scheduler = scheduler()
        engine.hold()
        scheduler.start()
        try await waitUntil { scheduler.isExchanging }
        let tap = Task { await scheduler.synchronizeNow() }
        try await Task.sleep(for: .milliseconds(20))
        engine.release()
        let report = await tap.value
        #expect(report?.acknowledged == 2, "the exchange after the running one")
        #expect(scheduler.history.count == 2 && scheduler.history.element(1)?.contains(.requested) == true)
        await scheduler.stop()
    }

    @Test func forceFullSynchronizationRunsUntilItReprojects() async throws {
        let scheduler = scheduler()
        scheduler.start()
        try await waitUntil { scheduler.history.count == 1 }
        try await settled(scheduler)
        var waiting = ServerExchangeReport()
        waiting.waitingForPause = true
        engine.queue(waiting)
        scheduler.playbackChanged(playing: true)
        let first = await scheduler.forceFullSynchronization()
        #expect(first?.reprojected == false && scheduler.needsProcessingTime)
        scheduler.playbackChanged(playing: false)
        try await waitUntil { engine.log.filter { $0 == "full" }.count == 2 }
        try await settled(scheduler)
        #expect(!scheduler.needsProcessingTime)
        scheduler.localChange()
        try await waitUntil { engine.log.count == 4 }
        #expect(engine.log == ["exchange", "full", "full", "exchange"], "done: later exchanges are ordinary")
        await scheduler.stop()
    }

    /// A repair that waits is not staged again by every trigger (ordinary exchanges run then);
    /// it runs when playback pauses.
    @Test func aWaitingRepairIsNotStagedAgainOnEveryTrigger() async throws {
        let scheduler = scheduler()
        scheduler.start()
        try await waitUntil { scheduler.history.count == 1 }
        try await settled(scheduler)
        var waiting = ServerExchangeReport()
        waiting.waitingForPause = true
        engine.queue(waiting)
        scheduler.playbackChanged(playing: true)
        _ = await scheduler.forceFullSynchronization()
        for _ in 0..<3 {
            let count = engine.log.count
            scheduler.localChange()
            try await waitUntil { engine.log.count == count + 1 }
            try await settled(scheduler)
        }
        #expect(engine.log == ["exchange", "full", "exchange", "exchange", "exchange"], "\(engine.log)")
        scheduler.playbackChanged(playing: false)
        try await waitUntil { engine.log.last == "full" && !scheduler.needsProcessingTime }
        #expect(!engine.requestedFull)
        await scheduler.stop()
    }

    /// The request outlives the process: a scheduler made after a relaunch runs the repair at launch; a failed
    /// repair stays requested and runs again at its retry.
    @Test func aRepairRequestedBeforeTheAppStoppedRunsAtLaunchAndSurvivesAFailure() async throws {
        engine.requestedFull = true
        var failed = ServerExchangeReport()
        failed.error = "disk full"
        failed.retryAfter = 0.1
        engine.queue(failed)
        let scheduler = scheduler()
        scheduler.start()
        try await waitUntil { engine.log == ["full", "full"] && !scheduler.hasPendingWork }
        #expect(!engine.requestedFull && !scheduler.needsProcessingTime)
        await scheduler.stop()
    }

    /// New-episode notifications still owed (a release whose pull committed before the app
    /// ended, a publication that failed) are delivered at launch, when the app comes to the foreground and after every
    /// exchange, not only when an exchange brings new releases.
    @Test func owedReleaseNotificationsAreDeliveredAtLaunchInTheForegroundAndAfterEveryExchange() async throws {
        let scheduler = scheduler()
        var deliveries = 0
        scheduler.callbacks.releasesArrived = { deliveries += 1 }
        scheduler.start()
        #expect(deliveries == 1, "at launch")
        try await waitUntil { scheduler.exchangesRun == 1 }
        try await settled(scheduler)
        #expect(deliveries == 2, "after the launch exchange, which brought no release")
        scheduler.setForeground(true)
        #expect(deliveries == 3, "in the foreground")
        try await waitUntil { scheduler.exchangesRun == 2 }
        try await settled(scheduler)
        #expect(deliveries == 4)
        await scheduler.stop()
    }

    @Test func libraryChangesReachTheScreensAtMostOncePerInterval() async throws {
        var timing = Self.fast
        timing.reloadInterval = .milliseconds(500)
        let scheduler = scheduler(timing: timing)
        var reloads: [ContinuousClock.Instant] = []
        scheduler.callbacks.libraryChanged = { reloads.append(.now) }
        scheduler.start()
        for _ in 0..<10 { engine.continuation.yield(.libraryChanged) }
        try await waitUntil { reloads.count == 2 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(reloads.count == 2, "one at once, one trailing: \(reloads.count)")
        if reloads.count == 2 { #expect(reloads[0].duration(to: reloads[1]) >= .milliseconds(490)) }
        await scheduler.stop()
    }

    @Test func backgroundTasksRunAnExchangeOrUntilTheHeavyWorkIsDone() async throws {
        let scheduler = scheduler()
        scheduler.start()
        try await waitUntil { scheduler.history.count == 1 }
        try await settled(scheduler)
        #expect(await scheduler.runInBackground(.refresh))
        #expect(scheduler.history.last == [.background])
        var waiting = ServerExchangeReport()
        waiting.waitingForPause = true
        engine.queue(waiting)
        engine.queue(waiting)
        let before = scheduler.history.count
        #expect(await scheduler.runInBackground(.processing), "processing continues until nothing waits")
        #expect(scheduler.history.count - before >= 3, "three rounds: \(scheduler.history)")
        #expect(!scheduler.needsProcessingTime)
        await scheduler.stop()
    }

    /// When granted background time ends, a pending retry and a debounced push do not start
    /// exchanges afterwards; they run when a scene or a new grant allows it.
    @Test func backgroundExpiryParksRetriesAndPushesUntilAllowedAgain() async throws {
        var failed = ServerExchangeReport()
        failed.retryAfter = 0.2
        engine.queue(failed)
        let scheduler = scheduler()
        scheduler.start()
        try await waitUntil { scheduler.lastReport?.retryAfter == 0.2 }
        try await settled(scheduler)
        scheduler.localChange()
        scheduler.suspendForBackground()
        try await Task.sleep(for: .milliseconds(500)) // past the retry deadline and the debounce
        #expect(engine.log.count == 1, "nothing after the grant expired: \(scheduler.history)")
        scheduler.setExpedited(true) // a new grant
        try await waitUntil { engine.log.count == 2 }
        try await settled(scheduler)
        #expect(scheduler.history.last?.isSuperset(of: [.retry, .localChange]) == true, "\(scheduler.history)")
        await scheduler.stop()
    }

    /// While audio plays the app keeps running: a grant's end parks nothing.
    @Test func whileAudioPlaysAGrantsEndParksNothing() async throws {
        var failed = ServerExchangeReport()
        failed.retryAfter = 0.2
        engine.queue(failed)
        let scheduler = scheduler()
        scheduler.playbackChanged(playing: true)
        scheduler.start()
        try await waitUntil { scheduler.lastReport?.retryAfter == 0.2 }
        scheduler.suspendForBackground()
        try await waitUntil { engine.log.count == 2 }
        #expect(scheduler.history.last == [.retry])
        await scheduler.stop()
    }

    @Test func stoppingEndsTheRunningExchangeAndEveryTrigger() async throws {
        let scheduler = scheduler()
        engine.hold()
        scheduler.start()
        try await waitUntil { scheduler.isExchanging }
        await scheduler.stop()
        #expect(engine.cancelled == 1)
        scheduler.localChange()
        scheduler.setForeground(true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(scheduler.history.count == 1 && !scheduler.hasPendingWork)
    }

    /// Past the diagnostic history's cap, a request still returns its report and a background task
    /// still reports its success.
    @Test func requestsAndBackgroundRunsKeepReportingAfterAHundredExchanges() async throws {
        let scheduler = scheduler()
        scheduler.start()
        try await waitUntil { scheduler.history.count == 1 }
        try await settled(scheduler)
        for _ in 0..<101 { _ = await scheduler.synchronizeNow() }
        #expect(scheduler.history.count == 100, "diagnostics stay capped")
        #expect(await scheduler.synchronizeNow() != nil, "the 103rd request ran and says so")
        #expect(await scheduler.runInBackground(.refresh), "and a background run succeeds")
        #expect(scheduler.exchangesRun == 104)
        await scheduler.stop()
    }

    @Test func leavingAnEpisodeAppliesWhatWaitedForThePlayer() async throws {
        let scheduler = scheduler()
        scheduler.start()
        scheduler.playerLeftEpisode()
        try await waitUntil { engine.releasedPins == 1 }
        await scheduler.stop()
    }
}

/// Server-sent events as `GET /v1/events` sends them.
@Suite struct ServerSentEventParserTests {
    func events(_ text: String) -> [ServerSentEventParser.Event] {
        var parser = ServerSentEventParser()
        return Array(text.utf8).compactMap { parser.feed($0) }
    }

    @Test func changedEventsHeartbeatsAndClosing() {
        let stream = "event: changed\ndata: {\"log_id\":\"00000000-0000-4000-8000-000000000001\",\"epoch\":1,\"seq\":7}\n\n: heartbeat\n\nevent: closed\ndata: {}\n\n"
        let parsed = events(stream)
        #expect(parsed.map(\.name) == ["changed", "closed"])
        #expect(ServerEventStream.head(parsed.first?.data ?? "") == ServerHead(logID: "00000000-0000-4000-8000-000000000001", epoch: 1, seq: 7))
    }

    @Test func lineEndingsAndMultilineData() {
        #expect(events("event: a\r\ndata: x\r\ndata: y\r\n\r\n") == [.init(name: "a", data: "x\ny")])
        #expect(events("data:z\r\r") == [.init(name: "message", data: "z")])
        #expect(events("event: partial\ndata: no blank line yet\n").isEmpty)
    }
}

extension Array {
    /// The element at `index`, or nil (a failed wait must fail its test, not crash the run).
    func element(_ index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
