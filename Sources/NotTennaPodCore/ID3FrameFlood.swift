import Darwin
import Foundation

/// Apple's AudioFile parses a file's ID3v2 tag in time that grows with the square of its frame
/// count (20,000 tiny frames took 1.9 seconds to open on a Mac; a 256 MB tag of them would never finish).
/// Real tags hold tens of frames, a few hundred with chapters. When a local file's tag holds more than
/// `maximumFrames`, AudioFile is shown the frames as padding (playback needs only the audio after the tag),
/// and the metadata reader uses the FFmpeg path, which reads such a tag quickly.
enum ID3FrameFlood {
    static let maximumFrames = 2_000

    /// The byte range of the tag's frames when the file starts with an ID3v2 tag of more than `maximumFrames`
    /// frames; nil otherwise or when the tag cannot be read.
    static func floodedFrames(fileDescriptor: Int32, length: Int64) -> Range<Int64>? {
        var block = (start: Int64(-1), bytes: [UInt8]())
        func byte(_ offset: Int64) -> UInt8? {
            guard offset >= 0, offset < length else { return nil }
            if offset < block.start || offset >= block.start + Int64(block.bytes.count) {
                let start = offset - offset % 65_536
                var bytes = [UInt8](repeating: 0, count: Int(min(65_536, length - start)))
                var count = 0
                repeat { count = bytes.withUnsafeMutableBytes { pread(fileDescriptor, $0.baseAddress, $0.count, off_t(start)) } }
                while count < 0 && errno == EINTR
                guard count > 0 else { return nil }
                block = (start, Array(bytes.prefix(count)))
                guard offset < start + Int64(count) else { return nil }
            }
            return block.bytes[Int(offset - block.start)]
        }
        func integer(_ offset: Int64, _ width: Int, synchsafe: Bool) -> Int64? {
            var value: Int64 = 0
            for index in 0..<Int64(width) {
                guard let next = byte(offset + index) else { return nil }
                value = synchsafe ? value << 7 | Int64(next & 0x7F) : value << 8 | Int64(next)
            }
            return value
        }
        guard byte(0) == 0x49, byte(1) == 0x44, byte(2) == 0x33, let version = byte(3), (2...4).contains(version),
              let flags = byte(5), let size = integer(6, 4, synchsafe: true) else { return nil }
        let end = min(length, 10 + size)
        var position: Int64 = 10
        if version >= 3, flags & 0x40 != 0, let extended = integer(10, 4, synchsafe: version == 4) {
            position += version == 4 ? extended : extended + 4
        }
        let start = position
        let header: Int64 = version == 2 ? 6 : 10
        var frames = 0
        while position + header <= end {
            guard let first = byte(position), first != 0,
                  let frameSize = version == 2 ? integer(position + 3, 3, synchsafe: false)
                    : integer(position + 4, 4, synchsafe: version == 4) else { return nil }
            frames += 1
            if frames > maximumFrames { return start..<end }
            position += header + frameSize
        }
        return nil
    }

    /// Zeroes the part of `buffer` (`count` bytes read at `offset`) inside `range`.
    static func mask(_ range: Range<Int64>?, buffer: UnsafeMutableRawPointer, offset: Int64, count: Int) {
        guard let range, count > 0 else { return }
        let lower = max(range.lowerBound, offset), upper = min(range.upperBound, offset + Int64(count))
        guard lower < upper else { return }
        memset(buffer.advanced(by: Int(lower - offset)), 0, Int(upper - lower))
    }
}
