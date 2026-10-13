import Foundation

/// Source-derived ID3v2.3/v2.4 local description extraction. Reads tag frames only;
/// the media payload is never loaded into memory. Call inside coordinated access.
public enum ID3CommentReader {
    public enum Failure: Error, Equatable, Sendable {
        case notID3, unsupportedVersion, truncated, invalidSize, unsupportedFrameEncoding, invalidText
    }

    public static func read(url: URL, checkCancellation: () throws -> Void = {}) throws -> String? {
        try checkCancellation()
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd(); try file.seek(toOffset: 0)
        var input = Cursor(file: file, end: length)
        guard length >= 3, try input.bytes(3) == [0x49, 0x44, 0x33] else { throw Failure.notID3 }
        let header = try input.bytes(7)
        guard header[0] == 3 || header[0] == 4 else { throw Failure.unsupportedVersion }
        let version = header[0], flags = header[2]
        let tagSize = try size(Array(header[3...6]), synchsafe: true)
        guard UInt64(tagSize) <= length - 10 else { throw Failure.truncated }
        input.end = 10 + UInt64(tagSize)
        input.unsynchronized = version == 3 && flags & 0x80 != 0
        // Extended header size includes itself in v2.4, excludes itself in v2.3.
        if flags & 0x40 != 0 {
            let extended = try size(input.bytes(4), synchsafe: version == 4)
            guard extended >= (version == 4 ? 4 : 0) else { throw Failure.invalidSize }
            try input.skip(UInt64(extended - (version == 4 ? 4 : 0)), checkCancellation: checkCancellation)
        }
        var comment: String?
        while input.position < input.end {
            try checkCancellation()
            let first = try input.bytes(1)[0]
            if first == 0 { break } // Padding; do not require a full frame header.
            let frame = [first] + (try input.bytes(9))
            let id = String(decoding: frame[0..<4], as: UTF8.self)
            let count = try size(Array(frame[4..<8]), synchsafe: version == 4)
            guard UInt64(count) <= input.end - input.position else { throw Failure.truncated }
            guard id == "COMM" || id == "TXXX" else { try input.skip(UInt64(count), checkCancellation: checkCancellation); continue }
            let formatFlags = frame[9]
            // Compressed/encrypted text needs an actual decoder, not guessed plaintext.
            guard (version == 3 ? formatFlags & 0xc0 : formatFlags & 0x0c) == 0 else { throw Failure.unsupportedFrameEncoding }
            var payload = try input.bytes(count, checkCancellation: checkCancellation)
            if version == 4 && (flags & 0x80 != 0 || formatFlags & 0x02 != 0) { payload = removeUnsynchronization(payload) }
            var prefix = 0
            if (version == 3 ? formatFlags & 0x20 : formatFlags & 0x40) != 0 { prefix += 1 }
            if version == 4 && formatFlags & 0x01 != 0 { prefix += 4 }
            guard payload.count > prefix else { throw Failure.truncated }
            var cursor = TextCursor(bytes: payload, position: prefix)
            let encoding = try cursor.byte()
            if id == "COMM" {
                try cursor.skip(3) // Language is intentionally not a selection criterion.
                let short = try cursor.string(encoding: encoding)
                let long = try cursor.string(encoding: encoding)
                comment = short.utf16.count > long.utf16.count ? short : long
            } else {
                let description = try cursor.string(encoding: encoding)
                let value = try cursor.string(encoding: encoding)
                if description == "comment" { comment = value }
            }
        }
        try checkCancellation()
        return comment
    }

    private static func size(_ bytes: [UInt8], synchsafe: Bool) throws -> Int {
        if synchsafe && bytes.contains(where: { $0 & 0x80 != 0 }) { throw Failure.invalidSize }
        return bytes.reduce(0) { ($0 << (synchsafe ? 7 : 8)) | Int($1) }
    }

