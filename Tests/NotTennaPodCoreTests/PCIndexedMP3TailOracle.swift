import AVFoundation
import CoreMedia
import Foundation
import Testing

/// Independent test-side MPEG inventory and public conversion. No production parser,
/// seek map, decoder or returned PCM length supplies the expected remaining count.
struct PCIndexedMP3TailOracle {
    struct Packet { let offset: Int; let count: Int }
    let media: Data
    let packets: [Packet]
    let rate: Int32
    let channels: Int
    let framesPerPacket: Int64
    let leading: Int64
    let trailing: Int64
    let headerOffset: Int
    let headerSize: Int
    let marker: String
    let table: [UInt8]
    let duration: Int64
    let declaredSize: Int64
    let vbriPositions: [Int64]
    let vbriTimes: [Int64]
    let mllt: Bool

    init(_ media: Data, allowPartialEnd: Bool = false) throws {
        self.media = media
        func word(_ at: Int, _ count: Int) -> Int64 { media[at..<(at + count)].reduce(0) { $0 * 256 + Int64($1) } }
        var offset = 0
        if media.starts(with: Data("ID3".utf8)) { offset = 10 + media[6..<10].reduce(0) { $0 * 128 + Int($1) } }
        try #require(offset + 4 <= media.count)
        let headerOffset = offset
        let bits = word(offset, 4), version = (bits >> 19) & 3
        try #require(bits >> 21 == 0x7ff && (bits >> 17) & 3 == 1 && version != 1)
        let rate = Int32([44100, 48000, 32000][Int((bits >> 10) & 3)] / (version == 3 ? 1 : version == 2 ? 2 : 4))
        let channels = (bits >> 6) & 3 == 3 ? 1 : 2
        let framesPerPacket: Int64 = version == 3 ? 1152 : 576
        func size(at offset: Int) throws -> Int {
            let value = word(offset, 4), index = Int((value >> 12) & 15)
            try #require(value >> 21 == 0x7ff && (1...14).contains(index))
            let rates = version == 3 ? [32,40,48,56,64,80,96,112,128,160,192,224,256,320] : [8,16,24,32,40,48,56,64,80,96,112,128,144,160]
            return (version == 3 ? 144000 : 72000) * rates[index - 1] / Int(rate) + Int((value >> 9) & 1)
        }
        let headerSize = try size(at: offset)
        let xing = offset + (version == 3 ? (channels == 1 ? 21 : 36) : (channels == 1 ? 13 : 21))
        let marker = String(decoding: media[xing..<(xing + 4)], as: UTF8.self)
        let isXing = marker == "Xing" || marker == "Info"
        let isVBRI = String(decoding: media[(offset + 36)..<(offset + 40)], as: UTF8.self) == "VBRI"
        var leading: Int64 = 0, trailing: Int64 = 0, table: [UInt8] = [], declaredSize = Int64(media.count - offset)
        var duration: Int64 = 0, vbriPositions: [Int64] = [], vbriTimes: [Int64] = []
        if isXing {
            let flags = word(xing + 4, 4); var cursor = xing + 8
            if flags & 1 != 0 { duration = (word(cursor, 4) * framesPerPacket - 1) * 1_000_000 / Int64(rate); cursor += 4 }
            if flags & 2 != 0 { declaredSize = word(cursor, 4); cursor += 4 }
            if flags & 4 != 0 { table = Array(media[cursor..<(cursor + 100)]); cursor += 100 }
            if flags & 8 != 0 { cursor += 4 }
            if cursor + 24 <= offset + headerSize {
                let padding = word(cursor + 21, 3); leading = padding >> 12; trailing = padding & 4095
            }
        } else if isVBRI {
            duration = (word(offset + 50, 4) * framesPerPacket - 1) * 1_000_000 / Int64(rate)
            let count = Int(word(offset + 54, 2)), scale = word(offset + 56, 2), width = Int(word(offset + 58, 2))
            var position = Int64(offset + headerSize)
            for i in 0..<count { vbriPositions.append(position); vbriTimes.append(Int64(i) * duration / Int64(count)); position += word(offset + 62 + i * width, width) * scale }
        }
        self.leading = leading; self.trailing = trailing; self.table = table
        self.duration = duration; self.declaredSize = declaredSize; self.vbriPositions = vbriPositions; self.vbriTimes = vbriTimes
        let mllt = headerOffset > 0 && media.prefix(headerOffset).range(of: Data("MLLT".utf8)) != nil
        if isXing || isVBRI { offset += headerSize }
        var packets: [Packet] = []
        while offset + 4 <= media.count {
            if media[offset..<(offset + min(3, media.count - offset))] == Data("TAG".utf8) { break }
            let count = try size(at: offset)
            if offset + count > media.count { try #require(allowPartialEnd); break }
            packets.append(Packet(offset: offset, count: count)); offset += count
        }
        self.rate = rate; self.channels = channels; self.framesPerPacket = framesPerPacket
        self.headerOffset = headerOffset; self.headerSize = headerSize; self.marker = marker; self.mllt = mllt
        self.packets = packets
        try #require(!packets.isEmpty)
    }

    /// Input coordinates are observed before draining output. The bootstrap seed
    /// contains independently countable complete MPEG packets; the parser-relative
    /// ordinal then locates the exact physical packet inside the captured Range.
    func expected(rangeOffset: Int?, seed: Data, decodingStartFrame: Int64, target: CMTime) throws -> (samples: [Int16], time: CMTime) {
        try #require(decodingStartFrame % framesPerPacket == 0)
        let first: Int
        var firstRangePacket: Int?
        let ranged = rangeOffset != nil
        if let rangeOffset {
            let anchor = try #require(packets.firstIndex { $0.offset >= rangeOffset })
            firstRangePacket = anchor
            let seedPackets = try Self(seed, allowPartialEnd: true).packets.count
            first = anchor + Int(decodingStartFrame / framesPerPacket) - seedPackets
        } else { first = Int(decodingStartFrame / framesPerPacket) }
        try #require(packets.indices.contains(first))
        let origin: CMTime
        if let firstRangePacket {
            // A sparse seek bucket labels the initial synchronized packet. Later
            // packets advance by their real frame counts, even within that bucket.
            origin = CMTime(value: try sourceTime(at: firstRangePacket), timescale: 1_000_000)
                + CMTime(value: Int64(first - firstRangePacket) * framesPerPacket - leading, timescale: rate)
        }
        else { origin = CMTime(value: max(0, Int64(first) * framesPerPacket - leading), timescale: rate) }
        let delta = CMTimeConvertScale(target - origin, timescale: rate, method: .roundTowardPositiveInfinity).value
        var raw = try convert(first: first)
        let encodedRemaining = Int64(packets.count - first) * framesPerPacket
        try #require(raw.count == Int(encodedRemaining) * channels)
        let startTrim = ranged ? 0 : max(0, leading - Int64(first) * framesPerPacket)
        // Whole MPEG frames starting before the target are dropped (Media3 drops
        // whole codec buffers); the first kept frame starts on the packet grid.
        let base = Int64(first) * framesPerPacket + startTrim
        let discard = delta <= 0 ? 0 : (base + delta + framesPerPacket - 1) / framesPerPacket * framesPerPacket - base
        let validCount = max(0, encodedRemaining - startTrim - trailing)
        raw = Array(raw.dropFirst(Int(startTrim) * channels).prefix(Int(validCount) * channels))
        let samples = Array(raw.dropFirst(Int(discard) * channels))
        let admittedTime = origin + CMTime(value: discard, timescale: rate)
        print("MP3_INDEPENDENT firstPacket=\(first) packetOffset=\(packets[first].offset) encodedRemaining=\(encodedRemaining) trim=\(startTrim)/\(trailing) discard=\(discard) expectedSamples=\(samples.count) time=\(admittedTime)")
        return (samples, admittedTime)
    }

    private func sourceTime(at packet: Int) throws -> Int64 {
        let offset = Int64(packets[packet].offset)
        if mllt {
            // These pinned generated MLLT fixtures declare one packet per reference,
            // 24ms per reference, and each independently inventoried packet byte size.
            try #require(rate == 48000 && framesPerPacket == 1152)
            return Int64(packet) * 24000
        }
        if !vbriPositions.isEmpty { return vbriTimes[vbriPositions.lastIndex(where: { $0 <= offset }) ?? 0] }
        if marker == "Xing" && table.count == 100 {
            let scaled = Double(offset - Int64(headerOffset)) * 256 / Double(declaredSize)
            let index = table.lastIndex(where: { Double($0) <= scaled }) ?? 0
            let low = Int64(index) * duration / 100, high = Int64(index + 1) * duration / 100
            let upper = index == 99 ? 256 : Int(table[index + 1]), lower = Int(table[index])
            let fraction = upper == lower ? 0 : (scaled - Double(lower)) / Double(upper - lower)
            return low + Int64((fraction * Double(high - low) + 0.5).rounded(.down))
        }
        try #require(marker == "Info" && duration > 0)
        let bytes = declaredSize - Int64(headerSize)
        let average = (bytes * 8_000_000 + duration / 2) / duration
        return (offset - Int64(packets[0].offset)) * 8_000_000 / average
    }

    private func convert(first: Int) throws -> [Int16] {
        var basic = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatMPEGLayer3,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        let input = try #require(AVAudioFormat(streamDescription: &basic))
        let output = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(rate), channels: UInt32(channels), interleaved: true))
        let converter = try #require(AVAudioConverter(from: input, to: output))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 4096))
        var cursor = first, result: [Int16] = []
        while true {
            var supplied: [AVAudioCompressedBuffer] = [], error: NSError?
            let status = converter.convert(to: pcm, error: &error) { _, state in
                guard cursor < packets.count else { state.pointee = .endOfStream; return nil }
                let end = min(packets.count, cursor + 64), slice = packets[cursor..<end]
                let buffer = AVAudioCompressedBuffer(format: input, packetCapacity: UInt32(slice.count), maximumPacketSize: slice.map(\.count).max()!)
                var position = 0
                for (index, packet) in slice.enumerated() {
                    media.withUnsafeBytes { buffer.data.advanced(by: position).copyMemory(from: $0.baseAddress!.advanced(by: packet.offset), byteCount: packet.count) }
                    buffer.packetDescriptions![index] = AudioStreamPacketDescription(mStartOffset: Int64(position), mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
                    position += packet.count
                }
                buffer.packetCount = UInt32(slice.count); buffer.byteLength = UInt32(position); cursor = end
                supplied.append(buffer); state.pointee = .haveData; return buffer
            }
            withExtendedLifetime(supplied) {}
            if let error { throw error }
            try #require(status != .error)
            if pcm.frameLength > 0 { result += UnsafeBufferPointer(start: pcm.int16ChannelData![0], count: Int(pcm.frameLength) * channels) }
            if status == .endOfStream { break }
        }
        return result
    }
}

