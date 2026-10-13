import CoreGraphics

public struct PlayerSheetTransition: Equatable, Sendable {
    public let miniPlayerAlpha: Double
    public let toolbarAlpha: Double

    public init(expansion: Double) {
        miniPlayerAlpha = 1 - max(0, min(0.2, expansion - 0.2)) / 0.2
        toolbarAlpha = max(0, min(0.2, expansion - 0.6)) / 0.2
    }

    public static func expandsAfterRelease(expansion: Double, velocity: CGSize) -> Bool {
        if velocity.height < 0 { return true }
        if velocity.height == 0 || abs(velocity.width) > abs(velocity.height) { return expansion > 0.5 }
        return false
    }
}
