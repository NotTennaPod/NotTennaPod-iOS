import Foundation

/// Codes and inheritance follow FeedPreferences.SkipSilence in release 3.12.1.
public enum PlaybackSilencePreference: Int, Codable, CaseIterable, Sendable {
    case off = 0, global = 1, aggressive = 2
}

public struct PlaybackSilencePreferences: Codable, Equatable, Sendable {
    public var global = false
    public var feeds: [Int64: PlaybackSilencePreference] = [:]
    public var temporary: PlaybackSilencePreference = .global

    public init() {}

    public func resolved(feedID: Int64, feedUsesGlobalSpeed: Bool, isCurrent: Bool) -> Bool {
        var choice = isCurrent ? temporary : .global
        if choice == .global, !feedUsesGlobalSpeed { choice = feeds[feedID] ?? .global }
        return choice == .global ? global : choice == .aggressive
    }
}
