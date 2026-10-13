import UIKit

/// AddPodcastTextView: original 24-unit icon, 8-unit drawable gap, 16-unit
/// horizontal / 8-unit vertical padding, BodyMedium text, minimum 48-unit row.
@MainActor
final class AddPodcastEntryButton: UIControl {
    private let label: UILabel
    private let icon: UIImageView

    init(title: String, image: String, identifier: String, action: @escaping () -> Void) {
        label = Appearance.label(title, size: 14)
        icon = UIImageView(image: UIImage(named: image))
        super.init(frame: .zero)
        icon.tintColor = Appearance.foreground
        addSubview(icon); addSubview(label)
        isAccessibilityElement = true; accessibilityTraits = .button
        accessibilityLabel = title; accessibilityIdentifier = identifier
        addAction(UIAction { _ in action() }, for: .touchUpInside)
        updateTypography()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (button: AddPodcastEntryButton, _) in
            button.updateTypography(); button.invalidateIntrinsicContentSize(); button.setNeedsLayout()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateTypography() {
        label.font = Appearance.font(14)
        let paragraph = NSMutableParagraphStyle()
        let scale = label.font.pointSize / 14
        paragraph.minimumLineHeight = 20 * scale; paragraph.maximumLineHeight = 20 * scale
        label.attributedText = NSAttributedString(string: accessibilityLabel ?? "", attributes: [
            .font: label.font as Any, .paragraphStyle: paragraph, .kern: 0.25 * scale
        ])
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let text = label.sizeThatFits(CGSize(width: max(0, size.width - 64), height: .greatestFiniteMagnitude))
        return CGSize(width: size.width, height: max(48, text.height + 16))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        label.textAlignment = rtl ? .right : .left
        let height = label.sizeThatFits(CGSize(width: max(0, bounds.width - 64), height: .greatestFiniteMagnitude)).height
        icon.frame = CGRect(x: rtl ? bounds.width - 40 : 16, y: (bounds.height - 24) / 2, width: 24, height: 24)
        label.frame = CGRect(x: rtl ? 16 : 48, y: (bounds.height - height) / 2, width: max(0, bounds.width - 64), height: height)
    }
    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? Appearance.foreground.withAlphaComponent(0.08) : .clear }
    }
}
