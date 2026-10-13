import CoreGraphics

/// Keeps ordinary Material allocation unless it would hide an entire readable
/// line or action. Only that starvation case scrolls the complete composition.
public struct SourceMessageViewportLayout: Equatable, Sendable {
    public let panel: CGRect
    public let content: SourceDialogLayout
    public let scrollsWholeContent: Bool

    public init(available: CGRect, titleTextHeight: CGFloat?, bodyHeight: CGFloat, customBody: Bool,
                footerHeight: CGFloat, minimumFooterHeight: CGFloat,
                minimumBodyHeight: CGFloat, minimumActionHeight: CGFloat, panelWidth: CGFloat? = nil) {
        let width = panelWidth ?? SourceDialogLayout.width(in: available)
        func layout(in rect: CGRect) -> SourceDialogLayout {
            if customBody {
                return .custom(available: rect, titleTextHeight: titleTextHeight, bodyHeight: bodyHeight,
                               footerHeight: footerHeight, minimumFooterHeight: minimumFooterHeight, panelWidth: width)
            }
            return .message(available: rect, titleTextHeight: titleTextHeight, textHeight: bodyHeight,
                            footerHeight: footerHeight, minimumFooterHeight: minimumFooterHeight, panelWidth: width)
        }
        let ordinary = layout(in: available)
        // A finite measurement region large enough for every undecorated part
        // plus the source title/body decoration and outer vertical margins.
        var expanded = available
        expanded.size.height = max(0, titleTextHeight ?? 0) + max(0, bodyHeight) + max(0, footerHeight) + 200
        let full = layout(in: expanded)
        self.init(ordinary: ordinary, full: full, minimumBodyHeight: minimumBodyHeight,
                  minimumActionHeight: minimumActionHeight)
    }

    /// Choice lists use their measured rows, without message-only body padding.
    public static func singleChoice(available: CGRect, titleTextHeight: CGFloat, rowHeights: [CGFloat],
                                    footerHeight: CGFloat, minimumFooterHeight: CGFloat,
                                    minimumBodyHeight: CGFloat, minimumActionHeight: CGFloat, panelWidth: CGFloat? = nil) -> Self {
        let width = panelWidth ?? SourceDialogLayout.width(in: available)
        func layout(in rect: CGRect) -> SourceDialogLayout {
            .singleChoice(available: rect, titleTextHeight: titleTextHeight, rowHeights: rowHeights,
                          footerHeight: footerHeight, minimumFooterHeight: minimumFooterHeight, panelWidth: width)
        }
        var expanded = available
        expanded.size.height = max(0, titleTextHeight) + rowHeights.reduce(0) { $0 + max(0, $1) }
            + max(0, footerHeight) + 200
        return Self(ordinary: layout(in: available), full: layout(in: expanded),
                    minimumBodyHeight: minimumBodyHeight, minimumActionHeight: minimumActionHeight)
    }

    private init(ordinary: SourceDialogLayout, full: SourceDialogLayout,
                 minimumBodyHeight: CGFloat, minimumActionHeight: CGFloat) {
        scrollsWholeContent = ordinary.title.height < full.title.height
            || ordinary.body.height < min(full.body.height, max(0, minimumBodyHeight))
            || ordinary.footer.height < min(full.footer.height, max(0, minimumActionHeight))
        panel = ordinary.panel
        content = scrollsWholeContent ? full : ordinary
    }
}
