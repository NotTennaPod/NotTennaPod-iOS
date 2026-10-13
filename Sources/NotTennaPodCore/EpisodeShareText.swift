import Foundation

public enum EpisodeShareText {
    public static func social(feed: LibraryFeed, episode: LibraryEpisode, withPosition: Bool, abbreviated: Bool,
                              startingPosition: String = "Starting position", website: String = "Episode website",
                              mediaFile: String = "Media file") -> String {
        func shorten(_ value: String) -> String {
            guard abbreviated, value.utf16.count > 50 else { return value }
            return String(decoding: value.utf16.prefix(50), as: UTF16.self) + "…"
        }
        var text = (feed.title ?? "null") + ": " + shorten(episode.details.title ?? "null")
        let position = episode.userState.positionMilliseconds
        if episode.details.media != nil && withPosition {
            let seconds = max(0, position) / 1_000
            text += "\n\(startingPosition): " + String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        if let link = EpisodeWebsite.link(episode: episode.details.link, feed: feed.metadata.link) {
            text += (abbreviated ? "\n" : "\n\n") + website + ": " + shorten(link)
        }
        if let url = episode.details.media?.url {
            text += (abbreviated ? "\n" : "\n\n") + mediaFile + ": " + shorten(url)
            if withPosition { text += "#t=\(position / 1_000)" }
        }
        return text
    }
}
