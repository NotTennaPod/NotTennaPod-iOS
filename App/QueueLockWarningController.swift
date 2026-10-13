import UIKit
import NotTennaPodCore

@MainActor enum QueueLockWarningController {
    static func make(confirm: @escaping (Bool) -> Void) -> SourceMessageController {
        let body = QueueLockWarningBody()
        return SourceMessageController(title: Appearance.text("lock_queue"), message: "",
            positive: .init(title: Appearance.text("lock_queue"), identifier: "queueLockConfirm", perform: { confirm(body.suppression.checked) }, performAfterDismiss: true),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "queueLockCancel"), customBody: body)
    }
}
/// A message with a "Do not show again" checkbox (`checkbox_do_not_show_again.xml`).
@MainActor final class QueueLockWarningBody: UIView {
    private let message: UILabel
    let suppression = SpeedCheckbox(titleKey: "checkbox_do_not_show_again")
    init(messageKey: String = "queue_lock_warning", identifier: String = "queueLockWarning", checkboxIdentifier: String = "queueLockSuppress") {
        message = Appearance.label(Appearance.text(messageKey), size: 14)
        super.init(frame: .zero)
        accessibilityIdentifier = identifier
        suppression.accessibilityIdentifier = checkboxIdentifier
        suppression.addAction(UIAction { [weak suppression] _ in suppression?.checked.toggle() }, for: .touchUpInside)
        addSubview(message); addSubview(suppression)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        .init(width: size.width, height: message.sizeThatFits(.init(width: max(0,size.width-48), height: .greatestFiniteMagnitude)).height
            + suppression.sizeThatFits(.init(width: max(0,size.width-32), height: .greatestFiniteMagnitude)).height + 32)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let height = message.sizeThatFits(.init(width: max(0,bounds.width-48), height: .greatestFiniteMagnitude)).height
        message.frame = .init(x: 24, y: 16, width: max(0,bounds.width-48), height: height)
        suppression.frame = .init(x: 16, y: height + 24, width: max(0,bounds.width-32), height: max(0,bounds.height-height-32))
    }
}
