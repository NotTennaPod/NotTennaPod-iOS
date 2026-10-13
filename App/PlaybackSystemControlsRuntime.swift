import UIKit
import MediaPlayer
import NotTennaPodCore
import OSLog

/// One process owner for MediaPlayer registration. No AVPlayer or audio session
/// is created here; local and Cast playback share the existing coordinator.
@MainActor final class PlaybackSystemControlsRuntime {
    enum Input: Sendable {
        case play, pause, toggle, stop, next, previous, forward(Double), backward(Double), position(Double), rate(Float)
    }
    private let controls: PlaybackSystemControls
    private let playback: PlaybackCoordinator
    private let library: FeedLibraryStore
    private let intervals: PlaybackIntervalPreferenceStore
    private let hardware: PlaybackHardwarePreferenceStore
    private let remote: @MainActor () -> Bool
    private let buttons: NotificationButtonPreferenceStore?
    private let presets: @MainActor () -> [Float]
    private let commands: MPRemoteCommandCenter
    private let info: MPNowPlayingInfoCenter
    private var registrations: [(MPRemoteCommand, Any)] = []
    private var intervalTask: Task<Void, Never>?
    private var hardwareTask: Task<Void, Never>?
    private var buttonsTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var commandTasks: [UUID: Task<Void, Never>] = [:]
    private var metadataIdentity: PlaybackSystemIdentity?
    private var feed: LibraryFeed?
    private var artwork: EpisodeArtworkView?
    private var artworkImage: UIImage?
    private var active = false
    private var published: NowPlayingPublication?
    /// What the remote commands were last set to: they are set only when that changes, not on
    /// every playback event (twice a second while playing, also locked).
    private struct AppliedCommands: Equatable {
        let offered: NowPlayingCommandAvailability
        let forward, rewind: Int32
    }
    private var appliedCommands: AppliedCommands?
    /// Completed refreshes, so tests can wait for one deterministically.
    private(set) var refreshes = 0
    private let uptime: @MainActor () -> TimeInterval

    init(playback: PlaybackCoordinator, library: FeedLibraryStore, intervals: PlaybackIntervalPreferenceStore,
         hardware: PlaybackHardwarePreferenceStore, remote: @escaping @MainActor () -> Bool,
         buttons: NotificationButtonPreferenceStore? = nil, presets: @escaping @MainActor () -> [Float] = { PlaybackSpeedPreferences().presets },
         commands: MPRemoteCommandCenter = .shared(), info: MPNowPlayingInfoCenter = .default(),
         uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.playback = playback; self.library = library; self.intervals = intervals; self.hardware = hardware
        self.uptime = uptime
        self.remote = remote; self.buttons = buttons; self.presets = presets; self.commands = commands; self.info = info
        controls = PlaybackSystemControls(playback: playback)
    }

    func start() {
        guard !active else { return }
        active = true
        register(commands.playCommand) { _ in .play }
        register(commands.pauseCommand) { _ in .pause }
        register(commands.togglePlayPauseCommand) { _ in .toggle }
        register(commands.stopCommand) { _ in .stop }
        // MediaPlayer does not reveal whether a next/previous command came
        // from an accessory or a system UI. Both use the configured mapping.
        register(commands.nextTrackCommand) { _ in .next }
        register(commands.previousTrackCommand) { _ in .previous }
        register(commands.skipForwardCommand) { ($0 as? MPSkipIntervalCommandEvent).map { .forward($0.interval) } }
        register(commands.skipBackwardCommand) { ($0 as? MPSkipIntervalCommandEvent).map { .backward($0.interval) } }
        register(commands.changePlaybackPositionCommand) { ($0 as? MPChangePlaybackPositionCommandEvent).map { .position($0.positionTime) } }
        register(commands.changePlaybackRateCommand) { ($0 as? MPChangePlaybackRateCommandEvent).map { .rate($0.playbackRate) } }
        controls.onChange = { [weak self] _ in self?.refresh() }
        controls.start()
        let intervalEvents = intervals.events(), hardwareEvents = hardware.events()
        intervalTask = Task { [weak self] in
            for await _ in intervalEvents { guard !Task.isCancelled else { return }; self?.refresh() }
        }
        hardwareTask = Task { [weak self] in
            for await _ in hardwareEvents { guard !Task.isCancelled else { return }; self?.refresh() }
        }
        // A changed "Set notification buttons" choice applies at once, also during playback.
        if let buttonEvents = buttons?.events() {
            buttonsTask = Task { [weak self] in
                for await _ in buttonEvents { guard !Task.isCancelled else { return }; self?.refresh() }
            }
        }
    }

