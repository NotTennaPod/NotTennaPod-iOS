import AVFoundation
import CoreMedia
import Foundation

/// Converter and callback buffers stay on the reader's executor. Temporary
/// input exhaustion is .noDataNow; only real transport EOF drains the codec.
/// More than two channels are decoded in the codec's own speaker layout and
/// played as stereo (`PCMStereoDownmix`).
final class NativeAudioStreamConverter {
    enum Step { case audio(NativePCMDecoder.Packet), needsInput, ended }
    let sampleRate: Int, channels: Int
    private let decodedChannels: Int
    private let downmix: PCMStereoDownmix?
    private let configuration: NativeAudioStreamParser.Configuration
    private let converter: AVAudioConverter
    private let output: AVAudioPCMBuffer
    private var pending: AVAudioBuffer?
    private var needsInput = true, sourceEnded = false, ended = false
    private var decoded: Int64 = 0, emitted: Int64 = 0
    private var allowIncompleteAfterSourceFailure = false

    init(configuration: NativeAudioStreamParser.Configuration, maximumFrames: Int) throws {
        var basic = configuration.basic
        if basic.mFormatID == kAudioFormatFLAC, basic.mFramesPerPacket == 0 {
            // AVAudioConverter rejects a zero FLAC packet capacity. STREAMINFO's
            // maximum sizes the converter; explicit per-packet counts retain
            // the real variable timing and the original cookie is unchanged.
            guard let capacity = configuration.maximumPacketFrames, capacity > 0 else {
                throw NativeAudioStreamParser.Failure.invalidFormat
            }
            basic.mFramesPerPacket = capacity
        }
        let input: AVAudioFormat?, format: AVAudioFormat?
        let layout = basic.mChannelsPerFrame > 2 ? Self.decodedLayout(basic: basic, configuration: configuration) : nil
        if let layout {
            // Input and output share the decoded layout, so nothing is reordered.
            input = AVAudioFormat(streamDescription: &basic, channelLayout: layout)
            format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: basic.mSampleRate, interleaved: true, channelLayout: layout)
        } else {
            input = AVAudioFormat(streamDescription: &basic)
            format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: basic.mSampleRate,
                channels: basic.mChannelsPerFrame, interleaved: true)
        }
        guard let input, let format,
              let converter = AVAudioConverter(from: input, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(maximumFrames)) else {
            throw NativeAudioStreamParser.Failure.invalidFormat
        }
        if let cookie = configuration.cookie { converter.magicCookie = cookie }
        self.configuration = configuration; self.converter = converter; self.output = output
        sampleRate = Int(basic.mSampleRate); decodedChannels = Int(basic.mChannelsPerFrame)
        if let layout {
            guard let downmix = PCMStereoDownmix(layout: layout, channels: decodedChannels) else { throw NativeAudioStreamParser.Failure.invalidFormat }
            self.downmix = downmix; channels = 2
        } else { downmix = nil; channels = decodedChannels }
    }
    /// The rate and channel count a configuration decodes to (surround as stereo).
    static func outputFormat(_ configuration: NativeAudioStreamParser.Configuration) -> (sampleRate: Int, channels: Int) {
        (Int(configuration.basic.mSampleRate), configuration.basic.mChannelsPerFrame > 2 ? 2 : Int(configuration.basic.mChannelsPerFrame))
    }
    /// The order a codec decodes into (AAC 5.1: C, L, R, Ls, Rs, LFE) when it
    /// names positions, else the container's positional layout, else whichever
    /// count-only (discrete) layout there is: FFmpeg's default order then.
    private static func decodedLayout(basic: AudioStreamBasicDescription,
                                      configuration: NativeAudioStreamParser.Configuration) -> AVAudioChannelLayout? {
        let channels = basic.mChannelsPerFrame
        var codec: AVAudioChannelLayout?
        if basic.mFormatID != kAudioFormatLinearPCM {
            var source = basic, decoded = AudioStreamBasicDescription(mSampleRate: basic.mSampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
                mBytesPerPacket: channels * 2, mFramesPerPacket: 1, mBytesPerFrame: channels * 2,
                mChannelsPerFrame: channels, mBitsPerChannel: 16, mReserved: 0)
            var converter: AudioConverterRef?
            if AudioConverterNew(&source, &decoded, &converter) == noErr, let converter {
                defer { AudioConverterDispose(converter) }
                if var cookie = configuration.cookie {
                    _ = cookie.withUnsafeMutableBytes {
                        AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32($0.count), $0.baseAddress!)
                    }
                }
                var size: UInt32 = 0
                if AudioConverterGetPropertyInfo(converter, kAudioConverterOutputChannelLayout, &size, nil) == noErr,
                   size >= UInt32(MemoryLayout<AudioChannelLayout>.size) {
                    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
                    defer { raw.deallocate() }
                    if AudioConverterGetProperty(converter, kAudioConverterOutputChannelLayout, &size, raw) == noErr {
                        let layout = AVAudioChannelLayout(layout: raw.assumingMemoryBound(to: AudioChannelLayout.self))
                        if layout.channelCount == channels { codec = layout }
                    }
                }
            }
        }
        let container = configuration.channelLayout.map { data in
            data.withUnsafeBytes { AVAudioChannelLayout(layout: $0.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self)) }
        }.flatMap { $0.channelCount == channels ? $0 : nil }
        return [codec, container].compactMap { $0 }.first { PCMStereoDownmix.isPositional(PCMStereoDownmix.labels($0)) }
            ?? codec ?? container ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
    }
    convenience init(configuration: NativeAudioStreamParser.Configuration, maximumFrames: Int, firstFrame: Int64) throws {
        try self.init(configuration: configuration, maximumFrames: maximumFrames)
        guard firstFrame >= 0,
              configuration.validFrames.map({ firstFrame <= configuration.primingFrames + $0 }) ?? true else {
            throw NativeAudioStreamParser.Failure.invalidPacket
        }
        decoded = firstFrame
        emitted = max(0, min(firstFrame - configuration.primingFrames, configuration.validFrames ?? .max))
    }
    func accept(_ batch: NativeAudioStreamParser.Batch) throws {
        guard needsInput, pending == nil, !sourceEnded else { throw NativeAudioStreamParser.Failure.invalidPacket }
        let basic = configuration.basic
        if basic.mFormatID == kAudioFormatLinearPCM {
            let frames = UInt64(batch.packetCount) * UInt64(basic.mFramesPerPacket)
            guard frames > 0, frames <= UInt32.max, converter.inputFormat.isInterleaved,
                  UInt64(basic.mBytesPerFrame) * frames == batch.bytes.count,
                  let buffer = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: UInt32(frames)) else {
                throw NativeAudioStreamParser.Failure.invalidPacket
            }
            buffer.frameLength = UInt32(frames)
            let list = buffer.mutableAudioBufferList
            guard list.pointee.mNumberBuffers == 1, let destination = list.pointee.mBuffers.mData,
                  list.pointee.mBuffers.mDataByteSize >= batch.bytes.count else { throw NativeAudioStreamParser.Failure.invalidPacket }
            batch.bytes.withUnsafeBytes { destination.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            pending = buffer
        } else {
            let maximumPacket = batch.descriptions?.map(\.mDataByteSize).max() ?? basic.mBytesPerPacket
            guard maximumPacket > 0, UInt64(maximumPacket) * UInt64(batch.packetCount) <= NativeAudioStreamParser.maximumBatchBytes else {
                throw NativeAudioStreamParser.Failure.invalidCapacity
            }
            let buffer = AVAudioCompressedBuffer(format: converter.inputFormat, packetCapacity: batch.packetCount,
                maximumPacketSize: Int(maximumPacket))
            guard batch.bytes.count <= buffer.byteCapacity else { throw NativeAudioStreamParser.Failure.invalidPacket }
            batch.bytes.withUnsafeBytes { buffer.data.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            if let descriptions = batch.descriptions {
                guard let destination = buffer.packetDescriptions else { throw NativeAudioStreamParser.Failure.invalidPacket }
                descriptions.withUnsafeBufferPointer { destination.update(from: $0.baseAddress!, count: $0.count) }
            }
            buffer.packetCount = batch.packetCount; buffer.byteLength = UInt32(batch.bytes.count)
            pending = buffer
        }
        needsInput = false
    }
    func finish(afterSourceFailure: Bool = false) {
        allowIncompleteAfterSourceFailure = afterSourceFailure
        sourceEnded = true; needsInput = false
    }
    func next() throws -> Step {
        if ended { return .ended }
        if needsInput { return .needsInput }
        while true {
            var error: NSError?, supplied: AVAudioBuffer?
            output.frameLength = 0
            let status = converter.convert(to: output, error: &error) { [self] _, state in
                if let buffer = pending { supplied = buffer; pending = nil; state.pointee = .haveData; return buffer }
                state.pointee = sourceEnded ? .endOfStream : .noDataNow
                return nil
            }
            withExtendedLifetime(supplied) {}
            if let error { throw error }
            guard status != .error else { throw NativeAudioStreamParser.Failure.invalidFormat }
            if status == .endOfStream {
                guard sourceEnded, output.frameLength == 0,
                      (allowIncompleteAfterSourceFailure || (configuration.validFrames.map({ $0 == emitted }) ?? true)) else { throw NativeMP3PCMDecoder.Failure.incompleteStream }
                ended = true; return .ended
            }
            needsInput = status == .inputRanDry
            let first = decoded, count = Int64(output.frameLength)
            let next = decoded.addingReportingOverflow(count)
            guard !next.overflow else { throw NativeAudioStreamParser.Failure.invalidFormat }
            decoded = next.partialValue
            let begin = max(first, configuration.primingFrames)
            let end = min(decoded, configuration.validFrames.map { configuration.primingFrames + $0 } ?? decoded)
            if end > begin {
                guard let data = output.int16ChannelData?[0] else { throw NativeAudioStreamParser.Failure.invalidFormat }
                let decoded = UnsafeBufferPointer(start: data + Int(begin - first) * decodedChannels, count: Int(end - begin) * decodedChannels)
                let packet = NativePCMDecoder.Packet(samples: downmix?.apply(decoded) ?? Array(decoded),
                    sampleRate: sampleRate, channels: channels, presentationTime: CMTime(value: emitted, timescale: Int32(sampleRate)))
                emitted += end - begin
                return .audio(packet)
            }
            if needsInput { return .needsInput }
            guard count > 0 else { throw NativeAudioStreamParser.Failure.invalidFormat }
        }
    }
}
