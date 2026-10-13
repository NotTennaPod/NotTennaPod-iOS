// Go's string and Unicode semantics as the server's parse uses them, over tables generated from the server's own Go
// toolchain (ParityTables.swift), so the port gives the server's answers on any OS version. Go strings are bytes:
// comparisons here are by exact bytes, never by Unicode canonical equivalence as Swift's String `==` would be.

enum GoUnicode {
    /// unicode.Is over a (low, high, stride) table.
    static func `is`(_ table: [UInt32], _ r: UInt32) -> Bool {
        var low = 0
        var high = table.count / 3
        while low < high {
            let middle = (low + high) / 2
            let lo = table[middle * 3]
            if r < lo {
                high = middle
            } else if r > table[middle * 3 + 1] {
                low = middle + 1
            } else {
                return (r - lo) % table[middle * 3 + 2] == 0
            }
        }
        return false
    }

    /// The (low, high) of the range of `table` holding r.
    static func range(_ table: [UInt32], _ r: UInt32) -> (UInt32, UInt32)? {
        var low = 0
        var high = table.count / 3
        while low < high {
            let middle = (low + high) / 2
            let lo = table[middle * 3]
            if r < lo {
                high = middle
            } else if r > table[middle * 3 + 1] {
                low = middle + 1
            } else {
                return (lo, table[middle * 3 + 1])
            }
        }
        return nil
    }

    /// A (code point, mapping) pair table's mapping of r, or r.
    static func mapped(_ pairs: [UInt32], _ r: UInt32) -> UInt32 {
        var low = 0
        var high = pairs.count / 2
        while low < high {
            let middle = (low + high) / 2
            let key = pairs[middle * 2]
            if key == r { return pairs[middle * 2 + 1] }
            if key < r { low = middle + 1 } else { high = middle }
        }
        return r
    }

    static func isDigit(_ r: UInt32) -> Bool {
        if r < 0x80 { return r >= 0x30 && r <= 0x39 }
        return `is`(ParityUnicodeTables.nd, r)
    }

    static func isLetter(_ r: UInt32) -> Bool {
        if r < 0x80 { return (r | 0x20) >= 0x61 && (r | 0x20) <= 0x7A }
        return `is`(ParityUnicodeTables.letter, r)
    }

    /// unicode.IsSpace.
    static func isSpace(_ r: UInt32) -> Bool {
        if r < 0x80 { return r == 0x20 || (r >= 0x09 && r <= 0x0D) }
        return `is`(ParityUnicodeTables.whiteSpace, r)
    }

    static func isUpper(_ r: UInt32) -> Bool { `is`(ParityUnicodeTables.lu, r) }
    static func isLower(_ r: UInt32) -> Bool { `is`(ParityUnicodeTables.ll, r) }
    static func isTitle(_ r: UInt32) -> Bool { `is`(ParityUnicodeTables.lt, r) }

    /// unicode.ToUpper.
    static func toUpper(_ r: UInt32) -> UInt32 {
        if r < 0x80 { return r >= 0x61 && r <= 0x7A ? r - 0x20 : r }
        return mapped(ParityUnicodeTables.upper, r)
    }

    /// unicode.ToLower.
    static func toLower(_ r: UInt32) -> UInt32 {
        if r < 0x80 { return r >= 0x41 && r <= 0x5A ? r + 0x20 : r }
        return mapped(ParityUnicodeTables.lower, r)
    }

    /// The smallest code point of r's simple case folding orbit (unicode.SimpleFold).
    static func foldMin(_ r: UInt32) -> UInt32 { mapped(ParityUnicodeTables.foldMin, r) }

    /// The value of a decimal digit: its offset in its Nd range, modulo ten.
    static func digitValue(_ r: UInt32) -> Int {
        guard let (lo, _) = range(ParityUnicodeTables.nd, r) else { return 0 }
        return Int((r - lo) % 10)
    }
}

// MARK: - Go strings

