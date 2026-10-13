// Source timing rules follow AndroidX Media3 (Apache-2.0).
// See Licenses/Android-Native-Audio-Metadata.txt.
import Foundation

/// Reads the movie's source timeline without substituting decoded PCM length.
/// The supplied lease is disposable; the playback item retains its byte owner.
enum NativeMP4SourceTimeline {
    enum Failure: Error, Equatable { case invalidMetadata, incompleteMetadata }
    static func read(input: any MediaByteInput) async throws -> NativeAudioSourceTimeline {
        let reader = Reader(input: input)
        return try await withTaskCancellationHandler {
            defer { input.cancel() }
            let result = try await reader.read()
            try Task.checkCancellation()
            return result
        } onCancel: { input.cancel() }
    }

    /// A single contiguous, synchronous AAC edit. Packet ordinals remain raw
    /// file ordinals; only source playback applies this window and time offset.
    struct AudioEdit: Equatable, Sendable {
        let packets: Range<Int64>
        let packetDuration: Int64
        let mediaScale: Int64
        let mediaStart: Int64
        var outputStartMicroseconds: Int64 = 0
        var outputPacketOffset: Int64 = 0
        func time(at packet: Int64) throws -> Int64 {
            let relative = (Int128(packet) * Int128(packetDuration) - Int128(mediaStart)) * 1_000_000 / Int128(mediaScale)
            guard let value = Int64(exactly: Int128(outputStartMicroseconds) + relative) else { throw Failure.invalidMetadata }
            return value
        }
    }
    private struct AudioEdits {
        let segments: [AudioEdit]
        let sequence: Bool
        var emptyFormat: EmptyAudioFormat? = nil
        var trim: AudioTrim? = nil
    }
    /// The sample entry's nominal geometry is used only by the empty processing
    /// endpoint. There is no selected audio track, converter or decoded PCM.
    struct EmptyAudioFormat: Equatable, Sendable {
        let sampleRate: Int
        let channels: Int
    }
    /// Edit values use the media timescale. iTunSMPB values are decoded frames.
    /// Keep the units explicit until the processing format has been selected.
    struct AudioTrim: Equatable, Sendable {
        let delay: Int64
        let padding: Int64
        let unitsPerSecond: Int64?
    }

