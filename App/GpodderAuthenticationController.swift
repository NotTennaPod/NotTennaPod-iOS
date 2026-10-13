import UIKit
import NotTennaPodCore

/// Owns only the source-shaped dialog. Authentication and account mutation stay
/// in the application-supplied flow; synchronization starts at explicit Sync now.
@MainActor final class GpodderAuthenticationController: SourceMessageController {
    private let flow: GpodderAuthenticationFlow
    private let body: GpodderAuthenticationBody
    private var actionTask: Task<Void, Never>?
    private var finishing = false

    init(flow: GpodderAuthenticationFlow, onSync: @escaping @MainActor () -> Void,
         onCancel: (() -> Void)? = nil) {
        self.flow = flow
        let body = GpodderAuthenticationBody()
        self.body = body
        super.init(title: Appearance.text("gpodnetauth_login_butLabel"), message: "",
            positive: .init(title: Appearance.text("cancel_label"), identifier: "gpodderCancel", perform: {
                body.clearCredentials(); flow.cancel(); onCancel?()
            }), customBody: body)
        avoidsKeyboard = true
        allowsImplicitCancellation = false
        isModalInPresentation = true
        flow.onChange = { [weak self] in self?.refresh() }
        body.onProceed = { [weak self] in
            guard let self else { return }
            let host = self.body.host.text ?? ""
            perform { await flow.proceed(host: host) }
        }
        body.onLogin = { [weak self] in
            guard let self else { return }
            let username = self.body.username.text ?? "", password = self.body.password.text ?? ""
            perform { await flow.login(username: username, password: password) }
        }
        body.onCreateDevice = { [weak self] in
            guard let self else { return }
            let name = self.body.deviceName.text ?? ""
            perform { await flow.createDevice(name: name) }
        }
        body.onChooseDevice = { [weak self] device in
            guard let self else { return }
            perform { await flow.choose(device: device) }
        }
        body.onSyncNow = { [weak self] in
            guard let self, !finishing else { return }
            finishing = true
            self.body.clearCredentials()
            self.body.isUserInteractionEnabled = false
            updateAction(identifier: "gpodderCancel", title: Appearance.text("cancel_label"), isEnabled: false)
            dismiss(animated: true, completion: onSync)
        }
        body.onEditingChange = { [weak self] in self?.viewIfLoaded?.setNeedsLayout() }
    }
    required init?(coder: NSCoder) { fatalError() }
    isolated deinit { actionTask?.cancel(); flow.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "gpodderAuthentication"
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
        updateTitle(flow.stage == .host ? Appearance.text("gpodnetauth_login_butLabel") : flow.host)
        body.update(flow)
        view.setNeedsLayout()
    }
}

