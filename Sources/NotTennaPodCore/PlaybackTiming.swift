public struct FeedSkipPreferences: Equatable, Codable, Sendable {
    public var introSeconds: Int32
    public var endingSeconds: Int32

    public init(introSeconds: Int32 = 0, endingSeconds: Int32 = 0) {
        self.introSeconds = introSeconds
        self.endingSeconds = endingSeconds
    }
}

public struct IntroSkipDecision: Equatable, Sendable {
    public let positionMilliseconds: Int64
    public let notificationSeconds: Int32?
}

public enum PlaybackTiming {
    enum IntervalDecision: Equatable { case seek(Int64), complete }

    /// Active Media3PlaybackService interval buttons have different end behavior
    /// from a direct scrub/seek. Unknown duration must not clamp forward progress.
    static func intervalSkip(positionMilliseconds: Int32, durationMilliseconds: Int32,
                             seconds: Int32, direction: PlaybackIntervalDirection? = nil) -> IntervalDecision {
        let delta = Int64(seconds) * 1_000 * (direction == .rewind ? -1 : 1)
        let target = Int64(positionMilliseconds) + delta
        if direction.map({ $0 == .forward }) ?? (seconds >= 0) {
            if durationMilliseconds > 0 && target >= Int64(durationMilliseconds) { return .complete }
            return .seek(target)
        }
        return .seek(max(0, target))
    }

    public static func positionAfterPause(
        positionMilliseconds: Int32,
        lastPlayedMilliseconds: Int64,
        nowMilliseconds: Int64
    ) -> Int32 {
        guard positionMilliseconds > 0, lastPlayedMilliseconds > 0 else {
            return positionMilliseconds
        }
        let elapsed = nowMilliseconds &- lastPlayedMilliseconds
        let rewind: Int32
        switch elapsed {
        case 86_400_001...: rewind = 20_000
        case 3_600_001...: rewind = 10_000
        case 60_001...: rewind = 3_000
        case 1...: rewind = 800
        default: rewind = 0
        }
        return max(0, positionMilliseconds - rewind)
    }

    public static func introSkip(
        positionMilliseconds: Int32,
        durationMilliseconds: Int32,
        preferences: FeedSkipPreferences?
    ) -> IntroSkipDecision {
        let position = Int64(positionMilliseconds)
        guard let preferences else {
            return IntroSkipDecision(positionMilliseconds: position, notificationSeconds: nil)
        }
        let intro = Int64(preferences.introSeconds) * 1_000
        guard intro > 0, position < intro,
              intro < Int64(durationMilliseconds) || durationMilliseconds <= 0 else {
            return IntroSkipDecision(positionMilliseconds: position, notificationSeconds: nil)
        }
        return IntroSkipDecision(positionMilliseconds: intro, notificationSeconds: preferences.introSeconds)
    }

    public static func shouldSkipEnding(
        positionMilliseconds: Int64,
        durationMilliseconds: Int64,
        speed: Float,
        preferences: FeedSkipPreferences?
    ) -> Bool {
        guard let preferences else { return false }
        let ending = Int64(preferences.endingSeconds) * 1_000
        let timeUntilEnding = (durationMilliseconds &- positionMilliseconds) &- ending
        return ending > 0 && ending < durationMilliseconds
            && timeUntilEnding > 0 && Float(timeUntilEnding) < speed * 1_000
    }
}
