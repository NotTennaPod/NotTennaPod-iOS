import UIKit

/// ItemFragment's nonSubscribedWarningLabel and bg_message_info.xml.
@MainActor
final class EpisodeSubscriptionNotice: UIControl {
    private let label = Appearance.label(Appearance.text("state_deleted_not_subscribed"), size: 14)

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(label)
        label.textColor = Appearance.accent
        label.isAccessibilityElement = false
        isAccessibilityElement = true
        accessibilityIdentifier = "episodeSubscriptionNotice"
        accessibilityLabel = label.text
        accessibilityTraits = .button
        layer.cornerRadius = 8
        layer.borderWidth = 2
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: EpisodeSubscriptionNotice, _: UITraitCollection) in
            view.updateColors()
        }
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func dp(_ value: CGFloat) -> CGFloat {
        let scale = max(1, traitCollection.displayScale)
        return (value * scale).rounded() / scale
    }
    private func updateColors() {
        // Fixed source themes use the same accent for colorPrimary and colorAccent.
        backgroundColor = Appearance.accent.withAlphaComponent(0.1)
        layer.borderColor = Appearance.accent.resolvedColor(with: traitCollection).cgColor
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let padding = dp(16)
        // Android wrap_content first caps the unwrapped desired width, then wraps
        // at that width. Shrinking to the longest wrapped line changes the box.
        let desired = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).width
        let width = min(size.width, desired + 2 * padding)
        let textSize = label.sizeThatFits(CGSize(width: max(0, width - 2 * padding), height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: textSize.height + 2 + 2 * dp(8))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: dp(16), dy: dp(8))
        updateColors()
    }
}
