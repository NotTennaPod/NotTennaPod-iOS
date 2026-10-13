import Foundation
import Testing
@testable import NotTennaPodCore

struct PlaybackFocusPolicyTests {
    /// Every 4-event sequence of interruptions, pauses, unplugging and reconnection yields the
    /// Android-observable outcome: whether audio is heard, whether the Play button shows and
    /// whether the resume rewinds. Internal intent/suppression flags are not compared.
    @Test func originalMethodsMatchEveryFourEventSequence() throws {
        let url = try #require(Bundle.module.url(forResource: "audio-focus-oracle", withExtension: "json", subdirectory: "Fixtures"))
        let expected = try JSONDecoder().decode([UInt32].self, from: Data(contentsOf: url))
        let actions: [PlaybackFocusPolicy.Event] = [.requestPlay(granted: true), .requestPlay(granted: false),
            .requestPause, .gained, .lost, .lostTemporarily, .lostTemporarilyCanDuck, .audioBecomingNoisy, .routeConnected]
        try #require(expected.count == 26_244)
        var index = 0
        for initial in [false, true] {
            for pause in [false, true] {
                for sequence in 0..<6561 {
                    var policy = PlaybackFocusPolicy(playWhenReady: initial, pauseOnDisconnect: pause)
                    var remaining = sequence
                    var packed: UInt32 = 0
                    for step in 0..<4 {
                        let value = policy.apply(actions[remaining % 9])
                        remaining /= 9
                        let bits: UInt32 = (value.playWhenReady ? 1 : 0) | (value.suppressed ? 2 : 0)
                            | (value.shouldRender ? 4 : 0) | (value.rewindAfterTransientLoss ? 8 : 0)
                            | (policy.shouldShowPlayButton(state: .ready) ? 16 : 0)
                        packed |= bits << (step * 8)
                    }
                    // Bits 4 (audible), 8 (rewind on resume) and 16 (Play button) of each step.
                    let visible: UInt32 = 0x1C1C_1C1C
                    #expect(packed & visible == expected[index] & visible, "initial=\(initial), disconnect=\(pause), sequence=\(sequence)")
                    index += 1
                }
            }
        }
    }

    // Ducking-then-gain and pause/unplug-during-interruption sequences are rows of the
    // exhaustive four-event oracle above (audible, Play button and rewind bits).

    @Test func suppressionClearUsesServiceRewindThresholdsEvenAfterManualPause() {
        let cases: [(Int64, Int64?)] = [(1000, nil), (1001, 24200), (61000, 24200), (61001, 22000),
            (3601000, 22000), (3601001, 15000), (86401000, 15000), (86401001, 5000)]
        for (now, target) in cases {
            var policy = PlaybackFocusPolicy(playWhenReady: true)
            let suppressed = policy.apply(.lostTemporarily)
            #expect(suppressed.rewindPosition(positionMilliseconds: 25000, lastPlayedMilliseconds: 1000,
                                               nowMilliseconds: now) == nil)
            policy.apply(.requestPause)
            let restored = policy.apply(.gained)
            #expect(!restored.shouldRender)
            #expect(restored.rewindPosition(positionMilliseconds: 25000, lastPlayedMilliseconds: 1000,
                                             nowMilliseconds: now) == target)
        }
    }

    @Test func preparedPlayerButtonStatesKeepSuppressionSeparateFromIntent() {
        for initial in [false, true] {
            for suppressed in [false, true] {
                var policy = PlaybackFocusPolicy(playWhenReady: initial)
                if suppressed { policy.apply(.lostTemporarily) }
                #expect(policy.shouldShowPlayButton(state: .idle))
                #expect(policy.shouldShowPlayButton(state: .ended))
                #expect(policy.shouldShowPlayButton(state: .ready) == (!initial || suppressed))
                #expect(policy.shouldShowPlayButton(state: .buffering) == (!initial || suppressed))
            }
        }
    }
}
