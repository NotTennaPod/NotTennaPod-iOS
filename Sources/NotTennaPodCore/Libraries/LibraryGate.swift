import Foundation
import Synchronization

/// The library gate (PROTOCOL §11.5). An export holds it shared while it collects its
/// source (the library's rows, its speeds and silence, the credentials its feeds name), so nothing it reads can change
/// or disappear meanwhile. Keep at logout, the removal of a library, the database import, the schema-20 migration of a
/// library that is not open, and the deletion of retired feed credentials from the Keychain hold it exclusively.
/// Writers go first: once one waits, new shared holders wait behind it, so a Keep is never starved by exports.
/// One gate per process; the encoding and writing of an export's document happen after it is released.
/// Work that background time may end (an export, the automatic backup, the database import) waits cancellably: a
/// cancelled wait holds nothing and lets whoever waited behind it in.
public final class LibraryGate: Sendable {
    public static let shared = LibraryGate()

    private struct Waiter {
        var id: UUID
        var exclusive: Bool
        /// True when the gate was granted, false when a cancellable wait was cancelled.
        var resume: @Sendable (Bool) -> Void
    }
    private struct State {
        var readers = 0
        var writer = false
        var waiting: [Waiter] = []
    }
    private let state = Mutex(State())

    public init() {}

    /// Waits for shared ownership; release it with `releaseShared()`.
    public func acquireShared() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let granted = state.withLock { state -> Bool in
                if !state.writer && !state.waiting.contains(where: \.exclusive) { state.readers += 1; return true }
                state.waiting.append(.init(id: UUID(), exclusive: false, resume: { _ in continuation.resume() }))
                return false
            }
            if granted { continuation.resume() }
        }
    }

    public func releaseShared() {
        let wake = state.withLock { state -> [Waiter] in
            state.readers = max(0, state.readers - 1)
            return Self.grant(&state)
        }
        for waiter in wake { waiter.resume(true) }
    }

    /// Waits for exclusive ownership; release it with `releaseExclusive()`.
    public func acquireExclusive() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let granted = state.withLock { state -> Bool in
                if !state.writer && state.readers == 0 && state.waiting.isEmpty { state.writer = true; return true }
                state.waiting.append(.init(id: UUID(), exclusive: true, resume: { _ in continuation.resume() }))
                return false
            }
            if granted { continuation.resume() }
        }
    }

    /// Shared ownership, or `CancellationError` when the task is cancelled before it is granted (nothing is held
    /// then). Cancellation is checked once more after the gate is granted.
    public func acquireSharedUnlessCancelled() async throws { try await acquireUnlessCancelled(exclusive: false) }

    /// Exclusive ownership, or `CancellationError` when the task is cancelled before it is granted (nothing is held
    /// then). Cancellation is checked once more after the gate is granted.
    public func acquireExclusiveUnlessCancelled() async throws { try await acquireUnlessCancelled(exclusive: true) }

    private func acquireUnlessCancelled(exclusive: Bool) async throws {
        let id = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let now = state.withLock { state -> Bool? in
                    if Task.isCancelled { return false }
                    if exclusive, !state.writer && state.readers == 0 && state.waiting.isEmpty { state.writer = true; return true }
                    if !exclusive, !state.writer && !state.waiting.contains(where: \.exclusive) { state.readers += 1; return true }
                    state.waiting.append(.init(id: id, exclusive: exclusive, resume: { continuation.resume(returning: $0) }))
                    return nil
                }
                if let now { continuation.resume(returning: now) }
            }
        } onCancel: {
            let (cancelled, wake) = state.withLock { state -> (Waiter?, [Waiter]) in
                guard let index = state.waiting.firstIndex(where: { $0.id == id }) else { return (nil, []) }
                let waiter = state.waiting.remove(at: index)
                // A writer that stops waiting lets the readers queued behind it in.
                return (waiter, Self.grant(&state))
            }
            cancelled?.resume(false)
            for waiter in wake { waiter.resume(true) }
        }
        guard granted else { throw CancellationError() }
        if Task.isCancelled {
            if exclusive { releaseExclusive() } else { releaseShared() }
            throw CancellationError()
        }
    }

    /// Exclusive ownership now, or false when anyone holds or waits for the gate (a graph start's migration of the
    /// libraries that are not open, which never waits).
    public func tryAcquireExclusive() -> Bool {
        state.withLock { state in
            guard !state.writer, state.readers == 0, state.waiting.isEmpty else { return false }
            state.writer = true
            return true
        }
    }

    public func releaseExclusive() {
        let wake = state.withLock { state -> [Waiter] in
            state.writer = false
            return Self.grant(&state)
        }
        for waiter in wake { waiter.resume(true) }
    }

    /// Whether anything holds the gate (tests).
    public var isHeld: Bool { state.withLock { $0.writer || $0.readers > 0 } }

    /// Whether anyone waits for the gate (tests).
    public var hasWaiters: Bool { state.withLock { !$0.waiting.isEmpty } }

    public func withShared<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquireShared()
        defer { releaseShared() }
        return try await body()
    }

    public func withExclusive<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquireExclusive()
        defer { releaseExclusive() }
        return try await body()
    }

    /// In arrival order: the first waiting writer alone once nobody holds the gate, or every reader before the first
    /// waiting writer.
    private static func grant(_ state: inout State) -> [Waiter] {
        guard !state.writer, let first = state.waiting.first else { return [] }
        if first.exclusive {
            guard state.readers == 0 else { return [] }
            state.waiting.removeFirst()
            state.writer = true
            return [first]
        }
        var granted: [Waiter] = []
        while let next = state.waiting.first, !next.exclusive {
            state.waiting.removeFirst()
            state.readers += 1
            granted.append(next)
        }
        return granted
    }
}
