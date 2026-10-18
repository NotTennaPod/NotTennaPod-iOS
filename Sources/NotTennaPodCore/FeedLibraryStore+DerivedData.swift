import Foundation
import Synchronization

/// Whether a library's derived list keys and counts (schema 21) are complete. A library migrated with episodes is
/// filled in background batches after its graph starts; until then every consumer of derived data either waits here or
/// reads the canonical tables, and defers rather than acknowledging durable work on a partial table. Playback and the
/// shell never wait.
public final class DerivedReadiness: Sendable {
    private struct State: ~Copyable {
        var ready: Bool
        var closed = false
        var failure: String?
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    }
    private let state: Mutex<State>

    init(ready: Bool) { state = Mutex(State(ready: ready)) }

    public var isReady: Bool { state.withLock { $0.ready } }

    /// Why the last fill step failed, while the fill retries it (nil once a step succeeds). Waiters keep waiting: no
    /// consumer reads derived data or acknowledges durable work on it meanwhile.
    public var failure: String? { state.withLock { $0.failure } }

    func recordFailure(_ error: (any Error)?) { state.withLock { $0.failure = error.map { String(describing: $0) } } }

    /// Returns once the derived data is complete; throws `FeedLibraryError.closed` when the library closes first, and
    /// `CancellationError` when the waiting task is cancelled.
    public func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Void, any Error>? = state.withLock { state in
                    if state.ready { return .success(()) }
                    if state.closed { return .failure(FeedLibraryError.closed) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    state.waiters[id] = continuation
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }

    func markReady() {
        let waiters = state.withLock { state in
            state.ready = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }

    func close() {
        let waiters = state.withLock { state in
            state.closed = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume(throwing: FeedLibraryError.closed) }
    }
}

extension FeedLibraryStore {
    /// The derived keys and counts are complete (no fill pending).
    public nonisolated var derivedReady: Bool { derived.isReady }

    /// Returns once the derived keys and counts are complete (at once when they are).
    public nonisolated func waitForDerivedData() async throws { try await derived.wait() }

    /// Fills the derived keys and counts in short background steps (`LibrarySchema21.fillBatch`: at most `batch` episodes,
    /// about 25 ms of work each), each its own write transaction, letting every other store call run between them.
    /// Resumes where an earlier fill stopped; returns at once when there is nothing to fill. A failed step is reported to
    /// `onFailure` and in `derived.failure`, then retried after `retryDelay` (doubling up to a minute) until it succeeds;
    /// readiness waits for that. Ends when the store closes (`FeedLibraryError.closed`) or the task is cancelled.
    public nonisolated func fillDerivedData(batch: Int = 1_000, retryDelay: Duration = .seconds(1),
                                            onFailure: (@Sendable (any Error) -> Void)? = nil) async throws {
        var delay = retryDelay
        while true {
            do {
                while try await !fillDerivedBatch(batch) {
                    try Task.checkCancellation()
                    await Task.yield()
                }
                derived.recordFailure(nil)
                return
            } catch FeedLibraryError.closed {
                throw FeedLibraryError.closed
            } catch let error as CancellationError {
                throw error
            } catch {
                derived.recordFailure(error)
                onFailure?(error)
                try await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(60))
            }
        }
    }

    /// One fill step (`LibrarySchema21.fillBatch`). Returns whether the fill is complete.
    func fillDerivedBatch(_ batch: Int) throws -> Bool {
        guard !readOnly else { throw FeedLibraryError.invalidMutation }
        if derived.isReady { return true }
        let complete = try LibrarySchema21.fillBatch(database, batch: batch)
        derived.recordFailure(nil)
        if complete { derived.markReady() }
        return complete
    }

    /// The graph's screen readers (two read-only connections), opened at the first call.
    public func readers() throws -> LibraryReaders {
        if let openReaders { return openReaders }
        guard !readOnly, !readersClosed else { throw FeedLibraryError.closed }
        let readers = try LibraryReaders(url: databaseURL)
        openReaders = readers
        return readers
    }

    /// Interrupts and closes the readers. The graph's teardown runs it before the store closes, and so before any Keep,
    /// switch, import or restore moves the library's files: no reader connection is open then.
    public func closeReaders() async {
        readersClosed = true
        guard let readers = openReaders else { return }
        openReaders = nil
        readers.shutdown()
        await readers.close()
    }

    /// Tests: every write transaction of this store checks the derived data before it commits.
    func verifyDerivedDataOnCommit(_ on: Bool = true) { database.verifiesDerivedData = on }

    /// Tests: what differs between the derived data and the records (empty when exact).
    func derivedDiscrepancies() throws -> [String] { try LibrarySchema21.discrepancies(database) }

    /// Tests: the store's own connection (its TEMP objects and counters are per connection).
    func withDatabaseForTesting<T>(_ body: (LibrarySQLite) throws -> T) rethrows -> T { try body(database) }
}
