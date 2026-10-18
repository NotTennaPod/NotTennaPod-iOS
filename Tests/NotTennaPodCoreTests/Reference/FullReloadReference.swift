import Foundation
@testable import NotTennaPodCore

/// The screens' full-reload reads as they were before incremental screens (iOS `1ca0d10`), copied verbatim from
/// `EpisodeLists.swift` (`EpisodeListQueries`), `FeedEpisodeSortOrder.swift`, `LibraryFeed.swift`
/// (`filteredDisplayEpisodes`, `sortedEpisodes`), `FeedEpisodeFilter.swift`, `AllEpisodesFilterPreferenceStore.swift`
/// (`AllEpisodesFilter.includes`), `DownloadsList.swift`, `NavigationCounters.swift` (`inbox`),
/// `SubscriptionListQueries.swift` (`counters`) and `LibraryViewController+EpisodeLists.swift` / `+Downloads.swift` (the
/// Episodes and Downloads rows), only renamed into this namespace. The incremental lists must equal these on every step.
/// `FullReloadReferencePinTests` fails when this file changes.
enum FullReloadReference {
    typealias Row = (feed: LibraryFeed, episode: LibraryEpisode)

    // MARK: EpisodeListQueries

    /// NEW episodes of subscribed feeds; equal keys by episode id.
    static func inbox(_ feeds: [LibraryFeed], sort: EpisodeListSort) -> [Row] {
        let subscribed = feeds.filter { $0.subscriptionState == .subscribed }
        let members = rows(subscribed) { $0.userState.playState == .new }
        return sorted(members, sort, tie: byEpisodeID)
    }

    /// Favorites of every feed state, in the Episodes sort; equal keys by episode id.
    static func favorites(_ feeds: [LibraryFeed], sort: EpisodeListSort) -> [Row] {
        let members = rows(feeds) { $0.userState.isFavorite }
        return sorted(members, sort, tie: byEpisodeID)
    }

    /// Episodes with a completion date (`playback_completion_date > 0`, media only), newest completion
    /// first, every feed state. Equal dates by media id, which is the episode id in this library.
    static func history(_ feeds: [LibraryFeed]) -> [Row] {
        rows(feeds) { ($0.userState.lastPlayedHistoryMilliseconds ?? 0) > 0 && $0.details.media != nil }.sorted { a, b in
            let left = a.episode.userState.lastPlayedHistoryMilliseconds ?? 0, right = b.episode.userState.lastPlayedHistoryMilliseconds ?? 0
            return left == right ? a.episode.id < b.episode.id : left > right
        }
    }

    /// Already-filtered Episodes rows in the Episodes sort. Equal keys follow AntennaPod's query plan: by feed id,
    /// then episode id, unless the filter uses `played`, `queued` or `is_favorite` (then by episode id).
    static func episodes(_ rows: [Row], filter: FeedEpisodeFilter, sort: EpisodeListSort) -> [Row] {
        let byEpisode = !Set(filter.values).isDisjoint(with: ["played", "queued", "is_favorite"])
        let tie: (Row, Row) -> Bool = { a, b in
            if byEpisode || a.feed.id == b.feed.id { return a.episode.id < b.episode.id }
            return a.feed.id < b.feed.id
        }
        return sorted(rows, sort, tie: tie)
    }

    private static func byEpisodeID(_ a: Row, _ b: Row) -> Bool { a.episode.id < b.episode.id }

    private static func rows(_ feeds: [LibraryFeed], _ include: (LibraryEpisode) -> Bool) -> [Row] {
        feeds.flatMap { feed in feed.episodes.filter(include).map { (feed, $0) } }
    }

    /// One sort column; SQLite puts NULL first ascending and last descending. Keys are computed once and
    /// row indices sorted, so a library of tens of thousands of episodes sorts without copying rows around.
    private static func sorted(_ rows: [Row], _ sort: EpisodeListSort, tie: (Row, Row) -> Bool) -> [Row] {
        func key(_ row: Row) -> Int64? {
            switch sort.row {
            case .date: row.episode.details.publicationDate.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
            case .duration: (row.episode.details.media?.durationMilliseconds).map(Int64.init)
            }
        }
        let keys = rows.map(key)
        return rows.indices.sorted { a, b in
            let left = keys[a], right = keys[b]
            if left == right { return tie(rows[a], rows[b]) }
            guard let left else { return sort.ascending }
            guard let right else { return !sort.ascending }
            return sort.ascending ? left < right : left > right
        }.map { rows[$0] }
    }

