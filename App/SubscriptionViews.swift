import UIKit
import NotTennaPodCore

/// SubscriptionsRecyclerAdapter geometry: `columns` slots across the content width
/// (`GridDividerItemDecorator` insets each cell 1 point), or list rows — two per line when the
/// device-class default is 5 columns.
@MainActor struct SubscriptionsGridLayout: Equatable {
    let width: CGFloat
    let columns: Int
    /// List rows use a 2-span grid on devices whose default is 5 columns.
    let wideList: Bool
    var span: Int { columns == 1 ? (wideList ? 2 : 1) : columns }
    var isList: Bool { columns == 1 }
    func slot(_ index: Int, rowHeight: CGFloat, top: CGFloat, rightToLeft: Bool) -> CGRect {
        let column = index % span, row = index / span
        let slotWidth = width / CGFloat(span)
        let x = rightToLeft ? width - CGFloat(column + 1) * slotWidth : CGFloat(column) * slotWidth
        let frame = CGRect(x: x, y: top + CGFloat(row) * rowHeight, width: slotWidth, height: rowHeight)
        return isList ? frame : frame.insetBy(dx: 1, dy: 1)
    }
    func height(count: Int, rowHeight: CGFloat) -> CGFloat { CGFloat((count + span - 1) / span) * rowHeight }
    /// Grid slot height: 4-point padding around a card holding the square cover (1-pixel margin) and,
    /// when titles are shown, two title lines with the column-dependent padding (`SubscriptionViewHolder`).
    func gridRowHeight(showTitle: Bool, pixel: CGFloat) -> CGFloat {
        let slot = width / CGFloat(span) - 2
        let cover = slot - 8 - 2 * pixel
        return 2 + 8 + 2 * pixel + cover + (showTitle ? SubscriptionGridCell.titleHeight(columns: columns) : 0)
    }
    static let listRowHeight: CGFloat = 72
}

/// Shared feed-cell content (`SubscriptionViewHolder.bind`).
@MainActor private func counterText(_ counter: Int) -> String? {
    counter > 0 ? NumberFormatter.localizedString(from: NSNumber(value: counter), number: .decimal) : nil
}

/// `subscription_grid_item.xml`: card with 12-point corners, square cover, counter pill at the top end,
/// failure icon at the bottom end, optional two-line title below; fallback title over a missing cover
/// in the no-title mode.
@MainActor final class SubscriptionGridCell: UIControl {
    static func titleFontSize(columns: Int) -> CGFloat { columns == 2 ? 16 : (columns == 3 ? 15 : 14) }
    /// `setPadding` takes pixels: 16 px (≤ 3 columns) / 8 px, about 6 / 3 points.
    static func titlePadding(columns: Int) -> CGFloat { columns <= 3 ? 6 : 3 }
    static func titleHeight(columns: Int) -> CGFloat {
        ceil(Appearance.font(titleFontSize(columns: columns)).lineHeight * 2) + 2 * titlePadding(columns: columns)
    }
    let feedID: Int64
    private let card = UIView(), coverCard = UIView()
    /// Selection mode: 48-point dark top gradient (40%), 32-point circle at the top start, a selected
    /// cover inset by 12 points; the counter pill hides (`SubscriptionsRecyclerAdapter`).
    private let gradient = CAGradientLayer()
    private let circle = SelectionCircleView()
    private var selectionMode = false, isChosen = false
    private let artwork: EpisodeArtworkView
    private let fallback: UILabel
    private let pill: UILabel
    private let failure = UIImageView(image: UIImage(named: "ic_error"))
    private let title: UILabel
    private let columns: Int, showTitle: Bool

