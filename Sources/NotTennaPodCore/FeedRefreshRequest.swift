import Foundation

/// Durable counterpart of the single WorkManager feedUpdateManual slot.
/// Nil feedID means all eligible subscriptions. Individual refresh is forced,
/// even for archived/keep-updated-disabled feeds; all-feeds refresh is not.
public struct FeedRefreshRequest: Equatable, Codable, Sendable {
    public let id: UUID
    public let feedID: Int64?
    public let nextPage: Bool
    public let requiresNetwork: Bool
    public let enqueuedAt: Date
    /// Nil preserves decoding of the original manual journal. Scheduled work
    /// occupies its own slot and never participates in manual admission/cooldown.
    public let periodic: PeriodicFeedRefreshSchedule?
    var slot: Int64 { periodic == nil ? 1 : 2 }
    var networkConstraint: DownloadNetworkConstraint {
        periodic?.allowMobile == false ? .unmetered : .connected
    }
    public var force: Bool { feedID != nil }

    public init(id: UUID = UUID(), feedID: Int64?, nextPage: Bool = false,
                isLocalFeed: Bool = false, enqueuedAt: Date) {
        self.id = id; self.feedID = feedID
        self.nextPage = feedID != nil && nextPage
        requiresNetwork = feedID == nil || !isLocalFeed
        self.enqueuedAt = enqueuedAt
        periodic = nil
    }
    init(periodic: PeriodicFeedRefreshSchedule, enqueuedAt: Date) {
        id = UUID(); feedID = nil; nextPage = false; requiresNetwork = true
        self.enqueuedAt = enqueuedAt; self.periodic = periodic
    }
    /// Source shuffles this eligible set before execution. Selection remains
    /// separate from scheduling order, which the worker will provide.
    public func eligibleFeeds(from feeds: [LibraryFeed], now: Date = Date()) -> [LibraryFeed] {
        if let feedID { return feeds.filter { $0.id == feedID } }
        return feeds.filter {
            guard $0.subscriptionState == .subscribed && $0.keepUpdated else { return false }
            guard let periodic else { return true }
            return ($0.lastRefreshAttempt ?? Date(timeIntervalSince1970: 0)) <=
                now.addingTimeInterval(-Double(periodic.intervalMinutes) * 60 - 900)
        }
    }
}

/// FeedUpdateManagerImpl.runOnceOrAsk admission only. A direct runOnce request
/// (such as Edit URL) bypasses this prompt/cooldown path entirely.
public enum ManualFeedRefreshAdmission: Equatable, Sendable {
    case run, cooldown, offline, askMobile(vpnOverWiFi: Bool)

    public init(feedID: Int64?, isLocalFeed: Bool, nowMilliseconds: Int64,
                lastManualMilliseconds: Int64 = 0, lastManualFeedID: Int64? = nil,
                connected: Bool, refreshAllowed: Bool, restricted: Bool, vpnOverWiFi: Bool) {
        // Java long subtraction wraps. Retain source boundary decisions for
        // backward wall-clock jumps instead of treating time as a tick count.
        if nowMilliseconds &- lastManualMilliseconds < 20_000 && feedID == lastManualFeedID {
            self = .cooldown
        } else if feedID != nil && isLocalFeed { self = .run }
        else if !connected { self = .offline }
        else if refreshAllowed { self = .run }
        else { self = .askMobile(vpnOverWiFi: restricted && vpnOverWiFi) }
    }
}
