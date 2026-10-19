import UIKit
import NotTennaPodCore

// Episode selection, list actions, sharing and the episode context menu.
extension LibraryViewController {
    func startFeedSelection(_ episodeID: Int64) {
        guard let scope = currentSelectionScope, feedSelectionIDs.contains(episodeID) else { return }
        if case .feed(let id) = scope {
            guard let feed = feeds.first(where: { $0.id == id }), feed.subscriptionState != .notSubscribed else { return }
        }
        selectionScope = scope; feedSelection.start(episodeID)
        feedSelectionBar.resetScroll(); updateFeedSelection()
    }

    func endFeedSelection() {
        feedSelection.end(); selectionScope = nil; updateFeedSelection()
    }

    @discardableResult func toggleFeedSelection(_ episodeID: Int64) -> Bool {
        guard let scope = currentSelectionScope, selectionScope == scope, feedSelection.active else { return false }
        feedSelection.toggle(episodeID); updateFeedSelection(); return true
    }

    func updateFeedSelection() {
        allEpisodesFilterLabel.isHidden = !allEpisodesVisible || !allEpisodesFilter.effective.isActive || feedSelection.active
        guard let scope = currentSelectionScope else {
            feedSelection.end(); selectionScope = nil; feedSelectionBar.isHidden = true
            updateFeedPageFooter(); return
        }
        if selectionScope != scope { feedSelection.end(); selectionScope = nil }
        if queueVisible && feedSelection.active { queueDragController?.cancel() }
        queueInformationLabel.isHidden = !queueVisible || !queuePolicy.showsInformation
        for (episode, row) in episodeRows.values {
            row.setSelected(feedSelection.active && feedSelection.ids.contains(episode.id), selectionMode: feedSelection.active)
            if queueVisible { row.setQueueInteraction(queuePolicy) }
        }
        let shownBar = toolbar.subviews.first { $0.accessibilityIdentifier == "feedSelectionToolbar" }
        if feedSelection.active {
            let items = episodeListItems(feedSelection.selected(displayed: feedSelectionIDs))
            if !items.isEmpty {
                feedSelectionBar.update(actions: EpisodeListMenu.actions(items, selection: true, bulkInbox: scope.bulkInbox),
                    hasMedia: items.count != 1 || items[0].episode.details.media != nil,
                    queueMoves: queueVisible ? [.top, .bottom].filter { queuePolicy.canMove(feedSelection.selected(displayed: feedSelectionIDs), in: queuedEpisodes.map(\.id), to: $0, bulk: true) } : [])
            }
            // The toolbar on screen keeps its views; only its count changes (`ActionMode.setTitle`), so a download's
            // progress each second never takes a tap or VoiceOver's focus from it. A new width draws the screen again.
            if let count = shownBar?.subviews.first(where: { $0.accessibilityIdentifier == "episodeSelectionCount" }) as? UILabel {
                count.text = String(format: Appearance.text("num_selected_label"), feedSelection.ids.count, feedSelectionIDs.count)
                updateFeedPageFooter(); return
            }
        }
        shownBar?.removeFromSuperview()
        toolbar.accessibilityElements = nil
        if feedSelection.active {
            let bar = UIView(frame: toolbar.bounds); bar.backgroundColor = Appearance.navigation
            bar.accessibilityIdentifier = "feedSelectionToolbar"
            let layout = toolbarLayout(hasOverflow: true, forceNavigation: true)
            let close = Appearance.icon("abc_ic_ab_back_material", label: Appearance.text("close_label")) { [weak self] in self?.endFeedSelection() }
            close.configuration?.image = UIImage(named: "abc_ic_ab_back_material")?.imageFlippedForRightToLeftLayoutDirection()
            close.accessibilityIdentifier = "endEpisodeSelection"; close.frame = layout.navigation
            let title = Appearance.label(String(format: Appearance.text("num_selected_label"), feedSelection.ids.count, feedSelectionIDs.count), size: 20)
            title.numberOfLines = 1; title.frame = layout.title; title.accessibilityIdentifier = "episodeSelectionCount"
            let more = Appearance.icon("dots_vertical", label: Appearance.text("overflow_more")) { [weak self, weak bar] in
                guard let self, let bar else { return }
                let keys = ["select_toggle", "select_all_above", "select_all_below"]
                let labels = [feedSelection.ids.count == feedSelectionIDs.count ? "deselect_all_label" : "select_all_label", "select_all_above", "select_all_below"]
                let menu = PopupMenuController(title: "", identifier: "episodeSelectionOptions", anchor: bar,
                    anchorFraction: CGPoint(x: bar.effectiveUserInterfaceLayoutDirection == .rightToLeft ? 0 : 1, y: 1),
                    actions: zip(keys, labels).map { ($0.0, Appearance.text($0.1)) }) { [weak self] key in
                        self?.changeFeedSelection(key)
                    }
                present(menu, animated: true)
            }
            more.accessibilityIdentifier = "episodeSelectionMore"; more.frame = layout.overflow
            [close, title, more].forEach(bar.addSubview); toolbar.addSubview(bar); toolbar.accessibilityElements = [bar]
        }
        updateFeedPageFooter()
    }

