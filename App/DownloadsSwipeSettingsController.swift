import UIKit
import NotTennaPodCore

@MainActor enum DownloadsSwipeSettingsController {
    static func make(value: DownloadsSwipePreferences?, save: @escaping (DownloadsSwipePreferences) -> Void) -> SourceMessageController {
        let body = DownloadsSwipeSettingsBody(value: value ?? .init())
        let dialog = SourceMessageController(title: Appearance.text("swipeactions_label") + " - " + Appearance.text("downloads_label"), message: "",
            positive: .init(title: Appearance.text("confirm_label"), identifier: "downloadsSwipeConfirm", perform: { save(body.draft) }, performAfterDismiss: true),
            negative: .init(title: Appearance.text("cancel_label"), identifier: "downloadsSwipeCancel"), customBody: body)
        body.pick = { [weak dialog, weak body] direction in
            guard let dialog, let body else { return }
            let choices = SwipeSettingsPickerBody(actions: DownloadsSwipeAction.allCases, selected: body.pickedDirections.contains(direction) ? body.draft.action(direction) : nil)
            let picker = SourceMessageController(title: Appearance.text(direction == .left ? "swipe_left" : "swipe_right"), message: "",
                positive: .init(title: Appearance.text("cancel_label"), identifier: "downloadsSwipePickerCancel"), customBody: choices)
            choices.select = { [weak picker, weak body, weak dialog] action in
                if direction == .left { body?.draft.left = action } else { body?.draft.right = action }
                body?.pickedDirections.insert(direction)
                body?.refresh(); dialog?.view.setNeedsLayout(); picker?.dismiss(animated: true)
            }
            dialog.present(picker, animated: true)
        }
        return dialog
    }
}

@MainActor final class DownloadsSwipeSettingsBody: UIView {
    var draft: DownloadsSwipePreferences
    var pickedDirections: Set<EpisodeSwipeDirection> = []
    var pick: ((EpisodeSwipeDirection) -> Void)?
    private let toggle = UIControl(), toggleLabel = Appearance.label(Appearance.text("enable_swipeactions"), size: 14)
    private let switchImage = PreferenceSwitchView()
    private let rows: [SwipeSettingsDirectionRow<DownloadsSwipeAction>] = [.init(direction: .left, action: .delete), .init(direction: .right, action: .delete)]
    init(value: DownloadsSwipePreferences) {
        draft = value; super.init(frame: .zero)
        accessibilityIdentifier = "downloadsSwipeSettings"
        toggle.accessibilityIdentifier = "downloadsSwipeEnabled"
        toggle.isAccessibilityElement = true; toggle.accessibilityLabel = toggleLabel.text; toggle.accessibilityTraits = .button
        toggleLabel.isUserInteractionEnabled = false; switchImage.isUserInteractionEnabled = false
        toggle.addSubview(toggleLabel); toggle.addSubview(switchImage); addSubview(toggle)
        toggle.addAction(UIAction { [weak self] _ in self?.draft.enabled.toggle(); self?.refresh() }, for: .touchUpInside)
        for row in rows { row.change = { [weak self, weak row] in if let row { self?.pick?(row.direction) } }; addSubview(row) }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    func refresh() {
        switchImage.isOn = draft.enabled; toggle.accessibilityValue = draft.enabled ? Appearance.text("on") : Appearance.text("off")
        for row in rows { row.action = draft.action(row.direction); row.alpha = draft.enabled ? 1 : 0.4 }
        setNeedsLayout()
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: layout(size.width, apply: false)) }
    override func layoutSubviews() { super.layoutSubviews(); _ = layout(bounds.width, apply: true) }
    private func layout(_ width: CGFloat, apply: Bool) -> CGFloat {
        let inset = min(16, width / 2), available = max(0, width - inset * 2)
        toggleLabel.font = Appearance.font(14, compatibleWith: traitCollection)
        let labelWidth = max(0, available - 68), height = max(48, toggleLabel.sizeThatFits(CGSize(width: labelWidth, height: .greatestFiniteMagnitude)).height + 16)
        if apply {
            toggle.frame = CGRect(x: inset, y: 16, width: available, height: height)
            let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
            toggleLabel.frame = CGRect(x: rtl ? 68 : 0, y: 0, width: labelWidth, height: height)
            switchImage.frame = CGRect(x: rtl ? 0 : max(0, available - 52), y: (height - 32)/2, width: 52, height: 32)
        }
        var y = 16 + height
        for row in rows {
            let h = row.sizeThatFits(CGSize(width: available, height: .greatestFiniteMagnitude)).height
            if apply { row.frame = CGRect(x: inset, y: y, width: available, height: h) }
            y += h
        }
        return y + 16
    }
}

@MainActor protocol SwipeSettingsOption: Equatable {
    var identifier: String { get }
    var titleKey: String { get }
    var icon: String { get }
    var swipeColor: UIColor { get }
}

