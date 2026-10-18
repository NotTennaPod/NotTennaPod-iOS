import Foundation

#if DEBUG
/// Test-only mutations of the list model (`LibraryScreenMutationTests`): each must be caught by its witness.
enum ScreenModelFault: Hashable, Sendable {
    /// `tieByEpisodeOnly`: Episodes ties by episode ID alone. `nullsLast`: NULL sorts last ascending. `removeByNewKey`: a
    /// removal is looked up by the new key. `equalKeyAfter`: an equal key goes on the wrong side of its ID tie.
    /// `countsNotKept`: the per-feed counts are not kept. `feedResetIgnored`: a podcast that entered or left the lists (a
    /// held removal, a reveal) is patched as a header change only.
    case tieByEpisodeOnly, nullsLast, removeByNewKey, equalKeyAfter, countsNotKept, feedResetIgnored
}
nonisolated(unsafe) var screenModelFaults: Set<ScreenModelFault> = []
#endif

/// One of the episode lists a screen shows, with what decides its membership and order: Inbox, Episodes (with its
/// filter), Favorites, Playback history and a podcast's own list. Queue and Downloads are the person's own collections and
/// are recomputed from them instead.
public enum EpisodeListSpec: Equatable, Sendable {
    case inbox(EpisodeListSort)
    case episodes(AllEpisodesFilter, EpisodeListSort)
    case favorites(EpisodeListSort)
    case history
    /// A podcast's list: its filter, and its order with the global default already applied.
    case feed(Int64, FeedEpisodeFilter, FeedEpisodeSortOrder)

    /// A podcast's list as its page shows it (`LibraryFeed.filteredDisplayEpisodes`).
    public static func feed(_ feed: LibraryFeed, globalSort: FeedEpisodeSortOrder) -> Self {
        let order = feed.episodeSortOrderCode.flatMap(FeedEpisodeSortOrder.init(rawValue:)) ?? .global
        let resolved = order == .global ? (globalSort == .global ? .dateNewest : globalSort) : order
        return .feed(feed.id, feed.episodeFilter, resolved)
    }

    /// Whether membership depends on the queue (a queued or not-queued filter).
    public var dependsOnQueue: Bool {
        switch self {
        case .episodes(let filter, _): Set(filter.effective.values).contains { $0 == "queued" || $0 == "not_queued" }
        case .feed(_, let filter, _): Set(filter.values).contains { $0 == "queued" || $0 == "not_queued" }
        default: false
        }
    }

    /// Whether membership depends on the podcast's subscription state.
    public var dependsOnFeedState: Bool {
        switch self {
        case .inbox, .episodes: true
        case .favorites, .history, .feed: false
        }
    }

    /// The membership rule of the list (the one its full read applies), for one episode of `feed`.
    public func includes(feed: LibraryFeed, episode: LibraryEpisode, queued: Bool) -> Bool {
        switch self {
        case .inbox: feed.subscriptionState == .subscribed && episode.userState.playState == .new
        case .episodes(let filter, _): filter.includes(episode, subscription: feed.subscriptionState, queued: queued)
        case .favorites: episode.userState.isFavorite
        case .history: (episode.userState.lastPlayedHistoryMilliseconds ?? 0) > 0 && episode.details.media != nil
        case .feed(let id, let filter, _): feed.id == id && filter.includes(episode, queued: queued)
        }
    }

