import Foundation

// The Home Screen player widget and the Control Center control. Foundation only: the widget extension compiles
// this file on its own, without the rest of NotTennaPodCore.

public enum PlayerWidget {
    public static let kind = "org.nottennapod.app.player-widget"
    public static let controlKind = "org.nottennapod.app.player-control"
    /// The App Group shared by the app and the widget extension.
    public static let appGroup = "group.org.nottennapod.app"
    /// `PlayerWidget.DEFAULT_COLOR` without its alpha (`PlayerWidget.java:27`, `player_widget.xml:13`).
    public static let backgroundRGB: UInt32 = 0x262C31
    /// `imgvBackground`'s alpha over the colour (`player_widget.xml:21`).
    public static let coverBackgroundAlpha = 0.6
}

/// Taps that open the app: the cover/text area and the speed button.
public enum PlayerWidgetLink {
    public static let scheme = "nottennapod-widget"
    /// `MainActivityStarter.withOpenPlayer()`, or the video player for a video episode.
    public static let player = URL(string: "nottennapod-widget://player")!
    /// `PlaybackSpeedActivityStarter`: the speed dialog.
    public static let speed = URL(string: "nottennapod-widget://speed")!

    public enum Destination: Equatable, Sendable { case player, playbackSpeed }
    public static func destination(for url: URL) -> Destination? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        switch url.host?.lowercased() {
        case "speed": return .playbackSpeed
        default: return .player
        }
    }
}

/// What a widget button or the control asks the app's player to do.
public enum PlayerWidgetCommand: String, Codable, Sendable, CaseIterable {
    /// `COMMAND_PLAY_PAUSE`, without saying which: pauses a player that wants to play, otherwise does nothing; it
    /// never plays. Only a widget button drawn before buttons said which sends it (`PlayerWidgetPlayPauseIntent`
    /// without `play`).
    case playPause
    /// `COMMAND_SEEK_BACK`: back by "Rewind skip time".
    case rewind
    /// `COMMAND_SEEK_FORWARD`: ahead by "Fast-forward skip time"; at the end the episode ends.
    case fastForward
    /// `COMMAND_SEEK_TO_NEXT_MEDIA_ITEM`: the next episode in the queue.
    case skip
    /// What the widget's Play/Pause button and the Control Center toggle show: Play plays and Pause pauses; neither
    /// flips the player. Android's button sends `COMMAND_PLAY_PAUSE` to a service that keeps its widget current;
    /// here a Pause still shown after the app ended must never start the player the tap restores.
    case play, pause
}

/// The current episode as the widget shows it, written by the app into the App Group.
public struct PlayerWidgetSnapshot: Codable, Equatable, Sendable {
    public var episodeID: Int64
    public var title: String
    public var isVideo: Bool
    /// The player wants to play: the button shows Pause (Android's PLAYING), otherwise Play.
    public var isPlaying: Bool
    /// How fast the position advances now; 0 while paused or buffering.
    public var positionRate: Float
    public var positionMilliseconds: Int32
    /// 0 when unknown.
    public var durationMilliseconds: Int32
    /// The playback speed (`TimeSpeedConverter`'s speed).
    public var speed: Float
    /// "Show remaining time" and "Time respects speed" when the snapshot was written.
    public var showRemainingTime: Bool
    public var timeRespectsSpeed: Bool
    public var savedAt: Date
    /// File name of the cover beside the snapshot; nil shows the app icon.
    public var cover: String?
    /// How long after `savedAt` a playing snapshot may be shown as playing (`PlayerWidgetLease`). nil in
    /// snapshots written before leases existed: those are never shown as playing.
    public var leaseSeconds: TimeInterval?

    public init(episodeID: Int64, title: String, isVideo: Bool = false, isPlaying: Bool, positionRate: Float,
                positionMilliseconds: Int32, durationMilliseconds: Int32, speed: Float = 1,
                showRemainingTime: Bool = false, timeRespectsSpeed: Bool = false, savedAt: Date, cover: String? = nil,
                leaseSeconds: TimeInterval? = nil) {
        self.episodeID = episodeID; self.title = title; self.isVideo = isVideo; self.isPlaying = isPlaying
        self.positionRate = positionRate; self.positionMilliseconds = positionMilliseconds
        self.durationMilliseconds = durationMilliseconds; self.speed = speed
        self.showRemainingTime = showRemainingTime; self.timeRespectsSpeed = timeRespectsSpeed
        self.savedAt = savedAt; self.cover = cover; self.leaseSeconds = leaseSeconds
    }

