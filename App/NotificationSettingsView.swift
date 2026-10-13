import UIKit
import NotTennaPodCore

/// Settings → Notifications: Android's own screen (`preferences_notifications.xml`), with each switch
/// acting like the matching Android 8+ channel. Rows follow the other settings screens:
/// 16 pt side padding (24 pt when the window's smallest side is at least 600 pt), the switch at the
/// trailing edge, mirrored in right-to-left layout.
@MainActor final class NotificationSettingsView: UIView {
    var onFailure: ((any Error) -> Void)?
    private let preferences: NotificationPreferenceStore?
    private let account: UUID?
    private struct Row {
        let key: String?
        let control: UIView
        let title: UILabel
        let summary: UILabel?
        let indicator: PreferenceSwitchView?
    }
    private var rows: [Row] = []

    /// `account` is the selected synchronization account; the sync row is enabled only with one.
    /// Like Android, the enabled state is fixed when the screen is created.
    init(preferences: NotificationPreferenceStore?, synchronizationAccount account: UUID?, width: CGFloat) {
        self.preferences = preferences; self.account = account
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 0))
        build()
        registerForTraitChanges([UITraitLayoutDirection.self]) { (view: NotificationSettingsView, _) in view.setNeedsLayout() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private var value: NotificationPreferences { preferences?.value ?? .init() }

    private func build() {
        let category = Appearance.label(Appearance.text(NotificationSettingsComposition.categoryKey), size: 14)
        category.textColor = Appearance.accent
        category.accessibilityTraits = [.header, .staticText]
        let header = UIView()
        header.addSubview(category)
        addSubview(header)
        rows.append(Row(key: nil, control: header, title: category, summary: nil, indicator: nil))
        for entry in NotificationSettingsComposition.rows {
            let enabled = NotificationSettingsComposition.isEnabled(entry.key, synchronizationAccount: account)
            let on = NotificationSettingsComposition.isOn(entry.key, value, synchronizationAccount: account)
            let control = UIControl()
            let title = Appearance.label(Appearance.text(entry.titleKey), size: 16)
            title.font = Appearance.font(16, medium: true)
            let summary = Appearance.label(Appearance.text(entry.summaryKey), size: 14)
            summary.textColor = Appearance.secondary
            for (label, lineHeight) in [(title, CGFloat(22)), (summary, CGFloat(20))] {
                guard let text = label.text else { continue }
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = lineHeight; paragraph.maximumLineHeight = lineHeight
                label.attributedText = NSAttributedString(string: text, attributes: [.paragraphStyle: paragraph])
            }
            // A disabled preference dims its title and summary (Material's disabled text alpha).
            if !enabled { title.alpha = 0.38; summary.alpha = 0.38 }
            let indicator = PreferenceSwitchView()
            indicator.isOn = on; indicator.preferenceEnabled = enabled; indicator.isUserInteractionEnabled = false
            control.addSubview(title); control.addSubview(summary); control.addSubview(indicator)
            control.isAccessibilityElement = true
            control.accessibilityIdentifier = entry.key
            control.accessibilityLabel = title.text
            control.accessibilityHint = summary.text
            control.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
            control.accessibilityValue = on ? Appearance.text("on") : Appearance.text("off")
            control.isEnabled = enabled
            control.addAction(UIAction { [weak self, weak control, weak indicator] _ in
                guard let self, let control, let indicator else { return }
                toggle(entry.key, control: control, indicator: indicator)
            }, for: .touchUpInside)
            addSubview(control)
            rows.append(Row(key: entry.key, control: control, title: title, summary: summary, indicator: indicator))
        }
        layoutRows()
    }

    /// Saves at once, with no dialog or permission request (`NotificationPreferencesFragment` has no listeners).
    private func toggle(_ key: String, control: UIView, indicator: PreferenceSwitchView) {
        guard let preferences else { return }
        do {
            let next = !NotificationSettingsComposition.isOn(key, preferences.value, synchronizationAccount: account)
            if key == NotificationSettingsComposition.synchronizationKey {
                guard let account else { return }
                try preferences.setSynchronizationFailed(next, account: account)
            } else {
                try preferences.setDownloadFailed(next)
            }
            indicator.isOn = next
            control.accessibilityValue = next ? Appearance.text("on") : Appearance.text("off")
        } catch { onFailure?(error) }
    }

    override func didMoveToWindow() { super.didMoveToWindow(); layoutRows() }
    override func layoutSubviews() { super.layoutSubviews(); layoutRows() }

    private func layoutRows() {
        let smallest = window.map { min($0.bounds.width, $0.bounds.height) } ?? bounds.width
        let inset: CGFloat = smallest >= 600 ? 24 : 16
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        var y: CGFloat = 0
        for row in rows {
            let widget: CGFloat = row.indicator == nil ? 0 : 52 + 16
            let textWidth = max(0, bounds.width - inset * 2 - widget)
            let titleHeight = row.title.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
            let summaryHeight = row.summary?.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height ?? 0
            let category = row.key == nil
            let height = category ? max(48, titleHeight + 24) : max(64, titleHeight + summaryHeight + 32)
            row.control.frame = CGRect(x: 0, y: y, width: bounds.width, height: height)
            let textX = inset + (rtl ? widget : 0)
            row.title.textAlignment = rtl ? .right : .left
            row.summary?.textAlignment = rtl ? .right : .left
            row.title.frame = CGRect(x: textX, y: category ? height - titleHeight - 8 : (height - titleHeight - summaryHeight) / 2,
                                     width: textWidth, height: titleHeight)
            row.summary?.frame = CGRect(x: textX, y: row.title.frame.maxY, width: textWidth, height: summaryHeight)
            row.indicator?.frame = CGRect(x: rtl ? inset : bounds.width - inset - 52, y: (height - 32) / 2, width: 52, height: 32)
            y += height
        }
        frame.size.height = y + 16
    }
}
