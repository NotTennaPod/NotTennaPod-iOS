import UIKit
import NotTennaPodCore

/// Source indeterminate `ProgressDialog` with “Please wait…”: spinner then message, no buttons.
/// Back (escape) hides only this dialog; outside touches do nothing. Neither cancels the write.
@MainActor final class PleaseWaitController: UIViewController {
    var onHidden: (() -> Void)?
    private let panel = UIView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let message = Appearance.label(Appearance.text("please_wait"), size: 16)
    private var hiding = false

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.32)
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "opmlExportProgress"
        panel.backgroundColor = Appearance.surfaceVariant
        panel.layer.cornerRadius = 28
        spinner.color = Appearance.accent
        spinner.startAnimating()
        spinner.isAccessibilityElement = false
        message.numberOfLines = 0
        message.accessibilityIdentifier = "opmlExportProgressMessage"
        panel.addSubview(spinner); panel.addSubview(message); view.addSubview(panel)
        view.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: UIView, _) in
            self?.view.setNeedsLayout()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIAccessibility.post(notification: .screenChanged, argument: message)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        guard safe.width > 0, safe.height > 0 else { return }
        let width = min(safe.width - 48, SourceDialogLayout.preferredContentWidth(in: safe, configurationSize: view.bounds.size))
        let spinnerSize: CGFloat = 48
        let textX: CGFloat = 24 + spinnerSize + 24
        message.font = Appearance.font(16, compatibleWith: traitCollection)
        let textWidth = max(0, width - textX - 24)
        let textHeight = message.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        let height = max(spinnerSize, textHeight) + 48
        panel.frame = CGRect(x: safe.midX - width / 2, y: safe.midY - height / 2, width: width, height: height)
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        spinner.frame = CGRect(x: rtl ? width - 24 - spinnerSize : 24, y: (height - spinnerSize) / 2, width: spinnerSize, height: spinnerSize)
        message.textAlignment = rtl ? .right : .left
        message.frame = CGRect(x: rtl ? 24 : textX, y: (height - textHeight) / 2, width: textWidth, height: textHeight)
    }

    /// Source Back on a cancelable progress dialog: dismiss the dialog only.
    func hide() {
        guard !hiding else { return }
        hiding = true
        let hidden = onHidden
        dismiss(animated: true) { hidden?() }
    }

    override func accessibilityPerformEscape() -> Bool { hide(); return true }
    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapePressed))
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }
    @objc private func escapePressed() { hide() }
}
