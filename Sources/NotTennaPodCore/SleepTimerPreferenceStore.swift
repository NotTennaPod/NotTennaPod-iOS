import Foundation

public struct SleepTimerPreferences: Codable, Equatable, Sendable {
    public var mode: SleepTimerMode = .minutes
    public var lastMinutes = "15"
    public var lastEpisodes = "1"
    public var vibrate = false
    public var shakeToReset = true
    public var autoEnable = false
    public var autoFromHour = 22
    public var autoToHour = 6

    public init() {}
    public var lastValue: String {
        get { mode == .minutes ? lastMinutes : lastEpisodes }
        set { if mode == .minutes { lastMinutes = newValue } else { lastEpisodes = newValue } }
    }
    public var timerValue: Int64? { Int64(lastValue).map { mode.timerValue($0) } }
    public var autoDurationHours: Int {
        autoFromHour >= autoToHour ? 24 - (autoFromHour - autoToHour) : autoToHour - autoFromHour
    }
    public var isAutoEnabledMostOfDay: Bool { autoDurationHours > 12 }
    public func includes(hour: Int) -> Bool {
        autoFromHour < autoToHour ? autoFromHour <= hour && hour < autoToHour
            : autoFromHour <= hour || hour < autoToHour
    }
    public static func validInput(_ text: String) -> Int64? {
        guard let value = Int64(text), value != 0 else { return nil }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case mode, lastMinutes, lastEpisodes, vibrate, shakeToReset, autoEnable, autoFromHour, autoToHour
    }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let index = try fields.decodeIfPresent(Int.self, forKey: .mode) ?? 0
        mode = SleepTimerMode(rawValue: index) ?? .episodes
        lastMinutes = try fields.decodeIfPresent(String.self, forKey: .lastMinutes) ?? "15"
        lastEpisodes = try fields.decodeIfPresent(String.self, forKey: .lastEpisodes) ?? "1"
        vibrate = try fields.decodeIfPresent(Bool.self, forKey: .vibrate) ?? false
        shakeToReset = try fields.decodeIfPresent(Bool.self, forKey: .shakeToReset) ?? true
        autoEnable = try fields.decodeIfPresent(Bool.self, forKey: .autoEnable) ?? false
        autoFromHour = try fields.decodeIfPresent(Int.self, forKey: .autoFromHour) ?? 22
        autoToHour = try fields.decodeIfPresent(Int.self, forKey: .autoToHour) ?? 6
    }
}

/// Only settings persist. An active countdown belongs to the playback lifetime.
@MainActor public final class SleepTimerPreferenceStore: JSONPreferenceStore<SleepTimerPreferences> {
    public init(file: URL) throws { try super.init(file: file, defaultValue: .init()) }
}