@MainActor final class SwipeSettingsDirectionRow<Action: SwipeSettingsOption>: UIView {
    let direction: EpisodeSwipeDirection
    var change: (() -> Void)?
    var action: Action { didSet { update() } }
    private let heading: UILabel, summary = Appearance.label(nil, size: 14)
    private let changeButton = UIButton(type: .system), preview = UIControl(), iconRegion = UIView(), icon = UIImageView()
    private let mock = DownloadsSwipeMockEpisode()
    private let topLine = UIView(), bottomLine = UIView()
    init(direction: EpisodeSwipeDirection, action: Action, identifierPrefix: String = "downloadsSwipe") {
        self.action = action; self.direction = direction; heading = Appearance.label(Appearance.text(direction == .left ? "swipe_left" : "swipe_right"), size: 18)
        super.init(frame: .zero)
        changeButton.setTitle(Appearance.text("change_setting"), for: .normal); changeButton.tintColor = Appearance.accent
        changeButton.accessibilityIdentifier = identifierPrefix + "Change-" + direction.rawValue
        changeButton.addAction(UIAction { [weak self] _ in self?.change?() }, for: .touchUpInside)
        preview.addAction(UIAction { [weak self] _ in self?.change?() }, for: .touchUpInside)
        preview.accessibilityIdentifier = identifierPrefix + "Preview-" + direction.rawValue
        preview.isAccessibilityElement = true; preview.accessibilityTraits = .button
        preview.backgroundColor = Appearance.background
        iconRegion.backgroundColor = Appearance.elevated
        icon.contentMode = .scaleAspectFit; icon.isUserInteractionEnabled = false
        mock.alpha = 0.3; mock.isUserInteractionEnabled = false; iconRegion.isUserInteractionEnabled = false
        preview.addSubview(mock); preview.addSubview(iconRegion); iconRegion.addSubview(icon)
        summary.textColor = Appearance.secondary
        [heading, summary, changeButton, preview, topLine, bottomLine].forEach(addSubview)
        topLine.backgroundColor = Appearance.secondary; bottomLine.backgroundColor = topLine.backgroundColor
        update()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func update() {
        summary.text = Appearance.text(action.titleKey); icon.image = UIImage(named: action.icon); icon.tintColor = action.swipeColor
        preview.accessibilityLabel = heading.text; preview.accessibilityValue = summary.text; setNeedsLayout()
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        heading.font = Appearance.font(18, compatibleWith: traitCollection); summary.font = Appearance.font(14, compatibleWith: traitCollection)
        let w = max(0, size.width - 80)
        return CGSize(width: size.width, height: 16 + max(48, heading.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height + summary.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height) + 8 + 78)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft, textWidth = max(0, bounds.width - 80)
        let headHeight = heading.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        let headerHeight = bounds.height - 102
        heading.frame = CGRect(x: rtl ? 80 : 0, y: 16, width: textWidth, height: headHeight)
        summary.frame = CGRect(x: rtl ? 80 : 0, y: 16 + headHeight, width: textWidth, height: max(0, headerHeight - headHeight))
        changeButton.titleLabel?.font = Appearance.font(14, medium: true, compatibleWith: traitCollection)
        changeButton.frame = CGRect(x: rtl ? 0 : textWidth, y: 16, width: min(80, bounds.width), height: headerHeight)
        let y = 16 + headerHeight + 8
        topLine.frame = CGRect(x: 0, y: y, width: bounds.width, height: 1)
        preview.frame = CGRect(x: 0, y: y + 1, width: bounds.width, height: 76)
        bottomLine.frame = CGRect(x: 0, y: y + 77, width: bounds.width, height: 1)
        let iconWidth = bounds.width * 0.3
        let iconLeft = direction == .right
        iconRegion.frame = CGRect(x: iconLeft ? 0 : bounds.width - iconWidth, y: 0, width: iconWidth, height: 76)
        icon.frame = iconRegion.bounds.insetBy(dx: min(22, iconWidth/2), dy: 22)
        mock.frame = CGRect(x: iconLeft ? iconWidth : 0, y: 0, width: bounds.width - iconWidth, height: 76)
    }
}

/// Source's unbound episode-row preview: visible status icons, block text and empty progress.
@MainActor private final class DownloadsSwipeMockEpisode: UIView {
    private let cover = UIView(), progress = UIView()
    private let icons = ["ic_videocam", "ic_star", "ic_playlist_play"].map { UIImageView(image: UIImage(named: $0)) }
    private let dots = [Appearance.label("·", size: 11), Appearance.label("·", size: 11)]
    private let titleBlocks = (0..<7).map { _ in UIView() }, positionBlocks = (0..<5).map { _ in UIView() }
    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        cover.backgroundColor = Appearance.color(0xbfbfbf, 0xbfbfbf); cover.layer.cornerRadius = 8
        icons.forEach { $0.tintColor = Appearance.secondary; $0.contentMode = .scaleAspectFit; addSubview($0) }
        dots.forEach { $0.textColor = Appearance.secondary; addSubview($0) }
        titleBlocks.forEach { $0.backgroundColor = Appearance.foreground; addSubview($0) }
        positionBlocks.forEach { $0.backgroundColor = Appearance.secondary; addSubview($0) }
        progress.backgroundColor = Appearance.color(0xd3dce0, 0x3c4e68); progress.layer.cornerRadius = 2
        addSubview(cover); addSubview(progress)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = Appearance.font(16, compatibleWith: traitCollection).pointSize / 16
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: rtl ? bounds.width-x-w : x, y: y, width: w, height: h)
        }
        cover.frame = rect(16, (bounds.height-56)/2, 56, 56)
        let x: CGFloat = 88, top = (bounds.height-50*scale)/2
        for (i, icon) in icons.enumerated() { icon.frame = rect(x+CGFloat(i)*12*scale, top+scale, 12*scale, 12*scale) }
        for (i, dot) in dots.enumerated() {
            dot.font = Appearance.font(11, medium: true, compatibleWith: traitCollection)
            dot.frame = rect(x+(40+CGFloat(i)*11.5)*scale, top, 4*scale, 15*scale)
        }
        // Android's fallback U+2588 glyph has separate narrow advances. Draw the
        // literal placeholder blocks so Apple font fallback cannot merge/widen them.
        for (i, block) in titleBlocks.enumerated() { block.frame = rect(x+CGFloat(i)*11.8*scale, top+17*scale, 11.4*scale, 19*scale) }
        for (i, block) in positionBlocks.enumerated() { block.frame = rect(x+CGFloat(i)*8.5*scale, top+38*scale, 8.1*scale, 12*scale) }
        let progressX = x+42.5*scale+4
        progress.frame = rect(progressX, top+42*scale, max(0, bounds.width-progressX-12), 4)
    }
}