    /// When the lease ends; nil without one.
    public var leaseExpiry: Date? {
        guard let leaseSeconds, leaseSeconds.isFinite, leaseSeconds > 0 else { return nil }
        return savedAt.addingTimeInterval(leaseSeconds)
    }

    /// Whether the lease holds at `date`: the snapshot was written before it (give or take
    /// `PlayerWidgetLease.clockTolerance`) and less than its lease ago. Comparing two wall-clock dates is all the
    /// widget's process can do with the app's file; a time that does not fit (the clock was set) is not trusted.
    public func isFresh(at date: Date) -> Bool {
        guard let leaseExpiry else { return false }
        return date.timeIntervalSince(savedAt) >= -PlayerWidgetLease.clockTolerance && date < leaseExpiry
    }

    /// What the widget and the control show at `date`: the snapshot as written while it is paused or its lease
    /// holds; otherwise paused at its own position, the last one the app reported.
    public func shown(at date: Date) -> PlayerWidgetSnapshot {
        guard isPlaying || positionRate > 0, !isFresh(at: date) else { return self }
        var paused = self
        paused.isPlaying = false; paused.positionRate = 0
        return paused
    }

    /// The position at `date`: advanced at `positionRate` since `savedAt`, never past the duration.
    public func position(at date: Date) -> Int32 {
        guard positionRate > 0, date > savedAt else { return positionMilliseconds }
        let advanced = Double(positionMilliseconds) + date.timeIntervalSince(savedAt) * 1_000 * Double(positionRate)
        let limit = durationMilliseconds > 0 ? Double(durationMilliseconds) : Double(Int32.max)
        return Int32(max(0, min(advanced, limit)))
    }

    /// Whether `other` shows something different from what this snapshot shows or predicts: another episode,
    /// title, cover, play state, speed, duration, time setting or lease, or, when the time shows (a known
    /// duration), a position more than `tolerance` away from this snapshot's prediction (a seek, a stall). With an
    /// unknown duration no time shows, so the position does not matter (a live stream's runs ahead of its rate
    /// with Skip silence).
    public func differs(from other: PlayerWidgetSnapshot, toleranceMilliseconds: Int32 = 1_500) -> Bool {
        if episodeID != other.episodeID || title != other.title || isVideo != other.isVideo || isPlaying != other.isPlaying
            || positionRate != other.positionRate || durationMilliseconds != other.durationMilliseconds || speed != other.speed
            || showRemainingTime != other.showRemainingTime || timeRespectsSpeed != other.timeRespectsSpeed || cover != other.cover
            || leaseSeconds != other.leaseSeconds {
            return true
        }
        guard other.durationMilliseconds > 0 else { return false }
        return abs(Int64(position(at: other.savedAt)) - Int64(other.positionMilliseconds)) > Int64(toleranceMilliseconds)
    }
}

/// One widget's settings (`WidgetConfigActivity`). Defaults are Android's.
public struct PlayerWidgetConfiguration: Equatable, Sendable {
    /// 0–100 %.
    public var opacity: Double
    public var playbackSpeed: Bool
    public var rewind: Bool
    public var fastForward: Bool
    public var skip: Bool
    public var coverAsBackground: Bool

    public init(opacity: Double = 100, playbackSpeed: Bool = false, rewind: Bool = false, fastForward: Bool = false,
                skip: Bool = false, coverAsBackground: Bool = false) {
        self.opacity = opacity; self.playbackSpeed = playbackSpeed; self.rewind = rewind
        self.fastForward = fastForward; self.skip = skip; self.coverAsBackground = coverAsBackground
    }

    /// `showPlaybackSpeed || showRewind || showSkip || showFastForward` (`WidgetUpdater.java:154`).
    public var showsExtendedButtons: Bool { playbackSpeed || rewind || fastForward || skip }

    /// The background colour's alpha: `round(255 × opacity / 100)` (`WidgetConfigActivity.java:177–179`);
    /// "Cover as background" forces 100 % (`:131–137`).
    public var backgroundAlpha: Double {
        guard !coverAsBackground else { return 1 }
        let percent = opacity.isFinite ? min(100, max(0, opacity)) : 100
        return (255 * percent / 100).rounded() / 255
    }
}

/// What one widget shows for a snapshot and its settings at a moment (`WidgetUpdater.updateWidget`).
public struct PlayerWidgetPresentation: Equatable, Sendable {
    /// The extended row, in `player_widget.xml` order.
    public enum Control: String, CaseIterable, Sendable { case playbackSpeed, rewind, playPause, fastForward, skip }
    public enum Action: Equatable, Sendable { case open(URL), command(PlayerWidgetCommand) }