    // MARK: FeedEpisodeSortOrder.sorted

    static func sorted(_ self: FeedEpisodeSortOrder, _ episodes: [LibraryEpisode], global: FeedEpisodeSortOrder = .dateNewest) -> [LibraryEpisode] {
        let order = self == .global ? (global == .global ? .dateNewest : global) : self
        func compare<T: Comparable>(_ a: T?, _ b: T?) -> Int {
            switch (a, b) {
            case (nil, nil): 0
            case (nil, _): -1
            case (_, nil): 1
            case let (a?, b?): a == b ? 0 : (a < b ? -1 : 1)
            }
        }
        func binary(_ a: String?, _ b: String?) -> Int {
            guard let a, let b else { return a == nil ? (b == nil ? 0 : -1) : 1 }
            if a.utf8.elementsEqual(b.utf8) { return 0 }
            return a.utf8.lexicographicallyPrecedes(b.utf8) ? -1 : 1
        }
        return episodes.sorted { a, b in
            let comparison: Int
            switch order.field {
            case .title: comparison = binary(a.details.title, b.details.title)
            case .filename: comparison = binary(a.details.link, b.details.link)
            case .duration: comparison = compare(a.details.media?.durationMilliseconds, b.details.media?.durationMilliseconds)
            case .size: comparison = compare(a.details.media?.size, b.details.media?.size)
            case .date: comparison = compare(a.details.publicationDate, b.details.publicationDate)
            case .global: comparison = 0
            }
            // SQLite's source row scan retains ID order when the sort key ties.
            if comparison == 0 { return a.id < b.id }
            return order.ascending ? comparison < 0 : comparison > 0
        }
    }

    // MARK: LibraryFeed

    static func filteredDisplayEpisodes(_ self: LibraryFeed, queuedIDs: Set<Int64>, globalSort: FeedEpisodeSortOrder = .dateNewest) -> [LibraryEpisode] {
        let filter = self.episodeFilter
        return sortedEpisodes(self, global: globalSort).filter { includes(filter, $0, queued: queuedIDs.contains($0.id)) }
    }
    static func sortedEpisodes(_ self: LibraryFeed, global: FeedEpisodeSortOrder = .dateNewest) -> [LibraryEpisode] {
        let order = self.episodeSortOrderCode.flatMap(FeedEpisodeSortOrder.init(rawValue:)) ?? .global
        return sorted(order, self.episodes, global: global)
    }

    // MARK: FeedEpisodeFilter.includes, AllEpisodesFilter.includes

    static func includes(_ self: FeedEpisodeFilter, _ episode: LibraryEpisode, queued: Bool) -> Bool {
        let tokens = Set(self.values), state = episode.userState, media = episode.details.media != nil
        if tokens.contains("played") { if state.playState != .played { return false } }
        else if tokens.contains("unplayed") { if state.playState == .played { return false } }
        else if tokens.contains("new"), state.playState != .new { return false }
        if tokens.contains("paused") { if !media || state.positionMilliseconds <= 0 { return false } }
        else if tokens.contains("not_paused"), media && state.positionMilliseconds != 0 { return false }
        if tokens.contains("queued") { if !queued { return false } }
        else if tokens.contains("not_queued"), queued { return false }
        // LEFT JOIN absence is SQL NULL: neither > 0 nor = 0 succeeds.
        let downloaded = state.downloadDate?.timeIntervalSince1970 ?? 0
        if tokens.contains("downloaded") { if !media || downloaded <= 0 { return false } }
        else if tokens.contains("not_downloaded"), !media || downloaded != 0 { return false }
        if tokens.contains("has_media") { if !media { return false } }
        else if tokens.contains("no_media"), media { return false }
        if tokens.contains("is_favorite") { if !state.isFavorite { return false } }
        else if tokens.contains("not_favorite"), state.isFavorite { return false }
        if tokens.contains("is_in_history"), !media || (state.lastPlayedHistoryMilliseconds ?? 0) <= 0 { return false }
        return true
    }
    static func includes(_ self: AllEpisodesFilter, _ episode: LibraryEpisode, subscription: FeedSubscriptionState, queued: Bool) -> Bool {
        let filter = self.effective, tokens = Set(filter.values)
        let states: [(FeedSubscriptionState, String)] = [(.subscribed, "include_subscribed"),
            (.archived, "include_archived"), (.notSubscribed, "include_not_subscribed")]
        let explicit = states.filter { tokens.contains($0.1) }.map(\.0)
        guard (explicit.isEmpty ? [.subscribed] : explicit).contains(subscription) else { return false }
        return includes(filter, episode, queued: queued)
    }

