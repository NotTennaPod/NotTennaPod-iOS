import Foundation

public enum PlayerOverflowAction: String, CaseIterable, Sendable {
    case openPodcast, visitWebsite, transcript, comments
    public var titleKey: String {
        switch self {
        case .openPodcast: "open_podcast"
        case .visitWebsite: "visit_website_label"
        case .transcript: "show_transcript"
        case .comments: "visit_social_interact_label"
        }
    }
    public static func available(episode: LibraryEpisode, feed: LibraryFeed) -> [Self] {
        var actions: [Self] = [.openPodcast]
        if !feed.source.isLocalFeedSource, EpisodeWebsite.link(episode: episode.details.link, feed: feed.metadata.link) != nil { actions.append(.visitWebsite) }
        if episode.details.transcript != nil { actions.append(.transcript) }
        if episode.details.socialInteractionURL != nil { actions.append(.comments) }
        return actions
    }
}
