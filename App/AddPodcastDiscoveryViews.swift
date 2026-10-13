import UIKit
import NotTennaPodCore

// Views: the Add-podcast search box and suggestions, the Discover screen body, and the bodies of the
// Add-by-address, Edit feed URL, Select country and feed chooser dialogs.

/// `addfeed.xml` search card: 28-point radius, surface-container fill, a leading 48-point magnifier
/// button labelled "Search podcast…", then the field with the same hint. Enter or the button searches.
@MainActor final class AddPodcastSearchBar: UIView, UITextFieldDelegate {
    let field = UITextField()
    let button: UIButton
    var onSubmit: ((String) -> Void)?
    override init(frame: CGRect) {
        button = Appearance.icon("ic_search", label: Appearance.text("search_podcast_hint")) {}
        super.init(frame: frame)
        backgroundColor = Appearance.color(0xe5e8ed, 0x2b3237)
        layer.cornerRadius = 28; layer.cornerCurve = .continuous
        accessibilityIdentifier = "addPodcastSearchBar"
        button.accessibilityIdentifier = "addPodcastSearchButton"
        button.addAction(UIAction { [weak self] _ in self?.submit() }, for: .touchUpInside)
        field.placeholder = Appearance.text("search_podcast_hint")
        field.accessibilityIdentifier = "addPodcastSearchField"
        field.returnKeyType = .search; field.autocorrectionType = .no; field.autocapitalizationType = .none
        field.textColor = Appearance.foreground; field.tintColor = Appearance.accent; field.delegate = self
        addSubview(button); addSubview(field)
        refreshFonts()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (bar: AddPodcastSearchBar, _) in
            bar.refreshFonts(); bar.setNeedsLayout()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    private func refreshFonts() { field.font = Appearance.font(16, compatibleWith: traitCollection) }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { submit(); return true }
    private func submit() {
        // performSearch hides the keyboard and clears focus first.
        field.resignFirstResponder()
        onSubmit?(field.text ?? "")
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: max(56, ceil((field.font?.lineHeight ?? 19) + 32)))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let side = min(48, bounds.width / 2)
        button.frame = CGRect(x: rtl ? bounds.width - 8 - side : 8, y: (bounds.height - 48) / 2, width: side, height: 48)
        let fieldWidth = max(0, bounds.width - side - 24)
        field.textAlignment = rtl ? .right : .left
        field.frame = CGRect(x: rtl ? 8 : side + 16, y: 0, width: fieldWidth, height: bounds.height)
    }
}

