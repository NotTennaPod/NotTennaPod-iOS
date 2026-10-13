import UIKit
import NotTennaPodCore

@MainActor enum FeedPlaybackSpeedController {
    static func make(feedID: Int64, preferences: PlaybackSpeedPreferenceStore,
                     save: @escaping (FeedPlaybackSpeedDraft) -> Void) -> SourceMessageController {
        let body = FeedPlaybackSpeedBody(draft: .init(
            speed: preferences.value.feeds[feedID] ?? PlaybackSpeed.useGlobal,
            skipSilence: preferences.value.silence.feeds[feedID] ?? .global))
        return SourceMessageController(title: Appearance.text("playback_speed"), message: "",
            positive: .init(title: Appearance.text("ok"), identifier: "feedSpeedSave", perform: { save(body.draft) }),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "feedSpeedCancel"), customBody: body)
    }
}

@MainActor final class FeedPlaybackSpeedBody: UIView, SourceMessageBodyViewport {
    private(set) var draft: FeedPlaybackSpeedDraft
    private let global = SpeedCheckbox(titleKey: "global_default")
    private let silence = SpeedCheckbox()
    private let decrease = SpeedStepButton(image: "ic_minus", label: "decrease_speed")
    private let increase = SpeedStepButton(image: "ic_add", label: "increase_speed")
    private let slider = SpeedSlider()
    private let value = Appearance.label(nil, size: 14)
    private let speedRow = UIView()
    var minimumMessageViewportHeight: CGFloat { 48 }

    init(draft: FeedPlaybackSpeedDraft) {
        self.draft = draft; super.init(frame: .zero)
        accessibilityIdentifier = "feedPlaybackSpeedDraft"
        global.accessibilityIdentifier = "feedSpeedUseGlobal"
        silence.accessibilityIdentifier = "feedSpeedSkipSilence"
        decrease.accessibilityIdentifier = "feedSpeedDecrease"
        increase.accessibilityIdentifier = "feedSpeedIncrease"
        slider.accessibilityIdentifier = "feedSpeedSlider"; slider.accessibilityLabel = Appearance.text("playback_speed")
        value.accessibilityIdentifier = "feedSpeedValue"; value.textColor = Appearance.secondary
        [global, speedRow, silence].forEach(addSubview)
        [decrease, slider, increase, value].forEach(speedRow.addSubview)
        global.addAction(UIAction { [weak self] _ in
            guard let self else { return }; self.draft.usesGlobal.toggle(); update()
        }, for: .touchUpInside)
        silence.addAction(UIAction { [weak self] _ in
            guard let self, !self.draft.usesGlobal else { return }; self.draft.skipsSilence.toggle(); update()
        }, for: .touchUpInside)
        decrease.addAction(UIAction { [weak self] _ in self?.step(-1) }, for: .touchUpInside)
        increase.addAction(UIAction { [weak self] _ in self?.step(1) }, for: .touchUpInside)
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }; self.draft.move(to: slider.progress); update()
        }, for: .valueChanged)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func step(_ amount: Int) { draft.step(amount); update() }
    private func update() {
        global.checked = draft.usesGlobal; silence.checked = draft.skipsSilence
        [decrease, slider, increase, silence].forEach {
            $0.isEnabled = !draft.usesGlobal
            if draft.usesGlobal { $0.accessibilityTraits.insert(.notEnabled) }
            else { $0.accessibilityTraits.remove(.notEnabled) }
        }
        speedRow.alpha = draft.usesGlobal ? 0.4 : 1; silence.alpha = speedRow.alpha
        slider.progress = draft.progress
        slider.accessibilityValue = PlaybackSpeedDialogState.text(draft.sliderSpeed)
        value.text = draft.label(); setNeedsLayout()
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: layout(width: size.width, apply: false)) }
    override func layoutSubviews() { super.layoutSubviews(); _ = layout(width: bounds.width, apply: true) }
    private func layout(width: CGFloat, apply: Bool) -> CGFloat {
        let inset = min(16, width / 2), available = max(0, width - 2 * inset)
        let font = Appearance.font(14, compatibleWith: traitCollection)
        value.font = font
        let rowHeight = max(48, font.lineHeight + 16)
        let globalHeight = global.sizeThatFits(CGSize(width: available, height: .greatestFiniteMagnitude)).height
        let silenceHeight = silence.sizeThatFits(CGSize(width: available, height: .greatestFiniteMagnitude)).height
        if apply {
            global.frame = CGRect(x: inset, y: 16, width: available, height: globalHeight)
            speedRow.frame = CGRect(x: inset, y: global.frame.maxY, width: available, height: rowHeight)
            silence.frame = CGRect(x: inset, y: speedRow.frame.maxY, width: available, height: silenceHeight)
            let labelWidth = min(max(0, available - 48), max(0, value.intrinsicContentSize.width))
            let controls = max(0, available - labelWidth - 8), stepWidth = min(48, controls / 3)
            let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
            func rect(_ x: CGFloat, _ width: CGFloat) -> CGRect {
                CGRect(x: rtl ? available - x - width : x, y: 0, width: width, height: rowHeight)
            }
            decrease.frame = rect(0, stepWidth)
            slider.frame = rect(stepWidth, max(0, controls - stepWidth * 2))
            increase.frame = rect(controls - stepWidth, stepWidth)
            value.frame = rect(controls + 8, labelWidth)
        }
        return globalHeight + rowHeight + silenceHeight + 32
    }
}
