import UIKit
import BackgroundTasks
import NotTennaPodCore

@MainActor protocol PeriodicRefreshScheduling: AnyObject {
    func submit(earliest: Date) async throws
    func cancel()
}

@MainActor final class NativePeriodicRefreshScheduler: PeriodicRefreshScheduling {
    nonisolated static let identifier = "org.nottennapod.app.feed-refresh"
    @concurrent nonisolated func submit(earliest: Date) async throws {
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = earliest
        try await BGTaskScheduler.shared.submitTaskRequest(request)
    }
    func cancel() { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier) }
}

@MainActor protocol PeriodicRefreshBackgroundLease: AnyObject, Sendable {
    var expiration: (@MainActor () -> Void)? { get set }
    func complete(success: Bool)
}

@MainActor final class NativePeriodicRefreshLease: PeriodicRefreshBackgroundLease {
    private let task: BGTask
    var expiration: (@MainActor () -> Void)?
#if DEBUG
    private var hubLease: String?
#endif
    init(_ task: BGTask) {
        self.task = task
        task.expirationHandler = { [weak self] in Task { @MainActor in self?.expiration?() } }
#if DEBUG
        // The hub bridge may call the task's own expiration handler, as iOS would.
        hubLease = HubBridge.shared?.leaseTaken(kind: "periodic-refresh") { [weak task] in task?.expirationHandler?() }
#endif
    }
    func complete(success: Bool) {
        expiration = nil; task.expirationHandler = nil
        task.setTaskCompleted(success: success)
#if DEBUG
        if let hubLease { HubBridge.shared?.leaseEnded(hubLease, state: "released", success: success) }
#endif
    }
}

/// BGAppRefresh grants execution time; foreground checks use the same durable
/// schedule and owner. Neither path invents an exact background launch guarantee.
@MainActor final class PeriodicFeedRefreshRuntime {
    private let owner: PeriodicFeedRefreshCoordinator
    private let scheduler: any PeriodicRefreshScheduling
    private var configuration: Task<Void, Never>?
    private var foreground = false
    private var foregroundRun: Task<Void, Never>?
    private var background: (id: UUID, lease: any PeriodicRefreshBackgroundLease, work: Task<Void, Never>)?
    private var revision = UUID()
    private var submission: Task<Void, Never>?
    private let clock: () -> Date
    var onFailure: ((any Error) -> Void)?

    init(owner: PeriodicFeedRefreshCoordinator, scheduler: any PeriodicRefreshScheduling = NativePeriodicRefreshScheduler(),
         clock: @escaping () -> Date = { Date() }) {
        self.owner = owner; self.scheduler = scheduler; self.clock = clock
    }
    deinit { foregroundRun?.cancel(); background?.work.cancel() }

    @discardableResult
    func configure(intervalMinutes: Int, allowMobile: Bool, replace: Bool) -> Task<Void, Never> {
        let previous = configuration
        let token = UUID(); revision = token
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                // Preference files and the work journal commit independently.
                // Recover an interrupted preference callback before applying KEEP.
                let saved = try await owner.schedule()
                let changed = saved.map { $0.intervalMinutes != intervalMinutes || $0.allowMobile != allowMobile } ?? false
                _ = try await owner.configure(intervalMinutes: intervalMinutes, allowMobile: allowMobile, replace: replace || changed).value
                guard revision == token else { return }
                if intervalMinutes == 0 { scheduler.cancel() }
                scheduleWake(token: token)
                restartForeground()
            } catch { onFailure?(error) }
        }
        configuration = task
        return task
    }

    /// Database import: end every run and release a background lease before the library is replaced.
    func stop() {
        configuration?.cancel(); configuration = nil
        foregroundRun?.cancel(); foregroundRun = nil
        submission?.cancel(); submission = nil
        if let background { background.work.cancel(); background.lease.complete(success: false); self.background = nil }
        owner.suspend()
    }

    func setForeground(_ value: Bool) {
        guard foreground != value else { return }
        foreground = value
        if value { restartForeground() }
        else {
            foregroundRun?.cancel(); foregroundRun = nil
            if background == nil { owner.suspend() }
        }
    }

    private func restartForeground() {
        foregroundRun?.cancel(); foregroundRun = nil
        guard foreground else { return }
        foregroundRun = Task { [weak self] in
            await self?.configuration?.value
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    guard let schedule = try await owner.schedule() else { return }
                    let delay = max(0, schedule.nextCheck.timeIntervalSince(clock()))
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    try Task.checkCancellation()
                    try await owner.runDue().value
                    try Task.checkCancellation()
                    scheduleWake(token: revision)
                } catch is CancellationError { return }
                catch {
                    onFailure?(error)
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
        }
    }

    func launch(_ lease: any PeriodicRefreshBackgroundLease) {
        guard background == nil else { lease.complete(success: false); return }
        let id = UUID()
        lease.expiration = { [weak self] in self?.expire(id) }
        let work = Task { [weak self] in
            guard let self else { return }
            await configuration?.value
            guard !Task.isCancelled, background?.id == id else { return }
            // Submit the next opportunity before starting any network work.
            scheduleWake(token: revision, minimumDelay: 3_600)
            do {
                try await owner.runDue().value
                finish(id, success: !Task.isCancelled)
            } catch {
                if !(error is CancellationError) { onFailure?(error) }
                finish(id, success: false)
            }
            scheduleWake(token: revision)
        }
        background = (id, lease, work)
    }

    private func expire(_ id: UUID) {
        guard background?.id == id else { return }
        background?.work.cancel()
        if !foreground { owner.suspend() }
        finish(id, success: false)
    }
    private func finish(_ id: UUID, success: Bool) {
        guard let active = background, active.id == id else { return }
        background = nil; active.lease.complete(success: success)
    }
    func waitForScheduling() async { await submission?.value }

    private func scheduleWake(token: UUID, minimumDelay: TimeInterval = 30) {
        // SDK27 submission may complete after an arbitrary delay. Serialize OS
        // writes without blocking foreground work or persisting the user's Never.
        let previous = submission
        submission = Task { [weak self] in
            await previous?.value
            guard let self, token == revision else { return }
            do {
                let schedule = try await owner.schedule()
                guard token == revision else { return }
                guard let schedule else { scheduler.cancel(); return }
                try await scheduler.submit(earliest: max(schedule.nextCheck, clock().addingTimeInterval(minimumDelay)))
                // A late submission must not resurrect a cancelled/replaced job.
                // No newer submission starts until this serial operation ends.
                if token != revision { scheduler.cancel() }
            } catch { onFailure?(error) }
        }
    }
}