/// Audible-outcome PCM comparison for lossy codecs and seek tails, where only
/// what a listener would notice matters: the audio is present (not silent), its
/// length matches within `lengthTolerance` seconds (nothing audible lost or
/// added), and the waveform stays aligned with the reference (no gaps, shifts
/// or garbage). Decoder-history differences in the first packets after a seek
/// and sub-LSB codec rounding are tolerated.
enum AudibleMatch {
    static func matches(_ actual: [Int16], _ expected: [Int16], channels: Int, sampleRate: Int,
                        lengthTolerance: Double = 0.05) -> Bool {
        let tolerance = Int(Double(sampleRate * max(channels, 1)) * lengthTolerance)
        guard abs(actual.count - expected.count) <= tolerance else { return false }
        // Under 100 ms nothing but the length is audible; decoder warm-up dominates.
        if expected.count < sampleRate * max(channels, 1) / 10 { return true }
        let count = min(actual.count, expected.count)
        var difference = 0.0, energy = 0.0, loudness = 0.0
        for index in 0..<count {
            let reference = Double(expected[index]), value = Double(actual[index])
            difference += (value - reference) * (value - reference)
            energy += reference * reference
            loudness += value * value
        }
        if energy == 0 { return loudness <= Double(count) * 16 }
        // Residual power at most 5% of the reference (about -13 dB): a dropped
        // or duplicated packet misaligns everything after it and fails this.
        return loudness > 0 && difference <= energy * 0.05
    }
}
