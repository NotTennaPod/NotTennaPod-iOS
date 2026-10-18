import Foundation

/// Reads a screen's data again after changes, at most once per `interval` while the screen is shown and never while it is
/// hidden, with one final read after the last change (the Download Log while downloads and refreshes run).
@MainActor public final class PacedRefresh {
    public var isActive: () -> Bool = { true }
    public private(set) var reads = 0
    private let interval: Duration
    private let read: () async -> Void
    private let sleep: @Sendable (Duration) async throws -> Void
    private var pending = false
    private var running: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var last: ContinuousClock.Instant?

    public init(interval: Duration = .seconds(1), sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                read: @escaping () async -> Void) {
        self.interval = interval; self.sleep = sleep; self.read = read
    }

    isolated deinit { running?.cancel(); timer?.cancel() }

    /// The data changed.
    public func changed() {
        pending = true
        schedule()
    }

    /// The screen is shown again: what changed meanwhile is read once.
    public func activate() { schedule() }

    public func stop() { pending = false; running?.cancel(); timer?.cancel(); running = nil; timer = nil }

    private func schedule() {
        guard pending, running == nil, timer == nil, isActive() else { return }
        if let last {
            let wait = interval - last.duration(to: .now)
            if wait > .zero {
                let sleep = sleep
                timer = Task { [weak self] in
                    do { try await sleep(wait) } catch { return }
                    self?.timer = nil
                    self?.schedule()
                }
                return
            }
        }
        pending = false
        reads += 1
        let read = read
        running = Task { [weak self] in
            await read()
            guard let self, !Task.isCancelled else { return }
            last = .now
            running = nil
            schedule()
        }
    }
}
