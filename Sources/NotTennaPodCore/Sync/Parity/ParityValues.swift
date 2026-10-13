import Foundation

// The value functions of the server's values.go: Java number parsing, DurationParser.inMillis,
// DateUtils.parseTimeString and MimeTypeUtils. Java longs and ints wrap and saturate where Java's do. A value can be
// as long as a feed's text: the functions count their steps against the parse's cancellation, when given one.

enum ParityValues {
    // MARK: Java number parsing

    /// Character.digit(char, 10): Unicode decimal digits count, but only in the Basic Multilingual Plane.
    static func javaDigit(_ r: UInt32) -> Int? {
        if r >= 0x30 && r <= 0x39 { return Int(r - 0x30) }
        if r > 0xFFFF || !GoUnicode.isDigit(r) { return nil }
        var v = 0
        var d = r - 1
        while v < 9 && GoUnicode.isDigit(d) {
            v += 1
            d -= 1
        }
        return v
    }

    /// Long.parseLong (radix 10).
    static func javaParseLong(_ s: String, work: ParityCancellation? = nil) throws -> Int64? {
        try javaParseInteger(s, min: .min, max: .max, work: work)
    }

    /// Integer.parseInt (radix 10).
    static func javaParseInt(_ s: String, work: ParityCancellation? = nil) throws -> Int64? {
        try javaParseInteger(s, min: Int64(Int32.min), max: Int64(Int32.max), work: work)
    }

    static func javaParseInteger(_ s: String, min: Int64, max: Int64, work: ParityCancellation? = nil) throws -> Int64? {
        let rs = s.unicodeScalars
        guard let first = rs.first else { return nil }
        var negative = false
        var i = rs.startIndex
        var limit = -max
        if first.value < 0x30 {
            switch first {
            case "-":
                negative = true
                limit = min
            case "+":
                break
            default:
                return nil
            }
            rs.formIndex(after: &i)
            if i == rs.endIndex { return nil }
        }
        // Integer.parseInt's algorithm: accumulate negatively against the limit.
        let multmin = limit / 10
        var result: Int64 = 0
        while i < rs.endIndex {
            try work?.tick()
            guard let d = javaDigit(rs[i].value), result >= multmin else { return nil }
            result *= 10
            if result < limit + Int64(d) { return nil }
            result -= Int64(d)
            rs.formIndex(after: &i)
        }
        return negative ? result : -result
    }

    /// Float.parseFloat: surrounding whitespace trimmed, an optional f/F/d/D suffix, decimal or hexadecimal
    /// significands, "NaN" and "Infinity"; rounded once to a float.
    static func javaParseFloat(_ input: String, work: ParityCancellation? = nil) throws -> Float? {
        var body = Array(try JavaStrings.trim(input, work: work).utf8)[...]
        guard let first = body.first else { return nil }
        var sign: [UInt8] = []
        if first == UInt8(ascii: "+") || first == UInt8(ascii: "-") {
            sign = [first]
            body = body.dropFirst()
        }
        if body.elementsEqual("NaN".utf8) { return .nan }
        if body.elementsEqual("Infinity".utf8) { return sign == [UInt8(ascii: "-")] ? -.infinity : .infinity }
        if let last = body.last, "fFdD".utf8.contains(last) { body = body.dropLast() }
        guard !body.isEmpty else { return nil }
        let hex = body.starts(with: "0x".utf8) || body.starts(with: "0X".utf8)
        var exponentMark = false
        for c in body {
            try work?.tick()
            let lower = c | 0x20
            if lower == UInt8(ascii: "p") { exponentMark = true }
            if c >= 0x30 && c <= 0x39 || c == UInt8(ascii: ".") { continue }
            if hex && (lower == UInt8(ascii: "x") || lower == UInt8(ascii: "p") || c == UInt8(ascii: "+")
                       || c == UInt8(ascii: "-") || lower >= 0x61 && lower <= 0x66) { continue }
            if !hex && (lower == UInt8(ascii: "e") || c == UInt8(ascii: "+") || c == UInt8(ascii: "-")) { continue }
            return nil
        }
        if hex && !exponentMark {
            return nil  // Java requires the binary exponent
        }
        return try goParseFloat32(String(decoding: sign + body, as: UTF8.self), work: work)
    }

