import UIKit
import NotTennaPodCore

@MainActor
final class EpisodeHeaderView: UIView {
    var openPodcast: (() -> Void)?
    var performAction: ((EpisodeDetailActions.Action) -> Void)?
    private var cover: EpisodeArtworkView
    private var artworkIdentity: (source: String?, fallback: String?, title: String?, size: Int64?)
    private let library: FeedLibraryStore?
    private let coverButton = UIButton(type: .custom)
    private let podcast = UIButton(type: .custom)
    private let title = Appearance.label(nil, size: 16)
    private let metadata = UIView()
    private let duration = Appearance.label(nil, size: 14)
    private let separator = Appearance.label("·", size: 14)
    private let date = Appearance.label(nil, size: 14)
    private let noMedia = Appearance.label(nil, size: 14)
    private let subscriptionNotice = EpisodeSubscriptionNotice()
    private let primary = EpisodeHeaderActionButton(secondary: false)
    private let secondary = EpisodeHeaderActionButton(secondary: true)
    private let divider = UIView()
    private var actions: EpisodeDetailActions?

    init(feed: LibraryFeed, episode: LibraryEpisode, library: FeedLibraryStore? = nil) {
        self.library = library
        artworkIdentity = (EpisodeArtworkSelection.source(episode: episode, feed: feed), feed.metadata.imageURL,
                           feed.title, episode.details.media?.size)
        cover = EpisodeArtworkView(feed: feed, episode: episode, library: library)
        super.init(frame: .zero)
        [cover, coverButton, podcast, title, metadata, primary, secondary, subscriptionNotice, noMedia, divider].forEach(addSubview)
        [duration, separator, date].forEach(metadata.addSubview)
        [duration, separator, date].forEach { $0.textColor = Appearance.secondary; $0.numberOfLines = 1 }
        separator.isAccessibilityElement = false
        duration.accessibilityIdentifier = "episodeDuration"
        date.accessibilityIdentifier = "episodeDate"
        subscriptionNotice.addAction(UIAction { [weak self] _ in self?.openPodcast?() }, for: .touchUpInside)
        noMedia.text = Appearance.text("no_media_label")
        noMedia.textAlignment = .center
        noMedia.backgroundColor = Appearance.secondary.withAlphaComponent(0.15)
        noMedia.accessibilityIdentifier = "episodeNoMedia"
        cover.layer.cornerRadius = 8; cover.clipsToBounds = true
        podcast.setTitle(feed.title, for: .normal)
        podcast.setTitleColor(Appearance.secondary, for: .normal)
        podcast.titleLabel?.font = Appearance.font(14)
        podcast.titleLabel?.numberOfLines = 1
        podcast.titleLabel?.lineBreakMode = .byTruncatingTail
        podcast.contentHorizontalAlignment = .leading
        podcast.accessibilityIdentifier = "episodePodcast"
        coverButton.accessibilityLabel = Appearance.text("open_podcast")
        coverButton.accessibilityIdentifier = "episodeCover"
        [podcast, coverButton].forEach { button in
            button.addAction(UIAction { [weak self] _ in self?.openPodcast?() }, for: .touchUpInside)
        }
        title.text = episode.details.title; title.numberOfLines = 5; title.lineBreakMode = .byTruncatingTail
        title.accessibilityIdentifier = "episodeTitle"
        metadata.accessibilityIdentifier = "episodeMetadata"
        divider.backgroundColor = Appearance.secondary.withAlphaComponent(0.15)
        primary.accessibilityIdentifier = "episodePrimaryAction"
        secondary.accessibilityIdentifier = "episodeSecondaryAction"
        primary.addAction(UIAction { [weak self] _ in
            guard let self, let action = actions?.primary, action.visible else { return }
            performAction?(action.action)
        }, for: .touchUpInside)
        secondary.addAction(UIAction { [weak self] _ in
            guard let self, let action = actions?.secondary, action.visible else { return }
            performAction?(action.action)
        }, for: .touchUpInside)
        update(feed: feed, episode: episode)
    }
    required init?(coder: NSCoder) { fatalError() }

