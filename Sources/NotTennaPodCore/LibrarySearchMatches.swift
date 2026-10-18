import Foundation

/// Every episode and podcast an open library search matches, kept exactly as the library changes: the query's scan finds
/// all matches once (not only the 300 shown), and each patch re-evaluates only the episodes and podcasts it changed with
/// the same predicate (`LibrarySearchResult.search`: every word in the title or description, the podcast's scope). The
/// result shows the first 300 in `pubdate DESC, id` order, so a result that leaves exposes the next one with no new scan,
/// and a refresh's unchanged podcast costs nothing. Only the person's new query scans again.
public struct LibrarySearchMatches: @unchecked Sendable {
    struct Member {
        let pubdate: Int64
        let id: Int64
        static func precedes(_ a: Self, _ b: Self) -> Bool { a.pubdate == b.pubdate ? a.id < b.id : a.pubdate > b.pubdate }
    }

    public struct Metrics: Equatable, Sendable {
        /// Episodes whose match was evaluated by patches.
        public var episodesEvaluated = 0
        /// Podcasts whose match was evaluated by patches.
        public var feedsEvaluated = 0
        public init() {}
    }

    public let feedID: Int64?
    public let archived: Bool
    /// The query's words, for the text condition read in SQLite (`LibraryDetailReader.episodes(_:matching:)`).
    public let words: [String]
    private let patterns: [SQLiteLikePattern]
    private var list: ChunkedOrderedList<Member>
    private var keys: [Int64: Int64]
    private var feeds: Set<Int64>
    public var metrics = Metrics()
    public static let shown = 300

    /// The query's words (`FeedLibraryStore.search`): Java's ASCII whitespace separates them.
    public static func words(_ query: String) -> [String] {
        query.components(separatedBy: CharacterSet(charactersIn: " \t\n\u{b}\u{c}\r")).filter { !$0.isEmpty }
    }

    /// The scan of a new query over the screens' library (nil without words). Cancellable.
    public init?(query: String, feeds all: [LibraryFeed], feedID: Int64?, archived: Bool, capacity: Int = 256) throws {
        let words = Self.words(query)
        guard !words.isEmpty else { return nil }
        self.feedID = feedID; self.archived = archived; self.words = words
        patterns = words.map(SQLiteLikePattern.init(containing:))
        var found: [Member] = []
        var matchedFeeds: Set<Int64> = []
        for feed in all {
            try Task.checkCancellation()
            if Self.matches(feed: feed, patterns: patterns, feedID: feedID, archived: archived) { matchedFeeds.insert(feed.id) }
            guard Self.inScope(feed, feedID: feedID, archived: archived) else { continue }
            for episode in feed.episodes where Self.matches(episode, patterns) { found.append(Member(pubdate: Self.pubdate(episode), id: episode.id)) }
        }
        found.sort(by: Member.precedes)
        var keys: [Int64: Int64] = [:]
        keys.reserveCapacity(found.count)
        for member in found { keys[member.id] = member.pubdate }
        self.keys = keys
        self.feeds = matchedFeeds
        list = ChunkedOrderedList(sorted: found, capacity: capacity, by: Member.precedes)
    }

