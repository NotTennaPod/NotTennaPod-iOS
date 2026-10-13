// Seek-map interpretation follows AndroidX Media3 (Apache-2.0).
// See Licenses/Android-MP3-Metadata.txt.
import Foundation

/// Source time/byte mapping, separate from decoder packet ordinals. A seek
/// position can lie inside a packet and must be synchronized before decoding.
enum MP3SeekIndex: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        let timeMicroseconds: Int64
        let bytePosition: Int64
    }
    struct Points: Equatable, Sendable {
        let first: Point
        let second: Point?
    }
    case constant(start: Int64, end: Int64, bitrate: Int32, frameSize: Int)
    case xing(start: Int64, headerSize: Int, duration: Int64, dataSize: Int64, table: [UInt8])
    case vbri(times: [Int64], positions: [Int64])

    func points(at requestedTime: Int64) -> Points {
        let time = max(0, requestedTime)
        switch self {
        case let .constant(start, end, bitrate, frameSize):
            let unaligned = Int128(time) * Int128(bitrate) / 8_000_000
            let aligned = unaligned / Int128(frameSize) * Int128(frameSize)
            let offset = max(0, min(aligned, Int128(end) - Int128(start) - Int128(frameSize)))
            let position = start + Int64(offset)
            let first = Point(timeMicroseconds: self.time(at: position), bytePosition: position)
            let next = Int128(position) + Int128(frameSize)
            return Points(first: first, second: first.timeMicroseconds < time && next < end
                ? Point(timeMicroseconds: self.time(at: Int64(next)), bytePosition: Int64(next)) : nil)
        case let .xing(start, headerSize, duration, size, table):
            let bounded = min(time, duration)
            let percent = Double(bounded) * 100 / Double(duration)
            let scaled: Double
            if percent <= 0 { scaled = 0 }
            else if percent >= 100 { scaled = 256 }
            else {
                let previous = Int(percent)
                let lower = Double(table[previous]), upper = previous == 99 ? 256 : Double(table[previous + 1])
                scaled = lower + (percent - Double(previous)) * (upper - lower)
            }
            let offset = min(size - 1, max(Int64(headerSize), Self.rounded(scaled / 256 * Double(size))))
            return Points(first: Point(timeMicroseconds: bounded, bytePosition: start + offset), second: nil)
        case let .vbri(times, positions):
            let i = Self.floorIndex(times, time)
            let first = Point(timeMicroseconds: times[i], bytePosition: positions[i])
            return Points(first: first, second: times[i] < time && i + 1 < times.count
                ? Point(timeMicroseconds: times[i + 1], bytePosition: positions[i + 1]) : nil)
        }
    }

    func time(at position: Int64) -> Int64 {
        switch self {
        case let .constant(start, _, bitrate, _):
            return Int64(clamping: max(0, Int128(position) - Int128(start)) * 8_000_000 / Int128(bitrate))
        case let .xing(start, headerSize, duration, size, table):
            let offset = max(0, Int128(position) - Int128(start))
            guard offset > headerSize else { return 0 }
            let scaled = Double(offset) * 256 / Double(size)
            let i = Self.floorIndex(table.map(Int64.init), Int64(clamping: Int128(scaled)))
            let lowerTime = Int64(Int128(i) * Int128(duration) / 100), upperTime = Int64(Int128(i + 1) * Int128(duration) / 100)
            let lower = Double(table[i]), upper = i == 99 ? 256 : Double(table[i + 1])
            let fraction = lower == upper ? 0 : (scaled - lower) / (upper - lower)
            return Int64(clamping: Int128(lowerTime) + Int128(Self.rounded(fraction * Double(upperTime - lowerTime))))
        case let .vbri(times, positions):
            return times[Self.floorIndex(positions, position)]
        }
    }

    private static func rounded(_ value: Double) -> Int64 {
        // Java Math.round rounds positive halves upward. Clamp malformed/extreme
        // requests instead of introducing trapping conversions or integer wrap.
        guard value.isFinite else { return value.sign == .minus ? .min : .max }
        let rounded = (value + 0.5).rounded(.down)
        if rounded >= Double(Int64.max) { return .max }
        if rounded <= Double(Int64.min) { return .min }
        return Int64(rounded)
    }
    private static func floorIndex(_ values: [Int64], _ target: Int64) -> Int {
        var lower = 0, upper = values.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if values[middle] <= target { lower = middle + 1 } else { upper = middle }
        }
        return max(0, lower - 1)
    }
}
