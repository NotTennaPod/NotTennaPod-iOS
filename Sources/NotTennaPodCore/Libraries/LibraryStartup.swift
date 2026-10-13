import Foundation
import Synchronization

/// The one owner of the library graph's start. iOS may launch the app before the first unlock after a restart
/// (a finished background download, a widget or Control Center button), when protected files and Keychain items
/// cannot be read yet. Such a start waits for the data instead of failing for the process's lifetime:
///
/// - Starts are serialised: launch, a retry and a restart after a library switch or import never build two graphs.
/// - A failed attempt is retired at once (no command reaches what it built) and discarded before the next attempt
///   begins; only a successful attempt is published.
/// - It is tried again when protected data becomes available or a scene becomes active, by repeating the failing
///   operation itself: protected data is never checked beforehand (files stay readable while the device is locked
///   after the first unlock). Once started, those events instead resume work that was parked because something it
///   needed could not be read.
/// - A start that failed while protected data was unavailable waits, with no error. A failure while it is available
///   is a normal error, tried again at the next activation, never an endless wait.
/// - Work that arrived while the start had not succeeded (a link, a shortcut, a notification, a widget button) runs
///   once, after a successful start; never on the error screen of a failed one. Widget and Control Center commands
///   run through one ordered dispatcher, before and after the start alike (`runCommand`).
@MainActor public final class LibraryStartup {
    public enum State: Equatable, Sendable {
        case notStarted
        /// An attempt is queued behind a failed attempt's discarding.
        case starting
        case started
        /// The last attempt failed while protected data was unavailable: nothing is shown but a wait.
        case waitingForUnlock
        /// The last attempt failed while protected data was available: its error is shown.
        case failed
    }

    public struct Hooks {
        /// Builds and publishes the graph; throws when it cannot (what it built so far is retired and discarded).
        public var build: @MainActor () throws -> Void
        /// Synchronously closes a failed attempt's command admission, before anything else runs.
        public var retire: @MainActor () -> Void
        /// Stops and releases what a failed attempt started; the next attempt begins after it returns.
        public var discard: @MainActor () async -> Void
        public var protectedDataAvailable: @MainActor () -> Bool
        /// After every attempt: the state it ended in, and the state that was shown before it.
        public var resolved: @MainActor (_ state: State, _ previous: State) -> Void
        /// Once started: protected data became available or a scene became active, so work parked because it could
        /// not read what it needed gets one new attempt.
        public var resumeParked: @MainActor () -> Void

        public init(build: @escaping @MainActor () throws -> Void, retire: @escaping @MainActor () -> Void,
                    discard: @escaping @MainActor () async -> Void, protectedDataAvailable: @escaping @MainActor () -> Bool,
                    resolved: @escaping @MainActor (_ state: State, _ previous: State) -> Void,
                    resumeParked: @escaping @MainActor () -> Void = {}) {
            self.build = build; self.retire = retire; self.discard = discard
            self.protectedDataAvailable = protectedDataAvailable; self.resolved = resolved; self.resumeParked = resumeParked
        }
    }

    /// A command admitted to run once the graph is started (a widget or Control Center button).
    private final class Command: Sendable {
        let deadline: ContinuousClock.Instant
        /// Set the moment its caller is cancelled, from any thread; checked right before the command runs.
        let cancelled = Mutex(false)
        /// The command while it runs, so its caller's cancellation reaches it.
        let running = Mutex<Task<Void, any Error>?>(nil)
        init(deadline: ContinuousClock.Instant) { self.deadline = deadline }
    }

    private struct Admitted {
        let command: Command
        let body: @MainActor () async throws -> Void
        let continuation: CheckedContinuation<Void, any Error>
        let expiry: Task<Void, Never>
    }

    public private(set) var state: State = .notStarted
    /// The error of the last failed attempt (waiting or failed); nil once started.
    public private(set) var failure: (any Error)?
    private let hooks: Hooks
    /// A failed attempt's discarding; the next attempt waits for it.
    private var discarding: Task<Void, Never>?
    /// The queued attempt, while one is.
    private var queued: Task<Void, Never>?
    /// The state shown while an attempt is queued.
    private var shown: State = .notStarted
    private var actions: [@MainActor () -> Void] = []
    /// Commands waiting to run, in admission order.
    private var admitted: [Admitted] = []
    private var dispatching = false

    public init(_ hooks: Hooks) { self.hooks = hooks }

    public var isStarted: Bool { state == .started }

    /// The state a screen shows: while an attempt is queued, the state before it.
    public var presented: State { state == .starting ? shown : state }

    /// Launch, and a restart once a switch, an import or a Keep stopped the graph: synchronous, unless a failed
    /// attempt is still being discarded; then the attempt follows as soon as that finished.
    public func start() {
        if discarding == nil, queued == nil { attempt(); return }
        queue()
    }

