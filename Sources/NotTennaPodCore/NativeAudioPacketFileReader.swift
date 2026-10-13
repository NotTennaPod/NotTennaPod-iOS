import AudioToolbox
import CoreMedia
import Foundation

/// Caller-confined indexed packet access over the same authenticated byte lease.
/// Native metadata supplies packet positions and dependency history; no PCM or
/// whole-episode payload is retained here.
final class NativeAudioPacketFileReader {
    private let input: (any MediaByteInput)?
    private let file: NativeAudioFileInput
    private let format: NativeAudioSourceTimeline.Format
    private(set) var configuration: NativeAudioStreamParser.Configuration!
    private(set) var firstFrame: Int64 = 0
    private(set) var firstPacket: Int64 = 0
    private var cursor: Int64 = 0, frame: Int64 = 0, packetCount: Int64 = 0
    private var maximumPackets = 0, byteCapacity = 0
    private var ended = false
    private var nativeFrameRate: Double = 0

    convenience init(input: any MediaByteInput, format: NativeAudioSourceTimeline.Format, start: CMTime, rawStart: CMTime? = nil) throws {
        guard start.isNumeric, start.epoch == 0, start >= .zero else { throw NativePCMDecoder.Failure.invalidStart }
        input.prepareForSeek()
        try self.init(file: NativeAudioFileInput(input: input, indexedReads: true), input: input, format: format, start: start, rawStart: rawStart)
    }
    convenience init(url: URL, format: NativeAudioSourceTimeline.Format, start: CMTime) throws {
        guard start.isNumeric, start.epoch == 0, start >= .zero else { throw NativePCMDecoder.Failure.invalidStart }
        try self.init(file: NativeAudioFileInput(url: url), input: nil, format: format, start: start)
    }
    private init(file: NativeAudioFileInput, input: (any MediaByteInput)?, format: NativeAudioSourceTimeline.Format, start: CMTime, rawStart: CMTime? = nil) throws {
        self.input = input; self.format = format; self.file = file
        var basic = AudioStreamBasicDescription()
        try read(kAudioFilePropertyDataFormat, into: &basic)
        nativeFrameRate = basic.mSampleRate
        do { basic = try NativeAudioFormatSelection.file(file.audioFile, fallback: basic) }
        catch { try checkIO(); throw error }
        try checkIO()
        guard nativeFrameRate.isFinite, nativeFrameRate > 0, nativeFrameRate <= 768000,
              nativeFrameRate.rounded(.towardZero) == nativeFrameRate,
              basic.mSampleRate.isFinite, basic.mSampleRate > 0, basic.mSampleRate <= 768000,
              basic.mSampleRate.rounded(.towardZero) == basic.mSampleRate,
              (1...32).contains(basic.mChannelsPerFrame) else { throw NativeAudioStreamParser.Failure.invalidFormat }
        var count: UInt64 = 0
        try read(kAudioFilePropertyAudioDataPacketCount, into: &count)
        guard count <= Int64.max else { throw NativeAudioStreamParser.Failure.invalidCapacity }
        packetCount = Int64(count)
        var table = AudioFilePacketTableInfo()
        let tableStatus = try property(kAudioFilePropertyPacketTableInfo, into: &table)
        var priming: Int64 = 0, valid: Int64?
        if tableStatus == noErr {
            guard table.mNumberValidFrames >= 0, table.mPrimingFrames >= 0,
                  !table.mNumberValidFrames.addingReportingOverflow(Int64(table.mPrimingFrames)).overflow else {
                throw NativeAudioStreamParser.Failure.invalidFormat
            }
            priming = try NativeAudioFormatSelection.frames(Int64(table.mPrimingFrames), from: nativeFrameRate, to: basic.mSampleRate)
            valid = try NativeAudioFormatSelection.frames(table.mNumberValidFrames, from: nativeFrameRate, to: basic.mSampleRate)
        } else {
            guard tableStatus == kAudioFileUnsupportedPropertyError else { try check(tableStatus); return }
            if basic.mFormatID == kAudioFormatLinearPCM {
                let total = UInt128(count) * UInt128(basic.mFramesPerPacket)
                guard total <= Int64.max else { throw NativeAudioStreamParser.Failure.invalidCapacity }
                valid = Int64(total)
            }
        }
        var cookie: Data?, size: UInt32 = 0
        let cookieStatus = AudioFileGetPropertyInfo(file.audioFile, kAudioFilePropertyMagicCookieData, &size, nil)
        try checkIO()
        if cookieStatus == noErr && size > 0 {
            guard size <= NativeAudioStreamParser.maximumBatchBytes else { throw NativeAudioStreamParser.Failure.invalidCapacity }
            var data = Data(count: Int(size))
            let status = data.withUnsafeMutableBytes { AudioFileGetProperty(file.audioFile, kAudioFilePropertyMagicCookieData, &size, $0.baseAddress!) }
            try check(status)
            guard size <= data.count else { throw NativeAudioStreamParser.Failure.invalidCapacity }
            cookie = Data(data.prefix(Int(size)))
        } else if cookieStatus != noErr && cookieStatus != kAudioFileUnsupportedPropertyError { try check(cookieStatus) }
        if format == .mp4, let selected = try NativeAACProfileDiscovery.file(file.audioFile, basic: basic, cookie: cookie, checkInput: { try checkIO() }) {
            priming = try NativeAudioFormatSelection.frames(priming, from: basic.mSampleRate, to: selected.basic.mSampleRate)
            valid = try valid.map { try NativeAudioFormatSelection.frames($0, from: basic.mSampleRate, to: selected.basic.mSampleRate) }
            basic = selected.basic; cookie = selected.cookie
        }
        if let valid, priming.addingReportingOverflow(valid).overflow { throw NativeAudioStreamParser.Failure.invalidFormat }
        var layout: Data?
        if basic.mChannelsPerFrame > 2, AudioFileGetPropertyInfo(file.audioFile, kAudioFilePropertyChannelLayout, &size, nil) == noErr,
           size >= UInt32(MemoryLayout<AudioChannelLayout>.size), size <= 65_536 {
            var data = Data(count: Int(size))
            if data.withUnsafeMutableBytes({ AudioFileGetProperty(file.audioFile, kAudioFilePropertyChannelLayout, &size, $0.baseAddress!) }) == noErr {
                layout = data
            }
        }
        try checkIO()
        configuration = .init(basic: basic, cookie: cookie, primingFrames: priming, validFrames: valid, channelLayout: layout)
        var upper: UInt32 = 0
        try read(kAudioFilePropertyPacketSizeUpperBound, into: &upper)
        guard upper > 0, upper <= NativeAudioStreamParser.maximumBatchBytes else { throw NativeAudioStreamParser.Failure.invalidCapacity }
        if format == .wav {
            guard basic.mFramesPerPacket == 1, basic.mBytesPerPacket > 0 else { throw NativeAudioStreamParser.Failure.invalidFormat }
            maximumPackets = min(NativeAudioStreamParser.maximumBatchBytes / Int(upper), max(1, Int(basic.mSampleRate) / 10))
            byteCapacity = maximumPackets * Int(upper)
        } else {
            byteCapacity = max(65536, Int(upper))
            maximumPackets = min(64, byteCapacity / Int(upper))
        }
        let target = CMTimeConvertScale(start, timescale: Int32(basic.mSampleRate), method: .roundTowardZero)
        guard target.isNumeric, target.value >= 0,
              !target.value.addingReportingOverflow(priming).overflow else { throw NativePCMDecoder.Failure.invalidStart }
        if packetCount == 0 { ended = true; return }
        let total = valid.map { Int128($0) + Int128(priming) }
            ?? (basic.mFramesPerPacket > 0 ? Int128(packetCount) * Int128(basic.mFramesPerPacket) : Int128.max)
        var requestedRaw = Int128(target.value) + Int128(priming)
        if let rawStart {
            let raw = CMTimeConvertScale(rawStart, timescale: Int32(basic.mSampleRate), method: .roundTowardZero)
            guard raw.isNumeric, raw.epoch == 0, raw.value >= 0 else { throw NativePCMDecoder.Failure.invalidStart }
            requestedRaw = Int128(raw.value)
        }
        let rawExtent = rawStart != nil && basic.mFramesPerPacket > 0
            ? Int128(packetCount) * Int128(basic.mFramesPerPacket) : total
        let rawTarget = Int64(clamping: min(requestedRaw, max(0, rawExtent - 1)))
        // AudioFile's frame/packet translations use its base DataFormat units,
        // even when the selected SBR output has twice that sample rate.
        let indexedTarget = try NativeAudioFormatSelection.frames(rawTarget, from: basic.mSampleRate, to: nativeFrameRate)
        var location = AudioFramePacketTranslation(mFrame: indexedTarget, mPacket: 0, mFrameOffsetInPacket: 0)
        try read(kAudioFilePropertyFrameToPacket, into: &location)
        guard location.mPacket >= 0, location.mPacket < packetCount else { throw NativeAudioStreamParser.Failure.invalidPacket }
        var selected = location.mPacket
        if format == .wav { selected -= selected % Int64(maximumPackets) }
        let dependency = try rollDistance(at: selected)
        selected -= dependency
        location = AudioFramePacketTranslation(mFrame: 0, mPacket: selected, mFrameOffsetInPacket: 0)
        try read(kAudioFilePropertyPacketToFrame, into: &location)
        guard location.mFrame >= 0 else { throw NativeAudioStreamParser.Failure.invalidPacket }
        cursor = selected
        frame = try NativeAudioFormatSelection.frames(location.mFrame, from: nativeFrameRate, to: basic.mSampleRate)
        firstPacket = selected; firstFrame = frame
    }
    deinit { file.close() }
    var bytesRead: Int64 { file.bytesRead }
    var estimatedFrameCount: Int64? {
        if let valid = configuration.validFrames { return valid }
        guard configuration.basic.mFramesPerPacket > 0 else { return nil }
        return Int64(exactly: max(0, Int128(packetCount) * Int128(configuration.basic.mFramesPerPacket) - Int128(configuration.primingFrames)))
    }
    var firstSampleOrdinal: Int64 { format == .wav ? firstPacket / Int64(maximumPackets) : firstPacket }

