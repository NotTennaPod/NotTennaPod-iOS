import UIKit
import NotTennaPodCore

/// `ItemSortDialog`'s two-column bottom sheet: no title or buttons, every tap saved immediately, the active
/// row marked ▲/▼. Subclasses supply the rows and what a tap does.
@MainActor class SortSheetController: UIViewController {
    private let panel = UIView(), scroll = UIScrollView()
    fileprivate var buttons: [String: SortButton] = [:]
    /// Row identifiers in grid order.
    var rowIDs: [String] { [] }
    var sheetIdentifier: String { "sortSheet" }
    func buttonIdentifier(_ row: String) -> String { "sort-\(row)" }
    func title(_ row: String) -> String { row }
    /// Whether the row is active, its direction arrow (if any) and whether it can be tapped.
    func state(_ row: String) -> (active: Bool, ascending: Bool?, enabled: Bool) { (false, nil, true) }
    func tap(_ row: String) {}
    /// A full-width control under the grid (the Queue sheet's "Keep sorted" checkbox).
    func makeFooter() -> UIView? { nil }
    private var footer: UIView?

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.32)
        view.accessibilityViewIsModal = true
        panel.accessibilityIdentifier = sheetIdentifier
        panel.backgroundColor = Appearance.surfaceVariant
        panel.layer.cornerRadius = 28; panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        panel.clipsToBounds = true
        view.addSubview(panel); panel.addSubview(scroll)
        // The sheet explicitly includes the current bottom inset once.
        scroll.contentInsetAdjustmentBehavior = .never
        for row in rowIDs {
            let button = SortButton()
            button.accessibilityIdentifier = buttonIdentifier(row)
            button.addAction(UIAction { [weak self] _ in self?.tap(row) }, for: .touchUpInside)
            buttons[row] = button; scroll.addSubview(button)
        }
        footer = makeFooter()
        if let footer { scroll.addSubview(footer) }
        updateButtons()
        let outside = UITapGestureRecognizer(target: self, action: #selector(outsideTap(_:)))
        outside.cancelsTouchesInView = false; view.addGestureRecognizer(outside)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self]) { (controller: SortSheetController, _) in
            controller.updateButtons()
        }
    }
    func updateButtons() {
        for (row, button) in buttons {
            let state = state(row)
            let suffix = state.ascending.map { $0 ? "\u{a0}▲" : "\u{a0}▼" } ?? ""
            button.setTitle(title(row) + suffix, for: .normal)
            button.active = state.active
            button.isEnabled = state.enabled
            button.accessibilityTraits = state.active ? [.button, .selected] : .button
            if !button.isEnabled { button.accessibilityTraits.insert(.notEnabled) }
            button.refresh()
        }
        view.setNeedsLayout()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets
        let available = max(0, view.bounds.width - safe.left - safe.right)
        let width = min(640, available), buttonWidth = max(0, (width - 48) / 2)
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let rows = rowIDs
        var y: CGFloat = 20
        for start in stride(from: 0, to: rows.count, by: 2) {
            let pair = rows[start..<min(start + 2, rows.count)]
            let height = pair.compactMap { buttons[$0]?.sizeThatFits(CGSize(width: buttonWidth, height: .greatestFiniteMagnitude)).height }.max() ?? 48
            for (column, row) in pair.enumerated() {
                let index = rtl ? 1 - column : column
                let ownHeight = buttons[row]?.sizeThatFits(CGSize(width: buttonWidth, height: .greatestFiniteMagnitude)).height ?? 48
                buttons[row]?.frame = CGRect(x: 20 + CGFloat(index) * (buttonWidth + 8), y: y + (height - ownHeight) / 2,
                                             width: buttonWidth, height: ownHeight)
            }
            y += height + 8
        }
        if let footer {
            let height = footer.sizeThatFits(CGSize(width: width - 40, height: .greatestFiniteMagnitude)).height
            footer.frame = CGRect(x: 20, y: y, width: max(0, width - 40), height: height)
            y += height + 8
        }
        let total = y - 8 + 20 + safe.bottom
        let height = min(total, max(0, view.bounds.height - safe.top))
        panel.frame = CGRect(x: safe.left + (available - width) / 2, y: view.bounds.height - height, width: width, height: height)
        scroll.frame = panel.bounds
        scroll.contentSize = CGSize(width: width, height: total)
        scroll.contentOffset.y = min(scroll.contentOffset.y, max(0, total - height))
    }
    @objc private func outsideTap(_ gesture: UITapGestureRecognizer) {
        if !panel.frame.contains(gesture.location(in: view)) { dismiss(animated: true) }
    }
    override func accessibilityPerformEscape() -> Bool { dismiss(animated: true); return true }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close))]
    }
    @objc private func close() { dismiss(animated: true) }
}

