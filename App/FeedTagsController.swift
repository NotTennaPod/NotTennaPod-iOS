import UIKit
import NotTennaPodCore

@MainActor enum FeedTagsController {
    static func make(feed: LibraryFeed, suggestions: [String], bottomNavigation: Bool,
                     save: @escaping ([String]) -> Void) -> SourceMessageController {
        make(draft: FeedTags(tags: feed.tags), suggestions: suggestions, bottomNavigation: bottomNavigation) {
            save($0.saved)
        }
    }
    static func make(draft: FeedTags, suggestions: [String], bottomNavigation: Bool,
                     save: @escaping (FeedTags) -> Void) -> SourceMessageController {
        let body = FeedTagsBody(draft: draft, suggestions: suggestions, showRoot: !bottomNavigation)
        let controller = SourceMessageController(title: Appearance.text("feed_tags_label"), message: "",
            positive: .init(title: Appearance.text("ok"), identifier: "feedTagsSave", perform: {
                _ = body.addDraft(); save(body.draft)
            }), negative: .init(title: Appearance.text("cancel_label"), identifier: "feedTagsCancel"), customBody: body)
        controller.avoidsKeyboard = true
        body.changed = { [weak controller] in controller?.view.setNeedsLayout() }
        controller.loadViewIfNeeded(); body.suggestionHost = controller.view
        return controller
    }
}

@MainActor final class FeedTagsBody: UIView, UITextFieldDelegate, SourceMessageBodyViewport, SourceMessageEditingBody {
    private(set) var draft: FeedTags
    let field = UITextField()
    var changed: (() -> Void)?
    weak var suggestionHost: UIView?
    var editingControl: UIView? { field.isFirstResponder ? field : nil }
    func messageBodyDidScroll() { setNeedsLayout() }
    private let suggestions: [String], showRoot: Bool
    private let root = TagRootButton(type: .system)
    /// `commonTagsInfo`: shown only when several feeds are edited.
    private let info = Appearance.label(Appearance.text("multi_feed_common_tags_info"), size: 12)
    private let outline = UIView()
    private let hint = UILabel()
    private var add: UIButton!
    private var chips: [UIView] = [], suggestionButtons: [UIButton] = []
    private var suggestionsOpen = false
    private let dropdown = UIScrollView()
    var minimumMessageViewportHeight: CGFloat { max(56, Appearance.font(16, compatibleWith: traitCollection).lineHeight + 32) }

