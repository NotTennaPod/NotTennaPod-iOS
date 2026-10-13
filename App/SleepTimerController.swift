import UIKit
import NotTennaPodCore

/// Source time_dialog.xml composition. Playback and preferences outlive this sheet.
@MainActor final class SleepTimerController: UIViewController, UITextFieldDelegate, UIGestureRecognizerDelegate {
    private let playback: PlaybackCoordinator
    private let preferences: SleepTimerPreferenceStore
    private let queuePreferences: PlaybackQueuePreferenceStore
    private let library: FeedLibraryStore?
    private let openPlaybackSettings: () -> Void
    private let viewport = UIView(), panel = UIView(), scroll = UIScrollView()
    private let input = SleepTimerNumberField(), mode = SleepTimerModeButton(type: .custom)
    private let hint = Appearance.label(nil, size: 14), time = Appearance.label(nil, size: 32)
    private let set = SleepTimerActionButton(type: .custom), disable = SleepTimerActionButton(type: .custom)
    private let shake = SleepTimerCheckbox(), vibrate = SleepTimerCheckbox(), automatic = SleepTimerCheckbox()
    private let hours = UIButton(type: .custom), settings = SleepTimerActionButton(type: .custom)
    private let extensions = (0..<3).map { _ in SleepTimerActionButton(type: .custom) }
    private let modeChoices = UIView()
    private var choiceButtons: [UIButton] = []
    private let message = Appearance.label(nil, size: 14)
    private var messageTask: Task<Void, Never>?, events: Task<Void, Never>?, contextTask: Task<Void, Never>?
    private var remainingQueue: Int?
    private var remainingMedia: Int64?
    private var changingTimer = false

