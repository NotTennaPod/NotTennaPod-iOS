public struct GenerativeCoverPattern: Equatable, Sendable {
    /// Source `GenerativePlaceholderImageModelLoader` model prefix: artwork addresses that start with it
    /// are drawn from this pattern instead of being downloaded.
    public static let artworkPrefix = "antennapod_generative_cover:"
    public struct Line: Equatable, Sendable {
        public let x1: Float
        public let y1: Float
        public let x2: Float
        public let y2: Float
        public let width: Float
        public let color: UInt32
        public let tint: UInt32
    }
    public let lines: [Line]

    public init(model: String, width: Int, height: Int) {
        var random = JavaRandom(seed: JavaString.hashCode(model))
        let steps = 4 + random.nextInt(4)
        let slope = Float(width / 4)
        let shadow = Float(width) * 0.01
        let distance = Float(width) / Float(steps - 2)
        let palettes: [UInt32] = [0xff78909c, 0xffff6f00, 0xff388e3c, 0xff00838f, 0xff7b1fa2, 0xffb71c1c, 0xff2196f3]
        let base = palettes[random.nextInt(palettes.count)]
        func grey(_ number: Int) -> UInt32 { 0xff777777 + 0x222222 * UInt32(number) }
        var color = grey(random.nextInt(5))
        let forcedChange = 1 + random.nextInt(steps - 2)
        var result: [Line] = []
        for index in (0..<steps).reversed() {
            let position = (Float(index) - 0.5) * distance
            let change = random.nextFloat() < 0.3 || index == forcedChange
            if change {
                var replacement = color
                while replacement == color { replacement = grey(random.nextInt(5)) }
                color = replacement
                result.append(Line(x1: position + slope + shadow, y1: -slope,
                                   x2: position - slope + shadow, y2: Float(height) + slope,
                                   width: distance, color: 0xff000000, tint: 0))
            }
            result.append(Line(x1: position + slope, y1: -slope, x2: position - slope, y2: Float(height) + slope,
                               width: distance, color: color, tint: base))
        }
        lines = result
    }
}

private struct JavaRandom {
    private var seed: UInt64
    private let mask: UInt64 = (1 << 48) - 1
    init(seed: Int32) { self.seed = (UInt64(bitPattern: Int64(seed)) ^ 0x5deece66d) & ((1 << 48) - 1) }
    mutating func next(_ bits: Int) -> Int32 {
        seed = (seed &* 0x5deece66d &+ 11) & mask
        return Int32(seed >> (48 - bits))
    }
    mutating func nextInt(_ bound: Int) -> Int {
        if bound & (bound - 1) == 0 { return Int((Int64(bound) * Int64(next(31))) >> 31) }
        while true {
            let bits = next(31)
            let value = bits % Int32(bound)
            if bits &- value &+ Int32(bound - 1) >= 0 { return Int(value) }
        }
    }
    mutating func nextFloat() -> Float { Float(next(24)) / Float(1 << 24) }
}
