// MPEG/Xing field interpretation follows AndroidX Media3 (Apache-2.0).
// See Licenses/Android-MP3-Metadata.txt for source provenance and attribution.
import Foundation

/// Bounded metadata supplement for omitted or confirmed estimated native fields. This does
/// not demux audio, estimate duration, or replace the native format/packet parser.
struct MP3XingMetadata {
    struct SourceFrame: Sendable {
        let bytes: Data
        let offset: Int64
        let sampleRate: Int32
        let framesPerPacket: Int64
        let bitrate: Int32
        let xingOffset: Int
    }
    struct InfoFrames {
        let sampleRate: Int32
        let channels: Int
        let encodedFrames: Int64
    }
    struct Padding {
        let sampleRate: Int32
        let channels: Int
        let encodedFrames: Int64
        let leading: Int64
        let trailing: Int64
    }
    private struct Header {
        let sampleRate: Int32
        let channels: Int
        let framesPerPacket: Int64
        let byteCount: Int
        let xingOffset: Int
        let bitrate: Int32
    }
    private var prefix = Data()
    private var skippedTagBytes = 0
    private var searchedBytes = 0
    private var header: Header?
    private var prefixOffset: Int64 = 0
    private let retainSourceFrame: Bool
    private(set) var isFinished = false
    private(set) var infoFrames: InfoFrames?
    private(set) var padding: Padding?
    private(set) var sourceFrame: SourceFrame?
    var retainedByteCount: Int { prefix.count + (sourceFrame?.bytes.count ?? 0) }

    init(retainSourceFrame: Bool = false) { self.retainSourceFrame = retainSourceFrame }
    mutating func takeSourceFrame() -> SourceFrame? {
        let frame = sourceFrame; sourceFrame = nil; return frame
    }

    mutating func append(_ data: Data) {
        guard !isFinished else { return }
        var index = data.startIndex
        while index < data.endIndex, !isFinished {
            if skippedTagBytes > 0 {
                let count = min(skippedTagBytes, data.endIndex - index)
                index += count
                skippedTagBytes -= count
                prefixOffset += Int64(count)
                continue
            }
            let target = header?.byteCount ?? 10
            let count = min(target - prefix.count, data.endIndex - index)
            prefix.append(contentsOf: data[index..<(index + count)])
            index += count
            guard prefix.count == target else { return }
            if let header {
                if retainSourceFrame {
                    sourceFrame = SourceFrame(bytes: prefix, offset: prefixOffset, sampleRate: header.sampleRate,
                        framesPerPacket: header.framesPerPacket, bitrate: header.bitrate, xingOffset: header.xingOffset)
                }
                infoFrames = Self.infoFrames(in: prefix, header: header)
                padding = Self.padding(in: prefix, header: header)
                finish()
            } else if prefix.starts(with: [0x49, 0x44, 0x33]) {
                guard (2...4).contains(prefix[3]), prefix[4] != 0xff,
                      prefix[6...9].allSatisfy({ $0 < 128 }) else { finish(); return }
                skippedTagBytes = prefix[6...9].reduce(0) { ($0 << 7) | Int($1) }
                prefixOffset += 10
                prefix.removeAll(keepingCapacity: true)
            } else if let parsed = Self.header(prefix) {
                header = parsed
            } else {
                // Match the original non-sniffing synchronization search budget.
                searchedBytes += 1
                guard searchedBytes < 131_072 else { finish(); return }
                prefix = Data(prefix.dropFirst())
                prefixOffset += 1
            }
        }
    }

    private mutating func finish() {
        isFinished = true
        prefix.removeAll()
        header = nil
    }

    static func frameByteCount(in bytes: Data) -> Int? {
        guard bytes.count >= 4 else { return nil }
        return header(bytes)?.byteCount
    }

    private static func header(_ bytes: Data) -> Header? {
        let bits = word(bytes, 0)
        let version = (bits >> 19) & 3
        let bitrateIndex = Int((bits >> 12) & 15)
        let rateIndex = Int((bits >> 10) & 3)
        guard bits & 0xffe00000 == 0xffe00000, version != 1,
              (bits >> 17) & 3 == 1, (1...14).contains(bitrateIndex), rateIndex < 3 else { return nil }
        let rates = [44100, 48000, 32000]
        let rate = rates[rateIndex] / (version == 3 ? 1 : version == 2 ? 2 : 4)
        let bitrates = version == 3
            ? [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
            : [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        let count = (version == 3 ? 144 : 72) * bitrates[bitrateIndex - 1] * 1000 / rate + Int((bits >> 9) & 1)
        let channels = (bits >> 6) & 3 == 3 ? 1 : 2
        return Header(sampleRate: Int32(rate), channels: channels, framesPerPacket: version == 3 ? 1152 : 576,
            byteCount: count, xingOffset: version == 3 ? (channels == 1 ? 21 : 36) : (channels == 1 ? 13 : 21),
            bitrate: Int32(bitrates[bitrateIndex - 1] * 1000))
    }

    static func bitrate(in bytes: Data) -> Int32? {
        guard bytes.count >= 4 else { return nil }
        return header(bytes)?.bitrate
    }

    private static func infoFrames(in bytes: Data, header: Header) -> InfoFrames? {
        let position = header.xingOffset
        guard position + 12 <= bytes.count, word(bytes, position) == 0x496e666f,
              word(bytes, position + 4) & 1 != 0 else { return nil }
        let packets = word(bytes, position + 8)
        guard packets > 0, packets <= Int32.max else { return nil }
        return InfoFrames(sampleRate: header.sampleRate, channels: header.channels,
            encodedFrames: Int64(packets) * header.framesPerPacket)
    }

    private static func padding(in bytes: Data, header: Header) -> Padding? {
        var position = header.xingOffset
        guard position + 8 <= bytes.count else { return nil }
        let marker = word(bytes, position)
        guard marker == 0x58696e67 || marker == 0x496e666f else { return nil } // Xing / Info
        let flags = word(bytes, position + 4)
        position += 8
        guard flags & 1 != 0, position + 4 <= bytes.count else { return nil }
        let packets = word(bytes, position)
        guard packets > 0, packets <= Int32.max else { return nil }
        position += 4
        if flags & 2 != 0 { position += 4 }
        if flags & 4 != 0 { position += 100 }
        if flags & 8 != 0 { position += 4 }
        // Encoder extension: version9 + revision1 + lowpass1 + ReplayGain8
        // + encoding flags1 + bitrate1, followed by two packed12-bit counts.
        guard position + 24 <= bytes.count else { return nil }
        position += 21
        let packed = Int64(bytes[position]) << 16 | Int64(bytes[position + 1]) << 8 | Int64(bytes[position + 2])
        let leading = packed >> 12, trailing = packed & 4095
        let frames = Int64(packets) * header.framesPerPacket
        guard leading + trailing <= frames else { return nil }
        return Padding(sampleRate: header.sampleRate, channels: header.channels, encodedFrames: frames,
            leading: leading, trailing: trailing)
    }

    private static func word(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
