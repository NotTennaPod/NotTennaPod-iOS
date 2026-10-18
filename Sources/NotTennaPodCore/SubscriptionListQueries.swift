import Foundation

/// `DBReader.getNavDrawerData`.
public enum SubscriptionListQueries {
    public struct Result: Sendable {
        public var feeds: [LibraryFeed]
        /// Counters of every subscribed feed under the counter setting (unfiltered).
        public var counters: [Int64: Int]
        /// Tag groups: feeds tagged `#root` (untagged feeds count as root) first, then each folder.
        public var folders: [(title: String, feeds: [LibraryFeed])]
        public var rootFeeds: [LibraryFeed] { folders.first { FeedTags.equal($0.title, FeedTags.root) }?.feeds ?? [] }
        public var counterSum: Int { counters.values.reduce(0, +) }
    }

    /// Items per subscribed feed matching the predicate (archived/preview feeds have none).
    public static func counters(_ feeds: [LibraryFeed], _ counter: FeedCounter) -> [Int64: Int] {
        guard counter != .showNone else { return [:] }
        return count(feeds, counter.counts)
    }
    static func count(_ feeds: [LibraryFeed], _ predicate: (LibraryEpisode) -> Bool) -> [Int64: Int] {
        var result: [Int64: Int] = [:]
        for feed in feeds where feed.subscriptionState == .subscribed {
            let value = feed.episodes.reduce(0) { predicate($1) ? $0 + 1 : $0 }
            if value > 0 { result[feed.id] = value }
        }
        return result
    }

    public static func load(_ all: [LibraryFeed], preferences: SubscriptionDisplayPreferences,
                            state: FeedSubscriptionState, globalAutoDownload: Bool) -> Result {
        load(all, counters: counters(all, preferences.counter), preferences: preferences, state: state, globalAutoDownload: globalAutoDownload)
    }

    /// With the per-feed counters already known for `preferences.counter` (the screens keep them as counts).
    public static func load(_ all: [LibraryFeed], counters: [Int64: Int], preferences: SubscriptionDisplayPreferences,
                            state: FeedSubscriptionState, globalAutoDownload: Bool) -> Result {
        let order = preferences.order
        return load(all, counters: counters, played: order == .mostPlayed ? playedCounts(all) : [:],
                    latest: order == .mostRecentEpisode ? latestDates(all) : [:], preferences: preferences, state: state,
                    globalAutoDownload: globalAutoDownload)
    }

    /// With every per-feed value it orders by already known: the counters, the played episodes of subscribed feeds
    /// (`playedCounts`, most played) and each feed's newest episode date (`latestDates`, most recent episode).
    public static func load(_ all: [LibraryFeed], counters: [Int64: Int], played: [Int64: Int], latest: [Int64: Int64],
                            preferences: SubscriptionDisplayPreferences, state: FeedSubscriptionState,
                            globalAutoDownload: Bool) -> Result {
        // The archive loads with an empty filter (SubscriptionFragment:368–369).
        let filter = state == .archived ? SubscriptionsFilter(stored: "") : preferences.filter
        let typed = preOrder(all).filter { $0.subscriptionState == state }
        let kept = filter.apply(typed, counters: counters, globalAutoDownload: globalAutoDownload)
        let ordered = sort(kept, order: preferences.order, counters: counters, played: played, latest: latest)
        return Result(feeds: ordered, counters: counters, folders: folders(ordered))
    }

#if DEBUG
    /// Tests: episodes visited by the full scans below (the screens keep these values instead, `FeedLatestDates`).
    nonisolated(unsafe) public static var episodesScanned = 0
#endif

    /// Played episodes per subscribed feed, above zero.
    public static func playedCounts(_ all: [LibraryFeed]) -> [Int64: Int] {
#if DEBUG
        episodesScanned += all.reduce(0) { $0 + $1.episodes.count }
#endif
        return count(all) { $0.userState.playState == .played }
    }

    /// Each feed's newest publication date in milliseconds (a missing date counts as 0; 0 without episodes).
    public static func latestDates(_ all: [LibraryFeed]) -> [Int64: Int64] {
#if DEBUG
        episodesScanned += all.reduce(0) { $0 + $1.episodes.count }
#endif
        var recent: [Int64: Int64] = [:]
        for feed in all {
            recent[feed.id] = feed.episodes.map { $0.details.publicationDate.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? 0 }.max() ?? 0
        }
        return recent
    }

