import UIKit
import NotTennaPodCore

@MainActor final class PlaybackSpeedController: UIViewController, UIGestureRecognizerDelegate {
    private let playback: PlaybackCoordinator
    private let preferences: PlaybackSpeedPreferenceStore
    private var state: PlaybackSpeedDialogState
    private let sheet = UIScrollView()
    private let heading = Appearance.label(Appearance.text("playback_speed"), size: 16)
    private let presetsHeading = Appearance.label(Appearance.text("speed_presets"), size: 16)
    private let current = SpeedChip(add: true)
    private let slider = SpeedSlider()
    private let decrease = SpeedStepButton(image: "ic_minus", label: "decrease_speed")
    private let increase = SpeedStepButton(image: "ic_add", label: "increase_speed")
    private let silence = SpeedCheckbox()
    private var chips: [SpeedChip] = []
    private var events: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var notice: UILabel?
    private var dragTranslation: CGFloat = 0

    init(playback: PlaybackCoordinator, preferences: PlaybackSpeedPreferenceStore) {
        self.playback = playback; self.preferences = preferences
        state = .init(speed: Self.currentSpeed(playback, preferences), presets: preferences.value.presets)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { events?.cancel(); dismissTask?.cancel(); noticeTask?.cancel() }
    /// The selected episode's speed, or the global speed when no episode is selected (Settings → Playback speed;
    /// `PlaybackSpeedUtils.getCurrentPlaybackSpeed(null)`).
    private static func currentSpeed(_ playback: PlaybackCoordinator, _ preferences: PlaybackSpeedPreferenceStore) -> Float {
        playback.episode == nil ? preferences.value.global : playback.speed
    }
    private var currentSpeed: Float { Self.currentSpeed(playback, preferences) }
    private var currentSkipSilence: Bool { playback.episode == nil ? preferences.value.silence.global : playback.skipSilence }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.32)
        view.accessibilityViewIsModal = true
        sheet.backgroundColor = Appearance.surfaceVariant
        sheet.layer.cornerRadius = 28
        sheet.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        sheet.contentInsetAdjustmentBehavior = .never
        sheet.accessibilityIdentifier = "speedDialog"
        view.addSubview(sheet)
        [heading, current, decrease, slider, increase, presetsHeading, silence].forEach(sheet.addSubview)
        heading.accessibilityIdentifier = "speedDialogTitle"
        current.accessibilityIdentifier = "speedAddPreset"
        current.accessibilityLabel = Appearance.text("add_preset")
        decrease.accessibilityIdentifier = "speedDecrease"; increase.accessibilityIdentifier = "speedIncrease"
        slider.accessibilityIdentifier = "speedSlider"
        slider.accessibilityLabel = Appearance.text("playback_speed")
        silence.accessibilityIdentifier = "speedSkipSilence"
        current.addAction(UIAction { [weak self] _ in self?.addPreset() }, for: .touchUpInside)
        decrease.addAction(UIAction { [weak self] _ in self?.step(-1) }, for: .touchUpInside)
        increase.addAction(UIAction { [weak self] _ in self?.step(1) }, for: .touchUpInside)
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }; changeSpeed(state.move(to: slider.progress))
        }, for: .valueChanged)
        silence.addAction(UIAction { [weak self] _ in self?.toggleSilence() }, for: .touchUpInside)
        let outside = UITapGestureRecognizer(target: self, action: #selector(outsideTap(_:)))
        outside.cancelsTouchesInView = false; view.addGestureRecognizer(outside)
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragSheet(_:)))
        drag.delegate = self; view.addGestureRecognizer(drag)
        rebuildPresets(); updateControls()
        events = Task { [weak self, playback] in
            for await _ in playback.events() {
                guard let self, !Task.isCancelled else { return }
                state.receive(speed: currentSpeed); updateControls()
            }
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let layout = PlaybackSpeedDialogLayout(size: CGSize(width: safe.width, height: view.bounds.height), topInset: view.safeAreaInsets.top,
            bottomInset: view.safeAreaInsets.bottom, count: chips.count,
            addWidth: max(77, current.titleWidth + 48), scale: view.window?.screen.scale ?? 1,
            rightToLeft: view.effectiveUserInterfaceLayoutDirection == .rightToLeft)
        sheet.frame = layout.sheet.offsetBy(dx: safe.minX, dy: dragTranslation)
        sheet.contentSize = CGSize(width: safe.width, height: layout.contentHeight)
        heading.frame = layout.heading; current.frame = layout.add
        decrease.frame = layout.decrease; slider.frame = layout.slider; increase.frame = layout.increase
        presetsHeading.frame = layout.presetsHeading; silence.frame = layout.silence
        for (index, chip) in chips.enumerated() { chip.frame = layout.presets[index] }
        layoutNotice()
    }
    private func updateControls() {
        current.title = PlaybackSpeedDialogState.text(state.displayedSpeed)
        current.accessibilityValue = current.title
        slider.progress = state.progress
        slider.accessibilityValue = current.title
        silence.checked = currentSkipSilence
        view.setNeedsLayout()
    }
    private func step(_ value: Int) { changeSpeed(state.step(value)) }
    private func changeSpeed(_ speed: Float, dismissAfter: Bool = false) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.setSpeed(speed, alsoGlobal: true)
                state.receive(speed: currentSpeed); updateControls()
                if dismissAfter {
                    dismissTask?.cancel()
                    dismissTask = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                        self?.dismiss(animated: true)
                    }
                }
            } catch { state.receive(speed: currentSpeed); updateControls(); showFailure(error) }
        }
    }
    private func addPreset() {
        let previous = state
        do {
            guard try state.addCurrent() else {
                showNotice(String(format: Appearance.text("preset_already_exists"), locale: .current, Double(state.currentSliderSpeed)))
                return
            }
            try preferences.setPresets(state.selection.presets); rebuildPresets()
        } catch { state = previous; showFailure(error) }
    }
    private func rebuildPresets() {
        chips.forEach { $0.removeFromSuperview() }; chips = []
        for (index, speed) in state.selection.presets.enumerated() {
            let chip = SpeedChip(add: false)
            chip.title = PlaybackSpeedDialogState.text(speed)
            chip.accessibilityLabel = chip.title
            chip.accessibilityIdentifier = "speedPreset-\(index)"
            chip.addAction(UIAction { [weak self] _ in self?.changeSpeed(speed, dismissAfter: true) }, for: .touchUpInside)
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(removePreset(_:)))
            longPress.minimumPressDuration = 0.5
            chip.addGestureRecognizer(longPress)
            chip.tag = index
            sheet.addSubview(chip); chips.append(chip)
        }
        view.setNeedsLayout()
    }
    @objc private func removePreset(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let index = recognizer.view?.tag,
              state.selection.presets.indices.contains(index) else { return }
        let previous = state
        state.remove(state.selection.presets[index])
        do { try preferences.setPresets(state.selection.presets); rebuildPresets() }
        catch { state = previous; showFailure(error) }
    }
    private func toggleSilence() {
        Task { [weak self] in
            guard let self else { return }
            do { try await playback.setSkipSilence(!currentSkipSilence, alsoGlobal: true); updateControls() }
            catch { updateControls(); showFailure(error) }
        }
    }
    private func showFailure(_ error: Error) {
        let dialog = UIAlertController(title: Appearance.text("error_label"), message: error.localizedDescription, preferredStyle: .alert)
        dialog.addAction(UIAlertAction(title: Appearance.text("confirm_label"), style: .default))
        present(dialog, animated: true)
    }
    private func showNotice(_ text: String) {
        noticeTask?.cancel(); notice?.removeFromSuperview()
        let label = Appearance.label(text, size: 14)
        label.textColor = Appearance.color(0xffffff, 0x323232)
        label.backgroundColor = Appearance.color(0x323232, 0xe6e6e6)
        label.textAlignment = .center; label.layer.cornerRadius = 4; label.clipsToBounds = true
        label.accessibilityIdentifier = "speedPresetDuplicate"
        view.addSubview(label); notice = label
        layoutNotice()
        UIAccessibility.post(notification: .announcement, argument: text)
        noticeTask = Task { [weak label] in
            do { try await Task.sleep(for: .milliseconds(2750)) } catch { return }; label?.removeFromSuperview()
        }
    }
    private func layoutNotice() {
        guard let notice else { return }
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let margin = min(16, safe.width / 2), width = max(0, safe.width - 2 * margin)
        let height = notice.sizeThatFits(CGSize(width: max(1, width - 32), height: .greatestFiniteMagnitude)).height + 28
        notice.frame = CGRect(x: safe.minX + margin, y: safe.maxY - height - 16, width: width, height: height)
    }
    @objc private func outsideTap(_ gesture: UITapGestureRecognizer) {
        if !sheet.frame.contains(gesture.location(in: view)) { dismiss(animated: true) }
    }
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        let point = pan.location(in: sheet)
        return sheet.frame.contains(pan.location(in: view)) && !slider.frame.contains(point)
            && sheet.contentOffset.y <= 0 && velocity.y > abs(velocity.x)
    }
    @objc private func dragSheet(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began { dragTranslation = 0 }
        if pan.state == .changed {
            dragTranslation = max(0, pan.translation(in: view).y)
            view.setNeedsLayout(); view.layoutIfNeeded()
        }
        if pan.state == .ended || pan.state == .cancelled {
            if pan.state == .ended && (pan.translation(in: view).y > sheet.frame.height / 2 || pan.velocity(in: view).y > 500) {
                dismiss(animated: true)
            } else {
                dragTranslation = 0
                UIView.animate(withDuration: 0.2) {
                    self.view.setNeedsLayout(); self.view.layoutIfNeeded()
                }
            }
        }
    }
    override func accessibilityPerformEscape() -> Bool { dismiss(animated: true); return true }
}

