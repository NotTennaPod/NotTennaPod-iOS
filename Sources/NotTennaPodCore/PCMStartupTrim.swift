import CoreMedia

/// A source's startup-only trim interval. Position, rather than a newly opened
/// decoder's first buffer, determines which frames belong to encoder delay.
/// End padding is a separate processing/transition policy.
struct PCMStartupTrim: Sendable {
    let frameCount: Int64
    var origin: CMTime = .zero

    static func mp4(_ trim: NativeMP4SourceTimeline.AudioTrim, sampleRate: Int) throws -> Self {
        guard (1...768_000).contains(sampleRate), trim.delay >= 0,
              trim.unitsPerSecond == nil || trim.unitsPerSecond! > 0,
              let frames = Int64(exactly: Int128(trim.delay) * Int128(trim.unitsPerSecond == nil ? 1 : sampleRate)
                / Int128(trim.unitsPerSecond ?? 1)) else { throw LocalPCMPlaybackStream.Failure.invalidInput }
        return Self(frameCount: frames)
    }

    func validate(sampleRate: Int) throws {
        guard (1...768_000).contains(sampleRate), frameCount >= 0,
              origin.isNumeric, origin.epoch == 0 else { throw LocalPCMPlaybackStream.Failure.invalidInput }
    }

    func framesToRemove(at time: CMTime, frames: Int, sampleRate: Int) throws -> Int {
        try validate(sampleRate: sampleRate)
        guard frames > 0, time.isNumeric, time.epoch == 0 else { throw LocalPCMPlaybackStream.Failure.invalidInput }
        // Pre-origin data is outside this interval; source admission owns preroll.
        guard time >= origin else { return 0 }
        let relative = CMTimeConvertScale(time - origin, timescale: Int32(sampleRate), method: .roundAwayFromZero)
        guard relative.isNumeric, relative.value >= 0 else { throw LocalPCMPlaybackStream.Failure.invalidInput }
        // Original source timestamps truncate to microseconds. Ceiling recovers
        // the sample-grid position without losing a frame at fragmented edges.
        return Int(min(Int64(frames), max(0, frameCount - min(frameCount, relative.value))))
    }
}
