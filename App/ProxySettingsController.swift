import UIKit
import NotTennaPodCore

@MainActor final class ProxySettingsController: SourceMessageController {
    let session: ProxySettingsSession
    let body: ProxySettingsBody
    private var resetHidden = false
    init(preferences: ProxyPreferenceStore,
         test: @escaping @Sendable (PodcastProxy) async throws -> Void = { try await ProxyConnectionTest().run($0) }) {
        session = ProxySettingsSession(preferences: preferences, test: test)
        body = ProxySettingsBody(draft: session.draft)
        // Actions capture a weak box because the message superclass must be
        // initialized before the controller can be captured.
        let owner = WeakProxyController()
        super.init(title: Appearance.text("pref_proxy_title"), message: "",
            positive: .init(title: session.testSuccessful ? Appearance.text("ok") : Appearance.text("proxy_test_label"),
                identifier: "proxyConfirm", perform: { owner.value?.confirm() }, dismisses: false),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "proxyCancel",
                perform: { owner.value?.session.cancel() }),
            neutral: .init(title: Appearance.text("reset"), identifier: "proxyReset", perform: {
                guard let controller = owner.value else { return }
                do { try controller.session.reset() } catch { controller.showStorageError(error) }
            }, dismisses: false), customBody: body)
        owner.value = self; avoidsKeyboard = true
        body.onEdit = { [weak self] in self?.session.edit($0) }
        body.onType = { [weak self] in self?.chooseType() }
        session.onChange = { [weak self] in self?.update() }
        onCancel = { [weak session] in session?.cancel() }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() { super.viewDidLoad(); update() }
    private func update() {
        body.update(draft: session.draft, errors: session.errors, status: session.status)
        updateAction(identifier: "proxyConfirm", title: session.testSuccessful ? Appearance.text("ok") : Appearance.text("proxy_test_label"),
                     isEnabled: !session.isTesting)
        updateAction(identifier: "proxyReset", title: Appearance.text("reset"), isEnabled: true, isHidden: resetHidden)
        view.setNeedsLayout()
    }
    private func confirm() {
        guard session.testSuccessful else { session.verify(); return }
        do { if try session.save() { dismiss(animated: true) } }
        catch { showStorageError(error) }
    }
    private func showStorageError(_ error: Error) {
        body.showFailure(error.localizedDescription); view.setNeedsLayout()
    }
    private func chooseType() {
        body.endEditing(true); body.typeFocused = true
        let menu = PopupMenuController(title: "", identifier: "proxyTypeChoices", anchor: body.type,
            anchorFraction: CGPoint(x: view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? 1 : 0, y: 1),
            actions: PodcastProxy.Kind.allCases.map { ("proxyType-" + $0.rawValue, $0.rawValue) }, matchesAnchorWidth: true, panelColor: Appearance.color(0xdbecf7, 0x293f55)) { [weak self] id in
                guard let self, let kind = PodcastProxy.Kind(rawValue: String(id.dropFirst("proxyType-".count))) else { return }
                resetHidden = kind == .direct
                session.selectType(kind)
            }
        present(menu, animated: true)
    }
}
@MainActor private final class WeakProxyController { weak var value: ProxySettingsController? }

