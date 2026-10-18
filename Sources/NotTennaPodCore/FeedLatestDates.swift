import Foundation

/// Each shown podcast's newest episode date, for the "most recent episode" order of Subscriptions and the drawer
/// (`SubscriptionListQueries.sort`: the largest publication date in milliseconds, a missing date counting as 0, and 0 for a
/// podcast without episodes), kept from patches: a changed episode only compares its date with the podcast's newest, and
/// only the newest leaving makes the podcast look at its episodes again (feed-proportional, rare).
public struct FeedLatestDates: Sendable {
    private var latest: [Int64: (value: Int64, count: Int)] = [:]
    /// Episodes looked at by patches and by recounts.
    public var visited = 0

    public init() {}

    public init(_ mirror: LibraryScreenMirror) {
        for feed in mirror.feeds { recount(feed) }
    }

    static func value(_ episode: LibraryEpisode) -> Int64 {
        episode.details.publicationDate.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? 0
    }

    /// The newest date of `feed` (0 without episodes).
    public subscript(feed: Int64) -> Int64 { latest[feed]?.value ?? 0 }

    /// Every shown podcast's newest date.
    public var values: [Int64: Int64] { latest.mapValues(\.value) }

    private mutating func recount(_ feed: LibraryFeed) {
        visited += feed.episodes.count
        guard !feed.episodes.isEmpty else { latest[feed.id] = nil; return }
        var best = Int64.min, count = 0
        for episode in feed.episodes {
            let value = Self.value(episode)
            if value > best { best = value; count = 1 } else if value == best { count += 1 }
        }
        latest[feed.id] = (best, count)
    }

    public mutating func apply(_ delta: LibraryMirrorDelta, mirror: LibraryScreenMirror) {
#if DEBUG
        if otherScreenFaults.contains(.latestNotPatched) { return }
#endif
        var stale: Set<Int64> = delta.feedStates
        // Each podcast's dates as a multiset with its maximum and the maximum's multiplicity: the new values join first, so
        // an episode whose date did not change (a played mark, a position) never empties the maximum.
        for (_, change) in delta.episodes {
            visited += 1
            guard let new = change.new, !stale.contains(new.feed.id) else { continue }
            if let old = change.old, old.feed.id == new.feed.id, Self.value(old.episode) == Self.value(new.episode) { continue }
            let value = Self.value(new.episode)
            if let current = latest[new.feed.id] {
                if value > current.value { latest[new.feed.id] = (value, 1) }
                else if value == current.value { latest[new.feed.id] = (value, current.count + 1) }
            } else { latest[new.feed.id] = (value, 1) }
        }
        for (_, change) in delta.episodes {
            guard let old = change.old, !stale.contains(old.feed.id), let current = latest[old.feed.id] else { continue }
            if let new = change.new, old.feed.id == new.feed.id, Self.value(old.episode) == Self.value(new.episode) { continue }
            guard Self.value(old.episode) == current.value else { continue }
            if current.count > 1 { latest[old.feed.id] = (current.value, current.count - 1) } else { stale.insert(old.feed.id) }
        }
        for id in stale {
            if let feed = mirror.feed(id) { recount(feed) } else { latest[id] = nil }
        }
    }
}

extension LibraryScreenMirror {
    /// Played episodes per subscribed podcast (above zero), from the counts (`SubscriptionListQueries.sort`'s most played).
    public var playedCounts: [Int64: Int] {
        var result: [Int64: Int] = [:]
        for feed in feeds where feed.subscriptionState == .subscribed {
            let value = Int(counts[feed.id]?.played ?? 0)
            if value > 0 { result[feed.id] = value }
        }
        return result
    }

    /// `SubscriptionListQueries.load` over the screens' library, with the per-podcast values it sorts and filters by taken
    /// from the counts and `latest` instead of a scan of every episode.
    public func subscriptionList(preferences: SubscriptionDisplayPreferences, state: FeedSubscriptionState,
                                 globalAutoDownload: Bool, latest: FeedLatestDates) -> SubscriptionListQueries.Result {
        let order = preferences.order
        return SubscriptionListQueries.load(feeds, counters: counters(preferences.counter),
            played: order == .mostPlayed ? playedCounts : [:], latest: order == .mostRecentEpisode ? latest.values : [:],
            preferences: preferences, state: state, globalAutoDownload: globalAutoDownload)
    }
}
