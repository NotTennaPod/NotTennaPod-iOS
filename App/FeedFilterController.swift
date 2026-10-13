import UIKit
import NotTennaPodCore

@MainActor
final class FeedFilterController: UIViewController {
    @MainActor private enum Owner {
        case feed(FeedFilterEditor), all(AllEpisodesFilterEditor), subscriptions(SubscriptionsFilterEditor)
        /// Button rows: stored value and label key per button.
        var rows: [[(value: String, label: String)]] {
            if case .subscriptions = self { return SubscriptionsFilter.rows.map { $0.map { ($0.token, $0.titleKey) } } }
            return FeedFilterGroup.allCases.map { group in (0...1).map { (group.values[$0], group.labelKeys[$0]) } }
        }
        var prefix: String { if case .subscriptions = self { "subscriptionsFilter" } else { "feedFilter" } }
        func contains(_ value: String) -> Bool {
            switch self { case .feed(let editor): editor.selection.contains(value); case .all(let editor): editor.selection.contains(value)
            case .subscriptions(let editor): editor.selection.contains(value) }
        }
        func toggle(row: Int, index: Int) {
            switch self {
            case .feed(let editor): editor.toggle(group: FeedFilterGroup.allCases[row], index: index)
            case .all(let editor): editor.toggle(group: FeedFilterGroup.allCases[row], index: index)
            case .subscriptions(let editor): editor.toggle(row: row, index: index)
            }
        }
        func reset() {
            switch self { case .feed(let editor): editor.reset(); case .all(let editor): editor.reset()
            case .subscriptions(let editor): editor.reset() }
        }
        func confirm() { if case .subscriptions(let editor) = self { editor.confirm() } }
        func restoreVisibleOptions() {
            switch self { case .feed(let editor): editor.restoreVisibleOptions(); case .all(let editor): editor.restoreVisibleOptions()
            case .subscriptions: break }
        }
    }
    private let editor: Owner
    private let sheet = UIScrollView()
    private var options: [[FeedFilterOption]] = []
    private let reset = UIButton(type: .custom), confirm = UIButton(type: .custom)
    init(editor: FeedFilterEditor, onSaved: ((LibraryFeed) -> Void)? = nil,
         onFailure: ((any Error) -> Void)? = nil) {
        self.editor = .feed(editor)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve
        editor.onEvent = { [weak self] event in
            switch event {
            case .changed: self?.updateSelection()
            case .saved(let feed): onSaved?(feed)
            case .failed(let error): onFailure?(error)
            }
        }
    }
    init(allEpisodes editor: AllEpisodesFilterEditor, onSaved: (() -> Void)? = nil,
         onFailure: ((any Error) -> Void)? = nil) {
        self.editor = .all(editor)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve
        editor.onEvent = { [weak self] event in
            switch event {
            case .changed: self?.updateSelection()
            case .saved: onSaved?()
            case .failed(let error): onFailure?(error)
            }
        }
    }
    /// SubscriptionsFilterDialog: every toggle applies and saves at once; Confirm re-applies and closes.
    init(subscriptions editor: SubscriptionsFilterEditor) {
        self.editor = .subscriptions(editor)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve
        editor.onSelectionChange = { [weak self] in self?.updateSelection() }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black.withAlphaComponent(0.32); view.accessibilityViewIsModal = true
        sheet.backgroundColor = Appearance.surfaceVariant
        sheet.layer.cornerRadius = 28; sheet.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        sheet.contentInsetAdjustmentBehavior = .never; sheet.accessibilityIdentifier = editor.prefix + "Sheet"
        view.addSubview(sheet)
        options = editor.rows.enumerated().map { row, buttons in
            buttons.enumerated().map { index, entry in
                let button = FeedFilterOption(title: Appearance.text(entry.label))
                button.accessibilityIdentifier = editor.prefix + "_" + entry.value
                button.addAction(UIAction { [weak self] _ in self?.editor.toggle(row: row, index: index) }, for: .touchUpInside)
                sheet.addSubview(button); return button
            }
        }
        for (button, key) in [(reset, "reset"), (confirm, "confirm_label")] {
            button.setTitle(Appearance.text(key), for: .normal); button.setTitleColor(Appearance.accent, for: .normal)
            button.titleLabel?.font = Appearance.font(14, medium: true); sheet.addSubview(button)
        }
        reset.accessibilityIdentifier = editor.prefix + "Reset"; confirm.accessibilityIdentifier = editor.prefix + "Confirm"
        reset.addAction(UIAction { [weak self] _ in self?.editor.reset() }, for: .touchUpInside)
        confirm.addAction(UIAction { [weak self] _ in self?.editor.confirm(); self?.dismiss(animated: true) }, for: .touchUpInside)
        let outside = UITapGestureRecognizer(target: self, action: #selector(outside(_:)))
        outside.cancelsTouchesInView = false; view.addGestureRecognizer(outside)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: FeedFilterController, _) in
            controller.options.flatMap { $0 }.forEach { $0.updateFont() }
            controller.view.setNeedsLayout()
        }
        updateSelection()
        editor.restoreVisibleOptions()
    }
    private func updateSelection() {
        for (row, buttons) in zip(editor.rows, options) {
            for (entry, button) in zip(row, buttons) { button.isSelected = editor.contains(entry.value) }
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets, width = min(640, max(0, view.bounds.width - safe.left - safe.right))
        let inner = max(0, width - 48), scale = max(1, traitCollection.displayScale)
        let leftWidth = floor((inner + 1) / 2 * scale) / scale
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        var y: CGFloat = 24
        for buttons in options {
            // A single button fills the row (SubscriptionsFilterGroup COUNTER_GREATER_ZERO, weightSum 1).
            let widths = buttons.count == 1 ? [inner] : [leftWidth, inner + 1 - leftWidth]
            let height = zip(buttons, widths).map { $0.sizeThatFits(CGSize(width: $1, height: .greatestFiniteMagnitude)).height }.max() ?? 0
            for (index, button) in buttons.enumerated() {
                let rect = CGRect(x: index == 0 ? 24 : 24 + leftWidth - 1, y: y, width: widths[index], height: height)
                button.frame = rtl ? CGRect(x: width - rect.maxX, y: y, width: rect.width, height: height) : rect
                button.rounding = buttons.count == 1 ? .both : ((index == 0) != rtl ? .left : .right)
                button.setNeedsLayout()
            }
            y += height
        }
        for (index, button) in [reset, confirm].enumerated() {
            let x = 24 + CGFloat(rtl ? 1 - index : index) * inner / 2
            button.frame = CGRect(x: x, y: y, width: inner / 2, height: 48)
        }
        y += 48 + 8 + safe.bottom
        let height = min(max(0, view.bounds.height - safe.top), y)
        sheet.frame = CGRect(x: safe.left + (view.bounds.width - safe.left - safe.right - width) / 2,
                             y: view.bounds.height - height, width: width, height: height)
        sheet.contentSize = CGSize(width: width, height: y)
    }
    @objc private func outside(_ recognizer: UITapGestureRecognizer) {
        if !sheet.frame.contains(recognizer.location(in: view)) { dismiss(animated: true) }
    }
    override func accessibilityPerformEscape() -> Bool { dismiss(animated: true); return true }
}

