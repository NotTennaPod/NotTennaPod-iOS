import Foundation

public enum SleepTimerMode: Int, Codable, CaseIterable, Sendable {
    case minutes = 0, episodes = 1

    public var extensions: [Int64] { self == .minutes ? [5, 10, 30] : [1, 2, 3] }
    public func timerValue(_ input: Int64) -> Int64 {
        self == .minutes ? SleepTimerMath.multiply(input, by: 60_000) : input
    }
}

public struct SleepTimerValue: Equatable, Sendable {
    /// Milliseconds in clock mode; count in episode mode.
    public let display: Int64
    /// Episode mode uses the raw final episode remainder for fading.
    public let milliseconds: Int64

    public var volume: Float {
        milliseconds > 0 && milliseconds < 10_000 ? max(0.1, Float(milliseconds) / 10_000) : 1
    }
}

public enum SleepTimerEvent: Equatable, Sendable {
    case enabled(SleepTimerValue), updated(SleepTimerValue), cancelled
    case expiryVibration, resetVibration, shakeListening(Bool)
}

/// Playback-owned state, independent of a screen or scheduler. The active service
/// supplies one-second position ticks while playback's observer is running.
/// A tick after a gap over ten seconds establishes a new baseline without counting
/// that gap. Short pauses therefore remain part of the next clock decrement.
/// Times are monotonic milliseconds, so a wall-clock correction neither extends
/// nor shortens a clock timer (Android uses wall time here).
public struct SleepTimer: Sendable {
    public private(set) var mode: SleepTimerMode = .minutes
    public private(set) var remaining: Int64 = 0
    public private(set) var isListeningForShake = false
    private var initial: Int64 = 0
    private var lastTick: Int64 = 0
    private var running = false
    private var hasVibrated = false

    public init() {}
    public var isActive: Bool { running && remaining > 0 }
    public var value: SleepTimerValue {
        .init(display: remaining, milliseconds: mode == .minutes ? remaining
              : SleepTimerMath.multiply(remaining, by: 86_400_000))
    }

    public mutating func start(mode: SleepTimerMode, value: Int64, nowMilliseconds: Int64) -> [SleepTimerEvent] {
        var events = running ? stop() : []
        self.mode = mode
        initial = value
        remaining = value
        lastTick = nowMilliseconds
        running = true
        hasVibrated = false
        events += [.enabled(self.value), .updated(clamped(self.value))]
        return events
    }

    public mutating func stop() -> [SleepTimerEvent] {
        remaining = 0
        running = false
        var events: [SleepTimerEvent] = []
        if isListeningForShake { events.append(.shakeListening(false)) }
        isListeningForShake = false
        events.append(.cancelled)
        return events
    }

    public mutating func tick(nowMilliseconds: Int64, positionMilliseconds: Int64, durationMilliseconds: Int64,
                              vibrate: Bool, shakeToReset: Bool) -> [SleepTimerEvent] {
        guard running else { return [] }
        let milliseconds: Int64
        if mode == .minutes {
            let elapsed = SleepTimerMath.subtract(nowMilliseconds, lastTick)
            lastTick = nowMilliseconds
            guard elapsed <= 10_000 else { return [] }
            remaining = SleepTimerMath.subtract(remaining, elapsed)
            milliseconds = remaining
        } else {
            milliseconds = remaining == 1 ? SleepTimerMath.subtract(durationMilliseconds, positionMilliseconds)
                : value.milliseconds
        }
        var events: [SleepTimerEvent] = [.updated(clamped(.init(display: remaining, milliseconds: milliseconds)))]
        if milliseconds < 10_000 {
            if vibrate && !hasVibrated {
                hasVibrated = true
                events.append(.expiryVibration)
            }
            if shakeToReset && !isListeningForShake {
                isListeningForShake = true
                events.append(.shakeListening(true))
            }
        }
        if mode == .minutes && remaining <= 0 { events += stop() }
        return events
    }

    /// Extensions affect the next tick's displayed value. A shake always restores
    /// the original start value, including after an extension.
    public mutating func extend(by additional: Int64) {
        guard isActive else { return }
        remaining = SleepTimerMath.add(remaining, additional)
    }

    public mutating func reset() -> [SleepTimerEvent] {
        guard running else { return [] }
        remaining = initial
        // The source retains its warning latch, shake listener and tick baseline.
        return [.cancelled, .enabled(value)]
    }

    public func isEndingThisEpisode(remainingMilliseconds: Int64) -> Bool {
        mode == .episodes ? remaining == 1 : remainingMilliseconds >= remaining
    }

    /// Call only for the service's completion path, not a manual next-item skip.
    public mutating func episodeFinished() -> (continuePlayback: Bool, events: [SleepTimerEvent]) {
        guard isActive else { return (true, []) }
        if mode == .episodes { remaining -= 1 }
        return remaining > 0 ? (true, []) : (false, stop())
    }

    private func clamped(_ value: SleepTimerValue) -> SleepTimerValue {
        .init(display: max(0, value.display), milliseconds: max(0, value.milliseconds))
    }
}

enum SleepTimerMath {
    static func multiply(_ value: Int64, by multiplier: Int64) -> Int64 {
        let result = value.multipliedReportingOverflow(by: multiplier)
        return result.overflow ? (value < 0 ? .min : .max) : result.partialValue
    }
    static func add(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? (rhs < 0 ? .min : .max) : result.partialValue
    }
    static func subtract(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.subtractingReportingOverflow(rhs)
        return result.overflow ? (rhs < 0 ? .max : .min) : result.partialValue
    }
}