    init(playback: PlaybackCoordinator, preferences: SleepTimerPreferenceStore,
         queuePreferences: PlaybackQueuePreferenceStore, library: FeedLibraryStore?,
         openPlaybackSettings: @escaping () -> Void) {
        self.playback = playback; self.preferences = preferences; self.queuePreferences = queuePreferences
        self.library = library; self.openPlaybackSettings = openPlaybackSettings
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { events?.cancel(); contextTask?.cancel(); messageTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.32); view.accessibilityViewIsModal = true
        viewport.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(viewport)
        NSLayoutConstraint.activate([
            viewport.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            viewport.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            viewport.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            viewport.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        ])
        viewport.addSubview(panel); panel.addSubview(scroll)
        panel.accessibilityIdentifier = "sleepTimerSheet"
        panel.backgroundColor = Appearance.surfaceVariant
        panel.layer.cornerRadius = 28; panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        panel.clipsToBounds = true; scroll.contentInsetAdjustmentBehavior = .never
        [input, mode, hint, time, set, disable, shake, vibrate, automatic, hours, settings].forEach(scroll.addSubview)
        // These controls paint source artwork in local points. Resizing must
        // repaint it, rather than stretch cached pixels into the new bounds.
        ([input, mode, set, disable, shake, vibrate, automatic, settings] as [UIView] + extensions).forEach { $0.contentMode = .redraw }
        view.addSubview(message)
        extensions.forEach(scroll.addSubview)
        input.text = preferences.value.lastValue; input.keyboardType = .numberPad; input.delegate = self
        input.textColor = Appearance.foreground; input.tintColor = Appearance.accent
        input.accessibilityIdentifier = "sleepTimerInput"; input.accessibilityLabel = Appearance.text("sleep_timer_label")
        input.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .editingChanged)
        mode.accessibilityIdentifier = "sleepTimerMode"
        mode.setTitleColor(Appearance.foreground, for: .normal)
        mode.addAction(UIAction { [weak self] _ in
            guard let self else { return }; input.resignFirstResponder()
            modeChoices.isHidden.toggle(); view.setNeedsLayout()
        }, for: .touchUpInside)
        configure(set, title: "set_sleeptimer_label", id: "sleepTimerSet", filled: true) { [weak self] in self?.start() }
        configure(disable, title: "disable_sleeptimer_label", id: "sleepTimerDisable", filled: true) { [weak self] in
            self?.command { [weak self] in try await self?.playback.disableSleepTimer() }
        }
        configure(settings, title: "settings_label", id: "sleepTimerPlaybackSettings", filled: true) { [weak self] in
            guard let self else { return }; dismiss(animated: true, completion: openPlaybackSettings)
        }
        configure(shake, title: "shake_to_reset_label", id: "sleepTimerShake") { [weak self] in
            self?.change { $0.shakeToReset.toggle() }
        }
        configure(vibrate, title: "timer_vibration_label", id: "sleepTimerVibrate") { [weak self] in
            self?.change { $0.vibrate.toggle() }
        }
        configure(automatic, title: "auto_enable_label", id: "sleepTimerAutomatic") { [weak self] in
            guard let self else { return }
            change { $0.autoEnable.toggle() }
            if preferences.value.autoEnable && preferences.value.mode == .episodes && preferences.value.isAutoEnabledMostOfDay {
                confirmContinuousPlayback()
            }
        }
        hours.setImage(UIImage(named: "ic_settings"), for: .normal); hours.tintColor = Appearance.foreground
        hours.accessibilityIdentifier = "sleepTimerHours"; hours.accessibilityLabel = Appearance.text("auto_enable_change_times")
        hours.addAction(UIAction { [weak self] _ in self?.showHours() }, for: .touchUpInside)
        for index in extensions.indices {
            configure(extensions[index], title: "", id: "sleepTimerExtend\(index)") { [weak self] in
                guard let self else { return }
                let mode = preferences.value.mode
                command { try await self.playback.extendSleepTimer(by: mode.timerValue(mode.extensions[index])) }
            }
            extensions[index].filled = false
        }
        hint.numberOfLines = 0; hint.accessibilityIdentifier = "sleepTimerHint"
        time.textAlignment = .center; time.accessibilityIdentifier = "sleepTimerRemaining"
        message.numberOfLines = 0; message.textColor = .white; message.backgroundColor = Appearance.color(0x303030, 0x303030)
        message.layer.cornerRadius = 4; message.clipsToBounds = true; message.isHidden = true
        message.accessibilityIdentifier = "sleepTimerMessage"
        scroll.addSubview(modeChoices); modeChoices.backgroundColor = Appearance.navigation
        modeChoices.layer.cornerRadius = 4; modeChoices.layer.shadowOpacity = 0.2; modeChoices.layer.shadowRadius = 4
        modeChoices.isHidden = true
        for selection in SleepTimerMode.allCases {
            let button = UIButton(type: .custom)
            configure(button, title: selection == .minutes ? "time_minutes" : "sleep_timer_episodes_label",
                id: selection == .minutes ? "sleepTimerModeMinutes" : "sleepTimerModeEpisodes") { [weak self] in self?.selectMode(selection) }
            button.setTitleColor(Appearance.foreground, for: .normal)
            modeChoices.addSubview(button); choiceButtons.append(button)
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(outside(_:)))
        tap.cancelsTouchesInView = false; view.addGestureRecognizer(tap)
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragSheet(_:)))
        drag.delegate = self; panel.addGestureRecognizer(drag)
        scroll.panGestureRecognizer.require(toFail: drag)
        let updates = playback.events()
        events = Task { [weak self] in for await _ in updates { self?.refresh() } }
        let selected = playback.episode?.id
        contextTask = Task { [weak self, library] in
            do {
                let episode = if let selected { try await library?.episode(id: selected) } else { nil as LibraryEpisode? }
                let queue = try await library?.queue() ?? []
                guard let self, !Task.isCancelled else { return }
                remainingQueue = selected.flatMap { id in queue.firstIndex { $0.id == id } }.map { queue.count - $0 } ?? 0
                if let episode { remainingMedia = Int64(episode.details.media?.durationMilliseconds ?? 0) - Int64(episode.userState.positionMilliseconds) }
                refresh()
            } catch { self?.remainingQueue = 0; self?.refresh() }
        }
        refresh()
    }

    private func configure(_ button: UIButton, title: String, id: String, filled: Bool = false, action: @escaping () -> Void) {
        button.setTitle(title.isEmpty ? "" : Appearance.text(title), for: .normal)
        button.setTitleColor(filled ? .white : button is SleepTimerCheckbox ? Appearance.foreground : Appearance.accent, for: .normal)
        button.titleLabel?.numberOfLines = 0
        button.accessibilityIdentifier = id
        if let action = button as? SleepTimerActionButton { action.filled = filled }
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }
    private func change(_ edit: (inout SleepTimerPreferences) -> Void) {
        var value = preferences.value; edit(&value)
        do { try preferences.update(value) } catch { showMessage(error.localizedDescription) }
        refresh()
    }
    private func selectMode(_ selection: SleepTimerMode) {
        modeChoices.isHidden = true
        guard selection != preferences.value.mode else { return }
        change {
            if let parsed = SleepTimerPreferences.validInput(input.text ?? "") { $0.lastValue = String(parsed) }
            $0.mode = selection
            if $0.isAutoEnabledMostOfDay { $0.autoEnable = false }
        }
        input.text = preferences.value.lastValue; refresh()
    }
    private func start() {
        guard playback.wantsPlayback else { showMessage(Appearance.text("no_media_playing_label")); return }
        guard let value = SleepTimerPreferences.validInput(input.text ?? ""), value > 0 else {
            showMessage(Appearance.text("time_dialog_invalid_input")); return
        }
        var settings = preferences.value; settings.lastValue = String(value)
        do { try preferences.update(settings) } catch { showMessage(error.localizedDescription); return }
        command {
            // Marks the timer as the person's own, so the screen does not announce it as auto-enabled.
            Self.personalStarts &+= 1
            do { try await self.playback.startSleepTimer(mode: settings.mode, value: settings.mode.timerValue(value)) }
            catch { Self.personalStarts &-= 1; throw error }
        }
        input.resignFirstResponder()
    }
    /// Timers started from this dialog (see `LibraryViewController.noticeSleepTimerAutoEnable`).
    static var personalStarts: UInt64 = 0
    private func command(_ work: @escaping @MainActor () async throws -> Void) {
        guard !changingTimer else { return }; changingTimer = true; refresh()
        Task { [weak self] in
            do { try await work() } catch { self?.showMessage(error.localizedDescription) }
            self?.changingTimer = false; self?.refresh()
        }
    }
    private func showMessage(_ text: String) {
        messageTask?.cancel(); message.text = "  " + text + "  "; message.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: text); view.setNeedsLayout()
        messageTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(3500)) } catch { return }
            self?.message.isHidden = true; self?.view.setNeedsLayout()
        }
    }
    private func showHours() {
        guard presentedViewController == nil else { return }
        let value = preferences.value
        present(SleepTimerTimeRangeController(from: value.autoFromHour, to: value.autoToHour) { [weak self] from, to in
            guard let self else { return }
            change { $0.autoFromHour = from; $0.autoToHour = to }
            if preferences.value.mode == .episodes && preferences.value.isAutoEnabledMostOfDay {
                confirmContinuousPlayback()
            } else { change { $0.autoEnable = true } }
        }, animated: true)
    }
    private func confirmContinuousPlayback() {
        let controller = SourceMessageController(title: Appearance.text("sleep_timer_without_continuous_playback"),
            message: Appearance.text("sleep_timer_without_continuous_playback_message"),
            positive: .init(title: Appearance.text("sleep_timer_without_continuous_playback_change_hours"),
                identifier: "sleepTimerChangeHours", perform: { [weak self] in self?.showHours() }, performAfterDismiss: true),
            negative: .init(title: Appearance.text("sleep_timer_without_continuous_playback"), identifier: "sleepTimerDisableContinuous", perform: { [weak self] in
                guard let self else { return }
                var queue = queuePreferences.value; queue.followQueue = false
                do { try queuePreferences.update(queue); change { $0.autoEnable = false } }
                catch { showMessage(error.localizedDescription) }
            }, titleColor: Appearance.color(0xba1a1a, 0xffb4ab)))
        controller.onCancel = { [weak self] in self?.change { $0.autoEnable = false } }
        present(controller, animated: true)
    }

    private func refresh() {
        guard isViewLoaded else { return }
        let value = preferences.value, active = playback.sleepTimerValue != nil
        let blocked = value.mode == .episodes && !queuePreferences.value.followQueue
        [input, mode, set, hint].forEach { $0.isHidden = active }
        ([time, disable] + extensions).forEach { $0.isHidden = !active }
        mode.setTitle(Appearance.text(value.mode == .minutes ? "time_minutes" : "sleep_timer_episodes_label"), for: .normal)
        input.isEnabled = !blocked; set.isEnabled = !blocked && !changingTimer; disable.isEnabled = !changingTimer
        extensions.forEach { $0.isEnabled = !blocked && !changingTimer }
        [set, disable].forEach { $0.alpha = $0.isEnabled ? 1 : 0.38 }
        shake.checked = value.shakeToReset; vibrate.checked = value.vibrate; automatic.checked = value.autoEnable
        shake.isHidden = blocked || value.mode == .episodes; vibrate.isHidden = blocked
        automatic.isHidden = blocked; hours.isHidden = blocked; settings.isHidden = !blocked
        hours.alpha = value.autoEnable ? 1 : 0.5
        automatic.setTitle(autoEnableText(value), for: .normal)
        let selected = SleepTimerPreferences.validInput(input.text ?? "") ?? 0
        if blocked { hint.text = Appearance.text("multiple_sleep_episodes_while_continuous_playback_disabled") }
        else if value.mode == .episodes, let remainingQueue, selected > Int64(remainingQueue) {
            hint.text = Appearance.quantity("episodes_sleep_timer_exceeds_queue", count: Int64(remainingQueue))
        } else if value.mode == .minutes, !queuePreferences.value.followQueue,
                  value.mode.timerValue(selected) > (remainingMedia ?? Int64(Int32.max)) {
            hint.text = Appearance.quantity("timer_exceeds_remaining_time_while_continuous_playback_disabled", count: (remainingMedia ?? Int64(Int32.max)) / 60_000)
        } else { hint.text = nil }
        hint.isHidden = active || hint.text == nil
        if let left = playback.sleepTimerValue {
            let seconds = max(0, left.display) / 1000
            time.text = value.mode == .episodes ? Appearance.quantity("num_episodes", count: left.display)
                : String(format: "%02lld:%02lld:%02lld", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        for index in extensions.indices {
            extensions[index].setTitle(value.mode == .minutes ? String(format: Appearance.text("extend_sleep_timer_label"), Int(value.mode.extensions[index]))
                : "+" + Appearance.quantity("num_episodes", count: value.mode.extensions[index]), for: .normal)
            extensions[index].alpha = extensions[index].isEnabled ? 1 : 0.38
        }
        view.setNeedsLayout()
    }
    private func autoEnableText(_ value: SleepTimerPreferences) -> String {
        guard value.autoFromHour != value.autoToHour else { return Appearance.text("auto_enable_label") }
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "HH"
        func hour(_ hour: Int) -> String {
            format.contains("a") ? String(format: "%02d:00 %@", hour % 12, hour >= 12 ? "PM" : "AM") : String(format: "%02d:00", hour)
        }
        return String(format: Appearance.text("auto_enable_label_with_times"), hour(value.autoFromHour), hour(value.autoToHour))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = min(640, viewport.bounds.width), inner = max(0, width - 32)
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        input.font = Appearance.font(18, compatibleWith: traitCollection)
        mode.titleLabel?.font = Appearance.font(16, compatibleWith: traitCollection)
        mode.titleLabel?.numberOfLines = 0
        hint.font = Appearance.font(14, compatibleWith: traitCollection); time.font = Appearance.font(32, compatibleWith: traitCollection)
        var y: CGFloat = 16
        func place(_ control: UIView, height: CGFloat, gap: CGFloat = 0) {
            guard !control.isHidden else { return }
            control.frame = CGRect(x: 16, y: y, width: inner, height: height); y += height + gap
        }
        func buttonHeight(_ button: UIButton, width: CGFloat) -> CGFloat {
            button.titleLabel?.font = Appearance.font(14, medium: true, compatibleWith: traitCollection)
            return max(48, (button.titleLabel?.sizeThatFits(CGSize(width: max(1, width - 24), height: .greatestFiniteMagnitude)).height ?? 0) + 24)
        }
        if !input.isHidden {
            let modeWidth = min(inner * 0.55, max(100, (mode.titleLabel?.sizeThatFits(CGSize(width: inner * 0.55, height: .greatestFiniteMagnitude)).width ?? 0) + 64))
            let modeHeight = mode.titleLabel?.sizeThatFits(CGSize(width: max(1, modeWidth - 48), height: .greatestFiniteMagnitude)).height ?? 0
            let h = max(48, input.font!.lineHeight + 24, modeHeight + 16)
            mode.frame = CGRect(x: rtl ? 16 : width - 16 - modeWidth, y: y + 8, width: modeWidth, height: h)
            input.frame = CGRect(x: rtl ? 24 + modeWidth : 24, y: y + 8, width: max(0, inner - modeWidth - 16), height: h)
            y += h + 16
        }
        let hintHeight = hint.sizeThatFits(CGSize(width: max(0, inner - 16), height: .greatestFiniteMagnitude)).height
        place(hint, height: hintHeight + 16)
        place(set, height: buttonHeight(set, width: inner))
        place(time, height: time.font.lineHeight + 8)
        if !time.isHidden {
            let spacing: CGFloat = 8, cell = max(0, (inner - spacing * 2) / 3)
            let height = extensions.map { buttonHeight($0, width: cell) }.max() ?? 48
            for i in extensions.indices {
                extensions[i].frame = CGRect(x: 16 + CGFloat(rtl ? 2 - i : i) * (cell + spacing), y: y, width: cell, height: height)
            }
            y += height
        }
        place(disable, height: buttonHeight(disable, width: inner))
        y += 8
        for checkbox in [shake, vibrate, automatic] {
            checkbox.titleLabel?.font = Appearance.font(14, compatibleWith: traitCollection)
            let available = checkbox === automatic ? inner - 24 : inner
            let height = max(48, (checkbox.titleLabel?.sizeThatFits(CGSize(width: max(0, available - 40), height: .greatestFiniteMagnitude)).height ?? 0) + 16)
            place(checkbox, height: height)
            if checkbox === automatic, !checkbox.isHidden {
                checkbox.frame.size.width = available
                if rtl { checkbox.frame.origin.x += 24 }
                hours.frame = CGRect(x: rtl ? 16 : width - 40, y: checkbox.frame.minY, width: 24, height: height)
                hours.imageView?.contentMode = .scaleAspectFit
            }
        }
        place(settings, height: buttonHeight(settings, width: inner))
        y += 16
        let height = min(y, viewport.bounds.height)
        let bottom = max(0, view.bounds.height - viewport.frame.maxY)
        // Extend the background only into the bottom system inset, never beneath the keyboard.
        let fill = min(bottom, view.safeAreaInsets.bottom)
        let dragTransform = panel.transform; panel.transform = .identity
        panel.frame = CGRect(x: (viewport.bounds.width - width) / 2, y: viewport.bounds.height - height, width: width, height: height + fill)
        panel.transform = dragTransform
        scroll.frame = CGRect(x: 0, y: 0, width: width, height: height); scroll.contentSize = CGSize(width: width, height: y)
        var choicesHeight: CGFloat = 0
        for button in choiceButtons {
            button.titleLabel?.font = Appearance.font(16, compatibleWith: traitCollection)
            let height = max(48, (button.titleLabel?.sizeThatFits(CGSize(width: max(1, mode.frame.width - 16), height: .greatestFiniteMagnitude)).height ?? 0) + 16)
            button.frame = CGRect(x: 0, y: choicesHeight, width: mode.frame.width, height: height)
            choicesHeight += height
        }
        modeChoices.frame = CGRect(x: mode.frame.minX, y: mode.frame.minY, width: mode.frame.width, height: choicesHeight)
        if !modeChoices.isHidden { scroll.contentSize.height = max(y, modeChoices.frame.maxY + 16) }
        scroll.bringSubviewToFront(modeChoices)
        let messageWidth = min(340, max(0, viewport.bounds.width - 48))
        let messageHeight = max(48, message.sizeThatFits(CGSize(width: messageWidth, height: .greatestFiniteMagnitude)).height + 20)
        message.frame = CGRect(x: viewport.frame.midX - messageWidth / 2, y: viewport.frame.maxY - messageHeight - 16, width: messageWidth, height: messageHeight)
        view.bringSubviewToFront(message)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-test-timer-geometry"), let scene = view.window?.windowScene {
            // Observe the scene's delivered orientation in UI tests. A Duo or
            // resizable scene need not share its orientation's aspect ratio.
            panel.accessibilityValue = "orientation:\(scene.effectiveGeometry.interfaceOrientation.rawValue)"
        }
        #endif
    }
    override func viewSafeAreaInsetsDidChange() { super.viewSafeAreaInsetsDidChange(); view.setNeedsLayout() }
    func textFieldDidBeginEditing(_ textField: UITextField) {
        // UIKit's initiating tap places the caret after this delegate callback.
        // Select after that event, preserving the source selectAllOnFocus rule.
        DispatchQueue.main.async { [weak textField] in
            guard let textField, textField.isFirstResponder else { return }
            textField.selectAll(nil)
        }
    }
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard let text = textField.text, let range = Range(range, in: text) else { return false }
        let result = text.replacingCharacters(in: range, with: string)
        return result.count <= 3 && result.allSatisfy { $0.isASCII && $0.isNumber }
    }
    override var keyCommands: [UIKeyCommand]? { [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close))] }
    @objc private func close() { dismiss(animated: true) }
    @objc private func outside(_ gesture: UITapGestureRecognizer) {
        if !panel.frame.contains(gesture.location(in: viewport)) { close() }
        else if !modeChoices.isHidden && !modeChoices.frame.contains(gesture.location(in: scroll)) { modeChoices.isHidden = true }
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: panel)
        return modeChoices.isHidden && scroll.contentOffset.y <= 0 && velocity.y > abs(velocity.x)
    }
    @objc private func dragSheet(_ gesture: UIPanGestureRecognizer) {
        let distance = max(0, gesture.translation(in: viewport).y)
        if gesture.state == .changed { panel.transform = CGAffineTransform(translationX: 0, y: distance) }
        else if gesture.state == .ended || gesture.state == .cancelled {
            if gesture.state == .ended && (distance > min(100, panel.bounds.height / 3) || gesture.velocity(in: viewport).y > 700) { close() }
            else { UIView.animate(withDuration: 0.2) { self.panel.transform = .identity } }
        }
    }
    override func accessibilityPerformEscape() -> Bool { close(); return true }
}