    private struct Box { let type: String; let payload: Int64; let end: Int64 }
    private actor Reader {
        nonisolated private let executor = BlockingReadExecutor()
        nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
        let input: any MediaByteInput
        init(input: any MediaByteInput) { self.input = input }

        func read() throws -> NativeAudioSourceTimeline {
            var offset: Int64 = 0
            while let box = try box(at: offset, end: input.length, allowEOF: true) {
                if box.type == "moov" { return try movie(box) }
                if box.type == "moof" { throw Failure.invalidMetadata }
                try advance(from: box.payload, to: box.end)
                offset = box.end
            }
            throw Failure.incompleteMetadata
        }

        private func movie(_ movie: Box) throws -> NativeAudioSourceTimeline {
            let children = try children(movie)
            if children.contains(where: { $0.type == "mvex" }) {
                return NativeAudioSourceTimeline(durationMicroseconds: nil, seekable: false,
                    supportsNativePacketTimeline: false)
            }
            let header = try required("mvhd", children)
            let movieScale = try timescale(header)
            // Native AudioFile selects the audio track. Until explicit track
            // identity is shared, do not attach one track's edits to another.
            var audioTracks = [Box]()
            for track in children where track.type == "trak" {
                let mdia = try self.children(required("mdia", self.children(track)))
                if try bytes(required("hdlr", mdia), offset: 8, count: 4) == Data("soun".utf8) { audioTracks.append(track) }
            }
            let edits = try audioTracks.count == 1 ? audioEdits(audioTracks[0], movieScale: movieScale) : nil
            let taggedTrim = try audioTracks.count == 1 ? gaplessMetadata(children) : nil
            let trim = edits?.emptyFormat == nil ? edits?.trim ?? taggedTrim : nil
            let untrimmed = try trim != nil && edits?.segments.isEmpty != false && edits?.sequence != true
                ? untrimmedAudio(audioTracks[0]) : nil
            let tracks = children.filter { $0.type == "trak" }
            var duration: Int64?
            for track in tracks {
                // Mp4Extractor omits an emptied sample table before it adds the
                // track duration. Other tracks still contribute independently.
                if edits?.emptyFormat != nil, track.payload == audioTracks.first?.payload { continue }
                if let value = try trackDuration(track, movieScale: movieScale) {
                    duration = max(duration ?? value, value)
                }
            }
            return NativeAudioSourceTimeline(durationMicroseconds: duration, seekable: true,
                mp4AudioEdit: edits?.sequence == false ? edits?.segments.first : nil,
                mp4AudioSequence: edits?.sequence == true && edits?.emptyFormat == nil ? edits?.segments : nil,
                mp4EmptyAudioFormat: tracks.count == 1 ? edits?.emptyFormat : nil,
                mp4AudioTrim: trim, mp4UntrimmedAudio: untrimmed)
        }

        /// Complete physical AAC access units, including a shortened final stts
        /// sample. Processing owns trim; the converter still has an exact end
        /// count so an incomplete source cannot silently become normal EOF.
        private func untrimmedAudio(_ track: Box) throws -> AudioEdit? {
            let mdia = try children(required("mdia", children(track)))
            let stbl = try children(required("stbl", children(required("minf", mdia))))
            guard !stbl.contains(where: { $0.type == "ctts" || $0.type == "stss" }) else { return nil }
            let description = try required("stsd", stbl)
            guard try uint(description, offset: 4, count: 4) == 1,
                  try box(at: description.payload + 8, end: description.end)?.type == "mp4a" else { return nil }
            let sizes = try stbl.first(where: { $0.type == "stsz" || $0.type == "stz2" }).unwrap()
            let count = try uint(sizes, offset: 8, count: 4)
            let scale = try timescale(required("mdhd", mdia))
            guard count > 0, scale <= Int32.max else { return nil }
            let timing = try required("stts", stbl), runs = try tableCount(timing, entrySize: 8)
            guard (1...2).contains(runs) else { return nil }
            let first = try bytes(timing, offset: 8, count: 8)
            var samples = Int64(big(first.prefix(4)))
            let delta = Int64(big(first.suffix(4)))
            guard samples > 0, delta > 0 else { throw Failure.invalidMetadata }
            if runs == 2 {
                let last = try bytes(timing, offset: 16, count: 8)
                let lastDelta = Int64(big(last.suffix(4)))
                guard big(last.prefix(4)) == 1, lastDelta > 0, lastDelta <= delta else { return nil }
                samples += 1
            }
            guard UInt64(samples) == count else { throw Failure.invalidMetadata }
            return AudioEdit(packets: 0..<samples, packetDuration: delta, mediaScale: scale, mediaStart: 0)
        }

        private func audioEdits(_ track: Box, movieScale: Int64) throws -> AudioEdits? {
            let trak = try children(track), mdia = try children(required("mdia", trak))
            let stbl = try children(required("stbl", children(required("minf", mdia))))
            guard let edts = trak.first(where: { $0.type == "edts" }),
                  let elst = try children(edts).first(where: { $0.type == "elst" }),
                  !stbl.contains(where: { $0.type == "ctts" || $0.type == "stss" }) else { return nil }
            let sizes = try stbl.first(where: { $0.type == "stsz" || $0.type == "stz2" }).unwrap()
            let sampleCount = try uint(sizes, offset: 8, count: 4)
            guard sampleCount > 0 else { return nil }
            let description = try required("stsd", stbl)
            guard try uint(description, offset: 4, count: 4) == 1,
                  try box(at: description.payload + 8, end: description.end)?.type == "mp4a" else { return nil }
            let version = try version(elst), width = version == 0 ? 4 : 8
            let count = try tableCount(elst, entrySize: width * 2 + 4)
            guard count > 0 else { return nil }
            let scale = try timescale(required("mdhd", mdia))
            guard scale <= Int32.max else { return nil }
            var entries: [(duration: UInt64, start: Int64, time: Int64)] = []
            var moviePosition: Int128 = 0
            for i in 0..<count {
                let edit = try bytes(elst, offset: 8 + Int64(i) * Int64(width * 2 + 4), count: width * 2 + 4)
                guard big(edit[(width * 2)..<(width * 2 + 4)]) == 0x00010000 else { return nil }
                let bits = big(edit[width..<(width * 2)])
                let start = version == 0 ? Int64(Int32(bitPattern: UInt32(bits))) : Int64(bitPattern: bits)
                guard start >= -1 else { throw Failure.invalidMetadata }
                let duration = big(edit.prefix(width))
                entries.append((duration, start, try scaled(moviePosition, by: movieScale)))
                moviePosition += Int128(duration)
            }
            let start = entries[0].start, editDuration = entries[0].duration
            let end = Int128(start) + Int128(editDuration) * Int128(scale) / Int128(movieScale)
            let timing = try required("stts", stbl), runs = try tableCount(timing, entrySize: 8)
            // Constant AAC packet timing with an optional shortened final
            // container sample. The final codec packet still decodes in full.
            guard (1...2).contains(runs) else { return nil }
            let first = try bytes(timing, offset: 8, count: 8)
            var samples = Int64(big(first.prefix(4)))
            let delta = Int64(big(first.suffix(4)))
            guard samples > 0, delta > 0 else { throw Failure.invalidMetadata }
            var duration = Int128(samples) * Int128(delta)
            if runs == 2 {
                let last = try bytes(timing, offset: 16, count: 8)
                let lastDelta = Int64(big(last.suffix(4)))
                guard big(last.prefix(4)) == 1, lastDelta > 0, lastDelta <= delta else { return nil }
                samples += 1; duration += Int128(lastDelta)
            }
            guard sampleCount == UInt64(samples) else { throw Failure.invalidMetadata }
            if count > 1 {
                var segments: [AudioEdit] = [], outputOffset: Int64 = 0
                for entry in entries where entry.start >= 0 {
                    let end = Int128(entry.start) + Int128(entry.duration) * Int128(scale) / Int128(movieScale)
                    let first = min(entry.start / delta, samples - 1)
                    let last = Int64(min(Int128(samples), (end + Int128(delta) - 1) / Int128(delta)))
                    guard last >= first, outputOffset <= Int64.max - (last - first) else { throw Failure.invalidMetadata }
                    if first < last {
                        segments.append(AudioEdit(packets: first..<last, packetDuration: delta, mediaScale: scale,
                            mediaStart: entry.start, outputStartMicroseconds: entry.time, outputPacketOffset: outputOffset))
                        outputOffset += last - first
                    }
                }
                if segments.isEmpty { return try emptyAudioEdits(description) }
                return AudioEdits(segments: segments, sequence: true)
            }
            // The source's special single zero-duration edit includes all
            // samples. A positive-duration empty edit selects none.
            if start == -1, editDuration > 0 { return try emptyAudioEdits(description) }
            guard start >= 0 else { return nil }
            // A qualifying edit supersedes a metadata tag, retains every packet
            // and delegates partial trimming to processing. Keep media units;
            // the decoded HE rate may differ from the source's core format.
            if samples >= 2, Int128(start) < Int128(min(4, samples - 1)) * Int128(delta),
               Int128(max(0, samples - 4)) * Int128(delta) < end, end <= duration + 2,
               start != 0 || end < duration {
                guard let padding = Int64(exactly: max(0, duration - end)) else { throw Failure.invalidMetadata }
                return AudioEdits(segments: [], sequence: false,
                    trim: AudioTrim(delay: start, padding: padding, unitsPerSecond: scale))
            }
            if editDuration == 0 {
                guard start != 0 else { return nil }
                return AudioEdits(segments: [AudioEdit(packets: 0..<samples, packetDuration: delta, mediaScale: scale, mediaStart: start)], sequence: false)
            }
            let firstPacket = min(start / delta, samples - 1)
            let endPacket = Int64(min(Int128(samples), (end + Int128(delta) - 1) / Int128(delta)))
            guard endPacket >= firstPacket else { throw Failure.invalidMetadata }
            // An edit that retains every packet at its original timestamp is
            // an identity operation. Preserve the existing native path and its
            // exact rational clock instead of introducing a new source policy.
            guard start != 0 || firstPacket != 0 || endPacket != samples else { return nil }
            return AudioEdits(segments: [AudioEdit(packets: firstPacket..<endPacket, packetDuration: delta, mediaScale: scale, mediaStart: start)], sequence: false)
        }

        private func emptyAudioEdits(_ description: Box) throws -> AudioEdits? {
            let entry = try box(at: description.payload + 8, end: description.end).unwrap()
            // Standard AudioSampleEntry geometry. QuickTime version 2 uses a
            // different layout and remains outside this scoped source policy.
            guard try uint(entry, offset: 8, count: 2) <= 1 else { return nil }
            let channels = try uint(entry, offset: 16, count: 2)
            let fixedRate = try uint(entry, offset: 24, count: 4)
            guard (1...32).contains(channels), fixedRate & 0xffff == 0, fixedRate >> 16 > 0 else {
                throw Failure.invalidMetadata
            }
            return AudioEdits(segments: [], sequence: true,
                emptyFormat: EmptyAudioFormat(sampleRate: Int(fixedRate >> 16), channels: Int(channels)))
        }

        private func gaplessMetadata(_ movie: [Box]) throws -> AudioTrim? {
            guard let udta = movie.first(where: { $0.type == "udta" }) else { return nil }
            for meta in try children(udta) where meta.type == "meta" {
                // ISO meta has full-box flags; QuickTime may omit them.
                let childOffset: Int64 = try uint(meta, offset: 4, count: 4) == 0x68646c72 ? 0 : 4
                let contents = try children(Box(type: meta.type, payload: meta.payload + childOffset, end: meta.end))
                guard let list = contents.first(where: { $0.type == "ilst" }) else { continue }
                for item in try children(list) where item.type == "----" {
                    let fields = try children(item)
                    guard let domain = fields.last(where: { $0.type == "mean" }),
                          let name = fields.last(where: { $0.type == "name" }),
                          let value = fields.last(where: { $0.type == "data" }),
                          try matchesString(domain, offset: 4, value: "com.apple.iTunes"),
                          try matchesString(name, offset: 4, value: "iTunSMPB"),
                          value.end - value.payload >= 35 else { continue }
                    // Only the fixed prefix is meaningful; large comment bodies
                    // need neither allocation nor full reads to establish trim.
                    let text = try bytes(value, offset: 8, count: 27)
                    guard text[0] == 32, text[9] == 32, text[18] == 32,
                          hex(text[1..<9]) != nil,
                          let delay = hex(text[10..<18]), let padding = hex(text[19..<27]),
                          delay <= Int32.max, padding <= Int32.max,
                          delay > 0 || padding > 0 else { continue }
                    return AudioTrim(delay: delay, padding: padding, unitsPerSecond: nil)
                }
            }
            return nil
        }

        private func matchesString(_ box: Box, offset: Int64, value: String) throws -> Bool {
            let expected = Data(value.utf8), available = box.end - box.payload - offset
            guard available >= expected.count else { return false }
            let data = try bytes(box, offset: offset, count: Int(min(available, Int64(expected.count + 1))))
            return data.prefix(expected.count) == expected && (data.count == expected.count || data.last == 0)
        }

        private func hex(_ bytes: Data) -> Int64? {
            var value: Int64 = 0
            for byte in bytes {
                let digit: UInt8
                switch byte {
                case 48...57: digit = byte - 48
                case 65...70: digit = byte - 55
                case 97...102: digit = byte - 87
                default: return nil
                }
                value = value * 16 + Int64(digit)
            }
            return value
        }

        private func trackDuration(_ track: Box, movieScale: Int64) throws -> Int64? {
            let trak = try children(track), mdia = try children(required("mdia", trak))
            let handler = try bytes(required("hdlr", mdia), offset: 8, count: 4)
            let type = String(decoding: handler, as: UTF8.self)
            guard ["soun", "vide", "text", "sbtl", "subt", "clcp", "subp", "meta"].contains(type) else { return nil }
            let minf = try children(required("minf", mdia)), stbl = try children(required("stbl", minf))
            guard let stsd = stbl.first(where: { $0.type == "stsd" }) else { return nil }
            // Decoder configuration remains the native decoder's responsibility.
            // Unknown sample-entry types must not silently acquire a timeline.
            guard try recognizesDescription(stsd) else { return nil }
            let sizes = try stbl.first(where: { $0.type == "stsz" || $0.type == "stz2" }).unwrap()
            let sampleCount = try uint(sizes, offset: 8, count: 4)
            guard sampleCount > 0 else { return nil }
            let tkhd = try required("tkhd", trak), trackVersion = try version(tkhd)
            let rawDuration = try uint(tkhd, offset: trackVersion == 0 ? 20 : 28, count: trackVersion == 0 ? 4 : 8)
            if rawDuration != 0 && rawDuration != (trackVersion == 0 ? UInt64(UInt32.max) : UInt64.max) {
                return try scaled(Int128(rawDuration), by: movieScale)
            }
            let mediaScale = try timescale(required("mdhd", mdia))
            let timing = try required("stts", stbl)
            let count = try tableCount(timing, entrySize: 8)
            var samples: UInt64 = 0, units: Int128 = 0
            for i in 0..<count {
                let entry = try bytes(timing, offset: 8 + Int64(i) * 8, count: 8)
                let n = big(entry.prefix(4)), delta = big(entry.suffix(4))
                guard n <= sampleCount - samples else { throw Failure.invalidMetadata }
                samples += n; units += Int128(n) * Int128(delta)
            }
            guard samples == sampleCount else { throw Failure.invalidMetadata }
            if let ctts = stbl.first(where: { $0.type == "ctts" }) {
                let count = try tableCount(ctts, entrySize: 8)
                var covered: UInt64 = 0, last: Int32 = 0
                for i in 0..<count {
                    let entry = try bytes(ctts, offset: 8 + Int64(i) * 8, count: 8)
                    let n = big(entry.prefix(4))
                    guard n <= sampleCount - covered else { throw Failure.invalidMetadata }
                    covered += n
                    if n > 0 { last = Int32(bitPattern: UInt32(big(entry.suffix(4)))) }
                }
                guard covered == sampleCount else { throw Failure.invalidMetadata }
                units += Int128(last)
            }
            if let edts = trak.first(where: { $0.type == "edts" }),
               let elst = try children(edts).first(where: { $0.type == "elst" }) {
                let version = try version(elst), size = version == 0 ? 12 : 20
                let count = try tableCount(elst, entrySize: size)
                var edited: Int128 = 0, start: Int128 = 0
                for i in 0..<count {
                    let entry = try bytes(elst, offset: 8 + Int64(i) * Int64(size), count: size)
                    let width = version == 0 ? 4 : 8
                    edited += Int128(big(entry.prefix(width)))
                    let media = big(entry[width..<(2 * width)])
                    start = version == 0 ? Int128(Int32(bitPattern: UInt32(media))) : Int128(Int64(bitPattern: media))
                    guard big(entry[(2 * width)..<(2 * width + 2)]) == 1 else { throw Failure.invalidMetadata }
                }
                if count == 1 && edited == 0 { return try scaled(units - start, by: mediaScale) }
                return try scaled(edited, by: movieScale)
            }
            return try scaled(units, by: mediaScale)
        }

        private func recognizesDescription(_ box: Box) throws -> Bool {
            let count = try uint(box, offset: 4, count: 4)
            guard count > 0 else { return false }
            let supported: Set<String> = ["mp4a", "alac", "fLaC", "Opus", "ac-3", "ec-3", "ac-4", "mlpa", "dtsc", "dtse", "dtsh", "dtsl", "dtsx", "samr", "sawb", "lpcm", "sowt", "twos", ".mp2", ".mp3", "mha1", "mhm1", "alaw", "ulaw", "ipcm", "fpcm", "avc1", "avc3", "hvc1", "hev1", "mp4v", "vp08", "vp09", "av01", "tx3g", "wvtt", "stpp", "c608", "enca", "encv", "m1v ", "vvc1", "vvi1", "s263", "H263", "h263", "dvav", "dva1", "dvhe", "dvh1", "apv1", "dav1", "iamf", "TTML", "mett", "camm"]
            var offset = box.payload + 8, found = false
            for _ in 0..<count {
                guard let entry = try self.box(at: offset, end: box.end) else { throw Failure.incompleteMetadata }
                found = found || supported.contains(entry.type)
                offset = entry.end
            }
            return found
        }
        private func tableCount(_ box: Box, entrySize: Int) throws -> Int {
            let count = try uint(box, offset: 4, count: 4)
            guard Int128(count) * Int128(entrySize) <= Int128(box.end - box.payload - 8) else { throw Failure.incompleteMetadata }
            return Int(count)
        }
        private func timescale(_ box: Box) throws -> Int64 {
            let version = try version(box)
            let scale = try uint(box, offset: version == 0 ? 12 : 20, count: 4)
            guard scale > 0 else { throw Failure.invalidMetadata }
            return Int64(scale)
        }
        private func version(_ box: Box) throws -> Int {
            let version = try uint(box, offset: 0, count: 1)
            guard version <= 1 else { throw Failure.invalidMetadata }
            return Int(version)
        }
        private func scaled(_ value: Int128, by timescale: Int64) throws -> Int64 {
            guard value >= 0, let result = Int64(exactly: value * 1_000_000 / Int128(timescale)) else { throw Failure.invalidMetadata }
            return result
        }
        private func required(_ type: String, _ boxes: [Box]) throws -> Box {
            try boxes.first(where: { $0.type == type }).unwrap()
        }
        private func children(_ parent: Box) throws -> [Box] {
            var result: [Box] = [], offset = parent.payload
            while offset < parent.end {
                guard let box = try box(at: offset, end: parent.end) else { throw Failure.incompleteMetadata }
                result.append(box); offset = box.end
            }
            return result
        }
        private func box(at offset: Int64, end: Int64?, allowEOF: Bool = false) throws -> Box? {
            if let end, offset == end { return nil }
            if let end, offset > end - 8 { throw Failure.incompleteMetadata }
            let header = try read(at: offset, count: 8, allowEOF: allowEOF)
            if header.isEmpty { return nil }
            let type = String(decoding: header.suffix(4), as: UTF8.self)
            var size = big(header.prefix(4)), headerSize: Int64 = 8
            if size == 1 { size = try big(read(at: offset + 8, count: 8)); headerSize = 16 }
            else if size == 0, let end = end ?? input.length { size = UInt64(end - offset) }
            guard size >= UInt64(headerSize), let size = Int64(exactly: size), offset <= Int64.max - size,
                  end.map({ offset + size <= $0 }) ?? true else { throw Failure.invalidMetadata }
            return Box(type: type, payload: offset + headerSize, end: offset + size)
        }
        private func advance(from start: Int64, to end: Int64) throws {
            if end - start >= 256 * 1024 { input.prepareForIndexedSeek(to: end); return }
            var offset = start
            while offset < end {
                let count = Int(min(4096, end - offset))
                _ = try read(at: offset, count: count); offset += Int64(count)
            }
        }
        private func uint(_ box: Box, offset: Int64, count: Int) throws -> UInt64 {
            try big(bytes(box, offset: offset, count: count))
        }
        private func bytes(_ box: Box, offset: Int64, count: Int) throws -> Data {
            guard offset >= 0, offset <= box.end - box.payload - Int64(count) else { throw Failure.incompleteMetadata }
            return try read(at: box.payload + offset, count: count)
        }
        private func read(at offset: Int64, count: Int, allowEOF: Bool = false) throws -> Data {
            guard (0...4096).contains(count), offset >= 0, offset <= Int64.max - Int64(count) else { throw Failure.invalidMetadata }
            var result = Data()
            while result.count < count {
                try Task.checkCancellation(); try input.checkFailure()
                let part = try input.read(at: offset + Int64(result.count), maximumCount: count - result.count)
                guard part.count <= count - result.count else { throw Failure.invalidMetadata }
                if part.isEmpty {
                    if result.isEmpty && allowEOF { return result }
                    throw Failure.incompleteMetadata
                }
                result.append(part)
            }
            return result
        }
        private func big(_ bytes: Data) -> UInt64 { bytes.reduce(0) { ($0 << 8) | UInt64($1) } }
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let value = self else { throw NativeMP4SourceTimeline.Failure.incompleteMetadata }
        return value
    }
}
