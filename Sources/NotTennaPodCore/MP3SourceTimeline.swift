// Source timeline interpretation follows AndroidX Media3 (Apache-2.0).
// See Licenses/Android-MP3-Metadata.txt.
import Foundation

/// The original extractor's initial duration/seekability, independent of native
/// gapless audio length or a cache's later EOF-derived size.
struct MP3SourceTimeline: Equatable, Sendable {
    enum Failure: Error, Equatable { case invalidMetadata }
    let durationMicroseconds: Int64?
    let seekable: Bool
    private(set) var byteIndex: MP3SeekIndex? = nil

    init(frame: MP3XingMetadata.SourceFrame, firstAudioBytes: Data, declaredLength: Int64?) throws {
        let data = frame.bytes
        let audioBitrate = MP3XingMetadata.bitrate(in: firstAudioBytes) ?? frame.bitrate
        let audioFrameSize = MP3XingMetadata.frameByteCount(in: firstAudioBytes) ?? data.count
        let firstAudio = frame.offset + Int64(data.count)
        let marker = data.count >= frame.xingOffset + 4 ? try Self.word(data, frame.xingOffset) : 0
        if marker == 0x58696e67 || marker == 0x496e666f { // Xing / Info
            let flags = try Self.word(data, frame.xingOffset + 4)
            var cursor = frame.xingOffset + 8
            var frames: Int64?, dataSize: Int64?
            if flags & 1 != 0 {
                let count = try Self.word(data, cursor); cursor += 4
                guard count <= Int32.max else { throw Failure.invalidMetadata }
                if count > 0 { frames = Int64(count) * frame.framesPerPacket }
            }
            if flags & 2 != 0 { dataSize = Int64(try Self.word(data, cursor)); cursor += 4 }
            let hasTable = flags & 4 != 0
            if hasTable { cursor += 100 }
            if flags & 8 != 0 { cursor += 4 }
            guard cursor <= data.count else { throw Failure.invalidMetadata }
            if let frames {
                let duration = (frames - 1) * 1_000_000 / Int64(frame.sampleRate)
                if marker == 0x58696e67, hasTable {
                    // The table is the source seekability criterion. Byte-map
                    // validation/indexed seeking is separate from this timeline.
                    durationMicroseconds = duration
                    seekable = true
                    let tableStart = frame.xingOffset + 8 + (flags & 1 != 0 ? 4 : 0) + (flags & 2 != 0 ? 4 : 0)
                    if let dataSize, dataSize > data.count, duration > 0,
                       !frame.offset.addingReportingOverflow(dataSize).overflow {
                        let table = Array(data[tableStart..<(tableStart + 100)])
                        if zip(table, table.dropFirst()).allSatisfy({ $0 <= $1 }) {
                            byteIndex = .xing(start: frame.offset, headerSize: data.count,
                                duration: duration, dataSize: dataSize, table: table)
                        }
                    }
                    return
                }
                let end = dataSize.map { frame.offset + $0 } ?? declaredLength
                if let end {
                    // Both Info and the enabled enhanced-CBR Xing fallback use
                    // rounded average bitrate, then the CBR byte-derived duration.
                    let bytes = end - firstAudio
                    guard bytes > 0, duration > 0 else { throw Failure.invalidMetadata }
                    let numerator = Int128(bytes) * 8_000_000
                    var average = (numerator + Int128(duration / 2)) / Int128(duration)
                    if marker == 0x496e666f, average > Int32.max { throw Failure.invalidMetadata }
                    average = min(Int128(Int32.max), average)
                    guard average > 0 else { throw Failure.invalidMetadata }
                    self = try Self.constant(end: end, start: firstAudio, bitrate: Int32(average), frameSize: audioFrameSize)
                    return
                }
            }
            // The app enables CBR fallback, including Xing without a usable map.
            self = try Self.constant(end: declaredLength, start: firstAudio, bitrate: audioBitrate, frameSize: audioFrameSize)
        } else if data.count >= 40, try Self.word(data, 36) == 0x56425249 { // VBRI
            let count = Int64(try Self.word(data, 50))
            guard count <= Int32.max else { throw Failure.invalidMetadata }
            if count == 0 {
                self = try Self.constant(end: declaredLength, start: firstAudio, bitrate: audioBitrate, frameSize: audioFrameSize)
                return
            }
            let entries = try Self.short(data, 54), size = try Self.short(data, 58)
            if !(1...4).contains(size) {
                self = try Self.constant(end: declaredLength, start: firstAudio, bitrate: audioBitrate, frameSize: audioFrameSize)
                return
            }
            guard entries > 0, 62 + entries * size <= data.count else { throw Failure.invalidMetadata }
            durationMicroseconds = (count * frame.framesPerPacket - 1) * 1_000_000 / Int64(frame.sampleRate)
            seekable = true
            let scale = try Self.short(data, 56)
            var positions: [Int64] = [], times: [Int64] = [], position = firstAudio
            for index in 0..<entries {
                times.append(Int64(index) * durationMicroseconds! / Int64(entries))
                positions.append(position)
                let offset = 62 + index * size
                let segment = data[offset..<(offset + size)].reduce(Int64(0)) { ($0 << 8) | Int64($1) }
                guard size != 4 || segment <= Int32.max else { throw Failure.invalidMetadata }
                let next = Int128(position) + Int128(segment) * Int128(scale)
                guard let value = Int64(exactly: next) else { throw Failure.invalidMetadata }
                position = value
            }
            byteIndex = .vbri(times: times, positions: positions)
        } else {
            self = try Self.constant(end: declaredLength, start: frame.offset, bitrate: frame.bitrate, frameSize: data.count)
        }
    }

    private init(duration: Int64?, seekable: Bool) {
        durationMicroseconds = duration; self.seekable = seekable
    }
    func applying(_ required: MP3RequiredID3Metadata?) -> Self {
        required.map { Self(duration: $0.durationMicroseconds, seekable: true) } ?? self
    }
    private static func constant(end: Int64?, start: Int64, bitrate: Int32, frameSize: Int) throws -> Self {
        guard let end else { return Self(duration: nil, seekable: false) }
        guard bitrate > 0, end >= start,
              let duration = Int64(exactly: Int128(end - start) * 8_000_000 / Int128(bitrate)) else {
            throw Failure.invalidMetadata
        }
        var result = Self(duration: duration, seekable: true)
        result.byteIndex = .constant(start: start, end: end, bitrate: bitrate, frameSize: frameSize)
        return result
    }
    private static func word(_ data: Data, _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw Failure.invalidMetadata }
        return data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }
    private static func short(_ data: Data, _ offset: Int) throws -> Int {
        guard offset >= 0, offset + 2 <= data.count else { throw Failure.invalidMetadata }
        return Int(data[offset]) << 8 | Int(data[offset + 1])
    }
}