    init(feed: LibraryFeed, counter: Int, columns: Int, showTitle: Bool, library: FeedLibraryStore?) {
        feedID = feed.id; self.columns = columns; self.showTitle = showTitle
        let reader = library.map(LocalFolderArtworkReader.init(store:))
        artwork = EpisodeArtworkView(source: feed.metadata.imageURL, fallback: nil, title: nil,
                                     folderArtwork: { identity in try await reader?.read(feedID: feed.id, identity: identity) })
        fallback = Appearance.label(feed.title, size: 14)
        pill = Appearance.label(counterText(counter), size: 14)
        title = Appearance.label(feed.title, size: Self.titleFontSize(columns: columns))
        super.init(frame: .zero)
        card.backgroundColor = Appearance.navigation; card.layer.cornerRadius = 12
        card.layer.shadowColor = UIColor.black.cgColor; card.layer.shadowOpacity = 0.2
        card.layer.shadowRadius = 1; card.layer.shadowOffset = CGSize(width: 0, height: 0.5)
        coverCard.backgroundColor = UIColor(red: 0x77 / 255, green: 0x77 / 255, blue: 0x77 / 255, alpha: 0x22 / 255)
        coverCard.layer.cornerRadius = 12; coverCard.clipsToBounds = true
        artwork.backgroundColor = .clear
        fallback.backgroundColor = UIColor(red: 0x33 / 255, green: 0x33 / 255, blue: 0x33 / 255, alpha: 0x55 / 255)
        fallback.textColor = .white; fallback.textAlignment = .center; fallback.numberOfLines = 0; fallback.lineBreakMode = .byTruncatingTail
        // Shown only without titles, while the cover is not loaded (CoverLoader fallback).
        fallback.isHidden = showTitle
        artwork.onArtworkChange = { [weak self] in self?.fallback.isHidden = true }
        pill.backgroundColor = UIColor(red: 0x40 / 255, green: 0x40 / 255, blue: 0x40 / 255, alpha: 0xD2 / 255)
        pill.textColor = .white; pill.textAlignment = .center; pill.numberOfLines = 1; pill.clipsToBounds = true
        pill.isHidden = counter <= 0; pill.accessibilityIdentifier = "subscriptionCounter-\(feed.id)"
        failure.isHidden = !feed.lastUpdateFailed; failure.tintColor = Appearance.foreground
        title.numberOfLines = 2; title.lineBreakMode = .byTruncatingTail; title.textAlignment = .natural
        title.isHidden = !showTitle
        [artwork, fallback, pill, failure].forEach(coverCard.addSubview)
        [coverCard, title].forEach(card.addSubview)
        addSubview(card)
        gradient.colors = [UIColor.black.withAlphaComponent(0.4).cgColor, UIColor.clear.cgColor]
        gradient.isHidden = true; coverCard.layer.addSublayer(gradient)
        circle.isHidden = true; circle.accessibilityIdentifier = "subscriptionSelectionCircle-\(feed.id)"
        addSubview(circle)
        for view in [card, coverCard, artwork, fallback, pill, failure, title, circle] as [UIView] { view.isUserInteractionEnabled = false }
        isAccessibilityElement = true; accessibilityTraits = .button; accessibilityIdentifier = "subscriptionFeed-\(feed.id)"
        accessibilityLabel = [feed.title, feed.lastUpdateFailed ? Appearance.text("refresh_failed_msg") : nil].compactMap { $0 }.joined(separator: ", ")
        accessibilityValue = counterText(counter)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isHighlighted: Bool { didSet { card.alpha = isHighlighted ? 0.7 : 1 } }
    func setSelection(mode: Bool, selected: Bool) {
        selectionMode = mode; isChosen = mode && selected
        circle.isHidden = !mode; circle.checked = isChosen; gradient.isHidden = !mode
        pill.isHidden = mode || pill.text == nil
        accessibilityTraits = isChosen ? [.button, .selected] : .button
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let pixel = 1 / max(1, traitCollection.displayScale)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        card.frame = bounds.insetBy(dx: 4, dy: 4)
        let side = max(0, card.bounds.width - 2 * pixel)
        coverCard.frame = CGRect(x: 0, y: 0, width: card.bounds.width, height: side + 2 * pixel)
        if isChosen { coverCard.frame = coverCard.frame.insetBy(dx: 12, dy: 12) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.frame = CGRect(x: 0, y: 0, width: coverCard.bounds.width, height: min(48, coverCard.bounds.height))
        CATransaction.commit()
        circle.frame = CGRect(x: rtl ? bounds.width - 36 : 4, y: 4, width: 32, height: 32)
        let coverSide = max(0, coverCard.bounds.width - 2 * pixel)
        artwork.frame = CGRect(x: pixel, y: pixel, width: coverSide, height: coverSide)
        fallback.frame = artwork.frame
        let padding = Self.titlePadding(columns: columns)
        title.frame = CGRect(x: padding, y: side + 2 * pixel + padding, width: max(0, card.bounds.width - 2 * padding),
                             height: ceil(title.font.lineHeight * 2))
        let pillWidth = ceil(pill.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 20)).width) + 16
        let pillHeight = ceil(pill.font.lineHeight) + 2
        pill.frame = CGRect(x: rtl ? pixel + 8 : pixel + coverSide - 8 - pillWidth, y: pixel + 8, width: pillWidth, height: pillHeight)
        pill.layer.cornerRadius = min(18, pillHeight / 2)
        failure.frame = CGRect(x: rtl ? pixel + 8 : pixel + coverSide - 32, y: pixel + coverSide - 32, width: 24, height: 24)
        card.layer.shadowPath = UIBezierPath(roundedRect: card.bounds, cornerRadius: 12).cgPath
    }
}

