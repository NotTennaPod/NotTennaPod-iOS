import Foundation

/// `FeedOrder`: stored as `prefDrawerFeedOrder` strings "0"…"3".
public enum FeedOrder: Int, Sendable, CaseIterable {
    case counter = 0, alphabetical = 1, mostRecentEpisode = 2, mostPlayed = 3
    /// `FeedOrder.fromOrdinal`: an unknown number is MOST_RECENT_EPISODE. A non-numeric value
    /// crashes the source; it falls back to the default instead.
    public init(stored: String) {
        guard let value = Int32(stored) else { self = .counter; return }
        self = Self(rawValue: Int(value)) ?? .mostRecentEpisode
    }
    public var stored: String { String(rawValue) }
    /// FeedSortDialog rows (`nav_drawer_feed_order_values`).
    public static let dialogOrder: [Self] = [.counter, .alphabetical, .mostRecentEpisode, .mostPlayed]
    public var titleKey: String {
        switch self {
        case .counter: "drawer_feed_order_unplayed_episodes"
        case .alphabetical: "drawer_feed_order_alphabetical"
        case .mostRecentEpisode: "drawer_feed_order_last_update"
        case .mostPlayed: "drawer_feed_order_most_played"
        }
    }
}

/// `FeedCounter`: stored as `prefDrawerFeedIndicator` strings.
public enum FeedCounter: Int, Sendable, CaseIterable {
    case showNew = 1, showUnplayed = 2, showNone = 3, showDownloaded = 4, showDownloadedUnplayed = 5
    /// `FeedCounter.fromOrdinal`: an unknown number is SHOW_NONE; a non-numeric value falls back to
    /// the default instead of crashing.
    public init(stored: String) {
        guard let value = Int32(stored) else { self = .showNew; return }
        self = Self(rawValue: Int(value)) ?? .showNone
    }
    public var stored: String { String(rawValue) }
    public static let dialogOrder: [Self] = [.showNew, .showUnplayed, .showDownloaded, .showDownloadedUnplayed, .showNone]
    public var titleKey: String {
        switch self {
        case .showNew: "drawer_feed_counter_inbox"
        case .showUnplayed: "drawer_feed_counter_unplayed"
        case .showDownloaded: "drawer_feed_counter_downloaded"
        case .showDownloadedUnplayed: "drawer_feed_counter_downloaded_unplayed"
        case .showNone: "drawer_feed_counter_none"
        }
    }
    /// `PodDBAdapter.getFeedCounters` predicates over an item (LEFT JOIN media).
    func counts(_ episode: LibraryEpisode) -> Bool {
        let unplayed = episode.userState.playState != .played
        let downloaded = episode.details.media != nil && episode.userState.isDownloaded
        switch self {
        case .showNew: return episode.userState.playState == .new
        case .showUnplayed: return unplayed
        case .showDownloaded: return downloaded
        case .showDownloadedUnplayed: return unplayed && downloaded
        case .showNone: return false
        }
    }
}

/// `SubscriptionsFilter`: comma-separated tokens; enabled when any token is present.
public struct SubscriptionsFilter: Equatable, Sendable {
    public static let counterGreaterZero = "counter_greater_zero"
    /// SubscriptionsFilterGroup rows, in order, with their button labels.
    public static let rows: [[(token: String, titleKey: String)]] = [
        [("counter_greater_zero", "subscriptions_counter_greater_zero")],
        [("enabled_auto_download", "auto_downloaded"), ("disabled_auto_download", "not_auto_downloaded")],
        [("enabled_updates", "kept_updated"), ("disabled_updates", "not_kept_updated")],
        [("episode_notification_enabled", "new_episode_notification_enabled"),
         ("episode_notification_disabled", "new_episode_notification_disabled")],
    ]
    public let tokens: [String]
    public init(stored: String) { tokens = TextUtils.split(stored) }
    public var isEnabled: Bool { !tokens.isEmpty }
    public func contains(_ token: String) -> Bool { tokens.contains(token) }

    /// The string SubscriptionsFilterDialog saves: a `HashSet` built in row order, joined with ",".
    public static func serialized(_ selection: Set<String>) -> String {
        var set = FeedTagOrder.Builder(capacity: 16)
        for row in rows { for button in row where selection.contains(button.token) { set.insert(button.token) } }
        return set.values.joined(separator: ",")
    }

