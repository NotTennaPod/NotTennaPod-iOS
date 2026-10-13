// Go 1.27.1's strconv.ParseFloat (src/internal/strconv: atof.go, decimal.go, uscale.go and pow10tab.go), which the
// server reads a float32 (values.go's javaParseFloat) and a date number's float64 (dates.go) with, ported line by
// line for both widths: readFloat, whose exponent is read only until it reaches 10,000; the exact fast paths in float
// arithmetic; unrounded scaling; and the slow path's 800-digit decimal, whose decimal point counts only the digits it
// kept. Its answers are Go's bit for bit, also where Go's answer for a literal of more than 800 digits is not the
// value nearest to it. Go's ints and uints are 64-bit and wrap; so does the arithmetic here. Steps over the literal
// are counted against the parse's cancellation.

enum GoFloat {
    /// ParseFloat's errors: ErrSyntax (the value is 0) and ErrRange (the value is ±Inf).
    enum Failure { case syntax, range }

    /// strconv.ParseFloat(s, bitSize): the value, a float32's when bitSize is 32, and Go's error.
    static func parseFloat(_ s: [UInt8], bitSize: Int, work: ParityCancellation? = nil) throws -> (value: Double, error: Failure?) {
        let result: (Double, Int, Failure?)
        if bitSize == 32 {
            let r = try atof32(s, work)
            result = (Double(r.0), r.1, r.2)
        } else {
            result = try atof64(s, work)
        }
        if result.1 != s.count { return (0, .syntax) }
        return (result.0, result.2)
    }

    // MARK: atof.go

    struct FloatInfo {
        let mantbits: Int
        let expbits: Int
        let bias: Int
    }

    static let float32info = FloatInfo(mantbits: 23, expbits: 8, bias: -127)
    static let float64info = FloatInfo(mantbits: 52, expbits: 11, bias: -1023)

    @inline(__always) static func lower(_ c: UInt8) -> UInt8 { c | (UInt8(ascii: "x") - UInt8(ascii: "X")) }

    static func commonPrefixLenIgnoreCase(_ s: ArraySlice<UInt8>, _ prefix: StaticString) -> Int {
        prefix.withUTF8Buffer { p in
            let n = min(p.count, s.count)
            for i in 0..<n {
                var c = s[s.startIndex + i]
                if UInt8(ascii: "A") <= c && c <= UInt8(ascii: "Z") { c += UInt8(ascii: "a") - UInt8(ascii: "A") }
                if c != p[i] { return i }
            }
            return n
        }
    }

    /// math.NaN(): Go's NaN, whose payload is 1.
    static let nan = Double(bitPattern: 0x7FF8_0000_0000_0001)

    /// special: ±inf, ±infinity and nan, case ignored, as a prefix of s.
    static func special(_ s: [UInt8]) -> (f: Double, n: Int, ok: Bool) {
        if s.isEmpty { return (0, 0, false) }
        var sign = 1.0
        var nsign = 0
        var rest = s[...]
        switch s[0] {
        case UInt8(ascii: "+"), UInt8(ascii: "-"):
            if s[0] == UInt8(ascii: "-") { sign = -1 }
            nsign = 1
            rest = s[1...]
            fallthrough
        case UInt8(ascii: "i"), UInt8(ascii: "I"):
            var n = commonPrefixLenIgnoreCase(rest, "infinity")
            // Anything longer than "inf" is ok, but if we don't have "infinity", only consume "inf".
            if 3 < n && n < 8 { n = 3 }
            if n == 3 || n == 8 { return (sign * .infinity, nsign + n, true) }
        case UInt8(ascii: "n"), UInt8(ascii: "N"):
            if commonPrefixLenIgnoreCase(rest, "nan") == 3 { return (nan, 3, true) }
        default:
            break
        }
        return (0, 0, false)
    }

    struct Read {
        var mantissa: UInt64 = 0
        var exp = 0
        var neg = false
        var trunc = false
        var hex = false
        var i = 0
        var ok = false
    }

