import Foundation

/// ItemFragment's TOP/ALIGN_FIXED Balloon1.5.3 and popup_bubble_view.
public struct UsageSuggestionLayout: Equatable, Sendable {
    public let card, arrow, message, no, yes: CGRect
    public let cornerRadius: CGFloat
    public init(width: CGFloat, anchorBottom: CGFloat, messageLineHeight: CGFloat, messageFontHeight: CGFloat,
                noTextWidth: CGFloat, yesTextWidth: CGFloat, offerStreaming: Bool,
                rightToLeft: Bool = false, scale: CGFloat = 1) {
        let scale = max(1, scale)
        func dp(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let margin = dp(8), elevation = floor(2 * scale) / scale
        let arrowSize = dp(12), arrowPadding = arrowSize - 1 / scale
        let popupTop = anchorBottom + CGFloat(Int(-12 * scale)) / scale
        let wrapperWidth = max(0, width - 2 * margin)
        let padding = dp(16), buttonHeight = dp(48)
        // Android includes font padding once around the fixed three-line region,
        // rather than adding padding to each line. Round at the device pixel grid.
        let messageHeight = (ceil(messageFontHeight * scale) + 2 * ceil(messageLineHeight * scale)) / scale
        let cardWidth = max(0, wrapperWidth - 2 * elevation)
        card = CGRect(x: margin + elevation, y: popupTop + arrowPadding,
                      width: cardWidth, height: 2 * padding + messageHeight + dp(4) + buttonHeight)
        cornerRadius = 5
        let fraction: CGFloat = (rightToLeft != offerStreaming) ? 0.25 : 0.75
        arrow = CGRect(x: margin + wrapperWidth * fraction - arrowSize / 2,
                       y: popupTop, width: arrowSize, height: arrowSize)
        message = CGRect(x: card.minX + padding, y: card.minY + padding,
                         width: max(0, card.width - 2 * padding), height: messageHeight)
        let yesWidth = max(dp(88), yesTextWidth + 2 * dp(8))
        let noWidth = max(dp(88), noTextWidth + 2 * dp(8))
        let y = message.maxY + dp(4)
        if rightToLeft {
            yes = CGRect(x: message.minX, y: y, width: yesWidth, height: buttonHeight)
            no = CGRect(x: yes.maxX, y: y, width: noWidth, height: buttonHeight)
        } else {
            yes = CGRect(x: message.maxX - yesWidth, y: y, width: yesWidth, height: buttonHeight)
            no = CGRect(x: yes.minX - noWidth, y: y, width: noWidth, height: buttonHeight)
        }
    }

    public static func presentationScale(at fraction: Double) -> Double {
        let t = min(1, max(0, fraction)) - 1
        return 0.5 + 0.5 * (t * t * (3 * t + 2) + 1)
    }
}
