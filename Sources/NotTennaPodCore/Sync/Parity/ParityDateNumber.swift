// Numbers in date fields, read as ICU reads an integer: an optional minus sign (any of Unicode's), then decimal
// digits of any script, or NaN, with ∞ allowed once, and at most one exponent. A plus sign does not start a number.

/// A number read from a date: for a finite one, its significant digits (ASCII, no leading or trailing zeros; empty for
/// zero) times 10^exp.
struct DateNumber {
    enum Kind { case finite, nan, positiveInfinity, negativeInfinity }

    var kind = Kind.finite
    var negative = false
    var digits: ArraySlice<UInt8> = []
    var exp: Int64 = 0

    /// The number as a 32-bit field value: an exact integer that fits in 64 bits gives its low 32 bits; anything else
    /// is truncated toward zero and saturates; NaN is 0.
    var int32: Int32 {
        switch kind {
        case .nan: return 0
        case .positiveInfinity: return .max
        case .negativeInfinity: return .min
        case .finite: break
        }
        if digits.isEmpty { return 0 }
        if exp >= 0 && Int64(digits.count) + exp <= 19 {
            var v: UInt64 = 0
            for d in digits { v = v &* 10 &+ UInt64(d - 0x30) }
            for _ in 0..<exp { v = v &* 10 }
            if !negative && v <= UInt64(Int64.max) { return Int32(truncatingIfNeeded: v) }
            if negative && v <= 1 << 63 { return Int32(truncatingIfNeeded: 0 &- v) }
        }
        return Self.saturate(double)
    }

    /// The number's double value. The digits and exponent go through Go's strconv.ParseFloat, which reads exponents
    /// only up to 10,000.
    var double: Double {
        switch kind {
        case .nan: return .nan
        case .positiveInfinity: return .infinity
        case .negativeInfinity: return -.infinity
        case .finite: break
        }
        var v = 0.0
        if !digits.isEmpty {
            let m = Int64(digits.count) + exp
            if m > 400 {
                v = .infinity
            } else if m >= -400 {
                // ParseFloat throws only through a cancellation, and none is given.
                v = (try? GoFloat.parseFloat(Array(digits) + [0x65] + Array(String(exp).utf8), bitSize: 64).value) ?? 0
            }
        }
        return negative ? -v : v
    }

    /// The milliseconds of an S field whose number is width units long: the value over 10^width, times 1000.
    func fraction(width: Int) -> Int32 {
        Self.saturate(double / Self.pow10(width) * 1000)
    }

    /// Truncates toward zero into 32 bits, saturating; NaN is 0.
    static func saturate(_ x: Double) -> Int32 {
        if x.isNaN { return 0 }
        if x >= Double(Int32.max) { return .max }
        if x <= Double(Int32.min) { return .min }
        return Int32(x)
    }

    private static let pow10Small: [Double] = [1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13,
                                               1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22, 1e23, 1e24, 1e25,
                                               1e26, 1e27, 1e28, 1e29, 1e30, 1e31]
    private static let pow10Large: [Double] = [1e0, 1e32, 1e64, 1e96, 1e128, 1e160, 1e192, 1e224, 1e256, 1e288]

    /// 10^n for n ≥ 0 as Go's math.Pow10 computes it: the product of two correctly rounded powers of ten.
    static func pow10(_ n: Int) -> Double {
        n <= 308 ? pow10Large[n / 32] * pow10Small[n % 32] : .infinity
    }
}