    func changeFeedSelection(_ key: String) {
        switch key {
        case "select_toggle": feedSelection.toggleAll(displayed: feedSelectionIDs)
        case "select_all_above": feedSelection.above(displayed: feedSelectionIDs)
        case "select_all_below": feedSelection.below(displayed: feedSelectionIDs)
        default: return
        }
        updateFeedSelection()
    }

    /// `home`: the Home section of the row or card pressed (its menu's identity).
    func showListEpisodeMenu(_ id: Int64, feedID: Int64, anchor: UIView, fraction: CGPoint, home: EpisodeSelectionScope? = nil) {
        guard let scope = currentSelectionScope ?? home, !feedSelection.active,
              let captured = captureAction(id), let feed = feeds.first(where: { $0.id == feedID }) else { return }
        let item = contextItem(captured.model), episode = item.episode
        let onHome: Bool = if case .destination(.home) = path.last { true } else { false }
        let actions = EpisodeListMenu.actions([item], selection: false).filter {
            // Home lists hide multi-select (source menu XML); feed lists hide it for previews.
            $0 != .multiSelect || (!onHome && (scope != .feed(feedID) || feed.subscriptionState != .notSubscribed))
        }
        let moves: [QueueBoundary] = scope == .queue ? [.top, .bottom].filter {
            queuePolicy.canMove([id], in: queuedEpisodes.map(\.id), to: $0, bulk: false)
        } : []
        let entries = moves.map { ("queue-" + $0.rawValue, Appearance.text($0 == .top ? "move_to_top_label" : "move_to_bottom_label")) }
            + actions.map { ($0.rawValue, Appearance.text($0.titleKey(hasMedia: episode.details.media != nil))) }
        present(PopupMenuController(title: episode.details.title ?? "", identifier: scope.contextIdentifier,
            anchor: anchor, anchorFraction: fraction, actions: entries) { [weak self] key in
                if key.hasPrefix("queue-"), let boundary = QueueBoundary(rawValue: String(key.dropFirst(6))) {
                    // The episode moves in the queue as it is at the tap (`DBWriter.moveQueueItemToTop/Bottom` by id).
                    self?.moveQueue(to: boundary, ids: [id], bulk: false); return
                }
                guard let action = EpisodeListAction(rawValue: key) else { return }
                if action == .multiSelect { self?.startFeedSelection(id) }
                else { self?.performEpisodeListAction(action, ids: [id], captured: action == .removeInbox ? captured : nil) }
            }, animated: true)
    }

    func episodeListItems(_ ids: [Int64]) -> [EpisodeListItem] {
        let queued = mirror.queuedIDs
        return ids.compactMap { id in
            guard let (feed, storedEpisode) = libraryEpisode(id) else { return nil }
            let episode = actionBindings[id]?.model.snapshot().episode ?? storedEpisode
            return EpisodeListItem(episode: episode, local: feed.source.isLocalFeedSource,
                subscription: feed.subscriptionState, queued: queued.contains(id),
                downloading: downloads?.activeJob(source: episode.details.media?.url) != nil)
        }
    }

