import Foundation

/// Android's "Set notification buttons" choices (`UserPreferences.NOTIFICATION_BUTTON_*`, UP:133–136).
/// Raw values are Android's stored ids.
public enum NotificationButton: Int, Codable, CaseIterable, Sendable {
    case skipEpisode = 2, nextChapter = 3, playbackSpeed = 4, sleepTimer = 5

    public var titleKey: String {
        switch self {
        case .skipEpisode: "skip_episode_label"
        case .nextChapter: "next_chapter"
        case .playbackSpeed: "playback_speed"
        case .sleepTimer: "sleep_timer_label"
        }
    }

    /// iOS offers only the buttons a standard Now Playing command can
    /// carry, in Android's dialog order (arrays.xml `full_notification_buttons_options`).
    public static let offered: [NotificationButton] = [.skipEpisode, .playbackSpeed]
}

public struct NotificationButtonPreferences: Codable, Equatable, Sendable {
    /// Android default "2,4": Skip episode and Playback speed (UP:226–229).
    public var buttons: [NotificationButton] = [.skipEpisode, .playbackSpeed]
    public init() {}
    public init(buttons: [NotificationButton]) { self.buttons = buttons }

    public func shows(_ button: NotificationButton) -> Bool { buttons.contains(button) }

    private enum CodingKeys: String, CodingKey { case buttons }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Unknown ids are ignored, as Android's dialog drops ids it no longer offers (UIPF:140–153).
        if let raw = try values.decodeIfPresent([Int].self, forKey: .buttons) {
            var seen: [NotificationButton] = []
            for id in raw { if let button = NotificationButton(rawValue: id), !seen.contains(button) { seen.append(button) } }
            buttons = seen
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(buttons.map(\.rawValue), forKey: .buttons)
    }
}

/// Persists the choice beside the library; observers see changes at once (Android only rebuilds the
/// notification's buttons on reconnect or a sleep-timer change, a delay that is not copied).
@MainActor public final class NotificationButtonPreferenceStore: JSONPreferenceStore<NotificationButtonPreferences> {
    public init(file: URL) throws { try super.init(file: file, defaultValue: .init()) }

    /// Saves the dialog's selection (indices into `NotificationButton.offered`) in the offered order.
    public func select(_ indices: Set<Int>) throws {
        try update(.init(buttons: NotificationButton.offered.indices.filter(indices.contains).map { NotificationButton.offered[$0] }))
    }
}

/// Which Now Playing commands are offered, derived from playback state and preferences.
/// Android → iOS: the always-present Rewind/Fast forward are skipBackward/skipForward;
/// Skip episode is the next-track command, whose action stays the "Forward button" choice because
/// MediaPlayer delivers headset and on-screen next-track alike; Playback speed is the playback-rate
/// command with the speed presets as its rates. Next chapter and Sleep timer have no iOS command.
public struct NowPlayingCommandAvailability: Equatable, Sendable {
    public var play = false, pause = false, toggle = false, stop = false
    public var skipForward = false, skipBackward = false, nextTrack = false, previousTrack = false
    public var changePosition = false, changeRate = false
    public var supportedRates: [Float] = []

    public init() {}

    public static func available(_ command: PlaybackSystemCommand, state: PlaybackSystemSnapshot) -> Bool {
        switch command {
        case .play, .toggle: state.canPlay
        case .seek: state.canSeek
        case .skip, .next, .restart: state.canSkip
        case .rate: state.canChangeRate
        case .pause, .stop: true
        }
    }

    public static func make(state: PlaybackSystemSnapshot?, buttons: NotificationButtonPreferences,
                            hardware: PlaybackHardwarePreferences, intervals: PlaybackIntervalPreferences,
                            presets: [Float], remote: Bool) -> NowPlayingCommandAvailability {
        var result = NowPlayingCommandAvailability()
        result.supportedRates = presets.filter { $0.isFinite && (0.5...(remote ? 2 : 4)).contains($0) }
        guard let state else { return result }
        result.play = state.canPlay && !state.wantsPlayback
        result.pause = state.wantsPlayback
        result.toggle = state.canPlay
        result.stop = true
        result.skipForward = state.canSkip
        result.skipBackward = state.canSkip
        result.nextTrack = buttons.shows(.skipEpisode) && available(hardware.forward.command(intervals: intervals), state: state)
        result.previousTrack = available(hardware.previous.command(intervals: intervals), state: state)
        result.changePosition = state.canSeek
        result.changeRate = buttons.shows(.playbackSpeed) && state.canChangeRate
        return result
    }
}
