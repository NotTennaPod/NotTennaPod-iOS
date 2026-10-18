import Foundation
import Synchronization

/// Where a committed library transaction came from: this device's own actions (playback, downloads, swipe actions,
/// refreshes) or synchronization (an applied unit, staging, a publication, a recovery step). Decided by the task that
/// runs the transaction: the sync engine runs its work under `.sync`.
public enum LibraryChangeOrigin: String, Sendable, Equatable {
    case local, sync

    /// The origin of the transactions the current task commits.
    @TaskLocal static var current: LibraryChangeOrigin = .local
}

/// The exact difference one committed write transaction made to what the screens show (the visible model): its feeds,
/// episodes, the visible queue order, statistics inputs, active downloads, swipe-Undo guards and local folder links.
/// Captured at `LibrarySQLite.transaction`, the one boundary every write uses, as the net difference between the
/// visible model before and after the transaction; a rolled-back or net-zero transaction has none.
///
/// A feed that enters or leaves the visible model (`feeds[f]` is `.added` or `.removed`: subscribed, revealed after
/// staging, hidden for removal, deleted) carries its episodes and their statistics, downloads, Undo guards and folder
/// link with it: those are not listed again. Everything else is listed key by key.
public struct LibraryChangeSet: Sendable, Equatable {
    public enum Change: String, Sendable, Equatable { case added, removed, changed }

    public struct EpisodeChange: Sendable, Equatable {
        public var change: Change
        /// The feed the episode belongs to after the transaction (before it, for a removal).
        public var feed: Int64?
        /// The feed it belonged to before, when it moved to another one.
        public var formerFeed: Int64?

        public init(change: Change, feed: Int64?, formerFeed: Int64? = nil) {
            self.change = change; self.feed = feed; self.formerFeed = formerFeed
        }
    }

    /// The visible queue order's difference: members added and removed, and `relinked`, the members present before and
    /// after whose visible predecessor changed. [1,2,3,4] → [1,3,2,4] relinks {2,3,4}; removing B from [A,B,C] relinks C;
    /// an append relinks nothing.
    public struct QueueChange: Sendable, Equatable {
        public var added: Set<Int64> = []
        public var removed: Set<Int64> = []
        public var relinked: Set<Int64> = []
        public init(added: Set<Int64> = [], removed: Set<Int64> = [], relinked: Set<Int64> = []) {
            self.added = added; self.removed = removed; self.relinked = relinked
        }
        public var isEmpty: Bool { added.isEmpty && removed.isEmpty && relinked.isEmpty }
    }

    /// The library and the store's opening the set belongs to (a library switch or reopening is a new identity).
    public var identity: LibraryChangeHub.Identity
    /// The commit's place in the library's order of visible changes: increases by one per non-empty committed set.
    public var sequence: Int64
    public var origin: LibraryChangeOrigin
    public var feeds: [Int64: Change] = [:]
    public var episodes: [Int64: EpisodeChange] = [:]
    public var queue: QueueChange?
    /// Episodes whose statistics inputs changed: their statistics units, or a field statistics read (played state and
    /// time, last played, history, position started, download date, publication date, media duration and size).
    public var statistics: [Int64: EpisodeChange] = [:]
    /// Episodes whose active download jobs changed.
    public var downloads: [Int64: EpisodeChange] = [:]
    /// Episodes whose swipe-Undo guard changed.
    public var undo: [Int64: EpisodeChange] = [:]
    /// Feeds whose local folder link changed.
    public var localFolders: [Int64: Change] = [:]

    public init(identity: LibraryChangeHub.Identity, sequence: Int64, origin: LibraryChangeOrigin) {
        self.identity = identity; self.sequence = sequence; self.origin = origin
    }

    public var isEmpty: Bool {
        feeds.isEmpty && episodes.isEmpty && (queue?.isEmpty ?? true) && statistics.isEmpty && downloads.isEmpty
            && undo.isEmpty && localFolders.isEmpty
    }

    /// The keys the set names, for counting and tests: each relation's keys.
    public var keyCount: Int {
        feeds.count + episodes.count + statistics.count + downloads.count + undo.count + localFolders.count
            + (queue.map { $0.added.count + $0.removed.count + $0.relinked.count } ?? 0)
    }

    /// The union of two sets in commit order, for a consumer that only invalidates (the sync scheduler's window): every
    /// key either names, a key in both marked `.changed` unless both agree. The later sequence and identity stand.
    public func union(_ later: LibraryChangeSet) -> LibraryChangeSet {
        var result = later
        func merge<K>(_ a: [K: Change], _ b: [K: Change]) -> [K: Change] {
            a.merging(b) { $0 == $1 ? $0 : .changed }
        }
        func mergeEpisodes(_ a: [Int64: EpisodeChange], _ b: [Int64: EpisodeChange]) -> [Int64: EpisodeChange] {
            a.merging(b) { first, second in
                EpisodeChange(change: first.change == second.change ? second.change : .changed, feed: second.feed,
                              formerFeed: second.formerFeed ?? first.formerFeed ?? (first.feed != second.feed ? first.feed : nil))
            }
        }
        result.feeds = merge(feeds, later.feeds)
        result.localFolders = merge(localFolders, later.localFolders)
        result.episodes = mergeEpisodes(episodes, later.episodes)
        result.statistics = mergeEpisodes(statistics, later.statistics)
        result.downloads = mergeEpisodes(downloads, later.downloads)
        result.undo = mergeEpisodes(undo, later.undo)
        switch (queue, later.queue) {
        case (nil, let b): result.queue = b
        case (let a, nil): result.queue = a
        case (let a?, let b?):
            result.queue = QueueChange(added: a.added.union(b.added), removed: a.removed.union(b.removed),
                                       relinked: a.relinked.union(b.relinked))
        }
        return result
    }
}

