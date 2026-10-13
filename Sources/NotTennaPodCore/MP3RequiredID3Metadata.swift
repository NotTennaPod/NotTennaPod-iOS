// Required ID3/MLLT interpretation follows AndroidX Media3 (Apache-2.0).
// See Licenses/Android-MP3-Metadata.txt.
import Foundation

/// Reads required source timing from the existing encoded cache without copying
/// an entire ID3 tag or allocating its reference table. Runs on the decoder's
/// blocking-read executor; its read lease owns cancellation. Gapless COM parsing
/// and indexed byte seeking remain separate from this initial timeline boundary.
struct MP3RequiredID3Metadata: Sendable {
    let durationMicroseconds: Int64
    let seekPoint: MP3SeekIndex.Point?
    let seekTable: MP3MLLTSeekTable?
    enum Lookup: Sendable {
        case timeMicroseconds(Int64)
        case bytePosition(Int64)
    }
    private enum Malformed: Error { case tag }

    static func read(from input: any MediaByteInput, seeking query: Lookup? = nil, firstFramePosition: Int64 = 0, retainSeekTable: Bool = false) throws -> Self? {
        var offset: Int64 = 0
        while true {
            var found = false
            var header = Cursor(input: input, position: offset, end: Int64.max)
            var bytes = try header.read(upTo: 10)
            for search in 0...131_072 {
                try Task.checkCancellation()
                guard bytes.count == 10 else { return nil }
                if bytes.starts(with: [0x49, 0x44, 0x33]) {
                    guard bytes[6...9].allSatisfy({ $0 < 128 }) else { return nil }
                    let size = bytes[6...9].reduce(Int64(0)) { ($0 << 7) | Int64($1) }
                    let start = offset + Int64(search) + 10, end = start + size
                    // Id3Peeker obtains the complete declared tag before decoding.
                    // This remains sequential cache loading, not an HTTP range seek.
                    if size > 0 {
                        var tail = Cursor(input: input, position: end - 1, end: end)
                        guard try tail.byte() != nil else { return nil }
                    }
                    // A v2.4 footer follows the declared body (ID3v2.4 PROTOCOL §15.2). An older layout
                    // places it at the end of the body instead; recognize either by its bytes,
                    // and never cut a frame for a flag without a footer.
                    var framesEnd = end, next = end
                    if let header = ID3v2Header(Data(bytes)), header.hasFooter {
                        var after = Cursor(input: input, position: end, end: end + 10)
                        var last = Cursor(input: input, position: max(start, end - 10), end: end)
                        if header.isFooter(Data(try after.read(upTo: 10))) { next = end + 10 }
                        else if size >= 10, header.isFooter(Data(try last.read(upTo: 10))) { framesEnd = end - 10 }
                    }
                    if let decoded = try decodeTag(input: input, start: start, end: framesEnd,
                                                  version: Int(bytes[3]), flags: bytes[5], query: query, firstFramePosition: firstFramePosition, retainSeekTable: retainSeekTable) {
                        // A valid empty/filtered tag also wins over later tags.
                        return decoded.result
                    }
                    offset = next
                    found = true
                    break
                }
                if MP3XingMetadata.bitrate(in: Data(bytes)) != nil { return nil }
                guard let next = try header.byte() else { return nil }
                bytes.removeFirst(); bytes.append(next)
            }
            if !found { return nil }
        }
    }

    private struct Tag { let result: MP3RequiredID3Metadata? }
    private static func decodeTag(input: any MediaByteInput, start: Int64, end: Int64,
                                  version: Int, flags: UInt8, query: Lookup?, firstFramePosition: Int64, retainSeekTable: Bool) throws -> Tag? {
        guard (2...4).contains(version), !(version == 2 && flags & 0x40 != 0) else { return nil }
        do {
            var framesStart = start, framesEnd = end
            if version >= 3, flags & 0x40 != 0 {
                var cursor = Cursor(input: input, position: start, end: end)
                let bytes = try cursor.exact(4)
                let size = version == 4 ? try synchSafe(bytes) : integer(bytes)
                guard size >= (version == 4 ? 4 : 0) else { return nil }
                framesStart += size + (version == 3 ? 4 : 0)
            }
            guard framesStart <= framesEnd else { return nil }
            let cursor = Cursor(input: input, position: framesStart, end: framesEnd,
                unsynchronized: version < 4 && flags & 0x80 != 0)
            if let tag = try scan(cursor, version: version, rawV4Size: false, query: query, firstFramePosition: firstFramePosition, retainSeekTable: retainSeekTable) { return tag }
            // Preserve the original v2.4 non-synchsafe-size fallback after whole
            // tag validation fails. Both passes read the same disk-backed bytes.
            return version == 4 ? try scan(cursor, version: version, rawV4Size: true, query: query, firstFramePosition: firstFramePosition, retainSeekTable: retainSeekTable) : nil
        } catch is Malformed { return nil }
    }