    func stop() {
        guard active else { return }
        active = false
        controls.stop(); controls.onChange = nil
        for (command, target) in registrations { command.removeTarget(target); command.isEnabled = false }
        registrations.removeAll(); appliedCommands = nil
        intervalTask?.cancel(); intervalTask = nil; hardwareTask?.cancel(); hardwareTask = nil
        buttonsTask?.cancel(); buttonsTask = nil
        metadataTask?.cancel(); metadataTask = nil
        for task in commandTasks.values { task.cancel() }; commandTasks.removeAll()
        artwork?.cancelLoading(); artwork = nil; artworkImage = nil; feed = nil; metadataIdentity = nil
        info.nowPlayingInfo = nil; published = nil
    }

    private func register(_ command: MPRemoteCommand, input: @escaping @Sendable (MPRemoteCommandEvent) -> Input?) {
        let token = command.addTarget { @Sendable [weak self] event in
            guard let value = input(event) else { return .commandFailed }
            // Admission is synchronous and bounded; playback/storage work runs
            // asynchronously on the coordinator. The framework callback is not
            // promised to run on MainActor.
            if Thread.isMainThread { return MainActor.assumeIsolated { self?.receive(value) ?? .commandFailed } }
            return DispatchQueue.main.sync { MainActor.assumeIsolated { self?.receive(value) ?? .commandFailed } }
        }
        registrations.append((command, token))
    }

    static func command(_ input: Input, hardware: PlaybackHardwarePreferences, intervals: PlaybackIntervalPreferences,
                        remote: Bool, buttons: NotificationButtonPreferences = .init()) -> PlaybackSystemCommand? {
        // Skip episode and Playback speed are offered only while chosen in "Set notification buttons".
        switch input {
        case .next where !buttons.shows(.skipEpisode), .rate where !buttons.shows(.playbackSpeed): return nil
        default: break
        }
        return switch input {
        case .play: .play
        case .pause: .pause
        case .toggle: .toggle
        case .stop: .stop
        case .next: hardware.forward.command(intervals: intervals)
        case .previous: hardware.previous.command(intervals: intervals)
        case .position(let seconds):
            seconds.isFinite && seconds >= 0 && seconds <= Double(Int32.max) / 1_000
                ? .seek(milliseconds: Int64(seconds * 1_000)) : nil
        case .forward(let seconds), .backward(let seconds):
            seconds.isFinite && seconds > 0 && seconds <= Double(Int32.max)
                ? .skip(seconds: Int32(seconds), direction: { if case .backward = input { .rewind } else { .forward } }()) : nil
        case .rate(let rate): rate.isFinite && (0.5...(remote ? 2 : 4)).contains(rate) ? .rate(rate) : nil
        }
    }