    func next() throws -> NativeAudioStreamParser.Batch? {
        try checkIO()
        guard !ended else { return nil }
        let requested = min(maximumPackets, Int(clamping: packetCount - cursor))
        guard requested > 0 else { ended = true; return nil }
        var count = UInt32(requested), size = UInt32(byteCapacity), data = Data(count: byteCapacity)
        let variable = configuration.basic.mBytesPerPacket == 0
        var descriptions = [AudioStreamPacketDescription](repeating: .init(), count: variable ? requested : 0)
        let status = data.withUnsafeMutableBytes { bytes in
            descriptions.withUnsafeMutableBufferPointer { packets in
                AudioFileReadPacketData(file.audioFile, false, &size, packets.baseAddress, cursor, &count, bytes.baseAddress!)
            }
        }
        try checkIO()
        guard status == noErr || status == kAudioFileEndOfFileError else { try check(status); return nil }
        guard count <= requested, size <= data.count else { throw NativeAudioStreamParser.Failure.invalidPacket }
        guard count > 0 else {
            // The native packet count is part of this finite input's contract.
            guard cursor == packetCount else { throw NativeMP3PCMDecoder.Failure.incompleteStream }
            ended = true; return nil
        }
        if format == .wav {
            let bytes = UInt64(count) * UInt64(configuration.basic.mBytesPerPacket)
            guard bytes == size, frame <= Int64.max - Int64(count) else { throw NativeAudioStreamParser.Failure.invalidPacket }
            let origin = frame
            frame += Int64(count); cursor += Int64(count); ended = cursor == packetCount
            return .init(bytes: Data(data.prefix(Int(size))), packetCount: count, descriptions: nil, firstFrame: origin)
        }
        var payload = Data(), normalized: [AudioStreamPacketDescription] = [], rolls: [Int64] = []
        let origin = frame
        for index in 0..<Int(count) {
            var description = variable ? descriptions[index] : AudioStreamPacketDescription(
                mStartOffset: Int64(index) * Int64(configuration.basic.mBytesPerPacket),
                mVariableFramesInPacket: configuration.basic.mFramesPerPacket, mDataByteSize: configuration.basic.mBytesPerPacket)
            guard description.mStartOffset >= 0, description.mDataByteSize > 0,
                  description.mStartOffset <= Int64(size) - Int64(description.mDataByteSize) else {
                throw NativeAudioStreamParser.Failure.invalidPacket
            }
            if description.mVariableFramesInPacket != 0, nativeFrameRate != configuration.basic.mSampleRate {
                let decoded = try NativeAudioFormatSelection.frames(Int64(description.mVariableFramesInPacket), from: nativeFrameRate, to: configuration.basic.mSampleRate)
                guard let value = UInt32(exactly: decoded) else { throw NativeAudioStreamParser.Failure.invalidPacket }
                description.mVariableFramesInPacket = value
            }
            let frames = description.mVariableFramesInPacket == 0 ? configuration.basic.mFramesPerPacket : description.mVariableFramesInPacket
            guard frames > 0, frame <= Int64.max - Int64(frames) else { throw NativeAudioStreamParser.Failure.invalidPacket }
            let begin = Int(description.mStartOffset), end = begin + Int(description.mDataByteSize)
            description.mStartOffset = Int64(payload.count)
            payload.append(data[begin..<end]); normalized.append(description)
            rolls.append(try rollDistance(at: cursor + Int64(index)))
            frame += Int64(frames)
        }
        cursor += Int64(count)
        if cursor == packetCount { ended = true }
        return .init(bytes: payload, packetCount: count, descriptions: variable ? normalized : nil,
            firstFrame: origin, rollDistances: rolls)
    }
    private func rollDistance(at packet: Int64) throws -> Int64 {
        if packet == 0 || format == .wav { return 0 }
        var value = AudioPacketRollDistanceTranslation(mPacket: packet, mRollDistance: -1)
        try read(kAudioFilePropertyPacketToRollDistance, into: &value)
        guard value.mRollDistance >= 0, value.mRollDistance <= packet else { throw NativeAudioStreamParser.Failure.invalidPacket }
        return value.mRollDistance
    }
    private func property<T>(_ id: AudioFilePropertyID, into value: inout T) throws -> OSStatus {
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { AudioFileGetProperty(file.audioFile, id, &size, $0.baseAddress!) }
        try checkIO()
        if status == noErr && size != MemoryLayout<T>.size { throw NativeAudioStreamParser.Failure.invalidFormat }
        return status
    }
    private func read<T>(_ id: AudioFilePropertyID, into value: inout T) throws { try check(property(id, into: &value)) }
    private func checkIO() throws {
        if let failure = file.failure { throw failure }
        try input?.checkFailure()
        try Task.checkCancellation()
    }
    private func check(_ status: OSStatus) throws {
        try checkIO()
        guard status == noErr else { throw NativeAudioStreamParser.Failure.native(status) }
    }
}
