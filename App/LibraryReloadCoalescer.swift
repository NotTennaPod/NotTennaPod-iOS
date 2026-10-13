import Foundation

/// A refresh used to report each refreshed podcast by waiting until every library screen had reread
/// and redrawn the whole library, so with hundreds of podcasts and tens of thousands of episodes the refresh
/// advanced only as fast as those reloads (minutes). Android's `FeedUpdateWorker` posts its update event and
/// continues while the lists reload on their own. Here requests made while a reload runs merge into one
/// follow-up reload, which always starts after the request.
@MainActor final class LibraryReloadCoalescer {
    private let reload: @MainActor () async -> Void
    private var running: Task<Void, Never>?
    private var followUp = false
    private var completed = 0

    init(reload: @escaping @MainActor () async -> Void) { self.reload = reload }

    /// Schedules a reload that starts after this call and returns at once.
    func request() {
        if running != nil { followUp = true } else { start() }
    }

    /// Schedules a reload that starts after this call and waits until it has finished.
    func requestAndWait() async {
        let target = running == nil ? completed + 1 : completed + 2
        request()
        while completed < target, let task = running { await task.value }
    }

    private func start() {
        running = Task { [weak self] in
            guard let self else { return }
            await reload()
            completed += 1
            running = nil
            if followUp { followUp = false; start() }
        }
    }
}
