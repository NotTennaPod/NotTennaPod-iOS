import CoreGraphics

public struct PlayerSeekLayout: Equatable, Sendable {
    public let track: CGRect
    public let progress: CGRect
    public let thumbCenter: CGPoint

    public init(bounds: CGRect, value: Float, scale: CGFloat = 1) {
        let scale = max(1, scale)
        let padding = min(max(0, bounds.width) / 2, (16 * scale).rounded() / scale)
        track = CGRect(x: bounds.minX + padding, y: bounds.midY - 1.5,
                       width: max(0, bounds.width - padding * 2), height: 3)
        let fraction = CGFloat(Self.quantize(value)) / 500
        progress = CGRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
        thumbCenter = CGPoint(x: progress.maxX, y: bounds.midY)
    }

    public static func quantize(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(500, max(0, value.rounded()))
    }

    public func value(at x: CGFloat) -> Float {
        guard track.width > 0, x.isFinite else { return 0 }
        return Self.quantize(Float((x - track.minX) / track.width) * 500)
    }
}
