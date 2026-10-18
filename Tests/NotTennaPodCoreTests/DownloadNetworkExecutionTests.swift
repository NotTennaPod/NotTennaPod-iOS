import Foundation
import Network
import Synchronization
import Testing
@testable import NotTennaPodCore

@Suite
struct DownloadNetworkExecutionTests {
    @Test func nativePathWithoutConnectionPreservesAndroidConservativeMetering() {
        for status in [NWPath.Status.satisfied, .unsatisfied, .requiresConnection] {
            for expensive in [false, true] {
                for cellular in [false, true] {
                    let state = DownloadNetworkMonitor.nativeState(status: status, isExpensive: expensive, usesCellular: cellular)
                    #expect(state.connected == (status == .satisfied))
                    #expect(state.metered == (status != .satisfied || expensive))
                    #expect(state.cellular == cellular)
                    #expect(state.restricted == (status != .satisfied || expensive || cellular))
                    #expect(!state.vpnOverWiFi) // No native VPN detection has been established.
                    #expect(DownloadNetworkConstraint.connected.permits(state) == (status == .satisfied))
                    #expect(DownloadNetworkConstraint.unmetered.permits(state) == (status == .satisfied && !expensive))
                }
            }
        }
    }

    /// Low Data Mode is restricted (the Mobile updates prompts and permissions apply) and is not UNMETERED: a Wi-Fi-only
    /// job waits instead of starting where the background session would refuse it; one allowed on any network runs.
    @Test func lowDataModeIsRestrictedAndNotUnmetered() {
        for (wifi, expensive) in [(true, false), (false, false), (false, true)] {
            let state = DownloadNetworkMonitor.nativeState(status: .satisfied, isExpensive: expensive, usesCellular: !wifi && expensive,
                                                           usesWiFi: wifi, isConstrained: true)
            #expect(state.constrained && state.restricted)
            #expect(DownloadNetworkConstraint.connected.permits(state))
            #expect(!DownloadNetworkConstraint.unmetered.permits(state))
        }
        let ordinary = DownloadNetworkMonitor.nativeState(status: .satisfied, isExpensive: false, usesCellular: false, usesWiFi: true)
        #expect(!ordinary.constrained && !ordinary.restricted && DownloadNetworkConstraint.unmetered.permits(ordinary))
    }

