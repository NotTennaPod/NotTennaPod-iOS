import Foundation

/// One accepted removal index, never an old queue snapshot. In-memory offers
/// belong to the originating store and cannot be replayed after recreation.
public struct EpisodeQueueRemovalReceipt: Equatable, Sendable {
    public let operationID: UUID
    public let episodeID: Int64
    public let index: Int
    let storeEpoch: UUID
    let feedID: Int64
    let source: String
    let identifier: String?
    let mediaURL: String?
}

public struct EpisodeQueueRemoval: Equatable, Sendable {
    public let receipt: EpisodeQueueRemovalReceipt?
    public let change: LibraryQueueChange
}

public struct EpisodeQueueUndoResult: Equatable, Sendable {
    public enum Status: Equatable, Sendable { case restored, alreadyQueued, missing, unavailable }
    public let status: Status
    /// Source no-op duplicate/missing branches still request auto-download.
    /// An unavailable/released/foreign receipt performs no database operation.
    public let change: LibraryQueueChange?
}