@MainActor private final class SleepTimerCheckbox: UIButton {
    var checked = false {
        // The sheet refreshes on every playback tick; repaint only when the box changes.
        didSet { accessibilityValue = checked ? Appearance.text("on") : Appearance.text("off"); if checked != oldValue { setNeedsDisplay() } }
    }
    init() { super.init(frame: .zero); contentHorizontalAlignment = .leading; setTitleColor(Appearance.foreground, for: .normal) }
    required init?(coder: NSCoder) { fatalError() }
    override func titleRect(forContentRect rect: CGRect) -> CGRect {
        CGRect(x: effectiveUserInterfaceLayoutDirection == .rightToLeft ? 0 : 36, y: 0, width: max(0, rect.width - 36), height: rect.height)
    }
    override func draw(_ rect: CGRect) {
        super.draw(rect)
        let x: CGFloat = effectiveUserInterfaceLayoutDirection == .rightToLeft ? bounds.width - 28 : 8
        let box = UIBezierPath(roundedRect: CGRect(x: x, y: bounds.midY - 9, width: 18, height: 18), cornerRadius: 1)
        (checked ? Appearance.accent : Appearance.secondary).setStroke(); box.lineWidth = 2; box.stroke()
        if checked {
            Appearance.accent.setFill(); box.fill(); UIColor.white.setStroke()
            let path = UIBezierPath(); path.move(to: CGPoint(x: x + 3, y: bounds.midY)); path.addLine(to: CGPoint(x: x + 7, y: bounds.midY + 4))
            path.addLine(to: CGPoint(x: x + 15, y: bounds.midY - 5)); path.lineWidth = 2; path.stroke()
        }
    }
}

