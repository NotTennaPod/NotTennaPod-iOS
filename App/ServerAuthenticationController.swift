import UIKit
import NotTennaPodCore

/// The NotTennaPod server's sign-in dialog (PROTOCOL §15.5), modelled on gpodder.net's: the server address,
/// then the credentials, with Android's wording and fields. A successful sign-in closes it and hands the unconfirmed
/// sign-in to the attachment or resume confirmation; nothing is stored before that.
@MainActor final class ServerAuthenticationController: SourceMessageController {
    private let flow: ServerSignInFlow
    private let body: ServerAuthenticationBody
    private var actionTask: Task<Void, Never>?
    private var finishing = false

    init(flow: ServerSignInFlow, onSignedIn: @escaping @MainActor (ServerPendingSignIn) -> Void) {
        self.flow = flow
        let body = ServerAuthenticationBody()
        self.body = body
        super.init(title: Appearance.text("gpodnetauth_login_butLabel"), message: "",
            positive: .init(title: Appearance.text("cancel_label"), identifier: "serverCancel", perform: {
                body.clearCredentials(); flow.cancel()
            }), customBody: body)
        avoidsKeyboard = true
        allowsImplicitCancellation = false
        isModalInPresentation = true
        flow.onChange = { [weak self] in self?.refresh() }
        body.username.text = flow.suggestedUsername
        body.onProceed = { [weak self] in
            guard let self else { return }
            let host = self.body.host.text ?? ""
            perform { await flow.proceed(host: host) }
        }
        body.onLogin = { [weak self] in
            guard let self else { return }
            let username = self.body.username.text ?? "", password = self.body.password.text ?? ""
            perform { [weak self] in
                guard let pending = await flow.login(username: username, password: password), let self, !self.finishing else { return }
                self.finishing = true
                self.body.clearCredentials()
                self.body.isUserInteractionEnabled = false
                self.dismiss(animated: true) { onSignedIn(pending) }
            }
        }
        body.onEditingChange = { [weak self] in self?.viewIfLoaded?.setNeedsLayout() }
    }
    required init?(coder: NSCoder) { fatalError() }
    isolated deinit { actionTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "serverAuthentication"
        refresh()
    }

    private func perform(_ operation: @escaping @MainActor () async -> Void) {
        guard !flow.busy, !finishing else { return }
        view.endEditing(true)
        actionTask?.cancel()
        actionTask = Task { await operation() }
    }

    private func refresh() {
        guard isViewLoaded, !finishing else { return }
        updateTitle(flow.stage == .host ? Appearance.text("gpodnetauth_login_butLabel") : flow.address?.string ?? "")
        body.update(flow)
        view.setNeedsLayout()
    }
}

