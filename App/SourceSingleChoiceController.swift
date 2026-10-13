import UIKit
import NotTennaPodCore

/// Shared MaterialListPreference layout; each choice commits immediately.
@MainActor class SourceSingleChoiceController: UIViewController {
    private let choices: [(id: String, title: String)]
    private let selectedIndex: Int?
    private var selectedIndices: Set<Int>?
    private let onConfirm: ((Set<Int>) throws -> Void)?
    private let confirmTitle: String
    private let identifier: String
    private let onSelect: (Int) throws -> Void
    private let shadow = SourceSingleChoiceShadow()
    private let panel = DefaultPageScrollView()
    private let heading: SourceDialogTitle
    private let list = DefaultPageScrollView()
    private let cancel = UIButton(type: .custom)
    private let confirm = UIButton(type: .custom)
    private lazy var actions = selectedIndices == nil ? NavigationDialogActions(positive: cancel)
        : NavigationDialogActions(positive: confirm, negative: cancel)
    private var rows: [DefaultPageRow] = []
    @MainActor private struct ReadingAnchor {
        let row: DefaultPageRow
        let hidden: CGFloat
        let height: CGFloat
        var position: CGFloat {
            let within = hidden < row.bounds.height ? hidden : hidden / height * row.bounds.height
            return row.frame.minY + within
        }
        var updated: Self { Self(row: row, hidden: position - row.frame.minY, height: row.bounds.height) }
    }
    private var ordinaryAnchor: ReadingAnchor?
    private func readingAnchor(at offset: CGFloat) -> ReadingAnchor? {
        guard offset > 0, let row = rows.first(where: { $0.frame.maxY > offset }), row.bounds.height > 0 else { return nil }
        return ReadingAnchor(row: row, hidden: offset - row.frame.minY, height: row.bounds.height)
    }
    init(title: String, identifier: String, choices: [(id: String, title: String)], selectedIndex: Int?,
         selectedIndices: Set<Int>? = nil, onConfirm: ((Set<Int>) throws -> Void)? = nil, confirmTitle: String = Appearance.text("ok"),
         onSelect: @escaping (Int) throws -> Void) {
        heading = SourceDialogTitle(title)
        self.identifier = identifier; self.choices = choices; self.selectedIndex = selectedIndex; self.onSelect = onSelect
        self.selectedIndices = selectedIndices; self.onConfirm = onConfirm; self.confirmTitle = confirmTitle
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.32)
        view.accessibilityViewIsModal = true
        for target in [view!, heading, list] {
            target.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: UIView, _) in
                self?.view.setNeedsLayout()
            }
        }
        panel.backgroundColor = Appearance.surfaceVariant
        panel.layer.cornerRadius = 28; panel.clipsToBounds = true
        // The physical panel is already inset into this controller's safe area.
        panel.contentInsetAdjustmentBehavior = .never
        panel.isScrollEnabled = false
        panel.cancellableAction = cancel
        panel.accessibilityIdentifier = identifier + "Content"
        view.addSubview(shadow); view.addSubview(panel); [heading, list, actions].forEach(panel.addSubview)
        actions.accessibilityIdentifier = identifier + "Actions"
        actions.onMetricsChange = { [weak self] in self?.view.setNeedsLayout() }
        heading.accessibilityIdentifier = identifier + "Title"
        list.contentInsetAdjustmentBehavior = .never
        list.accessibilityIdentifier = identifier + "Choices"
        for (index, choice) in choices.enumerated() {
            let row = DefaultPageRow(title: choice.title, selected: selectedIndices?.contains(index) ?? (selectedIndex == index), multiple: selectedIndices != nil)
            row.accessibilityIdentifier = identifier + "-" + choice.id
            row.onMetricsChange = { [weak self] in self?.view.setNeedsLayout() }
            row.addAction(UIAction { [weak self] _ in self?.choose(index) }, for: .touchUpInside)
            list.addSubview(row); rows.append(row)
        }
        cancel.setTitle(Appearance.text("cancel_label"), for: .normal)
        cancel.setTitleColor(Appearance.accent, for: .normal)
        cancel.titleLabel?.font = Appearance.font(14, medium: true)
        cancel.accessibilityIdentifier = identifier + "Cancel"
        cancel.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        if selectedIndices != nil {
            confirm.setTitle(confirmTitle, for: .normal); confirm.setTitleColor(Appearance.accent, for: .normal)
            confirm.titleLabel?.font = Appearance.font(14, medium: true)
            confirm.accessibilityIdentifier = identifier + "Confirm"
            confirm.addAction(UIAction { [weak self] _ in
                guard let self, let selectedIndices else { return }
                do { try onConfirm?(selectedIndices); dismiss(animated: true) }
                catch { showFailure(error) }
            }, for: .touchUpInside)
        }
        let outside = UITapGestureRecognizer(target: self, action: #selector(outsideTap(_:)))
        outside.cancelsTouchesInView = false; view.addGestureRecognizer(outside)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        // CGRect.height standardizes negative extents. Inspect the raw size so
        // collapsed bounds cannot become a positive viewport behind safe insets.
        guard safe.size.width > 0, safe.size.height > 48 else { panel.isHidden = true; shadow.isHidden = true; return }
        let preferred = SourceDialogLayout.preferredContentWidth(in: safe, configurationSize: view.bounds.size)
        let width = SourceDialogLayout.width(in: safe, configurationSize: view.bounds.size,
                                             desiredContentWidth: preferred)
        heading.semanticContentAttribute = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            ? .forceRightToLeft : .forceLeftToRight
        guard width > 0, safe.size.height > 48 else { panel.isHidden = true; shadow.isHidden = true; return }
        panel.isHidden = false; shadow.isHidden = false
        let previousFrame = list.frame, previousSize = list.contentSize
        let wasOverflow = panel.isScrollEnabled
        let previousPanelFrame = panel.frame, previousPanelSize = panel.contentSize, previousPanelOffset = panel.contentOffset
        let active = wasOverflow ? panel : list
        let idle = !active.isTracking && !active.isDragging && !active.isDecelerating
        let readingBody = wasOverflow && panel.contentOffset.y >= list.frame.minY
            && panel.contentOffset.y < list.frame.maxY
        let readingActions = wasOverflow && panel.contentOffset.y >= actions.frame.minY
        let actionOffset = panel.contentOffset.y - actions.frame.minY
        let anchor = wasOverflow ? (readingBody ? readingAnchor(at: panel.contentOffset.y - list.frame.minY) : ordinaryAnchor)
            : readingAnchor(at: list.contentOffset.y)
        let oldAnchorFrame = anchor?.row.frame
        list.semanticContentAttribute = heading.semanticContentAttribute
        panel.semanticContentAttribute = heading.semanticContentAttribute
        // DialogTitle retains fallback from the first preferred-width measure,
        // even if the subsequent minimum-width pass gives the panel more room.
        _ = heading.measuredSize(width: max(0, preferred - 48))
        let titleTextHeight = heading.measuredSize(width: max(0, width - 48)).height
        let rowHeights = rows.map { $0.measuredHeight(width: width) }
        let actionLayout = actions.measuredLayout(width: width, rightToLeft: view.effectiveUserInterfaceLayoutDirection == .rightToLeft)
        let viewport = SourceMessageViewportLayout.singleChoice(available: safe, titleTextHeight: titleTextHeight,
            rowHeights: rowHeights, footerHeight: actionLayout.height, minimumFooterHeight: actionLayout.minimumHeight,
            minimumBodyHeight: rows.map(\.minimumReadingHeight).max() ?? 0,
            minimumActionHeight: actionLayout.positive.height, panelWidth: width)
        let layout = viewport.content, overflow = viewport.scrollsWholeContent
        if overflow && !wasOverflow { ordinaryAnchor = anchor }
        panel.frame = viewport.panel
        shadow.frame = viewport.panel
        shadow.setNeedsLayout(); shadow.layoutIfNeeded()
        panel.contentSize = CGSize(width: width, height: layout.panel.height)
        panel.isScrollEnabled = overflow
        heading.frame = CGRect(x: 24, y: 18, width: max(0, width - 48), height: max(0, layout.title.height - 34))
        list.frame = layout.body
        var rowY: CGFloat = 0
        for (row, height) in zip(rows, rowHeights) {
            row.semanticContentAttribute = list.semanticContentAttribute
            row.frame = CGRect(x: 0, y: rowY, width: width, height: height)
            rowY += height
        }
        list.contentSize = CGSize(width: width, height: rowY)
        list.isScrollEnabled = !overflow
        actions.apply(actionLayout, frame: layout.footer)
        if overflow { actions.isScrollEnabled = false }
        let changed = wasOverflow != overflow || previousFrame != list.frame || previousSize != list.contentSize
            || anchor?.row.frame != oldAnchorFrame || previousPanelFrame != panel.frame || previousPanelSize != panel.contentSize
        if changed, idle || wasOverflow != overflow {
            let target = anchor?.position ?? 0
            let listOffset = CGPoint(x: 0, y: overflow ? 0 : min(max(0, target), max(0, rowY - list.bounds.height)))
            if list.contentOffset != listOffset { list.setContentOffset(listOffset, animated: false) }
            var outerY: CGFloat = 0
            if overflow {
                if readingBody || (!wasOverflow && target > 0) { outerY = list.frame.minY + target }
                else if readingActions { outerY = actions.frame.minY + actionOffset }
                else { outerY = previousPanelOffset.y }
            }
            let outerOffset = CGPoint(x: 0, y: min(max(0, outerY), max(0, panel.contentSize.height - panel.bounds.height)))
            if panel.contentOffset != outerOffset { panel.setContentOffset(outerOffset, animated: false) }
        }
        ordinaryAnchor = overflow ? ordinaryAnchor?.updated : nil
    }
    private func choose(_ index: Int) {
        guard choices.indices.contains(index) else { return }
        if var draft = selectedIndices {
            if draft.contains(index) { draft.remove(index) } else { draft.insert(index) }
            selectedIndices = draft; rows[index].setSelected(draft.contains(index)); return
        }
        do { try onSelect(index); dismiss(animated: true) }
        catch { showFailure(error) }
    }
    private func showFailure(_ error: any Error) {
            let alert = UIAlertController(title: Appearance.text("error_label"), message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: Appearance.text("confirm_label"), style: .default))
            present(alert, animated: true)
    }
    @objc private func outsideTap(_ gesture: UITapGestureRecognizer) {
        if !panel.frame.contains(gesture.location(in: view)) { dismiss(animated: true) }
    }
    override func accessibilityPerformEscape() -> Bool { dismiss(animated: true); return true }
}

