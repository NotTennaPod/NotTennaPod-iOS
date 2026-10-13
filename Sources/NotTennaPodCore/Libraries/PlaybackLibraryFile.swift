import Foundation

/// A server library's `playback-library.json` (PROTOCOL §15.4): the playback data keyed by the library's own
/// local IDs, which repeat across libraries. The standalone library keeps the same data in the root folder's
/// `playback-speed-preferences.json` and `shownotes-scroll.json`, in their existing format.
public struct PlaybackLibraryData: Codable, Equatable, Sendable {
    /// The library's half of `PlaybackSpeedPreferences`: per-feed speed and silence, and the current episode
    /// with its own speed and silence (one unit: they apply only while `currentEpisodeID` is that episode).
    public struct Speeds: Codable, Equatable, Sendable {
        public var feeds: [Int64: Float] = [:]
        public var feedSilence: [Int64: PlaybackSilencePreference] = [:]
        public var currentEpisodeID: Int64?
        public var temporary: Float = PlaybackSpeed.useGlobal
        public var temporarySilence: PlaybackSilencePreference = .global
        public init() {}

        private enum CodingKeys: String, CodingKey { case feeds, feedSilence, currentEpisodeID, temporary, temporarySilence }
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            feeds = try values.decodeIfPresent([Int64: Float].self, forKey: .feeds) ?? [:]
            feedSilence = try values.decodeIfPresent([Int64: PlaybackSilencePreference].self, forKey: .feedSilence) ?? [:]
            currentEpisodeID = try values.decodeIfPresent(Int64.self, forKey: .currentEpisodeID)
            temporary = try values.decodeIfPresent(Float.self, forKey: .temporary) ?? PlaybackSpeed.useGlobal
            temporarySilence = try values.decodeIfPresent(PlaybackSilencePreference.self, forKey: .temporarySilence) ?? .global
        }
    }

    /// The player's last saved shownotes reading position.
    public struct Shownotes: Codable, Equatable, Sendable {
        public var episodeID: Int64
        public var offset: Double
        public init(episodeID: Int64, offset: Double) { self.episodeID = episodeID; self.offset = offset }
    }

    public var speeds = Speeds()
    public var shownotes: Shownotes?
    public init() {}

    private enum CodingKeys: String, CodingKey { case speeds, shownotes }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        speeds = try values.decodeIfPresent(Speeds.self, forKey: .speeds) ?? .init()
        shownotes = try values.decodeIfPresent(Shownotes.self, forKey: .shownotes)
    }
}

/// The one owner of a server library's `playback-library.json`, shared by the speed and shownotes stores of
/// its library graph. Each change is one atomic file write. Opening validates the file's own values (speeds), so a
/// damaged file is recovered on its own, never as part of the device's root speed file.
@MainActor public final class PlaybackLibraryFile {
    public private(set) var value: PlaybackLibraryData
    public let url: URL

    public init(url: URL) throws {
        self.url = url
        let value = try SavedState.contents(of: url).map { try JSONDecoder().decode(PlaybackLibraryData.self, from: $0) }
            ?? PlaybackLibraryData()
        try value.speeds.validate()
        self.value = value
    }

    public func update(_ change: (inout PlaybackLibraryData) throws -> Void) throws {
        var next = value
        try change(&next)
        guard next != value else { return }
        try JSONEncoder().encode(next).write(to: url, options: .atomic)
        value = next
    }
}

extension PlaybackLibraryData.Speeds {
    /// Every speed is finite and positive (the current episode's may be "use the global speed").
    func validate() throws {
        guard feeds.values.allSatisfy(PlaybackSpeedPreferenceStore.valid),
              temporary == PlaybackSpeed.useGlobal || PlaybackSpeedPreferenceStore.valid(temporary) else {
            throw PlaybackSpeedError.invalidSpeed
        }
    }
}
