import Foundation

/// Ogg Vorbis/Opus local descriptions using the source's active key/length policy.
/// Run inside coordinated access. Ogg pages are buffered individually, not the file.
public enum VorbisDescriptionReader {
    public enum Failure: Error, Equatable, Sendable {
        case notOgg, truncated, noCommentHeader, invalidText, oversizedComment
    }

    public static func read(url: URL, checkCancellation: () throws -> Void = {}) throws -> String? {
        try checkCancellation()
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var input = Payload(file: file)
        var signature: UInt64 = 0
        var found = false
        for index in 0..<(64 * 1024 * 1024) {
            if index.isMultiple(of: 16_384) { try checkCancellation() }
            signature = (signature << 8) | UInt64(try input.byte(check: checkCancellation))
            if signature == 0x4f70757354616773 || signature & 0x00ff_ffff_ffff_ffff == 0x03766f72626973 {
                found = true; break
            }
        }
        guard found else { throw Failure.noCommentHeader }
        let vendorLength = try input.integer(check: checkCancellation)
        try input.skipUTF8(vendorLength, check: checkCancellation)
        let count = try input.integer(check: checkCancellation)
        var description: String?
        for _ in 0..<count {
            try checkCancellation()
            do {
                let length = try input.integer(check: checkCancellation)
                guard length <= 20 * 1024 * 1024 else { throw Failure.oversizedComment }
                var key: [UInt8] = []
                var remaining = length
                var separator = false
                while remaining > 0 {
                    let byte = try input.byte(check: checkCancellation); remaining -= 1
                    if byte == 61 { separator = true; break }
                    // Only these ASCII keys are actionable. Bound key storage even
                    // for malformed vectors containing megabytes without '='.
                    if key.count <= 11 { key.append(byte >= 65 && byte <= 90 ? byte + 32 : byte) }
                }
                guard separator else { continue } // Invalid key must not crash the scan.
                if key == Array("description".utf8) || key == Array("comment".utf8) {
                    let bytes = try input.bytes(remaining, check: checkCancellation)
                    // Source ignores an invalid UTF-8 vector and continues with later ones.
                    if let value = String(bytes: bytes, encoding: .utf8),
                       value.utf16.count > (description?.utf16.count ?? -1) { description = value }
                } else { try input.skip(remaining, check: checkCancellation) }
            } catch Failure.truncated { break } // Retain already-read valid descriptions.
            catch Failure.notOgg { break }
        }
        try checkCancellation()
        return description
    }

    private struct Payload {
        let file: FileHandle
        private var page: [UInt8] = []
        private var index = 0
        private var truncatedPage = false
        init(file: FileHandle) { self.file = file }

        mutating func byte(check: () throws -> Void) throws -> UInt8 {
            try refill(check: check)
            defer { index += 1 }; return page[index]
        }
        mutating func integer(check: () throws -> Void) throws -> Int {
            let bytes = try bytes(4, check: check)
            return bytes.enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        }
        mutating func bytes(_ count: Int, check: () throws -> Void) throws -> [UInt8] {
            var output: [UInt8] = []
            var remaining = count
            while remaining > 0 {
                try check(); try refill(check: check)
                let amount = min(remaining, page.count - index)
                output.append(contentsOf: page[index..<(index + amount)])
                index += amount; remaining -= amount
            }
            return output
        }
        mutating func skip(_ count: Int, check: () throws -> Void) throws {
            var remaining = count
            while remaining > 0 {
                try check(); try refill(check: check)
                let amount = min(remaining, page.count - index)
                index += amount; remaining -= amount
            }
        }
        /// Validate but do not retain the unused vendor text, even if very large.
        mutating func skipUTF8(_ count: Int, check: () throws -> Void) throws {
            var needed = 0, lower: UInt8 = 0x80, upper: UInt8 = 0xbf
            for offset in 0..<count {
                if offset.isMultiple(of: 16_384) { try check() }
                let value = try byte(check: check)
                if needed > 0 {
                    guard value >= lower && value <= upper else { throw Failure.invalidText }
                    needed -= 1; lower = 0x80; upper = 0xbf
                } else {
                    switch value {
                    case 0...0x7f: break
                    case 0xc2...0xdf: needed = 1
                    case 0xe0: needed = 2; lower = 0xa0
                    case 0xe1...0xec, 0xee...0xef: needed = 2
                    case 0xed: needed = 2; upper = 0x9f
                    case 0xf0: needed = 3; lower = 0x90
                    case 0xf1...0xf3: needed = 3
                    case 0xf4: needed = 3; upper = 0x8f
                    default: throw Failure.invalidText
                    }
                }
            }
            guard needed == 0 else { throw Failure.invalidText }
        }
        private mutating func refill(check: () throws -> Void) throws {
            while index == page.count {
                try check()
                guard !truncatedPage else { throw Failure.truncated }
                let header = try readPhysical(27)
                guard header.starts(with: [79, 103, 103, 83]) else { throw Failure.notOgg }
                let lacing = try readPhysical(Int(header[26]))
                let count = lacing.reduce(0) { $0 + Int($1) }
                page = try readPhysical(count, allowPartial: true); index = 0
                truncatedPage = page.count != count
                // Empty pages must not expose the next physical header as payload.
            }
        }
        private func readPhysical(_ count: Int, allowPartial: Bool = false) throws -> [UInt8] {
            var output: [UInt8] = []
            while output.count < count {
                guard let bytes = try file.read(upToCount: count - output.count), !bytes.isEmpty else {
                    if allowPartial && !output.isEmpty { break }
                    throw Failure.truncated
                }
                output.append(contentsOf: bytes)
            }
            return output
        }
    }
}