    @discardableResult func receive(_ input: Input) -> MPRemoteCommandHandlerStatus {
        guard active, let state = controls.snapshot else { return .noActionableNowPlayingItem }
        guard let command = Self.command(input, hardware: hardware.value, intervals: intervals.value, remote: remote(),
                                         buttons: buttons?.value ?? .init()),
              Self.available(command, state: state) else { return .commandFailed }
        let taskID = UUID()
        commandTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            defer { commandTasks[taskID] = nil; refresh() }
            do { _ = try await controls.perform(command, for: state.identity) }
            catch { Logger(subsystem: "org.nottennapod.app", category: "Playback").error("System playback command failed") }
        }
        // Success means admitted, not that asynchronous preparation has ended.
        return .success
    }

    static func available(_ command: PlaybackSystemCommand, state: PlaybackSystemSnapshot) -> Bool {
        NowPlayingCommandAvailability.available(command, state: state)
    }

    var availability: NowPlayingCommandAvailability { availability(controls.snapshot) }
    private func availability(_ state: PlaybackSystemSnapshot?) -> NowPlayingCommandAvailability {
        .make(state: state, buttons: buttons?.value ?? .init(), hardware: hardware.value,
              intervals: intervals.value, presets: presets(), remote: remote())
    }

    static func nowPlayingInfo(_ state: PlaybackSystemSnapshot, feed: LibraryFeed?, artwork: UIImage?) -> [String: Any] {
        var values: [String: Any] = [MPMediaItemPropertyTitle: state.title,
            MPNowPlayingInfoPropertyExternalContentIdentifier: "antennapod:episode:\(state.identity.episodeID)",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(state.positionMilliseconds) / 1_000,
            MPNowPlayingInfoPropertyPlaybackRate: state.rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: state.defaultRate,
            MPNowPlayingInfoPropertyIsLiveStream: state.durationMilliseconds == nil,
            MPNowPlayingInfoPropertyMediaType: state.isVideo ? MPNowPlayingInfoMediaType.video.rawValue : MPNowPlayingInfoMediaType.audio.rawValue]
        if let duration = state.durationMilliseconds { values[MPMediaItemPropertyPlaybackDuration] = Double(duration) / 1_000 }
        if let feed { values[MPMediaItemPropertyAlbumTitle] = feed.title; values[MPMediaItemPropertyArtist] = feed.metadata.author ?? feed.title }
        if let artwork { values[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { @Sendable _ in artwork } }
        return values
    }

    private func refresh() {
        guard active else { return }
        let state = controls.snapshot, offered = availability(state)
        let applied = AppliedCommands(offered: offered, forward: intervals.value.forwardSeconds, rewind: intervals.value.rewindSeconds)
        if applied != appliedCommands { appliedCommands = applied; apply(offered) }
        if state?.identity != metadataIdentity {
            metadataTask?.cancel(); artwork?.cancelLoading(); artwork = nil; artworkImage = nil; feed = nil
            metadataIdentity = state?.identity
            if let state, let episode = playback.episode {
                metadataTask = Task { [weak self, library] in
                    guard let feedID = try? await library.feedID(forEpisode: episode.id),
                          let feed = try? await library.playbackFeed(id: feedID), !Task.isCancelled,
                          let self, active, controls.snapshot?.identity == state.identity else { return }
                    self.feed = feed
                    // Lock-screen artwork is 512 px: load the large decode, not the 400 px row size.
                    let cover = EpisodeArtworkView(feed: feed, episode: episode, library: library, presentation: .chapterCover)
                    artwork = cover
                    cover.onArtworkChange = { [weak self, weak cover] in
                        guard let self, active, controls.snapshot?.identity == state.identity else { return }
                        artworkImage = cover?.artwork(size: .init(width: 512, height: 512), scale: 1)
                        refresh()
                    }
                    refresh()
                }
            }
        }
        publishNowPlaying(state)
        refreshes += 1
    }

    private func apply(_ offered: NowPlayingCommandAvailability) {
        commands.playCommand.isEnabled = offered.play
        commands.pauseCommand.isEnabled = offered.pause
        commands.togglePlayPauseCommand.isEnabled = offered.toggle
        commands.stopCommand.isEnabled = offered.stop
        commands.skipForwardCommand.isEnabled = offered.skipForward
        commands.skipBackwardCommand.isEnabled = offered.skipBackward
        commands.nextTrackCommand.isEnabled = offered.nextTrack
        commands.previousTrackCommand.isEnabled = offered.previousTrack
        commands.changePlaybackPositionCommand.isEnabled = offered.changePosition
        commands.changePlaybackRateCommand.isEnabled = offered.changeRate
        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: intervals.value.forwardSeconds)]
        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: intervals.value.rewindSeconds)]
        // Android's speed button steps through the chosen speeds (M3PS:594–614); system rate controls
        // step through these supported rates.
        commands.changePlaybackRateCommand.supportedPlaybackRates = offered.supportedRates.map { NSNumber(value: $0) }
    }

    /// Setting `nowPlayingInfo` makes iOS re-encode the artwork (7–14 % CPU when done on every playback tick,
    /// 2026-10-01 device profile). It is set only when something shown changes or the position leaves the
    /// track iOS extrapolates from the published position and rate (seeks, stalls).
    private func publishNowPlaying(_ state: PlaybackSystemSnapshot?) {
        guard let state else {
            if published != nil || info.nowPlayingInfo != nil { info.nowPlayingInfo = nil }
            published = nil
            return
        }
        let next = NowPlayingPublication(state, feed: feed, artwork: artworkImage, uptime: uptime())
        if let published, published.stillDescribes(next) { return }
        published = next
        info.nowPlayingInfo = Self.nowPlayingInfo(state, feed: feed, artwork: artworkImage)
    }

    isolated deinit { stop() }
}

/// What the system Now Playing display was last given. Elapsed time is advanced by iOS from the published
/// position and rate, so a later state is "still described" while everything else is unchanged and its
/// position is within `positionTolerance` of that extrapolation.
struct NowPlayingPublication: Equatable {
    struct Shown: Equatable {
        var identity: PlaybackSystemIdentity
        var title: String
        var durationMilliseconds: Int64?
        var rate: Float
        var defaultRate: Float
        var isVideo: Bool
        var album: String?
        var artist: String?
        var artwork: ObjectIdentifier?
    }
    /// Seconds; below what a person reads off the lock-screen clock.
    static let positionTolerance = 0.5
    var shown: Shown
    var positionSeconds: Double
    var uptime: TimeInterval

    init(_ state: PlaybackSystemSnapshot, feed: LibraryFeed?, artwork: UIImage?, uptime: TimeInterval) {
        shown = Shown(identity: state.identity, title: state.title, durationMilliseconds: state.durationMilliseconds,
                      rate: state.rate, defaultRate: state.defaultRate, isVideo: state.isVideo, album: feed?.title,
                      artist: feed.flatMap { $0.metadata.author ?? $0.title }, artwork: artwork.map(ObjectIdentifier.init))
        positionSeconds = Double(state.positionMilliseconds) / 1_000
        self.uptime = uptime
    }

    func stillDescribes(_ later: NowPlayingPublication) -> Bool {
        guard shown == later.shown else { return false }
        let expected = positionSeconds + max(0, later.uptime - uptime) * Double(shown.rate)
        return abs(later.positionSeconds - expected) <= Self.positionTolerance
    }
}
