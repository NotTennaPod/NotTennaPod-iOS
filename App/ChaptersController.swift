import UIKit
import CoreText
import NotTennaPodCore

@MainActor final class ChaptersController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let binding: PlayerChapterBinding
    private let playback: PlaybackCoordinator
    private let library: FeedLibraryStore
    private let access: EpisodeChapterAccess
    private let notice: (String) -> Void
    private let failure: (Error) -> Void
    private let openLink: (String) -> Void
    private let panel = UIScrollView(), composition = UIView()
    private let titleView = SourceDialogTitle(Appearance.text("chapters_label"))
    private let table = UITableView(frame: .zero, style: .plain)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let closeButton = UIButton(type: .custom), refreshButton = UIButton(type: .custom)
    private lazy var actions = NavigationDialogActions(positive: closeButton, neutral: refreshButton)
    private var feeds: [Int64: LibraryFeed] = [:]
    private var feedTask: Task<Void, Never>?
    private var displayedEpisode: Int64?
    private var displayedChapters: [ParsedChapter]?
    private var initialSelection = true
    private var openingVerticalBackgroundInset: CGFloat?
    private var rowHeights: [CGFloat] = []
    private var metricsWidth: CGFloat = -1
    private var metricsCategory: UIContentSizeCategory?
    private var metricsScale: CGFloat?
    private var closed = false
    private var layingOut = false
    private var state: EpisodeChapterPresentation { binding.presentation }

    init(playback: PlaybackCoordinator, library: FeedLibraryStore, access: EpisodeChapterAccess,
         notice: @escaping (String) -> Void, failure: @escaping (Error) -> Void, openLink: @escaping (String) -> Void) {
        self.playback = playback; self.library = library; self.access = access
        self.notice = notice; self.failure = failure; self.openLink = openLink
        binding = .init(surface: .dialog, playback: playback, library: library, access: access)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve
        state.onReloaded = { [weak self] in self?.initialSelection = true }
        state.onChange = { [weak self] in self?.update() }
        state.onEmpty = { [weak self] in
            guard let self, !closed else { return }
            stop(); dismiss(animated: true) { self.notice(Appearance.text("no_chapters_label")) }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    isolated deinit { binding.stop(); feedTask?.cancel() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.32); view.accessibilityViewIsModal = true
        panel.backgroundColor = Appearance.surfaceVariant
        panel.layer.cornerRadius = 28; panel.clipsToBounds = true
        panel.contentInsetAdjustmentBehavior = .never; panel.accessibilityIdentifier = "chaptersPanel"
        view.addSubview(panel); panel.addSubview(composition)
        [titleView, table, spinner, actions].forEach(composition.addSubview)
        titleView.accessibilityTraits.insert(.header)
        table.backgroundColor = .clear; table.contentInsetAdjustmentBehavior = .never
        table.separatorInset = .zero; table.estimatedRowHeight = 0; table.dataSource = self; table.delegate = self
        table.register(ChapterCell.self, forCellReuseIdentifier: "chapter"); table.accessibilityIdentifier = "chaptersList"
        for (button, key, id) in [(closeButton, "close_label", "chaptersClose"), (refreshButton, "refresh_label", "chaptersRefresh")] {
            button.setTitle(Appearance.text(key), for: .normal); button.setTitleColor(Appearance.accent, for: .normal)
            button.titleLabel?.font = Appearance.font(14, medium: true); button.accessibilityIdentifier = id
        }
        closeButton.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
        refreshButton.addAction(UIAction { [weak self] _ in self?.initialSelection = true; self?.binding.refresh() }, for: .touchUpInside)
        actions.onMetricsChange = { [weak self] in self?.view.setNeedsLayout() }
        spinner.accessibilityIdentifier = "chaptersLoading"
        let outside = UITapGestureRecognizer(target: self, action: #selector(outside(_:)))
        outside.cancelsTouchesInView = false; view.addGestureRecognizer(outside)
        view.registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitDisplayScale.self]) { [weak self] (_: UIView, _) in self?.view.setNeedsLayout() }
        update()
    }
    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if openingVerticalBackgroundInset == nil {
            // Material resolves the background style when opening the dialog.
            // Safe areas and frames still follow the current local geometry.
            openingVerticalBackgroundInset = SourceDialogLayout.verticalBackgroundInset(configurationSize:view.bounds.size)
            view.setNeedsLayout()
        }
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); if !closed { binding.attach(to: view.window?.windowScene) } }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); if isBeingDismissed || presentingViewController == nil { stop() } }
    private func stop() { closed = true; binding.attach(to: nil); feedTask?.cancel() }
    @objc private func close() { stop(); dismiss(animated: true) }
    @objc private func outside(_ gesture: UITapGestureRecognizer) { if !panel.frame.contains(gesture.location(in: view)) { close() } }
    override func accessibilityPerformEscape() -> Bool { close(); return true }
    override var keyCommands: [UIKeyCommand]? {
        guard !closed else { return nil }
        return [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeFromKeyboard(_:)))]
    }
    @objc private func closeFromKeyboard(_ command: UIKeyCommand) {
        guard !closed else { return }
        close()
    }

    private func update() {
        guard isViewLoaded, !closed else { return }
        let replaced = displayedEpisode != state.episode?.id || displayedChapters != state.chapters
        if replaced {
            displayedEpisode = state.episode?.id; displayedChapters = state.chapters
            metricsWidth = -1; initialSelection = true
            if let episode = state.episode, feeds[episode.id] == nil {
                feedTask?.cancel()
                feedTask = Task { [weak self, library] in
                    guard let feed = try? await library.playbackFeed(id: library.feedID(forEpisode: episode.id)), !Task.isCancelled else { return }
                    self?.feeds[episode.id] = feed; self?.metricsWidth = -1; self?.view.setNeedsLayout()
                }
            }
        }
        if state.showsProgress { spinner.startAnimating() } else { spinner.stopAnimating() }
        // INVISIBLE keeps the neutral action's geometry reserved.
        refreshButton.alpha = state.canRefresh ? 1 : 0
        refreshButton.isUserInteractionEnabled = state.canRefresh; refreshButton.accessibilityElementsHidden = !state.canRefresh
        if replaced { table.reloadData() }
        else {
            for case let cell as ChapterCell in table.visibleCells {
                guard let path = table.indexPath(for: cell) else { continue }
                cell.updateProgress(index: path.row, state: state)
            }
        }
        view.setNeedsLayout()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { state.chapters?.count ?? 0 }
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { rowHeights.indices.contains(indexPath.row) ? rowHeights[indexPath.row] : 100 }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "chapter", for: indexPath) as! ChapterCell
        cell.horizontalInset = view.bounds.width >= 1000 ? 56 : 0
        if let chapters = state.chapters, let episode = state.episode, chapters.indices.contains(indexPath.row) {
            let index = indexPath.row, chapter = chapters[index]
            let hasImages = chapters.contains { $0.imageURL?.isEmpty == false }
            cell.configure(chapter: chapter, duration: ChapterCell.duration(index: index, state: state),
                image: hasImages && (chapter.imageURL?.isEmpty == false || EpisodeArtworkSelection.source(episode: episode, feed: feeds[episode.id]) != nil),
                episode: episode, feed: feeds[episode.id], library: library, access: access, index: index,
                play: { [weak self] in self?.playRow(index, episodeID: episode.id, chapter: chapter) },
                open: { [weak self] in if let link = chapter.link { self?.openLink(link) } })
            cell.updateProgress(index: index, state: state)
        }
        return cell
    }
    private func playRow(_ index: Int, episodeID: Int64, chapter: ParsedChapter) {
        guard !closed, state.episode?.id == episodeID, state.chapters?.indices.contains(index) == true,
              state.chapters?[index] == chapter, let target = state.rowTarget(at: index) else { return }
        scrollToSelection()
        Task { [weak self, playback] in
            do { try await playback.seekChapter(episodeID: episodeID, to: target, startPlayback: true) }
            catch { self?.failure(error) }
        }
    }
    private func scrollToSelection() {
        let index = state.selectedIndex
        guard index >= 0, rowHeights.indices.contains(index) else { return }
        let complete = (table.indexPathsForVisibleRows ?? []).filter { table.bounds.contains(table.rectForRow(at: $0)) }
        if (complete.first?.row ?? -1) >= index || (complete.last?.row ?? -1) <= index {
            // RecyclerView uses a100-pixel offset, distinct from dp geometry.
            let offset = rowHeights.prefix(index).reduce(0,+) - 100 / max(1, table.traitCollection.displayScale)
            table.setContentOffset(CGPoint(x: 0, y: min(max(0, offset), max(0, table.contentSize.height - table.bounds.height))), animated: false)
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !layingOut else { return }; layingOut = true; defer { layingOut = false }
        let safe = view.bounds.inset(by: view.safeAreaInsets), rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let width = SourceDialogLayout.width(in: safe, configurationSize: view.bounds.size)
        let titleHeight = 18 + max(32, ceil(titleView.measuredSize(width: max(1,width-48), inheritedTraits: view.traitCollection).height))
        let footer = actions.measuredLayout(width: width, rightToLeft: rtl, inheritedTraits: view.traitCollection)
        let horizontalInset: CGFloat = view.bounds.width >= 1000 ? 56 : 0
        let rowWidth = max(0, width - 2 * horizontalInset)
        table.separatorInset = UIEdgeInsets(top: 0, left: horizontalInset, bottom: 0, right: horizontalInset)
        let reflow = rowWidth != metricsWidth || metricsCategory != view.traitCollection.preferredContentSizeCategory || metricsScale != view.traitCollection.displayScale
        if reflow {
            metricsWidth = rowWidth; metricsCategory = view.traitCollection.preferredContentSizeCategory; metricsScale = view.traitCollection.displayScale
            let hasImages = state.chapters?.contains { $0.imageURL?.isEmpty == false } == true
            let hasFallback = state.episode.map { EpisodeArtworkSelection.source(episode: $0, feed: feeds[$0.id]) != nil } ?? false
            rowHeights = (state.chapters ?? []).map { ChapterCell.height(chapter: $0, width: rowWidth,
                image: hasImages && ($0.imageURL?.isEmpty == false || hasFallback), traits: view.traitCollection) }
        }
        let chrome = titleHeight + footer.height
        let backgroundInset = openingVerticalBackgroundInset ?? SourceDialogLayout.verticalBackgroundInset(configurationSize:view.bounds.size)
        let maximum = max(0, safe.height - 2 * backgroundInset)
        // Source SwipeRefreshLayout measures its child to the full alert body,
        // even when ChaptersFragment gives the recycler WRAP_CONTENT params.
        // The source clips tall rows inside the list; it does not reserve a
        // whole row at the expense of the title or footer in short windows.
        let contentHeight = max(maximum, chrome)
        let height = min(maximum, contentHeight)
        panel.frame = CGRect(x:safe.midX-width/2,y:safe.midY-height/2,width:width,height:height)
        panel.contentSize = CGSize(width:width,height:contentHeight); panel.isScrollEnabled = contentHeight > height
        panel.contentOffset = CGPoint(x:0,y:min(max(0,panel.contentOffset.y),max(0,contentHeight-height)))
        composition.frame = CGRect(x:0,y:0,width:width,height:contentHeight)
        titleView.frame = CGRect(x:24,y:18,width:max(0,width-48),height:max(0,titleHeight-18))
        table.frame = CGRect(x:0,y:titleHeight,width:width,height:max(0,contentHeight-chrome))
        spinner.frame = CGRect(x:table.frame.midX-24,y:table.frame.midY-24,width:48,height:48)
        actions.apply(footer, frame:CGRect(x:0,y:table.frame.maxY,width:width,height:footer.height))
        if reflow { table.reloadData(); table.layoutIfNeeded() }
        if initialSelection, !state.isLoading { initialSelection = false; scrollToSelection() }
    }
}

