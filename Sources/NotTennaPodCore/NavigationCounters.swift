import Foundation

/// Drawer and bottom-navigation counters. Source: `DBReader.getNavDrawerData` (:719-721),
/// `NavListAdapter.bindNavView` (:180-213), `NavDrawerFragment.getFeedCounterSum` (:342-351) and
/// `BottomNavigation.updateBottomNavigationBadgeIfNeeded` (:66-85).
public struct NavigationCounters: Equatable, Sendable {
    /// Queue row: `PodDBAdapter.getQueueSize` (`COUNT(Queue.id)`).
    public var queue: Int
    /// Inbox row and the bottom-navigation Inbox badge: `getTotalEpisodeCount(new FeedItemFilter(NEW))`.
    /// A filter without a feed-state property keeps subscribed feeds only (FeedItemFilterQuery:71-89),
    /// so NEW episodes of archived and not-subscribed (preview) feeds never count.
    public var inbox: Int
    /// Subscriptions row: the sum of every subscribed feed's counter under the counter setting,
    /// whatever the Subscriptions filter hides.
    public var subscriptions: Int

    public init(feeds: [LibraryFeed], queueLength: Int, counter: FeedCounter) {
        self.init(feeds: feeds, queueLength: queueLength, feedCounters: SubscriptionListQueries.counters(feeds, counter))
    }
    /// With the per-feed counters already read for the same setting (the drawer's subscription list).
    public init(feeds: [LibraryFeed], queueLength: Int, feedCounters: [Int64: Int]) {
        queue = queueLength
        inbox = Self.inbox(feeds)
        subscriptions = feedCounters.values.reduce(0, +)
    }
    /// With the Inbox count and per-feed counters already known (the screens keep them as counts).
    public init(queueLength: Int, inbox: Int, feedCounters: [Int64: Int]) {
        queue = queueLength
        self.inbox = inbox
        subscriptions = feedCounters.values.reduce(0, +)
    }
    public static func inbox(_ feeds: [LibraryFeed]) -> Int {
        feeds.reduce(0) { total, feed in
            feed.subscriptionState == .subscribed ? total + feed.episodes.count { $0.userState.playState == .new } : total
        }
    }

    /// The badge number: Material `BadgeDrawable` shows the count up to `maxNumber` 999
    /// (Widget.MaterialComponents.Badge, `m3_badge_max_number`), then "999+"; nothing at 0.
    public static let badgeMaximum = 999
    public static func badgeText(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > badgeMaximum ? "\(badgeMaximum.formatted())+" : count.formatted()
    }
}
