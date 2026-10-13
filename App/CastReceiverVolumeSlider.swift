import UIKit

@MainActor final class CastVolumeScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        // Horizontal intent is owned by the slider's pan recognizer. Once it
        // fails for vertical motion, let scrolling cancel the control touch.
        view is CastReceiverVolumeSlider || super.touchesShouldCancel(in: view)
    }
}

@MainActor final class CastReceiverVolumeSlider: UIControl, UIGestureRecognizerDelegate {
    private let volumePan = UIPanGestureRecognizer()
    private let volumeTap = UITapGestureRecognizer()
    private var volumeGestureActive = false
    private var directTracking = false
    private let thumbLayer = CAShapeLayer()
    private let ripple = CastRippleFeedback()
    private var rippleTouch: CGPoint?
    private var thumbTouchOffset: CGFloat = 0
    private var hovered = false
    private var sceneActive = false
    private var visualVolume: Float = 0
    private var progressAnimation: (began: CFTimeInterval, from: Float, to: Float)?
    private var progressLink: CADisplayLink?
    override var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            accessibilityTraits = isEnabled ? .adjustable : [.adjustable, .notEnabled]
            volumePan.isEnabled = isEnabled; volumeTap.isEnabled = isEnabled
            if !isEnabled { cancelTracking(with: nil); resignFirstResponder(); hovered = false }
            updateFocusBackground()
            updateThumb(animated: false)
            setNeedsDisplay()
        }
    }
    override var isHighlighted: Bool {
        didSet {
            guard oldValue != isHighlighted else { return }
            updateThumb(animated: true)
            if isHighlighted, isEnabled { ripple.press(at: rippleTouch ?? CGPoint(x: thumbX, y: bounds.midY)) }
            else { ripple.release(); rippleTouch = nil }
            updateFocusBackground()
        }
    }
    var value: Float = 0 {
        didSet {
            guard oldValue != value else { return }
            stopProgressAnimation(); visualVolume = min(1, max(0, value))
            accessibilityValue = "\(Int(visualVolume * 100))%"; setNeedsDisplay(); setNeedsLayout()
        }
    }
    override init(frame: CGRect) {
        super.init(frame: frame); isOpaque = false; backgroundColor = .clear
        isAccessibilityElement = true; accessibilityTraits = .adjustable; accessibilityValue = "0%"; contentMode = .redraw
        focusEffect = nil
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hoverVolume(_:))))
        volumePan.addTarget(self, action: #selector(panVolume(_:))); volumePan.delegate = self
        volumePan.cancelsTouchesInView = false
        volumeTap.addTarget(self, action: #selector(tapVolume(_:))); volumeTap.delegate = self
        volumeTap.cancelsTouchesInView = false
        addGestureRecognizer(volumePan); addGestureRecognizer(volumeTap)
        thumbLayer.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        thumbLayer.path = UIBezierPath(ovalIn: thumbLayer.bounds).cgPath
        thumbLayer.fillColor = UIColor.white.cgColor
        layer.addSublayer(thumbLayer)
        ripple.view = self
    }
    required init?(coder: NSCoder) { fatalError() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil, progressAnimation != nil {
            if let animation = progressAnimation { visualVolume = animation.to }
            stopProgressAnimation()
        }
        for name in [UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification,
                     UIScene.didActivateNotification, UIScene.willDeactivateNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
            if window != nil { NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged(_:)), name: name, object: nil) }
        }
        sceneActive = window?.windowScene?.activationState == .foregroundActive
        if window == nil { cancelTracking(with: nil); resignFirstResponder(); stopProgressAnimation(); visualVolume = min(1, max(0, value)); ripple.reset() }
        else { updateFocusBackground() }
    }
    override var canBecomeFocused: Bool { isEnabled }
    override var canBecomeFirstResponder: Bool { isEnabled }
    @discardableResult override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder(); updateFocusBackground(); return result
    }
    @discardableResult override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder(); updateFocusBackground(); return result
    }
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if context.nextFocusedView === self { becomeFirstResponder() }
        else if context.previouslyFocusedView === self { resignFirstResponder() }
        updateFocusBackground()
    }
    @objc private func windowFocusChanged(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene === window?.windowScene {
            if notification.name == UIScene.willDeactivateNotification { sceneActive = false }
            if notification.name == UIScene.didActivateNotification { sceneActive = true }
        }
        updateFocusBackground()
    }
    private func updateFocusBackground() {
        ripple.setBackground(focused: isEnabled && (isFocused || isFirstResponder), hovered: isEnabled && hovered,
            windowFocused: window?.isKeyWindow == true && sceneActive,
            pressed: isHighlighted)
    }
    @objc private func hoverVolume(_ gesture: UIHoverGestureRecognizer) {
        hovered = gesture.state == .began || gesture.state == .changed; updateFocusBackground()
    }
    override var keyCommands: [UIKeyCommand]? {
        guard isFirstResponder, isEnabled else { return nil }
        return [UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow, "-", "+", "="].map {
            let command = UIKeyCommand(input: $0, modifierFlags: [], action: #selector(changeVolumeFromKeyboard(_:)))
            command.wantsPriorityOverSystemBehavior = true; return command
        }
    }
    @objc private func changeVolumeFromKeyboard(_ command: UIKeyCommand) {
        guard isFirstResponder, isEnabled else { return }
        let decreasing = command.input == UIKeyCommand.inputLeftArrow || command.input == "-"
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        adjust(decreasing != rtl ? -0.05 : 0.05)
    }
    private func stopProgressAnimation() {
        progressLink?.invalidate(); progressLink = nil; progressAnimation = nil
    }
    @objc private func animateProgress(_ link: CADisplayLink) {
        guard let animation = progressAnimation else { stopProgressAnimation(); return }
        let t = min(1, max(0, Float((CACurrentMediaTime() - animation.began) / 0.080)))
        visualVolume = animation.from + (animation.to - animation.from) * (1 - (1-t) * (1-t))
        setNeedsDisplay(); setNeedsLayout()
        if t >= 1 { stopProgressAnimation() }
    }
    private var thumbX: CGFloat {
        let fraction = CGFloat(visualVolume)
        return 16 + max(0, bounds.width - 32) * (effectiveUserInterfaceLayoutDirection == .rightToLeft ? 1 - fraction : fraction)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        thumbLayer.position = CGPoint(x: thumbX, y: bounds.midY)
        CATransaction.commit()
    }
    private func updateThumb(animated: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        thumbLayer.isHidden = !isEnabled
        thumbLayer.setAffineTransform(CGAffineTransform(scaleX: isHighlighted ? 1.5 : 1, y: isHighlighted ? 1.5 : 1))
        CATransaction.commit()
        thumbLayer.removeAnimation(forKey: "press")
        guard animated, isEnabled, window != nil else { return }
        // The selected platform animated selector uses separate, nonreversible
        // vectors. Interrupted transitions restart from their declared endpoint.
        let motion = CABasicAnimation(keyPath: "transform.scale")
        motion.fromValue = isHighlighted ? 1 : 1.5
        motion.toValue = isHighlighted ? 1.5 : 1
        motion.duration = isHighlighted ? 0.533 : 0.133
        motion.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        thumbLayer.add(motion, forKey: "press")
    }
    private var waitsForHorizontalIntent: Bool {
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView, scroll.isScrollEnabled { return true }
            ancestor = view.superview
        }
        return false
    }
    private func rememberThumbOffset(at point: CGPoint) {
        let offset = thumbX - point.x
        thumbTouchOffset = abs(offset) <= 6 ? offset / max(1, bounds.width - 32) : 0
    }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled, !waitsForHorizontalIntent else { return false }
        rippleTouch = touch.location(in: self)
        directTracking = true; volumeGestureActive = true; sendActions(for: .editingDidBegin); isHighlighted = true
        rememberThumbOffset(at: touch.location(in: self)); track(touch.location(in: self))
        return true
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard directTracking, isEnabled else { return false }
        track(touch.location(in: self)); return true
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        guard directTracking else { return }
        if let touch, isEnabled { track(touch.location(in: self)) }
        finishVolumeGesture()
    }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        ripple.draw(in: context, origin: CGPoint(x: thumbX, y: bounds.midY), scale: window?.screen.scale ?? traitCollection.displayScale)
        let track = CGRect(x: 16, y: bounds.midY - 1, width: max(0, bounds.width - 32), height: 2)
        let fraction = CGFloat(visualVolume)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let x = rtl ? track.maxX - track.width * fraction : track.minX + track.width * fraction
        let radius: CGFloat = 4
        let thumb = CGRect(x: x - radius, y: bounds.midY - radius, width: radius * 2, height: radius * 2)
        // API21+ AppCompat uses the platform Material drawable:2dp track,
        // alpha66/255 and an8dp disabled ring inside a12dp split-track gap.
        let subdued = UIColor.white.withAlphaComponent(66.0 / 255)
        context.saveGState()
        context.addRect(bounds); context.addRect(CGRect(x: x - 6, y: bounds.minY, width: 12, height: bounds.height))
        context.clip(using: .evenOdd)
        context.setFillColor(subdued.cgColor); context.fill(track)
        if isEnabled {
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: rtl ? track.maxX - track.width * fraction : track.minX, y: track.minY, width: track.width * fraction, height: track.height))
        }
        context.restoreGState()
        context.setFillColor(UIColor.white.cgColor)
        if !isEnabled { context.setStrokeColor(subdued.cgColor); context.setLineWidth(2); context.strokeEllipse(in: thumb.insetBy(dx: 1, dy: 1)) }
    }
    private func track(_ point: CGPoint) {
        let fraction = Float((point.x - 16) / max(1, bounds.width - 32) + thumbTouchOffset)
        value = min(1, max(0, effectiveUserInterfaceLayoutDirection == .rightToLeft ? 1 - fraction : fraction))
        sendActions(for: .valueChanged)
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isEnabled else { return false }
        guard gestureRecognizer === volumePan else { return true }
        let velocity = volumePan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard isEnabled, waitsForHorizontalIntent else { return false }
        rememberThumbOffset(at: touch.location(in: self))
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === volumePan, let scroll = other.view as? UIScrollView,
              other === scroll.panGestureRecognizer else { return false }
        return isDescendant(of: scroll)
    }
    @objc private func panVolume(_ gesture: UIPanGestureRecognizer) {
        guard isEnabled else { return }
        switch gesture.state {
        case .began: rippleTouch = gesture.location(in: self); volumeGestureActive = true; sendActions(for: .editingDidBegin); isHighlighted = true; track(gesture.location(in: self))
        case .changed: track(gesture.location(in: self))
        case .ended: track(gesture.location(in: self)); finishVolumeGesture()
        case .cancelled: finishVolumeGesture()
        default: break
        }
    }
    @objc private func tapVolume(_ gesture: UITapGestureRecognizer) {
        guard isEnabled, gesture.state == .ended else { return }
        rippleTouch = gesture.location(in: self)
        volumeGestureActive = true; sendActions(for: .editingDidBegin); isHighlighted = true
        track(gesture.location(in: self)); finishVolumeGesture()
    }
    override func cancelTracking(with event: UIEvent?) {
        volumePan.isEnabled = false; volumePan.isEnabled = isEnabled
        volumeTap.isEnabled = false; volumeTap.isEnabled = isEnabled
        finishVolumeGesture()
    }
    private func finishVolumeGesture() {
        guard volumeGestureActive else { return }; volumeGestureActive = false; directTracking = false; isHighlighted = false
        setNeedsDisplay()
        sendActions(for: .editingDidEnd)
    }
    override func accessibilityIncrement() { adjust(0.05) }
    override func accessibilityDecrement() { adjust(-0.05) }
    private func adjust(_ delta: Float) {
        guard isEnabled else { return }
        let next = min(1, max(0, value + delta)); guard next != value else { return }
        let from = visualVolume; value = next
        if window != nil {
            visualVolume = from; progressAnimation = (CACurrentMediaTime(), from, next)
            // One frame clock: a second adjustment within the 80 ms animation used to start another and leave
            // the first running for ever.
            if progressLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(animateProgress(_:)))
                progressLink = link; link.add(to: .main, forMode: .common)
            }
        }
        sendActions(for: .valueChanged)
    }
}
