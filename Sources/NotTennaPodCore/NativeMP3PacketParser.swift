import AudioToolbox
import CoreMedia
import Foundation

/// Incremental compressed packets for Apple's audio renderer. Confined to its caller's
/// executor; AudioFileStream invokes both callbacks synchronously inside parseBytes.
/// Does not own networking, playback intent, or infer an end from a temporary lack of data.
final class NativeMP3PacketParser {
    enum Failure: Error, Equatable {
        case closed, invalidChunk, invalidFormat, invalidPacket, invalidPacketTable, native(OSStatus)
    }
    /// The stream as its first frame describes it. A later run of frames at another
    /// sample rate or channel count keeps this timing and is converted to its geometry.
    struct Timing: Equatable, Sendable {
        let sampleRate: Int32
        let channels: Int
        let encodedFrameCount: Int64?
        let validFrameCount: Int64?
        let primingFrameCount: Int64?
        let remainderFrameCount: Int64?

        /// The original Xing seeker reports its encoded timeline separately from
        /// audio trimming, subtracting one sample before converting to duration.
        var durationMilliseconds: Int64? {
            guard let encodedFrameCount, encodedFrameCount > 0 else { return nil }
            let time = CMTimeConvertScale(CMTime(value: encodedFrameCount - 1, timescale: sampleRate),
                timescale: 1000, method: .roundTowardZero)
            return time.isNumeric ? time.value : nil
        }
    }
    struct Batch: Sendable {
        let bytes: Data
        let descriptions: [AudioStreamPacketDescription]
        let format: CMAudioFormatDescription
        let firstFrame: Int64
        let frameCount: Int64
        var timing: Timing
        var rollDistances: [Int64]? = nil
        var rangeOrigin: CMTime? = nil
        /// Exact time of the first packet since the parser's start: the sum of every earlier
        /// packet's frames at its own rate. Nil: all earlier packets had the stream's rate.
        var sourceTime: CMTime? = nil
        /// A frame at or before this batch, since the parser's start, had another sample rate
        /// or channel count than the stream's first frame.
        var afterFormatChange = false

        /// This batch's own configuration; one batch never spans a format change.
        var sampleRate: Int32 { Int32(format.audioStreamBasicDescription?.mSampleRate ?? Double(timing.sampleRate)) }
        var startTime: CMTime { sourceTime ?? CMTime(value: firstFrame, timescale: timing.sampleRate) }
        var duration: CMTime { CMTime(value: frameCount, timescale: sampleRate) }

        var sampleBuffer: CMReadySampleBuffer<CMReadOnlyDataBlockBuffer> {
            CMReadySampleBuffer(compressedAudioDataBuffer: CMReadOnlyDataBlockBuffer(bytes),
                formatDescription: format,
                presentationTimeStamp: CMTime(value: firstFrame,
                    timescale: timing.sampleRate),
                packetDescriptions: descriptions)
        }
    }
    private var stream: AudioFileStreamID?
    private var format: CMAudioFormatDescription?
    private var batches: [Batch] = []
    private var pendingBytes = Data()
    private var xingMetadata: MP3XingMetadata
    private var failure: (any Error)?
    private var finished = false
    private var nextParseFlags: AudioFileStreamParseFlags = []
    private(set) var parsedFrames: Int64 = 0
    private(set) var timing: Timing?
    /// Exact time of the next packet; see Batch.sourceTime.
    private var parsedTime: CMTime?
    /// Packets the current native stream has produced, for its dependency queries.
    private var streamPackets: Int64 = 0
    private var tracker = MP3RateTracker()
    private var formatChanged = false
    /// The current native stream began where the bytes were not followed frame by frame
    /// (after an indexed seek or junk): frames before it may still be needed to decode it.
    private var streamStartsMidRun = false
    /// AudioFileStream's own MP3 dependency distance once enough packets precede one.
    private static let nativePreroll: Int64 = 18
    /// Bytes the tracker has not yet confirmed as frames at the current rate, starting at
    /// stream byte `trackedStart`; `forwarded` bytes have gone to native streams so far.
    private var tracked = Data()
    private var trackedStart: Int64 = 0
    private var forwarded: Int64 = 0
    /// ID3v2 tags (and their verified v2.4 footers) before the first audio are never given to
    /// AudioFileStream: it then starts, as for an untagged file, at the first audio with its
    /// whole startup lookahead, however reads split the tags. (Fed a tag whose footer follows
    /// its body and then another tag, it misses or invents packets even in one read; it takes
    /// no timing from ID3.) Source byte coordinates keep counting these bytes.
    private var leading = LeadingTags.header
    private var leadingPartial = Data()
    private var leadingBytes: Int64 = 0
    private enum LeadingTags { case header, body(Int64, footer: ID3v2Header?), footer(ID3v2Header), audio }
    private var derivedFormats: [MP3FrameConfiguration: CMAudioFormatDescription] = [:]
    func takeSourceFrame() -> MP3XingMetadata.SourceFrame? { xingMetadata.takeSourceFrame() }