    /// The member's place in the order.
    public func member(feedID: Int64, episode: LibraryEpisode) -> EpisodeListMember {
        let key: EpisodeListMember.Key
        switch self {
        case .inbox(let sort), .episodes(_, let sort), .favorites(let sort):
            switch sort.row {
            case .date: key = .integer(episode.details.publicationDate.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) })
            case .duration: key = .integer((episode.details.media?.durationMilliseconds).map(Int64.init))
            }
        case .history: key = .integer(episode.userState.lastPlayedHistoryMilliseconds ?? 0)
        case .feed(_, _, let order):
            switch order.field {
            case .title: key = .text(episode.details.title)
            case .filename: key = .text(episode.details.link)
            case .duration: key = .integer((episode.details.media?.durationMilliseconds).map(Int64.init))
            case .size: key = .integer(episode.details.media?.size)
            case .date: key = .real(episode.details.publicationDate?.timeIntervalSinceReferenceDate)
            case .global: key = .integer(nil)
            }
        }
        return EpisodeListMember(id: episode.id, feedID: feedID, key: key)
    }

    /// The list's strict total order (the order its full read sorts by, ties included).
    public func precedes(_ a: EpisodeListMember, _ b: EpisodeListMember) -> Bool {
        switch self {
        case .inbox(let sort), .favorites(let sort):
#if DEBUG
            if screenModelFaults.contains(.equalKeyAfter), Self.column(a, b, ascending: sort.ascending) == nil { return a.id > b.id }
#endif
            return Self.column(a, b, ascending: sort.ascending) ?? (a.id < b.id)
        case .episodes(let filter, let sort):
            if let order = Self.column(a, b, ascending: sort.ascending) { return order }
            var byEpisode = !Set(filter.effective.values).isDisjoint(with: ["played", "queued", "is_favorite"])
#if DEBUG
            if screenModelFaults.contains(.tieByEpisodeOnly) { byEpisode = true }
#endif
            if byEpisode || a.feedID == b.feedID { return a.id < b.id }
            return a.feedID < b.feedID
        case .history:
            guard case .integer(let left?) = a.key, case .integer(let right?) = b.key else { return a.id < b.id }
            return left == right ? a.id < b.id : left > right
        case .feed(_, _, let order):
            let comparison = Self.compare(a.key, b.key)
            if comparison == 0 { return a.id < b.id }
            return order.ascending ? comparison < 0 : comparison > 0
        }
    }

    /// `EpisodeListQueries.sorted`: nil when the keys are equal; NULL first ascending, last descending.
    private static func column(_ a: EpisodeListMember, _ b: EpisodeListMember, ascending: Bool) -> Bool? {
        guard case .integer(let left) = a.key, case .integer(let right) = b.key else { return nil }
        if left == right { return nil }
#if DEBUG
        if screenModelFaults.contains(.nullsLast) {
            guard let left else { return !ascending }
            guard let right else { return ascending }
            return ascending ? left < right : left > right
        }
#endif
        guard let left else { return ascending }
        guard let right else { return !ascending }
        return ascending ? left < right : left > right
    }

    /// `FeedEpisodeSortOrder.sorted`'s three-way comparison: NULL first, text by its UTF-8 bytes.
    private static func compare(_ a: EpisodeListMember.Key, _ b: EpisodeListMember.Key) -> Int {
        func order<T: Comparable>(_ a: T?, _ b: T?) -> Int {
            switch (a, b) {
            case (nil, nil): 0
            case (nil, _): -1
            case (_, nil): 1
            case let (a?, b?): a == b ? 0 : (a < b ? -1 : 1)
            }
        }
        switch (a, b) {
        case let (.integer(x), .integer(y)): return order(x, y)
        case let (.real(x), .real(y)): return order(x, y)
        case let (.text(x), .text(y)):
            guard let x, let y else { return x == nil ? (y == nil ? 0 : -1) : 1 }
            if x.utf8.elementsEqual(y.utf8) { return 0 }
            return x.utf8.lexicographicallyPrecedes(y.utf8) ? -1 : 1
        default: return 0
        }
    }
}

/// One list member: the episode, its podcast and its sort key.
public struct EpisodeListMember: Sendable {
    public enum Key: Sendable { case integer(Int64?), real(Double?), text(String?) }
    public let id: Int64
    public let feedID: Int64
    public let key: Key
}

/// What one update did to a list: members that left (with their rank in the list before, highest first) and members that
/// joined (with their rank in the list after, lowest first). A member whose key changed leaves and joins again.
/// Applying the removals in order, then the insertions in order, to the list before gives the list after.
public struct EpisodeListChange: Equatable, Sendable {
    public var removed: [Removal] = []
    public var inserted: [Insertion] = []
    public struct Removal: Equatable, Sendable {
        public let id: Int64, rank: Int
        public init(id: Int64, rank: Int) { self.id = id; self.rank = rank }
    }
    public struct Insertion: Equatable, Sendable {
        public let id: Int64, rank: Int
        public init(id: Int64, rank: Int) { self.id = id; self.rank = rank }
    }
    public var isEmpty: Bool { removed.isEmpty && inserted.isEmpty }
    public init(removed: [Removal] = [], inserted: [Insertion] = []) { self.removed = removed; self.inserted = inserted }
}

/// The full ordered membership of an open list, kept by applying changed episodes one by one: each removal is found by its
/// stored member (the key it was placed by), each insert by binary search, in bounded chunks.
public struct EpisodeListIndex {
    public let spec: EpisodeListSpec
    private var list: ChunkedOrderedList<EpisodeListMember>
    private var members: [Int64: EpisodeListMember]

    /// Opens the list over `candidates` (every episode that could belong, with its podcast).
    public init<S: Sequence>(spec: EpisodeListSpec, candidates: S, queued: Set<Int64>, capacity: Int = 256)
    where S.Element == (feed: LibraryFeed, episode: LibraryEpisode) {
        self.spec = spec
        var found: [EpisodeListMember] = []
        for (feed, episode) in candidates where spec.includes(feed: feed, episode: episode, queued: queued.contains(episode.id)) {
            found.append(spec.member(feedID: feed.id, episode: episode))
        }
        found.sort(by: spec.precedes)
        var byID: [Int64: EpisodeListMember] = [:]
        byID.reserveCapacity(found.count)
        for member in found { byID[member.id] = member }
        members = byID
        list = ChunkedOrderedList(sorted: found, capacity: capacity, by: spec.precedes)
    }

