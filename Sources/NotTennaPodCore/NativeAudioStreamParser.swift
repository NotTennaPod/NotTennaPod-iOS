import AudioToolbox
import Foundation

/// Caller-confined incremental parsing. Native callbacks finish synchronously
/// before append returns; packet bytes never outlive their copied batch.
final class NativeAudioStreamParser {
    enum Failure: Error, Equatable {
        case closed, invalidFormat, invalidPacket, invalidCapacity, native(OSStatus), requiresRandomAccess
    }
    struct Configuration: Sendable {
        let basic: AudioStreamBasicDescription
        let cookie: Data?
        let primingFrames: Int64
        let validFrames: Int64?
        var maximumPacketFrames: UInt32? = nil
        /// The container's AudioChannelLayout bytes for more than two channels;
        /// a codec's own decoded order takes precedence (`NativeAudioStreamConverter`).
        var channelLayout: Data? = nil
    }
    struct Batch: Sendable {
        let bytes: Data
        let packetCount: UInt32
        let descriptions: [AudioStreamPacketDescription]?
        var firstFrame: Int64 = 0
        var rollDistances: [Int64]? = nil
        var sourceTimes: [Int64]? = nil
        /// Raw ADTS after a configuration change (`ADTSSegmentScanner`): the
        /// segment's ordinal and its own configuration; nil in segment zero.
        var segment = 0
        var configuration: Configuration? = nil
    }
    static let maximumBatchBytes = 8 << 20
    private var stream: AudioFileStreamID?
    private var pending = Data()
    private var batches: [Batch] = []
    private var batchBytes = 0
    private var parsedFrames: Int64 = 0, parsedPackets: Int64 = 0
    private var failure: (any Error)?
    private var finished = false
    private var flacMaximumPacketFrames: UInt32?
    /// AudioFileStream does not report a WAV's speaker positions; its
    /// WAVE_FORMAT_EXTENSIBLE channel mask is read from the header bytes.
    private var waveHeader = WaveHeaderReader()
    private var nativeFrameRate: Double = 0
    private var parsingConfiguration: Configuration?
    private var profileDiscovery: NativeAACProfileDiscovery?
    private(set) var configuration: Configuration?

    init() throws {
        let status = AudioFileStreamOpen(Unmanaged.passUnretained(self).toOpaque(), { context, stream, property, _ in
            guard property == kAudioFileStreamProperty_ReadyToProducePackets else { return }
            Unmanaged<NativeAudioStreamParser>.fromOpaque(context).takeUnretainedValue().ready(stream)
        }, { context, size, count, bytes, descriptions in
            Unmanaged<NativeAudioStreamParser>.fromOpaque(context).takeUnretainedValue()
                .receive(size: size, count: count, bytes: bytes, descriptions: descriptions)
        }, 0, &stream)
        try check(status)
    }
    deinit { close() }

