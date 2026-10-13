import Foundation
import Synchronization

public struct DownloadPreferences: Codable, Equatable, Sendable {
    public var allowMobile = false
    public var enqueue = true
    public var deleteRemovesFromQueue = false
    public var enqueueLocation: EnqueueLocation = .back
    public var listSortOrder: FeedEpisodeSortOrder?
    public var buttonActionPlay: Bool?
    public var swipe: DownloadsSwipePreferences?
    public var autoDelete: Bool?
    public var autoDeleteLocal: Bool?
    public var favoriteKeepsEpisode: Bool?
    public var smartMarkAsPlayedSeconds: Int32?
    public var newEpisodesAction: NewEpisodesAction?
    public var refreshIntervalMinutes: Int?

    public var playbackEnd: PlaybackEndPreferences {
        var value = PlaybackEndPreferences()
        value.autoDelete = autoDelete ?? false; value.autoDeleteLocal = autoDeleteLocal ?? false
        value.favoriteKeepsEpisode = favoriteKeepsEpisode ?? true
        value.smartMarkAsPlayedSeconds = smartMarkAsPlayedSeconds ?? 30
        return value
    }
    public func deletesAfterMark(_ item: EpisodeListItem) -> Bool {
        guard autoDelete == true, !item.local || autoDeleteLocal == true,
              let media = item.episode.details.media, media.durationMilliseconds > 0 else { return false }
        return Int64(item.episode.userState.positionMilliseconds) >= Int64(media.durationMilliseconds)
            - Int64(smartMarkAsPlayedSeconds ?? 30) * 1_000
    }

    public init() {}
}