    /// `getAllFeedsCursor`: raw feed title `COLLATE NOCASE` (ASCII fold, then UTF-8 bytes), NULL
    /// first, equal keys in rowid (feed id) order.
    public static func preOrder(_ feeds: [LibraryFeed]) -> [LibraryFeed] {
        func key(_ feed: LibraryFeed) -> [UInt8]? {
            feed.metadata.title.map { $0.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 } }
        }
        return feeds.map { (key($0), $0) }.sorted { lhs, rhs in
            switch (lhs.0, rhs.0) {
            case (nil, nil): return lhs.1.id < rhs.1.id
            case (nil, _): return true
            case (_, nil): return false
            case let (l?, r?): return l == r ? lhs.1.id < rhs.1.id : l.lexicographicallyPrecedes(r)
            }
        }.map(\.1)
    }

    /// The four stable comparators. A null display title in a counter tie throws in the source
    /// (reference defect); it sorts after non-null titles here, as ALPHABETICAL does.
    public static func sort(_ feeds: [LibraryFeed], order: FeedOrder, counters: [Int64: Int], all: [LibraryFeed]) -> [LibraryFeed] {
        sort(feeds, order: order, counters: counters, played: order == .mostPlayed ? playedCounts(all) : [:],
             latest: order == .mostRecentEpisode ? latestDates(all) : [:])
    }

    /// With the played counts and newest dates already known (missing values count as 0).
    public static func sort(_ feeds: [LibraryFeed], order: FeedOrder, counters: [Int64: Int], played: [Int64: Int],
                            latest recent: [Int64: Int64]) -> [LibraryFeed] {
        func titleOrder(_ l: LibraryFeed, _ r: LibraryFeed) -> Int {
            switch (l.title, r.title) {
            case (nil, nil): return 0
            case (nil, _): return 1
            case (_, nil): return -1
            case let (a?, b?): return compareToIgnoreCase(a, b)
            }
        }
        let comparison: (LibraryFeed, LibraryFeed) -> Int
        switch order {
        case .counter, .mostPlayed:
            let values = order == .counter ? counters : played
            comparison = { l, r in
                let a = values[l.id, default: 0], b = values[r.id, default: 0]
                return a != b ? (a > b ? -1 : 1) : titleOrder(l, r)
            }
        case .alphabetical:
            comparison = titleOrder
        case .mostRecentEpisode:
            comparison = { l, r in
                let a = recent[l.id, default: 0], b = recent[r.id, default: 0]
                return a == b ? 0 : (b > a ? 1 : -1)
            }
        }
        // Collections.sort is stable.
        return feeds.enumerated().sorted { lhs, rhs in
            let value = comparison(lhs.element, rhs.element)
            return value == 0 ? lhs.offset < rhs.offset : value < 0
        }.map(\.element)
    }

    /// `DBReader.getNavDrawerData` tag grouping: `HashMap` iteration order, then a stable
    /// case-insensitive sort; `#untagged` (feeds only in `#root`) first.
    static func folders(_ ordered: [LibraryFeed]) -> [(title: String, feeds: [LibraryFeed])] {
        var untagged: [LibraryFeed] = []
        var tags = FeedTagOrder.Builder(capacity: 16)
        var members: [[UInt16]: [LibraryFeed]] = [:]
        for feed in ordered {
            let feedTags = FeedTagOrder.Builder(collection: feed.tags.isEmpty ? [FeedTags.root] : feed.tags).values
            if feedTags.isEmpty || (feedTags.count == 1 && FeedTags.equal(feedTags[0], FeedTags.root)) { untagged.append(feed) }
            for tag in feedTags {
                tags.insert(tag)
                members[Array(tag.utf16), default: []].append(feed)
            }
        }
        var result = tags.values.enumerated().sorted { lhs, rhs in
            let value = compareToIgnoreCase(lhs.element, rhs.element)
            return value == 0 ? lhs.offset < rhs.offset : value < 0
        }.map { (title: $0.element, feeds: members[Array($0.element.utf16)] ?? []) }
        if !untagged.isEmpty { result.insert((FeedTags.untagged, untagged), at: 0) }
        return result
    }

    /// `String.compareToIgnoreCase`: UTF-16 code units, simple upper- then lower-case mapping
    /// (locale independent).
    public static func compareToIgnoreCase(_ a: String, _ b: String) -> Int {
        let left = Array(a.utf16), right = Array(b.utf16)
        for (c1, c2) in zip(left, right) where c1 != c2 {
            let u1 = simpleUpper(c1), u2 = simpleUpper(c2)
            if u1 != u2 {
                let l1 = simpleLower(u1), l2 = simpleLower(u2)
                if l1 != l2 { return Int(l1) - Int(l2) }
            }
        }
        return left.count - right.count
    }
    /// `Character.toUpperCase(char)`: the single-unit mapping; full mappings that expand keep the
    /// titlecase form when it is a single unit (U+1FB3 → U+1FBC) and otherwise the character (ß).
    static func simpleUpper(_ unit: UInt16) -> UInt16 {
        guard let scalar = Unicode.Scalar(unit) else { return unit }
        return single(scalar.properties.uppercaseMapping) ?? single(scalar.properties.titlecaseMapping) ?? unit
    }
    /// `Character.toLowerCase(char)`: U+0130 → U+0069 (UnicodeData simple mapping).
    static func simpleLower(_ unit: UInt16) -> UInt16 {
        if unit == 0x0130 { return 0x0069 }
        guard let scalar = Unicode.Scalar(unit) else { return unit }
        return single(scalar.properties.lowercaseMapping) ?? unit
    }
    private static func single(_ mapping: String) -> UInt16? {
        let units = Array(mapping.utf16)
        return units.count == 1 ? units[0] : nil
    }
}