    /// strconv.ParseFloat(s, 32), Go 1.27.1's (GoFloat): infinity on overflow, zero on underflow, nil for Go's
    /// syntax errors.
    static func goParseFloat32(_ s: String, work: ParityCancellation? = nil) throws -> Float? {
        let (value, error) = try GoFloat.parseFloat(Array(s.utf8), bitSize: 32, work: work)
        if error == .syntax { return nil }
        return Float(value)  // a float32's value: exact
    }

    /// Java's (long) narrowing of a float: NaN is 0, saturating.
    static func floatToLong(_ f: Float) -> Int64 {
        if f.isNaN { return 0 }
        if Double(f) >= 9.223372036854775807e18 { return .max }
        if Double(f) <= -9.223372036854775808e18 { return .min }
        return Int64(f)
    }

    /// TimeUnit's toMillis: saturating at the long range.
    static func saturatingMul(_ v: Int64, _ by: Int64) -> Int64 {
        if v > Int64.max / by { return .max }
        if v < Int64.min / by { return .min }
        return v * by
    }

    /// String.split(regex) for a single literal separator byte: trailing empty strings are removed. Its steps are
    /// counted.
    static func javaSplit(_ s: String, _ separator: UInt8, work: ParityCancellation? = nil) throws -> [String] {
        var parts: [String] = []
        var start = s.utf8.startIndex
        var i = start
        while i < s.utf8.endIndex {
            try work?.tick()
            if s.utf8[i] == separator {
                parts.append(String(decoding: s.utf8[start..<i], as: UTF8.self))
                start = s.utf8.index(after: i)
            }
            s.utf8.formIndex(after: &i)
        }
        if parts.isEmpty { return [s] }
        parts.append(String(decoding: s.utf8[start...], as: UTF8.self))
        while let last = parts.last, last.isEmpty { parts.removeLast() }
        return parts
    }

    // MARK: DurationParser.inMillis

    static func durationMillis(_ s: String, work: ParityCancellation? = nil) throws -> Int64? {
        let parts = try javaSplit(JavaStrings.trim(s, work: work), UInt8(ascii: ":"), work: work)
        switch parts.count {
        case 1: return try secondsMillis(parts[0], work)
        case 2: return try hmsMillis("0", parts[0], parts[1], work)
        case 3: return try hmsMillis(parts[0], parts[1], parts[2], work)
        default: return nil
        }
    }

    private static func hmsMillis(_ h: String, _ m: String, _ s: String, _ work: ParityCancellation?) throws -> Int64? {
        guard let hv = try javaParseLong(h, work: work), let mv = try javaParseLong(m, work: work),
              let sv = try secondsMillis(s, work) else { return nil }
        return saturatingMul(hv, 3_600_000) &+ saturatingMul(mv, 60_000) &+ sv
    }

    private static func secondsMillis(_ s: String, _ work: ParityCancellation?) throws -> Int64? {
        if s.utf8.contains(UInt8(ascii: ".")) {
            guard let v = try javaParseFloat(s, work: work) else { return nil }
            let fraction = Float(fmod(Double(v), 1))  // float % 1
            return saturatingMul(floatToLong(v), 1000) &+ floatToLong(fraction * 1000)
        }
        guard let v = try javaParseLong(s, work: work) else { return nil }
        return saturatingMul(v, 1000)
    }

    // MARK: DateUtils.parseTimeString ([HH:]MM:SS[.mmm]; a single value gives 0)

