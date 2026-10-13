import Foundation

/// One serialized lifetime shared by refresh and queue triggers. Cleanup is a
/// required dependency: callers cannot silently omit its file/playback effects.
@MainActor public final class AutomaticDownloadCoordinator {
    public enum State: Equatable, Sendable {
        case idle, running, suspended
        case failed(message: String)
    }
    public private(set) var state: State = .idle
    public var onChange: ((State) -> Void)?
    public struct Environment: Sendable {
        public var connection: AutomaticDownloadPolicy.Connection
        public var allowMobile: Bool
        public var charging: Bool
        public init(connection: AutomaticDownloadPolicy.Connection, allowMobile: Bool, charging: Bool) {
            self.connection = connection; self.allowMobile = allowMobile; self.charging = charging
        }
    }
    private let store: FeedLibraryStore
    private let preferences: @MainActor () -> AutomaticDownloadPreferences
    private let environment: @MainActor () async throws -> Environment
    private let cleanup: @MainActor (LibraryEpisode) async throws -> Void
    private let download: @MainActor (Int64) async throws -> Void
    private let clock: @Sendable () -> Date
    private var tail: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var suspended = true
    private var wakePending = false

    public init(store: FeedLibraryStore, preferences: @escaping @MainActor () -> AutomaticDownloadPreferences,
                environment: @escaping @MainActor () async throws -> Environment,
                cleanup: @escaping @MainActor (LibraryEpisode) async throws -> Void,
                download: @escaping @MainActor (Int64) async throws -> Void,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.preferences = preferences; self.environment = environment
        self.cleanup = cleanup; self.download = download; self.clock = clock
    }

    deinit { observation?.cancel(); work?.cancel() }

    /// Recover saved requests and observe queue changes independently of screens.
    /// Repeated activation does not run a second worker or invent a fresh request.
    public func resume() {
        suspended = false
        if observation == nil {
            observation = Task { [weak self, store] in
                let requests = await store.automaticDownloadRequests()
                for await _ in requests {
                    guard !Task.isCancelled else { return }
                    self?.wake()
                }
            }
        }
        wake()
    }

    /// Used by an execution lease expiring. Pending work survives interruption.
    public func suspend() {
        suspended = true
        generation = UUID()
        work?.cancel(); work = nil
        publish(.suspended)
    }

    /// The refresh worker awaits only this durable acceptance boundary, just as
    /// FeedUpdateWorker submits the source Future without awaiting its execution.
    public func request(manualRequestID: UUID? = nil) async throws {
        try await store.requestAutomaticDownload(manualRequestID: manualRequestID)
        wake()
    }

    private func wake() {
        guard !suspended else { return }
        wakePending = true
        guard work == nil else { return }
        let token = generation
        work = Task { [weak self, store] in
            guard let self else { return }
            do {
                repeat {
                    wakePending = false
                    while let request = try await store.automaticDownloadRequest() {
                        try Task.checkCancellation()
                        do { try await run() }
                        catch {
                            try Task.checkCancellation()
                            // A separately accepted trigger remains eligible even
                            // if an earlier Future failed. Do not strand that newer
                            // request or automatically retry the same failed one.
                            if let newer = try await store.automaticDownloadRequest(), newer != request { continue }
                            throw error
                        }
                        try Task.checkCancellation()
                        // A newer queue/refresh trigger arriving during selection
                        // survives this acknowledgement and receives another pass.
                        try await store.finishAutomaticDownloadRequest(request)
                    }
                } while wakePending
                try Task.checkCancellation()
                guard generation == token else { return }
                work = nil
                publish(.idle)
            } catch {
                guard generation == token else { return }
                work = nil
                // Leave the request saved. Retry only on a new trigger/resume;
                // a storage or cleanup failure must not create a hot retry loop.
                publish(.failed(message: String(describing: error)))
            }
        }
        publish(.running)
    }

    private func publish(_ value: State) { state = value; onChange?(value) }

    public func run() async throws {
        let previous = tail
        let task = Task { await previous?.value; try Task.checkCancellation(); try await self.execute() }
        tail = Task { _ = try? await task.value }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func execute() async throws {
        let environment = try await environment(), preferences = preferences()
        try Task.checkCancellation()
        guard AutomaticDownloadPolicy.permitted(connection: environment.connection, allowMobile: environment.allowMobile,
            charging: environment.charging, preferences: preferences) else { return }
        if !preferences.queue, preferences.cleanup == -2 || preferences.cacheSize == -1 {
            // Nothing can be selected (no feed downloads automatically, the queue is not included)
            // and nothing can be cleaned: the pass would end with no effect (the defaults).
            let feeds = try await store.feeds()
            try Task.checkCancellation()
            if !feeds.contains(where: { $0.subscriptionState == .subscribed
                && ($0.autoDownload == .enabled || ($0.autoDownload == .global && preferences.global)) }) { return }
        }
        let snapshot = try await store.snapshot()
        // A server library's pending releases stand in for NEW episodes (PROTOCOL §9.9); nil in a standalone library.
        let releases = try await store.serverReleaseCandidates()
        try Task.checkCancellation()
        // Walking the whole library happens off the main thread (queue changes trigger this pass).
        let now = clock()
        let (candidates, downloaded, reclaimable) = await Task.detached(priority: .utility) {
            let candidates = AutomaticDownloadPolicy.candidates(feeds: snapshot.feeds, queue: snapshot.queue, preferences: preferences,
                                                                releases: releases)
            let downloaded = snapshot.feeds.lazy.filter { $0.subscriptionState == .subscribed }
                .reduce(0) { $0 + $1.episodes.count { $0.details.media != nil && $0.userState.isDownloaded } }
            let reclaimable = AutomaticDownloadPolicy.cleanupCandidates(feeds: snapshot.feeds,
                queuedIDs: Set(snapshot.queue.map(\.id)), policy: preferences.cleanup, now: now)
            return (candidates, downloaded, reclaimable)
        }.value
        try Task.checkCancellation()
        let active = try await store.downloadJobs().count
        let room = AutomaticDownloadPolicy.cleanupCount(downloaded: downloaded, candidates: candidates.count, cacheSize: preferences.cacheSize)
        var deleted = 0
        for episode in reclaimable.prefix(room) {
            try Task.checkCancellation()
            try await cleanup(episode)
            // Count completed removal, not attempted deletion. A failed cleanup
            // must not create imaginary cache space for subsequent downloads.
            let current = try await store.episode(id: episode.id)
            if current == nil || current?.userState.isDownloaded == false { deleted += 1 }
        }
        let count = AutomaticDownloadPolicy.downloadCount(candidates: candidates.count, downloaded: downloaded,
            active: active, deleted: deleted, cacheSize: preferences.cacheSize)
        var requested = Set<Int64>()
        for episode in candidates.prefix(count) {
            try Task.checkCancellation()
            try await download(episode.id)
            requested.insert(episode.id)
        }
        // A release is done once its download is requested or nothing will download it; a blocked one stays pending.
        if let releases {
            try await store.finishServerReleases(requested.intersection(releases)
                .union(AutomaticDownloadPolicy.settledReleases(feeds: snapshot.feeds, releases: releases)))
        }
    }
}