    func primaryActionFrame(in view: UIView) -> CGRect { primary.convert(primary.bounds, to: view) }

    func minimumScrollViewportHeight(width: CGFloat) -> CGFloat {
        let frames = layout(width: width)
        // Wrapped text (including the tappable notice) is read progressively.
        // Requiring that whole paragraph to fit would starve the notes viewport.
        return max(frames.cover.height, frames.primary.height, frames.secondary.height)
    }

    /// One long-date formatter per locale, not one per update.
    private static var dateFormatter: (locale: Locale, formatter: DateFormatter)?
    private static func spokenDate(_ date: Date) -> String {
        if dateFormatter?.locale != .current {
            let formatter = DateFormatter(); formatter.dateStyle = .long; formatter.timeStyle = .none
            dateFormatter = (.current, formatter)
        }
        return dateFormatter!.formatter.string(from: date)
    }
    func update(feed: LibraryFeed, episode: LibraryEpisode) {
        podcast.setTitle(feed.title, for: .normal)
        title.text = episode.details.title
        let identity = (EpisodeArtworkSelection.source(episode: episode, feed: feed), feed.metadata.imageURL,
                        feed.title, episode.details.media?.size)
        if artworkIdentity != identity {
            // Retain the cover's interaction/focus target. Cancel the obsolete
            // request immediately, even if UIKit defers releasing the detached view.
            let replacement = EpisodeArtworkView(feed: feed, episode: episode, library: library)
            replacement.layer.cornerRadius = 8; replacement.clipsToBounds = true
            replacement.frame = cover.frame
            insertSubview(replacement, belowSubview: coverButton)
            cover.cancelLoading()
            cover.removeFromSuperview()
            cover = replacement
            artworkIdentity = identity
        }
        date.text = EpisodeRowPresentation.publicationDate(episode.details.publicationDate)
        if let publication = episode.details.publicationDate {
            date.accessibilityLabel = Self.spokenDate(publication)
        } else { date.accessibilityLabel = nil }
        let milliseconds = episode.details.media?.durationMilliseconds ?? 0
        duration.text = milliseconds > 0 ? EpisodeRowPresentation.time(milliseconds) : nil
        duration.isHidden = milliseconds <= 0; separator.isHidden = duration.isHidden
        duration.accessibilityLabel = PlayerTimePresentation.spokenDuration(milliseconds) { key, count in
            String.localizedStringWithFormat(Appearance.text(key), count)
        }
        noMedia.isHidden = episode.details.media != nil
        subscriptionNotice.isHidden = feed.subscriptionState != .notSubscribed
        setNeedsLayout()
    }

    func update(actions: EpisodeDetailActions) {
        self.actions = actions
        secondary.updateProgress(actions.downloadProgress, indeterminate: actions.downloadIndeterminate)
        for (button, state) in [(primary, actions.primary), (secondary, actions.secondary)] {
            button.setImage(UIImage(named: state.action.icon), for: .normal)
            button.setTitle(Appearance.text(state.action.labelKey), for: .normal)
            button.isHidden = !state.visible
        }
    }