@MainActor final class SwipeSettingsPickerBody<Action: SwipeSettingsOption>: UIView {
    var select: ((Action) -> Void)?
    private var buttons: [UIButton] = []
    init(actions: [Action], selected: Action?, identifierPrefix: String = "downloadsSwipe") {
        super.init(frame: .zero)
        for action in actions {
            let button = UIButton(type: .custom), icon = UIImageView(image: UIImage(named: action.icon)), label = Appearance.label(Appearance.text(action.titleKey), size: 14)
            button.accessibilityIdentifier = identifierPrefix + "Choice-" + action.identifier
            button.accessibilityLabel = label.text; label.textAlignment = .center; label.isUserInteractionEnabled = false
            icon.tintColor = action == selected ? action.swipeColor : Appearance.foreground
            label.textColor = icon.tintColor
            icon.contentMode = .scaleAspectFit; icon.isUserInteractionEnabled = false
            button.addSubview(icon); button.addSubview(label); button.addAction(UIAction { [weak self] _ in self?.select?(action) }, for: .touchUpInside)
            addSubview(button); buttons.append(button)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: layout(size.width, apply: false)) }
    override func layoutSubviews() { super.layoutSubviews(); _ = layout(bounds.width, apply: true) }
    private func layout(_ width: CGFloat, apply: Bool) -> CGFloat {
        let w = max(0, (width - 32)/2), rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        var y: CGFloat = 16
        for row in 0..<((buttons.count + 1)/2) {
            let items = buttons[(row*2)..<min(buttons.count, row*2+2)]
            let textHeight = items.map { button in
                let label = button.subviews[1] as! UILabel; label.font = Appearance.font(14, compatibleWith: traitCollection)
                return label.sizeThatFits(CGSize(width: max(0,w-16), height: .greatestFiniteMagnitude)).height
            }.max() ?? 0
            let h = 64 + textHeight
            if apply { for (column,button) in items.enumerated() {
                button.frame = CGRect(x: 16 + CGFloat(rtl ? 1-column : column)*w, y: y, width: w, height: h)
                button.subviews[0].frame = CGRect(x: (w-32)/2, y: 16, width: 32, height: 32)
                button.subviews[1].frame = CGRect(x: 8, y: 56, width: max(0,w-16), height: textHeight)
            } }
            y += h
        }
        return y + 16
    }
}

@MainActor extension DownloadsSwipeAction: SwipeSettingsOption {
    var identifier: String { rawValue }
    var swipeColor: UIColor {
        switch self { case .queue: Appearance.accent; case .delete: Appearance.color(0xcf1800, 0xcf1800)
        case .favorite: Appearance.color(0xf59f00, 0xf59f00); case .played: Appearance.color(0x25365a, 0xcdd9e4) }
    }
}