/// `subscription_list_item.xml`: 56-point cover, title (two lines at most), plain counter, failure icon.
@MainActor final class SubscriptionListRow: UIControl {
    let feedID: Int64
    private let cover = UIView()
    private let artwork: EpisodeArtworkView
    private let title: UILabel
    private let counter: UILabel
    private let failure = UIImageView(image: UIImage(named: "ic_error"))
    private var isChosen = false
    init(feed: LibraryFeed, counter value: Int, library: FeedLibraryStore?) {
        feedID = feed.id
        let reader = library.map(LocalFolderArtworkReader.init(store:))
        artwork = EpisodeArtworkView(source: feed.metadata.imageURL, fallback: nil, title: nil,
                                     folderArtwork: { identity in try await reader?.read(feedID: feed.id, identity: identity) })
        title = Appearance.label(feed.title, size: 14)
        counter = Appearance.label(counterText(value), size: 14)
        super.init(frame: .zero)
        cover.backgroundColor = UIColor(red: 0x77 / 255, green: 0x77 / 255, blue: 0x77 / 255, alpha: 0x22 / 255)
        cover.layer.cornerRadius = 12; cover.clipsToBounds = true
        artwork.backgroundColor = .clear; cover.addSubview(artwork)
        title.numberOfLines = 2; title.lineBreakMode = .byTruncatingTail; title.textAlignment = .natural
        counter.textColor = Appearance.secondary; counter.isHidden = value <= 0
        counter.accessibilityIdentifier = "subscriptionCounter-\(feed.id)"
        failure.isHidden = !feed.lastUpdateFailed; failure.tintColor = Appearance.foreground
        for view in [cover, title, counter, failure] as [UIView] { view.isUserInteractionEnabled = false; addSubview(view) }
        isAccessibilityElement = true; accessibilityTraits = .button; accessibilityIdentifier = "subscriptionFeed-\(feed.id)"
        accessibilityLabel = [feed.title, feed.lastUpdateFailed ? Appearance.text("refresh_failed_msg") : nil].compactMap { $0 }.joined(separator: ", ")
        accessibilityValue = counterText(value)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isHighlighted: Bool { didSet { updateBackground() } }
    /// List rows have no circle; a selected row gets the accent colour at 0x88 alpha.
    func setSelection(mode: Bool, selected: Bool) {
        isChosen = mode && selected
        accessibilityTraits = isChosen ? [.button, .selected] : .button
        updateBackground()
    }
    private func updateBackground() {
        backgroundColor = isChosen ? Appearance.accent.withAlphaComponent(0x88 / 255) : isHighlighted ? Appearance.selected.withAlphaComponent(0.5) : .clear
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let pixel = 1 / max(1, traitCollection.displayScale)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func place(_ x: CGFloat, _ width: CGFloat) -> CGFloat { rtl ? bounds.width - x - width : x }
        cover.frame = CGRect(x: place(16, 56), y: (bounds.height - 56) / 2, width: 56, height: 56)
        artwork.frame = cover.bounds.insetBy(dx: pixel, dy: pixel)
        var end = bounds.width - 16
        if !failure.isHidden {
            failure.frame = CGRect(x: place(end - 32, 24), y: (bounds.height - 24) / 2, width: 24, height: 24); end -= 40
        }
        if !counter.isHidden {
            let width = ceil(counter.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 20)).width)
            counter.frame = CGRect(x: place(end - width, width), y: (bounds.height - 20) / 2, width: width, height: 20); end -= width
        }
        let start: CGFloat = 16 + 56 + 8, width = max(0, end - 8 - start)
        let height = min(ceil(title.font.lineHeight * 2), ceil(title.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
        title.frame = CGRect(x: place(start, width), y: (bounds.height - height) / 2, width: width, height: height)
    }
}

/// `circle_checked` / `circle_unchecked` (24-unit vectors drawn at 32 points): a window-coloured disk with an
/// accent disk and a window-coloured tick, or a white ring.
@MainActor final class SelectionCircleView: UIView {
    var checked = false { didSet { setNeedsDisplay() } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SelectionCircleView, _) in view.setNeedsDisplay() }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ rect: CGRect) {
        let scale = bounds.width / 24
        func circle(_ radius: CGFloat) -> UIBezierPath {
            UIBezierPath(ovalIn: CGRect(x: (12 - radius) * scale, y: (12 - radius) * scale, width: 2 * radius * scale, height: 2 * radius * scale))
        }
        if checked {
            Appearance.background.setFill(); circle(11).fill()
            Appearance.accent.setFill(); circle(9).fill()
            let tick = UIBezierPath()
            for (index, point) in [(10.2, 17.1), (17.4, 9.9), (15.8, 8.3), (10.2, 13.9), (8.3, 12.0), (6.7, 13.6)].enumerated() {
                let p = CGPoint(x: point.0 * scale, y: point.1 * scale)
                if index == 0 { tick.move(to: p) } else { tick.addLine(to: p) }
            }
            tick.close(); Appearance.background.setFill(); tick.fill()
        } else {
            let ring = circle(10); ring.append(circle(8).reversing())
            UIColor.white.setFill(); ring.fill()
        }
    }
}

