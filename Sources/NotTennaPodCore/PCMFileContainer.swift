import AudioToolbox
import CFFmpegCodec
import Foundation

/// Content-only selection for the existing local readers. A probe identifies a
/// candidate container; the selected reader still validates its streams/packets.
enum PCMFileContainer: Equatable, Sendable {
    case native, buffered

    @concurrent static func select(url: URL) async throws -> Self {
        guard url.isFileURL else { throw NativePCMDecoder.Failure.notLocal }
        try Task.checkCancellation()
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        // Match the bundled demuxer's format-probe extent (PROBE_BUF_MIN/MAX).
        // No filename or MIME hint is supplied, including for opaque downloads.
        let maximum = 1 << 20
        var target = 2048, bytes = Data()
        while true {
            try Task.checkCancellation()
            let next = try file.read(upToCount: target - bytes.count) ?? Data()
            bytes.append(next)
            if isBufferedContainer(bytes) { return .buffered }
            if next.isEmpty || bytes.count == maximum { return .native }
            if bytes.count == target { target = min(maximum, target * 2) }
        }
    }

    /// AVURLAsset may reject an otherwise readable file solely because its suffix
    /// is unknown. Supply the actual native container MIME, never a feed's guess.
    static func nativeContentType(url: URL) throws -> String? {
        try Task.checkCancellation()
        let input = try NativeAudioFileInput(url: url)
        let values = try input.strings(kAudioFileGlobalInfo_MIMETypesForType)
        try Task.checkCancellation()
        return values.first
    }

    static func isBufferedContainer(_ bytes: Data) -> Bool {
        guard !bytes.isEmpty else { return false }
        // libavformat requires zero padding after the available probe bytes.
        var padded = Array(bytes) + [UInt8](repeating: 0, count: Int(AVPROBE_PADDING_SIZE))
        return padded.withUnsafeMutableBufferPointer { buffer in
            "".withCString { filename in
                var probe = AVProbeData(filename: filename, buf: buffer.baseAddress,
                    buf_size: Int32(bytes.count), mime_type: nil)
                var score: Int32 = 0
                guard let format = av_probe_input_format3(&probe, 1, &score), score > 0,
                      let name = format.pointee.name else { return false }
                let names = String(cString: name).split(separator: ",")
                return names.contains("ogg") || names.contains("matroska")
            }
        }
    }
}
