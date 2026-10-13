import Foundation

/// One instance belongs to the application lifetime, shared by every refresh entry
/// point. The journal persists work; this owner serializes its mutations and retains
/// execution independently of a screen or the caller awaiting enqueue completion.
@MainActor
public final class ManualFeedRefreshCoordinator {
    public enum State: Equatable, Sendable {
        case idle
        /// Includes network waiting. Source list running state includes queued
        /// work; per-feed notification progress comes from worker effects.
        case active(FeedRefreshRequest)
        case suspended(FeedRefreshRequest?)
        case failed(FeedRefreshRequest, message: String)
    }
    public private(set) var state: State = .idle
    public var onChange: ((State) -> Void)?

    private let store: FeedLibraryStore
    private let execute: @Sendable (FeedRefreshRequest) async throws -> Void
    private let clock: () -> Int64
    private var commands: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var current: FeedRefreshRequest?
    private var suspended = false
    private var stateListeners: [UUID: AsyncStream<State>.Continuation] = [:]
    // Android statics reset at process startup; recovery must not seed these
    // from a persisted request's date, even if that request was recently queued.
    private var lastManualMilliseconds: Int64 = 0
    private var lastManualFeedID: Int64?

    public convenience init(store: FeedLibraryStore, worker: FeedRefreshWorker) {
        self.init(store: store, execute: { try await worker.run($0) })
    }

    init(store: FeedLibraryStore,
         clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         execute: @escaping @Sendable (FeedRefreshRequest) async throws -> Void) {
        self.store = store; self.clock = clock; self.execute = execute
    }

    deinit { work?.cancel(); for listener in stateListeners.values { listener.finish() } }

    /// Await the owned refresh, including replacements, without replacing the
    /// UI's onChange callback or polling. Cancelling a waiter leaves refresh alive.
    public func waitUntilIdle() async throws {
        let id = UUID()
        let stream = AsyncStream<State>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            stateListeners[id] = continuation
            continuation.yield(state)
        }
        defer { stateListeners.removeValue(forKey: id)?.finish() }
        for await value in stream {
            try Task.checkCancellation()
            if case .active = value { continue }
            return
        }
        try Task.checkCancellation()
    }

    /// The UI uses this decision for source cooldown/offline/mobile messaging.
    /// Call runOnce immediately for .run, or after Once/Always confirmation.
    public func admission(feedID: Int64?, isLocalFeed: Bool, network: DownloadNetworkState,
                          refreshAllowed: Bool) -> ManualFeedRefreshAdmission {
        ManualFeedRefreshAdmission(feedID: feedID, isLocalFeed: isLocalFeed, nowMilliseconds: clock(),
            lastManualMilliseconds: lastManualMilliseconds, lastManualFeedID: lastManualFeedID,
            connected: network.connected, refreshAllowed: refreshAllowed,
            restricted: network.restricted, vpnOverWiFi: network.vpnOverWiFi)
    }

    /// Source runOnce bypasses admission (including Edit URL), and updates the
    /// process-local cooldown at invocation. Completion means durably accepted,
    /// not that feeds have finished. An enqueue failure leaves earlier work intact.
    @discardableResult
    public func runOnce(feedID: Int64?, isLocalFeed: Bool = false,
                        nextPage: Bool = false, resetPagination: Bool = false) -> Task<FeedRefreshRequest, any Error> {
        let now = clock()
        lastManualMilliseconds = now; lastManualFeedID = feedID
        let request = FeedRefreshRequest(feedID: feedID, nextPage: nextPage, isLocalFeed: isLocalFeed,
            enqueuedAt: Date(timeIntervalSince1970: Double(now) / 1000))
        return command { owner in
            // Persist the source's pagination reset with the replacement job so
            // a terminated process cannot leave the reset without its refresh.
            try await owner.store.enqueueManualRefresh(request, resetPagination: resetPagination)
            owner.start(request)
            return request
        }
    }

    /// Recover after launch/foregrounding or retry a retained failure. Repeated
    /// recovery while the same request is owned does not start a second worker.
    @discardableResult
    public func resume() -> Task<Void, any Error> {
        suspended = false
        return command { owner in
            let saved = try await owner.store.manualRefreshRequest()
            if let saved { owner.start(saved) }
            else {
                owner.stopExecution()
                owner.current = nil
                owner.publish(owner.suspended ? .suspended(nil) : .idle)
            }
        }
    }

    /// End this execution lease (for example OS expiration), retaining durable
    /// work for a later resume. Pending accepted commands still persist in order.
    public func suspend() {
        suspended = true
        stopExecution()
        publish(.suspended(current))
    }

    /// UUID-targeted notification cancellation cannot erase a newer request.
    @discardableResult
    public func cancel(requestID: UUID) -> Task<Bool, any Error> {
        command { owner in
            guard try await owner.store.finishManualRefresh(id: requestID) else { return false }
            if owner.current?.id == requestID {
                owner.stopExecution()
                owner.current = nil
                owner.publish(owner.suspended ? .suspended(nil) : .idle)
            }
            return true
        }
    }

    // Actor isolation alone cannot serialize operations that await the store:
    // the chain preserves command invocation order through those suspensions.
    private func command<Value: Sendable>(
        _ operation: @escaping @MainActor (ManualFeedRefreshCoordinator) async throws -> Value
    ) -> Task<Value, any Error> {
        let previous = commands
        let task = Task { [weak self] in
            await previous?.value
            try Task.checkCancellation()
            guard let self else { throw CancellationError() }
            return try await operation(self)
        }
        commands = Task { _ = try? await task.value }
        return task
    }

    private func start(_ request: FeedRefreshRequest) {
        if current?.id == request.id && work != nil { return }
        stopExecution()
        current = request
        guard !suspended else { publish(.suspended(request)); return }
        let token = generation, execute = execute
        work = Task { [weak self] in
            let result: Result<Void, any Error>
            do {
                while true {
                    try Task.checkCancellation()
                    do { try await execute(request); break }
                    catch is DownloadNetworkInterruption {
                        // The worker's next attempt waits for connectivity before
                        // executing. A changed network is not a failed feed/job.
                        try Task.checkCancellation()
                    }
                }
                try Task.checkCancellation()
                result = .success(())
            } catch { result = .failure(error) }
            guard !Task.isCancelled else { return }
            self?.finished(result, request: request, token: token)
        }
        // Ownership is stored before a callback can synchronously suspend or
        // request another refresh. Nothing afterward overwrites that decision.
        publish(.active(request))
    }

    private func finished(_ result: Result<Void, any Error>, request: FeedRefreshRequest, token: UUID) {
        guard generation == token, current?.id == request.id else { return }
        work = nil
        switch result {
        case .success:
            current = nil
            publish(.idle)
        case .failure(let error):
            publish(.failed(request, message: String(describing: error)))
        }
    }

    private func stopExecution() {
        generation = UUID()
        work?.cancel(); work = nil
    }
    private func publish(_ value: State) {
        state = value
        for listener in stateListeners.values { listener.yield(value) }
        onChange?(value)
    }
}
