/// Positive-value subset of Util.scaleLargeTimestamp, including its reduced-Double overflow
/// fallback. Exact Int128 division alone would differ from that fallback on very large inputs.
enum MediaTimestampMath {
    static func truncate(_ value: Double) -> Int64 {
        if value >= Double(Int64.max) { return .max }
        if value <= Double(Int64.min) { return .min }
        return Int64(value)
    }

    static func scale(_ value: Int64, by multiplier: Int64, over divisor: Int64) -> Int64 {
        if value == 0 || multiplier == 0 { return 0 }
        if divisor >= multiplier, divisor % multiplier == 0 { return value / (divisor / multiplier) }
        if divisor < multiplier, multiplier % divisor == 0 { return saturatedMultiply(value, multiplier / divisor) }
        if divisor >= value, divisor % value == 0 { return multiplier / (divisor / value) }
        if divisor < value, value % divisor == 0 { return saturatedMultiply(multiplier, value / divisor) }
        let numerator = saturatedMultiply(value, multiplier)
        if numerator != .max { return numerator / divisor }
        let factor = gcd(multiplier, divisor)
        let m = multiplier / factor
        let d = divisor / factor
        let secondFactor = gcd(value, d)
        let v = value / secondFactor
        let reducedDivisor = d / secondFactor
        let reduced = saturatedMultiply(v, m)
        if reduced != .max { return reduced / reducedDivisor }
        return truncate(Double(v) * (Double(m) / Double(reducedDivisor)))
    }

    private static func saturatedMultiply(_ a: Int64, _ b: Int64) -> Int64 {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? .max : value
    }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var x = a
        var y = b
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }
}
