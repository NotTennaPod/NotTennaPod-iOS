import UIKit
import NotTennaPodCore

/// The source's touch-anchored context popup, including its accent title row.
@MainActor final class PopupMenuController: UIViewController {
    private let heading = UILabel()
    private let panel = UIView(), scroll = UIScrollView()
    private let actions: [(id: String, title: String)]
    private let panelColor: UIColor?
    private let matchesAnchorWidth: Bool
    private let toolbarTrailing: Bool
    private let menuIdentifier: String
    private let perform: (String) -> Void
    private weak var anchor: UIView?
    private let anchorFraction: CGPoint
    private var buttons: [UIButton] = []
    convenience init(feed: LibraryFeed, anchor: UIView? = nil, anchorFraction: CGPoint = CGPoint(x: 0.5, y: 0.5),
         perform: @escaping (SearchFeedMenu.Action) -> Void) {
        self.init(title: feed.title ?? "", identifier: "searchFeedContextMenu", anchor: anchor, anchorFraction: anchorFraction,
            actions: SearchFeedMenu.actions(for: feed).map { ("searchFeedAction-" + $0.rawValue, Appearance.text($0.titleKey)) }) { id in
                if let action = SearchFeedMenu.Action(rawValue: String(id.dropFirst("searchFeedAction-".count))) { perform(action) }
            }
    }
    init(title: String, identifier: String, anchor: UIView?, anchorFraction: CGPoint = CGPoint(x: 0.5, y: 0.5),
         actions: [(id: String, title: String)], matchesAnchorWidth: Bool = false, toolbarTrailing: Bool = false, panelColor: UIColor? = nil, perform: @escaping (String) -> Void) {
        heading.text = title; self.anchor = anchor; self.anchorFraction = anchorFraction
        self.panelColor = panelColor; self.matchesAnchorWidth = matchesAnchorWidth; self.toolbarTrailing = toolbarTrailing
        self.actions = actions; self.perform = perform; menuIdentifier = identifier
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear; view.accessibilityViewIsModal = true
        panel.accessibilityIdentifier = menuIdentifier
        panel.backgroundColor = panelColor ?? Appearance.navigation; panel.layer.cornerRadius = 4
        panel.layer.shadowColor = UIColor.black.cgColor; panel.layer.shadowOpacity = 0.2
        panel.layer.shadowRadius = 3; panel.layer.shadowOffset = CGSize(width: 0, height: 2)
        view.addSubview(panel); panel.addSubview(scroll); scroll.addSubview(heading)
        scroll.contentInsetAdjustmentBehavior = .never
        heading.textColor = Appearance.accent; heading.numberOfLines = 1
        heading.lineBreakMode = .byTruncatingTail; heading.accessibilityTraits.insert(.header)
        buttons = actions.map { action in
            let button = UIButton(type: .system)
            button.setTitle(action.title, for: .normal)
            button.tintColor = Appearance.foreground
            button.contentHorizontalAlignment = .leading; button.titleLabel?.numberOfLines = 1
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.accessibilityIdentifier = action.id
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                dismiss(animated: true) { self.perform(action.id) }
            }, for: .touchUpInside)
            scroll.addSubview(button); return button
        }
        let gesture = UITapGestureRecognizer(target: self, action: #selector(outside(_:)))
        gesture.cancelsTouchesInView = false; view.addGestureRecognizer(gesture)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        var safe = view.safeAreaLayoutGuide.layoutFrame
        let keyboardTop = view.keyboardLayoutGuide.layoutFrame.minY
        safe.size.height = max(0, min(safe.maxY, keyboardTop) - safe.minY)
        panel.isHidden = safe.width <= 0 || safe.height <= 0
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let direction: UISemanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        scroll.semanticContentAttribute = direction; heading.semanticContentAttribute = direction
        heading.textAlignment = rtl ? .right : .left
        heading.font = Appearance.font(14, medium: true, compatibleWith: traitCollection)
        for button in buttons {
            button.semanticContentAttribute = direction
            button.titleLabel?.font = Appearance.font(16, compatibleWith: traitCollection)
        }
        let widths = buttons.map { $0.titleLabel?.intrinsicContentSize.width ?? 0 } + [heading.intrinsicContentSize.width]
        let width = min(max(0, safe.width), matchesAnchorWidth ? (anchor?.bounds.width ?? 196) : min(max(safe.width / 2, 320), max(196, (widths.max() ?? 0) + 32)))
        let inset = min(16, width / 2), textWidth = max(0, width - inset * 2)
        let rowHeight = max(48, (buttons.first?.titleLabel?.font.lineHeight ?? 0) + 16)
        let titleRows = heading.text?.isEmpty == false ? 1 : 0
        heading.isHidden = titleRows == 0
        heading.frame = CGRect(x: inset, y: 8, width: textWidth, height: rowHeight)
        for (i, button) in buttons.enumerated() {
            button.frame = CGRect(x: inset, y: 8 + CGFloat(i + titleRows) * rowHeight, width: textWidth, height: rowHeight)
        }
        let total = 16 + CGFloat(buttons.count + titleRows) * rowHeight, height = min(safe.height, total)
        let point = anchor.map { $0.convert(CGPoint(x: $0.bounds.width * anchorFraction.x, y: $0.bounds.height * anchorFraction.y), to: view) }
            ?? CGPoint(x: safe.midX, y: safe.midY)
        let preferredX = toolbarTrailing ? (rtl ? safe.minX + 4 : safe.maxX - width - 4) : (rtl ? point.x - width : point.x)
        let preferredY = point.y + height <= safe.maxY ? point.y : point.y - height
        panel.frame = CGRect(x: max(safe.minX, min(preferredX, safe.maxX - width)),
            y: max(safe.minY, min(preferredY, safe.maxY - height)), width: width, height: height)
        scroll.frame = panel.bounds; scroll.contentSize = CGSize(width: width, height: total)
    }
    @objc private func outside(_ gesture: UITapGestureRecognizer) {
        if !panel.frame.contains(gesture.location(in: view)) { dismiss(animated: true) }
    }
    override func accessibilityPerformEscape() -> Bool { dismiss(animated: true); return true }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close))]
    }
    @objc private func close() { dismiss(animated: true) }
}
