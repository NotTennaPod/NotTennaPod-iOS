import Foundation

/// One application lifetime owns the saved sync slot. Pending replacements reset
/// the timer. An active same-account pass can finish during the source debounce;
/// an eligible successor first retires it, so two workers never share cursors.
@MainActor public final class SynchronizationCoordinator {
    public enum State: Equatable, Sendable {
        case idle, suspended
        case waiting(SynchronizationRequest), running(SynchronizationRequest)
        case failed(message: String)
    }
    public private(set) var state: State = .suspended
    public var onChange: ((State) -> Void)?

    private struct Ticket: Equatable {
        let epoch: UUID
        let request: SynchronizationRequest
    }
    private let store: FeedLibraryStore
    private let execute: @Sendable (SynchronizationRequest) async throws -> SynchronizationWorker.Outcome
    private let clock: @Sendable () -> Date
    private let sleepUntil: @Sendable (Date) async throws -> Void
    private let announceStarted: @MainActor @Sendable (SynchronizationRequest, UUID) async throws -> Void
    private var announcedRequest: UUID?
    private var commands: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var scan: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var scheduled: Ticket?
    private var timerID = UUID()
    private var execution: Task<Void, Never>?
    private var executing: Ticket?
    private var executionID = UUID()
    private var failed: Ticket?
    private var suspended = true
    private var generation = UUID()
    private var wakePending = false
    private var expedited = false

    public convenience init(store: FeedLibraryStore, worker: SynchronizationWorker, delivery: SynchronizationDelivery) {
        self.init(store: store, announceStarted: { request, epoch in
            try await delivery.requestAccepted(request, epoch: epoch)
        }, execute: { try await worker.run($0) })
    }

    init(store: FeedLibraryStore, clock: @escaping @Sendable () -> Date = { Date() },
         sleepUntil: @escaping @Sendable (Date) async throws -> Void = { date in
             while date > Date() {
                 try await Task.sleep(for: .seconds(min(date.timeIntervalSinceNow, 60)))
             }
             try Task.checkCancellation()
         }, announceStarted: @escaping @MainActor @Sendable (SynchronizationRequest, UUID) async throws -> Void = { _, _ in },
         execute: @escaping @Sendable (SynchronizationRequest) async throws -> SynchronizationWorker.Outcome) {
        self.store = store; self.clock = clock; self.sleepUntil = sleepUntil; self.execute = execute
        self.announceStarted = announceStarted
    }

    deinit { observation?.cancel(); scan?.cancel(); timer?.cancel(); execution?.cancel() }

    /// Returns when accepted, independently of the timer/network/worker lifetime.
    @discardableResult
    public func request(immediately: Bool = false, ifNotRecent: Bool = false, full: Bool = false, expectedEpoch: UUID? = nil)
        -> Task<SynchronizationRequest?, any Error> {
        let previous = commands, store = store, now = clock()
        let task = Task { [weak self] in
            await previous?.value
            let request = try await store.requestSynchronization(immediately: immediately, ifNotRecent: ifNotRecent, full: full, now: now, expectedEpoch: expectedEpoch)
            self?.wake()
            return request
        }
        commands = Task { _ = try? await task.value }
        return task
    }

    /// Repeated resume is idempotent and can explicitly retry a retained local
    /// storage/presentation failure. Provider retries use their saved backoff.
    public func resume() {
        suspended = false; failed = nil
        if observation == nil {
            observation = Task { [weak self, store] in
                for await _ in await store.synchronizationChanges() {
                    guard !Task.isCancelled else { return }
                    self?.wake()
                }
            }
        }
        wake()
    }

    /// Adaptation: iOS suspends a backgrounded app within seconds, so Android's 20 s debounce
    /// (SynchronizationQueueImpl.java:62–73) would hold a pending pass until the app is opened again.
    /// While expedited (the app is in the background with granted time), a request that has not failed
    /// yet starts at once; provider retries keep their saved backoff. Leaving the background restores
    /// the source delay for later requests.
    public func setExpedited(_ value: Bool) {
        guard expedited != value else { return }
        expedited = value
        guard value, scheduled != nil, execution == nil else { return }
        cancelTimer()
        wake()
    }

