// Source seek and frame-header interpretation follows AndroidX Media3 (Apache-2.0).
// See Licenses/Android-Native-Audio-Metadata.txt.
import Foundation

/// A source byte map, independent of AudioFile's complete packet index. Native
/// parsing and conversion still own encoded packet interpretation and audio.
struct NativeFLACSeekIndex: Equatable, Sendable {
    struct SeekPoint: Equatable, Sendable { let sample: Int64, offset: Int64 }
    struct Position: Equatable, Sendable { let byte: Int64, sample: Int64 }
    let info: Data
    let firstAudioByte: Int64
    let declaredLength: Int64?
    let seekPoints: [SeekPoint]
    let sampleRate: Int64, totalSamples: Int64
    let minBlock: Int, maxBlock: Int, minFrame: Int, maxFrame: Int, channels: Int, bits: Int

    init(info: Data, firstAudioByte: Int64, declaredLength: Int64?, seekPoints: [SeekPoint]) throws {
        guard info.count == 34, firstAudioByte >= 42 else { throw NativeAudioSourceTimeline.Failure.invalidMetadata }
        self.info = info; self.firstAudioByte = firstAudioByte; self.declaredLength = declaredLength; self.seekPoints = seekPoints
        func value(_ start: Int, _ count: Int) -> UInt64 { info[start..<(start + count)].reduce(0) { ($0 << 8) | UInt64($1) } }
        minBlock = Int(value(0, 2)); maxBlock = Int(value(2, 2))
        minFrame = Int(value(4, 3)); maxFrame = Int(value(7, 3))
        let packed = value(10, 8)
        sampleRate = Int64(packed >> 44); channels = Int(packed >> 41 & 7) + 1
        bits = Int(packed >> 36 & 31) + 1; totalSamples = Int64(packed & 0x0f_ffff_ffff)
        guard minBlock > 0, maxBlock >= minBlock, sampleRate > 0,
              seekPoints.allSatisfy({ $0.sample >= 0 && $0.offset >= 0 && $0.offset <= Int64.max - firstAudioByte }),
              zip(seekPoints, seekPoints.dropFirst()).allSatisfy({ $0.sample <= $1.sample && $0.offset <= $1.offset }) else {
            throw NativeAudioSourceTimeline.Failure.invalidMetadata
        }
    }
    var nativePrefix: Data { Data("fLaC".utf8) + Data([0x80, 0, 0, 34]) + info }

    func position(at microseconds: Int64, input: any MediaByteInput) throws -> Position {
        let requested = max(0, Int128(microseconds) * Int128(sampleRate) / 1_000_000)
        let target = Int64(clamping: totalSamples > 0 ? min(requested, Int128(totalSamples - 1)) : requested)
        let reader = Bytes(input: input, end: declaredLength)
        let first = try reader.read(firstAudioByte, count: 2)
        guard first.count == 2 else { throw NativeAudioSourceTimeline.Failure.incompleteMetadata }
        let marker = UInt16(first[0]) << 8 | UInt16(first[1])
        guard marker & 0xfffe == 0xfff8 else { throw NativeAudioSourceTimeline.Failure.invalidMetadata }
        if !seekPoints.isEmpty {
            var low = 0, high = seekPoints.count
            while low < high {
                let middle = low + (high - low) / 2
                if seekPoints[middle].sample <= target { low = middle + 1 } else { high = middle }
            }
            let offset = low == 0 ? firstAudioByte : firstAudioByte + seekPoints[low - 1].offset
            return try nextFrame(at: offset, marker: marker, reader: reader)
        }
        guard let length = declaredLength, length > firstAudioByte, totalSamples > 0 else {
            throw NativeAudioSourceTimeline.Failure.invalidMetadata
        }
        var floor = Position(byte: firstAudioByte, sample: 0), ceiling = Position(byte: length, sample: totalSamples)
        let approximate = maxFrame > 0 ? Int64((maxFrame + minFrame) / 2 + 1)
            : Int64((minBlock == maxBlock ? minBlock : 4096) * channels * bits / 8 + 64)
        while true {
            try input.checkFailure()
            if ceiling.byte - floor.byte <= max(6, minFrame) || ceiling.sample - floor.sample <= 1 {
                return try nextFrame(at: floor.byte, marker: marker, reader: reader)
            }
            // Preserve the original Float estimate and its5% undershoot. The
            // following validated sample headers, not the estimate, choose audio.
            let ratio = Float(ceiling.byte - floor.byte) / Float(ceiling.sample - floor.sample)
            let estimate = Float(target - floor.sample) * ratio
            guard estimate.isFinite, estimate >= 0, Double(estimate) < Double(Int64.max) else {
                throw NativeAudioSourceTimeline.Failure.invalidMetadata
            }
            let skip = Int64(estimate)
            let raw = Int128(floor.byte) + Int128(skip) - Int128(approximate) - Int128(skip / 20)
            let seek = Int64(max(Int128(floor.byte), min(raw, Int128(ceiling.byte - 1))))
            let left = try nextFrame(at: seek, marker: marker, reader: reader)
            let right = try nextFrame(at: Int64(min(Int128(length), Int128(left.byte) + Int128(max(6, minFrame)))), marker: marker, reader: reader)
            if left.sample <= target && right.sample > target { return left }
            if right.sample <= target {
                guard right.byte > floor.byte, right.sample > floor.sample else { throw NativeAudioSourceTimeline.Failure.invalidMetadata }
                floor = right
            } else {
                guard seek < ceiling.byte, left.sample > floor.sample else { throw NativeAudioSourceTimeline.Failure.invalidMetadata }
                ceiling = Position(byte: seek, sample: left.sample)
            }
        }
    }

