import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

/// Serial, pull-driven local decoding. Each pull is bounded; an episode is never decoded
/// into one in-memory buffer. Remote media and playback/output scheduling are separate.
public actor NativePCMDecoder: PCMDecoding {
    public struct Packet: Sendable {
        public let samples: [Int16]
        public let sampleRate: Int
        public let channels: Int
        public let presentationTime: CMTime
        /// Container timestamps are checked once per decoded buffer, before chunk splitting.
        public let startsDecodedBuffer: Bool
        public let discontinuity: Bool
        /// Original media coordinates, when editing has changed presentation
        /// time. Encoder-padding intervals refer to this unedited sample data.
        let uneditedTime: CMTime?
        public var frameCount: Int { samples.count / channels }

        init(samples: [Int16], sampleRate: Int, channels: Int, presentationTime: CMTime,
             startsDecodedBuffer: Bool = true, discontinuity: Bool = false, uneditedTime: CMTime? = nil) {
            self.samples = samples
            self.sampleRate = sampleRate
            self.channels = channels
            self.presentationTime = presentationTime
            self.startsDecodedBuffer = startsDecodedBuffer
            self.discontinuity = discontinuity
            self.uneditedTime = uneditedTime
        }
    }
    public enum Failure: Error, Equatable { case notLocal, invalidFormat, invalidStart, cancelled }
    private let file: LocalAudioFile
    private let buffer: AVAudioPCMBuffer
    public nonisolated let startFrame: Int64
    public nonisolated let sampleRate: Int
    public nonisolated let channels: Int
    private var cancelled = false
    private var ended = false
    private var position: Int64

    public init(url: URL, start: CMTime = .zero) throws {
        guard url.isFileURL else { throw Failure.notLocal }
        guard start.isNumeric, start >= .zero else { throw Failure.invalidStart }
        try Task.checkCancellation()
        // The native reader identifies contents, including extensionless .media downloads.
        let file = try LocalAudioFile(url: url)
        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatInt16, format.isInterleaved,
              (1...32).contains(format.channelCount), format.sampleRate.isFinite,
              format.sampleRate > 0, format.sampleRate <= 768_000,
              format.sampleRate.rounded(.towardZero) == format.sampleRate,
              file.estimatedLength >= 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw Failure.invalidFormat
        }
        let target = CMTimeConvertScale(start, timescale: Int32(format.sampleRate), method: .roundTowardZero)
        guard target.isNumeric, target.value >= 0 else { throw Failure.invalidStart }
        // The reported compressed length can underestimate valid audio. Bound
        // the seek anchor by that estimate, not the requested output position.
        // Decode one second of preroll and discard up to the actual target.
        let anchor = max(0, min(target.value, file.estimatedLength) - Int64(format.sampleRate))
        let decodingStart = try file.seek(to: anchor)
        self.file = file
        self.buffer = buffer
        self.sampleRate = Int(format.sampleRate)
        self.channels = Int(format.channelCount)
        self.startFrame = target.value
        self.position = decodingStart
    }

    public func next() throws -> Packet? {
        guard !cancelled else { throw Failure.cancelled }
        try Task.checkCancellation()
        while !ended {
            let position = self.position
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { ended = true; return nil }
            let next = position.addingReportingOverflow(Int64(buffer.frameLength))
            guard !next.overflow else { throw Failure.invalidFormat }
            self.position = next.partialValue
            let discard = min(Int64(buffer.frameLength), max(0, startFrame - position))
            if discard == Int64(buffer.frameLength) {
                try Task.checkCancellation()
                continue
            }
            guard let samples = buffer.int16ChannelData?[0] else { throw Failure.invalidFormat }
            let offset = Int(discard) * channels
            let count = (Int(buffer.frameLength) - Int(discard)) * channels
            return Packet(samples: Array(UnsafeBufferPointer(start: samples + offset, count: count)),
                          sampleRate: sampleRate, channels: channels,
                          presentationTime: CMTime(value: position + discard, timescale: Int32(sampleRate)))
        }
        return nil
    }

    public func cancel() { cancelled = true }
}

/// Owned exclusively by the decoder actor. MP3 uses explicit zero-frame EOF,
/// since its native length can underestimate valid frames. Mismatched/opaque
/// filenames use content-only callback access to avoid native suffix misclassification.
/// Implicit AAC profiles use the full native packet format; other correctly
/// named formats retain AVAudioFile's existing read/seek path.
private final class LocalAudioFile {
    private enum Storage {
        case audioFile(AVAudioFile)
        case extended(ExtAudioFileRef, NativeAudioFileInput)
        case profile(LocalProfileAudioFile)
    }
    private let storage: Storage
    let processingFormat: AVAudioFormat
    let estimatedLength: Int64

