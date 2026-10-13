import UIKit
import NotTennaPodCore

@MainActor final class NavigationDrawerView: UIView {
    /// `folder` toggles an open tag folder; `filter` is the divider's "Filtered" message.
    enum Action { case destination(NavigationDestination), feed(Int64), folder(String), filter, settings, customize }
    struct Item {
        let action: Action
        let title: String
        let image: String?
        var count = 0
        var selected = false
        var artwork: String?
        var identifier: String
        /// Feeds inside an open folder are indented by half the thumbnail (NavListAdapter layer 1).
        var layer = 0
        /// A folder row opens Rename/Delete tag, a feed row the feed context menu.
        var contextMenu: ((UIView) -> Void)? = nil
    }
    var onAction: ((Action) -> Void)?
    var onDismiss: (() -> Void)?
    private let scrim = UIControl()
    private let panel = UIView()
    private let list = UIScrollView()
    private let divider = UIView()
    private let settings: DrawerRow
    private var rows: [UIView] = []
    private var rowHeights: [CGFloat] = []
    var layout: DrawerLayout? { didSet { setNeedsLayout() } }
    var fraction: CGFloat = 0 { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        settings = DrawerRow(title: Appearance.text("settings_label"), image: "ic_settings", count: 0, selected: false, settings: true)
        super.init(frame: frame)
        accessibilityIdentifier = "navigationDrawer"
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        scrim.accessibilityLabel = Appearance.text("drawer_close")
        scrim.accessibilityIdentifier = "drawerScrim"
        scrim.addAction(UIAction { [weak self] _ in self?.onDismiss?() }, for: .touchUpInside)
        panel.backgroundColor = Appearance.background
        panel.layer.cornerRadius = 16
        panel.clipsToBounds = true
        list.contentInsetAdjustmentBehavior = .never
        divider.backgroundColor = Appearance.secondary.withAlphaComponent(0.15)
        settings.accessibilityIdentifier = "drawerSettings"
        settings.addAction(UIAction { [weak self] _ in self?.onAction?(.settings) }, for: .touchUpInside)
        [scrim, panel].forEach(addSubview)
        [list, divider, settings].forEach(panel.addSubview)
        panel.accessibilityElements = [settings, list]
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(items: [Item], subscriptionItems: [Item], showSeparator: Bool, filtered: Bool = false, library: FeedLibraryStore? = nil) {
        list.subviews.forEach { $0.removeFromSuperview() }
        rows.removeAll(); rowHeights.removeAll()
        func add(_ item: Item) {
            let row = DrawerRow(title: item.title, image: item.image, count: item.count, selected: item.selected)
            if case .feed(let feedID) = item.action {
                let reader = library.map(LocalFolderArtworkReader.init(store:))
                row.setArtwork(item.artwork, title: item.title,
                    folderArtwork: { identity in try await reader?.read(feedID: feedID, identity: identity) })
            }
            row.accessibilityIdentifier = item.identifier
            row.addAction(UIAction { [weak self] _ in self?.onAction?(item.action) }, for: .touchUpInside)
            if case .destination = item.action {
                row.onLongPress = { [weak self] in self?.onAction?(.customize) }
            } else if let menu = item.contextMenu {
                row.onLongPress = { [weak row] in if let row { menu(row) } }
                row.accessibilityCustomActions = [UIAccessibilityCustomAction(name: Appearance.text("overflow_more")) { [weak row] _ in
                    guard let row else { return false }; menu(row); return true
                }]
            }
            row.indent = CGFloat(item.layer) * 20
            rows.append(row); rowHeights.append(48); list.addSubview(row)
        }
        items.forEach(add)
        if showSeparator {
            let region = UIView()
            let line = UIView(); line.backgroundColor = divider.backgroundColor
            line.frame = CGRect(x: 0, y: 8, width: list.bounds.width, height: 1)
            line.autoresizingMask = .flexibleWidth
            region.addSubview(line)
            var height: CGFloat = 17
            // nav_section_item: an info icon and "Filtered" below the line while the subscriptions filter is on.
            if filtered {
                let message = UIControl(frame: CGRect(x: 0, y: 9, width: list.bounds.width, height: 28))
                message.autoresizingMask = .flexibleWidth
                message.accessibilityIdentifier = "drawerFiltered"; message.isAccessibilityElement = true
                message.accessibilityLabel = Appearance.text("filtered_label"); message.accessibilityTraits = .button
                let icon = UIImageView(image: UIImage(named: "ic_info")); icon.tintColor = Appearance.foreground
                let text = Appearance.label(Appearance.text("filtered_label"), size: 14); text.textColor = Appearance.secondary
                let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
                icon.frame = CGRect(x: rtl ? message.bounds.width - 36 : 16, y: 4, width: 20, height: 20)
                text.frame = CGRect(x: rtl ? 0 : 40, y: 4, width: max(0, message.bounds.width - 40), height: 20)
                text.textAlignment = rtl ? .right : .left
                icon.autoresizingMask = rtl ? .flexibleLeftMargin : .flexibleRightMargin
                text.autoresizingMask = .flexibleWidth
                [icon, text].forEach { $0.isUserInteractionEnabled = false; message.addSubview($0) }
                message.addAction(UIAction { [weak self] _ in self?.onAction?(.filter) }, for: .touchUpInside)
                region.addSubview(message); height = 9 + 28 + 8
            }
            rows.append(region); rowHeights.append(height); list.addSubview(region)
        }
        subscriptionItems.forEach(add)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layout else { return }
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        scrim.frame = CGRect(x: 0, y: 0, width: bounds.width, height: layout.panel.height)
        scrim.isHidden = layout.isPersistent
        scrim.alpha = fraction
        panel.frame = layout.panel.offsetBy(dx: layout.isPersistent ? 0 : (rtl ? 1 : -1) * layout.panel.width * (1 - fraction), dy: 0)
        panel.layer.maskedCorners = rtl ? [.layerMinXMinYCorner, .layerMinXMaxYCorner] : [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        list.frame = layout.list; divider.frame = layout.divider; settings.frame = layout.settings
        var y: CGFloat = 8
        for (index, row) in rows.enumerated() {
            let margin: CGFloat = row is DrawerRow ? 8 : 0
            row.frame = CGRect(x: margin, y: y, width: max(0, panel.bounds.width - margin * 2), height: rowHeights[index])
            y += rowHeights[index]
        }
        list.contentSize = CGSize(width: list.bounds.width, height: y + 8)
        accessibilityViewIsModal = !layout.isPersistent && fraction > 0
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if layout?.isPersistent == true { return panel.frame.contains(point) }
        return super.point(inside: point, with: event)
    }
}

@MainActor private final class DrawerRow: UIControl {
    var onLongPress: (() -> Void)?
    var indent: CGFloat = 0 { didSet { setNeedsLayout() } }
    private let title: UILabel
    private let count: UILabel
    private var cover: UIView
    private let settings: Bool
    init(title: String, image: String?, count: Int, selected: Bool, settings: Bool = false) {
        self.title = Appearance.label(title, size: 16)
        self.count = Appearance.label(count > 0 ? count.formatted() : nil, size: 14)
        self.settings = settings
        let icon = UIImageView(image: image.flatMap { UIImage(named: $0) })
        icon.contentMode = .center
        icon.tintColor = Appearance.foreground
        cover = icon
        super.init(frame: .zero)
        self.title.numberOfLines = 1
        self.title.lineBreakMode = .byTruncatingTail
        self.count.numberOfLines = 1
        self.count.textColor = Appearance.secondary
        backgroundColor = selected ? Appearance.surfaceVariant : .clear
        [cover, self.title, self.count].forEach { $0.isUserInteractionEnabled = false; addSubview($0) }
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityValue = count > 0 ? count.formatted() : nil
        accessibilityTraits = selected ? [.button, .selected] : .button
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:))))
    }
    required init?(coder: NSCoder) { fatalError() }
    func setArtwork(_ source: String?, title: String,
                    folderArtwork: (@Sendable (String) async throws -> Data?)? = nil) {
        cover.removeFromSuperview()
        cover = EpisodeArtworkView(source: source, fallback: nil, title: title, folderArtwork: folderArtwork)
        cover.layer.cornerRadius = 4; cover.clipsToBounds = true
        cover.isUserInteractionEnabled = false
        addSubview(cover)
    }
    @objc private func longPress(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { onLongPress?() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        // Android GradientDrawable clamps its 32-dp radius to half the 48-dp row.
        layer.cornerRadius = min(32, bounds.height / 2, bounds.width / 2)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func mirrored(_ rect: CGRect) -> CGRect { rtl ? CGRect(x: bounds.width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height) : rect }
        cover.frame = mirrored(CGRect(x: 16 + indent, y: (bounds.height - 40) / 2, width: 40, height: 40))
        let countWidth = count.text == nil ? 0 : min(count.intrinsicContentSize.width + 16, max(0, bounds.width - 88))
        count.frame = mirrored(CGRect(x: bounds.width - 8 - countWidth, y: 0, width: countWidth, height: bounds.height))
        count.textAlignment = .center
        title.frame = mirrored(CGRect(x: 72 + indent, y: 0, width: max(0, bounds.width - 72 - indent - 16 - countWidth - (settings ? 0 : 8)), height: bounds.height))
        title.textAlignment = rtl ? .right : .left
    }
}

