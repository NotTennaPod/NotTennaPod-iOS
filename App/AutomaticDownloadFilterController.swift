import UIKit
import NotTennaPodCore

@MainActor enum AutomaticDownloadFilterController {
    static func make(value: AutomaticDownloadFilter, save: @escaping (AutomaticDownloadFilter) -> Void) -> SourceMessageController {
        let body = AutomaticDownloadFilterBody(value: value)
        let dialog = SourceMessageController(title: Appearance.text("episode_filters_label"), message: "",
            positive: .init(title: Appearance.text("confirm_label"), identifier: "downloadFilterConfirm", perform: {
                save(body.confirmed)
            }, performAfterDismiss: true),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "downloadFilterCancel"), customBody: body)
        dialog.avoidsKeyboard = true
        body.changed = { [weak dialog] in dialog?.view.setNeedsLayout() }
        return dialog
    }
}

@MainActor final class AutomaticDownloadFilterBody: UIView, UITextFieldDelegate, SourceMessageBodyViewport, SourceMessageEditingBody {
    private(set) var draft: AutomaticDownloadFilterDraft
    let term = UITextField(), duration = FeedSkipNumberField()
    private let include = DownloadFilterMode(title: "include_terms")
    private let exclude = DownloadFilterMode(title: "exclude_terms")
    private let durationToggle = SpeedCheckbox(titleKey: "exclude_episodes_shorter_than")
    private let units = Appearance.label(Appearance.text("time_minutes"), size: 14)
    private let outline = UIView(), divider = UIView(), underline = UIView()
    private var chips: [UIView] = []
    private var add: UIButton!
    var changed: (() -> Void)?
    var editingControl: UIView? { [term, duration].first { $0.isFirstResponder } }
    var minimumMessageViewportHeight: CGFloat { 56 }
    func messageBodyDidScroll() { }
    var confirmed: AutomaticDownloadFilter {
        var value = draft; value.minutes = duration.text ?? ""; return value.confirmed
    }
    init(value: AutomaticDownloadFilter) {
        draft = .init(value)
        super.init(frame: .zero); accessibilityIdentifier = "downloadFilterBody"
        include.accessibilityIdentifier = "downloadFilterInclude"
        exclude.accessibilityIdentifier = "downloadFilterExclude"
        include.addAction(UIAction { [weak self] _ in self?.selectMode(exclude: false) }, for: .touchUpInside)
        exclude.addAction(UIAction { [weak self] _ in self?.selectMode(exclude: true) }, for: .touchUpInside)
        [include, exclude, outline, divider, durationToggle, duration, units, underline].forEach(addSubview)
        term.accessibilityIdentifier = "downloadFilterTerm"; term.accessibilityLabel = Appearance.text("add_term")
        term.autocorrectionType = .no; term.autocapitalizationType = .none; term.returnKeyType = .done
        term.delegate = self; term.textColor = Appearance.foreground; term.tintColor = Appearance.accent
        outline.layer.cornerRadius = 4; outline.addSubview(term)
        add = Appearance.icon("ic_add", label: Appearance.text("add_term")) { [weak self] in self?.addTerm() }
        add.accessibilityIdentifier = "downloadFilterAdd"; add.tintColor = Appearance.secondary; outline.addSubview(add)
        duration.accessibilityIdentifier = "downloadFilterMinutes"
        duration.accessibilityLabel = Appearance.text("exclude_episodes_shorter_than") + " " + Appearance.text("time_minutes")
        duration.text = draft.minutes; duration.textColor = Appearance.foreground; duration.tintColor = Appearance.accent
        duration.keyboardType = .numbersAndPunctuation; duration.delegate = self
        durationToggle.accessibilityIdentifier = "downloadFilterDuration"
        durationToggle.addAction(UIAction { [weak self] _ in
            guard let self else { return }; draft.durationEnabled.toggle(); updateSelection()
        }, for: .touchUpInside)
        updateSelection(); rebuildChips()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func selectMode(exclude: Bool) { draft.exclude = exclude; updateSelection() }
    private func updateSelection() {
        include.checked = !draft.exclude; exclude.checked = draft.exclude
        durationToggle.checked = draft.durationEnabled; duration.isEnabled = draft.durationEnabled
        duration.alpha = draft.durationEnabled ? 1 : 0.38
        if !draft.durationEnabled { duration.resignFirstResponder() }
        setNeedsLayout()
    }
    private func addTerm() {
        guard draft.add(term.text ?? "") else { return }
        term.text = ""; rebuildChips()
    }
    // Android's single-line editor does not submit the pending term on Confirm.
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { textField.resignFirstResponder(); return true }
    func textFieldDidBeginEditing(_ textField: UITextField) { setNeedsLayout() }
    func textFieldDidEndEditing(_ textField: UITextField) { setNeedsLayout() }
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard textField === duration else { return true }
        let previous = textField.text ?? ""
        guard let value = AutomaticDownloadFilterDraft.editMinutes(previous, range: range, replacement: string) else { return false }
        textField.text = value
        let inserted = value.utf16.count - previous.utf16.count + range.length
        if let position = textField.position(from: textField.beginningOfDocument, offset: range.location + inserted) {
            textField.selectedTextRange = textField.textRange(from: position, to: position)
        }
        return false
    }
    private func rebuildChips() {
        chips.forEach { $0.removeFromSuperview() }
        chips = draft.terms.enumerated().map { index, value in
            let chip = UIView(), surface = UIView(), label = Appearance.label(value, size: 14)
            surface.layer.cornerRadius = 8; surface.layer.borderWidth = 1
            surface.backgroundColor = Appearance.color(0xdeeef8, 0x233141); surface.tag = 3
            surface.isUserInteractionEnabled = false; chip.addSubview(surface)
            label.tag = 1; label.numberOfLines = 1; label.lineBreakMode = .byTruncatingTail; chip.addSubview(label)
            let remove = DownloadFilterRemove(type: .custom)
            remove.setImage(UIImage(named: "ic_delete"), for: .normal); remove.tintColor = Appearance.secondary
            remove.accessibilityIdentifier = "downloadFilterRemove-\(index)"
            remove.accessibilityLabel = Appearance.text("delete_label") + " " + value; remove.tag = 2
            remove.addAction(UIAction { [weak self] _ in self?.draft.remove(at: index); self?.rebuildChips() }, for: .touchUpInside)
            chip.addSubview(remove); addSubview(chip); return chip
        }
        setNeedsLayout(); changed?()
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize { .init(width: size.width, height: layout(width: size.width, apply: false)) }
    override func layoutSubviews() { super.layoutSubviews(); _ = layout(width: bounds.width, apply: true) }
    private func layout(width: CGFloat, apply: Bool) -> CGFloat {
        let inset = min(16, width / 2), available = max(0, width - 2 * inset)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            .init(x: rtl ? width - x - w : x, y: y, width: w, height: h)
        }
        let font = Appearance.font(16, compatibleWith: traitCollection)
        term.font = font; duration.font = Appearance.font(18, compatibleWith: traitCollection)
        units.font = Appearance.font(14, compatibleWith: traitCollection)
        let modeWidth = available / 2
        let includeHeight = include.sizeThatFits(.init(width: modeWidth, height: .greatestFiniteMagnitude)).height
        let excludeHeight = exclude.sizeThatFits(.init(width: modeWidth, height: .greatestFiniteMagnitude)).height
        let modeHeight = max(includeHeight, excludeHeight)
        if apply {
            include.frame = rect(inset, 16, modeWidth, includeHeight)
            exclude.frame = rect(inset + modeWidth, 16, modeWidth, excludeHeight)
        }
        var y = 16 + modeHeight + 8
        let chipFont = Appearance.font(14, medium: true, compatibleWith: traitCollection)
        let column = max(0, (available - 16) / 2), visibleHeight = max(32, chipFont.lineHeight)
        let chipHeight = visibleHeight + 16
        for (index, chip) in chips.enumerated() where apply {
            chip.frame = rect(inset + 4 + CGFloat(index % 2) * (column + 8), y + CGFloat(index / 2) * (chipHeight + 8) + 4, column, chipHeight)
            chip.viewWithTag(3)?.frame = .init(x: 0, y: 8, width: column, height: visibleHeight)
            chip.viewWithTag(3)?.layer.borderColor = Appearance.secondary.resolvedColor(with: traitCollection).cgColor
            let removeWidth = min(34, column)
            let label = chip.viewWithTag(1) as? UILabel
            label?.attributedText = NSAttributedString(string: draft.terms[index], attributes: [
                .font: chipFont, .kern: chipFont.pointSize * 0.00714286, .foregroundColor: Appearance.foreground])
            label?.frame = .init(x: rtl ? removeWidth : 16, y: 8, width: max(0, column - removeWidth - 16), height: visibleHeight)
            chip.viewWithTag(2)?.frame = .init(x: rtl ? 0 : column - removeWidth, y: 8, width: removeWidth, height: visibleHeight)
        }
        y += CGFloat((chips.count + 1) / 2) * (chipHeight + 8)
        let inputHeight = max(56, font.lineHeight + 32)
        if apply {
            outline.frame = rect(inset, y + 6, available, inputHeight)
            outline.layer.borderWidth = term.isFirstResponder ? 2 : 1
            outline.layer.borderColor = (term.isFirstResponder ? Appearance.accent : Appearance.foreground.withAlphaComponent(0.38)).resolvedColor(with: traitCollection).cgColor
            let addWidth = min(48, available)
            term.frame = .init(x: rtl ? addWidth : min(16, available), y: 0, width: max(0, available - addWidth - 16), height: inputHeight)
            add.frame = .init(x: rtl ? 0 : available - addWidth, y: 0, width: addWidth, height: inputHeight)
        }
        y += inputHeight + 6 + 16
        if apply { divider.frame = rect(inset, y, available, 1); divider.backgroundColor = Appearance.secondary.withAlphaComponent(0.3) }
        y += 9
        let unitWidth = min(available / 3, units.intrinsicContentSize.width)
        let fieldWidth = min(50, max(0, available - unitWidth))
        let checkWidth = max(0, available - fieldWidth - unitWidth)
        let durationHeight = max(48, durationToggle.sizeThatFits(.init(width: checkWidth, height: .greatestFiniteMagnitude)).height,
                                 (duration.font?.lineHeight ?? 22) + 16)
        if apply {
            durationToggle.frame = rect(inset, y, checkWidth, durationHeight)
            duration.frame = rect(inset + checkWidth, y, fieldWidth, durationHeight)
            units.frame = rect(inset + checkWidth + fieldWidth, y, unitWidth, durationHeight)
            underline.frame = rect(inset + checkWidth + 4, y + durationHeight - 8, max(0, fieldWidth - 8), duration.isFirstResponder ? 2 : 1)
            underline.backgroundColor = (duration.isFirstResponder ? Appearance.accent : Appearance.secondary).withAlphaComponent(duration.isEnabled ? 1 : 0.38)
        }
        return y + durationHeight + 16
    }
}

