import Foundation

/// Finds where raw ADTS changes its decoder configuration (audio object type,
/// sampling frequency or channel configuration), ahead of AudioFileStream: that
/// parser keeps the first configuration and silently drops every later frame
/// that differs (an inserted ad encoded differently). Bytes arrive in order
/// from a frame boundary or from the start of the file, where ID3v2 tags are
/// skipped; losing frame sync ends detection and leaves the bytes unchanged.
/// A new configuration counts only when the following frame header agrees, so
/// one damaged header is not a segment. Caller-confined; at most one frame and
/// the next header are held back while a change is confirmed, and at most ten
/// bytes while a split header completes.
struct ADTSSegmentScanner {
    struct Key: Equatable, Sendable {
        let profile: UInt8, samplingIndex: UInt8, channels: UInt8
    }
    /// A byte span for the current parser, or the start of a new segment.
    enum Piece: Equatable { case bytes(Data), segment(Key) }
    private(set) var key: Key?
    private(set) var isActive = true
    /// Bytes held back from the next frame boundary (a header split across reads,
    /// or a new configuration awaiting its confirming header); empty otherwise.
    private var held = Data()
    /// Absolute offsets: the next unread byte, and the next frame or tag start.
    private var position: Int64
    private var boundary: Int64

    init(start: Int64) { position = start; boundary = start }

    static func header(_ bytes: Data, at index: Int) -> (key: Key, length: Int)? {
        let base = bytes.startIndex + index
        guard index >= 0, index + 7 <= bytes.count, bytes[base] == 0xff, bytes[base + 1] & 0xf6 == 0xf0 else { return nil }
        let length = Int(bytes[base + 3] & 3) << 11 | Int(bytes[base + 4]) << 3 | Int(bytes[base + 5] >> 5)
        guard length >= (bytes[base + 1] & 1 == 0 ? 9 : 7) else { return nil }
        return (Key(profile: bytes[base + 2] >> 6, samplingIndex: bytes[base + 2] >> 2 & 15,
                    channels: (bytes[base + 2] & 1) << 2 | bytes[base + 3] >> 6), length)
    }

    /// The next bytes of the stream, in order. Returns everything that may be
    /// parsed now, split where confirmed new segments begin. Without a change
    /// the input itself is returned; only held bytes are ever copied.
    mutating func consume(_ bytes: Data, eof: Bool) -> [Piece] {
        let data = held.isEmpty ? bytes : held + bytes
        let base = position - Int64(held.count)
        position += Int64(bytes.count)
        let end = position
        var pieces: [Piece] = [], emitted = base, hold: Int64?
        func slice(_ from: Int64, _ to: Int64) -> Data {
            from == base && to == end ? data : data[(data.startIndex + Int(from - base))..<(data.startIndex + Int(to - base))]
        }
        while isActive, boundary < end {
            let index = Int(boundary - base), first = data.startIndex + index
            // A header (or an ID3 tag header) split across reads waits for its bytes.
            guard index + 10 <= data.count || eof else { hold = boundary; break }
            if index + 3 <= data.count, data[first] == 0x49, data[first + 1] == 0x44, data[first + 2] == 0x33 {
                guard index + 10 <= data.count,
                      let length = PCMRemoteInput.Probe.id3v2TagLength(data[first..<(first + 10)]) else { isActive = false; break }
                boundary += length; continue
            }
            guard let frame = Self.header(data, at: index) else { isActive = false; break }
            guard let current = key, frame.key != current else {
                key = key ?? frame.key; boundary += Int64(frame.length); continue
            }
            let next = index + frame.length
            guard next + 7 <= data.count else {
                if eof { boundary += Int64(frame.length); continue }
                hold = boundary; break
            }
            if Self.header(data, at: next)?.key == frame.key {
                if boundary > emitted { pieces.append(.bytes(slice(emitted, boundary))); emitted = boundary }
                pieces.append(.segment(frame.key)); key = frame.key
            }
            boundary += Int64(frame.length)
        }
        if !isActive { hold = nil }
        let release = hold ?? end
        if release > emitted { pieces.append(.bytes(slice(emitted, release))) }
        held = hold.map { Data(data[(data.startIndex + Int($0 - base))...]) } ?? Data()
        return pieces
    }
}