@MainActor private final class SpeedChip: UIControl {
    private let surface = UIView()
    private let label = Appearance.label(nil, size: 14)
    private let plus = UIImageView(image: UIImage(named: "ic_add"))
    private let showsAdd: Bool
    var title: String? { get { label.text } set { label.text = newValue; setNeedsLayout() } }
    var titleWidth: CGFloat { label.intrinsicContentSize.width }
    init(add: Bool) {
        showsAdd = add; super.init(frame: .zero)
        isAccessibilityElement = true; accessibilityTraits = .button
        surface.isUserInteractionEnabled = false; surface.layer.cornerRadius = 8; surface.layer.borderWidth = 1
        surface.backgroundColor = Appearance.color(0xd3e8f5, 0x3c4e68)
        label.font = Appearance.font(14, medium: true); label.textAlignment = .center
        plus.tintColor = Appearance.secondary; plus.isHidden = !add
        [surface, label, plus].forEach { $0.isUserInteractionEnabled = false; addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        surface.frame = bounds.insetBy(dx: 0, dy: 8)
        surface.layer.borderColor = Appearance.secondary.resolvedColor(with: traitCollection).cgColor
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        label.frame = CGRect(x: showsAdd && rtl ? 28 : 0, y: 0, width: max(0, bounds.width - (showsAdd ? 28 : 0)), height: bounds.height)
        plus.frame = CGRect(x: rtl ? 8 : bounds.width - 28, y: (bounds.height - 20) / 2, width: 20, height: 20)
    }
}

@MainActor final class SpeedStepButton: UIControl {
    private let icon: UIImageView
    init(image: String, label: String) {
        icon = UIImageView(image: UIImage(named: image)); super.init(frame: .zero)
        icon.tintColor = Appearance.accent; icon.isUserInteractionEnabled = false; addSubview(icon)
        isAccessibilityElement = true; accessibilityTraits = .button; accessibilityLabel = Appearance.text(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        let size = min(20, bounds.width, bounds.height)
        icon.frame = CGRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)
    }
}

@MainActor final class SpeedSlider: UIControl {
    var progress: Int = 10 { didSet { progress = min(70, max(0, progress)); setNeedsDisplay() } }
    override var isEnabled: Bool { didSet { setNeedsDisplay() } }
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .clear; isOpaque = false
        isAccessibilityElement = true; accessibilityTraits = .adjustable; contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ rect: CGRect) {
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let width = max(0, bounds.width - 32), fraction = CGFloat(progress) / 70
        let x = 16 + width * (rtl ? 1 - fraction : fraction), y = bounds.midY
        let track = UIBezierPath(rect: CGRect(x: 16, y: y - 1, width: width, height: 2))
        let trackAlpha: CGFloat = traitCollection.userInterfaceStyle == .dark ? 0.3 : 0.26
        Appearance.secondary.withAlphaComponent(trackAlpha).setFill(); track.fill()
        if !isEnabled {
            // The source's off-state thumb has a clear gap around a gray ring.
            // Clear only this transparent control's drawing, preserving its parent.
            UIGraphicsGetCurrentContext()?.clear(CGRect(x: x - 6, y: y - 6, width: 12, height: 12))
            Appearance.secondary.setStroke()
            let ring = UIBezierPath(ovalIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6))
            ring.lineWidth = 2; ring.stroke()
            return
        }
        Appearance.accent.setFill()
        UIBezierPath(rect: CGRect(x: rtl ? x : 16, y: y - 1, width: width * fraction, height: 2)).fill()
        UIBezierPath(ovalIn: CGRect(x: x - 6, y: y - 6, width: 12, height: 12)).fill()
    }
    private func move(_ touch: UITouch) {
        var fraction = min(1, max(0, (touch.location(in: self).x - 16) / max(1, bounds.width - 32)))
        if effectiveUserInterfaceLayoutDirection == .rightToLeft { fraction = 1 - fraction }
        let next = Int((fraction * 70).rounded())
        if next != progress { progress = next; sendActions(for: .valueChanged) }
    }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool { move(touch); return true }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool { move(touch); return true }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) { if let touch { move(touch) } }
    override func accessibilityIncrement() { if progress < 70 { progress += 1; sendActions(for: .valueChanged) } }
    override func accessibilityDecrement() { if progress > 0 { progress -= 1; sendActions(for: .valueChanged) } }
}

