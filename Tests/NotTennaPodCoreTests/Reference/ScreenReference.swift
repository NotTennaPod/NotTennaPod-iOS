import Foundation
@testable import NotTennaPodCore

/// The other screens' full-reload reads as they were before incremental screens (iOS `1ca0d10`), copied verbatim from
/// `HomeSections.swift` (`HomeSectionQueries`), `SubscriptionListQueries.swift` (`counters`, `count`, `load`, `preOrder`,
/// `sort`), `LibrarySearch.swift` (`LibrarySearchResult.search`) and `LibraryViewController+Home.swift` (Home's Downloads
/// rows), only renamed into this namespace: `EpisodeListQueries.inbox` is `FullReloadReference.inbox`, and the unchanged
/// helpers `folders` and `compareToIgnoreCase` are called in `SubscriptionListQueries`. Home, Subscriptions, the drawer and
/// search kept from patches must equal these on every step. `FullReloadReferencePinTests` fails when this file changes.
enum ScreenReference {
    // MARK: HomeSectionQueries

    /// `getPausedQueue(8)` (PDA:1087–1101): the queue with resumed items (position ≥ 1 s, or played in
    /// the last 30 s) first by last played time, then queue order; any feed state.
    static func continueListening(queue: [LibraryEpisode], now: Int64, limit: Int = 8) -> [LibraryEpisode] {
        queue.enumerated().sorted { lhs, rhs in
            func key(_ episode: LibraryEpisode) -> Int64 {
                let state = episode.userState
                guard episode.details.media != nil else { return 0 }
                return state.positionMilliseconds >= 1000 || state.lastPlayedTimeMilliseconds >= now - 30_000 ? state.lastPlayedTimeMilliseconds : 0
            }
            let left = key(lhs.element), right = key(rhs.element)
            return left == right ? lhs.offset < rhs.offset : left > right
        }.prefix(limit).map(\.element)
    }

    /// `getEpisodes(0, 2, NEW, inbox order)` + total NEW count, subscribed feeds only, in the Inbox sort.
    static func inbox(_ feeds: [LibraryFeed], sort: EpisodeListSort = .standard, limit: Int = 2) -> (items: [(LibraryFeed, LibraryEpisode)], total: Int) {
        let all = FullReloadReference.inbox(feeds, sort: sort)
        return (all.prefix(limit).map { ($0.feed, $0.episode) }, all.count)
    }

    /// Badge text: "99+" at 100 or more (`InboxSection.java:131–136`).
    static func badge(_ total: Int) -> String { total >= 100 ? "99+" : "\(total)" }

    /// `getRandomEpisodes(8, seed)` (PDA:1146–1167): unplayed/new, published within 356·2 days (source
    /// value), never played or played in the last hour, subscribed, with media; one per feed (the
    /// member with the largest `(id·seed) % 46471`), ordered by `(id·wrap32(seed·3)) % 46471` desc.
    static func surprise(_ feeds: [LibraryFeed], seed: Int32, now: Int64, limit: Int = 8) -> [(LibraryFeed, LibraryEpisode)] {
        let seed64 = Int64(seed), seed3 = Int64(seed &* 3)
        let since = now - 1000 * 3600 * 24 * 356 * 2
        var picks: [(LibraryFeed, LibraryEpisode)] = []
        for feed in feeds.sorted(by: { $0.id < $1.id }) where feed.subscriptionState == .subscribed {
            let candidates = feed.episodes.filter { episode in
                let state = episode.userState
                guard episode.details.media != nil, state.playState != .played else { return false }
                let published = episode.details.publicationDate.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? 0
                return published > since && (state.lastPlayedTimeMilliseconds == 0 || state.lastPlayedTimeMilliseconds > now - 3_600_000)
            }
            if let pick = candidates.max(by: { lhs, rhs in
                let left = (lhs.id &* seed64) % 46471, right = (rhs.id &* seed64) % 46471
                return left == right ? lhs.id > rhs.id : left < right
            }) { picks.append((feed, pick)) }
        }
        return Array(picks.sorted { lhs, rhs in
            let left = (lhs.1.id &* seed3) % 46471, right = (rhs.1.id &* seed3) % 46471
            return left == right ? lhs.1.id < rhs.1.id : left > right
        }.prefix(limit))
    }