/// AppCompat popup-menu trailing widgets: checkbox (checkable item), radio button (single-choice
/// group) and the submenu arrow.
@MainActor final class PopupMenuAccessory: UIView {
    enum Kind: Equatable {
        case checkbox(Bool), radio(Bool), submenu
        var isOn: Bool { switch self { case .checkbox(let on), .radio(let on): on; case .submenu: false } }
    }
    let kind: Kind
    var mirrored = false { didSet { setNeedsDisplay() } }
    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        isOpaque = false; isUserInteractionEnabled = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: PopupMenuAccessory, _) in view.setNeedsDisplay() }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ rect: CGRect) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        switch kind {
        case .checkbox(let on):
            let box = UIBezierPath(roundedRect: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18), cornerRadius: 2)
            if on {
                Appearance.accent.setFill(); box.fill()
                let check = UIBezierPath()
                check.move(to: CGPoint(x: center.x - 5, y: center.y)); check.addLine(to: CGPoint(x: center.x - 1.5, y: center.y + 3.5))
                check.addLine(to: CGPoint(x: center.x + 5, y: center.y - 4))
                check.lineWidth = 2; UIColor.white.setStroke(); check.stroke()
            } else {
                box.lineWidth = 2; Appearance.foreground.setStroke(); box.stroke()
            }
        case .radio(let on):
            let ring = UIBezierPath(ovalIn: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18))
            ring.lineWidth = 2; (on ? Appearance.accent : Appearance.foreground).setStroke(); ring.stroke()
            if on { Appearance.accent.setFill(); UIBezierPath(ovalIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)).fill() }
        case .submenu:
            let arrow = UIBezierPath(), direction: CGFloat = mirrored ? -1 : 1
            arrow.move(to: CGPoint(x: center.x - 2.5 * direction, y: center.y - 5)); arrow.addLine(to: CGPoint(x: center.x + 2.5 * direction, y: center.y))
            arrow.addLine(to: CGPoint(x: center.x - 2.5 * direction, y: center.y + 5)); arrow.close()
            Appearance.foreground.setFill(); arrow.fill()
        }
    }
}