    /// `SubscriptionsFilterExecutor.filter`: the first failing rule removes a feed, then the counter rule.
    public func apply(_ feeds: [LibraryFeed], counters: [Int64: Int], globalAutoDownload: Bool) -> [LibraryFeed] {
        guard isEnabled else { return feeds }
        let kept = feeds.filter { feed in
            let autoDownload = feed.autoDownload == .enabled || (feed.autoDownload == .global && globalAutoDownload)
            if contains("enabled_auto_download") && !autoDownload { return false }
            if contains("disabled_auto_download") && autoDownload { return false }
            if contains("enabled_updates") && !feed.keepUpdated { return false }
            if contains("disabled_updates") && feed.keepUpdated { return false }
            if contains("episode_notification_enabled") && !feed.showEpisodeNotification { return false }
            if contains("episode_notification_disabled") && feed.showEpisodeNotification { return false }
            if !contains("show_non_subscribed") && feed.subscriptionState == .notSubscribed { return false }
            return true
        }
        return contains(Self.counterGreaterZero) ? kept.filter { counters[$0.id, default: 0] > 0 } : kept
    }
}

/// Subscriptions/Archive/drawer preferences in their Android string forms.
public struct SubscriptionDisplayPreferences: Codable, Equatable, Sendable {
    /// `prefDrawerFeedOrder`
    public var feedOrder = "0"
    /// `prefDrawerFeedIndicator`
    public var feedCounter = "1"
    /// `prefSubscriptionsFilter`
    public var subscriptionsFilter = ""
    /// `prefSubscriptionTitle`
    public var showTitle = false
    /// `SubscriptionFragment/columns` (1 = List); nil until the first visit writes the device default.
    public var columns: Int?
    /// `NavDrawerPrefs/prefOpenFolders`
    public var openFolders: [String] = []
    /// `SubscriptionFragment/last_tag`: the Subscriptions screen's selected tag chip.
    public var lastTag = FeedTags.root
    public init() {}

    public var order: FeedOrder { FeedOrder(stored: feedOrder) }
    public var counter: FeedCounter { FeedCounter(stored: feedCounter) }
    public var filter: SubscriptionsFilter { SubscriptionsFilter(stored: subscriptionsFilter) }
    /// `integers.xml` `subscriptions_default_num_of_columns`: 5 at sw600dp, else 3.
    public static func defaultColumns(smallestWidth: Double) -> Int { smallestWidth >= 600 ? 5 : 3 }

    private enum CodingKeys: String, CodingKey { case feedOrder, feedCounter, subscriptionsFilter, showTitle, columns, openFolders, lastTag }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        feedOrder = try values.decodeIfPresent(String.self, forKey: .feedOrder) ?? "0"
        feedCounter = try values.decodeIfPresent(String.self, forKey: .feedCounter) ?? "1"
        subscriptionsFilter = try values.decodeIfPresent(String.self, forKey: .subscriptionsFilter) ?? ""
        showTitle = try values.decodeIfPresent(Bool.self, forKey: .showTitle) ?? false
        columns = try values.decodeIfPresent(Int.self, forKey: .columns)
        openFolders = try values.decodeIfPresent([String].self, forKey: .openFolders) ?? []
        lastTag = try values.decodeIfPresent(String.self, forKey: .lastTag) ?? FeedTags.root
    }
}

@MainActor public final class SubscriptionDisplayPreferenceStore {
    public private(set) var value: SubscriptionDisplayPreferences
    private let file: URL
    /// Damaged content starts from the defaults, as always; a file that cannot be read now (before the first unlock) is
    /// thrown, so its defaults never replace the saved choices at the next change.
    public init(file: URL) throws {
        self.file = file
        value = try SavedState.contents(of: file)
            .map { (try? JSONDecoder().decode(SubscriptionDisplayPreferences.self, from: $0)) ?? .init() } ?? .init()
    }
    public func update(_ next: SubscriptionDisplayPreferences) throws {
        guard next != value else { return }
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        value = next
    }
}