/// Go's string operations on Swift strings (always valid UTF-8 here) and on raw bytes.
enum GoStrings {
    /// strings.TrimSpace.
    static func trimSpace(_ s: String) -> String { trim(s, GoUnicode.isSpace) }

    /// strings.TrimFunc.
    static func trim(_ s: String, _ drop: (UInt32) -> Bool) -> String { (try? trim(s, drop, work: nil)) ?? s }

    /// strings.TrimFunc, its steps over the trimmed ends counted against the parse's cancellation.
    static func trim(_ s: String, _ drop: (UInt32) -> Bool, work: ParityCancellation?) throws -> String {
        let scalars = s.unicodeScalars
        var first = scalars.startIndex
        while first < scalars.endIndex && drop(scalars[first].value) {
            try work?.tick()
            scalars.formIndex(after: &first)
        }
        if first == scalars.endIndex { return "" }
        var last = scalars.index(before: scalars.endIndex)
        while drop(scalars[last].value) {
            try work?.tick()
            scalars.formIndex(before: &last)
        }
        if first == scalars.startIndex && last == scalars.index(before: scalars.endIndex) { return s }
        return String(scalars[first...last])
    }

    /// strings.ToLower.
    static func toLower(_ s: String) -> String { map(s, GoUnicode.toLower) }

    /// strings.ToUpper.
    static func toUpper(_ s: String) -> String { map(s, GoUnicode.toUpper) }

    static func map(_ s: String, _ f: (UInt32) -> UInt32) -> String {
        var out = String.UnicodeScalarView()
        var changed = false
        for scalar in s.unicodeScalars {
            let value = f(scalar.value)
            if value != scalar.value { changed = true }
            out.append(Unicode.Scalar(value) ?? "\u{FFFD}")
        }
        return changed ? String(out) : s
    }

