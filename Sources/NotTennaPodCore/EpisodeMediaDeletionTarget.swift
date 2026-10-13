import Foundation

/// Destructive identity captured with the action, never a fresh row selected by
/// ID at timer fire. The deletion owner must validate this at its own admission.
public struct EpisodeMediaDeletionTarget: Equatable, Sendable {
    public enum Media: Equatable, Sendable {
        /// Keep the original stored strings, including nil and Unicode spelling.
        case remote(mediaURL: String?, originalFile: String?)
        case local(LocalDocumentReference)
    }
    public let episodeID: Int64
    public let feedID: Int64
    public let source: String
    public let media: Media

    public init(episodeID: Int64, feedID: Int64, source: String, media: Media) {
        self.episodeID = episodeID; self.feedID = feedID; self.source = source; self.media = media
    }
}

public enum EpisodeMediaDeletionOutcome: Equatable, Sendable { case deleted, stale }

