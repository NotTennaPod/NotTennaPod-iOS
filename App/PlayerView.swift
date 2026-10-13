import UIKit
import WebKit
import NotTennaPodCore

@MainActor
final class PlayerView: UIView, UIGestureRecognizerDelegate, UIScrollViewDelegate {
    /// The frame owner commits layout synchronously, inside the caller's animation transaction.
    var expansionChanged: (() -> Void)?
    var failure: ((Error) -> Void)?
    var showVideo: (() -> Void)?
    var showSpeedDialog: (() -> Void)?
    var showIntervalDialog: ((PlaybackIntervalDirection) -> Void)?
    var favoriteChanged: (() async -> Void)?
    var showShare: ((LibraryFeed, LibraryEpisode, UIView) -> Void)?
    var showCast: (() -> Void)?
    var showSleepTimer: (() -> Void)?
    var showChapters: (() -> Void)?
    var showOverflow: ((LibraryFeed, LibraryEpisode, UIView) -> Void)?
    private var overflowContext: (feed: LibraryFeed, episode: LibraryEpisode)?
    private var shareContext: (feed: LibraryFeed, episode: LibraryEpisode)?
    private var favoriteEpisode: LibraryEpisode?
    private var favoriteWriteInFlight = false
    private let intervalPreferences: PlaybackIntervalPreferenceStore?
    private var intervalUpdates: Task<Void, Never>?
    var shareShownotesSelection: ((String, ShownotesWebView) -> Void)?
    var showShownotesLinkMenu: ((String, ShownotesWebView) -> Void)?
    var openLink: ((String) -> Void)?
    private(set) var expansion: CGFloat = 0
    var expandedSize = CGSize.zero
    var topInset: CGFloat = 0
    private let playback: PlaybackCoordinator
    private let library: FeedLibraryStore?
    private let chapterAccess: EpisodeChapterAccess?
    private var coverChapters: PlayerChapterBinding?, seekChapters: PlayerChapterBinding?
    private var chapterFeed: LibraryFeed?
    private var chapterArtwork: ChapterArtworkView?
    private var chapterArtworkKey: [String?] = []
    private let chapterControl = UIControl()
    private var seekedToChapterStart = false
    private let timeDisplayPreferences: TimeDisplayPreferenceStore
    private let mini = UIView()
    private let full = UIView()
    private let toolbar = UIView()
    private let pager = UIScrollView()
    private let coverPage = UIView()
    /// Built when the player first opens: a collapsed player never starts WebKit or builds a document.
    private var notes: ShownotesWebView?
    private let shownotesScroll: ShownotesScrollStore
    private var notesPageActive = false
    private var scenePauseObserver: NSObjectProtocol?
    private let miniTitle = Appearance.label(nil, size: 14)
    private let miniPodcast = Appearance.label(nil, size: 14)
    private let podcast = Appearance.label(nil, size: 14)
    private let title = Appearance.label(nil, size: 14)
    private let position = Appearance.label(nil, size: 12)
    private let duration = UIButton(type: .custom)
    private let miniProgress = UIView()
    private let miniTrack = UIView()
    private let seek = PlayerSeekBar()
    private let seekPreview = Appearance.label(nil, size: 16)
    private let playRing = DownloadRingView()
    private let loading = PlayerLoadingIndicator()
    private var miniArtwork: EpisodeArtworkView?
    private var artwork: EpisodeArtworkView?
    private var episodeID: Int64?
    private var artworkKey: [String?] = []
    /// "Use episode cover": the mini player follows it; the full player cover does not.
    var useEpisodeCover = true
    private var fraction: CGFloat = 0
    private var dragStart: CGFloat = 0
    private lazy var open = button(nil, label: "", id: "miniPlayerOpen") { [weak self] in self?.setExpanded(true) }
    private lazy var miniPlay = button("ic_play_48dp", label: Appearance.text("play_label"), id: "miniPlayerPlay") { [weak self] in self?.toggle() }
    private lazy var play = button("ic_play_48dp", label: Appearance.text("play_label"), id: "playerPlay") { [weak self] in self?.toggle() }
    private lazy var back = button("ic_arrow_down", label: Appearance.text("toolbar_back_button_content_description"), id: "playerCollapse") { [weak self] in self?.setExpanded(false) }
    private lazy var favorite = button("ic_star_border", label: Appearance.text("add_to_favorite_label"), id: "playerFavorite") { [weak self] in self?.changeFavorite() }
    private lazy var share = button("ic_share", label: Appearance.text("share_label"), id: "playerShare") { [weak self] in self?.shareCurrentEpisode() }
    private lazy var more: UIButton = button("dots_vertical", label: Appearance.text("overflow_more"), id: "playerMore") { [weak self] in
        guard let self, let context = overflowContext else { return }
        showOverflow?(context.feed, context.episode, more)
    }
    private lazy var cast = button("cast_device", label: Appearance.text("cast_disconnected"), id: "playerCast") { [weak self] in self?.showCast?() }
    private lazy var castIndicator = CastButtonIndicator(button: cast)
    func updateCast(_ state: CastConnectionState?) {
        cast.isHidden = state == nil
        let phase = state?.phase ?? .disconnected
        castIndicator.update(phase)
        cast.accessibilityLabel = Appearance.text(phase == .connected ? "cast_connected" : phase == .connecting ? "cast_connecting" : "cast_disconnected")
        cast.accessibilityValue = state?.name.isEmpty == false ? state?.name : nil
        setNeedsLayout()
    }
    private lazy var sleepTimer = button("ic_sleep", label: Appearance.text("set_sleeptimer_label"), id: "playerSleepTimer") { [weak self] in self?.showSleepTimer?() }
    private lazy var rewind = button("ic_fast_rewind", label: Appearance.text("rewind_label"), id: "playerRewind") { [weak self] in
        self?.perform { [weak self] in
            guard let self else { return }
            try await playback.skipInterval(seconds: intervalPreferences?.value.rewindSeconds ?? 10, direction: .rewind)
        }
    }
    private lazy var forward = button("ic_fast_forward", label: Appearance.text("fast_forward_label"), id: "playerForward") { [weak self] in
        self?.perform { [weak self] in
            guard let self else { return }
            try await playback.skipInterval(seconds: intervalPreferences?.value.forwardSeconds ?? 30, direction: .forward)
        }
    }
    private lazy var skip = button("ic_skip_48dp", label: Appearance.text("skip_episode_label"), id: "playerSkip") { [weak self] in
        self?.perform { [weak self] in try await self?.playback.skip() }
    }
    private lazy var shownotes = button("ic_info", label: Appearance.text("shownotes_label"), id: "playerShownotes") { [weak self] in
        guard let self else { return }
        resetShownotesForPageNavigation()
        pager.setContentOffset(CGPoint(x: 0, y: pager.bounds.height), animated: true)
    }
    private lazy var chaptersButton = button(nil, label: Appearance.text("chapters_label"), id: "playerChapters") { [weak self] in self?.showChapters?() }
    private lazy var previousChapter = button("ic_chapter_prev", label: Appearance.text("prev_chapter"), id: "playerPreviousChapter") { [weak self] in self?.seekChapter(previous: true) }
    private lazy var nextChapter = button("ic_chapter_next", label: Appearance.text("next_chapter"), id: "playerNextChapter") { [weak self] in self?.seekChapter(previous: false) }
    private let rewindLabel = Appearance.label("10", size: 12)
    private let forwardLabel = Appearance.label("30", size: 12)
    private let speedLabel = Appearance.label("1.00", size: 12)
    private lazy var speedButton = button("ic_playback_speed", label: Appearance.text("playback_speed"), id: "playerSpeed") { [weak self] in self?.showSpeedDialog?() }

