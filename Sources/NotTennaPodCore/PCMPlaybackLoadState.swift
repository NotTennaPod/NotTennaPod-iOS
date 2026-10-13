import Foundation

/// Renderer-mapped media position and accepted playback speed, never decoder progress.
struct PCMPlaybackLoadState: Equatable, Sendable {
    let positionMicroseconds: Int64
    let speed: Float

    init(positionMicroseconds: Int64, speed: Float) throws {
        guard positionMicroseconds >= 0, speed.isFinite, speed > 0 else { throw PlaybackLoadControl.Failure.invalidInput }
        self.positionMicroseconds = positionMicroseconds
        self.speed = speed
    }
}