/// AppCompat DrawerArrowToggle's closed-menu geometry: 18-unit bars, 2-unit stroke,
/// 3-unit gaps inside its 24-unit drawable. Uses the same icon, not a system symbol.
@MainActor final class DrawerMenuButton: UIButton {
    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setStrokeColor(Appearance.secondary.cgColor)
        context.setLineWidth(2)
        for y in [-5.0, 0, 5] {
            context.move(to: CGPoint(x: bounds.midX - 9, y: bounds.midY + y))
            context.addLine(to: CGPoint(x: bounds.midX + 9, y: bounds.midY + y))
        }
        context.strokePath()
    }
}


@MainActor final class DrawerAnimator: NSObject {
    private var link: CADisplayLink?
    private var start: CFTimeInterval = 0
    private var duration: Double = 0
    private var update: ((Double) -> Void)?
    func run(duration: Double, update: @escaping (Double) -> Void) {
        cancel()
        guard duration > 0 else { update(1); return }
        self.duration = duration; self.update = update; start = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        self.link = link; link.add(to: .main, forMode: .common)
    }
    func cancel() { link?.invalidate(); link = nil; update = nil }
    @objc private func tick(_ link: CADisplayLink) {
        let fraction = min(1, (link.timestamp - start) / duration)
        update?(DrawerLayout.animationProgress(fraction))
        if fraction >= 1 { cancel() }
    }
}