    /// The network turns to Low Data Mode while a job runs: a Wi-Fi-only job stops and waits for an unrestricted network,
    /// where it runs; a job allowed on any network (a mobile allowance or "Allow this time") keeps its stored constraint
    /// and continues.
    @Test func lowDataModeDuringAJobStopsOnlyWiFiOnlyWork() async throws {
        let lowData = DownloadNetworkState(connected: true, metered: false, cellular: false, transport: .wifi, constrained: true)
        let monitor = monitor()
        await #expect(throws: DownloadNetworkInterruption.self) {
            try await monitor.perform(under: .unmetered) {
                monitor.update(lowData)
                return 42
            }
        }
        #expect(try await monitor.perform(under: .connected) {
            monitor.update(.init(connected: true, metered: false, cellular: false))
            monitor.update(lowData)
            return 42
        } == 42)
        let waiting = Task { try await monitor.waitUntilPermitted(.unmetered) }
        defer { waiting.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while monitor.pendingWaitCount != 1 && ContinuousClock.now < deadline { await Task.yield() }
        try #require(monitor.pendingWaitCount == 1, "waits on Low Data Wi-Fi")
        monitor.update(.init(connected: true, metered: false, cellular: false, transport: .wifi))
        try await waiting.value
        #expect(try await monitor.perform(under: .unmetered) { 7 } == 7)
        #expect(monitor.pendingWaitCount == 0)
    }

    @Test func firstObservationReleasesAllReadersIncludingOfflineWithoutReleasingDownloadWaiters() async throws {
        let monitor = DownloadNetworkMonitor(startMonitoring: false)
        let readers = (0..<30).map { _ in Task { try await monitor.observedState() } }
        let download = Task { try await monitor.waitUntilPermitted(.connected) }
        defer { readers.forEach { $0.cancel() }; download.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while (monitor.pendingObservationCount != 30 || monitor.pendingWaitCount != 1) && ContinuousClock.now < deadline {
            await Task.yield()
        }
        try #require(monitor.pendingObservationCount == 30 && monitor.pendingWaitCount == 1)
        let offline = DownloadNetworkState(connected: false, metered: false, cellular: false)
        monitor.update(offline)
        for reader in readers { #expect(try await reader.value == offline) }
        #expect(monitor.pendingObservationCount == 0 && monitor.pendingWaitCount == 1)
        let cellular = DownloadNetworkState(connected: true, metered: true, cellular: true)
        monitor.update(cellular)
        try await download.value
        #expect(try await monitor.observedState() == cellular)
        #expect(monitor.pendingWaitCount == 0)
    }

    private func monitor() -> DownloadNetworkMonitor {
        let monitor = DownloadNetworkMonitor(startMonitoring: false)
        monitor.update(.init(connected: true, metered: false, cellular: false))
        return monitor
    }

    @Test func ordinaryFailureDoesNotBecomeNetworkInterruption() async throws {
        let monitor = monitor()
        await #expect(throws: MediaDownloadError.httpStatus(500)) {
            try await monitor.perform(under: .unmetered) { throw MediaDownloadError.httpStatus(500) }
        }
        #expect(monitor.pendingWaitCount == 0)
    }

    @Test func changedPermissionBeforeOperationDoesNotStartOrStrandActiveWork() async throws {
        let monitor = DownloadNetworkMonitor(startMonitoring: false)
        for state in [nil, DownloadNetworkState(connected: true, metered: true, cellular: true)] {
            if let state { monitor.update(state) }
            let started = Mutex(false)
            await #expect(throws: DownloadNetworkInterruption.self) {
                try await monitor.perform(under: .unmetered) { started.withLock { $0 = true } }
            }
            #expect(started.withLock { $0 } == false)
            #expect(monitor.pendingWaitCount == 0)
        }
    }

    @Test func briefDisallowedTransitionCannotBeMissedBeforeWatcherRegistration() async throws {
        for _ in 0..<100 {
            let monitor = monitor()
            await #expect(throws: DownloadNetworkInterruption.self) {
                try await monitor.perform(under: .unmetered) {
                    monitor.update(.init(connected: true, metered: true, cellular: true))
                    monitor.update(.init(connected: true, metered: false, cellular: false))
                    return 42
                }
            }
            #expect(monitor.pendingWaitCount == 0)
        }
    }

    @Test func connectedConstraintPermitsMeteringChangeButNotDisconnection() async throws {
        let monitor = monitor()
        #expect(try await monitor.perform(under: .connected) {
            monitor.update(.init(connected: true, metered: true, cellular: true))
            return 42
        } == 42)
        await #expect(throws: DownloadNetworkInterruption.self) {
            try await monitor.perform(under: .connected) {
                monitor.update(.init(connected: false, metered: false, cellular: false))
                return 42
            }
        }
        #expect(monitor.pendingWaitCount == 0)
    }

    @Test func networkInterruptionWaitsForOperationToStopBeforeReturning() async throws {
        let monitor = monitor()
        let continuation = Mutex<CheckedContinuation<Int, any Error>?>(nil)
        let cancelled = Mutex(false)
        let returned = Mutex(false)
        let task = Task {
            defer { returned.withLock { $0 = true } }
            return try await monitor.perform(under: .unmetered) {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { pending in continuation.withLock { $0 = pending } }
                } onCancel: { cancelled.withLock { $0 = true } }
            }
        }
        defer {
            task.cancel()
            continuation.withLock { let value = $0; $0 = nil; return value }?.resume(throwing: CancellationError())
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while continuation.withLock({ $0 == nil }) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(continuation.withLock { $0 != nil })
        monitor.update(.init(connected: false, metered: false, cellular: false))
        while !cancelled.withLock({ $0 }) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(cancelled.withLock { $0 })
        #expect(returned.withLock { $0 } == false)
        continuation.withLock { let value = $0; $0 = nil; return value }?.resume(throwing: CancellationError())
        await #expect(throws: DownloadNetworkInterruption.self) { try await task.value }
        #expect(monitor.pendingWaitCount == 0)
    }

    @Test func callerCancellationWinsOverNetworkLoss() async throws {
        for _ in 0..<100 {
            let monitor = monitor()
            let started = Mutex(false)
            let task = Task {
                try await monitor.perform(under: .unmetered) {
                    started.withLock { $0 = true }
                    try await Task.sleep(for: .seconds(30))
                }
            }
            defer { task.cancel() }
            let deadline = ContinuousClock.now + .seconds(5)
            while !started.withLock({ $0 }) && ContinuousClock.now < deadline { await Task.yield() }
            try #require(started.withLock { $0 })
            task.cancel()
            monitor.update(.init(connected: false, metered: false, cellular: false))
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(monitor.pendingWaitCount == 0)
        }
    }
}
