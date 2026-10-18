import Foundation

/// A refresh used to report each refreshed podcast by waiting until every library screen had reread
/// and redrawn the whole library, so with hundreds of podcasts and tens of thousands of episodes the refresh
/// advanced only as fast as those reloads (minutes). Android's `FeedUpdateWorker` posts its update event and
/// continues while the lists reload on their own. Here requests made while a reload runs merge into one
/// follow-up reload, which always starts after the request.
///
/// A refresh of every podcast also redrew the lists once per podcast, back to back (a stutter while a person
/// scrolls). Reloads requested with `request()` start at most once per `interval` (from one start to the next):
/// the first at once, the rest merged into one that starts when the interval has passed. The refresh's final
/// report (`requestAndWait()`) does not wait for the interval, so the lists are current when the refresh ends.
@MainActor final class LibraryReloadCoalescer {
    private let reload: @MainActor () async -> Void
    private let interval: Duration
    private let clock = ContinuousClock()
    private var running: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var lastStart: ContinuousClock.Instant?
    private var pending = false
    private var urgent = false
    private var completed = 0

    init(interval: Duration = .seconds(1), reload: @escaping @MainActor () async -> Void) {
        self.interval = interval; self.reload = reload
    }

    /// Schedules a reload that starts after this call, at most one per interval, and returns at once.
    func request() {
        pending = true
        schedule()
    }

    /// Schedules a reload that starts after this call without waiting for the interval, and waits until it has finished.
    func requestAndWait() async {
        let target = running == nil ? completed + 1 : completed + 2
        pending = true; urgent = true
        schedule()
        while completed < target, let task = running { await task.value }
    }

    private func schedule() {
        guard pending, running == nil else { return }
        if !urgent, let lastStart {
            let wait = interval - lastStart.duration(to: clock.now)
            if wait > .zero {
                if timer == nil {
                    timer = Task { [weak self] in
                        do { try await Task.sleep(for: wait) } catch { return }
                        guard let self else { return }
                        timer = nil
                        schedule()
                    }
                }
                return
            }
        }
        timer?.cancel(); timer = nil
        pending = false; urgent = false
        lastStart = clock.now
        running = Task { [weak self] in
            guard let self else { return }
            await reload()
            completed += 1
            running = nil
            schedule()
        }
    }
}
