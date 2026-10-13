import AudioToolbox
import Foundation

enum StreamingAudioTypeError: Error, Equatable {
    case native(OSStatus)
    case unrecognized
    case closed
    case requiresNativePlaylist
}

/// A sequential native parser, owned exclusively by the HTTP source's serial queue.
/// It inspects incoming bytes without keeping a second copy of the media in Swift memory.
final class StreamingAudioTypeDetector {
    /// A container candidate, never a claim that a track/codec is supported.
    /// The typed demux boundary must inspect and validate it before selection.
    static let bufferedMediaIdentifier = "org.antennapod.ffmpeg-media"
    private var parser: AudioFileStreamID?
    private var pending = Data()
    private static let batchSize = 4096
    private(set) var typeIdentifier: String?
    private(set) var bytesExamined: Int64 = 0
    private(set) var maximumBufferedBytes = 0

    init() throws {
        let status = AudioFileStreamOpen(nil, { _, _, _, _ in }, { _, _, _, _, _ in }, 0, &parser)
        guard status == noErr else { throw StreamingAudioTypeError.native(status) }
    }

    deinit { close() }

    func append(_ bytes: Data) throws {
        guard typeIdentifier == nil else { return }
        guard parser != nil else { throw StreamingAudioTypeError.closed }
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = min(start + Self.batchSize - pending.count, bytes.endIndex)
            pending.append(bytes[start..<end])
            maximumBufferedBytes = max(maximumBufferedBytes, pending.count)
            start = end
            if pending.count == Self.batchSize {
                try parsePending()
                if typeIdentifier != nil { return }
            }
        }
    }

    private func parsePending() throws {
        guard !pending.isEmpty, let parser else { return }
        if bytesExamined == 0 {
            let prefix = pending.starts(with: [0xEF, 0xBB, 0xBF]) ? pending.dropFirst(3) : pending[...]
            if prefix.starts(with: Data("#EXTM3U".utf8)) { throw StreamingAudioTypeError.requiresNativePlaylist }
            if Self.isBufferedMediaCandidate(pending) {
                typeIdentifier = Self.bufferedMediaIdentifier
                bytesExamined += Int64(pending.count)
                close()
                return
            }
        }
        // AudioFileStream's auto-detection did not recognize one-byte ParseBytes calls.
        // Coalesce transport fragments into a fixed-size batch, flushing the tail at EOF.
        let status = pending.withUnsafeBytes { buffer in
            AudioFileStreamParseBytes(parser, UInt32(buffer.count), buffer.baseAddress!, [])
        }
        bytesExamined += Int64(pending.count)
        pending.removeAll(keepingCapacity: true)
        var format: AudioFileTypeID = 0
        var size = UInt32(MemoryLayout<AudioFileTypeID>.size)
        if AudioFileStreamGetProperty(parser, kAudioFileStreamProperty_FileFormat, &size, &format) == noErr,
           format != 0 {
            var identifiers: Unmanaged<CFArray>?
            var resultSize = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
            let result = AudioFileGetGlobalInfo(kAudioFileGlobalInfo_UTIsForType,
                UInt32(MemoryLayout<AudioFileTypeID>.size), &format, &resultSize, &identifiers)
            let values = identifiers?.takeRetainedValue() as? [String]
            if result == noErr, let identifier = values?.first {
                typeIdentifier = identifier
                close()
                return
            }
        }
        guard status == noErr else { throw StreamingAudioTypeError.native(status) }
    }

    private static func isBufferedMediaCandidate(_ bytes: Data) -> Bool {
        let prefix = Array(bytes.prefix(batchSize))
        if prefix.starts(with: Array("#!AMR\n".utf8)) || prefix.starts(with: Array("#!AMR-WB\n".utf8)) { return true }
        if prefix.count >= 12, prefix[0..<4].elementsEqual("RIFF".utf8),
           prefix[8..<12].elementsEqual("AVI ".utf8) { return true }
        if prefix.count >= 9, prefix[0..<3].elementsEqual("FLV".utf8), prefix[3] == 1,
           prefix[4] & ~UInt8(5) == 0 { return true }
        if prefix.starts(with: [0, 0, 1, 0xBA]) { return true }
        // A single sync byte is not a transport-stream signature. Check three
        // packet boundaries, including the four-byte timestamp prefix of M2TS.
        for (stride, offset) in [(188, 0), (192, 4), (204, 0)] {
            if prefix.count > offset + 2 * stride,
               prefix[offset] == 0x47, prefix[offset + stride] == 0x47,
               prefix[offset + 2 * stride] == 0x47 { return true }
        }
        return false
    }

    func finish() throws -> String {
        try parsePending()
        guard let typeIdentifier else { throw StreamingAudioTypeError.unrecognized }
        return typeIdentifier
    }

    func close() {
        if let parser { AudioFileStreamClose(parser) }
        parser = nil
        pending.removeAll()
    }
}
