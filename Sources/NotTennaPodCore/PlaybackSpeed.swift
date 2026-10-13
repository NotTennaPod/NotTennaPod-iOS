import Foundation

/// VariableSpeedDialog keeps its editable list in memory until the dialog is recreated.
/// Persisting two-decimal preset values must not round this open dialog's selections in place.
public struct PlaybackSpeedPresetSelection: Equatable, Sendable {
    public private(set) var presets: [Float]

    public init(presets: [Float]) { self.presets = presets }

    @discardableResult
    public mutating func add(_ speed: Float) throws -> Bool {
        guard speed.isFinite, speed > 0 else { throw PlaybackSpeedError.invalidSpeed }
        guard !presets.contains(speed) else { return false }
        presets.append(speed)
        presets.sort()
        return true
    }

    public mutating func remove(_ speed: Float) {
        if let index = presets.firstIndex(of: speed) { presets.remove(at: index) }
    }
}

public enum PlaybackSpeed {
    public static let useGlobal: Float = -1

    /// PlaybackSpeedUtils: only the currently selected feed media receives the temporary override.
    public static func resolve(global: Float, feed: Float = useGlobal, temporary: Float = useGlobal,
                               isCurrent: Bool = false, isFeedMedia: Bool = true) -> Float {
        guard isFeedMedia else { return global }
        if isCurrent, temporary != useGlobal { return temporary }
        return feed == useGlobal ? global : feed
    }

    /// TimeSpeedConverter uses Java float division followed by a saturating integer cast.
    public static func displayTime(_ milliseconds: Int32, speed: Float, respectsSpeed: Bool) -> Int32 {
        guard milliseconds > 0, respectsSpeed else { return milliseconds }
        let value = Float(milliseconds) / speed
        if value.isNaN { return 0 }
        if value >= Float(Int32.max) { return .max }
        if value <= Float(Int32.min) { return .min }
        return Int32(value)
    }

    /// QueueFragment widens the *result* of int subtraction, divides in float, then accumulates longs.
    /// Unlike the player, the queue does not clamp overruns to zero.
    public static func queueTimeLeft(_ items: [(position: Int32, duration: Int32, speed: Float)],
                                     respectsSpeed: Bool) -> Int64 {
        items.reduce(0) { total, item in
            let remaining = Int64(item.duration &- item.position)
            let converted = FeedValueParsing.javaLong(Float(remaining) / (respectsSpeed ? item.speed : 1))
            return total &+ converted
        }
    }

    public static func sliderProgress(speed: Float) -> Int {
        let value = 20 * speed - 10
        if value.isNaN { return 0 }
        return Int(min(70, max(0, value.rounded(.toNearestOrAwayFromZero))))
    }

    public static func sliderSpeed(progress: Int) -> Float {
        Float(min(70, max(0, progress)) + 10) / 20
    }
}
