import Foundation

/// One accepted "Remove from history" (`RemoveFromHistorySwipeAction`): the episode's original history
/// date, kept only for this store instance's Undo offer. Like the queue receipt, it cannot be replayed
/// after the store is recreated.
public struct EpisodeHistoryRemovalReceipt: Equatable, Sendable {
    public let operationID: UUID
    public let episodeID: Int64
    /// `FeedMedia.playback_completion_date` before the removal, in milliseconds.
    public let originalMilliseconds: Int64
    let storeEpoch: UUID
    let mediaURL: String?
}

public struct EpisodeHistoryUndoResult: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// The original date is written back, so the row returns to its old place.
        case restored
        /// The episode no longer exists.
        case missing
        /// The offer was released, already used, belongs to another store, or the media was replaced.
        case unavailable
    }
    public let status: Status
}
