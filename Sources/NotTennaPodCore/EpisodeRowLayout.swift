import CoreGraphics

public struct EpisodeRowLayout: Equatable, Sendable {
    public let height: CGFloat
    public let cover: CGRect
    public let dragHandle: CGRect
    public let text: CGRect
    public let action: CGRect

    public init(width: CGFloat, titleHeight: CGFloat, metadataHeight: CGFloat, progressHeight: CGFloat,
                draggable: Bool, showCover: Bool = true, showAction: Bool = true, rightToLeft: Bool = false, scale: CGFloat = 1) {
        let scale = max(1, scale)
        func dp(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let textHeight = max(0, titleHeight) + max(0, metadataHeight) + max(0, progressHeight)
        height = max(showCover ? dp(56) : 0, textHeight, dp(48)) + 2 * (dp(11) + dp(2))
        let coverX = dp(12) + dp(draggable ? 16 : 4)
        let textX = coverX + (showCover ? dp(56) + dp(16) : 0)
        let actionX = max(0, width - (showAction ? dp(12) + dp(48) : 0))
        func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rightToLeft ? width - x - w : x, y: y, width: w, height: h)
        }
        cover = frame(coverX, (height - dp(56)) / 2, showCover ? dp(56) : 0, showCover ? dp(56) : 0)
        dragHandle = frame(dp(12), dp(2), draggable ? dp(12) : 0, height - 2 * dp(2))
        text = frame(textX, (height - textHeight) / 2, max(0, actionX - dp(8) - textX), textHeight)
        action = frame(actionX, (height - dp(48)) / 2, showAction ? min(width, dp(48)) : 0, dp(48))
    }
}
