import Foundation

/// Declared container metadata, independent of indexes learned while decoding.
/// Run on the byte source's I/O executor; reads and cancellation remain caller-owned.
struct MatroskaTimeline: Equatable, Sendable {
    struct Cue: Equatable, Sendable {
        let timeMicroseconds: Int64
        let clusterOffset: Int64
        let relativeOffset: Int64?
    }
    let durationMicroseconds: Int64?
    let primaryTrack: Int64?
    let cues: [Int64: [Cue]]
    let declaredCueOffset: Int64?
    var isSeekable: Bool { durationMicroseconds != nil && primaryTrack.map { cues[$0]?.isEmpty == false } == true }

    struct SeekPoint: Equatable, Sendable {
        let timeMicroseconds: Int64
        let clusterOffset: Int64
        static let start = SeekPoint(timeMicroseconds: 0, clusterOffset: 0)
    }

    /// ProgressiveMediaPeriod uses the default ChunkIndex, not the track-aware
    /// overload. That index removes trailing cues at/after duration, retaining
    /// at least the first, and selects the first exact-time duplicate.
    func defaultSeekPoints(at target: Int64) -> (first: SeekPoint, second: SeekPoint) {
        guard let durationMicroseconds, let primaryTrack,
              let track = cues[primaryTrack], !track.isEmpty else { return (.start, .start) }
        var last = track.count - 1
        while last > 0 && track[last].timeMicroseconds >= durationMicroseconds { last -= 1 }
        var low = 0, high = last + 1
        while low < high {
            let middle = low + (high - low) / 2
            if track[middle].timeMicroseconds < target { low = middle + 1 } else { high = middle }
        }
        let index = low <= last && track[low].timeMicroseconds == target ? low : max(0, low - 1)
        let first = SeekPoint(timeMicroseconds: track[index].timeMicroseconds, clusterOffset: track[index].clusterOffset)
        if first.timeMicroseconds >= target || index == last { return (first, first) }
        return (first, SeekPoint(timeMicroseconds: track[index + 1].timeMicroseconds, clusterOffset: track[index + 1].clusterOffset))
    }

    enum Failure: Error, Equatable { case truncated, malformed, unsupportedUnknownSize }
    static func read(bytes: @escaping (Int64, Int) throws -> Data,
                     onCueSeek: @escaping (Int64) throws -> Void = { _ in },
                     checkCancellation: @escaping () throws -> Void = {}) throws -> Self {
        try Reader(bytes: bytes, onCueSeek: onCueSeek, check: checkCancellation).scan()
    }

    private final class Reader {
        struct Element { let id: UInt64; let content: Int64; let end: Int64? }
        struct Track { let number: Int64; let type: Int64; let isDefault: Bool }
        let bytes: (Int64, Int) throws -> Data
        let onCueSeek: (Int64) throws -> Void
        let check: () throws -> Void
        var segment: Int64 = 0
        var scale: Int64?
        var duration: Int64?
        var tracks: [Int64: Track] = [:]
        var primary: Int64?
        var cueOffset: Int64?
        var cues: [Int64: [Cue]] = [:]

        init(bytes: @escaping (Int64, Int) throws -> Data, onCueSeek: @escaping (Int64) throws -> Void,
             check: @escaping () throws -> Void) {
            self.bytes = bytes; self.onCueSeek = onCueSeek; self.check = check
        }

        func scan() throws -> MatroskaTimeline {
            var offset: Int64 = 0
            while let item = try header(at: offset, allowEOF: true) {
                if item.id == 0x18538067 {
                    segment = item.content
                    return try scanSegment(item)
                }
                offset = try end(item)
            }
            throw Failure.malformed
        }

        func scanSegment(_ parent: Element) throws -> MatroskaTimeline {
            var offset = parent.content
            while parent.end.map({ offset < $0 }) ?? true {
                guard let item = try header(at: offset, allowEOF: true) else { break }
                try validate(item, within: parent)
                switch item.id {
                case 0x114D9B74: try seekHead(item)
                case 0x1549A966: try info(item)
                case 0x1654AE6B: try trackList(item)
                case 0x1C53BB6B:
                    try cueList(item)
                    return result()
                case 0x1F43B675:
                    // At the first Cluster, Media3 follows a declared Cues location.
                    // With no such declaration it publishes Unseekable immediately.
                    if let cueOffset {
                        try onCueSeek(cueOffset)
                        guard let target = try header(at: cueOffset), target.id == 0x1C53BB6B else { throw Failure.malformed }
                        try validate(target, within: parent)
                        try cueList(target)
                    }
                    return result()
                default: break
                }
                offset = try end(item)
            }
            return result()
        }