@MainActor private final class ChapterCell: UITableViewCell {
    var horizontalInset: CGFloat = 0 { didSet { setNeedsLayout() } }
    private let start = ChapterTextLabel(size:14), titleText = ChapterTextLabel(size:16, lines:2)
    private let durationText = ChapterTextLabel(size:14), link = ChapterLinkButton(type:.custom), playButton = ChapterPlayButton(type:.custom)
    private let ring = DownloadRingView()
    private var artwork: ChapterArtworkView?
    private var progressIndex: Int?
    private var playAction: (() -> Void)?, openAction: (() -> Void)?
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style:style,reuseIdentifier:reuseIdentifier)
        selectionStyle = .none; backgroundColor = .clear
        [start,titleText,durationText,link,ring,playButton].forEach(contentView.addSubview)
        start.textColor = Appearance.secondary; durationText.textColor = Appearance.secondary
        titleText.numberOfLines = 2; titleText.lineBreakMode = .byTruncatingTail
        [start,durationText].forEach { $0.numberOfLines = 1; $0.lineBreakMode = .byTruncatingTail }
        link.setTitleColor(Appearance.secondary,for:.normal); link.titleLabel?.font = Appearance.font(14)
        link.titleLabel?.lineBreakMode = .byTruncatingTail; link.contentHorizontalAlignment = .leading
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: ChapterCell, _) in
            cell.link.titleLabel?.font = Appearance.font(14, compatibleWith: cell.traitCollection)
            cell.setNeedsLayout()
        }
        playButton.tintColor = Appearance.foreground
        playButton.addAction(UIAction { [weak self] _ in self?.playAction?() },for:.touchUpInside)
        link.addAction(UIAction { [weak self] _ in self?.openAction?() },for:.touchUpInside)
        ring.isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError() }
    static func duration(index: Int, state: EpisodeChapterPresentation) -> Int64 {
        guard let chapters = state.chapters, chapters.indices.contains(index) else { return 0 }
        let end = index+1 < chapters.count ? chapters[index+1].startMilliseconds : Int64(state.episode?.details.media?.durationMilliseconds ?? 0)
        return end &- chapters[index].startMilliseconds
    }
    static func height(chapter: ParsedChapter, width: CGFloat, image: Bool, traits: UITraitCollection) -> CGFloat {
        let textWidth = max(1,width - 84 - (image ? 72 : 0))
        let title = ChapterTextLabel(size:16, lines:2)
        title.configure(chapter.title, traits:traits)
        let titleHeight = title.sizeThatFits(CGSize(width:textWidth,height:.greatestFiniteMagnitude)).height
        let secondaryHeight = ChapterTextLabel.singleLineHeight(font:Appearance.font(14,compatibleWith:traits), traits:traits)
        return max(image ? 56 : 48, titleHeight + (chapter.link?.isEmpty == false ? 3 : 2) * secondaryHeight + 22) + 1
    }
    func configure(chapter: ParsedChapter, duration: Int64, image: Bool, episode: LibraryEpisode, feed: LibraryFeed?,
                   library: FeedLibraryStore, access: EpisodeChapterAccess, index: Int, play: @escaping () -> Void, open: @escaping () -> Void) {
        playAction = play; openAction = open
        start.text = EpisodeRowPresentation.time(Int32(truncatingIfNeeded:chapter.startMilliseconds))
        titleText.text = chapter.title; durationText.text = Appearance.durationDescription("chapter_duration",milliseconds:Int32(truncatingIfNeeded:duration))
        link.setTitle(chapter.link,for:.normal); link.isHidden = chapter.link?.isEmpty != false
        artwork?.cancelLoading(); artwork?.removeFromSuperview(); artwork = nil
        if image {
            let cover = ChapterArtworkView(reference:chapter.imageURL,episode:episode,feed:feed,library:library,access:access,coverFallback:false)
            cover.layer.cornerRadius = 4; contentView.addSubview(cover); artwork = cover
        }
        playButton.accessibilityLabel = Appearance.text("play_chapter"); playButton.accessibilityIdentifier = "chapterPlay-\(index)"
        link.accessibilityIdentifier = "chapterLink-\(index)"; accessibilityIdentifier = "chapterRow-\(index)"
        setNeedsLayout()
    }
    func updateProgress(index: Int, state: EpisodeChapterPresentation) {
        let current = state.highlightedIndex == index
        // SurfaceColors elevation32: round((4.5*ln(33)+2)%*255)=45
        // source-over primary on the theme surface, using ColorUtils integer math.
        contentView.backgroundColor = current ? Appearance.color(0xcde4f4, 0x253850) : .clear
        playButton.setImage(UIImage(named:current ? "ic_replay" : "ic_play_48dp"),for:.normal)
        guard let chapters = state.chapters, chapters.indices.contains(index) else { return }
        let duration = Self.duration(index:index,state:state)
        let progress = Float(state.rowProgressPosition &- chapters[index].startMilliseconds) / Float(duration)
        ring.update(current ? min(0.995,max(0.005,progress)) : 0,indeterminate:false,animated:current && progressIndex == index)
        progressIndex = current ? index : nil
    }
    override func prepareForReuse() { super.prepareForReuse(); artwork?.cancelLoading(); playAction = nil; openAction = nil }
    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.frame = bounds.insetBy(dx: horizontalInset, dy: 0)
        link.titleLabel?.font = Appearance.font(14, compatibleWith: traitCollection)
        start.configure(start.text, traits:traitCollection)
        titleText.configure(titleText.text, traits:traitCollection)
        durationText.configure(durationText.text, traits:traitCollection)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft, width = contentView.bounds.width
        func frame(_ x: CGFloat,_ y: CGFloat,_ w: CGFloat,_ h: CGFloat) -> CGRect { CGRect(x:rtl ? width-x-w:x,y:y,width:w,height:h) }
        let imageWidth: CGFloat = artwork == nil ? 0 : 72
        artwork?.frame = frame(16,(bounds.height-56)/2,56,56)
        playButton.frame = frame(width-60,(bounds.height-48)/2,48,48)
        ring.frame = playButton.frame.insetBy(dx:4,dy:4)
        let x = 16+imageWidth, textWidth = max(0,width-x-68), secondaryHeight = ChapterTextLabel.singleLineHeight(font:start.font, traits:traitCollection)
        var y: CGFloat = 11
        start.frame = frame(x,y,textWidth,secondaryHeight); y += secondaryHeight
        let titleHeight = titleText.sizeThatFits(CGSize(width:max(1,textWidth),height:.greatestFiniteMagnitude)).height
        titleText.frame = frame(x,y,textWidth,titleHeight); y += titleHeight
        link.frame = frame(x,y,textWidth,link.isHidden ? 0 : secondaryHeight); if !link.isHidden { y += secondaryHeight }
        durationText.frame = frame(x,y,textWidth,secondaryHeight)
    }
}

