import UIKit
import BackgroundTasks
import NotTennaPodCore
import OSLog

@MainActor protocol AutomaticBackupScheduling: AnyObject {
    func submit(earliest: Date)
    func cancel()
}

/// Background opportunity for a due backup. `BGProcessingTask`: no network or power
/// requirement, as the source worker has no constraints.
@MainActor final class NativeAutomaticBackupScheduler: AutomaticBackupScheduling {
    static let identifier = "org.nottennapod.app.database-backup"
    func submit(earliest: Date) {
        let request = BGProcessingTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = earliest
        request.requiresNetworkConnectivity = false; request.requiresExternalPower = false
        BGTaskScheduler.shared.submitTaskRequest(request) { error in
            guard error != nil else { return }
            Logger(subsystem: "org.nottennapod.app", category: "AutomaticBackup").notice("Background backup request not accepted; the next foreground check runs a due backup")
        }
    }
    func cancel() { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier) }
}

/// Source `AutomaticDatabaseExportWorker` scheduling, adapted to iOS (bounded platform adaptation): enabling
/// runs a backup immediately; afterwards a backup is due 3 days after the last run (successful or failed).
/// A due backup runs in a background processing window when iOS grants one, and otherwise at the next
/// launch or activation. Runs are single flight.
/// A run the app starts (not a processing window) holds the app's background grant while it runs, and parks at once
/// without time; a processing window's expiration completes its lease at once and exactly once. Before a run starts, a
/// bounded successor request is submitted, and kept when the run is cancelled, so an ended run is retried by a later
/// window without a tight loop. Every run has an attempt identity: a run that was cancelled (expiration, disable, the
/// graph stopping) is forgotten at once, and anything it reports later (its outcome, `lastRun`, a refreshed bookmark,
/// its leases) is ignored, even after a replacement run started.
@MainActor final class AutomaticDatabaseExportRuntime {
    /// How soon a backup that did not finish may run in a background window again: never a tight retry loop.
    static let retryDelay: TimeInterval = 60 * 60
    typealias Folder = (_ bookmark: Data, _ refreshed: @escaping @Sendable (Data) -> Void) -> any AutomaticBackupFolder
    private struct Run {
        let id: UUID
        let task: Task<Void, Never>
        var membership: BackgroundWorkGrant.Membership?
    }
    private let preferences: AutomaticDatabaseExportPreferenceStore
    private let scheduler: any AutomaticBackupScheduling
    private let clock: () -> Date
    private let folder: Folder
    private let grant: BackgroundWorkGrant?
    private let payload: @Sendable () async throws -> Data
    private let report: (String) -> Void
    private var current: Run?
    private var leases: [any PeriodicRefreshBackgroundLease] = []
    var onChange: (() -> Void)?
    /// Observation only (DEBUG UI-test marker): "done <file>", "failed <message>" or "scheduled".
    var onOutcome: ((String) -> Void)?

    init(preferences: AutomaticDatabaseExportPreferenceStore, scheduler: any AutomaticBackupScheduling = NativeAutomaticBackupScheduler(),
         clock: @escaping () -> Date = { Date() }, folder: Folder? = nil, grant: BackgroundWorkGrant? = nil,
         payload: @escaping @Sendable () async throws -> Data, report: @escaping (String) -> Void) {
        self.preferences = preferences; self.scheduler = scheduler; self.clock = clock; self.grant = grant
        self.payload = payload; self.report = report
        self.folder = folder ?? { bookmark, refreshed in SecurityScopedBackupFolder(bookmark: bookmark, refreshed: refreshed) }
    }

    var isEnabled: Bool { preferences.value.isEnabled }
    var isRunning: Bool { current != nil }

    /// Switch ON with a chosen folder (source `setupAutomaticBackup`, REPLACE): store it and back up now.
    func enable(bookmark: Data) throws {
        try preferences.update { $0.bookmark = bookmark }
        onChange?()
        start()
    }

    /// Switch OFF: forget the folder, cancel scheduling and any run; existing backups stay.
    func disable() throws {
        try preferences.update { $0.bookmark = nil }
        scheduler.cancel()
        cancelCurrent()
        finishLeases(success: false)
        onChange?()
    }

    /// Launch/activation (source `MainActivity.onCreate` KEEP): run a due backup, else keep the request.
    func resume() {
        guard isEnabled else { return }
        let now = clock()
        if let last = preferences.value.lastRun, last > now { try? preferences.update { $0.lastRun = now } }
        if AutomaticDatabaseExport.isDue(lastRun: preferences.value.lastRun, now: now) { start() }
        else {
            scheduler.submit(earliest: AutomaticDatabaseExport.nextDue(lastRun: preferences.value.lastRun, now: now))
            onOutcome?("scheduled")
        }
    }