    func append(_ bytes: Data) throws -> [Batch] {
        guard stream != nil, !finished else { throw Failure.closed }
        if let failure { throw failure }
        guard bytes.count <= 32768 else { throw Failure.invalidCapacity }
        if parsingConfiguration == nil { waveHeader.consume(bytes) }
        pending.append(bytes)
        // Small transport fragments must not become undersized native probes.
        guard pending.count >= 4096 else { return [] }
        return try parsePending()
    }
    func finish() throws -> [Batch] {
        guard let stream, !finished else { throw Failure.closed }
        if let failure { throw failure }
        var result = try parsePending()
        finished = true
        try check(AudioFileStreamParseBytes(stream, 0, nil, []))
        profileDiscovery?.finish()
        result += try takeBatches()
        guard configuration != nil else { throw Failure.invalidFormat }
        return result
    }
    func close() {
        if let stream { AudioFileStreamClose(stream) }
        stream = nil; pending.removeAll(); batches.removeAll(); batchBytes = 0
    }
    private func parsePending() throws -> [Batch] {
        guard !pending.isEmpty, let stream else { return [] }
        if configuration == nil {
            flacMaximumPacketFrames = NativeFLACPacketTiming.maximumFrameCount(in: pending) ?? flacMaximumPacketFrames
        }
        let status = pending.withUnsafeBytes { AudioFileStreamParseBytes(stream, UInt32($0.count), $0.baseAddress, []) }
        pending.removeAll(keepingCapacity: true)
        try check(status)
        return try takeBatches()
    }
    private func takeBatches() throws -> [Batch] {
        if let profileDiscovery, !profileDiscovery.finished { return [] }
        if configuration == nil, let original = parsingConfiguration {
            if let selected = profileDiscovery?.result {
                configuration = Configuration(basic: selected.basic, cookie: selected.cookie,
                    primingFrames: try NativeAudioFormatSelection.frames(original.primingFrames, from: original.basic.mSampleRate, to: selected.basic.mSampleRate),
                    validFrames: try original.validFrames.map { try NativeAudioFormatSelection.frames($0, from: original.basic.mSampleRate, to: selected.basic.mSampleRate) },
                    channelLayout: original.channelLayout)
            } else { configuration = original }
            if let configuration, let valid = configuration.validFrames,
               configuration.primingFrames.addingReportingOverflow(valid).overflow { throw Failure.invalidFormat }
        }
        var result = batches
        if let original = parsingConfiguration, let configuration, original.basic.mSampleRate != configuration.basic.mSampleRate {
            for i in result.indices {
                result[i].firstFrame = try NativeAudioFormatSelection.frames(result[i].firstFrame, from: original.basic.mSampleRate, to: configuration.basic.mSampleRate)
                if var descriptions = result[i].descriptions {
                    for j in descriptions.indices where descriptions[j].mVariableFramesInPacket != 0 {
                        let frames = try NativeAudioFormatSelection.frames(Int64(descriptions[j].mVariableFramesInPacket), from: original.basic.mSampleRate, to: configuration.basic.mSampleRate)
                        guard let value = UInt32(exactly: frames) else { throw Failure.invalidPacket }
                        descriptions[j].mVariableFramesInPacket = value
                    }
                    result[i] = Batch(bytes: result[i].bytes, packetCount: result[i].packetCount, descriptions: descriptions,
                        firstFrame: result[i].firstFrame, rollDistances: result[i].rollDistances)
                }
            }
        }
        batches.removeAll(keepingCapacity: true); batchBytes = 0
        return result
    }
    private func check(_ status: OSStatus) throws {
        if let failure { throw failure }
        guard status != kAudioFileStreamError_NotOptimized else { throw Failure.requiresRandomAccess }
        guard status == noErr else { throw Failure.native(status) }
    }
    private func ready(_ stream: AudioFileStreamID) {
        do {
            guard parsingConfiguration == nil else { throw Failure.invalidFormat }
            var basic = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataFormat, &size, &basic))
            nativeFrameRate = basic.mSampleRate
            basic = try NativeAudioFormatSelection.stream(stream, fallback: basic)
            guard basic.mSampleRate.isFinite, basic.mSampleRate > 0, basic.mSampleRate <= 768000,
                  basic.mSampleRate.rounded(.towardZero) == basic.mSampleRate,
                  (1...32).contains(basic.mChannelsPerFrame) else { throw Failure.invalidFormat }
            var cookie: Data?
            size = 0
            if AudioFileStreamGetPropertyInfo(stream, kAudioFileStreamProperty_MagicCookieData, &size, nil) == noErr,
               size > 0 {
                guard size <= Self.maximumBatchBytes else { throw Failure.invalidCapacity }
                var data = Data(count: Int(size))
                let status = data.withUnsafeMutableBytes {
                    AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_MagicCookieData, &size, $0.baseAddress!)
                }
                try check(status)
                cookie = data
            }
            var table = AudioFilePacketTableInfo()
            size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
            let tableStatus = AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_PacketTableInfo, &size, &table)
            var priming: Int64 = 0, valid: Int64?
            if tableStatus == noErr {
                guard table.mNumberValidFrames >= 0, table.mPrimingFrames >= 0,
                      !table.mNumberValidFrames.addingReportingOverflow(Int64(table.mPrimingFrames)).overflow else {
                    throw Failure.invalidFormat
                }
                // The valid interval fully determines trimming. Native M4A
                // remainder values vary even for identical input; do not use
                // an unused, redundant count to reject otherwise valid audio.
                // Packet-table counts retain DataFormat's core sample rate,
                // even when FormatList identifies a richer SBR output.
                priming = try NativeAudioFormatSelection.frames(Int64(table.mPrimingFrames), from: nativeFrameRate, to: basic.mSampleRate)
                let decodedValid = try NativeAudioFormatSelection.frames(table.mNumberValidFrames, from: nativeFrameRate, to: basic.mSampleRate)
                guard !priming.addingReportingOverflow(decodedValid).overflow else { throw Failure.invalidFormat }
                valid = decodedValid
            } else if basic.mFormatID == kAudioFormatLinearPCM {
                var count: UInt64 = 0
                size = UInt32(MemoryLayout<UInt64>.size)
                if AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_AudioDataPacketCount, &size, &count) == noErr {
                    let frames = UInt128(count) * UInt128(basic.mFramesPerPacket)
                    guard frames <= Int64.max else { throw Failure.invalidFormat }
                    valid = Int64(frames)
                }
            }
            var layout: Data?
            size = 0
            if basic.mChannelsPerFrame > 2,
               AudioFileStreamGetPropertyInfo(stream, kAudioFileStreamProperty_ChannelLayout, &size, nil) == noErr,
               size >= UInt32(MemoryLayout<AudioChannelLayout>.size), size <= 65_536 {
                var data = Data(count: Int(size))
                if data.withUnsafeMutableBytes({ AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_ChannelLayout, &size, $0.baseAddress!) }) == noErr {
                    layout = data
                }
            }
            if layout == nil, basic.mChannelsPerFrame > 2, basic.mFormatID == kAudioFormatLinearPCM,
               let mask = waveHeader.channelMask, mask.nonzeroBitCount == basic.mChannelsPerFrame, mask < 1 << 18 {
                // WAVE speaker bits are Core Audio's channel bitmap bits.
                var bitmap = AudioChannelLayout(mChannelLayoutTag: kAudioChannelLayoutTag_UseChannelBitmap,
                    mChannelBitmap: AudioChannelBitmap(rawValue: mask), mNumberChannelDescriptions: 0,
                    mChannelDescriptions: AudioChannelDescription())
                layout = Data(bytes: &bitmap, count: MemoryLayout<AudioChannelLayout>.size)
            }
            parsingConfiguration = Configuration(basic: basic, cookie: cookie, primingFrames: priming, validFrames: valid,
                maximumPacketFrames: basic.mFormatID == kAudioFormatFLAC ? flacMaximumPacketFrames : nil, channelLayout: layout)
            var type: AudioFileTypeID = 0
            size = UInt32(MemoryLayout<AudioFileTypeID>.size)
            try check(AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_FileFormat, &size, &type))
            if type == kAudioFileM4AType || type == kAudioFileMPEG4Type {
                profileDiscovery = try NativeAACProfileDiscovery(basic: basic, cookie: cookie)
            }
            if profileDiscovery == nil { configuration = parsingConfiguration }
        } catch { failure = error }
    }
    private func receive(size: UInt32, count: UInt32, bytes: UnsafeRawPointer,
                         descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard failure == nil else { return }
        guard parsingConfiguration != nil, size > 0, count > 0,
              size <= Self.maximumBatchBytes, count <= Self.maximumBatchBytes / MemoryLayout<AudioStreamPacketDescription>.size,
              batchBytes <= Self.maximumBatchBytes - Int(size) else {
            failure = Failure.invalidPacket; return
        }
        var copied = descriptions.map { Array(UnsafeBufferPointer(start: $0, count: Int(count))) }
        if let copied, !copied.allSatisfy({ $0.mStartOffset >= 0 && $0.mDataByteSize > 0 &&
            $0.mStartOffset <= Int64(size) - Int64($0.mDataByteSize) }) {
            failure = Failure.invalidPacket; return
        }
        if let basic = parsingConfiguration?.basic, nativeFrameRate != basic.mSampleRate, var packets = copied {
            do {
                for i in packets.indices where packets[i].mVariableFramesInPacket != 0 {
                    let frames = try NativeAudioFormatSelection.frames(Int64(packets[i].mVariableFramesInPacket), from: nativeFrameRate, to: basic.mSampleRate)
                    guard let count = UInt32(exactly: frames) else { throw Failure.invalidPacket }
                    packets[i].mVariableFramesInPacket = count
                }
                copied = packets
            } catch { failure = error; return }
        }
        if parsingConfiguration?.basic.mFormatID == kAudioFormatFLAC,
           parsingConfiguration?.basic.mFramesPerPacket == 0, var packets = copied {
            do {
                for i in packets.indices where packets[i].mVariableFramesInPacket == 0 {
                    let packet = packets[i]
                    let header = UnsafeRawBufferPointer(start: bytes.advanced(by: Int(packet.mStartOffset)), count: Int(packet.mDataByteSize))
                    packets[i].mVariableFramesInPacket = try NativeFLACPacketTiming.frameCount(in: header)
                }
                copied = packets
            } catch { failure = error; return }
        }
        if let copied {
            // Callback storage can include framing/gaps outside the described
            // packets. Retain only payload bytes and rebase their descriptions.
            var payload = Data(), normalized: [AudioStreamPacketDescription] = []
            payload.reserveCapacity(Int(size)); normalized.reserveCapacity(copied.count)
            for var packet in copied {
                guard payload.count <= Self.maximumBatchBytes - batchBytes - Int(packet.mDataByteSize) else {
                    failure = Failure.invalidCapacity; return
                }
                let offset = Int(packet.mStartOffset)
                packet.mStartOffset = Int64(payload.count)
                payload.append(bytes.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: Int(packet.mDataByteSize))
                normalized.append(packet)
            }
            batches.append(Batch(bytes: payload, packetCount: count, descriptions: normalized))
        } else {
            batches.append(Batch(bytes: Data(bytes: bytes, count: Int(size)), packetCount: count, descriptions: nil))
        }
        if let profileDiscovery, !profileDiscovery.finished, let batch = batches.last, let descriptions = batch.descriptions {
            do {
                for description in descriptions where !profileDiscovery.finished {
                    try batch.bytes.withUnsafeBytes { bytes in
                        let begin = Int(description.mStartOffset), end = begin + Int(description.mDataByteSize)
                        try profileDiscovery.append(UnsafeRawBufferPointer(rebasing: bytes[begin..<end]))
                    }
                }
            } catch { failure = error; return }
        }
        guard let parsingConfiguration else { failure = Failure.invalidFormat; return }
        let basic = parsingConfiguration.basic
        var frames: Int64 = 0
        for index in 0..<Int(count) {
            let variable = copied?[index].mVariableFramesInPacket ?? 0
            let frameCount = Int64(variable == 0 ? basic.mFramesPerPacket : variable)
            guard frameCount > 0, frames <= Int64.max - frameCount else { failure = Failure.invalidPacket; return }
            frames += frameCount
        }
        guard parsedFrames <= Int64.max - frames, parsedPackets <= Int64.max - Int64(count) else {
            failure = Failure.invalidPacket; return
        }
        var distances: [Int64]? = nil
        // Ask while these packets are current in the native callback. A missing
        // answer leaves seeking unavailable; it never implies zero dependencies.
        if basic.mFormatID != kAudioFormatLinearPCM, let stream {
            distances = []
            for index in 0..<Int(count) {
                var translation = AudioPacketRollDistanceTranslation(mPacket: parsedPackets + Int64(index), mRollDistance: 0)
                var size = UInt32(MemoryLayout.size(ofValue: translation))
                let status = AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_PacketToRollDistance, &size, &translation)
                guard status == noErr, translation.mRollDistance >= 0, translation.mRollDistance <= translation.mPacket else {
                    distances = nil; break
                }
                distances?.append(translation.mRollDistance)
            }
        }
        batches[batches.count - 1].firstFrame = parsedFrames
        batches[batches.count - 1].rollDistances = distances
        parsedFrames += frames; parsedPackets += Int64(count)
        batchBytes += batches.last!.bytes.count
    }
}