@MainActor private final class GpodderAuthenticationBody: UIView, SourceMessageBodyViewport, SourceMessageEditingBody {
    let host = GpodderAuthenticationField(key: "synchronization_host_label", identifier: "gpodderHost")
    let username = GpodderAuthenticationField(key: "username_label", identifier: "gpodderUsername")
    let password = GpodderAuthenticationField(key: "password_label", identifier: "gpodderPassword")
    let deviceName = GpodderAuthenticationField(key: "gpodnetauth_device_name", identifier: "gpodderDeviceName")
    var onProceed: (() -> Void)?
    var onLogin: (() -> Void)?
    var onCreateDevice: (() -> Void)?
    var onChooseDevice: ((SynchronizationDevice) -> Void)?
    var onSyncNow: (() -> Void)?
    var onEditingChange: (() -> Void)?
    private let stack = UIStackView()
    private let error = Appearance.label(nil, size: 14)
    private let warning = Appearance.label(Appearance.text("gpodnetauth_encryption_warning"), size: 14, bold: true)
    private let spinner = UIActivityIndicatorView(style: .large)
    private let spinnerRow = UIView()
    private var stage: GpodderAuthenticationFlow.Stage?
    private var outgoingStage: UIView?
    private var buttons: [UIButton] = []
    private var labels: [(UILabel, CGFloat, UIFont.Weight)] = []
    var editingControl: UIView? { [host, username, password, deviceName].first { $0.field.isFirstResponder } }
    var minimumMessageViewportHeight: CGFloat { host.intrinsicContentSize.height }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "gpodderAuthenticationBody"
        stack.axis = .vertical; stack.alignment = .fill; addSubview(stack)
        error.textColor = Appearance.color(0xb3261e, 0xf2b8b5)
        error.accessibilityIdentifier = "gpodderAuthenticationError"
        warning.textColor = error.textColor; warning.accessibilityIdentifier = "gpodderEncryptionWarning"
        password.field.isSecureTextEntry = true
        username.field.textContentType = .username; password.field.textContentType = .password
        host.field.keyboardType = .URL
        host.field.returnKeyType = .next; username.field.returnKeyType = .next
        password.field.returnKeyType = .go; deviceName.field.returnKeyType = .done
        host.onReturn = { [weak self] in self?.onProceed?() }
        username.onReturn = { [weak self] in self?.password.field.becomeFirstResponder() }
        password.onReturn = { [weak self] in self?.onLogin?() }
        deviceName.onReturn = { [weak self] in self?.onCreateDevice?() }
        for field in [host, username, password, deviceName] {
            field.onEditingChange = { [weak self] in self?.onEditingChange?() }
        }
        spinner.color = Appearance.accent; spinner.accessibilityIdentifier = "gpodderAuthenticationProgress"
        spinnerRow.addSubview(spinner)
        let spinnerHeight = spinnerRow.heightAnchor.constraint(equalToConstant: 48)
        spinnerHeight.priority = .init(999); spinnerHeight.isActive = true
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self]) { (body: GpodderAuthenticationBody, _) in
            body.invalidateIntrinsicContentSize(); body.setNeedsLayout(); body.onEditingChange?()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func clearCredentials() { password.text = nil }
    func messageBodyDidScroll() { setNeedsLayout() }

    func update(_ flow: GpodderAuthenticationFlow) {
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
                addButton("proceed_to_login_butLabel", identifier: "gpodderProceed") { [weak self] in self?.onProceed?() }
            case .credentials:
                addLabel("synchronization_credentials_explanation", spacing: 16)
                // Android INVISIBLE retains this warning's space for HTTPS.
                warning.alpha = flow.host.hasPrefix("http://") ? 1 : 0
                warning.accessibilityElementsHidden = warning.alpha == 0
                labels.append((warning, 14, .bold)); add(warning)
                add(username); add(password, spacing: 16); add(spinnerRow); add(error)
                error.textAlignment = .center; error.numberOfLines = 2; error.lineBreakMode = .byTruncatingTail
                addButton("synchronization_login_butLabel", identifier: "gpodderLogin") { [weak self] in self?.onLogin?() }
            case .devices:
                clearCredentials()
                deviceName.text = flow.suggestedDeviceName
                addLabel("synchronization_selectDevice_explanation", spacing: 16)
                add(deviceName)
                addButton("gpodnetauth_create_device", identifier: "gpodderCreateDevice", trailing: true, spacing: 16) { [weak self] in self?.onCreateDevice?() }
                addLabel("gpodnetauth_existing_devices", heading: true)
                error.textAlignment = .natural; error.numberOfLines = 0; add(error)
                for device in flow.devices {
                    let spacer = UIView(); spacer.heightAnchor.constraint(equalToConstant: 8).isActive = true; add(spacer)
                    addButton(device.caption, identifier: "gpodderDevice-\(device.id)", localized: false, outlined: true) { [weak self] in
                        self?.onChooseDevice?(device)
                    }
                }
                add(spinnerRow)
            case .finish:
                clearCredentials()
                let icon = UIImageView(image: UIImage(named: "gpodder_icon"))
                icon.contentMode = .scaleAspectFit; icon.isAccessibilityElement = false
                icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
                let row = UIStackView(arrangedSubviews: [icon, UIView()]); row.axis = .horizontal; add(row)
                addLabel("gpodnetauth_finish_descr", spacing: 8)
                addButton("synchronization_sync_changes_title", identifier: "gpodderSyncNow") { [weak self] in self?.onSyncNow?() }
            }
        }
        error.text = flow.error; error.isHidden = flow.error == nil
        spinnerRow.isHidden = !flow.busy
        if flow.busy { spinner.startAnimating() } else { spinner.stopAnimating() }
        for button in buttons { button.isEnabled = !flow.busy }
        for field in [host, username, password, deviceName] { field.field.isEnabled = !flow.busy }
        invalidateIntrinsicContentSize(); setNeedsLayout()
    }

    private func add(_ child: UIView, spacing: CGFloat = 0) {
        stack.addArrangedSubview(child); stack.setCustomSpacing(spacing, after: child)
    }
    private func addLabel(_ key: String, heading: Bool = false, spacing: CGFloat = 0) {
        let label = Appearance.label(Appearance.text(key), size: heading ? 22 : 14)
        label.accessibilityIdentifier = key
        label.adjustsFontForContentSizeCategory = false
        if heading { label.accessibilityTraits.insert(.header) }
        label.textColor = heading || key == "gpodnetauth_finish_descr" ? Appearance.foreground : Appearance.secondary
        labels.append((label, heading ? 22 : 14, heading ? .light : .regular)); add(label, spacing: spacing)
    }
    private func addButton(_ key: String, identifier: String, localized: Bool = true,
                           outlined: Bool = false, trailing: Bool = false, spacing: CGFloat = 0,
                           action: @escaping () -> Void) {
        let button = UIButton(type: .custom)
        var configuration = UIButton.Configuration.filled()
        configuration.title = localized ? Appearance.text(key) : key
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 24)
        configuration.background.backgroundInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
        button.configuration = configuration
        button.configurationUpdateHandler = { button in
            button.configuration?.baseForegroundColor = button.isEnabled ? (outlined ? Appearance.accent : .white) : Appearance.foreground.withAlphaComponent(0.38)
            button.configuration?.baseBackgroundColor = outlined ? .clear : (button.isEnabled ? Appearance.accent : Appearance.foreground.withAlphaComponent(0.12))
            button.configuration?.background.strokeWidth = outlined ? 1 : 0
            button.configuration?.background.strokeColor = Appearance.foreground.withAlphaComponent(0.38)
            let font = Appearance.font(14, medium: true, compatibleWith: button.traitCollection)
            button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var result = attributes; result.font = font; return result
            }
        }
        button.accessibilityIdentifier = identifier
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        buttons.append(button)
        if trailing {
            let row = UIStackView(arrangedSubviews: [UIView(), button]); row.axis = .horizontal; add(row, spacing: spacing)
        } else { add(button, spacing: spacing) }
    }

    private func updateFonts() {
        for (label, size, weight) in labels {
            if weight == .light {
                guard let font = UIFont(name: "Roboto-Light", size: size) else { preconditionFailure("Required Roboto Light instance unavailable") }
                label.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: font, compatibleWith: traitCollection)
            } else { label.font = Appearance.font(size, bold: weight == .bold, compatibleWith: traitCollection) }
        }
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
            // Source ViewFlipper uses physical right-in/left-out over300ms.
            // Layer presentation animation leaves editable model geometry and
            // the retained fields untouched during subsequent size changes.
            let incoming = CABasicAnimation(keyPath: "transform.translation.x")
            incoming.fromValue = stack.bounds.width; incoming.toValue = 0
            incoming.duration = 0.3; incoming.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            stack.layer.add(incoming, forKey: "gpodderStageIn")
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
                outgoing.transform = CGAffineTransform(translationX: -outgoing.bounds.width, y: 0)
            } completion: { _ in outgoing.removeFromSuperview() }
        }
    }
}

