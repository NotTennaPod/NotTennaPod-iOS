import Foundation

public struct PlaybackQueuePreferences: Codable, Equatable, Sendable {
    public var followQueue = true
    public var skipKeepsEpisode = true
    public init() {}
    private enum CodingKeys: String, CodingKey { case followQueue, skipKeepsEpisode }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        followQueue = try values.decodeIfPresent(Bool.self, forKey: .followQueue) ?? true
        skipKeepsEpisode = try values.decodeIfPresent(Bool.self, forKey: .skipKeepsEpisode) ?? true
    }
}

@MainActor public final class PlaybackQueuePreferenceStore: JSONPreferenceStore<PlaybackQueuePreferences> {
    public init(file: URL) throws { try super.init(file: file, defaultValue: .init()) }
}