@MainActor private final class DownloadFilterRemove: UIButton {
    override func imageRect(forContentRect rect: CGRect) -> CGRect { .init(x: rect.midX - 9, y: rect.midY - 9, width: 18, height: 18) }
}

@MainActor private final class DownloadFilterMode: UIControl {
    private let label: UILabel
    var checked = false { didSet { accessibilityTraits = checked ? [.button, .selected] : .button; setNeedsDisplay() } }
    init(title: String) {
        label = Appearance.label(Appearance.text(title), size: 14)
        super.init(frame: .zero); isOpaque = false; backgroundColor = .clear
        label.isUserInteractionEnabled = false; addSubview(label)
        isAccessibilityElement = true; accessibilityLabel = label.text
    }
    required init?(coder: NSCoder) { fatalError() }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        label.font = Appearance.font(14, compatibleWith: traitCollection)
        return .init(width: size.width, height: max(48, label.sizeThatFits(.init(width: max(0, size.width - 32), height: .greatestFiniteMagnitude)).height))
    }
    override func layoutSubviews() {
        super.layoutSubviews(); let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        label.frame = .init(x: rtl ? 0 : 32, y: 0, width: max(0, bounds.width - 32), height: bounds.height)
    }
    override func draw(_ rect: CGRect) {
        let x = effectiveUserInterfaceLayoutDirection == .rightToLeft ? bounds.width - 16 : 16
        let color = checked ? Appearance.accent : Appearance.secondary; color.setStroke(); color.setFill()
        let ring = UIBezierPath(ovalIn: .init(x: x - 9, y: bounds.midY - 9, width: 18, height: 18))
        ring.lineWidth = 2; ring.stroke()
        if checked { UIBezierPath(ovalIn: .init(x: x - 5, y: bounds.midY - 5, width: 10, height: 10)).fill() }
    }
}
