import UIKit
import NotTennaPodCore

/// Login Flow v2 opens the user's browser and polls; returning to this dialog
/// never fabricates an authorization callback or selects an account itself.
@MainActor final class NextcloudAuthenticationController: SourceMessageController {
    let flow: NextcloudAuthenticationFlow
    private let body = NextcloudAuthenticationBody()
    private var operation: Task<Void, Never>?
    private var finishing = false
    private var displayedError: String?
    private var restoredSession: NextcloudAuthenticationSession?
    var onSessionChange: ((NextcloudAuthenticationSession?) -> Void)?

    init(flow: NextcloudAuthenticationFlow, restoring session: NextcloudAuthenticationSession? = nil) {
        self.flow = flow
        restoredSession = session
        super.init(title: Appearance.text("gpodnetauth_login_butLabel"), message: "",
            positive: .init(title: Appearance.text("cancel_label"), identifier: "nextcloudCancel", perform: { flow.cancel() }), customBody: body)
        showsSourceElevation = true
        avoidsKeyboard = true
        allowsImplicitCancellation = false
        isModalInPresentation = true
        flow.onChange = { [weak self] in self?.refresh() }
        body.onProceed = { [weak self] in
            guard let self, !flow.busy, !finishing else { return }
            view.endEditing(true)
            let host = body.host.text ?? ""
            operation = Task { await flow.start(host: host) }
        }
        body.onEditingChange = { [weak self] in self?.viewIfLoaded?.setNeedsLayout() }
        NotificationCenter.default.addObserver(self, selector: #selector(sceneActivated(_:)),
            name: UIScene.didActivateNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    isolated deinit { operation?.cancel(); flow.cancel(); NotificationCenter.default.removeObserver(self) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "nextcloudAuthentication"
        refresh()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let session = restoredSession {
            operation = Task {
                restoredSession = nil
                await flow.resume(session: session)
            }
        }
        refresh()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { cancel() }
    }
    private func cancel() { operation?.cancel(); flow.cancel(); onSessionChange?(nil) }
    @objc private func sceneActivated(_ notification: Notification) {
        guard notification.object as? UIWindowScene === viewIfLoaded?.window?.windowScene else { return }
        refresh()
    }
    private func refresh() {
        // Loading the restored dialog precedes resume(). Do not erase its saved
        // token during that initial idle frame.
        if restoredSession == nil, flow.pendingSession != nil || !flow.busy {
            onSessionChange?(flow.pendingSession)
        }
        guard isViewLoaded, !finishing else { return }
        body.update(busy: flow.busy, host: flow.host)
        view.setNeedsLayout()
        guard view.window?.windowScene?.activationState == .foregroundActive else { return }
        if flow.connectedEpoch != nil {
            finishing = true
            dismiss(animated: true)
        } else if let error = flow.error, error != displayedError, presentedViewController == nil, !isBeingPresented {
            displayedError = error
            let advice = SourceMessageController(title: Appearance.text("error_label"),
                message: Appearance.text("nextcloud_login_error_generic"), details: error)
            advice.showsSourceElevation = true
            advice.replacesPresentingMessageDim = true
            present(advice, animated: true)
        } else if flow.error == nil { displayedError = nil }
    }
}

@MainActor final class NextcloudAuthenticationBody: UIView, SourceMessageBodyViewport, SourceMessageEditingBody {
    let host = GpodderAuthenticationField(key: "synchronization_host_label", identifier: "nextcloudHost")
    var onProceed: (() -> Void)?
    var onEditingChange: (() -> Void)?
    private let stack = UIStackView()
    private let explanation = Appearance.label(Appearance.text("synchronization_host_explanation"), size: 14)
    private let progress = UIStackView()
    private let spinner = PlayerLoadingIndicator()
    private let instruction = Appearance.label(Appearance.text("synchronization_nextcloud_authenticate_browser"), size: 14)
    private let proceed = UIButton(type: .custom)
    var minimumMessageViewportHeight: CGFloat { host.intrinsicContentSize.height }
    var editingControl: UIView? { host.field.isFirstResponder ? host.field : nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "nextcloudAuthenticationBody"
        stack.axis = .vertical; stack.alignment = .fill; addSubview(stack)
        explanation.textColor = Appearance.secondary
        explanation.accessibilityIdentifier = "nextcloudHostExplanation"
        instruction.textColor = Appearance.secondary
        instruction.accessibilityIdentifier = "nextcloudBrowserInstruction"
        host.field.keyboardType = .URL; host.field.returnKeyType = .next
        host.onReturn = { [weak self] in self?.onProceed?() }
        host.onEditingChange = { [weak self] in self?.onEditingChange?() }
        stack.addArrangedSubview(explanation); stack.setCustomSpacing(16, after: explanation)
        stack.addArrangedSubview(host); stack.setCustomSpacing(16, after: host)
        progress.axis = .horizontal; progress.alignment = .center; progress.spacing = 8
        spinner.accessibilityIdentifier = "nextcloudAuthenticationProgress"
        spinner.widthAnchor.constraint(equalToConstant: 48).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 48).isActive = true
        progress.addArrangedSubview(spinner); progress.addArrangedSubview(instruction)
        stack.addArrangedSubview(progress)
        var configuration = UIButton.Configuration.filled()
        configuration.title = Appearance.text("proceed_to_login_butLabel")
        configuration.baseBackgroundColor = Appearance.accent; configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.background.backgroundInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
        proceed.configuration = configuration
        proceed.configurationUpdateHandler = { button in
            let font = Appearance.font(14, medium: true, compatibleWith: button.traitCollection)
            button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var value = attributes; value.font = font; return value
            }
        }
        proceed.accessibilityIdentifier = "nextcloudProceed"
        proceed.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        proceed.addAction(UIAction { [weak self] _ in self?.onProceed?() }, for: .touchUpInside)
        stack.addArrangedSubview(proceed)
        update(busy: false, host: "")
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self]) { (body: NextcloudAuthenticationBody, _) in
            body.invalidateIntrinsicContentSize(); body.setNeedsLayout(); body.onEditingChange?()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    func messageBodyDidScroll() { setNeedsLayout() }
    func update(busy: Bool, host value: String) {
        if busy, !host.field.isFirstResponder { host.text = value }
        host.field.isEnabled = !busy
        progress.isHidden = !busy; proceed.isHidden = busy
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
    }
    private func updateFonts() {
        explanation.font = Appearance.font(14, compatibleWith: traitCollection)
        instruction.font = Appearance.font(14, compatibleWith: traitCollection)
        proceed.setNeedsUpdateConfiguration()
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        updateFonts()
        let width = max(0, size.width - 32)
        // Multiline labels need their actual widths before the horizontal
        // progress row participates in the vertical stack's fitting pass.
        explanation.preferredMaxLayoutWidth = width
        instruction.preferredMaxLayoutWidth = max(0, width - 48 - 8)
        let measured = stack.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return CGSize(width: size.width, height: measured.height + 32)
    }
    override func layoutSubviews() {
        super.layoutSubviews(); updateFonts()
        stack.frame = bounds.insetBy(dx: min(16, bounds.width / 2), dy: 16)
        stack.layoutIfNeeded()
    }
}
