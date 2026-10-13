import Foundation

/// The player widget's link to the app's playback coordinator.
@MainActor public enum PlayerWidgetPlayback {
    /// The widget's view of the selected episode; nil when none is selected ("No media playing"). It carries the
    /// lease of `PlayerWidgetLease`, counted from `now`.
    public static func snapshot(playback: PlaybackCoordinator, timeDisplay: TimeDisplayPreferences,
                                cover: String?, now: Date) -> PlayerWidgetSnapshot? {
        guard let state = playback.systemSnapshot else { return nil }
        func clamp(_ value: Int64) -> Int32 { Int32(max(0, min(value, Int64(Int32.max)))) }
        return PlayerWidgetSnapshot(episodeID: state.identity.episodeID, title: state.title, isVideo: state.isVideo,
            isPlaying: state.wantsPlayback, positionRate: state.rate, positionMilliseconds: clamp(state.positionMilliseconds),
            durationMilliseconds: clamp(state.durationMilliseconds ?? 0), speed: state.defaultRate,
            showRemainingTime: timeDisplay.showRemainingTime, timeRespectsSpeed: timeDisplay.timeRespectsSpeed,
            savedAt: now, cover: cover, leaseSeconds: PlayerWidgetLease.duration)
    }

    /// Runs a widget or control command on the current episode, as the player's own buttons do: Play (loading a
    /// restored episode first) and Pause, the preferred rewind and fast-forward intervals (ending the episode
    /// at its end), and Skip episode. The app may have been launched just for this command, so the saved
    /// selection is restored first; Pause then leaves it paused, whatever the widget still showed. Rewind,
    /// fast-forward and skip need a prepared player, as on Android, where they reach a playback service that has
    /// the episode loaded. Returns whether the command was accepted.
    ///
    /// `.playPause` comes only from a button drawn before buttons said Play or Pause, so what it showed is unknown:
    /// it pauses a player that wants to play and otherwise is refused. It never plays: a stale Pause may be on
    /// screen over a player restored for the tap, or one paused by an interruption or headphone removal.
    @discardableResult
    public static func perform(_ command: PlayerWidgetCommand, playback: PlaybackCoordinator,
                               intervals: PlaybackIntervalPreferences) async throws -> Bool {
        try await playback.restore()
        guard let state = playback.systemSnapshot else { return false }
        let system: PlaybackSystemCommand
        switch command {
        case .playPause:
            guard state.wantsPlayback else { return false }
            system = .pause
        case .play: system = .play
        case .pause: system = .pause
        case .rewind: system = .skip(seconds: intervals.rewindSeconds, direction: .rewind)
        case .fastForward: system = .skip(seconds: intervals.forwardSeconds, direction: .forward)
        case .skip: system = .next
        }
        return try await playback.performSystemCommand(system, for: state.identity)
    }
}