/// A choice remains tappable, but a drag after touch delivery belongs to the
/// active scroll viewport. UIScrollView otherwise retains UIControl tracking.
@MainActor private final class DefaultPageScrollView: UIScrollView {
    weak var cancellableAction: UIControl?
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is DefaultPageRow || view === cancellableAction { return true }
        return super.touchesShouldCancel(in: view)
    }
}

@MainActor private final class DefaultPageRow: UIControl {
    private let label: UILabel
    private let radio: SourceRadioIndicator
    var onMetricsChange: (() -> Void)?
    init(title: String, selected: Bool, multiple: Bool = false) {
        label = Appearance.label(title, size: 16)
        label.textColor = Appearance.secondary
        label.adjustsFontForContentSizeCategory = false
        label.lineBreakMode = .byWordWrapping
        radio = SourceRadioIndicator(); radio.checked = selected; radio.multiple = multiple
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = selected ? [.button, .selected] : .button
        label.isUserInteractionEnabled = false; radio.isUserInteractionEnabled = false
        addSubview(label); addSubview(radio)
        label.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: UILabel, _) in
            self?.onMetricsChange?()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    func setSelected(_ selected: Bool) {
        radio.checked = selected; radio.setNeedsDisplay()
        accessibilityTraits = selected ? [.button, .selected] : .button
    }
    func measuredHeight(width: CGFloat) -> CGFloat {
        label.font = Appearance.font(16, compatibleWith: label.traitCollection)
        let measured = label.sizeThatFits(CGSize(width: max(0, width - 96), height: .greatestFiniteMagnitude))
        return max(48, ceil(measured.height))
    }
    var minimumReadingHeight: CGFloat { ceil(label.font.lineHeight) }
    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        // abc_select_dialog_padding_start_material = 20dp; drawable gap = 20dp.
        radio.frame = CGRect(x: rtl ? bounds.width - 52 : 20, y: (bounds.height - 32) / 2, width: 32, height: 32)
        label.frame = CGRect(x: rtl ? 24 : 72, y: 0, width: max(0, bounds.width - 96), height: bounds.height)
        label.textAlignment = rtl ? .right : .left
    }
}