    /// A background processing window. Its expiration completes its lease at once, whatever the run still has to wind
    /// down; the run stops and the backup stays due for the successor request.
    func launch(_ lease: any PeriodicRefreshBackgroundLease) {
        guard isEnabled else { lease.complete(success: false); return }
        lease.expiration = { [weak self, weak lease] in
            guard let self, let lease else { return }
            leaseExpired(lease)
        }
        leases.append(lease)
        if current == nil {
            if AutomaticDatabaseExport.isDue(lastRun: preferences.value.lastRun, now: clock()) { start(inWindow: true) }
            else { finishLeases(success: true) }
        }
    }

    /// Database import (graph stop): cancel silently; the schedule and folder are kept.
    func stop() {
        cancelCurrent()
        finishLeases(success: false)
    }

    private func leaseExpired(_ lease: any PeriodicRefreshBackgroundLease) {
        // Exactly once: a completed lease is no longer held.
        guard let index = leases.firstIndex(where: { $0 === lease }) else { return }
        leases.remove(at: index)
        cancelCurrent()
        lease.complete(success: false)
    }

    private func start(inWindow: Bool = false) {
        guard current == nil, let bookmark = preferences.value.bookmark else { return }
        let id = UUID(), now = clock(), payload = payload
        // Before any work: should this run end before it finishes, a later background window still runs the backup.
        scheduler.submit(earliest: now.addingTimeInterval(Self.retryDelay))
        let folder = folder(bookmark) { [weak self] fresh in
            Task { @MainActor in self?.bookmarkRefreshed(fresh, from: bookmark, attempt: id) }
        }
        let work = Task.detached(priority: .utility) { () -> Result<String, any Error> in
            do { return .success(try await AutomaticDatabaseExport.run(folder: folder, now: now, timeZone: .current, attempt: id, payload: payload)) }
            catch { return .failure(error) }
        }
        // Disable/stop/expiration cancel the detached work too.
        current = Run(id: id, task: Task { [weak self] in
            let outcome = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            self?.finish(outcome, attempt: id)
        })
        onChange?()
        // A run the app started holds the background grant; in the background without time it parks at once.
        guard !inWindow, let grant else { return }
        let membership = grant.join(.init(hasWork: { [weak self] in self?.current?.id == id },
                                          park: { [weak self] in self?.park(attempt: id) }))
        if current?.id == id { current?.membership = membership } else { membership.leave() }
    }

    /// The background grant ended (expired or refused): the run stops; the backup stays due and its successor request
    /// stays.
    private func park(attempt id: UUID) {
        guard current?.id == id else { return }
        Logger(subsystem: "org.nottennapod.app", category: "AutomaticBackup").notice("Backup stopped by the end of background time; it runs again later")
        cancelCurrent()
        finishLeases(success: false)
    }

    private func cancelCurrent() {
        guard let run = current else { return }
        current = nil
        run.task.cancel()
        run.membership?.leave()
        onChange?()
    }

    /// A refreshed bookmark of the folder this run uses, saved only while the run is current and the folder unchanged.
    private func bookmarkRefreshed(_ fresh: Data, from original: Data, attempt id: UUID) {
        guard current?.id == id, preferences.value.bookmark == original else { return }
        try? preferences.update { $0.bookmark = fresh }
    }

    private func finish(_ outcome: Result<String, any Error>, attempt id: UUID) {
        // A cancelled or replaced run reports nothing.
        guard let run = current, run.id == id else { return }
        current = nil
        run.membership?.leave()
        if case .failure(let error) = outcome, error is CancellationError {
            // Stopped without being asked: still due, its successor request kept.
            finishLeases(success: false)
            onChange?()
            return
        }
        // A failed run also waits for the next period; success is silent.
        try? preferences.update { $0.lastRun = clock() }
        switch outcome {
        case .success(let name): onOutcome?("done \(name)")
        case .failure(let error):
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            report(message); onOutcome?("failed \(message)")
        }
        if isEnabled { scheduler.submit(earliest: AutomaticDatabaseExport.nextDue(lastRun: preferences.value.lastRun, now: clock())) }
        finishLeases(success: true)
        onChange?()
    }

    private func finishLeases(success: Bool) {
        let finished = leases; leases = []
        for lease in finished { lease.complete(success: success) }
    }
}
