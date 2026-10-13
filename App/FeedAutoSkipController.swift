import UIKit
import NotTennaPodCore

@MainActor enum FeedAutoSkipController {
    static func make(value: FeedSkipPreferences, save: @escaping (FeedSkipPreferences) -> Void) -> SourceMessageController {
        let body = FeedAutoSkipBody(value: value)
        let dialog = SourceMessageController(title: Appearance.text("pref_feed_skip"), message: "",
            positive: .init(title: Appearance.text("confirm_label"), identifier: "feedSkipConfirm", perform: {
                save(body.draft.confirmed)
            }, performAfterDismiss: true),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "feedSkipCancel"), customBody: body)
        dialog.avoidsKeyboard = true
        return dialog
    }
}

@MainActor final class FeedAutoSkipBody: UIView, UITextFieldDelegate, SourceMessageBodyViewport, SourceMessageEditingBody {
    let intro = FeedSkipNumberField(), ending = FeedSkipNumberField()
    private let labels = [Appearance.label(Appearance.text("pref_feed_skip_intro"), size: 14),
                          Appearance.label(Appearance.text("pref_feed_skip_ending"), size: 14)]
    private let units = [Appearance.label(Appearance.text("time_seconds"), size: 14),
                         Appearance.label(Appearance.text("time_seconds"), size: 14)]
    private let lines = [UIView(), UIView()]
    var minimumMessageViewportHeight: CGFloat { max(48, intro.bounds.height) }
    var editingControl: UIView? { [intro, ending].first { $0.isFirstResponder } }
    func messageBodyDidScroll() { }
    var draft: FeedSkipDraft {
        var value = FeedSkipDraft(.init()); value.intro = intro.text ?? ""; value.ending = ending.text ?? ""; return value
    }
    init(value: FeedSkipPreferences) {
        super.init(frame: .zero); accessibilityIdentifier = "feedAutoSkipBody"
        let draft = FeedSkipDraft(value); intro.text = draft.intro; ending.text = draft.ending
        for (index, field) in [intro, ending].enumerated() {
            field.keyboardType = .numberPad; field.delegate = self
            field.accessibilityIdentifier = index == 0 ? "feedSkipIntro" : "feedSkipEnding"
            field.accessibilityLabel = labels[index].text
            field.textColor = Appearance.foreground; field.tintColor = Appearance.accent
            field.borderStyle = .none; field.textAlignment = .natural
            field.autocorrectionType = .no; field.spellCheckingType = .no
            field.addTarget(self, action: #selector(editingChanged), for: [.editingDidBegin, .editingDidEnd])
            labels[index].textColor = Appearance.secondary; units[index].textColor = Appearance.secondary
            lines[index].accessibilityIdentifier = index == 0 ? "feedSkipIntroUnderline" : "feedSkipEndingUnderline"
            [labels[index], field, units[index], lines[index]].forEach(addSubview)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func editingChanged() { setNeedsLayout() }
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let previous = textField.text ?? ""
        guard let updated = FeedSkipDraft.edit(previous, range: range, replacement: string) else { return false }
        textField.text = updated
        let inserted = updated.utf16.count - previous.utf16.count + range.length
        if let position = textField.position(from: textField.beginningOfDocument, offset: range.location + inserted) {
            textField.selectedTextRange = textField.textRange(from: position, to: position)
        }
        return false
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: layout(width: size.width, apply: false)) }
    override func layoutSubviews() { super.layoutSubviews(); _ = layout(width: bounds.width, apply: true) }
    private func layout(width: CGFloat, apply: Bool) -> CGFloat {
        let inset = min(24, width / 2), available = max(0, width - 2 * inset)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        var y: CGFloat = 0
        for (index, field) in [intro, ending].enumerated() {
            labels[index].font = Appearance.font(14, compatibleWith: traitCollection)
            units[index].font = labels[index].font
            field.font = Appearance.font(18, compatibleWith: traitCollection)
            let labelHeight = labels[index].sizeThatFits(CGSize(width: available, height: .greatestFiniteMagnitude)).height
            let unitWidth = min(available / 2, units[index].intrinsicContentSize.width)
            let fieldWidth = min(max(0, available - unitWidth - 8), max(150, (field.font?.pointSize ?? 18) * 5))
            let rowHeight = max(48, (field.font?.lineHeight ?? 22) + 16,
                units[index].sizeThatFits(CGSize(width: unitWidth, height: .greatestFiniteMagnitude)).height + 16)
            func rect(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: rtl ? width - x - w : x, y: top, width: w, height: h)
            }
            if apply {
                labels[index].frame = rect(inset, y, available, labelHeight)
                field.frame = rect(inset, y + labelHeight, fieldWidth, rowHeight)
                units[index].frame = rect(inset + fieldWidth + 8, y + labelHeight, unitWidth, rowHeight)
                let thickness: CGFloat = field.isFirstResponder ? 2 : 1
                lines[index].frame = rect(inset + 4, y + labelHeight + rowHeight - 8, max(0, fieldWidth - 8), thickness)
                lines[index].backgroundColor = field.isFirstResponder ? Appearance.accent : Appearance.secondary
            }
            y += labelHeight + rowHeight
        }
        return y
    }
}

@MainActor final class FeedSkipNumberField: UITextField {
    override func textRect(forBounds bounds: CGRect) -> CGRect { bounds.insetBy(dx: min(4, bounds.width / 2), dy: 0) }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { textRect(forBounds: bounds) }
}
