import Foundation

/// A successful state mutation, not a replacement database snapshot. Apply only
/// after persistence (or guarded Undo) commits; progress and other fields survive.
public struct EpisodeActionStateDelta: Equatable, Sendable {
    public let playState: EpisodePlayState
    public let resetPosition: Bool

    public init(playState: EpisodePlayState, resetPosition: Bool = false) {
        self.playState = playState
        self.resetPosition = resetPosition
    }

    public func apply(to episode: inout LibraryEpisode) {
        episode.userState.playState = playState
        if resetPosition { episode.userState.positionMilliseconds = 0 }
    }
}

/// One presentation's captured data model. Redrawing a row retains this object;
/// accepting a newly loaded result creates a different object, even for the same
/// episode ID. Timers can retain a detached object without retaining its view.
@MainActor public final class EpisodeActionModel {
    public let identity = UUID()
    public var episodeID: Int64 { item.episode.id }
    private var item: EpisodeListItem

    public init(item: EpisodeListItem) { self.item = item }
    public func snapshot() -> EpisodeListItem { item }

    public func applyCommittedState(_ delta: EpisodeActionStateDelta) {
        var episode = item.episode
        delta.apply(to: &episode)
        replaceEpisode(episode)
    }

    /// The presentation owner must deliver only accepted playback events for its
    /// currently bound matching model. A paint or fresh lookup is not an event.
    public func receivePlaybackPosition(positionMilliseconds: Int32, durationMilliseconds: Int32) {
        guard item.episode.details.media != nil else { return }
        var episode = item.episode
        episode.userState.positionMilliseconds = positionMilliseconds
        episode.details.media?.durationMilliseconds = durationMilliseconds
        replaceEpisode(episode)
    }

    private func replaceEpisode(_ episode: LibraryEpisode) {
        item = .init(episode: episode, local: item.local, subscription: item.subscription,
                     queued: item.queued, downloading: item.downloading)
    }
}

/// An accepted position transition from the playback owner. Consumers check
/// isCurrent again when consuming an asynchronous event, before finding a binding.
public struct PlaybackPositionUpdate: Equatable, Sendable {
    public let episodeID: Int64
    /// Monotonic within this playback owner, independent of data-result identity.
    public let revision: UInt64
    public let generation: UUID
    public let commandID: UUID
    public let positionMilliseconds: Int32
    public let durationMilliseconds: Int32
}