    public var count: Int { list.count }
    public func contains(_ id: Int64) -> Bool { members[id] != nil }
    public var metrics: ChunkedOrderedList<EpisodeListMember>.Metrics {
        get { list.metrics }
        set { list.metrics = newValue }
    }

    /// The members with ranks in `range`, in order.
    public mutating func ids(_ range: Range<Int>) -> [Int64] { list.elements(range).map(\.id) }
    /// Every member in order (explicit: select all, the pager, tests).
    public var allIDs: [Int64] { list.all.map(\.id) }
    public mutating func rank(of id: Int64) -> Int? { members[id].flatMap { list.rank(of: $0) } }

    /// Applies the current state of changed episodes: `changes[id]` is the episode with its podcast now, or nil when it is
    /// gone from the library. An episode not named keeps its place.
    public mutating func apply(_ changes: [Int64: (feed: LibraryFeed, episode: LibraryEpisode)?], queued: Set<Int64>) -> EpisodeListChange {
        var leaving: [EpisodeListMember] = [], joining: [EpisodeListMember] = []
        for (id, value) in changes {
            let old = members[id]
            let new = value.flatMap { value in
                spec.includes(feed: value.feed, episode: value.episode, queued: queued.contains(id))
                    ? spec.member(feedID: value.feed.id, episode: value.episode) : nil
            }
            if let old, let new, !spec.precedes(old, new), !spec.precedes(new, old), old.feedID == new.feedID { continue }
#if DEBUG
            if screenModelFaults.contains(.removeByNewKey), old != nil, let new { leaving.append(new); joining.append(new); continue }
#endif
            if let old { leaving.append(old) }
            if let new { joining.append(new) }
        }
        var change = EpisodeListChange()
        guard !leaving.isEmpty || !joining.isEmpty else { return change }
        // Ranks against the list before, then removed highest first so each rank stays valid.
        var removals: [(EpisodeListMember, Int)] = leaving.compactMap { member in list.rank(of: member).map { (member, $0) } }
        removals.sort { $0.1 > $1.1 }
        for (member, rank) in removals {
            list.remove(member)
            members[member.id] = nil
            change.removed.append(.init(id: member.id, rank: rank))
        }
        for member in joining {
            list.insert(member)
            members[member.id] = member
        }
        var insertions = joining.compactMap { member in list.rank(of: member).map { EpisodeListChange.Insertion(id: member.id, rank: $0) } }
        insertions.sort { $0.rank < $1.rank }
        change.inserted = insertions
        return change
    }
}

extension EpisodeListIndex {
    /// Applies a mirror patch: the changed episodes, every episode of a feed whose state decides this list (a feed that
    /// entered, left or changed subscription state; feed-proportional and rare), and, for a list filtered by the queue,
    /// the episodes that joined or left the queue.
    public mutating func apply(_ delta: LibraryMirrorDelta, mirror: LibraryScreenMirror) -> EpisodeListChange {
        var changes: [Int64: (feed: LibraryFeed, episode: LibraryEpisode)?] = [:]
        for (id, change) in delta.episodes { changes.updateValue(change.new, forKey: id) }
        if spec.dependsOnFeedState {
            for feed in delta.feedStates {
                for episode in mirror.feed(feed)?.episodes ?? [] where changes[episode.id] == nil {
                    changes.updateValue(mirror.episode(episode.id), forKey: episode.id)
                }
            }
        }
        if spec.dependsOnQueue {
            for id in delta.queueMembers where changes[id] == nil {
                changes.updateValue(mirror.episode(id), forKey: id)
            }
        }
        return apply(changes, queued: mirror.queuedIDs)
    }
}

extension LibraryScreenMirror {
    /// The Inbox badge and drawer row: NEW episodes of subscribed feeds (`NavigationCounters.inbox`), from the counts.
    public var inboxCount: Int {
        feeds.reduce(0) { total, feed in
            feed.subscriptionState == .subscribed ? total + Int(counts[feed.id]?.new ?? 0) : total
        }
    }

    /// Each subscribed feed's counter under `counter` when above zero (`SubscriptionListQueries.counters`), from the counts.
    public func counters(_ counter: FeedCounter) -> [Int64: Int] {
        guard counter != .showNone else { return [:] }
        var result: [Int64: Int] = [:]
        for feed in feeds where feed.subscriptionState == .subscribed {
            let value = Int(counts[feed.id]?.count(for: counter) ?? 0)
            if value > 0 { result[feed.id] = value }
        }
        return result
    }

    /// The Downloads list (`DownloadsList.episodes` over the downloaded episodes and those of active jobs): proportional
    /// to the downloads, never to the library.
    public func downloads(jobs: [LibraryDownloadJob], order: FeedEpisodeSortOrder?) -> [Int64] {
        var candidates = downloadedIDs
        for job in jobs where job.state.isActive { candidates.formUnion(episodes(mediaURL: job.source)) }
        let episodes = candidates.sorted().compactMap { episode($0)?.episode }
        return DownloadsList.episodes(episodes, jobs: jobs, order: order).map(\.id)
    }
}