@MainActor final class SpeedCheckbox: UIControl {
    private let label = Appearance.label(Appearance.text("pref_skip_silence_title"), size: 14)
    var checked = false { didSet { accessibilityValue = checked ? Appearance.text("on") : Appearance.text("off"); setNeedsDisplay() } }
    override var isEnabled: Bool { didSet { updateTextColor(); setNeedsDisplay() } }
    init(titleKey: String = "pref_skip_silence_title") {
        super.init(frame: .zero); backgroundColor = .clear; isOpaque = false
        label.text = Appearance.text(titleKey)
        label.isUserInteractionEnabled = false; addSubview(label)
        isAccessibilityElement = true; accessibilityTraits = .button; accessibilityLabel = label.text
        updateTextColor()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func updateTextColor() {
        label.textColor = Appearance.color(0x1a1b20, 0xe2e2e9).withAlphaComponent(isEnabled ? 1 : 0.6)
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        label.font = Appearance.font(14, compatibleWith: traitCollection)
        return CGSize(width: size.width, height: max(48,
            label.sizeThatFits(CGSize(width: max(0, size.width - 32), height: .greatestFiniteMagnitude)).height + 16))
    }
    override func layoutSubviews() {
        super.layoutSubviews(); let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        label.font = Appearance.font(14, compatibleWith: traitCollection)
        label.frame = CGRect(x: rtl ? 0 : 32, y: 0, width: max(0, bounds.width - 32), height: bounds.height)
    }
    override func draw(_ rect: CGRect) {
        let x: CGFloat = effectiveUserInterfaceLayoutDirection == .rightToLeft ? bounds.width - 24 : 8
        let box = UIBezierPath(roundedRect: CGRect(x: x, y: bounds.midY - 8, width: 16, height: 16), cornerRadius: 1)
        let tint = isEnabled ? (checked ? Appearance.accent : Appearance.secondary)
            : Appearance.foreground.withAlphaComponent(0.38)
        if checked {
            tint.setFill()
            UIBezierPath(roundedRect: CGRect(x: x - 1, y: bounds.midY - 9, width: 18, height: 18), cornerRadius: 2).fill()
            (isEnabled ? Appearance.color(0xffffff, 0x000000) : Appearance.background).setStroke()
            let mark = UIBezierPath(); mark.move(to: CGPoint(x: x + 2, y: bounds.midY))
            mark.addLine(to: CGPoint(x: x + 6, y: bounds.midY + 4)); mark.addLine(to: CGPoint(x: x + 14, y: bounds.midY - 4))
            mark.lineWidth = 2; mark.stroke()
        } else {
            tint.setStroke(); box.lineWidth = 2; box.stroke()
        }
    }
}