    private static func removeUnsynchronization(_ input: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []; output.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            let byte = input[index]; output.append(byte); index += 1
            if byte == 0xff && index < input.count && input[index] == 0 { index += 1 }
        }
        return output
    }

    private struct Cursor {
        let file: FileHandle
        var end: UInt64
        // Physical position/end include inserted zeros; frame sizes count decoded bytes.
        var position: UInt64 = 0
        var unsynchronized = false
        private var buffer: [UInt8] = []
        private var index = 0

        init(file: FileHandle, end: UInt64) { self.file = file; self.end = end }

        mutating func bytes(_ count: Int, checkCancellation: () throws -> Void = {}) throws -> [UInt8] {
            guard count >= 0, UInt64(count) <= end - position else { throw Failure.truncated }
            var result: [UInt8] = []
            while result.count < count {
                if unsynchronized {
                    if result.count.isMultiple(of: 16_384) { try checkCancellation() }
                    let byte = try physicalByte(checkCancellation: checkCancellation)
                    result.append(byte)
                    // Consume the inserted zero immediately, including at frame/tag end.
                    // FF 00 00 decodes as FF 00, not FF; the second zero is real data.
                    if byte == 0xff && position < end {
                        try refill(checkCancellation: checkCancellation)
                        if buffer[index] == 0 { index += 1; position += 1 }
                    }
                } else {
                    try checkCancellation()
                    guard let part = try file.read(upToCount: min(16_384, count - result.count)), !part.isEmpty else { throw Failure.truncated }
                    result.append(contentsOf: part); position += UInt64(part.count)
                }
            }
            return result
        }

        mutating func skip(_ count: UInt64, checkCancellation: () throws -> Void = {}) throws {
            guard count <= end - position else { throw Failure.truncated }
            if !unsynchronized { position += count; try file.seek(toOffset: position); return }
            // Cannot seek by a decoded frame size through an escaped physical stream.
            var remaining = count
            while remaining > 0 {
                try checkCancellation()
                let chunk = min(remaining, 16_384)
                _ = try bytes(Int(chunk), checkCancellation: checkCancellation)
                remaining -= chunk
            }
        }

        private mutating func refill(checkCancellation: () throws -> Void) throws {
            guard index == buffer.count else { return }
            try checkCancellation()
            guard position < end,
                  let part = try file.read(upToCount: Int(min(16_384, end - position))), !part.isEmpty else { throw Failure.truncated }
            buffer = Array(part); index = 0
        }

        private mutating func physicalByte(checkCancellation: () throws -> Void) throws -> UInt8 {
            try refill(checkCancellation: checkCancellation)
            let byte = buffer[index]; index += 1; position += 1
            return byte
        }
    }

    private struct TextCursor {
        let bytes: [UInt8]
        var position = 0
        mutating func byte() throws -> UInt8 {
            guard position < bytes.count else { throw Failure.truncated }
            defer { position += 1 }; return bytes[position]
        }
        mutating func skip(_ count: Int) throws {
            guard count <= bytes.count - position else { throw Failure.truncated }; position += count
        }
        mutating func string(encoding: UInt8) throws -> String {
            let start = position
            let width = encoding == 1 || encoding == 2 ? 2 : 1
            while position + width <= bytes.count {
                if bytes[position..<(position + width)].allSatisfy({ $0 == 0 }) {
                    let end = position; position += width
                    return try decode(Array(bytes[start..<end]), encoding: encoding)
                }
                position += width
            }
            position = bytes.count
            return try decode(Array(bytes[start...]), encoding: encoding)
        }
        private func decode(_ bytes: [UInt8], encoding: UInt8) throws -> String {
            if encoding == 1 || encoding == 2 {
                var bytes = bytes
                // The original reader tolerates one final zero padding byte.
                if !bytes.count.isMultiple(of: 2), bytes.last == 0 { bytes.removeLast() }
                guard bytes.count.isMultiple(of: 2) else { return "" }
                let little = bytes.starts(with: [0xff, 0xfe])
                let bom = little || bytes.starts(with: [0xfe, 0xff])
                let data = Data(bom ? Array(bytes.dropFirst(2)) : bytes)
                // Java UTF-16 defaults to big endian without a BOM for both codes.
                return String(data: data, encoding: little ? .utf16LittleEndian : .utf16BigEndian) ?? ""
            }
            if encoding == 3 {
                guard let value = String(bytes: bytes, encoding: .utf8) else { throw Failure.invalidText }
                return value
            }
            return String(String.UnicodeScalarView(bytes.map { UnicodeScalar($0) }))
        }
    }
}
