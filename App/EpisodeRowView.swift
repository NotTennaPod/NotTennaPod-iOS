import UIKit
import ImageIO
import CryptoKit
import NotTennaPodCore

@MainActor
final class EpisodeRowView: UIView {
    private let title = UILabel()
    private let metadata = UILabel()
    private let status = UIStackView()
    private let position = UILabel()
    private let duration = UILabel()
    /// Created only for a row that shows or receives playback progress: building one for every row was a
    /// fifth of a row's cost, which a long list pays a page at a time.
    private var progress: UIProgressView?
    private let cover: EpisodeArtworkView
    private let drag = UIImageView(image: UIImage(named: "ic_drag_lighttheme"))
    private var presentation: EpisodeRowPresentation
    private let queued: Bool, queueScreen: Bool
    private var draggable: Bool
    private let showsSecondaryAction: Bool
    private let prefersDelete: Bool
    private let localFeed: Bool
    private var metadataHeight: CGFloat
    private let downloadButton: EpisodeDownloadButton
    private var episode: LibraryEpisode
    // Data identity is owned by the list presentation, independently of this view.
    var actionModel: EpisodeActionModel?
    var swipe: EpisodeRowSwipe?
    var contextMenu: ((UIView, CGPoint) -> Void)? {
        didSet {
            openButton.accessibilityCustomActions = contextMenu == nil ? nil : [UIAccessibilityCustomAction(name: Appearance.text("overflow_more"), actionHandler: { [weak self] _ in
                guard let self else { return false }; contextMenu?(self, CGPoint(x: 0.5, y: 0.5)); return true
            })]
        }
    }
    /// Source `bg_episode_list_item.xml`: `colorSecondaryContainer` when selected or activated (the playing episode, not
    /// during selection: `EpisodeItemListAdapter` deactivates rows in action mode), and the ripple on a press.
    private let selectedBackground = UIView()
    private let pressedBackground = UIView()
    private var selected = false
    private var selectionMode = false
    private var downloadState: (LibraryDownloadJob?, MediaDownloadProgress?, Bool, Bool)?
    func setSelected(_ selected: Bool, selectionMode: Bool = false) {
        self.selected = selected
        if self.selectionMode != selectionMode {
            self.selectionMode = selectionMode
            if let state = downloadState { updateDownload(job: state.0, progress: state.1, playing: state.2, streamOverDownload: state.3) }
        }
        updateBackground()
        if selected { openButton.accessibilityTraits.insert(.selected) }
        else { openButton.accessibilityTraits.remove(.selected) }
    }
    /// Selection, or the playing episode outside selection (`itemView.setActivated(isCurrentlyPlaying)`); playback is
    /// never spoken as selected.
    private func updateBackground() {
        selectedBackground.isHidden = !(selected || (downloadState?.2 == true && !selectionMode))
    }
    /// Whether the row shows the playing episode's background, or a press's (tests).
    var showsPlayingBackground: Bool { !selectedBackground.isHidden && !selected }
    var showsPressedFeedback: Bool { !pressedBackground.isHidden }
    /// Queue measures a new row before attachment; use its actual container environment.
    func configureQueueLayout(traits: UITraitCollection, rightToLeft: Bool) {
        semanticContentAttribute = rightToLeft ? .forceRightToLeft : .forceLeftToRight
        let secondary = Appearance.font(11, medium: true, compatibleWith: traits)
        metadataHeight = secondary.lineHeight + 2
        title.font = Appearance.font(16, compatibleWith: traits)
        let paragraph = NSMutableParagraphStyle()
        // Source Queue title uses viewStart, independent of the title's language.
        paragraph.alignment = rightToLeft ? .right : .left
        paragraph.minimumLineHeight = UIFontMetrics(forTextStyle: .body).scaledValue(for: 20, compatibleWith: traits)
        paragraph.maximumLineHeight = paragraph.minimumLineHeight
        paragraph.lineBreakMode = .byTruncatingTail
        title.attributedText = NSAttributedString(string: episode.details.title ?? "", attributes: [.paragraphStyle: paragraph])
        [metadata, position, duration].forEach { $0.font = secondary }
        for child in status.arrangedSubviews {
            if let image = child as? UIImageView {
                image.constraints.first { $0.firstAttribute == .width }?.constant =
                    UIFontMetrics(forTextStyle: .body).scaledValue(for: 12, compatibleWith: traits)
            } else if let label = child as? UILabel, label !== metadata {
                label.font = Appearance.font(11, compatibleWith: traits)
            }
        }
        setNeedsLayout()
    }
    func setQueueInteraction(_ policy: QueueInteractionPolicy) {
        draggable = policy.showsHandle; drag.isHidden = !draggable
        setNeedsLayout()
    }
    func acceptsQueueDrag(at point: CGPoint, policy: QueueInteractionPolicy) -> Bool {
        let geometry = layout(for: bounds.width)
        // Source handle layout is16 wide including4 end padding; the12-wide drawing excludes that padding.
        var hit = geometry.dragHandle
        if effectiveUserInterfaceLayoutDirection == .rightToLeft { hit.origin.x -= 4 }
        hit.size.width += 4
        return policy.startsDrag(at: point, handle: hit, cover: geometry.cover,
            rightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft)
    }
    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: self)
        contextMenu?(self, CGPoint(x: point.x / max(1, bounds.width), y: point.y / max(1, bounds.height)))
    }
    private let openButton = PressableButton(type: .custom)

    init(feed: LibraryFeed, episode: LibraryEpisode, queued: Bool, queueScreen: Bool, showRemainingTime: Bool,
         activelyPlaying: Bool, showsSecondaryAction: Bool = true, prefersDelete: Bool = false, library: FeedLibraryStore? = nil,
         episodeCover: Bool = true, downloadAction: @escaping () -> Void, open: @escaping () -> Void) {
        self.episode = episode
        self.queued = queued; self.queueScreen = queueScreen
        self.showsSecondaryAction = showsSecondaryAction
        self.prefersDelete = prefersDelete
        localFeed = feed.source.isLocalFeedSource
        downloadButton = EpisodeDownloadButton(episodeID: episode.id, action: downloadAction)
        presentation = EpisodeRowPresentation(episode: episode, inQueue: queued, queueScreen: queueScreen,
                                              activelyPlaying: activelyPlaying, showRemainingTime: showRemainingTime)
        draggable = queueScreen
        // False shows the podcast cover ("Use episode cover" off; a podcast's own list passes true).
        cover = EpisodeArtworkView(feed: feed, episode: episode, library: library, surface: .episodeList, useEpisodeCover: episodeCover)
        let secondaryFont = Appearance.font(11, medium: true)
        metadataHeight = secondaryFont.lineHeight + 2
        super.init(frame: .zero)
        selectedBackground.backgroundColor = Appearance.selected; selectedBackground.layer.cornerRadius = 12
        selectedBackground.isHidden = true; selectedBackground.isUserInteractionEnabled = false
        pressedBackground.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.2) : UIColor(white: 0, alpha: 0.12) }
        pressedBackground.layer.cornerRadius = 12
        pressedBackground.isHidden = true; pressedBackground.isUserInteractionEnabled = false
        addSubview(selectedBackground); addSubview(pressedBackground)
        openButton.highlightChanged = { [weak self] pressed in self?.pressedBackground.isHidden = !pressed }
        openButton.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(held(_:))))
        openButton.accessibilityIdentifier = "episode-\(episode.id)"
        openButton.accessibilityLabel = episode.details.title
        isAccessibilityElement = false
        alpha = presentation.opacity
        title.font = Appearance.font(16)
        title.textColor = Appearance.foreground
        title.numberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = UIFontMetrics(forTextStyle: .body).scaledValue(for: 20)
        paragraph.maximumLineHeight = paragraph.minimumLineHeight
        paragraph.lineBreakMode = .byTruncatingTail
        title.attributedText = NSAttributedString(string: episode.details.title ?? "", attributes: [.paragraphStyle: paragraph])
        [metadata, position, duration].forEach {
            $0.font = secondaryFont
            $0.textColor = Appearance.secondary
            $0.lineBreakMode = .byTruncatingTail
        }
        metadata.text = EpisodeRowPresentation.publicationDate(episode.details.publicationDate) + " · "
            + EpisodeRowPresentation.fileSize(episode.details.media?.size ?? 0)
        status.axis = .horizontal
        status.alignment = .center
        for indicator in presentation.indicators {
            let image = UIImageView(image: UIImage(named: Self.icon(for: indicator)))
            image.tintColor = Appearance.secondary
            image.widthAnchor.constraint(equalToConstant: UIFontMetrics(forTextStyle: .body).scaledValue(for: 12)).isActive = true
            image.heightAnchor.constraint(equalTo: image.widthAnchor).isActive = true
            status.addArrangedSubview(image)
        }
        if !presentation.indicators.isEmpty {
            let separator = Appearance.label(" · ", size: 11)
            separator.textColor = Appearance.secondary
            status.addArrangedSubview(separator)
        }
        status.addArrangedSubview(metadata)
        duration.text = presentation.duration
        position.text = presentation.position
        duration.isHidden = presentation.duration == nil
        position.isHidden = presentation.position == nil
        drag.tintColor = UIColor(white: 0.62, alpha: 1)
        drag.contentMode = .scaleAspectFit
        drag.isHidden = !draggable
        cover.layer.cornerRadius = 8
        cover.clipsToBounds = true
        [cover, drag, title, status, position, duration].forEach {
            $0.isUserInteractionEnabled = false
            addSubview($0)
        }
        if presentation.progressPercent != nil { progressBar().progress = Float(presentation.progressPercent ?? 0) / 100 }
        updateAccessibilityValue()
        openButton.addAction(UIAction { _ in open() }, for: .touchUpInside)
        addSubview(openButton)
        addSubview(downloadButton)
        downloadButton.isHidden = !showsSecondaryAction
        accessibilityElements = showsSecondaryAction ? [openButton, downloadButton] : [openButton]
        updateDownload(job: nil, progress: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    func updateDownload(job: LibraryDownloadJob?, progress: MediaDownloadProgress?, playing: Bool = false,
                        streamOverDownload: Bool = false) {
        downloadState = (job, progress, playing, streamOverDownload)
        downloadButton.update(episode: episode, job: job, progress: progress, playing: playing,
                              localFeed: localFeed, streamOverDownload: streamOverDownload,
                              prefersDelete: prefersDelete && !selectionMode)
        if !showsSecondaryAction { downloadButton.isHidden = true }
        updateBackground()
    }

    /// A commit that changed only the episode's playback (`LibraryEpisode.differsOnlyInPlayback`): the row shows its
    /// position, progress, duration and spoken value as a row built from it does, keeping its views (Android's rows are
    /// not rebound by a position save). Its height may change with the progress line; the list sets it.
    func showPlayback(of episode: LibraryEpisode, activelyPlaying: Bool, showRemainingTime: Bool) {
        guard episode.id == self.episode.id else { return }
        self.episode = episode
        presentation = EpisodeRowPresentation(episode: episode, inQueue: queued, queueScreen: queueScreen,
                                              activelyPlaying: activelyPlaying, showRemainingTime: showRemainingTime)
        duration.text = presentation.duration; position.text = presentation.position
        duration.isHidden = presentation.duration == nil
        position.isHidden = presentation.position == nil
        if presentation.progressPercent != nil || progress != nil {
            let bar = progressBar()
            bar.isHidden = presentation.progressPercent == nil
            bar.progress = Float(presentation.progressPercent ?? 0) / 100
        }
        if let state = downloadState { updateDownload(job: state.0, progress: state.1, playing: state.2, streamOverDownload: state.3) }
        updateAccessibilityValue()
        setNeedsLayout()
    }

    func updatePlaybackPosition(position value: Int32, duration length: Int32, showRemainingTime: Bool) {
        // Like notifyPlaybackPositionUpdated, retain the visibility established by the row binding.
        position.text = EpisodeRowPresentation.time(value)
        let percent = 100 * Double(value) / Double(length)
        progressBar().progress = percent.isNaN ? 0 : Float(min(100, max(0, percent))) / 100
        if let times = PlayerTimePresentation(position: value, duration: length, showRemainingTime: showRemainingTime) {
            duration.text = times.length
        }
        duration.isHidden = false
        updateAccessibilityValue()
        setNeedsLayout()
    }

    private func updateAccessibilityValue() {
        let state = episode.userState.playState == .played ? Appearance.text("is_played") : ""
        let visibleText = [metadata.text, position.isHidden ? nil : position.text, duration.isHidden ? nil : duration.text]
        openButton.accessibilityValue = ([state] + presentation.indicators.map { Appearance.text(Self.label(for: $0)) }
            + visibleText.compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: ". ")
    }

    private func layout(for width: CGFloat) -> EpisodeRowLayout {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let available = EpisodeRowLayout(width: width, titleHeight: 0, metadataHeight: 0, progressHeight: 0,
                                         draggable: draggable, showAction: showsSecondaryAction, scale: scale).text.width
        let titleHeight = title.sizeThatFits(CGSize(width: max(1, available), height: .greatestFiniteMagnitude)).height + 2
        let progressHeight = presentation.position != nil || presentation.duration != nil ? metadataHeight : 0
        // `EpisodeRowMetrics` measures rows that are not built yet the same way.
        return EpisodeRowLayout(width: width, titleHeight: titleHeight, metadataHeight: metadataHeight,
                                progressHeight: progressHeight, draggable: draggable, showAction: showsSecondaryAction,
                                rightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft, scale: scale)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: layout(for: size.width).height) }
    /// A row that leaves its list (removed, rebuilt or released) takes its swipe background with it, whatever its gesture
    /// or animation was doing; a row a patch moves takes it along.
    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)
        if newSuperview == nil { swipe?.rowWillLeave() }
    }
    override var frame: CGRect { didSet { swipe?.rowMoved() } }
    override var center: CGPoint { didSet { swipe?.rowMoved() } }
    override func layoutSubviews() {
        super.layoutSubviews()
        selectedBackground.frame = bounds.insetBy(dx: 4, dy: 2)
        pressedBackground.frame = selectedBackground.frame
        let layout = layout(for: bounds.width)
        cover.frame = layout.cover
        drag.frame = layout.dragHandle
        downloadButton.frame = layout.action
        openButton.frame = effectiveUserInterfaceLayoutDirection == .rightToLeft
            ? CGRect(x: layout.action.maxX, y: 0, width: bounds.width - layout.action.maxX, height: bounds.height)
            : CGRect(x: 0, y: 0, width: layout.action.minX, height: bounds.height)
        status.frame = CGRect(x: layout.text.minX, y: layout.text.minY, width: layout.text.width, height: metadataHeight)
        let progressHeight = presentation.position != nil || presentation.duration != nil ? metadataHeight : 0
        title.frame = CGRect(x: layout.text.minX, y: status.frame.maxY + 1, width: layout.text.width,
                             height: max(0, layout.text.height - metadataHeight - progressHeight - 2))
        let y = layout.text.maxY - progressHeight
        let positionWidth = position.sizeThatFits(CGSize(width: layout.text.width, height: metadataHeight)).width
        let durationWidth = duration.sizeThatFits(CGSize(width: layout.text.width, height: metadataHeight)).width
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        position.frame = CGRect(x: rtl ? layout.text.maxX - positionWidth : layout.text.minX, y: y, width: positionWidth, height: metadataHeight)
        duration.frame = CGRect(x: presentation.position == nil ? (rtl ? layout.text.maxX - durationWidth : layout.text.minX)
                               : (rtl ? layout.text.minX : layout.text.maxX - durationWidth), y: y, width: durationWidth, height: metadataHeight)
        progress?.frame = CGRect(x: layout.text.minX + (rtl ? durationWidth : positionWidth) + 4,
                                y: y + metadataHeight / 2 - 2, width: max(0, layout.text.width - positionWidth - durationWidth - 8), height: 4)
    }

    /// The progress bar, in its place between the position and duration texts; hidden unless the row's
    /// presentation shows progress (a later position update keeps that visibility).
    private func progressBar() -> UIProgressView {
        if let progress { return progress }
        let bar = UIProgressView(progressViewStyle: .default)
        bar.isHidden = presentation.progressPercent == nil
        bar.progressTintColor = Appearance.accent
        bar.trackTintColor = Appearance.selected
        bar.isUserInteractionEnabled = false
        insertSubview(bar, belowSubview: duration)
        progress = bar
        setNeedsLayout()
        return bar
    }

    private static func icon(for indicator: EpisodeRowPresentation.Indicator) -> String {
        switch indicator { case .inbox: "ic_inbox"; case .favorite: "ic_star"; case .video: "ic_videocam"; case .queue: "ic_playlist_play" }
    }
    private static func label(for indicator: EpisodeRowPresentation.Indicator) -> String {
        switch indicator { case .inbox: "is_inbox_label"; case .favorite: "is_favorite_label"; case .video: "media_type_video_label"; case .queue: "in_queue_label" }
    }

    /// Whether the row shows the position/duration line (`presentation.position` or `presentation.duration`).
    static func showsProgressLine(_ episode: LibraryEpisode, activelyPlaying: Bool) -> Bool {
        guard let media = episode.details.media else { return false }
        return activelyPlaying || episode.userState.positionMilliseconds > 0 || media.durationMilliseconds > 0
    }
}