    private func nextFrame(at start: Int64, marker: UInt16, reader: Bytes) throws -> Position {
        var offset = start
        while true {
            let bytes = try reader.read(offset, count: 17)
            if bytes.count < 6 {
                guard let end = declaredLength else { throw NativeAudioSourceTimeline.Failure.incompleteMetadata }
                return Position(byte: end, sample: totalSamples)
            }
            if let sample = frameSample(bytes, marker: marker) { return Position(byte: offset, sample: sample) }
            guard offset < Int64.max else { throw NativeAudioSourceTimeline.Failure.invalidMetadata }
            offset += 1
        }
    }

    /// RFC9639 header validation, including CRC8 and the first subframe's
    /// reserved bits. A sync-like byte sequence in compressed audio is not enough.
    private func frameSample(_ data: Data, marker: UInt16) -> Int64? {
        guard data.count >= 6, UInt16(data[0]) << 8 | UInt16(data[1]) == marker, data[3] & 1 == 0 else { return nil }
        let blockKey = Int(data[2] >> 4), rateKey = Int(data[2] & 15)
        let channelKey = Int(data[3] >> 4), bitsKey = Int(data[3] >> 1 & 7)
        guard channelKey <= 7 ? channelKey + 1 == channels : (channelKey <= 10 && channels == 2) else { return nil }
        let depths = [0, 8, 12, -1, 16, 20, 24, 32]
        guard bitsKey == 0 || depths[bitsKey] == bits else { return nil }
        var cursor = 4
        func byte() -> UInt8? { guard cursor < data.count else { return nil }; defer { cursor += 1 }; return data[cursor] }
        func word() -> Int? { guard let high = byte(), let low = byte() else { return nil }; return Int(high) << 8 | Int(low) }
        guard let first = byte() else { return nil }
        var width = 0, bit: UInt8 = 0x80
        while first & bit != 0 && bit != 0 { width += 1; bit >>= 1 }
        guard width != 1, width <= 7 else { return nil }
        var number = width == 0 ? UInt64(first) : UInt64(first & (0x7f >> width))
        if width > 0 {
            for _ in 1..<width {
                guard let next = byte(), next & 0xc0 == 0x80 else { return nil }
                number = number << 6 | UInt64(next & 0x3f)
            }
        }
        let rawSample = marker & 1 != 0 ? UInt128(number) : UInt128(number) * UInt128(maxBlock)
        guard let sample = Int64(exactly: rawSample), totalSamples == 0 || sample <= totalSamples else { return nil }
        let block: Int
        switch blockKey {
        case 1: block = 192
        case 2...5: block = 576 << (blockKey - 2)
        case 6: guard let value = byte() else { return nil }; block = Int(value) + 1
        case 7: guard let value = word() else { return nil }; block = value + 1
        case 8...15: block = 256 << (blockKey - 8)
        default: return nil
        }
        guard block <= maxBlock, totalSamples == 0 || Int128(sample) + Int128(block) >= Int128(totalSamples) || block >= minBlock else { return nil }
        let rates = [0, 88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000]
        if rateKey > 0 && rateKey < 12 {
            guard rates[rateKey] == sampleRate else { return nil }
        } else if rateKey == 12 {
            guard let value = byte(), Int64(value) * 1000 == sampleRate else { return nil }
        } else if rateKey == 13 || rateKey == 14 {
            guard let value = word(), Int64(value) * (rateKey == 14 ? 10 : 1) == sampleRate else { return nil }
        } else if rateKey == 15 { return nil }
        let end = cursor
        guard let crc = byte() else { return nil }
        var expected: UInt8 = 0
        for value in data.prefix(end) {
            expected ^= value
            for _ in 0..<8 { expected = expected & 0x80 != 0 ? (expected &<< 1) ^ 7 : expected &<< 1 }
        }
        guard crc == expected else { return nil }
        if cursor < data.count {
            let header = data[cursor], type = header >> 1 & 63
            guard header & 128 == 0, !(2...7).contains(type), !(13...31).contains(type) else { return nil }
        }
        return sample
    }

    private final class Bytes {
        let input: any MediaByteInput, end: Int64?
        var stored = Data(), origin: Int64 = 0, lastReadEnd: Int64?
        init(input: any MediaByteInput, end: Int64?) { self.input = input; self.end = end }
        func read(_ offset: Int64, count: Int) throws -> Data {
            guard offset >= 0, count <= 17 else { throw NativeAudioSourceTimeline.Failure.invalidMetadata }
            var result = Data(), position = offset
            while result.count < count {
                try input.checkFailure()
                if let end, position >= end { break }
                if position < origin || position >= origin + Int64(stored.count) {
                    if lastReadEnd != position { input.prepareForIndexedSeek(to: position) }
                    stored = try input.read(at: position, maximumCount: Int(min(4096, end.map { max(0, $0 - position) } ?? 4096)))
                    guard stored.count <= 4096, position <= Int64.max - Int64(stored.count) else { throw NativeAudioSourceTimeline.Failure.invalidMetadata }
                    origin = position; lastReadEnd = position + Int64(stored.count)
                    if stored.isEmpty { break }
                }
                let start = Int(position - origin), length = min(count - result.count, stored.count - start)
                result.append(stored[start..<(start + length)]); position += Int64(length)
            }
            return result
        }
    }
}
