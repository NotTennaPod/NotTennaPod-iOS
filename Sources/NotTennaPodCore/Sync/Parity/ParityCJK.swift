import Foundation

// golang.org/x/text's CJK decoders (EUC-JP, ISO-2022-JP, Shift_JIS, EUC-KR, GBK, GB18030, HZ-GB-2312 and Big5),
// which the server reaches for a feed declaring such a charset, ported with their handling of malformed input. Their
// tables (the WHATWG indexes) are in ParityCJKTables.swift.

enum ParityCJK {
    private static func table16(_ base64: String) -> [UInt16] {
        let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters)!
        return data.withUnsafeBytes { raw in
            (0..<(raw.count / 2)).map { UInt16(raw[2 * $0]) | UInt16(raw[2 * $0 + 1]) << 8 }
        }
    }

    private static func table32(_ base64: String) -> [UInt32] {
        let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters)!
        return data.withUnsafeBytes { raw in
            (0..<(raw.count / 4)).map {
                UInt32(raw[4 * $0]) | UInt32(raw[4 * $0 + 1]) << 8 | UInt32(raw[4 * $0 + 2]) << 16 | UInt32(raw[4 * $0 + 3]) << 24
            }
        }
    }

    private static let jis0208 = table16(ParityCJKTables.jis0208)
    private static let jis0212 = table16(ParityCJKTables.jis0212)
    private static let eucKR = table16(ParityCJKTables.eucKR)
    private static let gbk = table16(ParityCJKTables.gbk)
    private static let gb18030Ranges: [(UInt16, UInt16)] = {
        let flat = table16(ParityCJKTables.gb18030)
        return stride(from: 0, to: flat.count, by: 2).map { (flat[$0], flat[$0 + 1]) }
    }()
    private static let big5 = table32(ParityCJKTables.big5)
    /// Big5's two-rune special cases, E WITH CIRCUMFLEX AND MACRON / CARON (WHATWG).
    private static let big5Pairs: [Int: (UInt32, UInt32)] = [1133: (0xCA, 0x304), 1135: (0xCA, 0x30C),
                                                             1164: (0xEA, 0x304), 1166: (0xEA, 0x30C)]

    /// The decoder's output as UTF-8 (its whole input at once, as transform.Bytes runs it). Its steps are counted
    /// against the parse's cancellation.
    static func decode(_ input: ArraySlice<UInt8>, kind: ParityCharset.Kind, work: ParityCancellation? = nil) throws -> [UInt8]? {
        let src = Array(input)
        var out: [UInt8] = []
        out.reserveCapacity(src.count * 2)
        switch kind {
        case .eucJP: try eucJP(src, &out, work)
        case .iso2022JP: try iso2022JP(src, &out, work)
        case .shiftJIS: try shiftJIS(src, &out, work)
        case .eucKR: try eucKRDecode(src, &out, work)
        case .gbk: try gbkDecode(src, &out, gb18030: false, work)
        case .gb18030: try gbkDecode(src, &out, gb18030: true, work)
        case .hzGB2312: try hz(src, &out, work)
        case .big5: try big5Decode(src, &out, work)
        default: return nil
        }
        return out
    }

    private static func entry(_ table: [UInt16], _ i: Int) -> UInt32? {
        guard i < table.count else { return nil }
        return UInt32(table[i])
    }

    private static func eucJP(_ src: [UInt8], _ out: inout [UInt8], _ work: ParityCancellation?) throws {
        var n = 0
        while n < src.count {
            try work?.tick()
            var r: UInt32 = 0xFFFD
            var size = 1
            let c0 = src[n]
            if c0 < 0x80 {
                r = UInt32(c0)
            } else if c0 == 0x8E {
                if n + 1 < src.count {
                    let c1 = src[n + 1]
                    if c1 < 0xA1 {
                        size = 1
                    } else if c1 > 0xDF {
                        size = c1 == 0xFF ? 1 : 2
                    } else {
                        r = UInt32(c1) + (0xFF61 - 0xA1)
                        size = 2
                    }
                }
            } else if c0 == 0x8F {
                if n + 2 >= src.count {
                    if n + 1 < src.count && 0xA1 <= src[n + 1] && src[n + 1] < 0xFE { size = 2 }
                } else {
                    let c1 = src[n + 1]
                    let c2 = src[n + 2]
                    if c1 < 0xA1 || 0xFE < c1 {
                        size = 1
                    } else if c2 < 0xA1 || 0xFE < c2 {
                        size = 2
                    } else {
                        size = 3
                        if let v = entry(jis0212, Int(c1 - 0xA1) * 94 + Int(c2 - 0xA1)), v != 0 { r = v }
                    }
                }
            } else if 0xA1 <= c0 && c0 <= 0xFE {
                if n + 1 < src.count {
                    let c1 = src[n + 1]
                    if c1 >= 0xA1 && c1 <= 0xFE {
                        size = 2
                        if let v = entry(jis0208, Int(c0 - 0xA1) * 94 + Int(c1 - 0xA1)), v != 0 { r = v }
                    }
                }
            }
            GoStrings.appendRune(&out, r)
            n += size
        }
    }

    private static func shiftJIS(_ src: [UInt8], _ out: inout [UInt8], _ work: ParityCancellation?) throws {
        var n = 0
        while n < src.count {
            try work?.tick()
            var r: UInt32 = 0xFFFD
            var size = 1
            var c0 = src[n]
            if c0 < 0x80 {
                r = UInt32(c0)
            } else if 0xA1 <= c0 && c0 < 0xE0 {
                r = UInt32(c0) + (0xFF61 - 0xA1)
            } else if (0x81 <= c0 && c0 < 0xA0) || (0xE0 <= c0 && c0 < 0xFD) {
                c0 = c0 <= 0x9F ? c0 &- 0x70 : c0 &- 0xB0
                c0 = 2 &* c0 &- 0x21
                if n + 1 < src.count {
                    var c1 = src[n + 1]
                    var lookup = true
                    switch c1 {
                    case ..<0x40: lookup = false  // c1 is ASCII, read again
                    case ..<0x7F:
                        c0 &-= 1
                        c1 -= 0x40
                    case 0x7F: lookup = false
                    case ..<0x9F:
                        c0 &-= 1
                        c1 -= 0x41
                    case ..<0xFD:
                        c1 -= 0x9F
                    default:
                        lookup = false
                        size = 2
                    }
                    if lookup {
                        size = 2
                        if let v = entry(jis0208, Int(c0) * 94 + Int(c1)), v != 0 { r = v }
                    }
                }
            } else if c0 == 0x80 {
                r = 0x80
            }
            GoStrings.appendRune(&out, r)
            n += size
        }
    }

    private static func iso2022JP(_ src: [UInt8], _ out: inout [UInt8], _ work: ParityCancellation?) throws {
        enum State { case ascii, katakana, jis0208, jis0212 }
        var state = State.ascii
        var n = 0
        while n < src.count {
            try work?.tick()
            var r: UInt32 = 0xFFFD
            var size = 1
            let c0 = src[n]
            if c0 >= 0x80 {
                // U+FFFD
            } else if c0 == 0x1B {
                if n + 2 < src.count {
                    let c1 = src[n + 1]
                    let c2 = src[n + 2]
                    if c1 == UInt8(ascii: "$") && (c2 == UInt8(ascii: "@") || c2 == UInt8(ascii: "B")) {
                        state = .jis0208
                        n += 3
                        continue
                    } else if c1 == UInt8(ascii: "$") && c2 == UInt8(ascii: "(") {
                        if n + 3 < src.count && src[n + 3] == UInt8(ascii: "D") {
                            state = .jis0212
                            n += 4
                            continue
                        }
                    } else if c1 == UInt8(ascii: "(") && (c2 == UInt8(ascii: "B") || c2 == UInt8(ascii: "J")) {
                        state = .ascii
                        n += 3
                        continue
                    } else if c1 == UInt8(ascii: "(") && c2 == UInt8(ascii: "I") {
                        state = .katakana
                        n += 3
                        continue
                    }
                }
            } else {
                switch state {
                case .ascii:
                    r = UInt32(c0)
                case .katakana:
                    if c0 >= 0x21 && c0 < 0x60 { r = UInt32(c0) + (0xFF61 - 0x21) }
                case .jis0208, .jis0212:
                    if c0 == 0x0A {
                        state = .ascii
                        r = 0x0A
                    } else if n + 1 < src.count {
                        size = 2
                        let i = Int(c0 &- 0x21) * 94 + Int(src[n + 1] &- 0x21)
                        if let v = entry(state == .jis0208 ? jis0208 : jis0212, i), v != 0 { r = v }
                    }
                }
            }
            GoStrings.appendRune(&out, r)
            n += size
        }
    }

    private static func eucKRDecode(_ src: [UInt8], _ out: inout [UInt8], _ work: ParityCancellation?) throws {
        var n = 0
        while n < src.count {
            try work?.tick()
            var r: UInt32 = 0xFFFD
            var size = 1
            let c0 = src[n]
            if c0 < 0x80 {
                r = UInt32(c0)
            } else if 0x81 <= c0 && c0 < 0xFF, n + 1 < src.count {
                let c1 = src[n + 1]
                size = 2
                var index: Int?
                if c0 < 0xC7 {
                    let base = 178 * Int(c0 - 0x81)
                    switch c1 {
                    case 0x41..<0x5B: index = base + Int(c1) - 0x41
                    case 0x61..<0x7B: index = base + Int(c1) - (0x61 - 26)
                    case 0x81..<0xFF: index = base + Int(c1) - (0x81 - 2 * 26)
                    default: break
                    }
                } else if 0xA1 <= c1 && c1 < 0xFF {
                    index = 178 * (0xC7 - 0x81) + Int(c0 - 0xC7) * 94 + Int(c1 - 0xA1)
                }
                if let index, let v = entry(eucKR, index), v != 0 {
                    r = v
                } else if c1 < 0x80 {
                    size = 1
                }
            }
            GoStrings.appendRune(&out, r)
            n += size
        }
    }

    private static func gbkDecode(_ src: [UInt8], _ out: inout [UInt8], gb18030: Bool, _ work: ParityCancellation?) throws {
        var n = 0
        while n < src.count {
            try work?.tick()
            var r: UInt32 = 0xFFFD
            var size = 1
            let c0 = src[n]
            if c0 < 0x80 {
                r = UInt32(c0)
            } else if c0 == 0x80 {
                r = 0x20AC
            } else if c0 < 0xFF, n + 1 < src.count {
                var c1 = src[n + 1]
                var twoByte = true
                if 0x40 <= c1 && c1 < 0x7F {
                    c1 -= 0x40
                } else if 0x80 <= c1 && c1 < 0xFF {
                    c1 -= 0x41
                } else if gb18030 && 0x30 <= c1 && c1 < 0x40 {
                    twoByte = false
                    if n + 3 < src.count, src[n + 2] >= 0x81 && src[n + 2] < 0xFF, src[n + 3] >= 0x30 && src[n + 3] < 0x3A {
                        size = 4
                        var v = ((Int(c0 - 0x81) * 10 + Int(c1 - 0x30)) * 126 + Int(src[n + 2] - 0x81)) * 10 + Int(src[n + 3] - 0x30)
                        if v < 39420 {
                            var i = 0
                            var j = gb18030Ranges.count
                            while i < j {
                                let h = i + (j - i) / 2
                                if v >= Int(gb18030Ranges[h].0) { i = h + 1 } else { j = h }
                            }
                            let range = gb18030Ranges[i - 1]
                            v += Int(range.1) - Int(range.0)
                            r = UInt32(v)
                        } else {
                            v -= 189_000
                            if v >= 0 && v < 0x100000 {
                                r = UInt32(v + 0x10000)
                            } else {
                                size = 1
                            }
                        }
                    }
                } else {
                    twoByte = false
                }
                if twoByte {
                    size = 2
                    if let v = entry(gbk, Int(c0 - 0x81) * 190 + Int(c1)), v != 0 { r = v }
                }
            }
            GoStrings.appendRune(&out, r)
            n += size
        }
    }

    private static func hz(_ src: [UInt8], _ out: inout [UInt8], _ work: ParityCancellation?) throws {
        var gbState = false
        var n = 0
        while n < src.count {
            try work?.tick()
            var r: UInt32 = 0xFFFD
            var size = 1
            let c0 = src[n]
            if c0 >= 0x80 {
                // U+FFFD
            } else if c0 == UInt8(ascii: "~") && n + 1 < src.count {
                size = 2
                switch src[n + 1] {
                case UInt8(ascii: "{"):
                    gbState = true
                    n += 2
                    continue
                case UInt8(ascii: "}"):
                    gbState = false
                    n += 2
                    continue
                case UInt8(ascii: "~"):
                    out.append(UInt8(ascii: "~"))
                    n += 2
                    continue
                case 0x0A:
                    n += 2
                    continue
                default:
                    break  // U+FFFD for both bytes
                }
            } else if c0 == UInt8(ascii: "~") {
                // A trailing "~": U+FFFD
            } else if !gbState {
                r = UInt32(c0)
            } else if n + 1 < src.count {
                size = 2
                let c1 = src[n + 1]
                if !(c0 < 0x21 || 0x7E <= c0 || c1 < 0x21 || 0x7F <= c1),
                   let v = entry(gbk, Int(c0 - 0x01) * 190 + Int(c1 + 0x3F)), v != 0 {
                    r = v
                } else if c1 > 0x80 {
                    size = 1  // be consistent and always treat non-ASCII as a single error
                }
            }
            GoStrings.appendRune(&out, r)
            n += size
        }
    }

    private static func big5Decode(_ src: [UInt8], _ out: inout [UInt8], _ work: ParityCancellation?) throws {
        var n = 0
        while n < src.count {
            try work?.tick()
            var r: UInt32 = 0xFFFD
            var size = 1
            let c0 = src[n]
            if c0 < 0x80 {
                r = UInt32(c0)
            } else if 0x81 <= c0 && c0 < 0xFF, n + 1 < src.count {
                var c1 = src[n + 1]
                var lookup = true
                if 0x40 <= c1 && c1 < 0x7F {
                    c1 -= 0x40
                } else if 0xA1 <= c1 && c1 < 0xFF {
                    c1 -= 0x62
                } else if c1 < 0x40 {
                    lookup = false
                } else {
                    lookup = false
                    size = 2
                }
                if lookup {
                    size = 2
                    let i = Int(c0 - 0x81) * 157 + Int(c1)
                    if i < big5.count {
                        if let (a, b) = big5Pairs[i] {
                            GoStrings.appendRune(&out, a)
                            GoStrings.appendRune(&out, b)
                            n += size
                            continue
                        }
                        if big5[i] != 0 { r = big5[i] }
                    }
                }
            }
            GoStrings.appendRune(&out, r)
            n += size
        }
    }
}
