import Foundation

/// Source worker retries a restricted remote refresh even if WorkManager's
/// UNMETERED constraint admitted an unmetered cellular connection.
public struct PeriodicFeedRefreshNetworkBlocked: Error, Sendable { public init() {} }

/// Application-owned effects are explicit requirements, not silently empty defaults.
/// The recipient must retain request ownership across any suspension before publishing
/// a notification or starting another job. These events are not UI presentation code.
public protocol FeedRefreshEffects: Sendable {
    func handle(_ event: FeedRefreshWorker.Event, request: FeedRefreshRequest) async throws
}

/// Executes a persisted manual or periodic request. Each lifetime owner serializes starts,
/// cancel replaced work, retry a network interruption and recover the journal at launch.
/// This worker does not itself schedule OS background execution.
public struct FeedRefreshWorker: Sendable {
    public enum Event: Equatable, Sendable {
        case prepareNotifications
        case remaining([LibraryFeed])
        case refreshed(LibraryFeed)
        case cleanUnsubscribedFeeds
        case autoDownload
        case dismissProgress
        case synchronize
    }

    enum Outcome: Sendable {
        case updated(LibraryFeed), unchanged, failed, superseded
    }
    typealias Refresh = @Sendable (LibraryFeed, FeedRefreshRequest) async throws -> Outcome
    private let store: FeedLibraryStore
    private let network: DownloadNetworkMonitor
    private let effects: any FeedRefreshEffects
    private let refresh: Refresh
    private let clock: @Sendable () -> Date
    private let shuffle: @Sendable ([LibraryFeed]) -> [LibraryFeed]

    public init(store: FeedLibraryStore, remote: FeedRefreshService, local: LocalFeedRefreshService,
                localDescription: String, localAuthor: String,
                network: DownloadNetworkMonitor = .shared,
                credentials: @escaping @Sendable (Int64) async throws -> FeedCredentials?,
                options: @escaping @Sendable (Int64) async throws -> FeedRefreshOptions,
                effects: any FeedRefreshEffects) {
        self.init(store: store, network: network, effects: effects) { feed, request in
            let settings = try await options(feed.id)
            if feed.source.isLocalFeedSource {
                switch try await local.refresh(feedID: feed.id, description: localDescription, author: localAuthor,
                                               options: settings, manualRequestID: request.id) {
                case .updated(let result): return .updated(result.feed)
                case .failed: return .failed
                case .superseded: return .superseded
                }
            }
            let login = try await credentials(feed.id)
            switch try await remote.refresh(feedID: feed.id, force: request.force, nextPage: request.nextPage,
                                            credentials: login, options: settings, manualRequestID: request.id) {
            case .updated(let result): return .updated(result.feed)
            case .unchanged: return .unchanged
            case .failed: return .failed
            }
        }
    }

    init(store: FeedLibraryStore, network: DownloadNetworkMonitor, effects: any FeedRefreshEffects,
         clock: @escaping @Sendable () -> Date = { Date() },
         shuffle: @escaping @Sendable ([LibraryFeed]) -> [LibraryFeed] = { $0.shuffled() },
         refresh: @escaping Refresh) {
        self.store = store; self.network = network; self.effects = effects
        self.clock = clock; self.shuffle = shuffle; self.refresh = refresh
    }

    /// Interrupted, cancelled, replaced or failed-storage work is never acknowledged.
    /// The persisted request survives for its owner to resume or explicitly cancel.
    public func run(_ request: FeedRefreshRequest) async throws {
        try await requireCurrent(request)
        if request.requiresNetwork {
            try await network.waitUntilPermitted(request.networkConstraint)
            try await network.perform(under: request.networkConstraint) { try await execute(request) }
        } else {
            try await execute(request)
        }
        try await requireCurrent(request)
        guard try await store.finishRefresh(id: request.id, now: clock()) else { throw CancellationError() }
    }

    private func requireCurrent(_ request: FeedRefreshRequest) async throws {
        try Task.checkCancellation()
        guard try await store.refreshRequest(id: request.id) != nil else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func emit(_ event: Event, _ request: FeedRefreshRequest) async throws {
        try await requireCurrent(request)
        try await effects.handle(event, request: request)
        try await requireCurrent(request)
    }

    private func execute(_ request: FeedRefreshRequest) async throws {
        try await emit(.prepareNotifications, request)
        // Headers only: choosing the feeds decodes no episode (each refresh reads what it needs of its own feed).
        var feeds = request.eligibleFeeds(from: try await store.feedHeaders(), now: clock())
        if request.periodic?.allowMobile == false,
           feeds.contains(where: { !$0.source.isLocalFeedSource }),
           try await network.observedState().restricted {
            throw PeriodicFeedRefreshNetworkBlocked()
        }
        // Original worker returns early for a deleted selected feed, but an empty
        // all-feeds request still performs cleanup/auto-download/synchronization.
        if request.feedID != nil && feeds.isEmpty { return }
        if request.feedID == nil { feeds = shuffle(feeds) }
        try await emit(.remaining(feeds), request)
        try await withThrowingTaskGroup(of: (Int64, Outcome).self) { group in
            var pending = feeds.makeIterator()
            var remaining = feeds
            func start(_ feed: LibraryFeed) {
                group.addTask {
                    try await requireCurrent(request)
                    let outcome = try await refresh(feed, request)
                    try await requireCurrent(request)
                    return (feed.id, outcome)
                }
            }
            for _ in 0..<4 { if let feed = pending.next() { start(feed) } }
            while let (id, outcome) = try await group.next() {
                try await requireCurrent(request)
                if case .updated(let feed) = outcome { try await emit(.refreshed(feed), request) }
                remaining.removeAll { $0.id == id }
                if !remaining.isEmpty { try await emit(.remaining(remaining), request) }
                if let feed = pending.next() { start(feed) }
            }
        }
        try await emit(.cleanUnsubscribedFeeds, request)
        try await emit(.autoDownload, request)
        try await emit(.dismissProgress, request)
        try await emit(.synchronize, request)
    }
}
