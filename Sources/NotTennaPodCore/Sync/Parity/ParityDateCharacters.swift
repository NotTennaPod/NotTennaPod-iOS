// Character classes of the date parser, on Go's Unicode tables (GoUnicode). Text is UTF-16: a high surrogate followed
// by a low one is one code point, any other surrogate stands for itself.

enum DateCharacters {
    /// The code point at t[i] and its length in units.
    @inline(__always) static func rune(_ t: [UInt16], at i: Int) -> (UInt32, Int) {
        let c = UInt32(t[i])
        if c >= 0xD800 && c < 0xDC00 && i + 1 < t.count {
            let d = UInt32(t[i + 1])
            if d >= 0xDC00 && d < 0xE000 { return (0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00), 2) }
        }
        return (c, 1)
    }

    /// The code point ending at t[i - 1] and its length in units (0 at the start).
    static func rune(_ t: [UInt16], before i: Int) -> (UInt32, Int) {
        if i <= 0 { return (0, 0) }
        let c = UInt32(t[i - 1])
        if c >= 0xDC00 && c < 0xE000 && i >= 2 {
            let h = UInt32(t[i - 2])
            if h >= 0xD800 && h < 0xDC00 { return (0x10000 + ((h - 0xD800) << 10) + (c - 0xDC00), 2) }
        }
        return (c, 1)
    }

    /// A decimal digit (Nd) code point, any plane.
    @inline(__always) static func isDigit(_ r: UInt32) -> Bool { GoUnicode.isDigit(r) }

    /// A unit that is a decimal digit by itself: not a surrogate (Java's Character.isDigit on a char).
    static func isUnitDigit(_ c: UInt16) -> Bool {
        (c < 0xD800 || c >= 0xE000) && GoUnicode.isDigit(UInt32(c))
    }

    /// The value of a decimal digit code point.
    @inline(__always) static func digitValue(_ r: UInt32) -> Int {
        r < 0x80 ? Int(r) - 0x30 : GoUnicode.digitValue(r)
    }

    /// A word character of ICU regular expressions (\w).
    static func isWord(_ r: UInt32) -> Bool {
        if r < 0x80 {
            return r == 0x5F || (r >= 0x30 && r <= 0x39) || (r >= 0x61 && r <= 0x7A) || (r >= 0x41 && r <= 0x5A)
        }
        return GoUnicode.isLetter(r) || GoUnicode.is(ParityUnicodeTables.mark, r) || GoUnicode.is(ParityUnicodeTables.nd, r)
            || GoUnicode.is(ParityUnicodeTables.nl, r) || GoUnicode.is(ParityUnicodeTables.pc, r)
            || GoUnicode.is(ParityUnicodeTables.otherAlphabetic, r) || r == 0x200C || r == 0x200D
    }

    /// A code point that word boundaries look through: Mn, Me, Cf or Other_Grapheme_Extend.
    static func isBoundaryTransparent(_ r: UInt32) -> Bool {
        if r < 0x80 { return false }
        return GoUnicode.is(ParityUnicodeTables.mn, r) || GoUnicode.is(ParityUnicodeTables.me, r)
            || GoUnicode.is(ParityUnicodeTables.cf, r) || GoUnicode.is(ParityUnicodeTables.otherGraphemeExtend, r)
    }

    /// A Bidi_Control code point.
    static func isBidiControl(_ r: UInt32) -> Bool { GoUnicode.is(ParityUnicodeTables.bidiControl, r) }

    /// A line terminator of ICU regular expressions.
    @inline(__always) static func isLineTerminator(_ c: UInt16) -> Bool {
        (c >= 0x0A && c <= 0x0D) || c == 0x85 || c == 0x2028 || c == 0x2029
    }

    /// The blanks a field skips: space and tab.
    @inline(__always) static func isBlank(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 }

    /// Two units compared as Java's case-insensitive region match compares them: equal, equal upper cases, or equal
    /// lower cases of the upper cases.
    static func unitsMatchIgnoringCase(_ a: UInt16, _ b: UInt16) -> Bool {
        if a == b { return true }
        let ua = GoUnicode.toUpper(UInt32(a))
        let ub = GoUnicode.toUpper(UInt32(b))
        return ua == ub || GoUnicode.toLower(ua) == GoUnicode.toLower(ub)
    }

    /// The canonical member of r's simple case-fold orbit: two code points fold to each other when their keys are
    /// equal.
    @inline(__always) static func foldKey(_ r: UInt32) -> UInt32 { GoUnicode.foldMin(r) }

    /// Unicode's minus signs that ICU accepts before a number or an exponent.
    static func isMinus(_ r: UInt32) -> Bool {
        switch r {
        case 0x2D, 0xFF0D, 0xFE63, 0x2010, 0x2011, 0x2012, 0x2013, 0x2212, 0x207B, 0x208B, 0x2796: true
        default: false
        }
    }

    /// Unicode's plus signs that ICU accepts before an exponent.
    static func isPlus(_ r: UInt32) -> Bool {
        switch r {
        case 0x2B, 0xFF0B, 0xFB29, 0xFE62, 0x207A, 0x208A, 0x2795: true
        default: false
        }
    }
}