    /// readFloat: a decimal or hexadecimal mantissa and exponent from the start of s.
    static func readFloat(_ s: [UInt8], _ work: ParityCancellation?) throws -> Read {
        var r = Read()
        var underscores = false
        var i = 0
        if i >= s.count { return r }
        switch s[i] {
        case UInt8(ascii: "+"): i += 1
        case UInt8(ascii: "-"):
            i += 1
            r.neg = true
        default: break
        }
        var base: UInt64 = 10
        var maxMantDigits = 19  // 10^19 fits in uint64
        var expChar = UInt8(ascii: "e")
        if i + 2 < s.count && s[i] == UInt8(ascii: "0") && lower(s[i + 1]) == UInt8(ascii: "x") {
            base = 16
            maxMantDigits = 16  // 16^16 fits in uint64
            i += 2
            expChar = UInt8(ascii: "p")
            r.hex = true
        }
        var sawdot = false
        var sawdigits = false
        var nd = 0
        var ndMant = 0
        var dp = 0
        loop: while i < s.count {
            try work?.tick()
            let c = s[i]
            if c == UInt8(ascii: "_") {
                underscores = true
            } else if c == UInt8(ascii: ".") {
                if sawdot { break loop }
                sawdot = true
                dp = nd
            } else if UInt8(ascii: "0") <= c && c <= UInt8(ascii: "9") {
                sawdigits = true
                if c == UInt8(ascii: "0") && nd == 0 {  // ignore leading zeros
                    dp &-= 1
                } else {
                    nd &+= 1
                    if ndMant < maxMantDigits {
                        r.mantissa = r.mantissa &* base &+ UInt64(c - UInt8(ascii: "0"))
                        ndMant += 1
                    } else if c != UInt8(ascii: "0") {
                        r.trunc = true
                    }
                }
            } else if base == 16 && UInt8(ascii: "a") <= lower(c) && lower(c) <= UInt8(ascii: "f") {
                sawdigits = true
                nd &+= 1
                if ndMant < maxMantDigits {
                    r.mantissa = r.mantissa &* 16 &+ UInt64(lower(c) - UInt8(ascii: "a") + 10)
                    ndMant += 1
                } else {
                    r.trunc = true
                }
            } else {
                break loop
            }
            i += 1
        }
        if !sawdigits { return r }
        if !sawdot { dp = nd }
        if base == 16 {
            dp &*= 4
            ndMant &*= 4
        }
        // An optional exponent moves the decimal point; a very large one is read only until it reaches 10,000.
        if i < s.count && lower(s[i]) == expChar {
            i += 1
            if i >= s.count { return r }
            var esign = 1
            switch s[i] {
            case UInt8(ascii: "+"): i += 1
            case UInt8(ascii: "-"):
                i += 1
                esign = -1
            default: break
            }
            if i >= s.count || s[i] < UInt8(ascii: "0") || s[i] > UInt8(ascii: "9") { return r }
            var e = 0
            while i < s.count && (UInt8(ascii: "0") <= s[i] && s[i] <= UInt8(ascii: "9") || s[i] == UInt8(ascii: "_")) {
                try work?.tick()
                if s[i] == UInt8(ascii: "_") {
                    underscores = true
                } else if e < 10000 {
                    e = e * 10 + Int(s[i]) - Int(UInt8(ascii: "0"))
                }
                i += 1
            }
            dp &+= e &* esign
        } else if base == 16 {
            return r  // Must have exponent.
        }
        if r.mantissa != 0 { r.exp = dp &- ndMant }
        if underscores, !(try underscoreOK(s[..<i], work)) { return r }
        r.i = i  // the bytes consumed (only an accepted read's count is used)
        r.ok = true
        return r
    }

