import Foundation

/// Cancellable metadata I/O outside an actor/cooperative thread. The caller owns
/// the input scope; cancelling preparation retires that scope, not its shared cache.
final class MatroskaTimelineLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    private func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }

    func load(url: URL?, input: (any MediaByteInput)?) async throws -> MatroskaTimeline {
        guard (url != nil) != (input != nil), url?.isFileURL ?? true else { throw MatroskaTimeline.Failure.malformed }
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MatroskaTimeline, any Error>) in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    continuation.resume(with: Result {
                        try check()
                        let file = try url.map { try FileHandle(forReadingFrom: $0) }
                        defer { try? file?.close() }
                        return try MatroskaTimeline.read(bytes: { offset, count in
                            try self.check()
                            if let input { return try input.read(at: offset, maximumCount: count) }
                            guard let file else { throw MatroskaTimeline.Failure.malformed }
                            try file.seek(toOffset: UInt64(offset))
                            return try file.read(upToCount: count) ?? Data()
                        }, onCueSeek: { _ in input?.prepareForSeek() }, checkCancellation: {
                            try self.check()
                            try input?.checkFailure()
                        })
                    })
                }
            }
        } onCancel: { self.cancel(); input?.cancel() }
        try Task.checkCancellation()
        try check()
        return value
    }
}
