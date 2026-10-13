import Foundation

/// The original FeedItem priority for known artwork facts. Empty explicit image
/// strings are still explicit values; loading failures belong to the renderer.
public enum EpisodeArtworkSelection {
    public static let embeddedPrefix = "metadata-retriever:"

    public static func source(episodeImage: String?, hasEmbeddedPicture: Bool,
                              localMedia: String?, feedImage: String?) -> String? {
        if let episodeImage { return episodeImage }
        if hasEmbeddedPicture { return embeddedPrefix + (localMedia ?? "null") }
        return feedImage
    }

    public static func source(episode: LibraryEpisode, feed: LibraryFeed?) -> String? {
        let localMedia = feed?.source.isLocalFeedSource == true
            ? episode.details.media?.url : episode.userState.localFileURL
        let inspectUnknown = episode.details.media?.hasEmbeddedPicture == nil && localMedia != nil
            && (feed?.source.isLocalFeedSource == true || episode.userState.isDownloaded)
        return source(episodeImage: episode.details.imageURL,
                      hasEmbeddedPicture: episode.details.media?.hasEmbeddedPicture == true || inspectUnknown,
                      localMedia: localMedia, feedImage: feed?.metadata.imageURL)
    }

    /// "Use episode cover" (`ImageResourceUtils` and its call sites): the image a surface loads
    /// first and the one it loads when that fails. Surfaces that follow the setting show the podcast image when it
    /// is off; the others always prefer the episode's own image.
    public static func cover(for surface: EpisodeCoverSurface, own: String?, feedImage: String?,
                             useEpisodeCover: Bool) -> (primary: String?, fallback: String?) {
        (surface.followsEpisodeCoverSetting && !useEpisodeCover ? feedImage : own, feedImage)
    }

    public static func cover(for surface: EpisodeCoverSurface, episode: LibraryEpisode, feed: LibraryFeed?,
                             useEpisodeCover: Bool) -> (primary: String?, fallback: String?) {
        cover(for: surface, own: source(episode: episode, feed: feed), feedImage: feed?.metadata.imageURL, useEpisodeCover: useEpisodeCover)
    }
}

/// Where an episode cover is shown.
public enum EpisodeCoverSurface: String, CaseIterable, Sendable {
    /// `EpisodeItemViewHolder`: Queue, Inbox, Episodes, Downloads, History, Favorites, Search, Home lists.
    case episodeList
    /// `HorizontalItemViewHolder`: Home's Continue listening and Surprise cards.
    case homeEpisodeCard
    /// `ExternalPlayerFragment`.
    case miniPlayer
    /// `FeedItemlistFragment`: a podcast's own episode list ignores the setting.
    case feedEpisodeList
    /// `CoverFragment`: the full player cover.
    case playerCover
    /// `ItemFragment`.
    case episodeDetails

    public var followsEpisodeCoverSetting: Bool {
        switch self { case .episodeList, .homeEpisodeCard, .miniPlayer: true; case .feedEpisodeList, .playerCover, .episodeDetails: false }
    }
}
