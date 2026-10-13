import Foundation

/// Payload requested by the original manual Mark played/unplayed commands.
/// Delivery belongs to the synchronization service, not the episode screen.
public struct EpisodeStateSyncAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case play, new }
    public let kind: Kind
    public let podcast: String
    public let episode: String?
    public let guid: String?
    public let started, position, total: Int32

    public init?(episode: LibraryEpisode, feed: LibraryFeed, played: Bool, providerConnected: Bool) {
        guard providerConnected, !feed.source.isLocalFeedSource,
              feed.subscriptionState != .notSubscribed, let media = episode.details.media else { return nil }
        kind = played ? .play : .new
        podcast = feed.source
        self.episode = media.url
        guid = episode.details.identifier
        let value = played ? media.durationMilliseconds / 1_000 : -1
        started = value
        position = value
        total = value
    }
}