    /// `getStatistics(countAll, now − 3·365 d, max).feedTime` sorted by played seconds (stable over feed
    /// id), then the first 8 subscribed (archived skipped after ranking).
    static func classics(_ feeds: [LibraryFeed], units: [Int64: [LibraryStatisticsUnit]] = [:], includeMarkedAsPlayed: Bool,
                                now: Date, limit: Int = 8) throws -> [LibraryFeed] {
        let from = Int64((now.timeIntervalSince1970 * 1000).rounded()) - 3 * 365 * 24 * 3600 * 1000
        let statistics = try LibraryStatistics(feeds: feeds, units: units, includeMarkedAsPlayed: includeMarkedAsPlayed, timeFrom: from, timeTo: .max, now: now)
        let byID = Dictionary(uniqueKeysWithValues: feeds.map { ($0.id, $0) })
        let ranked = statistics.feeds.enumerated().sorted { lhs, rhs in
            lhs.element.playedSeconds == rhs.element.playedSeconds ? lhs.offset < rhs.offset : lhs.element.playedSeconds > rhs.element.playedSeconds
        }
        return Array(ranked.compactMap { byID[$0.element.feedID] }.filter { $0.subscriptionState == .subscribed }.prefix(limit))
    }

    /// `true` when Home shows the welcome state: no episodes in subscribed feeds.
    static func showsWelcome(_ feeds: [LibraryFeed]) -> Bool {
        !feeds.contains { $0.subscriptionState == .subscribed && !$0.episodes.isEmpty }
    }

    /// Home's Downloads rows (`LibraryViewController+Home.swift`): the first two downloaded episodes, no jobs.
    static func homeDownloads(_ feeds: [LibraryFeed], order: FeedEpisodeSortOrder?) -> [Int64] {
        let downloaded = DownloadsList.episodes(feeds.flatMap { $0.episodes.filter(\.userState.isDownloaded) }, jobs: [],
                                                order: order)
        return downloaded.prefix(2).map(\.id)
    }

    // MARK: SubscriptionListQueries

