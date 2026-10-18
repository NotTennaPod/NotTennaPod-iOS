import Foundation
import Testing
@testable import NotTennaPodCore

/// When a server library exchanges (PROTOCOL §6.4), with an engine of the test's own: launch, local
/// actions after the debounce, retries, pauses, change hints and polling, the network, playback pauses, the page's
/// "Synchronize now" and "Force full synchronization", background work, and screens told at most once a second.
@MainActor @Suite(.serialized) struct ServerSyncSchedulerTests {
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
        func exchange(snapshots: Bool) async -> ServerExchangeReport { await run(snapshots ? "exchange" : "exchange without snapshots") }
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
        /// Why it is not permitted: no network unless the test says mobile data is off.
        var mobileDataOff: Bool {
            get { lock.withLock { mobileOff } }
            set { lock.withLock { mobileOff = newValue } }
        }
        private var mobileOff = false
        func permitted() async -> Bool { permittedNow }
        func waitReason() async -> ServerNetworkWait? { permittedNow ? nil : mobileDataOff ? .mobileDataOff : .offline }
        func changes() -> AsyncStream<Void> { stream }
    }

    /// Change hints the test sends; each connection is a new stream.
    final class Hints: ServerChangeHintSource, @unchecked Sendable {
        private let lock = NSLock()
        private var current: AsyncThrowingStream<ServerHead, any Error>.Continuation?
        private var opened = 0
        private var openedAt: [ContinuousClock.Instant] = []
        private var failing: (any Error)?
        private var connectHead: ServerHead?
        private var dropping = false
        /// Its own lock: a stream ending (`finish`) reports here while `lock` may be held.
        private let liveLock = NSLock()
        private var open = 0
        var connections: Int { lock.withLock { opened } }
        /// Streams opened and not ended yet.
        var live: Int { liveLock.withLock { open } }
        /// When each connection opened.
        var connectionTimes: [ContinuousClock.Instant] { lock.withLock { openedAt } }
        var failure: (any Error)? {
            get { lock.withLock { failing } }
            set { lock.withLock { failing = newValue } }
        }
        /// The head each connection sends at once, as the server does (PROTOCOL §12).
        var headAtConnect: ServerHead? {
            get { lock.withLock { connectHead } }
            set { lock.withLock { connectHead = newValue } }
        }
        /// Each connection ends right after its first head.
        var dropsAtOnce: Bool {
            get { lock.withLock { dropping } }
            set { lock.withLock { dropping = newValue } }
        }

        func hints() -> AsyncThrowingStream<ServerHead, any Error> {
            let (stream, continuation) = AsyncThrowingStream<ServerHead, any Error>.makeStream()
            liveLock.withLock { open += 1 }
            continuation.onTermination = { [weak self] _ in self?.liveLock.withLock { self?.open -= 1 } }
            lock.withLock {
                opened += 1
                openedAt.append(.now)
                if let failing { continuation.finish(throwing: failing); return }
                if let connectHead { continuation.yield(connectHead) }
                if dropping { continuation.finish() } else { current = continuation }
            }
            return stream
        }
        func send(_ head: ServerHead) { _ = lock.withLock { current?.yield(head) } }
        func drop() { lock.withLock { current?.finish(); current = nil } }
    }

    /// A gate whose `permitted()` answers can be held (a slow check) while `waitReason()` answers at once.
    final class HeldGate: ServerSyncNetworkGate, @unchecked Sendable {
        private let lock = NSLock()
        private var holding = false
        private var heldAnswers: [CheckedContinuation<Bool, Never>] = []
        private var reasons = 0
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        var holds: Bool {
            get { lock.withLock { holding } }
            set { lock.withLock { holding = newValue } }
        }
        var held: Int { lock.withLock { heldAnswers.count } }
        var reasonsAsked: Int { lock.withLock { reasons } }
        func permitted() async -> Bool {
            await withCheckedContinuation { answer in
                let hold = lock.withLock { () -> Bool in
                    guard holding else { return false }
                    heldAnswers.append(answer)
                    return true
                }
                if !hold { answer.resume(returning: true) }
            }
        }
        /// The held answers arrive now: permitted.
        func release() {
            let answers = lock.withLock { let list = heldAnswers; heldAnswers = []; return list }
            for answer in answers { answer.resume(returning: true) }
        }
        func waitReason() async -> ServerNetworkWait? { lock.withLock { reasons += 1 }; return nil }
        func changes() -> AsyncStream<Void> { stream }
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

    func scheduler(hints: (any ServerChangeHintSource)? = nil, timing: ServerSyncScheduler.Timing = fast,
                   snapshotsNeedForeground: Bool = false) -> ServerSyncScheduler {
        ServerSyncScheduler(engine: engine, hints: hints, outbox: { [stream = outbox.stream] in stream }, network: network, timing: timing,
                            snapshotsNeedForeground: snapshotsNeedForeground)
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

    /// Gaps between successive connections, from the second.
    static func gaps(_ times: [ContinuousClock.Instant]) -> [Duration] { zip(times, times.dropFirst()).map { $0.duration(to: $1) } }

    static var backoff: ServerSyncScheduler.Timing {
        var timing = fast
        timing.reconnect = .milliseconds(40); timing.polling = .milliseconds(320); timing.stableAfter = .seconds(60)
        return timing
    }

    /// A stream that drops right after the head the server sends at connect never stays up: reconnections back off
    /// 1, 2, 4, 8 times the first delay, up to the polling interval (5, 10, 20, 40, 60 s in the app), measured as
    /// connection attempts.
    @Test func aStreamDroppingRightAfterItsFirstHeadBacksOff() async throws {
        let hints = Hints()
        hints.headAtConnect = engine.head
        hints.dropsAtOnce = true
        let scheduler = scheduler(hints: hints, timing: Self.backoff)
        scheduler.start()
        scheduler.setForeground(true)
        try await waitUntil { hints.connections >= 7 }
        let gaps = Self.gaps(hints.connectionTimes)
        for (gap, expected) in zip(gaps, [40, 80, 160, 320, 320, 320].map { Duration.milliseconds($0) }) {
            #expect(gap >= expected - .milliseconds(2), "\(gaps)")
        }
        await scheduler.stop()
    }

    /// The same short connections, each cut off by the network going and coming back: the backoff survives the path
    /// changes (a flapping connection does not reconnect at once every time).
    @Test func shortConnectionsAcrossNetworkChangesKeepBackingOff() async throws {
        let hints = Hints()
        hints.headAtConnect = engine.head
        let scheduler = scheduler(hints: hints, timing: Self.backoff)
        scheduler.start()
        scheduler.setForeground(true)
        var ends: [ContinuousClock.Instant] = []
        for round in 1...5 {
            try await waitUntil { hints.connections == round && scheduler.hintsConnected }
            let before = scheduler.hintReconnectionNotBefore
            network.permittedNow = false
            try await waitUntil { scheduler.networkWait == .offline && scheduler.hintReconnectionNotBefore != before }
            ends.append(.now)
            network.permittedNow = true
            try await waitUntil { scheduler.networkWait == nil }
        }
        try await waitUntil { hints.connections == 6 }
        let times = hints.connectionTimes
        for (index, expected) in [40, 80, 160, 320, 320].map({ Duration.milliseconds($0) }).enumerated() {
            #expect(ends[index].duration(to: times[index + 1]) >= expected - .milliseconds(20), "\(Self.gaps(times))")
        }
        await scheduler.stop()
    }

    /// A connection that stays up past `stableAfter` starts the backoff again; a new foreground period does too.
    @Test func aStableConnectionOrANewForegroundPeriodResetsTheBackoff() async throws {
        let hints = Hints()
        hints.headAtConnect = engine.head
        hints.dropsAtOnce = true
        var timing = Self.backoff
        timing.reconnect = .milliseconds(40); timing.polling = .seconds(2); timing.stableAfter = .milliseconds(300)
        let scheduler = scheduler(hints: hints, timing: timing)
        scheduler.start()
        scheduler.setForeground(true)
        try await waitUntil { hints.connections == 4 }
        // Backed off to 320 ms; this connection stays up past stableAfter, then drops.
        hints.dropsAtOnce = false
        try await waitUntil { hints.connections == 5 && scheduler.hintsConnected }
        try await Task.sleep(for: .milliseconds(350))
        hints.dropsAtOnce = true
        hints.drop()
        try await waitUntil { hints.connections == 7 }
        var gaps = Self.gaps(hints.connectionTimes)
        #expect(gaps[4] >= .milliseconds(340) && gaps[5] < .milliseconds(600), "after the stable one: 40 ms, not 640 ms: \(gaps)")
        // Short again: backing off from the start.
        try await waitUntil { hints.connections == 9 }
        gaps = Self.gaps(hints.connectionTimes)
        #expect(gaps[6] >= .milliseconds(78) && gaps[7] >= .milliseconds(158), "\(gaps)")
        // The scene leaves and comes back: at once.
        scheduler.setForeground(false)
        let count = hints.connections
        scheduler.setForeground(true)
        let resumed = ContinuousClock.now
        try await waitUntil { hints.connections == count + 1 }
        #expect(resumed.duration(to: hints.connectionTimes[count]) < .milliseconds(200), "not after the 320 ms backoff")
        await scheduler.stop()
    }

    /// A hint task stopped while it waits for the gate's answer (the scene left) and replaced (it came back): the late
    /// answer changes nothing of its successor's, opens no stream, and a later network event opens no second one; a stop
    /// ends every stream it started.
    @Test func aLateGateAnswerOfAStoppedHintTaskNeverOpensASecondStream() async throws {
        let gate = HeldGate()
        let hints = Hints()
        hints.headAtConnect = engine.head
        var timing = Self.fast
        timing.polling = .seconds(3_600)
        let scheduler = ServerSyncScheduler(engine: engine, hints: hints, outbox: nil, network: gate, timing: timing)
        gate.holds = true
        scheduler.start()
        scheduler.setForeground(true)
        try await waitUntil { gate.held == 1 }
        // The scene leaves while the first task waits for its answer, and comes back: its replacement connects.
        scheduler.setForeground(false)
        gate.holds = false
        scheduler.setForeground(true)
        try await waitUntil { hints.connections == 1 && hints.live == 1 && scheduler.hintsConnected }
        // The stopped task's answer arrives late: permitted.
        gate.release()
        for _ in 0..<50 { await Task.yield() }
        #expect(scheduler.hintsConnected, "the replacement's state is its own")
        #expect(hints.connections == 1 && hints.live == 1, "no stream opened for a stopped task")
        // One network event, permitted: the hints that run stay the only ones.
        let asked = gate.reasonsAsked
        gate.continuation.yield(())
        try await waitUntil { gate.reasonsAsked > asked }
        for _ in 0..<50 { await Task.yield() }
        #expect(hints.connections == 1 && hints.live == 1, "one live hint stream: \(hints.connections) opened, \(hints.live) live")
        await scheduler.stop()
        try await waitUntil { hints.live == 0 }
        #expect(!scheduler.hintsConnected)
    }

    /// Path updates repeating the same network and answer are not passed on; a real change is, and so is a change of
    /// the answer alone (the mobile-data preference).
    @Test func repeatedIdenticalPathUpdatesAreNotNetworkChanges() async throws {
        var filter = DownloadNetworkSyncGate.ChangeFilter()
        let wifi = DownloadNetworkState(connected: true, metered: false, cellular: false, transport: .wifi)
        let cellular = DownloadNetworkState(connected: true, metered: true, cellular: true)
        let lowData = DownloadNetworkState(connected: true, metered: false, cellular: false, transport: .wifi, constrained: true)
        let passed = [filter.isChange(wifi, nil), filter.isChange(wifi, nil), filter.isChange(wifi, nil),
                      filter.isChange(cellular, .mobileDataOff), filter.isChange(cellular, nil), filter.isChange(cellular, nil),
                      filter.isChange(lowData, nil)]
        // The first, cellular, mobile sync allowed now (the answer alone changed), Low Data Mode.
        #expect(passed == [true, false, false, true, true, false, true])
        // Through the gate: one change passed on per real change.
        let monitor = DownloadNetworkMonitor(startMonitoring: false)
        let gate = DownloadNetworkSyncGate(monitor: monitor, allowMobile: { false })
        var iterator = gate.changes().makeAsyncIterator()
        monitor.update(wifi)
        let first: Void? = await iterator.next()
        monitor.update(cellular)
        let second: Void? = await iterator.next()
        #expect(first != nil && second != nil)
    }

    /// A local change in the background, pushed at once there, asks for granted time; so does a push waiting for the
    /// debounce, and every exchange that starts.
    @Test func startedWorkAsksForGrantedTime() async throws {
        let scheduler = scheduler()
        var started = 0
        scheduler.callbacks.workStarted = { started += 1 }
        scheduler.start()
        try await waitUntil { scheduler.history.count == 1 }
        try await settled(scheduler)
        #expect(started == 1, "the launch exchange")
        scheduler.localChange()
        #expect(started == 2 && scheduler.debouncing, "a push waiting for the debounce")
        try await waitUntil { scheduler.history.count == 2 }
        try await settled(scheduler)
        scheduler.setExpedited(true)
        let before = started
        scheduler.localChange()
        #expect(started == before + 1 && scheduler.hasPendingWork, "in the background: at once, with its time asked for")
        try await settled(scheduler)
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

    /// Low Data Mode does not stop ordinary sync, with mobile sync off too: positions and changes keep flowing. Mobile
    /// data with mobile sync off, and no network, are refused, each with its reason.
    @Test func ordinarySyncRunsOnLowDataWiFiWithMobileSyncOff() async {
        let monitor = DownloadNetworkMonitor(startMonitoring: false)
        let wifiOnly = DownloadNetworkSyncGate(monitor: monitor, allowMobile: { false })
        let mobile = DownloadNetworkSyncGate(monitor: monitor, allowMobile: { true })
        #expect(await wifiOnly.permitted(), "not known yet: try")
        monitor.update(.init(connected: true, metered: false, cellular: false, transport: .wifi, constrained: true))
        #expect(await wifiOnly.permitted())
        #expect(await wifiOnly.waitReason() == nil)
        monitor.update(.init(connected: true, metered: true, cellular: true, constrained: true))
        #expect(await wifiOnly.waitReason() == .mobileDataOff)
        #expect(await !wifiOnly.permitted())
        #expect(await mobile.permitted())
        monitor.update(.init(connected: false, metered: true, cellular: false))
        #expect(await wifiOnly.waitReason() == .offline)
        #expect(await mobile.waitReason() == .offline)
    }

    /// Without a permitted network the page is told why (no network, or mobile data sync may not use), apart from
    /// any exchange's result; the network back, it is told once more and what waited runs.
    @Test func noPermittedNetworkIsToldWithItsReason() async throws {
        network.permittedNow = false
        network.mobileDataOff = true
        let scheduler = scheduler()
        var waits: [ServerNetworkWait?] = []
        scheduler.callbacks.networkWaitChanged = { waits.append($0) }
        scheduler.start()
        scheduler.localChange()
        try await waitUntil { waits == [.mobileDataOff] }
        try await settled(scheduler)
        #expect(scheduler.history.isEmpty && scheduler.networkWait == .mobileDataOff)
        network.mobileDataOff = false
        network.permittedNow = true
        try await waitUntil { scheduler.history.count == 1 }
        #expect(waits == [.mobileDataOff, nil])
        await scheduler.stop()
    }

    /// Successful, then idle with nothing to send, then the network goes: the page is told at once, without a user
    /// action and without an exchange or a report standing for one; it comes back the same way.
    @Test func theNetworkGoingWhileIdleIsToldWithoutAnExchange() async throws {
        let scheduler = scheduler()
        var waits: [ServerNetworkWait?] = []
        var reports: [ServerExchangeReport] = []
        scheduler.callbacks.networkWaitChanged = { waits.append($0) }
        scheduler.callbacks.reported = { reports.append($0) }
        scheduler.start()
        try await waitUntil { scheduler.history.count == 1 && reports.contains { $0.completed } }
        try await settled(scheduler)
        let reported = reports.count
        network.permittedNow = false
        try await waitUntil { waits == [.offline] }
        network.permittedNow = true
        try await waitUntil { waits == [.offline, nil] }
        try await settled(scheduler)
        #expect(scheduler.history.count == 1, "nothing waited: nothing runs")
        #expect(reports.count == reported, "the network never stands for an exchange's result")
        #expect(scheduler.lastReport?.completed == true)
        await scheduler.stop()
    }

    /// The network goes while an exchange runs: the page is told at once, the exchange is cancelled (never a success),
    /// and its cancelled report does not clear what the page says; the network back, the exchange runs again.
    @Test func theNetworkGoingDuringAnExchangeIsToldAndTheExchangeRunsAgain() async throws {
        let scheduler = scheduler()
        var waits: [ServerNetworkWait?] = []
        scheduler.callbacks.networkWaitChanged = { waits.append($0) }
        scheduler.start()
        try await waitUntil { scheduler.history.count == 1 }
        try await settled(scheduler)
        engine.hold()
        scheduler.localChange()
        try await waitUntil { scheduler.isExchanging }
        network.permittedNow = false
        try await waitUntil { engine.cancelled == 1 && !scheduler.hasPendingWork }
        #expect(waits == [.offline] && scheduler.networkWait == .offline)
        let count = engine.log.count
        network.permittedNow = true
        try await waitUntil { engine.log.count == count + 1 }
        try await settled(scheduler)
        #expect(waits == [.offline, nil] && scheduler.history.last?.contains(.network) == true)
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
        var delivered: [LibraryChangeSet] = []
        scheduler.callbacks.libraryChanged = { reloads.append(.now); delivered.append($0) }
        scheduler.start()
        for index in 0..<10 { engine.continuation.yield(.libraryChanged(Self.changes(episode: Int64(index)))) }
        try await waitUntil { reloads.count == 2 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(reloads.count == 2, "one at once, one trailing: \(reloads.count)")
        if reloads.count == 2 { #expect(reloads[0].duration(to: reloads[1]) >= .milliseconds(490)) }
        // The trailing delivery is the union of what arrived meanwhile: nothing is lost.
        #expect(Set(delivered.flatMap(\.episodes.keys)) == Set(0..<10))
        await scheduler.stop()
    }

    static func changes(episode: Int64) -> LibraryChangeSet {
        var set = LibraryChangeSet(identity: .init(library: nil, incarnation: UUID()), sequence: episode + 1, origin: .sync)
        set.episodes[episode] = .init(change: .changed, feed: 1)
        return set
    }

    /// An empty change set never reaches the screens, and position knowledge is told at once, unpaced.
    @Test func anEmptyChangeSetIsNotToldAndKnowledgeIsToldAtOnce() async throws {
        let scheduler = scheduler()
        var reloads = 0
        var knowledge: [LibraryPositionKnowledge] = []
        scheduler.callbacks.libraryChanged = { _ in reloads += 1 }
        scheduler.callbacks.positionKnowledge = { knowledge.append($0) }
        scheduler.start()
        try await waitUntil { scheduler.history.count == 1 }
        try await settled(scheduler)
        let before = knowledge.count
        engine.continuation.yield(.libraryChanged(LibraryChangeSet(identity: .init(library: nil, incarnation: UUID()), sequence: 1, origin: .sync)))
        for id in 0..<3 { engine.continuation.yield(.positionKnowledge(.init(episodes: [Int64(id)]))) }
        try await waitUntil { knowledge.count == before + 3 }
        #expect(reloads == 0, "an empty set is not a change")
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

    /// A background app refresh task has seconds: with a Force full synchronization owed it runs an ordinary exchange
    /// that starts no snapshot download (the repair, or a recovery's download, waits for a processing task or the app);
    /// a processing task runs the repair.
    @Test func aRefreshTaskNeverStartsASnapshotDownload() async throws {
        // The repair owed at launch waits for the app to leave the foreground.
        engine.requestedFull = true
        var waiting = ServerExchangeReport()
        waiting.waitingForBackground = true
        for _ in 0..<3 { engine.queue(waiting) }
        var timing = Self.fast
        timing.polling = .seconds(3_600)
        let scheduler = scheduler(timing: timing)
        scheduler.start()
        scheduler.setForeground(true)
        // The activation may run before the launch has read the owed repair: the repair runs at the first exchange that knows it.
        try await waitUntil { engine.log.contains("full") }
        try await settled(scheduler)
        #expect(engine.requestedFull)
        let before = engine.log.count
        _ = await scheduler.runInBackground(.refresh)
        #expect(Array(engine.log.dropFirst(before)) == ["exchange without snapshots"], "\(engine.log)")
        _ = await scheduler.runInBackground(.processing)
        #expect(engine.log.dropFirst(before).contains("full"), "\(engine.log)")
        await scheduler.stop()
    }

    /// A refresh task that finds parked work (a local change whose grant ended) still downloads no snapshot: the rule
    /// follows the task, not the triggers it runs.
    @Test func aRefreshTaskWithParkedWorkStillStartsNoSnapshotDownload() async throws {
        let scheduler = scheduler()
        scheduler.start()
        try await waitUntil { scheduler.history.count == 1 }
        try await settled(scheduler)
        scheduler.localChange()
        scheduler.suspendForBackground()
        try await waitUntil { scheduler.pendingTriggers.contains(.localChange) }
        let before = engine.log.count
        _ = await scheduler.runInBackground(.refresh)
        #expect(scheduler.history.last == [.background, .localChange], "\(scheduler.history)")
        #expect(Array(engine.log.dropFirst(before)) == ["exchange without snapshots"], "\(engine.log)")
        await scheduler.stop()
    }

    /// The app started in the background (for a refresh task): its launch exchange downloads nothing and an owed
    /// repair waits; in the foreground the repair runs.
    @Test func aLaunchInTheBackgroundDownloadsNothingUntilTheForeground() async throws {
        engine.requestedFull = true
        var timing = Self.fast
        timing.polling = .seconds(3_600)
        let scheduler = scheduler(timing: timing, snapshotsNeedForeground: true)
        scheduler.start()
        try await waitUntil { !engine.log.isEmpty }
        try await settled(scheduler)
        #expect(engine.log == ["exchange without snapshots"], "\(engine.log)")
        scheduler.setForeground(true)
        try await waitUntil { engine.log.contains("full") }
        await scheduler.stop()
    }

    /// While a recovery waits for playback to pause (its download or switch), hints, polls and local changes do not ask
    /// the server again at every trigger; the pause runs it.
    @Test func aRecoveryWaitingForThePauseRunsAtThePauseNotAtEveryTrigger() async throws {
        let scheduler = scheduler()
        scheduler.start()
        try await waitUntil { scheduler.history.count == 1 }
        try await settled(scheduler)
        scheduler.playbackChanged(playing: true)
        var waiting = ServerExchangeReport()
        waiting.recovery = .running
        waiting.waitingForPause = true
        engine.queue(waiting)
        _ = await scheduler.synchronizeNow()
        let before = engine.log.count
        scheduler.localChange()
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.log.count == before, "a local change waits for the pause: \(engine.log)")
        scheduler.playbackChanged(playing: false)
        try await waitUntil { engine.log.count > before }
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