    /// The task ends when the action is over, after the person answered a local folder's delete warning.
    @discardableResult
    func performEpisodeListAction(_ action: EpisodeListAction, ids: [Int64], confirmedLocalDelete: Bool = false, selection: Bool = false, resetPosition: Bool = true, captured: CapturedAction? = nil, guardedSwipe: Bool = false) -> Task<Void, Never>? {
        guard let library, let downloads, let playback else { return nil }
        let capturedItem = captured?.model.snapshot()
        return Task { [self] in
            do {
                let queue = try await library.queue()
                // A captured item's queue membership is the queue's now: the model's may predate a queue change, which would
                // veto an Add to queue settled after it.
                var items: [EpisodeListItem] = capturedItem.map { item in [.init(episode: item.episode, local: item.local,
                    subscription: item.subscription, queued: queue.contains { $0.id == item.episode.id }, downloading: item.downloading)] } ?? []
                for id in capturedItem == nil ? ids : [] {
                    guard let episode = try await library.episode(id: id),
                          let feed = try await library.listedFeedHeader(id: library.feedID(forEpisode: id)) else { continue }
                    items.append(.init(episode: episode, local: feed.source.isLocalFeedSource, subscription: feed.subscriptionState,
                        queued: queue.contains { $0.id == id }, downloading: downloads.activeJob(source: episode.details.media?.url) != nil))
                }
                guard !items.isEmpty else { showEpisodeActionMessage(Appearance.text("no_items_selected_message")); return }
                if action == .delete && !confirmedLocalDelete && items.contains(where: \.local) {
                    await withCheckedContinuation { (answered: CheckedContinuation<Void, Never>) in
                        // Answered by either button, by cancelling, or by the warning going away unanswered.
                        let answer = LocalDeleteAnswer(answered)
                        let warning = SourceMessageController(title: Appearance.text("delete_label"), message: Appearance.text("delete_local_feed_confirmation_dialog_message"),
                            positive: .init(title: Appearance.text("delete_label"), identifier: "confirmLocalEpisodeDelete", perform: { [weak self] in
                                let deletion = self?.performEpisodeListAction(action, ids: ids, confirmedLocalDelete: true, selection: selection, captured: captured, guardedSwipe: guardedSwipe)
                                Task { await deletion?.value; answer.resume() }
                            }, performAfterDismiss: true),
                            negative: .init(title: Appearance.text("cancel_label"), identifier: "cancelLocalEpisodeDelete", perform: { answer.resume() }))
                        warning.onCancel = { answer.resume() }
                        present(warning, animated: true)
                    }
                    return
                }
                if action == .share {
                    let episode = items[0].episode
                    guard let feed = try await library.listedFeedHeader(id: library.feedID(forEpisode: episode.id)) else { return }
                    presentEpisodeShare(feed: feed, episode: episode); return
                }
                let executor = EpisodeListActionExecutor(store: library,
                    download: { try await downloads.requestBatch(episodeID: $0) },
                    delete: { [self] id in
                        if guardedSwipe {
                            guard let target = captured?.deletionTarget else { throw FeedLibraryError.invalidMutation }
                            switch target.media {
                            case .local:
                                guard let localFolders else { throw FeedLibraryError.invalidMutation }
                                _ = try await localFolders.deleteMedia(target: target, playback: playback, removeFromQueue: downloads.deletionRemovesFromQueue)
                            case .remote: _ = try await downloads.deleteDownloadedMedia(target: target, playback: playback)
                            }
                            return
                        }
                        let feedID = try await library.feedID(forEpisode: id)
                        if try await library.listedFeedHeader(id: feedID)?.source.isLocalFeedSource == true {
                            guard let localFolders else { throw FeedLibraryError.invalidMutation }
                            try await localFolders.deleteMedia(episodeID: id, playback: playback, removeFromQueue: downloads.deletionRemovesFromQueue)
                        } else if let episode = try await library.episode(id: id), episode.userState.isDownloaded {
                            try await downloads.deleteDownloadedMedia(episodeID: id, playback: playback)
                        } else { try await downloads.cancel(episodeID: id) }
                    }, reset: { try await playback.resetPlaybackPosition(episodeID: $0) })
                if captured != nil { try await beforeEpisodeActionCommit?() }
                let count = try await executor.perform(action, items: items, resetPosition: resetPosition, selection: selection)
                // The write's receipt, read as it returns: what fences this result later.
                let receipt = library.changes.emitted
                actionMutationRevision &+= 1
                if !selection, action == .removeInbox, let captured {
                    reconcileCommittedAction(captured, delta: .init(playState: .unplayed), receipt: receipt)
                    scheduleMediaDeletionAfterMark(captured)
                } else {
                    if (!selection && action == .removeInbox)
                        || (!resetPosition && (action == .markPlayed || action == .markUnplayed)) {
                        for item in items { scheduleMediaDeletionAfterMark(item) }
                    }
                    await reloadLibrary()?.value
                }
                if selection && count != 1, let key = action.messageKey { showEpisodeActionMessage(String.localizedStringWithFormat(Appearance.text(key), count)) }
            } catch { showError(error) }
        }
    }