/// Episodes whose remote position or claim knowledge changed: records, overlays, sessions, pins, holds or the
/// recovery state. A recheck hint, deliberately a superset; `all` asks to recheck the player's episode whatever it is.
public struct LibraryPositionKnowledge: Sendable, Equatable {
    public var episodes: Set<Int64> = []
    public var all = false
    public init(episodes: Set<Int64> = [], all: Bool = false) { self.episodes = episodes; self.all = all }
    public var isEmpty: Bool { episodes.isEmpty && !all }
    public func union(_ other: LibraryPositionKnowledge) -> LibraryPositionKnowledge {
        .init(episodes: episodes.union(other.episodes), all: all || other.all)
    }
    public func concerns(_ episode: Int64?) -> Bool { all || episode.map(episodes.contains) == true }
}

/// What one committed write transaction changed: its visible set (nil when it changed nothing visible) and the position
/// knowledge it touched.
struct LibraryCommit: Sendable {
    var set: LibraryChangeSet?
    var knowledge: LibraryPositionKnowledge?
    var origin: LibraryChangeOrigin
}

/// The one place every committed visible change of a library is delivered, whatever its origin (local actions, sync units,
/// staging, shown-ahead batches, publications, recovery steps). A subscriber gets, atomically, the library's identity, the
/// last sequence emitted (`baseline`) and a stream of every later set in commit order. A set is emitted synchronously
/// after its COMMIT, before the store method that wrote it returns: `emitted` read right after an awaited write is a
/// receipt at least that write's sequence.
public final class LibraryChangeHub: Sendable {
    public struct Identity: Sendable, Hashable {
        /// The library's identity (`library_identity`), when it has one.
        public let library: String?
        /// This opening of the store.
        public let incarnation: UUID
    }

    public struct Subscription: Sendable {
        public let identity: Identity
        public let baseline: Int64
        public let changes: AsyncStream<LibraryChangeSet>
    }

    private struct State {
        var emitted: Int64
        var subscribers: [UUID: AsyncStream<LibraryChangeSet>.Continuation] = [:]
        /// The store closed: no set follows, and a subscription made now finishes at once.
        var finished = false
    }

    public let identity: Identity
    private let state: Mutex<State>

    init(identity: Identity, baseline: Int64) {
        self.identity = identity
        state = Mutex(State(emitted: baseline))
    }

    /// The last sequence emitted.
    public var emitted: Int64 { state.withLock { $0.emitted } }

    public func subscribe() -> Subscription {
        let id = UUID()
        let (stream, continuation) = AsyncStream<LibraryChangeSet>.makeStream(bufferingPolicy: .unbounded)
        let (baseline, open) = state.withLock { state in
            if !state.finished || faults.contains(.noTerminalFlag) { state.subscribers[id] = continuation }
            return (state.emitted, !state.finished || faults.contains(.noTerminalFlag))
        }
        if open {
            continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) } }
        } else {
            continuation.finish()
        }
        return Subscription(identity: identity, baseline: baseline, changes: stream)
    }

    func emit(_ set: LibraryChangeSet) {
        state.withLock { state in
            state.emitted = max(state.emitted, set.sequence)
            guard !faults.contains(.dropDelivery) else { return }
            for continuation in state.subscribers.values { continuation.yield(set) }
        }
    }

    func finish() {
        let subscribers = state.withLock { state in
            state.finished = true
            defer { state.subscribers = [:] }
            return Array(state.subscribers.values)
        }
        for continuation in subscribers { continuation.finish() }
    }

    /// Test-only faults (mutation checks): delivery dropped while the sequence still moves on; no terminal state kept.
    enum Fault: Hashable, Sendable { case dropDelivery, noTerminalFlag }
    private let faultState = Mutex<Set<Fault>>([])
    private var faults: Set<Fault> { faultState.withLock { $0 } }
    func setFaultsForTesting(_ faults: Set<Fault>) { faultState.withLock { $0 = faults } }
}

/// Sync-origin commits not yet taken by the sync engine: it publishes them after each step it runs.
final class LibrarySyncChanges: Sendable {
    private let state = Mutex<(set: LibraryChangeSet?, knowledge: LibraryPositionKnowledge?)>((nil, nil))

    func add(_ commit: LibraryCommit) {
        state.withLock { state in
            if let set = commit.set { state.set = state.set.map { $0.union(set) } ?? set }
            if let knowledge = commit.knowledge { state.knowledge = state.knowledge.map { $0.union(knowledge) } ?? knowledge }
        }
    }

    /// Whether anything committed waits to be taken (tests: nothing is left untold at a request).
    var isEmpty: Bool { state.withLock { $0.set == nil && $0.knowledge == nil } }

    func take() -> (set: LibraryChangeSet?, knowledge: LibraryPositionKnowledge?) {
        state.withLock { state in
            defer { state = (nil, nil) }
            return state
        }
    }
}
