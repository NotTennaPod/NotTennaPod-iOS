import AudioToolbox
import Foundation

/// Identifies implicit SBR/PS using Apple's bitstream parser. Only a validated
/// ADTS-representable LC core is reframed, and only for a bounded startup probe.
/// Original media packets remain owned by their reader and are never replaced.
final class NativeAACProfileDiscovery {
    struct Result { let basic: AudioStreamBasicDescription; let cookie: Data }
    static let maximumPackets = 16
    private let frequency: Int, channels: Int
    private var stream: AudioFileStreamID?
    private var ready = false
    private var packetCount = 0
    private(set) var finished = false
    private(set) var result: Result?

    init?(basic: AudioStreamBasicDescription, cookie: Data?) throws {
        guard basic.mFormatID == kAudioFormatMPEG4AAC, basic.mFramesPerPacket == 1024,
              let cookie, let core = Self.core(cookie),
              basic.mSampleRate == Self.rates[core.frequency], basic.mChannelsPerFrame == core.channels else { return nil }
        frequency = core.frequency; channels = core.channels
        try check(AudioFileStreamOpen(Unmanaged.passUnretained(self).toOpaque(), { context, _, property, _ in
            if property == kAudioFileStreamProperty_ReadyToProducePackets {
                Unmanaged<NativeAACProfileDiscovery>.fromOpaque(context).takeUnretainedValue().ready = true
            }
        }, { _, _, _, _, _ in }, kAudioFileAAC_ADTSType, &stream))
    }
    deinit { if let stream { AudioFileStreamClose(stream) } }

