import CFFmpegCodec
import Foundation

/// Synchronous callbacks run on the native demux owner's dedicated execution queue.
/// Cancellation must be safe from any thread and wake a blocked read without waiting
/// for that queue. A read lease cancels only its generation; a source owner retires its cache.
protocol MediaByteInput: Sendable {
    var sourceFailure: PCMSourceFailure? { get }
    var sourceRetry: PCMSourceRetry? { get }
    var length: Int64? { get }
    var declaredLength: Int64? { get }
    /// Initial source declaration; later range headers must not reclassify Ogg.
    var initialDeclaredLength: Int64? { get }
    var httpRepresentation: HTTPMediaRepresentation? { get }
    var supportsRandomAccess: Bool { get }
    /// This reader is waiting for uncached upstream bytes, not parsing cached data.
    var isWaitingForData: Bool { get }
    func prepareForSeek()
    func prepareForIndexedSeek(to offset: Int64)
    func read(at offset: Int64, maximumCount: Int) throws -> Data
    func checkFailure() throws
    func cancel()
}

extension MediaByteInput {
    func prepareForIndexedSeek(to offset: Int64) { prepareForSeek() }
    var sourceFailure: PCMSourceFailure? { nil }
    var sourceRetry: PCMSourceRetry? { nil }
    var declaredLength: Int64? { length }
    var initialDeclaredLength: Int64? { declaredLength }
    var httpRepresentation: HTTPMediaRepresentation? { nil }
    var isWaitingForData: Bool { false }
}

/// A playback source that can give each replacement demux its own cancellation scope.
protocol MediaByteLeaseSource: MediaByteInput {
    func makeReadLease() -> any MediaByteInput
}

final class BlockingReadExecutor: SerialExecutor {
    let queue = DispatchQueue(label: "AntennaPod.FFmpegReader")
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}

/// The demux owner retains this object until avformat_close_input has returned.
/// Only its execution queue accesses the cursor/error or the native IO context.
final class FFmpegAVIOInput {
    let input: any MediaByteInput
    private(set) var context: UnsafeMutablePointer<AVIOContext>?
    private var cursor: Int64 = 0
    private(set) var failure: (any Error)?

    init(input: any MediaByteInput) throws {
        self.input = input
        guard let buffer = av_malloc(32_768)?.assumingMemoryBound(to: UInt8.self) else {
            throw FFmpegAudioReader.Failure.allocation
        }
        context = avio_alloc_context(buffer, 32_768, 0, Unmanaged.passUnretained(self).toOpaque(),
            { opaque, buffer, count in
                guard let opaque, let buffer, count > 0 else { return -Int32(EINVAL) }
                let owner = Unmanaged<FFmpegAVIOInput>.fromOpaque(opaque).takeUnretainedValue()
                return owner.read(buffer: buffer, count: Int(count))
            }, nil, { opaque, offset, whence in
                guard let opaque else { return -Int64(EINVAL) }
                return Unmanaged<FFmpegAVIOInput>.fromOpaque(opaque).takeUnretainedValue()
                    .seek(offset: offset, whence: whence)
            })
        guard let context else { av_free(buffer); throw FFmpegAudioReader.Failure.allocation }
        // Initial sequential loading avoids end-of-file probing. A complete cache or
        // explicitly enabled range source permits indexed seek/duration inspection.
        context.pointee.seekable = input.supportsRandomAccess ? AVIO_SEEKABLE_NORMAL : 0
    }

    deinit {
        if let context { av_free(context.pointee.buffer) }
        avio_context_free(&context)
    }

    private func read(buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int32 {
        do {
            let data = try input.read(at: cursor, maximumCount: min(count, 65_536))
            guard !data.isEmpty else { return apCodecEOF() }
            guard data.count <= count, Int64(data.count) <= Int64.max - cursor else { return -Int32(EINVAL) }
            data.copyBytes(to: buffer, count: data.count)
            cursor += Int64(data.count)
            return Int32(data.count)
        } catch { failure = error; return -Int32(EIO) }
    }

    private func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence & AVSEEK_SIZE != 0 { return input.length ?? -Int64(ENOSYS) }
        let base: Int64
        switch whence & ~AVSEEK_FORCE {
        case SEEK_SET: base = 0
        case SEEK_CUR: base = cursor
        case SEEK_END:
            guard let length = input.length else { return -Int64(ENOSYS) }
            base = length
        default: return -Int64(EINVAL)
        }
        let result = base.addingReportingOverflow(offset)
        guard !result.overflow, result.partialValue >= 0 else { return -Int64(EINVAL) }
        cursor = result.partialValue
        return cursor
    }
}