    /// End an execution lease without erasing pending work. Resume waits for the
    /// old worker's cancellation cleanup before starting the saved successor.
    public func suspend() {
        suspended = true; generation = UUID()
        scan?.cancel(); scan = nil
        cancelTimer()
        execution?.cancel()
        publish(.suspended)
    }

    private func wake() {
        guard !suspended else { return }
        wakePending = true
        guard scan == nil else { return }
        let token = generation
        scan = Task { [weak self, store] in
            do {
                repeat {
                    self?.wakePending = false
                    let saved = try await store.synchronizationState()
                    try Task.checkCancellation()
                    guard let self, !suspended, generation == token else { return }
                    reconcile(saved)
                } while self?.wakePending == true
                if self?.generation == token { self?.scan = nil }
            } catch {
                guard let self, generation == token, !suspended else { return }
                scan = nil; cancelTimer()
                // Do not erase the saved request or create a storage-error loop.
                publish(.failed(message: String(describing: error)))
            }
        }
    }

    private func reconcile(_ saved: SynchronizationState) {
        if let executing, executing.epoch != saved.epoch { execution?.cancel() }
        guard let request = saved.request else {
            cancelTimer()
            if execution == nil { publish(.idle) }
            return
        }
        let ticket = Ticket(epoch: saved.epoch, request: request)
        guard failed != ticket else { return }
        if executing == ticket && execution?.isCancelled == false { return }
        if scheduled == ticket {
            if execution == nil { publish(.waiting(request)) }
            return
        }
        cancelTimer()
        scheduled = ticket
        let token = timerID, sleep = sleepUntil
        let deadline = expedited && request.attempts == 0 ? min(request.notBefore, clock()) : request.notBefore
        timer = Task { [weak self] in
            do {
                if request.announcesStart == true, request.attempts == 0, saved.accountID != nil,
                   self?.announcedRequest != request.id, let announce = self?.announceStarted {
                    try await announce(request, ticket.epoch)
                    try Task.checkCancellation()
                    guard self?.timerID == token, self?.suspended == false else { return }
                    self?.announcedRequest = request.id
                }
                try await sleep(deadline)
                try Task.checkCancellation()
                await self?.startWhenRetired(ticket, token: token)
            } catch {
                guard !Task.isCancelled, let self, timerID == token, !suspended else { return }
                failed = ticket; cancelTimer()
                publish(.failed(message: String(describing: error)))
            }
        }
        if execution == nil { publish(.waiting(request)) }
    }

    private func startWhenRetired(_ ticket: Ticket, token: UUID) async {
        do {
            guard timerID == token, !suspended else { return }
            if let previous = execution {
                previous.cancel()
                await previous.value
                try Task.checkCancellation()
            }
            let saved = try await store.synchronizationState()
            try Task.checkCancellation()
            guard timerID == token, !suspended, saved.epoch == ticket.epoch, saved.request == ticket.request else { wake(); return }
            timer = nil; scheduled = nil
            executionID = UUID()
            let runID = executionID, execute = execute
            executing = ticket
            execution = Task { [weak self] in
                let result: Result<SynchronizationWorker.Outcome, any Error>
                do {
                    var outcome: SynchronizationWorker.Outcome
                    while true {
                        try Task.checkCancellation()
                        do { outcome = try await execute(ticket.request); break }
                        catch is DownloadNetworkInterruption {
                            // Worker waits for the captured constraint on reentry.
                            try Task.checkCancellation()
                        }
                    }
                    result = .success(outcome)
                } catch { result = .failure(error) }
                self?.finished(result, ticket: ticket, token: runID)
            }
            publish(.running(ticket.request))
        } catch {
            guard !Task.isCancelled, timerID == token, !suspended else { return }
            failed = ticket; cancelTimer()
            publish(.failed(message: String(describing: error)))
        }
    }

    private func finished(_ result: Result<SynchronizationWorker.Outcome, any Error>, ticket: Ticket, token: UUID) {
        guard executionID == token else { return }
        execution = nil; executing = nil
        if !suspended, case .failure(let error) = result, !(error is CancellationError), !Task.isCancelled {
            failed = ticket
            publish(.failed(message: String(describing: error)))
        }
        wake()
    }

    private func cancelTimer() {
        timerID = UUID(); timer?.cancel(); timer = nil; scheduled = nil
    }
    private func publish(_ value: State) {
        guard state != value else { return }
        state = value; onChange?(value)
    }
}