/// SingleFeedSortDialog.
@MainActor final class FeedSortController: SortSheetController {
    let editor: FeedSortEditor
    init(editor: FeedSortEditor) {
        self.editor = editor
        super.init()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        editor.onChange = { [weak self] in self?.updateButtons() }
    }
    override var rowIDs: [String] { editor.fields.map(\.rawValue) }
    override var sheetIdentifier: String { "feedSortSheet" }
    override func buttonIdentifier(_ row: String) -> String { "feedSort-\(row)" }
    override func title(_ row: String) -> String { FeedEpisodeSortOrder.Field(rawValue: row).map { Appearance.text($0.titleKey) } ?? row }
    override func state(_ row: String) -> (active: Bool, ascending: Bool?, enabled: Bool) {
        let active = editor.selection.field.rawValue == row, global = row == FeedEpisodeSortOrder.Field.global.rawValue
        return (active, active && !global ? editor.selection.ascending : nil, !(active && global))
    }
    override func tap(_ row: String) {
        if let field = FeedEpisodeSortOrder.Field(rawValue: row) { editor.select(field) }
    }
}

/// `InboxSortDialog` / `AllEpisodesSortDialog`: Duration and Date only.
@MainActor final class EpisodeListSortController: SortSheetController {
    private let current: () -> EpisodeListSort
    private let save: (EpisodeListSort) -> Void
    init(current: @escaping () -> EpisodeListSort, save: @escaping (EpisodeListSort) -> Void) {
        self.current = current; self.save = save
        super.init()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var rowIDs: [String] { EpisodeListSort.Row.allCases.map(\.rawValue) }
    override var sheetIdentifier: String { "episodeListSortSheet" }
    override func buttonIdentifier(_ row: String) -> String { "episodeListSort-\(row)" }
    override func title(_ row: String) -> String { EpisodeListSort.Row(rawValue: row).map { Appearance.text($0.titleKey) } ?? row }
    override func state(_ row: String) -> (active: Bool, ascending: Bool?, enabled: Bool) {
        let sort = current(), active = sort.row.rawValue == row
        return (active, active ? sort.ascending : nil, true)
    }
    override func tap(_ row: String) {
        guard let row = EpisodeListSort.Row(rawValue: row) else { return }
        save(current().selecting(row)); updateButtons()
    }
}

@MainActor private final class SortButton: UIButton {
    var active = false
    private let surface = UIView()
    override init(frame: CGRect) {
        super.init(frame: frame)
        surface.isUserInteractionEnabled = false; insertSubview(surface, at: 0)
        titleLabel?.numberOfLines = 0; titleLabel?.textAlignment = .center
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    func refresh() {
        titleLabel?.font = Appearance.font(14, medium: true, compatibleWith: traitCollection)
        setTitleColor(active ? Appearance.foreground : Appearance.accent, for: .normal)
        setTitleColor(Appearance.foreground, for: .disabled)
        surface.backgroundColor = active ? Appearance.selected : .clear
        surface.layer.borderColor = Appearance.secondary.resolvedColor(with: traitCollection).cgColor
        surface.layer.borderWidth = active ? 0 : 1
        setNeedsLayout()
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let height = titleLabel?.sizeThatFits(CGSize(width: max(0, size.width - 48), height: .greatestFiniteMagnitude)).height ?? 20
        return CGSize(width: size.width, height: max(48, ceil(height) + 20))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        surface.frame = bounds.insetBy(dx: 0, dy: 4); surface.layer.cornerRadius = surface.bounds.height / 2
        titleLabel?.frame = bounds.insetBy(dx: min(24, bounds.width / 2), dy: 10)
        sendSubviewToBack(surface)
    }
}

/// `QueueFragment.QueueSortDialog`: six rows and the "Keep sorted" checkbox. Each change is saved and
/// re-sorts the queue at once through `onChange`; the sheet stays open.
@MainActor final class QueueSortController: SortSheetController {
    private(set) var sheetState: QueueSortSheetState
    var onChange: ((QueueSortSheetState) -> Void)?
    let keepSorted = SpeedCheckbox(titleKey: "keep_sorted")
    init(state: QueueSortSheetState) {
        self.sheetState = state
        super.init()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var rowIDs: [String] { QueueSortRow.allCases.map(\.rawValue) }
    override var sheetIdentifier: String { "queueSortSheet" }
    override func buttonIdentifier(_ row: String) -> String { "queueSort-\(row)" }
    override func title(_ row: String) -> String { QueueSortRow(rawValue: row).map { Appearance.text($0.titleKey) } ?? row }
    override func state(_ row: String) -> (active: Bool, ascending: Bool?, enabled: Bool) {
        guard let row = QueueSortRow(rawValue: row) else { return (false, nil, true) }
        return (row.isActive(sheetState.order), row.arrowAscending(sheetState.order), true)
    }
    override func makeFooter() -> UIView? {
        keepSorted.accessibilityIdentifier = "queueKeepSorted"
        keepSorted.addAction(UIAction { [weak self] _ in
            guard let self, keepSorted.isEnabled else { return }
            self.sheetState.setKeepSorted(!sheetState.keepSorted); changed()
        }, for: .touchUpInside)
        return keepSorted
    }
    override func tap(_ row: String) {
        guard let row = QueueSortRow(rawValue: row) else { return }
        sheetState.tap(row); changed()
    }
    override func updateButtons() {
        keepSorted.checked = sheetState.keepSorted
        keepSorted.isEnabled = sheetState.keepSortedEnabled
        keepSorted.accessibilityTraits = sheetState.keepSortedEnabled ? .button : [.button, .notEnabled]
        super.updateButtons()
    }
    private func changed() {
        updateButtons()
        onChange?(sheetState)
    }
}
