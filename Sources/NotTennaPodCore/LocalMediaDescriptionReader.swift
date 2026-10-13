import Foundation

/// The source first tries ID3; only a failed ID3 read falls back to Vorbis/Opus.
/// Unavailable comments do not fail otherwise readable native media metadata.
public enum LocalMediaDescriptionReader {
    public static func read(url: URL, checkCancellation: () throws -> Void = {}) throws -> String? {
        // Once the caller's probe aborts, later format fallbacks must not swallow
        // it merely because a stateful probe throws only on its first signal.
        var abort: (any Error)?
        func poll() throws {
            if let abort { throw abort }
            do { try checkCancellation() }
            catch { abort = error; throw error }
        }
        try poll()
        do { return try ID3CommentReader.read(url: url, checkCancellation: poll) }
        catch is CancellationError { throw CancellationError() }
        catch { try poll() }
        do { return try VorbisDescriptionReader.read(url: url, checkCancellation: poll) }
        catch is CancellationError { throw CancellationError() }
        catch { try poll(); return nil }
    }
}