@MainActor private final class ServerAuthenticationBody: UIView, SourceMessageBodyViewport, SourceMessageEditingBody {
    let host = GpodderAuthenticationField(key: "synchronization_host_label", identifier: "serverHost")
    let username = GpodderAuthenticationField(key: "username_label", identifier: "serverUsername")
    let password = GpodderAuthenticationField(key: "password_label", identifier: "serverPassword")
    var onProceed: (() -> Void)?
    var onLogin: (() -> Void)?
    var onEditingChange: (() -> Void)?
    private let stack = UIStackView()
    private let error = Appearance.label(nil, size: 14)
    private let warning = Appearance.label(Appearance.text("gpodnetauth_encryption_warning"), size: 14, bold: true)
    private let spinner = UIActivityIndicatorView(style: .large)
    private let spinnerRow = UIView()
    private var stage: ServerSignInFlow.Stage?
    private var outgoingStage: UIView?
    private var buttons: [UIButton] = []
    private var labels: [(UILabel, CGFloat, Bool)] = []
    var editingControl: UIView? { [host, username, password].first { $0.field.isFirstResponder } }
    var minimumMessageViewportHeight: CGFloat { host.intrinsicContentSize.height }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "serverAuthenticationBody"
        stack.axis = .vertical; stack.alignment = .fill; addSubview(stack)
        error.textColor = Appearance.color(0xb3261e, 0xf2b8b5)
        error.accessibilityIdentifier = "serverAuthenticationError"
        warning.textColor = error.textColor; warning.accessibilityIdentifier = "serverEncryptionWarning"
        password.field.isSecureTextEntry = true
        username.field.textContentType = .username; password.field.textContentType = .password
        host.field.keyboardType = .URL
        host.field.returnKeyType = .next; username.field.returnKeyType = .next; password.field.returnKeyType = .go
        host.onReturn = { [weak self] in self?.onProceed?() }
        username.onReturn = { [weak self] in self?.password.field.becomeFirstResponder() }
        password.onReturn = { [weak self] in self?.onLogin?() }
        for field in [host, username, password] { field.onEditingChange = { [weak self] in self?.onEditingChange?() } }
        spinner.color = Appearance.accent; spinner.accessibilityIdentifier = "serverAuthenticationProgress"
        spinnerRow.addSubview(spinner)
        let spinnerHeight = spinnerRow.heightAnchor.constraint(equalToConstant: 48)
        spinnerHeight.priority = .init(999); spinnerHeight.isActive = true
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self]) { (body: ServerAuthenticationBody, _) in
            body.invalidateIntrinsicContentSize(); body.setNeedsLayout(); body.onEditingChange?()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func clearCredentials() { password.text = nil }
    func messageBodyDidScroll() { setNeedsLayout() }

    func update(_ flow: ServerSignInFlow) {
        if stage != flow.stage {
            outgoingStage?.removeFromSuperview()
            outgoingStage = nil
            if stage != nil, window != nil, !UIAccessibility.isReduceMotionEnabled {
                outgoingStage = stack.snapshotView(afterScreenUpdates: false)
                outgoingStage?.isUserInteractionEnabled = false
                outgoingStage?.accessibilityElementsHidden = true
                outgoingStage?.frame = stack.frame
                if let outgoingStage { addSubview(outgoingStage) }
            }
            endEditing(true)
            stage = flow.stage
            stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
            buttons.removeAll(); labels.removeAll()
            switch flow.stage {
            case .host:
                addLabel("synchronization_host_explanation", spacing: 16)
                add(host, spacing: 16); add(error)
                error.textAlignment = .natural; error.numberOfLines = 0
                addButton("proceed_to_login_butLabel", identifier: "serverProceed") { [weak self] in self?.onProceed?() }
            case .credentials:
                addLabel("synchronization_credentials_explanation", spacing: 16)
                // As Android's INVISIBLE warning, it keeps its space when the connection is encrypted.
                warning.alpha = flow.showsEncryptionWarning ? 1 : 0
                warning.accessibilityElementsHidden = warning.alpha == 0
                labels.append((warning, 14, true)); add(warning)
                add(username); add(password, spacing: 16); add(spinnerRow); add(error)
                error.textAlignment = .center; error.numberOfLines = 0
                addButton("synchronization_login_butLabel", identifier: "serverLogin") { [weak self] in self?.onLogin?() }
            }
        }
        error.text = flow.error.map(ServerSynchronizationText.message(for:)); error.isHidden = flow.error == nil
        spinnerRow.isHidden = !flow.busy
        if flow.busy { spinner.startAnimating() } else { spinner.stopAnimating() }
        for button in buttons { button.isEnabled = !flow.busy }
        for field in [host, username, password] { field.field.isEnabled = !flow.busy }
        invalidateIntrinsicContentSize(); setNeedsLayout()
    }

    private func add(_ child: UIView, spacing: CGFloat = 0) {
        stack.addArrangedSubview(child); stack.setCustomSpacing(spacing, after: child)
    }
    private func addLabel(_ key: String, spacing: CGFloat = 0) {
        let label = Appearance.label(Appearance.text(key), size: 14)
        label.accessibilityIdentifier = key
        label.adjustsFontForContentSizeCategory = false
        label.textColor = Appearance.secondary
        labels.append((label, 14, false)); add(label, spacing: spacing)
    }
    /// The gpodder.net dialog's filled button.
    private func addButton(_ key: String, identifier: String, action: @escaping () -> Void) {
        let button = UIButton(type: .custom)
        var configuration = UIButton.Configuration.filled()
        configuration.title = Appearance.text(key)
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 24)
        configuration.background.backgroundInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
        button.configuration = configuration
        button.configurationUpdateHandler = { button in
            button.configuration?.baseForegroundColor = button.isEnabled ? .white : Appearance.foreground.withAlphaComponent(0.38)
            button.configuration?.baseBackgroundColor = button.isEnabled ? Appearance.accent : Appearance.foreground.withAlphaComponent(0.12)
            let font = Appearance.font(14, medium: true, compatibleWith: button.traitCollection)
            button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var result = attributes; result.font = font; return result
            }
        }
        button.accessibilityIdentifier = identifier
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        buttons.append(button); add(button)
    }

    private func updateFonts() {
        for (label, size, bold) in labels { label.font = Appearance.font(size, bold: bold, compatibleWith: traitCollection) }
        error.font = Appearance.font(14, compatibleWith: traitCollection)
        for button in buttons { button.setNeedsUpdateConfiguration() }
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        updateFonts()
        let width = max(0, size.width - 32)
        let content = stack.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return CGSize(width: size.width, height: content.height + 32)
    }
    override func layoutSubviews() {
        super.layoutSubviews(); updateFonts()
        stack.frame = bounds.insetBy(dx: min(16, bounds.width / 2), dy: 16)
        stack.layoutIfNeeded()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        spinner.frame = CGRect(x: rtl ? 0 : max(0, spinnerRow.bounds.width - 48), y: 0, width: 48, height: 48)
        if let outgoing = outgoingStage {
            outgoingStage = nil
            // The gpodder.net dialog's ViewFlipper transition: the next stage slides in over 300 ms.
            let incoming = CABasicAnimation(keyPath: "transform.translation.x")
            incoming.fromValue = stack.bounds.width; incoming.toValue = 0
            incoming.duration = 0.3; incoming.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            stack.layer.add(incoming, forKey: "serverStageIn")
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                outgoing.transform = CGAffineTransform(translationX: -outgoing.bounds.width, y: 0)
            } completion: { _ in outgoing.removeFromSuperview() }
        }
    }
}
