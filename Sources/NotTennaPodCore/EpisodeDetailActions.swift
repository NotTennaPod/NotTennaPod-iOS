import Foundation

/// ItemFragment.updateButtons owns two independent action slots. Do not use the
/// episode-list row's one-button preference/priority rules for this screen.
public struct EpisodeDetailActions: Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case markRead, visitWebsite, pause, playLocal, play, stream, cancelDownload, delete, download

        public var labelKey: String {
            switch self {
            case .markRead: "mark_read_no_media_label"
            case .visitWebsite: "visit_website_label"
            case .pause: "pause_label"
            case .playLocal, .play: "play_label"
            case .stream: "stream_label"
            case .cancelDownload: "cancel_download_label"
            case .delete: "delete_label"
            case .download: "download_label"
            }
        }
        public var icon: String {
            switch self {
            case .markRead: "ic_check"
            case .visitWebsite: "ic_web"
            case .pause: "ic_pause"
            case .playLocal, .play: "ic_play_24dp"
            case .stream: "ic_stream"
            case .cancelDownload: "ic_cancel"
            case .delete: "ic_delete"
            case .download: "ic_download"
            }
        }
    }
    public struct Button: Equatable, Sendable {
        public let action: Action
        /// Invisible still occupies its half of the action row.
        public let visible: Bool
    }
    public let primary, secondary: Button
    public let downloadProgress: Float?
    public let downloadIndeterminate: Bool

    public init(episode: LibraryEpisode, localFeed: Bool, currentlyPlaying: Bool,
                downloading: Bool, queuedDownload: Bool, downloadPercent: Int) {
        let hasMedia = episode.details.media != nil
        downloadProgress = hasMedia && downloading ? 0.01 * Float(max(1, downloadPercent)) : nil
        downloadIndeterminate = hasMedia && downloading && queuedDownload
        guard hasMedia else {
            primary = Button(action: .markRead, visible: episode.userState.playState != .played)
            // Text-only Visit website uses the episode link, with only a null
            // check. It does not share the toolbar's blank-aware feed fallback.
            secondary = Button(action: .visitWebsite, visible: episode.details.link != nil)
            return
        }
        let downloaded = episode.userState.isDownloaded
        primary = Button(action: currentlyPlaying ? .pause : localFeed ? .playLocal : downloaded ? .play : .stream, visible: true)
        secondary = Button(action: downloading ? .cancelDownload : localFeed || downloaded ? .delete : .download, visible: true)
    }
}