/// TextInputLayout's outlined field, with a retained floating hint and no
/// password-reveal affordance (the source auth layout does not provide one).
@MainActor final class GpodderAuthenticationField: UIView, UITextFieldDelegate {
    let field = UITextField()
    private let outline = GpodderAuthenticationOutline(), hint = UILabel()
    var onReturn: (() -> Void)?
    var onEditingChange: (() -> Void)?
    var text: String? {
        get { field.text }
        set { field.text = newValue; setNeedsLayout() }
    }
    private var fieldHeight: CGFloat { max(56, Appearance.font(16, compatibleWith: traitCollection).lineHeight + 32) }
    private var labelMargin: CGFloat { floor(Appearance.font(12, compatibleWith: traitCollection).ascender / 2) }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: fieldHeight + labelMargin) }

    init(key: String, identifier: String) {
        super.init(frame: .zero)
        field.accessibilityIdentifier = identifier; field.accessibilityLabel = Appearance.text(key)
        field.autocapitalizationType = .none; field.autocorrectionType = .no; field.spellCheckingType = .no
        field.textColor = Appearance.foreground; field.tintColor = Appearance.accent; field.delegate = self
        field.addAction(UIAction { [weak self] _ in self?.setNeedsLayout(); self?.onEditingChange?() }, for: .editingChanged)
        addSubview(outline); outline.addSubview(field)
        hint.text = field.accessibilityLabel; hint.isAccessibilityElement = false
        hint.backgroundColor = .clear; outline.addSubview(hint)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self]) { (view: GpodderAuthenticationField, _) in
            view.invalidateIntrinsicContentSize(); view.setNeedsLayout()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { onReturn?(); return true }
    func textFieldDidBeginEditing(_ textField: UITextField) { setNeedsLayout(); onEditingChange?() }
    func textFieldDidEndEditing(_ textField: UITextField) { setNeedsLayout(); onEditingChange?() }
    override func layoutSubviews() {
        super.layoutSubviews()
        outline.frame = CGRect(x: 0, y: labelMargin, width: bounds.width, height: fieldHeight)
        let active = field.isFirstResponder, raised = field.isFirstResponder || !(field.text ?? "").isEmpty
        field.font = Appearance.font(16, compatibleWith: traitCollection)
        field.frame = outline.bounds.insetBy(dx: min(16, outline.bounds.width / 2), dy: 8)
        field.attributedPlaceholder = raised ? nil : NSAttributedString(string: field.accessibilityLabel ?? "",
            attributes: [.font: field.font!, .foregroundColor: Appearance.foreground.withAlphaComponent(0.6)])
        outline.strokeWidth = active ? 2 : 1
        outline.strokeColor = active ? Appearance.accent : Appearance.foreground.withAlphaComponent(0.38)
        hint.isHidden = !raised; hint.font = Appearance.font(12, compatibleWith: traitCollection)
        hint.textColor = active ? Appearance.accent : Appearance.foreground.withAlphaComponent(0.6)
        let size = hint.sizeThatFits(CGSize(width: max(0, bounds.width - 32), height: .greatestFiniteMagnitude))
        hint.frame = CGRect(x: effectiveUserInterfaceLayoutDirection == .rightToLeft ? max(0, bounds.width - 16 - size.width) : 16,
            y: -size.height / 2, width: min(size.width, max(0, bounds.width - 32)), height: size.height)
        // TextInputLayout cuts the stroke out four units beyond either side
        // of the floating hint; painting an opaque label does not cut a layer border.
        outline.hintCutout = raised ? hint.frame.insetBy(dx: -4, dy: 0) : nil
        outline.setNeedsDisplay()
    }
}

/// Draw below the text children, with a genuine transparent hint cutout. This
/// also works over any parent surface without a hard-coded label background.
@MainActor private final class GpodderAuthenticationOutline: UIView {
    var strokeWidth: CGFloat = 1
    var strokeColor: UIColor = .clear
    var hintCutout: CGRect?
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), bounds.width > strokeWidth,
              bounds.height > strokeWidth else { return }
        context.saveGState()
        if let hintCutout {
            context.addRect(bounds)
            context.addRect(hintCutout)
            context.clip(using: .evenOdd)
        }
        strokeColor.resolvedColor(with: traitCollection).setStroke()
        let path = UIBezierPath(roundedRect: bounds.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2),
                                cornerRadius: max(0, 4 - strokeWidth / 2))
        path.lineWidth = strokeWidth
        path.stroke()
        context.restoreGState()
    }
}
