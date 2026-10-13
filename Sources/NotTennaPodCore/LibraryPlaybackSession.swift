import Foundation

public struct LibraryPlaybackSession: Codable, Equatable, Sendable {
    public enum Status: Int, Codable, Sendable { case playing = 1, paused = 2, other = 3 }
    public let id: UUID
    public let episodeID: Int64
    public let startPositionMilliseconds: Int32
    public let playedDurationWhenStarted: Int64
    public var itemPlayState: EpisodePlayState
    public var status: Status
}

public struct PlaybackSample: Equatable, Sendable {
    public var positionMilliseconds: Int32
    public var durationMilliseconds: Int32
    public var seekable: Bool
    public var status: LibraryPlaybackSession.Status

    public init(positionMilliseconds: Int32, durationMilliseconds: Int32, seekable: Bool = true,
                status: LibraryPlaybackSession.Status) {
        self.positionMilliseconds = positionMilliseconds
        self.durationMilliseconds = durationMilliseconds
        self.seekable = seekable
        self.status = status
    }
}

public struct PlaybackEndPreferences: Equatable, Sendable {
    public var smartMarkAsPlayedSeconds: Int32 = 30
    public var skipKeepsEpisode = true
    public var autoDelete = false
    public var autoDeleteLocal = false
    public var favoriteKeepsEpisode = true
    public var synchronize = false

    public init() {}
}

public enum PlaybackEndReason: Sendable { case ended, skipped, switched }

public struct PlaybackEndResult: Equatable, Sendable {
    public let episode: LibraryEpisode
    public let nextEpisodeID: Int64?
    public let markedPlayed: Bool
    public let removedFromQueue: Bool
}
