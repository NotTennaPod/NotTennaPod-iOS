import UIKit
import NotTennaPodCore

/// `item_tag_chip.xml`: a Material3 filter chip (32-point surface in a 48-point touch row, 8-point
/// corners, outlined when unchecked, filled with a leading check when checked). Long press on a real tag
/// opens the Rename/Delete tag menu.
@MainActor final class SubscriptionTagChip: UIControl {
    static let rowHeight: CGFloat = 48
    let tagTitle: String
    var onLongPress: ((SubscriptionTagChip) -> Void)?
    private let surface = UIView()
    private let label: UILabel
    private let check = UIImageView(image: UIImage(named: "ic_check"))
    private let checked: Bool
    init(tag: String, title: String, checked: Bool) {
        tagTitle = tag; self.checked = checked
        label = Appearance.label(title, size: 14)
        super.init(frame: .zero)
        label.font = Appearance.font(14, medium: true); label.numberOfLines = 1
        surface.layer.cornerRadius = 8; surface.layer.borderWidth = checked ? 0 : 1
        check.tintColor = Appearance.foreground; check.contentMode = .scaleAspectFit; check.isHidden = !checked
        [surface, check, label].forEach { $0.isUserInteractionEnabled = false; addSubview($0) }
        isAccessibilityElement = true; accessibilityLabel = title
        accessibilityTraits = checked ? [.button, .selected] : .button
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(held(_:))))
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (chip: SubscriptionTagChip, _) in chip.setNeedsLayout() }
    }
    required init?(coder: NSCoder) { fatalError() }
    /// VoiceOver reaches the long-press menu as a custom action.
    func enableTagMenu(_ menu: @escaping (SubscriptionTagChip) -> Void) {
        onLongPress = menu
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: Appearance.text("overflow_more")) { [weak self] _ in
            guard let self else { return false }; menu(self); return true
        }]
    }
    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { onLongPress?(self) }
    }
    override var isHighlighted: Bool { didSet { surface.alpha = isHighlighted ? 0.7 : 1 } }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        label.font = Appearance.font(14, medium: true, compatibleWith: traitCollection)
        let text = ceil(label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 20)).width)
        return CGSize(width: text + 32 + (checked ? 26 : 0), height: max(Self.rowHeight, ceil(label.font.lineHeight) + 16))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let height = max(32, ceil(label.font.lineHeight) + 12)
        surface.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        surface.backgroundColor = checked ? Appearance.selected : .clear
        surface.layer.borderColor = Appearance.secondary.resolvedColor(with: traitCollection).cgColor
        let lead: CGFloat = checked ? 34 : 16
        check.frame = CGRect(x: rtl ? bounds.width - 8 - 18 : 8, y: (bounds.height - 18) / 2, width: 18, height: 18)
        let width = max(0, bounds.width - lead - 16)
        label.frame = CGRect(x: rtl ? 16 : lead, y: 0, width: width, height: bounds.height)
        label.textAlignment = rtl ? .right : .left
    }
}

/// A long-press recognizer that runs a closure once when the press begins.
final class ClosureLongPress: UILongPressGestureRecognizer {
    private let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(fire))
    }
    @objc private func fire() { if state == .began { action() } }
}