    /// strings.ToLower on bytes that may not be UTF-8: an invalid byte becomes U+FFFD, as Go maps it.
    static func toLower(bytes: ArraySlice<UInt8>) -> [UInt8] {
        if bytes.allSatisfy({ $0 < 0x80 }) {
            return bytes.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
        }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let (r, n) = decodeRune(bytes, i)
            appendRune(&out, n == 1 && r == 0xFFFD ? 0xFFFD : GoUnicode.toLower(r))
            i += n
        }
        return out
    }

    /// utf8.DecodeRune: the rune at i and its width; (U+FFFD, 1) for an invalid or short sequence.
    static func decodeRune(_ s: ArraySlice<UInt8>, _ i: Int) -> (UInt32, Int) {
        let c = s[i]
        if c < 0x80 { return (UInt32(c), 1) }
        var n = 0
        var lo: UInt8 = 0x80
        var hi: UInt8 = 0xBF
        switch c {
        case 0xC2...0xDF: n = 2
        case 0xE0: n = 3; lo = 0xA0
        case 0xE1...0xEC, 0xEE, 0xEF: n = 3
        case 0xED: n = 3; hi = 0x9F
        case 0xF0: n = 4; lo = 0x90
        case 0xF1...0xF3: n = 4
        case 0xF4: n = 4; hi = 0x8F
        default: return (0xFFFD, 1)
        }
        guard i + n <= s.endIndex else { return (0xFFFD, 1) }
        let b1 = s[i + 1]
        guard b1 >= lo && b1 <= hi else { return (0xFFFD, 1) }
        var r = UInt32(c) & (n == 2 ? 0x1F : n == 3 ? 0x0F : 0x07)
        r = r << 6 | UInt32(b1 & 0x3F)
        for k in 2..<n {
            let b = s[i + k]
            guard b >= 0x80 && b <= 0xBF else { return (0xFFFD, 1) }
            r = r << 6 | UInt32(b & 0x3F)
        }
        return (r, n)
    }

    /// utf8.EncodeRune (an invalid rune is U+FFFD).
    static func appendRune(_ out: inout [UInt8], _ r: UInt32) {
        var r = r
        if r > 0x10FFFF || (r >= 0xD800 && r <= 0xDFFF) { r = 0xFFFD }
        switch r {
        case 0..<0x80:
            out.append(UInt8(r))
        case 0x80..<0x800:
            out.append(UInt8(0xC0 | r >> 6)); out.append(UInt8(0x80 | r & 0x3F))
        case 0x800..<0x10000:
            out.append(UInt8(0xE0 | r >> 12)); out.append(UInt8(0x80 | r >> 6 & 0x3F)); out.append(UInt8(0x80 | r & 0x3F))
        default:
            out.append(UInt8(0xF0 | r >> 18)); out.append(UInt8(0x80 | r >> 12 & 0x3F))
            out.append(UInt8(0x80 | r >> 6 & 0x3F)); out.append(UInt8(0x80 | r & 0x3F))
        }
    }

    /// A Go string's bytes as text the way Go's JSON encoder writes it: each byte that starts no valid UTF-8
    /// sequence is U+FFFD.
    static func string(_ bytes: some Collection<UInt8>) -> String {
        let s = ArraySlice(bytes)
        if let valid = String(validating: s, as: UTF8.self) { return valid }
        var out: [UInt8] = []
        out.reserveCapacity(s.count + 8)
        var i = s.startIndex
        while i < s.endIndex {
            let (r, n) = decodeRune(s, i)
            if n == 1 && r == 0xFFFD { appendRune(&out, 0xFFFD) } else { out.append(contentsOf: s[i..<(i + n)]) }
            i += n
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Byte equality of two strings (Go's ==).
    @inline(__always) static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    /// strings.HasPrefix.
    @inline(__always) static func hasPrefix(_ s: String, _ prefix: String) -> Bool { s.utf8.starts(with: prefix.utf8) }

    /// strings.Contains for an ASCII byte.
    @inline(__always) static func contains(_ s: String, _ byte: UInt8) -> Bool { s.utf8.contains(byte) }
}

/// Java's String helpers the parse uses.
enum JavaStrings {
    /// String.length(): UTF-16 code units.
    @inline(__always) static func length(_ s: String) -> Int { s.utf16.count }

    /// String.trim(): code points up to U+0020 at both ends; its steps are counted.
    static func trim(_ s: String, work: ParityCancellation? = nil) throws -> String {
        try GoStrings.trim(s, { $0 <= 0x20 }, work: work)
    }

    /// \s in Android's ICU regular expressions: [\t\n\f\r\p{Z}].
    static func icuSpace(_ r: UInt32) -> Bool {
        switch r {
        case 0x09, 0x0A, 0x0C, 0x0D: true
        default: r >= 0x80 || r == 0x20 ? GoUnicode.is(ParityUnicodeTables.z, r) : false
        }
    }

    /// SyndStringUtils.trimAllWhitespace: replaceAll("(^\\s*)|(\\s*$)", "") under ICU; its steps are counted.
    static func trimAllWhitespace(_ s: String, work: ParityCancellation? = nil) throws -> String {
        try GoStrings.trim(s, icuSpace, work: work)
    }

    /// String.toLowerCase(Locale.US) as the server ports it: U+0130 to "i̇", then the simple mapping. Its steps are
    /// counted.
    static func lowerUS(_ s: String, work: ParityCancellation? = nil) throws -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            try work?.tick()
            if scalar.value == 0x130 {
                out.append("i"); out.append("\u{307}")
            } else {
                out.append(Unicode.Scalar(GoUnicode.toLower(scalar.value)) ?? "\u{FFFD}")
            }
        }
        return String(out)
    }
}

extension UInt16 {
    /// A UTF-16 code unit of an ASCII character, as UInt8(ascii:) is for bytes.
    @inline(__always) init(ascii scalar: Unicode.Scalar) {
        precondition(scalar.isASCII)
        self = UInt16(scalar.value)
    }
}