    /// The episode title; nil shows "No media playing".
    public let title: String?
    public let progress: String?
    public let isPlaying: Bool
    /// Title, progress and the extended row; hidden in the narrow (small) widget (`WidgetUpdater.java:143–147`).
    public let showsText: Bool
    /// The extended row; empty shows the standalone play/pause button.
    public let extendedControls: [Control]
    public let showsStandalonePlay: Bool
    /// The small cover, or (Cover as background) the blurred cover behind everything.
    public let showsCover: Bool
    public let showsCoverBackground: Bool
    public let backgroundAlpha: Double
    public let hasMedia: Bool

    /// `narrow`: the small widget, Android's fewer-than-three-cells layout. Unlike Android, it keeps the
    /// play/pause button when extended buttons are chosen (Android then shows only the cover).
    public init(snapshot: PlayerWidgetSnapshot?, configuration: PlayerWidgetConfiguration, date: Date,
                narrow: Bool, hasCover: Bool, locale: Locale = .current) {
        hasMedia = snapshot != nil
        title = snapshot?.title
        isPlaying = snapshot?.isPlaying ?? false
        progress = snapshot.flatMap {
            Self.progress(position: $0.position(at: date), duration: $0.durationMilliseconds, speed: $0.speed,
                          showRemainingTime: $0.showRemainingTime, timeRespectsSpeed: $0.timeRespectsSpeed, locale: locale)
        }
        showsText = !narrow
        let extended = !narrow && configuration.showsExtendedButtons
        extendedControls = extended ? Control.allCases.filter {
            switch $0 {
            case .playbackSpeed: configuration.playbackSpeed
            case .rewind: configuration.rewind
            case .playPause: true
            case .fastForward: configuration.fastForward
            case .skip: configuration.skip
            }
        } : []
        showsStandalonePlay = !extended
        showsCover = !configuration.coverAsBackground
        showsCoverBackground = configuration.coverAsBackground && hasCover && snapshot != nil
        backgroundAlpha = configuration.backgroundAlpha
    }

    /// The widget gallery's and the settings' preview: Android's configuration preview shows the app name and
    /// `00:00:00` (`WidgetConfigActivity.java:80–86`) with the chosen buttons.
    public static func preview(configuration: PlayerWidgetConfiguration, narrow: Bool) -> PlayerWidgetPresentation {
        let base = PlayerWidgetPresentation(snapshot: PlayerWidgetSnapshot(episodeID: 0, title: "NotTennaPod", isPlaying: false,
            positionRate: 0, positionMilliseconds: 0, durationMilliseconds: 0, savedAt: .distantPast),
            configuration: configuration, date: .distantPast, narrow: narrow, hasCover: false)
        return PlayerWidgetPresentation(title: base.title, progress: PlayerWidgetPresentation.durationLong(0), isPlaying: false,
            showsText: base.showsText, extendedControls: base.extendedControls, showsStandalonePlay: base.showsStandalonePlay,
            showsCover: base.showsCover, showsCoverBackground: false, backgroundAlpha: base.backgroundAlpha, hasMedia: true)
    }

    private init(title: String?, progress: String?, isPlaying: Bool, showsText: Bool, extendedControls: [Control],
                 showsStandalonePlay: Bool, showsCover: Bool, showsCoverBackground: Bool, backgroundAlpha: Double, hasMedia: Bool) {
        self.title = title; self.progress = progress; self.isPlaying = isPlaying; self.showsText = showsText
        self.extendedControls = extendedControls; self.showsStandalonePlay = showsStandalonePlay; self.showsCover = showsCover
        self.showsCoverBackground = showsCoverBackground; self.backgroundAlpha = backgroundAlpha; self.hasMedia = hasMedia
    }

    /// With an episode the buttons act on it and the speed button opens the speed dialog; with none
    /// every control opens the app (Android's standalone Play; its extended Play does nothing). Play/Pause does
    /// what it shows (`PlayerWidgetCommand.play`/`.pause`), never a flip.
    public func action(for control: Control) -> Action {
        guard hasMedia else { return .open(PlayerWidgetLink.player) }
        return switch control {
        case .playbackSpeed: .open(PlayerWidgetLink.speed)
        case .rewind: .command(.rewind)
        case .playPause: .command(isPlaying ? .pause : .play)
        case .fastForward: .command(.fastForward)
        case .skip: .command(.skip)
        }
    }

    /// Content descriptions (`player_widget.xml`, `WidgetUpdater.java:99–109`).
    public func labelKey(for control: Control) -> String {
        switch control {
        case .playbackSpeed: "playback_speed"
        case .rewind: "rewind_label"
        case .playPause: isPlaying ? "pause_label" : "play_label"
        case .fastForward: "fast_forward_label"
        case .skip: "skip_episode_label"
        }
    }