    /// atoi.go's underscoreOK: underscores only between digits (or after a base prefix).
    static func underscoreOK(_ input: ArraySlice<UInt8>, _ work: ParityCancellation?) throws -> Bool {
        var saw = UInt8(ascii: "^")
        var s = input
        if s.count >= 1 && (s.first == UInt8(ascii: "-") || s.first == UInt8(ascii: "+")) { s = s.dropFirst() }
        var hex = false
        var i = s.startIndex
        if s.count >= 2 && s[i] == UInt8(ascii: "0")
            && (lower(s[i + 1]) == UInt8(ascii: "b") || lower(s[i + 1]) == UInt8(ascii: "o") || lower(s[i + 1]) == UInt8(ascii: "x")) {
            i += 2
            saw = UInt8(ascii: "0")  // the base prefix counts as a digit for "underscore as digit separator"
            hex = lower(s[s.startIndex + 1]) == UInt8(ascii: "x")
        }
        while i < s.endIndex {
            try work?.tick()
            let c = s[i]
            i += 1
            if UInt8(ascii: "0") <= c && c <= UInt8(ascii: "9") || hex && UInt8(ascii: "a") <= lower(c) && lower(c) <= UInt8(ascii: "f") {
                saw = UInt8(ascii: "0")
                continue
            }
            if c == UInt8(ascii: "_") {
                if saw != UInt8(ascii: "0") { return false }
                saw = UInt8(ascii: "_")
                continue
            }
            if saw == UInt8(ascii: "_") { return false }
            saw = UInt8(ascii: "!")
        }
        return saw != UInt8(ascii: "_")
    }

    static let float64pow10: [Double] = [1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14,
                                          1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22]
    static let float32pow10: [Float] = [1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10]

    /// atof64exact: mantissa × 10^exp in one float64 multiplication or division, when that is exact.
    static func atof64exact(_ mantissa: UInt64, _ exp: Int, _ neg: Bool) -> Double? {
        if mantissa >> UInt64(float64info.mantbits) != 0 { return nil }
        var f = Double(mantissa)
        if neg { f = -f }
        var exp = exp
        switch true {
        case exp == 0:
            return f  // an integer
        case exp > 0 && exp <= 15 + 22:  // int * 10^k
            // If the exponent is big but the number of digits is not, move a few zeros into the integer part.
            if exp > 22 {
                f *= float64pow10[exp - 22]
                exp = 22
            }
            if f > 1e15 || f < -1e15 { return nil }  // the exponent was really too large
            return f * float64pow10[exp]
        case exp < 0 && exp >= -22:  // int / 10^k
            return f / float64pow10[-exp]
        default:
            return nil
        }
    }

    /// atof32exact: mantissa × 10^exp in one float32 multiplication or division, when that is exact.
    static func atof32exact(_ mantissa: UInt64, _ exp: Int, _ neg: Bool) -> Float? {
        if mantissa >> UInt64(float32info.mantbits) != 0 { return nil }
        var f = Float(mantissa)
        if neg { f = -f }
        var exp = exp
        switch true {
        case exp == 0:
            return f
        case exp > 0 && exp <= 7 + 10:  // int * 10^k
            if exp > 10 {
                f *= float32pow10[exp - 10]
                exp = 10
            }
            if f > 1e7 || f < -1e7 { return nil }
            return f * float32pow10[exp]
        case exp < 0 && exp >= -10:  // int / 10^k
            return f / float32pow10[-exp]
        default:
            return nil
        }
    }

