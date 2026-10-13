import UIKit
import NotTennaPodCore

@MainActor final class TranscriptController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let playback: PlaybackCoordinator
    private let library: FeedLibraryStore
    private let loader: TranscriptLoader
    private let notice: (String) -> Void
    private let failure: (Error) -> Void
    private let copyText: (String) -> Void
    private let panel = UIScrollView(), composition = UIView(), toolbar = UIScrollView()
    private let heading = Appearance.label(Appearance.text("transcript"), size: 24)
    private let table = UITableView(frame: .zero, style: .plain)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let follow = SpeedCheckbox(titleKey: "transcript_follow_audio_label")
    private let closeButton = UIButton(type: .custom)
    private lazy var actions = NavigationDialogActions(positive: closeButton)
    private lazy var refresh = Appearance.icon("ic_refresh", label: Appearance.text("refresh_label")) { [weak self] in self?.loadSelected(force: true) }
    private lazy var copy = Appearance.icon("ic_copy", label: Appearance.text("copy_to_clipboard")) { [weak self] in self?.copySelection() }
    private lazy var cancel = Appearance.icon("ic_close", label: Appearance.text("cancel_label")) { [weak self] in self?.setSelecting(false) }
    private lazy var more = Appearance.icon("dots_vertical", label: Appearance.text("overflow_more")) { [weak self] in self?.showSelectionMenu() }
    private var transcript: EpisodeTranscript?
    private var loadedEpisodeID: Int64?
    private var selected = Set<Int>()
    private var selecting = false
    private var highlighted: Int?
    private var initialScroll = true
    private let scrollAnimator = TranscriptScrollAnimator()
    private var loadingTask: Task<Void, Never>?, eventsTask: Task<Void, Never>?
    private var requestID = UUID()
    private var observedEpisode: Int64?
    private var observedPhase: PlaybackCoordinator.Phase?
    private var observedPosition: Int32?
    private var rowHeights: [CGFloat] = []
    private var headingHeights: [CGFloat] = []
    private var metricsWidth: CGFloat = -1
    private var metricsScale: CGFloat = -1
    private var metricsCategory: UIContentSizeCategory?
    private var layingOut = false
    private var isLoading = true
    private var isClosed = false
    private var wholeScroll = false

    init(playback: PlaybackCoordinator, library: FeedLibraryStore, loader: TranscriptLoader,
         notice: @escaping (String) -> Void, failure: @escaping (Error) -> Void,
         copyText: @escaping (String) -> Void = { UIPasteboard.general.string = $0 }) {
        self.playback = playback; self.library = library; self.loader = loader
        self.notice = notice; self.failure = failure; self.copyText = copyText
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { loadingTask?.cancel(); eventsTask?.cancel() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.32); view.accessibilityViewIsModal = true
        panel.backgroundColor = Appearance.surfaceVariant
        panel.layer.cornerRadius = 28; panel.clipsToBounds = true
        panel.delegate = self; toolbar.contentInsetAdjustmentBehavior = .never
        panel.contentInsetAdjustmentBehavior = .never; panel.accessibilityIdentifier = "transcriptPanel"
        view.addSubview(panel); panel.addSubview(composition)
        [toolbar, spinner, table, follow, actions].forEach(composition.addSubview)
        [heading, refresh, copy, cancel, more].forEach(toolbar.addSubview)
        heading.accessibilityTraits.insert(.header)
        refresh.accessibilityIdentifier = "transcriptRefresh"; copy.accessibilityIdentifier = "transcriptCopy"
        cancel.accessibilityIdentifier = "transcriptCancelSelection"; more.accessibilityIdentifier = "transcriptMore"
        follow.accessibilityIdentifier = "transcriptFollow"; follow.checked = true; follow.contentMode = .redraw
        follow.addAction(UIAction { [weak self] _ in self?.follow.checked.toggle() }, for: .touchUpInside)
        closeButton.setTitle(Appearance.text("close_label"), for: .normal); closeButton.setTitleColor(Appearance.accent, for: .normal)
        closeButton.titleLabel?.font = Appearance.font(14, medium: true)
        closeButton.accessibilityIdentifier = "transcriptClose"
        closeButton.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
        actions.onMetricsChange = { [weak self] in self?.view.setNeedsLayout() }
        table.register(TranscriptCell.self, forCellReuseIdentifier: "segment")
        table.dataSource = self; table.delegate = self; table.separatorStyle = .none
        table.backgroundColor = .clear; table.contentInsetAdjustmentBehavior = .never
        table.estimatedRowHeight = 0; table.accessibilityIdentifier = "transcriptList"
        spinner.accessibilityIdentifier = "transcriptLoading"; spinner.startAnimating()
        let outside = UITapGestureRecognizer(target: self, action: #selector(outside(_:)))
        outside.cancelsTouchesInView = false; view.addGestureRecognizer(outside)
        view.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { [weak self] (_: UIView, _) in self?.view.setNeedsLayout() }
        updateToolbar()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard eventsTask == nil, !isClosed else { return }
        observedEpisode = playback.episode?.id; observedPhase = playback.phase
        observedPosition = playback.sample?.positionMilliseconds
        loadSelected(force: false)
        let events = playback.events()
        eventsTask = Task { [weak self] in
            for await _ in events {
                guard let self, !Task.isCancelled else { return }
                let changedMedia = observedEpisode != playback.episode?.id
                let changedStatus = observedPhase != playback.phase
                let position = playback.sample?.positionMilliseconds
                let positionChanged = observedPosition != position
                observedEpisode = playback.episode?.id; observedPhase = playback.phase; observedPosition = position
                if changedMedia || changedStatus { loadSelected(force: false) }
                if positionChanged { updatePosition() }
            }
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { stop() }
    }
    private func stop() {
        scrollAnimator.cancel()
        isClosed = true; requestID = UUID(); loadingTask?.cancel(); loadingTask = nil
        eventsTask?.cancel(); eventsTask = nil
    }
    @objc private func close() { stop(); dismiss(animated: true) }
    @objc private func outside(_ gesture: UITapGestureRecognizer) {
        if !panel.frame.contains(gesture.location(in: view)) { close() }
    }
    override func accessibilityPerformEscape() -> Bool { close(); return true }
    override var keyCommands: [UIKeyCommand]? { [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close))] }

    private func loadSelected(force: Bool) {
        loadingTask?.cancel(); requestID = UUID()
        guard let episodeID = playback.episode?.id else { isLoading = false; spinner.stopAnimating(); view.setNeedsLayout(); return }
        let token = requestID, library = library, loader = loader
        if force { isLoading = true; spinner.startAnimating(); view.setNeedsLayout() }
        loadingTask = Task { [weak self] in
            do {
                guard let episode = try await library.episode(id: episodeID) else {
                    guard let self, requestID == token, !isClosed else { return }
                    apply(nil, episodeID: episodeID); return
                }
                try Task.checkCancellation()
                guard let descriptor = episode.details.transcript else {
                    guard let self, requestID == token, !isClosed else { return }
                    stop(); dismiss(animated: true) { self.notice(Appearance.text("no_transcript_label")) }; return
                }
                let loaded = try await loader.load(descriptor, localMediaPath: episode.userState.localFileURL, forceRefresh: force)
                try Task.checkCancellation()
                guard let self, requestID == token, !isClosed, playback.episode?.id == episodeID else { return }
                apply(loaded, episodeID: episodeID)
            } catch is CancellationError { }
            catch {
                guard let self, requestID == token, !isClosed else { return }
                // Source nil parse/network content yields an empty, refreshable list.
                // Also terminate the verified parser-exception loading dead end.
                apply(nil, episodeID: episodeID)
            }
        }
    }
    private func apply(_ value: EpisodeTranscript?, episodeID: Int64) {
        let changedMedia = loadedEpisodeID != episodeID
        // A play/pause reload of the same transcript keeps its measured rows.
        if !changedMedia, let value, value == transcript {
            scrollAnimator.cancel(); initialScroll = true
            isLoading = false; spinner.stopAnimating(); view.setNeedsLayout()
            return
        }
        scrollAnimator.cancel()
        transcript = value; loadedEpisodeID = episodeID; initialScroll = true
        if changedMedia { selected = []; highlighted = nil }
        else { selected = selected.filter { value?.segments.indices.contains($0) == true } }
        isLoading = false; spinner.stopAnimating(); metricsWidth = -1
        view.setNeedsLayout(); view.layoutIfNeeded(); table.reloadData()
        // Position events, not merely opening a paused transcript, select highlighting.
    }
    private func setSelecting(_ value: Bool) {
        selecting = value
        if !value { selected = [] }
        follow.checked = !value; updateToolbar(); table.reloadData(); view.setNeedsLayout()
    }
    private func updateToolbar() {
        refresh.isHidden = selecting; copy.isHidden = !selecting; cancel.isHidden = !selecting; more.isHidden = !selecting
    }
    private func copySelection() {
        copyText(transcript?.selectedText(indices: selected) ?? ""); setSelecting(false)
    }
    private func showSelectionMenu() {
        guard presentedViewController == nil else { return }
        present(PopupMenuController(title: "", identifier: "transcriptSelectionMenu", anchor: more,
            anchorFraction: .zero, actions: [("transcriptSelectAll", Appearance.text("select_all_label"))], toolbarTrailing: true) { [weak self] _ in
                guard let self else { return }
                selected = Set(transcript?.segments.indices ?? 0..<0); table.reloadData()
            }, animated: true)
    }
    private func selectRow(_ index: Int, longPress: Bool) {
        guard let transcript, transcript.segments.indices.contains(index) else { return }
        if longPress {
            if !selecting { setSelecting(true); selected.insert(index); table.reloadData() }
        } else if selecting {
            if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }; table.reloadData()
        } else {
            guard playback.episode?.id == loadedEpisodeID else { return }
            let episodeID = loadedEpisodeID
            let segment = transcript.segments[index]
            scrollToSegment(index)
            follow.checked = true
            let position = Int64(playback.sample?.positionMilliseconds ?? playback.episode?.userState.positionMilliseconds ?? 0)
            let seek = position < segment.startMilliseconds || position > segment.endMilliseconds
            Task { [weak self] in
                guard let self, !isClosed, playback.episode?.id == episodeID else { return }
                do {
                    if seek { try await playback.seek(to: segment.startMilliseconds) }
                    else if playback.wantsPlayback { try await playback.pause() }
                    else { try await playback.play() }
                } catch { failure(error) }
            }
        }
    }
    private func updatePosition() {
        guard let transcript, playback.episode?.id == loadedEpisodeID, let position = playback.sample?.positionMilliseconds else { return }
        let previous = highlighted
        highlighted = transcript.segmentIndex(at: Int64(position))
        // Rows are redrawn when the highlighted segment changes, not every second.
        if previous != highlighted { table.reloadData() }
        scrollToSegment(highlighted!)
    }
    private func scrollToSegment(_ index: Int) {
        guard index > 0, follow.checked || initialScroll, index < rowHeights.count else { return }
        initialScroll = false
        let target = rowHeights.prefix(index - 1).reduce(0,+)
        let end = max(0, table.contentSize.height - table.bounds.height)
        if table.contentOffset.y >= end && (table.indexPathsForVisibleRows?.first?.row ?? 0) < index - 1 { return }
        let first = table.indexPathsForVisibleRows?.first?.row ?? 0
        let quick = abs(first - index) > 5
        let animation = TranscriptScrollAnimation(offset: table.contentOffset.y,
            targetTop: target, targetBottom: target + rowHeights[index - 1], viewport: table.bounds.height,
            maximum: end, quick: quick, pixelsPerPoint: table.traitCollection.displayScale)
        scrollAnimator.run(animation) { [weak self] offset in
            self?.table.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        }
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { if scrollView === table || scrollView === panel { scrollAnimator.cancel(); follow.checked = false } }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { transcript?.segments.count ?? 0 }
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { rowHeights.indices.contains(indexPath.row) ? rowHeights[indexPath.row] : 1 }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "segment", for: indexPath) as! TranscriptCell
        if let transcript {
            let index = indexPath.row
            cell.configure(segment: transcript.segments[index], heading: transcript.timecodeHeading(at: index),
                headingHeight: headingHeights.indices.contains(index) ? headingHeights[index] : 0,
                highlighted: selecting ? selected.contains(index) : highlighted == index, index: index,
                traits: view.traitCollection, rtl: view.effectiveUserInterfaceLayoutDirection == .rightToLeft) { [weak self] long in self?.selectRow(index, longPress: long) }
        }
        return cell
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !layingOut else { return }; layingOut = true; defer { layingOut = false }
        let traitCollection = view.traitCollection
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        let verticalInset = SourceDialogLayout.verticalBackgroundInset(configurationSize: view.bounds.size)
        guard safe.size.width > 48, safe.size.height > 2 * verticalInset else { panel.isHidden = true; return }
        panel.isHidden = false
        let width = safe.width - 48, maximum = safe.height - 2 * verticalInset
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let direction: UISemanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        [composition, toolbar, table, follow].forEach { $0.semanticContentAttribute = direction }
        heading.font = Appearance.font(24, compatibleWith: traitCollection); heading.numberOfLines = 1
        heading.textAlignment = rtl ? .right : .left
        let topHeight = max(64, heading.font.lineHeight + 16)
        let loadingHeight: CGFloat = isLoading ? 48 : 0
        let followHeight = follow.sizeThatFits(CGSize(width: max(0,width - 32), height: .greatestFiniteMagnitude)).height
        let footer = actions.measuredLayout(width: width, rightToLeft: rtl, inheritedTraits: traitCollection)
        let textWidth = max(0,width - 48 - 4)
        let font = Appearance.font(14, compatibleWith: traitCollection)
        let reflow = metricsWidth != width || metricsScale != traitCollection.displayScale || metricsCategory != traitCollection.preferredContentSizeCategory
        let oldIndex = table.indexPathsForVisibleRows?.first?.row
        let oldRowY = oldIndex.map { rowHeights.prefix($0).reduce(0,+) } ?? 0
        let hidden = table.contentOffset.y - oldRowY
        let oldRowHeight = oldIndex.flatMap { rowHeights.indices.contains($0) ? rowHeights[$0] : nil } ?? 1
        let hiddenFraction = min(1, max(0, hidden / max(1, oldRowHeight)))
        if reflow {
            scrollAnimator.cancel()
            metricsWidth = width; metricsScale = traitCollection.displayScale; metricsCategory = traitCollection.preferredContentSizeCategory
            headingHeights = []; rowHeights = []
            if let transcript {
                for (index, segment) in transcript.segments.enumerated() {
                    let title = transcript.timecodeHeading(at: index)
                    let titleHeight = title.map { TranscriptCell.height($0, width: textWidth, font: Appearance.font(14,bold:true,compatibleWith:traitCollection), scale: traitCollection.displayScale) + 16 } ?? 0
                    headingHeights.append(titleHeight)
                    rowHeights.append(titleHeight + TranscriptCell.height(segment.words, width: textWidth, font: font, scale: traitCollection.displayScale, maxLines: 100))
                }
            }
        }
        let rowsHeight = rowHeights.reduce(0,+)
        let chrome = topHeight + loadingHeight + followHeight + footer.height
        let minimumRow = min(rowsHeight, max(48, font.lineHeight + 16))
        let contentHeight = min(chrome + rowsHeight, max(maximum,chrome + minimumRow))
        let height = min(maximum, contentHeight)
        let previousWhole = wholeScroll; wholeScroll = contentHeight > height
        panel.isScrollEnabled = wholeScroll
        panel.frame = CGRect(x: safe.minX + 24, y: safe.midY - height/2, width: width, height: height)
        panel.contentSize = CGSize(width: width, height: contentHeight)
        if !wholeScroll && previousWhole { panel.setContentOffset(.zero, animated: false) }
        composition.frame = CGRect(x:0,y:0,width:width,height:contentHeight)
        toolbar.frame = CGRect(x:0,y:0,width:width,height:topHeight)
        let toolbarWidth = max(width, selecting ? 184 : 96)
        toolbar.contentSize = CGSize(width: toolbarWidth, height: topHeight)
        toolbar.isScrollEnabled = toolbarWidth > width
        toolbar.setContentOffset(CGPoint(x: min(max(0, toolbar.contentOffset.x), max(0, toolbarWidth - width)), y: 0), animated: false)
        func frame(_ x: CGFloat,_ w:CGFloat) -> CGRect { CGRect(x:rtl ? toolbarWidth-x-w:x,y:(topHeight-48)/2,width:w,height:48) }
        refresh.frame = frame(toolbarWidth-48,48); more.frame = frame(toolbarWidth-40,40)
        cancel.frame = frame(toolbarWidth-88,48); copy.frame = frame(toolbarWidth-136,48)
        let headingWidth = max(0,toolbarWidth - (selecting ? 136 : 48) - 32)
        heading.frame = CGRect(x:rtl ? toolbarWidth-16-headingWidth:16,y:0,width:headingWidth,height:topHeight)
        spinner.frame = CGRect(x:0,y:topHeight,width:width,height:loadingHeight)
        let listHeight = max(0,contentHeight-chrome)
        table.frame = CGRect(x:0,y:topHeight+loadingHeight,width:width,height:listHeight)
        follow.frame = CGRect(x:16,y:table.frame.maxY,width:max(0,width-32),height:followHeight)
        actions.apply(footer, frame: CGRect(x:0,y:follow.frame.maxY,width:width,height:footer.height))
        if reflow {
            table.reloadData(); table.layoutIfNeeded()
            if let oldIndex, rowHeights.indices.contains(oldIndex) {
                let retained = min(rowHeights[oldIndex] * hiddenFraction, max(0, rowHeights[oldIndex] - font.lineHeight))
                let offset = rowHeights.prefix(oldIndex).reduce(0,+) + retained
                table.setContentOffset(CGPoint(x:0,y:min(max(0,table.contentSize.height-table.bounds.height),offset)),animated:false)
            }
        }
    }
}

