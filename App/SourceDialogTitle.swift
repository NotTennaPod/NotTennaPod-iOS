import UIKit

/// Material DialogTitle's retained one-line → smaller two-line fallback.
@MainActor
final class SourceDialogTitle: UILabel {
    private var originalText: String
    private var usesFallback = false

    init(_ text: String) {
        originalText = text
        super.init(frame: .zero)
        textColor = Appearance.foreground
        lineBreakMode = .byTruncatingTail
        accessibilityLabel = text
        // Local trait metrics are applied during the owner's layout, avoiding
        // double scaling by UILabel and process-wide content-size assumptions.
        adjustsFontForContentSizeCategory = false
        updatePresentation()
    }
    required init?(coder: NSCoder) { fatalError() }

    func updateText(_ text: String) {
        guard originalText != text else { return }
        originalText = text
        accessibilityLabel = text
        usesFallback = false
        updatePresentation()
    }

    func measuredSize(width: CGFloat, inheritedTraits: UITraitCollection? = nil) -> CGSize {
        guard width > 0 else { return .zero }
        let metrics = inheritedTraits.map { Appearance.textMetricsTraits(inheriting: $0, through: [self]) } ?? traitCollection
        updatePresentation(metrics: metrics)
        if !usesFallback {
            let singleLineWidth = (text! as NSString).size(withAttributes: [.font: font!]).width
            if singleLineWidth > width {
                usesFallback = true
                updatePresentation(metrics: metrics)
            }
        }
        return super.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    private func updatePresentation(metrics: UITraitCollection? = nil) {
        font = Appearance.font(usesFallback ? 18 : 24, compatibleWith: metrics ?? traitCollection)
        textAlignment = effectiveUserInterfaceLayoutDirection == .rightToLeft ? .right : .left
        numberOfLines = usesFallback ? 2 : 1
        // Android's single-line transformation maps LF to space and CR to FEFF.
        // In multiline mode Android's text renderer ignores CR, while UIKit
        // treats it as a line break; FEFF preserves the intended visible text.
        let displayed = originalText.replacingOccurrences(of: "\r", with: "\u{feff}")
        text = usesFallback ? displayed : displayed.replacingOccurrences(of: "\n", with: " ")
    }
}