    convenience init(tags: [String], suggestions: [String], showRoot: Bool) {
        self.init(draft: FeedTags(tags: tags), suggestions: suggestions, showRoot: showRoot)
    }
    init(draft: FeedTags, suggestions: [String], showRoot: Bool) {
        self.draft = draft; self.suggestions = suggestions; self.showRoot = showRoot
        super.init(frame: .zero)
        accessibilityIdentifier = "feedTagsBody"
        root.accessibilityIdentifier = "feedTagsRoot"
        root.contentHorizontalAlignment = .leading; root.titleLabel?.numberOfLines = 0
        root.setTitle(Appearance.text("feed_folders_include_root"), for: .normal)
        root.tintColor = Appearance.foreground; root.isHidden = !showRoot
        root.addAction(UIAction { [weak self] _ in
            guard let self else { return }; self.draft.includeRoot.toggle(); updateRoot()
        }, for: .touchUpInside)
        addSubview(root)
        info.textAlignment = .center; info.textColor = Appearance.foreground
        info.accessibilityIdentifier = "feedTagsCommonInfo"; info.isHidden = !draft.isMultiple
        addSubview(info)
        outline.layer.borderWidth = 1; outline.layer.cornerRadius = 4
        outline.layer.borderColor = Appearance.secondary.cgColor; addSubview(outline)
        dropdown.backgroundColor = Appearance.navigation
        dropdown.contentInsetAdjustmentBehavior = .never
        dropdown.accessibilityIdentifier = "feedTagSuggestions"
        field.accessibilityIdentifier = "feedTagInput"; field.placeholder = Appearance.text("add_tag")
        field.textColor = Appearance.foreground; field.returnKeyType = .done
        field.tintColor = Appearance.accent
        field.autocorrectionType = .no; field.autocapitalizationType = .none; field.delegate = self
        field.addAction(UIAction { [weak self] _ in self?.rebuildSuggestions() }, for: .editingChanged)
        outline.addSubview(field)
        hint.text = Appearance.text("add_tag"); hint.backgroundColor = Appearance.surfaceVariant
        hint.isAccessibilityElement = false; addSubview(hint)
        add = Appearance.icon("ic_add", label: Appearance.text("add_tag")) { [weak self] in _ = self?.addDraft() }
        add.tintColor = Appearance.secondary
        add.accessibilityIdentifier = "feedTagAdd"; outline.addSubview(add)
        updateRoot(); rebuildChips()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func updateRoot() {
        root.checked = draft.includeRoot
        root.accessibilityTraits = draft.includeRoot ? [.button, .selected] : .button
    }
    @discardableResult func addDraft() -> Bool {
        guard draft.add(field.text ?? "") else { field.becomeFirstResponder(); return false }
        field.text = ""; suggestionsOpen = false
        rebuildChips(); rebuildSuggestions(); return true
    }
    func textFieldDidBeginEditing(_ textField: UITextField) { suggestionsOpen = true; rebuildSuggestions() }
    func textFieldDidEndEditing(_ textField: UITextField) { suggestionsOpen = false; rebuildSuggestions() }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { _ = addDraft(); return true }
    private func rebuildChips() {
        chips.forEach { $0.removeFromSuperview() }
        chips = draft.displayed.enumerated().map { index, name in
            let chip = UIView()
            let surface = UIView(); surface.isUserInteractionEnabled = false
            surface.accessibilityIdentifier = "feedTagSurface-\(index)"
            surface.layer.cornerRadius = 8; surface.layer.borderWidth = 1
            // Material's 6dp dialog elevation tints the chip's surface color.
            surface.backgroundColor = Appearance.color(0xdeeef8, 0x233141)
            surface.tag = 3; chip.addSubview(surface)
            let label = Appearance.label(name, size: 14); label.lineBreakMode = .byTruncatingTail; label.numberOfLines = 1
            label.tag = 1; chip.addSubview(label)
            let remove = TagRemoveButton(type: .custom)
            remove.setImage(UIImage(named: "ic_delete"), for: .normal)
            remove.tintColor = Appearance.secondary
            remove.accessibilityLabel = Appearance.text("delete_label") + " " + name
            remove.addAction(UIAction { [weak self] _ in
                guard let self else { return }; draft.remove(at: index); rebuildChips()
            }, for: .touchUpInside)
            remove.accessibilityIdentifier = "feedTagRemove-\(index)"; remove.tag = 2
            chip.addSubview(remove); addSubview(chip); return chip
        }
        setNeedsLayout(); changed?()
    }
    private func rebuildSuggestions() {
        suggestionButtons.forEach { $0.removeFromSuperview() }
        let prefix = (field.text ?? "").lowercased()
        suggestionButtons = (suggestionsOpen ? suggestions.filter {
            prefix.isEmpty || $0.lowercased().hasPrefix(prefix) || $0.lowercased().split(separator: " ").contains { $0.hasPrefix(prefix) }
        } : []).enumerated().map { index, name in
            let button = UIButton(type: .system)
            button.setTitle(name, for: .normal); button.tintColor = Appearance.foreground
            button.backgroundColor = Appearance.navigation; button.contentHorizontalAlignment = .leading
            button.accessibilityIdentifier = "feedTagSuggestion-\(index)"
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }; field.text = name; suggestionsOpen = false; rebuildSuggestions()
            }, for: .touchUpInside)
            dropdown.addSubview(button); return button
        }
        setNeedsLayout(); changed?()
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: arrange(width: size.width, apply: false)) }
    override func layoutSubviews() { super.layoutSubviews(); _ = arrange(width: bounds.width, apply: true) }
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        let inset = min(16, max(0, width / 2)), available = max(0, width - inset * 2)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let font = Appearance.font(16, compatibleWith: traitCollection)
        field.font = font; root.titleLabel?.font = font
        field.attributedPlaceholder = NSAttributedString(string: Appearance.text("add_tag"), attributes: [.foregroundColor: Appearance.secondary, .font: font])
        let showsHint = field.isFirstResponder || !(field.text ?? "").isEmpty
        if showsHint { field.placeholder = nil }
        hint.isHidden = !showsHint; hint.font = Appearance.font(12, compatibleWith: traitCollection)
        hint.textColor = field.isFirstResponder ? Appearance.accent : Appearance.secondary
        outline.layer.borderColor = (field.isFirstResponder ? Appearance.accent : Appearance.secondary).resolvedColor(with: traitCollection).cgColor
        outline.layer.borderWidth = field.isFirstResponder ? 2 : 1
        var y: CGFloat = 16
        if showRoot {
            let height = max(48, (root.titleLabel?.sizeThatFits(CGSize(width: max(0, available - 32), height: .greatestFiniteMagnitude)).height ?? 0) + 16)
            if apply { root.frame = CGRect(x: inset, y: y, width: available, height: height) }
            y += height
        }
        if !info.isHidden {
            info.font = Appearance.font(12, compatibleWith: traitCollection)
            let height = ceil(info.sizeThatFits(CGSize(width: available, height: .greatestFiniteMagnitude)).height)
            if apply { info.frame = CGRect(x: inset, y: y, width: available, height: height) }
            y += height + 16
        }
        let chipFont = Appearance.font(14, medium: true, compatibleWith: traitCollection)
        let column = max(0, (available - 16) / 2)
        let visibleHeight = max(32, chipFont.lineHeight), chipHeight = visibleHeight + 16
        for (i, chip) in chips.enumerated() {
            let index = rtl ? 1 - i % 2 : i % 2
            if apply {
                chip.frame = CGRect(x: inset + 4 + CGFloat(index) * (column + 8), y: y + CGFloat(i / 2) * (chipHeight + 8) + 4, width: column, height: chipHeight)
                let surface = chip.viewWithTag(3)
                surface?.frame = CGRect(x: 0, y: 8, width: column, height: visibleHeight)
                surface?.layer.borderColor = Appearance.secondary.resolvedColor(with: traitCollection).cgColor
                let removeWidth = min(34, column)
                let label = chip.viewWithTag(1) as? UILabel
                label?.attributedText = NSAttributedString(string: draft.displayed[i], attributes: [
                    .font: chipFont, .kern: chipFont.pointSize * 0.00714286,
                    .foregroundColor: Appearance.foreground
                ])
                label?.frame = CGRect(x: rtl ? removeWidth : 16, y: 8, width: max(0, column - removeWidth - 16), height: visibleHeight)
                chip.viewWithTag(2)?.frame = CGRect(x: rtl ? 0 : column - removeWidth, y: 8, width: removeWidth, height: visibleHeight)
            }
        }
        y += CGFloat((chips.count + 1) / 2) * (chipHeight + 8)
        let inputHeight = max(56, font.lineHeight + 32)
        if apply {
            outline.frame = CGRect(x: inset, y: y + 8, width: available, height: inputHeight)
            let actionWidth = min(48, available)
            field.frame = CGRect(x: rtl ? actionWidth : min(16, available), y: 0, width: max(0, available - actionWidth - 16), height: inputHeight)
            add.frame = CGRect(x: rtl ? 0 : available - actionWidth, y: 0, width: actionWidth, height: inputHeight)
            let hintWidth = min(max(0, available - 24), hint.intrinsicContentSize.width + 8)
            hint.frame = CGRect(x: outline.frame.minX + (rtl ? max(0, available - 12 - hintWidth) : min(12, available)),
                y: outline.frame.minY - hint.font.lineHeight / 2, width: hintWidth, height: hint.font.lineHeight)
        }
        y += inputHeight + 8
        var dropdownHeight: CGFloat = 0
        for button in suggestionButtons {
            button.titleLabel?.font = font
            let height = max(48, font.lineHeight + 16)
            if apply { button.frame = CGRect(x: 16, y: dropdownHeight, width: max(0, available - 32), height: height) }
            dropdownHeight += height
        }
        if apply, let host = suggestionHost {
            if suggestionButtons.isEmpty { dropdown.removeFromSuperview() }
            else {
                if dropdown.superview !== host { host.addSubview(dropdown) }
                var safe = host.safeAreaLayoutGuide.layoutFrame
                safe.size.height = max(0, min(safe.maxY, host.keyboardLayoutGuide.layoutFrame.minY) - safe.minY)
                let anchor = outline.convert(outline.bounds, to: host)
                var visible = safe, ancestor = outline.superview
                while let current = ancestor, current !== host {
                    if current.clipsToBounds { visible = visible.intersection(current.convert(current.bounds, to: host)) }
                    ancestor = current.superview
                }
                dropdown.isHidden = visible.isNull || !visible.intersects(anchor)
                let below = min(safe.height, max(0, safe.maxY - anchor.maxY))
                let above = min(safe.height, max(0, anchor.minY - safe.minY))
                let useBelow = below >= min(dropdownHeight, 96) || below >= above
                let height = min(dropdownHeight, useBelow ? below : above)
                dropdown.frame = CGRect(x: max(safe.minX, min(anchor.minX, safe.maxX - available)),
                    y: max(safe.minY, min(useBelow ? anchor.maxY : anchor.minY - height, safe.maxY - height)),
                    width: max(0, min(available, safe.width)), height: height)
                dropdown.contentSize = CGSize(width: available, height: dropdownHeight)
            }
        }
        return y + 16
    }
}

