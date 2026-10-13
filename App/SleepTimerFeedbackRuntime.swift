import CoreMotion
import CoreHaptics
import AVFAudio
import OSLog
import NotTennaPodCore

@MainActor protocol SleepTimerMotionSource: AnyObject {
    func start(_ sample: @escaping @MainActor @Sendable (Double, Double, Double) -> Void)
    func stop()
}
@MainActor protocol SleepTimerHapticOutput: AnyObject {
    func vibrate(duration: TimeInterval, intensity: Float) throws
}

/// Application-owned feedback survives dismissal of the player and timer dialog.
@MainActor final class SleepTimerFeedbackRuntime {
    private let motion: any SleepTimerMotionSource
    private let haptics: any SleepTimerHapticOutput
    private let reset: @MainActor () async throws -> Void
    private var listening = false
    private var generation = UUID()
    init(motion: any SleepTimerMotionSource = NativeSleepTimerMotion(),
         haptics: any SleepTimerHapticOutput = NativeSleepTimerHaptics(),
         reset: @escaping @MainActor () async throws -> Void) {
        self.motion = motion; self.haptics = haptics; self.reset = reset
    }
    func receive(_ event: SleepTimerEvent) {
        switch event {
        case .shakeListening(let enabled):
            guard enabled != listening else { return }
            listening = enabled; generation = UUID()
            if enabled {
                let token = generation
                motion.start { [weak self] x, y, z in
                    guard let self, listening, generation == token,
                          sqrt(x * x + y * y + z * z) > 2.25 else { return }
                    Task { [weak self] in
                        guard let self, listening, generation == token else { return }
                        do { try await reset() } catch { logFailure() }
                    }
                }
            } else { motion.stop() }
        case .expiryVibration: vibrate(duration: 0.5, intensity: 1)
        case .resetVibration: vibrate(duration: 0.1, intensity: 120 / 255)
        default: break
        }
    }
    private func vibrate(duration: TimeInterval, intensity: Float) {
        do { try haptics.vibrate(duration: duration, intensity: intensity) } catch { logFailure() }
    }
    private func logFailure() { Logger(subsystem: "org.nottennapod.app", category: "SleepTimer").error("Sleep timer feedback unavailable") }
}

@MainActor private final class NativeSleepTimerMotion: SleepTimerMotionSource {
    /// Exists only while shake listening runs: a manager made at launch kept Core Motion's thread
    /// and service connection alive for the app's whole life although shaking is used only in a timer's last 10 s.
    private var manager: CMMotionManager?
    func start(_ sample: @escaping @MainActor @Sendable (Double, Double, Double) -> Void) {
        let manager = manager ?? CMMotionManager()
        guard manager.isAccelerometerAvailable else { return }
        self.manager = manager
        // Android SENSOR_DELAY_UI is a 60 ms requested period. Core Motion values
        // already use g, including gravity, as required by the source threshold.
        manager.accelerometerUpdateInterval = 0.06
        manager.startAccelerometerUpdates(to: .main) { data, _ in
            guard let acceleration = data?.acceleration else { return }
            // Delivered on the main queue.
            MainActor.assumeIsolated { sample(acceleration.x, acceleration.y, acceleration.z) }
        }
    }
    func stop() { manager?.stopAccelerometerUpdates(); manager = nil }
    isolated deinit { manager?.stopAccelerometerUpdates() }
}

@MainActor private final class NativeSleepTimerHaptics: SleepTimerHapticOutput {
    private var engine: CHHapticEngine?
    private var player: (any CHHapticPatternPlayer)?
    func vibrate(duration: TimeInterval, intensity: Float) throws {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        if engine == nil {
            let value = try CHHapticEngine(audioSession: AVAudioSession.sharedInstance())
            value.playsHapticsOnly = true; value.isAutoShutdownEnabled = true
            engine = value
        }
        guard let engine else { return }
        try engine.start()
        let event = CHHapticEvent(eventType: .hapticContinuous,
            parameters: [.init(parameterID: .hapticIntensity, value: intensity), .init(parameterID: .hapticSharpness, value: 0.5)],
            relativeTime: 0, duration: duration)
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        player = try engine.makePlayer(with: pattern); try player?.start(atTime: CHHapticTimeImmediate)
    }
}