    static func parseTimeString(_ s: String, work: ParityCancellation? = nil) throws -> Int64? {
        let parts = try javaSplit(s, UInt8(ascii: ":"), work: work)
        var result: Int64 = 0
        var index = 0
        if parts.count == 3 {
            guard let h = try javaParseInt(parts[index], work: work) else { return nil }
            result &+= h &* 3_600_000
            index += 1
        }
        if parts.count >= 2 {
            guard let m = try javaParseInt(parts[index], work: work) else { return nil }
            result &+= m &* 60_000
            index += 1
            guard let seconds = try javaParseFloat(parts[index], work: work) else { return nil }
            result &+= floatToLong(seconds * 1000)
        }
        return result
    }

    // MARK: MimeTypeUtils

    static let octetStream = "application/octet-stream"
    private static let audioExtensions: Set<[UInt8]> = Set(["3gp", "aac", "amr", "flac", "imy", "m4a", "m4b", "mid", "mkv",
        "mp3", "mp4", "mxmf", "oga", "ogg", "ogx", "opus", "ota", "rtttl", "rtx", "wav", "xmf"].map { Array($0.utf8) })
    private static let videoExtensions: Set<[UInt8]> = Set(["3gp", "mkv", "mp4", "ogg", "ogv", "ogx", "webm"].map { Array($0.utf8) })
    /// MimeTypeMap's extensions, compared by bytes.
    private static let mimeMap: [[UInt8]: String] = Dictionary(AndroidMIMEMap.extensions.map { (Array($0.key.utf8), $0.value) },
                                                               uniquingKeysWith: { a, _ in a })

    static func isMediaFile(_ t: String?) -> Bool {
        guard let t else { return false }
        return GoStrings.hasPrefix(t, "audio/") || GoStrings.hasPrefix(t, "video/") || GoStrings.same(t, "application/ogg")
            || GoStrings.same(t, octetStream)
    }

    static func isImageFile(_ t: String?) -> Bool { t.map { GoStrings.hasPrefix($0, "image/") } ?? false }

    /// MimeTypeUtils.getMimeType. Its steps over the file name are counted.
    static func mimeType(_ t: String?, _ filename: String?, work: ParityCancellation? = nil) throws -> String? {
        if isMediaFile(t), let t, !GoStrings.same(t, octetStream) { return t }
        if let fromURL = try mimeTypeFromURL(filename, work: work), isMediaFile(fromURL) { return fromURL }
        return t
    }

    static func mimeTypeFromURL(_ url: String?, work: ParityCancellation? = nil) throws -> String? {
        guard let url else { return nil }
        let ext = try fileExtension(Array(url.utf8), work: work)
        if let mime = mimeTypeFromExtension(ext) { return mime }
        if audioExtensions.contains(ext) { return "audio/*" }
        if videoExtensions.contains(ext) { return "video/*" }
        return nil
    }

    /// The longest extension in the MIME map. Lower-casing shrinks a character by at most two bytes (KELVIN SIGN, three
    /// bytes, is "k"), so an extension of more than three times as many bytes is in the map under no case, and is
    /// neither lower-cased nor looked up.
    private static let longestExtension = mimeMap.keys.map(\.count).max() ?? 0

    /// MimeTypeMap.getMimeTypeFromExtension (Android's MimeMap: the extension lower-cased).
    static func mimeTypeFromExtension(_ ext: [UInt8]) -> String? {
        guard !ext.isEmpty, ext.count <= 3 * longestExtension else { return nil }
        return mimeMap[Array(GoStrings.toLower(GoStrings.string(ext)).utf8)]
    }

    /// commons-io FilenameUtils.getExtension. Its steps are counted.
    static func fileExtension(_ name: [UInt8], work: ParityCancellation? = nil) throws -> [UInt8] {
        var dot = -1
        var separator = -1
        for (i, c) in name.enumerated() {
            try work?.tick()
            if c == UInt8(ascii: ".") { dot = i } else if c == UInt8(ascii: "/") || c == UInt8(ascii: "\\") { separator = i }
        }
        guard dot >= 0, separator < dot else { return [] }
        return Array(name[(dot + 1)...])
    }
}
