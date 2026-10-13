import Foundation

/// AudioPlayerFragment.updatePosition, including the optional playback-speed conversion.
/// Invalid position events leave the existing display intact.
public struct PlayerTimePresentation: Equatable, Sendable {
    public let position: String
    public let length: String
    public let lengthMilliseconds: Int32
    public let lengthAccessibilityKey: String

    public init?(position: Int32, duration: Int32, showRemainingTime: Bool,
                 speed: Float = 1, timeRespectsSpeed: Bool = false, locale: Locale = .current) {
        let convertedPosition = PlaybackSpeed.displayTime(position, speed: speed, respectsSpeed: timeRespectsSpeed)
        let convertedDuration = PlaybackSpeed.displayTime(duration, speed: speed, respectsSpeed: timeRespectsSpeed)
        guard convertedPosition != -1, convertedDuration != -1 else { return nil }
        self.position = EpisodeRowPresentation.time(convertedPosition, locale: locale)
        lengthMilliseconds = showRemainingTime
            ? PlaybackSpeed.displayTime(max(duration &- position, 0), speed: speed, respectsSpeed: timeRespectsSpeed)
            : convertedDuration
        length = (showRemainingTime && lengthMilliseconds > 0 ? "-" : "")
            + EpisodeRowPresentation.time(lengthMilliseconds, locale: locale)
        lengthAccessibilityKey = showRemainingTime ? "remaining_time" : "chapter_duration"
    }

    /// Converter.getDurationStringLocalized deliberately speaks hours and minutes, not seconds.
    public static func spokenDuration(_ milliseconds: Int32, unit: (String, Int) -> String) -> String {
        let hours = Int(milliseconds / 3_600_000)
        let minutes = Int((milliseconds % 3_600_000) / 60_000)
        var parts: [String] = []
        if hours > 0 { parts.append(unit("time_hours_quantified", hours).replacingOccurrences(of: " ", with: "\u{00a0}")) }
        parts.append(unit("time_minutes_quantified", minutes).replacingOccurrences(of: " ", with: "\u{00a0}"))
        return parts.joined(separator: " ")
    }
}
