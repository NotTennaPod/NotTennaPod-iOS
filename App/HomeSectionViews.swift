import UIKit
import NotTennaPodCore

/// Source `home_section.xml` header: title (TitleMedium, 60% max), optional shuffle button or inbox
/// badge pill after it, and the trailing "more" text button with an arrow.
@MainActor final class HomeSectionHeader: UIView {
    private let title: UILabel
    private let more = UIButton(type: .system)
    private let shuffle: UIButton?
    private let badge: UILabel?
    init(section: HomeSection, moreTitle: String, badge badgeText: String?, onShuffle: (() -> Void)?, onMore: @escaping () -> Void) {
        title = Appearance.label(Appearance.text(section.titleKey), size: 16)
        title.font = Appearance.font(16, medium: true); title.numberOfLines = 1; title.lineBreakMode = .byTruncatingTail
        title.accessibilityTraits.insert(.header); title.accessibilityIdentifier = "homeSectionTitle-\(section.rawValue)"
        shuffle = onShuffle.map { action in
            let button = Appearance.icon("ic_shuffle", label: Appearance.text("shuffle_suggestions"), action: action)
            button.accessibilityIdentifier = "homeShuffle"; return button
        }
        badge = badgeText.map { text in
            let label = Appearance.label(text, size: 16); label.font = Appearance.font(16, medium: true)
            label.textColor = Appearance.accent; label.textAlignment = .center
            label.layer.borderColor = Appearance.accent.cgColor; label.layer.borderWidth = 1; label.layer.cornerRadius = 15
            label.accessibilityIdentifier = "homeInboxBadge"; return label
        }
        super.init(frame: .zero)
        var configuration = UIButton.Configuration.plain()
        configuration.title = moreTitle
        configuration.image = UIImage(named: "ic_arrow_right_white")?.withRenderingMode(.alwaysTemplate).imageFlippedForRightToLeftLayoutDirection()
        configuration.imagePlacement = .trailing; configuration.imagePadding = 4
        configuration.contentInsets = .init(top: 8, leading: 12, bottom: 8, trailing: 12)
        configuration.baseForegroundColor = Appearance.accent
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var next = attributes; next.font = Appearance.font(14, medium: true); return next
        }
        more.configuration = configuration
        more.accessibilityIdentifier = "homeMore-\(section.rawValue)"
        more.addAction(UIAction { _ in onMore() }, for: .touchUpInside)
        [title, more].forEach(addSubview); shuffle.map(addSubview); badge.map(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    static let height: CGFloat = 56
    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func place(_ view: UIView, x: CGFloat, width: CGFloat, height: CGFloat) {
            view.frame = CGRect(x: rtl ? bounds.width - x - width : x, y: 8 + (bounds.height - 8 - height) / 2, width: width, height: height)
        }
        let moreSize = more.sizeThatFits(CGSize(width: bounds.width * 0.4, height: 48))
        let moreWidth = min(moreSize.width, bounds.width * 0.4)
        place(more, x: bounds.width - 8 - moreWidth, width: moreWidth, height: max(40, moreSize.height))
        let titleWidth = min(title.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 24)).width, bounds.width * 0.6)
        place(title, x: 16, width: titleWidth, height: 24)
        var x = 16 + titleWidth + 8
        if let shuffle { place(shuffle, x: x - 8, width: 48, height: 48); x += 40 }
        if let badge {
            let width = max(30, badge.sizeThatFits(CGSize(width: 200, height: 30)).width + 16)
            place(badge, x: x, width: width, height: 30)
        }
    }
}

/// Source `horizontal_itemlist_item.xml` episode card: 128-point cover (12-point corners), 48-point
/// action circle at its bottom end, 4-point progress when started, two-line title and date.
@MainActor final class HomeEpisodeCard: UIControl {
    static let width: CGFloat = 128, pitch: CGFloat = 136, height: CGFloat = 212
    let episodeID: Int64
    private let artwork: EpisodeArtworkView
    private let circle = UIView()
    let actionButton: EpisodeDownloadButton
    private let track = UIView(), fill = UIView()
    private let title: UILabel, date: UILabel
    private let progress: CGFloat?
    var contextMenu: ((UIView, CGPoint) -> Void)?

