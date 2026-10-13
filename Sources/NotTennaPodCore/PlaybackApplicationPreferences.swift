import Foundation

/// The application's live playback binding. Account/subscription/local-feed
/// eligibility remains transactional in the library's synchronization outbox.
public enum PlaybackApplicationPreferences {
    public static func resolve(download: DownloadPreferences, queue: PlaybackQueuePreferences) -> PlaybackPreferences {
        var value = PlaybackPreferences()
        value.end = download.playbackEnd
        value.end.synchronize = true
        value.end.skipKeepsEpisode = queue.skipKeepsEpisode
        value.followQueue = queue.followQueue
        value.enqueueLocation = download.enqueueLocation
        return value
    }
}
