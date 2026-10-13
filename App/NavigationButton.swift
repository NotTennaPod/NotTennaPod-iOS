import UIKit
import NotTennaPodCore

@MainActor
final class NavigationButton: UIControl {
    private let indicator = UIView()
    private let icon = UIImageView()
    private let label = UILabel()
    private let badge = UILabel()

    /// `BottomNavigation.updateBottomNavigationBadgeIfNeeded` puts a Material `BadgeDrawable`
    /// with the Inbox count on the Inbox item and hides it at 0 (Widget.Material3.Badge: colorError
    /// pill, 16 dp high, at least 16 dp wide, 4 dp side padding, labelSmall colorOnError text, "999+"
    /// above 999). TalkBack reads "Inbox, 1 new notification" (`mtrl_badge_content_description`).
    var badgeCount = 0 {
        didSet {
            guard badgeCount != oldValue else { return }
            updateBadge(); setNeedsLayout()
        }
    }

    init(title: String, image: String, selected: Bool, action: @escaping () -> Void) {
        super.init(frame: .zero)
        accessibilityLabel = title
        accessibilityTraits = selected ? [.button, .selected] : .button
        indicator.backgroundColor = Appearance.selected
        indicator.isHidden = !selected
        indicator.layer.cornerRadius = 16
        icon.image = UIImage(named: image)
        icon.contentMode = .scaleAspectFit
        icon.tintColor = selected ? Appearance.foreground : Appearance.secondary
        label.text = title
        label.font = Appearance.font(12, bold: selected)
        label.textColor = selected ? Appearance.foreground : Appearance.secondary
        label.textAlignment = .center
        badge.accessibilityIdentifier = "navigationBadge"
        badge.backgroundColor = Appearance.color(0xb3261e, 0xf2b8b5)
        badge.textColor = Appearance.color(0xffffff, 0x601410)
        badge.textAlignment = .center
        badge.clipsToBounds = true
        badge.isHidden = true
        [indicator, icon, label, badge].forEach { $0.isUserInteractionEnabled = false; addSubview($0) }
        addAction(UIAction { _ in action() }, for: .touchUpInside)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitLayoutDirection.self]) { (button: NavigationButton, _) in
            button.setNeedsLayout()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateBadge() {
        let text = NavigationCounters.badgeText(badgeCount)
        badge.text = text
        badge.isHidden = text == nil
        if badgeCount > NavigationCounters.badgeMaximum {
            accessibilityValue = String(format: Appearance.text("mtrl_exceed_max_badge_number_content_description"), NavigationCounters.badgeMaximum)
        } else if badgeCount > 0 {
            accessibilityValue = Appearance.plural("mtrl_badge_content_description", badgeCount)
        } else { accessibilityValue = nil }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        indicator.frame = CGRect(x: (bounds.width - 64) / 2, y: 6, width: 64, height: 32)
        icon.frame = CGRect(x: (bounds.width - 24) / 2, y: 10, width: 24, height: 24)
        label.frame = CGRect(x: 0, y: 40, width: bounds.width, height: 16)
        guard !badge.isHidden else { return }
        // Measured on the Android 3.12.1 capture: the pill starts at the icon's centre (its trailing
        // half overhangs the icon) and its top is about 2 dp above the icon.
        badge.font = Appearance.font(11, medium: true, compatibleWith: traitCollection)
        let text = badge.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        let height = max(16, ceil(text.height) + 4), width = max(height, ceil(text.width) + 8)
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        badge.frame = CGRect(x: rightToLeft ? icon.frame.midX - width : icon.frame.midX, y: icon.frame.minY - 2, width: width, height: height)
        badge.layer.cornerRadius = height / 2
    }
}
