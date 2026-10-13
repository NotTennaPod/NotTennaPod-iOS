import Foundation

/// Source `HomeFragment` sections (`arrays.xml:249–255` default order).
public enum HomeSection: String, CaseIterable, Sendable {
    case queue = "QueueSection", inbox = "InboxSection", surprise = "EpisodesSurpriseSection"
    case classics = "SubscriptionsSection", downloads = "DownloadsSection"

    public var titleKey: String {
        switch self {
        case .queue: "home_continue_title"
        case .inbox: "home_new_title"
        case .surprise: "home_surprise_title"
        case .classics: "home_classics_title"
        case .downloads: "home_downloads_title"
        }
    }
}

/// `HomePreferences` (`PrefHomeFragment`): two comma-joined tag strings, default "".
public struct HomeSectionPreferences: Codable, Equatable, Sendable {
    /// `PrefHomeSectionsString`: hidden tags.
    public var hidden: String = ""
    /// `PrefHomeSectionOrder`: ordered tags.
    public var order: String = ""
    public init(hidden: String = "", order: String = "") { self.hidden = hidden; self.order = order }

    /// `getSortedSectionTags`: stable sort of the known tags by their index in `order` (absent →
    /// after the listed ones, in default order), then remove hidden. Unknown tags never appear.
    public var sections: [HomeSection] {
        let order = TextUtils.split(self.order), hidden = Set(TextUtils.split(self.hidden))
        return HomeSection.allCases.enumerated().sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs.element.rawValue) ?? .max, right = order.firstIndex(of: rhs.element.rawValue) ?? .max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element).filter { !hidden.contains($0.rawValue) }
    }

    /// The Configure dialog's rows: shown sections in order, then the stored hidden list (known tags;
    /// decision: unknown stored tags are kept in storage but not shown as blank rows).
    public var dialogHidden: [HomeSection] { TextUtils.split(hidden).compactMap(HomeSection.init(rawValue:)) }

    /// Dialog OK: order = every section in dialog order (shown, then hidden); hidden = those after "Hidden".
    public static func confirmed(shown: [HomeSection], hidden: [HomeSection]) -> Self {
        .init(hidden: hidden.map(\.rawValue).joined(separator: ","), order: (shown + hidden).map(\.rawValue).joined(separator: ","))
    }
}

@MainActor public final class HomeSectionPreferenceStore {
    public private(set) var value: HomeSectionPreferences
    private let file: URL
    public init(file: URL) throws {
        self.file = file
        // Damaged content starts from the defaults, as always; a file that cannot be read now is not replaced.
        value = try SavedState.contents(of: file).map { (try? JSONDecoder().decode(HomeSectionPreferences.self, from: $0)) ?? .init() }
            ?? .init()
    }
    public func update(_ next: HomeSectionPreferences) throws {
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        value = next
    }
}

/// The five source queries.
public enum HomeSectionQueries {
    /// `getPausedQueue(8)` (PDA:1087–1101): the queue with resumed items (position ≥ 1 s, or played in
    /// the last 30 s) first by last played time, then queue order; any feed state.
    public static func continueListening(queue: [LibraryEpisode], now: Int64, limit: Int = 8) -> [LibraryEpisode] {
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
    public static func inbox(_ feeds: [LibraryFeed], sort: EpisodeListSort = .standard, limit: Int = 2) -> (items: [(LibraryFeed, LibraryEpisode)], total: Int) {
        let all = EpisodeListQueries.inbox(feeds, sort: sort)
        return (all.prefix(limit).map { ($0.feed, $0.episode) }, all.count)
    }

    /// Badge text: "99+" at 100 or more (`InboxSection.java:131–136`).
    public static func badge(_ total: Int) -> String { total >= 100 ? "99+" : "\(total)" }

    /// `getRandomEpisodes(8, seed)` (PDA:1146–1167): unplayed/new, published within 356·2 days (source
    /// value), never played or played in the last hour, subscribed, with media; one per feed (the
    /// member with the largest `(id·seed) % 46471`), ordered by `(id·wrap32(seed·3)) % 46471` desc.
    public static func surprise(_ feeds: [LibraryFeed], seed: Int32, now: Int64, limit: Int = 8) -> [(LibraryFeed, LibraryEpisode)] {
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
    public static func classics(_ feeds: [LibraryFeed], units: [Int64: [LibraryStatisticsUnit]] = [:], includeMarkedAsPlayed: Bool,
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
    public static func showsWelcome(_ feeds: [LibraryFeed]) -> Bool {
        !feeds.contains { $0.subscriptionState == .subscribed && !$0.episodes.isEmpty }
    }
}
