// MP4 box interpretation follows AndroidX Media3 (Apache-2.0).
// See Licenses/Android-Native-Audio-Metadata.txt.
import Foundation

/// Supplies Apple's random-access audio file API with a verified byte extent.
/// MP4 box boundaries locate metadata without retaining skipped media. A box's
/// declared end is never itself accepted as the end of the whole file.
final class NativeMP4Input: MediaByteInput {
    enum Failure: Error, Equatable { case invalidBox, incompleteBox, unknownSizedBox }
    let length: Int64?
    private let input: any MediaByteInput

    static func open(remote: PCMRemoteInput) async throws -> NativeMP4Input {
        remote.input.allowDecoderRangeSeeks()
        return try await open(input: remote.makeReadLease())
    }

    static func open(input: any MediaByteInput) async throws -> NativeMP4Input {
        do {
            let reader = ExtentReader(input: input)
            let extent = try await withTaskCancellationHandler {
                let extent = try await reader.prepare()
                try Task.checkCancellation()
                return extent
            } onCancel: { input.cancel() }
            return NativeMP4Input(input: input, extent: extent)
        } catch { input.cancel(); throw error }
    }

    private init(input: any MediaByteInput, extent: Int64) { self.input = input; length = extent }
    deinit { input.cancel() }
    var declaredLength: Int64? { input.declaredLength }
    var initialDeclaredLength: Int64? { input.initialDeclaredLength }
    var httpRepresentation: HTTPMediaRepresentation? { input.httpRepresentation }
    var supportsRandomAccess: Bool { input.supportsRandomAccess }
    var isWaitingForData: Bool { input.isWaitingForData }
    var sourceFailure: PCMSourceFailure? { input.sourceFailure }
    var sourceRetry: PCMSourceRetry? { input.sourceRetry }
    func prepareForSeek() { input.prepareForSeek() }
    func prepareForIndexedSeek(to offset: Int64) { input.prepareForIndexedSeek(to: offset) }
    func checkFailure() throws { try input.checkFailure() }
    func cancel() { input.cancel() }
    func read(at offset: Int64, maximumCount: Int) throws -> Data { try input.read(at: offset, maximumCount: maximumCount) }

    private actor ExtentReader {
        nonisolated private let executor = BlockingReadExecutor()
        nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
        let input: any MediaByteInput
        private var position: Int64 = 0
        init(input: any MediaByteInput) { self.input = input }

        func prepare() throws -> Int64 {
            if let length = try knownLength() { return length }
            while true {
                let start = position
                let header = try bytes(8)
                if let length = try knownLength() { return length }
                if header.isEmpty {
                    // Sequential reads, or the explicit last-byte check below,
                    // proved that the byte directly before this EOF exists.
                    guard start > 0 else { throw Failure.incompleteBox }
                    return start
                }
                guard header.count == 8 else { throw Failure.incompleteBox }
                var size = Self.big(header.prefix(4))
                var headerSize: UInt64 = 8
                if size == 1 {
                    let extended = try bytes(8)
                    guard extended.count == 8 else { throw Failure.incompleteBox }
                    size = Self.big(extended); headerSize = 16
                }
                // An EOF-sized top-level atom cannot locate a later index.
                // The configured original extractor also rejects it while the
                // extent is unknown. Do not silently guess or force a spool.
                guard size != 0 else { throw Failure.unknownSizedBox }
                guard size >= headerSize, let count = Int64(exactly: size),
                      start <= Int64.max - count else { throw Failure.invalidBox }
                let end = start + count
                if end - position >= 256 * 1024 {
                    // Check the last byte as well as the following header. A
                    // truncated box returning EOF at a distant offset must not
                    // manufacture a huge file length from its corrupt header.
                    input.prepareForIndexedSeek(to: end - 1)
                    position = end - 1
                    guard try bytes(1).count == 1 else { throw Failure.incompleteBox }
                    if let length = try knownLength() { return length }
                } else {
                    while position < end {
                        let count = Int(min(4096, end - position))
                        guard try bytes(count).count == count else { throw Failure.incompleteBox }
                    }
                }
            }
        }

        private func knownLength() throws -> Int64? {
            try Task.checkCancellation()
            try input.checkFailure()
            guard let length = input.length else { return nil }
            guard length > 0, position <= length else { throw Failure.invalidBox }
            return length
        }
        private func bytes(_ count: Int) throws -> Data {
            var result = Data()
            while result.count < count {
                try Task.checkCancellation()
                try input.checkFailure()
                let data = try input.read(at: position, maximumCount: count - result.count)
                guard data.count <= count - result.count, position <= Int64.max - Int64(data.count) else {
                    throw Failure.invalidBox
                }
                if data.isEmpty { break }
                position += Int64(data.count)
                result.append(data)
            }
            return result
        }
        private static func big(_ bytes: Data) -> UInt64 {
            bytes.reduce(0) { ($0 << 8) | UInt64($1) }
        }
    }
}