    private static func scan(_ initial: Cursor, version: Int, rawV4Size: Bool, query: Lookup?, firstFramePosition: Int64, retainSeekTable: Bool) throws -> Tag? {
        var cursor = initial
        var result: Self?
        do {
            while true {
                try Task.checkCancellation()
                let header = try cursor.read(upTo: version == 2 ? 6 : 10)
                if header.count < (version == 2 ? 6 : 10) { return Tag(result: result) }
                if header.allSatisfy({ $0 == 0 }) { return Tag(result: result) }
                let sizeBytes = Array(header[(version == 2 ? 3 : 4)..<(version == 2 ? 6 : 8)])
                let size = version == 4 && !rawV4Size ? try synchSafe(sizeBytes) : integer(sizeBytes)
                let flags = version == 2 ? 0 : Int(header[8]) << 8 | Int(header[9])
                let grouped = version == 3 ? flags & 0x20 != 0 : version == 4 && flags & 0x40 != 0
                let dataLength = version == 3 ? flags & 0x80 != 0 : version == 4 && flags & 1 != 0
                let prefixCount = (grouped ? 1 : 0) + (dataLength ? 4 : 0)
                guard size >= prefixCount else { return nil }
                var next = cursor
                try next.skip(size)
                let compressedOrEncrypted = version == 3 ? flags & 0xc0 != 0 : version == 4 && flags & 0xc != 0
                // The active decoder recognizes MLLT (v2.3/2.4). Its v2.2 MLL
                // predicate admits a BinaryFrame, not an MlltFrame/seek map.
                if result == nil, version >= 3, header.prefix(4).elementsEqual([0x4d, 0x4c, 0x4c, 0x54]),
                   !compressedOrEncrypted {
                    var payload = Payload(cursor: cursor, remaining: size)
                    for _ in 0..<prefixCount { _ = try payload.byte() }
                    payload.unsynchronized = version == 4 && flags & 2 != 0
                    result = try decodeMLLT(&payload, query: query, firstFramePosition: firstFramePosition, retainSeekTable: retainSeekTable)
                }
                cursor = next
            }
        } catch is Malformed { return nil }
    }

    private static func decodeMLLT(_ payload: inout Payload, query: Lookup?, firstFramePosition: Int64, retainSeekTable: Bool) throws -> Self? {
        var header: [UInt8] = []
        for _ in 0..<10 {
            guard let byte = try payload.byte() else { return nil }
            header.append(byte)
        }
        let bytes = integer(Array(header[2..<5]))
        let milliseconds = integer(Array(header[5..<8]))
        let byteBits = Int(header[8]), timeBits = Int(header[9])
        guard byteBits <= 32, timeBits <= 32, byteBits + timeBits > 0 else { return nil }
        var bits = Bits(), total: Int128 = 0, position = Int128(firstFramePosition)
        var lookup = LookupCursor(query: query, firstFramePosition: firstFramePosition)
        let builder = try retainSeekTable ? MP3MLLTSeekTable.Builder() : nil
        while true {
            guard let byteDeviation = try bits.read(byteBits, from: &payload),
                  let deviation = try bits.read(timeBits, from: &payload) else { break }
            // ParsableBitArray.readBits returns a signed Java int for32 bits.
            let value = timeBits == 32 ? Int64(Int32(bitPattern: deviation)) : Int64(deviation)
            total += Int128(milliseconds + value)
            let byteValue = byteBits == 32 ? Int64(Int32(bitPattern: byteDeviation)) : Int64(byteDeviation)
            position += Int128(bytes + byteValue)
            lookup.observe(milliseconds: total, position: position)
            try builder?.append(milliseconds: total, position: position - Int128(firstFramePosition))
        }
        guard total >= 0, let duration = Int64(exactly: total * 1000) else { return nil }
        return Self(durationMicroseconds: duration, seekPoint: lookup.point, seekTable: try builder?.finish())
    }