@MainActor
private final class FeedFilterOption: UIControl {
    private let shape = CAShapeLayer()
    private let label: UILabel
    enum Rounding { case left, right, both }
    var rounding = Rounding.left
    init(title: String) {
        label = Appearance.label(title, size: 14)
        super.init(frame: .zero)
        label.numberOfLines = 3; label.textAlignment = .center
        layer.addSublayer(shape); addSubview(label); updateFont()
        isAccessibilityElement = true; accessibilityLabel = title; accessibilityTraits = .button
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (button: FeedFilterOption, _) in button.setNeedsLayout() }
    }
    required init?(coder: NSCoder) { fatalError() }
    func updateFont() { label.font = Appearance.font(14, medium: true); setNeedsLayout() }
    override var isSelected: Bool {
        didSet { accessibilityTraits = isSelected ? [.button, .selected] : .button; setNeedsLayout() }
    }
    override var isHighlighted: Bool { didSet { setNeedsLayout() } }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let text = label.sizeThatFits(CGSize(width: max(0, size.width - 48), height: .greatestFiniteMagnitude))
        return CGSize(width: size.width, height: max(48, ceil(text.height) + 20))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let outline = bounds.insetBy(dx: 0.5, dy: 4.5)
        let corners: UIRectCorner = switch rounding {
        case .left: [.topLeft, .bottomLeft]
        case .right: [.topRight, .bottomRight]
        case .both: .allCorners
        }
        shape.path = UIBezierPath(roundedRect: outline, byRoundingCorners: corners,
                                  cornerRadii: CGSize(width: outline.height / 2, height: outline.height / 2)).cgPath
        shape.lineWidth = 1; shape.strokeColor = Appearance.secondary.resolvedColor(with: traitCollection).cgColor
        shape.fillColor = Appearance.accent.withAlphaComponent(isSelected ? 0.3 : (isHighlighted ? 0.08 : 0)).resolvedColor(with: traitCollection).cgColor
        label.frame = bounds.insetBy(dx: 24, dy: 10)
    }
}

/// SubscriptionsFilterDialog state: single selection per row (a checked button unchecks on tap); each
/// change saves the `HashSet`-ordered token string immediately.
@MainActor final class SubscriptionsFilterEditor {
    private(set) var selection: Set<String>
    var onSelectionChange: (() -> Void)?
    private let save: (String) -> Void
    init(stored: String, save: @escaping (String) -> Void) {
        selection = Set(SubscriptionsFilter(stored: stored).tokens); self.save = save
    }
    func toggle(row: Int, index: Int) {
        let buttons = SubscriptionsFilter.rows[row].map(\.token), token = buttons[index]
        if selection.contains(token) { selection.remove(token) }
        else { buttons.forEach { selection.remove($0) }; selection.insert(token) }
        apply()
    }
    func reset() { selection = []; apply() }
    func confirm() { apply() }
    /// The dialog saves only its checked buttons, so unknown stored tokens are dropped on any change.
    private func apply() {
        let known = Set(SubscriptionsFilter.rows.flatMap { $0.map(\.token) })
        selection.formIntersection(known)
        onSelectionChange?(); save(SubscriptionsFilter.serialized(selection))
    }
}
