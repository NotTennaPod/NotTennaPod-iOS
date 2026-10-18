import UIKit
import NotTennaPodCore

/// Shared subscribed/archive list and information header. Information keeps the action
/// strip's occupied space while hiding its list-only controls.
@MainActor
final class SubscribedFeedHeaderView: UIView {
    enum Action: Equatable {
        case information, filter, settings, failure, restore, subscribe
        case copyTitle(String), copyAuthor(String)
    }
    var onAction: ((Action) -> Void)?
    var onArtworkChange: (() -> Void)?
    func artwork(size: CGSize, scale: CGFloat) -> UIImage? { cover.artwork(size: size, scale: scale) }
    /// The cover location now shown (nil while the placeholder shows).
    var artworkSource: String? { cover.displayedSource }
    private let informationScreen: Bool
    private let library: FeedLibraryStore?
    private let strip = UIView()
    private let noticesBackground = UIView()
    private let leftCorner = UIImageView(image: UIImage(named: "ic_rounded_corner_left"))
    private let rightCorner = UIImageView(image: UIImage(named: "ic_rounded_corner_right"))
    private let title = Appearance.label(nil, size: 22)
    private let author = Appearance.label(nil, size: 14)
    private let coverButton = UIButton(type: .custom)
    private let info = UIButton(type: .custom)
    private let filter = UIButton(type: .custom)
    private let settings = UIButton(type: .custom)
    private let restore = ArchivedFeedRestoreButton(type: .custom)
    private var archived = false, preview = false
    private let previewDescription = FeedPreviewDescriptionView()
    private let failure = HeaderNoticeButton(text: Appearance.text("refresh_failed_msg"), error: true)
    private let filtered = HeaderNoticeButton(text: Appearance.text("filtered_label"), error: false)
    private let updatesDisabled = HeaderNoticeButton(text: Appearance.text("updates_disabled_label"), error: false)
    private var cover: EpisodeArtworkView
    private var artworkIdentity: String?
    private var artworkFeedID: Int64
    private var failed = false, hasFilter = false, keepUpdated = true
    private var descriptionText = ""
    /// The preview's "interacted" notice, after the podcast's episodes changed.
    func updateInteracted(_ hasInteracted: Bool) { previewDescription.update(text: descriptionText, hasInteracted: hasInteracted) }

