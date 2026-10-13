import CoreGraphics

/// speed_select_dialog.xml and the captured three/four-preset Android sheet.
public struct PlaybackSpeedDialogLayout: Sendable {
    public let sheet: CGRect
    public let heading: CGRect
    public let add: CGRect
    public let decrease: CGRect
    public let slider: CGRect
    public let increase: CGRect
    public let presetsHeading: CGRect
    public let presets: [CGRect]
    public let silence: CGRect
    public let contentHeight: CGFloat
    public init(size: CGSize, topInset: CGFloat, bottomInset: CGFloat, count: Int, addWidth: CGFloat = 77,
                scale: CGFloat = 1, rightToLeft: Bool = false) {
        let width = max(0, size.width), inner = max(0, width - 32)
        let inset = floor(4 * max(1, scale)) / max(1, scale)
        let rowHeight = 48 + 2 * inset
        let rows = (max(0, count) + 2) / 3
        let gridY: CGFloat = 16 + 48 - 8 + 48 + 22 + 8
        contentHeight = gridY + CGFloat(rows) * rowHeight + 48 + 16 + max(0, bottomInset)
        let height = min(max(0, size.height - max(0, topInset)), contentHeight)
        sheet = CGRect(x: 0, y: size.height - height, width: width, height: height)
        func mirror(_ rect: CGRect) -> CGRect {
            rightToLeft ? CGRect(x: width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height) : rect
        }
        let chipWidth = min(inner, max(0, addWidth))
        add = mirror(CGRect(x: width - 16 - chipWidth, y: 16, width: chipWidth, height: 48))
        heading = mirror(CGRect(x: 16, y: 28, width: max(0, inner - chipWidth), height: 22))
        decrease = mirror(CGRect(x: 16, y: 56, width: 48, height: 48))
        increase = mirror(CGRect(x: max(16, width - 64), y: 56, width: 48, height: 48))
        slider = CGRect(x: 64, y: 56, width: max(0, width - 128), height: 48)
        presetsHeading = mirror(CGRect(x: 16, y: 104, width: inner, height: 22))
        presets = (0..<max(0, count)).map { index in
            mirror(CGRect(x: 16 + CGFloat(index % 3) * inner / 3 + inset,
                          y: gridY + CGFloat(index / 3) * rowHeight + inset,
                          width: max(0, inner / 3 - 2 * inset), height: 48))
        }
        silence = CGRect(x: 16, y: gridY + CGFloat(rows) * rowHeight, width: inner, height: 48)
    }
}