    /// Android's `ic_widget_*` drawables.
    public func iconName(for control: Control) -> String {
        switch control {
        case .playbackSpeed: "ic_widget_playback_speed"
        case .rewind: "ic_widget_fast_rewind"
        case .playPause: isPlaying ? "ic_widget_pause" : "ic_widget_play"
        case .fastForward: "ic_widget_fast_forward"
        case .skip: "ic_widget_skip"
        }
    }

    /// `WidgetUpdater.getProgressString`: hidden when the position or duration is unknown, otherwise
    /// "position / duration" or "position / -remaining", both through `TimeSpeedConverter`.
    public static func progress(position: Int32, duration: Int32, speed: Float, showRemainingTime: Bool,
                                timeRespectsSpeed: Bool, locale: Locale = .current) -> String? {
        guard position >= 0, duration > 0 else { return nil }
        func convert(_ time: Int32) -> Int32 {
            guard time > 0, timeRespectsSpeed else { return time }
            let value = Float(time) / speed
            if value.isNaN { return 0 }
            if value >= Float(Int32.max) { return .max }
            return Int32(value)
        }
        let start = durationLong(convert(position), locale: locale)
        return showRemainingTime
            ? start + " / -" + durationLong(convert(max(0, duration &- position)), locale: locale)
            : start + " / " + durationLong(convert(duration), locale: locale)
    }

    /// `Converter.getDurationStringLong`: `HH:MM:SS` in the locale's digits, `00:00:00` for ≤ 0.
    public static func durationLong(_ milliseconds: Int32, locale: Locale = .current) -> String {
        guard milliseconds > 0 else { return "00:00:00" }
        let seconds = Int(milliseconds / 1_000)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumIntegerDigits = 2
        formatter.maximumFractionDigits = 0
        return [seconds / 3_600, (seconds / 60) % 60, seconds % 60]
            .map { formatter.string(from: NSNumber(value: $0)) ?? String($0) }.joined(separator: ":")
    }
}

/// How long the widget and the control trust a "playing" snapshot once the app may have ended.
///
/// Android's service updates its widget until it is destroyed. iOS can end the app at any moment (memory, a crash,
/// a force-quit) without `willTerminate`, and nothing reaches the widget then. So a playing snapshot is a lease:
/// - While the app plays, it rewrites the snapshot at least every `renewal` (on its playback events, or a live
///   stream's position ticks, which already arrive every second; no timer of its own) and with that asks for the
///   widget's timeline to be reloaded, so about once a minute, not on every position update. It times this by
///   its own monotonic clock.
/// - The snapshot is trusted as playing for `duration` after `savedAt`. Every timeline built from it ends with a
///   paused entry at that moment (`PlayerWidgetTimeline`), and the Control Center control reads the file and
///   checks the lease each time the system asks for its value. Buffering and an unknown duration show no running
///   time. A snapshot written before leases existed is never trusted as playing.
/// - Nothing wakes the app, keeps it running or asks for background time to renew; `willTerminate` still writes
///   the episode paused when iOS sends it.
///
/// Honest limits. WidgetKit decides when a requested reload is delivered (playing Now Playing apps are exempt from
/// its reload budget, but there is no delivery deadline), so this gives no display deadline:
/// - During healthy playback, if a replacement timeline arrives after the delivered one reached its paused entry,
///   the widget shows paused until the next timeline that is delivered (WidgetKit also asks for one at that entry).
/// - After the app has ended, the widget can show playing, with a running time, until its delivered timeline
///   reaches the paused entry; that entry knows only the position of the snapshot it was built from, not
///   necessarily the app's last position.
/// - The Control Center control is only as current as the system's last request for its value.
/// - The file holds wall-clock dates, the only time both processes can compare. A date that does not fit the
///   reader's clock (from the future, or older than its lease) is not trusted. When the clock is set, the app renews
///   at once if it is told (`NSSystemClockDidChange`) or a running time shows (the position no longer fits the
///   prediction), and otherwise within `renewal`, since its own cadence does not follow the wall clock.
public enum PlayerWidgetLease {
    /// How long after it was written a playing snapshot is trusted.
    public static let duration: TimeInterval = 180
    /// How often the app renews it while playing, and so at most how often it asks for a reload to renew it. A
    /// replacement timeline arriving within `duration − renewal` of a request keeps healthy playback shown playing.
    public static let renewal: TimeInterval = 60
    /// How far in the reader's future a snapshot may have been written (a small clock correction) and still hold.
    public static let clockTolerance: TimeInterval = 5

