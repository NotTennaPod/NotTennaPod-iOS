import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor private final class TimerMotionProbe: SleepTimerMotionSource {
    var sample: (@MainActor @Sendable (Double, Double, Double) -> Void)?
    var starts = 0, stops = 0
    func start(_ sample: @escaping @MainActor @Sendable (Double, Double, Double) -> Void) { self.sample = sample; starts += 1 }
    func stop() { stops += 1 }
}
@MainActor private final class TimerHapticProbe: SleepTimerHapticOutput {
    var values: [(Double, Float)] = []
    func vibrate(duration: Double, intensity: Float) { values.append((duration, intensity)) }
}
@MainActor @Suite(.serialized) struct SleepTimerFeedbackTests {
    @Test func sourceThresholdFeedbackDurationsAndCancelledDelivery() async throws {
        let motion = TimerMotionProbe(), haptics = TimerHapticProbe()
        var resets = 0
        let runtime = SleepTimerFeedbackRuntime(motion: motion, haptics: haptics) { resets += 1 }
        runtime.receive(.shakeListening(true)); runtime.receive(.shakeListening(true))
        #expect(motion.starts == 1)
        let first = try #require(motion.sample)
        first(0, 0, 1); first(2.25, 0, 0)
        await Task.yield(); #expect(resets == 0)
        first(0, -2, -2)
        let deadline = ContinuousClock.now + .seconds(2)
        while resets == 0 && ContinuousClock.now < deadline { await Task.yield() }
        #expect(resets == 1)
        runtime.receive(.expiryVibration); runtime.receive(.resetVibration)
        #expect(haptics.values.count == 2)
        #expect(haptics.values[0].0 == 0.5 && haptics.values[0].1 == 1)
        #expect(haptics.values[1].0 == 0.1 && haptics.values[1].1 == Float(120) / 255)
        runtime.receive(.shakeListening(false)); runtime.receive(.shakeListening(false))
        first(3, 0, 0); await Task.yield()
        #expect(motion.stops == 1 && resets == 1)
        runtime.receive(.shakeListening(true)); first(3, 0, 0); await Task.yield()
        #expect(resets == 1 && motion.starts == 2)
        runtime.receive(.shakeListening(false))
    }
}
