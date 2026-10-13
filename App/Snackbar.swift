import UIKit

/// Material3 snackbar with an optional independently owned action. The shell supplies the source anchor region
/// in local coordinates; resizing does not replace the message or its timer.
@MainActor final class Snackbar: UIView, UIGestureRecognizerDelegate {
    struct Action {
        let title: String
        let identifier: String
        let perform: () -> Void
    }
    private final class FocusLabel: UILabel {
        var focusChanged: ((Bool) -> Void)?
        override func accessibilityElementDidBecomeFocused() { super.accessibilityElementDidBecomeFocused(); focusChanged?(true) }
        override func accessibilityElementDidLoseFocus() { super.accessibilityElementDidLoseFocus(); focusChanged?(false) }
    }
    private final class FocusButton: UIButton {
        var focusChanged: ((Bool) -> Void)?
        override func accessibilityElementDidBecomeFocused() { super.accessibilityElementDidBecomeFocused(); focusChanged?(true) }
        override func accessibilityElementDidLoseFocus() { super.accessibilityElementDidLoseFocus(); focusChanged?(false) }
    }
    let label: UILabel = FocusLabel()
    private let actionButton = FocusButton(type: .system)
    private let action: Action?
    private let actionTimeout: Duration?
    private let retainUnvisitedForVoiceOver: Bool
    private let voiceOverRunning: () -> Bool
    private var appeared = false
    private var retainingUnvisited = false
    private var voiceOverWasRunning = false
    private var ignoreStaleVoiceOverFocus = false
    private var actionConsumed = false
    var message: String { didSet { updateText(); setNeedsLayout() } }
    var wide = false { didSet { label.numberOfLines = wide ? 1 : 2; setNeedsLayout() } }
    var swipeEnabled = true
    var onDismiss: (() -> Void)?
    var onNeedsLayout: (() -> Void)?
    private var timeout: Task<Void, Never>?
    private var presenting = true
    private var interacting = false
    private var focusedElements: Set<ObjectIdentifier> = []
    private var focusExit: Task<Void, Never>?
    private var dismissed = false
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
    private lazy var touch = UILongPressGestureRecognizer(target: self, action: #selector(touched(_:)))

    /// Undo offers can retain an unvisited action when VoiceOver is already on.
    /// After first focus, the existing focus/touch pauses and full ordinary grace
    /// apply. Other notices keep their original timing; nil remains test-injected.
    init(message: String, action: Action? = nil, actionTimeout: Duration? = .milliseconds(2_750),
         retainUnvisitedForVoiceOver: Bool = false,
         voiceOverRunning: @escaping () -> Bool = { UIAccessibility.isVoiceOverRunning }) {
        self.message = message; self.action = action; self.actionTimeout = actionTimeout
        self.retainUnvisitedForVoiceOver = retainUnvisitedForVoiceOver && action != nil
        self.voiceOverRunning = voiceOverRunning
        super.init(frame: .zero)
        backgroundColor = Appearance.color(0x121318, 0xfaf8ff)
        layer.cornerRadius = 4
        layer.shadowColor = UIColor.black.cgColor; layer.shadowOpacity = 0.22
        layer.shadowRadius = 3; layer.shadowOffset = CGSize(width: 0, height: 3)
        label.textColor = Appearance.color(0xe2e2e9, 0x1a1b20)
        label.numberOfLines = 2; label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        (label as? FocusLabel)?.focusChanged = { [weak self] focused in
            guard let self else { return }; updateAssistiveFocus(label, focused: focused)
        }
        actionButton.focusChanged = { [weak self] focused in
            guard let self else { return }; updateAssistiveFocus(actionButton, focused: focused)
        }
        isAccessibilityElement = action == nil; accessibilityLabel = message
        if let action {
            label.isAccessibilityElement = true
            actionButton.setTitle(action.title, for: .normal)
            actionButton.accessibilityIdentifier = action.identifier
            actionButton.tintColor = Appearance.color(0xcdd9e4, 0x25365a)
            actionButton.addAction(UIAction { [weak self] _ in self?.pauseTimeout() }, for: .touchDown)
            actionButton.addAction(UIAction { [weak self] _ in self?.resumeTimeout() }, for: [.touchCancel, .touchUpOutside])
            actionButton.addAction(UIAction { [weak self] _ in self?.performAction() }, for: .touchUpInside)
            addSubview(actionButton)
            accessibilityElements = [label, actionButton]
        }
        accessibilityIdentifier = "synchronizationErrorSnackbar"
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: Appearance.text("dismiss_label"), target: self, selector: #selector(accessibilityDismiss))]
        pan.delegate = self; addGestureRecognizer(pan)
        touch.minimumPressDuration = 0; touch.delegate = self; addGestureRecognizer(touch)
        label.accessibilityCustomActions = accessibilityCustomActions
        if self.retainUnvisitedForVoiceOver {
            NotificationCenter.default.addObserver(self, selector: #selector(voiceOverStatusChanged),
                name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
        }
        updateText()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Snackbar, _) in
            self.updateText(); self.onNeedsLayout?()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timeout?.cancel(); focusExit?.cancel() }

    private func updateText() {
        let font = Appearance.font(14, compatibleWith: traitCollection)
        label.font = font
        actionButton.titleLabel?.font = Appearance.font(14, medium: true, compatibleWith: traitCollection)
        let scale = font.pointSize / 14
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 20 * scale; paragraph.maximumLineHeight = 20 * scale
        paragraph.lineBreakMode = .byTruncatingTail
        label.attributedText = NSAttributedString(string: message, attributes: [
            .font: font, .foregroundColor: label.textColor!, .kern: 0.25 * scale, .paragraphStyle: paragraph])
        accessibilityLabel = message
    }
    func place(in region: CGRect, wide: Bool) {
        self.wide = wide
        let available = max(0, region.width - 16)
        let oneLine = label.attributedText?.size().width ?? 0
        let actionWidth = action == nil ? 0 : max(48, actionButton.sizeThatFits(CGSize(width: available, height: 48)).width + 16)
        let width = wide ? min(available, 576, max(320, ceil(oneLine) + 32 + actionWidth)) : available
        let reserved = action == nil ? 0 : min(actionWidth, max(0, width / 2))
        let fitting = label.sizeThatFits(CGSize(width: max(1, width - 32 - reserved), height: .greatestFiniteMagnitude))
        let line = 20 * label.font.pointSize / 14
        let multiline = !wide && fitting.height > line + 1
        let height = ceil(min(fitting.height, line * (wide ? 1 : 2))) + (multiline ? 32 : 28)
        // Avoid transformed-frame geometry while fading/scaling or dragging.
        bounds.size = CGSize(width: width, height: height)
        center = CGPoint(x: region.midX, y: region.maxY - 8 - height / 2)
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let actionWidth = action == nil ? 0 : min(max(48, actionButton.sizeThatFits(CGSize(width: bounds.width, height: bounds.height)).width + 16), max(0, bounds.width / 2))
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        label.frame = CGRect(x: 16 + (rtl ? actionWidth : 0), y: 0,
            width: max(0, bounds.width - 32 - actionWidth), height: bounds.height)
        actionButton.frame = CGRect(x: rtl ? 8 : bounds.width - 8 - actionWidth,
            y: 0, width: actionWidth, height: bounds.height)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 4).cgPath
    }
    func appear(animated: Bool = true) {
        guard !dismissed, !appeared else { return }
        appeared = true
        voiceOverWasRunning = voiceOverRunning()
        retainingUnvisited = retainUnvisitedForVoiceOver && voiceOverWasRunning
        let animate = animated && !UIAccessibility.isReduceMotionEnabled && !UIAccessibility.isVoiceOverRunning
        alpha = animate ? 0 : 1; transform = animate ? CGAffineTransform(scaleX: 0.8, y: 0.8) : .identity
        let completion: () -> Void = { [weak self] in
            guard let self, !dismissed else { return }
            presenting = false
            UIAccessibility.post(notification: .announcement, argument: message)
            scheduleTimeout()
        }
        if animate { UIView.animate(withDuration: 0.5, animations: { self.alpha = 1; self.transform = .identity }, completion: { _ in completion() }) }
        else { completion() }
    }
    func dismiss(animated: Bool = true) {
        guard !dismissed else { return }
        NotificationCenter.default.removeObserver(self, name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
        retainingUnvisited = false
        dismissed = true; timeout?.cancel(); timeout = nil; focusExit?.cancel(); focusExit = nil; focusedElements.removeAll()
        let complete = { [weak self] in guard let self else { return }; removeFromSuperview(); onDismiss?() }
        if animated && !UIAccessibility.isReduceMotionEnabled && !UIAccessibility.isVoiceOverRunning {
            UIView.animate(withDuration: 0.25, animations: { self.alpha = 0 }, completion: { _ in complete() })
        } else { complete() }
    }
    func pauseTimeout() {
        interacting = true
        timeout?.cancel(); timeout = nil
    }
    func resumeTimeout() {
        interacting = false; scheduleTimeout()
    }
    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused(); updateAssistiveFocus(self, focused: true)
    }
    override func accessibilityElementDidLoseFocus() {
        super.accessibilityElementDidLoseFocus(); updateAssistiveFocus(self, focused: false)
    }
    private func updateAssistiveFocus(_ element: AnyObject, focused: Bool) {
        guard !dismissed else { return }
        // Turning VoiceOver off can leave a focused element/callback behind.
        // It must not indefinitely retain this offer. A different actual assistive
        // technology may still use the existing focus-retention behavior.
        if focused, ignoreStaleVoiceOverFocus, !voiceOverRunning() {
            let technologies = (element as? UIView)?.accessibilityAssistiveTechnologyFocusedIdentifiers() ?? []
            guard technologies.contains(where: { $0 != .notificationVoiceOver }) else { return }
        }
        focusExit?.cancel(); focusExit = nil
        if focused {
            retainingUnvisited = false
            focusedElements.insert(ObjectIdentifier(element))
            timeout?.cancel(); timeout = nil
        } else {
            focusedElements.remove(ObjectIdentifier(element))
            guard focusedElements.isEmpty else { return }
            // UIKit reports loss before gain. Coalesce a label→Undo transfer;
            // touch release cannot restart a timer during this focus boundary.
            focusExit = Task { [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                focusExit = nil
                scheduleTimeout()
            }
        }
    }
    @objc private func voiceOverStatusChanged() {
        guard appeared, !dismissed, retainUnvisitedForVoiceOver else { return }
        let running = voiceOverRunning()
        defer { voiceOverWasRunning = running }
        if voiceOverWasRunning && !running {
            retainingUnvisited = false
            ignoreStaleVoiceOverFocus = true
            focusedElements.removeAll()
            focusExit?.cancel(); focusExit = nil
            timeout?.cancel(); timeout = nil
            scheduleTimeout()
        } else if running {
            // Re-enabling does not restart the consumed unvisited accommodation.
            ignoreStaleVoiceOverFocus = false
        }
    }
    private func scheduleTimeout() {
        guard !dismissed, !presenting, !retainingUnvisited, !interacting, focusedElements.isEmpty, focusExit == nil, timeout == nil else { return }
        // SnackbarManager restores the full duration after touch/drag.
        guard let delay = action == nil ? Duration.milliseconds(2_750) : actionTimeout else { return }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.dismiss()
        }
    }
    private func performAction() {
        guard !dismissed, !actionConsumed, let action else { return }
        actionConsumed = true; actionButton.isEnabled = false
        // Invoke first: its recipient cancels its operation before any await.
        action.perform()
        dismiss()
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view = touch.view else { return true }
        return action == nil || !(view === actionButton || view.isDescendant(of: actionButton))
    }
    @objc private func accessibilityDismiss() -> Bool { dismiss(); return true }
    @objc private func touched(_ recognizer: UILongPressGestureRecognizer) {
        guard swipeEnabled else { return }
        switch recognizer.state {
        case .began: pauseTimeout()
        case .ended, .cancelled, .failed: if pan.state != .changed { resumeTimeout() }
        default: break
        }
    }
    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        guard swipeEnabled else { return }
        let direction: CGFloat = effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
        let distance = max(0, recognizer.translation(in: superview).x * direction)
        let translation = distance * direction
        switch recognizer.state {
        case .began: pauseTimeout()
        case .changed:
            transform = CGAffineTransform(translationX: translation, y: 0)
            alpha = max(0, min(1, 1 - (distance / max(1, bounds.width) - 0.1) / 0.5))
        case .ended, .cancelled:
            if recognizer.state == .ended && (distance >= bounds.width * 0.5 || recognizer.velocity(in: superview).x * direction > 50) { dismiss() }
            else { UIView.animate(withDuration: 0.2, animations: { self.transform = .identity; self.alpha = 1 }, completion: { _ in self.resumeTimeout() }) }
        default: break
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard swipeEnabled else { return false }
        if gestureRecognizer === pan {
            let velocity = pan.velocity(in: self)
            let direction: CGFloat = effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
            return velocity.x * direction > 0 && abs(velocity.x) > abs(velocity.y)
        }
        return true
    }
}
