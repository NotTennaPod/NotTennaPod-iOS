import CoreGraphics

public struct MiniPlayerLayout: Equatable, Sendable {
    public let cover: CGRect
    public let text: CGRect
    public let play: CGRect
    public let progress: CGRect
    public let open: CGRect

    public init(width: CGFloat, height: CGFloat = 64, artworkAspectRatio: CGFloat = 1,
                rightToLeft: Bool = false, scale: CGFloat = 1) {
        let scale = max(1, scale)
        func dp(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let width = max(0, width), height = max(0, height)
        let lineHeight = min(height, dp(4))
        let rowHeight = height - lineHeight
        let buttonWidth = min(width, dp(52))
        let coverWidth = min(max(0, width - buttonWidth), dp(96), (rowHeight * max(0, artworkAspectRatio) * scale).rounded() / scale)
        let textStart = min(width - buttonWidth, coverWidth + dp(16))
        func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rightToLeft ? width - x - w : x, y: y, width: w, height: h)
        }
        cover = frame(0, 0, coverWidth, rowHeight)
        text = frame(textStart, 0, max(0, width - buttonWidth - textStart), rowHeight)
        play = frame(width - buttonWidth, 0, buttonWidth, rowHeight)
        progress = CGRect(x: 0, y: rowHeight, width: width, height: lineHeight)
        open = frame(0, 0, width - buttonWidth, rowHeight)
    }
}