    private func scheduleMediaDeletionAfterMark(_ captured: CapturedAction) {
        guard let downloads, let playback else { return }
        let localFolders = self.localFolders
        lastEpisodeActionDeletion = downloads.deleteAfterMark(model: captured.model,
            target: captured.deletionTarget, wait: episodeActionDeletionWait) { target in
            switch target.media {
            case .local:
                guard let localFolders else { throw FeedLibraryError.invalidMutation }
                return try await localFolders.deleteMedia(target: target, playback: playback,
                    removeFromQueue: downloads.deletionRemovesFromQueue)
            case .remote:
                return try await downloads.deleteDownloadedMedia(target: target, playback: playback)
            }
        }
    }

    private func scheduleMediaDeletionAfterMark(_ item: EpisodeListItem) {
        guard let downloads, let playback else { return }
        let localFolders = self.localFolders
        downloads.deleteAfterMark(item) { id, local in
            if local {
                guard let localFolders else { throw FeedLibraryError.invalidMutation }
                try await localFolders.deleteMedia(episodeID: id, playback: playback,
                    removeFromQueue: downloads.deletionRemovesFromQueue)
            } else { try await downloads.deleteDownloadedMedia(episodeID: id, playback: playback) }
        }
    }

    func showEpisodeActionMessage(_ message: String) {
        // Both routes are source MainActivity MessageEvent snackbar recipients.
        if showSnackbar(message) { visibleSnackbar?.accessibilityIdentifier = "episodeActionSnackbar" }
    }

    func presentShownotesSelectionShare(_ text: String, source: ShownotesWebView) {
        guard presentedViewController == nil, let anchor = visibleShareAnchor(source) else { return }
        let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = anchor
        activity.popoverPresentationController?.sourceRect = (anchor as? ShownotesWebView)?.linkShareAnchorRect ?? anchor.bounds
        presentShareActivity(activity)
    }

    func presentShownotesLinkMenu(_ destination: String, source: ShownotesWebView) {
        guard presentedViewController == nil else { return }
        let callable = URL(string: destination).map { UIApplication.shared.canOpenURL($0) } ?? false
        let menu = ShownotesLinkMenu(destination: destination, canOpenInBrowser: callable)
        present(ShownotesLinkMenuController(menu: menu) { [weak self, weak source] action in
            guard let self else { return }
            switch action {
            case .openInBrowser: openWebsite(menu.destination)
            case .copyURL: UIPasteboard.general.string = menu.destination
            case .goToPosition:
                if let time = menu.positionMilliseconds { source?.selectTimecode?(time) }
            case .shareURL:
                let activity = UIActivityViewController(activityItems: [menu.destination], applicationActivities: nil)
                let anchor = visibleShareAnchor(source) ?? toolbar
                activity.popoverPresentationController?.sourceView = anchor
                activity.popoverPresentationController?.sourceRect = (anchor as? ShownotesWebView)?.linkShareAnchorRect ?? anchor.bounds
                presentShareActivity(activity)
            }
        }, animated: true)
    }

    func presentEpisodeShare(feed: LibraryFeed, episode: LibraryEpisode, anchor: UIView? = nil) {
        guard presentedViewController == nil else { return }
        present(EpisodeShareController(feed: feed, episode: episode) { [weak self, weak anchor] value in
            guard let self else { return }
            let activity = UIActivityViewController(activityItems: [value], applicationActivities: nil)
            let source = visibleShareAnchor(anchor) ?? toolbar
            activity.popoverPresentationController?.sourceView = source
            activity.popoverPresentationController?.sourceRect = source.bounds
            presentShareActivity(activity)
        }, animated: true)
    }

