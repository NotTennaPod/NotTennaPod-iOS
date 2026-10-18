/// Process-local admission state from the active Media3 service. The playback owner
/// applies decisions before queue insertion, selection persistence and remote loading.
/// Dismissing the UI has no state transition: a later Play may accept the pending item.
public struct StreamingAdmissionPolicy: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case proceed
        /// Replace the live item with the paused confirmation item and clear current playable.
        case confirm(mediaID: Int64)
        /// Load/prepare/play the pending episode through the ordinary media-loading path.
        case reload(mediaID: Int64)
    }
    public enum PlayerState: Equatable, Sendable { case idle, buffering, ready, ended }
    public struct Media: Equatable, Sendable {
        public let id: Int64
        public let needsStreaming: Bool
        public init(id: Int64, needsStreaming: Bool) {
            self.id = id
            self.needsStreaming = needsStreaming
        }
    }

    public private(set) var pendingMediaID: Int64?
    public private(set) var allowStreamingThisTime = false

    public init() {}

    /// ensureCurrentMediaLoaded clears the pending request for an ordinary media item.
    /// A nil/confirmation item returns before that assignment and must not call this.
    public mutating func willLoadEpisode() { pendingMediaID = nil }

    /// Called after resolving the episode, before committing it as the current playable.
    public mutating func loadedMedia(_ media: Media, streamingAllowed: Bool, isCasting: Bool) -> Decision {
        if media.needsStreaming && !streamingAllowed && !allowStreamingThisTime && !isCasting {
            return confirm(media.id)
        }
        // Also consumed when the next load is local, unrestricted or cast.
        allowStreamingThisTime = false
        return .proceed
    }

    /// ForwardingPlayer.play checks pending confirmation before ready/buffering admission,
    /// and runs ordinary resume/rewind only if this returns proceed.
    public mutating func play(isConfirmationItem: Bool, currentMedia: Media?, state: PlayerState,
                              streamingAllowed: Bool, isCasting: Bool) -> Decision {
        if isConfirmationItem, let id = pendingMediaID {
            pendingMediaID = nil
            allowStreamingThisTime = true
            return .reload(mediaID: id)
        }
        if let media = currentMedia, state == .ready || state == .buffering,
           media.needsStreaming, !streamingAllowed, !isCasting {
            return confirm(media.id)
        }
        return .proceed
    }

    /// A route that fetches through the phone refused a load this policy let through (a Cast relay on a network that
    /// does not admit streaming). The episode becomes the pending confirmation item, as a refused load's would, so the
    /// affirmative Play reloads it with Once consent.
    public mutating func requireConfirmation(mediaID: Int64) -> Decision { confirm(mediaID) }

    private mutating func confirm(_ id: Int64) -> Decision {
        pendingMediaID = id
        return .confirm(mediaID: id)
    }
}