/// `PreferenceSwitchDialog`'s body: one switch row with its text, initially off.
@MainActor final class BulkSwitchBody: UIView {
    private(set) var isOn = false
    private let toggle = UIControl(), text: UILabel, switchImage = PreferenceSwitchView()
    init(text value: String) {
        text = Appearance.label(value, size: 14)
        super.init(frame: .zero)
        accessibilityIdentifier = "bulkSwitchBody"
        toggle.accessibilityIdentifier = "bulkSwitch"
        toggle.isAccessibilityElement = true; toggle.accessibilityLabel = value; toggle.accessibilityTraits = .button
        text.isUserInteractionEnabled = false; switchImage.isUserInteractionEnabled = false
        switchImage.isOpaque = false; switchImage.backgroundColor = .clear
        toggle.addSubview(text); toggle.addSubview(switchImage); addSubview(toggle)
        toggle.addAction(UIAction { [weak self] _ in self?.isOn.toggle(); self?.refresh() }, for: .touchUpInside)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func refresh() {
        switchImage.isOn = isOn; toggle.accessibilityValue = isOn ? Appearance.text("on") : Appearance.text("off")
        toggle.accessibilityTraits = isOn ? [.button, .selected] : .button
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: layout(size.width, apply: false)) }
    override func layoutSubviews() { super.layoutSubviews(); _ = layout(bounds.width, apply: true) }
    private func layout(_ width: CGFloat, apply: Bool) -> CGFloat {
        let inset = min(24, width / 2), available = max(0, width - inset * 2)
        text.font = Appearance.font(14, compatibleWith: traitCollection)
        let labelWidth = max(0, available - 68)
        let height = max(48, text.sizeThatFits(CGSize(width: labelWidth, height: .greatestFiniteMagnitude)).height + 16)
        if apply {
            let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
            toggle.frame = CGRect(x: inset, y: 8, width: available, height: height)
            text.frame = CGRect(x: rtl ? 68 : 0, y: 0, width: labelWidth, height: height)
            text.textAlignment = rtl ? .right : .left
            switchImage.frame = CGRect(x: rtl ? 0 : max(0, available - 52), y: (height - 32) / 2, width: 52, height: 32)
        }
        return height + 16
    }
}

/// `PreferenceListDialog`'s body: single-choice rows, the first preselected; Confirm applies.
@MainActor final class BulkChoiceBody: UIView {
    private(set) var selected = 0
    private var rows: [UIControl] = []
    private var labels: [UILabel] = []
    private var radios: [PopupMenuAccessory] = []
    private let titles: [String]
    init(titles: [String], identifier: String) {
        self.titles = titles
        super.init(frame: .zero)
        accessibilityIdentifier = identifier
        for (index, title) in titles.enumerated() {
            let row = UIControl(); row.accessibilityIdentifier = "\(identifier)-\(index)"
            row.isAccessibilityElement = true; row.accessibilityLabel = title
            let label = Appearance.label(title, size: 16); label.numberOfLines = 0; label.isUserInteractionEnabled = false
            row.addSubview(label); addSubview(row)
            row.addAction(UIAction { [weak self] _ in self?.selected = index; self?.refresh() }, for: .touchUpInside)
            rows.append(row); labels.append(label)
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func refresh() {
        radios.forEach { $0.removeFromSuperview() }
        radios = rows.enumerated().map { index, row in
            let radio = PopupMenuAccessory(kind: .radio(index == selected))
            row.accessibilityTraits = index == selected ? [.button, .selected] : .button
            row.addSubview(radio); return radio
        }
        setNeedsLayout()
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: layout(size.width, apply: false)) }
    override func layoutSubviews() { super.layoutSubviews(); _ = layout(bounds.width, apply: true) }
    private func layout(_ width: CGFloat, apply: Bool) -> CGFloat {
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        var y: CGFloat = 8
        for (index, row) in rows.enumerated() {
            let label = labels[index]
            label.font = Appearance.font(16, compatibleWith: traitCollection)
            let textWidth = max(0, width - 24 - 56 - 24)
            let height = max(48, label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height + 16)
            if apply {
                row.frame = CGRect(x: 0, y: y, width: width, height: height)
                radios[index].frame = CGRect(x: rtl ? width - 24 - 32 : 24, y: (height - 32) / 2, width: 32, height: 32)
                label.frame = CGRect(x: rtl ? 24 : 24 + 56, y: 0, width: textWidth, height: height)
                label.textAlignment = rtl ? .right : .left
            }
            y += height
        }
        return y + 8
    }
}
