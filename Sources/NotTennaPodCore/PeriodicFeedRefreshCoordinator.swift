import Foundation

/// App-wide execution owner for the independent scheduled slot. OS and foreground
/// callers join the same execution; cancelling a caller does not erase durable work.
@MainActor public final class PeriodicFeedRefreshCoordinator {
    private let store: FeedLibraryStore
    private let execute: @Sendable (FeedRefreshRequest) async throws -> Void
    private let clock: @Sendable () -> Date
    private var commands: Task<Void, Never>?
    private var work: Task<Void, any Error>?
    private var current: UUID?
    private var generation = UUID()
    private var suspended = false
    public var onEnd: ((UUID) -> Void)?

    public convenience init(store: FeedLibraryStore, worker: FeedRefreshWorker) {
        self.init(store: store, execute: { try await worker.run($0) })
    }
    init(store: FeedLibraryStore, clock: @escaping @Sendable () -> Date = { Date() },
         execute: @escaping @Sendable (FeedRefreshRequest) async throws -> Void) {
        self.store = store; self.clock = clock; self.execute = execute
    }
    deinit { work?.cancel() }

    @discardableResult
    public func configure(intervalMinutes: Int, allowMobile: Bool, replace: Bool) -> Task<PeriodicFeedRefreshSchedule?, any Error> {
        command { owner in
            let schedule = try await owner.store.configurePeriodicRefresh(intervalMinutes: intervalMinutes,
                allowMobile: allowMobile, replace: replace, now: owner.clock())
            if replace || schedule == nil { owner.suspend() }
            return schedule
        }
    }

    public func schedule() async throws -> PeriodicFeedRefreshSchedule? { try await store.periodicRefreshSchedule() }

    public func runDue() -> Task<Void, any Error> {
        suspended = false
        let preparation = command { owner -> Task<Void, any Error> in
            guard !owner.suspended else { throw CancellationError() }
            if let work = owner.work { return work }
            guard let request = try await owner.store.beginPeriodicRefresh(now: owner.clock()) else { return Task {} }
            let token = UUID(); owner.generation = token; owner.current = request.id
            let execute = owner.execute
            let work = Task { [weak owner] in
                defer {
                    if let owner, owner.generation == token {
                        owner.work = nil; owner.current = nil; owner.onEnd?(request.id)
                    }
                }
                while true {
                    try Task.checkCancellation()
                    do { try await execute(request); return }
                    catch is DownloadNetworkInterruption { try Task.checkCancellation() }
                }
            }
            owner.work = work
            return work
        }
        return Task { try await preparation.value.value }
    }

    /// Expiration retains the request and its atomic notification journal.
    public func suspend() {
        suspended = true
        generation = UUID(); work?.cancel(); work = nil
        if let current { self.current = nil; onEnd?(current) }
    }

    private func command<Value: Sendable>(_ operation: @escaping @MainActor (PeriodicFeedRefreshCoordinator) async throws -> Value) -> Task<Value, any Error> {
        let previous = commands
        let task = Task { await previous?.value; return try await operation(self) }
        commands = Task { _ = try? await task.value }
        return task
    }
}
