import Foundation

public struct PlaybackSpeedPreferences: Codable, Equatable, Sendable {
    public var global: Float = 1
    public var presets: [Float] = [1, 1.25, 1.5]
    public var feeds: [Int64: Float] = [:]
    public var currentEpisodeID: Int64?
    public var temporary: Float = PlaybackSpeed.useGlobal
    public var silence = PlaybackSilencePreferences()

    public init() {}

    private enum CodingKeys: String, CodingKey { case global, presets, feeds, currentEpisodeID, temporary, silence }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        global = try values.decode(Float.self, forKey: .global)
        presets = try values.decode([Float].self, forKey: .presets)
        feeds = try values.decode([Int64: Float].self, forKey: .feeds)
        currentEpisodeID = try values.decodeIfPresent(Int64.self, forKey: .currentEpisodeID)
        temporary = try values.decode(Float.self, forKey: .temporary)
        // Existing speed files predate silence ownership; absence means original defaults.
        silence = try values.decodeIfPresent(PlaybackSilencePreferences.self, forKey: .silence) ?? .init()
    }

    public func resolved(episodeID: Int64, feedID: Int64) -> Float {
        PlaybackSpeed.resolve(global: global, feed: feeds[feedID] ?? PlaybackSpeed.useGlobal,
                              temporary: temporary, isCurrent: currentEpisodeID == episodeID)
    }

    public func resolvedSkipSilence(episodeID: Int64, feedID: Int64) -> Bool {
        silence.resolved(feedID: feedID, feedUsesGlobalSpeed: (feeds[feedID] ?? PlaybackSpeed.useGlobal) == PlaybackSpeed.useGlobal,
                         isCurrent: currentEpisodeID == episodeID)
    }
}

/// Speed and silence share current-media identity and atomic preference writes.
///
/// The standalone library keeps everything in one file, as always. A server library (PROTOCOL §15.4) keeps the
/// values keyed by its local IDs (per-feed speed and silence, the current episode with its speed and silence)
/// in its `playback-library.json`; the device-wide values (global speed, presets, global skip silence) stay in
/// the root file for every library, whose library-keyed values remain the standalone library's, untouched.
@MainActor
public final class PlaybackSpeedPreferenceStore {
    public private(set) var value: PlaybackSpeedPreferences
    private let file: URL
    /// A server library's playback data; nil for the standalone library.
    private let library: PlaybackLibraryFile?
    /// The root file as saved.
    private var saved: PlaybackSpeedPreferences

    public convenience init(file: URL) throws { try self.init(file: file, library: nil) }

    /// `library` is a server library's `playback-library.json`; nil for the standalone library.
    public init(file: URL, library: PlaybackLibraryFile?) throws {
        self.file = file
        self.library = library
        let saved = try SavedState.contents(of: file).map { try JSONDecoder().decode(PlaybackSpeedPreferences.self, from: $0) }
            ?? PlaybackSpeedPreferences()
        // Each file is validated on its own, so an error is attributed to the file that holds it: the server library's
        // values were validated when its file opened.
        try Self.validate(saved)
        var value = saved
        if let speeds = library?.value.speeds {
            value.feeds = speeds.feeds; value.silence.feeds = speeds.feedSilence
            value.currentEpisodeID = speeds.currentEpisodeID
            value.temporary = speeds.temporary; value.silence.temporary = speeds.temporarySilence
        }
        self.saved = saved
        self.value = value
    }

    public func setGlobal(_ speed: Float) throws {
        var changed = value
        changed.global = speed
        try save(changed)
    }

    public func setFeed(_ feedID: Int64, speed: Float, skipSilence: PlaybackSilencePreference? = nil) throws {
        var changed = value
        changed.feeds[feedID] = speed == PlaybackSpeed.useGlobal ? nil : speed
        if let skipSilence { changed.silence.feeds[feedID] = skipSilence == .global ? nil : skipSilence }
        try save(changed)
    }

    /// Bulk Playback speed: one atomic write for every selected feed.
    public func setFeeds(_ feedIDs: [Int64], speed: Float, skipSilence: PlaybackSilencePreference? = nil) throws {
        var changed = value
        for feedID in feedIDs {
            changed.feeds[feedID] = speed == PlaybackSpeed.useGlobal ? nil : speed
            if let skipSilence { changed.silence.feeds[feedID] = skipSilence == .global ? nil : skipSilence }
        }
        try save(changed)
    }