    struct SeekPosition: Sendable {
        let bytePosition: Int64
        let isEstimated: Bool
    }
    /// The returned byte position includes DataOffset. An estimated packet
    /// ordinal is suitable for native parser bookkeeping, never an exact source
    /// clock or declared end-count assertion in a positioned decoder.
    func seek(toPacket packet: Int64) throws -> SeekPosition {
        guard let stream, let basic = format?.audioStreamBasicDescription, timing != nil else {
            throw Failure.invalidFormat
        }
        if let failure { throw failure }
        guard packet >= 0 else { throw Failure.invalidPacket }
        let (frame, overflow) = packet.multipliedReportingOverflow(by: Int64(basic.mFramesPerPacket))
        guard !overflow else { throw Failure.invalidPacket }
        var relative: Int64 = 0, flags: AudioFileStreamSeekFlags = []
        let status = AudioFileStreamSeek(stream, packet, &relative, &flags)
        guard status == noErr else { throw Failure.native(status) }
        var dataOffset: Int64 = 0, size = UInt32(MemoryLayout<Int64>.size)
        let offsetStatus = AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataOffset, &size, &dataOffset)
        guard offsetStatus == noErr else { throw Failure.native(offsetStatus) }
        let (absolute, offsetOverflow) = (dataOffset + leadingBytes).addingReportingOverflow(relative)
        guard !offsetOverflow, absolute >= 0 else { throw Failure.invalidPacket }
        pendingBytes.removeAll(keepingCapacity: true); batches.removeAll(keepingCapacity: true)
        parsedFrames = frame; finished = false; nextParseFlags = []
        streamPackets = packet; parsedTime = nil; resynchronize()
        return SeekPosition(bytePosition: absolute, isEstimated: flags.contains(.offsetIsEstimated))
    }

    /// A source-owned index may select arbitrary encoded bytes. Discard a
    /// partial packet at that boundary using the supported native parse flag;
    /// retain native packet bookkeeping for dependency queries, not source time.
    func beginDiscontinuity() throws {
        guard stream != nil, format != nil, timing != nil else { throw Failure.invalidFormat }
        if let failure { throw failure }
        pendingBytes.removeAll(keepingCapacity: true); batches.removeAll(keepingCapacity: true)
        nextParseFlags = .discontinuity; finished = false
        resynchronize()
    }

    private func resynchronize() {
        trackedStart = forwarded; tracked.removeAll(keepingCapacity: true); tracker.resynchronize()
    }

    init(captureSourceFrame: Bool = false) throws {
        xingMetadata = MP3XingMetadata(retainSourceFrame: captureSourceFrame)
        stream = try Self.open(self)
    }

    private static func open(_ parser: NativeMP3PacketParser) throws -> AudioFileStreamID {
        var opened: AudioFileStreamID?
        let status = AudioFileStreamOpen(Unmanaged.passUnretained(parser).toOpaque(),
            { context, stream, property, _ in
                Unmanaged<NativeMP3PacketParser>.fromOpaque(context).takeUnretainedValue()
                    .propertyChanged(stream, property)
            }, { context, byteCount, packetCount, bytes, descriptions in
                Unmanaged<NativeMP3PacketParser>.fromOpaque(context).takeUnretainedValue()
                    .receive(byteCount: byteCount, packetCount: packetCount,
                             bytes: bytes, descriptions: descriptions)
            }, kAudioFileMP3Type, &opened)
        guard status == noErr, let opened else { throw Failure.native(status) }
        return opened
    }

    deinit { close() }

    /// Bounded input also bounds newly retained packet data. Empty input is inert, not EOF.
    func append(_ bytes: Data) throws -> [Batch] {
        guard stream != nil, !finished else { throw Failure.closed }
        if let failure { throw failure }
        guard bytes.count <= 32_768 else { throw Failure.invalidChunk }
        guard !bytes.isEmpty else { return [] }
        xingMetadata.append(bytes)
        guard let bytes = skipLeadingTags(bytes) else { return [] }
        pendingBytes.append(bytes)
        tracked.append(bytes)
        defer { batches.removeAll(keepingCapacity: true) }
        var held: Int64?
        while true {
            let scan = tracker.scan(tracked)
            guard let change = scan.change else {
                held = scan.hold.map { trackedStart + Int64($0) }
                tracked.removeFirst(scan.safe); trackedStart += Int64(scan.safe); tracker.consumed(scan.safe)
                break
            }
            try restart(at: change)
        }
        // Initial tiny reads can misidentify an Info/Xing frame or emit it as audio.
        // Supply bounded header lookahead until the format is ready. Afterwards,
        // at least four bytes avoid the independently reproduced one-byte packet loss.
        // A frame that may begin another sample rate waits until that is known: given
        // to this stream, it can become a packet in the wrong format.
        let count = held.map { Int(max(0, min(Int64(pendingBytes.count), $0 - forwarded))) } ?? pendingBytes.count
        guard count >= (format == nil ? 2048 : 4) else { return batches }
        try parse(pendingBytes.prefix(count))
        forwarded += Int64(count)
        pendingBytes.removeFirst(count)
        return batches
    }

    /// Only the transport's actual EOF may flush the native parser.
    func finish() throws -> [Batch] {
        guard stream != nil, !finished else { throw Failure.closed }
        if let failure { throw failure }
        finished = true
        defer { batches.removeAll(keepingCapacity: true) }
        // Bytes that never completed a tag header are not a tag.
        if case .header = leading, !leadingPartial.isEmpty {
            leading = .audio; forwarded = leadingBytes; trackedStart = leadingBytes
            pendingBytes = leadingPartial; leadingPartial = Data()
        }
        // A last frame at another rate has no later header to confirm it. At the real
        // end, a complete frame at the frame boundary is confirmation enough.
        if let change = tracker.change(atEndOf: tracked) { try restart(at: change) }
        if !pendingBytes.isEmpty {
            try parse(pendingBytes)
            forwarded += Int64(pendingBytes.count)
            pendingBytes.removeAll()
        }
        try parse(nil)
        tracked.removeAll()
        return batches
    }

    /// Consumes leading ID3v2 tags; returns the bytes from the first that are not one, or nil
    /// while every byte so far belongs to a tag (at most ten are held to recognize a header).
    private func skipLeadingTags(_ bytes: Data) -> Data? {
        if case .audio = leading { return bytes }
        let input = leadingPartial + bytes
        leadingPartial = Data()
        var index = input.startIndex
        while true {
            switch leading {
            case .audio:
                return input[index...]
            case .body(let remaining, let footer):
                let available = Int64(input.endIndex - index)
                guard available >= remaining else { leadingBytes += available; leading = .body(remaining - available, footer: footer); return nil }
                index += Int(remaining); leadingBytes += remaining
                leading = footer.map { .footer($0) } ?? .header
            case .footer(let header):
                guard input.endIndex - index >= 10 else { leadingPartial = input[index...]; return nil }
                if header.isFooter(input[index..<(index + 10)]) { index += 10; leadingBytes += 10 }
                leading = .header
            case .header:
                guard input.endIndex - index >= 10 else { leadingPartial = input[index...]; return nil }
                guard let header = ID3v2Header(input[index..<(index + 10)]) else {
                    leading = .audio; forwarded = leadingBytes; trackedStart = leadingBytes
                    continue
                }
                index += 10; leadingBytes += 10
                leading = .body(header.size, footer: header.hasFooter ? header : nil)
            }
        }
    }

    /// AudioFileStream keeps the first sample rate it locks onto and skips frames at
    /// another rate as lost sync. Give it everything before the change, flush it as at
    /// EOF, and continue with a native stream that starts at the change (`change` in the
    /// tracked bytes). Bytes past the change it already had are skipped by it as such.
    /// The stream's timing stays the first's.
    private func restart(at change: Int) throws {
        let start = trackedStart + Int64(change)
        if forwarded < start { try parse(pendingBytes.prefix(Int(start - forwarded))) }
        try parse(nil)
        if let stream { AudioFileStreamClose(stream) }
        stream = nil; format = nil; streamPackets = 0; nextParseFlags = []
        stream = try Self.open(self)
        tracked.removeFirst(change); trackedStart = start; forwarded = start
        pendingBytes = tracked
        streamStartsMidRun = !tracker.changeFollowsFrames
        tracker.restarted()
    }

    /// Feeds the current native stream; nil flushes it, as at the end of its bytes.
    private func parse(_ bytes: Data?) throws {
        guard let stream else { throw Failure.closed }
        let status: OSStatus
        if let bytes, !bytes.isEmpty {
            status = bytes.withUnsafeBytes {
                AudioFileStreamParseBytes(stream, UInt32($0.count), $0.baseAddress!, nextParseFlags)
            }
            nextParseFlags = []
        } else if bytes == nil {
            status = AudioFileStreamParseBytes(stream, 0, nil, [])
        } else { return }
        if let failure { throw failure }
        if status != noErr {
            let error = Failure.native(status)
            failure = error
            throw error
        }
    }

    func close() {
        if let stream { AudioFileStreamClose(stream) }
        stream = nil
        batches.removeAll()
        pendingBytes.removeAll()
        tracked.removeAll()
    }

    private func propertyChanged(_ stream: AudioFileStreamID, _ property: AudioFileStreamPropertyID) {
        guard failure == nil else { return }
        if property == kAudioFileStreamProperty_ReadyToProducePackets {
            // A native stream restarted at a sample-rate change describes only its
            // own run of frames; the first stream's timing describes the source.
            if timing == nil { readTiming(stream) }
            return
        }
        guard property == kAudioFileStreamProperty_DataFormat else { return }
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioFileStreamGetProperty(stream, property, &size, &description)
        guard status == noErr else { failure = Failure.native(status); return }
        guard description.mFormatID == kAudioFormatMPEGLayer3,
              description.mSampleRate.isFinite, (1...768_000).contains(description.mSampleRate),
              description.mSampleRate.rounded() == description.mSampleRate,
              (1...2).contains(description.mChannelsPerFrame), description.mFramesPerPacket > 0 else {
            failure = Failure.invalidFormat; return
        }
        do { format = try CMAudioFormatDescription(audioStreamBasicDescription: description) }
        catch { failure = error }
    }

    private func readTiming(_ stream: AudioFileStreamID) {
        guard let description = format?.audioStreamBasicDescription else { failure = Failure.invalidFormat; return }
        var packets: UInt64 = 0
        var size = UInt32(MemoryLayout<UInt64>.size)
        let countStatus = AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_AudioDataPacketCount, &size, &packets)
        guard Self.isAvailableOrUnknown(countStatus) else { failure = Failure.native(countStatus); return }
        var encodedFrames: Int64?
        if countStatus == noErr, packets > 0 {
            let (frames, overflow) = packets.multipliedReportingOverflow(by: UInt64(description.mFramesPerPacket))
            guard !overflow, let count = Int64(exactly: frames) else { failure = Failure.invalidPacketTable; return }
            encodedFrames = count
        }
        var table = AudioFilePacketTableInfo()
        size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
        let tableStatus = AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_PacketTableInfo, &size, &table)
        guard Self.isAvailableOrUnknown(tableStatus) else { failure = Failure.native(tableStatus); return }
        var valid: Int64?, priming: Int64?, remainder: Int64?
        if tableStatus == noErr {
            let padding = Int64(table.mPrimingFrames) + Int64(table.mRemainderFrames)
            let (total, overflow) = table.mNumberValidFrames.addingReportingOverflow(padding)
            guard table.mNumberValidFrames >= 0, table.mPrimingFrames >= 0, table.mRemainderFrames >= 0,
                  !overflow, encodedFrames.map({ $0 == total }) ?? true else {
                failure = Failure.invalidPacketTable; return
            }
            valid = table.mNumberValidFrames
            priming = Int64(table.mPrimingFrames)
            remainder = Int64(table.mRemainderFrames)
        }
        // For Info, native packet/table counts can be bitrate estimates even
        // when the header declares a different exact count. Preserve native
        // padding, but use that declaration for valid-frame and EOF accounting.
        // No count is inferred from downloaded bytes or observed parser output.
        if let declared = xingMetadata.infoFrames,
           declared.sampleRate == Int32(description.mSampleRate), declared.channels == Int(description.mChannelsPerFrame) {
            encodedFrames = declared.encodedFrames
            if let priming, let remainder {
                guard priming + remainder <= declared.encodedFrames else { failure = Failure.invalidPacketTable; return }
                valid = declared.encodedFrames - priming - remainder
            }
        }
        // Native MPEG2/2.5 parsing can provide packet count but omit declared
        // encoder padding. Supplement only a matching header; native tables win.
        if valid == nil, let padding = xingMetadata.padding,
           padding.sampleRate == Int32(description.mSampleRate),
           padding.channels == Int(description.mChannelsPerFrame), padding.encodedFrames == encodedFrames {
            priming = padding.leading
            remainder = padding.trailing
            valid = padding.encodedFrames - padding.leading - padding.trailing
        }
        // Unsupported properties without a matching declaration stay unknown. Parsed bytes and
        // a running bitrate estimate are not a declared finite-media duration.
        timing = Timing(sampleRate: Int32(description.mSampleRate), channels: Int(description.mChannelsPerFrame),
            encodedFrameCount: encodedFrames,
            validFrameCount: valid, primingFrameCount: priming, remainderFrameCount: remainder)
    }

    private static func isAvailableOrUnknown(_ status: OSStatus) -> Bool {
        status == noErr || status == kAudioFileStreamError_ValueUnknown || status == kAudioFileStreamError_UnsupportedProperty
    }

    private func receive(byteCount: UInt32, packetCount: UInt32, bytes: UnsafeRawPointer,
                         descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard failure == nil else { return }
        guard let format, let basic = format.audioStreamBasicDescription, let timing,
              byteCount > 0, byteCount <= 65_536, packetCount > 0,
              packetCount <= byteCount, let descriptions else {
            failure = Failure.invalidPacket; return
        }
        let packets = Array(UnsafeBufferPointer(start: descriptions, count: Int(packetCount)))
        // Each frame header says its own sample rate and channel count. The native
        // stream reports neither a mono ↔ two-channel change nor (after a restart)
        // anything earlier, so a batch takes its configuration from its frames.
        let native = MP3FrameConfiguration(basic)
        var configurations: [MP3FrameConfiguration] = []
        var frames: Int64 = 0
        for packet in packets {
            guard packet.mStartOffset >= 0, packet.mDataByteSize > 0,
                  packet.mStartOffset <= Int64(byteCount) - Int64(packet.mDataByteSize) else {
                failure = Failure.invalidPacket; return
            }
            let configuration = packet.mDataByteSize >= 4
                ? MP3FrameConfiguration(header: bytes.advanced(by: Int(packet.mStartOffset))) ?? native : native
            configurations.append(configuration)
            frames += Int64(packet.mVariableFramesInPacket == 0 ? configuration.framesPerPacket : Int64(packet.mVariableFramesInPacket))
        }
        guard !parsedFrames.addingReportingOverflow(frames).overflow else {
            failure = Failure.invalidPacket; return
        }
        // Dependency queries are valid for the packets in this callback. Keep
        // the native preroll requirement with the packet instead of guessing a
        // fixed time window (which is insufficient for lower-rate MP3 audio).
        var distances: [Int64]? = []
        if let stream {
            let first = streamPackets
            for index in 0..<Int(packetCount) {
                var dependency = AudioPacketRollDistanceTranslation(mPacket: first + Int64(index), mRollDistance: 0)
                var size = UInt32(MemoryLayout.size(ofValue: dependency))
                let status = AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_PacketToRollDistance, &size, &dependency)
                guard status == noErr, dependency.mRollDistance >= 0, dependency.mRollDistance <= dependency.mPacket else {
                    distances = nil; break
                }
                distances?.append(dependency.mRollDistance)
            }
        } else { distances = nil }
        // A restarted stream counts its dependencies from its own first packet. That is a
        // run's first frame only when the restart followed the frames up to it.
        if streamStartsMidRun { distances = distances?.map { max($0, Self.nativePreroll) } }
        streamPackets += Int64(packetCount)
        var covered: Int64 = 0
        let contiguous = packets.allSatisfy { packet in
            defer { covered = packet.mStartOffset + Int64(packet.mDataByteSize) }
            return packet.mStartOffset == covered
        } && covered == Int64(byteCount)
        var start = 0
        while start < packets.count {
            let configuration = configurations[start]
            var end = start + 1
            while end < packets.count, configurations[end] == configuration { end += 1 }
            let run = packets[start..<end]
            let count = run.reduce(Int64(0)) {
                $0 + ($1.mVariableFramesInPacket == 0 ? configuration.framesPerPacket : Int64($1.mVariableFramesInPacket))
            }
            let data: Data, described: [AudioStreamPacketDescription]
            if start == 0, end == packets.count, contiguous {
                data = Data(bytes: bytes, count: Int(byteCount)); described = packets
            } else {
                // One format's packets only; bytes AudioFileStream skipped are not audio.
                var compact = Data(), rebased: [AudioStreamPacketDescription] = []
                for packet in run {
                    var packet = packet
                    compact.append(bytes.advanced(by: Int(packet.mStartOffset)).assumingMemoryBound(to: UInt8.self),
                                   count: Int(packet.mDataByteSize))
                    packet.mStartOffset = Int64(compact.count) - Int64(packet.mDataByteSize)
                    rebased.append(packet)
                }
                data = compact; described = rebased
            }
            let batchFormat: CMAudioFormatDescription
            do { batchFormat = configuration == native ? format : try derivedFormat(configuration, from: basic) }
            catch { failure = error; return }
            let time = parsedTime ?? CMTime(value: parsedFrames, timescale: timing.sampleRate)
            if configuration.sampleRate != timing.sampleRate || configuration.channels != timing.channels { formatChanged = true }
            batches.append(Batch(bytes: data, descriptions: described, format: batchFormat, firstFrame: parsedFrames,
                frameCount: count, timing: timing, rollDistances: distances.map { Array($0[start..<end]) }, sourceTime: time,
                afterFormatChange: formatChanged))
            parsedFrames += count
            parsedTime = time + CMTime(value: count, timescale: configuration.sampleRate)
            start = end
        }
    }

    private func derivedFormat(_ configuration: MP3FrameConfiguration, from basic: AudioStreamBasicDescription) throws -> CMAudioFormatDescription {
        if let format = derivedFormats[configuration] { return format }
        var description = basic
        description.mSampleRate = Double(configuration.sampleRate)
        description.mChannelsPerFrame = UInt32(configuration.channels)
        description.mFramesPerPacket = UInt32(configuration.framesPerPacket)
        let format = try CMAudioFormatDescription(audioStreamBasicDescription: description)
        derivedFormats[configuration] = format
        return format
    }
}

