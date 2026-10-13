import Foundation

/// Pinned active-player policy. Durations describe buffered encoded media, and byte
/// allocation includes retained sample queues; neither means PCM output or HTTP file size.
struct PlaybackLoadControl: Sendable {
    enum Failure: Error { case invalidInput }
    static let minimumBufferMicroseconds: Int64 = 3_600_000_000
    static let maximumBufferMicroseconds: Int64 = 10_800_000_000
    static let backBufferMicroseconds: Int64 = 300_000_000
    static let retainBackBufferFromKeyframe = true
    static let audioTargetBytes: Int64 = 200 * 65_536
    static let streamingCacheBytes: Int64 = 100 * 1024 * 1024
    private(set) var isLoading = false

    mutating func shouldContinueLoading(bufferedMicroseconds: Int64, speed: Float,
                                        allocatedBytes: Int64, targetBytes: Int64 = audioTargetBytes) throws -> Bool {
        try validate(bufferedMicroseconds, speed, allocatedBytes, targetBytes)
        let targetReached = allocatedBytes >= targetBytes
        let minimum = speed > 1
            ? min(Self.roundDuration(Double(Self.minimumBufferMicroseconds) * Double(speed)), Self.maximumBufferMicroseconds)
            : Self.minimumBufferMicroseconds
        if bufferedMicroseconds < minimum { isLoading = !targetReached }
        else if bufferedMicroseconds >= Self.maximumBufferMicroseconds || targetReached { isLoading = false }
        return isLoading
    }

    func shouldStartPlayback(bufferedMicroseconds: Int64, speed: Float, rebuffering: Bool,
                             allocatedBytes: Int64, targetBytes: Int64 = audioTargetBytes,
                             targetLiveOffsetMicroseconds: Int64? = nil) throws -> Bool {
        try validate(bufferedMicroseconds, speed, allocatedBytes, targetBytes)
        var minimum: Int64 = rebuffering ? 2_000_000 : 1_000_000
        if let liveOffset = targetLiveOffsetMicroseconds {
            guard liveOffset >= 0 else { throw Failure.invalidInput }
            minimum = min(minimum, liveOffset / 2)
        }
        let playout = speed == 1 ? bufferedMicroseconds : Self.roundDuration(Double(bufferedMicroseconds) / Double(speed))
        return minimum <= 0 || playout >= minimum || allocatedBytes >= targetBytes
    }

    mutating func reset() { isLoading = false }

    private func validate(_ duration: Int64, _ speed: Float, _ bytes: Int64, _ target: Int64) throws {
        guard duration >= 0, speed.isFinite, speed > 0, bytes >= 0, target > 0 else { throw Failure.invalidInput }
    }

    /// Java Math.round(double), including saturation, for these nonnegative durations.
    private static func roundDuration(_ value: Double) -> Int64 {
        if value >= Double(Int64.max) { return .max }
        return Int64(floor(value + 0.5))
    }
}

/// Decisions for already-classified source causes. URLSession-to-source classification,
/// load scheduling and deferred sample-queue resets remain integration responsibilities.
enum PlaybackLoadRetryPolicy {
    enum Cause: String, Codable, CaseIterable, Sendable {
        case network, httpResponse, parser, fileNotFound, cleartextNotPermitted, unexpectedLoader, positionOutOfRange
    }
    enum Recovery: Equatable {
        case resumeCurrentPosition
        case deferUntilSamplesExhausted
        case restartAtZero(notifyDiscontinuity: Bool)
    }

    static func retryDelayMilliseconds(errorCount: Int, causes: [Cause]) throws -> Int64? {
        guard errorCount > 0 else { throw PlaybackLoadControl.Failure.invalidInput }
        if causes.contains(where: { $0 != .network && $0 != .httpResponse }) { return nil }
        return Int64(min(errorCount - 1, 5)) * 1000
    }

    static func minimumRetryCount(progressiveLive: Bool) -> Int { progressiveLive ? 6 : 3 }

    /// Loader.maybeThrowError's threshold; this is not a scheduling limit or an
    /// instruction to fail while buffered samples can still satisfy the renderer.
    static func mayThrowCurrentError(errorCount: Int, progressiveLive: Bool) -> Bool {
        errorCount > minimumRetryCount(progressiveLive: progressiveLive)
    }

    static func recovery(lengthKnown: Bool, durationKnown: Bool, prepared: Bool, readSuppressed: Bool) -> Recovery {
        if lengthKnown || durationKnown { return .resumeCurrentPosition }
        if prepared && !readSuppressed { return .deferUntilSamplesExhausted }
        return .restartAtZero(notifyDiscontinuity: prepared)
    }
}