@MainActor final class ProxySettingsBody: UIView, UITextFieldDelegate, SourceMessageBodyViewport, SourceMessageEditingBody {
    let type = ProxyTypeButton(type: .custom)
    let host = UITextField(), port = UITextField(), username = UITextField(), password = UITextField()
    let info = UILabel()
    private let arrow = ProxyTypeArrow()
    private let fieldError = ProxyFieldError()
    private let outlines = (0..<5).map { _ in UIView() }, hints = (0..<5).map { _ in UILabel() }
    private let errorIcons = (0..<4).map { _ in ProxyFieldErrorIcon(type: .custom) }
    private var draft: ProxySettingsDraft
    private var errors: [ProxySettingsDraft.Field: String] = [:]
    var onEdit: ((ProxySettingsDraft) -> Void)?
    var onType: (() -> Void)?
    var typeFocused = true { didSet { setNeedsLayout() } }
    private var fields: [UITextField] { [host, port, username, password] }
    var editingControl: UIView? { fields.first(where: \.isFirstResponder) }
    private var fieldHeight: CGFloat { max(56, Appearance.font(16, compatibleWith: traitCollection).lineHeight + 32) }
    private var labelMargin: CGFloat { floor(Appearance.font(12, compatibleWith: traitCollection).ascender / 2) }
    var minimumMessageViewportHeight: CGFloat { fieldHeight + labelMargin }
    init(draft: ProxySettingsDraft) {
        self.draft = draft; super.init(frame: .zero)
        accessibilityIdentifier = "proxySettingsBody"
        let keys = ["proxy_type_label", "host_label", "port_label", "username_label", "password_label"]
        for i in 0..<5 {
            let outline = outlines[i]; outline.layer.cornerRadius = 4; addSubview(outline)
            let hint = hints[i]; hint.text = Appearance.text(keys[i]); hint.isAccessibilityElement = false
            hint.backgroundColor = Appearance.surfaceVariant; addSubview(hint)
        }
        outlines[0].addSubview(type); type.addSubview(arrow)
        type.contentHorizontalAlignment = .leading
        type.setTitleColor(Appearance.foreground, for: .normal)
        type.accessibilityLabel = Appearance.text("proxy_type_label"); type.accessibilityIdentifier = "proxyType"
        type.addAction(UIAction { [weak self] _ in self?.onType?() }, for: .touchUpInside)
        for (i, field) in fields.enumerated() {
            outlines[i + 1].addSubview(field)
            field.accessibilityIdentifier = ["proxyHost", "proxyPort", "proxyUsername", "proxyPassword"][i]
            field.accessibilityLabel = Appearance.text(keys[i + 1]); field.delegate = self
            field.autocapitalizationType = .none; field.autocorrectionType = .no
            field.textColor = Appearance.foreground; field.tintColor = Appearance.accent
            field.returnKeyType = i == 3 ? .done : .next
            field.addAction(UIAction { [weak self] _ in self?.edited() }, for: .editingChanged)
            let icon = errorIcons[i]; outlines[i + 1].addSubview(icon)
            icon.tintColor = Appearance.color(0xba1a1a, 0xffb4ab)
            icon.accessibilityIdentifier = field.accessibilityIdentifier! + "Error"
            icon.addAction(UIAction { [weak self, weak icon, weak field] _ in
                guard let self, let icon, let field else { return }
                field.becomeFirstResponder()
                if let message = icon.accessibilityLabel { UIAccessibility.post(notification: .announcement, argument: message) }; setNeedsLayout()
            }, for: .touchUpInside)
        }
        host.keyboardType = .URL; port.keyboardType = .numberPad
        username.textContentType = .username; password.textContentType = .password; password.isSecureTextEntry = true
        info.numberOfLines = 0; info.textAlignment = .center; info.accessibilityIdentifier = "proxyStatus"
        addSubview(info); addSubview(fieldError); update(draft: draft, errors: [:], status: .none)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(draft: ProxySettingsDraft, errors: [ProxySettingsDraft.Field: String], status: ProxySettingsSession.Status) {
        self.draft = draft; self.errors = errors
        type.setTitle(draft.kind.rawValue, for: .normal); type.accessibilityValue = draft.kind.rawValue
        for (field, value) in zip(fields, [draft.host, draft.port, draft.username, draft.password]) {
            if field.text != value { field.text = value }
            field.isEnabled = draft.kind != .direct
        }
        switch status {
        case .none: info.text = " "; info.isHidden = true
        case .checking: info.text = Appearance.text("proxy_checking"); info.isHidden = false; info.textColor = Appearance.foreground
        case .succeeded: info.text = Appearance.text("proxy_test_successful"); info.isHidden = false; info.textColor = Appearance.color(0x008537, 0x008537)
        case .failed(let value): showFailure(value)
        }
        setNeedsLayout()
    }
    func showFailure(_ value: String) {
        info.text = Appearance.text("proxy_test_failed") + ": " + value
        info.textColor = Appearance.color(0xcf1800, 0xcf1800); info.isHidden = false; setNeedsLayout()
    }
    private func edited() {
        draft.host = host.text ?? ""; draft.port = port.text ?? ""
        draft.username = username.text ?? ""; draft.password = password.text ?? ""
        onEdit?(draft); setNeedsLayout()
    }
    func messageBodyDidScroll() { setNeedsLayout() }
    func textFieldDidBeginEditing(_ textField: UITextField) { typeFocused = false }
    func textFieldDidEndEditing(_ textField: UITextField) { setNeedsLayout() }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if let i = fields.firstIndex(of: textField), i < 3 { fields[i + 1].becomeFirstResponder() }
        else { textField.resignFirstResponder() }
        return true
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        info.font = Appearance.font(14, compatibleWith: traitCollection)
        let height = max(info.font.lineHeight, info.sizeThatFits(CGSize(width: max(0, size.width - 32), height: .greatestFiniteMagnitude)).height)
        return CGSize(width: size.width, height: 32 + 5 * (fieldHeight + labelMargin) + 40 + height)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = min(16, bounds.width / 2), width = max(0, bounds.width - inset * 2)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        for i in 0..<5 {
            let outline = outlines[i], hint = hints[i]
            let active = i == 0 ? typeFocused : fields[i - 1].isFirstResponder
            let enabled = i == 0 || draft.kind != .direct
            let raised = i == 0 || active || !(fields[i - 1].text ?? "").isEmpty
            outline.frame = CGRect(x: inset, y: 16 + labelMargin + CGFloat(i) * (fieldHeight + labelMargin + 8), width: width, height: fieldHeight)
            outline.layer.borderWidth = active ? 2 : 1
            outline.layer.borderColor = (active ? Appearance.accent : Appearance.foreground.withAlphaComponent(enabled ? 0.38 : 0.16)).resolvedColor(with: traitCollection).cgColor
            hint.font = Appearance.font(12, compatibleWith: traitCollection); hint.isHidden = !raised
            hint.textColor = active ? Appearance.accent : Appearance.foreground.withAlphaComponent(enabled ? 0.6 : 0.38)
            let hintSize = hint.sizeThatFits(CGSize(width: max(0, width - 24), height: .greatestFiniteMagnitude))
            hint.frame = CGRect(x: inset + (rtl ? max(0, width - 12 - hintSize.width) : 12), y: outline.frame.minY - hintSize.height / 2,
                                width: min(hintSize.width, max(0, width - 24)), height: hintSize.height)
            if i == 0 {
                type.frame = outline.bounds
                outline.backgroundColor = active ? Appearance.color(0xeaeff3, 0x293f55) : .clear
                type.titleLabel?.font = Appearance.font(16, compatibleWith: traitCollection)
                arrow.frame = CGRect(x: rtl ? 16 : max(0, type.bounds.width - 40), y: (fieldHeight - 24) / 2, width: 24, height: 24)
                arrow.tintColor = active ? Appearance.accent : Appearance.foreground.withAlphaComponent(0.6)
            } else {
                let field = fields[i - 1], icon = errorIcons[i - 1]
                let error = i == 1 ? errors[.host] : (i == 2 ? errors[.port] : nil)
                icon.isHidden = error == nil; icon.accessibilityLabel = error.map(Appearance.text)
                let trailing: CGFloat = error == nil ? 0 : 32
                field.font = Appearance.font(16, compatibleWith: traitCollection)
                field.textColor = Appearance.foreground.withAlphaComponent(enabled ? 1 : 0.38)
                field.frame = CGRect(x: min(16, width / 2) + (rtl ? trailing : 0), y: 8,
                    width: max(0, width - 32 - trailing), height: max(0, fieldHeight - 16))
                field.attributedPlaceholder = raised ? nil : NSAttributedString(string: field.accessibilityLabel ?? "",
                    attributes: [.font: field.font!, .foregroundColor: hint.textColor!])
                icon.frame = CGRect(x: rtl ? 4 : max(0, width - 36), y: (fieldHeight - 32) / 2, width: 32, height: 32)
            }
        }
        info.font = Appearance.font(14, compatibleWith: traitCollection)
        let top = outlines[4].frame.maxY + 8
        info.frame = CGRect(x: inset, y: top, width: width, height: max(0, bounds.height - top - 16))
        if let index = fields.firstIndex(where: \.isFirstResponder), index < 2,
           let key = errors[index == 0 ? .host : .port] {
            fieldError.isHidden = false
            fieldError.label.text = Appearance.text(key)
            fieldError.label.font = Appearance.font(14, compatibleWith: traitCollection)
            let measured = fieldError.label.sizeThatFits(CGSize(width: max(0, width - 28), height: .greatestFiniteMagnitude))
            let popupWidth = min(width, measured.width + 28), popupHeight = measured.height + 24
            let box = outlines[index + 1].frame
            // Android's anchored error window moves above the field when the
            // lower edge would clip. Use the actual clipped viewport, including
            // keyboard-driven scrolling, rather than the whole body height.
            var visible = bounds, ancestor = superview
            while let parent = ancestor {
                if parent.clipsToBounds { visible = visible.intersection(convert(parent.bounds, from: parent)) }
                ancestor = parent.superview
            }
            let available = visible.isNull ? CGRect.zero : visible
            let height = min(popupHeight, max(0, available.height))
            let below = box.maxY - 4
            let preferredY = below + height <= available.maxY ? below : box.minY - height + 4
            let y = max(available.minY, min(preferredY, available.maxY - height))
            fieldError.frame = CGRect(x: rtl ? inset + 4 : inset + width - popupWidth - 4,
                                      y: y, width: popupWidth, height: height)
            fieldError.pointsDown = below + height > available.maxY
            fieldError.rightToLeft = rtl; fieldError.setNeedsLayout(); fieldError.setNeedsDisplay()
        } else { fieldError.isHidden = true }

    }
}
@MainActor private final class ProxyTypeArrow: UIView {
    override func tintColorDidChange() { super.tintColorDidChange(); setNeedsDisplay() }
    override func draw(_ rect: CGRect) {
        let path = UIBezierPath(); path.move(to: CGPoint(x: rect.midX - 5, y: rect.midY - 2.5))
        path.addLine(to: CGPoint(x: rect.midX + 5, y: rect.midY - 2.5)); path.addLine(to: CGPoint(x: rect.midX, y: rect.midY + 2.5))
        path.close(); tintColor.setFill(); path.fill()
    }
    override init(frame: CGRect) { super.init(frame: frame); isOpaque = false; isUserInteractionEnabled = false }
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor final class ProxyTypeButton: UIButton {
    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        titleLabel?.frame = CGRect(x: rtl ? 48 : 16, y: 0, width: max(0, bounds.width - 64), height: bounds.height)
        titleLabel?.textAlignment = rtl ? .right : .left
        titleLabel?.lineBreakMode = .byTruncatingTail
    }
}
@MainActor private final class ProxyFieldError: UIView {
    let label = UILabel()
    var rightToLeft = false
    var pointsDown = false
    override init(frame: CGRect) {
        super.init(frame: frame); isOpaque = false; isUserInteractionEnabled = false
        label.textColor = .white; label.numberOfLines = 0; label.textAlignment = .center
        label.accessibilityIdentifier = "proxyFieldErrorMessage"; addSubview(label)
        layer.shadowColor = UIColor.black.cgColor; layer.shadowOpacity = 0.3; layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 2)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() { super.layoutSubviews(); label.frame = bounds.insetBy(dx: 14, dy: 12) }
    override func draw(_ rect: CGRect) {
        UIColor(white: 0.08, alpha: 1).setFill()
        UIRectFill(CGRect(x: 0, y: pointsDown ? 0 : 6, width: rect.width, height: max(0, rect.height - 6)))
        UIColor(red: 1, green: 0, blue: 0.25, alpha: 1).setFill()
        let edge: CGFloat = pointsDown ? rect.height - 6 : 6
        UIRectFill(CGRect(x: 0, y: pointsDown ? edge - 2 : edge, width: rect.width, height: 2))
        let x = rightToLeft ? min(20, rect.width / 2) : max(rect.width - 20, rect.width / 2)
        let pointer = UIBezierPath(); pointer.move(to: CGPoint(x: x - 5, y: edge))
        pointer.addLine(to: CGPoint(x: x, y: pointsDown ? rect.height : 0))
        pointer.addLine(to: CGPoint(x: x + 5, y: edge)); pointer.close(); pointer.fill()
    }
}

/// Android EditText's field-error indicator differs from the app's ic_error.
@MainActor private final class ProxyFieldErrorIcon: UIButton {
    override func draw(_ rect: CGRect) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        UIColor(red: 1, green: 0, blue: 0.25, alpha: 1).setFill()
        UIBezierPath(ovalIn: CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)).fill()
        UIColor.white.setFill()
        UIRectFill(CGRect(x: center.x - 1.5, y: center.y - 6, width: 3, height: 7))
        UIRectFill(CGRect(x: center.x - 1.5, y: center.y + 3, width: 3, height: 3))
    }
}
