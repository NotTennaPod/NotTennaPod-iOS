import UIKit

/// Original more_content_list_footer: bottom-anchored 8-point padding,
/// 16-point expand/progress mark and centered text with 8-point side margins.
@MainActor final class FeedPageFooter: UIControl {
    private let label = Appearance.label(Appearance.text("load_next_page_label"), size: 14)
    private let image = UIImageView(image: UIImage(named: "ic_load_more"))
    private let progress = CAShapeLayer()
    var onLoad: (() -> Void)?
    private(set) var isLoading = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Appearance.background
        image.tintColor = Appearance.foreground
        // This control measures and applies the same scaled font itself.
        // UILabel's automatic adjustment can temporarily re-resolve that font
        // using its old inherited traits during a size-category transition.
        label.adjustsFontForContentSizeCategory = false
        label.isUserInteractionEnabled = false; image.isUserInteractionEnabled = false
        addSubview(image); addSubview(label); layer.addSublayer(progress)
        progress.fillColor = UIColor.clear.cgColor; progress.lineWidth = 2
        progress.strokeEnd = 0.75
        isAccessibilityElement = true; accessibilityTraits = .button
        accessibilityIdentifier = "feedNextPage"; accessibilityLabel = label.text
        addAction(UIAction { [weak self] _ in
            guard let self, !isLoading else { return }
            onLoad?()
        }, for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The text's measurement, kept for its width, text size and text: the list asks for the footer's size on every
    /// scroll callback.
    private var measured: (width: CGFloat, category: UIContentSizeCategory, text: String?, size: CGSize)?
    /// Text measurements made (tests).
    private(set) var measurements = 0

    private func textSize(width: CGFloat) -> CGSize {
        let category = traitOverrides.contains(UITraitPreferredContentSizeCategory.self)
            ? traitOverrides.preferredContentSizeCategory : traitCollection.preferredContentSizeCategory
        if let measured, measured.width == width, measured.category == category, measured.text == label.text {
            return measured.size
        }
        label.font = Appearance.font(14, compatibleWith: Appearance.textMetricsTraits(inheriting: traitCollection, through: [self]))
        let size = label.sizeThatFits(CGSize(width: max(1, width - 48), height: .greatestFiniteMagnitude))
        measurements += 1
        measured = (width, category, label.text, size)
        return size
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let text = textSize(width: size.width)
        // Android's small TextView includes font padding in its approximately
        // 20-point line box. Keep that space around the same 14-point glyphs.
        return CGSize(width: size.width, height: max(20 * label.font.pointSize / 14, text.height) + 16)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let text = textSize(width: bounds.width)
        let start = (bounds.width - text.width - 32) / 2
        image.frame = CGRect(x: start, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.frame = CGRect(x: start + 24, y: (bounds.height - text.height) / 2, width: text.width, height: text.height)
        if effectiveUserInterfaceLayoutDirection == .rightToLeft {
            image.frame.origin.x = bounds.width - image.frame.maxX
            label.frame.origin.x = bounds.width - label.frame.maxX
        }
        progress.frame = image.frame
        progress.path = UIBezierPath(ovalIn: CGRect(x: 2, y: 2, width: 12, height: 12)).cgPath
        progress.strokeColor = Appearance.accent.cgColor
    }
    func setLoading(_ loading: Bool) {
        isLoading = loading; isEnabled = !loading
        image.isHidden = loading; progress.isHidden = !loading
        accessibilityTraits = loading ? [.button, .notEnabled] : .button
        guard loading, !UIAccessibility.isReduceMotionEnabled else { progress.removeAllAnimations(); return }
        if progress.animation(forKey: "rotation") == nil {
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = 0; rotation.toValue = Double.pi * 2
            rotation.duration = 1.332; rotation.repeatCount = .infinity
            progress.add(rotation, forKey: "rotation")
        }
    }
}