    /// A new query's matches from the episodes whose text matches it (`LibraryReader.searchMatches`, read in SQLite, with
    /// their stored `pubdate`), kept when the screens' library shows them in the query's scope (the library
    /// holds no show notes to scan). Nil without words. Cancellable.
    public init?(query: String, textMatches: [(id: Int64, pubdate: Int64)], mirror: LibraryScreenMirror, feedID: Int64?, archived: Bool,
                 capacity: Int = 256) throws {
        let words = Self.words(query)
        guard !words.isEmpty else { return nil }
        self.feedID = feedID; self.archived = archived; self.words = words
        patterns = words.map(SQLiteLikePattern.init(containing:))
        var found: [Member] = []
        for (id, pubdate) in textMatches {
            guard let value = mirror.episode(id), Self.inScope(value.feed, feedID: feedID, archived: archived) else { continue }
            found.append(Member(pubdate: pubdate, id: id))
        }
        try Task.checkCancellation()
        var matchedFeeds: Set<Int64> = []
        for feed in mirror.feeds where Self.matches(feed: feed, patterns: patterns, feedID: feedID, archived: archived) { matchedFeeds.insert(feed.id) }
        found.sort(by: Member.precedes)
        var keys: [Int64: Int64] = [:]
        keys.reserveCapacity(found.count)
        for member in found { keys[member.id] = member.pubdate }
        self.keys = keys
        self.feeds = matchedFeeds
        list = ChunkedOrderedList(sorted: found, capacity: capacity, by: Member.precedes)
    }