    init(feed: LibraryFeed, library: FeedLibraryStore? = nil, hasFilter: Bool = false, keepUpdated: Bool = true,
         informationScreen: Bool = false, hasInteracted: Bool = false) {
        self.informationScreen = informationScreen
        self.library = library
        artworkIdentity = feed.metadata.imageURL
        artworkFeedID = feed.id
        cover = Self.artwork(feed: feed, library: library)
        super.init(frame: .zero)
        cover.onArtworkChange = { [weak self] in self?.onArtworkChange?() }
        strip.backgroundColor = UIColor.black.withAlphaComponent(128 / 255)
        noticesBackground.backgroundColor = Appearance.background
        leftCorner.tintColor = Appearance.background; rightCorner.tintColor = Appearance.background
        [strip, noticesBackground, leftCorner, rightCorner, cover, coverButton, title, author,
         info, filter, settings, restore, failure, filtered, updatesDisabled, previewDescription].forEach(addSubview)
        title.accessibilityIdentifier = "feedTitle"; author.accessibilityIdentifier = "feedAuthor"
        for label in [title, author] {
            label.textColor = .white; label.numberOfLines = 2; label.lineBreakMode = .byTruncatingTail
            label.layer.shadowColor = UIColor.black.cgColor; label.layer.shadowOpacity = 1
            label.layer.shadowRadius = 2; label.layer.shadowOffset = .zero
            label.isUserInteractionEnabled = true
        }
        title.font = Self.titleFont()
        title.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(copyTitle(_:))))
        author.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(copyAuthor(_:))))
        title.accessibilityCustomActions = [UIAccessibilityCustomAction(name: Appearance.text("copy_to_clipboard")) { [weak self] _ in
            guard let self, let text = title.text else { return false }; onAction?(.copyTitle(text)); return true
        }]
        author.accessibilityCustomActions = [UIAccessibilityCustomAction(name: Appearance.text("copy_to_clipboard")) { [weak self] _ in
            guard let self, let text = author.text else { return false }; onAction?(.copyAuthor(text)); return true
        }]
        configure(info, image: "ic_info_white", label: "show_info_label", id: "feedInformation", action: .information)
        configure(filter, image: "ic_filter_white", label: "filter", id: "feedFilter", action: .filter)
        configure(settings, image: "ic_settings_white", label: "show_feed_settings_label", id: "feedSettings", action: .settings)
        restore.setTitle(Appearance.text("restore_archive_label"), for: .normal)
        restore.titleLabel?.font = Appearance.font(14, medium: true)
        restore.setTitleColor(.white, for: .normal)
        restore.accessibilityIdentifier = "restoreFeed"
        restore.addAction(UIAction { [weak self] _ in
            guard let self else { return }; onAction?(preview ? .subscribe : .restore)
        }, for: .touchUpInside)
        previewDescription.openInformation = { [weak self] in self?.onAction?(.information) }
        if informationScreen {
            title.numberOfLines = 6
            [info, filter, settings, coverButton].forEach { $0.isHidden = true }
        }
        coverButton.accessibilityIdentifier = "feedCover"
        // The original cover duplicates the info action and is excluded from traversal.
        coverButton.isAccessibilityElement = false
        coverButton.addAction(UIAction { [weak self] _ in self?.onAction?(.information) }, for: .touchUpInside)
        failure.accessibilityIdentifier = "feedRefreshFailure"
        filtered.accessibilityIdentifier = "feedFiltered"
        updatesDisabled.accessibilityIdentifier = "feedUpdatesDisabled"
        updatesDisabled.isUserInteractionEnabled = false; updatesDisabled.accessibilityTraits = .staticText
        failure.addAction(UIAction { [weak self] _ in self?.onAction?(.failure) }, for: .touchUpInside)
        filtered.addAction(UIAction { [weak self] _ in self?.onAction?(.filter) }, for: .touchUpInside)
        update(feed: feed, hasFilter: hasFilter, keepUpdated: keepUpdated)
        descriptionText = (try? FeedDescriptionText.format(feed.metadata.description)) ?? ""
        previewDescription.update(text: descriptionText, hasInteracted: hasInteracted)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (header: SubscribedFeedHeaderView, _) in
            header.title.font = Self.titleFont(); header.author.font = Appearance.font(14)
            header.restore.titleLabel?.font = Appearance.font(14, medium: true)
            header.invalidateIntrinsicContentSize(); header.setNeedsLayout()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func titleFont() -> UIFont {
        guard let font = UIFont(name: "Roboto-Light", size: 22) else { preconditionFailure("Required Roboto Light instance unavailable") }
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: font)
    }

    private static func artwork(feed: LibraryFeed, library: FeedLibraryStore?) -> EpisodeArtworkView {
        let reader = library.map(LocalFolderArtworkReader.init(store:))
        let view = EpisodeArtworkView(source: feed.metadata.imageURL, fallback: nil, title: nil,
            folderArtwork: { identity in try await reader?.read(feedID: feed.id, identity: identity) })
        view.backgroundColor = UIColor(white: 191 / 255, alpha: 1)
        view.layer.cornerRadius = 16; view.clipsToBounds = true
        view.accessibilityIdentifier = "feedArtwork"; view.isAccessibilityElement = false
        return view
    }

    private func configure(_ button: UIButton, image: String, label: String, id: String, action: Action) {
        button.setImage(UIImage(named: image), for: .normal); button.tintColor = .white
        button.accessibilityLabel = Appearance.text(label); button.accessibilityIdentifier = id
        button.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
    }

    func update(feed: LibraryFeed, hasFilter: Bool, keepUpdated: Bool) {
        title.text = feed.title; author.text = feed.metadata.author
        failed = !informationScreen && feed.refreshFailed
        preview = feed.subscriptionState == .notSubscribed
        self.hasFilter = !informationScreen && !preview && hasFilter
        archived = !informationScreen && feed.subscriptionState == .archived
        self.keepUpdated = informationScreen || preview || (keepUpdated && !archived)
        restore.isHidden = !archived && !preview
        restore.setTitle(Appearance.text(preview ? "subscribe_label" : "restore_archive_label"), for: .normal)
        restore.accessibilityIdentifier = preview ? "subscribeFeed" : "restoreFeed"
        info.isHidden = informationScreen || preview
        filter.isHidden = informationScreen || archived || preview; settings.isHidden = filter.isHidden
        previewDescription.isHidden = !preview || informationScreen
        failure.isHidden = !failed; filtered.isHidden = !self.hasFilter; updatesDisabled.isHidden = self.keepUpdated
        let sameImage: Bool
        switch (artworkIdentity, feed.metadata.imageURL) {
        case (nil, nil): sameImage = true
        case let (old?, new?): sameImage = old.utf16.elementsEqual(new.utf16)
        default: sameImage = false
        }
        if artworkFeedID != feed.id || !sameImage {
            cover.cancelLoading(); cover.removeFromSuperview()
            cover = Self.artwork(feed: feed, library: library); insertSubview(cover, belowSubview: coverButton)
            cover.onArtworkChange = { [weak self] in self?.onArtworkChange?() }
            onArtworkChange?()
            artworkIdentity = feed.metadata.imageURL
            artworkFeedID = feed.id
        }
        invalidateIntrinsicContentSize(); setNeedsLayout()
    }

    private func measuredLayout(width: CGFloat) -> FeedHeaderLayout {
        let configurationWidth = window?.bounds.width ?? width
        let inset: CGFloat = configurationWidth >= 1000 ? 56 : 0
        let textWidth = FeedHeaderLayout(width: width, titleHeight: 0, authorHeight: 0,
            scale: traitCollection.displayScale, configurationWidth: configurationWidth).title.width
        let titleHeight = title.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        // Android keeps one author line even when the feed has no author.
        let authorHeight = max(author.font.lineHeight, author.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        let noticeWidth = max(0, width - 2 * inset)
        return FeedHeaderLayout(width: width, titleHeight: titleHeight, authorHeight: authorHeight,
            failureTextHeight: failed ? failure.textHeight(width: max(0, noticeWidth - 64)) : nil,
            filteredTextHeight: hasFilter ? filtered.textHeight(width: max(0, noticeWidth - 4)) : nil,
            updatesDisabledTextHeight: keepUpdated ? nil : updatesDisabled.textHeight(width: max(0, noticeWidth - 4)),
            scale: traitCollection.displayScale, rightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft,
            configurationWidth: configurationWidth, actionStripHeight: (archived || preview) ? 56 : 48)
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: measuredLayout(width: size.width).height +
            (previewDescription.isHidden ? 0 : previewDescription.sizeThatFits(size).height))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let layout = measuredLayout(width: bounds.width)
        strip.frame = layout.actionStrip; cover.frame = layout.cover; coverButton.frame = layout.cover
        noticesBackground.frame = CGRect(x: layout.hero.minX, y: layout.hero.maxY, width: layout.hero.width,
            height: max(0, layout.height - layout.hero.maxY))
        let scale = max(1, traitCollection.displayScale), corner = (12 * scale).rounded() / scale
        leftCorner.frame = CGRect(x: layout.hero.minX, y: layout.hero.maxY - corner, width: corner, height: corner)
        rightCorner.frame = CGRect(x: layout.hero.maxX - corner, y: layout.hero.maxY - corner, width: corner, height: corner)
        info.frame = layout.info; filter.frame = layout.filter; settings.frame = layout.settings
        if archived || preview {
            let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
            let wanted = max(64, restore.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 48)).width + 48)
            let trailing = preview ? CGFloat(4) : 48
            let available = rtl ? layout.info.maxX - layout.hero.minX - trailing : layout.hero.maxX - layout.info.minX - trailing
            let width = min(wanted, max(0, available))
            restore.frame = CGRect(x: rtl ? layout.info.maxX - 4 - width : layout.info.minX + 4,
                y: layout.actionStrip.minY + 4, width: width, height: 48)
            info.frame = layout.info.offsetBy(dx: rtl ? -width : width, dy: 0)
        }
        title.frame = layout.title; author.frame = layout.author
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        title.textAlignment = rtl ? .right : .left; author.textAlignment = title.textAlignment
        failure.frame = layout.failure; filtered.frame = layout.filtered; updatesDisabled.frame = layout.updatesDisabled
        previewDescription.frame = CGRect(x: 0, y: layout.height, width: bounds.width,
            height: previewDescription.isHidden ? 0 : previewDescription.sizeThatFits(bounds.size).height)
    }
    @objc private func copyTitle(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began, let text = title.text { onAction?(.copyTitle(text)) }
    }
    @objc private func copyAuthor(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began, let text = author.text { onAction?(.copyAuthor(text)) }
    }
}

