import UIKit
import NotTennaPodCore

/// Source-composed modal; UICollectionView owns dragging and edge auto-scrolling.
@MainActor final class NavigationCustomizationController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private let preferences: NavigationPreferenceStore
    private var editor: NavigationCustomization
    private let panel = UIView()
    private let heading = SourceDialogTitle(Appearance.text("drawer_preferences"))
    private let collection: CustomizationCollectionView
    private let flow: UICollectionViewFlowLayout
    private let reset = UIButton(type: .custom)
    private let cancel = UIButton(type: .custom)
    private let confirm = UIButton(type: .custom)
    private lazy var actions = NavigationDialogActions(positive: confirm, negative: cancel, neutral: reset)
    private var dragging = false
    private var measuredRows: [(tag: String, height: CGFloat)] = []
    private let measuringLabel = UILabel()
    private var scrollsWholeContent = false
    private var topPadding: CGFloat = 16
    private struct ReadingPosition {
        var atTop: Bool
        var tag: String?
        var hidden: CGFloat
        var height: CGFloat
    }
    private var ordinaryPosition: ReadingPosition?
    private var ordinaryActionOffset: CGPoint?
    var onSaved: (() -> Void)?

    init(preferences: NavigationPreferenceStore) {
        self.preferences = preferences
        editor = NavigationCustomization(preferences: preferences.value)
        flow = UICollectionViewFlowLayout(); flow.minimumLineSpacing = 0; flow.minimumInteritemSpacing = 0
        collection = CustomizationCollectionView(frame: .zero, collectionViewLayout: flow)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.32)
        view.accessibilityViewIsModal = true
        for target in [view!, heading, collection] {
            target.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: UIView, _) in
                self?.view.setNeedsLayout()
            }
        }
        let outside = UITapGestureRecognizer(target: self, action: #selector(outsideTap(_:)))
        outside.cancelsTouchesInView = false; view.addGestureRecognizer(outside)
        panel.backgroundColor = Appearance.surfaceVariant
        panel.layer.cornerRadius = 28; panel.clipsToBounds = true
        heading.accessibilityIdentifier = "customizeTitle"
        view.addSubview(panel)
        [heading, collection, actions].forEach(panel.addSubview)
        actions.accessibilityIdentifier = "customizeActions"
        actions.onMetricsChange = { [weak self] in self?.view.setNeedsLayout() }
        collection.backgroundColor = .clear
        collection.contentInsetAdjustmentBehavior = .never
        collection.contentInset.top = 16
        collection.dataSource = self; collection.delegate = self
        collection.cancellableActions = [reset, cancel, confirm]
        collection.register(CustomizationCell.self, forCellWithReuseIdentifier: "row")
        collection.register(UICollectionReusableView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "title")
        collection.register(UICollectionReusableView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter, withReuseIdentifier: "actions")
        collection.accessibilityIdentifier = "customizeList"
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(drag(_:)))
        collection.addGestureRecognizer(longPress)
        for (index, key) in ["reset", "cancel_label", "confirm_label"].enumerated() {
            let button = [reset, cancel, confirm][index]
            button.setTitle(index == 2 ? Appearance.text("ok") : Appearance.text(key), for: .normal)
            button.setTitleColor(Appearance.accent, for: .normal)
            button.titleLabel?.font = Appearance.font(14, medium: true)
            button.accessibilityIdentifier = ["customizeReset", "customizeCancel", "customizeOK"][index]
            button.addAction(UIAction { [weak self] _ in self?.finish(index) }, for: .touchUpInside)
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        // CGRect.height standardizes negative extents. Inspect the raw size so
        // collapsed bounds cannot become a positive viewport behind safe insets.
        guard safe.size.width > 0, safe.size.height > 48 else { panel.isHidden = true; return }
        let preferred = SourceDialogLayout.preferredContentWidth(in: safe, configurationSize: view.bounds.size)
        let width = SourceDialogLayout.width(in: safe, configurationSize: view.bounds.size,
                                             desiredContentWidth: preferred)
        guard width > 0, safe.size.height > 48 else { panel.isHidden = true; return }
        panel.isHidden = false
        let wasOverflow = scrollsWholeContent
        let previousFrame = collection.frame, previousOffset = collection.contentOffset
        let previousVisibleTop = previousOffset.y + (wasOverflow ? 0 : topPadding)
        let previousHeader = flow.headerReferenceSize.height
        let previousFooter = flow.footerReferenceSize.height
        let previousFooterY = previousHeader + measuredRows.reduce(0) { $0 + $1.height }
        let readingBody = !wasOverflow || (previousOffset.y >= previousHeader - topPadding && previousOffset.y < previousFooterY)
        var captured = ReadingPosition(atTop: !wasOverflow && previousOffset.y <= -collection.adjustedContentInset.top + 0.5,
                                       tag: nil, hidden: 0, height: 1)
        for (index, row) in measuredRows.enumerated() {
            guard let frame = collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { continue }
            if frame.maxY > previousVisibleTop {
                captured.tag = row.tag; captured.hidden = previousVisibleTop - frame.minY; captured.height = frame.height
                break
            }
        }
        let position = readingBody ? captured : ordinaryPosition ?? captured
        let previousHeights = measuredRows.map(\.height)
        let previousInset = collection.contentInset
        let idle = !dragging && !collection.isTracking && !collection.isDragging && !collection.isDecelerating
        let direction: UISemanticContentAttribute = view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        collection.semanticContentAttribute = direction; heading.semanticContentAttribute = direction
        let rowFont = Appearance.font(16, compatibleWith: collection.traitCollection)
        topPadding = UIFontMetrics(forTextStyle: .body).scaledValue(for: 16, compatibleWith: collection.traitCollection)
        measuringLabel.numberOfLines = 0; measuringLabel.lineBreakMode = .byWordWrapping; measuringLabel.font = rowFont
        measuredRows = editor.items.map { item in
            measuringLabel.text = CustomizationCell.title(item)
            let header = item == .shown || item == .hidden
            let textHeight = ceil(measuringLabel.sizeThatFits(CGSize(width: max(0, width - (header ? 40 : 64)), height: .greatestFiniteMagnitude)).height)
            return (item.tag, max(header ? 0 : 40, textHeight + 16) + 1)
        }
        // Virtual supplementary hosting must not change title/action typography
        // merely because the list has a local category override.
        _ = heading.measuredSize(width: max(0, preferred - 48), inheritedTraits: panel.traitCollection)
        let titleHeight = heading.measuredSize(width: max(0, width - 48), inheritedTraits: panel.traitCollection).height
        let actionLayout = actions.measuredLayout(width: width, rightToLeft: direction == .forceRightToLeft,
                                                  inheritedTraits: panel.traitCollection)
        let viewport = SourceMessageViewportLayout(available: safe, titleTextHeight: titleHeight,
            bodyHeight: measuredRows.reduce(topPadding) { $0 + $1.height }, customBody: true,
            footerHeight: actionLayout.height, minimumFooterHeight: actionLayout.minimumHeight,
            minimumBodyHeight: topPadding + max(40, ceil(rowFont.lineHeight)), minimumActionHeight: actionLayout.positive.height, panelWidth: width)
        let layout = viewport.content
        scrollsWholeContent = viewport.scrollsWholeContent
        if scrollsWholeContent && !wasOverflow {
            ordinaryPosition = captured
            ordinaryActionOffset = actions.contentOffset
        }
        if scrollsWholeContent != wasOverflow {
            heading.removeFromSuperview(); actions.removeFromSuperview()
            if !scrollsWholeContent { panel.addSubview(heading); panel.addSubview(actions) }
        }
        panel.frame = viewport.panel
        collection.frame = scrollsWholeContent ? panel.bounds : layout.body
        collection.contentInset = UIEdgeInsets(top: scrollsWholeContent ? 0 : topPadding, left: 0, bottom: 0, right: 0)
        collection.clippedTopPadding = scrollsWholeContent ? 0 : topPadding
        flow.headerReferenceSize = scrollsWholeContent ? CGSize(width: width, height: layout.title.height + topPadding) : .zero
        flow.footerReferenceSize = scrollsWholeContent ? CGSize(width: width, height: actionLayout.height) : .zero
        heading.frame = CGRect(x: 24, y: 18, width: max(0, width - 48), height: max(0, layout.title.height - 18))
        actions.apply(actionLayout, frame: scrollsWholeContent ? CGRect(x: 0, y: 0, width: width, height: actionLayout.height) : layout.footer)
        if !scrollsWholeContent, wasOverflow, let offset = ordinaryActionOffset {
            let restored = CGPoint(x: 0, y: min(max(0, offset.y), max(0, actions.contentSize.height - actions.bounds.height)))
            if actions.contentOffset != restored { actions.setContentOffset(restored, animated: false) }
            ordinaryActionOffset = nil
        }
        for cell in collection.visibleCells.compactMap({ $0 as? CustomizationCell }) { cell.apply(font: rowFont) }
        let changed = previousFrame != collection.frame || previousHeights != measuredRows.map(\.height)
            || previousInset != collection.contentInset || previousHeader != flow.headerReferenceSize.height
            || previousFooter != flow.footerReferenceSize.height
            || wasOverflow != scrollsWholeContent
        if changed {
            collection.collectionViewLayout.invalidateLayout()
            collection.layoutIfNeeded()
        }
        func mapped(_ position: ReadingPosition) -> CGFloat {
            if position.atTop { return -collection.adjustedContentInset.top }
            guard let tag = position.tag, let index = measuredRows.firstIndex(where: { $0.tag == tag }),
                  let frame = collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return -collection.adjustedContentInset.top }
            let within = position.hidden < frame.height ? position.hidden : position.hidden / max(1, position.height) * frame.height
            return frame.minY + within - (scrollsWholeContent ? 0 : topPadding)
        }
        if changed, idle {
            var target = mapped(position)
            if scrollsWholeContent && wasOverflow && !readingBody {
                target = previousOffset.y >= previousFooterY
                    ? flow.headerReferenceSize.height + measuredRows.reduce(0) { $0 + $1.height } + previousOffset.y - previousFooterY
                    : previousOffset.y
            }
            let minimum = -collection.adjustedContentInset.top
            let maximum = max(minimum, collection.contentSize.height - collection.bounds.height + collection.adjustedContentInset.bottom)
            let restored = CGPoint(x: 0, y: min(max(target, minimum), maximum))
            if collection.contentOffset != restored { collection.setContentOffset(restored, animated: false) }
            collection.layoutIfNeeded()
        }
        if var saved = ordinaryPosition, let tag = saved.tag, let row = measuredRows.first(where: { $0.tag == tag }) {
            if saved.hidden >= row.height { saved.hidden = saved.hidden / max(1, saved.height) * row.height }
            saved.height = row.height; ordinaryPosition = saved
        }
        if !scrollsWholeContent { ordinaryPosition = nil }
    }
    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let isTitle = kind == UICollectionView.elementKindSectionHeader
        let wrapper = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: isTitle ? "title" : "actions", for: indexPath)
        if scrollsWholeContent { wrapper.addSubview(isTitle ? heading : actions) }
        return wrapper
    }
    func collectionView(_ collectionView: UICollectionView, willDisplaySupplementaryView view: UICollectionReusableView, forElementKind elementKind: String, at indexPath: IndexPath) {
        if scrollsWholeContent { view.addSubview(elementKind == UICollectionView.elementKindSectionHeader ? heading : actions) }
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { editor.items.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "row", for: indexPath) as! CustomizationCell
        cell.configure(editor.items[indexPath.item])
        cell.apply(font: Appearance.font(16, compatibleWith: collection.traitCollection))
        cell.onHandle = { [weak self] gesture in self?.drag(gesture) }
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: collectionView.bounds.width, height: measuredRows.indices.contains(indexPath.item) ? measuredRows[indexPath.item].height : 41)
    }
    func collectionView(_ collectionView: UICollectionView, canMoveItemAt indexPath: IndexPath) -> Bool { indexPath.item > 0 }
    func collectionView(_ collectionView: UICollectionView, targetIndexPathForMoveFromItemAt originalIndexPath: IndexPath, toProposedIndexPath proposedIndexPath: IndexPath) -> IndexPath {
        proposedIndexPath.item == 0 ? IndexPath(item: 1, section: 0) : proposedIndexPath
    }
    func collectionView(_ collectionView: UICollectionView, moveItemAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        if editor.move(from: sourceIndexPath.item, to: destinationIndexPath.item), measuredRows.indices.contains(sourceIndexPath.item) {
            let row = measuredRows.remove(at: sourceIndexPath.item)
            measuredRows.insert(row, at: destinationIndexPath.item)
        }
    }
    @objc private func drag(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: collection)
        switch gesture.state {
        case .began:
            guard !dragging, collection.rowViewport.contains(point), let index = collection.indexPathForItem(at: point), index.item > 0 else { return }
            dragging = collection.beginInteractiveMovementForItem(at: index)
        case .changed: if dragging { collection.updateInteractiveMovementTargetPosition(point) }
        case .ended: if dragging { collection.endInteractiveMovement(); dragging = false }
        case .cancelled, .failed: if dragging { collection.cancelInteractiveMovement(); dragging = false }
        default: break
        }
    }
    @objc private func outsideTap(_ gesture: UITapGestureRecognizer) {
        if !panel.frame.contains(gesture.location(in: view)) { dismiss(animated: true) }
    }
    override func accessibilityPerformEscape() -> Bool { dismiss(animated: true); return true }
    private func finish(_ action: Int) {
        if action == 1 { dismiss(animated: true); return }
        do {
            let value = action == 0 ? NavigationCustomization.reset(updating: preferences.value) : editor.confirmed(updating: preferences.value)
            try preferences.update(value)
            let callback = onSaved
            dismiss(animated: true) { callback?() }
        } catch {
            let alert = UIAlertController(title: Appearance.text("error_label"), message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: Appearance.text("confirm_label"), style: .default))
            present(alert, animated: true)
        }
    }
}