/// QuickFeedDiscoveryFragment: a grid of up to 12 square covers (4 columns, 6 above 600 points),
/// the state message with Retry centred over it, then "Suggestions by Apple Podcasts" and
/// "Discover more »".
@MainActor final class QuickDiscoveryView: UIView {
    var onSelect: ((PodcastSearchResult) -> Void)?
    var onRetry: (() -> Void)?
    var onDiscoverMore: (() -> Void)?
    private(set) var tiles: [UIControl] = []
    private let message = UILabel()
    private let retry = UIButton(type: .system)
    private let attribution = UILabel()
    private let more = UIButton(type: .system)
    private var state = TopListSession.State.loading

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "quickDiscovery"
        message.textAlignment = .center; message.numberOfLines = 0; message.textColor = Appearance.foreground
        message.accessibilityIdentifier = "quickDiscoveryMessage"
        retry.setTitle(Appearance.text("retry_label"), for: .normal); retry.tintColor = Appearance.accent
        retry.accessibilityIdentifier = "quickDiscoveryRetry"
        retry.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
        attribution.text = Appearance.text("discover_powered_by_itunes"); attribution.numberOfLines = 0
        attribution.textColor = Appearance.secondary; attribution.accessibilityIdentifier = "quickDiscoveryAttribution"
        more.setTitle(Appearance.text("discover_more"), for: .normal); more.tintColor = Appearance.accent
        more.accessibilityIdentifier = "discoverMore"
        more.addAction(UIAction { [weak self] _ in self?.onDiscoverMore?() }, for: .touchUpInside)
        [message, retry, attribution, more].forEach(addSubview)
        refreshFonts()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: QuickDiscoveryView, _) in
            view.refreshFonts(); view.setNeedsLayout()
        }
        update(.loading)
    }
    required init?(coder: NSCoder) { fatalError() }
    private func refreshFonts() {
        message.font = Appearance.font(14, compatibleWith: traitCollection)
        attribution.font = Appearance.font(12, compatibleWith: traitCollection)
        retry.titleLabel?.font = Appearance.font(14, medium: true, compatibleWith: traitCollection)
        more.titleLabel?.font = Appearance.font(14, medium: true, compatibleWith: traitCollection)
    }

    func update(_ state: TopListSession.State) {
        self.state = state
        let items: [PodcastSearchResult?]
        switch state {
        case .loaded(let results): items = results.map { $0 }
        // Placeholders keep the layout from jumping; the empty and error states keep their height.
        default: items = Array(repeating: nil, count: ItunesTopList.addScreenLimit)
        }
        tiles.forEach { $0.removeFromSuperview() }
        tiles = items.enumerated().map { index, item in
            let tile = QuickDiscoveryTile(item: item)
            tile.accessibilityIdentifier = item == nil ? nil : "quickDiscoveryItem-\(index)"
            if let item { tile.addAction(UIAction { [weak self] _ in self?.onSelect?(item) }, for: .touchUpInside) }
            insertSubview(tile, at: 0)
            return tile
        }
        switch state {
        case .loading, .loaded:
            message.isHidden = true; retry.isHidden = true
        case .empty:
            message.text = Appearance.text("search_status_no_results"); message.isHidden = false; retry.isHidden = true
        case .failed(let text):
            message.text = text; message.isHidden = false; retry.isHidden = false
        case .hidden:
            message.text = Appearance.text("discover_is_hidden"); message.isHidden = false; retry.isHidden = true
        }
        let gridVisible: Bool = { if case .loaded = state { true } else if case .loading = state { true } else { false } }()
        tiles.forEach { $0.isHidden = !gridVisible }
        attribution.isHidden = state == .hidden
        setNeedsLayout()
    }

    private var columns: Int { bounds.width > 600 ? 6 : 4 }
    private func gridHeight(width: CGFloat) -> CGFloat {
        let columns = width > 600 ? 6 : 4
        let side = width / CGFloat(columns)
        let rows = Int(ceil(Double(max(tiles.count, 1)) / Double(columns)))
        return 8 + CGFloat(rows) * side
    }
    private func footerHeight(width: CGFloat) -> CGFloat {
        let moreWidth = more.intrinsicContentSize.width + 16
        let text = attribution.sizeThatFits(CGSize(width: max(0, width - moreWidth - 8), height: .greatestFiniteMagnitude)).height
        return max(48, text)
    }
    private func messageHeight(width: CGFloat) -> CGFloat {
        guard !message.isHidden else { return 0 }
        let text = message.sizeThatFits(CGSize(width: max(0, width - 32), height: .greatestFiniteMagnitude)).height
        return 16 + text + 16 + (retry.isHidden ? 0 : 48 + 16)
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let body = state == .hidden ? messageHeight(width: size.width) : max(gridHeight(width: size.width), messageHeight(width: size.width))
        return CGSize(width: size.width, height: body + footerHeight(width: size.width))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let width = bounds.width, columns = self.columns
        let side = width / CGFloat(columns)
        for (index, tile) in tiles.enumerated() {
            let column = index % columns, row = index / columns
            let x = CGFloat(column) * side
            tile.frame = CGRect(x: rtl ? width - x - side : x, y: 8 + CGFloat(row) * side, width: side, height: side)
        }
        let body = state == .hidden ? messageHeight(width: width) : max(gridHeight(width: width), messageHeight(width: width))
        if !message.isHidden {
            let text = message.sizeThatFits(CGSize(width: max(0, width - 32), height: .greatestFiniteMagnitude)).height
            let block = messageHeight(width: width)
            let top = max(0, (body - block) / 2) + 16
            message.frame = CGRect(x: 16, y: top, width: max(0, width - 32), height: text)
            let retryWidth = min(width, retry.intrinsicContentSize.width + 32)
            retry.frame = CGRect(x: (width - retryWidth) / 2, y: message.frame.maxY + 16, width: retryWidth, height: 48)
        }
        let footer = footerHeight(width: width)
        let moreWidth = min(width, more.intrinsicContentSize.width + 16)
        more.frame = CGRect(x: rtl ? 0 : width - moreWidth, y: body, width: moreWidth, height: footer)
        attribution.textAlignment = rtl ? .right : .left
        attribution.frame = CGRect(x: rtl ? moreWidth + 4 : 4, y: body, width: max(0, width - moreWidth - 8), height: footer)
    }
}

/// FeedDiscoverAdapter item: a square cover with 8-point corners and 4-point padding, labelled
/// with the podcast title. A placeholder does nothing when tapped.
@MainActor private final class QuickDiscoveryTile: UIControl {
    private let cover: UIView
    init(item: PodcastSearchResult?) {
        if let item {
            cover = EpisodeArtworkView(source: item.imageURL, fallback: nil, title: nil)
        } else {
            cover = UIView(); cover.backgroundColor = UIColor(white: 191.0 / 255, alpha: 1)
        }
        super.init(frame: .zero)
        cover.layer.cornerRadius = 8; cover.clipsToBounds = true; cover.isUserInteractionEnabled = false
        addSubview(cover)
        isAccessibilityElement = item != nil
        accessibilityLabel = item?.title; accessibilityTraits = .button
        isEnabled = item != nil
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() { super.layoutSubviews(); cover.frame = bounds.insetBy(dx: 4, dy: 4) }
}
