import Foundation
import CoreGraphics

/// feeditem_fragment.xml. Text measurements are supplied by the renderer;
/// dimension rounding follows Android's independently rounded child dimensions.
public struct EpisodeHeaderLayout: Equatable, Sendable {
    public let cover, podcast, title, metadata, primary, secondary, divider: CGRect
    public let subscriptionNotice, noMedia: CGRect
    public let height: CGFloat

    public init(width: CGFloat, podcastHeight: CGFloat, titleHeight: CGFloat, metadataHeight: CGFloat,
                scale: CGFloat = 1, rightToLeft: Bool = false,
                subscriptionNoticeSize: CGSize = .zero, noMediaHeight: CGFloat = 0) {
        let density = max(1, scale)
        func dp(_ value: CGFloat) -> CGFloat { (value * density).rounded() / density }
        func pixels(_ value: CGFloat) -> CGFloat { (value * density).rounded() / density }
        let inset = dp(16), coverSize = dp(56), gap = dp(16)
        let textX = inset + coverSize + gap
        let textWidth = max(0, width - inset - textX)
        let p = pixels(podcastHeight), t = pixels(titleHeight), m = pixels(metadataHeight)
        let topHeight = max(coverSize, p + t + m)
        let actionHeight = max(dp(24) + 2 * dp(12), dp(40) + 2 * dp(4))
        let available = max(0, width - 2 * inset)
        // First weighted child takes integer division; the second gets the remainder.
        let firstWidth = floor(available * density / 2) / density
        func mirror(_ rect: CGRect) -> CGRect {
            rightToLeft ? CGRect(x: width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height) : rect
        }
        cover = mirror(CGRect(x: inset, y: pixels((topHeight - coverSize) / 2), width: coverSize, height: coverSize))
        podcast = mirror(CGRect(x: textX, y: 0, width: textWidth, height: p))
        title = mirror(CGRect(x: textX, y: p, width: textWidth, height: t))
        metadata = mirror(CGRect(x: textX, y: p + t, width: textWidth, height: m))
        primary = mirror(CGRect(x: inset, y: topHeight, width: firstWidth, height: actionHeight))
        secondary = mirror(CGRect(x: inset + firstWidth, y: topHeight, width: available - firstWidth, height: actionHeight))
        var bottom = topHeight + actionHeight
        if subscriptionNoticeSize.height > 0 {
            let noticeWidth = min(available, max(0, pixels(subscriptionNoticeSize.width)))
            subscriptionNotice = CGRect(x: pixels((width - noticeWidth) / 2), y: bottom + dp(8),
                width: noticeWidth, height: pixels(subscriptionNoticeSize.height))
            bottom = subscriptionNotice.maxY + dp(8)
        } else { subscriptionNotice = .zero }
        noMedia = CGRect(x: inset, y: bottom, width: available, height: max(0, pixels(noMediaHeight)))
        divider = CGRect(x: inset, y: noMedia.maxY, width: available, height: dp(1))
        height = divider.maxY
    }
}
