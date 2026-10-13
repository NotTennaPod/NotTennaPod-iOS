import UIKit
import Testing
import Synchronization
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Automatic database export runtime with a fake scheduler, folder, lease and clock, plus the
/// Backup & restore switch row. Real Files picker and folder writes run in the automatic database export journey.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct AutomaticDatabaseExportRuntimeTests {
    final class Scheduler: AutomaticBackupScheduling {
        var submitted: [Date] = [], cancels = 0
        func submit(earliest: Date) { submitted.append(earliest) }
        func cancel() { cancels += 1 }
    }
    /// The chosen folder's files; each run gets its own view, whose coordination its cancellation stops.
    final class Folder: Sendable {
        let names = Mutex<[String]>([]), failing = Mutex(false)
        /// A provider stall inside the next create accessor, which ignores cancellation.
        let stall = Mutex<DispatchSemaphore?>(nil), stalled = Mutex(false)
        var backups: [String] { names.withLock { $0.filter(AutomaticDatabaseExport.isBackupName) } }
        func view() -> View { View(self) }
        final class View: AutomaticBackupFolder, Sendable {
            let folder: Folder, cancelled = Mutex(false)
            init(_ folder: Folder) { self.folder = folder }
            private func live() throws { if cancelled.withLock({ $0 }) { throw CancellationError() } }
            func list() throws -> [AutomaticBackupFolderItem] {
                try live()
                if folder.failing.withLock({ $0 }) { throw CocoaError(.fileReadNoPermission) }
                return folder.names.withLock { $0.map { .init(name: $0, isRegularFile: true, modified: Date()) } }
            }
            func create(_ name: String, data: Data) throws {
                try live()
                if let stall = folder.stall.withLock({ value in defer { value = nil }; return value }) {
                    folder.stalled.withLock { $0 = true }
                    stall.wait()
                }
                folder.names.withLock { $0.append(name) }
            }
            func rename(_ name: String, to newName: String) throws {
                try live()
                try folder.names.withLock { names in
                    guard !names.contains(newName) else { throw AutomaticDatabaseExport.Failure.nameTaken }
                    names = names.map { $0 == name ? newName : $0 }
                }
            }
            func remove(_ name: String) throws { try live(); folder.names.withLock { $0.removeAll { $0 == name } } }
            func isComplete(_ name: String) throws -> Bool? { try live(); return true }
            func cancel() { cancelled.withLock { $0 = true } }
        }
    }
    final class Lease: PeriodicRefreshBackgroundLease {
        var expiration: (@MainActor () -> Void)?
        var results: [Bool] = []
        func complete(success: Bool) { results.append(success) }
    }
    final class Gate: Sendable {
        let open = Mutex(true), calls = Mutex(0)
        /// The library gate the payload collects its source under (`LibraryExport.collect`).
        let library = LibraryGate()
        func payload() async throws -> Data {
            calls.withLock { $0 += 1 }
            while !open.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
            try await library.acquireSharedUnlessCancelled()
            library.releaseShared()
            return Data("backup".utf8)
        }
    }
    /// UIKit's background task, as the app's grant sees it.
    final class Time: BackgroundTimeProviding {
        var isInBackground = false, refuses = false, begun = 0, ended: [Bool] = []
        var expiration: (@MainActor () -> Void)?
        func begin(expired: @escaping @MainActor () -> Void) -> Int? {
            guard !refuses else { return nil }
            begun += 1; expiration = expired; return begun
        }
        func end(_ grant: Int, expired: Bool) { ended.append(expired) }
    }

    private func wait(_ stage: String, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate(), Comment(rawValue: stage))
    }

    private func make(now: @escaping () -> Date, gate: Gate = Gate(), folder: Folder = Folder(), grant: BackgroundWorkGrant? = nil,
                      refreshed: Box? = nil) throws
        -> (AutomaticDatabaseExportRuntime, AutomaticDatabaseExportPreferenceStore, Scheduler, Folder, Box) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("M18R-\(UUID()).json")
        let store = try AutomaticDatabaseExportPreferenceStore(file: file)
        let scheduler = Scheduler(), reports = Box()
        let runtime = AutomaticDatabaseExportRuntime(preferences: store, scheduler: scheduler, clock: now, folder: { _, refresh in
            refreshed?.refreshers.append(refresh)
            return folder.view()
        }, grant: grant, payload: { try await gate.payload() }, report: { reports.values.append($0) })
        return (runtime, store, scheduler, folder, reports)
    }
    final class Box { var values: [String] = []; var outcomes: [String] = []; var refreshers: [@Sendable (Data) -> Void] = [] }

    @Test func enablingBacksUpImmediatelyThenSchedulesThreeDaysLater() async throws {
        let start = Date()
        let (runtime, store, scheduler, folder, reports) = try make(now: { start })
        #expect(!runtime.isEnabled)
        try runtime.enable(bookmark: Data([1]))
        try await wait("first run") { folder.names.withLock { $0.count } == 1 && !runtime.isRunning }
        #expect(store.value.lastRun == start && reports.values.isEmpty, "Success is silent")
        #expect(scheduler.submitted.last == start.addingTimeInterval(AutomaticDatabaseExport.interval))
        runtime.resume()
        #expect(folder.names.withLock { $0.count } == 1, "Not due yet: no second backup")
    }

    @Test func dueCheckRunsOnceAndFailureWaitsForTheNextPeriod() async throws {
        var now = Date()
        let gate = Gate(); gate.open.withLock { $0 = false }
        let (runtime, store, scheduler, folder, reports) = try make(now: { now }, gate: gate)
        try store.update { $0.bookmark = Data([1]); $0.lastRun = now.addingTimeInterval(-AutomaticDatabaseExport.interval) }
        runtime.resume(); runtime.resume(); runtime.resume()
        try await wait("single flight") { gate.calls.withLock { $0 } == 1 }
        gate.open.withLock { $0 = true }
        try await wait("done") { !runtime.isRunning }
        #expect(gate.calls.withLock { $0 } == 1 && folder.names.withLock { $0.count } == 1)
        // A failing folder: the source message is reported and the run still counts.
        now = now.addingTimeInterval(AutomaticDatabaseExport.interval)
        folder.failing.withLock { $0 = true }
        runtime.resume()
        try await wait("failed run") { reports.values.count == 1 }
        #expect(reports.values == ["Unable to open export folder"])
        #expect(store.value.lastRun == now && scheduler.submitted.last == now.addingTimeInterval(AutomaticDatabaseExport.interval))
        runtime.resume()
        #expect(reports.values.count == 1, "No retry until the next period")
    }

    @Test func disablingForgetsTheFolderCancelsAndStopIsSilent() async throws {
        let now = Date()
        let gate = Gate(); gate.open.withLock { $0 = false }
        let (runtime, store, scheduler, folder, reports) = try make(now: { now }, gate: gate)
        try runtime.enable(bookmark: Data([1]))
        try await wait("running") { gate.calls.withLock { $0 } == 1 }
        try runtime.disable()
        gate.open.withLock { $0 = true }
        try await wait("cancelled") { !runtime.isRunning }
        #expect(!store.value.isEnabled && scheduler.cancels == 1 && folder.names.withLock { $0.isEmpty } && reports.values.isEmpty)
        #expect(store.value.lastRun == nil, "A cancelled run does not count")
        // Import stop: silent, folder and schedule kept.
        gate.open.withLock { $0 = false }
        try runtime.enable(bookmark: Data([2]))
        try await wait("running again") { gate.calls.withLock { $0 } == 2 }
        runtime.stop()
        gate.open.withLock { $0 = true }
        try await wait("stopped") { !runtime.isRunning }
        #expect(store.value.isEnabled && reports.values.isEmpty && folder.names.withLock { $0.isEmpty })
    }

    @Test func backgroundWindowRunsADueBackupAndCompletesItsLease() async throws {
        let now = Date()
        let (runtime, store, _, folder, _) = try make(now: { now })
        let idle = Lease()
        runtime.launch(idle)
        #expect(idle.results == [false], "Disabled: nothing to do")
        try store.update { $0.bookmark = Data([1]); $0.lastRun = now.addingTimeInterval(-AutomaticDatabaseExport.interval - 1) }
        let lease = Lease()
        runtime.launch(lease)
        try await wait("lease completed") { lease.results == [true] }
        #expect(folder.names.withLock { $0.count } == 1)
        let early = Lease()
        runtime.launch(early)
        #expect(early.results == [true] && folder.names.withLock { $0.count } == 1, "Not due: completes without a backup")
    }

    // MARK: - Background time for the backup

    @Test func windowExpirationCompletesItsLeaseAtOnceWhileTheBackupWaitsForTheLibraryGate() async throws {
        let now = Date(), gate = Gate()
        let (runtime, store, scheduler, folder, reports) = try make(now: { now }, gate: gate)
        runtime.onOutcome = { reports.outcomes.append($0) }
        try store.update { $0.bookmark = Data([1]) }
        await gate.library.acquireExclusive() // a Keep at logout moving libraries
        let lease = Lease()
        runtime.launch(lease)
        #expect(scheduler.submitted == [now.addingTimeInterval(AutomaticDatabaseExportRuntime.retryDelay)], "The successor comes first")
        try await wait("waiting for the gate") { gate.library.hasWaiters }
        let expire = try #require(lease.expiration)
        expire()
        #expect(lease.results == [false], "Completed at once, before the work has wound down")
        #expect(!runtime.isRunning)
        expire()
        #expect(lease.results == [false], "Exactly once")
        try await wait("the wait ends") { !gate.library.hasWaiters }
        gate.library.releaseExclusive()
        #expect(!gate.library.isHeld && folder.names.withLock { $0.isEmpty } && reports.values.isEmpty && reports.outcomes.isEmpty)
        #expect(store.value.lastRun == nil, "Still due")
        #expect(scheduler.submitted == [now.addingTimeInterval(AutomaticDatabaseExportRuntime.retryDelay)], "Its successor stays")
    }

    @Test func aLateFinishAfterAReplacementRunStartedChangesNothing() async throws {
        var now = Date()
        let folder = Folder(), stall = DispatchSemaphore(value: 0)
        folder.stall.withLock { $0 = stall }
        let (runtime, store, scheduler, _, reports) = try make(now: { now }, folder: folder)
        runtime.onOutcome = { reports.outcomes.append($0) }
        try store.update { $0.bookmark = Data([1]) }
        let first = Lease()
        runtime.launch(first)
        try await wait("first run inside the provider's write") { folder.stalled.withLock { $0 } }
        // Its window ends while the provider still writes; the person opens the app later and a new run starts.
        first.expiration?()
        #expect(first.results == [false])
        now = now.addingTimeInterval(60)
        runtime.resume()
        try await wait("replacement run done") { reports.outcomes.count == 1 && !runtime.isRunning }
        let done = try #require(reports.outcomes.first)
        #expect(done.hasPrefix("done NotTennaPodBackup-") && store.value.lastRun == now)
        let submitted = scheduler.submitted
        // The first run's accessor finishes now: it publishes nothing and reports nothing.
        stall.signal()
        try await wait("the first run's file is never published") {
            folder.names.withLock { $0.count } == 2 && folder.backups.count == 1
        }
        #expect(folder.names.withLock { $0.filter(AutomaticDatabaseExport.isIncompleteName).count } == 1, "Left for the next run")
        #expect(reports.outcomes == [done] && store.value.lastRun == now && scheduler.submitted == submitted && first.results == [false])
        // The next run removes it.
        try store.update { $0.lastRun = nil }
        runtime.resume()
        try await wait("next run") { reports.outcomes.count == 2 && !runtime.isRunning }
        #expect(folder.names.withLock { $0.filter(AutomaticDatabaseExport.isIncompleteName).isEmpty })
    }

    @Test func theGrantsEndParksTheBackupKeepingItDueAndItsSuccessor() async throws {
        let now = Date(), gate = Gate(); gate.open.withLock { $0 = false }
        let time = Time()
        let grant = BackgroundWorkGrant(time: time, pollInterval: .seconds(30))
        let (runtime, store, scheduler, folder, reports) = try make(now: { now }, gate: gate, grant: grant)
        runtime.onOutcome = { reports.outcomes.append($0) }
        try runtime.enable(bookmark: Data([1]))
        try await wait("running") { gate.calls.withLock { $0 } == 1 }
        #expect(time.begun == 0, "In the foreground the backup needs no grant")
        time.isInBackground = true
        grant.enterBackground()
        #expect(time.begun == 1, "Leaving the app, the running backup holds the grant")
        let expire = try #require(time.expiration)
        expire()
        #expect(time.ended == [true] && !runtime.isRunning)
        gate.open.withLock { $0 = true }
        try await wait("wound down") { gate.calls.withLock { $0 } == 1 }
        #expect(store.value.lastRun == nil && reports.outcomes.isEmpty && folder.backups.isEmpty, "Still due; nothing published")
        #expect(scheduler.submitted.last == now.addingTimeInterval(AutomaticDatabaseExportRuntime.retryDelay), "Its successor stays")
        // Started again while the time is still exhausted (a later background activation): it parks at once.
        runtime.resume()
        #expect(!runtime.isRunning && time.begun == 1, "Time that ran out is not renewed")
        // The app is active again: the due backup runs.
        time.isInBackground = false
        grant.enterForeground()
        runtime.resume()
        try await wait("done") { reports.outcomes.count == 1 && !runtime.isRunning }
        #expect(reports.outcomes[0].hasPrefix("done ") && folder.backups.count == 1 && store.value.lastRun == now)
        #expect(scheduler.submitted.last == now.addingTimeInterval(AutomaticDatabaseExport.interval))
    }

    @Test func startingInTheBackgroundWithoutTimeParksAtOnce() async throws {
        let now = Date(), time = Time()
        time.isInBackground = true; time.refuses = true
        let grant = BackgroundWorkGrant(time: time, pollInterval: .seconds(30))
        let (runtime, store, scheduler, folder, reports) = try make(now: { now }, grant: grant)
        runtime.onOutcome = { reports.outcomes.append($0) }
        try store.update { $0.bookmark = Data([1]) }
        // A background launch (a finished download) runs the due-backup check.
        runtime.resume()
        #expect(!runtime.isRunning, "No time: parked at once")
        #expect(scheduler.submitted == [now.addingTimeInterval(AutomaticDatabaseExportRuntime.retryDelay)])
        #expect(store.value.lastRun == nil && reports.outcomes.isEmpty && folder.backups.isEmpty)
    }

    @Test func aLateBookmarkRefreshNeverReplacesTheFolderChosenSince() async throws {
        let now = Date(), refreshed = Box(), gate = Gate(); gate.open.withLock { $0 = false }
        let (runtime, store, _, _, _) = try make(now: { now }, gate: gate, refreshed: refreshed)
        try runtime.enable(bookmark: Data([1]))
        try await wait("running") { gate.calls.withLock { $0 } == 1 }
        let late = try #require(refreshed.refreshers.first)
        try runtime.disable()
        try runtime.enable(bookmark: Data([2]))
        late(Data([9]))
        try await wait("second run started") { gate.calls.withLock { $0 } == 2 }
        #expect(store.value.bookmark == Data([2]), "The first run's refreshed bookmark of the old folder is ignored")
        // The current run's own refresh of its folder is kept.
        let current = try #require(refreshed.refreshers.last)
        current(Data([3]))
        try await wait("saved") { store.value.bookmark == Data([3]) }
        gate.open.withLock { $0 = true }
        try await wait("done") { !runtime.isRunning }
    }

    @Test func switchRowSitsBetweenExportAndImportAndReflectsState() throws {
        func find<T: UIView>(_ id: String, in view: UIView) -> T? {
            if let match = view as? T, view.accessibilityIdentifier == id { return match }
            return view.subviews.lazy.compactMap { find(id, in: $0) }.first
        }
        var taps = 0
        for on in [false, true] {
            let shell = BackupRestoreView(importAction: {}, exportAction: {}, databaseExportAction: {}, databaseImportAction: {},
                                          automaticExport: .init(isOn: on, toggle: { taps += 1 }))
            shell.frame = CGRect(origin: .zero, size: shell.sizeThatFits(CGSize(width: 390, height: 844))); shell.layoutIfNeeded()
            let export: UIButton = try #require(find("databaseExport", in: shell)), auto: UIButton = try #require(find("automaticDatabaseExport", in: shell))
            let restore: UIButton = try #require(find("databaseImport", in: shell))
            #expect(export.frame.maxY <= auto.frame.minY + 0.01 && auto.frame.maxY <= restore.frame.minY + 0.01, "\(export.frame) \(auto.frame) \(restore.frame)")
            #expect(auto.accessibilityLabel == "Automatic database export")
            #expect(auto.accessibilityHint == "Create a backup of the NotTennaPod database every 3 days. Only keep the 5 most recent backups.")
            #expect(auto.accessibilityValue == (on ? "On" : "Off"))
            let toggle = try #require(auto.subviews.compactMap { $0 as? PreferenceSwitchView }.first)
            #expect(toggle.isOn == on && toggle.frame.maxX <= auto.bounds.width - 16)
            let texts = auto.subviews.compactMap { $0 as? UILabel }
            #expect(texts.allSatisfy { $0.frame.maxX <= toggle.frame.minX }, "Text never runs under the switch")
            auto.sendActions(for: .touchUpInside)
        }
        #expect(taps == 2)
    }
}