    /// Whether the app writes `next`, given the snapshot it last wrote (`.some(nil)`: "No media playing"; nil:
    /// nothing yet) and how long ago by its monotonic clock (nil: unknown, renew now). It writes when the widget
    /// would show something else, and while playing once the last write is `renewal` old; never for progress
    /// along the predicted line in between, nor to renew a paused snapshot.
    public static func needsWrite(_ next: PlayerWidgetSnapshot?, after written: PlayerWidgetSnapshot??, elapsed: Duration?) -> Bool {
        guard case .some(let previous) = written else { return true }
        switch (previous, next) {
        case (nil, nil): return false
        case (let old?, let new?):
            if old.differs(from: new) { return true }
            guard new.isPlaying || new.positionRate > 0 else { return false }
            return elapsed.map { $0 >= .seconds(renewal) } ?? true
        default: return true
        }
    }
}

/// When the widget's view changes without the app: Android redraws every second while playing; here a timeline
/// holds one entry per second ahead, advanced at the playback rate, until the snapshot's lease ends, and then a
/// paused entry (`PlayerWidgetLease`).
public enum PlayerWidgetTimeline {
    public struct Entry: Equatable, Sendable {
        public let date: Date
        /// nil: "No media playing".
        public let snapshot: PlayerWidgetSnapshot?
        public init(date: Date, snapshot: PlayerWidgetSnapshot?) { self.date = date; self.snapshot = snapshot }
    }

    /// The entries of a timeline built at `now`, and when to ask for the next one (nil: only when the app reloads
    /// it). Paused, stale or old-format snapshots give one entry, shown paused. A playing one gives an entry per
    /// second while its position advances with a known duration (stopping at the entry that reaches the end; the
    /// app reports what comes next), only the first entry while buffering or of unknown duration, and last the
    /// paused entry at its lease's end, where WidgetKit asks for a new timeline.
    public static func schedule(for snapshot: PlayerWidgetSnapshot?, now: Date) -> (entries: [Entry], refresh: Date?) {
        guard let snapshot else { return ([Entry(date: now, snapshot: nil)], nil) }
        let shown = snapshot.shown(at: now)
        guard shown.isPlaying || shown.positionRate > 0, let expiry = snapshot.leaseExpiry else {
            return ([Entry(date: now, snapshot: shown)], nil)
        }
        var entries = [Entry(date: now, snapshot: snapshot)]
        if snapshot.positionRate > 0, snapshot.durationMilliseconds > 0 {
            var date = now
            while snapshot.position(at: date) < snapshot.durationMilliseconds {
                date = date.addingTimeInterval(1)
                guard date < expiry else { break }
                entries.append(Entry(date: date, snapshot: snapshot))
            }
        }
        entries.append(Entry(date: expiry, snapshot: snapshot.shown(at: expiry)))
        return (entries, expiry)
    }
}

/// The snapshot and cover files in the App Group container.
public struct PlayerWidgetStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    /// The shared container; nil when the process has no App Group entitlement.
    public static func appGroup(fileManager: FileManager = .default) -> PlayerWidgetStore? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: PlayerWidget.appGroup)
            .map { PlayerWidgetStore(directory: $0.appendingPathComponent("PlayerWidget", isDirectory: true)) }
    }

    private var snapshotFile: URL { directory.appendingPathComponent("snapshot.json") }

    /// nil: no media (also when nothing was ever written or the file is unreadable).
    public func read() -> PlayerWidgetSnapshot? {
        guard let data = try? Data(contentsOf: snapshotFile) else { return nil }
        return try? JSONDecoder().decode(PlayerWidgetSnapshot.self, from: data)
    }

    public func write(_ snapshot: PlayerWidgetSnapshot?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let snapshot else {
            try? FileManager.default.removeItem(at: snapshotFile)
            removeCovers(except: nil)
            return
        }
        try JSONEncoder().encode(snapshot).write(to: snapshotFile, options: .atomic)
        removeCovers(except: snapshot.cover)
    }

    /// Saves an episode's cover and returns its file name for the snapshot.
    public func writeCover(_ data: Data, episodeID: Int64) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "cover-\(episodeID)-\(UUID().uuidString.prefix(8)).png"
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        return name
    }

    /// The Control Center control's value, read again each time the system asks: on only while a playing
    /// snapshot's lease holds at `date`.
    public func controlValue(at date: Date) -> Bool {
        read()?.shown(at: date).isPlaying ?? false
    }

    public func cover(named name: String) -> Data? {
        guard !name.contains("/") else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    private func removeCovers(except kept: String?) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix("cover-") && name != kept {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