/// The decoder configuration an MPEG audio layer III frame header declares. Stereo,
/// joint stereo and dual channel are all two channels; only mono differs.
struct MP3FrameConfiguration: Hashable, Sendable {
    let sampleRate: Int32
    let channels: Int
    let framesPerPacket: Int64

    init(sampleRate: Int32, channels: Int, framesPerPacket: Int64) {
        self.sampleRate = sampleRate; self.channels = channels; self.framesPerPacket = framesPerPacket
    }
    init(_ description: AudioStreamBasicDescription) {
        self.init(sampleRate: Int32(description.mSampleRate), channels: Int(description.mChannelsPerFrame),
                  framesPerPacket: Int64(description.mFramesPerPacket))
    }
    init?(header bytes: UnsafeRawPointer) {
        let word = (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(bytes.load(fromByteOffset: $1, as: UInt8.self)) }
        guard let header = MP3FrameHeader(word) else { return nil }
        self = header.configuration
    }
}

/// One MPEG audio layer III frame header (Media3 MpegAudioUtil's fields).
struct MP3FrameHeader: Sendable {
    let configuration: MP3FrameConfiguration
    let byteCount: Int

    init?(_ word: UInt32) {
        let version = (word >> 19) & 3, bitrateIndex = Int((word >> 12) & 15), rateIndex = Int((word >> 10) & 3)
        guard word & 0xffe00000 == 0xffe00000, version != 1, (word >> 17) & 3 == 1,
              (1...14).contains(bitrateIndex), rateIndex < 3 else { return nil }
        let rate = [44100, 48000, 32000][rateIndex] / (version == 3 ? 1 : version == 2 ? 2 : 4)
        let bitrates = version == 3
            ? [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
            : [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        byteCount = (version == 3 ? 144 : 72) * bitrates[bitrateIndex - 1] * 1000 / rate + Int((word >> 9) & 1)
        configuration = MP3FrameConfiguration(sampleRate: Int32(rate), channels: (word >> 6) & 3 == 3 ? 1 : 2,
            framesPerPacket: version == 3 ? 1152 : 576)
    }
}

/// Follows MPEG frame headers through bytes before they reach AudioFileStream, to find
/// where frames at another sample rate begin. Where the previous frames lead to it, a frame
/// at another rate is accepted when another header follows exactly at its end, or when it
/// ends the source; when searching (after an indexed seek or unrecognized bytes), only when
/// the next frame has its rate too, as Media3's Mp3Extractor synchronizes. ID3v2 tags are
/// skipped; free-format and unrecognized bytes are left to AudioFileStream.
struct MP3RateTracker: Sendable {
    private enum State: Sendable { case searching, skipping(Int, footer: ID3v2Header?), footer(ID3v2Header), synchronized }
    private var state = State.searching
    /// Offset in the unparsed bytes of the next header to examine.
    private var position = 0
    private var rate: Int32?
    private var pendingRate: Int32?
    /// The last change was found at the frame boundary the previous frames lead to, not by
    /// searching (after a discontinuity or unrecognized bytes).
    private(set) var changeFollowsFrames = false

    /// `safe`: leading bytes confirmed as the current rate's (or as tags and unrecognized
    /// bytes), no longer needed. `hold`: a frame at another rate starts here, not yet
    /// confirmed. `change`: where confirmed frames at another rate begin.
    mutating func scan(_ data: Data) -> (safe: Int, hold: Int?, change: Int?) {
        while true {
            switch state {
            case .skipping(let remaining, let footer):
                let available = data.count - position
                guard available >= remaining else {
                    position = data.count; state = .skipping(remaining - available, footer: footer); return (data.count, nil, nil)
                }
                position += remaining; state = footer.map { .footer($0) } ?? .searching
            case .footer(let header):
                guard position + 10 <= data.count else { return (position, nil, nil) }
                let base = data.startIndex + position
                if header.isFooter(data[base..<(base + 10)]) { position += 10 }
                state = .searching
            case .searching:
                guard position + 10 <= data.count else { return (max(0, min(position, data.count)), nil, nil) }
                let base = data.startIndex + position
                if let tag = ID3v2Header(data[base..<(base + 10)]) {
                    state = .skipping(10 + Int(tag.size), footer: tag.hasFooter ? tag : nil)
                    continue
                }
                guard let header = header(data, position) else { position += 1; continue }
                let other = rate.map { $0 != header.configuration.sampleRate } ?? false
                guard position + header.byteCount + 4 <= data.count else { return (position, other ? position : nil, nil) }
                guard let next = self.header(data, position + header.byteCount),
                      next.configuration.sampleRate == header.configuration.sampleRate,
                      next.configuration.framesPerPacket == header.configuration.framesPerPacket else { position += 1; continue }
                if other {
                    pendingRate = header.configuration.sampleRate; changeFollowsFrames = false
                    return (position, position, position)
                }
                rate = header.configuration.sampleRate
                state = .synchronized
            case .synchronized:
                guard position + 4 <= data.count else { return (min(position, data.count), nil, nil) }
                guard let header = header(data, position) else { state = .searching; continue }
                if header.configuration.sampleRate == rate { position += header.byteCount; continue }
                // Another rate exactly where the next frame begins. It is a frame when another
                // header follows exactly at its end: the start of a run at the new rate, or a
                // single frame between two runs. A last frame waits for `change(atEndOf:)`,
                // also when what follows may still be a trailing 128-byte ID3v1 tag.
                let end = position + header.byteCount
                guard end + 4 <= data.count else { return (position, position, nil) }
                guard self.header(data, end) != nil else {
                    if data.count - end <= Self.id3v1Size, data[(data.startIndex + end)...].starts(with: Self.id3v1Marker) {
                        return (position, position, nil)
                    }
                    state = .searching; continue
                }
                pendingRate = header.configuration.sampleRate; changeFollowsFrames = true
                return (position, position, position)
            }
        }
    }

    /// At the source's real end: a complete frame at another rate exactly at the frame
    /// boundary that ends the source (or precedes only an ID3v1 tag). Incomplete frames and
    /// candidates found by searching through unsynchronized bytes are not changes.
    mutating func change(atEndOf data: Data) -> Int? {
        guard case .synchronized = state, let rate, let header = header(data, position),
              header.configuration.sampleRate != rate else { return nil }
        let end = position + header.byteCount
        guard end == data.count || end + Self.id3v1Size == data.count && data[(data.startIndex + end)...].starts(with: Self.id3v1Marker) else {
            return nil
        }
        pendingRate = header.configuration.sampleRate; changeFollowsFrames = true
        return position
    }

    /// The native stream was restarted at the reported change.
    mutating func restarted() {
        rate = pendingRate; pendingRate = nil; position = 0; state = .synchronized
    }
    /// The first `count` bytes are no longer scanned.
    mutating func consumed(_ count: Int) { position -= count }
    /// Bytes no longer follow the previous ones (an indexed seek).
    mutating func resynchronize() { position = 0; pendingRate = nil; state = .searching }

    private static let id3v1Size = 128
    private static let id3v1Marker = Data("TAG".utf8)

    private func header(_ data: Data, _ offset: Int) -> MP3FrameHeader? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let base = data.startIndex + offset
        return MP3FrameHeader(UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16 | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3]))
    }
}

