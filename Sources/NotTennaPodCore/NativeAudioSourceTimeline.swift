// Source metadata interpretation follows AndroidX Media3 (Apache-2.0).
// See Licenses/Android-Native-Audio-Metadata.txt.
import Foundation

/// Source duration and seeking policy, independent of Apple's decoded frame
/// count and of a cache discovering an initially unknown extent at EOF.
/// MP4 requires its own indexed-container preparation; it is not treated as an
/// unseekable elementary stream by this reader.
struct NativeAudioSourceTimeline: Equatable, Sendable {
    enum Format: Sendable {
        case wav, adts, flac, mp4
        init(_ format: PCMRemoteInput.Format) throws {
            guard case .native(let type) = format else { throw PCMRemoteInput.Failure.unidentified }
            switch type {
            case "com.microsoft.waveform-audio", "public.wav": self = .wav
            case "public.aac-audio": self = .adts
            case "org.xiph.flac": self = .flac
            case "com.apple.m4a-audio", "public.mpeg-4", "public.mpeg-4-audio": self = .mp4
            default: throw PCMRemoteInput.Failure.unsupportedFormat(type)
            }
        }
    }
    enum Failure: Error, Equatable { case invalidMetadata, incompleteMetadata, unsupportedWAV }
    let durationMicroseconds: Int64?
    let seekable: Bool
    /// Fragmented MP4 needs the common demux timeline, even if its initial movie
    /// also contains nonempty sample tables. Native packet indexes cover one movie.
    var supportsNativePacketTimeline = true
    // ADTS uses the same constant-bitrate map as the enabled MP3 CBR policy.
    private(set) var adtsByteIndex: MP3SeekIndex? = nil
    private(set) var adtsSyncFormat: UInt16? = nil
    var mp4AudioEdit: NativeMP4SourceTimeline.AudioEdit? = nil
    var mp4AudioSequence: [NativeMP4SourceTimeline.AudioEdit]? = nil
    var mp4EmptyAudioFormat: NativeMP4SourceTimeline.EmptyAudioFormat? = nil
    var mp4AudioTrim: NativeMP4SourceTimeline.AudioTrim? = nil
    var mp4UntrimmedAudio: NativeMP4SourceTimeline.AudioEdit? = nil
    private(set) var flacByteIndex: NativeFLACSeekIndex? = nil

    func preparingStartupTrim(_ enabled: Bool) throws -> (timeline: Self, trim: NativeMP4SourceTimeline.AudioTrim?) {
        var result = self
        let trim = enabled ? mp4AudioTrim : nil
        if trim != nil {
            if mp4AudioEdit != nil || mp4AudioSequence != nil {
                // Existing source windows already expose raw AAC units. Each
                // buffer carries its unedited coordinate through presentation.
                return (result, trim)
            }
            guard let raw = mp4UntrimmedAudio else {
                throw NativePCMDecoder.Failure.invalidFormat
            }
            result.mp4AudioEdit = raw
        }
        return (result, trim)
    }

    /// The caller supplies a disposable read lease. Only that lease is retired;
    /// a retained playback owner remains responsible for the encoded source.
    static func read(input: any MediaByteInput, format: Format) async throws -> Self {
        if case .mp4 = format { return try await NativeMP4SourceTimeline.read(input: input) }
        let reader = Reader(input: input)
        return try await withTaskCancellationHandler {
            defer { input.cancel() }
            let result = try await reader.read(format)
            try Task.checkCancellation()
            return result
        } onCancel: { input.cancel() }
    }

