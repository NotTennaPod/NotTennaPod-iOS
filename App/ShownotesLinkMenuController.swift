import UIKit
import NotTennaPodCore

/// The platform context dialog used by original ShownotesWebView (not Material3).
@MainActor final class ShownotesLinkMenuController: UIViewController {
    let menu: ShownotesLinkMenu
    private let perform: (ShownotesLinkMenu.Action) -> Void
    private let panel = UIView(), outer = ShownotesLinkMenuScrollView(), scroll = ShownotesLinkMenuScrollView(), heading = ShownotesLinkTitleLabel()
    private var buttons: [UIButton] = []
    private var titleFallback = false
    private var finished = false

    init(menu: ShownotesLinkMenu, perform: @escaping (ShownotesLinkMenu.Action) -> Void) {
        self.menu = menu; self.perform = perform
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.accessibilityViewIsModal = true
        panel.accessibilityIdentifier = "shownotesLinkMenu"
        panel.backgroundColor = Appearance.color(0xffffff, 0x424242)
        panel.layer.cornerRadius = 2
        panel.layer.shadowColor = UIColor.black.cgColor; panel.layer.shadowOpacity = 0.3
        panel.layer.shadowRadius = 16; panel.layer.shadowOffset = CGSize(width: 0, height: 12)
        view.addSubview(panel); panel.addSubview(outer); outer.addSubview(scroll)
        outer.contentInsetAdjustmentBehavior = .never; scroll.contentInsetAdjustmentBehavior = .never
        scroll.accessibilityIdentifier = "shownotesLinkActions"
        outer.accessibilityIdentifier = "shownotesLinkViewport"
        heading.text = menu.title(); heading.accessibilityLabel = menu.title()
        heading.textColor = Appearance.color(0x212121, 0xffffff)
        heading.accessibilityTraits.insert(.header); heading.accessibilityIdentifier = "shownotesLinkTitle"
        heading.lineBreakMode = .byTruncatingTail
        outer.addSubview(heading)
        buttons = menu.actions.map { action in
            let button = ShownotesLinkActionButton(type: .system)
            button.setTitle(Appearance.text(action.rawValue), for: .normal)
            button.tintColor = Appearance.color(0x212121, 0xffffff)
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.numberOfLines = 1; button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.accessibilityIdentifier = "shownotesLink-" + action.rawValue
            button.addAction(UIAction { [weak self] _ in self?.finish(action) }, for: .touchUpInside)
            scroll.addSubview(button); return button
        }
        let outside = UITapGestureRecognizer(target: self, action: #selector(outside(_:)))
        outside.cancelsTouchesInView = false; view.addGestureRecognizer(outside)
        view.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: UIView, _) in
            self?.view.setNeedsLayout()
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        var safe = view.bounds.inset(by: view.safeAreaInsets)
        safe.size.height = max(0, min(safe.maxY, view.keyboardLayoutGuide.layoutFrame.minY) - safe.minY)
        guard safe.size.width > 32, safe.size.height > 32 else { panel.isHidden = true; return }
        panel.isHidden = false
        // Framework floating window fractions with16dp drawable padding per side.
        let size = view.bounds.size, short = min(size.width, size.height), long = max(size.width, size.height)
        let portrait = size.width < size.height
        let fraction: CGFloat = short >= 720 && long >= 960 ? (portrait ? 0.72 : 0.45)
            : short >= 480 && long >= 640 ? (portrait ? 0.8 : 0.55) : (portrait ? 0.95 : 0.65)
        let preferred: CGFloat = short >= 600 ? 580 : short >= 480 && long >= 640 ? 440 : 320
        let width = min(safe.width - 32, max(min(preferred, safe.width) - 32, floor(safe.width * fraction) - 32))
        let inset = min(24, width / 2), textWidth = max(0, width - inset * 2)
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        heading.textAlignment = rtl ? .right : .left
        heading.font = Appearance.font(20, medium: true, compatibleWith: traitCollection)
        // Framework DialogTitle retains its18sp/two-line fallback once truncated.
        if (menu.title() as NSString).size(withAttributes: [.font: heading.font!]).width > textWidth { titleFallback = true }
        if titleFallback { heading.font = Appearance.font(18, medium: true, compatibleWith: traitCollection) }
        heading.numberOfLines = titleFallback ? 2 : 1
        let scale = max(1, traitCollection.displayScale)
        let titleHeight = ceil(heading.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height * scale) / scale
        heading.frame = CGRect(x: inset, y: 18, width: textWidth, height: titleHeight)
        let bodyTop = heading.frame.maxY + 8
        var y: CGFloat = 0
        for button in buttons {
            button.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            button.titleLabel?.font = Appearance.font(16, compatibleWith: traitCollection)
            let height = max(48, ceil(button.titleLabel?.font.lineHeight ?? 0))
            button.frame = CGRect(x: 0, y: y, width: width, height: height); y += height
        }
        let bodyHeight = y + 8, total = bodyTop + bodyHeight, height = min(safe.height - 32, total)
        let wholeContent = bodyTop >= height - min(48, bodyHeight)
        panel.frame = CGRect(x: safe.midX - width / 2, y: safe.midY - height / 2, width: width, height: height)
        outer.frame = panel.bounds
        outer.contentSize = CGSize(width: width, height: wholeContent ? total : height)
        outer.isScrollEnabled = wholeContent
        scroll.frame = CGRect(x: 0, y: bodyTop, width: width, height: wholeContent ? bodyHeight : height - bodyTop)
        scroll.contentSize = CGSize(width: width, height: bodyHeight); scroll.isScrollEnabled = !wholeContent
        for viewport in [outer, scroll] {
            viewport.contentOffset.y = min(max(0, viewport.contentOffset.y), max(0, viewport.contentSize.height - viewport.bounds.height))
        }
    }
    private func finish(_ action: ShownotesLinkMenu.Action? = nil) {
        guard !finished else { return }; finished = true
        dismiss(animated: true) { [self] in if let action { perform(action) } }
    }
    @objc private func outside(_ gesture: UITapGestureRecognizer) {
        if !panel.frame.contains(gesture.location(in: view)) { finish() }
    }
    override func accessibilityPerformEscape() -> Bool { finish(); return true }
    override var keyCommands: [UIKeyCommand]? {
        finished ? [] : [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close(_:)))]
    }
    @objc private func close(_ command: UIKeyCommand) { finish() }
}

@MainActor private final class ShownotesLinkActionButton: UIButton {
    override func titleRect(forContentRect contentRect: CGRect) -> CGRect {
        super.titleRect(forContentRect: contentRect.insetBy(dx: min(24, contentRect.width / 2), dy: 0))
    }
}

@MainActor private final class ShownotesLinkMenuScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is UIControl { return true }
        return super.touchesShouldCancel(in: view)
    }
}

/// Android TextView includes the font's first/last-line bounds. Match those
/// using the bundled font and local pixel scale, as the chapter labels do.
@MainActor private final class ShownotesLinkTitleLabel: UILabel {
    private var fontInsets: UIEdgeInsets {
        let scale = max(1, traitCollection.displayScale), box = CTFontGetBoundingBox(font as CTFont)
        return UIEdgeInsets(top: max(0, ceil(box.maxY * scale) / scale - font.ascender), left: 0,
            bottom: max(0, ceil(-box.minY * scale) / scale + font.descender), right: 0)
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let measured = super.sizeThatFits(size), insets = fontInsets
        return CGSize(width: measured.width, height: measured.height + insets.top + insets.bottom)
    }
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: fontInsets)) }
}