    func append(_ payload: UnsafeRawBufferPointer) throws {
        guard !finished, let stream else { return }
        guard payload.count > 0, payload.count <= 8184 else { finish(); return }
        let size = payload.count + 7
        var framed = Data([0xff, 0xf1, UInt8(0x40 | frequency << 2 | channels >> 2),
            UInt8((channels & 3) << 6 | size >> 11), UInt8((size >> 3) & 255),
            UInt8((size & 7) << 5 | 31), 0xfc])
        framed.append(contentsOf: payload)
        try check(framed.withUnsafeBytes { AudioFileStreamParseBytes(stream, UInt32($0.count), $0.baseAddress, []) })
        packetCount += 1
        if ready {
            var basic = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataFormat, &size, &basic))
            basic = try NativeAudioFormatSelection.stream(stream, fallback: basic)
            if basic.mFormatID == kAudioFormatMPEG4AAC_HE || basic.mFormatID == kAudioFormatMPEG4AAC_HE_V2 {
                size = 0
                try check(AudioFileStreamGetPropertyInfo(stream, kAudioFileStreamProperty_MagicCookieData, &size, nil))
                guard size > 0, size <= 65536 else { throw NativeAudioStreamParser.Failure.invalidFormat }
                var cookie = Data(count: Int(size))
                let capacity = size
                try check(cookie.withUnsafeMutableBytes { AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_MagicCookieData, &size, $0.baseAddress!) })
                guard size > 0, size <= capacity else { throw NativeAudioStreamParser.Failure.invalidFormat }
                result = .init(basic: basic, cookie: Data(cookie.prefix(Int(size))))
            }
            finish()
        } else if packetCount == Self.maximumPackets { finish() }
    }
    func finish() { finished = true }

    static func file(_ file: AudioFileID, checkInput: () throws -> Void) throws -> Result? {
        var type: AudioFileTypeID = 0, size = UInt32(MemoryLayout<AudioFileTypeID>.size)
        var status = AudioFileGetProperty(file, kAudioFilePropertyFileFormat, &size, &type)
        try checkInput()
        guard status == noErr else { throw NativeAudioStreamParser.Failure.native(status) }
        guard type == kAudioFileM4AType || type == kAudioFileMPEG4Type else { return nil }
        var basic = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &basic)
        try checkInput()
        guard status == noErr else { throw NativeAudioStreamParser.Failure.native(status) }
        guard basic.mFormatID == kAudioFormatMPEG4AAC else { return nil }
        size = 0
        status = AudioFileGetPropertyInfo(file, kAudioFilePropertyMagicCookieData, &size, nil)
        try checkInput()
        if status == kAudioFileUnsupportedPropertyError { return nil }
        guard status == noErr else { throw NativeAudioStreamParser.Failure.native(status) }
        guard size > 0, size <= 65536 else { return nil }
        var cookie = Data(count: Int(size))
        let capacity = size
        status = cookie.withUnsafeMutableBytes { AudioFileGetProperty(file, kAudioFilePropertyMagicCookieData, &size, $0.baseAddress!) }
        try checkInput()
        guard status == noErr else { throw NativeAudioStreamParser.Failure.native(status) }
        guard size <= capacity else { throw NativeAudioStreamParser.Failure.invalidFormat }
        return try Self.file(file, basic: basic, cookie: Data(cookie.prefix(Int(size))), checkInput: checkInput)
    }

    static func file(_ file: AudioFileID, basic: AudioStreamBasicDescription, cookie: Data?, checkInput: () throws -> Void) throws -> Result? {
        guard let probe = try Self(basic: basic, cookie: cookie) else { return nil }
        var upper: UInt32 = 0, propertySize = UInt32(MemoryLayout<UInt32>.size)
        let propertyStatus = AudioFileGetProperty(file, kAudioFilePropertyPacketSizeUpperBound, &propertySize, &upper)
        try checkInput()
        guard propertyStatus == noErr else { throw NativeAudioStreamParser.Failure.native(propertyStatus) }
        guard upper > 0, upper <= 8184 else { return nil }
        for index in 0..<maximumPackets {
            try checkInput()
            var bytes = Data(count: 8192), size: UInt32 = 8192, count: UInt32 = 1
            var description = AudioStreamPacketDescription()
            let status = bytes.withUnsafeMutableBytes {
                AudioFileReadPacketData(file, false, &size, &description, Int64(index), &count, $0.baseAddress!)
            }
            try checkInput()
            guard status == noErr || status == kAudioFileEndOfFileError else { throw NativeAudioStreamParser.Failure.native(status) }
            guard size <= bytes.count, count <= 1 else { throw NativeAudioStreamParser.Failure.invalidPacket }
            if count == 0 { break }
            guard description.mStartOffset >= 0, description.mDataByteSize > 0,
                  description.mStartOffset <= Int64(size) - Int64(description.mDataByteSize) else { throw NativeAudioStreamParser.Failure.invalidPacket }
            try bytes.withUnsafeBytes { data in
                try probe.append(UnsafeRawBufferPointer(rebasing: data[Int(description.mStartOffset)..<(Int(description.mStartOffset) + Int(description.mDataByteSize))]))
            }
            if probe.finished { break }
        }
        return probe.result
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw NativeAudioStreamParser.Failure.native(status) }
    }
    private static let rates: [Double] = [96000,88200,64000,48000,44100,32000,24000,22050,16000,12000,11025,8000,7350]

    /// AudioToolbox cookies contain either ASC or MPEG-4 ES descriptors. Reject
    /// PCE, explicit-frequency, 960-frame and core-dependent configurations;
    /// those cannot be represented by the probe's ADTS header.
    static func core(_ cookie: Data) -> (frequency: Int, channels: Int)? {
        let data = [UInt8](cookie)
        guard !data.isEmpty, data.count <= 65536 else { return nil }
        func specific(_ begin: Int, _ end: Int, _ depth: Int) -> ArraySlice<UInt8>? {
            guard depth <= 3 else { return nil }
            var position = begin
            while position < end {
                let tag = data[position]; position += 1
                var length = 0, terminated = false
                for _ in 0..<4 {
                    guard position < end else { return nil }
                    let byte = data[position]; position += 1
                    length = length << 7 | Int(byte & 127)
                    if byte & 128 == 0 { terminated = true; break }
                }
                guard terminated, length <= end - position else { return nil }
                let limit = position + length
                if tag == 5 { return data[position..<limit] }
                if tag == 3 {
                    guard length >= 3 else { return nil }
                    let flags = data[position + 2]; var child = position + 3
                    if flags & 128 != 0 { child += 2 }
                    if flags & 64 != 0 {
                        guard child < limit else { return nil }
                        child += 1 + Int(data[child])
                    }
                    if flags & 32 != 0 { child += 2 }
                    guard child <= limit else { return nil }
                    if let value = specific(child, limit, depth + 1) { return value }
                } else if tag == 4 {
                    guard length >= 13, data[position] == 0x40, data[position + 1] >> 2 == 5 else { return nil }
                    if let value = specific(position + 13, limit, depth + 1) { return value }
                }
                position = limit
            }
            return nil
        }
        let bytes: ArraySlice<UInt8>
        if data[0] == 3 || data[0] == 4 || data[0] == 5 {
            guard let value = specific(0, data.count, 0) else { return nil }; bytes = value
        } else { bytes = data[...] }
        guard bytes.count >= 2 else { return nil }
        let first = bytes[bytes.startIndex], second = bytes[bytes.startIndex + 1]
        let frequency = Int(first & 7) << 1 | Int(second >> 7), channels = Int(second >> 3 & 15)
        guard first >> 3 == 2, frequency < rates.count, (1...6).contains(channels), second & 7 == 0 else { return nil }
        return (frequency, channels)
    }
}