    private actor Reader {
        nonisolated private let executor = BlockingReadExecutor()
        nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
        let input: any MediaByteInput
        private var position: Int64 = 0
        init(input: any MediaByteInput) { self.input = input }

        func read(_ format: Format) throws -> NativeAudioSourceTimeline {
            switch format {
            case .wav: return try wav()
            case .adts: return try adts()
            case .flac: return try flac()
            case .mp4: preconditionFailure("MP4 uses its indexed metadata reader")
            }
        }

        // Each read/allocation is at most 4 KiB, including skipped pictures,
        // padding and ID3 bodies. Blocking input never occupies a cooperative
        // executor. No complete encoded file or decoded audio is retained here.
        private func bytes(_ count: Int, allowShort: Bool = false) throws -> Data {
            guard (0...4096).contains(count) else { throw Failure.invalidMetadata }
            var result = Data()
            while result.count < count {
                try Task.checkCancellation()
                try input.checkFailure()
                let part = try input.read(at: position, maximumCount: count - result.count)
                guard part.count <= count - result.count,
                      position <= Int64.max - Int64(part.count) else { throw Failure.invalidMetadata }
                if part.isEmpty {
                    guard allowShort else { throw Failure.incompleteMetadata }
                    break
                }
                position += Int64(part.count)
                result.append(part)
            }
            return result
        }
        private func skip(_ count: Int64, allowShort: Bool = false) throws -> Bool {
            guard count >= 0, position <= Int64.max - count else { throw Failure.invalidMetadata }
            var remaining = count
            while remaining > 0 {
                let size = Int(min(4096, remaining))
                let chunk = try bytes(size, allowShort: allowShort)
                remaining -= Int64(chunk.count)
                if chunk.count != size { return false }
            }
            return true
        }
        private func duration(frames: Int64, rate: Int64) throws -> Int64 {
            guard frames >= 0, rate > 0,
                  let value = Int64(exactly: Int128(frames) * 1_000_000 / Int128(rate)) else {
                throw Failure.invalidMetadata
            }
            return value
        }

        private func wav() throws -> NativeAudioSourceTimeline {
            let header = try bytes(12)
            guard (header.prefix(4) == Data("RIFF".utf8) || header.prefix(4) == Data("RF64".utf8)),
                  header.suffix(4) == Data("WAVE".utf8) else { throw Failure.invalidMetadata }
            let extent = input.initialDeclaredLength
            var sampleRate: Int64?, blockSize: Int64?, framesPerBlock: Int64 = 1, rf64Size: Int64?
            var nativePacketEncoding = true
            while true {
                let chunk = try bytes(8), size = Int64(Self.little(chunk, 4, 4))
                let type = chunk.prefix(4)
                if type == Data("fmt ".utf8) {
                    guard sampleRate == nil, size >= 16 else { throw Failure.invalidMetadata }
                    let format = try bytes(Int(min(size, 20)))
                    let encoding = Self.little(format, 0, 2), channels = Int64(Self.little(format, 2, 2))
                    let rate = Int64(Self.little(format, 4, 4)), block = Int64(Self.little(format, 12, 2))
                    let bits = Int64(Self.little(format, 14, 2))
                    guard rate > 0, channels > 0, block > 0 else { throw Failure.invalidMetadata }
                    if encoding == 17 { // IMA ADPCM: source block, not a decoded PCM frame.
                        guard size >= 20, bits == 4, block >= channels * 4 else { throw Failure.invalidMetadata }
                        framesPerBlock = Int64(Self.little(format, 18, 2))
                        guard framesPerBlock == (block - channels * 4) * 2 / channels + 1 else {
                            throw Failure.invalidMetadata
                        }
                    } else {
                        guard encoding == 1 || encoding == 3 || encoding == 6 || encoding == 7 || encoding == 65534 else {
                            throw Failure.unsupportedWAV
                        }
                        guard bits > 0, bits % 8 == 0, block == channels * bits / 8 else { throw Failure.invalidMetadata }
                    }
                    // Apple's compressed-buffer API explicitly excludes G.711.
                    // Keep its metadata, but select the common decoder for these WAVs.
                    nativePacketEncoding = encoding != 6 && encoding != 7
                    sampleRate = rate; blockSize = block
                    _ = try skip(size - Int64(format.count))
                } else if type == Data("ds64".utf8), header.prefix(4) == Data("RF64".utf8) {
                    guard size >= 28 else { throw Failure.invalidMetadata }
                    let values = try bytes(28)
                    guard let parsed = Int64(exactly: Self.little(values, 8, 8)) else { throw Failure.invalidMetadata }
                    rf64Size = parsed
                    _ = try skip(size - 28)
                } else if type == Data("data".utf8) {
                    guard let sampleRate, let blockSize else { throw Failure.invalidMetadata }
                    let dataSize = size == 0xffff_ffff ? rf64Size ?? size : size
                    let end = position.addingReportingOverflow(dataSize)
                    guard !end.overflow else { throw Failure.invalidMetadata }
                    let availableEnd = extent.map { min($0, end.partialValue) } ?? end.partialValue
                    guard availableEnd >= position else { throw Failure.invalidMetadata }
                    let frames = Int128((availableEnd - position) / blockSize) * Int128(framesPerBlock)
                    guard let count = Int64(exactly: frames) else { throw Failure.invalidMetadata }
                    return try NativeAudioSourceTimeline(durationMicroseconds: duration(frames: count, rate: sampleRate), seekable: true,
                        supportsNativePacketTimeline: framesPerBlock == 1 && nativePacketEncoding)
                } else { _ = try skip(size) }
                // RIFF chunks are word aligned; padding is outside the size.
                if size & 1 != 0 { _ = try skip(1) }
            }
        }

        private func flac() throws -> NativeAudioSourceTimeline {
            guard try bytes(4) == Data("fLaC".utf8) else { throw Failure.invalidMetadata }
            let extent = input.initialDeclaredLength
            var sampleRate: Int64?, samples: Int64 = 0, hasSeekPoint = false
            var streamInfo: Data?, seekPoints: [NativeFLACSeekIndex.SeekPoint] = []
            while true {
                let header = try bytes(4)
                let type = header[0] & 127, size = Int64(Self.big(header, 1, 3))
                if type == 0 {
                    guard sampleRate == nil, size == 34 else { throw Failure.invalidMetadata }
                    let info = try bytes(34), packed = Self.big(info, 10, 8)
                    let rate = Int64(packed >> 44)
                    guard rate > 0 else { throw Failure.invalidMetadata }
                    sampleRate = rate; samples = Int64(packed & 0x0f_ffff_ffff); streamInfo = info
                } else {
                    guard sampleRate != nil else { throw Failure.invalidMetadata }
                    if type == 3, size >= 18 {
                        var remaining = size, endedPoints = false
                        while remaining >= 18 {
                            let entry = try bytes(18); remaining -= 18
                            let sample = Self.big(entry, 0, 8)
                            if sample == UInt64.max { endedPoints = true }
                            if !endedPoints {
                                guard let count = Int64(exactly: sample), let offset = Int64(exactly: Self.big(entry, 8, 8)) else {
                                    throw Failure.invalidMetadata
                                }
                                seekPoints.append(.init(sample: count, offset: offset))
                            }
                        }
                        hasSeekPoint = !seekPoints.isEmpty
                        _ = try skip(remaining)
                    } else { _ = try skip(size) }
                }
                if header[0] & 128 != 0 { break }
            }
            guard let sampleRate else { throw Failure.invalidMetadata }
            var result = try NativeAudioSourceTimeline(durationMicroseconds: samples == 0 ? nil : duration(frames: samples, rate: sampleRate),
                seekable: hasSeekPoint || (extent != nil && samples > 0))
            if result.seekable, let streamInfo {
                result.flacByteIndex = try NativeFLACSeekIndex(info: streamInfo, firstAudioByte: position,
                    declaredLength: extent, seekPoints: seekPoints)
            }
            return result
        }

        private func adts() throws -> NativeAudioSourceTimeline {
            // Read enough to establish the initial HTTP headers before choosing
            // the finite-only CBR policy. A later EOF-derived length is ignored.
            var first = try bytes(6)
            let extent = input.initialDeclaredLength
            guard let extent else { return NativeAudioSourceTimeline(durationMicroseconds: nil, seekable: false) }
            while first.prefix(3) == Data("ID3".utf8) {
                let size = try bytes(4)
                guard size.allSatisfy({ $0 < 128 }) else { throw Failure.invalidMetadata }
                let count = size.reduce(Int64(0)) { ($0 << 7) | Int64($1) }
                _ = try skip(count)
                first = try bytes(6)
            }
            let start = position - 6
            var frames: Int64 = 0, total: Int64 = 0, rate: Int64?
            var header = first
            while header.count == 6 {
                guard (Self.big(header, 0, 2) & 0xfff6) == 0xfff0 else {
                    return NativeAudioSourceTimeline(durationMicroseconds: nil, seekable: false)
                }
                let size = Int64(header[3] & 3) << 11 | Int64(header[4]) << 3 | Int64(header[5] >> 5)
                guard size > 6 else { throw Failure.invalidMetadata }
                if rate == nil {
                    let rates: [Int64] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
                    let index = Int(header[2] >> 2 & 15)
                    guard rates.indices.contains(index) else { throw Failure.invalidMetadata }
                    rate = rates[index]
                }
                frames += 1; total += size
                // Include a terminal partial frame in the average, matching the
                // original peek algorithm. This is not decoded-audio validation.
                if frames == 1000 { break }
                if try !skip(size - 6, allowShort: true) { break }
                header = try bytes(6, allowShort: true)
                if header.count >= 2, (Self.big(header, 0, 2) & 0xfff6) != 0xfff0 {
                    return NativeAudioSourceTimeline(durationMicroseconds: nil, seekable: false)
                }
            }
            guard frames > 0, let rate, extent >= start else { throw Failure.invalidMetadata }
            let frameDuration = 1_024_000_000 / rate
            let bitrate = (total / frames) * 8_000_000 / frameDuration
            guard bitrate > 0, let duration = Int64(exactly: Int128(extent - start) * 8_000_000 / Int128(bitrate)) else {
                throw Failure.invalidMetadata
            }
            guard bitrate <= Int32.max, let average = Int(exactly: total / frames), average > 0 else {
                throw Failure.invalidMetadata
            }
            var result = NativeAudioSourceTimeline(durationMicroseconds: duration, seekable: true)
            result.adtsByteIndex = .constant(start: start, end: extent, bitrate: Int32(bitrate), frameSize: average)
            result.adtsSyncFormat = UInt16(first[1] & 8) << 8 | UInt16(first[2] & 0x3c)
            return result
        }

        private static func big(_ data: Data, _ offset: Int, _ size: Int) -> UInt64 {
            data[offset..<(offset + size)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        private static func little(_ data: Data, _ offset: Int, _ size: Int) -> UInt64 {
            data[offset..<(offset + size)].reversed().reduce(0) { ($0 << 8) | UInt64($1) }
        }
    }
}