    /// atofHex: a hexadecimal mantissa × 2^exp rounded to the width (to nearest even, truncated bits sticky);
    /// range is ErrRange (infinity).
    static func atofHex(_ flt: FloatInfo, _ m: UInt64, _ e: Int, _ neg: Bool, _ trunc: Bool) -> (value: Double, range: Bool) {
        var mantissa = m
        var exp = e
        let maxExp = (1 << flt.expbits) + flt.bias - 2
        let minExp = flt.bias + 1
        exp &+= flt.mantbits  // mantissa now implicitly divided by 2^mantbits.
        let mantbits = UInt64(flt.mantbits)
        // Shift the mantissa and exponent into the float's range: a leading 1 bit, mantbits more, and two rounding
        // bits, the bottom one sticky.
        while mantissa != 0 && mantissa >> (mantbits + 2) == 0 {
            mantissa <<= 1
            exp &-= 1
        }
        if trunc { mantissa |= 1 }
        while mantissa >> (1 + mantbits + 2) != 0 {
            mantissa = (mantissa >> 1) | (mantissa & 1)
            exp &+= 1
        }
        // If the exponent is too negative, denormalize in hopes of making it representable.
        while mantissa > 1 && exp < minExp - 2 {
            mantissa = (mantissa >> 1) | (mantissa & 1)
            exp &+= 1
        }
        // Round using the two bottom bits.
        var round = mantissa & 3
        mantissa >>= 2
        round |= mantissa & 1  // round to even (round up if mantissa is odd)
        exp &+= 2
        if round == 3 {
            mantissa &+= 1
            if mantissa == 1 << (1 + mantbits) {
                mantissa >>= 1
                exp &+= 1
            }
        }
        if mantissa >> mantbits == 0 { exp = flt.bias }  // denormal or zero
        var range = false
        if exp > maxExp {  // infinity and range error
            mantissa = 1 << mantbits
            exp = maxExp + 1
            range = true
        }
        var bits = mantissa & ((1 << mantbits) - 1)
        bits |= UInt64(truncatingIfNeeded: (exp &- flt.bias) & ((1 << flt.expbits) - 1)) << mantbits
        if neg { bits |= (1 << mantbits) << UInt64(flt.expbits) }
        if flt.expbits == float32info.expbits { return (Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits))), range) }
        return (Double(bitPattern: bits), range)
    }

    static func atof32(_ s: [UInt8], _ work: ParityCancellation?) throws -> (Float, Int, Failure?) {
        let sp = special(s)
        if sp.ok { return (Float(sp.f), sp.n, nil) }
        let r = try readFloat(s, work)
        if !r.ok { return (0, r.i, .syntax) }
        let n = r.i
        let (d, p, neg, trunc) = (r.mantissa, r.exp, r.neg, r.trunc)
        if r.hex {
            let (f, range) = atofHex(float32info, d, p, neg, trunc)
            return (Float(f), n, range ? .range : nil)
        }
        let sign: UInt32 = neg ? 1 << 31 : 0
        if d == 0 { return (Float(bitPattern: sign), n, nil) }
        if p > 40 { return (Float(bitPattern: sign | 0xff << 23), n, .range) }  // overflow to ±Inf
        if p < -70 { return (Float(bitPattern: sign), n, nil) }  // underflow to ±0
        if !trunc, let f = atof32exact(d, p, neg) { return (f, n, nil) }  // exact rounding with one operation
        // Fast unrounded scaling; the only possible error is ErrRange, when the result overflows to ±Inf.
        let (f, range) = parseFloat32(d, p, sign)
        if !trunc { return (f, n, range ? .range : nil) }
        // If digits were truncated from d but d+1 converts to the same value, the digits do not matter.
        let (f1, _) = parseFloat32(d &+ 1, p, sign)
        if f == f1 { return (f, n, range ? .range : nil) }
        // Slow fallback.
        var dec = Decimal()
        if !(try dec.set(s[..<n], work)) { return (0, n, .syntax) }
        let (b, overflow) = dec.floatBits(float32info)
        return (Float(bitPattern: UInt32(truncatingIfNeeded: b)), n, overflow ? .range : nil)
    }

    static func atof64(_ s: [UInt8], _ work: ParityCancellation?) throws -> (Double, Int, Failure?) {
        let sp = special(s)
        if sp.ok { return (sp.f, sp.n, nil) }
        let r = try readFloat(s, work)
        if !r.ok { return (0, r.i, .syntax) }
        let n = r.i
        let (d, p, neg, trunc) = (r.mantissa, r.exp, r.neg, r.trunc)
        if r.hex {
            let (f, range) = atofHex(float64info, d, p, neg, trunc)
            return (f, n, range ? .range : nil)
        }
        let sign: UInt64 = neg ? 1 << 63 : 0
        if d == 0 { return (Double(bitPattern: sign), n, nil) }
        if p > 310 { return (Double(bitPattern: sign | 0x7ff << 52), n, .range) }  // overflow to ±Inf
        if p < -345 { return (Double(bitPattern: sign), n, nil) }  // underflow to ±0
        if !trunc, let f = atof64exact(d, p, neg) { return (f, n, nil) }
        let (f, range) = parseFloat64(d, p, sign)
        if !trunc { return (f, n, range ? .range : nil) }
        let (f1, _) = parseFloat64(d &+ 1, p, sign)
        if f == f1 { return (f, n, range ? .range : nil) }
        var dec = Decimal()
        if !(try dec.set(s[..<n], work)) { return (0, n, .syntax) }
        let (b, overflow) = dec.floatBits(float64info)
        return (Double(bitPattern: b), n, overflow ? .range : nil)
    }

    // MARK: uscale.go

    /// An unrounded value: the integer part above two bits, a half bit and a sticky bit.
    typealias Unrounded = UInt64

    @inline(__always) static func round(_ u: Unrounded) -> UInt64 { (u &+ 1 &+ ((u >> 2) & 1)) >> 2 }

    /// unmin: the least unrounded value that rounds to x.
    @inline(__always) static func unmin(_ x: UInt64) -> Unrounded { (x << 2) &- 2 }

    /// ⌊x × log₂ 10⌋.
    @inline(__always) static func log2Pow10(_ x: Int) -> Int { (x &* 108853) >> 15 }

    struct Scaler {
        var pmHi: UInt64 = 0
        var pmLo: UInt64 = 0
        var s = 0
    }

    static func prescale(_ e: Int, _ p: Int, _ lp: Int) -> Scaler {
        Scaler(pmHi: ParityFloatTables.pow10Hi[p - ParityFloatTables.pow10Min],
               pmLo: ParityFloatTables.pow10Lo[p - ParityFloatTables.pow10Min], s: -(e &+ lp &+ 3))
    }

    /// uscale: unround(x × 2^e × 10^p), for x with its high bit set.
    static func uscale(_ x: UInt64, _ c: Scaler) -> Unrounded {
        let product = x.multipliedFullWidth(by: c.pmHi)
        var hi = product.high
        let mid = product.low
        let s = UInt64(truncatingIfNeeded: c.s & 63)
        if (hi >> s) << s != hi { return (hi >> s) | 1 }
        let mid2 = x.multipliedFullWidth(by: c.pmLo).high
        hi &-= mid < mid2 ? 1 : 0
        return (hi >> s) | (mid &- mid2 > 1 ? 1 : 0)
    }

    /// pack32: m × 2^e for a 24-bit mantissa (its sign bit included); range when it rounds to infinity.
    static func pack32(_ m: UInt32, _ e: Int) -> (Float, Bool) {
        if m & (1 << 23) == 0 { return (Float(bitPattern: m), false) }
        if e >= 0xFF - 150 { return (Float(bitPattern: (m & (1 << 31)) | 0xff << 23), true) }
        return (Float(bitPattern: (m & ~(1 << 23)) | UInt32(truncatingIfNeeded: 150 &+ e) << 23), false)
    }

    static func pack64(_ m: UInt64, _ e: Int) -> (Double, Bool) {
        if m & (1 << 52) == 0 { return (Double(bitPattern: m), false) }
        if e >= 0x7FF - 1075 { return (Double(bitPattern: (m & (1 << 63)) | 0x7ff << 52), true) }
        return (Double(bitPattern: (m & ~(1 << 52)) | UInt64(truncatingIfNeeded: 1075 &+ e) << 52), false)
    }

    /// parseFloat32: d × 10^p rounded to the nearest float32, for d of at most 19 digits.
    static func parseFloat32(_ d: UInt64, _ p: Int, _ sign: UInt32) -> (Float, Bool) {
        let b = 64 - d.leadingZeroBitCount
        let lp = log2Pow10(p)
        var e = min(149, 24 - b - lp)
        let pre = prescale(e - (64 - b), p, lp)
        if pre.s >= 64 { return (Float(bitPattern: sign), false) }
        var u = uscale(d << UInt64(64 - b), pre)
        // if u.round() >= 1<<24 { u = u.rsh(1); e = e - 1 }, branch-free.
        let s: UInt64 = u >= unmin(1 << 24) ? 1 : 0
        u = (u >> s) | (u & 1)
        e -= Int(s)
        return pack32(sign | UInt32(truncatingIfNeeded: round(u)), -e)
    }

    /// parseFloat64: d × 10^p rounded to the nearest float64, for d of at most 19 digits.
    static func parseFloat64(_ d: UInt64, _ p: Int, _ sign: UInt64) -> (Double, Bool) {
        let b = 64 - d.leadingZeroBitCount
        let lp = log2Pow10(p)
        var e = min(1074, 53 - b - lp)
        let pre = prescale(e - (64 - b), p, lp)
        if pre.s >= 64 { return (Double(bitPattern: sign), false) }
        var u = uscale(d << UInt64(64 - b), pre)
        let s: UInt64 = u >= unmin(1 << 53) ? 1 : 0
        u = (u >> s) | (u & 1)
        e -= Int(s)
        return pack64(sign | round(u), -e)
    }

    // MARK: decimal.go

    /// A multiprecision decimal: at most 800 digits, a decimal point, a sign and whether nonzero digits were cut.
    struct Decimal {
        var d = [UInt8](repeating: 0, count: 800)  // digits, big-endian
        var nd = 0  // number of digits used
        var dp = 0  // decimal point
        var neg = false
        var trunc = false  // discarded nonzero digits beyond d[:nd]

        /// decimal.set (atof.go): the literal readFloat accepted. Digits past the 800th are not kept, and the point
        /// is placed by the digits kept.
        mutating func set(_ s: ArraySlice<UInt8>, _ work: ParityCancellation?) throws -> Bool {
            var i = s.startIndex
            neg = false
            trunc = false
            if i >= s.endIndex { return false }
            switch s[i] {
            case UInt8(ascii: "+"): i += 1
            case UInt8(ascii: "-"):
                i += 1
                neg = true
            default: break
            }
            var sawdot = false
            var sawdigits = false
            loop: while i < s.endIndex {
                try work?.tick()
                let c = s[i]
                if c == UInt8(ascii: "_") {
                    // readFloat already checked underscores
                } else if c == UInt8(ascii: ".") {
                    if sawdot { return false }
                    sawdot = true
                    dp = nd
                } else if UInt8(ascii: "0") <= c && c <= UInt8(ascii: "9") {
                    sawdigits = true
                    if c == UInt8(ascii: "0") && nd == 0 {  // ignore leading zeros
                        dp &-= 1
                    } else if nd < d.count {
                        d[nd] = c
                        nd += 1
                    } else if c != UInt8(ascii: "0") {
                        trunc = true
                    }
                } else {
                    break loop
                }
                i += 1
            }
            if !sawdigits { return false }
            if !sawdot { dp = nd }
            if i < s.endIndex && lower(s[i]) == UInt8(ascii: "e") {
                i += 1
                if i >= s.endIndex { return false }
                var esign = 1
                switch s[i] {
                case UInt8(ascii: "+"): i += 1
                case UInt8(ascii: "-"):
                    i += 1
                    esign = -1
                default: break
                }
                if i >= s.endIndex || s[i] < UInt8(ascii: "0") || s[i] > UInt8(ascii: "9") { return false }
                var e = 0
                while i < s.endIndex && (UInt8(ascii: "0") <= s[i] && s[i] <= UInt8(ascii: "9") || s[i] == UInt8(ascii: "_")) {
                    try work?.tick()
                    if s[i] != UInt8(ascii: "_") && e < 10000 { e = e * 10 + Int(s[i]) - Int(UInt8(ascii: "0")) }
                    i += 1
                }
                dp &+= e &* esign
            }
            return i == s.endIndex
        }

        static let powtab = [1, 3, 6, 9, 13, 16, 19, 23, 26]

        /// decimal.floatBits: the float's bits, and whether it overflowed to infinity.
        mutating func floatBits(_ flt: FloatInfo) -> (UInt64, Bool) {
            var exp = 0
            var mant: UInt64 = 0
            var overflow = false
            func assemble() -> UInt64 {
                var bits = mant & ((1 << UInt64(flt.mantbits)) - 1)
                bits |= UInt64(truncatingIfNeeded: (exp &- flt.bias) & ((1 << flt.expbits) - 1)) << UInt64(flt.mantbits)
                if neg { bits |= (1 << UInt64(flt.mantbits)) << UInt64(flt.expbits) }
                return bits
            }
            func infinity() -> (UInt64, Bool) {
                mant = 0
                exp = (1 << flt.expbits) - 1 + flt.bias
                overflow = true
                return (assemble(), overflow)
            }
            if nd == 0 {  // zero is always a special case
                mant = 0
                exp = flt.bias
                return (assemble(), overflow)
            }
            // Obvious overflow or underflow (bounds for 64-bit floats).
            if dp > 310 { return infinity() }
            if dp < -330 {
                mant = 0
                exp = flt.bias
                return (assemble(), overflow)
            }
            // Scale by powers of two until in range [0.5, 1.0).
            exp = 0
            while dp > 0 {
                let n = dp >= Self.powtab.count ? 27 : Self.powtab[dp]
                shift(-n)
                exp += n
            }
            while dp < 0 || dp == 0 && d[0] < UInt8(ascii: "5") {
                let n = -dp >= Self.powtab.count ? 27 : Self.powtab[-dp]
                shift(n)
                exp -= n
            }
            // The range is [0.5, 1) but the float's is [1, 2).
            exp -= 1
            // The least exponent is bias+1; a smaller one is moved up, d adjusted.
            if exp < flt.bias + 1 {
                let n = flt.bias + 1 - exp
                shift(-n)
                exp += n
            }
            if exp - flt.bias >= (1 << flt.expbits) - 1 { return infinity() }
            // Extract 1+mantbits bits.
            shift(1 + flt.mantbits)
            mant = roundedInteger()
            // Rounding might have added a bit; shift down.
            if mant == 2 << UInt64(flt.mantbits) {
                mant >>= 1
                exp += 1
                if exp - flt.bias >= (1 << flt.expbits) - 1 { return infinity() }
            }
            // Denormalized?
            if mant & (1 << UInt64(flt.mantbits)) == 0 { exp = flt.bias }
            return (assemble(), overflow)
        }

        /// The maximum shift that fits a uint in its arithmetic: uintSize - 4.
        static let maxShift = 60

        mutating func trim() {
            while nd > 0 && d[nd - 1] == UInt8(ascii: "0") { nd -= 1 }
            if nd == 0 { dp = 0 }
        }

        /// rightShift: a × 2^-k (k ≤ maxShift).
        mutating func rightShift(_ k: UInt64) {
            var r = 0  // read pointer
            var w = 0  // write pointer
            // Pick up enough leading digits to cover the first shift.
            var n: UInt64 = 0
            while n >> k == 0 {
                if r >= nd {
                    if n == 0 {  // a == 0; should not get here, but handle anyway
                        nd = 0
                        return
                    }
                    while n >> k == 0 {
                        n = n &* 10
                        r += 1
                    }
                    break
                }
                let c = UInt64(d[r])
                n = n &* 10 &+ c &- UInt64(UInt8(ascii: "0"))
                r += 1
            }
            dp -= r - 1
            let mask: UInt64 = (1 << k) &- 1
            // Pick up a digit, put down a digit.
            while r < nd {
                let c = UInt64(d[r])
                let dig = n >> k
                n &= mask
                d[w] = UInt8(truncatingIfNeeded: dig &+ UInt64(UInt8(ascii: "0")))
                w += 1
                n = n &* 10 &+ c &- UInt64(UInt8(ascii: "0"))
                r += 1
            }
            // Put down extra digits.
            while n > 0 {
                let dig = n >> k
                n &= mask
                if w < d.count {
                    d[w] = UInt8(truncatingIfNeeded: dig &+ UInt64(UInt8(ascii: "0")))
                    w += 1
                } else if dig > 0 {
                    trunc = true
                }
                n = n &* 10
            }
            nd = w
            trim()
        }

        /// leftcheats: the digits a shift by i adds, one fewer if the decimal is below the cutoff (5^i).
        static let leftcheatDeltas: [Int] = [0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 6, 6, 6, 7, 7, 7, 7, 8, 8, 8, 9,
                                             9, 9, 10, 10, 10, 10, 11, 11, 11, 12, 12, 12, 13, 13, 13, 13, 14, 14, 14, 15,
                                             15, 15, 16, 16, 16, 16, 17, 17, 17, 18, 18, 18, 19]
        static let leftcheatCutoffs: [[UInt8]] = ([
            "", "5", "25", "125", "625", "3125", "15625", "78125", "390625", "1953125", "9765625", "48828125",
            "244140625", "1220703125", "6103515625", "30517578125", "152587890625", "762939453125", "3814697265625",
            "19073486328125", "95367431640625", "476837158203125", "2384185791015625", "11920928955078125",
            "59604644775390625", "298023223876953125", "1490116119384765625", "7450580596923828125",
            "37252902984619140625", "186264514923095703125", "931322574615478515625", "4656612873077392578125",
            "23283064365386962890625", "116415321826934814453125", "582076609134674072265625",
            "2910383045673370361328125", "14551915228366851806640625", "72759576141834259033203125",
            "363797880709171295166015625", "1818989403545856475830078125", "9094947017729282379150390625",
            "45474735088646411895751953125", "227373675443232059478759765625", "1136868377216160297393798828125",
            "5684341886080801486968994140625", "28421709430404007434844970703125",
            "142108547152020037174224853515625", "710542735760100185871124267578125",
            "3552713678800500929355621337890625", "17763568394002504646778106689453125",
            "88817841970012523233890533447265625", "444089209850062616169452667236328125",
            "2220446049250313080847263336181640625", "11102230246251565404236316680908203125",
            "55511151231257827021181583404541015625", "277555756156289135105907917022705078125",
            "1387778780781445675529539585113525390625", "6938893903907228377647697925567626953125",
            "34694469519536141888238489627838134765625", "173472347597680709441192448139190673828125",
            "867361737988403547205962240695953369140625"
        ] as [String]).map { Array($0.utf8) }

        /// prefixIsLessThan: whether d[:nd] is less than s, as digit strings.
        func prefixIsLessThan(_ s: [UInt8]) -> Bool {
            for i in 0..<s.count {
                if i >= nd { return true }
                if d[i] != s[i] { return d[i] < s[i] }
            }
            return false
        }

        /// leftShift: a × 2^k (k ≤ maxShift).
        mutating func leftShift(_ k: UInt64) {
            var delta = Self.leftcheatDeltas[Int(k)]
            if prefixIsLessThan(Self.leftcheatCutoffs[Int(k)]) { delta -= 1 }
            var r = nd  // read index
            var w = nd + delta  // write index
            // Pick up a digit, put down a digit.
            var n: UInt64 = 0
            r -= 1
            while r >= 0 {
                n &+= (UInt64(d[r]) &- UInt64(UInt8(ascii: "0"))) << k
                let quo = n / 10
                let rem = n &- 10 &* quo
                w -= 1
                if w < d.count {
                    d[w] = UInt8(truncatingIfNeeded: rem &+ UInt64(UInt8(ascii: "0")))
                } else if rem != 0 {
                    trunc = true
                }
                n = quo
                r -= 1
            }
            // Put down extra digits.
            while n > 0 {
                let quo = n / 10
                let rem = n &- 10 &* quo
                w -= 1
                if w < d.count {
                    d[w] = UInt8(truncatingIfNeeded: rem &+ UInt64(UInt8(ascii: "0")))
                } else if rem != 0 {
                    trunc = true
                }
                n = quo
            }
            nd += delta
            if nd >= d.count { nd = d.count }
            dp += delta
            trim()
        }

        /// Shift: a × 2^k, k of either sign.
        mutating func shift(_ k: Int) {
            var k = k
            if nd == 0 { return }  // nothing to do: a == 0
            if k > 0 {
                while k > Self.maxShift {
                    leftShift(UInt64(Self.maxShift))
                    k -= Self.maxShift
                }
                leftShift(UInt64(k))
            } else if k < 0 {
                while k < -Self.maxShift {
                    rightShift(UInt64(Self.maxShift))
                    k += Self.maxShift
                }
                rightShift(UInt64(-k))
            }
        }

        /// shouldRoundUp: whether rounding to nd digits rounds up; exactly halfway rounds to even, or up when
        /// digits were truncated.
        func shouldRoundUp(_ n: Int) -> Bool {
            if n < 0 || n >= nd { return false }
            if d[n] == UInt8(ascii: "5") && n + 1 == nd {  // exactly halfway
                if trunc { return true }
                return n > 0 && (d[n - 1] - UInt8(ascii: "0")) % 2 != 0
            }
            return d[n] >= UInt8(ascii: "5")
        }

        /// RoundedInteger: the integer part, rounded.
        func roundedInteger() -> UInt64 {
            if dp > 20 { return 0xFFFF_FFFF_FFFF_FFFF }
            var i = 0
            var n: UInt64 = 0
            while i < dp && i < nd {
                n = n &* 10 &+ UInt64(d[i] - UInt8(ascii: "0"))
                i += 1
            }
            while i < dp {
                n = n &* 10
                i += 1
            }
            if shouldRoundUp(dp) { n &+= 1 }
            return n
        }
    }
}