        func result() -> MatroskaTimeline {
            .init(durationMicroseconds: duration, primaryTrack: primary, cues: cues, declaredCueOffset: cueOffset)
        }

        func seekHead(_ parent: Element) throws {
            try children(parent) { item in
                guard item.id == 0x4DBB else { return }
                var id: Int64?, position: Int64?
                try children(item) { field in
                    if field.id == 0x53AB { id = try unsigned(field) }
                    if field.id == 0x53AC { position = try unsigned(field) }
                }
                guard let id, let position else { throw Failure.malformed }
                if id == 0x1C53BB6B { cueOffset = try add(segment, position) }
            }
        }

        func info(_ parent: Element) throws {
            var ticks: Int64?
            try children(parent) { item in
                if item.id == 0x2AD7B1 { scale = try unsigned(item) }
                if item.id == 0x4489 {
                    let count = try size(item)
                    guard count == 4 || count == 8 else { throw Failure.malformed }
                    let data = try exact(at: item.content, count: count)
                    let bits = data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                    let value: Double
                    if count == 4 { value = Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits))) }
                    else if count == 8 { value = Double(bitPattern: bits) }
                    else { throw Failure.malformed }
                    // MatroskaExtractor casts Duration to Java long before scaling.
                    ticks = value.isNaN ? 0 : MediaTimestampMath.truncate(value)
                }
            }
            if scale == nil { scale = 1_000_000 }
            if let ticks { duration = try time(ticks) }
        }

        func trackList(_ parent: Element) throws {
            try children(parent) { item in
                guard item.id == 0xAE else { return }
                var number: Int64 = 0, type: Int64 = 0, isDefault = true
                var codec: String?
                try children(item) { field in
                    switch field.id {
                    case 0xD7: number = Int64(Int32(truncatingIfNeeded: try unsigned(field)))
                    case 0x83: type = try unsigned(field)
                    case 0x88: isDefault = try unsigned(field) == 1
                    case 0x86:
                        codec = try codecID(field)
                    default: break
                    }
                }
                guard let codec else { throw Failure.malformed }
                if supportedCodecs.contains(codec) { tracks[number] = .init(number: number, type: type, isDefault: isDefault) }
            }
            guard !tracks.isEmpty else { throw Failure.malformed }
            // Android SparseArray iterates by track number, not file declaration order.
            let sorted = tracks.values.sorted { $0.number < $1.number }
            let video = sorted.filter { $0.type == 1 }, audio = sorted.filter { $0.type == 2 }
            primary = (video.last { $0.isDefault } ?? video.first
                ?? audio.last { $0.isDefault } ?? audio.first ?? sorted.first)?.number
        }

        func cueList(_ parent: Element) throws {
            try children(parent) { item in
                guard item.id == 0xBB else { return }
                var timestamp: Int64?
                try children(item) { field in
                    if field.id == 0xB3 { timestamp = try time(unsigned(field)) }
                    if field.id == 0xB7 {
                        var track: Int64?, cluster: Int64?, relative: Int64?
                        try children(field) { value in
                            switch value.id {
                            case 0xF7: track = Int64(Int32(truncatingIfNeeded: try unsigned(value)))
                            case 0xF1: if cluster == nil { cluster = try unsigned(value) }
                            case 0xF0: if relative == nil { relative = try unsigned(value) }
                            default: break
                            }
                        }
                        if let timestamp, let track, let cluster {
                            cues[track, default: []].append(.init(timeMicroseconds: timestamp,
                                clusterOffset: try add(segment, cluster), relativeOffset: relative))
                        }
                    }
                }
            }
            for track in cues.keys {
                cues[track] = cues[track]!.enumerated().sorted {
                    $0.element.timeMicroseconds == $1.element.timeMicroseconds
                        ? $0.offset < $1.offset : $0.element.timeMicroseconds < $1.element.timeMicroseconds
                }.map(\.element)
            }
        }

        func time(_ ticks: Int64) throws -> Int64 {
            guard let scale, scale >= 0, ticks >= 0 else { throw Failure.malformed }
            return MediaTimestampMath.scale(ticks, by: scale, over: 1000)
        }
        func children(_ parent: Element, visit: (Element) throws -> Void) throws {
            let limit = try end(parent)
            var offset = parent.content
            while offset < limit {
                try check()
                guard let item = try header(at: offset) else { throw Failure.truncated }
                try validate(item, within: parent)
                try visit(item)
                offset = try end(item)
            }
        }
        func validate(_ item: Element, within parent: Element) throws {
            if let limit = parent.end {
                guard item.content <= limit, item.end.map({ $0 <= limit }) ?? true else { throw Failure.malformed }
            }
        }
        func end(_ item: Element) throws -> Int64 {
            guard let end = item.end else { throw Failure.unsupportedUnknownSize }
            return end
        }
        func size(_ item: Element) throws -> Int {
            guard let count = Int(exactly: try end(item) - item.content) else { throw Failure.malformed }
            return count
        }
        func codecID(_ item: Element) throws -> String {
            // DefaultEbmlReader strips trailing NULs. Preserve that behavior without
            // retaining an arbitrarily large string that cannot name a supported codec.
            let count = try size(item)
            var prefix = Data(), offset = 0, lastNonzero = -1
            while offset < count {
                let part = try exact(at: add(item.content, Int64(offset)), count: min(4096, count - offset))
                for (index, byte) in part.enumerated() where byte != 0 { lastNonzero = offset + index }
                if prefix.count < 64 { prefix.append(part.prefix(64 - prefix.count)) }
                offset += part.count
            }
            guard lastNonzero < 64 else { return "" }
            return String(decoding: prefix.prefix(lastNonzero + 1), as: UTF8.self)
        }
        func unsigned(_ item: Element) throws -> Int64 {
            let count = try size(item)
            guard count <= 8 else { throw Failure.malformed }
            let value = try exact(at: item.content, count: count).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard let result = Int64(exactly: value) else { throw Failure.malformed }
            return result
        }
        func header(at offset: Int64, allowEOF: Bool = false) throws -> Element? {
            try check()
            let first = try bytes(offset, 1)
            if first.isEmpty, allowEOF { return nil }
            guard first.count == 1 else { throw Failure.truncated }
            func vint(at position: Int64, first: UInt8, maximum: Int, strip: Bool) throws -> (UInt64, Int) {
                guard first != 0 else { throw Failure.malformed }
                let count = first.leadingZeroBitCount + 1
                guard count <= maximum else { throw Failure.malformed }
                var value = UInt64(strip ? first & (0xFF >> count) : first)
                for byte in try exact(at: add(position, 1), count: count - 1) { value = (value << 8) | UInt64(byte) }
                return (value, count)
            }
            let (id, idCount) = try vint(at: offset, first: first.first!, maximum: 4, strip: false)
            let sizeOffset = try add(offset, Int64(idCount))
            let sizeFirst = try exact(at: sizeOffset, count: 1)[0]
            let (length, lengthCount) = try vint(at: sizeOffset, first: sizeFirst, maximum: 8, strip: true)
            let content = try add(sizeOffset, Int64(lengthCount))
            let unknown = length == (UInt64(1) << (7 * lengthCount)) - 1
            return .init(id: id, content: content, end: unknown ? nil : try add(content, Int64(length)))
        }
        func exact(at offset: Int64, count: Int) throws -> Data {
            var data = Data()
            while data.count < count {
                try check()
                let remaining = count - data.count
                let part = try bytes(add(offset, Int64(data.count)), min(remaining, 4096))
                guard !part.isEmpty, part.count <= min(remaining, 4096) else { throw Failure.truncated }
                data.append(part)
            }
            return data
        }
        func add(_ a: Int64, _ b: Int64) throws -> Int64 {
            let (result, overflow) = a.addingReportingOverflow(b)
            guard !overflow, result >= 0 else { throw Failure.malformed }
            return result
        }

        private var supportedCodecs: Set<String> { Self.codecs }
        private static let codecs: Set<String> = [
            "V_VP8",
            "V_VP9",
            "V_AV1",
            "V_MPEG2",
            "V_MPEG4/ISO/SP",
            "V_MPEG4/ISO/ASP",
            "V_MPEG4/ISO/AP",
            "V_MPEG4/ISO/AVC",
            "V_MPEGH/ISO/HEVC",
            "V_MS/VFW/FOURCC",
            "V_THEORA",
            "A_OPUS",
            "A_VORBIS",
            "A_AAC",
            "A_MPEG/L2",
            "A_MPEG/L3",
            "A_AC3",
            "A_EAC3",
            "A_TRUEHD",
            "A_DTS",
            "A_DTS/EXPRESS",
            "A_DTS/LOSSLESS",
            "A_FLAC",
            "A_MS/ACM",
            "A_PCM/INT/LIT",
            "A_PCM/INT/BIG",
            "A_PCM/FLOAT/IEEE",
            "S_TEXT/UTF8",
            "S_TEXT/ASS",
            "S_TEXT/SSA",
            "S_TEXT/WEBVTT",
            "S_VOBSUB",
            "S_HDMV/PGS",
            "S_DVBSUB"
        ]
    }
}
