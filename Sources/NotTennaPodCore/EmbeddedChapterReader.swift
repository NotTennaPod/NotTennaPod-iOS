import Foundation

/// A chapter image stays in the media resource. The access owner supplies the
/// same resource when the player needs artwork, rather than persisting image data.
public struct EmbeddedChapterImage: Equatable, Sendable {
    public let offset: Int64
    public let length: Int
    public var url: String { "embedded-image://\(offset)/\(length)" }
    public init?(url: String) {
        guard url.hasPrefix("embedded-image://") else { return nil }
        let parts = url.dropFirst("embedded-image://".count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let offset = Int64(parts[0]), let length = Int(parts[1]),
              offset >= 0, length >= 0, Int128(offset) + Int128(length) <= Int128(Int64.max) else { return nil }
        self.offset = offset; self.length = length
    }
    init(offset: Int64, length: Int) { self.offset = offset; self.length = length }

    public func read(url: URL, checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> Data {
        try withChapterFile(url: url, check: checkCancellation) { try read(input: $0) }
    }
    func read(input: any MediaByteInput) throws -> Data {
        var cursor = ChapterByteCursor(input: input, position: offset, end: offset + Int64(length))
        return Data(try cursor.bytes(length))
    }
}

/// Tag parsing uses bounded reads under the caller's file/provider access grant.
/// The internal byte-input entry point also accepts a proxy-owned network lease.
/// Run these synchronous operations on a blocking-read executor, never in a view.
public enum EmbeddedChapterReader {
    public static func read(url: URL, checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> [ParsedChapter]? {
        try withChapterFile(url: url, check: checkCancellation) { try read(input: $0) }
    }

    static func read(input: any MediaByteInput) throws -> [ParsedChapter]? {
        for reader in [id3, vorbis, m4a] {
            try Task.checkCancellation(); try input.checkFailure()
            do {
                let raw = try reader(input)
                try Task.checkCancellation(); try input.checkFailure()
                guard !raw.isEmpty, raw.allSatisfy({ $0.startMilliseconds >= 0 }) else { continue }
                // Explicit tie order preserves the source's stable sort.
                var result = raw.enumerated().sorted {
                    $0.element.startMilliseconds == $1.element.startMilliseconds ? $0.offset < $1.offset :
                        $0.element.startMilliseconds < $1.element.startMilliseconds
                }.map(\.element)
                for index in result.indices where result[index].title == nil { result[index].title = String(index) }
                return result
            } catch is ChapterReadFailure { continue }
            catch {
                try Task.checkCancellation(); try input.checkFailure()
                if error is CancellationError { throw error }
                if let error = error as? URLError, [.cancelled, .timedOut].contains(error.code) { throw error }
            }
        }
        return nil
    }

    private static func id3(_ input: any MediaByteInput) throws -> [ParsedChapter] {
        var cursor = ChapterByteCursor(input: input)
        let header = try cursor.bytes(10)
        guard header.starts(with: [73, 68, 51]), [3, 4].contains(header[3]) else { throw ChapterReadFailure.notFormat }
        let version = header[3]
        let size = header[6...9].reduce(Int64(0)) { ($0 << 7) | Int64($1 & 127) }
        if header[5] & 0x40 != 0 {
            let extended = try cursor.integer(4)
            guard extended >= 4 else { throw ChapterReadFailure.malformed }
            try cursor.skip(Int64(extended) - 4)
        }
        cursor.end = cursor.position + size
        var chapters: [ParsedChapter] = []
        while cursor.position < cursor.end {
            let header = try cursor.bytes(10)
            guard (48...122).contains(header[0]) else { break }
            let size = frameSize(header, version: version)
            var frame = try cursor.slice(size)
            guard String(decoding: header[0..<4], as: UTF8.self) == "CHAP" else { continue }
            let id = try frame.text(encoding: 0, maximum: 100)
            let start = Int64(Int32(bitPattern: UInt32(try frame.integer(4))))
            try frame.skip(12)
            var chapter = ParsedChapter(startMilliseconds: start, chapterID: id)
            while frame.position < frame.end {
                let subheader = try frame.bytes(10)
                var subframe = try frame.slice(frameSize(subheader, version: version))
                switch String(decoding: subheader[0..<4], as: UTF8.self) {
                case "TIT2": chapter.title = try subframe.encodedText()
                case "WXXX":
                    _ = try subframe.encodedText()
                    chapter.link = decodeLink(try subframe.text(encoding: 0))
                case "APIC":
                    let encoding = try subframe.byte()
                    let mime = try subframe.text(encoding: 0)
                    let type = try subframe.byte()
                    _ = try subframe.text(encoding: encoding)
                    if chapter.imageURL?.isEmpty != false || type == 3 {
                        chapter.imageURL = mime == "-->" ? try subframe.text(encoding: 0) :
                            EmbeddedChapterImage(offset: subframe.position, length: Int(subframe.end - subframe.position)).url
                    }
                default: break
                }
            }
            chapters.append(chapter)
        }
        return chapters
    }

    private static func frameSize(_ header: [UInt8], version: UInt8) -> Int64 {
        header[4..<8].reduce(Int64(0)) { ($0 << (version == 4 ? 7 : 8)) | Int64(version == 4 ? $1 & 127 : $1) }
    }

    private static func decodeLink(_ text: String) -> String? {
        let characters = Array(text.unicodeScalars)
        var decoded = String.UnicodeScalarView(), index = 0
        while index < characters.count {
            if characters[index] == "%" {
                guard index + 2 < characters.count,
                      let value = UInt8(String(String.UnicodeScalarView(characters[(index + 1)...(index + 2)])), radix: 16) else { return nil }
                decoded.append(UnicodeScalar(value)); index += 3
            } else {
                // The source URLDecoder uses ISO-8859-1 for %-encoded bytes.
                decoded.append(characters[index] == "+" ? " " : characters[index]); index += 1
            }
        }
        return String(decoded)
    }

    private static func vorbis(_ input: any MediaByteInput) throws -> [ParsedChapter] {
        var stream = ChapterOggPayload(cursor: ChapterByteCursor(input: input))
        var chapters: [ParsedChapter] = []
        do {
            var signature: UInt64 = 0, found = false
            for _ in 0..<(64 * 1024 * 1024) {
                signature = (signature << 8) | UInt64(try stream.byte())
                if signature == 0x4f70757354616773 || signature & 0x00ff_ffff_ffff_ffff == 0x03766f72626973 { found = true; break }
            }
            guard found else { return [] }
            let vendorLength = try stream.integer()
            guard String(bytes: try stream.bytes(vendorLength), encoding: .utf8) != nil else { return [] }
            let count = try stream.integer()
            for _ in 0..<count {
                let size = try stream.integer()
                guard size <= 20 * 1024 * 1024 else { throw ChapterReadFailure.malformed }
                let bytes = try stream.bytes(size)
                guard let split = bytes.firstIndex(of: 61) else { continue }
                let key = String(decoding: bytes[..<split], as: UTF8.self).lowercased()
                guard key.hasPrefix("chapter"), key.utf8.count >= 10 else { continue }
                let digits = key.dropFirst(7).prefix(3)
                guard digits.utf8.allSatisfy({ (48...57).contains($0) }), let id = Int(digits),
                      let value = String(bytes: bytes[(split + 1)...], encoding: .utf8) else { continue }
                let attribute = key.dropFirst(10)
                if attribute.isEmpty {
                    guard !chapters.contains(where: { $0.chapterID == String(id) }) else { throw ChapterReadFailure.malformed }
                    chapters.append(.init(startMilliseconds: try vorbisTime(value), chapterID: String(id)))
                } else if let index = chapters.firstIndex(where: { $0.chapterID == String(id) }) {
                    if attribute == "name" { chapters[index].title = value }
                    else if attribute == "url" { chapters[index].link = value }
                }
            }
        } catch ChapterReadFailure.truncated { return chapters }
        catch ChapterReadFailure.notFormat { return chapters }
        return chapters
    }

    private static func vorbisTime(_ text: String) throws -> Int64 {
        let parts = text.components(separatedBy: ":")
        guard parts.count >= 3, let hours = Int64(parts[0]), let minutes = Int64(parts[1]),
              let seconds = Float(parts[2].components(separatedBy: "-->")[0].trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds.isFinite, Double(seconds) > Double(Int64.min), Double(seconds) < Double(Int64.max) else { throw ChapterReadFailure.malformed }
        let milliseconds = Int128(hours) * 3_600_000 + Int128(minutes) * 60_000 + Int128(Int64(seconds)) * 1000
        guard let result = Int64(exactly: milliseconds) else { throw ChapterReadFailure.malformed }
        return result
    }

    private static func m4a(_ input: any MediaByteInput) throws -> [ParsedChapter] {
        var cursor = ChapterByteCursor(input: input)
        let first = try cursor.bytes(8)
        guard String(decoding: first[4...7], as: UTF8.self) == "ftyp" else { throw ChapterReadFailure.notFormat }
        let size = first[0...3].reduce(Int64(0)) { $0 << 8 | Int64($1) }
        guard size >= 8 else { throw ChapterReadFailure.malformed }
        try cursor.skip(size - 8)
        var chapters: [ParsedChapter] = []
        do {
            for wanted in ["moov", "udta", "chpl"] {
                var found = false
                while cursor.position < cursor.bound {
                    let header = try cursor.bytes(8)
                    var size = header[0...3].reduce(Int64(0)) { $0 << 8 | Int64($1) }
                    var headerSize: Int64 = 8
                    if size == 1 {
                        let extended = try cursor.integer(8)
                        guard extended <= UInt64(Int64.max) else { throw ChapterReadFailure.malformed }
                        size = Int64(extended); headerSize = 16
                    } else if size == 0 { size = cursor.bound - cursor.position + headerSize }
                    guard size >= headerSize else { throw ChapterReadFailure.malformed }
                    let atom = try cursor.slice(size - headerSize)
                    if String(decoding: header[4...7], as: UTF8.self) == wanted { cursor = atom; found = true; break }
                }
                guard found else { return [] }
            }
            try cursor.skip(5)
            let count = try cursor.integer(4)
            for index in 0..<count {
                let time = Int64(bitPattern: try cursor.integer(8)) / 10_000
                let count = Int(try cursor.byte())
                let title = String(decoding: try cursor.bytes(count), as: UTF8.self)
                chapters.append(.init(startMilliseconds: time, title: title, chapterID: String(index + 1)))
            }
        } catch is ChapterReadFailure { return chapters }
        return chapters
    }
}

private enum ChapterReadFailure: Error { case notFormat, malformed, truncated }

private func withChapterFile<Value>(url: URL, check: @Sendable () throws -> Void,
                                   body: (any MediaByteInput) throws -> Value) throws -> Value {
    try check()
    return try withoutActuallyEscaping(check) { check in
        let input = ChapterCheckedInput(base: try LocalAudioBytes(url: url).lease(), check: check)
        defer { input.cancel() }
        let result = try body(input)
        try check()
        return result
    }
}

private struct ChapterCheckedInput: MediaByteInput {
    let base: any MediaByteInput
    let check: @Sendable () throws -> Void
    var length: Int64? { base.length }
    var supportsRandomAccess: Bool { base.supportsRandomAccess }
    func prepareForSeek() { base.prepareForSeek() }
    func cancel() { base.cancel() }
    func checkFailure() throws { try check(); try base.checkFailure() }
    func read(at offset: Int64, maximumCount: Int) throws -> Data {
        try checkFailure()
        let data = try base.read(at: offset, maximumCount: maximumCount)
        try checkFailure()
        return data
    }
}

private struct ChapterByteCursor {
    let input: any MediaByteInput
    var position: Int64 = 0
    var end: Int64 = .max
    private var buffer: [UInt8] = []
    private var bufferStart: Int64 = -1
    var bound: Int64 { min(end, input.length ?? .max) }
    init(input: any MediaByteInput, position: Int64 = 0, end: Int64 = .max) {
        self.input = input; self.position = position; self.end = end
    }
    mutating func byte() throws -> UInt8 { try bytes(1)[0] }
    mutating func integer(_ count: Int) throws -> UInt64 { try bytes(count).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
    mutating func bytes(_ count: Int) throws -> [UInt8] {
        try Task.checkCancellation(); try input.checkFailure()
        guard count >= 0, position >= 0, position <= bound, Int64(count) <= bound - position else { throw ChapterReadFailure.truncated }
        var result: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            try Task.checkCancellation(); try input.checkFailure()
            if position < bufferStart || position >= bufferStart + Int64(buffer.count) {
                bufferStart = position
                buffer = Array(try input.read(at: position, maximumCount: Int(min(65_536, bound - position))))
                guard !buffer.isEmpty else { throw ChapterReadFailure.truncated }
            }
            let index = Int(position - bufferStart), amount = min(remaining, buffer.count - index)
            result.append(contentsOf: buffer[index..<(index + amount)])
            position += Int64(amount); remaining -= amount
        }
        return result
    }
    mutating func skip(_ count: Int64) throws {
        try Task.checkCancellation(); try input.checkFailure()
        guard count >= 0, position >= 0, position <= bound, count <= bound - position else { throw ChapterReadFailure.truncated }
        if count > 0, input.length == nil {
            guard !(try input.read(at: position + count - 1, maximumCount: 1)).isEmpty else { throw ChapterReadFailure.truncated }
        }
        position += count
    }
    mutating func slice(_ count: Int64) throws -> Self {
        let start = position
        try skip(count)
        var slice = self; slice.position = start; slice.end = position
        return slice
    }
    mutating func encodedText() throws -> String { let encoding = try byte(); return try text(encoding: encoding) }
    mutating func text(encoding: UInt8, maximum: Int = .max) throws -> String {
        let width = encoding == 1 || encoding == 2 ? 2 : 1
        var remaining = min(Int(bound - position), maximum), bytes: [UInt8] = []
        while remaining >= width {
            let part = try self.bytes(width); remaining -= width
            if part.allSatisfy({ $0 == 0 }) { remaining = 0; break }
            bytes.append(contentsOf: part)
        }
        if remaining == 1 { let last = try byte(); if last != 0 { bytes.append(last) } }
        if width == 2 {
            guard bytes.count.isMultiple(of: 2) else { return "" }
            let little = bytes.starts(with: [255, 254]), bom = little || bytes.starts(with: [254, 255])
            return String(data: Data(bom ? Array(bytes.dropFirst(2)) : bytes), encoding: little ? .utf16LittleEndian : .utf16BigEndian) ?? ""
        }
        if encoding == 3 {
            guard let value = String(bytes: bytes, encoding: .utf8) else { throw ChapterReadFailure.malformed }
            return value
        }
        return String(String.UnicodeScalarView(bytes.map { UnicodeScalar($0) }))
    }
}

private struct ChapterOggPayload {
    var cursor: ChapterByteCursor
    private var remaining = 0
    init(cursor: ChapterByteCursor) { self.cursor = cursor }
    mutating func byte() throws -> UInt8 {
        while remaining == 0 {
            let header = try cursor.bytes(27)
            guard header.starts(with: [79, 103, 103, 83]) else { throw ChapterReadFailure.notFormat }
            remaining = try cursor.bytes(Int(header[26])).reduce(0) { $0 + Int($1) }
        }
        remaining -= 1; return try cursor.byte()
    }
    mutating func bytes(_ count: Int) throws -> [UInt8] {
        var bytes: [UInt8] = []
        for _ in 0..<count { bytes.append(try byte()) }
        return bytes
    }
    mutating func integer() throws -> Int {
        try bytes(4).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
    }
}