@MainActor
private final class HeaderNoticeButton: UIControl {
    private let label: UILabel
    private let error: Bool
    init(text: String, error: Bool) {
        self.error = error; label = Appearance.label(text, size: 14)
        super.init(frame: .zero)
        let red = UIColor(red: 207 / 255, green: 24 / 255, blue: 0, alpha: 1)
        label.textColor = error ? red : Appearance.accent
        if error {
            layer.cornerRadius = 8; layer.borderWidth = 2; layer.borderColor = red.cgColor
            backgroundColor = red.withAlphaComponent(0.1)
        } else { label.textAlignment = .center; backgroundColor = Appearance.background }
        addSubview(label); isAccessibilityElement = true; accessibilityLabel = text; accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError() }
    func textHeight(width: CGFloat) -> CGFloat { label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height }
    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: error ? 16 : 2, dy: error ? 8 : 2)
    }
}

/// Material button's 48-point hit area contains a 40-point pill.
@MainActor private final class ArchivedFeedRestoreButton: UIButton {
    private let fill = CAShapeLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.insertSublayer(fill, at: 0)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 8 else {
            fill.path = nil
            return
        }
        let rect = bounds.insetBy(dx: 0, dy: 4)
        fill.fillColor = Appearance.accent.cgColor
        fill.path = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2).cgPath
    }
}
