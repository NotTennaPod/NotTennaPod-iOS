import CoreMedia
import CoreVideo

/// Decoded picture ownership crosses actors only after all pixel mutation finishes.
/// Its time range remains in source-media time until the processing owner maps it.
public struct PlaybackVideoFrame: Sendable {
    public let pixelBuffer: CVReadOnlyPixelBuffer
    public let sourceRange: CMTimeRange
    public init(pixelBuffer: CVReadOnlyPixelBuffer, sourceRange: CMTimeRange) {
        self.pixelBuffer = pixelBuffer; self.sourceRange = sourceRange
    }
}

/// Independently pulled from the common bounded demux owner. Implementations must
/// not await presentation inside the audio pull: mapping requires future audio input.
public protocol PlaybackVideoDecoding: Sendable {
    func nextVideoFrame() async throws -> PlaybackVideoFrame?
    /// Idempotent cancellation must release a blocked video pull, including video-only sources.
    func cancelVideo() async
    /// At video EOF, one genuine last decoded picture may remain before the seek
    /// target. It is a display poster only; its original source range is unchanged.
    func videoPosterFrame() async -> PlaybackVideoFrame?
}

public extension PlaybackVideoDecoding {
    func videoPosterFrame() async -> PlaybackVideoFrame? { nil }
}
