import Foundation

/// QueueFragment.refreshInfoBar: count all items, sum only media, resolve each rate.
public struct QueueInformation: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var episodeID: Int64
        public var feedID: Int64
        public var position: Int32
        public var duration: Int32?
        public init(episodeID: Int64, feedID: Int64, position: Int32, duration: Int32?) {
            self.episodeID = episodeID; self.feedID = feedID
            self.position = position; self.duration = duration
        }
    }
    public let count: Int
    public let remainingMilliseconds: Int64
    public let isVisible: Bool
    public init(items: [Item], speeds: PlaybackSpeedPreferences, respectsSpeed: Bool, selecting: Bool = false) {
        count = items.count
        isVisible = !selecting
        remainingMilliseconds = PlaybackSpeed.queueTimeLeft(items.compactMap { item in
            guard let duration = item.duration else { return nil }
            return (item.position, duration, speeds.resolved(episodeID: item.episodeID, feedID: item.feedID))
        }, respectsSpeed: respectsSpeed)
    }

    /// Converter.getDurationStringLocalized(..., false), including Java's narrowing casts.
    /// Queue totals can exceed Int32; player duration formatting alone is insufficient.
    public var durationUnits: (hours: Int32, minutes: Int32) {
        let hours = Int32(truncatingIfNeeded: remainingMilliseconds / 3_600_000)
        let rest = Int32(truncatingIfNeeded: remainingMilliseconds &- (Int64(hours) * 3_600_000))
        return (hours, rest / 60_000)
    }
    public func durationText(unit: (String, Int) -> String) -> String {
        let (hours, minutes) = durationUnits
        var parts: [String] = []
        if hours > 0 { parts.append(unit("time_hours_quantified", Int(hours)).replacingOccurrences(of: " ", with: "\u{00a0}")) }
        parts.append(unit("time_minutes_quantified", Int(minutes)).replacingOccurrences(of: " ", with: "\u{00a0}"))
        return parts.joined(separator: " ")
    }
}