extension DateParser {
    /// Reads a number at t[at...]: the number and where it ends, or nil when none is there.
    func readNumber(_ t: [UInt16], at: Int) throws -> (DateNumber, Int)? {
        var negative = false, seen = false, nan = false, infinite = false, hasExp = false
        var expNegative = false, expHuge = false
        var expValue: Int64 = 0
        var digits: [UInt8] = []
        var i = at
        scan: while i < t.count {
            let (r, size) = DateCharacters.rune(t, at: i)
            if !seen && !negative && DateCharacters.isMinus(r) {
                negative = true
                i += size
            } else if !seen && Self.foldsToNaN(t, at: i) {
                nan = true
                seen = true
                i += 3
            } else if !seen && DateCharacters.isDigit(r) {
                while i < t.count {
                    let (r, size) = DateCharacters.rune(t, at: i)
                    if !DateCharacters.isDigit(r) { break }
                    try work.step()
                    digits.append(UInt8(0x30 + DateCharacters.digitValue(r)))
                    i += size
                }
                seen = true
            } else if !infinite && r == 0x221E {
                infinite = true
                seen = true
                i += size
            } else if seen && !hasExp && (r == 0x45 || r == 0x65) {
                guard let e = try readExponent(t, at: i + size) else { break scan }
                hasExp = true
                expNegative = e.negative
                expValue = e.value
                expHuge = e.huge
                i = e.end
            } else {
                break scan
            }
        }
        guard seen else { return nil }
        var n = DateNumber(negative: negative)
        if nan {
            n.kind = .nan
            return (n, i)
        }
        if infinite {
            n.kind = negative ? .negativeInfinity : .positiveInfinity
            return (n, i)
        }
        var lead = 0
        while lead < digits.count && digits[lead] == 0x30 { lead += 1 }
        var trail = digits.count
        while trail > lead && digits[trail - 1] == 0x30 { trail -= 1 }
        n.digits = digits[lead..<trail]
        n.exp = Int64(digits.count - trail)
        guard hasExp else { return (n, i) }
        var overflow = expHuge
        if !overflow && !n.digits.isEmpty {
            let k = expNegative ? n.exp - expValue : n.exp + expValue
            overflow = k < Int64(Int32.min) || k > Int64(Int32.max) || k + Int64(n.digits.count) > Int64(Int32.max)
            n.exp = k
        }
        if overflow {
            // Too large an exponent: zero when negative, else an infinity.
            n.digits = []
            n.exp = 0
            if !expNegative { n.kind = negative ? .negativeInfinity : .positiveInfinity }
        }
        return (n, i)
    }

    /// Reads an exponent's rest after its E: an optional bidi control, an optional sign, an optional bidi control and
    /// at least one decimal digit. huge reports a value of more than ten digits or above 2,147,483,647.
    private func readExponent(_ t: [UInt16], at start: Int) throws -> (end: Int, negative: Bool, value: Int64, huge: Bool)? {
        var i = start
        func optional(_ accepts: (UInt32) -> Bool) -> UInt32? {
            guard i < t.count else { return nil }
            let (r, size) = DateCharacters.rune(t, at: i)
            guard accepts(r) else { return nil }
            i += size
            return r
        }
        _ = optional(DateCharacters.isBidiControl)
        let sign = optional { DateCharacters.isMinus($0) || DateCharacters.isPlus($0) }
        let negative = sign.map(DateCharacters.isMinus) ?? false
        _ = optional(DateCharacters.isBidiControl)
        var value: Int64 = 0
        var count = 0
        var significant = 0
        while i < t.count {
            let (r, size) = DateCharacters.rune(t, at: i)
            if !DateCharacters.isDigit(r) { break }
            try work.step()
            let d = Int64(DateCharacters.digitValue(r))
            if significant > 0 || d != 0 {
                significant += 1
                if significant <= 10 { value = value * 10 + d }
            }
            count += 1
            i += size
        }
        guard count > 0 else { return nil }
        return (i, negative, value, significant > 10 || value > Int64(Int32.max))
    }

    private static let nanKeys = Array("NaN".unicodeScalars).map { DateCharacters.foldKey($0.value) }

    /// Whether "NaN" is at t[at...], each unit fold-equal to its letter.
    private static func foldsToNaN(_ t: [UInt16], at: Int) -> Bool {
        guard t.count - at >= 3 else { return false }
        for k in 0..<3 where DateCharacters.foldKey(UInt32(t[at + k])) != nanKeys[k] { return false }
        return true
    }
}