    /// A waiting or failed start is tried again. Triggers while an attempt is queued are covered by that attempt.
    public func retry() {
        guard state == .waitingForUnlock || state == .failed else { return }
        queue()
    }

    /// Protected data became available: a start that has not succeeded is tried again; once started, parked work gets
    /// one new attempt.
    public func protectedDataBecameAvailable() { accessMayHaveReturned() }

    /// A scene became active: as `protectedDataBecameAvailable`.
    public func sceneActivated() { accessMayHaveReturned() }

    private func accessMayHaveReturned() {
        if state == .started { hooks.resumeParked() } else { retry() }
    }

    /// Runs `action` once the graph is started: now if it is, otherwise once, right after the successful attempt (and
    /// its `resolved`). A failed attempt keeps it for the next success.
    public func whenStarted(_ action: @escaping @MainActor () -> Void) {
        if state == .started { action() } else { actions.append(action) }
    }

    /// Runs `body` once the graph is started, after every command admitted before it, one at a time. A command is
    /// admitted (its place in the order fixed) the moment this is called, whatever its task's priority, and goes through
    /// the same dispatcher before and after the start. Throws `SavedStateUnavailable` when `deadline` (a continuous
    /// clock: time asleep counts) passes before it runs, whether or not anything else happens, and `CancellationError`
    /// when its task is cancelled first: such a command never runs. A cancellation while it runs is forwarded to it.
    public func runCommand(before deadline: ContinuousClock.Instant, _ body: @escaping @MainActor () async throws -> Void) async throws {
        guard ContinuousClock.now < deadline else { throw SavedStateUnavailable() }
        let command = Command(deadline: deadline)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // One-shot, in-process: it holds no background time and wakes nothing; after a suspension it fires on
                // resumption, since the continuous clock counts the time asleep.
                let expiry = Task { [weak self] in
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    guard !Task.isCancelled else { return }
                    self?.withdraw(command, .failure(SavedStateUnavailable()))
                }
                admitted.append(Admitted(command: command, body: body, continuation: continuation, expiry: expiry))
                if command.cancelled.withLock({ $0 }) { withdraw(command, .failure(CancellationError())) }
                dispatch()
            }
        } onCancel: {
            command.cancelled.withLock { $0 = true }
            command.running.withLock { $0 }?.cancel()
            Task { @MainActor [weak self] in self?.withdraw(command, .failure(CancellationError())) }
        }
    }

    /// Commands admitted and not yet running (host tests).
    var admittedCommands: Int { admitted.count }

    /// Ends a command that is still waiting, once: a later expiry, cancellation or dispatch finds nothing.
    private func withdraw(_ command: Command, _ result: Result<Void, any Error>) {
        guard let index = admitted.firstIndex(where: { $0.command === command }) else { return }
        let entry = admitted.remove(at: index)
        entry.expiry.cancel()
        entry.continuation.resume(with: result)
    }

    /// The one ordered dispatcher: once started, runs the admitted commands one at a time in admission order, including
    /// those admitted while it runs.
    private func dispatch() {
        guard state == .started, !dispatching, !admitted.isEmpty else { return }
        dispatching = true
        Task { [weak self] in
            while let self, self.state == .started, !self.admitted.isEmpty {
                let entry = self.admitted.removeFirst()
                entry.expiry.cancel()
                let command = entry.command, body = entry.body
                // Checked right before it runs: a command cancelled or past its deadline never runs.
                let run = Task { @MainActor in
                    guard !command.cancelled.withLock({ $0 }) else { throw CancellationError() }
                    guard ContinuousClock.now <= command.deadline else { throw SavedStateUnavailable() }
                    try await body()
                }
                command.running.withLock { $0 = run }
                if command.cancelled.withLock({ $0 }) { run.cancel() }
                entry.continuation.resume(with: await run.result)
            }
            self?.dispatching = false
        }
    }

    /// One attempt, after the last failed attempt's discarding; repeated requests meanwhile share it.
    private func queue() {
        guard queued == nil else { return }
        shown = presented
        state = .starting
        queued = Task { [weak self] in
            if let discarding = self?.discarding { await discarding.value }
            guard let self else { return }
            self.discarding = nil
            self.queued = nil
            self.attempt()
        }
    }

    private func attempt() {
        let previous = presented
        do {
            try hooks.build()
            state = .started
            failure = nil
        } catch {
            hooks.retire()
            let discard = hooks.discard
            discarding = Task { await discard() }
            failure = error
            state = hooks.protectedDataAvailable() ? .failed : .waitingForUnlock
        }
        hooks.resolved(state, previous)
        guard state == .started else { return }
        let pending = actions
        actions = []
        for action in pending { action() }
        dispatch()
    }
}