@MainActor private final class ChapterPlayButton: UIButton {
    override func layoutSubviews() {
        super.layoutSubviews()
        imageView?.frame = CGRect(x:bounds.midX-12,y:bounds.midY-12,width:24,height:24)
    }
}

/// Preserve the release row's padded first/last line and 20sp title baseline
/// interval. UIKit owns shaping, wrapping and ellipsis; measurement and drawing
/// use the same attributed label, font and local text-size traits.
@MainActor private final class ChapterTextLabel: UILabel {
    private let baseSize: CGFloat
    private var insets = UIEdgeInsets.zero
    init(size: CGFloat, lines: Int = 1) {
        baseSize = size
        super.init(frame:.zero)
        numberOfLines = lines; lineBreakMode = .byTruncatingTail
        textColor = Appearance.foreground
    }
    required init?(coder: NSCoder) { fatalError() }
    static func padding(font: UIFont, traits: UITraitCollection) -> UIEdgeInsets {
        let scale = max(1,traits.displayScale), box = CTFontGetBoundingBox(font as CTFont)
        return UIEdgeInsets(top:max(0,ceil(box.maxY*scale)/scale-font.ascender),left:0,
            bottom:max(0,ceil(-box.minY*scale)/scale+font.descender),right:0)
    }
    static func singleLineHeight(font: UIFont, traits: UITraitCollection) -> CGFloat {
        let padding = padding(font:font,traits:traits)
        return font.lineHeight + padding.top + padding.bottom
    }
    func configure(_ value: String?, traits: UITraitCollection) {
        font = Appearance.font(baseSize,compatibleWith:traits)
        insets = Self.padding(font:font,traits:traits)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        if numberOfLines > 1 { paragraph.lineSpacing = max(0,20*font.pointSize/baseSize-font.lineHeight) }
        attributedText = NSAttributedString(string:value ?? "",attributes:[.font:font!, .paragraphStyle:paragraph])
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let measured = super.sizeThatFits(size)
        return CGSize(width:measured.width,height:max(font.lineHeight,measured.height)+insets.top+insets.bottom)
    }
    override func drawText(in rect: CGRect) { super.drawText(in:rect.inset(by:insets)) }
}

@MainActor private final class ChapterLinkButton: UIButton {
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let titleLabel else { return }
        let padding = ChapterTextLabel.padding(font:titleLabel.font,traits:traitCollection)
        titleLabel.frame.origin.y = padding.top
        titleLabel.frame.size.height = max(0,bounds.height-padding.top-padding.bottom)
    }
}