@MainActor private final class SleepTimerNumberField: UITextField {
    override func textRect(forBounds bounds: CGRect) -> CGRect { bounds.insetBy(dx: 4, dy: 0) }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { textRect(forBounds: bounds) }
    override func draw(_ rect: CGRect) {
        super.draw(rect)
        let line = UIBezierPath(); line.move(to: CGPoint(x: 0, y: bounds.height - 7)); line.addLine(to: CGPoint(x: bounds.width, y: bounds.height - 7))
        (isFirstResponder ? Appearance.accent : Appearance.secondary).setStroke(); line.lineWidth = isFirstResponder ? 2 : 1; line.stroke()
    }
}
@MainActor private final class SleepTimerActionButton: UIButton {
    var filled = false { didSet { setNeedsDisplay() } }
    override func draw(_ rect: CGRect) {
        let path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 4), cornerRadius: 20)
        if filled { Appearance.accent.setFill(); path.fill() }
        else { Appearance.secondary.setStroke(); path.lineWidth = 1; path.stroke() }
        super.draw(rect)
    }
}
@MainActor private final class SleepTimerModeButton: UIButton {
    override func titleRect(forContentRect rect: CGRect) -> CGRect {
        CGRect(x: effectiveUserInterfaceLayoutDirection == .rightToLeft ? 40 : 8, y: 0, width: max(0, rect.width - 48), height: rect.height)
    }
    override func draw(_ rect: CGRect) {
        super.draw(rect)
        let x: CGFloat = effectiveUserInterfaceLayoutDirection == .rightToLeft ? 20 : bounds.width - 20
        let path = UIBezierPath(); path.move(to: CGPoint(x: x - 5, y: bounds.midY - 2.5))
        path.addLine(to: CGPoint(x: x + 5, y: bounds.midY - 2.5)); path.addLine(to: CGPoint(x: x, y: bounds.midY + 2.5)); path.close()
        Appearance.secondary.setFill(); path.fill()
    }
}