/// The row's open button, which reports its pressed state (Android's ripple on touch-down).
private final class PressableButton: UIButton {
    var highlightChanged: ((Bool) -> Void)?
    override var isHighlighted: Bool {
        didSet { if isHighlighted != oldValue { highlightChanged?(isHighlighted) } }
    }
}

/// Row heights without building rows: long lists lay out every loaded row but create
/// views only near the visible area, like Android's RecyclerView. Mirrors `EpisodeRowView.layout(for:)` and the
/// fonts its initializer (or `configureQueueLayout`) sets; one instance serves one layout pass.
@MainActor final class EpisodeRowMetrics {
    private let title = UILabel()
    private let paragraph = NSMutableParagraphStyle()
    private let metadataHeight: CGFloat
    private let scale: CGFloat

    /// `queueTraits`: the Queue's rows use its container traits (`configureQueueLayout`); other rows the defaults.
    init(queueTraits: UITraitCollection?, scale: CGFloat) {
        self.scale = scale
        metadataHeight = Appearance.font(11, medium: true, compatibleWith: queueTraits).lineHeight + 2
        title.font = Appearance.font(16, compatibleWith: queueTraits)
        title.numberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        paragraph.minimumLineHeight = UIFontMetrics(forTextStyle: .body).scaledValue(for: 20, compatibleWith: queueTraits)
        paragraph.maximumLineHeight = paragraph.minimumLineHeight
        paragraph.lineBreakMode = .byTruncatingTail
    }

    func height(title text: String, progressLine: Bool, width: CGFloat, draggable: Bool, showAction: Bool) -> CGFloat {
        let available = EpisodeRowLayout(width: width, titleHeight: 0, metadataHeight: 0, progressHeight: 0,
                                         draggable: draggable, showAction: showAction, scale: scale).text.width
        title.attributedText = NSAttributedString(string: text, attributes: [.paragraphStyle: paragraph])
        let titleHeight = title.sizeThatFits(CGSize(width: max(1, available), height: .greatestFiniteMagnitude)).height + 2
        return EpisodeRowLayout(width: width, titleHeight: titleHeight, metadataHeight: metadataHeight,
                                progressHeight: progressLine ? metadataHeight : 0, draggable: draggable,
                                showAction: showAction, scale: scale).height
    }
}
