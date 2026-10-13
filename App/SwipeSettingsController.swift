import UIKit
import NotTennaPodCore

@MainActor enum SwipeSettingsController {
    static func make(screen: SwipeScreen, store: SwipePreferenceStore,
                     saved: @escaping () -> Void, failed: @escaping (any Error) -> Void) -> SourceMessageController {
        let body = SwipeSettingsBody(draft: store.draft(for: screen))
        weak var presented: SourceMessageController?
        var committed = false
        let dialog = SourceMessageController(title: Appearance.text("swipeactions_label") + " - " + Appearance.text(screen.titleKey), message: "",
            positive: .init(title: Appearance.text("confirm_label"), identifier: "inboxSwipeConfirm", perform: {
                guard !committed else { return }
                do {
                    try store.confirm(body.draft)
                    committed = true
                    presented?.dismiss(animated: true, completion: saved)
                } catch { failed(error) }
            }, dismisses: false),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "inboxSwipeCancel"), customBody: body)
        presented = dialog
        body.pick = { [weak dialog, weak body] direction in
            guard let dialog, let body else { return }
            let choices = SwipeSettingsPickerBody(actions: screen.actions,
                selected: body.pickedDirections.contains(direction) ? body.draft.configuration.action(direction) : nil,
                identifierPrefix: "inboxSwipe")
            let picker = SourceMessageController(title: Appearance.text(direction == .left ? "swipe_left" : "swipe_right"), message: "",
                positive: .init(title: Appearance.text("cancel_label"), identifier: "inboxSwipePickerCancel"), customBody: choices)
            choices.select = { [weak picker, weak body, weak dialog] action in
                if direction == .left { body?.draft.configuration.left = action }
                else { body?.draft.configuration.right = action }
                body?.pickedDirections.insert(direction)
                body?.refresh(); dialog?.view.setNeedsLayout(); picker?.dismiss(animated: true)
            }
            dialog.present(picker, animated: true)
        }
        return dialog
    }
}

@MainActor final class SwipeSettingsBody: UIView {
    var draft: SwipeDraft
    var pickedDirections: Set<EpisodeSwipeDirection> = []
    var pick: ((EpisodeSwipeDirection) -> Void)?
    private let toggle = UIControl(), toggleLabel = Appearance.label(Appearance.text("enable_swipeactions"), size: 14)
    private let switchImage = PreferenceSwitchView()
    private let rows: [SwipeSettingsDirectionRow<SwipeAction>]
    init(draft: SwipeDraft) {
        self.draft = draft
        rows = [.init(direction: .left, action: draft.configuration.left, identifierPrefix: "inboxSwipe"),
                .init(direction: .right, action: draft.configuration.right, identifierPrefix: "inboxSwipe")]
        super.init(frame: .zero)
        accessibilityIdentifier = "inboxSwipeSettings"
        toggle.accessibilityIdentifier = "inboxSwipeEnabled"
        toggle.isAccessibilityElement = true; toggle.accessibilityLabel = toggleLabel.text; toggle.accessibilityTraits = .button
        toggleLabel.isUserInteractionEnabled = false; switchImage.isUserInteractionEnabled = false
        toggle.addSubview(toggleLabel); toggle.addSubview(switchImage); addSubview(toggle)
        toggle.addAction(UIAction { [weak self] _ in self?.draft.configuration.enabled.toggle(); self?.refresh() }, for: .touchUpInside)
        for row in rows { row.change = { [weak self, weak row] in if let row { self?.pick?(row.direction) } }; addSubview(row) }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    func refresh() {
        switchImage.isOn = draft.configuration.enabled; toggle.accessibilityValue = draft.configuration.enabled ? Appearance.text("on") : Appearance.text("off")
        for row in rows { row.action = draft.configuration.action(row.direction); row.alpha = draft.configuration.enabled ? 1 : 0.4 }
        setNeedsLayout()
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: layout(size.width, apply: false)) }
    override func layoutSubviews() { super.layoutSubviews(); _ = layout(bounds.width, apply: true) }
    private func layout(_ width: CGFloat, apply: Bool) -> CGFloat {
        let inset = min(16, width / 2), available = max(0, width - inset * 2)
        toggleLabel.font = Appearance.font(14, compatibleWith: traitCollection)
        let labelWidth = max(0, available - 68), height = max(48, toggleLabel.sizeThatFits(CGSize(width: labelWidth, height: .greatestFiniteMagnitude)).height + 16)
        if apply {
            toggle.frame = CGRect(x: inset, y: 16, width: available, height: height)
            let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
            toggleLabel.frame = CGRect(x: rtl ? 68 : 0, y: 0, width: labelWidth, height: height)
            switchImage.frame = CGRect(x: rtl ? 0 : max(0, available - 52), y: (height - 32)/2, width: 52, height: 32)
        }
        var y = 16 + height
        for row in rows {
            let height = row.sizeThatFits(CGSize(width: available, height: .greatestFiniteMagnitude)).height
            if apply { row.frame = CGRect(x: inset, y: y, width: available, height: height) }
            y += height
        }
        return y + 16
    }
}

@MainActor extension SwipeAction: SwipeSettingsOption {
    var identifier: String { rawValue }
    var swipeColor: UIColor {
        switch self {
        case .queue, .removeQueue: Appearance.accent
        case .download: Appearance.color(0x008537, 0x008537)
        case .removeInbox, .removeHistory: Appearance.color(0x5f1984, 0xaa55d8)
        case .delete: Appearance.color(0xcf1800, 0xcf1800)
        case .favorite, .removeFavorite: Appearance.color(0xf59f00, 0xf59f00)
        case .played: Appearance.color(0x25365a, 0xcdd9e4)
        }
    }
}