    init(url: URL) throws {
        let input = try NativeAudioFileInput(url: url)
        if try NativeAACProfileDiscovery.file(input.audioFile, checkInput: { try Task.checkCancellation() }) != nil {
            let profile = try LocalProfileAudioFile(url: url)
            processingFormat = profile.processingFormat
            estimatedLength = profile.estimatedLength
            storage = .profile(profile)
            return
        }
        let extensions = try input.strings(kAudioFileGlobalInfo_ExtensionsForType)
        let correctlyNamed = extensions.contains { $0.caseInsensitiveCompare(url.pathExtension) == .orderedSame }
        if correctlyNamed {
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
            // Preserve the existing codec rule: MP3 needs explicit EOF even if
            // carried by a container other than a raw MPEG audio file.
            if file.fileFormat.streamDescription.pointee.mFormatID != kAudioFormatMPEGLayer3 {
                processingFormat = file.processingFormat
                estimatedLength = file.length
                storage = .audioFile(file)
                return
            }
        }
        var opened: ExtAudioFileRef?
        try Self.check(ExtAudioFileWrapAudioFileID(input.audioFile, false, &opened))
        guard let opened else { throw NativePCMDecoder.Failure.invalidFormat }
        var retained = false
        defer { if !retained { ExtAudioFileDispose(opened) } }
        var source = AudioStreamBasicDescription()
        var sourceSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(ExtAudioFileGetProperty(opened, kExtAudioFileProperty_FileDataFormat, &sourceSize, &source))
        guard source.mSampleRate.isFinite, source.mSampleRate > 0, source.mSampleRate <= 768_000,
              source.mSampleRate.rounded(.towardZero) == source.mSampleRate,
              (1...32).contains(source.mChannelsPerFrame) else { throw NativePCMDecoder.Failure.invalidFormat }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: source.mSampleRate,
            channels: source.mChannelsPerFrame, interleaved: true) else { throw NativePCMDecoder.Failure.invalidFormat }
        processingFormat = format
        var length: Int64 = 0, lengthSize = UInt32(MemoryLayout<Int64>.size)
        try Self.check(ExtAudioFileGetProperty(opened, kExtAudioFileProperty_FileLengthFrames, &lengthSize, &length))
        estimatedLength = length
        var client = processingFormat.streamDescription.pointee
        try Self.check(ExtAudioFileSetProperty(opened, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client))
        storage = .extended(opened, input)
        retained = true
    }
    deinit { if case .extended(let reference, _) = storage { ExtAudioFileDispose(reference) } }
    func seek(to frame: Int64) throws -> Int64 {
        switch storage {
        case .audioFile(let file): file.framePosition = frame
        case .extended(let reference, _): try Self.check(ExtAudioFileSeek(reference, frame))
        case .profile(let file): return try file.seek(to: frame)
        }
        return frame
    }
    func read(into buffer: AVAudioPCMBuffer) throws {
        switch storage {
        case .audioFile(let file):
            let remaining = file.length - file.framePosition
            guard remaining > 0 else { buffer.frameLength = 0; return }
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining)))
        case .profile(let file): try file.read(into: buffer)
        case .extended(let reference, _):
            buffer.frameLength = buffer.frameCapacity
            var frames = buffer.frameCapacity
            try Self.check(ExtAudioFileRead(reference, &frames, buffer.mutableAudioBufferList))
            guard frames <= buffer.frameCapacity else { throw NativePCMDecoder.Failure.invalidFormat }
            buffer.frameLength = frames
        }
    }
    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

/// Local counterpart of the full-profile native packet path. The selected
/// file descriptor stays open while reading, including opaque downloads.
private final class LocalProfileAudioFile {
    let processingFormat: AVAudioFormat
    let estimatedLength: Int64
    private let url: URL
    private var reader: NativeAudioPacketFileReader
    private var converter: NativeAudioStreamConverter?
    private var packetsEnded = false

    init(url: URL) throws {
        self.url = url
        reader = try NativeAudioPacketFileReader(url: url, format: .mp4, start: .zero)
        let basic = reader.configuration.basic
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: basic.mSampleRate,
            channels: basic.mChannelsPerFrame, interleaved: true),
              let length = reader.estimatedFrameCount else { throw NativePCMDecoder.Failure.invalidFormat }
        processingFormat = format; estimatedLength = length
    }
    func seek(to frame: Int64) throws -> Int64 {
        if frame > 0 {
            reader = try NativeAudioPacketFileReader(url: url, format: .mp4,
                start: CMTime(value: frame, timescale: Int32(processingFormat.sampleRate)))
        }
        converter = try NativeAudioStreamConverter(configuration: reader.configuration,
            maximumFrames: 4096, firstFrame: reader.firstFrame)
        packetsEnded = false
        return max(0, reader.firstFrame - reader.configuration.primingFrames)
    }
    func read(into buffer: AVAudioPCMBuffer) throws {
        guard let converter else { throw NativePCMDecoder.Failure.invalidFormat }
        while true {
            try Task.checkCancellation()
            switch try converter.next() {
            case .audio(let packet):
                guard packet.frameCount <= buffer.frameCapacity,
                      packet.channels == buffer.format.channelCount,
                      Double(packet.sampleRate) == buffer.format.sampleRate,
                      let destination = buffer.int16ChannelData?[0] else { throw NativePCMDecoder.Failure.invalidFormat }
                packet.samples.withUnsafeBufferPointer { samples in
                    destination.update(from: samples.baseAddress!, count: samples.count)
                }
                buffer.frameLength = AVAudioFrameCount(packet.frameCount)
                return
            case .ended: buffer.frameLength = 0; return
            case .needsInput:
                guard !packetsEnded else { throw NativeAudioStreamParser.Failure.invalidFormat }
                if let batch = try reader.next() { try converter.accept(batch) }
                else { packetsEnded = true; converter.finish() }
            }
        }
    }
}
