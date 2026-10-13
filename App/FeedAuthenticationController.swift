import UIKit
import NotTennaPodCore

@MainActor enum FeedAuthenticationController {
    enum Purpose { case preview, settings }
    static func make(purpose: Purpose = .preview, credentials: FeedCredentials?, confirm: @escaping (FeedCredentials) -> Void,
                     cancel: @escaping () -> Void) -> SourceMessageController {
        let body = FeedAuthenticationBody(credentials: credentials)
        let controller = FeedAuthenticationMessageController(title: Appearance.text(purpose == .settings ? "authentication_label" : "authentication_notification_title"), message: "",
            positive: .init(title: Appearance.text("confirm_label"), identifier: "feedAuthenticationConfirm", perform: {
                confirm(.init(username: body.username.text ?? "", password: body.password.text ?? ""))
            }, performAfterDismiss: true),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "feedAuthenticationCancel",
                            perform: cancel, performAfterDismiss: true), customBody: body)
        controller.avoidsKeyboard = true
        controller.reportsFailure = purpose == .preview && credentials != nil
        controller.onCancelAfterDismiss = cancel
        return controller
    }
}

@MainActor private final class FeedAuthenticationMessageController: SourceMessageController {
    var reportsFailure = false
    private var noticeTask: Task<Void, Never>?
    deinit { noticeTask?.cancel() }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard reportsFailure else { return }; reportsFailure = false
        let label = Appearance.label(Appearance.text("download_error_unauthorized"), size: 14)
        label.numberOfLines = 0; label.textAlignment = .center
        label.accessibilityIdentifier = "feedAuthenticationFailure"
        // The rounded toast pads its text so the corners never clip a wrapped message.
        let notice = UIView(); notice.isUserInteractionEnabled = false
        notice.backgroundColor = Appearance.navigation; notice.layer.cornerRadius = 20
        label.translatesAutoresizingMaskIntoConstraints = false; notice.addSubview(label)
        notice.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(notice)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: notice.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: notice.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: notice.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: notice.bottomAnchor, constant: -12),
            notice.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            notice.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            notice.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor, constant: -48),
            notice.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        ])
        UIAccessibility.post(notification: .announcement, argument: label.text)
        noticeTask = Task { [weak notice] in
            do { try await Task.sleep(for: .milliseconds(3500)) } catch { return }
            notice?.removeFromSuperview()
        }
    }
}

@MainActor final class FeedAuthenticationBody: UIView, UITextFieldDelegate, SourceMessageBodyViewport, SourceMessageEditingBody {
    let username = UITextField(), password = UITextField()
    private let outlines = [UIView(), UIView()], hints = [UILabel(), UILabel()]
    private var eye: UIButton!
    var editingControl: UIView? { [username, password].first(where: \.isFirstResponder) }
    var minimumMessageViewportHeight: CGFloat { fieldHeight }
    private var fieldHeight: CGFloat { max(56, Appearance.font(16, compatibleWith: traitCollection).lineHeight + 32) }
    // Outlined TextInputLayout reserves half the collapsed label's ascent above
    // each box, even while the empty field is displaying its full-size hint.
    private var labelMargin: CGFloat { floor(Appearance.font(12, compatibleWith: traitCollection).ascender / 2) }

    init(credentials: FeedCredentials?) {
        super.init(frame: .zero)
        accessibilityIdentifier = "feedAuthenticationBody"
        username.text = credentials?.username; password.text = credentials?.password
        password.isSecureTextEntry = true
        username.textContentType = .username; password.textContentType = .password
        username.returnKeyType = .next; password.returnKeyType = .done
        for (index, field) in [username, password].enumerated() {
            field.accessibilityIdentifier = index == 0 ? "feedUsername" : "feedPassword"
            field.accessibilityLabel = Appearance.text(index == 0 ? "username_label" : "password_label")
            field.autocapitalizationType = .none; field.autocorrectionType = .no
            field.textColor = Appearance.foreground; field.tintColor = Appearance.accent; field.delegate = self
            field.addAction(UIAction { [weak self] _ in self?.setNeedsLayout() }, for: .editingChanged)
            let outline = outlines[index]
            outline.layer.cornerRadius = 4; addSubview(outline); outline.addSubview(field)
            let hint = hints[index]
            hint.isAccessibilityElement = false; hint.text = field.accessibilityLabel
            hint.backgroundColor = Appearance.surfaceVariant; outline.addSubview(hint)
        }
        eye = Appearance.icon("ic_eye", label: Appearance.text("show_password_accessibility")) { [weak self] in
            guard let self else { return }
            let selection = password.selectedTextRange
            password.isSecureTextEntry.toggle()
            if let selection { password.selectedTextRange = selection }
            eye.alpha = password.isSecureTextEntry ? 0.6 : 1
        }
        eye.accessibilityIdentifier = "feedPasswordVisibility"; eye.alpha = 0.6
        eye.tintColor = Appearance.foreground; addSubview(eye)
    }
    required init?(coder: NSCoder) { fatalError() }
    func messageBodyDidScroll() { setNeedsLayout() }
    func textFieldDidBeginEditing(_ textField: UITextField) { setNeedsLayout() }
    func textFieldDidEndEditing(_ textField: UITextField) { setNeedsLayout() }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === username { password.becomeFirstResponder() } else { password.resignFirstResponder() }
        return true
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize { .init(width: size.width, height: 32 + (fieldHeight + labelMargin) * 2 + 8) }
    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = min(16, bounds.width / 2), width = max(0, bounds.width - 2 * inset)
        let eyeWidth = min(40, width), gap = min(8, max(0, width - eyeWidth))
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let y = 16 + labelMargin * 2 + fieldHeight + 8
        outlines[0].frame = CGRect(x: inset, y: 16 + labelMargin, width: width, height: fieldHeight)
        outlines[1].frame = CGRect(x: inset + (rtl ? eyeWidth + gap : 0), y: y,
                                   width: max(0, width - eyeWidth - gap), height: fieldHeight)
        eye.frame = CGRect(x: rtl ? inset : inset + width - eyeWidth, y: y + (fieldHeight - 40) / 2, width: eyeWidth, height: 40)
        for (index, field) in [username, password].enumerated() {
            let outline = outlines[index], hint = hints[index], active = field.isFirstResponder
            let raised = active || !(field.text ?? "").isEmpty
            field.font = Appearance.font(16, compatibleWith: traitCollection)
            field.frame = outline.bounds.insetBy(dx: min(16, outline.bounds.width / 2), dy: 8)
            field.attributedPlaceholder = raised ? nil : NSAttributedString(string: field.accessibilityLabel ?? "",
                attributes: [.font: field.font!, .foregroundColor: Appearance.foreground.withAlphaComponent(0.6)])
            outline.layer.borderWidth = active ? 2 : 1
            outline.layer.borderColor = (active ? Appearance.accent : Appearance.foreground.withAlphaComponent(0.38)).resolvedColor(with: traitCollection).cgColor
            hint.isHidden = !raised; hint.font = Appearance.font(12, compatibleWith: traitCollection)
            hint.textColor = active ? Appearance.accent : Appearance.foreground.withAlphaComponent(0.6)
            let size = hint.sizeThatFits(CGSize(width: max(0, outline.bounds.width - 24), height: .greatestFiniteMagnitude))
            hint.frame = CGRect(x: rtl ? max(0, outline.bounds.width - 12 - size.width) : 12, y: -size.height / 2,
                                width: min(size.width, max(0, outline.bounds.width - 24)), height: size.height)
        }
    }
}