@MainActor private final class SourceRadioIndicator: UIView {
    var checked = false
    var multiple = false
    override init(frame: CGRect) { super.init(frame: frame); isOpaque = false; backgroundColor = .clear }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ rect: CGRect) {
        let color = checked ? Appearance.accent : Appearance.secondary
        color.setStroke(); color.setFill()
        if multiple {
            let box = CGRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16)
            if checked {
                UIBezierPath(roundedRect: box.insetBy(dx: -1, dy: -1), cornerRadius: 2).fill()
                Appearance.color(0xffffff, 0x000000).setStroke()
                let mark = UIBezierPath(); mark.move(to: CGPoint(x: box.minX + 2, y: box.midY))
                mark.addLine(to: CGPoint(x: box.minX + 6, y: box.midY + 4)); mark.addLine(to: CGPoint(x: box.minX + 14, y: box.midY - 4))
                mark.lineWidth = 2; mark.stroke()
            } else { let outline = UIBezierPath(roundedRect: box, cornerRadius: 1); outline.lineWidth = 2; outline.stroke() }
            return
        }
        let ring = UIBezierPath(ovalIn: CGRect(x: bounds.midX - 9, y: bounds.midY - 9, width: 18, height: 18))
        ring.lineWidth = 2; ring.stroke()
        if checked { UIBezierPath(ovalIn: CGRect(x: bounds.midX - 5, y: bounds.midY - 5, width: 10, height: 10)).fill() }
    }
}

/// Keep elevation outside the scrolling panel, whose content must remain clipped.
/// The source Material3 dialog uses elevation level3 (6dp), with ambient/key shadows.
@MainActor final class SourceSingleChoiceShadow: UIView {
    private let ambient = CALayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22; layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 6)
        ambient.shadowColor = UIColor.black.cgColor
        ambient.shadowOpacity = 0.06; ambient.shadowRadius = 3
        ambient.shadowOffset = .zero
        layer.addSublayer(ambient)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ambient.frame = bounds
        let path = bounds.width > 0 && bounds.height > 0 ? UIBezierPath(roundedRect: bounds, cornerRadius: 28).cgPath : nil
        layer.shadowPath = path; ambient.shadowPath = path
        CATransaction.commit()
    }
}