/// An ID3v2 tag header (as MP3XingMetadata and the type probe accept it). A v2.4 tag may
/// end with a 10-byte footer after its declared body: "3DI" and the header's other fields.
struct ID3v2Header: Sendable {
    let fields: [UInt8]
    let size: Int64
    var hasFooter: Bool { fields[0] == 4 && fields[2] & 0x10 != 0 }

    init?(_ bytes: Data) {
        guard bytes.count == 10 else { return nil }
        let b = bytes.startIndex
        guard bytes[b] == 0x49, bytes[b + 1] == 0x44, bytes[b + 2] == 0x33, (2...4).contains(bytes[b + 3]),
              bytes[b + 4] != 0xff, bytes[(b + 6)...(b + 9)].allSatisfy({ $0 < 128 }) else { return nil }
        fields = Array(bytes[(b + 3)...(b + 9)])
        size = bytes[(b + 6)...(b + 9)].reduce(Int64(0)) { ($0 << 7) | Int64($1) }
    }
    /// Exactly this tag's footer: "3DI" and the same version, revision, flags and size.
    func isFooter(_ bytes: Data) -> Bool {
        bytes.count == 10 && bytes.starts(with: [0x33, 0x44, 0x49]) && Array(bytes.dropFirst(3)) == fields
    }
}
