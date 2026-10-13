import CoreGraphics

/// Source-style centered alert with a scrolling body and pinned title/actions.
/// Width uses the current local configuration, independently of body/keyboard height.
public struct SourceDialogLayout: Equatable, Sendable {
    public let panel: CGRect
    public let title: CGRect
    public let body: CGRect
    public let footer: CGRect
    /// AppCompat minimum fractions; Material adds24-point surface insets on each side.
    /// `configurationSize` is the unoccluded local view, never a synthetic scroll extent.
    public static func width(in available: CGRect, configurationSize: CGSize? = nil,
                             desiredContentWidth: CGFloat = 0) -> CGFloat {
        let size = configurationSize ?? available.size
        let short = min(size.width, size.height), long = max(size.width, size.height)
        let portrait = size.width < size.height
        let fraction: CGFloat
        if short >= 720 && long >= 960 { fraction = portrait ? 0.72 : 0.45 }
        else if short >= 480 && long >= 640 { fraction = portrait ? 0.80 : 0.55 }
        else { fraction = portrait ? 0.95 : 0.65 }
        let maximum = max(0, available.width - 48)
        return min(maximum, max(0, floor(available.width * fraction) - 48, desiredContentWidth))
    }

    /// ViewRootImpl first measures a floating dialog at config_prefDialogWidth.
    /// A content request can be smaller; the minimum-width pass is resolved above.
    public static func preferredContentWidth(in available: CGRect, configurationSize: CGSize? = nil) -> CGFloat {
        let size = configurationSize ?? available.size
        let short = min(size.width, size.height), long = max(size.width, size.height)
        let windowWidth: CGFloat = short >= 600 ? 580 : short >= 480 && long >= 640 ? 440 : 320
        return max(0, min(available.width, windowWidth) - 48)
    }
    /// Material1.12: vertical background insets80dp, overridden to24dp in
    /// values-land and values-small. Android classifies square windows as
    /// portrait and a long side below470dp as small. Use the unoccluded local
    /// configuration, independently of safe-area or keyboard reductions.
    public static func verticalBackgroundInset(configurationSize: CGSize) -> CGFloat {
        max(configurationSize.width, configurationSize.height) < 470
            || configurationSize.width > configurationSize.height ? 24 : 80
    }

    /// Material single-choice list: title top inset 18, font box at least 32,
    /// then a 16-point title divider. Unlike message dialogs, the list has no inset.
    /// Android API 36 capture: default-page/06-home-choice/hierarchy.xml.
    public static func singleChoice(available: CGRect, titleTextHeight: CGFloat, rowHeight: CGFloat, count: Int, panelWidth: CGFloat? = nil) -> Self {
        Self(available: available, titleHeight: 18 + max(32, ceil(titleTextHeight)) + 16,
             bodyHeight: max(0, rowHeight) * CGFloat(max(0, count)), panelWidth: panelWidth)
    }
    /// Wrapped choice labels have individual measured heights; the list owns
    /// those row frames and scrolls their complete combined extent.
    public static func singleChoice(available: CGRect, titleTextHeight: CGFloat, rowHeights: [CGFloat],
                                    footerHeight: CGFloat = 76, minimumFooterHeight: CGFloat? = nil, panelWidth: CGFloat? = nil) -> Self {
        Self(available: available, titleHeight: 18 + max(32, ceil(titleTextHeight)) + 16,
             bodyHeight: rowHeights.reduce(0) { $0 + max(0, $1) },
             footerHeight: footerHeight, minimumFooterHeight: minimumFooterHeight, panelWidth: panelWidth)
    }
    /// Material message dialogs share the title divider but add 18 points above
    /// the message only when no title is present. Text measurement belongs to the view.
    public static func message(available: CGRect, titleTextHeight: CGFloat?, textHeight: CGFloat, footerHeight: CGFloat = 76,
                               minimumFooterHeight: CGFloat? = nil, panelWidth: CGFloat? = nil) -> Self {
        Self(available: available, titleHeight: titleTextHeight.map { 18 + max(32, ceil($0)) + 16 } ?? 0,
             bodyHeight: max(48, max(0, textHeight) + (titleTextHeight == nil ? 18 : 0)),
             footerHeight: footerHeight, minimumFooterHeight: minimumFooterHeight, panelWidth: panelWidth)
    }
    /// setView content owns its padding. Without a message/list, Android omits
    /// both the title divider and the titleless message spacer.
    public static func custom(available: CGRect, titleTextHeight: CGFloat?, bodyHeight: CGFloat,
                              footerHeight: CGFloat = 76, minimumFooterHeight: CGFloat? = nil, panelWidth: CGFloat? = nil) -> Self {
        Self(available: available, titleHeight: titleTextHeight.map { 18 + max(32, ceil($0)) } ?? 0,
             bodyHeight: max(48, bodyHeight), footerHeight: footerHeight,
             minimumFooterHeight: minimumFooterHeight, panelWidth: panelWidth)
    }
    public init(available: CGRect, titleHeight: CGFloat, bodyHeight: CGFloat, footerHeight: CGFloat = 76,
                minimumFooterHeight: CGFloat? = nil, panelWidth: CGFloat? = nil) {
        let width = max(0, min(available.width, panelWidth ?? Self.width(in: available)))
        let height = min(max(0, available.height - 48), max(0, titleHeight) + max(0, bodyHeight) + max(0, footerHeight))
        let titleSize = min(height, max(0, titleHeight))
        let requestedFooter = max(0, footerHeight)
        let minimumFooter = min(requestedFooter, max(0, minimumFooterHeight ?? requestedFooter))
        // AlertDialogLayout reserves the resolved button minimum, measures the
        // body in the remaining space, then expands actions with any surplus.
        // Keep all child frames within the panel even when the title exhausts it;
        // meaningful reachability at those extreme sizes needs a separate policy.
        let reservedFooter = min(height - titleSize, minimumFooter)
        let bodySize = min(max(0, bodyHeight), height - titleSize - reservedFooter)
        let footerSize = min(requestedFooter, height - titleSize - bodySize)
        panel = CGRect(x: available.midX - width / 2, y: available.midY - height / 2, width: width, height: height)
        title = CGRect(x: 0, y: 0, width: width, height: titleSize)
        body = CGRect(x: 0, y: titleSize, width: width, height: height - titleSize - footerSize)
        footer = CGRect(x: 0, y: body.maxY, width: width, height: footerSize)
    }
}
