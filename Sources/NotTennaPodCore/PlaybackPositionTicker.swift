import Foundation

@MainActor protocol PlaybackPositionTicking: AnyObject {
    func start(_ tick: @escaping @MainActor () -> Void)
    func stop()
}

/// Active service polls once per second. Main-run-loop ownership keeps delivery ordered with
/// commands and UI; the engine separately fences each subscription and media generation.
@MainActor final class PlaybackPositionTicker: PlaybackPositionTicking {
    private var timer: Timer?
    func start(_ tick: @escaping @MainActor () -> Void) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        // Lets iOS combine this wake-up with others; fire dates do not drift.
        timer.tolerance = 0.1
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func stop() { timer?.invalidate(); timer = nil }
    isolated deinit { stop() }
}
