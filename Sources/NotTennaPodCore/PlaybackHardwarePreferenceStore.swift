import Foundation

public enum PlaybackHardwareAction: String, Codable, CaseIterable, Sendable {
    case forward = "90", rewind = "89", next = "87", restart = "88"
    public var titleKey: String {
        switch self {
        case .forward: "button_action_fast_forward"
        case .rewind: "button_action_rewind"
        case .next: "button_action_skip_episode"
        case .restart: "button_action_restart_episode"
        }
    }
    public func command(intervals: PlaybackIntervalPreferences) -> PlaybackSystemCommand {
        switch self {
        case .forward: .skip(seconds: intervals.forwardSeconds, direction: .forward)
        case .rewind: .skip(seconds: intervals.rewindSeconds, direction: .rewind)
        case .next: .next
        case .restart: .restart
        }
    }
}

public struct PlaybackHardwarePreferences: Codable, Equatable, Sendable {
    public var pauseOnDisconnect = true
    public var forward: PlaybackHardwareAction = .forward
    public var previous: PlaybackHardwareAction = .rewind
    public init() {}
    private enum CodingKeys: String, CodingKey { case forward, previous, pauseOnDisconnect }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pauseOnDisconnect = try values.decodeIfPresent(Bool.self, forKey: .pauseOnDisconnect) ?? true
        forward = PlaybackHardwareAction(rawValue: try values.decodeIfPresent(String.self, forKey: .forward) ?? "90") ?? .forward
        previous = PlaybackHardwareAction(rawValue: try values.decodeIfPresent(String.self, forKey: .previous) ?? "89") ?? .rewind
    }
}

@MainActor public final class PlaybackHardwarePreferenceStore: JSONPreferenceStore<PlaybackHardwarePreferences> {
    public init(file: URL) throws { try super.init(file: file, defaultValue: .init()) }
}