    // MARK: LibraryViewController+EpisodeLists (allEpisodesRows)

    static func allEpisodesRows(_ feeds: [LibraryFeed], queuedEpisodes: [LibraryEpisode], filter: AllEpisodesFilter, sort: EpisodeListSort) -> [Row] {
        let queued = Set(queuedEpisodes.map(\.id))
        let rows = feeds.flatMap { feed in
            feed.episodes.filter { includes(filter, $0, subscription: feed.subscriptionState, queued: queued.contains($0.id)) }.map { (feed: feed, episode: $0) }
        }
        return episodes(rows, filter: filter.effective, sort: sort).map { ($0.feed, $0.episode) }
    }

    // MARK: DownloadsList, LibraryViewController+Downloads (downloadsRows)

    static func order(_ preference: FeedEpisodeSortOrder?) -> FeedEpisodeSortOrder {
        guard let preference, DownloadsList.sortFields.contains(preference.field) else { return .dateNewest }
        return preference
    }
    static func downloads(_ episodes: [LibraryEpisode], jobs: [LibraryDownloadJob],
                          order preference: FeedEpisodeSortOrder? = nil) -> [LibraryEpisode] {
        let completed = episodes.filter { $0.userState.isDownloaded }
        func equal(_ a: String?, _ b: String) -> Bool { a?.utf16.elementsEqual(b.utf16) == true }
        let activeURLs = jobs.filter { $0.state.isActive }.map(\.source).filter { url in
            !completed.contains { equal($0.details.media?.url, url) }
        }
        let active = episodes.filter { episode in activeURLs.contains { equal(episode.details.media?.url, $0) } }.sorted { a, b in
            let left = a.userState.lastPlayedHistoryMilliseconds ?? a.userState.lastPlayedTimeMilliseconds
            let right = b.userState.lastPlayedHistoryMilliseconds ?? b.userState.lastPlayedTimeMilliseconds
            return left == right ? a.id < b.id : left > right
        }
        return active + sorted(order(preference), completed)
    }
    static func downloadsRows(_ feeds: [LibraryFeed], jobs: [LibraryDownloadJob], order: FeedEpisodeSortOrder?) -> [Int64] {
        let active = jobs.filter { $0.state.isActive }.map(\.source)
        let sources = Set(active)
        func activeSource(_ url: String?) -> Bool {
            guard !active.isEmpty, let url, sources.contains(url) else { return false }
            return active.contains { $0.utf16.elementsEqual(url.utf16) }
        }
        let candidates = feeds.flatMap { feed in
            feed.episodes.filter { episode in
                episode.userState.isDownloaded || activeSource(episode.details.media?.url)
            }
        }
        return downloads(candidates, jobs: jobs, order: order).map(\.id)
    }

    // MARK: NavigationCounters.inbox, SubscriptionListQueries.counters

    static func inboxCount(_ feeds: [LibraryFeed]) -> Int {
        feeds.reduce(0) { total, feed in
            feed.subscriptionState == .subscribed ? total + feed.episodes.count { $0.userState.playState == .new } : total
        }
    }
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
}