    /// A query keeps two bracketing references, never the complete MLLT table.
    private struct LookupCursor {
        let query: Lookup?
        let target: Int128
        var lower: (x: Int128, y: Int128)
        var upper: (x: Int128, y: Int128)?
        var last: (x: Int128, y: Int128)
        var monotonic = true
        init(query: Lookup?, firstFramePosition: Int64) {
            self.query = query
            if case let .timeMicroseconds(value) = query {
                target = Int128(max(0, value) / 1000); lower = (0, Int128(firstFramePosition))
            } else if case let .bytePosition(value) = query {
                target = Int128(value); lower = (Int128(firstFramePosition), 0)
            } else { target = 0; lower = (0, Int128(firstFramePosition)) }
            last = lower
        }
        mutating func observe(milliseconds: Int128, position: Int128) {
            guard let query else { return }
            let next: (x: Int128, y: Int128)
            switch query {
            case .timeMicroseconds: next = (milliseconds, position)
            case .bytePosition: next = (position, milliseconds)
            }
            monotonic = monotonic && next.x >= last.x && next.y >= last.y
            last = next
            if next.x <= target { lower = next; upper = nil }
            else if upper == nil { upper = next }
        }
        var point: MP3SeekIndex.Point? {
            guard let query, monotonic else { return nil }
            let x: Int128, y: Int128
            if let upper {
                let fraction = upper.x == lower.x ? 0 : Double(target - lower.x) / Double(upper.x - lower.x)
                x = target; y = lower.y + Int128(fraction * Double(upper.y - lower.y))
            } else { x = lower.x; y = lower.y }
            let time: Int128, position: Int128
            switch query {
            case .timeMicroseconds: time = x * 1000; position = y
            case .bytePosition: time = y * 1000; position = x
            }
            guard let t = Int64(exactly: time), let p = Int64(exactly: position) else { return nil }
            return .init(timeMicroseconds: t, bytePosition: p)
        }
    }

    private static func integer(_ bytes: [UInt8]) -> Int64 {
        bytes.reduce(0) { ($0 << 8) | Int64($1) }
    }
    private static func synchSafe(_ bytes: [UInt8]) throws -> Int64 {
        guard bytes.allSatisfy({ $0 < 128 }) else { throw Malformed.tag }
        return bytes.reduce(0) { ($0 << 7) | Int64($1) }
    }

    private struct Bits {
        var value: UInt64 = 0, count = 0
        mutating func read(_ width: Int, from payload: inout Payload) throws -> UInt32? {
            if width == 0 { return 0 }
            while count < width {
                guard let byte = try payload.byte() else { return nil }
                value = (value << 8) | UInt64(byte); count += 8
            }
            count -= width
            let result = UInt32((value >> count) & ((UInt64(1) << width) - 1))
            value &= (UInt64(1) << count) - 1
            return result
        }
    }

    private struct Payload {
        var cursor: Cursor
        var remaining: Int64
        var unsynchronized = false
        private var afterFF = false
        init(cursor: Cursor, remaining: Int64) { self.cursor = cursor; self.remaining = remaining }
        mutating func byte() throws -> UInt8? {
            while remaining > 0 {
                guard let byte = try cursor.byte() else { throw Malformed.tag }
                remaining -= 1
                if unsynchronized && afterFF && byte == 0 { afterFF = false; continue }
                afterFF = byte == 0xff
                return byte
            }
            return nil
        }
    }

    /// Small independent windows allow validation/retry without retaining a tag.
    private struct Cursor {
        let input: any MediaByteInput
        var position: Int64
        let end: Int64
        var unsynchronized = false
        private var afterFF = false
        private var bytes = Data()
        private var base: Int64 = 0
        init(input: any MediaByteInput, position: Int64, end: Int64, unsynchronized: Bool = false) {
            self.input = input; self.position = position; self.end = end; self.unsynchronized = unsynchronized
        }
        mutating func byte() throws -> UInt8? {
            while position < end {
                if position < base || position - base >= bytes.count {
                    try Task.checkCancellation()
                    bytes = try input.read(at: position, maximumCount: Int(min(4096, end - position)))
                    base = position
                    guard !bytes.isEmpty else { return nil }
                }
                let byte = bytes[Int(position - base)]; position += 1
                if unsynchronized && afterFF && byte == 0 { afterFF = false; continue }
                afterFF = byte == 0xff
                return byte
            }
            return nil
        }
        mutating func read(upTo count: Int) throws -> [UInt8] {
            var result: [UInt8] = []
            while result.count < count, let byte = try byte() { result.append(byte) }
            return result
        }
        mutating func exact(_ count: Int) throws -> [UInt8] {
            let bytes = try read(upTo: count)
            guard bytes.count == count else { throw Malformed.tag }
            return bytes
        }
        mutating func skip(_ count: Int64) throws {
            guard count >= 0 else { throw Malformed.tag }
            if !unsynchronized {
                guard count <= end - position else { throw Malformed.tag }
                position += count
            } else {
                for _ in 0..<count { guard try byte() != nil else { throw Malformed.tag } }
            }
        }
    }
}
