import Foundation

public enum PlaybackIntervalDirection: String, Sendable, CaseIterable {
    case rewind, forward
    public var preferenceKey: String { self == .forward ? "prefPlaybackFastForwardDeltaLauncher" : "prefPlaybackRewindDeltaLauncher" }
    public var titleKey: String { self == .forward ? "pref_fast_forward" : "pref_rewind" }
}

public struct PlaybackIntervalPreferences: Codable, Equatable, Sendable {
    public static let choices: [Int32] = [5, 10, 15, 20, 30, 45, 60]
    public var rewindSeconds: Int32 = 10
    public var forwardSeconds: Int32 = 30
    public init() {}
    public func seconds(for direction: PlaybackIntervalDirection) -> Int32 {
        direction == .forward ? forwardSeconds : rewindSeconds
    }
    public func selectedIndex(for direction: PlaybackIntervalDirection) -> Int {
        Self.choices.firstIndex(of: seconds(for: direction)) ?? 0
    }
    public mutating func select(_ index: Int, for direction: PlaybackIntervalDirection) {
        guard Self.choices.indices.contains(index) else { return }
        if direction == .forward { forwardSeconds = Self.choices[index] }
        else { rewindSeconds = Self.choices[index] }
    }
    private enum CodingKeys: String, CodingKey { case rewindSeconds, forwardSeconds }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        rewindSeconds = try fields.decodeIfPresent(Int32.self, forKey: .rewindSeconds) ?? 10
        forwardSeconds = try fields.decodeIfPresent(Int32.self, forKey: .forwardSeconds) ?? 30
    }
}

@MainActor public final class PlaybackIntervalPreferenceStore: JSONPreferenceStore<PlaybackIntervalPreferences> {
    public init(file: URL) throws { try super.init(file: file, defaultValue: .init()) }
}
