import Foundation

/// Source notification content, before localization and platform presentation.
/// count is the total new-episode count after refresh, never the count increase.
public struct NewEpisodeNotification: Equatable, Sendable {
    public let feedID: Int64
    public let title: String?
    public let imageURL: String?
    public let count: Int
}

/// One worker attempt's baseline. Restarting an interrupted attempt obtains a
/// fresh baseline as the original FeedUpdateWorker doesWork does.
public struct NewEpisodeNotificationBaseline: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let counts: [Int64: Int]
    /// Feeds whose notifications were on when the baseline was taken; only they were counted. Nil (older
    /// saved attempts, and explicit baselines) means every subscribed feed was counted. A feed switched on
    /// during the attempt has no baseline count, so it is not notified until the next attempt.
    public let notifyingFeedIDs: Set<Int64>?

    public init(requestID: UUID, counts: [Int64: Int], notifyingFeedIDs: Set<Int64>? = nil) {
        self.requestID = requestID; self.counts = counts; self.notifyingFeedIDs = notifyingFeedIDs
    }

    func counted(_ feedID: Int64) -> Bool { notifyingFeedIDs?.contains(feedID) ?? true }

    public func notification(for feed: LibraryFeed, newCount: Int) -> NewEpisodeNotification? {
        guard feed.keepUpdated, feed.showEpisodeNotification, counted(feed.id),
              newCount > (counts[feed.id] ?? 0) else { return nil }
        return NewEpisodeNotification(feedID: feed.id, title: feed.title, imageURL: feed.metadata.imageURL, count: newCount)
    }
}

/// A committed refresh's outstanding publication. Retains only the source
/// preference/title/image snapshot and its attempt's count, never episode data.
/// A new attempt still gets a fresh baseline after recovering this work.
struct PendingEpisodeNotification: Codable, Equatable, Sendable {
    let id: UUID
    let requestID: UUID
    let feedID: Int64
    let title: String?
    let imageURL: String?
    let beforeCount: Int
    var childPublished: Bool = false

    init(feed: LibraryFeed, baseline: NewEpisodeNotificationBaseline) {
        id = UUID(); requestID = baseline.requestID; feedID = feed.id
        title = feed.title; imageURL = feed.metadata.imageURL
        beforeCount = baseline.counts[feed.id] ?? 0
    }
}
