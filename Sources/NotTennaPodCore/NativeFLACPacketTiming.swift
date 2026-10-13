import Foundation

/// AudioFileStream can report both ASBD and packet frame counts as zero for
/// variable-block FLAC. Read only the missing timing from the native packet's
/// RFC9639 header; native parsing and conversion still own packet/audio decoding.
enum NativeFLACPacketTiming {
    static func maximumFrameCount(in prefix: Data) -> UInt32? {
        // STREAMINFO is the mandatory first metadata block; its first four bytes
        // declare minimum/maximum blocks independently of fixed/variable mode.
        guard prefix.count >= 42, prefix.prefix(4) == Data("fLaC".utf8),
              prefix[4] & 127 == 0, prefix[5] == 0, prefix[6] == 0, prefix[7] == 34 else { return nil }
        let minimum = UInt32(prefix[8]) << 8 | UInt32(prefix[9])
        let maximum = UInt32(prefix[10]) << 8 | UInt32(prefix[11])
        return minimum >= 16 && maximum >= minimum ? maximum : nil
    }

    static func frameCount(in bytes: UnsafeRawBufferPointer) throws -> UInt32 {
        func invalid() -> NativeAudioStreamParser.Failure { .invalidPacket }
        guard bytes.count >= 6, bytes[0] == 255, bytes[1] & 0xfe == 0xf8,
              bytes[3] & 1 == 0, bytes[3] >> 4 <= 10, bytes[3] >> 1 & 7 != 3 else { throw invalid() }
        var cursor = 4
        func byte() throws -> UInt8 {
            guard cursor < bytes.count else { throw invalid() }
            defer { cursor += 1 }; return bytes[cursor]
        }
        func word() throws -> UInt32 { let high = try byte(); return UInt32(high) << 8 | UInt32(try byte()) }
        let first = try byte()
        var width = 0, mask: UInt8 = 128
        while mask != 0 && first & mask != 0 { width += 1; mask >>= 1 }
        guard width != 1, width <= 7 else { throw invalid() }
        if width > 0 {
            for _ in 1..<width { guard try byte() & 0xc0 == 0x80 else { throw invalid() } }
        }
        let count: UInt32
        let blockKey = bytes[2] >> 4
        switch blockKey {
        case 1: count = 192
        case 2...5: count = 576 << (blockKey - 2)
        case 6: count = UInt32(try byte()) + 1
        case 7: count = try word() + 1
        case 8...15: count = 256 << (blockKey - 8)
        default: throw invalid()
        }
        switch bytes[2] & 15 {
        case 12: _ = try byte()
        case 13, 14: _ = try word()
        case 15: throw invalid()
        default: break
        }
        let end = cursor, crc = try byte()
        var expected: UInt8 = 0
        for value in bytes.prefix(end) {
            expected ^= value
            for _ in 0..<8 { expected = expected & 128 != 0 ? (expected &<< 1) ^ 7 : expected &<< 1 }
        }
        guard crc == expected, count <= 65535 else { throw invalid() }
        return count
    }
}
