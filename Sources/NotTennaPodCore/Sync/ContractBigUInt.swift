/// A small arbitrary-precision unsigned integer for queue keys: little-endian 64-bit limbs without
/// trailing zero limbs, so zero has no limbs and equal values have equal limbs.
struct ContractBigUInt: Hashable, Comparable, Sendable {
    private(set) var limbs: [UInt64]

    init(_ value: UInt64 = 0) { limbs = value == 0 ? [] : [value] }

    private init(limbs: [UInt64]) {
        self.limbs = limbs
        normalize()
    }

    /// Big-endian bytes.
    init(bytes: [UInt8]) {
        var limbs: [UInt64] = []
        var index = bytes.count
        while index > 0 {
            let start = max(0, index - 8)
            var limb: UInt64 = 0
            for byte in bytes[start..<index] { limb = limb << 8 | UInt64(byte) }
            limbs.append(limb)
            index = start
        }
        self.init(limbs: limbs)
    }

    /// Hex digits (either case); nil for anything else.
    init?(hex: some Collection<UInt8>) {
        var limbs: [UInt64] = []
        var limb: UInt64 = 0
        var shift: UInt64 = 0
        for byte in hex.reversed() {
            guard let digit = ContractHex.digit(byte, uppercase: true) else { return nil }
            limb |= UInt64(digit) << shift
            shift += 4
            if shift == 64 {
                limbs.append(limb)
                limb = 0
                shift = 0
            }
        }
        if shift > 0 { limbs.append(limb) }
        self.init(limbs: limbs)
    }

    private mutating func normalize() {
        while limbs.last == 0 { limbs.removeLast() }
    }

    var isZero: Bool { limbs.isEmpty }
    var isOdd: Bool { (limbs.first ?? 0) & 1 == 1 }

    /// The number of bits needed (Python's `bit_length`).
    var bitWidth: Int {
        guard let last = limbs.last else { return 0 }
        return (limbs.count - 1) * 64 + (64 - last.leadingZeroBitCount)
    }

    /// Lowercase hex without leading zeros ("0" for zero).
    var hex: String {
        guard let last = limbs.last else { return "0" }
        var text = String(last, radix: 16)
        for limb in limbs.dropLast().reversed() {
            let digits = String(limb, radix: 16)
            text += String(repeating: "0", count: 16 - digits.count) + digits
        }
        return text
    }

    static func < (lhs: ContractBigUInt, rhs: ContractBigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count { return lhs.limbs.count < rhs.limbs.count }
        for index in stride(from: lhs.limbs.count - 1, through: 0, by: -1) where lhs.limbs[index] != rhs.limbs[index] {
            return lhs.limbs[index] < rhs.limbs[index]
        }
        return false
    }

    static func << (value: ContractBigUInt, bits: Int) -> ContractBigUInt {
        guard !value.isZero, bits > 0 else { return value }
        let whole = bits / 64
        let partial = bits % 64
        var limbs = [UInt64](repeating: 0, count: whole)
        limbs.reserveCapacity(whole + value.limbs.count + 1)
        if partial == 0 {
            limbs.append(contentsOf: value.limbs)
        } else {
            var carry: UInt64 = 0
            for limb in value.limbs {
                limbs.append(limb << UInt64(partial) | carry)
                carry = limb >> UInt64(64 - partial)
            }
            limbs.append(carry)
        }
        return ContractBigUInt(limbs: limbs)
    }

    static func >> (value: ContractBigUInt, bits: Int) -> ContractBigUInt {
        guard bits > 0 else { return value }
        let whole = bits / 64
        guard whole < value.limbs.count else { return ContractBigUInt() }
        let partial = bits % 64
        let source = Array(value.limbs[whole...])
        guard partial > 0 else { return ContractBigUInt(limbs: source) }
        var limbs = [UInt64](repeating: 0, count: source.count)
        for index in source.indices {
            let high = index + 1 < source.count ? source[index + 1] << UInt64(64 - partial) : 0
            limbs[index] = source[index] >> UInt64(partial) | high
        }
        return ContractBigUInt(limbs: limbs)
    }

    static func + (lhs: ContractBigUInt, rhs: ContractBigUInt) -> ContractBigUInt {
        var limbs: [UInt64] = []
        limbs.reserveCapacity(max(lhs.limbs.count, rhs.limbs.count) + 1)
        var carry = false
        for index in 0..<max(lhs.limbs.count, rhs.limbs.count) {
            let a = index < lhs.limbs.count ? lhs.limbs[index] : 0
            let b = index < rhs.limbs.count ? rhs.limbs[index] : 0
            let (partial, first) = a.addingReportingOverflow(b)
            let (sum, second) = partial.addingReportingOverflow(carry ? 1 : 0)
            limbs.append(sum)
            carry = first || second
        }
        if carry { limbs.append(1) }
        return ContractBigUInt(limbs: limbs)
    }

    /// `lhs − rhs`; the caller ensures `lhs >= rhs`.
    static func - (lhs: ContractBigUInt, rhs: ContractBigUInt) -> ContractBigUInt {
        precondition(!(lhs < rhs), "unsigned subtraction below zero")
        var limbs = lhs.limbs
        var borrow = false
        for index in limbs.indices {
            let b = index < rhs.limbs.count ? rhs.limbs[index] : 0
            let (partial, first) = limbs[index].subtractingReportingOverflow(b)
            let (difference, second) = partial.subtractingReportingOverflow(borrow ? 1 : 0)
            limbs[index] = difference
            borrow = first || second
        }
        return ContractBigUInt(limbs: limbs)
    }

    /// The value modulo 2^bits.
    func lowBits(_ bits: Int) -> ContractBigUInt {
        let whole = bits / 64
        let partial = bits % 64
        guard whole < limbs.count else { return self }
        var low = Array(limbs[..<whole])
        if partial > 0 { low.append(limbs[whole] & (UInt64(1) << UInt64(partial) - 1)) }
        return ContractBigUInt(limbs: low)
    }
}
