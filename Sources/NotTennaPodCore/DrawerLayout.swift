import CoreGraphics
import Foundation

/// Android phone DrawerLayout and the sw720dp persistent-sidebar composition.
/// Values are logical layout units; callers supply their window's configuration and insets.
public struct DrawerLayout: Equatable, Sendable {
    public let panel: CGRect
    public let list: CGRect
    public let settings: CGRect
    public let divider: CGRect
    public let contentOrigin: CGFloat
    public let isPersistent: Bool

    public init(size: CGSize, topInset: CGFloat, bottomInset: CGFloat, persistent: Bool,
                rightToLeft: Bool = false, afterConfigurationChange: Bool = false) {
        let width = max(0, size.width), height = max(0, size.height)
        let bottom = min(height, max(0, bottomInset))
        let top = min(height - bottom, max(0, topInset))
        let panelWidth = persistent ? min(300, width) : max(0, afterConfigurationChange
            ? min(width * 0.8, 480, width - 64) : width - 64)
        panel = CGRect(x: rightToLeft ? width - panelWidth : 0, y: 0, width: panelWidth, height: height - bottom)
        let settingsHeight = min(48, panel.height - top)
        settings = CGRect(x: 0, y: panel.height - settingsHeight, width: panelWidth, height: settingsHeight)
        divider = CGRect(x: 0, y: max(top, settings.minY - 1), width: panelWidth, height: min(1, settings.minY - top))
        list = CGRect(x: 0, y: top, width: panelWidth, height: max(0, divider.minY - top))
        isPersistent = persistent
        contentOrigin = persistent && !rightToLeft ? min(width, panelWidth + 1) : 0
    }

    public func row(index: Int) -> CGRect {
        CGRect(x: 8, y: 8 + CGFloat(index) * 48, width: max(0, panel.width - 16), height: 48)
    }

    /// ViewDragHelper filters velocities below 400 dp/s; DrawerLayout uses a strict half
    /// threshold at zero effective velocity. Mirror velocity, not item order, for RTL.
    public static func shouldOpen(fraction: CGFloat, velocity: CGFloat, rightToLeft: Bool = false) -> Bool {
        let directional = rightToLeft ? -velocity : velocity
        if abs(directional) >= 400 { return directional > 0 }
        return fraction > 0.5
    }
    public static func settleDuration(distance: CGFloat, parentWidth: CGFloat, dragRange: CGFloat, velocity: CGFloat) -> Double {
        guard distance != 0, parentWidth > 0, dragRange > 0 else { return 0 }
        let speed = abs(velocity) < 400 ? 0 : abs(velocity)
        let milliseconds: Int
        if speed > 0 {
            let half = Float(parentWidth / 2)
            let ratio = min(1, Float(abs(distance) / parentWidth))
            let influence = half + half * Float(sin(Double((ratio - 0.5) * 0.47123894)))
            milliseconds = 4 * Int((1000 * abs(influence / Float(speed)) + 0.5).rounded(.down))
        } else {
            milliseconds = Int((Float(abs(distance) / dragRange) + 1) * 256)
        }
        return Double(min(600, milliseconds)) / 1000
    }

    public static func animationProgress(_ elapsedFraction: Double) -> Double {
        let t = min(1, max(0, elapsedFraction)) - 1
        return t * t * t * t * t + 1
    }

}
