import AppIntents
#if !WIDGET_EXTENSION
import NotTennaPodCore
#endif

// The widget's playback buttons and the Control
// Center toggle. Compiled into the app and the widget extension; as AudioPlaybackIntents the system runs them in
// the app's process, launching it in the background when needed, so they act on the app's own player.

/// Where the intents reach the app's player. The app sets it at launch; in the widget extension it stays nil.
@MainActor enum PlayerWidgetIntentRouter {
    /// The Home Screen widget's buttons (the system reloads the widget once one returns) or the Control Center toggle.
    enum Source: Sendable { case widget, control }

    static var perform: (@MainActor (PlayerWidgetCommand, Source) async throws -> Void)?

    static func run(_ command: PlayerWidgetCommand, from source: Source) async throws {
        try await perform?(command, source)
    }
}

/// `butPlay` / `butPlayExtended`. Android sends `COMMAND_PLAY_PAUSE`; here the button sends what it shows, Play or
/// Pause, so a Pause still on screen after the app ended cannot start the player that the tap restores.
struct PlayerWidgetPlayPauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "play_label"
    static let isDiscoverable = false
    /// true: Play, false: Pause. Missing only from a button drawn before the buttons carried it: that pauses a
    /// player that wants to play and never plays; otherwise the widget is drawn again with today's buttons.
    @Parameter(title: "play_label") var play: Bool?
    init() {}
    init(play: Bool) { self.play = play }
    @MainActor func perform() async throws -> some IntentResult {
        try await PlayerWidgetIntentRouter.run(play.map { $0 ? .play : .pause } ?? .playPause, from: .widget)
        return .result()
    }
}

/// `butRew`: back by "Rewind skip time".
struct PlayerWidgetRewindIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "rewind_label"
    static let isDiscoverable = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        try await PlayerWidgetIntentRouter.run(.rewind, from: .widget)
        return .result()
    }
}

/// `butFastForward`: ahead by "Fast-forward skip time".
struct PlayerWidgetFastForwardIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "fast_forward_label"
    static let isDiscoverable = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        try await PlayerWidgetIntentRouter.run(.fastForward, from: .widget)
        return .result()
    }
}

/// `butSkip`: the next episode in the queue.
struct PlayerWidgetSkipIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "skip_episode_label"
    static let isDiscoverable = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        try await PlayerWidgetIntentRouter.run(.skip, from: .widget)
        return .result()
    }
}

/// The Control Center toggle: on plays, off pauses.
struct PlayerControlToggleIntent: SetValueIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "play_label"
    static let isDiscoverable = false
    @Parameter(title: "play_label") var value: Bool
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        try await PlayerWidgetIntentRouter.run(value ? .play : .pause, from: .control)
        return .result()
    }
}