    public func activate(episodeID: Int64, resolvedSpeed: Float, resolvedSkipSilence: Bool = false) throws {
        var changed = value
        changed.currentEpisodeID = episodeID
        changed.temporary = resolvedSpeed
        changed.silence.temporary = resolvedSkipSilence ? .aggressive : .off
        try save(changed)
    }

    public func setCurrent(_ speed: Float, alsoGlobal: Bool) throws {
        var changed = value
        changed.temporary = speed
        if alsoGlobal { changed.global = speed }
        try save(changed)
    }

    public func clearCurrent() throws {
        var changed = value
        changed.currentEpisodeID = nil
        // writeNoMediaPlaying clears media identity but leaves the temporary value stored.
        try save(changed)
    }

    public func setGlobalSkipSilence(_ enabled: Bool) throws {
        var changed = value
        changed.silence.global = enabled
        try save(changed)
    }

    public func setCurrentSkipSilence(_ enabled: Bool, alsoGlobal: Bool) throws {
        var changed = value
        changed.silence.temporary = enabled ? .aggressive : .off
        if alsoGlobal { changed.silence.global = enabled }
        try save(changed)
    }

    /// A podcast merge (PROTOCOL §9.7): the survivor feed takes the source feed's speed and skip silence
    /// when it has neither of its own. Repeating it changes nothing.
    public func adoptFeedSettings(from source: Int64, to survivor: Int64) throws {
        guard source != survivor, value.feeds[survivor] == nil, value.silence.feeds[survivor] == nil,
              value.feeds[source] != nil || value.silence.feeds[source] != nil else { return }
        var changed = value
        changed.feeds[survivor] = value.feeds[source]
        changed.silence.feeds[survivor] = value.silence.feeds[source]
        try save(changed)
    }

    /// Database import: per-feed speed and silence come from the backup; the current episode and
    /// its temporary values belonged to the replaced library and are cleared.
    public func restore(feeds: [Int64: Float], silence: [Int64: PlaybackSilencePreference]) throws {
        var changed = value
        changed.feeds = feeds; changed.silence.feeds = silence
        changed.currentEpisodeID = nil; changed.temporary = PlaybackSpeed.useGlobal; changed.silence.temporary = .global
        try save(changed)
    }

    public func setPresets(_ presets: [Float]) throws {
        guard presets.allSatisfy(Self.valid) else { throw PlaybackSpeedError.invalidSpeed }
        // UserPreferences writes preset values with the US "0.00" DecimalFormat.
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .halfEven
        var changed = value
        changed.presets = try presets.map {
            guard let text = formatter.string(from: NSNumber(value: Double($0))), let speed = Float(text) else {
                throw PlaybackSpeedError.invalidSpeed
            }
            return speed
        }
        try save(changed)
    }

    nonisolated static func valid(_ speed: Float) -> Bool { speed.isFinite && speed > 0 }

    private static func validate(_ value: PlaybackSpeedPreferences) throws {
        guard valid(value.global), value.presets.allSatisfy(valid), value.feeds.values.allSatisfy(valid),
              value.temporary == PlaybackSpeed.useGlobal || valid(value.temporary) else { throw PlaybackSpeedError.invalidSpeed }
    }

    private func save(_ changed: PlaybackSpeedPreferences) throws {
        try Self.validate(changed)
        guard let library else {
            try JSONEncoder().encode(changed).write(to: file, options: .atomic)
            saved = changed
            value = changed
            return
        }
        var root = saved
        root.global = changed.global; root.presets = changed.presets; root.silence.global = changed.silence.global
        if root != saved {
            try JSONEncoder().encode(root).write(to: file, options: .atomic)
            saved = root
        }
        try library.update {
            $0.speeds.feeds = changed.feeds; $0.speeds.feedSilence = changed.silence.feeds
            $0.speeds.currentEpisodeID = changed.currentEpisodeID
            $0.speeds.temporary = changed.temporary; $0.speeds.temporarySilence = changed.silence.temporary
        }
        value = changed
    }
}