@MainActor private final class TranscriptCell: UITableViewCell {
    private let heading = UILabel(), words = TranscriptWords(type: .custom)
    private var headingHeight: CGFloat = 0
    private var rightToLeft = false
    private var perform: ((Bool) -> Void)?
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style:style,reuseIdentifier:reuseIdentifier); backgroundColor = .clear; selectionStyle = .none
        contentView.addSubview(heading); contentView.addSubview(words)
        heading.numberOfLines = 0; heading.isAccessibilityElement = false
        words.titleLabel?.numberOfLines = 100; words.contentHorizontalAlignment = .leading
        words.addAction(UIAction { [weak self] _ in self?.perform?(false) },for:.touchUpInside)
        words.addGestureRecognizer(UILongPressGestureRecognizer(target:self,action:#selector(longPress(_:))))
    }
    required init?(coder:NSCoder) { fatalError() }
    static func height(_ text:String,width:CGFloat,font:UIFont,scale:CGFloat,maxLines:Int = 0) -> CGFloat {
        // API36 default14sp TextView box is51px at2.625 density (includes font padding).
        // Keep that padding around native multiline font metrics; round at the local display scale.
        let measured = max(font.lineHeight,(text as NSString).boundingRect(with:CGSize(width:width,height:CGFloat.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:font],context:nil).height)
        let padding = max(0, font.pointSize * (51 / 2.625 / 14) - font.lineHeight)
        let scale = max(1,scale)
        let bounded = maxLines > 0 ? min(measured, font.lineHeight * CGFloat(maxLines)) : measured
        return ((bounded + padding) * scale).rounded(.up) / scale
    }
    func configure(segment:TranscriptSegment,heading:String?,headingHeight:CGFloat,highlighted:Bool,index:Int,traits:UITraitCollection,rtl:Bool,perform:@escaping(Bool)->Void) {
        self.perform = perform; self.headingHeight = headingHeight; rightToLeft = rtl
        self.heading.text = heading; self.heading.font = Appearance.font(14,bold:true,compatibleWith:traits)
        self.heading.textAlignment = rtl ? .right:.left; self.heading.textColor = Appearance.foreground
        words.setTitle(segment.words,for:.normal); words.titleLabel?.font = Appearance.font(14,compatibleWith:traits)
        words.titleLabel?.textAlignment = rtl ? .right:.left; words.setTitleColor(Appearance.foreground,for:.normal)
        words.semanticContentAttribute = rtl ? .forceRightToLeft:.forceLeftToRight
        // Material1.12 SurfaceColors at32dp: rounded overlay alpha45/255.
        words.backgroundColor = highlighted ? Appearance.color(0xcde4f4, 0x253850):.clear
        words.alpha = highlighted ? 1:0.5; self.heading.alpha = words.alpha
        words.accessibilityIdentifier = "transcriptSegment-\(index)"
        words.accessibilityLabel = [heading,segment.words].compactMap{$0}.joined(separator:". ")
        words.accessibilityTraits = highlighted ? [.button,.selected]:[.button]
        words.accessibilityCustomActions = [UIAccessibilityCustomAction(name:Appearance.text("transcript_select_action")) { [weak self] _ in self?.perform?(true);return true }]
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let inset:CGFloat = 24
        heading.frame = CGRect(x:inset + (rightToLeft ? 4 : 0),y:8,width:max(0,contentView.bounds.width-inset*2-4),height:max(0,headingHeight-16))
        heading.isHidden = headingHeight == 0
        words.frame = CGRect(x:rightToLeft ? 4 : 0,y:headingHeight,width:max(0,contentView.bounds.width-4),height:max(0,contentView.bounds.height-headingHeight))
    }
    @objc private func longPress(_ gesture:UILongPressGestureRecognizer) { if gesture.state == .began { perform?(true) } }
}

@MainActor private final class TranscriptWords: UIButton {
    override func layoutSubviews() {
        super.layoutSubviews()
        titleLabel?.frame = CGRect(x:24,y:0,width:max(0,bounds.width-48),height:bounds.height)
    }
}