    private func layout(width: CGFloat) -> EpisodeHeaderLayout {
        let scale = traitCollection.displayScale
        let available = EpisodeHeaderLayout(width: width, podcastHeight: 0, titleHeight: 0, metadataHeight: 0, scale: scale).title.width
        let size = CGSize(width: available, height: .greatestFiniteMagnitude)
        return EpisodeHeaderLayout(width: width,
            podcastHeight: (podcast.titleLabel?.sizeThatFits(size).height ?? 0) + 2,
            titleHeight: title.sizeThatFits(size).height + 2,
            metadataHeight: max(duration.font.lineHeight, date.font.lineHeight) + 2,
            scale: scale, rightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft,
            subscriptionNoticeSize: subscriptionNotice.isHidden ? .zero : subscriptionNotice.sizeThatFits(
                CGSize(width: max(0, width - 2 * (16 * max(1, scale)).rounded() / max(1, scale)), height: .greatestFiniteMagnitude)),
            noMediaHeight: noMediaHeight(width: width))
    }
    private func noMediaHeight(width: CGFloat) -> CGFloat {
        noMedia.isHidden ? 0 : noMedia.sizeThatFits(CGSize(width: max(0, width - 32), height: .greatestFiniteMagnitude)).height + 2
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: layout(width: size.width).height)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let frames = layout(width: bounds.width)
        cover.frame = frames.cover; coverButton.frame = frames.cover
        podcast.frame = frames.podcast; title.frame = frames.title; metadata.frame = frames.metadata
        primary.frame = frames.primary; secondary.frame = frames.secondary; divider.frame = frames.divider
        subscriptionNotice.frame = frames.subscriptionNotice
        noMedia.frame = frames.noMedia
        let gap: CGFloat = (4 * max(1, traitCollection.displayScale)).rounded() / max(1, traitCollection.displayScale)
        let lengthWidth = duration.isHidden ? 0 : duration.sizeThatFits(metadata.bounds.size).width
        let dotWidth = separator.isHidden ? 0 : separator.sizeThatFits(metadata.bounds.size).width
        let dateX = duration.isHidden ? 0 : lengthWidth + 2 * gap + dotWidth
        func mirrored(_ rect: CGRect) -> CGRect {
            effectiveUserInterfaceLayoutDirection == .rightToLeft
                ? CGRect(x: metadata.bounds.width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height) : rect
        }
        duration.frame = mirrored(CGRect(x: 0, y: 0, width: lengthWidth, height: metadata.bounds.height))
        separator.frame = mirrored(CGRect(x: lengthWidth + gap, y: 0, width: dotWidth, height: metadata.bounds.height))
        date.frame = mirrored(CGRect(x: dateX, y: 0, width: max(0, metadata.bounds.width - dateX), height: metadata.bounds.height))
    }
}

@MainActor
private final class EpisodeHeaderActionButton: UIButton {
    private let secondarySlot: Bool
    private let ring = DownloadRingView()
    init(secondary: Bool) {
        secondarySlot = secondary
        super.init(frame: .zero)
        tintColor = Appearance.foreground
        setTitleColor(Appearance.foreground, for: .normal)
        titleLabel?.font = Appearance.font(14, medium: true)
        titleLabel?.adjustsFontForContentSizeCategory = true
        ring.isUserInteractionEnabled = false
        ring.isHidden = true
        insertSubview(ring, at: 0)
    }
    required init?(coder: NSCoder) { fatalError() }
    func updateProgress(_ value: Float?, indeterminate: Bool) {
        ring.isHidden = value == nil
        if let value { ring.update(value, indeterminate: indeterminate) }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = max(1, traitCollection.displayScale)
        func dp(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let icon = dp(24), leading = secondarySlot ? dp(8) : 0
        let iconSpace = secondarySlot ? dp(40) : icon + dp(8)
        let label = titleLabel?.sizeThatFits(CGSize(width: max(0, bounds.width - iconSpace), height: .greatestFiniteMagnitude)) ?? .zero
        let start = (bounds.width - iconSpace - label.width) / 2
        func mirrored(_ rect: CGRect) -> CGRect {
            effectiveUserInterfaceLayoutDirection == .rightToLeft
                ? CGRect(x: bounds.width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height) : rect
        }
        imageView?.frame = mirrored(CGRect(x: start + leading, y: (bounds.height - icon) / 2, width: icon, height: icon))
        if let imageView { ring.frame = imageView.frame.insetBy(dx: -dp(6), dy: -dp(6)) }
        titleLabel?.frame = mirrored(CGRect(x: start + iconSpace, y: (bounds.height - label.height) / 2, width: label.width, height: label.height))
    }
}