@MainActor private final class TagRemoveButton: UIButton {
    override func imageRect(forContentRect rect: CGRect) -> CGRect {
        CGRect(x: rect.midX - 9, y: rect.midY - 9, width: 18, height: 18)
    }
}

@MainActor private final class TagRootButton: UIButton {
    var checked = false { didSet { setNeedsDisplay() } }
    override func titleRect(forContentRect rect: CGRect) -> CGRect {
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        return CGRect(x: rtl ? 0 : 32, y: 0, width: max(0, rect.width - 32), height: rect.height)
    }
    override func draw(_ rect: CGRect) {
        super.draw(rect)
        let x: CGFloat = effectiveUserInterfaceLayoutDirection == .rightToLeft ? bounds.width - 24 : 4
        let box = UIBezierPath(roundedRect: CGRect(x: x, y: bounds.midY - 9, width: 18, height: 18), cornerRadius: 1)
        (checked ? Appearance.accent : Appearance.secondary).setStroke(); box.lineWidth = 2; box.stroke()
        if checked {
            Appearance.accent.setFill(); box.fill(); UIColor.white.setStroke()
            let mark = UIBezierPath(); mark.move(to: CGPoint(x: x + 3, y: bounds.midY))
            mark.addLine(to: CGPoint(x: x + 7, y: bounds.midY + 4)); mark.addLine(to: CGPoint(x: x + 15, y: bounds.midY - 5))
            mark.lineWidth = 2; mark.stroke()
        }
    }
}
