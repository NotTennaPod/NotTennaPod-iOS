import Foundation

/// A queue position key (PROTOCOL §3.6): the reduced dyadic rational `m / 2^n` with `m` odd and
/// `0 < m/2^n < 1`, written `q1:<n>:<m hex>`. Keys compare numerically, never bytewise.
public struct QueueKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// A sanity bound on key size; an allocation that would exceed it fails.
    public static let maximumExponent = 1_048_576

    public let exponent: Int
    let numerator: ContractBigUInt

    /// Parses the wire form. Rejects even `m`, leading zeros, uppercase hex, values outside (0, 1) and
    /// `n` above 1,048,576.
    public init(wire: String) throws {
        let bytes = Array(wire.utf8)
        guard bytes.starts(with: Array("q1:".utf8)) else { throw Self.malformed(wire) }
        let rest = bytes.dropFirst(3)
        guard let colon = rest.firstIndex(of: UInt8(ascii: ":")) else { throw Self.malformed(wire) }
        let exponentDigits = rest[..<colon]
        let hexDigits = rest[(colon + 1)...]
        guard let first = exponentDigits.first, exponentDigits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              first != UInt8(ascii: "0") || exponentDigits.count == 1 else { throw Self.malformed(wire) }
        guard let leading = hexDigits.first, leading != UInt8(ascii: "0"),
              hexDigits.allSatisfy({ ContractHex.digit($0, uppercase: false) != nil }) else { throw Self.malformed(wire) }
        guard exponentDigits.count <= 7, let exponent = Int(String(decoding: exponentDigits, as: UTF8.self)),
              exponent <= Self.maximumExponent else {
            throw ContractError(.invalidQueueKey, "n above \(Self.maximumExponent) in \(wire)")
        }
        guard hexDigits.count <= (exponent + 3) / 4, let numerator = ContractBigUInt(hex: hexDigits) else {
            throw ContractError(.invalidQueueKey, "value not below 1 in \(wire)")
        }
        guard numerator.isOdd else { throw ContractError(.invalidQueueKey, "m is even in \(wire)") }
        guard numerator.bitWidth <= exponent else { throw ContractError(.invalidQueueKey, "value not below 1 in \(wire)") }
        self.exponent = exponent
        self.numerator = numerator
    }

    /// `m / 2^n`, already reduced and in (0, 1).
    init(exponent: Int, numerator: ContractBigUInt) throws {
        guard numerator.isOdd, numerator.bitWidth <= exponent else {
            throw ContractError(.invalidQueueKey, "not a reduced key in (0, 1)")
        }
        guard exponent <= Self.maximumExponent else { throw ContractError(.invalidQueueKey, "n above \(Self.maximumExponent)") }
        self.exponent = exponent
        self.numerator = numerator
    }

    public static func isValid(_ wire: String) -> Bool { (try? QueueKey(wire: wire)) != nil }

    public var wire: String { "q1:\(exponent):\(numerator.hex)" }
    public var description: String { wire }

    private static func malformed(_ wire: String) -> ContractError {
        ContractError(.invalidQueueKey, "malformed queue key \(wire)")
    }

    public static func < (lhs: QueueKey, rhs: QueueKey) -> Bool { compare(lhs, rhs) < 0 }

    /// −1, 0 or 1 comparing `m1/2^n1` with `m2/2^n2` exactly.
    public static func compare(_ lhs: QueueKey, _ rhs: QueueKey) -> Int {
        // floor(log2(value)) + 1 = bitWidth(m) − n; different magnitudes decide at once.
        let lhsMagnitude = lhs.numerator.bitWidth - lhs.exponent
        let rhsMagnitude = rhs.numerator.bitWidth - rhs.exponent
        if lhsMagnitude != rhsMagnitude { return lhsMagnitude < rhsMagnitude ? -1 : 1 }
        let a = lhs.exponent >= rhs.exponent ? lhs.numerator : lhs.numerator << (rhs.exponent - lhs.exponent)
        let b = lhs.exponent >= rhs.exponent ? rhs.numerator << (lhs.exponent - rhs.exponent) : rhs.numerator
        return a < b ? -1 : (b < a ? 1 : 0)
    }

    /// The key strictly between `low` and `high` (nil: the sentinels 0 and 1) for a position-write ID.
    /// Distinct IDs never give equal keys. Fails when `low >= high` or the key would exceed the bound.
    public static func between(_ low: QueueKey?, _ high: QueueKey?, positionWriteID: UUID) throws -> QueueKey {
        let id = positionWriteID.uuid
        let bytes = [id.0, id.1, id.2, id.3, id.4, id.5, id.6, id.7, id.8, id.9, id.10, id.11, id.12, id.13, id.14, id.15]
        return try between(low, high, positionWriteBytes: bytes)
    }

    /// The same, with the position-write ID as its 16 big-endian bytes.
    public static func between(_ low: QueueKey?, _ high: QueueKey?, positionWriteBytes: [UInt8]) throws -> QueueKey {
        guard positionWriteBytes.count == 16 else { throw ContractError(.invalidValue, "position write ID must be 16 bytes") }
        let lowExponent = low?.exponent ?? 0
        let highExponent = high?.exponent ?? 0
        let base = max(lowExponent, highExponent)
        // L = lowNumerator / 2^base and R = highNumerator / 2^base.
        let lowNumerator = (low?.numerator ?? ContractBigUInt(0)) << (base - lowExponent)
        let highNumerator = (high?.numerator ?? ContractBigUInt(1)) << (base - highExponent)
        guard lowNumerator < highNumerator else { throw ContractError(.invalidRange, "low >= high") }
        let difference = highNumerator - lowNumerator
        // The smallest n >= 1 with D · 2^n > 2^130, that is difference · 2^n > 2^(130 + base).
        let target = ContractBigUInt(1) << (130 + base)
        var n = max(1, 130 + base - difference.bitWidth)
        while n > 1, target < difference << (n - 1) { n -= 1 }
        while !(target < difference << n) { n += 1 }
        // The smallest m > L · 2^n with m ≡ r (mod 2^129), where r = 2U + 1.
        let r = (ContractBigUInt(bytes: positionWriteBytes) << 1) + ContractBigUInt(1)
        let minimum = ((lowNumerator << n) >> base) + ContractBigUInt(1)
        let modulus = ContractBigUInt(1) << 129
        let residue = minimum.lowBits(129)
        let step = residue < r || residue == r ? r - residue : r + modulus - residue
        let numerator = minimum + step
        precondition((numerator << base) < (highNumerator << n), "queue key allocation left its interval")
        guard n <= maximumExponent else {
            throw ContractError(.keyTooLong, "allocation would need n above \(maximumExponent)")
        }
        return try QueueKey(exponent: n, numerator: numerator)
    }
}
