import UIKit
import NotTennaPodCore
import CoreText

@MainActor final class UsageSuggestionView: UIControl {
    var respond: ((Bool) -> Void)?
    var dismiss: (() -> Void)?
    private let group = UIView()
    private let card = UIControl()
    private let arrow = UIImageView(image: UIImage(named: "usage_suggestion_arrow"))
    private let message = TopAlignedSuggestionLabel()
    private let no = UIButton(type: .custom), yes = UIButton(type: .custom)
    private let offerStreaming: Bool
    private var anchorBottom: CGFloat
    init(frame: CGRect, anchorBottom: CGFloat, offerStreaming: Bool) {
        self.offerStreaming = offerStreaming; self.anchorBottom = anchorBottom
        super.init(frame: frame)
        accessibilityIdentifier = "usageSuggestion"
        accessibilityViewIsModal = true
        addSubview(group)
        [card, arrow, message, no, yes].forEach(group.addSubview)
        card.backgroundColor = Appearance.accent
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.2; card.layer.shadowRadius = 2
        card.layer.shadowOffset = CGSize(width: 0, height: 2)
        arrow.tintColor = Appearance.accent
        message.textColor = Appearance.color(0xffffff, 0x000000)
        message.font = Appearance.font(14)
        message.adjustsFontForContentSizeCategory = true
        message.numberOfLines = 3
        message.text = Appearance.text(offerStreaming ? "on_demand_config_stream_text" : "on_demand_config_download_text")
        message.accessibilityIdentifier = "usageSuggestionMessage"
        for (button, key) in [(no, "no"), (yes, "yes")] {
            button.setTitle(Appearance.text(key), for: .normal)
            button.setTitleColor(message.textColor, for: .normal)
            let font = Appearance.font(14, bold: true)
            button.setAttributedTitle(NSAttributedString(string: Appearance.text(key), attributes: [
                .font: font, .foregroundColor: message.textColor!, .kern: font.pointSize * 0.0892857143
            ]), for: .normal)
            button.accessibilityIdentifier = "usageSuggestion-" + key
        }
        no.addAction(UIAction { [weak self] _ in self?.respond?(false) }, for: .touchUpInside)
        yes.addAction(UIAction { [weak self] _ in self?.respond?(true) }, for: .touchUpInside)
        addAction(UIAction { [weak self] _ in self?.dismiss?() }, for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError() }
    func updateAnchorBottom(_ value: CGFloat) {
        guard anchorBottom != value else { return }
        anchorBottom = value
        setNeedsLayout()
    }
    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        let command = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapeSuggestion))
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }
    @objc private func escapeSuggestion() { dismiss?() }
    override func accessibilityPerformEscape() -> Bool { dismiss?(); return true }
    override func layoutSubviews() {
        super.layoutSubviews()
        group.frame = bounds
        let layout = UsageSuggestionLayout(width: bounds.width, anchorBottom: anchorBottom,
            messageLineHeight: message.font.lineHeight, messageFontHeight: CTFontGetBoundingBox(message.font as CTFont).height,
            noTextWidth: no.titleLabel?.intrinsicContentSize.width ?? 0,
            yesTextWidth: yes.titleLabel?.intrinsicContentSize.width ?? 0,
            offerStreaming: offerStreaming, rightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft,
            scale: traitCollection.displayScale)
        card.frame = layout.card; card.layer.cornerRadius = layout.cornerRadius
        arrow.frame = layout.arrow; message.frame = layout.message
        no.frame = layout.no; yes.frame = layout.yes
    }
    // Let taps outside the visible content reach the dismiss control.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === group ? self : hit
    }
    func animatePresentation() {
        layoutIfNeeded()
        becomeFirstResponder()
        if !UIAccessibility.isReduceMotionEnabled {
            let animation = CAKeyframeAnimation(keyPath: "transform.scale")
            animation.values = (0...30).map { UsageSuggestionLayout.presentationScale(at: Double($0) / 30) }
            animation.duration = 0.25
            // Animate the visible body about its own center, not the screen.
            let bottomPadding = max(arrow.frame.height - 1 / max(1, traitCollection.displayScale), 2)
            let rect = CGRect(x: 0, y: arrow.frame.minY, width: bounds.width,
                              height: card.frame.maxY + bottomPadding - arrow.frame.minY)
            group.layer.anchorPoint = CGPoint(x: rect.midX / bounds.width, y: rect.midY / bounds.height)
            group.layer.position = CGPoint(x: rect.midX, y: rect.midY)
            group.layer.add(animation, forKey: "suggestionEntrance")
        }
        UIAccessibility.post(notification: .screenChanged, argument: message)
    }
}

@MainActor private final class TopAlignedSuggestionLabel: UILabel {
    override func drawText(in rect: CGRect) {
        var textRect = rect
        let scale = max(1, traitCollection.displayScale)
        let fontTop = CTFontGetBoundingBox(font as CTFont).maxY
        let topPadding = max(0, ceil(fontTop * scale) - ceil(font.ascender * scale)) / scale
        textRect.origin.y += topPadding
        textRect.size.height = min(max(0, rect.height - topPadding), sizeThatFits(rect.size).height)
        super.drawText(in: textRect)
    }
}
