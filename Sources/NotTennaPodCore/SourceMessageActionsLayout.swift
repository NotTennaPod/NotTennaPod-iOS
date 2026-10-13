import CoreGraphics

/// Material alert action anchors, including the source ButtonBar's narrow-width stack.
public struct SourceMessageActionsLayout: Equatable, Sendable {
    public let positive: CGRect
    public let negative: CGRect?
    public let neutral: CGRect?
    public let height: CGFloat
    public let minimumHeight: CGFloat
    public let stacked: Bool

    /// `stackedHeights`: per button (positive, negative, neutral), the height its title needs when stacked and too long
    /// for one line (it wraps, as an Android button's text does); nil keeps the button one line high.
    public init(width: CGFloat, positiveTextWidth: CGFloat, negativeTextWidth: CGFloat? = nil,
                neutralTextWidth: CGFloat? = nil, rightToLeft: Bool = false, buttonHeight: CGFloat = 48,
                stackedHeights: [CGFloat?] = [nil, nil, nil]) {
        func buttonWidth(_ text: CGFloat) -> CGFloat { max(64, ceil(text) + 24) }
        let p = buttonWidth(positiveTextWidth)
        let n = negativeTextWidth.map(buttonWidth)
        let c = neutralTextWidth.map(buttonWidth)
        let count = 1 + (n == nil ? 0 : 1) + (c == nil ? 0 : 1)
        let isStacked = p + (n ?? 0) + (c ?? 0) + CGFloat(count - 1) * 8 > max(0, width - 48)
        stacked = isStacked
        let buttonHeight = max(48, ceil(buttonHeight))
        let heights = (0..<3).map { index -> CGFloat in
            if index == 1 && n == nil || index == 2 && c == nil { return 0 }
            guard isStacked, index < stackedHeights.count, let wrapped = stackedHeights[index] else { return buttonHeight }
            return max(buttonHeight, ceil(wrapped))
        }
        let total = 28 + (isStacked ? heights.reduce(0, +) : buttonHeight)
        height = total
        // ButtonBarLayout: top padding + first button + next button's actual
        // top padding (6 + 4 inset) + 16dp peek; otherwise include bottom padding.
        minimumHeight = isStacked && count > 1 ? 14 + heights[0] + 10 + 16 : total
        func frame(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat = buttonHeight) -> CGRect {
            let w = min(w, max(0, width - 48))
            let x = min(max(0, width - w), max(0, x))
            return CGRect(x: rightToLeft ? max(0, width - x - w) : x, y: y, width: w, height: h)
        }
        if isStacked {
            positive = frame(x: max(24, width - 24 - p), y: 14, w: p, h: heights[0])
            negative = n.map { frame(x: max(24, width - 24 - $0), y: 14 + heights[0], w: $0, h: heights[1]) }
            neutral = c.map { frame(x: max(24, width - 24 - $0), y: 14 + heights[0] + heights[1], w: $0, h: heights[2]) }
        } else {
            positive = frame(x: width - 24 - p, y: 14, w: p)
            negative = n.map { frame(x: width - 24 - p - 8 - $0, y: 14, w: $0) }
            neutral = c.map { frame(x: 24, y: 14, w: $0) }
        }
    }
}
