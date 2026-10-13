import Foundation

/// `PieChartView.PieChartData`: a share gets a slice and a palette colour only above 4 %.
public struct StatisticsPieShares: Equatable, Sendable {
    public static let palette: [UInt32] = [0x3775e6, 0xe51c23, 0xff9800, 0x259b24, 0x9c27b0, 0x0099c6, 0xdd4477,
                                           0x66aa00, 0xb82e2e, 0x316395, 0x994499, 0x22aa99, 0xaaaa11, 0x6633cc, 0x0073e6]
    /// `Color.GRAY`.
    public static let gray: UInt32 = 0x888888
    public let values: [Float]
    public let sum: Float

    public init(values: [Float]) { self.values = values; sum = values.reduce(0, +) }

    public func fraction(_ index: Int) -> Float { sum == 0 ? 0 : values[index] / sum }
    public func isLargeEnoughToDisplay(_ index: Int) -> Bool { Double(fraction(index)) > 0.04 }
    /// Palette index of a row's chip and slice, or nil for grey.
    public func paletteIndex(_ index: Int) -> Int? { isLargeEnoughToDisplay(index) ? index % Self.palette.count : nil }
    public func color(_ index: Int) -> UInt32 { paletteIndex(index).map { Self.palette[$0] } ?? Self.gray }
}
