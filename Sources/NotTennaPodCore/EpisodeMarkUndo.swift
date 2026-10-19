import Foundation

/// The shared swipe helper changes state without resetting position or emitting
/// a manual played/unplayed synchronization action. A swipe marks the state it was accepted for (`markPlayed`,
/// `markUnplayed`), whatever the episode's state when the mark is written.
public enum EpisodeSwipeMark: Sendable {
    case removeInbox, togglePlayed, markPlayed, markUnplayed
}

/// A committed state delta, not a saved episode to write back during Undo.
/// Receipts are deliberately not Codable: an offer belongs to one live store.
public struct EpisodeMarkReceipt: Equatable, Sendable {
    public let operationID: UUID
    public let episodeID: Int64
    public let feedID: Int64
    public let previousState: EpisodePlayState
    public let appliedState: EpisodePlayState
    let storeEpoch: UUID
}

public enum EpisodeMarkUndoResult: Equatable, Sendable {
    case restored
    /// A subsequent state intent, replacement, release or Undo owns this row.
    case superseded
    /// The episode or the originating store instance no longer exists here.
    case unavailable
}