    init(playback: PlaybackCoordinator, timeDisplayPreferences: TimeDisplayPreferenceStore, library: FeedLibraryStore? = nil, intervalPreferences: PlaybackIntervalPreferenceStore? = nil, chapterAccess: EpisodeChapterAccess? = nil, shownotesScroll: ShownotesScrollStore = .init()) {
        self.playback = playback
        self.shownotesScroll = shownotesScroll
        self.intervalPreferences = intervalPreferences
        self.library = library
        self.chapterAccess = chapterAccess
        self.timeDisplayPreferences = timeDisplayPreferences
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = Appearance.background
        full.backgroundColor = Appearance.background
        mini.backgroundColor = Appearance.navigation
        [full, mini].forEach(addSubview)
        [toolbar, pager, seek, position, duration, playRing, play, rewind, forward, skip, speedButton, speedLabel, rewindLabel, forwardLabel, loading, seekPreview].forEach(full.addSubview)
        toolbar.addSubview(back)
        toolbar.addSubview(favorite)
        toolbar.addSubview(share)
        toolbar.addSubview(sleepTimer)
        toolbar.addSubview(cast); cast.isHidden = true
        toolbar.addSubview(more)
        more.isHidden = true
        favorite.isHidden = true
        share.isHidden = true
        pager.addSubview(coverPage)
        pager.isPagingEnabled = true
        pager.delegate = self
        pager.showsVerticalScrollIndicator = false
        pager.contentInsetAdjustmentBehavior = .never
        [podcast, title, shownotes].forEach(coverPage.addSubview)
        coverPage.addSubview(chapterControl)
        chapterControl.addAction(UIAction { [weak self] _ in self?.showChapters?() }, for: .touchUpInside)
        [previousChapter, chaptersButton, nextChapter].forEach(chapterControl.addSubview)
        chapterControl.isHidden = true
        chaptersButton.setTitle(Appearance.text("chapters_label"), for: .normal)
        [previousChapter, nextChapter].forEach { $0.tintColor = Appearance.secondary; ($0 as? PlayerIconButton)?.padding = 6 }
        if let library, let chapterAccess {
            coverChapters = .init(surface: .cover, playback: playback, library: library, access: chapterAccess)
            seekChapters = .init(surface: .seekbar, playback: playback, library: library, access: chapterAccess, timePreferences: timeDisplayPreferences)
            coverChapters?.presentation.onChange = { [weak self] in self?.updateChapters() }
            seekChapters?.presentation.onChange = { [weak self] in self?.updateChapterDividers() }
        }
        [miniTitle, miniPodcast, miniTrack, open, miniPlay].forEach(mini.addSubview)
        miniTrack.addSubview(miniProgress)
        miniTrack.backgroundColor = Appearance.selected
        miniProgress.backgroundColor = Appearance.accent
        [miniTitle, miniPodcast].forEach { $0.numberOfLines = 1; $0.lineBreakMode = .byTruncatingTail }
        [podcast, title].forEach { $0.numberOfLines = 2; $0.textAlignment = .center }
        [podcast, position, rewindLabel, forwardLabel, speedLabel].forEach { $0.textColor = Appearance.secondary }
        [rewindLabel, forwardLabel, speedLabel].forEach { $0.textAlignment = .center }
        speedLabel.accessibilityIdentifier = "playerSpeedValue"
        rewindLabel.accessibilityIdentifier = "playerRewindValue"
        forwardLabel.accessibilityIdentifier = "playerForwardValue"
        rewind.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(editRewind(_:))))
        forward.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(editForward(_:))))
        rewind.accessibilityCustomActions = [UIAccessibilityCustomAction(name: Appearance.text("pref_rewind")) { [weak self] _ in self?.showIntervalDialog?(.rewind); return true }]
        forward.accessibilityCustomActions = [UIAccessibilityCustomAction(name: Appearance.text("pref_fast_forward")) { [weak self] _ in self?.showIntervalDialog?(.forward); return true }]
        updateIntervals(intervalPreferences?.value ?? .init())
        if let intervalPreferences {
            let events = intervalPreferences.events()
            intervalUpdates = Task { [weak self] in
                for await value in events { self?.updateIntervals(value) }
            }
        }
        (speedButton as? PlayerIconButton)?.padding = 8
        duration.contentHorizontalAlignment = .right
        duration.titleLabel?.font = Appearance.font(12)
        duration.titleLabel?.adjustsFontForContentSizeCategory = true
        duration.setTitleColor(Appearance.secondary, for: .normal)
        duration.addAction(UIAction { [weak self] _ in
            guard let self, playback.episode?.details.media != nil else { return }
            do {
                try timeDisplayPreferences.toggleRemainingTime()
                updatePosition()
            } catch { failure?(error) }
        }, for: .touchUpInside)
        position.accessibilityIdentifier = "playerPosition"
        duration.accessibilityIdentifier = "playerDuration"
        seek.accessibilityIdentifier = "playerSeek"
        seek.addAction(UIAction { [weak self] _ in self?.previewSeek() }, for: .valueChanged)
        seek.addAction(UIAction { [weak self] _ in self?.finishSeek() }, for: .editingDidEnd)
        seekPreview.backgroundColor = Appearance.navigation
        seekPreview.textAlignment = .center
        seekPreview.numberOfLines = 0
        seekPreview.layer.cornerRadius = 8
        seekPreview.clipsToBounds = true
        seekPreview.isHidden = true
        playRing.isUserInteractionEnabled = false
        loading.isUserInteractionEnabled = false
        loading.accessibilityIdentifier = "playerLoading"
        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
        // ViewPagerBottomSheetBehavior: a downward drag on the cover page (pager at its top) moves the sheet, as on
        // the toolbar; the pager scrolls only drags the sheet declines (upward, or on the show-notes page).
        pager.panGestureRecognizer.require(toFail: pan)
        mini.accessibilityElements = [open, miniPlay]
        (miniPlay as? PlayerIconButton)?.padding = 8
        (play as? PlayerIconButton)?.padding = 8
    }
    required init?(coder: NSCoder) { fatalError() }

    @discardableResult
    private func loadNotes() -> ShownotesWebView {
        if let notes { return notes }
        let notes = ShownotesWebView()
        notes.isOpaque = false
        notes.backgroundColor = Appearance.background
        notes.accessibilityIdentifier = "playerShownotesContent"
        notes.showLinkMenu = { [weak self] link, source in self?.showShownotesLinkMenu?(link, source) }
        notes.shareSelection = { [weak self] text, source in self?.shareShownotesSelection?(text, source) }
        notes.openLink = { [weak self] link in self?.openLink?(link) }
        notes.willPerformTextService = { [weak self] in self?.saveShownotesForExternalAction() }
        notes.restoreScrollOffset = { [weak self] in
            guard let self, let id = playback.episode?.id else { return 0 }
            return CGFloat(shownotesScroll.offset(for: id) ?? 0)
        }
        notes.failure = { [weak self] error in self?.failure?(error) }
        notes.selectTimecode = { [weak self] time in
            self?.perform { [weak self] in try await self?.playback.seek(to: Int64(time)) }
        }
        self.notes = notes
        pager.addSubview(notes)
        notes.frame = CGRect(x: 0, y: pager.bounds.height, width: pager.bounds.width, height: pager.bounds.height)
        if let episode = playback.episode { notes.show(episode) }
        setNeedsLayout()
        return notes
    }

    isolated deinit {
        intervalUpdates?.cancel(); coverChapters?.stop(); seekChapters?.stop(); chapterArtwork?.cancelLoading()
        if let scenePauseObserver { NotificationCenter.default.removeObserver(scenePauseObserver) }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let scenePauseObserver { NotificationCenter.default.removeObserver(scenePauseObserver) }
        scenePauseObserver = nil
        if let scene = window?.windowScene {
            scenePauseObserver = NotificationCenter.default.addObserver(forName: UIScene.willDeactivateNotification, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveShownotesIfActive() }
            }
        } else { saveShownotesIfActive() }
        coverChapters?.attach(to: window?.windowScene); seekChapters?.attach(to: window?.windowScene)
        if window == nil { chapterArtwork?.cancelLoading(); chapterArtworkKey = [] }
    }
    private func updateChapterDividers() {
        let state = seekChapters?.presentation
        let duration = state?.episode?.details.media?.durationMilliseconds ?? 0
        seek.chapterFractions = duration > 0 ? (state?.chapters ?? []).map { Float($0.startMilliseconds) / Float(duration) } : []
    }
    private func updateChapters() {
        let state = coverChapters?.presentation
        chapterControl.isHidden = state?.hasChapters != true
        let visible = state?.nextVisible ?? true
        nextChapter.alpha = visible ? 1 : 0; nextChapter.isUserInteractionEnabled = visible
        nextChapter.accessibilityElementsHidden = !visible
        let image = state?.currentChapter?.imageURL
        let episode = state?.episode
        let key = [episode.map { String($0.id) }, image, episode.flatMap { EpisodeArtworkSelection.source(episode:$0,feed:chapterFeed) }, episode?.details.media?.url,
                   episode?.userState.localFileURL, episode?.details.media.map { String($0.size) }, chapterFeed?.metadata.imageURL]
        if key != chapterArtworkKey {
            chapterArtworkKey = key; chapterArtwork?.cancelLoading(); chapterArtwork?.removeFromSuperview(); chapterArtwork = nil
            if let episode, let image, !image.isEmpty, let library, let chapterAccess {
                let view = ChapterArtworkView(reference: image, episode: episode, feed: chapterFeed, library: library, access: chapterAccess, coverFallback: true)
                view.accessibilityIdentifier = "playerChapterArtwork"
                togglesPlaybackOnTap(view)
                view.layer.cornerRadius = 16; coverPage.insertSubview(view, aboveSubview: artwork ?? podcast); chapterArtwork = view
            }
        }
        artwork?.isHidden = chapterArtwork != nil
        setNeedsLayout()
    }
    private func seekChapter(previous: Bool) {
        guard let state = coverChapters?.presentation, let episodeID = state.episode?.id else { return }
        let target = previous ? state.previousTarget(position: Int64(playback.sample?.positionMilliseconds ?? 0), speed: playback.speed) : state.nextTarget()
        guard let target else { return }
        perform { [weak self] in try await self?.playback.seekChapter(episodeID: episodeID, to: target, startPlayback: false) }
    }
    private func updateIntervals(_ value: PlaybackIntervalPreferences) {
        rewindLabel.text = value.rewindSeconds.formatted()
        forwardLabel.text = value.forwardSeconds.formatted()
        rewind.accessibilityValue = "\(value.rewindSeconds.formatted()) \(Appearance.text("time_seconds"))"
        forward.accessibilityValue = "\(value.forwardSeconds.formatted()) \(Appearance.text("time_seconds"))"
    }
    @objc private func editRewind(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { showIntervalDialog?(.rewind) }
    }
    @objc private func editForward(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { showIntervalDialog?(.forward) }
    }

    /// What a full player update shows besides the position: each second's tick changes only the
    /// position, which needs no new labels, images, artwork or layout.
    private struct Shown: Equatable {
        let feed: LibraryFeed?
        let episodeID: Int64?, details: ParsedEpisode?
        let wantsPlayback: Bool, buffering: Bool, speed: Float, timer: Bool, useEpisodeCover: Bool
    }
    private var shown: Shown?
    private(set) var fullUpdates = 0
    private static var speedFormatter: (locale: Locale, formatter: NumberFormatter)?
    private static func formattedSpeed(_ speed: Float) -> String? {
        if speedFormatter?.locale != .current {
            let formatter = NumberFormatter()
            formatter.locale = .current; formatter.minimumFractionDigits = 2; formatter.maximumFractionDigits = 2
            formatter.usesGroupingSeparator = false; formatter.roundingMode = .halfEven
            speedFormatter = (.current, formatter)
        }
        return speedFormatter?.formatter.string(from: NSNumber(value: speed))
    }

    func update(feed: LibraryFeed?) {
        let next = Shown(feed: feed, episodeID: playback.episode?.id, details: playback.episode?.details,
            wantsPlayback: playback.wantsPlayback, buffering: playback.isBuffering, speed: playback.speed,
            timer: playback.sleepTimerValue != nil, useEpisodeCover: useEpisodeCover)
        if next == shown {
            let before = fraction
            updatePosition()
            if fraction != before { layoutMiniProgress() }
            return
        }
        shown = next
        fullUpdates += 1
        chapterFeed = feed
        let timerActive = playback.sleepTimerValue != nil
        sleepTimer.setImage(UIImage(named: timerActive ? "ic_sleep_off" : "ic_sleep"), for: .normal)
        sleepTimer.accessibilityLabel = Appearance.text(timerActive ? "sleep_timer_label" : "set_sleeptimer_label")
        guard let episode = playback.episode else {
            updateFavorite(nil)
            overflowContext = nil; more.isHidden = true
            shareContext = nil
            share.isHidden = true
            setNeedsLayout()
            return
        }
        overflowContext = feed.flatMap { feed in feed.episodes.first(where: { $0.id == episode.id }).map { (feed, $0) } }
        more.isHidden = overflowContext == nil
        if let feed, !feed.source.isLocalFeedSource,
           let stored = feed.episodes.first(where: { $0.id == episode.id }) {
            shareContext = (feed, stored)
        } else { shareContext = nil }
        share.isHidden = shareContext == nil
        // Playback keeps a position snapshot. Library mutations can be newer than that snapshot.
        updateFavorite(feed?.episodes.first { $0.id == episode.id })
        speedLabel.text = Self.formattedSpeed(playback.speed)
        speedButton.accessibilityValue = speedLabel.text
        let source = EpisodeArtworkSelection.source(episode: episode, feed: feed)
        let nextArtworkKey = [source, feed?.metadata.imageURL, feed?.title, episode.details.media.map { String($0.size) }, String(useEpisodeCover)]
        if episodeID != episode.id || artworkKey != nextArtworkKey {
            artworkKey = nextArtworkKey
            miniArtwork?.cancelLoading(); miniArtwork?.removeFromSuperview()
            artwork?.cancelLoading(); artwork?.removeFromSuperview()
            miniArtwork = EpisodeArtworkView(feed: feed, episode: episode, library: library, surface: .miniPlayer, useEpisodeCover: useEpisodeCover)
            artwork = EpisodeArtworkView(feed:feed,episode:episode,library:library,presentation:.chapterCover)
            artwork?.accessibilityIdentifier = "playerCoverArtwork"
            miniArtwork?.accessibilityIdentifier = "miniPlayerArtwork"
            if let miniArtwork { mini.insertSubview(miniArtwork, at: 0) }
            if let artwork {
                artwork.layer.cornerRadius = 16
                artwork.clipsToBounds = true
                togglesPlaybackOnTap(artwork)
                coverPage.insertSubview(artwork, at: 0)
            }
        }
        notes?.show(episode)
        episodeID = episode.id
        miniTitle.text = episode.details.title
        miniPodcast.text = feed?.title
        title.text = episode.details.title
        podcast.text = [feed?.title, EpisodeRowPresentation.publicationDate(episode.details.publicationDate)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\u{00a0}・\u{00a0}")
        open.accessibilityLabel = [episode.details.title, feed?.title].compactMap { $0 }.joined(separator: ". ")
        for button in [play, miniPlay] {
            button.setImage(UIImage(named: playback.wantsPlayback ? "ic_pause" : "ic_play_48dp"), for: .normal)
            button.accessibilityLabel = Appearance.text(playback.wantsPlayback ? "pause_label" : "play_label")
        }
        if playback.isBuffering { loading.startAnimating() }
        else { loading.stopAnimating() }
        updatePosition()
        updateChapters()
        setNeedsLayout()
    }

    private func updateFavorite(_ episode: LibraryEpisode?) {
        favoriteEpisode = episode
        favorite.isHidden = episode == nil || library == nil
        favorite.isEnabled = !favoriteWriteInFlight
        let selected = episode?.userState.isFavorite == true
        favorite.setImage(UIImage(named: selected ? "ic_star" : "ic_star_border"), for: .normal)
        favorite.accessibilityLabel = Appearance.text(selected ? "remove_from_favorite_label" : "add_to_favorite_label")
        favorite.accessibilityTraits = selected ? [.button, .selected] : [.button]
    }

    private func changeFavorite() {
        guard let library, let episode = favoriteEpisode, !favoriteWriteInFlight else { return }
        favoriteWriteInFlight = true
        favorite.isEnabled = false
        perform { [weak self] in
            guard let self else { return }
            defer { favoriteWriteInFlight = false; favorite.isEnabled = true }
            // Execute the displayed Add/Remove command against the captured episode, even if playback advances.
            try await library.setFavorite(episodeID: episode.id, favorite: !episode.userState.isFavorite)
            let saved = try await library.episode(id: episode.id)
            if playback.episode?.id == episode.id { updateFavorite(saved) }
            await favoriteChanged?()
        }
    }

    private func shareCurrentEpisode() {
        guard let context = shareContext else { return }
        var episode = context.episode
        // The library's five-second checkpoint can lag the displayed player position.
        // Capture this selection and position once for the lifetime of the share dialog.
        if playback.episode?.id == episode.id {
            episode.userState.positionMilliseconds = playback.sample?.positionMilliseconds
                ?? playback.episode?.userState.positionMilliseconds ?? episode.userState.positionMilliseconds
        }
        showShare?(context.feed, episode, share)
    }

    private func updatePosition() {
        let sample = playback.sample
        let value = sample?.positionMilliseconds ?? playback.episode?.userState.positionMilliseconds ?? 0
        let length = sample?.durationMilliseconds ?? playback.episode?.details.media?.durationMilliseconds ?? 0
        let percent = length > 0 ? min(100, max(0, Int(Double(value) / Double(length) * 100))) : 0
        fraction = CGFloat(percent) / 100
        guard let times = PlayerTimePresentation(position: value, duration: length,
                                                 showRemainingTime: timeDisplayPreferences.value.showRemainingTime,
                                                 speed: playback.speed,
                                                 timeRespectsSpeed: timeDisplayPreferences.value.timeRespectsSpeed) else { return }
        position.text = times.position
        duration.setTitle(times.length, for: .normal)
        duration.accessibilityLabel = Appearance.durationDescription(times.lengthAccessibilityKey, milliseconds: times.lengthMilliseconds)
        if !seek.isTracking { seek.value = length > 0 ? Float(Int(Float(value) / Float(length) * 500)) : 0 }
        seek.isEnabled = sample?.seekable == true && length > 0 && playback.phase != .stopped
    }

    func setExpanded(_ expanded: Bool, animated: Bool = true) {
        if expanded, playback.videoPresentation?.videoDisplayLayer != nil || playback.episode?.details.media?.mimeType?.hasPrefix("video/") == true, let showVideo {
            showVideo(); return
        }
        if expanded { loadNotes() }
        let changes = {
            self.expansion = expanded ? 1 : 0
            if !expanded {
                self.resetShownotesForPageNavigation()
                self.pager.setContentOffset(.zero, animated: false)
            }
            self.expansionChanged?()
            self.layoutIfNeeded()
        }
        if animated {
            UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut], animations: changes) { [weak self] _ in
                self?.releaseCollapsedNotes()
            }
        } else { changes(); releaseCollapsedNotes() }
        UIAccessibility.post(notification: .layoutChanged, argument: expanded ? back : open)
    }

    /// A collapsed player keeps no WebKit process for iOS to reclaim: its notes are built again when it opens, at
    /// their top as after every collapse (the saved position was reset with them).
    private func releaseCollapsedNotes() {
        guard expansion == 0, let notes else { return }
        notes.removeFromSuperview(); self.notes = nil
        notesPageActive = false
    }

    private func saveShownotesScroll() {
        guard let id = playback.episode?.id else { return }
        guard let notes else { return }
        do { try shownotesScroll.save(episodeID: id, offset: Double(notes.scrollView.contentOffset.y)) }
        catch { failure?(error) }
    }

    // Android pauses its description fragment for system choosers/text services.
    // Apple can present these within the active scene, so checkpoint at handoff.
    func saveShownotesForExternalAction() { saveShownotesIfActive() }

    private func saveShownotesIfActive() {
        if notesPageActive { saveShownotesScroll() }
    }

    private func resetShownotesForPageNavigation() {
        notes?.scrollToTopForPageNavigation()
        saveShownotesScroll()
    }

    private func updateShownotesPageState() {
        let active = expansion == 1 && pager.bounds.height > 0 && pager.contentOffset.y > pager.bounds.height / 2
        if notesPageActive && !active { saveShownotesScroll() }
        notesPageActive = active
        notes?.visibilityMayHaveChanged()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Notes whose process ended are rebuilt as soon as the page turn reveals them.
        if scrollView === pager { notes?.visibilityMayHaveChanged() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if scrollView === pager { updateShownotesPageState() }
    }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if scrollView === pager { updateShownotesPageState() }
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if scrollView === pager && !decelerate { updateShownotesPageState() }
    }

    private func layoutMiniProgress() {
        miniProgress.frame = CGRect(x: effectiveUserInterfaceLayoutDirection == .rightToLeft ? miniTrack.bounds.width * (1 - fraction) : 0,
                                    y: 0, width: miniTrack.bounds.width * fraction, height: miniTrack.bounds.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        loading.outOfSight = expansion == 0
        full.frame = CGRect(origin: .zero, size: expandedSize)
        mini.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 64)
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let miniLayout = MiniPlayerLayout(width: bounds.width, rightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft, scale: scale)
        miniArtwork?.frame = miniLayout.cover
        miniPlay.frame = miniLayout.play
        open.frame = miniLayout.open
        let textHeight = miniTitle.font.lineHeight + miniPodcast.font.lineHeight
        miniTitle.frame = CGRect(x: miniLayout.text.minX, y: (miniLayout.text.height - textHeight) / 2, width: miniLayout.text.width, height: miniTitle.font.lineHeight)
        miniPodcast.frame = miniTitle.frame.offsetBy(dx: 0, dy: miniTitle.font.lineHeight)
        miniTrack.frame = miniLayout.progress
        layoutMiniProgress()
        let available = CGSize(width: max(1, (expandedSize.width - 16) / (expandedSize.width > expandedSize.height ? 2 : 1)), height: .greatestFiniteMagnitude)
        let layout = PlayerLayout(size: expandedSize, topInset: topInset,
            podcastHeight: podcast.sizeThatFits(available).height + 4, titleHeight: title.sizeThatFits(available).height + 4,
            timeHeight: position.font.lineHeight + 2, scale: scale, hasChapters: !chapterControl.isHidden,
            rightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft)
        toolbar.frame = layout.toolbar
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        back.frame = CGRect(x: rtl ? toolbar.bounds.width - 56 : 0, y: 4, width: 56, height: 56)
        // Android's trailing group: favorite, sleep, Cast, share (48 each), overflow (40).
        // A local feed has no Share action; Android removes that slot from the group.
        let trailingFavoriteSpace: CGFloat = share.isHidden ? 136 : 184
        favorite.frame = CGRect(x: rtl ? trailingFavoriteSpace : toolbar.bounds.width - trailingFavoriteSpace - 48, y: 8, width: 48, height: 48)
        sleepTimer.frame = CGRect(x: rtl ? trailingFavoriteSpace - 48 : toolbar.bounds.width - trailingFavoriteSpace, y: 8, width: 48, height: 48)
        cast.frame = CGRect(x: rtl ? trailingFavoriteSpace - 96 : toolbar.bounds.width - trailingFavoriteSpace + 48, y: 8, width: 48, height: 48)
        more.frame = CGRect(x: rtl ? 0 : toolbar.bounds.width - 40, y: 8, width: 40, height: 48)
        share.frame = CGRect(x: rtl ? 40 : toolbar.bounds.width - 88, y: 8, width: 48, height: 48)
        let showingNotes = pager.contentOffset.y > pager.bounds.height / 2
        pager.frame = layout.pager
        pager.contentSize = CGSize(width: pager.bounds.width, height: pager.bounds.height * 2)
        coverPage.frame = pager.bounds.offsetBy(dx: -pager.bounds.minX, dy: -pager.bounds.minY)
        if expansion > 0 { loadNotes() }
        notes?.frame = CGRect(x: 0, y: pager.bounds.height, width: pager.bounds.width, height: pager.bounds.height)
        if !pager.isDragging && !pager.isDecelerating { pager.contentOffset.y = showingNotes ? pager.bounds.height : 0 }
        artwork?.frame = layout.artwork
        chapterArtwork?.frame = layout.artwork
        podcast.frame = layout.podcast
        title.frame = layout.title
        shownotes.frame = layout.shownotes
        shownotes.setTitle(Appearance.text("shownotes_label"), for: .normal)
        shownotes.layer.borderColor = Appearance.secondary.resolvedColor(with: traitCollection).cgColor
        shownotes.layer.borderWidth = 1
        shownotes.layer.cornerRadius = 8
        chapterControl.frame = layout.chapterControl ?? .zero
        chapterControl.layer.borderColor = Appearance.secondary.resolvedColor(with: traitCollection).cgColor
        chapterControl.layer.borderWidth = 1; chapterControl.layer.cornerRadius = 8
        let arrowWidth = min(36, chapterControl.bounds.width / 2)
        previousChapter.frame = CGRect(x: rtl ? chapterControl.bounds.width - arrowWidth : 0, y: 0, width: arrowWidth, height: 36)
        nextChapter.frame = CGRect(x: rtl ? 0 : chapterControl.bounds.width - arrowWidth, y: 0, width: arrowWidth, height: 36)
        chaptersButton.frame = CGRect(x: arrowWidth, y: 0, width: max(0, chapterControl.bounds.width - 2 * arrowWidth), height: 36)
        seek.frame = layout.seek
        position.frame = CGRect(x: layout.times.minX, y: layout.times.minY, width: layout.times.width / 2, height: layout.times.height)
        duration.frame = position.frame.offsetBy(dx: layout.times.width / 2, dy: 0)
        play.frame = layout.play
        rewind.frame = layout.rewind
        forward.frame = layout.forward
        skip.frame = layout.skip
        speedButton.frame = layout.speed
        speedLabel.frame = CGRect(x: layout.speed.minX, y: layout.speed.maxY, width: layout.speed.width, height: speedLabel.font.lineHeight)
        rewindLabel.frame = CGRect(x: rewind.frame.minX, y: play.frame.maxY - rewindLabel.font.lineHeight, width: rewind.frame.width, height: rewindLabel.font.lineHeight)
        forwardLabel.frame = rewindLabel.frame.offsetBy(dx: forward.frame.minX - rewind.frame.minX, dy: 0)
        playRing.frame = play.frame
        loading.frame = play.frame
        let previewText = seekPreview.sizeThatFits(CGSize(width: max(1, bounds.width - 80), height: .greatestFiniteMagnitude))
        let previewWidth = min(max(0, bounds.width - 32), previewText.width + 48), previewHeight = previewText.height + 8
        seekPreview.frame = CGRect(x: (bounds.width - previewWidth) / 2, y: pager.frame.maxY - 12 - previewHeight, width: previewWidth, height: previewHeight)
        let transition = PlayerSheetTransition(expansion: expansion)
        mini.alpha = transition.miniPlayerAlpha
        mini.isHidden = transition.miniPlayerAlpha < 0.01
        mini.accessibilityElementsHidden = expansion > 0
        toolbar.alpha = transition.toolbarAlpha
        full.accessibilityElementsHidden = expansion < 1
        if !pager.isDragging && !pager.isDecelerating { updateShownotesPageState() }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        guard abs(velocity.y) > abs(velocity.x) else { return false }
        if expansion == 0 { return velocity.y < 0 }
        let point = pan.location(in: self)
        return velocity.y > 0 && (point.y <= toolbar.frame.maxY || pager.contentOffset.y <= 0) && !seek.isTracking
    }

    @objc private func drag(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began { dragStart = expansion }
        let distance = max(1, expandedSize.height - 64)
        if pan.state == .began || pan.state == .changed {
            expansion = min(1, max(0, dragStart - pan.translation(in: superview).y / distance))
            if expansion > 0 { loadNotes() }
            expansionChanged?()
        } else if pan.state == .ended {
            let velocity = pan.velocity(in: superview)
            setExpanded(PlayerSheetTransition.expandsAfterRelease(expansion: expansion,
                        velocity: CGSize(width: velocity.x, height: velocity.y)))
        } else if pan.state == .cancelled { setExpanded(dragStart >= 0.5) }
    }

    private func button(_ image: String?, label: String, id: String, action: @escaping () -> Void) -> UIButton {
        let button = PlayerIconButton(type: .custom)
        button.setImage(image.flatMap { UIImage(named: $0) }, for: .normal)
        button.tintColor = Appearance.foreground
        button.setTitleColor(Appearance.secondary, for: .normal)
        button.titleLabel?.font = Appearance.font(16)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = id
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func toggle() { perform { [weak self] in try await self?.playback.toggle() } }
    /// CoverFragment.imgvCover: tapping the cover pauses while playing and plays otherwise. Touch only, as on
    /// Android, where the cover is not important for accessibility; VoiceOver uses the play button.
    private func togglesPlaybackOnTap(_ view: UIView) {
        view.isUserInteractionEnabled = true
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(coverTapped)))
    }
    @objc func coverTapped() { toggle() }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task { [weak self] in do { try await action() } catch { self?.failure?(error) } }
    }
    private func previewSeek() {
        let duration = playback.sample?.durationMilliseconds ?? 0
        let preview = Int32(Float(duration) * seek.value / 500)
        let converted = PlaybackSpeed.displayTime(preview, speed: playback.speed, respectsSpeed: timeDisplayPreferences.value.timeRespectsSpeed)
        let state = seekChapters?.presentation
        let index = ChapterPlaybackRules.currentIndex(in: state?.chapters, positionMilliseconds: Int64(converted))
        let chapter = index >= 0 ? state?.chapters?[index] : nil
        let time = EpisodeRowPresentation.time(converted)
        seekPreview.text = chapter.map { ($0.title ?? "") + "\n" + time } ?? time
        if !seek.isHighlighted, let chapter, index != state?.selectedIndex, let episodeID = state?.episode?.id {
            seekedToChapterStart = true
            seek.highlightCurrentChapter()
            perform { [weak self] in try await self?.playback.seekChapter(episodeID: episodeID, to: chapter.startMilliseconds, startPlayback: false) }
        }
        seekPreview.isHidden = false
        setNeedsLayout()
    }
    private func finishSeek() {
        seekPreview.isHidden = true
        if seekedToChapterStart { seekedToChapterStart = false; return }
        let target = Int64(Float(playback.sample?.durationMilliseconds ?? 0) * seek.value / 500)
        perform { [weak self] in try await self?.playback.seek(to: target) }
    }
}

@MainActor
private final class PlayerIconButton: UIButton {
    var padding: CGFloat = 0
    override func layoutSubviews() {
        super.layoutSubviews()
        guard currentTitle == nil, let size = currentImage?.size, size.width > 0, size.height > 0 else { return }
        let available = bounds.insetBy(dx: padding, dy: padding)
        let scale = max(0, min(1, available.width / size.width, available.height / size.height))
        imageView?.frame = CGRect(x: bounds.midX - size.width * scale / 2, y: bounds.midY - size.height * scale / 2,
                                 width: size.width * scale, height: size.height * scale)
    }
}