    func presentShareActivity(_ activity: UIActivityViewController) {
        guard presentedViewController == nil else { return }
        playerView?.saveShownotesForExternalAction()
        present(activity, animated: true)
    }

    private func visibleShareAnchor(_ original: UIView?) -> UIView? {
        var candidate = original
        while let source = candidate {
            candidate = source.superview
            guard let window = source.window else { continue }
            var visible = source.convert(source.bounds, to: window).intersection(window.bounds)
            var ancestor: UIView? = source
            while let view = ancestor {
                if view.isHidden || view.alpha < 0.01 { visible = .null; break }
                if view.clipsToBounds { visible = visible.intersection(view.convert(view.bounds, to: window)) }
                ancestor = view.superview
            }
            if !visible.isNull && !visible.isEmpty { return source }
        }
        return nil
    }

    func requestEpisodeMenu(feedID: Int64, episodeID: Int64) {
        Task { [weak self] in
            guard let self, let library else { return }
            do {
                guard let feed = try await library.listedFeedHeader(id: feedID), try await library.feedID(forEpisode: episodeID) == feedID,
                      let episode = try await library.episode(id: episodeID),
                      case .episode(let visibleFeed, let visibleEpisode) = path.last,
                      visibleFeed == feedID, visibleEpisode == episodeID else { return }
                // Playback saves can update position without recreating shownotes.
                // Read current menu state instead of the toolbar's captured copy.
                showEpisodeMenu(feed: feed, episode: episode)
            } catch { showError(error) }
        }
    }

