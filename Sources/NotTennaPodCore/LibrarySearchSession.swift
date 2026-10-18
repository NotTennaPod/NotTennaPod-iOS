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
    /// The screens' library a search over it keeps its matches against (set by the screen).
    public var library: (() -> LibraryScreenMirror?)?
    /// Of some episodes, those whose text matches the words, read in SQLite (set by the screen when its library holds list
    /// projections, `LibraryDetailReader.episodes(_:matching:)`).
    public var textMatches: ((Set<Int64>, [String]) throws -> Set<Int64>?)?
    /// A read is running (or waiting for its delay): library changes are kept for its result.
    private var reading = false
    private var pendingEpisodes: Set<Int64> = [], pendingResetFeeds: Set<Int64> = [], pendingFeeds: Set<Int64> = []
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
    public func cancel() { generation += 1; task?.cancel(); task = nil; loading = false; reading = false; clearPending() }

    private func clearPending() { pendingEpisodes = []; pendingResetFeeds = []; pendingFeeds = [] }

    /// A library change while the result shows: only the episodes and podcasts it changed are matched again and the shown
    /// result is patched (never a new scan, also for a large catch-up). While a read runs the change is kept, and applied
    /// to its result when it arrives (that result was read from the library before the change). Returns the result shown
    /// before (without its matches, so they change in place, never as a copy of every match) and whether the shown result
    /// changed; the screen patches its rows from one to the other.
    @discardableResult
    public func patch(_ delta: LibraryMirrorDelta, mirror: LibraryScreenMirror) -> (previous: LibrarySearchResult, changed: Bool) {
        var previous = result
        previous.matches = nil
        if reading {
            pendingEpisodes.formUnion(delta.textChanged); pendingResetFeeds.formUnion(delta.feedStates)
            pendingFeeds.formUnion(delta.headers)
            return (previous, false)
        }
        guard var matches = result.matches else { return (previous, false) }
        // Taken out first, so the kept matches change in place rather than as a copy.
        result.matches = nil
#if DEBUG
        if otherScreenFaults.contains(.searchPreviousKeepsMatches) { previous.matches = matches }
#endif
        matches.apply(delta, mirror: mirror, text: textMatches)
        let next = matches.result(mirror: mirror)
        let changed = next != previous
        result = next
        return (previous, changed)
    }
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
        loading = progress; reading = true; onChange?()
        task = Task { [weak self, read, delay] in
            do {
                if delayed { try await delay() }
                try Task.checkCancellation()
                var result = try await read(query, feedID, archived)
                try Task.checkCancellation()
                guard let self, self.generation == generation else { return }
                // Matches read from the library before a change are brought up to the library now.
                if var matches = result.matches, let mirror = library?() {
                    result.matches = nil
                    matches.apply(episodes: pendingEpisodes, resetFeeds: pendingResetFeeds, feeds: pendingFeeds, mirror: mirror, text: textMatches)
                    result = matches.result(mirror: mirror)
                }
                reading = false; clearPending()
                self.result = result; self.acceptedQuery = query; self.resultRevision &+= 1; self.loading = false
                if delayed { self.lastChange = nil }
                self.onChange?()
            } catch is CancellationError { }
            catch {
                guard let self, self.generation == generation else { return }
                self.reading = false; self.clearPending()
                self.loading = false; self.onChange?(); self.onFailure?(error)
            }
        }
    }
}
