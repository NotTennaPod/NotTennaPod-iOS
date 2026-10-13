import Testing
@testable import NotTennaPodCore

struct PlaybackTimingTests {
    @Test(arguments: [
        (-1, 0), (0, 0), (1, 800), (59_999, 800), (60_000, 800),
        (60_001, 3_000), (3_599_999, 3_000), (3_600_000, 3_000),
        (3_600_001, 10_000), (86_399_999, 10_000), (86_400_000, 10_000),
        (86_400_001, 20_000)
    ])
    func rewindThresholds(elapsed: Int64, rewind: Int32) {
        #expect(PlaybackTiming.positionAfterPause(
            positionMilliseconds: 60_000,
            lastPlayedMilliseconds: 1_000,
            nowMilliseconds: 1_000 + elapsed
        ) == 60_000 - rewind)
    }

    @Test(arguments: [Int32.min, -1, 0, 1, 799, 800, 801, 2_999, 3_000, 3_001, 9_999, 10_000, 10_001, 19_999, 20_000, 20_001, Int32.max])
    func rewindClampsAtStartAndPreservesUnsetPositions(position: Int32) {
        for (elapsed, rewind) in [(Int64(500), Int32(800)), (61_000, 3_000), (3_600_001, 10_000), (86_400_001, 20_000)] {
            let result = PlaybackTiming.positionAfterPause(
                positionMilliseconds: position,
                lastPlayedMilliseconds: 1_000,
                nowMilliseconds: 1_000 + elapsed
            )
            #expect(result == (position > 0 ? max(0, position - rewind) : position))
        }
    }

    @Test(arguments: [Int64.min, -1, 0])
    func missingPauseTimestampDoesNotRewind(timestamp: Int64) {
        #expect(PlaybackTiming.positionAfterPause(
            positionMilliseconds: 42_000, lastPlayedMilliseconds: timestamp, nowMilliseconds: 100_000_000
        ) == 42_000)
    }

    @Test(arguments: [
        (Int32(0), Int32(60_000), Int32(10), Int64(10_000), true),
        (5_000, 60_000, 10, 10_000, true),
        (9_999, 60_000, 10, 10_000, true),
        (10_000, 60_000, 10, 10_000, false),
        (10_001, 60_000, 10, 10_001, false),
        (0, 10_000, 10, 0, false),
        (0, 9_999, 10, 0, false),
        (0, 10_001, 10, 10_000, true),
        (0, 0, 10, 10_000, true),
        (0, -1, 10, 10_000, true),
        (0, 60_000, 0, 0, false),
        (0, 60_000, -1, 0, false),
        (0, 0, Int32.max, 2_147_483_647_000, true)
    ])
    func introBoundaries(position: Int32, duration: Int32, intro: Int32, expected: Int64, notified: Bool) {
        let decision = PlaybackTiming.introSkip(
            positionMilliseconds: position, durationMilliseconds: duration,
            preferences: FeedSkipPreferences(introSeconds: intro)
        )
        #expect(decision.positionMilliseconds == expected)
        #expect(decision.notificationSeconds == (notified ? intro : nil))
    }

    @Test func missingPreferencesDoNotSkipOrNotify() {
        #expect(PlaybackTiming.introSkip(
            positionMilliseconds: 3_000, durationMilliseconds: 60_000, preferences: nil
        ) == IntroSkipDecision(positionMilliseconds: 3_000, notificationSeconds: nil))
        #expect(!PlaybackTiming.shouldSkipEnding(
            positionMilliseconds: 49_500, durationMilliseconds: 60_000, speed: 1, preferences: nil
        ))
    }

    @Test(arguments: [Float(0.5), 1, 1.5, 2, 3])
    func endingTriggersOnlyInStrictSpeedAdjustedWindow(speed: Float) {
        let window = Int64(speed * 1_000)
        for (distance, expected) in [(-1, false), (0, false), (1, true), (window - 1, true), (window, false), (window + 1, false)] {
            #expect(PlaybackTiming.shouldSkipEnding(
                positionMilliseconds: 50_000 - distance, durationMilliseconds: 60_000,
                speed: speed, preferences: FeedSkipPreferences(endingSeconds: 10)
            ) == expected)
        }
    }

    @Test(arguments: [Int32(-1), 0, 60, 61])
    func endingRejectsDisabledAndWholeEpisodeSkip(ending: Int32) {
        #expect(!PlaybackTiming.shouldSkipEnding(
            positionMilliseconds: 500, durationMilliseconds: 60_000, speed: 1,
            preferences: FeedSkipPreferences(endingSeconds: ending)
        ))
    }
}
