import Darwin
import Foundation
import Synchronization

/// Positional reads never share a mutable cursor. Each disposable lease has
/// independent cancellation; the descriptor closes only after all owners go.
final class LocalAudioBytes: Sendable {
    private let file: FileHandle?
    private let document: LocalPlaybackDocument?
    let length: Int64
    init(url: URL) throws {
        guard url.isFileURL else { throw NativePCMDecoder.Failure.notLocal }
        let file = try FileHandle(forReadingFrom: url)
        var info = stat()
        guard fstat(file.fileDescriptor, &info) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else { throw NativePCMDecoder.Failure.invalidFormat }
        self.file = file; document = nil; length = info.st_size
    }
    init(document: LocalPlaybackDocument) throws {
        guard document.length > 0 else { throw NativePCMDecoder.Failure.invalidFormat }
        self.document = document; file = nil; length = document.length
    }
    /// Identification keeps the same descriptor that playback will consume.
    /// Unknown containers retain the existing reader's validation behavior.
    static func openIdentified(url: URL) async throws -> (file: LocalAudioBytes, format: PCMRemoteInput.Format)? {
        do {
            let file = try LocalAudioBytes(url: url)
            return (file, try await file.identify())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }
    func identify() async throws -> PCMRemoteInput.Format {
        let input = lease()
        defer { input.cancel() }
        return try await withTaskCancellationHandler {
            let result = try await PCMRemoteInput.Probe(input: input).identify()
            try Task.checkCancellation()
            return result.format
        } onCancel: { input.cancel() }
    }
    deinit { try? file?.close() }
    func lease() -> any MediaByteLeaseSource { Lease(owner: self) }
    private func read(at offset: Int64, maximumCount: Int) throws -> Data {
        guard let file else { throw NativePCMDecoder.Failure.notLocal }
        guard offset >= 0, (1...65536).contains(maximumCount) else { throw NativeAudioStreamParser.Failure.invalidCapacity }
        guard offset < length else { return Data() }
        var result = Data(count: Int(min(Int64(maximumCount), length - offset)))
        let count = result.withUnsafeMutableBytes { buffer in
            var count: Int
            repeat { count = pread(file.fileDescriptor, buffer.baseAddress!, buffer.count, offset) } while count < 0 && errno == EINTR
            return count
        }
        guard count >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard count > 0 else { throw MediaDownloadError.wrongSize(expected: length, received: offset) }
        result.count = count
        return result
    }
    private final class Lease: MediaByteLeaseSource {
        private let owner: LocalAudioBytes, cancelled = Mutex(false)
        private let reader: LocalPlaybackDocument.Reader?
        init(owner: LocalAudioBytes) { self.owner = owner; reader = owner.document?.makeReader() }
        deinit { cancel() }
        var length: Int64? { owner.length }
        var supportsRandomAccess: Bool { true }
        func makeReadLease() -> any MediaByteInput { Lease(owner: owner) }
        func prepareForSeek() {}
        func cancel() { cancelled.withLock { $0 = true }; reader?.cancel() }
        func checkFailure() throws { if cancelled.withLock({ $0 }) { throw CancellationError() } }
        func read(at offset: Int64, maximumCount: Int) throws -> Data {
            try Task.checkCancellation(); try checkFailure()
            let result = try reader.map { try $0.readSynchronously(at: offset, maximumCount: maximumCount) }
                ?? owner.read(at: offset, maximumCount: maximumCount)
            try checkFailure(); try Task.checkCancellation()
            return result
        }
    }
}