    /// A new query's scan over the screens' library: its text matched in SQLite on `reader` (the library holds no show
    /// notes), with the query's own reader token, so cancelling the query interrupts its read and a read cancelled before
    /// it starts never runs: a superseded query never keeps the reader from the next one. Nil without words.
    public static func scan(query: String, reader: LibraryReader, mirror: LibraryScreenMirror, feedID: Int64?, archived: Bool,
                            capacity: Int = 256, token: LibraryReader.Token = .init()) async throws -> LibrarySearchMatches? {
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let text = try await reader.searchMatches(words: words(query), feedID: feedID, token: token)
            return try LibrarySearchMatches(query: query, textMatches: text, mirror: mirror, feedID: feedID, archived: archived, capacity: capacity)
        } onCancel: {
            reader.interrupt(token)
        }
    }

    /// Every matching episode (tests).
    public var count: Int { list.count }

    // MARK: - The predicate

    /// The episodes table's pubdate column: whole milliseconds, truncated.
    public static func pubdate(_ episode: LibraryEpisode) -> Int64 {
        episode.details.publicationDate.map { Int64($0.timeIntervalSince1970 * 1_000) } ?? 0
    }

    static func inScope(_ feed: LibraryFeed, feedID: Int64?, archived: Bool) -> Bool {
        if let feedID { return feed.id == feedID }
        return feed.subscriptionState == (archived ? .archived : .subscribed)
    }

    static func matches(_ episode: LibraryEpisode, _ patterns: [SQLiteLikePattern]) -> Bool {
        patterns.allSatisfy { $0.matches(episode.details.title) || $0.matches(episode.details.description) }
    }

    /// The podcast results: subscribed (or archived) podcasts whose title, custom title, author or description has every
    /// word; none in a podcast's own search.
    static func matches(feed: LibraryFeed, patterns: [SQLiteLikePattern], feedID: Int64?, archived: Bool) -> Bool {
        guard feedID == nil, feed.subscriptionState == (archived ? .archived : .subscribed) else { return false }
        return patterns.allSatisfy { pattern in
            [feed.metadata.title, feed.customTitle, feed.metadata.author, feed.metadata.description].contains { pattern.matches($0) }
        }
    }

    // MARK: - Patches

    /// Re-evaluates `episodes` (changed, added or gone), every episode of `resetFeeds` (a podcast that came, went or
    /// changed its scope: feed-proportional, rare) and the podcast results of `feeds`, against the library now. Returns
    /// whether the matches changed.
    /// `text`: of the given episodes, those whose title and show notes match the words, read in SQLite
    /// (`LibraryDetailReader.episodes(_:matching:)`) when the mirror holds list projections; nil (or a nil result): the
    /// mirror's episodes are whole and are matched in memory. A failed read changes nothing.
    @discardableResult
    public mutating func apply(episodes: Set<Int64>, resetFeeds: Set<Int64>, feeds changedFeeds: Set<Int64>,
                               mirror: LibraryScreenMirror, text: ((Set<Int64>, [String]) throws -> Set<Int64>?)? = nil) -> Bool {
#if DEBUG
        if otherScreenFaults.contains(.searchNotPatched) { return false }
#endif
        var changed = false
        var ids = episodes
        for feed in resetFeeds { for episode in mirror.feed(feed)?.episodes ?? [] { ids.insert(episode.id) } }
        var textMatched: Set<Int64>?
        if let text {
            let candidates = Set(ids.filter { id in mirror.episode(id).map { Self.inScope($0.feed, feedID: feedID, archived: archived) } ?? false })
            do { textMatched = try text(candidates, words) } catch { return false }
        }
        for id in ids {
            metrics.episodesEvaluated += 1
            let now = mirror.episode(id).flatMap { value -> Member? in
                guard Self.inScope(value.feed, feedID: feedID, archived: archived),
                      textMatched?.contains(id) ?? Self.matches(value.episode, patterns) else { return nil }
                return Member(pubdate: Self.pubdate(value.episode), id: id)
            }
            let old = keys[id].map { Member(pubdate: $0, id: id) }
            if old?.pubdate == now?.pubdate, (old == nil) == (now == nil) { continue }
            if let old { list.remove(old); keys[id] = nil }
            if let now { list.insert(now); keys[id] = now.pubdate }
            changed = true
        }
        for id in changedFeeds.union(resetFeeds) {
            metrics.feedsEvaluated += 1
            let matched = mirror.feed(id).map { Self.matches(feed: $0, patterns: patterns, feedID: feedID, archived: archived) } ?? false
            if matched != feeds.contains(id) {
                if matched { feeds.insert(id) } else { feeds.remove(id) }
                changed = true
            }
        }
        return changed
    }

    /// A mirror patch: its changed episodes, the episodes of podcasts that came, went or changed state, and the podcast
    /// results of podcasts whose header changed.
    @discardableResult
    public mutating func apply(_ delta: LibraryMirrorDelta, mirror: LibraryScreenMirror,
                               text: ((Set<Int64>, [String]) throws -> Set<Int64>?)? = nil) -> Bool {
        apply(episodes: delta.textChanged, resetFeeds: delta.feedStates, feeds: delta.headers, mirror: mirror, text: text)
    }

    // MARK: - The result

    /// The first 300 matching episodes (`ORDER BY e.pubdate DESC, e.id LIMIT 300`) and podcasts (`ORDER BY f.title, f.id
    /// LIMIT 300`), with their current values.
    public mutating func result(mirror: LibraryScreenMirror) -> LibrarySearchResult {
        var result = LibrarySearchResult()
        result.episodes = list.elements(0..<Self.shown).compactMap { member in
            mirror.episode(member.id).map { .init(feedID: $0.feed.id, episode: $0.episode, deletionTarget: mirror.deletionTargets[member.id]) }
        }
        let found = feeds.compactMap(mirror.feed)
        result.feeds = Array(found.sorted { lhs, rhs in
            switch (lhs.metadata.title, rhs.metadata.title) {
            case (nil, nil): return lhs.id < rhs.id
            case (nil, _): return true
            case (_, nil): return false
            case let (left?, right?):
                if left.utf8.elementsEqual(right.utf8) { return lhs.id < rhs.id }
                return left.utf8.lexicographicallyPrecedes(right.utf8)
            }
        }.prefix(Self.shown)).map { var feed = $0; feed.episodes = []; return feed }
        result.matches = self
        return result
    }

#if DEBUG
    /// Tests: the storage of the ID → key map (a copy of every match gets new storage).
    var keysStorage: UnsafeRawPointer { unsafeBitCast(keys, to: UnsafeRawPointer.self) }
#endif

    /// The memory the matches hold: the ordered list's chunks at their capacity and its directory, and the ID → key map at
    /// its capacity.
    public var estimatedBytes: Int {
        list.estimatedBytes + keys.capacity * (MemoryLayout<Int64>.stride * 2) + keys.capacity / 8 + 64
            + feeds.capacity * MemoryLayout<Int64>.stride
    }
}