    private func showEpisodeMenu(feed: LibraryFeed, episode: LibraryEpisode) {
        guard let anchor = toolbar.subviews.first(where: { $0.accessibilityIdentifier == "episodeMore" }) else { return }
        popup?.removeFromSuperview()
        let overlay = UIControl(frame: surface.bounds)
        overlay.addAction(UIAction { [weak self] _ in self?.popup?.removeFromSuperview(); self?.popup = nil }, for: .touchUpInside)
        let actions = EpisodeMenu.actions(episode: episode, feed: feed,
            queued: isQueued(episode.id),
            isSelectedMedia: playback?.episode?.id == episode.id)
        let titles = actions.map { Appearance.text($0.titleKey(hasMedia: episode.details.media != nil)) }
        let widths = titles.map { ($0 as NSString).size(withAttributes: [.font: Appearance.font(16)]).width }
        let layout = EpisodeMenuLayout(viewport: CGSize(width: surface.bounds.width, height: surface.bounds.height - view.safeAreaInsets.bottom),
            overflowAnchor: anchor.convert(anchor.bounds, to: surface), titleWidths: widths, density: traitCollection.displayScale,
            rightToLeft: view.effectiveUserInterfaceLayoutDirection == .rightToLeft)
        // Native ambient/spot layers fit measured straight-edge profiles.
        // The spot projects away from the viewport's top center; this preserves
        // the different left/right falloff on the phone and inset tablet popup.
        let shadow = UIView(frame: layout.panel)
        shadow.accessibilityIdentifier = "episodeMenuShadow"
        shadow.isUserInteractionEnabled = false
        let ambientShadow = CALayer()
        ambientShadow.shadowColor = UIColor.black.cgColor
        ambientShadow.shadowOpacity = 0.08
        ambientShadow.shadowRadius = 0.5
        ambientShadow.shadowOffset = .zero
        let spotShadow = CALayer()
        spotShadow.shadowColor = UIColor.black.cgColor
        spotShadow.shadowOpacity = 0.15
        spotShadow.shadowRadius = 1.75
        spotShadow.shadowOffset = .zero
        shadow.layer.addSublayer(ambientShadow)
        shadow.layer.addSublayer(spotShadow)
        func updateShadowPaths(frame: CGRect, viewportWidth: CGFloat) {
            let bounds = CGRect(origin: .zero, size: frame.size)
            ambientShadow.frame = bounds
            spotShadow.frame = bounds
            let path = UIBezierPath(roundedRect: bounds, cornerRadius: 4).cgPath
            ambientShadow.shadowPath = path
            let projection: CGFloat = 0.005
            var transform = CGAffineTransform(a: 1 + projection, b: 0, c: 0, d: 1 + projection,
                tx: (frame.minX - viewportWidth / 2) * projection, ty: frame.minY * projection)
            spotShadow.shadowPath = path.copy(using: &transform)
        }
        updateShadowPaths(frame: layout.panel, viewportWidth: surface.bounds.width)
        let panel = UIScrollView()
        panel.accessibilityIdentifier = "episodeMenuPanel"
        panel.backgroundColor = Appearance.navigation
        panel.layer.cornerRadius = 4
        panel.frame = layout.panel
        panel.contentSize = layout.contentSize
        for (index, action) in actions.enumerated() {
            let button = textButton(titles[index]) { [weak self] in
                guard let self, let library else { return }
                popup?.removeFromSuperview()
                popup = nil
                if action == .share {
                    presentEpisodeShare(feed: feed, episode: episode, anchor: toolbar)
                    return
                }
                if action == .openPodcast {
                    playerView?.setExpanded(false, animated: false)
                    if feed.subscriptionState == .notSubscribed { fetch(feed.source) }
                    else { push(.feed(feed.id)) }
                    return
                }
                Task {
                    do {
                        switch action {
                        case .skip:
                            // Selection, including paused media, controls eligibility.
                            // A stale menu must never skip a replacement episode.
                            guard let playback, playback.episode?.id == episode.id else { return }
                            try await playback.skip()
                        case .removeFromInbox:
                            try await library.removeEpisodeFromInbox(episodeID: episode.id)
                            scheduleMediaDeletionAfterMark(.init(episode: episode,
                                local: feed.source.isLocalFeedSource,
                                subscription: feed.subscriptionState))
                        case .removeFromQueue: _ = try await library.removeFromQueue([episode.id])
                        case .addToQueue: _ = try await library.enqueueUsingSettings([episode.id])
                        case .addFavorite, .removeFavorite:
                            try await library.setFavorite(episodeID: episode.id, favorite: action == .addFavorite)
                        case .markPlayed, .markUnplayed:
                            // The shared store queues the action for its selected sync account.
                            try await library.markEpisodePlayed(episodeID: episode.id, played: action == .markPlayed)
                        case .resetPosition:
                            if let playback { try await playback.resetPlaybackPosition(episodeID: episode.id) }
                            else { try await library.resetPlaybackPosition(episodeID: episode.id) }
                        default: return
                        }
                        await reloadLibrary()?.value
                    } catch { showError(error) }
                }
            }
            button.accessibilityIdentifier = action.rawValue
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.numberOfLines = 1
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.frame = layout.rows[index]
            panel.addSubview(button)
        }
        overlay.addSubview(shadow)
        overlay.addSubview(panel)
        surface.addSubview(overlay)
        popup = overlay
        layoutPopup = { [weak self, weak overlay, weak panel, weak shadow] in
            guard let self, let overlay, let panel, let shadow,
                  let anchor = toolbar.subviews.first(where: { $0.accessibilityIdentifier == "episodeMore" }) else { return }
            overlay.frame = surface.bounds
            let current = EpisodeMenuLayout(
                viewport: CGSize(width: surface.bounds.width, height: surface.bounds.height - view.safeAreaInsets.bottom),
                overflowAnchor: anchor.convert(anchor.bounds, to: surface), titleWidths: widths, density: traitCollection.displayScale,
                rightToLeft: view.effectiveUserInterfaceLayoutDirection == .rightToLeft)
            panel.frame = current.panel
            panel.contentSize = current.contentSize
            shadow.frame = current.panel
            updateShadowPaths(frame: current.panel, viewportWidth: surface.bounds.width)
            for (button, frame) in zip(panel.subviews.compactMap({ $0 as? UIButton }), current.rows) {
                button.frame = frame
            }
        }
    }
}

/// The answer to a local folder's delete warning, given once: by a button, by cancelling, or when the warning goes away.
@MainActor private final class LocalDeleteAnswer {
    private var answered: CheckedContinuation<Void, Never>?
    init(_ answered: CheckedContinuation<Void, Never>) { self.answered = answered }
    func resume() { answered?.resume(); answered = nil }
    isolated deinit { answered?.resume() }
}
