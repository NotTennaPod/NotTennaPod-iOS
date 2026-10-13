import Foundation

/// Search state survives navigation into a result. Superseded reads cannot publish.
@MainActor public final class LibrarySearchSession {
    public private(set) var query = ""
    public private(set) var feedID: Int64?
    public let feedTitle: String
    /// SubscriptionFragment's Archive search (`FeedItemFilter(INCLUDE_ARCHIVED)`): archived feeds only,
    /// shown as a removable chip titled `feedTitle`.
    public private(set) var archived = false
    public private(set) var result = LibrarySearchResult()
    /// Changes only for accepted read results, including value-equal results.
    public private(set) var resultRevision: UInt64 = 0
    public private(set) var loading = false
    public var onChange: (() -> Void)?
    public var onFailure: ((any Error) -> Void)?
    private let read: @Sendable (String, Int64?, Bool) async throws -> LibrarySearchResult
    private let delay: @Sendable () async throws -> Void
    private var task: Task<Void, Never>?
    private var generation = 0
    private var lastChange: Date?
    private var acceptedQuery: String?
    public init(feedID: Int64?, feedTitle: String,
                delay: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(750)) },
                read: @escaping @Sendable (String, Int64?) async throws -> LibrarySearchResult) {
        self.feedID = feedID; self.feedTitle = feedTitle; self.delay = delay; self.read = { query, id, _ in try await read(query, id) }
    }
    public init(archivedTitle: String, delay: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(750)) },
                read: @escaping @Sendable (String, Int64?, Bool) async throws -> LibrarySearchResult) {
        feedTitle = archivedTitle; archived = true; self.delay = delay; self.read = read
    }
    public func change(_ query: String, at now: Date = .now) {
        self.query = query
        let immediate = query.isEmpty || query.hasSuffix(" ") || lastChange.map { now.timeIntervalSince($0) > 1.5 } == true
        lastChange = now; start(delayed: !immediate, progress: false)
    }
    public func submit() { start(delayed: false, progress: true) }
    /// The text a restored search shows before it searches: nothing is read until `submit`.
    public func restoreQuery(_ query: String) { self.query = query }
    public func clearScope() { feedID = nil; archived = false; submit() }
    public func refresh() { start(delayed: false, progress: false) }
    /// An empty query retains the last accepted list. Reconcile that actual
    /// list after a commit without changing the user's visible query text.
    public func reconcileCurrentData() {
        start(delayed: false, progress: false, retainedQuery: query.isEmpty ? acceptedQuery : nil)
    }
    public func cancel() { generation += 1; task?.cancel(); task = nil; loading = false }
    /// Reconcile an already committed action without replacing this result's
    /// models. A completion from an older result cannot patch its replacement.
    @discardableResult public func applyCommittedState(_ delta: EpisodeActionStateDelta,
        episodeID: Int64, expectedResultRevision: UInt64) -> Bool {
        guard resultRevision == expectedResultRevision,
              let index = result.episodes.firstIndex(where: { $0.episode.id == episodeID }) else { return false }
        let prior = result.episodes[index]
        var episode = prior.episode
        delta.apply(to: &episode)
        result.episodes[index] = .init(feedID: prior.feedID, episode: episode, deletionTarget: prior.deletionTarget)
        onChange?()
        return true
    }

    private func start(delayed: Bool, progress: Bool, retainedQuery: String? = nil) {
        cancel(); generation += 1
        let generation = generation, query = retainedQuery ?? query, feedID = feedID, archived = archived
        // SearchFragment clears the query while retaining the last completed list.
        if query.isEmpty { onChange?(); return }
        loading = progress; onChange?()
        task = Task { [weak self, read, delay] in
            do {
                if delayed { try await delay() }
                try Task.checkCancellation()
                let result = try await read(query, feedID, archived)
                try Task.checkCancellation()
                guard let self, self.generation == generation else { return }
                self.result = result; self.acceptedQuery = query; self.resultRevision &+= 1; self.loading = false
                if delayed { self.lastChange = nil }
                self.onChange?()
            } catch is CancellationError { }
            catch {
                guard let self, self.generation == generation else { return }
                self.loading = false; self.onChange?(); self.onFailure?(error)
            }
        }
    }
}