    init(feed: LibraryFeed, episode: LibraryEpisode, library: FeedLibraryStore?, playing: Bool, episodeCover: Bool = true,
         action: @escaping () -> Void, open: @escaping () -> Void) {
        episodeID = episode.id
        artwork = EpisodeArtworkView(feed: feed, episode: episode, library: library, surface: .homeEpisodeCard, useEpisodeCover: episodeCover)
        actionButton = EpisodeDownloadButton(episodeID: episode.id, action: action)
        title = Appearance.label(episode.details.title, size: 14); title.numberOfLines = 2; title.lineBreakMode = .byTruncatingTail
        date = Appearance.label(EpisodeRowPresentation.publicationDate(episode.details.publicationDate), size: 14)
        date.textColor = Appearance.secondary; date.numberOfLines = 1
        let duration = episode.details.media?.durationMilliseconds ?? 0, position = episode.userState.positionMilliseconds
        progress = duration > 0 && position > 0 ? max(0.05, min(1, CGFloat(position) / CGFloat(duration))) : nil
        super.init(frame: .zero)
        backgroundColor = playing ? Appearance.selected : Appearance.navigation
        layer.cornerRadius = 12; clipsToBounds = true
        accessibilityIdentifier = "homeEpisode-\(episode.id)"
        isAccessibilityElement = true; accessibilityTraits = .button
        accessibilityLabel = [episode.details.title, date.text].compactMap { $0 }.joined(separator: ", ")
        artwork.isUserInteractionEnabled = false; artwork.layer.cornerRadius = 12; artwork.clipsToBounds = true
        circle.backgroundColor = Appearance.accent; circle.layer.cornerRadius = 24
        circle.layer.borderColor = UIColor.white.cgColor; circle.layer.borderWidth = 2; circle.isUserInteractionEnabled = false
        actionButton.tintColor = .white; actionButton.iconTint = .white; actionButton.cardStyle = true
        track.backgroundColor = Appearance.color(0xd3d6db, 0x3a4048); fill.backgroundColor = Appearance.accent
        track.isHidden = progress == nil; fill.isHidden = progress == nil
        [artwork, circle, actionButton, track, fill, title, date].forEach(addSubview)
        addAction(UIAction { _ in open() }, for: .touchUpInside)
        installContextMenuHooks()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var accessibilityElements: [Any]? { get { [actionButton] } set {} }
    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        artwork.frame = CGRect(x: 0, y: 0, width: 128, height: 128)
        let circleX: CGFloat = rtl ? 4 : 128 - 4 - 48
        circle.frame = CGRect(x: circleX, y: 128 - 4 - 48, width: 48, height: 48)
        actionButton.frame = circle.frame
        track.frame = CGRect(x: 0, y: 128, width: 128, height: 4)
        let filled = 128 * (progress ?? 0)
        fill.frame = CGRect(x: rtl ? 128 - filled : 0, y: 128, width: filled, height: 4)
        let titleHeight = ceil(title.font.lineHeight * 2)
        title.frame = CGRect(x: 4, y: 132 + 8, width: 120, height: titleHeight)
        date.frame = CGRect(x: 4, y: title.frame.maxY, width: 120, height: ceil(date.font.lineHeight) + 4)
    }
}

extension HomeEpisodeCard {
    @objc func held(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: self)
        contextMenu?(self, CGPoint(x: point.x / max(1, bounds.width), y: point.y / max(1, bounds.height)))
    }
    func installContextMenuHooks() {
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(held(_:))))
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: Appearance.text("overflow_more"), actionHandler: { [weak self] _ in
            guard let self, let contextMenu else { return false }; contextMenu(self, CGPoint(x: 0.5, y: 0.5)); return true
        })]
    }
}

/// Source `horizontal_feed_item.xml`: 96-point square cover, 16-point corners, no title.
@MainActor final class HomeFeedCover: UIControl {
    static let size: CGFloat = 96, pitch: CGFloat = 104
    let feedID: Int64
    private let artwork: EpisodeArtworkView
    var contextMenu: ((UIView, CGPoint) -> Void)?
    init(feed: LibraryFeed, open: @escaping () -> Void) {
        feedID = feed.id
        artwork = EpisodeArtworkView(source: feed.metadata.imageURL, fallback: nil, title: feed.title)
        super.init(frame: .zero)
        artwork.isUserInteractionEnabled = false; artwork.layer.cornerRadius = 16; artwork.clipsToBounds = true
        layer.shadowColor = UIColor.black.cgColor; layer.shadowOpacity = 0.18; layer.shadowRadius = 2; layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(artwork)
        isAccessibilityElement = true; accessibilityTraits = .button
        accessibilityLabel = feed.title; accessibilityIdentifier = "homeFeed-\(feed.id)"
        addAction(UIAction { _ in open() }, for: .touchUpInside)
        installContextMenuHooks()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() { super.layoutSubviews(); artwork.frame = bounds }
}

extension HomeFeedCover {
    @objc func held(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: self)
        contextMenu?(self, CGPoint(x: point.x / max(1, bounds.width), y: point.y / max(1, bounds.height)))
    }
    func installContextMenuHooks() {
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(held(_:))))
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: Appearance.text("overflow_more"), actionHandler: { [weak self] _ in
            guard let self, let contextMenu else { return false }; contextMenu(self, CGPoint(x: 0.5, y: 0.5)); return true
        })]
    }
}

/// A horizontal strip (source `LinearLayoutManager(HORIZONTAL)`, 12-point padding), mirrored in RTL.
@MainActor final class HomeStrip: UIScrollView {
    private let pitch: CGFloat, itemSize: CGSize
    private var items: [UIView] = []
    init(items: [UIView], pitch: CGFloat, itemSize: CGSize, identifier: String) {
        self.pitch = pitch; self.itemSize = itemSize; self.items = items
        super.init(frame: .zero)
        showsHorizontalScrollIndicator = false; alwaysBounceHorizontal = true; clipsToBounds = true
        accessibilityIdentifier = identifier
        items.forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = 12 + CGFloat(items.count) * pitch + 12
        contentSize = CGSize(width: max(bounds.width, width), height: bounds.height)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        for (index, item) in items.enumerated() {
            let x = 12 + (pitch - itemSize.width) / 2 + CGFloat(index) * pitch
            item.frame = CGRect(x: rtl ? contentSize.width - x - itemSize.width : x, y: (bounds.height - itemSize.height) / 2,
                                width: itemSize.width, height: itemSize.height)
        }
    }
}