    /// Items per subscribed feed matching the predicate (archived/preview feeds have none).
    static func counters(_ feeds: [LibraryFeed], _ counter: FeedCounter) -> [Int64: Int] {
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

    static func load(_ all: [LibraryFeed], preferences: SubscriptionDisplayPreferences,
                            state: FeedSubscriptionState, globalAutoDownload: Bool) -> SubscriptionListQueries.Result {
        let counters = counters(all, preferences.counter)
        // The archive loads with an empty filter (SubscriptionFragment:368–369).
        let filter = state == .archived ? SubscriptionsFilter(stored: "") : preferences.filter
        let typed = preOrder(all).filter { $0.subscriptionState == state }
        let kept = filter.apply(typed, counters: counters, globalAutoDownload: globalAutoDownload)
        let ordered = sort(kept, order: preferences.order, counters: counters, all: all)
        return SubscriptionListQueries.Result(feeds: ordered, counters: counters, folders: SubscriptionListQueries.folders(ordered))
    }

    /// `getAllFeedsCursor`: raw feed title `COLLATE NOCASE` (ASCII fold, then UTF-8 bytes), NULL
    /// first, equal keys in rowid (feed id) order.
    static func preOrder(_ feeds: [LibraryFeed]) -> [LibraryFeed] {
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
    static func sort(_ feeds: [LibraryFeed], order: FeedOrder, counters: [Int64: Int], all: [LibraryFeed]) -> [LibraryFeed] {
        func titleOrder(_ l: LibraryFeed, _ r: LibraryFeed) -> Int {
            switch (l.title, r.title) {
            case (nil, nil): return 0
            case (nil, _): return 1
            case (_, nil): return -1
            case let (a?, b?): return SubscriptionListQueries.compareToIgnoreCase(a, b)
            }
        }
        let comparison: (LibraryFeed, LibraryFeed) -> Int
        switch order {
        case .counter, .mostPlayed:
            let values = order == .counter ? counters : count(all) { $0.userState.playState == .played }
            comparison = { l, r in
                let a = values[l.id, default: 0], b = values[r.id, default: 0]
                return a != b ? (a > b ? -1 : 1) : titleOrder(l, r)
            }
        case .alphabetical:
            comparison = titleOrder
        case .mostRecentEpisode:
            var recent: [Int64: Int64] = [:]
            for feed in all {
                recent[feed.id] = feed.episodes.map { $0.details.publicationDate.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? 0 }.max() ?? 0
            }
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


    // MARK: LibrarySearchResult

    /// `FeedLibraryStore.search` over a library already loaded in memory: the same results in
    /// the same order, without SQLite parsing every episode record's JSON for each query (0.3–0.4 s on a
    /// 23,000-episode library). `deletionTargets` are the loaded snapshot's.
    static func search(query: String, feeds: [LibraryFeed], deletionTargets: [Int64: EpisodeMediaDeletionTarget],
                              feedID: Int64? = nil, archived: Bool = false) throws -> LibrarySearchResult {
        try Task.checkCancellation()
        let words = query.components(separatedBy: CharacterSet(charactersIn: " \t\n\u{b}\u{c}\r")).filter { !$0.isEmpty }
        guard !words.isEmpty else { return .init() }
        let patterns = words.map(SQLiteLikePattern.init(containing:))
        let state: FeedSubscriptionState = archived ? .archived : .subscribed
        var result = LibrarySearchResult()
        var matches: [(pubdate: Int64, episode: LibraryEpisode, feedID: Int64)] = []
        for feed in feeds {
            if let feedID { guard feed.id == feedID else { continue } } else { guard feed.subscriptionState == state else { continue } }
            try Task.checkCancellation()
            for episode in feed.episodes where patterns.allSatisfy({ $0.matches(episode.details.title) || $0.matches(episode.details.description) }) {
                // The episodes table's pubdate column: whole milliseconds, truncated.
                let pubdate = episode.details.publicationDate.map { Int64($0.timeIntervalSince1970 * 1_000) } ?? 0
                matches.append((pubdate, episode, feed.id))
            }
        }
        // ORDER BY e.pubdate DESC, e.id LIMIT 300
        matches.sort { $0.pubdate != $1.pubdate ? $0.pubdate > $1.pubdate : $0.episode.id < $1.episode.id }
        result.episodes = matches.prefix(300).map { .init(feedID: $0.feedID, episode: $0.episode, deletionTarget: deletionTargets[$0.episode.id]) }
        if feedID == nil {
            let found = feeds.filter { feed in
                feed.subscriptionState == state && patterns.allSatisfy { pattern in
                    [feed.metadata.title, feed.customTitle, feed.metadata.author, feed.metadata.description].contains { pattern.matches($0) }
                }
            }
            // ORDER BY f.title ASC (the metadata title column; NULL first; byte order), f.id LIMIT 300
            result.feeds = Array(found.sorted { lhs, rhs in
                switch (lhs.metadata.title, rhs.metadata.title) {
                case (nil, nil): return lhs.id < rhs.id
                case (nil, _): return true
                case (_, nil): return false
                case let (left?, right?):
                    if left.utf8.elementsEqual(right.utf8) { return lhs.id < rhs.id }
                    return left.utf8.lexicographicallyPrecedes(right.utf8)
                }
            }.prefix(300)).map { var feed = $0; feed.episodes = []; return feed }
        }
        return result
    }
}