@MainActor private final class CustomizationCollectionView: UICollectionView {
    var cancellableActions: [UIButton] = []
    private let paddingMask = UIView()
    var clippedTopPadding: CGFloat = 0 {
        didSet { if oldValue != clippedTopPadding { setNeedsLayout() } }
    }
    var rowViewport: CGRect {
        bounds.inset(by: UIEdgeInsets(top: clippedTopPadding, left: 0, bottom: 0, right: 0))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        // Android RecyclerView clips children to its fixed container padding.
        // Keep the physical scroll/drag owner, including pans in that blank band.
        if clippedTopPadding > 0 {
            paddingMask.backgroundColor = .black
            paddingMask.frame = rowViewport
            if mask !== paddingMask { mask = paddingMask }
        } else if mask != nil { mask = nil }
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return bounds.contains(point) && !rowViewport.contains(point) ? self : hit
    }
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if cancellableActions.contains(where: { $0 === view }) { return true }
        return super.touchesShouldCancel(in: view)
    }
}

@MainActor private final class CustomizationCell: UICollectionViewCell {
    private let label = Appearance.label(nil, size: 16)
    private let separator = UIView()
    private let handle = UIView()
    private let grip = UIImageView(image: UIImage(named: "ic_drag_lighttheme"))
    private var header = false
    var onHandle: ((UILongPressGestureRecognizer) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(label); contentView.addSubview(handle)
        separator.backgroundColor = Appearance.secondary.withAlphaComponent(0.15); contentView.addSubview(separator)
        grip.tintColor = Appearance.color(0x9d9d9d, 0xa9a9a9)
        grip.contentMode = .scaleAspectFit
        handle.addSubview(grip)
        handle.isUserInteractionEnabled = true
        handle.isAccessibilityElement = true; handle.accessibilityLabel = Appearance.text("sort")
        let pan = UILongPressGestureRecognizer(target: self, action: #selector(handleDrag(_:))); pan.minimumPressDuration = 0
        handle.addGestureRecognizer(pan)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.adjustsFontForContentSizeCategory = false
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(_ item: NavigationCustomization.Item) {
        header = item == .shown || item == .hidden
        label.text = Self.title(item)
        label.textColor = header ? Appearance.secondary : Appearance.foreground
        label.accessibilityIdentifier = "customize-row-" + item.tag
        handle.accessibilityIdentifier = "customize-handle-" + item.tag
        handle.isHidden = header
        accessibilityIdentifier = "customize-cell-" + item.tag
        backgroundColor = Appearance.surfaceVariant
        setNeedsLayout()
    }
    static func title(_ item: NavigationCustomization.Item) -> String {
        switch item {
        case .shown: Appearance.text("section_shown")
        case .hidden: Appearance.text("section_hidden")
        case .destination(let destination): destination == .subscriptionList
            ? Appearance.text("subscriptions_list_label") : Appearance.title(for: destination)
        }
    }
    func apply(font: UIFont) {
        if label.font != font { label.font = font; setNeedsLayout() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        separator.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        let leading: CGFloat = header ? 20 : 56
        let trailing: CGFloat = header ? 20 : 8
        label.frame = CGRect(x: rtl ? trailing : leading, y: 8,
            width: max(0, bounds.width - leading - trailing), height: max(0, bounds.height - 17))
        label.textAlignment = rtl ? .right : .left
        // Source 20×30 drawable scales into a 40×16 area after 8 leading/12 vertical padding.
        handle.frame = CGRect(x: rtl ? bounds.width - 48 : 0, y: (bounds.height - 1 - 40) / 2, width: 48, height: 40)
        grip.frame = CGRect(x: rtl ? 0 : 8, y: 12, width: 40, height: 16)
    }
    @objc private func handleDrag(_ gesture: UILongPressGestureRecognizer) { onHandle?(gesture) }
}
