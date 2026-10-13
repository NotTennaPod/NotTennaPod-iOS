import CoreGraphics

/// AppCompat popup row/content measurements with either an actual overflow
/// button or an explicit content origin for other menu hosts.
public struct EpisodeMenuLayout: Equatable, Sendable {
    public let panel: CGRect
    public let contentSize: CGSize
    public let rows: [CGRect]

    /// The actual AppCompat overflow overlaps its button. Its signed horizontal
    /// offset is not mirrored in RTL; the window clips the result to the display.
    /// Android's same-state phone/tablet captures place its top one raster pixel below
    /// the button top, independently of display density.
    public init(viewport: CGSize, overflowAnchor: CGRect, titleWidths: [CGFloat],
                density: CGFloat = 1, rightToLeft: Bool = false) {
        let scale = density.isFinite && density > 0 ? density : 1
        let content = Self(viewport: viewport, anchorY: overflowAnchor.minY + 1 / scale,
            titleWidths: titleWidths, density: scale, rightToLeft: rightToLeft)
        let availableWidth = (max(0, viewport.width) * scale).rounded()
        let width = (content.panel.width * scale).rounded()
        let edge = ((rightToLeft ? overflowAnchor.minX : overflowAnchor.maxX) * scale).rounded()
        let offset = (4 * scale).rounded(.towardZero)
        let x = min(max(0, edge - offset - (rightToLeft ? 0 : width)), max(0, availableWidth - width))
        panel = CGRect(x: x / scale, y: content.panel.minY,
            width: content.panel.width, height: content.panel.height)
        contentSize = content.contentSize
        rows = content.rows
    }

    public init(viewport: CGSize, anchorY: CGFloat, titleWidths: [CGFloat],
                density: CGFloat = 1, rightToLeft: Bool = false) {
        let scale = density.isFinite && density > 0 ? density : 1
        func px(_ value: CGFloat) -> CGFloat { (value * scale).rounded() }
        let availableWidth = px(max(0, viewport.width))
        // ListPopupWindow reads its signed -4dp offset with
        // getDimensionPixelOffset (truncation), not pixel-size rounding.
        let edge = min((4 * scale).rounded(.towardZero), availableWidth / 2)
        let maxWidth = min(max(0, availableWidth - 2 * edge), max(availableWidth / 2, px(320)))
        let labelWidth = titleWidths.map { ceil(max(0, $0) * scale) }.max() ?? 0
        let width = min(maxWidth, max(px(196), labelWidth + 2 * px(16)))
        let y = min(px(max(0, anchorY)), px(max(0, viewport.height)))
        let contentHeight = px(8) * 2 + px(48) * CGFloat(titleWidths.count)
        panel = CGRect(x: (rightToLeft ? edge : availableWidth - edge - width) / scale,
            y: y / scale, width: width / scale,
            height: min(contentHeight, max(0, px(viewport.height) - y)) / scale)
        contentSize = CGSize(width: width / scale, height: contentHeight / scale)
        let inset = min(px(16), width / 2)
        rows = titleWidths.indices.map { index in
            CGRect(x: inset / scale, y: (px(8) + CGFloat(index) * px(48)) / scale,
                   width: max(0, width - 2 * inset) / scale, height: px(48) / scale)
        }
    }
}