/// The dwChannelMask of a RIFF/RF64/BW64 WAVE_FORMAT_EXTENSIBLE header, read as
/// the bytes arrive in any pieces: chunks before "fmt " (JUNK, ds64, metadata)
/// are skipped by counting, so state stays at most one 24-byte buffer.
struct WaveHeaderReader {
    private(set) var channelMask: UInt32?
    private(set) var finished = false
    private enum Stage { case file, chunk, format(UInt32), skip(Int64, padded: Bool), pad }
    private var stage = Stage.file
    private var buffer: [UInt8] = []

    mutating func consume(_ bytes: Data) {
        var index = bytes.startIndex
        while !finished, index < bytes.endIndex {
            switch stage {
            case .skip(let remaining, let padded):
                let count = Int(min(remaining, Int64(bytes.endIndex - index)))
                index += count
                stage = remaining > Int64(count) ? .skip(remaining - Int64(count), padded: padded) : padded ? .pad : .chunk
            case .pad:
                // RIFF pads an odd chunk to even with a zero byte; some writers omit it (and
                // AudioFileStream expects it omitted). A chunk ID never starts with zero.
                if bytes[index] == 0 { index += 1 }
                stage = .chunk
            default:
                let need: Int
                switch stage {
                case .file: need = 12
                case .chunk: need = 8
                case .format(let size): need = Int(min(size, 24))
                case .skip, .pad: need = 0
                }
                let count = min(need - buffer.count, bytes.endIndex - index)
                buffer += bytes[index..<(index + count)]; index += count
                guard buffer.count == need else { continue }
                let header = buffer; buffer.removeAll(keepingCapacity: true)
                func little(_ at: Int, _ count: Int) -> UInt32 { (0..<count).reduce(0) { $0 | UInt32(header[at + $1]) << (8 * $1) } }
                switch stage {
                case .file:
                    let kind = String(decoding: header[0..<4], as: UTF8.self)
                    guard ["RIFF", "RF64", "BW64"].contains(kind), header[8..<12].elementsEqual("WAVE".utf8) else { finished = true; break }
                    stage = .chunk
                case .chunk:
                    let id = String(decoding: header[0..<4], as: UTF8.self), size = little(4, 4)
                    // A format chunk too short for a mask, or audio before one: no mask.
                    if id == "fmt " { if size >= 24 { stage = .format(size) } else { finished = true } }
                    else if id == "data" { finished = true }
                    else { stage = .skip(Int64(size), padded: size % 2 == 1) }
                case .format:
                    if little(0, 2) == 0xfffe { channelMask = little(20, 4) }
                    finished = true
                case .skip, .pad: break
                }
            }
        }
    }
}
