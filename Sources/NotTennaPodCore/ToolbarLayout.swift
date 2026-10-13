import CoreGraphics

/// Material3's outer toolbar, AppCompat's navigation row and overflow item.
/// Round each Android dimension independently before centering its child pixels.
public struct ToolbarLayout: Equatable, Sendable {
    public let navigation: CGRect
    public let title: CGRect
    public let overflow: CGRect
    public let primaryAction: CGRect
    public let secondaryAction: CGRect

    public init(size: CGSize, hasNavigation: Bool, hasOverflow: Bool,
                density: CGFloat = 1, rightToLeft: Bool = false, hasPrimaryAction: Bool = false, hasSecondaryAction: Bool = false) {
        let scale = density.isFinite && density > 0 ? density : 1
        func px(_ value: CGFloat) -> CGFloat { (value * scale).rounded() }
        let width = px(max(0, size.width)), height = px(max(0, size.height))
        let rowHeight = min(px(56), height)
        let rowY = floor((height - rowHeight) / 2)
        let navigationWidth = hasNavigation ? min(px(56), width) : 0
        let overflowWidth = hasOverflow ? min(px(40), max(0, width - navigationWidth)) : 0
        let primaryWidth = hasPrimaryAction ? min(px(48), max(0, width - navigationWidth - overflowWidth)) : 0
        let secondaryWidth = hasSecondaryAction ? min(px(48), max(0, width - navigationWidth - overflowWidth - primaryWidth)) : 0
        let actionHeight = min(px(48), rowHeight)
        let actionWidth = overflowWidth + primaryWidth + secondaryWidth
        let leading = min(width - actionWidth, px(hasNavigation ? 72 : 16))
        let trailing = hasOverflow || hasPrimaryAction || hasSecondaryAction ? actionWidth : min(px(16), max(0, width - leading))
        func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: (rightToLeft ? width - x - w : x) / scale, y: y / scale, width: w / scale, height: h / scale)
        }
        navigation = frame(0, rowY, navigationWidth, rowHeight)
        title = frame(leading, 0, max(0, width - trailing - leading), height)
        overflow = frame(width - overflowWidth, rowY + floor((rowHeight - actionHeight) / 2), overflowWidth, actionHeight)
        primaryAction = frame(width - overflowWidth - primaryWidth, rowY + floor((rowHeight - actionHeight) / 2), primaryWidth, actionHeight)
        secondaryAction = frame(width - actionWidth, rowY + floor((rowHeight - actionHeight) / 2), secondaryWidth, actionHeight)
    }
}
