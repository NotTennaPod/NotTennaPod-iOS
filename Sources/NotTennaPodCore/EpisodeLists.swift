import Foundation

/// Order and membership of the Inbox, Episodes (All episodes), Favorites and Playback history lists.
/// Each screen sorts on one column (`FeedItemSortQuery`); equal keys keep the order SQLite's plan yields,
/// reproduced here.
public enum EpisodeListSort: Int, Codable, CaseIterable, Sendable {
    case dateOldest = 1, dateNewest = 2, durationShortest = 5, durationLongest = 6

    /// Source default `DATE_NEW_OLD` (`UserPreferences`); unknown stored codes also fall back to it,
    /// where Android shows an empty list and crashes on Sort (not copied).
    public static let standard = Self.dateNewest
    public static func stored(_ code: Int?) -> Self { code.flatMap(Self.init(rawValue:)) ?? .standard }

    /// `ItemSortDialog` rows kept by the Inbox and Episodes dialogs, in grid order.
    public enum Row: String, CaseIterable, Sendable {
        case duration, date
        public var titleKey: String { rawValue }
        /// Tapping an inactive row selects its default direction.
        public var defaultOrder: EpisodeListSort { self == .duration ? .durationShortest : .dateNewest }
    }
    public var row: Row { self == .dateOldest || self == .dateNewest ? .date : .duration }
    public var ascending: Bool { self == .dateOldest || self == .durationShortest }
    /// Tapping the active row flips its direction; an inactive row selects its default.
    public func selecting(_ row: Row) -> Self {
        guard row == self.row else { return row.defaultOrder }
        switch self {
        case .dateOldest: return .dateNewest
        case .dateNewest: return .dateOldest
        case .durationShortest: return .durationLongest
        case .durationLongest: return .durationShortest
        }
    }
}

public struct EpisodeListPreferences: Codable, Equatable, Sendable {
    /// `prefInboxSortedOrder` and `prefEpisodesSort` (Favorites follows the Episodes sort).
    public var inboxSort: Int?
    public var episodesSort: Int?
    /// `PrefNewEpisodesFragment.prefDoNotPromptRemovalAllFromInbox`.
    public var doNotPromptRemoveAllFromInbox = false
    public init() {}
    public var inbox: EpisodeListSort { .stored(inboxSort) }
    public var episodes: EpisodeListSort { .stored(episodesSort) }
}

@MainActor public final class EpisodeListPreferenceStore {
    public private(set) var value: EpisodeListPreferences
    private let file: URL
    /// Damaged content starts from the defaults, as always; a file that cannot be read now (before the first unlock) is
    /// thrown, so its defaults never replace the saved sorts at the next change.
    public init(file: URL) throws {
        self.file = file
        value = try SavedState.contents(of: file)
            .map { (try? JSONDecoder().decode(EpisodeListPreferences.self, from: $0)) ?? .init() } ?? .init()
    }
    public func update(_ change: (inout EpisodeListPreferences) -> Void) throws {
        var next = value; change(&next)
        guard next != value else { return }
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        value = next
    }
}

public enum EpisodeListQueries {
    public typealias Row = (feed: LibraryFeed, episode: LibraryEpisode)

    /// NEW episodes of subscribed feeds; equal keys by episode id.
    public static func inbox(_ feeds: [LibraryFeed], sort: EpisodeListSort) -> [Row] {
        let subscribed = feeds.filter { $0.subscriptionState == .subscribed }
        let members = rows(subscribed) { $0.userState.playState == .new }
        return sorted(members, sort, tie: byEpisodeID)
    }

    /// Favorites of every feed state, in the Episodes sort; equal keys by episode id.
    public static func favorites(_ feeds: [LibraryFeed], sort: EpisodeListSort) -> [Row] {
        let members = rows(feeds) { $0.userState.isFavorite }
        return sorted(members, sort, tie: byEpisodeID)
    }

    /// Episodes with a completion date (`playback_completion_date > 0`, media only), newest completion
    /// first, every feed state. Equal dates by media id, which is the episode id in this library.
    public static func history(_ feeds: [LibraryFeed]) -> [Row] {
        rows(feeds) { ($0.userState.lastPlayedHistoryMilliseconds ?? 0) > 0 && $0.details.media != nil }.sorted { a, b in
            let left = a.episode.userState.lastPlayedHistoryMilliseconds ?? 0, right = b.episode.userState.lastPlayedHistoryMilliseconds ?? 0
            return left == right ? a.episode.id < b.episode.id : left > right
        }
    }

    /// Already-filtered Episodes rows in the Episodes sort. Equal keys follow AntennaPod's query plan: by feed id,
    /// then episode id, unless the filter uses `played`, `queued` or `is_favorite` (then by episode id).
    public static func episodes(_ rows: [Row], filter: FeedEpisodeFilter, sort: EpisodeListSort) -> [Row] {
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
}
